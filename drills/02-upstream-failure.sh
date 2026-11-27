#!/usr/bin/env bash
# Drill 2: the gateway cannot use its upstream LLM. Three flavours:
#   url  (default)  wrong upstream URL in the config  -> new pods never become Ready
#   502             mock LLM returns HTTP 500 for every call -> gateway answers 502
#   504             mock LLM is slower than the gateway timeout -> gateway answers 504
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
[[ "${1:-}" == "restore" ]] && { drill_restore; exit 0; }
MODE="${1:-url}"
case "$MODE" in url|502|504) ;; *) die "unknown mode '$MODE' (url|502|504)" ;; esac   # validate BEFORE touching the release

drill_begin
case "$MODE" in
  url) helm_break --set gateway.upstream.url=http://mock-llm-typo:8080 ;;
  502) helm_break --set mockLlm.faults.errorRate=1 ;;
  504) helm_break --set mockLlm.faults.latencyMs=15000 --set gateway.upstream.timeoutSeconds=3 ;;
esac
if [[ "$MODE" == "url" ]]; then
  wait_until 120 "a failed readiness probe on a new gateway pod" unready_pod_has_probe_failure
  kubectl -n "$NS" get pods
else
  want=502; [[ "$MODE" == 504 ]] && want=504
  kubectl -n "$NS" rollout status "deploy/$(gateway_svc)" --timeout=180s
  kubectl -n "$NS" rollout status "deploy/$RELEASE-mock-llm" --timeout=180s
  pf_start 18080
  chat_status() {
    local code
    code="$(curl -s -o "$DEVNULL" -w '%{http_code}' --max-time 20 http://127.0.0.1:18080/v1/chat \
      -H 'content-type: application/json' -d '{"messages":[{"role":"user","content":"hello"}]}')"
    [[ "$code" == "$want" ]]
  }
  # Old pods can keep a pooled connection to the old mock pod for a moment: poll until the new behaviour shows.
  wait_until 60 "chat to answer HTTP $want" chat_status || true
  echo "A chat request now:"
  curl -s -i --max-time 20 "http://127.0.0.1:18080/v1/chat" -H 'content-type: application/json' \
    -d '{"messages":[{"role":"user","content":"hello"}]}' | sed -n '1p;/^x-request-id/Ip;$p'
  echo
  pf_stop
  kubectl -n "$NS" get pods
fi
banner "upstream failure, mode=$MODE" 02-upstream-failure.md
