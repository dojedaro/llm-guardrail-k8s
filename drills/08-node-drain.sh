#!/usr/bin/env bash
# Drill 8: planned node maintenance. Drain both workers while a request loop runs through the ingress, to see
# the PodDisruptionBudgets hold the last healthy replica of the gateway and of the (HA) upstream.
#   1. mockLlm.replicas=2 so the upstream is highly available too (a single-replica dependency defeats the PDB)
#   2. cordon both workers, drain worker A      -> allowed: one replica of each is still Ready on B
#   3. drain worker B                           -> BLOCKED by the PDBs ("Cannot evict pod ... disruption budget")
#   4. uncordon A                               -> replacements start on A, become Ready, drain of B completes
# Needs the release installed with the ingress enabled (values-kind.yaml) for the request loop; without it the
# loop is skipped and only the drain behaviour is shown.   Undo: drills/08-node-drain.sh restore
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
WORKERS=(); while read -r n; do WORKERS+=("$n"); done < <(kubectl get nodes -l '!node-role.kubernetes.io/control-plane' -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}')
if [[ "${1:-inject}" == "restore" ]]; then
  for n in "${WORKERS[@]}"; do kubectl uncordon "$n"; done
  drill_restore; exit 0
fi
[[ "${#WORKERS[@]}" -eq 2 ]] || die "this drill needs exactly 2 worker nodes (found ${#WORKERS[@]})"
A="${WORKERS[0]}"; B="${WORKERS[1]}"
LOG="$REPO_ROOT/reports"; mkdir -p "$LOG"

pods() { kubectl -n "$NS" get pods -o wide -l app.kubernetes.io/part-of=llm-guardrail | awk '{print $1, $2, $3, $7}' | column -t; }
all_ready() { [[ "$(kubectl -n "$NS" get pods -l app.kubernetes.io/part-of=llm-guardrail -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' | grep -c true)" -ge "$1" ]]; }

drill_begin
log "step 1: make the upstream highly available too (mockLlm.replicas=2)"
helm upgrade "$RELEASE" "$CHART" -n "$NS" -f "$VALUES_FILE" --set mockLlm.replicas=2 --wait --timeout 180s >/dev/null
# The spread constraint is only a preference (ScheduleAnyway), so two replicas can still share a node. Start the drill
# from a clean state: if every replica of a Deployment is on one node, delete one so it is rescheduled.
ensure_spread() {  # ensure_spread <app label value>
  local nodes
  for _ in 1 2 3; do
    nodes="$(kubectl -n "$NS" get pods -l "app.kubernetes.io/name=$1" --field-selector=status.phase=Running \
      -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u | wc -l | tr -d ' ')"
    [[ "$nodes" -ge 2 ]] && return 0
    kubectl -n "$NS" delete "$(kubectl -n "$NS" get pods -l "app.kubernetes.io/name=$1" -o name | head -1)" >/dev/null
    wait_until 90 "replicas of $1 Ready" all_ready 4 || true
  done
}
all_ready 4 || wait_until 90 "all pods Ready" all_ready 4
ensure_spread gateway; ensure_spread mock-llm
pods; kubectl -n "$NS" get pdb

PROBE_PID=""
code="$(curl -s -o "$DEVNULL" -w '%{http_code}' -m 3 -H 'Host: guardrail.localtest.me' -H 'content-type: application/json' -d '{}' http://127.0.0.1:8080/v1/chat || true)"
if [[ "$code" == 422 ]]; then   # 422 = the gateway answered (empty body is invalid); 404 would be the ingress default backend
  log "request loop through the ingress (20 req/s) started in the background"
  "$PYTHON" "$REPO_ROOT/scripts/availability_probe.py" --url http://127.0.0.1:8080 --host guardrail.localtest.me \
    --seconds 150 --rate 20 > "$LOG/drill-08-probe.out" 2>&1 &
  PROBE_PID=$!
else
  warn "ingress not reachable on 127.0.0.1:8080: skipping the request loop"
fi

log "step 2: cordon both workers, then drain $A"
kubectl cordon "$A" "$B"
kubectl drain "$A" --ignore-daemonsets --delete-emptydir-data --timeout=120s
pods; kubectl -n "$NS" get pdb

log "step 3: drain $B while $A is still cordoned (expect it to be held by the PDBs)"
( kubectl drain "$B" --ignore-daemonsets --delete-emptydir-data --timeout=120s > "$LOG/drill-08-drain-b.out" 2>&1 ) &
DRAIN_PID=$!
sleep 20
echo "--- drain of $B after 20 s (still waiting):"; grep -E 'evict|Cannot|disruption' "$LOG/drill-08-drain-b.out" | sort | uniq -c | head
pods; kubectl -n "$NS" get pdb

log "step 4: uncordon $A so replacements can start there; the drain of $B can then proceed"
kubectl uncordon "$A"
wait "$DRAIN_PID" || warn "drain of $B did not finish cleanly (see $LOG/drill-08-drain-b.out)"
tail -3 "$LOG/drill-08-drain-b.out"
wait_until 120 "all four pods Ready" all_ready 4 || true
pods

if [[ -n "$PROBE_PID" ]]; then
  log "waiting for the request loop to finish"
  wait "$PROBE_PID" || true
  cat "$LOG/drill-08-probe.out"
fi
echo; log "DRILL DONE. $B is still cordoned. Undo with: $0 restore"
