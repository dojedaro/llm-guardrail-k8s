#!/usr/bin/env bash
# Drill 5: the gateway is switched to the external LLM, but its API-key Secret is wrong.
#   missing  (default)  Secret does not exist          -> CreateContainerConfigError: secret "..." not found
#   wrongkey            Secret exists, key name wrong  -> CreateContainerConfigError: couldn't find key
# No real API key is used or needed: the pods never start.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
if [[ "${1:-}" == "restore" ]]; then
  drill_restore
  kubectl -n "$NS" delete secret drill-wrong-key --ignore-not-found
  exit 0
fi
MODE="${1:-missing}"

drill_begin
case "$MODE" in
  missing) SECRET=does-not-exist ;;
  wrongkey)
    SECRET=drill-wrong-key
    kubectl -n "$NS" create secret generic "$SECRET" --from-literal=token=placeholder-not-a-real-key
    ;;
  *) drill_restore; die "unknown mode '$MODE' (missing|wrongkey)" ;;
esac
helm_break --set gateway.upstream.kind=anthropic --set gateway.upstream.url=https://api.anthropic.com \
  --set "gateway.secret.existingSecret=$SECRET" --set gateway.secret.key=api-key
sleep 15
kubectl -n "$NS" get pods -l app.kubernetes.io/name=gateway
banner "API-key Secret problem, mode=$MODE" 05-missing-secret.md
