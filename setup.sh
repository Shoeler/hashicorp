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

  # 2.5 Install Container Registry
  echo -e "${GREEN}Installing Container Registry...${NC}"
  helm repo add twuni https://helm.twun.io
  helm repo update

  # Install docker-registry using Helm
  # NodePort 30500 mapped to host 5001 (via kind-config)
  helm install registry twuni/docker-registry \
    --version 2.2.1 \
    --set service.type=NodePort \
    --set service.nodePort=30500 \
    --set service.port=5000 \
    --set persistence.enabled=false \
    --wait

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

  # Create EnvoyProxy config (to set LoadBalancer type)
  # We use LoadBalancer to ensure Envoy is configured with standard external-facing ports,
  # but we will create a separate stable NodePort service for local access to avoid
  # port fluctuation during reconciliation.
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

  # Dynamically determine targetPorts from the managed service
  # This ensures we map to the correct container ports (e.g. 10080 vs 80)
  HTTP_TARGET=$(kubectl get svc "$EG_SVC" -n envoy-gateway-system -o jsonpath='{.spec.ports[?(@.name=="http")].targetPort}')
  [ -z "$HTTP_TARGET" ] && HTTP_TARGET=$(kubectl get svc "$EG_SVC" -n envoy-gateway-system -o jsonpath='{.spec.ports[?(@.port==80)].targetPort}')
  [ -z "$HTTP_TARGET" ] && HTTP_TARGET=80 # Fallback

  # For HTTPS, it might not be present yet if listener is not added, but standard is often 443 or 10443.
  # If the service doesn't have it, we default to https named port if possible, or try 443.
  HTTPS_TARGET=$(kubectl get svc "$EG_SVC" -n envoy-gateway-system -o jsonpath='{.spec.ports[?(@.name=="https")].targetPort}' 2>/dev/null)
  [ -z "$HTTPS_TARGET" ] && HTTPS_TARGET=$(kubectl get svc "$EG_SVC" -n envoy-gateway-system -o jsonpath='{.spec.ports[?(@.port==443)].targetPort}' 2>/dev/null)
  [ -z "$HTTPS_TARGET" ] && HTTPS_TARGET=443 # Fallback

  echo "Detected TargetPorts - HTTP: $HTTP_TARGET, HTTPS: $HTTPS_TARGET"

  # Create a stable NodePort Service for access
  echo -e "${GREEN}Creating stable NodePort Service for Gateway...${NC}"
  cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: gateway-nodeports
  namespace: envoy-gateway-system
spec:
  type: NodePort
  selector:
    gateway.envoyproxy.io/owning-gateway-name: eg
    gateway.envoyproxy.io/owning-gateway-namespace: default
  ports:
  - name: http
    port: 80
    targetPort: $HTTP_TARGET
    nodePort: 30080
    protocol: TCP
  - name: https
    port: 443
    targetPort: $HTTPS_TARGET
    nodePort: 30443
    protocol: TCP
