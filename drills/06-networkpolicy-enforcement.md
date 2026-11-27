# Drill 6: prove NetworkPolicy is actually enforced

Run: `drills/06-networkpolicy-enforcement.sh` (read-only apart from two short-lived test pods and the namespace `np-outsider`).

## Why this drill exists
The Kubernetes API accepts a NetworkPolicy on **any** cluster. Whether packets are really dropped depends on the CNI plugin.
If it does not enforce policies, the "default deny" in this chart is decoration and a customer's security review would be misled.
So the claim is tested, not assumed.

## What it does
1. **Control**: a pod in the release namespace with label `guardrail-client=true` calls the gateway. It must succeed
   (this proves the cluster, DNS and the gateway are healthy, so a failure below is meaningful).
2. **Outsider**: a pod in another namespace (`np-outsider`, which has no default-deny of its own) calls the same gateway.
   Only the gateway's ingress policy can stop it, and it must time out.

Exit code 0 means enforcement is proven.

<!-- CAPTURE: run drills/06-networkpolicy-enforcement.sh -->

## Interpreting the result
| control | outsider | Meaning |
|---|---|---|
| ok | blocked | Enforced. |
| ok | connected | Not enforced: the CNI ignores policies. Recreate with `CNI=calico scripts/cluster-up.sh` and re-run. |
| fail | any | Test is invalid: fix the release first (`helm test`, `kubectl get pods`). |

## Diagnose manually
```bash
kubectl -n guardrail get networkpolicy
kubectl -n guardrail describe networkpolicy guardrail-gateway-ingress
kubectl -n kube-system get pods | grep -Ei 'calico|cilium|kindnet|antrea|weave'     # which CNI?
```

## Prevention
- Make the enforcement test part of every environment assessment for a new cluster (`PROBE_NETPOL=1 scripts/preflight.sh` does a generic version).
- State which CNI was verified in the deployment report.

## Note on kind
Whether kind's default CNI (kindnet) enforces NetworkPolicy depends on the kindnet version bundled with the node image.
Older versions did not; newer ones are reported to. This repo does not rely on memory of that: it ships a Calico option and this drill.
