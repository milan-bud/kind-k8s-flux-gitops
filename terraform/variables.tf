variable "github_token" {
  type      = string
  sensitive = true
}

variable "github_owner" {
  type = string
}

variable "environments" {
  type    = list(string)
  default = ["production", "test"]
}
