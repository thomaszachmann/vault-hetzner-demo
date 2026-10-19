#!/usr/bin/env bash
# Disaster-Recovery-Replication fsn1 (Primary) → nbg1 (Secondary). Nur Enterprise.
# Der Secondary übernimmt den kompletten Datenbestand des Primary – auch dessen
# Recovery-Keys und Tokens; sein eigenes Root-Token wird ungültig.
# Die Cluster erreichen sich nur über die internen LBs (Pod-IPs sind nicht routbar),
# deshalb wird primary_cluster_addr explizit auf den LB gesetzt.
set -euo pipefail
source scripts/lib.sh
enterprise || { echo "DR-Replication braucht Vault Enterprise."; exit 0; }
tunnel_ensure

PTOKEN=$(admin_token "$PRIMARY")
STOKEN=$(admin_token "$DR")
P_LB=$(site_lb_ip "$PRIMARY")

mode() { vault_lb "$1" "" read -format=json sys/replication/dr/status | jq -r .data.mode; }

step "DR-Primary $PRIMARY aktivieren (primary_cluster_addr = LB $P_LB:8201)"
if [[ "$(mode "$PRIMARY")" == "disabled" ]]; then
  vault_lb "$PRIMARY" "$PTOKEN" write -f sys/replication/dr/primary/enable primary_cluster_addr="https://$P_LB:8201"
  healthy() { vault_lb "$PRIMARY" "" status >/dev/null; }
  sleep 10; wait_for 120 "Primary wieder aktiv" healthy
fi

step "DR-Secondary $DR aktivieren"
if [[ "$(mode "$DR")" == "disabled" ]]; then
  WRAP=$(vault_lb "$PRIMARY" "$PTOKEN" write -format=json sys/replication/dr/primary/secondary-token id="$DR" | jq -r .wrap_info.token)
  vault_lb "$DR" "$STOKEN" write sys/replication/dr/secondary/enable token="$WRAP" \
    primary_api_addr="$(lb_url "$PRIMARY")" ca_file=/vault/userconfig/tls/ca.crt
fi

streaming() {
  vault_lb "$DR" "" read -format=json sys/replication/dr/status \
    | jq -e '.data.mode == "secondary" and (.data.state == "stream-wals")' >/dev/null
}
wait_for 300 "Replikation im Zustand stream-wals" streaming
vault_lb "$DR" "" read -format=json sys/replication/dr/status | jq -c '.data | {mode, state, primaries: [.primaries[]?.api_address]}'

step "DR-Operation-Batch-Token (24h, darf nur befördern)"
# Policy dr-secondary-promotion legt terraform/vault-config an
vault_lb "$PRIMARY" "$PTOKEN" token create -format=json -orphan -type=batch -ttl=24h \
  -policy=dr-secondary-promotion -display-name=dr-operation | jq -r .auth.client_token > "$SECRETS/dr-operation-token"
chmod 600 "$SECRETS/dr-operation-token"
echo "Gespeichert: $SECRETS/dr-operation-token"
