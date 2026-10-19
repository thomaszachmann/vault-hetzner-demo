#!/usr/bin/env bash
# Unseal-Vaults entsiegeln, z. B. nachdem ihr Node neu gestartet wurde.
# Die Haupt-Cluster entsiegeln sich danach selbst (Transit-Auto-Unseal).
# Aufruf: scripts/unseal.sh [fsn1|nbg1]   (ohne Argument: beide)
set -euo pipefail
source scripts/lib.sh
tunnel_ensure

for site in "${@:-${SITES[@]}}"; do
  pod_status() { kube "$site" -n vault-unseal exec vault-unseal-0 -- sh -c 'vault status -format=json || true'; }
  pod_up() { pod_status | jq -e .initialized >/dev/null; }
  wait_for 600 "Unseal-Vault $site erreichbar" pod_up
  if [[ "$(pod_status | jq -r .sealed)" == "true" ]]; then
    for k in $(jq -r '.unseal_keys_b64[:3][]' "$SECRETS/unseal-$site.json"); do
      kube "$site" -n vault-unseal exec vault-unseal-0 -- vault operator unseal "$k" >/dev/null
    done
    echo "Unseal-Vault $site entsiegelt."
  else
    echo "Unseal-Vault $site ist bereits entsiegelt."
  fi
done
