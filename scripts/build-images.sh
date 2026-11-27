#!/usr/bin/env bash
# Build both images locally and load them into the kind cluster's nodes (no registry needed).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need docker

docker build -q -t "llm-guardrail/gateway:$IMAGE_TAG"  "$REPO_ROOT/app/gateway"
docker build -q -t "llm-guardrail/mock-llm:$IMAGE_TAG" "$REPO_ROOT/app/mock-llm"

if command -v kind >/dev/null 2>&1 && kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "loading images into kind cluster '$CLUSTER_NAME'"
  kind load docker-image --name "$CLUSTER_NAME" \
    "llm-guardrail/gateway:$IMAGE_TAG" "llm-guardrail/mock-llm:$IMAGE_TAG"
else
  warn "kind cluster '$CLUSTER_NAME' not found; images built but not loaded"
fi
