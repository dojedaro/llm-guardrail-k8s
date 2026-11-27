# Drill 2: upstream LLM failure (readiness failing, 502, 504)

Inject: `drills/02-upstream-failure.sh [url|502|504]`   Undo: `drills/02-upstream-failure.sh restore`

In the captures, a line starting with `$ ` is either a command that was run or, when it is not a typeable command (for example `$ managedFields after restore`), a label for the step; the output under it is what the real commands printed.

| Mode | What is broken | What the client sees |
|---|---|---|
| `url` | upstream URL in the config points at a Service that does not exist | new pods stay `0/1 Ready` (readiness fails); old pods keep serving |
| `502` | mock LLM answers HTTP 500 to every call (`MOCK_ERROR_RATE=1`) | gateway returns HTTP 502 with a request id |
| `504` | mock LLM is slower (15 s) than the gateway timeout (3 s) | gateway returns HTTP 504 with a request id |

`502` / `504`: pods stay Ready (readiness only tests that the upstream answers `/healthz`, not that the model works), but chat calls fail.

## Real run: `url`
Captured from a real run on the local kind cluster (header line of the log gives the date and versions). Nothing below is edited except where marked trimmed.

```text
# drill 02, 2026-11-27T02:13:57Z, helm v4.3.2+g8346aaa, kind v0.33.0, k8s v1.37.0
=== mode: url
$ drills/02-upstream-failure.sh url
==> last deployed (healthy) revision recorded: 15
Release "guardrail" has been upgraded. Happy Helming!
NAME                                  READY   STATUS      RESTARTS   AGE
guardrail-gateway-5bb8b749c4-t5jhf    0/1     Running     0          7s
guardrail-gateway-86f69d77d7-2t6r5    1/1     Running     0          4m24s
guardrail-gateway-86f69d77d7-jfxzh    1/1     Running     0          4m19s
guardrail-mock-llm-75598fd896-s8l7q   1/1     Running     0          4m24s
guardrail-smoke-test                  0/1     Completed   0          7m35s
==> FAULT INJECTED: upstream failure, mode=url
new pod: guardrail-gateway-5bb8b749c4-t5jhf
$ kubectl describe pod (Events)
Events:
  Type     Reason     Age   From               Message
  ----     ------     ----  ----               -------
  Normal   Scheduled  8s    default-scheduler  Successfully assigned guardrail/guardrail-gateway-5bb8b749c4-t5jhf to guardrail-worker
  Normal   Pulled     8s    kubelet            spec.containers{gateway}: Container image "llm-guardrail/gateway:0.1.0" already present on machine and can be accessed by the pod
  Normal   Created    8s    kubelet            spec.containers{gateway}: Container created
  Normal   Started    7s    kubelet            spec.containers{gateway}: Container started
  Warning  Unhealthy  6s    kubelet            spec.containers{gateway}: Startup probe failed: Get "http://192.168.135.240:8080/healthz": dial tcp 192.168.135.240:8080: connect: connection refused
  Warning  Unhealthy  2s    kubelet            spec.containers{gateway}: Readiness probe failed: HTTP probe failed with statuscode: 503
$ kubectl logs <new pod> (not-ready lines)
{"ts": "2026-11-27T02:14:05.685885+00:00", "level": "WARNING", "msg": "not ready", "version": "0.1.0", "policy_loaded": true, "upstream_reachable": false, "policy_version": "2026-11-27.1", "upstream_url": "http://mock-llm-typo:808 ...[line cut]
$ kubectl get svc,endpoints
NAME                         TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)    AGE
service/guardrail-gateway    ClusterIP   10.96.196.175   <none>        80/TCP     7m44s
service/guardrail-mock-llm   ClusterIP   10.96.231.24    <none>        8080/TCP   7m44s

NAME                           ENDPOINTS                                  AGE
endpoints/guardrail-gateway    192.168.135.235:8080,192.168.41.178:8080   7m44s
endpoints/guardrail-mock-llm   192.168.41.177:8080                        7m44s
$ UPSTREAM_URL env
UPSTREAM_URL=http://mock-llm-typo:8080
$ rollout status
Waiting for deployment "guardrail-gateway" rollout to finish: 1 out of 2 new replicas have been updated...
error: timed out waiting for the condition
$ drills/02-upstream-failure.sh restore
NAME                                  READY   STATUS        RESTARTS   AGE
guardrail-gateway-5bb8b749c4-t5jhf    0/1     Terminating   0          14s
guardrail-gateway-86f69d77d7-2t6r5    1/1     Running       0          4m31s
guardrail-gateway-86f69d77d7-jfxzh    1/1     Running       0          4m26s
guardrail-mock-llm-75598fd896-s8l7q   1/1     Running       0          4m31s
guardrail-smoke-test                  0/1     Completed     0          7m42s
```

