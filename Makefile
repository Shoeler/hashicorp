SHELL := /bin/bash

.PHONY: setup teardown demo-rotate-cert demo-update-secret demo-dynamic-creds

CLUSTER_NAME := vault-demo

setup:
	./setup.sh

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
	kubectl exec vault-0 -- vault kv put secret/example \
	  username=$$NEW_USER password=$$NEW_PASS; \
	echo ""; \
	echo "==> Waiting 12s for VSO to sync (refreshAfter=10s)..."; \
	sleep 12; \
	echo "==> Updated /secret response:"; \
	curl -s http://localhost:8080/secret | python3 -m json.tool

# Show ephemeral DB credentials, force rotation, confirm new credentials issued
demo-dynamic-creds:
	@echo ""; \
	echo "==> Current dynamic database credentials (Vault-issued, TTL=1h):"; \
	echo "    username: $$(kubectl get secret db-dynamic-creds \
	  -o jsonpath='{.data.username}' | base64 --decode)"; \
	echo "    password: $$(kubectl get secret db-dynamic-creds \
	  -o jsonpath='{.data.password}' | base64 --decode)"; \
	echo ""; \
	echo "==> Deleting secret — VSO requests a fresh lease from Vault..."; \
	kubectl delete secret db-dynamic-creds; \
	echo "==> Waiting for new credentials..."; \
	for i in $$(seq 1 30); do \
	  kubectl get secret db-dynamic-creds >/dev/null 2>&1 && break; \
	  printf "."; sleep 1; \
	done; echo ""; \
	echo "==> New dynamic database credentials:"; \
	echo "    username: $$(kubectl get secret db-dynamic-creds \
	  -o jsonpath='{.data.username}' | base64 --decode)"; \
	echo "    password: $$(kubectl get secret db-dynamic-creds \
	  -o jsonpath='{.data.password}' | base64 --decode)"; \
	echo ""; \
	echo "Each issuance creates a unique Postgres role — no shared long-lived passwords."
