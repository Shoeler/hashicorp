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

  # Create EnvoyProxy config for static NodePorts
  echo -e "${GREEN}Creating EnvoyProxy configuration...${NC}"
  cat <<EOF | kubectl apply -f -
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: static-nodeport-config
  namespace: envoy-gateway-system
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        type: LoadBalancer
        ports:
        - name: https
          port: 443
          protocol: TCP
          servicePort: 443
          nodePort: 30443
        - name: http
          port: 80
          protocol: TCP
          servicePort: 80
          nodePort: 30080
EOF

  # Create Gateway Class and Gateway
  echo -e "${GREEN}Creating Gateway resource...${NC}"
  cat <<EOF | kubectl apply -f -
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
  parametersRef:
    group: gateway.envoyproxy.io
    kind: EnvoyProxy
    name: static-nodeport-config
    namespace: envoy-gateway-system
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
  sleep 10
  EG_SVC=$(kubectl get svc -l gateway.envoyproxy.io/owning-gateway-name=eg -o jsonpath='{.items[0].metadata.name}' -n envoy-gateway-system)

  echo "Envoy Service Created: $EG_SVC"

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

  # 5. Build and Deploy Flask App (Install first so Deployment exists for VSO)
  echo -e "${GREEN}Building and deploying Flask App (Pre-Terraform)...${NC}"
  podman build -t flask-app:latest ./flask-app
  kind load docker-image flask-app:latest --name "${CLUSTER_NAME}"
  # This has to run twice because it doesn't tag it properly the first time
  kind load docker-image flask-app:latest --name "${CLUSTER_NAME}"

  echo -e "${GREEN}Deploying Flask App Helm Chart...${NC}"
  # We don't wait here because the secret doesn't exist yet, so it might not be ready
  helm upgrade --install flask-app ./flask-app/chart

  # 6. Run Terraform
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

  # 6.5. Enable HTTPS on Gateway
  # Now that Terraform has run, the flask-app-tls secret should exist (or be creating).
  # We can now add the HTTPS listener to the Gateway.
  # To ensure the EnvoyProxy configuration (specifically NodePort 30443) is picked up correctly,
  # we recreate the Gateway with both listeners defined.

  echo -e "${GREEN}Recreating Gateway to include HTTPS listener...${NC}"
  kubectl delete gateway eg -n default

  cat <<EOF | kubectl apply -f -
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
  - name: https
    protocol: HTTPS
    port: 443
    tls:
      mode: Terminate
      certificateRefs:
      - name: flask-app-tls
EOF

  # Wait for the Envoy Proxy Service to be recreated/updated
  echo "Waiting for Envoy Proxy Service..."
  sleep 10
  EG_SVC=$(kubectl get svc -l gateway.envoyproxy.io/owning-gateway-name=eg -o jsonpath='{.items[0].metadata.name}' -n envoy-gateway-system)
  echo "Envoy Service: $EG_SVC"
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

if [ "$REDEPLOY_ONLY" == "true" ]; then
    echo -e "${GREEN}Building and deploying Flask App...${NC}"
    podman build -t flask-app:latest ./flask-app
    kind load docker-image flask-app:latest --name "${CLUSTER_NAME}"
    kind load docker-image flask-app:latest --name "${CLUSTER_NAME}"

    echo -e "${GREEN}Deploying Flask App Helm Chart...${NC}"
    helm upgrade --install flask-app ./flask-app/chart

    echo "Restarting deployment to pick up new image..."
    kubectl rollout restart deployment/flask-app
    echo -e "${BLUE}Waiting for rollout to complete...${NC}"
    kubectl rollout status deployment/flask-app
fi

echo -e "${BLUE}Waiting for Flask App to be ready...${NC}"
kubectl wait --for=condition=available --timeout=60s deployment/flask-app

echo -e "${GREEN}Verifying Flask App...${NC}"
echo "Calling /secret endpoint via HTTP..."

# Wait for the app to be reachable via Gateway
RETRIES=20
SLEEP=3
SUCCESS=false

for ((i=1; i<=RETRIES; i++)); do
  # Check if endpoint returns 200 OK
  HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost/secret)
  if [ "$HTTP_CODE" == "200" ]; then
    SUCCESS=true
    break
  fi
  echo "Attempt $i/$RETRIES: Got HTTP $HTTP_CODE. Waiting for Gateway route..."
  sleep $SLEEP
done

if [ "$SUCCESS" = true ]; then
  # We can access via localhost/secret now
  curl -s http://localhost/secret | jq

  echo "Calling https://localhost/secret endpoint via HTTPS..."
  curl -sk https://localhost/secret | jq
else
  echo -e "\033[0;31mError: Failed to reach /secret endpoint via Gateway.\033[0m"
  curl -v http://localhost/secret
  exit 1
fi

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

echo ""
echo "To see the serial number of the issued certificate presented by the Gateway:"
echo "    echo | openssl s_client -showcerts -connect 127.0.0.1:443 2>/dev/null | openssl x509 -noout -serial"

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
