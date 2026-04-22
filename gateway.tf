# --- Envoy Gateway Helm Release ---

resource "helm_release" "envoy_gateway" {
  name             = "eg"
  repository       = "oci://docker.io/envoyproxy"
  chart            = "gateway-helm"
  version          = "v1.2.0"
  namespace        = "envoy-gateway-system"
  create_namespace = true
  wait             = true
  timeout          = 600
}

# --- Envoy Gateway Kubernetes Resources ---

resource "kubernetes_manifest" "envoy_proxy_config" {
  manifest = {
    apiVersion = "gateway.envoyproxy.io/v1alpha1"
    kind       = "EnvoyProxy"
    metadata = {
      name      = "static-nodeport-config"
      namespace = "envoy-gateway-system"
    }
    spec = {
      provider = {
        type = "Kubernetes"
        kubernetes = {
          envoyService = {
            type = "LoadBalancer"
          }
        }
      }
    }
  }
  depends_on = [helm_release.envoy_gateway]
}

resource "kubernetes_manifest" "gateway_class" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "GatewayClass"
    metadata = {
      name = "eg"
    }
    spec = {
      controllerName = "gateway.envoyproxy.io/gatewayclass-controller"
      parametersRef = {
        group     = "gateway.envoyproxy.io"
        kind      = "EnvoyProxy"
        name      = "static-nodeport-config"
        namespace = "envoy-gateway-system"
      }
    }
  }
  depends_on = [kubernetes_manifest.envoy_proxy_config]
}

# Gateway with HTTP listener only — HTTPS is added after the TLS cert is provisioned
# (see null_resource.gateway_add_https_listener below)
resource "kubernetes_manifest" "gateway" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "Gateway"
    metadata = {
      name      = "eg"
      namespace = "default"
    }
    spec = {
      gatewayClassName = "eg"
      listeners = [
        {
          name     = "http"
          protocol = "HTTP"
          port     = 80
        }
      ]
    }
  }
  depends_on = [kubernetes_manifest.gateway_class]
}

resource "kubernetes_manifest" "vault_httproute" {
  manifest = {
    apiVersion = "gateway.networking.k8s.io/v1"
    kind       = "HTTPRoute"
    metadata = {
      name      = "vault"
      namespace = "default"
    }
    spec = {
      parentRefs = [{ name = "eg" }]
      rules = [
        {
          backendRefs = [
            {
              name = "vault"
              port = 8200
            }
          ]
        }
      ]
    }
  }
  depends_on = [kubernetes_manifest.gateway]
}

# --- Dynamic Port Detection ---
# Envoy Gateway assigns container ports that vary by platform (macOS/Podman differs from Linux).
# We query the managed service after the Gateway is created rather than hardcoding values.

data "external" "envoy_http_port" {
  program = [
    "bash", "-c", <<-SCRIPT
      RETRIES=30
      SLEEP=3
      for ((i=1; i<=RETRIES; i++)); do
        PORT=$(kubectl get svc \
          -n envoy-gateway-system \
          -l gateway.envoyproxy.io/owning-gateway-name=eg \
          -o jsonpath='{.items[0].spec.ports[?(@.name=="http")].targetPort}' 2>/dev/null)
        [ -z "$PORT" ] && PORT=$(kubectl get svc \
          -n envoy-gateway-system \
          -l gateway.envoyproxy.io/owning-gateway-name=eg \
          -o jsonpath='{.items[0].spec.ports[?(@.port==80)].targetPort}' 2>/dev/null)
        if [ -n "$PORT" ]; then
          echo "{\"port\": \"$PORT\"}"
          exit 0
        fi
        sleep $SLEEP
      done
      echo "{\"port\": \"80\"}"
    SCRIPT
  ]
  depends_on = [kubernetes_manifest.gateway]
}

# HTTP-only NodePort service — created in Phase 2 so Vault is accessible before Phase 3
resource "kubernetes_service" "gateway_nodeports_http" {
  metadata {
    name      = "gateway-nodeports-http"
    namespace = "envoy-gateway-system"
  }
  spec {
    type = "NodePort"
    selector = {
      "gateway.envoyproxy.io/owning-gateway-name"      = "eg"
      "gateway.envoyproxy.io/owning-gateway-namespace" = "default"
    }
    port {
      name        = "http"
      port        = 80
      target_port = data.external.envoy_http_port.result.port
      node_port   = var.gateway_http_node_port
      protocol    = "TCP"
    }
  }
  depends_on = [data.external.envoy_http_port]
}

# --- HTTPS Listener + NodePort (Phase 3, after TLS cert is provisioned by VSO) ---

# Patch the Gateway to add the HTTPS listener once flask-app-tls secret exists
resource "null_resource" "gateway_add_https_listener" {
  provisioner "local-exec" {
    command = <<-CMD
      kubectl patch gateway eg -n default --type=merge -p '{
        "spec": {"listeners": [
          {"name": "http", "protocol": "HTTP", "port": 80},
          {"name": "https", "protocol": "HTTPS", "port": 443, "tls": {
            "mode": "Terminate",
            "certificateRefs": [{"name": "flask-app-tls"}]
          }}
        ]}
      }'
    CMD
  }
  # vault_pki_secret (in vso.tf) triggers VSO to create flask-app-tls
  depends_on = [kubernetes_manifest.vault_pki_secret]
}

data "external" "envoy_https_port" {
  program = [
    "bash", "-c", <<-SCRIPT
      RETRIES=30
      SLEEP=3
      for ((i=1; i<=RETRIES; i++)); do
        PORT=$(kubectl get svc \
          -n envoy-gateway-system \
          -l gateway.envoyproxy.io/owning-gateway-name=eg \
          -o jsonpath='{.items[0].spec.ports[?(@.name=="https")].targetPort}' 2>/dev/null)
        [ -z "$PORT" ] && PORT=$(kubectl get svc \
          -n envoy-gateway-system \
          -l gateway.envoyproxy.io/owning-gateway-name=eg \
          -o jsonpath='{.items[0].spec.ports[?(@.port==443)].targetPort}' 2>/dev/null)
        if [ -n "$PORT" ]; then
          echo "{\"port\": \"$PORT\"}"
          exit 0
        fi
        sleep $SLEEP
      done
      echo "{\"port\": \"443\"}"
    SCRIPT
  ]
  depends_on = [null_resource.gateway_add_https_listener]
}

# HTTPS-only NodePort service — created after TLS cert + HTTPS listener are active
resource "kubernetes_service" "gateway_nodeports_https" {
  metadata {
    name      = "gateway-nodeports-https"
    namespace = "envoy-gateway-system"
  }
  spec {
    type = "NodePort"
    selector = {
      "gateway.envoyproxy.io/owning-gateway-name"      = "eg"
      "gateway.envoyproxy.io/owning-gateway-namespace" = "default"
    }
    port {
      name        = "https"
      port        = 443
      target_port = data.external.envoy_https_port.result.port
      node_port   = var.gateway_https_node_port
      protocol    = "TCP"
    }
  }
  depends_on = [data.external.envoy_https_port]
}
