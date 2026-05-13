# Vault with Kind and Vault Secrets Operator

A local demo environment showing how the [Vault Secrets Operator (VSO)](https://developer.hashicorp.com/vault/docs/platform/k8s/vso) syncs secrets and PKI certificates from HashiCorp Vault into Kubernetes. Terraform manages everything after cluster creation.

> **Warning:** `make setup` deletes and recreates the Kind cluster if one already exists.

## Architecture

```
  localhost:8080 (HTTP)          localhost:8443 (HTTPS)
         │                               │
         │  NodePort 30080               │  NodePort 30443
         ▼                               ▼
  ╔══════════════════════════════════════════════════╗
  ║  Envoy Gateway                                   ║
  ║  :80 (HTTP)   :443 (HTTPS) ◄── flask-app-tls    ║
  ╚══════════════════╤═══════════════════════════════╝
                     │  /secret, /dynamic-secret
                     ▼
  ╔══════════════════════════════╗
  ║  Flask App                   ║
  ║  GET /secret                 ║  ◄── env: SECRET_USERNAME, SECRET_PASSWORD
  ║  GET /dynamic-secret         ║  ◄── env: DB_USERNAME, DB_PASSWORD
  ╚══════════════════════════════╝
           ▲ K8s Secrets (env vars)
           │
  ╔══════════════════════════════════════════════════╗
  ║  Vault Secrets Operator (VSO)                    ║
  ║                                                  ║
  ║  VaultStaticSecret  ──► k8s-secret-from-vault   ║
  ║  VaultDynamicSecret ──► db-dynamic-creds         ║
  ║  VaultPKISecret     ──► flask-app-tls            ║
  ╚═══════════════════════════╤══════════════════════╝
                              │  Kubernetes auth
                              ▼
  ╔══════════════════════════════════════════════════╗
  ║  Vault (dev mode, token: root)                   ║
  ║                                                  ║
  ║  secret/example      ──► KV credentials          ║
  ║  pki/                ──► TLS certificate CA      ║
  ║  database/           ──► Postgres dynamic creds  ║
  ║  secret/flask-app/*  ──► namespace-isolated KV   ║
  ╚══════════════════════════════════════════════════╝
```

### Namespace isolation

Each namespace gets its own `VaultAuth` bound to a scoped Vault role — a tenant in `flask-app` cannot read secrets owned by `default`, and vice versa:

```
  ┌─────────────────────────────┐   ┌──────────────────────────────┐
  │  namespace: default         │   │  namespace: flask-app        │
  │  role: vso-role             │   │  role: flask-app-role        │
  │                             │   │                              │
  │  ✓ secret/data/*            │   │  ✓ secret/flask-app/* only  │
  │  ✓ pki/issue/*              │   │  ✗ secret/example           │
  │  ✓ database/creds/*         │   │  ✗ pki/issue/*              │
  │                             │   │  ✗ database/creds/*         │
  │  k8s-secret-from-vault      │   │  flask-app-isolated-secret  │
  │  db-dynamic-creds           │   │                              │
  │  flask-app-tls              │   │                              │
  └─────────────────────────────┘   └──────────────────────────────┘
```

## Prerequisites

Built for M-series Macs with Podman. Requires:

- [Podman](https://podman.io): `brew install podman && podman machine init && podman machine set --rootful && podman machine start`
- [Kind](https://kind.sigs.k8s.io/): `brew install kind`
- `kubectl`: `brew install kubectl`
- [Helm](https://helm.sh/): `brew install helm`
- [tfenv](https://github.com/tfutils/tfenv): `brew install tfenv` — then `tfenv install && tfenv use` in the project root

## Quick Start

```bash
make setup       # create cluster + full Terraform apply (~10 min)
make teardown    # delete the Kind cluster when done
```

To rebuild and redeploy only the Flask app without touching the cluster:

```bash
make redeploy-app
```

## How it works

`setup.sh` (invoked by `make setup`) bootstraps in three Terraform phases to handle provider ordering:

1. **Phase 1** — Installs Helm releases (Vault, VSO, Envoy Gateway, registry) and creates the Postgres deployment and `flask-app` namespace.
2. **Phase 2** — Creates Gateway infrastructure and the HTTP NodePort service, making Vault reachable at `http://localhost:8080`.
3. **Phase 3** — Full `terraform apply`: configures Vault engines (KV, PKI, database), auth methods, VSO CRDs, builds the Flask image, and deploys the app. Creates the HTTPS NodePort after VSO issues the TLS cert.

## Endpoints

| Endpoint | HTTP | HTTPS |
|---|---|---|
| Vault UI | http://localhost:8080/ui/ (token: `root`) | — |
| KV secret | http://localhost:8080/secret | https://localhost:8443/secret |
| Dynamic DB creds | http://localhost:8080/dynamic-secret | https://localhost:8443/dynamic-secret |

## Demo scripts

After setup, use `make` to run the scripted demos:

```bash
make demo-rotate-cert          # delete TLS cert → VSO reissues → confirm serial changed
make demo-update-secret        # update KV in Vault → observe Flask /secret sync in ~10s
make demo-dynamic-creds        # show ephemeral Postgres creds → force rotation → new creds
make demo-namespace-isolation  # show scoped VaultAuth roles and the flask-app tenant secret
```

### Inspect synced secrets manually

```bash
# KV secret (static)
kubectl get secret k8s-secret-from-vault -o jsonpath='{.data.username}' | base64 --decode

# Dynamic Postgres credentials
kubectl get secret db-dynamic-creds -o jsonpath='{.data.username}' | base64 --decode

# Namespace-isolated secret (flask-app tenant)
kubectl get secret flask-app-isolated-secret -n flask-app -o yaml

# VSO resource status
kubectl describe VaultStaticSecret example-secret
kubectl describe VaultDynamicSecret db-creds
kubectl describe VaultPKISecret flask-app-cert
```

### TLS certificate rotation

```bash
# View serial of the certificate currently served by the Gateway
echo | openssl s_client -showcerts -connect 127.0.0.1:8443 2>/dev/null | openssl x509 -noout -serial

# Force rotation — VSO immediately requests a new cert from Vault PKI
kubectl delete secret flask-app-tls
kubectl get secret flask-app-tls   # recreated within seconds
```

## Troubleshooting

### Podman machine not rootful

VSO and Kind require rootful Podman. If you see permission errors on cluster creation:
```bash
podman machine stop && podman machine set --rootful && podman machine start
```

### Port already in use (8080, 8443, or 5001)

The Kind cluster maps host ports 8080, 8443, and 5001. If another process holds one:
```bash
lsof -i :8080    # find the conflicting process
```
Alternatively, override the ports in `variables.tf` and update `kind-config.yaml` to match.

### Phase 2 timeout — Vault not reachable

If `setup.sh` stalls at "Waiting for Vault to be reachable", the Envoy Gateway may not have assigned the HTTP NodePort yet:
```bash
kubectl get svc -n envoy-gateway-system
kubectl get gateway eg -n default -o yaml
kubectl logs -n envoy-gateway-system -l control-plane=envoy-gateway
```

### Vault database connection fails in Phase 3

`vault_database_secret_backend_connection` verifies connectivity to Postgres on creation. If Terraform errors here, Postgres may not have finished starting:
```bash
kubectl get pod -l app=postgres   # should be Running 1/1
kubectl logs -l app=postgres
```
Re-run `terraform apply -auto-approve` once Postgres is ready.

### `db-dynamic-creds` secret missing or `/dynamic-secret` returns 500

VSO issues the first dynamic credential set after the `VaultDynamicSecret` CRD is created. Allow ~10s after the Flask app starts, then check:
```bash
kubectl describe VaultDynamicSecret db-creds
kubectl get secret db-dynamic-creds
```

### `VaultStaticSecret` shows `RolloutRestartTriggeredFailed`

This appears if the first sync races with Flask app startup. It is benign and resolves automatically once the deployment is ready.

### HTTPS Gateway not responding

```bash
kubectl get gateway eg -n default -o yaml
kubectl get httproute -n default
kubectl logs -n envoy-gateway-system -l control-plane=envoy-gateway
```
The HTTPS listener stays degraded until `flask-app-tls` is created by VSO. If the secret exists but HTTPS is still down, describe the VaultPKISecret:
```bash
kubectl describe VaultPKISecret flask-app-cert
```
