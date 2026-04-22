# --- Vault Helm Release ---

resource "helm_release" "vault" {
  name       = "vault"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault"
  version    = "0.32.0"

  set {
    name  = "server.dev.enabled"
    value = "true"
  }
  set {
    name  = "server.dev.devRootToken"
    value = var.vault_dev_token
  }

  wait    = true
  timeout = 600
}

# --- Vault Configuration ---

resource "vault_mount" "kvv2" {
  path        = "secret"
  type        = "kv"
  options     = { version = "2" }
  description = "KV Version 2 secret engine mount"

  depends_on = [helm_release.vault]
}

resource "vault_kv_secret_v2" "example" {
  mount               = vault_mount.kvv2.path
  name                = "example"
  cas                 = 1
  delete_all_versions = true
  data_json = jsonencode(
    {
      username = "admin"
      password = "supersecretpassword"
    }
  )
}

# Enable PKI secrets engine
resource "vault_mount" "pki" {
  path        = "pki"
  type        = "pki"
  description = "PKI backend"

  depends_on = [helm_release.vault]
}

# Configure Root CA
resource "vault_pki_secret_backend_root_cert" "root" {
  backend     = vault_mount.pki.path
  type        = "internal"
  common_name = "example.com"
  ttl         = "87600h"
}

# Configure PKI Role
resource "vault_pki_secret_backend_role" "role" {
  backend            = vault_mount.pki.path
  name               = "flask-app-role"
  allowed_domains    = ["example.com", "flask-app.default.svc"]
  allow_subdomains   = true
  allow_bare_domains = true
  max_ttl            = "72h"
}

# Enable Kubernetes Auth
resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"

  depends_on = [helm_release.vault]
}

# Configure Kubernetes Auth to point to the internal K8s API
resource "vault_kubernetes_auth_backend_config" "config" {
  backend         = vault_auth_backend.kubernetes.path
  kubernetes_host = "https://kubernetes.default.svc"
}

# Policy for VSO
resource "vault_policy" "vso_policy" {
  name = "vso-policy"

  policy = <<EOT
path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["list"]
}
path "pki/issue/*" {
  capabilities = ["create", "update"]
}
EOT
}

# Role binding VSO SA to the policy
resource "vault_kubernetes_auth_backend_role" "vso_role" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "vso-role"
  bound_service_account_names      = [var.vso_service_account, "default"]
  bound_service_account_namespaces = [var.vso_namespace, "default"]
  token_policies                   = ["default", vault_policy.vso_policy.name]
  token_ttl                        = 3600
}
