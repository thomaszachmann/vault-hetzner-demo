#!/usr/bin/env bash
# Abschluss: kurzlebiges Automatisierungs-Token erzeugen, dann alle Root-Tokens widerrufen.
# Grundsatz: Root-Tokens gehören nicht in den regulären Betrieb.
set -euo pipefail
source scripts/lib.sh
tunnel_ensure

step "Automatisierungs-Token (8h, Policy platform-automation)"
PTOKEN=$(root_token "$PRIMARY")
if [[ "$PTOKEN" != "REVOKED" ]]; then
  vault_lb "$PRIMARY" "$PTOKEN" token create -format=json -orphan -ttl=8h -explicit-max-ttl=8h \
    -policy=platform-automation -display-name=platform-automation | jq -r .auth.client_token > "$SECRETS/automation-token"
  chmod 600 "$SECRETS/automation-token"
fi

step "Root-Tokens widerrufen"
revoke_in_file() { # revoke_in_file <datei> <revoke-befehl…>
  local file=$1; shift
  local t; t=$(jq -r .root_token "$file")
  [[ "$t" == "REVOKED" ]] && return 0
  "$@" "$t" || true   # DR-Secondary: Root-Token durch Replikation bereits ungültig
  jq '.root_token = "REVOKED"' "$file" > "$file.tmp" && mv "$file.tmp" "$file" && chmod 600 "$file"
  echo "  widerrufen: $file"
}
for site in "${SITES[@]}"; do
  revoke_lb()     { vault_lb "$site" "$1" token revoke -self >/dev/null 2>&1; }
  revoke_unseal() { kube "$site" -n vault-unseal exec vault-unseal-0 -- env VAULT_TOKEN="$1" vault token revoke -self >/dev/null 2>&1; }
  revoke_in_file "$SECRETS/init-$site.json" revoke_lb
  revoke_in_file "$SECRETS/unseal-$site.json" revoke_unseal
done
echo "Neues Root-Token nur noch per 'vault operator generate-root' mit Quorum der Recovery-Keys."
