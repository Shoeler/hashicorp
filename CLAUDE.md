# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A local demo environment showing how the Vault Secrets Operator (VSO) syncs secrets and PKI certificates from HashiCorp Vault into Kubernetes. Terraform manages everything after cluster creation — Helm releases, Vault config, VSO CRDs, and the Flask demo app. Designed for M-series Macs with Podman.

## Commands

**Primary interface — use `make` for everything:**
```bash
make setup                     # full cluster + Terraform apply (~10 min, destructive) — Vault dev mode
make setup-ha                  # same but Vault in standalone mode (Raft, requires init/unseal)
make redeploy-app              # rebuild Flask image and redeploy only, cluster intact
make teardown                  # delete the Kind cluster
make demo-rotate-cert          # delete TLS cert, watch VSO reissue, compare serials
make demo-update-secret        # write new KV secret to Vault, observe Flask sync in ~10s
make demo-dynamic-creds        # show creds + DB query, force rotation, confirm new role in query
make demo-namespace-isolation  # show scoped VaultAuth roles and flask-app tenant secret
```

**Flask app unit tests:**
```bash
cd flask-app && python -m pytest tests/
# run a single test:
python -m pytest tests/test_app.py::FlaskAppTests::test_get_dynamic_secret_env
```

**Targeted Terraform (iterating on a single resource post-setup):**
```bash
terraform apply -auto-approve -target=<resource>
```

**Inspect VSO resource status:**
```bash
kubectl get vaultstaticsecret example-secret -o yaml
kubectl get vaultpkisecret flask-app-cert -o yaml
kubectl get vaultdynamicsecret db-creds -o yaml
kubectl get secret flask-app-isolated-secret -n flask-app -o yaml
```

**Troubleshoot Gateway:**
```bash
kubectl get gateway eg -n default -o yaml
kubectl get httproute -n default
kubectl logs -n envoy-gateway-system -l control-plane=envoy-gateway
```

## Architecture

### Phased Terraform bootstrap

Terraform can't run a single `apply` because the Vault provider needs Vault to be reachable before it can configure it, but Vault becomes reachable only after the Gateway NodePort service is created. `setup.sh` (invoked by `make setup` / `make setup-ha`) solves this with targeted phases:

1. **Phase 1** — Installs Helm releases (registry, Envoy Gateway, Vault, VSO), deploys the Postgres pod and service, and creates the `flask-app` namespace. No Vault provider calls.
2. **Phase 2** — Creates the HTTP NodePort service and the `vault` HTTPRoute, making Vault reachable at `http://localhost:8080`.
3. **Phase 2.5** *(standalone mode only)* — `kubectl exec vault-0 -- vault operator init` (saves to `vault-init.json`) + `vault operator unseal`. Exports `TF_VAR_vault_dev_token` so the Vault provider uses the generated root token.
4. **Phase 3** — Full `terraform apply`. Vault provider can now connect; configures KV/PKI/database engines, auth methods and policies, all VSO CRDs, builds and deploys the Flask app, creates the HTTPS NodePort after VSO provisions the TLS cert. In dev mode, also imports `vault_mount.kvv2` — Vault dev mode pre-creates the `secret/` mount, so Terraform must import it rather than create it.

### VSO resource dependency chain

`VaultConnection` → `VaultAuth` → `VaultStaticSecret` / `VaultDynamicSecret` / `VaultPKISecret`

- **VaultConnection** (`vso.tf`): points VSO at `http://vault.default.svc:8200`.
- **VaultAuth** (`vso.tf`): binds the `default` service account to `vso-role` via Kubernetes auth.
- **VaultStaticSecret** (`vso.tf`): syncs `secret/data/example` → K8s Secret `k8s-secret-from-vault`. Refreshes every 10s; triggers a rollout restart on `flask-app` when the secret changes.
- **VaultDynamicSecret** (`vso.tf`): requests ephemeral Postgres credentials from `database/creds/flask-app-db-role` → K8s Secret `db-dynamic-creds`. VSO renews the Vault lease at 67% of TTL (default 1h). Deleting the K8s Secret forces immediate re-issuance; also triggers a rollout restart. The `/db-query` endpoint issues a live `SELECT` against the `products` table using these credentials — the `connected_as` field in the response shows the Vault-issued Postgres role name, making rotation visible.
- **VaultPKISecret** (`vso.tf`): issues a cert for `flask-app.default.svc` from the `pki` engine → K8s TLS Secret `flask-app-tls`. Deleting the secret forces immediate re-issuance.

### TLS certificate flow

Vault PKI engine → VSO `VaultPKISecret` → K8s Secret `flask-app-tls` → Envoy Gateway HTTPS listener → TLS termination → plain HTTP to Flask.

