#!/usr/bin/env bash
# HA-Demo innerhalb eines Standorts: Den Node mit dem AKTIVEN Vault-Pod in fsn1 hart
# ausschalten. Raft wählt einen neuen Leader, der LB zeigt auf den neuen aktiven Pod,
# UI und API bleiben erreichbar. kubectl läuft über den LB und reißt nicht ab.
set -euo pipefail
source scripts/lib.sh
tunnel_ensure

STATE_FILE=$SECRETS/ha-failed-node
pods() { kube "$PRIMARY" -n vault get pods -o wide -l component=server -L vault-active 2>/dev/null || echo "(kubectl gerade nicht erreichbar)"; }

case "${1:-}" in
  fail)
    step "Vor dem Ausfall"
    pods
    NODE=$(kube "$PRIMARY" -n vault get pods -l component=server,vault-active=true -o jsonpath='{.items[0].spec.nodeName}')
    echo "$NODE" > "$STATE_FILE"
    step "$NODE (aktiver Vault-Pod) wird hart ausgeschaltet"
    hcloud server poweroff "$NODE"
    OLD_POD=$(kube "$PRIMARY" -n vault get pods -l component=server,vault-active=true -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    # Bis Kubernetes den Node als NotReady erkennt (~40 s), kann der LB einzelne Anfragen
    # noch zum toten Pod schicken. Deshalb auf 3 erfolgreiche Antworten in Folge warten.
    echo "Warte auf neuen Leader und stabile Antworten über den LB …"
    ok=0; start=$SECONDS
    while (( ok < 3 && SECONDS - start < 180 )); do
      leader=$(vault_lb "$PRIMARY" "$(automation_token)" operator raft list-peers -format=json 2>/dev/null \
        | jq -r '.data.config.servers[] | select(.leader) | .node_id' || true)
      if [[ -n "$leader" && "$leader" != "$OLD_POD" ]]; then ok=$((ok + 1)); else ok=0; fi
      sleep 3
    done
    echo "Neuer Leader: ${leader:-?} (nach $((SECONDS - start)) s)"
    step "Nach dem Ausfall"
    vault_lb "$PRIMARY" "$(automation_token)" operator raft list-peers
    vault_lb "$PRIMARY" "" status | grep -E 'HA Mode|Active Node|Sealed'
    echo "UI und API unter $(lb_url "$PRIMARY")/ui/ funktionieren weiter. Zurück mit: mise run ha:node-restore"
    ;;
  restore)
    NODE=$(cat "$STATE_FILE" 2>/dev/null || echo "k3s-$PRIMARY-1")
    step "$NODE wird wieder eingeschaltet"
    hcloud server poweron "$NODE"
    node_ready() { kube "$PRIMARY" get node "$NODE" --no-headers | grep -q ' Ready'; }
    wait_for 300 "$NODE Ready" node_ready
    # War es der Node des Unseal-Vaults (Node 3), muss dieser erst entsiegelt werden
    scripts/unseal.sh "$PRIMARY"
    kube "$PRIMARY" -n vault wait --for=condition=Ready pod -l component=server --timeout=300s >/dev/null || true
    rm -f "$STATE_FILE"
    pods
    vault_lb "$PRIMARY" "$(automation_token)" operator raft list-peers
    ;;
  *) echo "Usage: $0 fail|restore"; exit 1 ;;
esac