The `not ready` log line is the shortest path to the answer: `upstream_url` shows the typo, `upstream_error` the failure class.
(Here it is `ConnectTimeout`: the readiness check gives the upstream 2 seconds, and resolving a name that does not exist took longer
than that, so it surfaces as a timeout rather than a resolver error. Do not read it as "the network is slow".)

## Real run: `502`
```text
# drill 02 mode 502, 2026-11-27T02:14:21Z, helm v4.3.2+g8346aaa, kind v0.33.0, k8s v1.37.0
$ drills/02-upstream-failure.sh 502
==> last deployed (healthy) revision recorded: 17
Release "guardrail" has been upgraded. Happy Helming!
deployment "guardrail-gateway" successfully rolled out
Waiting for deployment "guardrail-mock-llm" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "guardrail-mock-llm" rollout to finish: 1 old replicas are pending termination...
deployment "guardrail-mock-llm" successfully rolled out
A chat request now:
HTTP/1.1 502 Bad Gateway
x-request-id: 816cf32aa0eb4e7e
{"request_id":"816cf32aa0eb4e7e","policy_version":"2026-11-27.1","error":"upstream_unavailable"}
NAME                                  READY   STATUS      RESTARTS   AGE
guardrail-gateway-86f69d77d7-2t6r5    1/1     Running     0          4m47s
guardrail-gateway-86f69d77d7-jfxzh    1/1     Running     0          4m42s
guardrail-mock-llm-75598fd896-s8l7q   0/1     Completed   0          4m47s
guardrail-mock-llm-865bb986c9-5gfm6   1/1     Running     0          7s
guardrail-smoke-test                  0/1     Completed   0          7m58s
==> FAULT INJECTED: upstream failure, mode=502
$ kubectl logs (request lines, gateway)
{"ts": "2026-11-27T02:14:29.714039+00:00", "level": "WARNING", "msg": "request", "request_id": "526a2746683e4e47", "policy_version": "2026-11-27.1", "decision": "upstream_error", "error": "unavailable", "detail": "upstream returne ...[line cut]
{"ts": "2026-11-27T02:14:29.777378+00:00", "level": "WARNING", "msg": "request", "request_id": "816cf32aa0eb4e7e", "policy_version": "2026-11-27.1", "decision": "upstream_error", "error": "unavailable", "detail": "upstream returne ...[line cut]
$ metrics
gateway_upstream_errors_total{kind="unavailable"} 2.0

$ mock-llm env (fault knobs)
MOCK_LATENCY_MS=0
MOCK_ERROR_RATE=1
$ gateway timeout env
UPSTREAM_TIMEOUT_S=10
$ drills/02-upstream-failure.sh restore
NAME                                  READY   STATUS        RESTARTS   AGE
guardrail-gateway-86f69d77d7-2t6r5    1/1     Running       0          4m56s
guardrail-gateway-86f69d77d7-jfxzh    1/1     Running       0          4m51s
guardrail-mock-llm-75598fd896-bt48h   1/1     Running       0          7s
guardrail-mock-llm-865bb986c9-5gfm6   1/1     Terminating   0          16s
guardrail-smoke-test                  0/1     Completed     0          8m7s
```

