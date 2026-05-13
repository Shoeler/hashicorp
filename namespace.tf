# --- Namespace Isolation Demo ---
#
# Demonstrates that VSO auth roles are scoped to a namespace: the flask-app
# namespace can only read secret/flask-app/* and cannot access secrets owned
# by the default namespace tenant.

resource "kubernetes_namespace" "flask_app" {
  metadata {
    name = "flask-app"
  }
}

# Vault policy: read-only access to flask-app/* secrets only
resource "vault_policy" "flask_app_policy" {
  name = "flask-app-policy"

  policy = <<EOT
path "secret/data/flask-app/*" {
  capabilities = ["read"]
}
path "secret/metadata/flask-app/*" {
  capabilities = ["list"]
}
EOT

  depends_on = [helm_release.vault]
}

# KV secret owned by the flask-app tenant
resource "vault_kv_secret_v2" "flask_app_config" {
  mount               = vault_mount.kvv2.path
  name                = "flask-app/config"
  delete_all_versions = true
  data_json = jsonencode({
    api_key = "demo-api-key-abc123"
    tier    = "premium"
  })
}

# K8s auth role bound exclusively to the flask-app namespace
resource "vault_kubernetes_auth_backend_role" "flask_app_role" {
  backend                          = vault_auth_backend.kubernetes.path
  role_name                        = "flask-app-role"
  bound_service_account_names      = ["default"]
  bound_service_account_namespaces = ["flask-app"]
  token_policies                   = ["default", vault_policy.flask_app_policy.name]
  token_ttl                        = 3600
}

# VSO resources scoped to the flask-app namespace

resource "kubernetes_manifest" "flask_app_vault_connection" {
  manifest = {
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultConnection"
    metadata = {
      name      = "default"
      namespace = "flask-app"
    }
    spec = {
      address = "http://vault.default.svc:8200"
    }
  }
  depends_on = [
    helm_release.vault_secrets_operator,
    kubernetes_namespace.flask_app,
  ]
}

resource "kubernetes_manifest" "flask_app_vault_auth" {
  manifest = {
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultAuth"
    metadata = {
      name      = "default"
      namespace = "flask-app"
    }
    spec = {
      method = "kubernetes"
      mount  = vault_auth_backend.kubernetes.path
      kubernetes = {
        role           = vault_kubernetes_auth_backend_role.flask_app_role.role_name
        serviceAccount = "default"
      }
      vaultConnectionRef = "default"
    }
  }
  depends_on = [
    kubernetes_manifest.flask_app_vault_connection,
    vault_kubernetes_auth_backend_role.flask_app_role,
  ]
}

resource "kubernetes_manifest" "flask_app_isolated_secret" {
  manifest = {
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultStaticSecret"
    metadata = {
      name      = "app-config"
      namespace = "flask-app"
    }
    spec = {
      type  = "kv-v2"
      mount = vault_mount.kvv2.path
      path  = "flask-app/config"
      destination = {
        create = true
        name   = "flask-app-isolated-secret"
      }
      vaultAuthRef = "default"
      refreshAfter = "10s"
    }
  }
  depends_on = [
    kubernetes_manifest.flask_app_vault_auth,
    vault_kv_secret_v2.flask_app_config,
  ]
}
