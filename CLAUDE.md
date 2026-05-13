# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this project is

A local demo environment showing how the Vault Secrets Operator (VSO) syncs secrets and PKI certificates from HashiCorp Vault into Kubernetes. Terraform manages everything after cluster creation — Helm releases, Vault config, VSO CRDs, and the Flask demo app. Designed for M-series Macs with Podman.

## Commands

**Full setup (creates/recreates the Kind cluster):**
```bash
./setup.sh
```

**Redeploy the Flask app only (no cluster teardown):**
```bash
./setup.sh --redeploy-flask
```

**Flask app unit tests:**
```bash
cd flask-app && python -m pytest tests/
# or run a single test:
python -m pytest tests/test_app.py::FlaskAppTests::test_get_secret_env
```

**Demo make targets (after setup completes):**
```bash
make demo-rotate-cert      # delete TLS cert, watch VSO reissue from Vault PKI, compare serials
make demo-update-secret    # write new KV secret to Vault, observe Flask /secret update in ~10s
make demo-dynamic-creds    # show ephemeral Postgres creds, force re-issuance, show new creds
make teardown              # delete the Kind cluster
```

**Targeted Terraform (after initial setup):**
```bash
terraform apply -auto-approve -target=<resource>
```

**Demo operations:**
```bash
# Inspect VSO resource status
kubectl get vaultstaticsecret example-secret -o yaml
kubectl get vaultpkisecret flask-app-cert -o yaml
kubectl get vaultdynamicsecret db-creds -o yaml

# Namespace isolation: show the flask-app tenant secret (cannot read default namespace secrets)
kubectl get secret flask-app-isolated-secret -n flask-app -o yaml
```

**Troubleshooting:**
```bash
kubectl get gateway eg -n default -o yaml
kubectl get httproute vault -n default -o yaml
kubectl logs -n envoy-gateway-system -l control-plane=envoy-gateway
```

## Architecture

### Phased Terraform bootstrap

Terraform can't run a single `apply` because the Vault provider needs Vault to be reachable before it can configure it, but Vault becomes reachable only after the Gateway NodePort service is created. `setup.sh` solves this with three targeted phases:

1. **Phase 1** — installs Helm releases only (registry, Envoy Gateway, Vault, VSO). No Vault provider calls.
2. **Phase 2** — creates the HTTP NodePort service and the `vault` HTTPRoute, making Vault reachable at `http://localhost:8080`. Also imports `vault_mount.kvv2` — Vault dev mode pre-creates the `secret/` mount, so Terraform must import it rather than create it.
3. **Phase 3** — full `terraform apply`. Vault provider can now connect; configures KV/PKI/auth, deploys VSO CRDs and the Flask app, creates the HTTPS NodePort after VSO provisions the TLS cert.

### VSO resource dependency chain

`VaultConnection` → `VaultAuth` → `VaultStaticSecret` / `VaultDynamicSecret` / `VaultPKISecret`

- **VaultConnection** (`vso.tf`): points VSO at `http://vault.default.svc:8200`.
- **VaultAuth** (`vso.tf`): binds the `default` service account to `vso-role` via the Kubernetes auth method.
- **VaultStaticSecret** (`vso.tf`): syncs `secret/data/example` → K8s Secret `k8s-secret-from-vault`. Refreshes every 10s and triggers a rollout restart on the `flask-app` deployment when the secret changes.
- **VaultDynamicSecret** (`vso.tf`): requests ephemeral Postgres credentials from `database/creds/flask-app-db-role` → K8s Secret `db-dynamic-creds`. VSO renews the Vault lease at 67% of TTL (default 1h). Deleting the K8s Secret forces immediate re-issuance. Triggers a rollout restart when credentials rotate.
- **VaultPKISecret** (`vso.tf`): issues a cert for `flask-app.default.svc` from the `pki` engine → K8s TLS Secret `flask-app-tls`. Deleting the secret forces immediate re-issuance.

### TLS certificate flow

Vault PKI engine → VSO `VaultPKISecret` → K8s Secret `flask-app-tls` → Envoy Gateway HTTPS listener → TLS termination at the gateway → plain HTTP to the Flask service.

