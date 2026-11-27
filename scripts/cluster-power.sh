#!/usr/bin/env bash
# Stop or start the demo cluster without destroying it.
#
#   scripts/cluster-power.sh stop    # stop the Kind node (and the Podman machine, if idle)
#   scripts/cluster-power.sh start   # start it again, unseal Vault, repair Postgres if needed
#
# Vault data survives only in standalone mode (make setup-ha): it lives on a PersistentVolume
# inside the Kind node container, and Vault is unsealed again with the key in vault-init.json.
# Dev mode (make setup) keeps Vault in memory, so a stop loses it — run `make setup` afterwards.
set -euo pipefail

cd "$(dirname "$0")/.."

CLUSTER_NAME="vault-demo"
NODE="${CLUSTER_NAME}-control-plane"

say()  { printf '==> %s\n' "$*"; }
ok()   { printf '    [ok] %s\n' "$*"; }
note() { printf '    [..] %s\n' "$*"; }
fail() { printf '    [error] %s\n' "$*" >&2; exit 1; }

kubectl() { command kubectl --context "kind-${CLUSTER_NAME}" "$@"; }

# Name of a Podman machine that exists on this host ("" on Linux, where Podman runs natively).
podman_machine() {
  command -v podman >/dev/null 2>&1 || return 0
  podman machine list --noheading --format '{{.Name}}' 2>/dev/null | head -1 | tr -d '*'
}

podman_machine_running() {
  podman machine list --noheading --format '{{.Running}}' 2>/dev/null | head -1 | grep -qi true
}

init_value() { # init_value <python expression over d>
  python3 -c "import json; d=json.load(open('vault-init.json')); print($1)"
}

stop() {
  RUNTIME=$(scripts/container-runtime.sh) || fail "no running container runtime found — nothing to stop."

  "$RUNTIME" container inspect "$NODE" >/dev/null 2>&1 \
    || fail "container $NODE does not exist. Create the cluster with 'make setup-ha' first."

  if [ ! -f vault-init.json ]; then
    note "No vault-init.json: Vault is in dev mode (in-memory). Its data will NOT survive this stop."
    note "After 'make start', run 'make setup' to rebuild it. Use 'make setup-ha' for a Vault that survives."
  fi

  say "Stopping Kind node $NODE ($RUNTIME)"
  "$RUNTIME" stop "$NODE" >/dev/null
  ok "node stopped — cluster and Vault data are kept inside the stopped container"

  if [ "$RUNTIME" = "podman" ] && [ -n "$(podman_machine)" ] && podman_machine_running; then
    OTHERS=$(podman ps --format '{{.Names}}' | grep -vx "$NODE" || true)
    if [ -n "$OTHERS" ]; then
      note "Podman machine left running: other containers are still up ($(echo "$OTHERS" | tr '\n' ' '))"
    else
      say "Stopping Podman machine"
      podman machine stop >/dev/null
      ok "Podman machine stopped"
    fi
  fi

  echo ""
  echo "Stopped. Bring it back with: make start"
  echo "Do NOT run 'make setup', 'make setup-ha' or 'make teardown' in between — they delete the cluster."
}

