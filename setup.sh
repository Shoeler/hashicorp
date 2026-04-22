#!/bin/bash
set -e

BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

CLUSTER_NAME="vault-demo"
REDEPLOY_ONLY=false

section() { echo -e "\n${BOLD}${BLUE}==> $*${NC}"; }
ok()      { echo -e "    ${GREEN}✓${NC} $*"; }
info()    { echo -e "    ${CYAN}->${NC} $*"; }
waiting() { echo -e "    ${YELLOW}..${NC} $*"; }
err()     { echo -e "\n    ${RED}✗ Error:${NC} $*" >&2; }
hr()      { echo -e "${BLUE}────────────────────────────────────────────────────────────${NC}"; }

hr
echo -e "${BOLD}  Vault Demo Setup${NC}"
hr

if [ "$1" == "--redeploy-flask" ]; then
  REDEPLOY_ONLY=true
  echo -e "\n  Mode: Flask App redeploy only"
fi

# 1. Prerequisite checks
section "Checking prerequisites"
for cmd in kind kubectl helm terraform; do
  command -v "$cmd" >/dev/null 2>&1 || { err "$cmd is required but not installed."; exit 1; }
  ok "$cmd"
done

if command -v podman >/dev/null 2>&1; then
  ok "podman (configuring Kind to use it)"
  export KIND_EXPERIMENTAL_PROVIDER=podman
else
  command -v docker >/dev/null 2>&1 || { err "neither podman nor docker found."; exit 1; }
  ok "docker"
fi

if [ "$REDEPLOY_ONLY" == "false" ]; then

  # 2. Create Kind cluster
  section "Creating Kind cluster: ${CLUSTER_NAME}"
  if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    waiting "Cluster already exists — deleting to start fresh..."
    kind delete cluster --name "${CLUSTER_NAME}"
  fi

  info "Generating registry configuration..."
  rm -rf registry-config
  mkdir -p registry-config/registry-docker-registry.default.svc.cluster.local:5000
  cat <<EOF > registry-config/registry-docker-registry.default.svc.cluster.local:5000/hosts.toml
server = "http://registry-docker-registry.default.svc.cluster.local:5000"

[host."http://127.0.0.1:30500"]
  capabilities = ["pull", "resolve"]
EOF

  kind create cluster --name "${CLUSTER_NAME}" --config kind-config.yaml
  ok "Cluster created"

  # 3. Terraform — three phases to handle provider bootstrap ordering:
  #   Phase 1: Helm releases only (installs CRDs; vault provider not invoked)
  #   Phase 2: Gateway k8s resources (makes Vault accessible via NodePort)
  #   Phase 3: Full apply (vault provider can now connect)

  section "Initializing Terraform"
  terraform init

  section "Phase 1: Installing Helm releases"
  info "Installing: registry, envoy gateway, vault, VSO..."
  terraform apply -auto-approve \
    -target=helm_release.registry \
    -target=helm_release.envoy_gateway \
    -target=helm_release.vault \
    -target=helm_release.vault_secrets_operator
  ok "Helm releases installed"

  section "Phase 2: Creating Gateway infrastructure"
  terraform apply -auto-approve \
    -target=kubernetes_service.gateway_nodeports_http \
    -target=kubernetes_manifest.vault_httproute
  ok "Gateway infrastructure created"

  # Wait for Vault to be reachable via Gateway before Phase 3
  section "Waiting for Vault to be reachable"
  RETRIES=30
  SLEEP=5
  VAULT_READY=false
  for ((i=1; i<=RETRIES; i++)); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/v1/sys/health || echo "000")
    if [[ "$HTTP_CODE" =~ ^(200|429|472|473|501|503)$ ]]; then
      ok "Vault is reachable (HTTP $HTTP_CODE)"
      VAULT_READY=true
      break
    fi
    waiting "Attempt $i/$RETRIES: not reachable yet (HTTP $HTTP_CODE)..."
    sleep $SLEEP
  done

  if [ "$VAULT_READY" = false ]; then
    err "Vault is not reachable via Gateway. Cannot proceed with Terraform."
    exit 1
  fi

  section "Importing existing Vault state"
  if ! terraform state list | grep -q "vault_mount.kvv2"; then
    info "Importing existing 'secret' mount (Vault Dev Mode pre-creates it)..."
    terraform import vault_mount.kvv2 secret || true
  else
    info "Secret mount already in state — skipping import."
  fi

  section "Phase 3: Full Terraform apply"
  terraform apply -auto-approve
  ok "Terraform complete"

fi

# Verification
section "Verifying secrets"
waiting "Waiting for Vault Secrets Operator to sync..."

