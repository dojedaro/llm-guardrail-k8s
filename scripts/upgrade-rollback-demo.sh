#!/usr/bin/env bash
# Rehearse a change window twice, verifying against the LIVE gateway each time:
#   A. config change : flip policy.pii.mode (redact <-> block), verify, helm history, rollback, verify
#   B. image upgrade : gateway 0.1.0 -> 0.1.1 (a real rebuild, reported by /readyz), verify, rollback, verify
# If a verification fails after an upgrade, the script rolls the release back itself before exiting non-zero.
# Requires the release to be installed already (README, Run it). Safe to re-run.
#
# Values handling: the baseline's user-supplied values are saved to a file and passed back with -f on every
# upgrade. `--reuse-values` is avoided on purpose: it also freezes chart DEFAULTS from the old release, so new
# defaults in a newer chart version silently do not apply.
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need kubectl helm curl docker

PORT="${PORT:-18080}"
NEW_IMAGE_TAG="${NEW_IMAGE_TAG:-0.1.1}"
WORK="$REPO_ROOT/reports/.upgrade-demo"; mkdir -p "$WORK"
helm status "$RELEASE" -n "$NS" >/dev/null 2>&1 || die "release '$RELEASE' not found in namespace '$NS'. Install it first."

# Helm 4 renamed --atomic to --rollback-on-failure; Helm 3 only knows --atomic.
if helm upgrade --help 2>&1 | grep -q -- '--rollback-on-failure'; then AUTOROLLBACK=--rollback-on-failure; else AUTOROLLBACK=--atomic; fi

PENDING=""   # revision to return to if we exit non-zero while a change is live
on_exit() {
  local rc=$?
  if [[ $rc -ne 0 && -n "$PENDING" ]]; then
    warn "verification failed: rolling back to revision $PENDING"
    helm rollback "$RELEASE" "$PENDING" -n "$NS" --wait --timeout 180s || warn "automatic rollback failed: act manually"
  fi
  pf_stop
}
trap on_exit EXIT

# What does the live gateway say, and how does it treat an email address?
verify() { # verify <expected-gateway-version> <expected-pii-mode>
  local want_ver="$1" want_mode="$2" ready status want_status=200
  [[ "$want_mode" == block ]] && want_status=403
  ready="$(curl -s "http://127.0.0.1:$PORT/readyz")"
  status="$(curl -s -o "$DEVNULL" -w '%{http_code}' "http://127.0.0.1:$PORT/v1/chat" \
    -H 'content-type: application/json' \
    -d '{"messages":[{"role":"user","content":"my email is jane@example.com"}]}')"
  echo "    readyz: $ready"
  echo "    chat with an email address -> HTTP $status (expected $want_status for pii.mode=$want_mode)"
  grep -q "\"version\":\"$want_ver\"" <<<"$ready" || die "expected gateway version $want_ver"
  [[ "$status" == "$want_status" ]] || die "expected HTTP $want_status"
}
restart_pf() { pf_stop; sleep 1; pf_start "$PORT"; }   # a port-forward targets ONE pod; restart after rollouts
upgrade() { helm upgrade "$RELEASE" "$CHART" -n "$NS" -f "$WORK/base-values.yaml" --hide-notes "$AUTOROLLBACK" --wait --timeout 240s "$@"; }

helm_user_values "$WORK/base-values.yaml"
BASE_REV="$(last_deployed_revision)"
BASE_MODE="$(helm get values "$RELEASE" -n "$NS" -a -o yaml | awk '/^policy:/{p=1} p && /^  pii:/{q=1} q && /mode:/{print $2; exit}')"
BASE_TAG="$(helm get values "$RELEASE" -n "$NS" -a -o yaml | awk '/^gateway:/{g=1} g && /^  image:/{i=1} i && /tag:/{gsub(/"/,"",$2); print $2; exit}')"
NEW_MODE=block; [[ "$BASE_MODE" == block ]] && NEW_MODE=redact
log "baseline: revision $BASE_REV, pii.mode=$BASE_MODE, gateway image tag $BASE_TAG"
pf_start "$PORT"
verify "$BASE_TAG" "$BASE_MODE"

log "A. config change: pii.mode=$NEW_MODE"
PENDING="$BASE_REV"
upgrade --set "policy.version=upgrade-demo-$(date +%H%M%S)" --set "policy.pii.mode=$NEW_MODE"
restart_pf; verify "$BASE_TAG" "$NEW_MODE"
helm history "$RELEASE" -n "$NS" | tail -4
log "A. rollback to revision $BASE_REV"
helm rollback "$RELEASE" "$BASE_REV" -n "$NS" --wait --timeout 180s
PENDING=""; restart_pf; verify "$BASE_TAG" "$BASE_MODE"

log "B. image upgrade: build gateway $NEW_IMAGE_TAG and load it into the cluster"
docker build -q --build-arg "GATEWAY_VERSION=$NEW_IMAGE_TAG" -t "llm-guardrail/gateway:$NEW_IMAGE_TAG" "$REPO_ROOT/app/gateway" >/dev/null
load_images "llm-guardrail/gateway:$NEW_IMAGE_TAG"
PENDING="$(last_deployed_revision)"
upgrade --set "gateway.image.tag=$NEW_IMAGE_TAG"
restart_pf; verify "$NEW_IMAGE_TAG" "$BASE_MODE"
kubectl -n "$NS" get pods -l app.kubernetes.io/name=gateway -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.containers[0].image}{"\n"}{end}'
log "B. rollback to revision $PENDING"
helm rollback "$RELEASE" "$PENDING" -n "$NS" --wait --timeout 180s
PENDING=""; restart_pf; verify "$BASE_TAG" "$BASE_MODE"

helm history "$RELEASE" -n "$NS"
log "OK: config change and image upgrade both verified, and both rolled back"
