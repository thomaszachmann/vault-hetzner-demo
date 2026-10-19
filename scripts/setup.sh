#!/usr/bin/env bash
# Prüft alle Voraussetzungen für `mise run deploy`.
set -euo pipefail

ok()   { printf '  \033[32m✔\033[0m %s\n' "$1"; }
fail() { printf '  \033[31m✘\033[0m %s\n' "$1"; FAILED=1; }
info() { printf '  \033[33m•\033[0m %s\n' "$1"; }
FAILED=0

echo "Voraussetzungen:"

if [[ -n "${HCLOUD_TOKEN:-}" ]]; then ok "Hetzner-API-Token im Schlüsselbund (hcloud-vault-demo)"
else fail "Hetzner-API-Token fehlt: security add-generic-password -a \"\$USER\" -s hcloud-vault-demo -w"; fi

if [[ -f "$SSH_KEY.pub" ]]; then ok "SSH-Key $SSH_KEY.pub"
else fail "SSH-Key fehlt: ssh-keygen -t ed25519 -f ~/.ssh/vault-demo -C vault-demo-admin"; fi

if ssh-add -L 2>/dev/null | grep -qF "$(cut -d' ' -f2 "$SSH_KEY.pub" 2>/dev/null || echo none)"; then ok "SSH-Key im ssh-agent geladen"
else fail "SSH-Key nicht im Agent: ssh-add --apple-use-keychain $SSH_KEY"; fi

if [[ -f .secrets/vault.hclic ]]; then ok "Vault-Enterprise-Lizenz (.secrets/vault.hclic) → Enterprise-Modus"
else info "Keine Lizenz unter .secrets/vault.hclic → Community-Modus (ohne Namespaces/DR/HSM)"; fi

for t in terraform ansible-playbook hcloud vault kubectl helm jq openssl; do
  command -v "$t" >/dev/null && ok "$t" || fail "$t fehlt (mise install)"
done
command -v envsubst >/dev/null && ok "envsubst" || fail "envsubst fehlt (brew install gettext)"
(( BASH_VERSINFO[0] >= 4 )) && ok "bash ${BASH_VERSION%%(*}" || fail "bash >= 4 nötig (brew install bash)"

scripts/ca-init.sh | sed 's/^/  /'

if [[ $FAILED -ne 0 ]]; then echo; echo "Bitte die markierten Punkte beheben."; exit 1; fi
echo; echo "Alles bereit: mise run deploy"
