**\# Devops task: Terraform, Kind, FluxCD, Simple Web App**

About: A comprehensive Kubernetes environment demonstrating a GitOps operating model. 

**\#\# Architecture**

| Domain | Tooling |  
| :--- | :--- |  
| \*\*Infrastructure\*\* | Kind (Kubernetes in Docker), Terraform (Bootstrap) |  
| \*\*GitOps\*\* | FluxCD (Source, Kustomize, & Helm Controllers) |  
| \*\*Secret Mgmt\*\* | HashiCorp Vault \+ External Secrets Operator (ESO) |  
| \*\*Observability\*\* | Prometheus (Metrics), Loki (Logs), Alloy (Collector) |  
| \*\*Scaling\*\* | Metrics Server \+ Horizontal Pod Autoscaler (HPA) |

\---

**\#\# Repository Structure**

Repository contains both the Infrastructure-as-Code (Terraform) and the Kubernetes Configuration (Flux).

.  
├── apps/                  \# Application workloads (Base & Overlays)  
│   ├── base/              \# Deployment, Service, HPA, NetworkPolicy  
│   └── overlays/          \# Environment specifics (Prod/Test)  
├── clusters/              \# Flux Cluster definitions  
├── docs/                  \# README.md, validation PDF
├── infrastructure/        \# Core Infra (Vault, ESO, Monitoring)  
│   ├── monitoring/        \# Prometheus, Loki, Alloy, Grafana, Metrics Server  
│   ├── operator/        \# ESO  
│   ├── vault/        \# Vault, Vault bridge  
│   └── ...  
└── terraform/             \# Terraform Bootstrap Scripts

\---

**\#\# Deployment Steps**

Step 1: Bootstrap (Infrastructure as Code)

The cluster and Flux controllers are provisioned using Terraform.

