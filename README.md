# Vault with Kind and Vault Secrets Operator

This project sets up a local HashiCorp Vault instance and the Vault Secrets Operator (VSO) on a Kind Kubernetes cluster. It uses Terraform to configure Vault and the VSO resources.  It will reinstall the KIND cluster if one already exists, so be intentional about re-running it!

## Prerequisites

Ensure you have the following tools installed on your M-series Mac:

*   [Podman](https://podman.io) ('brew install podman')
*   [Docker](https://docs.docker.com/get-docker/) (podman machine must be running)
*   [Kind](https://kind.sigs.k8s.io/) (`brew install kind`)
*   [Kubectl](https://kubernetes.io/docs/tasks/tools/) (`brew install kubectl`)
*   [Helm](https://helm.sh/) (`brew install helm`)
*   [Terraform](https://www.terraform.io/) (`brew install terraform`)
*   [tfenv](https://github.com/tfutils/tfenv) ('brew install tfenv') - optional but strongly suggested

## Quick Start

Run the setup script:

```bash
./setup.sh
```

This script will:
1.  Create or recreate a Kind cluster named `vault-demo`.
2.  Install Vault (in dev mode) via Helm.
3.  Install Vault Secrets Operator via Helm.
4.  Configure Vault and the Operator using Terraform.
5.  Verify that a sample secret is synced from Vault to a Kubernetes Secret.

## Architecture

*   **Vault**: Runs in `dev` mode with root token `root`. Accessible at `http://localhost:8200` via port-forwarding.
*   **Vault Secrets Operator**: Authenticates to Vault using the Kubernetes Auth Method.
*   **Terraform**:
    *   Configures the Kubernetes Auth Method in Vault.
    *   Creates a policy and role for VSO.
    *   Creates a sample secret `secret/data/example`.
    *   Deploys VSO CRDs (`VaultConnection`, `VaultAuth`, `VaultStaticSecret`) to sync the secret.

## Manual Interaction

After the script completes:

*   **Kubernetes Context**: `kind-vault-demo`
*   **Vault UI**: http://localhost:8200 (Token: `root`) NOTE:  Sometimes the port-forward seems to die, if it does then run `kubectl port-forward svc/vault 8200:8200 >/dev/null 2>&1 &`

To see the synced secret:

```bash
kubectl get secret k8s-secret-from-vault -o yaml
```

## Troubleshooting

If the script fails at the verification step, check the status of the `VaultStaticSecret`:

```bash
kubectl get vaultstaticsecret example-secret -o yaml
```
