#!/usr/bin/env bash
# Shared by the drills. Each drill script supports:  <drill>.sh [inject|restore]
#   inject  (default)  record the current Helm revision, then break something
#   restore            helm rollback to the recorded revision
source "$(dirname "${BASH_SOURCE[0]}")/../scripts/lib.sh"
need kubectl helm

REV_FILE="$REPO_ROOT/reports/.drill-revision"

current_revision() { helm history "$RELEASE" -n "$NS" -o json | grep -o '"revision":[0-9]*' | tail -1 | cut -d: -f2; }

drill_begin() {  # call before breaking anything
  helm status "$RELEASE" -n "$NS" >/dev/null 2>&1 || die "release '$RELEASE' not installed in '$NS' (see docs/LAB.md)"
  mkdir -p "$REPO_ROOT/reports"
  [[ -f "$REV_FILE" ]] && die "a drill is already active (revision file exists). Run: $0 restore"
  current_revision > "$REV_FILE"
  log "healthy revision recorded: $(cat "$REV_FILE")"
}

drill_restore() {
  [[ -f "$REV_FILE" ]] || die "nothing to restore (no recorded revision)"
  log "rolling back to revision $(cat "$REV_FILE")"
  helm rollback "$RELEASE" "$(cat "$REV_FILE")" -n "$NS" --wait --timeout 180s
  rm -f "$REV_FILE"
  kubectl -n "$NS" get pods
}

# helm_break <--set args...> : upgrade WITHOUT --wait so the script returns while the failure is live.
helm_break() {
  helm upgrade "$RELEASE" "$CHART" -n "$NS" --reuse-values "$@"
}

banner() { echo; log "FAULT INJECTED: $1"; echo "    Now diagnose it. Writeup: drills/$2"; echo "    Undo with: $0 restore"; }
