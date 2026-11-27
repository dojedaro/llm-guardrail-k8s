# Drill 5: missing or wrong Secret (CreateContainerConfigError)

Inject: `drills/05-missing-secret.sh [missing|wrongkey]`   Undo: `drills/05-missing-secret.sh restore`
No real API key is needed: the pods never start. (The drill also enables the external-LLM egress rule with a documentation-range
address, because the chart refuses `kind: anthropic` without one; nothing is ever contacted.)

## Symptom
New gateway pods sit in `CreateContainerConfigError`. The container is never created, so there are **no logs at all**.
That is the key difference from a crash: `kubectl logs` returns "container ... is waiting to start".

## Real run: `missing`
Captured from a real run on the local kind cluster (header line of the log gives the date and versions). Nothing below is edited except where marked trimmed.

```text
# drill 05 mode missing, 2026-11-27T02:16:24Z, helm v4.3.2+g8346aaa, kind v0.33.0, k8s v1.37.0
$ drills/05-missing-secret.sh missing
==> last deployed (healthy) revision recorded: 25
Release "guardrail" has been upgraded. Happy Helming!
NAME                                 READY   STATUS                       RESTARTS   AGE
guardrail-gateway-55d4f6c6db-nwbnc   1/1     Running                      0          71s
guardrail-gateway-55d4f6c6db-pdgw9   1/1     Running                      0          35s
guardrail-gateway-b49d47bb5-hgs7q    0/1     CreateContainerConfigError   0          3s
==> FAULT INJECTED: API-key Secret problem, mode=missing
pod: guardrail-gateway-b49d47bb5-hgs7q
$ kubectl logs <pod>  (no logs: the container never started)
Error from server (BadRequest): container "gateway" in pod "guardrail-gateway-b49d47bb5-hgs7q" is waiting to start: CreateContainerConfigError
$ kubectl describe pod (Events)
Events:
  Type     Reason     Age              From               Message
  ----     ------     ----             ----               -------
  Normal   Scheduled  3s               default-scheduler  Successfully assigned guardrail/guardrail-gateway-b49d47bb5-hgs7q to guardrail-worker
  Normal   Pulled     0s (x3 over 2s)  kubelet            spec.containers{gateway}: Container image "llm-guardrail/gateway:0.1.0" already present on machine and can be accessed by the pod
  Warning  Failed     0s (x3 over 2s)  kubelet            spec.containers{gateway}: Error: secret "does-not-exist" not found
$ kubectl get secrets (names and types only)
NAME                               TYPE                 DATA   AGE
sh.helm.release.v1.guardrail.v...  helm.sh/release.v1   1   (Helm release history, rows trimmed)
$ secretKeyRef in the Deployment
        - name: ANTHROPIC_API_KEY
          valueFrom:
            secretKeyRef:
              key: api-key
              name: does-not-exist
        image: llm-guardrail/gateway:0.1.0
        imagePullPolicy: IfNotPresent
        lifecycle:
          preStop:
$ restore
Rollback was a success! Happy Helming!
NAME                                  READY   STATUS        RESTARTS   AGE
guardrail-gateway-55d4f6c6db-nwbnc    1/1     Running       0          72s
guardrail-gateway-55d4f6c6db-pdgw9    1/1     Running       0          36s
guardrail-gateway-b49d47bb5-hgs7q     0/1     Terminating   0          4s
guardrail-mock-llm-75598fd896-wcqtz   1/1     Running       0          91s
guardrail-smoke-test                  0/1     Completed     0          9m58s
```

