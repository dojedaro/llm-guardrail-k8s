#!/usr/bin/env bash
# Drill 6: PROVE that NetworkPolicy is enforced, not just accepted by the API server.
#   control : pod labelled guardrail-client=true in the release namespace  -> must reach the gateway
#   outsider: pod in a different namespace with no allow rule              -> must be BLOCKED
# The outsider lives in another namespace (which has no default-deny) so that ONLY the gateway's
# ingress policy can be what stops it. Enforcers block in one of two ways:
#   dropped  -> the client times out           (Calico, Cilium default)
#   rejected -> the client gets "refused"      (k3s's embedded kube-router: -j REJECT icmp-port-unreachable)
# A refusal only counts because the control pod reached the SAME Service in the same run, so the gateway
# was listening. A DNS error or an image-pull failure is reported as inconclusive, never as proof.
# Exit code 0 = enforcement proven.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/_common.sh"

IMG="$(gateway_image)"
URL="http://$(gateway_svc).$NS.svc.cluster.local/healthz"
CODE="import urllib.request as u, socket, sys
try:
    r = u.urlopen('$URL', timeout=5); print('CONNECTED', r.status)
except Exception as e:
    reason = getattr(e, 'reason', e)
    if isinstance(reason, (socket.timeout, TimeoutError)):
        print('TIMEOUT', type(reason).__name__); sys.exit(1)
    if isinstance(reason, ConnectionRefusedError):
        print('REFUSED', reason); sys.exit(1)
    print('ERROR', type(e).__name__, e); sys.exit(2)"

kubectl create namespace np-outsider --dry-run=client -o yaml | kubectl apply -f - >/dev/null
trap 'kubectl delete namespace np-outsider --wait=false >/dev/null 2>&1 || true' EXIT

log "control: allowed client (label guardrail-client=true) in namespace $NS"
if run_pod np-control "$NS" "guardrail-client=true" "$IMG" "$CODE"; then control=ok; else control=fail; fi

log "outsider: pod in namespace np-outsider, no allow rule"
if run_pod np-outsider np-outsider "" "$IMG" "$CODE"; then outsider=connected
elif grep -q '^TIMEOUT' <<<"$RUN_POD_LOG"; then outsider=blocked; how="dropped: timeout"
elif grep -q '^REFUSED' <<<"$RUN_POD_LOG"; then outsider=blocked; how="rejected: connection refused"
else outsider=inconclusive; fi

echo
echo "control  -> $control   (expected: ok)"
echo "outsider -> $outsider${how:+ ($how)}  (expected: blocked)"
if [[ "$control" == ok && "$outsider" == blocked ]]; then
  log "PASS: NetworkPolicy is enforced by this cluster: traffic $how while the control got through"
elif [[ "$control" == ok && "$outsider" == connected ]]; then
  warn "FAIL: the outsider got through. This CNI accepts NetworkPolicy objects but does NOT enforce them. Recreate the cluster with: CNI=calico scripts/cluster-up.sh"; exit 1
elif [[ "$control" != ok ]]; then
  warn "INVALID: the control pod could not connect either, so the result proves nothing. Check the release is healthy first."; exit 1
else
  warn "INCONCLUSIVE: the outsider failed for a reason other than a timeout or a refusal (see its log above): that is not proof of enforcement."; exit 1
fi