## Real run: `504`
```text
# drill 02 mode 504, 2026-11-27T02:14:38Z, helm v4.3.2+g8346aaa, kind v0.33.0, k8s v1.37.0
$ drills/02-upstream-failure.sh 504
==> last deployed (healthy) revision recorded: 19
Release "guardrail" has been upgraded. Happy Helming!
Waiting for deployment "guardrail-gateway" rollout to finish: 1 out of 2 new replicas have been updated...
Waiting for deployment "guardrail-gateway" rollout to finish: 1 out of 2 new replicas have been updated...
Waiting for deployment "guardrail-gateway" rollout to finish: 1 out of 2 new replicas have been updated...
Waiting for deployment "guardrail-gateway" rollout to finish: 1 old replicas are pending termination...
Waiting for deployment "guardrail-gateway" rollout to finish: 1 old replicas are pending termination...
deployment "guardrail-gateway" successfully rolled out
deployment "guardrail-mock-llm" successfully rolled out
A chat request now:
HTTP/1.1 504 Gateway Timeout
x-request-id: 0d4bffec793441dc
{"request_id":"0d4bffec793441dc","policy_version":"2026-11-27.1","error":"upstream_timeout"}
NAME                                  READY   STATUS      RESTARTS   AGE
guardrail-gateway-85d4c656b9-68v5h    1/1     Running     0          12s
guardrail-gateway-85d4c656b9-gz4ck    1/1     Running     0          16s
guardrail-mock-llm-77dc48575d-swwjs   1/1     Running     0          16s
guardrail-smoke-test                  0/1     Completed   0          8m25s
==> FAULT INJECTED: upstream failure, mode=504
$ kubectl logs (request lines, gateway)
{"ts": "2026-11-27T02:14:53.011761+00:00", "level": "WARNING", "msg": "request", "request_id": "a5cf17226f0b47a8", "policy_version": "2026-11-27.1", "decision": "upstream_error", "error": "timeout", "detail": "timeout", "upstream_ ...[line cut]
{"ts": "2026-11-27T02:14:56.089149+00:00", "level": "WARNING", "msg": "request", "request_id": "0d4bffec793441dc", "policy_version": "2026-11-27.1", "decision": "upstream_error", "error": "timeout", "detail": "timeout", "upstream_ ...[line cut]
$ metrics
gateway_upstream_errors_total{kind="timeout"} 2.0

$ mock-llm env (fault knobs)
MOCK_LATENCY_MS=15000
MOCK_ERROR_RATE=0
$ gateway timeout env
UPSTREAM_TIMEOUT_S=3
$ drills/02-upstream-failure.sh restore
guardrail-gateway-85d4c656b9-gz4ck    1/1     Terminating   0          27s
guardrail-gateway-86f69d77d7-9t9n6    1/1     Running       0          5s
guardrail-gateway-86f69d77d7-tmv29    1/1     Running       0          9s
guardrail-mock-llm-75598fd896-wcqtz   1/1     Running       0          9s
guardrail-mock-llm-77dc48575d-swwjs   1/1     Terminating   0          27s
guardrail-smoke-test                  0/1     Completed     0          8m36s
```

## Diagnose
```bash
kubectl -n guardrail get pods                                    # READY column
kubectl -n guardrail describe pod <gateway-pod>                  # "Readiness probe failed: HTTP probe failed with statuscode: 503"
kubectl -n guardrail logs <gateway-pod> | grep -E '"not ready"|"request"' | tail    # JSON logs
kubectl -n guardrail get deploy guardrail-gateway -o jsonpath='{range .spec.template.spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}'
kubectl -n guardrail get svc,endpoints                           # does the upstream Service exist, does it have endpoints?
```
The gateway logs one JSON line per request with `decision`, `status`, `upstream_ms` and the `request_id` the client received in
`X-Request-ID`, so a customer's "request abc123 failed" maps to exactly one log line.

Test the upstream from inside the cluster, bypassing the gateway. Use a pod that is allowed to talk to it, not a throwaway pod:
the namespace is default-deny, so a fresh `kubectl run` pod would fail even when everything is healthy.
```bash
kubectl -n guardrail exec deploy/guardrail-gateway -- python -c \
  "import urllib.request as u; print(u.urlopen('http://guardrail-mock-llm:8080/healthz', timeout=3).read())"
```
Metrics confirm the pattern (the capture above shows `kind="unavailable"` for 502 and `kind="timeout"` for 504):
`kubectl -n guardrail exec deploy/guardrail-gateway -- python -c "import urllib.request as u;print(u.urlopen('http://127.0.0.1:8080/metrics').read().decode())" | grep upstream_errors`

## Root cause
`url`: typo in the configured upstream URL. `502`: upstream is up but failing. `504`: upstream is too slow for the configured timeout.

## Fix
`url`: `helm rollback` or correct `gateway.upstream.url`. `502`/`504`: fix or scale the upstream; do not raise the gateway timeout above
what callers will wait for, and only with the application owner's agreement.

## Prevention
- Readiness checks the upstream, so a bad URL never receives traffic and the rollout stalls instead of completing; keep `maxUnavailable: 0`.
  The cost of that choice (every replica leaves the Service when the upstream is down) is discussed in ARCHITECTURE.md.
- Alert on `rate(gateway_upstream_errors_total[5m])` and on p95 of `gateway_upstream_latency_seconds`.
- Test the upstream endpoint in preflight (`scripts/preflight.sh`, egress check) before installing.
- Document the 502 versus 504 meaning for the customer's application teams (troubleshooting table in the deployment guide).
