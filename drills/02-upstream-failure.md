# Drill 2: upstream LLM failure (readiness failing, 502, 504)

Inject: `drills/02-upstream-failure.sh [url|502|504]`   Undo: `drills/02-upstream-failure.sh restore`

| Mode | What is broken | What the client sees |
|---|---|---|
| `url` | upstream URL in the config points at a Service that does not exist | new pods stay `0/1 Ready` (readiness fails) |
| `502` | mock LLM answers HTTP 500 to every call (`MOCK_ERROR_RATE=1`) | gateway returns HTTP 502 with a request id |
| `504` | mock LLM is slower (15 s) than the gateway timeout (3 s) | gateway returns HTTP 504 with a request id |

## Symptom
`url`: rollout stuck, pods `Running` but `0/1` Ready; the old pods keep serving.
`502` / `504`: pods are Ready (liveness and readiness only test reachability, not model health), but chat calls fail.

<!-- CAPTURE: run drills/02-upstream-failure.sh url -->
<!-- CAPTURE: run drills/02-upstream-failure.sh 502 (restore first) -->
<!-- CAPTURE: run drills/02-upstream-failure.sh 504 (restore first) -->

## Diagnose
```bash
kubectl -n guardrail get pods                                   # READY column
kubectl -n guardrail describe pod <gateway-pod>                  # "Readiness probe failed: HTTP probe failed with statuscode: 503"
kubectl -n guardrail logs <gateway-pod> | tail -20               # JSON logs: look at "not ready" / "request" lines
kubectl -n guardrail get cm guardrail-policy -o yaml             # config actually mounted
kubectl -n guardrail get deploy guardrail-gateway -o jsonpath='{.spec.template.spec.containers[0].env}' ; echo
kubectl -n guardrail get svc,endpoints                           # does the upstream Service exist, does it have endpoints?
```
The gateway logs one JSON line per request with `decision`, `status`, `upstream_ms` and the `request_id` the client
received in `X-Request-ID`, so a customer's "request abc123 failed" maps to exactly one log line. For readiness failures it
logs `not ready` with `upstream_url` and `upstream_error` (for example a name-resolution error).

Test the upstream from inside the cluster, bypassing the gateway:
```bash
kubectl -n guardrail run dbg --rm -it --restart=Never --image=guardrail-gateway-image --command -- \
  python -c "import urllib.request as u;print(u.urlopen('http://guardrail-mock-llm:8080/healthz').read())"
```
(Use the image from `kubectl -n guardrail get deploy guardrail-gateway -o jsonpath='{.spec.template.spec.containers[0].image}'`.)

Metrics confirm the pattern: `curl localhost:8080/metrics | grep upstream_errors` (after a port-forward) shows
`kind="unavailable"` (502) versus `kind="timeout"` (504).

## Root cause
`url`: typo in the configured upstream URL. `502`: upstream is up but failing. `504`: upstream is too slow for the configured timeout.

## Fix
`url`: `helm rollback` or correct `gateway.upstream.url`. `502`/`504`: fix or scale the upstream; do not raise the
gateway timeout above what callers will wait for. In production, raise it only with the application owner's agreement.

## Prevention
- Readiness checks the upstream, so a bad URL never receives traffic; keep `maxUnavailable: 0` so a bad rollout cannot remove good pods.
- Alert on `rate(gateway_upstream_errors_total[5m])` and on p95 of `gateway_upstream_latency_seconds`.
- Test the upstream endpoint in preflight (`scripts/preflight.sh`, check 10) before installing.
- Document the 502 versus 504 meaning for the customer's application teams (see the troubleshooting table in the deployment guide).
