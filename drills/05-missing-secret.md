# Drill 5: missing or wrong Secret (CreateContainerConfigError)

Inject: `drills/05-missing-secret.sh [missing|wrongkey]`   Undo: `drills/05-missing-secret.sh restore`
No real API key is needed: the pods never start.

## Symptom
New gateway pods sit in `CreateContainerConfigError`. The container is never created, so there are **no logs at all**.
That is the key difference from a crash: `kubectl logs` returns "container ... is waiting to start".

<!-- CAPTURE: run drills/05-missing-secret.sh missing -->
<!-- CAPTURE: run drills/05-missing-secret.sh wrongkey (restore first) -->

## Diagnose
```bash
kubectl -n guardrail get pods -l app.kubernetes.io/name=gateway
kubectl -n guardrail describe pod <pod>          # Events: Error: secret "does-not-exist" not found
                                                 #     or: couldn't find key api-key in Secret guardrail/drill-wrong-key
kubectl -n guardrail get secrets                 # does it exist, in THIS namespace?
kubectl -n guardrail get secret <name> -o jsonpath='{.data}' | head -c 200   # key NAMES only; do not print values in tickets
kubectl -n guardrail get deploy guardrail-gateway -o yaml | grep -B2 -A6 secretKeyRef
```
Remember: Secrets are namespaced. A Secret created in `default` is invisible to a pod in `guardrail`, a very common cause.

<!-- CAPTURE: describe pod Events output -->

## Root cause
`missing`: the Secret named in `gateway.secret.existingSecret` does not exist in the namespace.
`wrongkey`: it exists, but has no key named `api-key` (here it has `token`); `gateway.secret.key` and the Secret disagree.

## Fix
```bash
kubectl -n guardrail create secret generic anthropic-api-key --from-literal=api-key="$ANTHROPIC_API_KEY"
# then restart the pods so they pick it up
kubectl -n guardrail rollout restart deploy/guardrail-gateway
# or revert: drills/05-missing-secret.sh restore
```

## Prevention
- Create the Secret before `helm install`, as a documented step with a verification command.
- Keep key names consistent between the Secret and `gateway.secret.key`.
- The gateway also refuses to start with `UPSTREAM_KIND=anthropic` and an empty key, so a blank Secret fails loudly rather than sending unauthenticated requests.
- `helm upgrade --atomic` reverts a rollout that never becomes Ready.