## Real run: `wrongkey`
```text
# drill 05 mode wrongkey, 2026-11-27T02:16:30Z, helm v4.3.2+g8346aaa, kind v0.33.0, k8s v1.37.0
$ drills/05-missing-secret.sh wrongkey
==> last deployed (healthy) revision recorded: 27
secret/drill-wrong-key created
Release "guardrail" has been upgraded. Happy Helming!
NAME                                 READY   STATUS                       RESTARTS   AGE
guardrail-gateway-55d4f6c6db-nwbnc   1/1     Running                      0          76s
guardrail-gateway-55d4f6c6db-pdgw9   1/1     Running                      0          40s
guardrail-gateway-59474d7c99-frvnn   0/1     CreateContainerConfigError   0          2s
==> FAULT INJECTED: API-key Secret problem, mode=wrongkey
pod: guardrail-gateway-59474d7c99-frvnn
$ kubectl logs <pod>  (no logs: the container never started)
Error from server (BadRequest): container "gateway" in pod "guardrail-gateway-59474d7c99-frvnn" is waiting to start: CreateContainerConfigError
$ kubectl describe pod (Events)
Events:
  Type     Reason     Age              From               Message
  ----     ------     ----             ----               -------
  Normal   Scheduled  3s               default-scheduler  Successfully assigned guardrail/guardrail-gateway-59474d7c99-frvnn to guardrail-worker
  Normal   Pulled     1s (x3 over 2s)  kubelet            spec.containers{gateway}: Container image "llm-guardrail/gateway:0.1.0" already present on machine and can be accessed by the pod
  Warning  Failed     1s (x3 over 2s)  kubelet            spec.containers{gateway}: Error: couldn't find key api-key in Secret guardrail/drill-wrong-key
$ kubectl get secrets (names and types only)
NAME                               TYPE                 DATA   AGE
drill-wrong-key                    Opaque               1      4s
sh.helm.release.v1.guardrail.v...  helm.sh/release.v1   1   (Helm release history, rows trimmed)
$ kubectl describe secret drill-wrong-key  (key names and sizes, never values)
Type:  Opaque

Data
====
token:  26 bytes
$ secretKeyRef in the Deployment
        - name: ANTHROPIC_API_KEY
          valueFrom:
            secretKeyRef:
              key: api-key
              name: drill-wrong-key
        image: llm-guardrail/gateway:0.1.0
        imagePullPolicy: IfNotPresent
        lifecycle:
          preStop:
$ restore
NAME                                  READY   STATUS        RESTARTS   AGE
guardrail-gateway-55d4f6c6db-nwbnc    1/1     Running       0          78s
guardrail-gateway-55d4f6c6db-pdgw9    1/1     Running       0          42s
guardrail-gateway-59474d7c99-frvnn    0/1     Terminating   0          4s
guardrail-mock-llm-75598fd896-wcqtz   1/1     Running       0          97s
guardrail-smoke-test                  0/1     Completed     0          10m
secret "drill-wrong-key" deleted from guardrail namespace
```

## Diagnose
```bash
kubectl -n guardrail get pods -l app.kubernetes.io/name=gateway
kubectl -n guardrail describe pod <pod>          # Events: Error: secret "does-not-exist" not found
                                                 #     or: couldn't find key api-key in Secret guardrail/drill-wrong-key
kubectl -n guardrail get secrets                 # does it exist, in THIS namespace? (names and types only)
kubectl -n guardrail describe secret <name>      # key NAMES and sizes; never prints values
kubectl -n guardrail get deploy guardrail-gateway -o yaml | grep -B2 -A6 secretKeyRef
```
Do not use `get secret -o jsonpath='{.data}'` to "check the key names": it prints the base64-encoded **values**. `describe secret` is the safe one.
Secrets are namespaced: one created in `default` is invisible to a pod in `guardrail`, a very common cause.

## Root cause
`missing`: the Secret named in `gateway.secret.existingSecret` does not exist in the namespace.
`wrongkey`: it exists, but has no key named `api-key` (here it has `token`); `gateway.secret.key` and the Secret disagree.

## Fix
```bash
kubectl -n guardrail create secret generic anthropic-api-key --from-literal=api-key="$ANTHROPIC_API_KEY"
# the stuck pods retry by themselves once the Secret exists; or revert: drills/05-missing-secret.sh restore
```

## Prevention
- Create the Secret before `helm install`, as a documented step with a verification command.
- Keep key names consistent between the Secret and `gateway.secret.key`.
- The gateway also refuses to start with `UPSTREAM_KIND=anthropic` and an empty key, so a blank Secret fails loudly rather than sending unauthenticated requests.
- `helm upgrade --rollback-on-failure` (Helm 4; `--atomic` on Helm 3) reverts a rollout that never becomes Ready.
