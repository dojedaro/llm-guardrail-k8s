#!/usr/bin/env bash
# Simulate an offline customer site: take ONLY the bundle, stand up a private registry,
# push the images into it, and install the chart so the nodes pull from that registry.
#
#   scripts/airgap-install.sh dist/llm-guardrail-airgap-0.1.0.tar.gz
#
# What is and is not simulated: the registry-and-bundle workflow is real; the network is not
# physically cut off. To tighten it further, remove images from the nodes first (see docs/LAB.md).
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need docker kubectl helm kind sha256sum tar

BUNDLE="${1:-}"; [[ -f "$BUNDLE" ]] || die "usage: $0 <bundle.tar.gz>"
REGISTRY_NAME="${REGISTRY_NAME:-kind-registry}"
REGISTRY_IMAGE="${REGISTRY_IMAGE:-registry:2.8.3}"
HOST_PORT="${REGISTRY_HOST_PORT:-5001}"        # how this workstation reaches the registry
CLUSTER_REG="$REGISTRY_NAME:5000"              # how the cluster nodes reach it (kind docker network)

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
log "extracting bundle and verifying checksums"
tar -xzf "$BUNDLE" -C "$WORK"
( cd "$WORK" && sha256sum -c SHA256SUMS )   # aborts (set -e) if anything was tampered with or corrupted
cat "$WORK/MANIFEST.txt"

log "loading images into the local Docker daemon"
docker load -i "$WORK/images.tar"

log "starting private registry '$REGISTRY_NAME'"
docker rm -f "$REGISTRY_NAME" >/dev/null 2>&1 || true
docker run -d --restart=always --name "$REGISTRY_NAME" -p "127.0.0.1:$HOST_PORT:5000" "$REGISTRY_IMAGE" >/dev/null
# Put the registry on the same Docker network as the kind nodes so they can resolve its name.
docker network connect kind "$REGISTRY_NAME" 2>/dev/null || true

log "teaching each kind node's containerd to use the registry over plain HTTP"
for node in $(kind get nodes --name "$CLUSTER_NAME"); do
  docker exec "$node" mkdir -p "/etc/containerd/certs.d/$CLUSTER_REG"
  printf '[host."http://%s"]\n' "$CLUSTER_REG" |
    docker exec -i "$node" tee "/etc/containerd/certs.d/$CLUSTER_REG/hosts.toml" >/dev/null
done

log "pushing images to the registry"
for img in gateway mock-llm; do
  docker tag "llm-guardrail/$img:$IMAGE_TAG" "localhost:$HOST_PORT/llm-guardrail/$img:$IMAGE_TAG"
  docker push -q "localhost:$HOST_PORT/llm-guardrail/$img:$IMAGE_TAG"
done
curl -s "http://localhost:$HOST_PORT/v2/_catalog"; echo

log "installing the chart FROM THE BUNDLE with registry $CLUSTER_REG"
chart_tgz="$(ls "$WORK"/llm-guardrail-*.tgz)"
kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -
helm upgrade --install "$RELEASE" "$chart_tgz" -n "$NS" \
  -f "$WORK/values-airgapped.yaml" --set "global.imageRegistry=$CLUSTER_REG" \
  --wait --timeout 180s

log "images the pods are actually running (should all start with $CLUSTER_REG):"
kubectl -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.containers[0].image}{"\n"}{end}'
helm test "$RELEASE" -n "$NS" --logs
