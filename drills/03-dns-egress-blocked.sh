#!/usr/bin/env bash
# Drill 3: the egress NetworkPolicy has no DNS rule -> the gateway cannot resolve the mock-llm Service name.
# Needs a CNI that enforces NetworkPolicy (run drill 06 first if unsure).
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
[[ "${1:-inject}" == "restore" ]] && { drill_restore; exit 0; }

drill_begin
helm_break --set networkPolicy.allowDns=false
# Policy changes do not restart pods; restart them so startup runs against the broken network.
kubectl -n "$NS" rollout restart "deploy/$(gateway_svc)"
wait_until 120 "a failed readiness probe on a gateway pod" unready_pod_has_probe_failure
kubectl -n "$NS" get pods -l app.kubernetes.io/name=gateway
banner "DNS egress removed from NetworkPolicy" 03-dns-egress-blocked.md
