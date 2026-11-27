# Drill 4: memory limit too low (OOMKilled)

Inject: `drills/04-oomkilled.sh`   Undo: `drills/04-oomkilled.sh restore`

## Symptom
New gateway pods restart repeatedly: status goes `Running` -> `OOMKilled` -> `CrashLoopBackOff`, with a growing RESTARTS count.
The old pods keep serving (`maxUnavailable: 0`) so users may notice nothing; the stuck rollout is the only sign.

<!-- CAPTURE: run drills/04-oomkilled.sh -->

## Diagnose
```bash
kubectl -n guardrail get pods -l app.kubernetes.io/name=gateway          # RESTARTS rising, CrashLoopBackOff
kubectl -n guardrail describe pod <pod> | grep -A8 "Last State"          # Reason: OOMKilled, Exit Code: 137
kubectl -n guardrail logs <pod> --previous                               # last words of the crashed container (may be empty)
kubectl -n guardrail get pod <pod> -o jsonpath='{.spec.containers[0].resources}{"\n"}'
kubectl top pod -n guardrail                                             # needs metrics-server; compare usage with the limit
```
Exit code 137 is 128 + 9 (SIGKILL). `Reason: OOMKilled` says the kernel killed it for exceeding the memory limit, as opposed
to a failing liveness probe, where the event says `Liveness probe failed` and the reason is not OOMKilled.

<!-- CAPTURE: describe pod "Last State" output -->

## Root cause
`resources.limits.memory` (20Mi) is below what the Python process needs at startup (interpreter plus FastAPI/uvicorn imports).

## Fix
`helm rollback`, or raise the limit (the chart default is 256Mi). Choose the number from measurement, not guesswork:
run under load, read `kubectl top`, then set the limit with headroom (for example 2x the observed peak) and the request near the typical usage.

## Prevention
- Load-test and record memory before shipping default limits; document the sizing in the deployment guide.
- Alert on `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}` (kube-state-metrics) and on restart counts.
- Use `helm upgrade --atomic` so a crash-looping rollout is reverted automatically.
