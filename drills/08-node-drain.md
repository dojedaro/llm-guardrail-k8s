# Drill 8: planned node maintenance (node drain with PodDisruptionBudgets)

Inject: `drills/08-node-drain.sh`   Undo: `drills/08-node-drain.sh restore`

In the captures, a line starting with `$ ` is either a command that was run or, when it is not a typeable command (for example `$ managedFields after restore`), a label for the step; the output under it is what the real commands printed.
Needs the release installed with the ingress on (`values-kind.yaml`) for the request loop, and exactly two worker nodes.

## What it shows
A PodDisruptionBudget (PDB) limits voluntary disruptions such as `kubectl drain`. With `minAvailable: 1` and two replicas, a drain may
evict one gateway pod, but must wait for a replacement to be Ready before evicting the other. The drill does the hard version: both
workers are cordoned (nothing can be rescheduled) and drained one after the other, so the second drain has to be **held** by the PDBs.
A request loop (20 requests per second through the ingress) runs the whole time.

The upstream is made highly available for the drill too (`mockLlm.replicas=2`, which the chart also protects with a PDB). A single-replica
dependency has no PDB (it would block every drain), so draining its node takes the dependency down and, because the gateway's readiness
depends on the upstream, every gateway replica with it. That is the readiness trade-off in ARCHITECTURE.md seen from the operations side.

## Real run
Captured from a real run on the local kind cluster (header line of the log gives the date and versions). Nothing below is edited except where marked trimmed.

```text
# drill 08, 2026-11-27T02:22:57Z, helm v4.3.2+g8346aaa, kind v0.33.0, k8s v1.37.0, Calico v3.28.2
$ drills/08-node-drain.sh
==> last deployed (healthy) revision recorded: 48
==> step 1: make the upstream highly available too (mockLlm.replicas=2)
NAME                                 READY  STATUS   NODE
guardrail-gateway-7775f969dd-g94ms   1/1    Running  guardrail-worker2
guardrail-gateway-7775f969dd-svnlf   1/1    Running  guardrail-worker
guardrail-mock-llm-774bd8554d-6bfrg  1/1    Running  guardrail-worker2
guardrail-mock-llm-774bd8554d-tc8x9  1/1    Running  guardrail-worker
NAME                 MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
guardrail-gateway    1               N/A               1                     16m
guardrail-mock-llm   1               N/A               1                     14s
==> request loop through the ingress (20 req/s) started in the background
==> step 2: cordon both workers, then drain guardrail-worker
node/guardrail-worker cordoned
node/guardrail-worker2 cordoned
node/guardrail-worker already cordoned
Warning: ignoring DaemonSet-managed Pods: kube-system/calico-node-rl8dc, kube-system/kube-proxy-tscs7
evicting pod guardrail/guardrail-mock-llm-774bd8554d-tc8x9
evicting pod guardrail/guardrail-gateway-7775f969dd-svnlf
pod/guardrail-mock-llm-774bd8554d-tc8x9 evicted
pod/guardrail-gateway-7775f969dd-svnlf evicted
node/guardrail-worker drained
NAME                                 READY  STATUS   NODE
guardrail-gateway-7775f969dd-g94ms   1/1    Running  guardrail-worker2
guardrail-gateway-7775f969dd-jd6fj   0/1    Pending  <none>
guardrail-mock-llm-774bd8554d-6bfrg  1/1    Running  guardrail-worker2
guardrail-mock-llm-774bd8554d-bljn6  0/1    Pending  <none>
NAME                 MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
guardrail-gateway    1               N/A               0                     16m
guardrail-mock-llm   1               N/A               0                     22s
==> step 3: drain guardrail-worker2 while guardrail-worker is still cordoned (expect it to be held by the PDBs)
--- drain of guardrail-worker2 after 20 s (still waiting):
      4 error when evicting pods/"guardrail-gateway-7775f969dd-g94ms" -n "guardrail" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
      4 error when evicting pods/"guardrail-mock-llm-774bd8554d-6bfrg" -n "guardrail" (will retry after 5s): Cannot evict pod as it would violate the pod's disruption budget.
      4 evicting pod guardrail/guardrail-gateway-7775f969dd-g94ms
      4 evicting pod guardrail/guardrail-mock-llm-774bd8554d-6bfrg
NAME                                 READY  STATUS   NODE
guardrail-gateway-7775f969dd-g94ms   1/1    Running  guardrail-worker2
guardrail-gateway-7775f969dd-jd6fj   0/1    Pending  <none>
guardrail-mock-llm-774bd8554d-6bfrg  1/1    Running  guardrail-worker2
guardrail-mock-llm-774bd8554d-bljn6  0/1    Pending  <none>
NAME                 MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
guardrail-gateway    1               N/A               0                     17m
guardrail-mock-llm   1               N/A               0                     43s
==> step 4: uncordon guardrail-worker so replacements can start there; the drain of guardrail-worker2 can then proceed
node/guardrail-worker uncordoned
pod/guardrail-mock-llm-774bd8554d-6bfrg evicted
pod/guardrail-gateway-7775f969dd-g94ms evicted
node/guardrail-worker2 drained
NAME                                 READY  STATUS   NODE
guardrail-gateway-7775f969dd-jd6fj   1/1    Running  guardrail-worker
guardrail-gateway-7775f969dd-nqv2q   1/1    Running  guardrail-worker
guardrail-mock-llm-774bd8554d-bljn6  1/1    Running  guardrail-worker
guardrail-mock-llm-774bd8554d-k7scf  1/1    Running  guardrail-worker
==> waiting for the request loop to finish
requests sent: 2996 in 150s (target 20/s, 4 concurrent loops)
  HTTP 200: 2996
failed requests: 0 of 2996

==> DRILL DONE. guardrail-worker2 is still cordoned. Undo with: drills/08-node-drain.sh restore
$ drills/08-node-drain.sh restore
node/guardrail-worker2 uncordoned
==> rolling back to revision 48
Rollback was a success! Happy Helming!
NAME                                  READY   STATUS        RESTARTS   AGE
guardrail-gateway-7775f969dd-jd6fj    1/1     Running       0          2m32s
guardrail-gateway-7775f969dd-nqv2q    1/1     Running       0          2m
guardrail-mock-llm-774bd8554d-bljn6   1/1     Running       0          2m32s
guardrail-mock-llm-774bd8554d-k7scf   1/1     Terminating   0          2m
```