RETRIES=10
SLEEP=5
FOUND=false

for ((i=1; i<=RETRIES; i++)); do
  if kubectl get secret k8s-secret-from-vault >/dev/null 2>&1 && kubectl get secret flask-app-tls >/dev/null 2>&1; then
    FOUND=true
    break
  fi
  waiting "Attempt $i/$RETRIES: secrets not found yet..."
  sleep $SLEEP
done

if [ "$FOUND" = true ]; then
  ok "Secrets found: k8s-secret-from-vault, flask-app-tls"
  echo ""
  echo -e "    username: $(kubectl get secret k8s-secret-from-vault -o jsonpath='{.data.username}' | base64 --decode)"
  echo -e "    password: $(kubectl get secret k8s-secret-from-vault -o jsonpath='{.data.password}' | base64 --decode)"
else
  err "Secret was not synced within the expected time."
  echo "Checking VaultStaticSecret status:"
  kubectl get vaultstaticsecret example-secret -o yaml
  exit 1
fi

if [ "$REDEPLOY_ONLY" == "true" ]; then
  section "Redeploying Flask App"
  terraform apply -auto-approve -target=null_resource.flask_image -target=helm_release.flask_app
  info "Restarting deployment to pick up new image..."
  kubectl rollout restart deployment/flask-app
  waiting "Waiting for rollout to complete..."
  kubectl rollout status deployment/flask-app
  ok "Flask App redeployed"
fi

section "Verifying Flask App"
waiting "Waiting for deployment to be available..."
kubectl wait --for=condition=available --timeout=60s deployment/flask-app

waiting "Probing /secret endpoint via HTTP..."
RETRIES=20
SLEEP=3
SUCCESS=false

for ((i=1; i<=RETRIES; i++)); do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/secret)
  if [ "$HTTP_CODE" == "200" ]; then
    SUCCESS=true
    break
  fi
  waiting "Attempt $i/$RETRIES: HTTP $HTTP_CODE — waiting for Gateway route..."
  sleep $SLEEP
done

if [ "$SUCCESS" = true ]; then
  ok "HTTP endpoint is up"
  echo ""
  curl -s http://localhost:8080/secret | jq
  echo ""
  info "HTTPS response:"
  curl -sk https://localhost:8443/secret | jq
else
  err "Failed to reach /secret endpoint via Gateway."
  curl -v http://localhost:8080/secret
  echo "Checking Gateway status:"
  kubectl get gateway eg -n default -o yaml
  exit 1
fi

# Final summary
echo ""
hr
echo -e "${BOLD}${GREEN}  Setup complete!${NC}"
hr
echo ""
echo -e "  ${BOLD}Cluster:${NC}    kubectl --context kind-${CLUSTER_NAME}"
echo -e "  ${BOLD}Vault UI:${NC}   http://localhost:8080/ui/  (token: root)"
echo -e "  ${BOLD}Flask App:${NC}  http://localhost:8080/secret"
echo -e "              https://localhost:8443/secret"
echo ""
hr
echo -e "  ${BOLD}Common operations${NC}"
hr
echo ""
echo -e "  ${CYAN}Update a Vault secret:${NC}"
echo -e "    kubectl exec -it vault-0 -- vault kv put secret/example username=newuser password=newpass"
echo -e "    (VSO syncs within ~10s — check http://localhost:8080/secret)"
echo ""
echo -e "  ${CYAN}Check synced certificate status:${NC}"
echo -e "    kubectl describe VaultPKISecret flask-app-cert"
echo ""
echo -e "  ${CYAN}View TLS certificate serial from Gateway:${NC}"
echo -e "    echo | openssl s_client -showcerts -connect 127.0.0.1:8443 2>/dev/null | openssl x509 -noout -serial"
echo ""
echo -e "  ${CYAN}Force TLS cert rotation:${NC}"
echo -e "    kubectl delete secret flask-app-tls"
echo -e "    kubectl get secret flask-app-tls  # verify recreation"
echo ""
hr
echo -e "  ${BOLD}Troubleshooting${NC}"
hr
echo ""
echo -e "    kubectl get vaultstaticsecret example-secret -o yaml"
echo -e "    kubectl get vaultpkisecret flask-app-cert -o yaml"
echo -e "    kubectl get gateway eg -n default -o yaml"
echo -e "    kubectl logs -n envoy-gateway-system -l control-plane=envoy-gateway"
echo ""
echo -e "  ${YELLOW}Note:${NC} VaultStaticSecret may show 'RolloutRestartTriggeredFailed' initially — typically harmless."
echo ""
