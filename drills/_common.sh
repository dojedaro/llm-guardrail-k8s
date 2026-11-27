#!/usr/bin/env bash
# Shared by the drills. Each drill script supports:  <drill>.sh [inject|restore]
#   inject  (default)  record the last DEPLOYED Helm revision and the user values, then break something
#   restore            helm rollback to the recorded revision
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"
need kubectl helm

REV_FILE="$REPO_ROOT/reports/.drill-revision"
VALUES_FILE="$REPO_ROOT/reports/.drill-values.yaml"

drill_begin() {  # call before breaking anything, and only AFTER validating the arguments
  helm status "$RELEASE" -n "$NS" >/dev/null 2>&1 || die "release '$RELEASE' not installed in '$NS' (see docs/LAB.md)"
  mkdir -p "$REPO_ROOT/reports"
  [[ -f "$REV_FILE" ]] && die "a drill is already active (revision file exists). Run: $0 restore"
  last_deployed_revision > "$REV_FILE"
  helm get values "$RELEASE" -n "$NS" -o yaml > "$VALUES_FILE"
  grep -qx 'null' "$VALUES_FILE" && echo '{}' > "$VALUES_FILE"
  log "last deployed (healthy) revision recorded: $(cat "$REV_FILE")"
}

drill_restore() {
  [[ -f "$REV_FILE" ]] || die "nothing to restore (no recorded revision)"
  log "rolling back to revision $(cat "$REV_FILE")"
  helm rollback "$RELEASE" "$(cat "$REV_FILE")" -n "$NS" --wait --timeout 180s
  rm -f "$REV_FILE" "$VALUES_FILE"
  kubectl -n "$NS" get pods
}

# helm_break <--set args...> : upgrade WITHOUT --wait so the script returns while the failure is live.
# The baseline values are passed back explicitly (-f) instead of --reuse-values (see upgrade-rollback-demo.sh).
helm_break() {
  helm upgrade "$RELEASE" "$CHART" -n "$NS" -f "$VALUES_FILE" --hide-notes "$@"
}

# Predicates for wait_until (polling instead of fixed sleeps).
gateway_field_matches() {  # gateway_field_matches <kubectl jsonpath> <grep -E pattern>
  kubectl -n "$NS" get pods -l app.kubernetes.io/name=gateway -o jsonpath="$1" | grep -Eq "$2"
}
# True when a gateway pod that is NOT Ready has a failed-probe (Unhealthy) event of its own. Events outlive their
# pods for an hour, so matching events namespace-wide would wrongly succeed on leftovers from earlier runs.
unready_pod_has_probe_failure() {
  local p
  for p in $(kubectl -n "$NS" get pods -l app.kubernetes.io/name=gateway \
      -o jsonpath='{range .items[?(@.status.containerStatuses[0].ready==false)]}{.metadata.name}{"\n"}{end}'); do
    kubectl -n "$NS" get events --field-selector "involvedObject.name=$p,reason=Unhealthy" \
      -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' | grep -q 'Readiness probe failed' && return 0
  done
  return 1
}

banner() { echo; log "FAULT INJECTED: $1"; echo "    Now diagnose it. Writeup: drills/$2"; echo "    Undo with: $0 restore"; }
