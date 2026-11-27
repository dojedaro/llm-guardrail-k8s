#!/usr/bin/env bash
# Simulate an offline customer site: take ONLY the bundle, stand up a private registry,
# push the images into it, and install the chart so the nodes pull from that registry.
#
#   scripts/airgap-install.sh dist/llm-guardrail-airgap-0.1.0.tar.gz
#
# What is and is not simulated: the bundle-and-registry workflow is real; the network is not physically cut
# off (the machine running this script still has internet). The evidence that the nodes used the bundle is
# in the pod image names and the kubelet "Pulled" events printed at the end, not in network isolation.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need docker kubectl helm kind sha256sum tar curl

BUNDLE="${1:-}"; [[ -f "$BUNDLE" ]] || die "usage: $0 <bundle.tar.gz>"
REGISTRY_NAME="${REGISTRY_NAME:-kind-registry}"
REGISTRY_IMAGE="${REGISTRY_IMAGE:-registry:2.8.3}"
HOST_PORT="${REGISTRY_HOST_PORT:-5001}"        # how this workstation reaches the registry
CLUSTER_REG="$REGISTRY_NAME:5000"              # how the cluster nodes reach it (kind docker network)

# Work dir inside the repo (not /tmp): docker.exe and helm.exe cannot see Git Bash's /tmp on Windows.
mkdir -p "$REPO_ROOT/dist"; WORK="$REPO_ROOT/dist/.airgap-work-$$"; mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT

log "verifying the bundle file against its .sha256 (outer checksum)"
if [[ -f "$BUNDLE.sha256" ]]; then
  ( cd "$(dirname "$BUNDLE")" && sha256sum -c "$(basename "$BUNDLE").sha256" )
  echo "    note: a checksum shipped next to the bundle detects corruption in transit. It does not prove who made"
  echo "    the bundle: for that, deliver the checksum by a separate trusted channel or sign it."
else
  warn "no $BUNDLE.sha256 next to the bundle: skipping the outer check"
fi
tar -xz -C "$WORK" < "$BUNDLE"       # stdin: Git Bash tar treats "C:/path" as host:path
log "verifying the checksums inside the bundle"
( cd "$WORK" && sha256sum -c SHA256SUMS )   # aborts (set -e) on any mismatch
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
  # containerd reads certs.d only when registry.config_path points at it. kind v0.33 / containerd 2.x prints an empty
  # value in `containerd config dump` and still honours /etc/containerd/certs.d (proven by the Pulled events below), so
  # this is a warning, not a gate. On other node images, add config_path via kind's containerdConfigPatches.
  docker exec "$node" sh -c "containerd config dump 2>/dev/null | grep -q \"config_path = '/\"" ||
    warn "containerd on $node shows no explicit registry config_path; relying on its default (see the Pulled events at the end)"
  docker exec "$node" mkdir -p "/etc/containerd/certs.d/$CLUSTER_REG"
  printf '[host."http://%s"]'$'\n' "$CLUSTER_REG" |
    docker exec -i "$node" tee "/etc/containerd/certs.d/$CLUSTER_REG/hosts.toml" >/dev/null
done

log "pushing images to the registry"
for img in gateway mock-llm; do
  docker tag "llm-guardrail/$img:$IMAGE_TAG" "localhost:$HOST_PORT/llm-guardrail/$img:$IMAGE_TAG"
  docker push -q "localhost:$HOST_PORT/llm-guardrail/$img:$IMAGE_TAG"
done
echo "registry catalog:"; curl -s "http://localhost:$HOST_PORT/v2/_catalog"; echo

log "installing the chart FROM THE BUNDLE with registry $CLUSTER_REG"
chart_tgz="$(ls "$WORK"/llm-guardrail-*.tgz)"
kubectl get namespace "$NS" >/dev/null 2>&1 || kubectl create namespace "$NS"
helm upgrade --install "$RELEASE" "$chart_tgz" -n "$NS" \
  -f "$WORK/values-airgapped.yaml" --set "global.imageRegistry=$CLUSTER_REG" \
  --wait --timeout 180s

log "evidence 1: images the pods run (all must start with $CLUSTER_REG/)"
kubectl -n "$NS" get pods -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.containers[0].image}{"\n"}{end}'
log "evidence 2: the registry's own access log shows the nodes fetching the images from it"
# (Not `crictl rmi` + "Pulled" events: removing the registry-named image also removes a local image with the same
# ID, because kind-loaded and pushed images are identical bits. That broke a following default install in testing.)
docker logs "$REGISTRY_NAME" 2>&1 | grep -E '"(GET|HEAD) /v2/llm-guardrail/(gateway|mock-llm)/(manifests|blobs)' | tail -6 ||
  warn "the registry served no manifest/blob request for our images: the nodes did not use it"
helm test "$RELEASE" -n "$NS" --logs
