# Drill 1: bad image tag (ImagePullBackOff)

Inject: `drills/01-bad-image-tag.sh`   Undo: `drills/01-bad-image-tag.sh restore`

## Symptom
After an upgrade, `helm upgrade` returns but the new gateway pod never becomes Ready. `kubectl rollout status` hangs.
Existing traffic keeps working, because the Deployment uses `maxUnavailable: 0` and keeps the old pods running (in the capture below
the two old `86f69d77d7` pods stay `1/1 Running` while the new pod is in `ErrImagePull`).

## Real run
Captured from a real run on the local kind cluster (header line of the log gives the date and versions). Nothing below is edited except where marked trimmed.

```text
# drill 01, 2026-11-27T02:12:38Z, helm v4.3.2+g8346aaa, kind v0.33.0, k8s v1.37.0
$ drills/01-bad-image-tag.sh
==> last deployed (healthy) revision recorded: 9
Release "guardrail" has been upgraded. Happy Helming!
(helm output trimmed)
NAME                                 READY   STATUS         RESTARTS   AGE
guardrail-gateway-7c78f6fbb7-mckn4   0/1     ErrImagePull   0          5s
guardrail-gateway-86f69d77d7-2t6r5   1/1     Running        0          3m2s
guardrail-gateway-86f69d77d7-jfxzh   1/1     Running        0          2m57s

==> FAULT INJECTED: gateway image tag 0.1.0-doesnotexist
    Now diagnose it. Writeup: drills/01-bad-image-tag.md
    Undo with: drills/01-bad-image-tag.sh restore
new pod: pod/guardrail-gateway-7c78f6fbb7-mckn4
$ kubectl rollout status --timeout=15s
Waiting for deployment "guardrail-gateway" rollout to finish: 1 out of 2 new replicas have been updated...
error: timed out waiting for the condition
$ kubectl describe pod (Events)
Events:
  Type     Reason     Age               From               Message
  ----     ------     ----              ----               -------
  Normal   Scheduled  20s               default-scheduler  Successfully assigned guardrail/guardrail-gateway-7c78f6fbb7-mckn4 to guardrail-worker2
  Normal   BackOff    17s               kubelet            spec.containers{gateway}: Back-off pulling image "llm-guardrail/gateway:0.1.0-doesnotexist"
  Warning  Failed     17s               kubelet            spec.containers{gateway}: Error: ImagePullBackOff
  Normal   Pulling    5s (x2 over 19s)  kubelet            spec.containers{gateway}: Pulling image "llm-guardrail/gateway:0.1.0-doesnotexist"
  Warning  Failed     4s (x2 over 18s)  kubelet            spec.containers{gateway}: Failed to pull image "llm-guardrail/gateway:0.1.0-doesnotexist": failed to pull and unpack image "docker.io/llm-guardrail/gateway:0.1.0-doesnotex ...[line cut]
  Warning  Failed     4s (x2 over 18s)  kubelet            spec.containers{gateway}: Error: ErrImagePull
$ kubectl get events (tail)
20s         Normal    ScalingReplicaSet   deployment/guardrail-gateway               (combined from similar events): Scaled up replica set guardrail-gateway-7c78f6fbb7 from 0 to 1
20s         Normal    Scheduled           pod/guardrail-gateway-7c78f6fbb7-mckn4     Successfully assigned guardrail/guardrail-gateway-7c78f6fbb7-mckn4 to guardrail-worker2
20s         Normal    SuccessfulCreate    replicaset/guardrail-gateway-7c78f6fbb7    Created pod: guardrail-gateway-7c78f6fbb7-mckn4
17s         Warning   Failed              pod/guardrail-gateway-7c78f6fbb7-mckn4     Error: ImagePullBackOff
17s         Normal    BackOff             pod/guardrail-gateway-7c78f6fbb7-mckn4     Back-off pulling image "llm-guardrail/gateway:0.1.0-doesnotexist"
5s          Normal    Pulling             pod/guardrail-gateway-7c78f6fbb7-mckn4     Pulling image "llm-guardrail/gateway:0.1.0-doesnotexist"
4s          Warning   Failed              pod/guardrail-gateway-7c78f6fbb7-mckn4     Error: ErrImagePull
4s          Warning   Failed              pod/guardrail-gateway-7c78f6fbb7-mckn4     Failed to pull image "llm-guardrail/gateway:0.1.0-doesnotexist": failed to pull and unpack image "docker.io/llm-guardrail/gateway:0.1.0-doesnotex ...[line cut]
$ image in deployment
llm-guardrail/gateway:0.1.0-doesnotexist
$ helm history
REVISION	UPDATED                 	STATUS    	CHART              	APP VERSION	DESCRIPTION     
1       	Fri Nov 27 11:06:22 2026	superseded	llm-guardrail-0.1.0	0.1.0      	Install complete
2       	Fri Nov 27 11:08:15 2026	superseded	llm-guardrail-0.1.0	0.1.0      	Upgrade complete
3       	Fri Nov 27 11:08:22 2026	superseded	llm-guardrail-0.1.0	0.1.0      	Rollback to 1   
4       	Fri Nov 27 11:08:28 2026	superseded	llm-guardrail-0.1.0	0.1.0      	Upgrade complete
5       	Fri Nov 27 11:08:46 2026	superseded	llm-guardrail-0.1.0	0.1.0      	Rollback to 3   
6       	Fri Nov 27 11:09:13 2026	superseded	llm-guardrail-0.1.0	0.1.0      	Upgrade complete
7       	Fri Nov 27 11:09:19 2026	superseded	llm-guardrail-0.1.0	0.1.0      	Rollback to 5   
8       	Fri Nov 27 11:09:25 2026	superseded	llm-guardrail-0.1.0	0.1.0      	Upgrade complete
9       	Fri Nov 27 11:09:42 2026	superseded	llm-guardrail-0.1.0	0.1.0      	Rollback to 7   
10      	Fri Nov 27 11:12:39 2026	deployed  	llm-guardrail-0.1.0	0.1.0      	Upgrade complete
$ helm rollback via drill restore
==> rolling back to revision 9
Rollback was a success! Happy Helming!
NAME                                  READY   STATUS        RESTARTS   AGE
guardrail-gateway-7c78f6fbb7-mckn4    0/1     Terminating   0          22s
guardrail-gateway-86f69d77d7-2t6r5    1/1     Running       0          3m19s
guardrail-gateway-86f69d77d7-jfxzh    1/1     Running       0          3m14s
guardrail-mock-llm-75598fd896-s8l7q   1/1     Running       0          3m19s
guardrail-smoke-test                  0/1     Completed     0          6m30s
```

