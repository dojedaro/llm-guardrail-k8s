#!/usr/bin/env bash
# Create the local kind cluster, optionally with Calico, install an ingress controller, build and load images.
#
#   scripts/cluster-up.sh                 # kind's default CNI
#   CNI=calico scripts/cluster-up.sh      # Calico (guaranteed NetworkPolicy enforcement)
#   INGRESS=0 scripts/cluster-up.sh       # skip ingress-nginx
#   IMAGE_LOADER=none scripts/cluster-up.sh   # build the images but do not load them (see scripts/lib.sh load_images)
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need kind kubectl docker

CNI="${CNI:-default}"
INGRESS="${INGRESS:-1}"
CALICO_VERSION="${CALICO_VERSION:-v3.28.2}"
KIND_NODE_IMAGE="${KIND_NODE_IMAGE:-kindest/node:v1.37.0@sha256:a1ed56cfb0e7b93589bdf97c8cd566405a265939e3620fc4f5de89adff580ae5}"
# ingress-nginx was retired upstream in March 2026 (its repository is archived; controller-v1.15.1 is the last
# release). It is used here only because kind's documented ingress setup is built on it; the chart's Ingress takes
# any controller through ingress.className.
INGRESS_MANIFEST="${INGRESS_MANIFEST:-https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/kind/deploy.yaml}"

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "kind cluster '$CLUSTER_NAME' already exists, reusing it"
else
  cfg="$REPO_ROOT/kind/cluster.yaml"
  [[ "$CNI" == "calico" ]] && cfg="$REPO_ROOT/kind/cluster-calico.yaml"
  log "creating cluster '$CLUSTER_NAME' (CNI=$CNI, node image $KIND_NODE_IMAGE) from $cfg"
  kind create cluster --name "$CLUSTER_NAME" --config "$cfg" --image "$KIND_NODE_IMAGE"
fi
kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null

if [[ "$CNI" == "calico" ]]; then
  log "installing Calico $CALICO_VERSION (nodes stay NotReady until it is up)"
  kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/calico.yaml"
  kubectl -n kube-system rollout status ds/calico-node --timeout=300s
fi
kubectl wait --for=condition=Ready nodes --all --timeout=300s

if [[ "$INGRESS" == "1" ]]; then
  log "installing ingress-nginx ($INGRESS_MANIFEST)"
  kubectl apply -f "$INGRESS_MANIFEST"
  # The manifest does not pin the controller to the node that has host ports 80/443 mapped (found on a real run:
  # it landed on a worker and localhost:8080 was dead). Pin it to the ingress-ready control-plane node ourselves,
  # then wait for the replacement pod.
  kubectl -n ingress-nginx patch deployment ingress-nginx-controller --type=merge -p \
    '{"spec":{"template":{"spec":{"nodeSelector":{"ingress-ready":"true"},"tolerations":[{"key":"node-role.kubernetes.io/control-plane","operator":"Equal","effect":"NoSchedule"}]}}}}'
  kubectl -n ingress-nginx rollout status deployment/ingress-nginx-controller --timeout=240s
fi

"$REPO_ROOT/scripts/build-images.sh"
log "cluster ready. Next: scripts/preflight.sh, then helm install (README, Run it)"
