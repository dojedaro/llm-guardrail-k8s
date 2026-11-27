#!/usr/bin/env bash
# Build both images locally and make them available to the cluster's nodes (no registry needed).
# How they are loaded depends on the cluster: IMAGE_LOADER=kind | k3s | none (see load_images in lib.sh).
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need docker

docker build -q --build-arg "GATEWAY_VERSION=$IMAGE_TAG" -t "llm-guardrail/gateway:$IMAGE_TAG" "$REPO_ROOT/app/gateway"
docker build -q -t "llm-guardrail/mock-llm:$IMAGE_TAG" "$REPO_ROOT/app/mock-llm"
load_images "llm-guardrail/gateway:$IMAGE_TAG" "llm-guardrail/mock-llm:$IMAGE_TAG"
