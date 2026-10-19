#!/usr/bin/env bash
# kubectl gegen einen Cluster über den SSH-Tunnel: mise run kubectl -- nbg1 get pods -A
set -euo pipefail
source scripts/lib.sh

SITE=${1:?Standort angeben: fsn1 oder nbg1}
shift
tunnel_ensure
kube "$SITE" "$@"
