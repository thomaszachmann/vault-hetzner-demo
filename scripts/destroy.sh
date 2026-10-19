#!/usr/bin/env bash
# Löscht ALLE Hetzner-Ressourcen der Demo und die Laufzeit-Secrets.
# Erhalten bleiben: Offline-Root-CA (.secrets/ca) und die Lizenz (.secrets/vault.hclic).
set -euo pipefail
source scripts/lib.sh

if [[ "${1:-}" != "-y" ]]; then
  read -r -p "Alle Server, Load Balancer und Netze im Projekt löschen? [j/N] " answer
  [[ "$answer" =~ ^[jJyY]$ ]] || { echo "Abgebrochen."; exit 1; }
fi

tunnel_close

step "Hetzner-Ressourcen löschen (Terraform)"
terraform -chdir=terraform/infra init -input=false >/dev/null
terraform -chdir=terraform/infra destroy -auto-approve -input=false \
  -var "ssh_public_key_path=$SSH_KEY.pub"

step "Vault-Konfigurationsstand und Laufzeit-Secrets entfernen"
rm -f terraform/vault-config/terraform.tfstate terraform/vault-config/terraform.tfstate.backup
rm -rf "$SECRETS"/init-*.json "$SECRETS"/unseal-*.json "$SECRETS"/automation-token "$SECRETS"/dr-operation-token \
       "$SECRETS"/pki "$SECRETS"/wireguard "$SECRETS"/kubeconfig-* "$SECRETS"/k8s-* "$SECRETS"/render \
       "$SECRETS"/passwords "$SECRETS"/logs "$CONTROL_DIR"
rm -f ansible/inventory.yml

step "Kontrolle: verbliebene Ressourcen im Projekt"
LEFT=$( { hcloud server list -o noheader; hcloud load-balancer list -o noheader; \
          hcloud network list -o noheader; hcloud primary-ip list -o noheader; \
          hcloud volume list -o noheader; } 2>/dev/null | grep -v '^$' || true)
if [[ -n "$LEFT" ]]; then
  echo "ACHTUNG – noch vorhanden:"; echo "$LEFT"; exit 1
fi
echo "Nichts mehr vorhanden – es fallen keine Kosten mehr an."
