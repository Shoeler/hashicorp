#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

CLUSTER_NAME="vault-demo"
REDEPLOY_ONLY=false

# Check for redeploy flag
if [ "$1" == "--redeploy-flask" ]; then
  REDEPLOY_ONLY=true
  echo -e "${BLUE}Redeploying Flask App only...${NC}"
fi

echo -e "${BLUE}Starting Setup...${NC}"

# 1. Prerequisite Checks
command -v kind >/dev/null 2>&1 || { echo >&2 "kind is required but not installed. Aborting."; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo >&2 "kubectl is required but not installed. Aborting."; exit 1; }
command -v helm >/dev/null 2>&1 || { echo >&2 "helm is required but not installed. Aborting."; exit 1; }
command -v terraform >/dev/null 2>&1 || { echo >&2 "terraform is required but not installed. Aborting."; exit 1; }

# Check for Podman and configure Kind to use it
if command -v podman >/dev/null 2>&1; then
  echo -e "${BLUE}Podman detected. Configuring Kind to use podman...${NC}"
  export KIND_EXPERIMENTAL_PROVIDER=podman
else
  command -v docker >/dev/null 2>&1 || { echo >&2 "neither podman nor docker found. Aborting."; exit 1; }
fi

if [ "$REDEPLOY_ONLY" == "false" ]; then
  # 2. Create Kind Cluster
  if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    echo -e "${BLUE}Cluster ${CLUSTER_NAME} already exists. Deleting it to start fresh...${NC}"
    kind delete cluster --name "${CLUSTER_NAME}"
  fi

  echo -e "${GREEN}Creating Kind cluster: ${CLUSTER_NAME}...${NC}"

  # Create registry config for containerd (must exist before kind create cluster mounts it)
  echo -e "${GREEN}Generating registry configuration...${NC}"
  rm -rf registry-config
  mkdir -p registry-config/registry-docker-registry.default.svc.cluster.local:5000
  cat <<EOF > registry-config/registry-docker-registry.default.svc.cluster.local:5000/hosts.toml
server = "http://registry-docker-registry.default.svc.cluster.local:5000"

[host."http://127.0.0.1:30500"]
  capabilities = ["pull", "resolve"]
EOF

  kind create cluster --name "${CLUSTER_NAME}" --config kind-config.yaml

  # 3. Initialize and run Terraform in three phases to handle provider bootstrap ordering:
  #
  #   Phase 1 — Helm releases only (installs CRDs; vault provider not invoked)
  #   Phase 2 — Gateway k8s resources only (makes Vault accessible via NodePort)
  #   Phase 3 — Full apply (vault provider can now connect)
  #
  # This ordering is required because the vault Terraform provider must connect to
  # Vault at startup, and Vault is only reachable after the Gateway NodePort service
  # is created (Phase 2).

  echo -e "${GREEN}Initializing Terraform...${NC}"
  terraform init

  echo -e "${GREEN}Phase 1: Installing Helm releases (registry, envoy gateway, vault, VSO)...${NC}"
  terraform apply -auto-approve \
    -target=helm_release.registry \
    -target=helm_release.envoy_gateway \
    -target=helm_release.vault \
    -target=helm_release.vault_secrets_operator

  echo -e "${GREEN}Phase 2: Creating Gateway infrastructure (makes Vault accessible)...${NC}"
  # -target automatically pulls in dependencies:
  #   gateway_nodeports_http → data.external.envoy_http_port → kubernetes_manifest.gateway
  #   → kubernetes_manifest.gateway_class → kubernetes_manifest.envoy_proxy_config
  terraform apply -auto-approve \
    -target=kubernetes_manifest.gateway_nodeports_http \
    -target=kubernetes_manifest.vault_httproute

  # Wait for Vault to be reachable via Gateway before Phase 3
  echo -e "${BLUE}Waiting for Vault to be reachable via Gateway...${NC}"
  RETRIES=30
  SLEEP=5
  VAULT_READY=false
  for ((i=1; i<=RETRIES; i++)); do
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/v1/sys/health || echo "000")
    if [[ "$HTTP_CODE" =~ ^(200|429|472|473|501|503)$ ]]; then
      echo "Vault is reachable (HTTP $HTTP_CODE)."
      VAULT_READY=true
      break
    fi
    echo "Attempt $i/$RETRIES: Vault not reachable (HTTP $HTTP_CODE)..."
    sleep $SLEEP
  done

  if [ "$VAULT_READY" = false ]; then
    echo -e "\033[0;31mError: Vault is not reachable via Gateway. Cannot proceed with Terraform.\033[0m"
    exit 1
  fi

  # Import the 'secret' mount if it exists (Vault Dev Mode pre-creates it)
  echo -e "${BLUE}Checking for existing secret mount...${NC}"
  if ! terraform state list | grep -q "vault_mount.kvv2"; then
    echo "Importing existing secret mount..."
    terraform import vault_mount.kvv2 secret || true
  fi

  echo -e "${GREEN}Phase 3: Applying full Terraform configuration...${NC}"
  terraform apply -auto-approve
