#!/usr/bin/env bash
# Drill 2: the gateway cannot use its upstream LLM. Three flavours:
#   url  (default)  wrong upstream URL in the config  -> new pods never become Ready
#   502             mock LLM returns HTTP 500 for every call -> gateway answers 502
#   504             mock LLM is slower than the gateway timeout -> gateway answers 504
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
[[ "${1:-}" == "restore" ]] && { drill_restore; exit 0; }
MODE="${1:-url}"

drill_begin
case "$MODE" in
  url) helm_break --set gateway.upstream.url=http://mock-llm-typo:8080 ;;
  502) helm_break --set mockLlm.faults.errorRate=1 ;;
  504) helm_break --set mockLlm.faults.latencyMs=15000 --set gateway.upstream.timeoutSeconds=3 ;;
  *) drill_restore; die "unknown mode '$MODE' (url|502|504)" ;;
esac
sleep 20
kubectl -n "$NS" get pods
if [[ "$MODE" != "url" ]]; then
  pf_start 18080
  echo "A chat request now:"
  curl -s -i "http://127.0.0.1:18080/v1/chat" -H 'content-type: application/json' \
    -d '{"messages":[{"role":"user","content":"hello"}]}' | head -1
  pf_stop
fi
banner "upstream failure, mode=$MODE" 02-upstream-failure.md
