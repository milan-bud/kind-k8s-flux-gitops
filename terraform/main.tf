# 1. Provider Configurations
terraform {
  required_providers {
    kind = {
      source  = "tehcyx/kind"
      version = "0.7.0"
    }
    github = {
      source  = "integrations/github"
      version = "6.6.0"
    }
    flux = {
      source  = "fluxcd/flux"
      version = "1.4.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.35.0"
    }
  }
}

# 2. Infrastructure Layer: Kind Cluster
resource "kind_cluster" "devops_task" {
  name           = "devops-task-cluster"
  wait_for_ready = true
  
  kind_config {
    kind        = "Cluster"
    api_version = "kind.x-k8s.io/v1alpha4"

    node {
      role = "control-plane"
      extra_port_mappings {
        container_port = 80
        host_port      = 80
      }
    }
    node { role = "worker" } # Scalability
    node { role = "worker" }
  }
}

# 3. Security Layer: Namespace, PSS, and Service Account (Kubernetes provider pointing to our new Kind cluster)
provider "kubernetes" {
  host                   = kind_cluster.devops_task.endpoint
  client_certificate     = kind_cluster.devops_task.client_certificate
  client_key             = kind_cluster.devops_task.client_key
  cluster_ca_certificate = kind_cluster.devops_task.cluster_ca_certificate
}

# Create namespaces
resource "kubernetes_namespace" "envs" {
  for_each = toset(var.environments)

  metadata {
    name = each.value
    labels = {
      # Apply the same security standards to all environments
      "pod-security.kubernetes.io/enforce" = "baseline"
    }
  }
}

# Update Service Account
resource "kubernetes_service_account" "app_sa" {
  for_each = toset(var.environments)

  metadata {
    name      = "webapp-sa"
    namespace = kubernetes_namespace.envs[each.value].metadata[0].name
  }
}

# 4. Git Glue: GitHub Repository Setup
provider "github" {
  token = var.github_token # Pass this as an env var TF_VAR_github_token
  owner = var.github_owner
}

resource "github_repository" "main" {
  name        = "kind-k8s-flux-gitops"
  visibility  = "public"
  auto_init   = true
}

# 5. GitOps Layer: Flux Bootstrap
provider "flux" {
  kubernetes = {
    host                   = kind_cluster.devops_task.endpoint
    client_certificate     = kind_cluster.devops_task.client_certificate
    client_key             = kind_cluster.devops_task.client_key
    cluster_ca_certificate = kind_cluster.devops_task.cluster_ca_certificate
  }
  git = {
    url = github_repository.main.http_clone_url
    http = {
      username = "git"
      password = var.github_token
    }
  }
}

resource "flux_bootstrap_git" "this" {
  depends_on = [github_repository.main, kind_cluster.devops_task]
  path       = "clusters/production"
}

# 6. Network Security: Default Deny All (Except what is explicitly allowed)
resource "kubernetes_network_policy" "default_deny" {
  for_each = toset(var.environments)

  metadata {
    name      = "default-deny-all"
    namespace = kubernetes_namespace.envs[each.value].metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
}

# Allow Ingress to Web App from the Nginx Ingress Controller
resource "kubernetes_network_policy" "allow_web_traffic" {
  for_each = toset(var.environments)

  metadata {
    name      = "allow-web-traffic"
    namespace = kubernetes_namespace.envs[each.value].metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = {
        app = "webapp"
      }
    }

    ingress {
      from {
        namespace_selector {} 
      }
      ports {
        port     = 80
        protocol = "TCP"
      }
    }

    policy_types = ["Ingress"]
  }
}