## Diagnose
```bash
kubectl -n guardrail get pods -l app.kubernetes.io/name=gateway     # STATUS: ErrImagePull / ImagePullBackOff
kubectl -n guardrail rollout status deploy/guardrail-gateway --timeout=30s
kubectl -n guardrail describe pod <new-pod>                          # read the Events section at the bottom
kubectl -n guardrail get events --sort-by=.lastTimestamp | tail -15
kubectl -n guardrail get deploy guardrail-gateway -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

### Reading the message (the capture shows a trap)
The event says `pull access denied, repository does not exist or may require authorization ... insufficient_scope`. That wording
does **not** by itself distinguish "this tag does not exist" from "this repository needs credentials": for a nonexistent repository
or tag, many registries (Docker Hub here) answer with an authorization error instead of `manifest unknown`, precisely so that they do
not reveal which private repositories exist. So do not stop at the first reading. Tell the causes apart like this:

| Evidence | Likely cause |
|---|---|
| The same image reference worked a revision ago (`helm history`, previous ReplicaSet's image) and only the **tag** changed | wrong or missing tag |
| `docker manifest inspect <image>:<tag>` (or `curl <registry>/v2/<name>/tags/list`) from a machine with the right credentials shows the tag is absent | missing tag |
| The pod spec has no `imagePullSecrets`, the registry is private, and the old tag still pulls from a machine that is logged in | missing pull secret |
| `no such host` / `i/o timeout` in the event | registry unreachable (DNS, proxy, firewall) |
| `manifest unknown` / `not found` | the registry is telling you the tag is missing |

Here the image name `llm-guardrail/gateway` only exists in the nodes' local image store (loaded by `kind load`), so Docker Hub cannot find
any tag of it: that is why the message is an authorization error even though no secret is involved.

## Root cause
The release was upgraded with an image tag that is not present in any registry the nodes can reach (on kind: not loaded into the nodes).

## Fix
```bash
helm history guardrail -n guardrail
helm rollback guardrail <last-good-revision> -n guardrail --wait      # fastest, restores the previous values
# or fix forward: helm upgrade ... --set gateway.image.tag=0.1.0
```

## Prevention
- Pin tags, never `latest` (the chart's `values.schema.json` rejects `latest`).
- Verify the tag exists before the change window: `docker manifest inspect <registry>/<image>:<tag>`.
- Use `helm upgrade --rollback-on-failure --timeout 3m` (Helm 4; `--atomic` on Helm 3) so Helm rolls back by itself if pods do not become Ready.
- Air-gapped sites: confirm the image is in the private registry (`curl <registry>/v2/_catalog`) before upgrading.
