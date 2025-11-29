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
EOT
}

# Role binding VSO SA to the policy
resource "vault_kubernetes_auth_backend_role" "vso_role" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "vso-role"
  bound_service_account_names      = [var.vso_service_account]
  bound_service_account_namespaces = [var.vso_namespace]
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
        role = vault_kubernetes_auth_backend_role.vso_role.role_name
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
    }
  }
}
