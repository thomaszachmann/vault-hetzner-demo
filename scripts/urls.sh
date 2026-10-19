#!/usr/bin/env bash
# Übersicht aller GUIs und Zugänge. `mise run urls -- --secrets` zeigt auch die Passwörter.
set -euo pipefail
source scripts/lib.sh

BASTION=$(bastion_ip)
SVC=$(tf_out services_ip)
SHOW=hide; [[ "${1:-}" == "--secrets" ]] && SHOW=show
pw() { if [[ $SHOW == show ]]; then cat "$SECRETS/passwords/$1" 2>/dev/null || echo "?"; else echo "(.secrets/passwords/$1)"; fi; }

cat <<EOF

Vault-Demo – Zugänge  (alle GUIs nur mit aktivem WireGuard-Tunnel)
═══════════════════════════════════════════════════════════════════════════
WireGuard:   .secrets/wireguard/vault-demo.conf  → in die WireGuard-App importieren
Bastion:     ssh root@$BASTION   (mise run ssh <host>)
Root-CA:     .secrets/ca/root-ca.pem  (einmalig dem Laptop vertrauen, siehe Doku)
kubectl:     mise run kubectl -- fsn1 get pods -A   (bzw. nbg1)

Vault (UI, Login-Methode "OIDC" → Keycloak)
  RZ A fsn1 (Primary)   $(lb_url fsn1)/ui/
  RZ B nbg1 (DR)        $(lb_url nbg1)/ui/

Keycloak (Behörden-IdM, Realm "behoerde")
  Admin-Konsole         https://keycloak.$SVC.nip.io/admin/   admin / $(pw keycloak_admin)
  Benutzer-Konto        https://keycloak.$SVC.nip.io/realms/behoerde/account/
  alice  (vault-admins)   $(pw user_alice)
  bob    (fa-entwickler)  $(pw user_bob)
  carol  (fb-betrieb)     $(pw user_carol)
  → beim ersten Login TOTP einrichten (MFA)

Break-Glass (nur wenn Keycloak ausfällt): Methode "Userpass", Pfad "breakglass"
  breakglass              $(pw breakglass)

Monitoring
  Grafana               https://grafana.$SVC.nip.io/      admin / $(pw grafana_admin)
  Prometheus            https://prometheus.$SVC.nip.io/

Fachanwendung (Kubernetes Auth, dynamische DB-Zugänge)
  mise run kubectl -- nbg1 -n fachanwendung logs deploy/fachanwendung -c app -f

Tokens und Schlüssel (lokal, .secrets/)
  Automatisierung (8h)  automation-token
  DR-Operation (24h)    dr-operation-token
  Recovery-Keys         init-fsn1.json, init-nbg1.json
  Unseal-Vault-Keys     unseal-fsn1.json, unseal-nbg1.json
EOF
