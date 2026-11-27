#!/usr/bin/env bash
# Scan both application images for fixable HIGH/CRITICAL vulnerabilities with Trivy, run from a container image
# pinned by digest (nothing to install, and a moved tag cannot change what runs). Exit code 1 if any are found.
#
#   scripts/scan-images.sh              # scans llm-guardrail/{gateway,mock-llm}:$IMAGE_TAG; build them first
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need docker

TRIVY_IMAGE="${TRIVY_IMAGE:-aquasec/trivy@sha256:ab70a02200597efa04748f210f793936eb647cbcdb0ea69cc30b226d6f5a22c7}" # 0.58.1
WORK="$REPO_ROOT/dist/.scan-work-$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

status=0
for img in gateway mock-llm; do
  log "scanning llm-guardrail/$img:$IMAGE_TAG"
  # Scan an exported archive instead of mounting the Docker socket: the same command works with any engine.
  docker save -o "$WORK/$img.tar" "llm-guardrail/$img:$IMAGE_TAG"
  docker run --rm -v "$WORK:/scan:ro" -v trivy-cache:/root/.cache/ "$TRIVY_IMAGE" image \
    --input "/scan/$img.tar" --severity CRITICAL,HIGH --ignore-unfixed --exit-code 1 --quiet || status=1
done
if [[ "$status" -eq 0 ]]; then log "no fixable HIGH or CRITICAL findings"; else warn "fixable HIGH/CRITICAL findings above"; fi
exit "$status"