fi

# Verification
echo -e "${BLUE}Verifying setup...${NC}"
echo "Waiting for Vault Secrets Operator to sync the secret..."

RETRIES=10
SLEEP=5
FOUND=false

for ((i=1; i<=RETRIES; i++)); do
  if kubectl get secret k8s-secret-from-vault >/dev/null 2>&1 && kubectl get secret flask-app-tls >/dev/null 2>&1; then
    FOUND=true
    break
  fi
  echo "Attempt $i/$RETRIES: Secrets not found yet..."
  sleep $SLEEP
done

if [ "$FOUND" = true ]; then
  echo -e "${GREEN}Success! Secrets 'k8s-secret-from-vault' and 'flask-app-tls' found.${NC}"
  echo "Content:"
  kubectl get secret k8s-secret-from-vault -o jsonpath='{.data.username}' | base64 --decode
  echo ""
  kubectl get secret k8s-secret-from-vault -o jsonpath='{.data.password}' | base64 --decode
  echo ""
else
  echo -e "\033[0;31mError: Secret was not synced within the expected time.\033[0m"
  echo "Checking VaultStaticSecret status:"
  kubectl get vaultstaticsecret example-secret -o yaml
  exit 1
fi

if [ "$REDEPLOY_ONLY" == "true" ]; then
  echo -e "${GREEN}Redeploying Flask App via Terraform...${NC}"
  terraform apply -auto-approve -target=null_resource.flask_image -target=helm_release.flask_app

  echo "Restarting deployment to pick up new image..."
  kubectl rollout restart deployment/flask-app
  echo -e "${BLUE}Waiting for rollout to complete...${NC}"
  kubectl rollout status deployment/flask-app
fi

echo -e "${BLUE}Waiting for Flask App to be ready...${NC}"
kubectl wait --for=condition=available --timeout=60s deployment/flask-app

echo -e "${GREEN}Verifying Flask App...${NC}"
echo "Calling /secret endpoint via HTTP..."

RETRIES=20
SLEEP=3
SUCCESS=false

for ((i=1; i<=RETRIES; i++)); do
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/secret)
  if [ "$HTTP_CODE" == "200" ]; then
    SUCCESS=true
    break
  fi
  echo "Attempt $i/$RETRIES: Got HTTP $HTTP_CODE. Waiting for Gateway route..."
  sleep $SLEEP
done

if [ "$SUCCESS" = true ]; then
  curl -s http://localhost:8080/secret | jq

  echo "Calling https://localhost/secret endpoint via HTTPS..."
  curl -v -sk https://localhost:8443/secret | jq
else
  echo -e "\033[0;31mError: Failed to reach /secret endpoint via Gateway.\033[0m"
  curl -v http://localhost:8080/secret

  echo "Checking Gateway Status:"
  kubectl get gateway eg -n default -o yaml
  exit 1
fi

echo -e "${GREEN}Setup complete!${NC}"
echo "You can interact with the cluster using: kubectl --context kind-${CLUSTER_NAME}"
echo "Vault UI is available at http://localhost:8080/ui/ (Token: root)"
echo "Flask App is available at http://localhost:8080/secret or https://localhost:8443/secret"

echo ""
echo "To explore and modify secrets in Vault:"
echo "1. Exec into the Vault pod:"
echo "   kubectl exec -it vault-0 -- /bin/sh"
echo ""
echo "2. Inside the pod, update the secret (e.g., change username/password):"
echo "   vault kv put secret/example username=newuser password=newpass"
echo ""
echo "   (Wait up to 10s for VSO to sync, then check http://localhost:8080/secret again)"
echo ""
echo "To see the status of the synced k8s certificate:"
echo "    kubectl describe VaultPKISecret flask-app-cert"

echo ""
echo "To see the serial number of the issued certificate presented by the Gateway:"
echo "    echo | openssl s_client -showcerts -connect 127.0.0.1:8443 2>/dev/null | openssl x509 -noout -serial"

echo ""
echo "To force a rotation of the TLS cert on the Gateway:"
echo "    kubectl delete secret flask-app-tls"
echo "    # Verify that the secret has been recreated:"
echo "    kubectl get secret flask-app-tls"

echo ""
echo "Troubleshooting:"
echo "If verification fails, check the status of the Vault resources:"
echo "    kubectl get vaultstaticsecret example-secret -o yaml"
echo "    kubectl get vaultpkisecret flask-app-cert -o yaml"
echo ""
echo "If the HTTPS gateway is not reachable, check the Gateway status:"
echo "    kubectl get gateway eg -n default -o yaml"
echo "    kubectl logs -n envoy-gateway-system -l control-plane=envoy-gateway"
echo ""
echo "Note: 'VaultStaticSecret' may show a 'RolloutRestartTriggeredFailed' error initially if the deployment was not ready. This is typically harmless."
