# Vault with Kind and Vault Secrets Operator

A local demo showing how the **Vault Secrets Operator (VSO)** syncs secrets and PKI
certificates from HashiCorp Vault into Kubernetes. Terraform manages everything after
cluster creation — Helm releases, Vault config, VSO CRDs, and the Flask demo app.

> **Warning:** `make setup` and `make setup-ha` delete and recreate the Kind cluster if one already exists.

---

## Architecture

```
  localhost:8080 (HTTP)          localhost:8443 (HTTPS)
         │                               │
         │  NodePort 30080               │  NodePort 30443
         ▼                               ▼
  ┌──────────────────────────────────────────────────┐
  │  Envoy Gateway                                   │
  │  :80 (HTTP)   :443 (HTTPS) ◄── flask-app-tls    │
  └──────────────────┬───────────────────────────────┘
                     │  /secret, /dynamic-secret
                     ▼
  ┌──────────────────────────────┐
  │  Flask App                   │
  │  GET /secret                 │  ◄── SECRET_USERNAME, SECRET_PASSWORD
  │  GET /dynamic-secret         │  ◄── DB_USERNAME, DB_PASSWORD
  └──────────────────────────────┘
           ▲ env vars from K8s Secrets
           │
  ┌──────────────────────────────────────────────────┐
  │  Vault Secrets Operator (VSO)                    │
  │                                                  │
  │  VaultStaticSecret  ──► k8s-secret-from-vault    │
  │  VaultDynamicSecret ──► db-dynamic-creds         │
  │  VaultPKISecret     ──► flask-app-tls            │
  └───────────────────────────┬──────────────────────┘
                              │  Kubernetes auth
                              ▼
  ┌──────────────────────────────────────────────────┐
  │  Vault  (dev mode or standalone/Raft)            │
  │                                                  │
  │  secret/example      ──► KV credentials          │
  │  pki/                ──► TLS certificate CA      │
  │  database/           ──► Postgres dynamic creds  │
  │  secret/flask-app/*  ──► namespace-isolated KV   │
  └──────────────────────────────────────────────────┘
```

### Namespace isolation

Each namespace gets its own `VaultAuth` bound to a scoped Vault role:

```
  ┌──────────────────────────────┐   ┌──────────────────────────────┐
  │  namespace: default          │   │  namespace: flask-app        │
  │  role: vso-role              │   │  role: flask-app-role        │
  │                              │   │                              │
  │  ✓ secret/data/*             │   │  ✓ secret/flask-app/* only  │
  │  ✓ pki/issue/*               │   │  ✗ secret/example           │
  │  ✓ database/creds/*          │   │  ✗ pki/issue/*              │
  │                              │   │  ✗ database/creds/*         │
  │  k8s-secret-from-vault       │   │  flask-app-isolated-secret  │
  │  db-dynamic-creds            │   │                              │
  │  flask-app-tls               │   │                              │
  └──────────────────────────────┘   └──────────────────────────────┘
```

---

## Prerequisites

Built for M-series Macs with Podman. Install before running setup:

- **Podman** — `brew install podman` then `podman machine init && podman machine set --rootful && podman machine start`
- **Kind** — `brew install kind`
- **kubectl** — `brew install kubectl`
- **Helm** — `brew install helm`
- **tfenv** — `brew install tfenv` then `tfenv install && tfenv use` in the project root

---

## Quick Start

```bash
make setup       # create cluster + full Terraform apply (~10 min) — Vault dev mode
make setup-ha    # same, but Vault in standalone mode with Raft storage (init/unseal required)
make teardown    # delete the Kind cluster when done
```

Rebuild and redeploy only the Flask app without touching the cluster:

```bash
make redeploy-app
```

---

## How it works

`setup.sh` (invoked by `make setup` / `make setup-ha`) runs targeted Terraform phases to work around
provider bootstrap ordering — the Vault provider needs Vault reachable, but Vault only
becomes reachable after the Gateway NodePort is created:

