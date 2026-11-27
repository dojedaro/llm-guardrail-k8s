# Drill 3: NetworkPolicy blocks DNS egress

Inject: `drills/03-dns-egress-blocked.sh`   Undo: `drills/03-dns-egress-blocked.sh restore`
Needs a CNI that enforces NetworkPolicy. Run drill 06 first if you are not sure yours does.

## Symptom
Gateway pods are `Running` but not Ready. Calls fail even though the mock LLM pod is healthy and the Service exists.
A classic trap: a "default deny egress" policy was applied and nobody allowed UDP/TCP 53 to cluster DNS.

## Real run
Captured from a real run on the local kind cluster (header line of the log gives the date and versions). Nothing below is edited except where marked trimmed.

```text
# drill 03, 2026-11-27T02:31:21Z, helm v4.3.2+g8346aaa, kind v0.33.0, k8s v1.37.0, Calico v3.28.2
$ drills/03-dns-egress-blocked.sh
==> last deployed (healthy) revision recorded: 58
Release "guardrail" has been upgraded. Happy Helming!
(helm output trimmed)
deployment.apps/guardrail-gateway restarted
NAME                                 READY   STATUS    RESTARTS   AGE
guardrail-gateway-5d846f4bd6-79m2g   0/1     Running   0          7s
guardrail-gateway-7775f969dd-htcfd   1/1     Running   0          2m59s
guardrail-gateway-7775f969dd-k7t67   1/1     Running   0          3m3s

==> FAULT INJECTED: DNS egress removed from NetworkPolicy
    Now diagnose it. Writeup: drills/03-dns-egress-blocked.md
    Undo with: drills/03-dns-egress-blocked.sh restore
not-ready pod: guardrail-gateway-5d846f4bd6-79m2g
$ kubectl logs <pod> | grep "not ready"
{"ts": "2026-11-27T02:31:30.435946+00:00", "level": "WARNING", "msg": "not ready", "version": "0.1.0", "policy_loaded": true, "upstream_reachable": false, "policy_version": "2026-11-27.1", "upstream_url": "http://guardrail-mock-ll ...[line cut]
$ kubectl describe pod (Events)
Events:
  Type     Reason     Age   From               Message
  ----     ------     ----  ----               -------
  Normal   Scheduled  8s    default-scheduler  Successfully assigned guardrail/guardrail-gateway-5d846f4bd6-79m2g to guardrail-worker2
  Normal   Pulled     8s    kubelet            spec.containers{gateway}: Container image "llm-guardrail/gateway:0.1.0" already present on machine and can be accessed by the pod
  Normal   Created    8s    kubelet            spec.containers{gateway}: Container created
  Normal   Started    8s    kubelet            spec.containers{gateway}: Container started
  Warning  Unhealthy  6s    kubelet            spec.containers{gateway}: Startup probe failed: Get "http://192.168.41.150:8080/healthz": dial tcp 192.168.41.150:8080: connect: connection refused
  Warning  Unhealthy  2s    kubelet            spec.containers{gateway}: Readiness probe failed: HTTP probe failed with statuscode: 503
$ kubectl describe networkpolicy guardrail-gateway-egress (note: no port 53 rule)
Spec:
  PodSelector:     app.kubernetes.io/instance=guardrail,app.kubernetes.io/name=gateway
  Not affecting ingress traffic
  Allowing egress traffic:
    To Port: 8080/TCP
    To:
      PodSelector: app.kubernetes.io/instance=guardrail,app.kubernetes.io/name=mock-llm
  Policy Types: Egress
$ CoreDNS itself healthy?
NAME                       READY   STATUS    RESTARTS   AGE
coredns-559f6c778d-6ghzv   1/1     Running   0          56m
coredns-559f6c778d-fvx4p   1/1     Running   0          56m
$ resolve the Service name from inside the gateway pod (blocked by policy)
socket.gaierror: [Errno -3] Temporary failure in name resolution
command terminated with exit code 1
$ resolve the same name from an unrestricted namespace (works: DNS is up, so it is the policy)
Name:	guardrail-mock-llm.guardrail.svc.cluster.local
Address: 10.96.231.24
$ drills/03-dns-egress-blocked.sh restore
NAME                                  READY   STATUS        RESTARTS   AGE
guardrail-gateway-5d846f4bd6-79m2g    1/1     Running       0          41s
guardrail-gateway-5d846f4bd6-g9llc    1/1     Running       0          5s
guardrail-gateway-7775f969dd-htcfd    1/1     Terminating   0          3m33s
guardrail-gateway-7775f969dd-k7t67    1/1     Terminating   0          3m37s
guardrail-mock-llm-774bd8554d-t5znh   1/1     Running       0          89s
```

## Diagnose
```bash
kubectl -n guardrail get pods -o wide
kubectl -n guardrail logs <gateway-pod> | grep '"not ready"'        # upstream_error shows the failure
kubectl -n guardrail get networkpolicy
kubectl -n guardrail describe networkpolicy guardrail-gateway-egress   # is there a rule for port 53?
kubectl -n kube-system get pods -l k8s-app=kube-dns                  # is cluster DNS itself healthy?
```
Separate "DNS is down" from "DNS is blocked": resolve the same name from a pod that is NOT restricted and from one that is (both
are in the capture). Use `kubectl exec` into an existing gateway pod for the restricted side: a new debug pod in this namespace would be
blocked by default-deny whether or not DNS is the problem.
```bash
kubectl -n guardrail exec <gateway-pod> -- python -c "import socket;print(socket.gethostbyname('guardrail-mock-llm.guardrail.svc.cluster.local'))"
kubectl -n default run dnstest --rm -i --restart=Never --image=busybox:1.36.1 -- nslookup guardrail-mock-llm.guardrail.svc.cluster.local
```
The signature: the unrestricted pod resolves the name, the gateway pod gets `Temporary failure in name resolution`, and the egress policy
has no port-53 rule. CoreDNS is healthy throughout.

## Root cause
Egress is default-deny and the allow rule for cluster DNS (namespace `kube-system`, label `k8s-app=kube-dns`, port 53 UDP and TCP) is missing.

## Fix
`helm rollback`, or set `networkPolicy.allowDns=true`. If you write the rule by hand it needs both UDP and TCP 53 and must select the DNS
pods by namespace AND pod label. If the cluster uses node-local DNS or DNS outside `kube-system`, set `networkPolicy.dns.*` in the values.

## Prevention
- Ship the DNS rule with every default-deny egress policy; the chart does, and the drill removes it on purpose.
- Test connectivity after any policy change, not just that the manifest applied.
- Keep a break-glass procedure: `kubectl delete networkpolicy <name>` is faster than debugging at 3 a.m., but record it and restore it.
