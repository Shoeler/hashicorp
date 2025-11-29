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
