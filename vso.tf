# --- Vault Secrets Operator Helm Release ---

resource "helm_release" "vault_secrets_operator" {
  name       = "vault-secrets-operator"
  repository = "https://helm.releases.hashicorp.com"
  chart      = "vault-secrets-operator"
  version    = "1.3.0"

  set {
    name  = "defaultVaultConnection.enabled"
    value = "false"
  }

  wait       = true
  timeout    = 600
  depends_on = [helm_release.vault]
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
  depends_on = [helm_release.vault_secrets_operator]
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
  depends_on = [
    helm_release.vault_secrets_operator,
    kubernetes_manifest.vault_connection,
  ]
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
      type  = "kv-v2"
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
  depends_on = [kubernetes_manifest.vault_auth]
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
  depends_on = [kubernetes_manifest.vault_auth]
}
