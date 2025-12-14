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

if [ "$REDEPLOY_ONLY" == "false" ]; then
  # 2. Create Kind Cluster
  if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
    echo -e "${BLUE}Cluster ${CLUSTER_NAME} already exists. Deleting it to start fresh...${NC}"
    kind delete cluster --name "${CLUSTER_NAME}"
  fi

  echo -e "${GREEN}Creating Kind cluster: ${CLUSTER_NAME}...${NC}"
  kind create cluster --name "${CLUSTER_NAME}" --config kind-config.yaml

  # 3. Install Envoy Gateway
  echo -e "${GREEN}Installing Gateway API CRDs and Envoy Gateway...${NC}"
  # Use podman to build/load images
  # Note: Helm OCI authentication might fail with default docker creds if docker desktop is not present.
  # Setting registry config to /dev/null avoids reading bad user config.
  # export HELM_REGISTRY_CONFIG=/dev/null # This did not work
  helm install eg oci://docker.io/envoyproxy/gateway-helm \
    --version v1.2.0 \
    -n envoy-gateway-system \
    --create-namespace \
    --wait

  echo "Waiting for Envoy Gateway to be ready..."
  kubectl wait --namespace envoy-gateway-system \
    --for=condition=available deployment/envoy-gateway \
    --timeout=90s

  # Create Gateway Class and Gateway
  echo -e "${GREEN}Creating Gateway resource...${NC}"
  cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: eg
  namespace: default
spec:
  gatewayClassName: eg
  listeners:
  - name: http
    protocol: HTTP
    port: 80
EOF

  # Wait for the Envoy Proxy Service to be created by the Gateway
  echo "Waiting for Envoy Proxy Service..."
  # The service name is usually generated based on the Gateway name.
  # For Envoy Gateway, it follows a pattern like envoy-<gateway-name>-<random> or similar,
  # but usually it's deterministic or we can find it via label selector.
  sleep 10
  EG_SVC=$(kubectl get svc -l gateway.envoyproxy.io/owning-gateway-name=eg -o jsonpath='{.items[0].metadata.name}' -n envoy-gateway-system)

  echo "Patching Envoy Service $EG_SVC to NodePort 30080..."
  kubectl patch svc $EG_SVC --type='json' -p='[{"op": "replace", "path": "/spec/type", "value": "NodePort"}, {"op": "replace", "path": "/spec/ports/0/nodePort", "value": 30080}]' -n envoy-gateway-system

  # Create HTTPRoute for Vault
  echo -e "${GREEN}Creating HTTPRoute for Vault...${NC}"
  cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: vault
  namespace: default
spec:
  parentRefs:
  - name: eg
  rules:
  - backendRefs:
    - name: vault
      port: 8200
