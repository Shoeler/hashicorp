# Vault with Kind and Vault Secrets Operator

This project sets up a local HashiCorp Vault instance and the Vault Secrets Operator (VSO) on a Kind Kubernetes cluster. It uses Terraform to configure Vault and the VSO resources.

## Prerequisites

Ensure you have the following tools installed on your M1 Mac:

*   [Docker](https://docs.docker.com/get-docker/) (running)
*   [Kind](https://kind.sigs.k8s.io/) (`brew install kind`)
*   [Kubectl](https://kubernetes.io/docs/tasks/tools/) (`brew install kubectl`)
*   [Helm](https://helm.sh/) (`brew install helm`)
*   [Terraform](https://www.terraform.io/) (`brew install terraform`)

## Quick Start

Run the setup script:

```bash
./setup.sh
```

This script will:
1.  Create a Kind cluster named `vault-demo`.
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
*   **Vault UI**: http://localhost:8200 (Token: `root`)

To see the synced secret:

```bash
kubectl get secret k8s-secret-from-vault -o yaml
```

## Troubleshooting

If the script fails at the verification step, check the status of the `VaultStaticSecret`:

```bash
kubectl get vaultstaticsecret example-secret -o yaml
```
