#!/usr/bin/env bash
# Drill 4: memory limit far too low -> container is OOMKilled -> CrashLoopBackOff.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
[[ "${1:-inject}" == "restore" ]] && { drill_restore; exit 0; }

drill_begin
helm_break --set gateway.resources.limits.memory=20Mi --set gateway.resources.requests.memory=16Mi
sleep 30
kubectl -n "$NS" get pods -l app.kubernetes.io/name=gateway
banner "gateway memory limit 20Mi" 04-oomkilled.md
