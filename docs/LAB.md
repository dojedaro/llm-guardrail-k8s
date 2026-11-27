# Hands-on lab: learn Kubernetes operations by running this project

About 4 to 6 hours. The exercises are independent after Exercise 3, so they can be split across days. Type the commands
yourself and read the output before moving on. Each exercise has **Do**, **Observe** and **Learned**.

Use a POSIX shell (Git Bash on Windows). Names used throughout: cluster `guardrail`, namespace `guardrail`, release `guardrail`.
Run every command from the repository root.

Tested with kind v0.33.0, Kubernetes v1.37.0, Helm v4.3.2 and Docker Desktop 29.9.3 (see [EVIDENCE.md](EVIDENCE.md)).
The chart relies on Helm 4 behaviour in two places (server-side apply conflicts in drill 7, `--rollback-on-failure`);
with Helm 3 the equivalent flag is `--atomic`.

## Exercise 0. Install the tools
You need Docker (8 GB or more for the Docker VM; the 3-node cluster uses roughly 3 to 4 GB), `kind`, `kubectl` and `helm`.
On Windows with winget:
```powershell
winget install -e --id Kubernetes.kind
winget install -e --id Kubernetes.kubectl
winget install -e --id Helm.Helm
```
Open a new terminal, then:
```bash
kind version && kubectl version --client && helm version
docker info | grep -E "CPUs|Total Memory"
```
If a winget id is not found, `winget search kind` shows the current one.
**Learned:** `kind` runs Kubernetes nodes as Docker containers; `kubectl` talks to the API server; `helm` renders and installs packaged manifests.

Git Bash note: it rewrites arguments that look like Unix paths before handing them to Windows programs. The scripts set
`MSYS_NO_PATHCONV=1`; when you type a command that passes a path *to a container*, prefix it yourself or wrap it:
`MSYS_NO_PATHCONV=1 kubectl exec ... -- ls /etc/guardrail`, or `kubectl exec ... -- sh -c "ls /etc/guardrail"`.

## Exercise 1. Create the cluster and look around
```bash
CNI=calico scripts/cluster-up.sh               # NetworkPolicy is guaranteed to be enforced with Calico
kubectl cluster-info
kubectl get nodes -o wide
kubectl get pods -A
docker ps --format '{{.Names}}'                # the "nodes" are containers
kubectl describe node guardrail-worker | head -60
```
**Observe:** 3 nodes (1 control plane, 2 workers); system pods in `kube-system`; ingress-nginx in its own namespace. In
`describe node` find *Capacity*, *Allocatable* and *Allocated resources*.
**Learned:** control plane versus workers; namespaces; Kubernetes components are pods too; allocatable resources are what the scheduler uses.

## Exercise 2. Environment assessment
```bash
PROBE_NETPOL=1 scripts/preflight.sh
```
**Observe:** PASS/WARN/FAIL lines, saved under `reports/`. The NetworkPolicy line comes from an active probe: a client fetches a file
before a deny-all policy (positive control) and must then time out. Read each check in the script: each is a `kubectl` question you can ask by hand.
**Learned:** the first thing done in an unfamiliar environment. Any FAIL is fixed first; a WARN is a decision to record.

## Exercise 3. Read the chart before installing
```bash
helm lint charts/llm-guardrail
helm template guardrail charts/llm-guardrail | less
helm template guardrail charts/llm-guardrail -f charts/llm-guardrail/values-airgapped.yaml | grep image:
scripts/chart-check.sh                          # every values file, strict YAML, kubeconform, bad-values tests
```
**Observe:** the YAML Helm would send. Find the Deployment, Service, ConfigMap, NetworkPolicies, the `checksum/policy` annotation and the probes.
The air-gapped values change every `image:` line.
**Learned:** Helm is templating plus release bookkeeping; you can always read what it will do.

## Exercise 4. Install
```bash
helm install guardrail charts/llm-guardrail -n guardrail --create-namespace -f charts/llm-guardrail/values-kind.yaml
kubectl -n guardrail get pods -w               # Ctrl+C when all are Running 1/1
helm list -n guardrail
helm status guardrail -n guardrail
```
**Observe:** pods go `ContainerCreating` -> `Running` -> `Ready`. Read the NOTES output.
**Learned:** a Deployment creates a ReplicaSet which creates Pods; Helm records a release revision.

