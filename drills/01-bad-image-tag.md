# Drill 1: bad image tag (ImagePullBackOff)

Inject: `drills/01-bad-image-tag.sh`   Undo: `drills/01-bad-image-tag.sh restore`

## Symptom
After an upgrade, `helm upgrade` returns but the new gateway pod never becomes Ready. `kubectl rollout status` hangs.
Existing traffic keeps working, because the Deployment uses `maxUnavailable: 0` and keeps the old pods running.

<!-- CAPTURE: run drills/01-bad-image-tag.sh -->

## Diagnose
```bash
kubectl -n guardrail get pods -l app.kubernetes.io/name=gateway     # STATUS: ErrImagePull / ImagePullBackOff
kubectl -n guardrail rollout status deploy/guardrail-gateway --timeout=30s
kubectl -n guardrail describe pod <new-pod>                          # read the Events section at the bottom
kubectl -n guardrail get events --sort-by=.lastTimestamp | tail -15
kubectl -n guardrail get deploy guardrail-gateway -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```
What to look for in the events: `Failed to pull image "...:0.1.0-doesnotexist"` followed by `manifest unknown` / `not found`
(tag does not exist) versus `no such host` / `i/o timeout` (registry unreachable) versus `unauthorized` (missing pull secret).
Those three messages point to three different root causes.

<!-- CAPTURE: describe pod + events output -->

## Root cause
The release was upgraded with an image tag that is not present in the registry (or, on kind, not loaded into the nodes).

## Fix
```bash
helm history guardrail -n guardrail
helm rollback guardrail <last-good-revision> -n guardrail --wait      # fastest, restores the previous values
# or fix forward: helm upgrade ... --set gateway.image.tag=0.1.0
```

## Prevention
- Pin tags, never `latest` (the chart's `values.schema.json` already rejects `latest`).
- Verify the tag exists before the change window: `docker manifest inspect <registry>/<image>:<tag>`.
- Use `helm upgrade --atomic --timeout 3m` so Helm rolls back by itself if pods do not become Ready.
- Air-gapped sites: confirm the image is in the private registry (`curl <registry>/v2/_catalog`) before upgrading.
