# Drill 4: memory limit too low (OOMKilled)

Inject: `drills/04-oomkilled.sh`   Undo: `drills/04-oomkilled.sh restore`

## Symptom
New gateway pods restart repeatedly: status goes `Running` -> `OOMKilled` -> `CrashLoopBackOff`, with a growing RESTARTS count.
The old pods keep serving (`maxUnavailable: 0`), so users may notice nothing; the stuck rollout is the only sign.

## Real run
Captured from a real run on the local kind cluster (header line of the log gives the date and versions). Nothing below is edited except where marked trimmed.

```text
# drill 04, 2026-11-27T02:32:11Z, helm v4.3.2+g8346aaa, kind v0.33.0, k8s v1.37.0
$ drills/04-oomkilled.sh
==> last deployed (healthy) revision recorded: 60
Release "guardrail" has been upgraded. Happy Helming!
(helm output trimmed)
NAME                                 READY   STATUS             RESTARTS     AGE
guardrail-gateway-5d846f4bd6-79m2g   1/1     Running            0            56s
guardrail-gateway-5d846f4bd6-g9llc   1/1     Running            0            20s
guardrail-gateway-758cf569d5-7j9fx   0/1     CrashLoopBackOff   1 (2s ago)   7s

==> FAULT INJECTED: gateway memory limit 20Mi
    Now diagnose it. Writeup: drills/04-oomkilled.md
    Undo with: drills/04-oomkilled.sh restore
pod: guardrail-gateway-758cf569d5-7j9fx
$ kubectl describe pod | grep -A8 "Last State"
    Host Port:      0/TCP (http)
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
      Started:      Fri, 27 Nov 2026 11:32:16 +0900
      Finished:     Fri, 27 Nov 2026 11:32:18 +0900
    Ready:          False
    Restart Count:  1
    Limits:
      cpu:     500m
      memory:  20Mi
$ kubectl logs --previous  (the process was killed before it could log anything)
$ resources of the pod
{"limits":{"cpu":"500m","memory":"20Mi"},"requests":{"cpu":"100m","memory":"16Mi"}}
$ events
  Type     Reason     Age              From               Message
  ----     ------     ----             ----               -------
  Normal   Scheduled  8s               default-scheduler  Successfully assigned guardrail/guardrail-gateway-758cf569d5-7j9fx to guardrail-worker
  Normal   Pulled     5s (x2 over 7s)  kubelet            spec.containers{gateway}: Container image "llm-guardrail/gateway:0.1.0" already present on machine and can be accessed by the pod
  Normal   Created    5s (x2 over 7s)  kubelet            spec.containers{gateway}: Container created
  Normal   Started    5s (x2 over 7s)  kubelet            spec.containers{gateway}: Container started
  Warning  Unhealthy  4s (x2 over 6s)  kubelet            spec.containers{gateway}: Startup probe failed: Get "http://192.168.135.215:8080/healthz": dial tcp 192.168.135.215:8080: connect: connection refused
  Warning  BackOff    1s (x3 over 3s)  kubelet            spec.containers{gateway}: Back-off restarting failed container gateway in pod guardrail-gateway-758cf569d5-7j9fx_guardrail(b7029d86-6ffe-41d7-9708-58ef6aa65f41)
$ drills/04-oomkilled.sh restore
Rollback was a success! Happy Helming!
NAME                                  READY   STATUS      RESTARTS     AGE
guardrail-gateway-5d846f4bd6-79m2g    1/1     Running     0            59s
guardrail-gateway-5d846f4bd6-g9llc    1/1     Running     0            23s
guardrail-gateway-758cf569d5-7j9fx    0/1     OOMKilled   1 (5s ago)   10s
guardrail-mock-llm-774bd8554d-t5znh   1/1     Running     0            107s
```

Note `kubectl logs --previous` printed nothing: the process was killed by the kernel before it logged anything, which is itself a clue
(a crash with a Python traceback would have left log lines).

## Diagnose
```bash
kubectl -n guardrail get pods -l app.kubernetes.io/name=gateway          # RESTARTS rising, CrashLoopBackOff
kubectl -n guardrail describe pod <pod> | grep -A8 "Last State"          # Reason: OOMKilled, Exit Code: 137
kubectl -n guardrail logs <pod> --previous                               # last words of the crashed container (may be empty)
kubectl -n guardrail get pod <pod> -o jsonpath='{.spec.containers[0].resources}{"\n"}'
kubectl top pod -n guardrail                                             # needs metrics-server (not installed in this lab)
```
Exit code 137 is 128 + 9 (SIGKILL). `Reason: OOMKilled` says the kernel killed it for exceeding the memory limit, as opposed to a failing
liveness probe, where the event says `Liveness probe failed` and the reason is not OOMKilled.

## Root cause
`resources.limits.memory` (20Mi) is below what the Python process needs at startup (interpreter plus FastAPI/uvicorn imports).

## Fix
`helm rollback`, or raise the limit (the chart default is 256Mi). Choose the number from measurement: run under load, read the
real usage, then set the limit with headroom and the request near the typical usage.

## Prevention
- Load-test and record memory before shipping default limits; document the sizing in the deployment guide.
- Alert on `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}` (kube-state-metrics) and on restart counts.
- Use `helm upgrade --rollback-on-failure` (Helm 4; `--atomic` on Helm 3) so a crash-looping rollout is reverted automatically.