## Exercise 5. The objects, one by one
```bash
kubectl -n guardrail get deploy,rs,pods,svc,endpoints,cm,networkpolicy,pdb,ingress
kubectl -n guardrail get deploy guardrail-gateway -o yaml | less
kubectl -n guardrail describe svc guardrail-gateway
kubectl -n guardrail get pods -o wide --show-labels
```
**Observe:** the Service selects pods by label; `endpoints` lists the pod IPs behind it; the two gateway pods sit on different nodes
(topology spread). Delete one (`kubectl -n guardrail delete pod <a gateway pod>`) and watch the ReplicaSet replace it while the Service keeps answering.
**Learned:** Deployment/ReplicaSet/Pod, labels and selectors, Service and Endpoints, self-healing, spreading replicas over nodes.

## Exercise 6. Logs, describe, events
```bash
kubectl -n guardrail logs deploy/guardrail-gateway
kubectl -n guardrail describe pod <gateway-pod>        # read Events at the bottom
kubectl -n guardrail get events --sort-by=.lastTimestamp
kubectl -n guardrail exec deploy/guardrail-gateway -- sh -c "ls /etc/guardrail"
kubectl -n guardrail exec deploy/guardrail-gateway -- sh -c "touch /app/x" ; echo "exit=$?"
kubectl -n guardrail exec deploy/guardrail-gateway -- sh -c "touch /tmp/x && echo tmp-ok"
```
**Observe:** JSON logs. Writing to `/app` fails (non-root, read-only root filesystem) while `/tmp` works (a mounted emptyDir).
**Learned:** logs say what the app did; describe and events say what Kubernetes did; the security context is real.

## Exercise 7. Call the service
```bash
helm test guardrail -n guardrail --logs
curl -s -i -H 'Host: guardrail.localtest.me' -H 'content-type: application/json' \
  -d '{"messages":[{"role":"user","content":"my email is jane@example.com, phone 010-1234-5678"}]}' http://localhost:8080/v1/chat
curl -s -o /dev/null -w '%{http_code}\n' -H 'Host: guardrail.localtest.me' http://localhost:8080/metrics     # 404: not exposed
kubectl -n guardrail port-forward svc/guardrail-gateway 18081:80 &
curl -s localhost:18081/metrics | grep gateway_
kubectl -n guardrail logs deploy/guardrail-gateway --tail=3
kill %1
```
**Observe:** a redacted decision plus `X-Request-ID` and `X-Policy-Version`; one JSON log line per request with the same request id and no raw email.
Through the ingress only `/v1` is reachable; `/metrics` answers 404 there but works via port-forward.
**Learned:** ingress routing, port-forward, helm test hook pods, how to prove an app works end to end.

## Exercise 8. ConfigMap and the checksum roll
```bash
helm upgrade guardrail charts/llm-guardrail -n guardrail -f charts/llm-guardrail/values-kind.yaml \
  --set policy.version=lab-2 --set policy.pii.mode=block
kubectl -n guardrail rollout status deploy/guardrail-gateway
kubectl -n guardrail get pods                              # new pod names: they were rolled
```
Then the wrong way, to see why the checksum annotation exists:
```bash
kubectl -n guardrail edit cm guardrail-policy              # change something, save
kubectl -n guardrail get pods                              # nothing restarted: the app still has the old policy in memory
```
Put it back: `helm rollback guardrail <revision> -n guardrail`.
**Learned:** ConfigMaps are volumes; pods do not restart on change; the pod-template annotation trick; hand edits drift from the release.

## Exercise 9. Secrets and an external LLM (optional, needs an API key)
Without a key you can still see the failure path in drill 5. With one:
```bash
kubectl -n guardrail create secret generic anthropic-api-key --from-literal=api-key="$ANTHROPIC_API_KEY"
kubectl -n guardrail describe secret anthropic-api-key      # key names and sizes, never values
nslookup api.anthropic.com                                   # find the addresses to allowlist
helm upgrade guardrail charts/llm-guardrail -n guardrail -f charts/llm-guardrail/values-external-llm.yaml \
  --set 'networkPolicy.externalLLM.cidrs={<address>/32}'
```
The Anthropic adapter has not been run against the real API by the author (unit tests with a mocked transport only), so treat this exercise as the first real test of it.
**Learned:** Secrets, `secretKeyRef`, egress allowlisting by IP, why `existingSecret` beats `--set`.

