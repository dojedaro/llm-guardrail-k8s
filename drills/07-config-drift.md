# Drill 7: configuration drift (a hand edit blocks `helm upgrade`)

Inject: `drills/07-config-drift.sh`   Undo: `drills/07-config-drift.sh restore`

In the captures, a line starting with `$ ` is either a command that was run or, when it is not a typeable command (for example `$ managedFields after restore`), a label for the step; the output under it is what the real commands printed.

This is written as a customer-style incident report; there was no actual customer. The system is the lab cluster; the incident was found by accident while
running the integration tests and then reproduced on purpose by the drill. Versions: Helm v4.3.2, kubectl v1.36.1 client, Kubernetes v1.37.0
(kind v0.33.0), 2026-11-27.

## Summary
A planned `helm upgrade` failed with a field-ownership conflict because someone had earlier changed an environment variable on a
Helm-managed Deployment with `kubectl set env`. The failed upgrade changed nothing live. The cost was
a blocked change window, a `failed` revision in the release history, and (in the worst variant, below) a stale field owner that makes the
*next* upgrade fail again even after a "fix".

## Impact
- Customer-facing (hypothetical, lab only): none observed. The failed upgrade changed no live object, and the gateway pods were not touched. The hand edit itself rolled the single mock-llm pod; no request loop was running during this drill, so there is no measurement of that moment.
- Operational: the upgrade could not be applied; `helm history` showed revision 6 as `failed` (capture below); anyone reading `helm list`
  would see the release as `failed` even though every pod was healthy.

## Timeline (real run, UTC)
| Time | Event |
|---|---|
| 04:36:30 | Operator runs `kubectl set env deploy/guardrail-mock-llm MOCK_LATENCY_MS=1` ("temporary" change). Deployment rolls; `kubectl-set` becomes owner of that env var. |
| 04:36:38 | Planned change window: `helm upgrade ... --set policy.version=drift-demo --wait`. Helm 4 applies server-side, the API server reports a conflict, Helm records revision 6 as `failed`. |
| 04:36:39 | `managedFields` inspected: `helm` (Apply) and `kubectl-set` (Update) both appear, the latter owns the env var. |
| 04:36:51 | Resolution: the stale `kubectl-set` field manager removed, ownership re-asserted with `helm upgrade --force-conflicts`, then rolled back to the last deployed revision (5). |

## What the customer-visible error would look like
```text
# drill 07, 2026-11-27T04:36:27Z, helm v4.3.2+g8346aaa, kind v0.33.0, k8s v1.37.0
$ drills/07-config-drift.sh
==> last deployed (healthy) revision recorded: 5
==> hand edit, outside Helm: kubectl set env deploy/guardrail-mock-llm MOCK_LATENCY_MS=1
deployment.apps/guardrail-mock-llm env updated
Waiting for deployment "guardrail-mock-llm" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "guardrail-mock-llm" rollout to finish: 1 old replicas are pending termination...
deployment "guardrail-mock-llm" successfully rolled out
==> a routine change window: helm upgrade with a new policy version (expected to FAIL)
Error: UPGRADE FAILED: conflict occurred while applying object guardrail/guardrail-mock-llm apps/v1, Kind=Deployment: Apply failed with 1 conflict: conflict with "kubectl-set" using apps/v1: .spec.template.spec.containers[name="mock-llm"].env[name="MOCK_LATENCY_MS"].value
==> release status after the failed upgrade
4       	Fri Nov 27 13:34:41 2026	superseded	llm-guardrail-0.1.0	0.1.0  Upgrade complete                                                                
5       	Fri Nov 27 13:35:05 2026	deployed  llm-guardrail-0.1.0	0.1.0      	Rollback to 3                                   
6       	Fri Nov 27 13:36:38 2026	failed  llm-guardrail-0.1.0	0.1.0      	Upgrade "guardrail" failed: conflict occurred wh
==> who owns the conflicting field? (managedFields)
  [0] manager=helm                     operation=Apply   time=2026-11-27T04:35:05Z
  [1] manager=kubectl-set              operation=Update  time=2026-11-27T04:36:30Z
  [2] manager=kube-controller-manager  operation=Update  time=2026-11-27T04:36:39Z

==> FAULT INJECTED: mock-llm env edited by kubectl; helm upgrade blocked
    Now diagnose it. Writeup: drills/07-config-drift.md
    Undo with: drills/07-config-drift.sh restore
exit code: 0
$ kubectl describe/get: who changed it
MOCK_LATENCY_MS=1
MOCK_ERROR_RATE=0
$ helm get values (what Helm believes)
mockLlm:
  enabled: true
  faults:
    errorRate: 0
    latencyMs: 0
  image:
$ drills/07-config-drift.sh restore
==> removing the stale 'kubectl-set' field manager (managedFields[1])
deployment.apps/guardrail-mock-llm patched
==> rolling back to revision 5
Rollback was a success! Happy Helming!
NAME                                  READY   STATUS      RESTARTS   AGE
guardrail-gateway-646c646f9f-9prw6    1/1     Running     0          101s
guardrail-gateway-646c646f9f-nstnc    1/1     Running     0          108s
guardrail-mock-llm-75598fd896-6pp7j   1/1     Running     0          11s
guardrail-mock-llm-78657c4b49-rbjzt   0/1     Completed   0          23s
guardrail-smoke-test                  0/1     Completed   0          3m4s
exit code: 0
$ helm status after restore
NAME: guardrail
LAST DEPLOYED: Fri Nov 27 13:36:51 2026
NAMESPACE: guardrail
STATUS: deployed
REVISION: 8
DESCRIPTION: Rollback to 5
$ managedFields after restore
  [0] manager=helm                     operation=Apply
  [1] manager=kube-controller-manager  operation=Update
```

