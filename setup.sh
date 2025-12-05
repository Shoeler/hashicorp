#!/bin/bash
set -e

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}Starting Vault with Kind setup...${NC}"

# 1. Prerequisite Checks
command -v kind >/dev/null 2>&1 || { echo >&2 "kind is required but not installed. Aborting."; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo >&2 "kubectl is required but not installed. Aborting."; exit 1; }
command -v helm >/dev/null 2>&1 || { echo >&2 "helm is required but not installed. Aborting."; exit 1; }
command -v terraform >/dev/null 2>&1 || { echo >&2 "terraform is required but not installed. Aborting."; exit 1; }

# 2. Create Kind Cluster
CLUSTER_NAME="vault-demo"
if kind get clusters | grep -q "^${CLUSTER_NAME}$"; then
  echo -e "${BLUE}Cluster ${CLUSTER_NAME} already exists. Deleting it to start fresh...${NC}"
  kind delete cluster --name "${CLUSTER_NAME}"
fi

echo -e "${GREEN}Creating Kind cluster: ${CLUSTER_NAME}...${NC}"
kind create cluster --name "${CLUSTER_NAME}" --config kind-config.yaml

# 3. Install Envoy Gateway
echo -e "${GREEN}Installing Gateway API CRDs and Envoy Gateway...${NC}"

# Prompt for Helm login
echo -e "${BLUE}Please login to docker.io registry to pull Helm charts.${NC}"
helm registry login registry-1.docker.io

# Use podman to build/load images
# Note: Helm OCI authentication might fail with default docker creds if docker desktop is not present.
# Setting registry config to /dev/null avoids reading bad user config.
export HELM_REGISTRY_CONFIG=/dev/null
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
# Loop to find the service in any namespace (it should be in default, but we check -A to be safe and robust)
# We also wait for it to be created.
FOUND=false
for i in {1..30}; do
  SVC_INFO=$(kubectl get svc -A -l gateway.envoyproxy.io/owning-gateway-name=eg -o jsonpath='{.items[0].metadata.namespace}/{.items[0].metadata.name}' 2>/dev/null || true)
  if [ -n "$SVC_INFO" ]; then
    EG_NS=$(echo "$SVC_INFO" | cut -d'/' -f1)
    EG_SVC=$(echo "$SVC_INFO" | cut -d'/' -f2)
    echo "Found Envoy Service: $EG_SVC in namespace: $EG_NS"
    FOUND=true
    break
  fi
  echo "Waiting for Envoy Service..."
  sleep 2
done

if [ "$FOUND" = false ]; then
  echo -e "\033[0;31mError: Envoy Proxy Service not found after waiting.\033[0m"
  kubectl get svc -A
  exit 1
fi

echo "Patching Envoy Service $EG_SVC to NodePort 30080..."
kubectl patch svc -n "$EG_NS" "$EG_SVC" --type='json' -p='[{"op": "replace", "path": "/spec/type", "value": "NodePort"}, {"op": "replace", "path": "/spec/ports/0/nodePort", "value": 30080}]'

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

# 6. Verification
echo -e "${BLUE}Verifying setup...${NC}"
echo "Waiting for Vault Secrets Operator to sync the secret..."

# Loop to check for the secret
RETRIES=10
SLEEP=5
FOUND=false

for ((i=1; i<=RETRIES; i++)); do
  if kubectl get secret k8s-secret-from-vault >/dev/null 2>&1; then
    FOUND=true
    break
  fi
  echo "Attempt $i/$RETRIES: Secret not found yet..."
  sleep $SLEEP
done

if [ "$FOUND" = true ]; then
  echo -e "${GREEN}Success! Secret 'k8s-secret-from-vault' found.${NC}"
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
# Save image to archive for loading into Kind (compatible with Podman)
podman save -o flask-app.tar flask-app:latest
kind load image-archive flask-app.tar --name "${CLUSTER_NAME}"
rm flask-app.tar

echo -e "${GREEN}Installing Flask App Helm Chart...${NC}"
helm install flask-app ./flask-app/chart

echo -e "${BLUE}Waiting for Flask App to be ready...${NC}"
kubectl wait --for=condition=available --timeout=60s deployment/flask-app

echo -e "${GREEN}Verifying Flask App...${NC}"
echo "Calling /secret endpoint..."
# We can access via localhost/secret now
curl -s http://localhost/secret | python3 -m json.tool

echo -e "${GREEN}Setup complete!${NC}"
echo "You can interact with the cluster using: kubectl --context kind-${CLUSTER_NAME}"
echo "Vault UI is available at http://localhost/ui/ (Token: root)"
echo "Flask App is available at http://localhost/secret"

echo ""
echo "To explore and modify secrets in Vault:"
echo "1. Exec into the Vault pod:"
echo "   kubectl exec -it vault-0 -- /bin/sh"
echo ""
echo "2. Inside the pod, update the secret (e.g., change username/password):"
echo "   vault kv put secret/example username=newuser password=newpass"
echo ""
echo "   (Wait up to 10s for VSO to sync, then check http://localhost/secret again)"
