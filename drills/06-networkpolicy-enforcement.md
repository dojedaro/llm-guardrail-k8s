# Drill 6: prove NetworkPolicy is actually enforced

Run: `drills/06-networkpolicy-enforcement.sh` (read-only apart from two short-lived test pods and the namespace `np-outsider`).

In the captures, a line starting with `$ ` is either a command that was run or, when it is not a typeable command (for example `$ managedFields after restore`), a label for the step; the output under it is what the real commands printed.

## Why this drill exists
The Kubernetes API accepts a NetworkPolicy on **any** cluster. Whether packets are really dropped depends on the CNI plugin.
If it does not enforce policies, the "default deny" in this chart is decoration and a customer's security review would be misled.
So the claim is tested, not assumed.

## What it does
1. **Control**: a pod in the release namespace with label `guardrail-client=true` calls the gateway. It must succeed
   (this proves the cluster, DNS and the gateway are healthy, so a failure below is meaningful).
2. **Outsider**: a pod in another namespace (`np-outsider`, which has no default-deny of its own) calls the same gateway.
   Only the gateway's ingress policy can stop it. Enforcers block in one of two ways, and both count: **dropped** (the client
   times out: Calico, Cilium) or **rejected** (the client gets "connection refused": k3s's embedded kube-router answers with
   `-j REJECT --reject-with icmp-port-unreachable`). A refusal is accepted only because the control pod reached the *same* Service
   in the same run, so the gateway was listening. A DNS error or an image-pull failure is reported as *inconclusive*, never as proof.
   Both pods run with a restricted security context, so the drill also works in a namespace that enforces the `restricted` Pod Security profile.

Exit code 0 means enforcement is proven.

## Real run
Captured from a real run on the local kind cluster (header line of the log gives the date and versions). Nothing below is edited except where marked trimmed.

```text
# drill 06, 2026-11-27T04:36:06Z, kind v0.33.0, k8s v1.37.0, Calico v3.28.2
$ drills/06-networkpolicy-enforcement.sh
==> control: allowed client (label guardrail-client=true) in namespace guardrail
    | CONNECTED 200
==> outsider: pod in namespace np-outsider, no allow rule
    | TIMEOUT TimeoutError

control  -> ok   (expected: ok)
outsider -> blocked (dropped: timeout)  (expected: blocked)
==> PASS: NetworkPolicy is enforced by this cluster: traffic dropped: timeout while the control got through
exit code: 0
$ kubectl describe networkpolicy guardrail-gateway-ingress
Spec:
  PodSelector:     app.kubernetes.io/instance=guardrail,app.kubernetes.io/name=gateway
  Allowing ingress traffic:
    To Port: 8080/TCP
    From:
      NamespaceSelector: kubernetes.io/metadata.name=ingress-nginx
    From:
      PodSelector: guardrail-client=true
  Not affecting egress traffic
  Policy Types: Ingress
$ which CNI
calico-kube-controllers-bf9bccf8c-7djvk           1/1     Running   0          41m
calico-node-5l8q2                                 1/1     Running   0          41m
calico-node-d6ps7                                 1/1     Running   0          41m
```

## Interpreting the result
| control | outsider | Meaning |
|---|---|---|
| ok | blocked (timeout, or refused) | Enforced: dropped or rejected, depending on the CNI. |
| ok | connected | Not enforced: the CNI ignores policies. Recreate with `CNI=calico scripts/cluster-up.sh` and re-run. |
| ok | inconclusive | The outsider failed for another reason (see its log); fix that and re-run. |
| fail | any | Test is invalid: fix the release first (`helm test`, `kubectl get pods`). |

## Prevention
- Make the enforcement test part of every environment assessment for a new cluster (`PROBE_NETPOL=1 scripts/preflight.sh` is a generic
  version with a positive control and the same timeout-or-refused rule).
- State which CNI was verified in the deployment report.

## Note on kind
Whether kind's default CNI (kindnet) enforces NetworkPolicy depends on the version bundled with the node image. This repo does not rely on
memory of that: it ships a Calico option and this drill. All runs recorded here used Calico v3.28.2; the default-CNI case was not tested.
