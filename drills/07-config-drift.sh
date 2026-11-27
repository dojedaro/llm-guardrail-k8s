#!/usr/bin/env bash
# Drill 7: someone hot-fixes a Helm-managed object by hand (kubectl set env), so the next server-side
# `helm upgrade` fails with a field-ownership conflict. Shows how to find who changed what (managedFields)
# and how to hand ownership back to Helm. Written up as a customer incident report in 07-config-drift.md.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
MOCK="deploy/$RELEASE-mock-llm"

managers() {  # who owns what on the Deployment, with the index needed to remove an entry
  kubectl -n "$NS" get "$MOCK" --show-managed-fields -o json | python -c "
import json, sys
for i, m in enumerate(json.load(sys.stdin)['metadata']['managedFields']):
    print(f'  [{i}] manager={m[\"manager\"]:<24} operation={m[\"operation\"]:<7} time={m[\"time\"]}')"
}

if [[ "${1:-inject}" == "restore" ]]; then
  # 1. Remove a leftover kubectl-set entry (needed when it co-owns a field with Helm; --force-conflicts alone
  #    does not remove a manager whose value equals Helm's). 2. Re-assert the chart as owner, 3. roll back.
  idx="$(kubectl -n "$NS" get "$MOCK" --show-managed-fields -o json | python -c "
import json, sys
print(next((i for i, m in enumerate(json.load(sys.stdin)['metadata']['managedFields']) if m['manager'] == 'kubectl-set'), ''))")"
  if [[ -n "$idx" ]]; then
    log "removing the stale 'kubectl-set' field manager (managedFields[$idx])"
    kubectl -n "$NS" patch "$MOCK" --type=json -p "[{\"op\":\"remove\",\"path\":\"/metadata/managedFields/$idx\"}]"
  fi
  helm upgrade "$RELEASE" "$CHART" -n "$NS" -f "$VALUES_FILE" --force-conflicts --wait --timeout 180s >/dev/null
  drill_restore
  exit 0
fi

drill_begin
log "hand edit, outside Helm: kubectl set env $MOCK MOCK_LATENCY_MS=1"
kubectl -n "$NS" set env "$MOCK" MOCK_LATENCY_MS=1
kubectl -n "$NS" rollout status "$MOCK" --timeout=90s

log "a routine change window: helm upgrade with a new policy version (expected to FAIL)"
if helm upgrade "$RELEASE" "$CHART" -n "$NS" -f "$VALUES_FILE" --set policy.version=drift-demo --wait --timeout 120s; then
  die "helm upgrade succeeded; this Helm version did not detect the drift (client-side apply?)"
fi

log "release status after the failed upgrade"
helm history "$RELEASE" -n "$NS" | tail -3 | cut -c1-200
log "who owns the conflicting field? (managedFields)"
managers
banner "mock-llm env edited by kubectl; helm upgrade blocked" 07-config-drift.md
