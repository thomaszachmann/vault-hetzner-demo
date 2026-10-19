#!/usr/bin/env bash
# Vault-Plattform eines Standorts im k3s-Cluster aufbauen (idempotent):
#   1. Unseal-Vault (HSM-Stellvertreter) installieren, initialisieren, Transit-Schlüssel anlegen
#   2. Vault-Cluster (3 Pods, Raft) installieren und initialisieren – entsiegelt sich selbst
#   3. NodePort-Service für den internen Hetzner-LB, Service-Account für Kubernetes Auth
# Aufruf: scripts/platform.sh fsn1|nbg1
set -euo pipefail
source scripts/lib.sh

SITE=${1:?Standort angeben: fsn1 oder nbg1}
tunnel_ensure

if enterprise; then
  VAULT_IMAGE=hashicorp/vault-enterprise
  VAULT_IMAGE_TAG="${VAULT_VERSION}-ent"
else
  VAULT_IMAGE=hashicorp/vault
  VAULT_IMAGE_TAG="${VAULT_VERSION}"
fi
export SITE VAULT_VERSION VAULT_IMAGE VAULT_IMAGE_TAG

step "[$SITE] Namespaces und Secrets"
kube_ns "$SITE" vault vault-unseal monitoring
kube_secret "$SITE" vault vault-tls generic \
  --from-file=tls.crt="$SECRETS/pki/vault-$SITE.crt" --from-file=tls.key="$SECRETS/pki/vault-$SITE.key" \
  --from-file=ca.crt="$SECRETS/ca/root-ca.pem"
kube_secret "$SITE" vault-unseal vault-unseal-tls generic \
  --from-file=tls.crt="$SECRETS/pki/unseal-$SITE.crt" --from-file=tls.key="$SECRETS/pki/unseal-$SITE.key" \
  --from-file=ca.crt="$SECRETS/ca/root-ca.pem"
for ns in vault monitoring; do
  kube_secret "$SITE" "$ns" root-ca generic --from-file=ca.crt="$SECRETS/ca/root-ca.pem"
done
if enterprise; then
  kube_secret "$SITE" vault vault-license generic --from-file=license="$SECRETS/vault.hclic"
fi

# ---------------------------------------------------------------------------
step "[$SITE] Unseal-Vault (Transit, HSM-Stellvertreter)"
helm_site "$SITE" upgrade --install vault-unseal vault --repo "$CHART_REPO" --version "$VAULT_CHART_VERSION" \
  -n vault-unseal -f "$(render k8s/vault/values-unseal.yaml SITE VAULT_VERSION)" >/dev/null
useal() { kube "$SITE" -n vault-unseal exec vault-unseal-0 -- "$@"; }
status_json() { useal sh -c 'vault status -format=json || true'; }
# `vault status`: Exit 0 = entsiegelt, 2 = versiegelt, 1 = Fehler/nicht erreichbar
responds() { local rc=0; kube "$SITE" -n "$1" exec "$2" -c vault -- vault status >/dev/null 2>&1 || rc=$?; [[ $rc -eq 0 || $rc -eq 2 ]]; }
wait_for 300 "Unseal-Vault-Pod antwortet" responds vault-unseal vault-unseal-0

if [[ "$(status_json | jq -r .initialized)" != "true" ]]; then
  useal vault operator init -key-shares=5 -key-threshold=3 -format=json > "$SECRETS/unseal-$SITE.json"
  chmod 600 "$SECRETS/unseal-$SITE.json"
fi
if [[ "$(status_json | jq -r .sealed)" == "true" ]]; then
  for k in $(jq -r '.unseal_keys_b64[:3][]' "$SECRETS/unseal-$SITE.json"); do
    useal vault operator unseal "$k" >/dev/null
  done
fi

if ! kube "$SITE" -n vault get secret vault-transit-token >/dev/null 2>&1; then
  UROOT=$(jq -r .root_token "$SECRETS/unseal-$SITE.json")
  uv() { kube "$SITE" -n vault-unseal exec -i vault-unseal-0 -- env VAULT_TOKEN="$UROOT" vault "$@"; }
  uv secrets enable transit >/dev/null 2>&1 || true
  uv write -f transit/keys/autounseal >/dev/null
  uv policy write autounseal - >/dev/null <<'EOF'
path "transit/encrypt/autounseal" { capabilities = ["update"] }
path "transit/decrypt/autounseal" { capabilities = ["update"] }
EOF
  TRANSIT_TOKEN=$(uv token create -orphan -policy=autounseal -period=24h -display-name="seal-$SITE" -format=json | jq -r .auth.client_token)
  kube_secret "$SITE" vault vault-transit-token generic --from-literal=token="$TRANSIT_TOKEN"
fi

# ---------------------------------------------------------------------------
step "[$SITE] Vault-Cluster (3 Pods, Raft, Auto-Unseal) – $VAULT_IMAGE:$VAULT_IMAGE_TAG"
LICENSE_ARGS=()
enterprise && LICENSE_ARGS=(--set server.enterpriseLicense.secretName=vault-license --set server.enterpriseLicense.secretKey=license)
helm_site "$SITE" upgrade --install vault vault --repo "$CHART_REPO" --version "$VAULT_CHART_VERSION" \
  -n vault -f "$(render k8s/vault/values-vault.yaml SITE VAULT_IMAGE VAULT_IMAGE_TAG)" "${LICENSE_ARGS[@]}" >/dev/null

vpod() { kube "$SITE" -n vault exec "$1" -c vault -- sh -c 'vault status -format=json || true'; }
wait_for 300 "vault-0 antwortet" responds vault vault-0

if [[ "$(vpod vault-0 | jq -r .initialized)" != "true" ]]; then
  kube "$SITE" -n vault exec vault-0 -c vault -- vault operator init \
    -recovery-shares=5 -recovery-threshold=3 -format=json > "$SECRETS/init-$SITE.json"
  chmod 600 "$SECRETS/init-$SITE.json"
fi

echo "Warte, bis alle 3 Pods entsiegelt und bereit sind …"
kube "$SITE" -n vault wait --for=condition=Ready pod -l app.kubernetes.io/name=vault,component=server --timeout=600s >/dev/null

TOKEN=$(admin_token "$SITE")
for _ in $(seq 1 30); do
  VOTERS=$(vault_pod "$SITE" vault vault-0 "$TOKEN" operator raft list-peers -format=json 2>/dev/null \
    | jq '[.data.config.servers[] | select(.voter)] | length' || echo 0)
  [[ "$VOTERS" == "3" ]] && break
  sleep 5
done
vault_pod "$SITE" vault vault-0 "$TOKEN" operator raft list-peers || true

# ---------------------------------------------------------------------------
step "[$SITE] LB-Service (NodePort 30200/30201) und Kubernetes-Auth-Service-Account"
kube "$SITE" apply -f k8s/vault/lb-service.yaml >/dev/null
reviewer_ready() { kube "$SITE" -n vault get secret vault-auth-token -o jsonpath='{.data.token}' | grep -q .; }
wait_for 60 "Reviewer-Token erzeugt" reviewer_ready
kube "$SITE" -n vault get secret vault-auth-token -o jsonpath='{.data.token}' | base64 -d > "$SECRETS/k8s-$SITE-reviewer.jwt"
kube "$SITE" -n vault get secret vault-auth-token -o jsonpath='{.data.ca\.crt}' | base64 -d > "$SECRETS/k8s-$SITE-ca.crt"
chmod 600 "$SECRETS/k8s-$SITE-reviewer.jwt"

echo "[$SITE] fertig."
