#!/usr/bin/env bash
# SSH über die Bastion: mise run ssh k3s-fsn1-1 | services | bastion
set -euo pipefail
source scripts/lib.sh

HOST=${1:?Host angeben, z. B. k3s-fsn1-1, services oder bastion}
shift || true
case "$HOST" in
  bastion)  exec ssh "${SSH_OPTS[@]}" "root@$(bastion_ip)" "$@" ;;
  services) IP=$(tf_out services_ip) ;;
  *)        IP=$(tf_json nodes | jq -r --arg n "$HOST" '.[$n].ip // empty') ;;
esac
[[ -n "${IP:-}" ]] || { echo "Unbekannter Host: $HOST"; exit 1; }
exec ssh "${SSH_OPTS[@]}" -o ProxyCommand="ssh ${SSH_OPTS[*]} -W %h:%p root@$(bastion_ip)" "root@$IP" "$@"
