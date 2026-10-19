#!/usr/bin/env bash
# Pods, Raft- und Replikationsstatus beider Standorte
set -euo pipefail
source scripts/lib.sh
tunnel_ensure

TOKEN=$(admin_token "$PRIMARY")
for site in "${SITES[@]}"; do
  step "Standort $site"
  kube "$site" get pods -n vault -o wide -l component=server 2>/dev/null || echo "(Cluster nicht erreichbar)"
  vault_lb "$site" "" status 2>/dev/null | grep -E 'Seal Type|Sealed|Version|HA Mode|Raft Committed' || echo "(Vault über LB nicht erreichbar)"
  vault_lb "$site" "$TOKEN" operator raft list-peers 2>/dev/null || true
  if enterprise; then
    vault_lb "$site" "" read -format=json sys/replication/dr/status 2>/dev/null | jq -c '.data | {mode, state}' || true
  fi
done
