# Drill 7: configuration drift (a hand edit blocks `helm upgrade`)

Inject: `drills/07-config-drift.sh`   Undo: `drills/07-config-drift.sh restore`

I found this one by accident while running the integration tests. They used to break the mock LLM with
`kubectl set env`, and the next drill's `helm upgrade` then failed. It is the most realistic drill
here: at a customer site, someone "temporarily" edits a Deployment during an incident, and weeks later the
planned upgrade fails during the change window.

## Symptom
```
Error: UPGRADE FAILED: conflict occurred while applying object guardrail/guardrail-mock-llm apps/v1, Kind=Deployment:
Apply failed with 1 conflict: conflict with "kubectl-set" using apps/v1:
.spec.template.spec.containers[name="mock-llm"].env[name="MOCK_ERROR_RATE"].value
```
(Captured on Helm v4.3.2 and Kubernetes v1.37.0 (kind v0.33.0), 2026-11-27.)

## Diagnose
```bash
helm history guardrail -n guardrail                     # last revision failed
kubectl -n guardrail get deploy guardrail-mock-llm --show-managed-fields -o yaml | less
#   look for a managedFields entry whose manager is not "helm", e.g. manager: kubectl-set
helm get values guardrail -n guardrail -a | grep -A3 faults   # what Helm thinks the value is
kubectl -n guardrail get deploy guardrail-mock-llm -o jsonpath='{.spec.template.spec.containers[0].env}'  # what is live
```
The conflict message names both the field and the manager that changed it. Comparing `helm get values` with the
live object shows how far the drift goes.

## Root cause
Helm 4 uses server-side apply by default. Every field has an owner (a "field manager"). `kubectl set env`
made `kubectl-set` the owner of that env var, and server-side apply will not overwrite another manager's field
without permission. Helm 3 (client-side 3-way merge) would usually have overwritten the hand edit silently, which
hides the drift instead.

## Fix
1. Decide which value is correct. Was the hand edit a real fix that belongs in values.yaml?
2. If it should stay, add it to the values and upgrade. If not, take ownership back:
   `helm upgrade guardrail charts/llm-guardrail -n guardrail --reuse-values --force-conflicts`
Never use `--force-conflicts` before step 1. It throws away whatever the other person changed.

## Prevention
- Make all changes through Helm, including incident hot-fixes (`helm upgrade --set ...`), so `helm history` stays the audit trail.
- Limit who can `patch` Deployments in the namespace (RBAC); give operators a runbook instead of kubectl edit.
- Before each change window, run a drift check: `helm diff upgrade` (plugin), or compare `helm get manifest` with live objects.