EOF

  # Wait for Envoy Proxy Data Plane to be ready BEFORE installing Vault/Terraform
  # This prevents "Connection Reset" errors when Terraform tries to talk to Vault via Gateway.
  echo "Waiting for Envoy Proxy Deployment to be available..."
  kubectl wait --namespace envoy-gateway-system \
    --for=condition=available deployment \
    -l gateway.envoyproxy.io/owning-gateway-name=eg \
    --timeout=120s

  # Ensure the NodePort service endpoints are populated
  echo "Waiting for Gateway NodePort endpoints..."
  # We just sleep a bit to allow endpoints to propagate, a more robust check would be waiting for endpoints
  sleep 5

  # Create HTTPRoute for Vault
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
  # Build and push to local registry
  podman build -t localhost:5001/flask-app:latest ./flask-app
  podman push localhost:5001/flask-app:latest --tls-verify=false

  echo -e "${GREEN}Deploying Flask App Helm Chart...${NC}"
  # We don't wait here because the secret doesn't exist yet, so it might not be ready
  # Use the registry internal DNS name (registry-docker-registry) and port 5000
  helm upgrade --install flask-app ./flask-app/chart \
    --set image.repository=registry-docker-registry.default.svc.cluster.local:5000/flask-app \
    --set image.pullPolicy=Always

  # 6. Run Terraform
  echo -e "${GREEN}Initializing Terraform...${NC}"
  terraform init

  # Wait for Vault to be reachable via Gateway before applying Terraform
  echo -e "${BLUE}Waiting for Vault to be reachable via Gateway...${NC}"
  RETRIES=30
  SLEEP=5
  VAULT_READY=false
  for ((i=1; i<=RETRIES; i++)); do
    # Check Vault health or just root path. 503/500 is fine (means reachable), connection reset/refused is not.
    # We use -o /dev/null -w "%{http_code}" to check status.
    # Vault unseal status check: /v1/sys/health
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:80/v1/sys/health || echo "000")

    # 200 = initialized, unsealed, active
    # 429 = standby
    # 472 = disaster recovery mode
    # 473 = performance standby
    # 501 = not initialized
    # 503 = sealed
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

  echo -e "${GREEN}Updating Gateway to include HTTPS listener...${NC}"
  # We apply the update instead of delete/recreate to minimize downtime, but we must ensure the data plane updates.
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

  # Wait for the Envoy Proxy Deployment to be ready (Data Plane)
  echo "Waiting for Envoy Proxy Deployment to be ready..."
  # The deployment name typically matches the service name found via label
  # But we can find it by label directly.
  kubectl wait --namespace envoy-gateway-system \
    --for=condition=available deployment \
    -l gateway.envoyproxy.io/owning-gateway-name=eg \
    --timeout=120s

  EG_SVC=$(kubectl get svc -l gateway.envoyproxy.io/owning-gateway-name=eg -o jsonpath='{.items[0].metadata.name}' -n envoy-gateway-system)
  echo "Envoy Service: $EG_SVC"

  # Wait for the managed Service to be updated with the HTTPS port by the Gateway Controller
  echo "Waiting for HTTPS port to appear on managed Envoy Service..."
  RETRIES=30
  SLEEP=2
  HTTPS_TARGET=""

  for ((i=1; i<=RETRIES; i++)); do
    HTTPS_TARGET=$(kubectl get svc "$EG_SVC" -n envoy-gateway-system -o jsonpath='{.spec.ports[?(@.name=="https")].targetPort}' 2>/dev/null)
    [ -z "$HTTPS_TARGET" ] && HTTPS_TARGET=$(kubectl get svc "$EG_SVC" -n envoy-gateway-system -o jsonpath='{.spec.ports[?(@.port==443)].targetPort}' 2>/dev/null)

    if [ -n "$HTTPS_TARGET" ]; then
      echo "Found HTTPS TargetPort: $HTTPS_TARGET"
      break
    fi
    echo "Attempt $i/$RETRIES: HTTPS port not ready on managed service..."
    sleep $SLEEP
  done

  # Fallback only if absolutely necessary, but warn
  if [ -z "$HTTPS_TARGET" ]; then
    echo "Warning: Could not detect HTTPS target port. Defaulting to 443."
    HTTPS_TARGET=443
  fi

  if [ -n "$HTTPS_TARGET" ]; then
    echo "Updating stable NodePort Service with HTTPS target port: $HTTPS_TARGET"
    # We re-apply the service with the detected target port
    cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Service
metadata:
  name: gateway-nodeports
  namespace: envoy-gateway-system
spec:
  type: NodePort
  selector:
    gateway.envoyproxy.io/owning-gateway-name: eg
    gateway.envoyproxy.io/owning-gateway-namespace: default
  ports:
  - name: http
    port: 80
    targetPort: $HTTP_TARGET
    nodePort: 30080
    protocol: TCP
  - name: https
    port: 443
    targetPort: $HTTPS_TARGET
    nodePort: 30443
    protocol: TCP
EOF
  fi
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
    podman build -t localhost:5001/flask-app:latest ./flask-app
    podman push localhost:5001/flask-app:latest --tls-verify=false

    echo -e "${GREEN}Deploying Flask App Helm Chart...${NC}"
    helm upgrade --install flask-app ./flask-app/chart \
      --set image.repository=registry-docker-registry.default.svc.cluster.local:5000/flask-app \
      --set image.pullPolicy=Always

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
curl -v -sk https://localhost/secret | jq
else
  echo -e "\033[0;31mError: Failed to reach /secret endpoint via Gateway.\033[0m"
  curl -v http://localhost/secret

  echo "Checking Gateway Status:"
  kubectl get gateway eg -n default -o yaml
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