The HTTPS NodePort service (`gateway_nodeports_https` in `gateway.tf`) is created last in Phase 3. A `data "external"` block polls until `flask-app-tls` exists and Envoy has assigned its HTTPS container port — this is required on macOS/Podman where the port is non-deterministic.

### Dynamic port detection

`data "external" "envoy_http_port"` and `data "external" "envoy_https_port"` in `gateway.tf` use inline bash scripts to query the Envoy-managed service for its assigned container port. The HTTP detection runs in Phase 2; HTTPS detection runs in Phase 3 after the cert exists.

### Dynamic secrets: Postgres + Vault database engine (`database.tf`)

Deploys a Postgres pod and configures Vault's database secrets engine against it. Vault issues time-limited Postgres roles on demand; each credential set is unique and expires automatically. The `VaultDynamicSecret` (`db-creds`) holds the active lease. The Flask app exposes `/dynamic-secret` to show the current ephemeral credentials.

Postgres is deployed in Phase 1 so it is running before Phase 3 configures the Vault database connection. `vault_database_secret_backend_connection` verifies connectivity on creation — if it fails, check `kubectl get pod -l app=postgres`.

### Namespace isolation (`namespace.tf`)

Provisions a `flask-app` namespace with its own `VaultConnection`, `VaultAuth`, and `VaultStaticSecret`. The Vault auth role `flask-app-role` is bound exclusively to the `flask-app` namespace service account and carries `flask-app-policy`, which only grants access to `secret/data/flask-app/*`. The `default` namespace's `vso-role` cannot authenticate as `flask-app-role`, and vice versa.

Both namespaces have a `VaultConnection` and `VaultAuth` named `default` — Kubernetes scopes them independently.

### Flask app secret consumption

Reads KV creds as env vars (`SECRET_USERNAME`, `SECRET_PASSWORD`) from `k8s-secret-from-vault` and dynamic DB creds (`DB_USERNAME`, `DB_PASSWORD`) from `db-dynamic-creds`. The DB env vars are `optional: true` — the pod starts without them and returns 500 at `/dynamic-secret` until VSO provisions the secret. Both secrets are mounted via `secretKeyRef` in the Helm chart (`flask-app/chart/templates/deployment.yaml`).

`DB_HOST` is a plain env var (value: `postgres.default.svc`) set in the Helm chart. The `/db-query` endpoint uses `DB_USERNAME`/`DB_PASSWORD`/`DB_HOST` to open a psycopg2 connection, runs `SELECT current_user` and `SELECT id, name, description FROM products`, and returns both results — making it unambiguous which Vault-issued role is active. The `products` table is seeded by `null_resource.seed_postgres` in `database.tf` (runs in Phase 3 after Vault verifies the Postgres connection).

## Known quirks

- The Terraform Helm provider uses the chart `version` field in `Chart.yaml` to detect upgrades. Bump `flask-app/chart/Chart.yaml` version when changing chart templates, otherwise `terraform apply` will not re-render them.

- `VaultStaticSecret` may show `RolloutRestartTriggeredFailed` on first sync if the `flask-app` deployment isn't ready yet. Benign; resolves automatically.
- `vault_mount.kvv2` must be imported during Phase 2 (`terraform import vault_mount.kvv2 secret`) because Vault dev mode pre-creates the `secret/` engine. `setup.sh` handles this automatically (skipped in standalone mode).
- `make setup` / `make setup-ha` **delete and recreate the Kind cluster**. All in-cluster Terraform state is invalidated; `setup.sh` taints `null_resource.flask_image` to force an image rebuild, and removes any stale `vault-init.json`.
- `/dynamic-secret` returns 500 for a few seconds after first deploy while VSO provisions `db-dynamic-creds`. The `optional: true` secretKeyRef prevents CrashLoopBackOff.
- In standalone mode, `vault-init.json` is written by `setup.sh` and is git-ignored. It contains the unseal key and root token. Do not delete it while the cluster is running — `make setup-ha` on an already-initialized cluster reads it to re-unseal.

## Access points (post-setup)

| | URL | Auth |
|---|---|---|
| Vault UI | http://localhost:8080/ui/ | token: `root` (dev) or from `vault-init.json` (standalone) |
| Flask — KV secret (HTTP) | http://localhost:8080/secret | — |
| Flask — KV secret (HTTPS) | https://localhost:8443/secret | self-signed |
| Flask — dynamic creds (HTTP) | http://localhost:8080/dynamic-secret | — |
| Flask — dynamic creds (HTTPS) | https://localhost:8443/dynamic-secret | self-signed |
| Flask — DB query (HTTP) | http://localhost:8080/db-query | — |
| Flask — DB query (HTTPS) | https://localhost:8443/db-query | self-signed |
| Container registry | localhost:5001 | — |
