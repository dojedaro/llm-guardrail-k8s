#!/usr/bin/env bash
# Measure what clients see during rolling updates: a steady request loop goes through the ingress while the release is
# upgraded three times (two policy changes, one gateway image change), then rolled back. Prints the real error count.
# Needs the release installed with values-kind.yaml (ingress on; kind maps host port 8080 to the controller).
#
#   scripts/rollout-availability.sh            # about 2.5 minutes; DURATION=200 to make it longer
set -euo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need helm docker kubectl curl
[[ -n "$PYTHON" ]] || die "python3 (or python) is required"

DURATION="${DURATION:-150}"; RATE="${RATE:-20}"
NEW_TAG="${NEW_IMAGE_TAG:-0.1.1}"
URL=http://127.0.0.1:8080
WORK="$REPO_ROOT/reports/.rollout-availability"; mkdir -p "$WORK"
HEAD=(-H 'Host: guardrail.localtest.me' -H 'content-type: application/json')

code="$(curl -s -o "$DEVNULL" -w '%{http_code}' -m 3 "${HEAD[@]}" -d '{}' "$URL/v1/chat" || true)"
[[ "$code" == 422 ]] || die "the ingress does not answer on $URL (got '$code'): install with -f charts/llm-guardrail/values-kind.yaml"
helm_user_values "$WORK/base.yaml"
BASE_REV="$(last_deployed_revision)"
if ! docker image inspect "llm-guardrail/gateway:$NEW_TAG" >/dev/null 2>&1; then
  log "building gateway $NEW_TAG"
  docker build -q --build-arg "GATEWAY_VERSION=$NEW_TAG" -t "llm-guardrail/gateway:$NEW_TAG" "$REPO_ROOT/app/gateway" >/dev/null
fi
load_images "llm-guardrail/gateway:$NEW_TAG" >/dev/null

up() { helm upgrade "$RELEASE" "$CHART" -n "$NS" -f "$WORK/base.yaml" --wait --timeout 240s "$@" >/dev/null; }

log "request loop: ${RATE}/s for ${DURATION}s through the ingress"
"$PYTHON" "$REPO_ROOT/scripts/availability_probe.py" --url "$URL" --host guardrail.localtest.me \
  --seconds "$DURATION" --rate "$RATE" > "$WORK/probe.out" 2>&1 &
PROBE=$!
sleep 8
log "rollout 1: policy.version change";    up --set policy.version=rollout-1
log "rollout 2: policy.version change";    up --set policy.version=rollout-2
log "rollout 3: gateway image $NEW_TAG";   up --set policy.version=rollout-2 --set "gateway.image.tag=$NEW_TAG"
log "rollback to revision $BASE_REV"
helm rollback "$RELEASE" "$BASE_REV" -n "$NS" --wait --timeout 240s >/dev/null
wait "$PROBE" || true
echo; echo "result (4 rollouts happened during the loop: 3 upgrades and 1 rollback):"
cat "$WORK/probe.out"
