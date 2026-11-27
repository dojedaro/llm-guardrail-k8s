#!/usr/bin/env bash
# Drill 5: the gateway is switched to the external LLM, but its API-key Secret is wrong.
#   missing  (default)  Secret does not exist          -> CreateContainerConfigError: secret "..." not found
#   wrongkey            Secret exists, key name wrong  -> CreateContainerConfigError: couldn't find key
# No real API key is used or needed: the pods never start.
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
if [[ "${1:-}" == "restore" ]]; then
  drill_restore
  kubectl -n "$NS" delete secret drill-wrong-key --ignore-not-found
  exit 0
fi
MODE="${1:-missing}"
case "$MODE" in
  missing) SECRET=does-not-exist ;;
  wrongkey) SECRET=drill-wrong-key ;;
  *) die "unknown mode '$MODE' (missing|wrongkey)" ;;   # validate BEFORE touching the release
esac

drill_begin
[[ "$MODE" == wrongkey ]] && kubectl -n "$NS" create secret generic "$SECRET" --from-literal=token=placeholder-not-a-real-key
# The chart refuses anthropic without an egress allowlist; a documentation-range address that is never contacted.
helm_break --set gateway.upstream.kind=anthropic --set gateway.upstream.url=https://api.anthropic.com \
  --set "gateway.secret.existingSecret=$SECRET" --set gateway.secret.key=api-key \
  --set networkPolicy.externalLLM.enabled=true --set 'networkPolicy.externalLLM.cidrs={203.0.113.10/32}'
wait_until 120 "a gateway pod in CreateContainerConfigError" \
  gateway_field_matches '{..waiting.reason}' 'CreateContainerConfigError'
kubectl -n "$NS" get pods -l app.kubernetes.io/name=gateway
banner "API-key Secret problem, mode=$MODE" 05-missing-secret.md
