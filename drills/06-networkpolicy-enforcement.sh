#!/usr/bin/env bash
# Drill 6: PROVE that NetworkPolicy is enforced, not just accepted by the API server.
#   control : pod labelled guardrail-client=true in the release namespace  -> must reach the gateway
#   outsider: pod in a different namespace with no allow rule              -> must be blocked
# The outsider lives in another namespace (which has no default-deny) so that ONLY the gateway's
# ingress policy can be what stops it. Exit code 0 = enforcement proven.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

IMG="$(gateway_image)"
URL="http://$(gateway_svc).$NS.svc.cluster.local/healthz"
CODE="import urllib.request as u,sys
try:
    r=u.urlopen('$URL',timeout=5); print('CONNECTED', r.status)
except Exception as e:
    print('BLOCKED/FAILED:', type(e).__name__, e); sys.exit(1)"

kubectl create namespace np-outsider --dry-run=client -o yaml | kubectl apply -f - >/dev/null
trap 'kubectl delete namespace np-outsider --wait=false >/dev/null 2>&1 || true' EXIT

log "control: allowed client (label guardrail-client=true) in namespace $NS"
if run_pod np-control "$NS" "guardrail-client=true" "$IMG" "$CODE"; then control=ok; else control=fail; fi

log "outsider: pod in namespace np-outsider, no allow rule"
if run_pod np-outsider np-outsider "" "$IMG" "$CODE"; then outsider=connected; else outsider=blocked; fi

echo
echo "control  -> $control   (expected: ok)"
echo "outsider -> $outsider  (expected: blocked)"
if [[ "$control" == ok && "$outsider" == blocked ]]; then
  log "PASS: NetworkPolicy is enforced by this cluster's CNI"
else
  if [[ "$control" == ok && "$outsider" == connected ]]; then
    warn "FAIL: the outsider got through. This CNI accepts NetworkPolicy objects but does NOT enforce them. Recreate the cluster with: CNI=calico scripts/cluster-up.sh"
  else
    warn "FAIL: the control pod could not connect either, so the result proves nothing. Check the release is healthy first."
  fi
  exit 1
fi
