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

# 7. Build and Deploy Flask App
echo -e "${GREEN}Building and deploying Flask App...${NC}"
docker build -t flask-app:latest ./flask-app
kind load docker-image flask-app:latest --name "${CLUSTER_NAME}"

echo -e "${GREEN}Installing Flask App Helm Chart...${NC}"
helm install flask-app ./flask-app/chart

echo -e "${BLUE}Waiting for Flask App to be ready...${NC}"
kubectl wait --for=condition=available --timeout=60s deployment/flask-app

echo -e "${GREEN}Verifying Flask App...${NC}"
# Port forward to the flask app service
kubectl port-forward svc/flask-app 8080:80 >/dev/null 2>&1 &
FLASK_PID=$!
echo "Flask App Port forward PID: ${FLASK_PID}"
sleep 2

echo "Calling /secret endpoint..."
curl -s http://localhost:8080/secret | python3 -m json.tool

echo -e "${GREEN}Setup complete!${NC}"
echo "Flask app port forward is running with PID: ${FLASK_PID}"
echo "To stop it, run: kill ${FLASK_PID}"
echo "You can interact with the cluster using: kubectl --context kind-${CLUSTER_NAME}"
echo "Vault is available at http://localhost:8200 (Token: root)"

echo ""
echo "To explore and modify secrets in Vault:"
echo "1. Exec into the Vault pod:"
echo "   kubectl exec -it vault-0 -- /bin/sh"
echo ""
echo "2. Inside the pod, update the secret (e.g., change username/password):"
echo "   vault kv put secret/example username=newuser password=newpass"
echo ""
echo "   (Wait up to 60s for VSO to sync, then check http://localhost:8080/secret again)"