## Diagnosis
```bash
helm history guardrail -n guardrail                                   # last revision "failed", message names the conflict
kubectl -n guardrail get deploy guardrail-mock-llm --show-managed-fields -o yaml | less
#   look for a managedFields entry whose manager is not "helm", e.g. manager: kubectl-set, operation: Update
helm get values guardrail -n guardrail -a | grep -A3 faults           # what Helm believes the value is
kubectl -n guardrail get deploy guardrail-mock-llm -o jsonpath='{.spec.template.spec.containers[0].env}'   # what is live
```
The conflict message names both the field and the manager that changed it.

## Root cause
Helm 4 applies manifests with **server-side apply** by default. Every field has an owner (a "field manager"). `kubectl set env` made
`kubectl-set` the owner of that env var, and server-side apply will not overwrite another manager's field without being told to. Helm 3
(client-side three-way merge) would usually have overwritten the hand edit silently, which hides the drift instead of surfacing it.

## Resolution, and two things that did not work the way we expected
All three were checked live on the same cluster, with the same versions, on the same day:

1. **`helm upgrade --force-conflicts` works when Helm's value differs from the hand edit.** Helm wants `0`, the live value is `1`: forcing
   takes the field over, and afterwards only `helm` owns it. `drills/07-config-drift.sh restore` does this, but first removes the stale `kubectl-set` manager entry (the capture
   above shows it) and only then re-applies with `--force-conflicts`, so it also works when the two values are equal (point 2). Decide first which value is
   right: forcing throws away whatever the other person changed.
2. **A shared field is not cleaned up by `--force-conflicts`.** If the hand-edited value equals what Helm is told to apply (we set
   `MOCK_LATENCY_MS=1` by hand and ran `helm upgrade --set mockLlm.faults.latencyMs=1`), both managers co-own the field and there is no
   conflict. Running the same upgrade again with `--force-conflicts` and an *unchanged* value leaves `kubectl-set` in `managedFields`.
   The next upgrade that changes the value (we used `latencyMs=5`) then fails with the same conflict again. The fix that worked was
   removing the stale manager entry:
   ```bash
   kubectl -n guardrail patch deploy/guardrail-mock-llm --type=json \
     -p '[{"op":"remove","path":"/metadata/managedFields/<index of kubectl-set>"}]'
   ```
   after which the same `helm upgrade` succeeded and `helm` was the only owner.
3. **`helm upgrade --force-replace` is not an escape hatch on Helm 4.3.2**: it fails immediately with
   `cannot use server-side apply and force replace together`.

## Prevention
- Make every change through Helm, including incident hot-fixes (`helm upgrade --set ...`), so `helm history` stays the audit trail.
  The integration tests that inject faults do exactly that (and not `kubectl set env`), which is how this incident was found.
- Limit who can `patch` Deployments in the namespace (RBAC); give operators a runbook instead of `kubectl edit`.
- Add a drift check to the change checklist: `helm diff upgrade` (plugin), or compare `helm get manifest` with the live objects, and look
  at `managedFields` for managers other than `helm` before the window.
- When a hand edit is unavoidable, record it, and remove the manager entry (item 2) when reverting, not only the value.
