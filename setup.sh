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
kind create cluster --name "${CLUSTER_NAME}"

# 3. Install Vault and VSO
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

# 4. Port Forwarding
echo -e "${BLUE}Setting up port forwarding to Vault...${NC}"
# Kill any existing port forward on 8200 just in case
lsof -ti:8200 | xargs kill -9 2>/dev/null || true

kubectl port-forward svc/vault 8200:8200 >/dev/null 2>&1 &
PF_PID=$!
echo "Port forward PID: ${PF_PID}"

# Ensure we kill the port forward when the script exits
trap "kill ${PF_PID}" EXIT

echo "Waiting for port forwarding to be ready..."
sleep 5

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

echo -e "${GREEN}Setup complete!${NC}"
echo "You can interact with the cluster using: kubectl --context kind-${CLUSTER_NAME}"
echo "Vault is available at http://localhost:8200 (Token: root)"
