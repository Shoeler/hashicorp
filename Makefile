SHELL := /bin/bash

.PHONY: setup setup-ha redeploy-app teardown \
        demo-rotate-cert demo-update-secret demo-dynamic-creds demo-namespace-isolation

CLUSTER_NAME := vault-demo

# Full cluster teardown + rebuild — Vault in dev mode (ephemeral, pre-initialized, token=root)
setup:
	./setup.sh

# Full cluster teardown + rebuild — Vault in standalone mode (Raft storage, init/unseal required)
# Init credentials are saved to vault-init.json (git-ignored)
setup-ha:
	./setup.sh --mode=standalone

# Rebuild and redeploy only the Flask app — leaves cluster and Vault state intact
redeploy-app:
	./setup.sh --redeploy-flask

# Delete the Kind cluster
teardown:
	kind delete cluster --name $(CLUSTER_NAME)

# Show current TLS cert serial, force VSO to reissue from Vault, confirm serial changed
demo-rotate-cert:
	@BEFORE=$$(echo | openssl s_client -showcerts -connect 127.0.0.1:8443 2>/dev/null \
	  | openssl x509 -noout -serial 2>/dev/null); \
	echo ""; \
	echo "==> Current TLS certificate serial: $$BEFORE"; \
	echo ""; \
	echo "==> Deleting flask-app-tls — VSO will request a new cert from Vault PKI..."; \
	kubectl delete secret flask-app-tls; \
	echo "==> Waiting for VSO to reissue..."; \
	for i in $$(seq 1 30); do \
	  kubectl get secret flask-app-tls >/dev/null 2>&1 && break; \
	  printf "."; sleep 1; \
	done; echo ""; \
	AFTER=$$(echo | openssl s_client -showcerts -connect 127.0.0.1:8443 2>/dev/null \
	  | openssl x509 -noout -serial 2>/dev/null); \
	echo "==> New TLS certificate serial:     $$AFTER"; \
	echo ""; \
	[ "$$BEFORE" != "$$AFTER" ] \
	  && echo "Rotation confirmed — serial changed." \
	  || echo "WARNING: serial unchanged — Gateway may need a moment to reload."

# Update KV secret in Vault, watch VSO sync it to the pod within ~10s
demo-update-secret:
	@NEW_USER="demo-$$(date +%s)"; \
	NEW_PASS="rotated-$$(date +%H%M%S)"; \
	echo ""; \
	echo "==> Current /secret response:"; \
	curl -s http://localhost:8080/secret | python3 -m json.tool; \
	echo ""; \
	echo "==> Writing new credentials to Vault (username=$$NEW_USER)..."; \
	VAULT_TOKEN=$$([ -f vault-init.json ] \
	  && python3 -c "import json; print(json.load(open('vault-init.json'))['root_token'])" \
	  || echo "root"); \
	kubectl exec vault-0 -- env VAULT_TOKEN=$$VAULT_TOKEN vault kv put secret/example \
	  username=$$NEW_USER password=$$NEW_PASS; \
	echo ""; \
	echo "==> Waiting 12s for VSO to sync (refreshAfter=10s)..."; \
	sleep 12; \
	echo "==> Updated /secret response:"; \
	curl -s http://localhost:8080/secret | python3 -m json.tool

# Show ephemeral DB credentials, query Postgres, force rotation, confirm new credentials
demo-dynamic-creds:
	@echo ""; \
	echo "==> K8s Secret 'db-dynamic-creds' (as synced by VSO):"; \
	kubectl get secret db-dynamic-creds \
	  -o custom-columns=\
	NAME:.metadata.name,\
	CREATED:.metadata.creationTimestamp,\
	MANAGED-BY:.metadata.labels."app\.kubernetes\.io/managed-by"; \
	echo ""; \
	echo "==> Decoded credentials:"; \
	echo "    username: $$(kubectl get secret db-dynamic-creds \
	  -o jsonpath='{.data.username}' | base64 --decode)"; \
	echo "    password: $$(kubectl get secret db-dynamic-creds \
	  -o jsonpath='{.data.password}' | base64 --decode)"; \
	echo ""; \
	echo "==> Querying Postgres via /db-query (pre-rotation):"; \
	curl -s http://localhost:8080/db-query | python3 -m json.tool; \
	echo ""; \
	echo "==> Forcing rotation — deleting 'db-dynamic-creds'..."; \
	kubectl delete secret db-dynamic-creds; \
	echo "==> Waiting for VSO to request a new lease from Vault..."; \
	for i in $$(seq 1 30); do \
	  kubectl get secret db-dynamic-creds >/dev/null 2>&1 && break; \
	  printf "."; sleep 1; \
	done; echo ""; \
	echo "==> K8s Secret 'db-dynamic-creds' (re-issued by VSO):"; \
	kubectl get secret db-dynamic-creds \
	  -o custom-columns=\
	NAME:.metadata.name,\
	CREATED:.metadata.creationTimestamp,\
	MANAGED-BY:.metadata.labels."app\.kubernetes\.io/managed-by"; \
	echo ""; \
	echo "==> New decoded credentials (different Postgres role):"; \
	echo "    username: $$(kubectl get secret db-dynamic-creds \
	  -o jsonpath='{.data.username}' | base64 --decode)"; \
	echo "    password: $$(kubectl get secret db-dynamic-creds \
	  -o jsonpath='{.data.password}' | base64 --decode)"; \
	echo ""; \
	echo "==> Waiting for rollout restart triggered by VSO..."; \
	kubectl rollout status deployment/flask-app --timeout=60s; \
	echo ""; \
	echo "==> Querying Postgres via /db-query (post-rotation — new Vault role):"; \
	for i in $$(seq 1 15); do \
	  BODY=$$(curl -sf http://localhost:8080/db-query 2>/dev/null); \
	  [ -n "$$BODY" ] && echo "$$BODY" | python3 -m json.tool && break; \
	  printf "."; sleep 1; \
	done; echo ""; \
	echo "The 'connected_as' field confirms the pod is using the rotated credential."

# Demonstrate namespace isolation: show the flask-app tenant secret and compare auth roles
demo-namespace-isolation:
	@echo ""; \
	echo "==> flask-app namespace VaultAuth (uses flask-app-role — scoped to flask-app/* only):"; \
	kubectl get vaultauth default -n flask-app \
	  -o jsonpath='    role: {.spec.kubernetes.role}{"\n"}    serviceAccount: {.spec.kubernetes.serviceAccount}{"\n"}'; \
	echo ""; \
	echo "==> default namespace VaultAuth (uses vso-role — access to all engines):"; \
	kubectl get vaultauth default -n default \
	  -o jsonpath='    role: {.spec.kubernetes.role}{"\n"}    serviceAccount: {.spec.kubernetes.serviceAccount}{"\n"}'; \
	echo ""; \
	echo "==> flask-app-isolated-secret (synced from secret/flask-app/config — flask-app ns only):"; \
	kubectl get secret flask-app-isolated-secret -n flask-app \
	  -o jsonpath='{.data}' \
	  | python3 -c "import sys,json,base64; d=json.load(sys.stdin); [print(f'    {k}: {base64.b64decode(v).decode()}') for k,v in d.items() if k != '_raw']"; \
	echo ""; \
	echo "The flask-app-role cannot read secret/example or issue PKI/database creds."
