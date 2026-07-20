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
| `/dynamic-secret` | Ephemeral Postgres credentials (username + password) |
| `/db-query` | Live Postgres query using the current Vault-issued credentials |

All Flask endpoints are available on HTTP and HTTPS.

---

## Demo scripts

```bash
make demo-rotate-cert          # delete TLS cert → VSO reissues → confirm serial changed
make demo-update-secret        # update KV in Vault → observe Flask sync in ~10s
make demo-dynamic-creds        # show creds + DB query → rotate → confirm new role in query
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

## Attaching a Vault Agent Running on the Host (macOS)

You can run a [Vault Agent](https://developer.hashicorp.com/vault/docs/agent-and-proxy/agent) directly on your Mac — outside the Kind cluster — that authenticates to the same Vault instance the cluster uses. The agent reaches Vault through the Gateway's HTTP listener (`http://localhost:8080`), the same address the Vault UI uses.

The root token isn't appropriate to hand to a host process, so the agent authenticates using [AppRole](https://developer.hashicorp.com/vault/docs/auth/approle) instead.

### Install the Vault CLI/Agent binary

```bash
brew install vault
```

### Create an AppRole for the agent

Point the CLI at the local Vault instance and authenticate with an admin token. For `make setup` (dev mode) that's the hardcoded dev token; for `make setup-ha` (standalone mode) pull `root_token` out of `vault-init.json`:

```bash
export VAULT_ADDR=http://localhost:8080

# dev mode
export VAULT_TOKEN=root

# standalone mode instead
export VAULT_TOKEN=$(python3 -c "import json; print(json.load(open('vault-init.json'))['root_token'])")
```

Enable the AppRole auth method (skip if already enabled):

```bash
vault auth enable approle
```

Create a policy granting the agent whatever access it needs — this example allows read access to the same KV secrets the Flask app uses:

```bash
vault policy write host-agent-policy - <<EOF
path "secret/data/*" {
  capabilities = ["read"]
}
path "secret/metadata/*" {
  capabilities = ["list"]
}
EOF
```

Create an AppRole role bound to that policy:

```bash
vault write auth/approle/role/host-agent \
    token_policies="host-agent-policy" \
    token_ttl=1h \
    token_max_ttl=4h \
    secret_id_ttl=24h \
    secret_id_num_uses=0
```

Fetch the Role ID and generate a Secret ID, saving each to a file the agent will read on the host:

```bash
vault read -field=role_id auth/approle/role/host-agent/role-id > ~/.vault-role-id
vault write -field=secret_id -f auth/approle/role/host-agent/secret-id > ~/.vault-secret-id
chmod 600 ~/.vault-role-id ~/.vault-secret-id
```

`secret_id` is a credential — treat `~/.vault-secret-id` like a password. `role_id` is less sensitive but still shouldn't be made public.

> In dev mode, storage is in-memory, so every `make setup` run wipes Vault clean and you'll need to re-run this section after each redeploy. In standalone mode (`make setup-ha`), Raft storage persists across pod restarts, but `make teardown` still destroys the cluster and the AppRole with it. Either way, for anything beyond a one-off demo, codify this in `vault.tf` alongside `vault_kubernetes_auth_backend_role.vso_role`, using `vault_auth_backend`, `vault_policy`, and `vault_approle_auth_backend_role` resources.

### Write the Vault Agent config

Create `vault-agent.hcl` on the host (replace `/Users/youruser` with your home directory):

```hcl
vault {
  address = "http://127.0.0.1:8080"
}

auto_auth {
  method "approle" {
    mount_path = "auth/approle"
    config = {
      role_id_file_path                  = "/Users/youruser/.vault-role-id"
      secret_id_file_path                = "/Users/youruser/.vault-secret-id"
      remove_secret_id_file_after_reading = false
    }
  }

  sink "file" {
    config = {
      path = "/Users/youruser/.vault-token"
    }
  }
}

cache {
  use_auto_auth_token = true
}

listener "tcp" {
  address     = "127.0.0.1:8200"
  tls_disable = true
}

template {
  source      = "/Users/youruser/vault-agent-templates/example.ctmpl"
  destination = "/Users/youruser/vault-agent-output/example.env"
}
```

This config authenticates via AppRole, writes the resulting token to `~/.vault-token`, serves a local Vault-compatible cache/proxy on `127.0.0.1:8200`, and renders the `secret/example` KV secret to a file via `template`.

Create the template referenced above at `vault-agent-templates/example.ctmpl`:

```
{{- with secret "secret/data/example" }}
USERNAME={{ .Data.data.username }}
PASSWORD={{ .Data.data.password }}
{{- end }}
```

### Run the agent

```bash
mkdir -p ~/vault-agent-templates ~/vault-agent-output
vault agent -config=vault-agent.hcl
```

In another terminal, confirm it authenticated and rendered the template:

```bash
cat ~/.vault-token
cat ~/vault-agent-output/example.env
```

You can also point any Vault-aware client at the agent's local listener instead of Vault directly:

```bash
export VAULT_ADDR=http://127.0.0.1:8200
vault kv get secret/example
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
may still be in progress. Wait for it to finish:

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
