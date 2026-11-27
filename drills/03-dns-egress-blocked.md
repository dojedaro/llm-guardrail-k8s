# Drill 3: NetworkPolicy blocks DNS egress

Inject: `drills/03-dns-egress-blocked.sh`   Undo: `drills/03-dns-egress-blocked.sh restore`
Needs a CNI that enforces NetworkPolicy. Run drill 06 first if you are not sure yours does.

## Symptom
Gateway pods are `Running` but not Ready. Calls fail even though the mock LLM pod is healthy and the Service exists.
A classic trap: a "default deny egress" policy was applied and nobody allowed UDP/TCP 53 to CoreDNS.

<!-- CAPTURE: run drills/03-dns-egress-blocked.sh -->

## Diagnose
```bash
kubectl -n guardrail get pods -o wide
kubectl -n guardrail logs <gateway-pod> | grep "not ready"        # upstream_error shows a name-resolution or timeout error
kubectl -n guardrail get networkpolicy
kubectl -n guardrail describe networkpolicy guardrail-gateway-egress   # is there a rule for port 53?
kubectl -n kube-system get pods -l k8s-app=kube-dns                  # is CoreDNS itself healthy?
```
Separate "DNS is down" from "DNS is blocked": from a pod that is NOT restricted (another namespace) resolve the same name,
and from the gateway pod's namespace compare.
```bash
kubectl run dnstest --rm -it --restart=Never --image=<gateway-image> --command -- \
  python -c "import socket;print(socket.gethostbyname('guardrail-mock-llm.guardrail.svc.cluster.local'))"
```
The upstream is reachable by IP but not by name: that asymmetry is the signature of blocked DNS.
You can also read the pod IP of mock-llm (`kubectl get pods -o wide`) and call it directly.

<!-- CAPTURE: logs + describe networkpolicy output -->

## Root cause
Egress is default-deny and the allow rule for CoreDNS (namespace `kube-system`, label `k8s-app=kube-dns`, port 53 UDP and TCP) is missing.

## Fix
`helm rollback`, or set `networkPolicy.allowDns=true`. If you write the rule by hand it needs both UDP and TCP 53 and must
select the kube-dns pods by namespace AND pod label.

## Prevention
- Ship the DNS rule with every default-deny egress policy; the chart does, and the drill removes it on purpose.
- Test connectivity after any policy change, not just that the manifest applied.
- Keep a break-glass procedure: `kubectl delete networkpolicy <name>` is faster than debugging at 3 a.m., but record it and restore it.
