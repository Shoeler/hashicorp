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
  bound_service_account_namespaces = [var.vso_namespace, "default", "envoy-gateway-system"]
  token_policies                   = ["default", vault_policy.vso_policy.name]
  token_ttl                        = 3600
}

# --- Data Source to find Envoy Deployment ---
data "kubernetes_resources" "envoy_deployment" {
  api_version    = "apps/v1"
  kind           = "Deployment"
  namespace      = "envoy-gateway-system"
  label_selector = "gateway.envoyproxy.io/owning-gateway-name=eg"
}

locals {
  envoy_deploy_name = try(data.kubernetes_resources.envoy_deployment.objects[0].metadata[0].name, "")
}

output "envoy_deployment_name" {
  value = local.envoy_deploy_name
}

# --- Envoy Restarter Infrastructure ---

# Service Account for the restarter
resource "kubernetes_service_account" "envoy_restarter" {
  metadata {
    name      = "envoy-restarter"
    namespace = "envoy-gateway-system"
  }
}

# Role to allow restarting deployments in envoy-gateway-system
resource "kubernetes_role" "envoy_restarter_role" {
  metadata {
    name      = "envoy-restarter-role"
    namespace = "envoy-gateway-system"
  }

  rule {
    api_groups = ["apps", "extensions"]
    resources  = ["deployments"]
    verbs      = ["get", "list", "patch"]
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["get", "list", "watch"]
  }
}

# Bind the Role to the Service Account
resource "kubernetes_role_binding" "envoy_restarter_binding" {
  metadata {
    name      = "envoy-restarter-binding"
    namespace = "envoy-gateway-system"
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role.envoy_restarter_role.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account.envoy_restarter.metadata[0].name
    namespace = "envoy-gateway-system"
  }
}

# Deployment that runs kubectl to restart envoy
resource "kubernetes_deployment" "envoy_restarter" {
  metadata {
    name      = "envoy-restarter"
    namespace = "envoy-gateway-system"
  }

  spec {
    replicas = 1

    selector {
      match_labels = {
        app = "envoy-restarter"
      }
    }

    template {
      metadata {
        labels = {
          app = "envoy-restarter"
        }
      }

      spec {
        service_account_name = kubernetes_service_account.envoy_restarter.metadata[0].name
        container {
          name  = "restarter"
          image = "bitnami/kubectl:latest"
          command = ["/bin/sh", "-c"]
          args = [
            <<EOT
restart_envoy() {
  echo "$(date): Triggering Envoy Restart..."
  kubectl rollout restart -n envoy-gateway-system deployment/envoy-gateway || echo "Failed to restart controller."
  if [ -n "$ENVOY_DEPLOY_NAME" ]; then
    echo "Restarting Proxy Deployment: $ENVOY_DEPLOY_NAME"
    kubectl rollout restart -n envoy-gateway-system deployment/$ENVOY_DEPLOY_NAME || echo "Failed to restart proxy."
  else
    echo "Warning: ENVOY_DEPLOY_NAME is empty."
  fi
}

# 1. Immediate restart on pod startup (covers VSO rotation)
restart_envoy

# 2. Watch loop for manual secret changes (deletion/restoration)
echo "Starting Secret Watch Loop..."
LAST_RV=$(kubectl get secret flask-app-tls -n envoy-gateway-system -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null)

while true; do
  sleep 5
  CURRENT_RV=$(kubectl get secret flask-app-tls -n envoy-gateway-system -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null)

  # Handle case where secret was missing and came back, or changed
  if [ -n "$CURRENT_RV" ] && [ "$CURRENT_RV" != "$LAST_RV" ]; then
    if [ -n "$LAST_RV" ]; then
       echo "Secret changed (RV: $LAST_RV -> $CURRENT_RV). Restarting..."
       restart_envoy
    else
       # If LAST_RV was empty (secret missing), and now it exists, that's a restore.
       echo "Secret appeared/restored (RV: $CURRENT_RV). Restarting..."
       restart_envoy
    fi
    LAST_RV="$CURRENT_RV"
  elif [ -z "$CURRENT_RV" ]; then
    # Secret missing
    LAST_RV=""
  fi
done
EOT
          ]

          env {
            name  = "ENVOY_DEPLOY_NAME"
            value = local.envoy_deploy_name
          }
        }
      }
    }
  }
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

# --- Resources for Envoy Gateway System ---

# 5. VaultConnection for envoy-gateway-system
resource "kubernetes_manifest" "vault_connection_eg" {
  manifest = {
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultConnection"
    metadata = {
      name      = "default"
      namespace = "envoy-gateway-system"
    }
    spec = {
      address = "http://vault.default.svc:8200"
    }
  }
}

# 6. VaultAuth for envoy-gateway-system
resource "kubernetes_manifest" "vault_auth_eg" {
  manifest = {
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultAuth"
    metadata = {
      name      = "default"
      namespace = "envoy-gateway-system"
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

# 7. VaultPKISecret for Envoy in envoy-gateway-system
resource "kubernetes_manifest" "vault_pki_secret_eg" {
  manifest = {
    apiVersion = "secrets.hashicorp.com/v1beta1"
    kind       = "VaultPKISecret"
    metadata = {
      name      = "flask-app-cert-envoy"
      namespace = "envoy-gateway-system"
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
      rolloutRestartTargets = [
        {
          kind = "Deployment"
          name = "envoy-restarter"
        }
      ]
    }
  }
}

# 8. ReferenceGrant to allow Gateway (in default) to read Secret (in envoy-gateway-system)
resource "kubernetes_manifest" "reference_grant" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1beta1"
    kind       = "ReferenceGrant"
    metadata = {
      name      = "allow-gateway-secret-read"
      namespace = "envoy-gateway-system"
    }
    spec = {
      from = [
        {
          group     = "gateway.networking.k8s.io"
          kind      = "Gateway"
          namespace = "default"
        }
      ]
      to = [
        {
          group = ""
          kind  = "Secret"
          name  = "flask-app-tls"
        }
      ]
    }
  }
}