EOF

  # 4. Install Vault and VSO
  echo -e "${GREEN}Adding HashiCorp Helm repo...${NC}"
  helm repo add hashicorp https://helm.releases.hashicorp.com
  helm repo update

  echo -e "${GREEN}Installing Vault (Dev Mode)...${NC}"
  helm install vault hashicorp/vault \
    --set "server.dev.enabled=true" \
    --set "server.dev.devRootToken=root" \
    --wait

  echo -e "${GREEN}Installing Vault Secrets Operator...${NC}"
  helm install vault-secrets-operator hashicorp/vault-secrets-operator \
    --set "defaultVaultConnection.enabled=false" \
    --wait

  # 5. Run Terraform
  echo -e "${GREEN}Initializing Terraform...${NC}"
  terraform init

  # Import the 'secret' mount if it exists (Vault Dev Mode default)
  echo -e "${BLUE}Checking for existing secret mount...${NC}"
  if ! terraform state list | grep -q "vault_mount.kvv2"; then
    echo "Importing existing secret mount..."
    terraform import vault_mount.kvv2 secret || true
  fi

  echo -e "${GREEN}Applying Terraform configuration...${NC}"
  terraform apply -auto-approve

  # 5.5. Enable HTTPS on Gateway
  # Now that Terraform has run, the flask-app-tls secret should exist (or be creating).
  # We can now add the HTTPS listener to the Gateway.

  echo -e "${GREEN}Updating Gateway to include HTTPS listener...${NC}"
  kubectl patch gateway eg --type='json' -p='[
    {"op": "add", "path": "/spec/listeners/-", "value": {
      "name": "https",
      "protocol": "HTTPS",
      "port": 443,
      "tls": {
        "mode": "Terminate",
        "certificateRefs": [{"name": "flask-app-tls"}]
      }
    }}
  ]' -n default

  # Wait for the Envoy Proxy Service to be updated with port 443
  echo "Waiting for Envoy Proxy Service to add port 443..."
  RETRIES=30
  SLEEP=5
  FOUND_PORT=false

  EG_SVC=$(kubectl get svc -l gateway.envoyproxy.io/owning-gateway-name=eg -o jsonpath='{.items[0].metadata.name}' -n envoy-gateway-system)

  for ((i=1; i<=RETRIES; i++)); do
    HAS_443=$(kubectl get svc "$EG_SVC" -n envoy-gateway-system -o jsonpath='{.spec.ports[?(@.port==443)].port}' 2>/dev/null)

    if [ -n "$HAS_443" ]; then
      echo "Service $EG_SVC has port 443."
      FOUND_PORT=true
      break
    fi

    echo "Attempt $i/$RETRIES: Port 443 not ready yet..."
    sleep $SLEEP
  done

  if [ "$FOUND_PORT" = false ]; then
    echo "Error: Port 443 failed to appear on Envoy Service."
    exit 1
  fi

  echo "Patching Envoy Service $EG_SVC to NodePort 30443..."
  # Use strategic merge patch to update port 443 without affecting port 80
  kubectl patch svc $EG_SVC -p='{"spec": {"ports": [{"port": 443, "nodePort": 30443}]}}' -n envoy-gateway-system
fi

# 6. Verification
echo -e "${BLUE}Verifying setup...${NC}"
echo "Waiting for Vault Secrets Operator to sync the secret..."

# Loop to check for the secret
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
  # Debug info
  echo "Checking VaultStaticSecret status:"
  kubectl get vaultstaticsecret example-secret -o yaml
  exit 1
fi

# 7. Build and Deploy Flask App
echo -e "${GREEN}Building and deploying Flask App...${NC}"
podman build -t flask-app:latest ./flask-app
kind load docker-image flask-app:latest --name "${CLUSTER_NAME}"
# This has to run twice because it doesn't tag it properly the first time
kind load docker-image flask-app:latest --name "${CLUSTER_NAME}"
# The second load was duplicated in original file, removing it
# kind load docker-image flask-app:latest --name "${CLUSTER_NAME}"

echo -e "${GREEN}Deploying Flask App Helm Chart...${NC}"
helm upgrade --install flask-app ./flask-app/chart

if [ "$REDEPLOY_ONLY" == "true" ]; then
    echo "Restarting deployment to pick up new image..."
    kubectl rollout restart deployment/flask-app
    echo -e "${BLUE}Waiting for rollout to complete...${NC}"
    kubectl rollout status deployment/flask-app
fi

echo -e "${BLUE}Waiting for Flask App to be ready...${NC}"
kubectl wait --for=condition=available --timeout=60s deployment/flask-app

echo -e "${GREEN}Verifying Flask App...${NC}"
echo "Calling /secret endpoint via HTTP..."
# We can access via localhost/secret now
curl -s http://localhost/secret | jq

echo "Calling https://localhost/secret endpoint via HTTPS..."
curl -sk https://localhost/secret | jq

echo "Calling https://localhost/secret endpoint..."
curl -sk https://localhost/secret | jq

echo -e "${GREEN}Setup complete!${NC}"
echo "You can interact with the cluster using: kubectl --context kind-${CLUSTER_NAME}"
echo "Vault UI is available at http://localhost/ui/ (Token: root)"
echo "Flask App is available at http://localhost/secret or https://localhost/secret"

echo ""
echo "To explore and modify secrets in Vault:"
echo "1. Exec into the Vault pod:"
echo "   kubectl exec -it vault-0 -- /bin/sh"
echo ""
echo "2. Inside the pod, update the secret (e.g., change username/password):"
echo "   vault kv put secret/example username=newuser password=newpass"
echo ""
echo "   (Wait up to 10s for VSO to sync, then check http://localhost/secret again)"
echo ""
echo "To see the status of the synced k8s certificate:"
echo "    kubectl describe VaultPKISecret flask-app-cert"
