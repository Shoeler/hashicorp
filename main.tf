# --- Vault Configuration ---
resource "vault_mount" "kvv2" {
  path        = "secret"
  type        = "kv"
  options     = { version = "2" }
  description = "KV Version 2 secret engine mount"
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
}

# Configure Root CA
resource "vault_pki_secret_backend_root_cert" "root" {
  backend = vault_mount.pki.path
  type    = "internal"
  common_name = "example.com"
  ttl = "87600h"
}

# Configure PKI Role
resource "vault_pki_secret_backend_role" "role" {
  backend = vault_mount.pki.path
  name    = "flask-app-role"
  allowed_domains = ["example.com", "flask-app.default.svc"]
  allow_subdomains = true
  allow_bare_domains = true
  max_ttl = "72h"
}

# Enable Kubernetes Auth
resource "vault_auth_backend" "kubernetes" {
  type = "kubernetes"
}

# Configure Kubernetes Auth to point to the internal K8s API
# In a Kind cluster, Vault (running inside) can talk to K8s via the default service.
resource "vault_kubernetes_auth_backend_config" "config" {
  backend         = vault_auth_backend.kubernetes.path
  kubernetes_host = "https://kubernetes.default.svc"
  # In dev mode/kind, we often don't need to specify the CA cert or JWT issuer explicitly
  # if Vault is running inside the cluster and using the service account token.
  # However, sometimes we might need to disable issuer validation if things are tricky.
  # For now, we rely on defaults which usually work for in-cluster Vault.
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

# --- Vault Secrets Operator CRDs ---

# 1. VaultConnection
resource "kubernetes_manifest" "vault_connection" {
  manifest = {
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultConnection"
    metadata = {
      name      = "default"
      namespace = "default"
    }
    spec = {
      address = "http://vault.default.svc:8200"
    }
  }
}

# 2. VaultAuth
resource "kubernetes_manifest" "vault_auth" {
  manifest = {
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultAuth"
    metadata = {
      name      = "default"
      namespace = "default"
    }
    spec = {
      method = "kubernetes"
      mount  = vault_auth_backend.kubernetes.path
      kubernetes = {
        role           = vault_kubernetes_auth_backend_role.vso_role.role_name
        serviceAccount = "default"
      }
      vaultConnectionRef = "default"
    }
  }
}

# 3. VaultStaticSecret
resource "kubernetes_manifest" "vault_static_secret" {
  manifest = {
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultStaticSecret"
    metadata = {
      name      = "example-secret"
      namespace = "default"
    }
    spec = {
      type = "kv-v2"
      mount = vault_mount.kvv2.path
      path  = vault_kv_secret_v2.example.name
      destination = {
        create = true
        name   = "k8s-secret-from-vault"
      }
      vaultAuthRef = "default"
      refreshAfter = "10s"
      rolloutRestartTargets = [
        {
          kind = "Deployment"
          name = "flask-app"
        }
      ]
    }
  }
}

# 4. VaultPKISecret
resource "kubernetes_manifest" "vault_pki_secret" {
  manifest = {
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultPKISecret"
    metadata = {
      name      = "flask-app-cert"
      namespace = "default"
    }
    spec = {
      vaultAuthRef = "default"
      mount        = vault_mount.pki.path
      role         = vault_pki_secret_backend_role.role.name
      commonName   = "flask-app.default.svc"
      format       = "pem"
      destination = {
        create = true
        name   = "flask-app-tls"
        type   = "kubernetes.io/tls"
      }
    }
  }
}