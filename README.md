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
                     │  /secret  /dynamic-secret
                     │  /db-query  /pool-status
                     ▼
  ┌──────────────────────────────────────────────────┐
  │  Flask App  (2 replicas, RollingUpdate)          │
  │  GET /secret          ◄── SECRET_USERNAME        │
  │  GET /dynamic-secret  ◄── DB_USERNAME            │
  │  GET /db-query            DB_PASSWORD            │
  │  GET /pool-status     ◄── ThreadedConnectionPool │
  └──────────────────────────────────────────────────┘
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

| Path | HTTP | HTTPS | Notes |
|---|---|---|---|
| `/ui/` | [http](http://localhost:8080/ui/) | — | Vault UI — token: `root` (dev) or from `vault-init.json` (standalone) |
| `/secret` | [http](http://localhost:8080/secret) | [https](https://localhost:8443/secret) | KV credentials synced from `secret/example` |
| `/dynamic-secret` | [http](http://localhost:8080/dynamic-secret) | [https](https://localhost:8443/dynamic-secret) | Ephemeral Postgres credentials (username + password) |
| `/db-query` | [http](http://localhost:8080/db-query) | [https](https://localhost:8443/db-query) | Live Postgres query via connection pool; `connected_as` shows the active Vault role |
| `/pool-status` | [http](http://localhost:8080/pool-status) | [https](https://localhost:8443/pool-status) | Per-replica pool stats: pod name, vault role, pool size, queries served since pod start |

All Flask endpoints are available on HTTP and HTTPS. The app runs as **2 replicas** — hit
`/pool-status` repeatedly to see requests load-balanced across both pods, both showing the
same `vault_role`. When VSO rotates credentials it triggers a rolling restart, so at least
one replica is always serving.

---

## Demo scripts

```bash
make demo-rotate-cert          # delete TLS cert → VSO reissues → confirm serial changed
make demo-update-secret        # update KV in Vault → observe Flask sync in ~10s
make demo-dynamic-creds        # show creds + DB query → rotate → confirm new role in query
make demo-namespace-isolation  # compare VaultAuth roles; show flask-app tenant secret
```

### `make demo-rotate-cert`

[HTTP](http://localhost:8080/secret) · [HTTPS](https://localhost:8443/secret)

```
==> Current TLS certificate serial: serial=02AE2DB8045C856D11E7A915071636C29038F2E4

==> Deleting flask-app-tls — VSO will request a new cert from Vault PKI...
==> Waiting for VSO to reissue...
==> New TLS certificate serial:     serial=15FB485F02498EF7480317C156C1C7F6F4F94EE8

Rotation confirmed — serial changed.
```

### `make demo-update-secret`

[HTTP](http://localhost:8080/secret) · [HTTPS](https://localhost:8443/secret)

```
==> Current /secret response:
{ "password": "supersecretpassword", "username": "admin" }

==> Writing new credentials to Vault (username=demo-1779969091)...
==> Waiting 12s for VSO to sync (refreshAfter=10s)...
==> Updated /secret response:
{ "password": "rotated-065131", "username": "demo-1779969091" }
```

### `make demo-dynamic-creds`

[/dynamic-secret HTTP](http://localhost:8080/dynamic-secret) · [HTTPS](https://localhost:8443/dynamic-secret) · [/db-query HTTP](http://localhost:8080/db-query) · [HTTPS](https://localhost:8443/db-query)

```
==> K8s Secret 'db-dynamic-creds' (as synced by VSO):
NAME               CREATED                MANAGED-BY
db-dynamic-creds   2026-05-28T11:49:27Z   hashicorp-vso

==> Decoded credentials:
    username: v-kubernet-flask-ap-mnZlYzJgF35S4Lv8MXc4-1779968967

==> Querying Postgres via /db-query (pre-rotation):
{ "connected_as": "v-kubernet-flask-ap-mnZlYzJgF35S4Lv8MXc4-1779968967", "products": [...] }

==> Forcing rotation — deleting 'db-dynamic-creds'...
==> New decoded credentials (different Postgres role):
    username: v-kubernet-flask-ap-3btxtORgIr3Tmv8RDOtj-1779969109

==> Waiting for rollout restart triggered by VSO...
deployment "flask-app" successfully rolled out

==> Querying Postgres via /db-query (post-rotation — new Vault role):
{ "connected_as": "v-kubernet-flask-ap-3btxtORgIr3Tmv8RDOtj-1779969109", "products": [...] }

The 'connected_as' field confirms the pod is using the rotated credential.
```

### `make demo-namespace-isolation`

[Vault UI](http://localhost:8080/ui/)

```
==> flask-app namespace VaultAuth (uses flask-app-role — scoped to flask-app/* only):
    role: flask-app-role

==> default namespace VaultAuth (uses vso-role — access to all engines):
    role: vso-role

==> flask-app-isolated-secret (synced from secret/flask-app/config — flask-app ns only):
    api_key: demo-api-key-abc123
    tier: premium

The flask-app-role cannot read secret/example or issue PKI/database creds.
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

### `/dynamic-secret` or `/db-query` returns 500

VSO issues the first credential set after the `VaultDynamicSecret` CRD is created.
Allow ~10s after the Flask app starts:

```bash
kubectl describe VaultDynamicSecret db-creds
kubectl get secret db-dynamic-creds
```

If `/db-query` returns a Postgres connection error after rotation, the rollout restart
may still be in progress:

```bash
kubectl rollout status deployment/flask-app
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
