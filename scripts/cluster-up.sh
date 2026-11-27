#!/usr/bin/env bash
# Create the local kind cluster, optionally with Calico, install ingress-nginx, load images.
#
#   scripts/cluster-up.sh                 # kind's default CNI
#   CNI=calico scripts/cluster-up.sh      # Calico (guaranteed NetworkPolicy enforcement)
#   INGRESS=0 scripts/cluster-up.sh       # skip ingress-nginx
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need kind kubectl docker

CNI="${CNI:-default}"
INGRESS="${INGRESS:-1}"
CALICO_VERSION="${CALICO_VERSION:-v3.28.2}"
INGRESS_MANIFEST="${INGRESS_MANIFEST:-https://kind.sigs.k8s.io/examples/ingress/deploy-ingress-nginx.yaml}"

if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
  log "kind cluster '$CLUSTER_NAME' already exists, reusing it"
else
  cfg="$REPO_ROOT/kind/cluster.yaml"
  [[ "$CNI" == "calico" ]] && cfg="$REPO_ROOT/kind/cluster-calico.yaml"
  log "creating cluster '$CLUSTER_NAME' (CNI=$CNI) from $cfg"
  kind create cluster --name "$CLUSTER_NAME" --config "$cfg"
fi
kubectl config use-context "kind-$CLUSTER_NAME" >/dev/null

if [[ "$CNI" == "calico" ]]; then
  log "installing Calico $CALICO_VERSION (nodes stay NotReady until it is up)"
  kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/$CALICO_VERSION/manifests/calico.yaml"
  kubectl -n kube-system rollout status ds/calico-node --timeout=300s
fi
kubectl wait --for=condition=Ready nodes --all --timeout=300s

if [[ "$INGRESS" == "1" ]]; then
  log "installing ingress-nginx (kind's documented manifest)"
  kubectl apply -f "$INGRESS_MANIFEST"
  kubectl -n ingress-nginx wait --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller --timeout=240s
fi

"$REPO_ROOT/scripts/build-images.sh"
log "cluster ready. Next: scripts/preflight.sh, then helm install (docs/LAB.md)"