## Reading it
- Step 2: draining the first worker evicted one gateway and one mock pod. The PDB output afterwards shows `ALLOWED DISRUPTIONS 0` for both:
  the replacements are `Pending` (both nodes are cordoned), so only one replica of each is Ready and the budget forbids touching it.
- Step 3: the drain of the second worker **repeats** `Cannot evict pod as it would violate the pod's disruption budget` every 5 seconds
  and evicts nothing. The service keeps answering from the two pods still running there.
- Step 4: uncordoning the first worker lets the pending replacements start there; once they are Ready the budget allows the evictions and the
  second drain completes.
- The request loop recorded **no failed request** across the whole sequence (count in the capture). That is a measurement of this run on
  this cluster, not a guarantee: it depends on the preStop sleep, readiness and the ingress controller keeping up with endpoint changes.

## Diagnose a drain that hangs in production
```bash
kubectl get pdb -A                                       # ALLOWED DISRUPTIONS = 0 means the budget is holding
kubectl -n guardrail get pods -o wide                    # are replacements Pending? why?
kubectl -n guardrail describe pod <pending-pod>          # Events: FailedScheduling (cordoned nodes, no capacity, taints)
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --timeout=120s   # a timeout is safer than waiting forever
```
Common causes: replacements cannot schedule (no spare capacity, all other nodes cordoned), a replica is already unhealthy so the budget
has nothing to spare, or `minAvailable` equals the replica count (a PDB that can never be satisfied: do not do this).

## Prevention
- Drain one node at a time and wait for the replacements to be Ready before the next.
- Keep `minAvailable` below the replica count; keep at least two replicas of anything that matters, spread over nodes (`topologySpreadConstraints` is in the chart).
- The chart does not render a PDB for a single replica, because it would block every drain.
- Run the upstream with the same care as the gateway: its availability is part of the gateway's.