start() {
  # The Podman machine may be stopped, in which case runtime detection fails until it is started.
  if ! RUNTIME=$(scripts/container-runtime.sh); then
    if [ -n "$(podman_machine)" ]; then
      say "Starting Podman machine"
      podman machine start >/dev/null
      ok "Podman machine started"
      RUNTIME=$(scripts/container-runtime.sh) || fail "podman is still not responding after 'podman machine start'."
    else
      fail "no usable container runtime found (need a working podman or docker)."
    fi
  fi

  "$RUNTIME" container inspect "$NODE" >/dev/null 2>&1 \
    || fail "container $NODE does not exist — the cluster was deleted. Run 'make setup-ha' to create it."

  say "Starting Kind node $NODE ($RUNTIME)"
  "$RUNTIME" start "$NODE" >/dev/null
  ok "node container started"

  say "Waiting for the Kubernetes API"
  for i in $(seq 1 60); do
    kubectl get --raw /readyz >/dev/null 2>&1 && break
    [ "$i" = 60 ] && fail "Kubernetes API not ready after 5 minutes. Check: $RUNTIME logs $NODE"
    sleep 5
  done
  kubectl wait --for=condition=Ready node --all --timeout=180s >/dev/null
  ok "API server and node are ready"

  if [ ! -f vault-init.json ]; then
    echo ""
    note "No vault-init.json: Vault ran in dev mode (in-memory), so its secrets and config are gone."
    note "Run 'make setup' (or 'make setup-ha' for a Vault that survives restarts) to rebuild."
    exit 0
  fi

  say "Unsealing Vault"
  # `vault status` exits 0 when unsealed, 2 when sealed, anything else while the pod restarts.
  STATUS=1
  for i in $(seq 1 60); do
    STATUS=0
    kubectl exec vault-0 -- vault status >/dev/null 2>&1 || STATUS=$?
    { [ "$STATUS" = 0 ] || [ "$STATUS" = 2 ]; } && break
    [ "$i" = 60 ] && fail "vault-0 did not come up after 5 minutes. Check: kubectl --context kind-${CLUSTER_NAME} describe pod vault-0"
    sleep 5
  done
  if [ "$STATUS" = 2 ]; then
    kubectl exec vault-0 -- vault operator unseal "$(init_value "d['unseal_keys_b64'][0]")" >/dev/null
    ok "Vault unsealed with the key from vault-init.json"
  else
    ok "Vault is already unsealed"
  fi

  say "Waiting for workloads"
  kubectl wait --for=condition=Ready pod/vault-0 --timeout=120s >/dev/null
  for d in postgres vault-secrets-operator-controller-manager flask-app; do
    kubectl rollout status "deployment/$d" --timeout=180s >/dev/null
  done
  ok "vault, postgres, vault-secrets-operator and flask-app are running"

  # Envoy comes back a little after the pods do; Terraform (below) and the UI need this route.
  CODE=000
  for i in $(seq 1 60); do
    CODE=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/v1/sys/health || true)
    [ "$CODE" = 200 ] && break
    sleep 3
  done
  [ "$CODE" = 200 ] || fail "Vault is not reachable at http://localhost:8080 (HTTP $CODE). Check: kubectl --context kind-${CLUSTER_NAME} get pods -n envoy-gateway-system"
  ok "Vault is reachable through the Gateway at http://localhost:8080"

  # Postgres has no persistent volume: a restart wipes the products table and the roles
  # Vault created. Re-seed it and make VSO request fresh dynamic credentials.
  TABLE=""
  for i in $(seq 1 30); do
    if TABLE=$(kubectl exec deployment/postgres -- psql -U postgres -d app -tAc \
      "SELECT to_regclass('public.products')" 2>/dev/null); then
      break
    fi
    [ "$i" = 30 ] && fail "Postgres is not accepting connections."
    sleep 2
  done
  if [ -z "$TABLE" ]; then
    say "Repairing Postgres (its data does not survive a restart)"
    export TF_VAR_vault_mode="standalone"
    export TF_VAR_container_runtime="$RUNTIME"
    TF_VAR_vault_dev_token="$(init_value "d['root_token']")"
    export TF_VAR_vault_dev_token
    terraform apply -auto-approve -input=false \
      -replace=null_resource.seed_postgres -target=null_resource.seed_postgres >/dev/null
    ok "products table re-seeded"
    kubectl delete secret db-dynamic-creds --ignore-not-found >/dev/null
    for i in $(seq 1 60); do
      kubectl get secret db-dynamic-creds >/dev/null 2>&1 && break
      [ "$i" = 60 ] && fail "VSO did not re-issue db-dynamic-creds. Check: kubectl --context kind-${CLUSTER_NAME} get vaultdynamicsecret db-creds -o yaml"
      sleep 2
    done
    kubectl rollout status deployment/flask-app --timeout=120s >/dev/null
    ok "new dynamic database credentials issued by Vault"
  else
    ok "Postgres data is intact"
  fi

  say "Checking endpoints"
  for path in /secret /db-query; do
    CODE=000
    for i in $(seq 1 30); do
      CODE=$(curl -s -o /dev/null -w "%{http_code}" "http://localhost:8080${path}" || true)
      [ "$CODE" = 200 ] && break
      sleep 3
    done
    [ "$CODE" = 200 ] || fail "http://localhost:8080${path} returned HTTP $CODE"
    ok "http://localhost:8080${path} -> HTTP 200"
  done

  echo ""
  echo "Started. Vault UI: http://localhost:8080/ui/   token: root_token in vault-init.json"
}

case "${1:-}" in
  stop)  stop ;;
  start) start ;;
  *) echo "usage: $0 stop|start" >&2; exit 2 ;;
esac
