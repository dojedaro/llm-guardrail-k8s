#!/usr/bin/env bash
# Upgrade the policy, verify, roll back, verify. Shows what a safe change window looks like:
#   baseline -> helm upgrade (policy v2, PII mode "block") -> verify -> helm history -> helm rollback -> verify
# Requires the release to be installed already (see docs/LAB.md). Safe to re-run.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need kubectl helm curl

NEW_VERSION="${NEW_VERSION:-upgrade-demo-$(date +%H%M%S)}"
PORT="${PORT:-18080}"
helm status "$RELEASE" -n "$NS" >/dev/null 2>&1 || die "release '$RELEASE' not found in namespace '$NS'. Install it first."

# Ask the live gateway what policy it is running and how it treats an email address.
verify() { # verify <expected-version> <expected-http-status-for-email>
  local want_ver="$1" want_status="$2" ready status
  ready="$(curl -s "http://127.0.0.1:$PORT/readyz")"
  status="$(curl -s -o "$DEVNULL" -w '%{http_code}' "http://127.0.0.1:$PORT/v1/chat" \
    -H 'content-type: application/json' \
    -d '{"messages":[{"role":"user","content":"my email is jane@example.com"}]}')"
  echo "    readyz: $ready"
  echo "    chat with an email address -> HTTP $status (expected $want_status)"
  grep -q "\"policy_version\":\"$want_ver\"" <<<"$ready" || die "expected policy_version $want_ver"
  [[ "$status" == "$want_status" ]] || die "expected HTTP $want_status"
}

# The port-forward targets ONE pod, so restart it after every rollout.
restart_pf() { pf_stop; sleep 1; pf_start "$PORT"; }

BASE_REV="$(helm history "$RELEASE" -n "$NS" -o json | grep -o '"revision":[0-9]*' | tail -1 | cut -d: -f2)"
BASE_VER="$(helm get values "$RELEASE" -n "$NS" -a | awk '/^policy:/{p=1} p && /version:/{gsub(/"/,"",$2); print $2; exit}')"
log "baseline: revision $BASE_REV, policy version $BASE_VER"
pf_start "$PORT"
verify "$BASE_VER" 200

log "upgrade: policy $NEW_VERSION, pii.mode=block"
helm upgrade "$RELEASE" "$CHART" -n "$NS" --reuse-values \
  --set "policy.version=$NEW_VERSION" --set policy.pii.mode=block --wait --timeout 180s
restart_pf
verify "$NEW_VERSION" 403

log "release history"
helm history "$RELEASE" -n "$NS"

log "rollback to revision $BASE_REV"
helm rollback "$RELEASE" "$BASE_REV" -n "$NS" --wait --timeout 180s
restart_pf
verify "$BASE_VER" 200

helm history "$RELEASE" -n "$NS"
log "OK: upgrade and rollback both verified"
