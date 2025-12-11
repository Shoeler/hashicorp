# Vault with Kind and Vault Secrets Operator

This project sets up a local HashiCorp Vault instance and the Vault Secrets Operator (VSO) on a Kind Kubernetes cluster. It uses Terraform to configure Vault and the VSO resources.  Additionally, it uses gatewayAPI / envoy to expose ports locally instead of having to use port-forward.

**This script will delete and reinstall the KIND cluster if one already exists, so be intentional about re-running it!**

## Prerequisites

Ensure you have the following tools preinstalled on your M-series Mac:

*   [Podman](https://podman.io) (`brew install podman && podman machine init && podman machine start`)
*   [Kind](https://kind.sigs.k8s.io/) (`brew install kind`)
*   [Kubectl](https://kubernetes.io/docs/tasks/tools/) (`brew install kubectl`)
*   [Helm](https://helm.sh/) (`brew install helm`)
*   [tfenv](https://github.com/tfutils/tfenv) (`brew install tfenv && tfenv install && tfenv use`) - optional but strongly suggested

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
2.  Install envoy gateway via Helm to handle cluster ingress
3.  Install Vault (in dev mode) via Helm to the kind cluster as a pod.
4.  Install Vault Secrets Operator via Helm to the kind cluster.
5.  Configure Vault and the Operator using Terraform.
6.  Verify that a sample secret is synced from Vault to a Kubernetes Secret by deploying a simple flask app that reads the secret's contents with an API call
7.  Verify that a TLS certificate is issued by Vault and synced to a Kubernetes Secret, enabling HTTPS on the Gateway.

## Architecture

*   **Vault**: Runs in `dev` mode with root token `root`. UI accessible via http://localhost/ui/
*   **Vault Secrets Operator**: Authenticates to Vault using the Kubernetes Auth Method.
*   **Gateway API and envoy**: Ingress from the local machine to the kind cluster. Terminates HTTPS traffic using certificates issued by Vault.
*   **Helm**:
    *    Deploys envoy via the default envoy helm chart
    *    Deploys Vault via default HashiCorp helm chart
    *    Deploys VSO via default HashiCorp helm chart
    *    Deploys dogfood flask app after k8s cluster fully configured
*   **Terraform**:
    *   Configures the Kubernetes Auth Method in Vault.
    *   Enables the PKI secrets engine in Vault and configures a role.
    *   Creates a policy and role for VSO.
    *   Creates a sample secret `secret/data/example`.
    *   Deploys VSO CRDs:
        *   `VaultConnection`, `VaultAuth`
        *   `VaultStaticSecret`: Syncs the KV secret.
        *   `VaultPKISecret`: Issues and syncs a TLS certificate.
    *   Creates HTTP routes for the flask app and vault UI

## Manual Interaction

After the script completes:

*   **Kubernetes Context**:`kind-vault-demo`
*   **Vault UI**: http://localhost/ui (Token: `root`) 
*   **Test APP (HTTP)**: http://localhost/secret
*   **Test APP (HTTPS)**: https://localhost/secret

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

To see the serial number of the issued certificate (from inside the app):
```bash
kubectl exec -it <flask-app-pod-name> -- openssl x509 -in /etc/certs/tls.crt -noout -serial
```

## Troubleshooting

If the script fails at the verification step, check the status of the `VaultStaticSecret` or `VaultPKISecret`:

```bash
kubectl get vaultstaticsecret example-secret -o yaml
kubectl get vaultpkisecret flask-app-cert -o yaml
```
