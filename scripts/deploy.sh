#!/usr/bin/env bash
# Baut die komplette Demo-Umgebung auf (idempotent, ca. 20 Minuten).
set -euo pipefail
source scripts/lib.sh
mkdir -p "$SECRETS/logs"

START=$SECONDS
scripts/setup.sh
echo "Edition: $(enterprise && echo Enterprise || echo Community)"

step "1/8 Infrastruktur (Terraform → Hetzner Cloud)"
MY_IP=$(curl -4 -fsS --max-time 10 https://api.ipify.org)
echo "SSH/WireGuard nur von $MY_IP erlaubt"
terraform -chdir=terraform/infra init -input=false >/dev/null
terraform -chdir=terraform/infra apply -auto-approve -input=false \
  -var "ssh_public_key_path=$SSH_KEY.pub" \
  -var "admin_cidrs=[\"$MY_IP/32\"]" \
  -var "k3s_version=$K3S_VERSION"

step "2/8 Bastion und WireGuard"
BASTION=$(bastion_ip)
bastion_ready() { ssh "${SSH_OPTS[@]}" "root@$BASTION" test -f /root/wireguard-client.conf; }
wait_for 600 "Bastion bereit (cloud-init)" bastion_ready
mkdir -p "$SECRETS/wireguard"
ssh "${SSH_OPTS[@]}" "root@$BASTION" cat /root/wireguard-client.conf > "$SECRETS/wireguard/vault-demo.conf"
chmod 600 "$SECRETS/wireguard/vault-demo.conf"
tunnel_close
tunnel_ensure

step "3/8 Externe Dienste auf der Dienste-VM (Ansible, läuft parallel)"
ANSIBLE_LOG="$SECRETS/logs/ansible-services.log"
ansible-playbook ansible/services.yml > "$ANSIBLE_LOG" 2>&1 &
ANSIBLE_PID=$!
echo "Log: $ANSIBLE_LOG"

step "4/8 k3s-Cluster abwarten und kubeconfig holen"
for site in "${SITES[@]}"; do
  API_IP=$(tf_json nodes | jq -r --arg s "$site" 'to_entries[] | select(.value.site==$s and .value.index==1) | .value.ip')
  k3s_ready() { on_host "$API_IP" "k3s kubectl get nodes --no-headers 2>/dev/null | grep -c ' Ready' | grep -qx 3"; }
  wait_for 900 "k3s-Cluster $site mit 3 Ready-Nodes" k3s_ready
  on_host "$API_IP" cat /etc/rancher/k3s/k3s.yaml \
    | sed -e "s#https://127.0.0.1:6443#https://127.0.0.1:${API_PORT[$site]}#" -e "s#: default\$#: $site#" \
    > "$SECRETS/kubeconfig-$site"
  chmod 600 "$SECRETS/kubeconfig-$site"
  kube "$site" get nodes -o wide
done

step "5/8 Vault-Plattform je Standort (Helm)"
for site in "${SITES[@]}"; do
  scripts/platform.sh "$site"
done

step "6/8 Monitoring-Agent (Alloy) in beiden Clustern"
export SERVICES_IP SITE
SERVICES_IP=$(tf_out services_ip)
for SITE in "${SITES[@]}"; do
  kube "$SITE" apply -f "$(render k8s/monitoring/alloy.yaml SITE SERVICES_IP)" >/dev/null
done

echo "Warte auf Ansible (Dienste-VM) …"
if ! wait "$ANSIBLE_PID"; then
  tail -40 "$ANSIBLE_LOG"; echo "Ansible fehlgeschlagen – siehe $ANSIBLE_LOG"; exit 1
fi
grep -A3 "PLAY RECAP" "$ANSIBLE_LOG" | tail -2

step "7/8 Vault konfigurieren (Terraform → Vault $PRIMARY)"
export VAULT_TOKEN
VAULT_TOKEN=$(admin_token "$PRIMARY")
terraform -chdir=terraform/vault-config init -input=false >/dev/null
terraform -chdir=terraform/vault-config apply -auto-approve -input=false \
  -var "enterprise=$(enterprise && echo true || echo false)" \
  -var "vault_addr=https://127.0.0.1:${VAULT_PORT[$PRIMARY]}" \
  -var "k8s_host=https://$(tf_json nodes | jq -r --arg s "$APP_SITE" 'to_entries[] | select(.value.site==$s and .value.index==1) | .value.ip'):6443"
terraform -chdir=terraform/vault-config output -raw breakglass_password > "$SECRETS/passwords/breakglass"
chmod 600 "$SECRETS/passwords/breakglass"
unset VAULT_TOKEN

step "8/8 Fachanwendung, DR-Replication, Root-Tokens widerrufen"
scripts/app.sh
if enterprise; then
  scripts/dr.sh
else
  echo "DR-Replication übersprungen (Community Edition – Enterprise-Feature)"
fi
scripts/finalize.sh

echo
echo "Fertig in $(( (SECONDS - START) / 60 )) Minuten."
scripts/urls.sh