## Exercise 10. Probes and failure behaviour
```bash
kubectl -n guardrail scale deploy/guardrail-mock-llm --replicas=0
kubectl -n guardrail get pods,endpoints -w                 # gateway pods go 0/1 Ready within seconds
kubectl -n guardrail logs deploy/guardrail-gateway --tail=5       # "not ready" with the reason
kubectl -n guardrail scale deploy/guardrail-mock-llm --replicas=1
```
**Observe:** gateway pods stay `Running` but drop to `0/1`, the Service endpoints empty out, nothing restarts (liveness ignores the upstream), and they recover by themselves.
**Think:** readiness here depends on the upstream, so when the single upstream goes away *every* gateway replica leaves the Service at once. Why might that be
the right or the wrong call? (The design note is in [ARCHITECTURE.md](ARCHITECTURE.md).)
**Learned:** liveness versus readiness versus startup probes.

## Exercise 11. Rollout, history, rollback
```bash
scripts/upgrade-rollback-demo.sh
kubectl -n guardrail rollout history deploy/guardrail-gateway
helm history guardrail -n guardrail
```
**Observe:** the config change and an image upgrade (0.1.0 to 0.1.1, reported by `/readyz`) are each verified, then rolled back and verified again.
**Learned:** a change window done properly: baseline, change, verify, evidence, rollback. `kubectl rollout undo` rolls back one Deployment; `helm rollback` the whole release.

## Exercise 12. NetworkPolicy, and proving it
```bash
drills/06-networkpolicy-enforcement.sh
```
**Observe:** the control connects, the outsider times out, final line PASS. If the outsider got through, the CNI does not enforce policies:
`scripts/cluster-down.sh && CNI=calico scripts/cluster-up.sh`.
**Learned:** API acceptance versus enforcement; namespace and pod selectors; default deny; why "blocked" must mean a timeout.

## Exercise 13. Incident drills
For each drill: run it, diagnose before reading the writeup, then compare. Always restore afterwards.
```bash
drills/01-bad-image-tag.sh         # then: drills/01-bad-image-tag.sh restore
drills/02-upstream-failure.sh url  # also 502 and 504
drills/03-dns-egress-blocked.sh
drills/04-oomkilled.sh
drills/05-missing-secret.sh        # also wrongkey
drills/07-config-drift.sh
drills/08-node-drain.sh
```
**Learned:** ImagePullBackOff, OOMKilled, CreateContainerConfigError, DNS and egress failures, 502 versus 504, field-ownership conflicts, PodDisruptionBudgets.
Practise the one-minute version: symptom, command, finding, cause, fix.

## Exercise 14. Air-gapped install
```bash
scripts/airgap-bundle.sh
helm uninstall guardrail -n guardrail
scripts/airgap-install.sh dist/llm-guardrail-airgap-0.1.0.tar.gz
```
**Observe:** the image names carry the `kind-registry:5000/` prefix and the kubelet "Pulled" events name that registry: the nodes pulled from the registry built from the bundle.
The network is not physically cut off, so that evidence (not isolation) is what shows the bundle was used.
**Learned:** the offline delivery workflow (bundle, checksum, registry, values override).

## Exercise 15. Support bundle
```bash
scripts/collect-diagnostics.sh
tar -tzf diagnostics-*.tar.gz | head -30
tests/scripts/test-redact.sh
```
**Learned:** what to send a product team, and why credential redaction is tested rather than trusted.

## Exercise 16. Measure the guardrails
```bash
python scripts/eval_guardrails.py
```
**Observe:** measured false-positive and false-negative rates on `eval/corpus.jsonl`. Add prompts of your own and see which ones the heuristics miss.

## Cleanup
```bash
scripts/cluster-down.sh
```
