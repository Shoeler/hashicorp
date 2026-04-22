variable "vso_namespace" {
  description = "Namespace where Vault Secrets Operator is installed"
  type        = string
  default     = "default"
}

variable "vso_service_account" {
  description = "Service Account name for Vault Secrets Operator"
  type        = string
  default     = "vault-secrets-operator"
}

variable "cluster_name" {
  description = "Name of the Kind cluster"
  type        = string
  default     = "vault-demo"
}

variable "vault_dev_token" {
  description = "Root token for Vault dev mode"
  type        = string
  default     = "root"
}

variable "registry_node_port" {
  description = "NodePort for the container registry"
  type        = number
  default     = 30500
}

variable "gateway_http_node_port" {
  description = "NodePort for the Envoy Gateway HTTP listener"
  type        = number
  default     = 30080
}

variable "gateway_https_node_port" {
  description = "NodePort for the Envoy Gateway HTTPS listener"
  type        = number
  default     = 30443
}

variable "flask_image_tag" {
  description = "Tag for the Flask app container image"
  type        = string
  default     = "latest"
}
