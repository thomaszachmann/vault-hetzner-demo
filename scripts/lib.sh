# Gemeinsame Hilfsfunktionen für die mise-Tasks (wird per `source` eingebunden).

SECRETS=.secrets
CONTROL_DIR=.ssh-control
RENDER_DIR=$SECRETS/render
SITES=(fsn1 nbg1)
PRIMARY=fsn1
DR=nbg1
APP_SITE=nbg1
CHART_REPO=https://helm.releases.hashicorp.com
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o ConnectTimeout=10)

# Lokale Tunnel-Ports (über die Bastion):  Kubernetes-API und Vault-LB je Standort
declare -A API_PORT=([fsn1]=16443 [nbg1]=26443)
declare -A VAULT_PORT=([fsn1]=18200 [nbg1]=28200)

step() { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
enterprise() { [[ -f "$SECRETS/vault.hclic" ]]; }

tf_out()  { terraform -chdir=terraform/infra output -raw "$1" 2>/dev/null; }
tf_json() { terraform -chdir=terraform/infra output -json "$1" 2>/dev/null; }

bastion_ip() {
  local ip
  ip=$(tf_out bastion_ipv4) || true
  [[ -n "$ip" ]] || { echo "Keine Umgebung deployt (terraform output leer)." >&2; exit 1; }
  echo "$ip"
}

site_lb_ip()  { tf_json sites | jq -r --arg s "$1" '.[$s].lb_ip'; }
lb_url()      { echo "https://vault-$1.$(site_lb_ip "$1").nip.io:8200"; }

# Befehl auf einem privaten Host über die Bastion ausführen
on_host() {
  local ip=$1; shift
  ssh "${SSH_OPTS[@]}" -o ProxyCommand="ssh ${SSH_OPTS[*]} -W %h:%p root@$(bastion_ip)" "root@$ip" "$@"
}

# ---- SSH-Tunnel (eine Master-Verbindung, mehrere Weiterleitungen) ----
tunnel_alive() { [[ -S "$CONTROL_DIR/tunnel" ]] && ssh -S "$CONTROL_DIR/tunnel" -O check root@x 2>/dev/null; }

tunnel_ensure() {
  tunnel_alive && return 0
  mkdir -p "$CONTROL_DIR"
  rm -f "$CONTROL_DIR/tunnel"
  local fwd=() s
  for s in "${SITES[@]}"; do
    # Kubernetes-API und Vault jeweils über den internen LB des Standorts
    fwd+=(-L "${API_PORT[$s]}:$(site_lb_ip "$s"):6443" -L "${VAULT_PORT[$s]}:$(site_lb_ip "$s"):8200")
  done
  ssh "${SSH_OPTS[@]}" -f -N -M -S "$CONTROL_DIR/tunnel" -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=15 "${fwd[@]}" "root@$(bastion_ip)"
}

tunnel_close() {
  [[ -S "$CONTROL_DIR/tunnel" ]] && ssh -S "$CONTROL_DIR/tunnel" -O exit root@x 2>/dev/null
  rm -f "$CONTROL_DIR/tunnel"
  return 0
}

# ---- Kubernetes / Helm ----
kube() { local s=$1; shift; kubectl --kubeconfig "$SECRETS/kubeconfig-$s" "$@"; }
helm_site() { local s=$1; shift; helm --kubeconfig "$SECRETS/kubeconfig-$s" "$@"; }

# Manifest/Values mit envsubst rendern – nur die genannten Variablen werden ersetzt
render() {
  local src=$1; shift
  local vars="" v
  for v in "$@"; do vars+="\${$v} "; done
  mkdir -p "$RENDER_DIR"
  local out="$RENDER_DIR/$(basename "$src")"
  envsubst "$vars" < "$src" > "$out"
  echo "$out"
}

# Secret idempotent anlegen/aktualisieren: kube_secret <site> <ns> <name> <kubectl-create-secret-args…>
kube_secret() {
  local s=$1 ns=$2 name=$3; shift 3
  kube "$s" -n "$ns" create secret "$@" "$name" --dry-run=client -o yaml | kube "$s" apply -f - >/dev/null
}

kube_ns() { local s=$1; shift; for ns in "$@"; do kube "$s" create ns "$ns" --dry-run=client -o yaml | kube "$s" apply -f - >/dev/null; done; }

# ---- Vault ----
# Vault-CLI im Pod (für Init, bevor der LB den Cluster als gesund sieht)
vault_pod() {
  local s=$1 ns=$2 pod=$3 token=$4; shift 4
  kube "$s" -n "$ns" exec "$pod" -c vault -- env VAULT_TOKEN="$token" vault "$@"
}

# Lokale Vault-CLI über Tunnel → interner LB des Standorts
vault_lb() {
  local s=$1 token=$2; shift 2
  VAULT_ADDR="https://127.0.0.1:${VAULT_PORT[$s]}" VAULT_CACERT="$SECRETS/ca/root-ca.pem" \
    VAULT_TOKEN="$token" vault "$@"
}

root_token()       { jq -r .root_token "$SECRETS/init-$1.json"; }
automation_token() { cat "$SECRETS/automation-token" 2>/dev/null || true; }

# Token für administrative Schritte: Root-Token, solange nicht widerrufen, sonst Automatisierung
admin_token() {
  local t
  t=$(root_token "$1" 2>/dev/null || true)
  if [[ -z "$t" || "$t" == "REVOKED" || "$t" == "null" ]]; then automation_token; else echo "$t"; fi
}

wait_for() { # wait_for <sekunden> <beschreibung> <befehl…>
  local timeout=$1 desc=$2; shift 2
  local end=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do
    (( SECONDS < end )) || { echo "Timeout: $desc" >&2; return 1; }
    sleep 5
  done
}
