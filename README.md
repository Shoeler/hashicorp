# Vault with Kind and Vault Secrets Operator

This project sets up a local HashiCorp Vault instance and the Vault Secrets Operator (VSO) on a Kind Kubernetes cluster. Terraform manages all infrastructure — Helm releases, Gateway resources, Vault configuration, and VSO CRDs. Additionally, it uses Gateway API / Envoy to expose ports locally instead of having to use port-forward.

**This script will delete and reinstall the KIND cluster if one already exists, so be intentional about re-running it!**

## Prerequisites

I have built this to run on my local M-series MacBook - so YMMV.

Ensure you have the following tools preinstalled on your Mac:

*   [Homebrew](https://brew.sh/)
*   [Podman](https://podman.io) (`brew install podman && podman machine init && podman machine set --rootful && podman machine start`)
*   [Kind](https://kind.sigs.k8s.io/) (`brew install kind`)
*   [Kubectl](https://kubernetes.io/docs/tasks/tools/) (`brew install kubectl`)
*   [Helm](https://helm.sh/) (`brew install helm`)
*   [tfenv](https://github.com/tfutils/tfenv) (`brew install tfenv && tfenv install && tfenv use`) - optional but strongly suggested
*   [terraform](https://developer.hashicorp.com/terraform) - optional in case you don't want to use tfenv

## Quick Start

Run the setup script:

```bash
./setup.sh
```

## Quick re-deploy of the app-only

Run the setup script with --redeploy-flask:

```bash
./setup.sh --redeploy-flask
```

This script will:
1.  Create or recreate a Kind cluster named `vault-demo`.
2.  Run Terraform in three phases:
    - **Phase 1**: Install Helm releases (container registry, Envoy Gateway, Vault, VSO).
    - **Phase 2**: Create Gateway infrastructure — dynamically detects Envoy container ports (safe on macOS/Podman) and creates the HTTP NodePort service so Vault becomes accessible.
    - **Phase 3**: Full apply — configures Vault (KV, PKI, Kubernetes auth), deploys VSO CRDs, builds and pushes the Flask app image, and deploys the app.
3.  Verify that a sample secret is synced from Vault to a Kubernetes Secret by calling the Flask app's `/secret` endpoint.
4.  Verify that a TLS certificate is issued by Vault and synced to a Kubernetes Secret, enabling HTTPS on the Gateway.

## Architecture

*   **Vault**: Runs in `dev` mode with root token `root`. UI accessible via http://localhost:8080/ui/
    *   **KV Engine**: Stores application configuration (username/password).
    *   **PKI Engine**: Acts as an internal Certificate Authority to issue TLS certificates.
*   **Vault Secrets Operator (VSO)**:
    *   Authenticates to Vault using the Kubernetes Auth Method.
    *   Syncs KV secrets to Kubernetes Secrets.
    *   Issues and syncs PKI certificates to Kubernetes TLS Secrets.
*   **Gateway API (Envoy Gateway)**:
    *   Manages the ingress traffic from the local machine to the Kind cluster.
    *   Terminates HTTPS traffic using the certificates synced by VSO.
*   **Flask App**:
    *   A simple Python application that reads secrets from the environment.
    *   Exposed via the Gateway on `/secret`.
*   **Infrastructure as Code**:
    *   **Terraform**: Manages everything after the Kind cluster is created — Helm releases (Vault, VSO, Envoy Gateway, container registry, Flask app), all Kubernetes Gateway resources, Vault internals (auth methods, PKI engine/roles, KV secrets), and VSO resources (`VaultConnection`, `VaultAuth`, `VaultStaticSecret`, `VaultPKISecret`).
    *   `setup.sh` is a thin bootstrap: it creates the Kind cluster, runs `terraform init`, and orchestrates three targeted `terraform apply` phases to resolve provider bootstrap ordering.

## TLS Certificate Plumbing

The following steps describe how the TLS certificate is generated and used to secure the application:

1.  **Vault Configuration**: Terraform enables the PKI secret engine in Vault (`pki/`) and configures a role (`flask-app-role`) that allows issuing certificates for `flask-app.default.svc`.
2.  **Certificate Request**: The `VaultPKISecret` custom resource (`flask-app-cert`) defines a request for a certificate from Vault using the `flask-app-role`.
3.  **Secret Sync**: The Vault Secrets Operator (VSO) processes this request, communicates with Vault to issue the certificate and private key, and saves them into a Kubernetes Secret named `flask-app-tls` (type `kubernetes.io/tls`) in the `default` namespace.
4.  **Gateway Configuration**: The `Gateway` resource (`eg`) is configured with an HTTPS listener on port 443. This listener explicitly references the `flask-app-tls` secret.
5.  **TLS Termination**: The Envoy Proxy (data plane) loads the certificate from the `flask-app-tls` secret and uses it to terminate TLS connections from the client (browser/curl) before forwarding the decrypted traffic to the `flask-app` service.

This architecture ensures that certificates are short-lived (managed by Vault) and automatically rotated by VSO (which updates the Kubernetes Secret), with the Gateway picking up the changes automatically.

## Manual Interaction

After the script completes:

*   **Kubernetes Context**:`kind-vault-demo`
*   **Vault UI**: http://localhost:8080/ui (Token: `root`)
*   **Test APP (HTTP)**: http://localhost:8080/secret
*   **Test APP (HTTPS)**: https://localhost:8443/secret

To see the synced secret:

username:
```bash
kubectl get secret k8s-secret-from-vault -o jsonpath='{.data.username}' | base64 --decode
```

password:
```bash
kubectl get secret k8s-secret-from-vault -o jsonpath='{.data.password}' | base64 --decode
```

To see the status of the synced k8s certificate:
```bash
kubectl describe VaultPKISecret flask-app-cert
```

To see the serial number of the issued certificate presented by the Gateway:
```bash
echo | openssl s_client -showcerts -connect 127.0.0.1:8443 2>/dev/null | openssl x509 -noout -serial
```

To force a rotation of the TLS cert on the Gateway:
1. Delete the generated Kubernetes secret. VSO will detect this and immediately request a new certificate from Vault.
    ```bash
    kubectl delete secret flask-app-tls
    ```
2. Verify that the secret has been recreated (the age should be very recent):
    ```bash
    kubectl get secret flask-app-tls
    ```
3. Check the serial number again to confirm it has changed:
    ```bash
    echo | openssl s_client -showcerts -connect 127.0.0.1:8443 2>/dev/null | openssl x509 -noout -serial
    ```

## Troubleshooting

If the script fails at the verification step, check the status of the `VaultStaticSecret` or `VaultPKISecret`.

**Note:** `VaultStaticSecret` may show a `RolloutRestartTriggeredFailed` error initially if the `flask-app` deployment was not ready when the secret was first synced. This is expected and should resolve automatically or can be ignored if the application is running correctly.

```bash
kubectl get vaultstaticsecret example-secret -o yaml
kubectl get vaultpkisecret flask-app-cert -o yaml
```

If the HTTPS gateway is not reachable, check the Gateway and HTTPRoute status:

```bash
kubectl get gateway eg -n default -o yaml
kubectl get httproute vault -n default -o yaml
```

You can also check the Envoy Gateway logs:
```bash
kubectl logs -n envoy-gateway-system -l control-plane=envoy-gateway
```
