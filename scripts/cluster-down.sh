#!/usr/bin/env bash
# Delete the kind cluster and the local registry container used by airgap-install.sh.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need kind

kind delete cluster --name "$CLUSTER_NAME"
docker rm -f "${REGISTRY_NAME:-kind-registry}" >/dev/null 2>&1 || true
log "cluster '$CLUSTER_NAME' deleted"
