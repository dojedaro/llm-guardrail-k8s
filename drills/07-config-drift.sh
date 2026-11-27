#!/usr/bin/env bash
# Drill 7: someone hot-fixes a Helm-managed object by hand (kubectl set env), so the next
# server-side `helm upgrade` fails with a field-ownership conflict. Shows how to find who
# changed what (managedFields) and how to hand ownership back to Helm.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
[[ "${1:-inject}" == "restore" ]] && {
  # Re-assert the chart as the single owner, then go back to the recorded healthy revision.
  helm upgrade "$RELEASE" "$CHART" -n "$NS" --reuse-values --force-conflicts --wait --timeout 180s >/dev/null
  drill_restore
  exit 0
}

drill_begin
MOCK="deploy/$RELEASE-mock-llm"
log "hand edit, outside Helm: kubectl set env $MOCK MOCK_LATENCY_MS=1"
kubectl -n "$NS" set env "$MOCK" MOCK_LATENCY_MS=1
kubectl -n "$NS" rollout status "$MOCK" --timeout=90s

log "a routine change window: helm upgrade with a new policy version (expected to FAIL)"
if helm upgrade "$RELEASE" "$CHART" -n "$NS" --reuse-values --set policy.version=drift-demo --wait --timeout 120s; then
  die "helm upgrade succeeded; this Helm version did not detect the drift (client-side apply?)"
fi

log "who owns the conflicting field? (managers listed in managedFields)"
kubectl -n "$NS" get "$MOCK" --show-managed-fields -o json \
  | grep -o '"manager": *"[^"]*"\|"operation": *"[^"]*"' | paste - - | sort -u
banner "mock-llm env edited by kubectl; helm upgrade blocked" 07-config-drift.md