1. **Phase 1** — Helm releases (Vault, VSO, Envoy Gateway, registry), Postgres pod, and the `flask-app` namespace.
2. **Phase 2** — Gateway infrastructure and HTTP NodePort; Vault is now reachable at `http://localhost:8080`.
3. **Phase 2.5** *(standalone mode only)* — Runs `vault operator init` (saves unseal key + root token to `vault-init.json`) and `vault operator unseal`. Root token is exported as `TF_VAR_vault_dev_token` for Phase 3.
4. **Phase 3** — Full apply: Vault engines (KV, PKI, database), auth methods, VSO CRDs, Flask image build and deploy, HTTPS NodePort.

### Vault modes

| | `make setup` (dev) | `make setup-ha` (standalone) |
|---|---|---|
| Storage | in-memory, ephemeral | Raft on `/vault/data` |
| Init/unseal | automatic | `vault operator init` + unseal |
| Root token | `root` (hardcoded) | generated; saved to `vault-init.json` |
| Data on restart | lost | persists across pod restarts |
| Use case | demos, local dev | closer to production behaviour |

> **Caution:** `vault-init.json` contains the unseal key and root token — it is git-ignored and should never be committed.

---

## Endpoints

Base URLs: **HTTP** → `http://localhost:8080` · **HTTPS** → `https://localhost:8443`

| Path | Notes |
|---|---|
| `/ui/` | Vault UI — token: `root` |
| `/secret` | KV credentials synced from `secret/example` |
| `/dynamic-secret` | Ephemeral Postgres credentials from Vault database engine |

Both `/secret` and `/dynamic-secret` are available on HTTP and HTTPS.

---

## Demo scripts

```bash
make demo-rotate-cert          # delete TLS cert → VSO reissues → confirm serial changed
make demo-update-secret        # update KV in Vault → observe Flask sync in ~10s
make demo-dynamic-creds        # show ephemeral Postgres creds → force rotation → new creds
make demo-namespace-isolation  # compare VaultAuth roles; show flask-app tenant secret
```

### Inspect synced secrets

```bash
# KV secret
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

### Force TLS certificate rotation

```bash
# Current serial
echo | openssl s_client -showcerts -connect 127.0.0.1:8443 2>/dev/null \
  | openssl x509 -noout -serial

# Rotate — VSO reissues within seconds
kubectl delete secret flask-app-tls
kubectl get secret flask-app-tls
```

---

## Troubleshooting

### Podman machine not rootful

```bash
podman machine stop && podman machine set --rootful && podman machine start
```

### Port already in use (8080, 8443, or 5001)

```bash
lsof -i :8080    # find the conflicting process
```

Override ports in `variables.tf` and update `kind-config.yaml` to match.

### Phase 2 timeout — Vault not reachable

```bash
kubectl get svc -n envoy-gateway-system
kubectl get gateway eg -n default -o yaml
kubectl logs -n envoy-gateway-system -l control-plane=envoy-gateway
```

### Vault database connection fails in Phase 3

`vault_database_secret_backend_connection` verifies connectivity to Postgres on creation.
If Terraform errors here, Postgres may not have finished starting:

```bash
kubectl get pod -l app=postgres    # should be Running 1/1
kubectl logs -l app=postgres
```

Re-run `terraform apply -auto-approve` once Postgres is ready.

### `/dynamic-secret` returns 500

VSO issues the first credential set after the `VaultDynamicSecret` CRD is created.
Allow ~10s after the Flask app starts:

```bash
kubectl describe VaultDynamicSecret db-creds
kubectl get secret db-dynamic-creds
```

### `VaultStaticSecret` shows `RolloutRestartTriggeredFailed`

Benign race between first sync and Flask app startup — resolves automatically.

### HTTPS Gateway not responding

```bash
kubectl get gateway eg -n default -o yaml
kubectl get httproute -n default
kubectl logs -n envoy-gateway-system -l control-plane=envoy-gateway
kubectl describe VaultPKISecret flask-app-cert
```

The HTTPS listener stays degraded until `flask-app-tls` is created by VSO.
