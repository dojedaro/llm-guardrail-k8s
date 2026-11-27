#!/usr/bin/env bash
# Shared helpers, sourced by the other scripts. Not meant to be run directly.

# Git Bash on Windows rewrites arguments that look like Unix paths (e.g. /healthz) before
# passing them to native programs such as kubectl. Turn that off.
export MSYS_NO_PATHCONV=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHART="$REPO_ROOT/charts/llm-guardrail"

# Defaults, override with environment variables.
CLUSTER_NAME="${CLUSTER_NAME:-guardrail}"
NS="${NS:-guardrail}"
RELEASE="${RELEASE:-guardrail}"
IMAGE_TAG="${IMAGE_TAG:-0.1.0}"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33mWARN\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mERROR\033[0m %s\n' "$*" >&2; exit 1; }

need() {  # need kubectl helm ... : fail early with a clear message if a tool is missing
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "'$c' not found on PATH (see docs/LAB.md, step 0)"; done
}

gateway_svc() { echo "$RELEASE-gateway"; }

# run_pod NAME NAMESPACE LABELS IMAGE PYCODE
# Runs a one-shot pod executing `python -c PYCODE`, waits for it to finish, prints its logs,
# and returns 0 if the container exited 0. Used to test connectivity from inside the cluster.
run_pod() {
  local name="$1" ns="$2" labels="$3" image="$4" code="$5" phase i
  kubectl -n "$ns" delete pod "$name" --ignore-not-found --wait=true >/dev/null
  kubectl -n "$ns" run "$name" --image="$image" --image-pull-policy=IfNotPresent --restart=Never \
    ${labels:+--labels="$labels"} --command -- python -c "$code" >/dev/null
  for i in $(seq 1 60); do
    phase="$(kubectl -n "$ns" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
    sleep 1
  done
  kubectl -n "$ns" logs "$name" 2>&1 | sed 's/^/    | /' || true
  kubectl -n "$ns" delete pod "$name" --wait=false >/dev/null 2>&1 || true
  [[ "$phase" == "Succeeded" ]]
}

# Image the gateway Deployment is currently running (so probes use an image the cluster already has).
gateway_image() {
  kubectl -n "$NS" get deploy "$(gateway_svc)" -o jsonpath='{.spec.template.spec.containers[0].image}'
}

# redact: stdin -> stdout, masks anything that looks like a credential. Used by collect-diagnostics.sh.
# Two layers: (1) YAML/JSON keys whose name suggests a secret, (2) well-known key shapes anywhere.
redact() {
  sed -E \
    -e 's/((api[-_]?key|password|passwd|token|secret|authorization)[A-Za-z_-]*"?[:=] *)("[^"]*"|[^[:space:],]+)/\1<redacted>/I' \
    -e 's/sk-(ant-)?[A-Za-z0-9_-]{16,}/<redacted>/g' \
    -e 's/AKIA[0-9A-Z]{16}/<redacted>/g'
}

# Port-forward the gateway Service to localhost:PORT in the background; pf_stop kills it.
PF_PID=""
pf_start() {
  local port="${1:-18080}"
  kubectl -n "$NS" port-forward "svc/$(gateway_svc)" "$port:80" >/dev/null 2>&1 &
  PF_PID=$!
  trap pf_stop EXIT
  local i
  for i in $(seq 1 30); do
    curl -s -o /dev/null -m 1 "http://127.0.0.1:$port/healthz" && return 0
    sleep 1
  done
  die "port-forward to $(gateway_svc) did not become ready"
}
pf_stop() { [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true; }
