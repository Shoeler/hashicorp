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

This script will:
1.  Create or recreate a Kind cluster named `vault-demo`.
2.  Install envoy gateway via Helm to handle cluster ingress
3.  Install Vault (in dev mode) via Helm to the kind cluster as a pod.
4.  Install Vault Secrets Operator via Helm to the kind cluster.
5.  Configure Vault and the Operator using Terraform.
6.  Verify that a sample secret is synced from Vault to a Kubernetes Secret by deploying a simple flask app that reads the secret's contents with an API call

## Architecture

*   **Vault**: Runs in `dev` mode with root token `root`. UI accessible via http://localhost/ui/
*   **Vault Secrets Operator**: Authenticates to Vault using the Kubernetes Auth Method.
*   **Gateway API and envoy**: Ingress from the local machine to the kind cluster
*   **Helm**:
    *    Deploys envoy via the default envoy helm chart
    *    Deploys Vault via default HashiCorp helm chart
    *    Deploys VSO via default HashiCorp helm chart
    *    Deploys dogfood flask app after k8s cluster fully configured
*   **Terraform**:
    *   Configures the Kubernetes Auth Method in Vault.
    *   Creates a policy and role for VSO.
    *   Creates a sample secret `secret/data/example`.
    *   Deploys VSO CRDs (`VaultConnection`, `VaultAuth`, `VaultStaticSecret`) to sync the secret.
    *   Creates HTTP routes for the flask app and vault UI

## Manual Interaction

After the script completes:

*   **Kubernetes Context**:`kind-vault-demo`
*   **Vault UI**: http://localhost/ui (Token: `root`) 
*   **Test APP**: http://localhost/secret

To see the synced secret:

username:
```bash
kubectl get secret k8s-secret-from-vault -o jsonpath='{.data.username}' | base64 --decode
```

password:
```bash
kubectl get secret k8s-secret-from-vault -o jsonpath='{.data.password}' | base64 --decode
```

## Troubleshooting

If the script fails at the verification step, check the status of the `VaultStaticSecret`:

```bash
kubectl get vaultstaticsecret example-secret -o yaml
```
