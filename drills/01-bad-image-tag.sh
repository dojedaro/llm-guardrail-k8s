#!/usr/bin/env bash
# Drill 1: upgrade points at an image tag that does not exist -> ImagePullBackOff.
set -euo pipefail
# shellcheck source=_common.sh
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"
[[ "${1:-inject}" == "restore" ]] && { drill_restore; exit 0; }

drill_begin
helm_break --set gateway.image.tag=0.1.0-doesnotexist
wait_until 120 "a gateway pod in ErrImagePull/ImagePullBackOff" \
  gateway_field_matches '{..waiting.reason}' 'ErrImagePull|ImagePullBackOff'
kubectl -n "$NS" get pods -l app.kubernetes.io/name=gateway
banner "gateway image tag 0.1.0-doesnotexist" 01-bad-image-tag.md