The HTTPS NodePort service (`gateway_nodeports_https` in `gateway.tf`) is intentionally created last in Phase 3. A `data "external"` block polls until `flask-app-tls` exists and Envoy has assigned its HTTPS container port — this is required on macOS/Podman where Envoy's container port is non-deterministic.

### Dynamic port detection

`data "external" "envoy_http_port"` and `data "external" "envoy_https_port"` in `gateway.tf` use inline bash scripts to query the Envoy-managed service for its assigned container port. This avoids hardcoding ports that differ between Docker and Podman. The HTTP detection runs in Phase 2; HTTPS detection runs in Phase 3 after the cert exists.

### Dynamic secrets: Postgres + Vault database engine

`database.tf` deploys a Postgres pod and configures Vault's database secrets engine against it. Vault issues time-limited Postgres roles on demand; each credential set is unique and expires automatically. The VSO `VaultDynamicSecret` (`db-creds`) holds the active lease. The Flask app exposes `/dynamic-secret` to display the current ephemeral credentials.

Postgres is deployed in Phase 1 so it's running well before Phase 3 attempts to configure the Vault database connection. The `vault_database_secret_backend_connection` resource will verify connectivity to Postgres on creation — if it fails, check that `kubectl get pod -l app=postgres` is Running.

### Namespace isolation

`namespace.tf` provisions a `flask-app` namespace with its own `VaultConnection`, `VaultAuth`, and `VaultStaticSecret`. The Vault auth role `flask-app-role` is bound exclusively to the `flask-app` namespace service account and carries `flask-app-policy`, which only grants access to `secret/data/flask-app/*`. The `default` namespace's `vso-role` cannot authenticate as `flask-app-role`, and vice versa.

To demonstrate isolation: the `flask-app` namespace `VaultStaticSecret` successfully syncs `flask-app-isolated-secret`. Attempting to manually authenticate with `flask-app-role` from the `default` namespace SA would fail.

### Flask app secret consumption

The Flask app reads KV secrets as env vars (`SECRET_USERNAME`, `SECRET_PASSWORD`) from `k8s-secret-from-vault` and dynamic DB credentials (`DB_USERNAME`, `DB_PASSWORD`) from `db-dynamic-creds`. The DB env vars are `optional: true` in the Deployment spec — the pod starts without them and Envoy returns a 500 at `/dynamic-secret` until VSO provisions the dynamic secret. The Helm chart (`flask-app/chart/`) mounts both secrets.

## Known quirks

- `VaultStaticSecret` may show `RolloutRestartTriggeredFailed` on first sync if the `flask-app` deployment isn't ready yet. This is benign and resolves automatically.
- The `vault_mount.kvv2` Terraform resource must be imported during Phase 2 (`terraform import vault_mount.kvv2 secret`) because Vault dev mode pre-creates the `secret/` engine. `setup.sh` handles this automatically.
- Running `./setup.sh` without `--redeploy-flask` **deletes and recreates the Kind cluster**. All Terraform state for in-cluster resources is invalidated; `setup.sh` taints `null_resource.flask_image` automatically to force an image rebuild.
- The `/dynamic-secret` endpoint returns 500 if VSO hasn't yet provisioned `db-dynamic-creds`. This resolves within seconds of the Flask app starting; the `optional: true` flag on the secretKeyRef prevents the pod from going into CrashLoopBackOff while waiting.
- The `flask-app` namespace VSO resources (in `namespace.tf`) create a second `VaultConnection` and `VaultAuth` named `default` in that namespace — same names as the resources in the `default` namespace, but Kubernetes scopes them independently.

## Access points (post-setup)

| | URL | Auth |
|---|---|---|
| Vault UI | http://localhost:8080/ui/ | token: `root` |
| Flask app — KV secret | http://localhost:8080/secret | — |
| Flask app — dynamic creds | http://localhost:8080/dynamic-secret | — |
| Flask app (HTTPS) | https://localhost:8443/secret | self-signed |
| Container registry | localhost:5001 | — |
