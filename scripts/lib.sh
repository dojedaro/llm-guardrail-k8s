#!/usr/bin/env bash
# Shared helpers, sourced by the other scripts. Not meant to be run directly.

# Git Bash on Windows rewrites arguments that look like Unix paths (e.g. /healthz) before
# passing them to native programs such as kubectl. Turn that off.
export MSYS_NO_PATHCONV=1
# ...which also stops /dev/null being translated for native Windows curl, so give curl -o
# the right null device for the platform.
DEVNULL=/dev/null
if command -v cygpath >/dev/null 2>&1; then DEVNULL=NUL; fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Git Bash on Windows: native tools (kind.exe, helm.exe, kubectl.exe) cannot open /c/... paths,
# so use the mixed form C:/... there. No-op on Linux/macOS.
if command -v cygpath >/dev/null 2>&1; then REPO_ROOT="$(cygpath -m "$REPO_ROOT")"; fi
export CHART="$REPO_ROOT/charts/llm-guardrail"

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
# Runs a one-shot pod executing `python -c PYCODE`, waits for it to finish and prints its logs (also kept in
# $RUN_POD_LOG). Returns 0 if the container exited 0. Used to test connectivity from inside the cluster.
RUN_POD_LOG=""
run_pod() {
  local name="$1" ns="$2" labels="$3" image="$4" code="$5" phase
  kubectl -n "$ns" delete pod "$name" --ignore-not-found --wait=true >/dev/null
  kubectl -n "$ns" run "$name" --image="$image" --image-pull-policy=IfNotPresent --restart=Never     ${labels:+--labels="$labels"} --command -- python -c "$code" >/dev/null
  for _ in $(seq 1 90); do
    phase="$(kubectl -n "$ns" get pod "$name" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
    [[ "$phase" == "Succeeded" || "$phase" == "Failed" ]] && break
    sleep 1
  done
  RUN_POD_LOG="$(kubectl -n "$ns" logs "$name" 2>&1 || true)"
  sed 's/^/    | /' <<<"$RUN_POD_LOG"
  kubectl -n "$ns" delete pod "$name" --wait=false >/dev/null 2>&1 || true
  [[ "$phase" == "Succeeded" ]]
}

# wait_until TIMEOUT_SECONDS DESCRIPTION CMD... : poll CMD every 2 s until it succeeds (replaces fixed sleeps).
wait_until() {
  local timeout="$1" what="$2" end; shift 2
  end=$((SECONDS + timeout))
  until "$@" >/dev/null 2>&1; do
    [[ $SECONDS -ge $end ]] && { warn "timed out after ${timeout}s waiting for: $what"; return 1; }
    sleep 2
  done
}

# Last Helm revision whose status is "deployed" (a failed upgrade creates a newer, failed revision).
last_deployed_revision() {
  helm history "$RELEASE" -n "$NS" -o json | tr '{' '\n' | grep '"status":"deployed"' | grep -o '"revision":[0-9]*' | tail -1 | cut -d: -f2
}

# Image the gateway Deployment is currently running (so probes use an image the cluster already has).
gateway_image() {
  kubectl -n "$NS" get deploy "$(gateway_svc)" -o jsonpath='{.spec.template.spec.containers[0].image}'
}

# redact: stdin -> stdout, masks anything that looks like a credential. Used by collect-diagnostics.sh.
# Layers: PEM private keys, Authorization/Bearer values, "<name>: value" pairs whose name ends in a secret-ish
# word (api_key, password, token, secret ... but not secretName), env lists written as name:/value: pairs (YAML and
# JSON, which is how `helm get manifest` and `kubectl get -o yaml` print them), then well-known key shapes anywhere.
# Uses perl (present in Git Bash, Linux and macOS) because GNU-only sed flags are not portable.
redact() {
  perl -0777 -pe '
    s/-----BEGIN [A-Z ]*PRIVATE KEY-----.*?(?:-----END [A-Z ]*PRIVATE KEY-----|\z)/<redacted-private-key>/gs;
    s/\b(authorization"?\s*[:=]\s*"?)(?:Bearer|Basic|Token)\s+[^\s",]+/$1<redacted>/gi;
    s/\b([A-Za-z0-9_-]*(?:api[-_]?key|password|passwd|token|secret|authorization)"?\s*[:=]\s*)("[^"]*"|[^\s,}]+)/$1<redacted>/gi;
    s/(name:\s*"?[A-Za-z0-9_-]*(?:api[-_]?key|password|passwd|token|secret|authorization)[A-Za-z0-9_-]*"?\s*\n\s*value:\s*)("[^"]*"|[^\s]+)/$1<redacted>/gi;
    s/("name"\s*:\s*"[^"]*(?:api[-_]?key|password|passwd|token|secret|authorization)[^"]*"\s*,\s*"value"\s*:\s*)"[^"]*"/$1"<redacted>"/gi;
    s/\bBearer\s+[A-Za-z0-9._~+\/=-]{8,}/Bearer <redacted>/gi;
    s/(?<![A-Za-z0-9])sk-(?:ant-|proj-|svcacct-|admin-)?[A-Za-z0-9_-]{16,}/<redacted>/g;
    s/\bAKIA[0-9A-Z]{16}\b/<redacted>/g;
    s/\bgh[pousr]_[A-Za-z0-9]{30,}/<redacted>/g;
    s/\bgithub_pat_[A-Za-z0-9_]{30,}/<redacted>/g;
    s/\bxox[abprs]-[A-Za-z0-9-]{10,}/<redacted>/g;
    s/\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}/<redacted>/g;
  '
}

# Port-forward the gateway Service to localhost:PORT in the background; pf_stop kills it.
PF_PID=""
pf_start() {
  local port="${1:-18080}"
  kubectl -n "$NS" port-forward "svc/$(gateway_svc)" "$port:80" >/dev/null 2>&1 &
  PF_PID=$!
  [[ -z "$(trap -p EXIT)" ]] && trap pf_stop EXIT   # do not clobber a caller's own EXIT trap
  for _ in $(seq 1 30); do
    curl -s -o "$DEVNULL" -m 1 "http://127.0.0.1:$port/healthz" && return 0
    sleep 1
  done
  die "port-forward to $(gateway_svc) did not become ready"
}
pf_stop() { [[ -n "$PF_PID" ]] && kill "$PF_PID" 2>/dev/null || true; }
