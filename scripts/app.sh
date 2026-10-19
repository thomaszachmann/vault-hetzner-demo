#!/usr/bin/env bash
# Fachanwendung im Anwendungs-Cluster (nbg1): Vault Agent Injector + Deployment,
# Anmeldung per Kubernetes Auth, dynamische PostgreSQL-Zugänge.
# Aufruf: scripts/app.sh [vault-standort]   (Standard: aktueller Primary fsn1)
set -euo pipefail
source scripts/lib.sh
tunnel_ensure

TARGET=${1:-$PRIMARY}
VAULT_URL=$(lb_url "$TARGET")

step "[$APP_SITE] Vault Agent Injector → $VAULT_URL"
helm_site "$APP_SITE" upgrade --install vault-injector vault --repo "$CHART_REPO" --version "$VAULT_CHART_VERSION" \
  -n vault-injector --create-namespace \
  --set server.enabled=false \
  --set injector.enabled=true \
  --set injector.externalVaultAddr="$VAULT_URL" \
  --set injector.agentImage.repository=hashicorp/vault \
  --set injector.agentImage.tag="$VAULT_VERSION" >/dev/null
kube "$APP_SITE" -n vault-injector rollout status deploy/vault-injector-agent-injector --timeout=180s >/dev/null

step "[$APP_SITE] Fachanwendung"
APP=$(terraform -chdir=terraform/vault-config output -json fachanwendung)
export VAULT_APP_NAMESPACE VAULT_K8S_MOUNT VAULT_CREDS_PATH SERVICES_IP
VAULT_APP_NAMESPACE=$(jq -r .namespace <<<"$APP")
VAULT_K8S_MOUNT=$(jq -r .k8s_mount <<<"$APP")
VAULT_CREDS_PATH=$(jq -r .creds_path <<<"$APP")
SERVICES_IP=$(tf_out services_ip)

kube_ns "$APP_SITE" fachanwendung
kube_secret "$APP_SITE" fachanwendung root-ca generic --from-file=ca.crt="$SECRETS/ca/root-ca.pem"
kube "$APP_SITE" apply -f "$(render k8s/fachanwendung/app.yaml VAULT_APP_NAMESPACE VAULT_K8S_MOUNT VAULT_CREDS_PATH SERVICES_IP)" >/dev/null
kube "$APP_SITE" -n fachanwendung rollout restart deploy/fachanwendung >/dev/null
kube "$APP_SITE" -n fachanwendung rollout status deploy/fachanwendung --timeout=300s
sleep 5
kube "$APP_SITE" -n fachanwendung logs deploy/fachanwendung -c app --tail=3 || true