Security Note: Credentials are **not** hardcoded. They can be injected as Environment Variables (e.g., \`TF\_VAR\_github\_token\`) or passed via a \`.tfvars\` file that is excluded from version control via \`.gitignore\`.

RUN: cd terraform; terraform init && terraform apply

### Step 2: Secret Injection (**The "Secret Zero" Problem**)

Since Vault runs in Dev Mode for this lab, the integration bridge must be configured manually after the pod starts.

Command Log:  
\# 1\. Open a shell inside the Vault pod  
kubectl exec \-it vault-0 \-n flux-system \-- /bin/sh

\# 2\. (Inside the pod) Run these commands one by one:  
export VAULT\_ADDR='http://127.0.0.1:8200'  
export VAULT\_TOKEN='root'

\# Enable Kubernetes Auth (The step that was failing)  
vault auth enable kubernetes

\# Configure Vault to talk to the Kubernetes API  
vault write auth/kubernetes/config \\  
    kubernetes\_host="https://$KUBERNETES\_PORT\_443\_TCP\_ADDR:443"

\# Create the Policy that allows reading secrets  
vault policy write webapp-policy \- \<\<EOF  
path "secret/data/\*" {  
  capabilities \= \["read"\]  
}  
EOF

\# Create the Role that links your ESO ServiceAccount to the Policy  
vault write auth/kubernetes/role/webapp-role \\  
    bound\_service\_account\_names=external-secrets \\  
    bound\_service\_account\_namespaces=flux-system \\  
    policies=webapp-policy \\  
    ttl=24h

\# Create the actual Secret for Grafana  
vault kv put secret/grafana password="SuperSecretPassword123\!"

\# 3\. Exit the pod  
exit

Wait 1 minute.

Check if the Secret was created:   
kubectl get secret grafana-admin-credentials \-n flux-system.

If yes, delete the Grafana pod to restart it with the new password.  
If no, wait a bit more (until vault is ready\!), or check if external secret is there.

*Events:*  
  *Type     Reason        Age                   From              Message*  
  *\----     \------        \----                  \----              \-------*  
  *Warning  UpdateFailed  8m16s (x19 over 79m)  external-secrets  error processing spec.data\[0\] (key: secret/data/grafana), err: ClusterSecretStore "vault-backend" is not ready*  
  *Normal   Created       76s                   external-secrets  secret created*

As grafana is part of prometheus-stack, do again:  
flux reconcile helmrelease kube-prometheus-stack \-n flux-system

Verify that external secret is synced:  
kubectl get externalsecret grafana-admin-credentials \-n flux-system

**\#\# Requirement Verification**

1.Security

    Least Privilege: WebApp runs with securityContext: runAsNonRoot: true using the nginxinc/nginx-unprivileged image to avoid permission errors.

    Network Policy: A Zero-Trust policy (deny-all-ingress) is applied, strictly allowing traffic only from the Ingress controller and Prometheus.

    Secret Management: No secrets are stored in Git. All secrets are injected at runtime via ESO from Vault.

2.Scalability

    HPA Configured: The WebApp scales between 2 and 10 pods based on CPU utilization.

    Infrastructure: The metrics-server is deployed to provide real-time resource usage data to the Autoscaler.

    Verification: kubectl get hpa webapp-hpa shows the current target percentage (e.g., 0%/50%).

3.Resilience

    Auto-Rollback: All HelmReleases (Loki, Alloy, etc.) are configured with remediateLastFailure: true. If an upgrade fails (e.g., bad config), Flux automatically reverts to the previous working version.

    Drift Detection: Flux reconciles the cluster state every 60 minutes to correct any manual changes.

**\#\# Issues Faced & Resolutions**

\#Issue 1: The "Webhook Deadlock"

Symptoms: flux reconcile would hang indefinitely during the initial bootstrap of the monitoring stack.

Root Cause: The kube-prometheus-stack and external-secrets charts install ValidatingWebhookConfigurations. Flux attempted to create resources that required validation before the webhook pods were fully ready, causing the API server to block its own requests. 

Resolution: Explicitly disabled admissionWebhooks in the HelmRelease values during the bootstrap phase to break the dependency cycle.

\#Issue 2: Metrics Server vs. Kind Networking

Symptoms: The Horizontal Pod Autoscaler (HPA) failed to calculate CPU usage, and the metrics-server pod crashed with TLS errors. 

Root Cause: Kind clusters use self-signed certificates for Kubelets, which the standard Metrics Server rejects by default. 

Resolution: Patched the metrics-server HelmRelease with the argument \--kubelet-insecure-tls to allow it to scrape metrics from Kind nodes.

\#Issue 3: Application Security & File Permissions

Symptoms: After implementing the Security Requirement (running as runAsNonRoot: true), the Nginx-based WebApp crashed with mkdir() "/var/cache/nginx" failed: Permission denied. Root 

Cause: Standard Nginx images attempt to write to root-owned directories (/var/cache), which is forbidden for non-root users (UID 1000). 

Resolution: Switched the container image to nginxinc/nginx-unprivileged, which is pre-configured to write to accessible directories, ensuring compliance with the security policy.

\#Issue 4: Cluster rebuild: destroy & apply

Symptoms: After rebuilding the cluster, several Kustomizations (external-secrets, vault, monitoring) tried to reconcile at the same time.   
Vault-0 was missing because its Kustomization was failing a "Dry-Run" check, even though the External Secrets Operator pods were technically "Running."

Root Cause: In a Kind (Kubernetes-in-Docker) environment on a VM, the External Secrets Webhook takes significant CPU to generate TLS certificates and initialize its network listener. The Kubernetes API server has a default 5-second timeout to reach this webhook. Because the VM was under high load during the "cold start," the webhook didn't answer in time, causing the i/o timeout error.

Resolution: Implemented a Tiered Dependency Tree using dependsOn in the Flux Kustomization specs. This forced Flux to wait until the Operator was 100% healthy before even attempting to deploy Vault.

\#Issue 5: Webhook deadline exceeded (again, tried to fix timeouts)

Symptoms: Even with dependencies, the webhook continued to time out with context deadline exceeded.  
Manual kubectl patch commands failed because the webhook configuration names differed from the standard documentation.

Root Cause: The latency in Kind's internal networking (bridging between the Master and Worker nodes) was consistently exceeding the 5-second threshold.

Resolution: First identified the specific validators: externalsecret-validate and secretstore-validate. Second, attempted to increase the timeoutSeconds to 30s.  
Third, for the sake of the lab environment, we eventually disabled the webhook creation in the HelmRelease values (webhook.create: false) to bypass the "gatekeeper" entirely and allow the Vault pod to spawn.

\#Issue 6: Missing File & Schema Validation Errors

Symptoms: Moving vault.yaml to a subfolder caused the infrastructure-monitoring Kustomization to crash with a "no such file or directory" error.

Resolution: The file path error was a side effect of reorganizing the repo into a cleaner structure without updating the parent Kustomization.

\#Issue 7: Vault KV-V2 Path Mismatch

Symptoms: The ExternalSecret reported SecretSyncError even after Vault was running.  
Events showed error processing spec.data\[0\]... ClusterSecretStore "vault-backend" is not ready.

Root Cause: There was a mismatch between how Vault stores data in KV Version 2 (which uses a nested data/ path) and how the ExternalSecret was trying to fetch it. Additionally, the Kubernetes Auth engine in Vault needed manual initialization of the token\_reviewer\_jwt.

Resolution: Manually entered the vault-0 pod to:

1. Enable auth kubernetes.  
   2. Configure the webapp-role bound to the external-secrets ServiceAccount.  
   3. Define a webapp-policy with read capabilities on the secret/data/\* path.

\#Issue 8: Helm Controller Cache Sync

Symptoms: kube-prometheus-stack reported secrets "grafana-admin-credentials" not found even after the secret was created. The Monitoring stack remained in a "False" state.

Root Cause: The Helm Controller cached the failure when the secret was missing and didn't immediately notice when the External Secrets Operator finally created it.

Resolution: Manual flux reconcile helmrelease forced the controller to re-check the cluster state, find the new secret, and complete the Grafana installation.

**\#\# Validation commands**

\#Cluster check  
kubectl get nodes  
Kubectl get pods \-A

\#Flux check  
Flux get all

\# Check if secrets were successfully pulled from Vault   
kubectl get externalsecrets \-n flux-system

\#Check production namespace inventory (webapp)  
kubectl describe kustomization webapp-production \-n flux-system 

\# Check if Alloy is successfully pushing logs to Loki  
kubectl logs \-l app.kubernetes.io/name=alloy \-n flux-system 

\# Verify Autoscaling   
kubectl get hpa \-A

[View Validation Report](./docs/validation/DevOps_TaskValidationSnapshots.pdf)
