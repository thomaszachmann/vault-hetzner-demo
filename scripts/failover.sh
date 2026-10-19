#!/usr/bin/env bash
# DR-Failover-Demo (nur Enterprise):
#   simulate – RZ A (fsn1) fällt aus: alle k3s-Nodes in fsn1 werden hart ausgeschaltet
#   promote  – RZ B (nbg1) wird mit dem DR-Operation-Token zum Primary befördert,
#              die Fachanwendung wird auf nbg1 umgestellt
#   restore  – fsn1 kommt zurück, wird demotet und als neuer DR-Secondary an nbg1 gehängt
set -euo pipefail
source scripts/lib.sh
enterprise || { echo "DR-Failover braucht Vault Enterprise (Lizenz unter .secrets/vault.hclic)."; exit 1; }
tunnel_ensure

FSN1_NODES=$(tf_json nodes | jq -r --arg s "$PRIMARY" 'to_entries[] | select(.value.site==$s) | .key')
DR_OP=$(cat "$SECRETS/dr-operation-token")
DR_LB=$(site_lb_ip "$DR")

case "${1:-}" in
  simulate)
    step "Ausfall RZ A: alle Nodes in $PRIMARY werden ausgeschaltet"
    for n in $FSN1_NODES; do hcloud server poweroff "$n" & done; wait
    echo "$PRIMARY ist aus. $DR läuft weiter als DR-Secondary. Weiter mit: mise run failover:promote"
    ;;

  promote)
    step "$DR zum Primary befördern (DR-Operation-Batch-Token, primary_cluster_addr = LB $DR_LB:8201)"
    vault_lb "$DR" "" write sys/replication/dr/secondary/promote \
      dr_operation_token="$DR_OP" primary_cluster_addr="https://$DR_LB:8201"
    active() { vault_lb "$DR" "" read -format=json sys/replication/dr/status | jq -e '.data.mode == "primary"' >/dev/null; }
    wait_for 120 "$DR ist Primary" active
    vault_lb "$DR" "" read -format=json sys/replication/dr/status | jq -c '.data | {mode, state}'
    step "Fachanwendung auf $DR umstellen"
    scripts/app.sh "$DR"
    echo "$DR ist Primary: $(lb_url "$DR")/ui/ – alle Secrets, Policies, Namespaces und Leases sind da."
    ;;

  restore)
    step "RZ A wieder einschalten"
    for n in $FSN1_NODES; do hcloud server poweron "$n" & done; wait
    tunnel_close; tunnel_ensure
    api_up() { kube "$PRIMARY" get nodes >/dev/null; }
    wait_for 600 "Kubernetes-API $PRIMARY" api_up
    scripts/unseal.sh "$PRIMARY"
    kube "$PRIMARY" -n vault wait --for=condition=Ready pod -l component=server --timeout=600s >/dev/null
    TOKEN=$(automation_token)

    step "Alten Primary $PRIMARY demoten (verhindert Split-Brain)"
    vault_lb "$PRIMARY" "$TOKEN" write -f sys/replication/dr/primary/demote
    sleep 10

    step "$PRIMARY als DR-Secondary an den neuen Primary $DR hängen"
    WRAP=$(vault_lb "$DR" "$TOKEN" write -format=json sys/replication/dr/primary/secondary-token id="$PRIMARY" | jq -r .wrap_info.token)
    vault_lb "$PRIMARY" "" write sys/replication/dr/secondary/update-primary \
      dr_operation_token="$DR_OP" token="$WRAP" primary_api_addr="$(lb_url "$DR")" ca_file=/vault/userconfig/tls/ca.crt
    sleep 20
    scripts/status.sh
    ;;

  *)
    echo "Usage: $0 simulate|promote|restore"; exit 1 ;;
esac
