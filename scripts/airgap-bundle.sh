#!/usr/bin/env bash
# Build ONE tarball you can carry into a network with no internet access:
#   images.tar              both app images + the registry image (docker save)
#   llm-guardrail-<v>.tgz   the packaged Helm chart
#   values-airgapped.yaml   starting values for the offline site
#   MANIFEST.txt            what is inside (versions, image IDs, date)
#   airgap-install.sh, lib.sh  the installer, so the site needs nothing from the git repo
#   SHA256SUMS              checksums of the files above, verified by airgap-install.sh before anything is loaded
# Run this on a machine WITH internet, then transfer dist/llm-guardrail-airgap-*.tar.gz.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need docker helm tar sha256sum

REGISTRY_IMAGE="${REGISTRY_IMAGE:-registry:2.8.3}"
VERSION="$(sed -n 's/^version: *//p' "$CHART/Chart.yaml")"
STAGE="$REPO_ROOT/dist/bundle"
OUT="$REPO_ROOT/dist/llm-guardrail-airgap-$VERSION.tar.gz"

rm -rf "$STAGE" && mkdir -p "$STAGE"

log "building application images"
docker build -q --build-arg "GATEWAY_VERSION=$IMAGE_TAG" -t "llm-guardrail/gateway:$IMAGE_TAG" "$REPO_ROOT/app/gateway"  >/dev/null
docker build -q -t "llm-guardrail/mock-llm:$IMAGE_TAG" "$REPO_ROOT/app/mock-llm" >/dev/null
log "pulling $REGISTRY_IMAGE (used to run the local registry at the offline site)"
docker pull -q "$REGISTRY_IMAGE" >/dev/null

log "saving images"
docker save -o "$STAGE/images.tar" \
  "llm-guardrail/gateway:$IMAGE_TAG" "llm-guardrail/mock-llm:$IMAGE_TAG" "$REGISTRY_IMAGE"

log "packaging chart"
helm package "$CHART" --destination "$STAGE" >/dev/null
cp "$CHART/values-airgapped.yaml" "$STAGE/"
cp "$REPO_ROOT/scripts/airgap-install.sh" "$REPO_ROOT/scripts/lib.sh" "$STAGE/"

{
  echo "llm-guardrail air-gap bundle"
  echo "created:  $(date -u +%FT%TZ)"
  echo "chart:    llm-guardrail $VERSION"
  echo "images:"
  for img in "llm-guardrail/gateway:$IMAGE_TAG" "llm-guardrail/mock-llm:$IMAGE_TAG" "$REGISTRY_IMAGE"; do
    echo "  $img  $(docker image inspect --format '{{.Id}}' "$img")"
  done
} > "$STAGE/MANIFEST.txt"

( cd "$STAGE" && sha256sum images.tar ./*.tgz values-airgapped.yaml airgap-install.sh lib.sh MANIFEST.txt > SHA256SUMS )

# cd + relative names: Git Bash's tar treats "C:/..." as host:path if given an absolute Windows path.
( cd "$STAGE" && tar -czf "../$(basename "$OUT")" . )
( cd "$(dirname "$OUT")" && sha256sum "$(basename "$OUT")" > "$(basename "$OUT").sha256" )
log "bundle ready: $OUT ($(du -h "$OUT" | cut -f1))"
cat "$STAGE/MANIFEST.txt"
