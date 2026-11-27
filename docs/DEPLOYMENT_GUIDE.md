# Deployment guide: LLM guardrail gateway

Audience: the customer's platform / infrastructure team. This guide installs the gateway into an existing Kubernetes cluster,
verifies it, connects applications to it, and covers upgrades, rollback and troubleshooting.

Placeholders: namespace `guardrail`, release name `guardrail`. Change them consistently if you prefer others.

## 1. What is being deployed
| Component | Kind | Purpose |
|---|---|---|
| `guardrail-gateway` | Deployment (2 replicas), Service, PodDisruptionBudget, optional HPA and Ingress | Applies PII and prompt-injection policy, forwards allowed requests to the LLM |
| `guardrail-mock-llm` | Deployment, Service | Optional stand-in LLM for evaluation or air-gapped sites |
| `guardrail-policy` | ConfigMap | The policy file, versioned |
| API-key Secret | Secret | Only when an external LLM is used |
| NetworkPolicies | 5 objects | Default deny, plus explicit allows |

Default resource requests: gateway 100m CPU / 128Mi x 2 replicas, mock LLM 50m / 64Mi. Total about 250m CPU and 320Mi.

## 2. Prerequisites
- Kubernetes 1.27 or newer; `kubectl` and Helm 3.12+ on the workstation used for the install, with permission to create
  Deployments, Services, ConfigMaps, Secrets and NetworkPolicies in the target namespace.
- A CNI plugin that **enforces** NetworkPolicy (for example Calico or Cilium). Accepting the objects is not enough; see section 3.
- Container images available to the nodes (public registry, private registry, or the offline bundle in section 5).
- Optional: an ingress controller (only for `ingress.enabled=true`), metrics-server (only for the HPA).
- For an external LLM: outbound HTTPS from the namespace to the provider, and the provider's IP ranges for the egress allowlist.

## 3. Environment assessment
Run the read-only assessment and attach its report to the change ticket:
```bash
scripts/preflight.sh                       # report saved under reports/
PROBE_NETPOL=1 scripts/preflight.sh        # also actively proves NetworkPolicy enforcement (temporary namespace)
EXTERNAL_LLM=1 UPSTREAM_URL=https://api.anthropic.com scripts/preflight.sh   # treat egress failure as FAIL
REGISTRY_URL=https://registry.customer.local/v2/ scripts/preflight.sh        # test the private registry
```
It checks: Kubernetes version, RBAC in the namespace, node readiness, allocatable CPU and memory against the chart's requests,
default StorageClass (informational; the chart is stateless), ingress controller, CoreDNS health, NetworkPolicy support,
registry reachability and egress to the LLM endpoint. Checks 9 and 10 run from the workstation: repeat them from a pod
inside the cluster if the cluster sits behind a different proxy or firewall than the workstation.

Resolve every FAIL before installing. A WARN needs a conscious decision recorded in the ticket.

## 4. Install (online)
```bash
kubectl create namespace guardrail
helm upgrade --install guardrail charts/llm-guardrail -n guardrail --wait --timeout 180s
helm test guardrail -n guardrail --logs
```
With the default values the gateway uses the in-cluster mock LLM. To tune the policy or sizing, copy `values.yaml`, change
only what you need and pass it with `-f my-values.yaml`; `values.schema.json` rejects invalid values at install time.

### Using an external LLM
```bash
kubectl -n guardrail create secret generic anthropic-api-key --from-literal=api-key="$ANTHROPIC_API_KEY"
# Resolve the provider endpoint to the addresses your firewall team will approve, then allow only those:
helm upgrade --install guardrail charts/llm-guardrail -n guardrail \
  -f charts/llm-guardrail/values-external-llm.yaml \
  --set 'networkPolicy.externalLLM.cidrs={<ip-or-cidr>,<ip-or-cidr>}' --wait
```
Notes: NetworkPolicy matches IP ranges, not hostnames, so provider IP changes require updating the list; consider an egress
proxy or a CNI with FQDN policies if the provider's addresses change often. The model id is `gateway.upstream.model`
(default `claude-haiku-5-5`). Prefer `existingSecret` to `gateway.secret.apiKey`: a key passed to Helm is stored in the release history.

## 5. Install in an air-gapped environment
On a connected machine:
```bash
scripts/airgap-bundle.sh        # produces dist/llm-guardrail-airgap-<version>.tar.gz and a .sha256 file
```
The bundle contains the image archive (gateway, mock LLM, registry), the packaged chart, `values-airgapped.yaml`, a manifest and checksums.
Transfer it by the site's approved method, verify the `.sha256`, then on the offline site:
```bash
scripts/airgap-install.sh dist/llm-guardrail-airgap-<version>.tar.gz
```
The script verifies the internal checksums, loads the images, starts a private registry, pushes the images, and installs the chart with
`global.imageRegistry` pointing at that registry. At a real customer site you would instead push the images to their existing
registry (`docker load`, `docker tag`, `docker push`) and run `helm upgrade --install ... -f values-airgapped.yaml --set global.imageRegistry=<registry>`.
Use the mock LLM, or an LLM endpoint inside the site's network (`gateway.upstream.url`), and keep `networkPolicy.externalLLM.enabled=false`.

## 6. Verification
```bash
kubectl -n guardrail get pods                              # all Running, READY 1/1
helm test guardrail -n guardrail --logs                    # every line PASS
kubectl -n guardrail port-forward svc/guardrail-gateway 8080:80 &
curl -s localhost:8080/readyz
curl -s -i localhost:8080/v1/chat -H 'content-type: application/json' \
  -d '{"messages":[{"role":"user","content":"my email is jane@example.com"}]}'
```
Expect `decision: redacted`, no raw email in the reply, and headers `X-Request-ID` and `X-Policy-Version`.
For a full check from the repository: `pytest tests/integration -v` and `drills/06-networkpolicy-enforcement.sh`.

## 7. Integrating applications
- **Address:** `http://guardrail-gateway.guardrail.svc.cluster.local/v1/chat` (port 80). Request: `{"messages":[{"role":"user","content":"..."}]}`; roles are `system`, `user`, `assistant`.
- **Who may call it:** pods in namespaces listed in `networkPolicy.allowedNamespaces` (matched on the `kubernetes.io/metadata.name` label; default `ingress-nginx`).
  Add the application's namespace: `--set 'networkPolicy.allowedNamespaces={ingress-nginx,payments}'`.
- **Ingress:** `--set ingress.enabled=true --set ingress.host=guardrail.example.internal` (class `nginx`). Terminate TLS at the ingress; the gateway speaks plain HTTP inside the cluster.
- **Response handling:** `200` allowed or redacted (`decision` tells which); `403` blocked (`reason`: `pii` or `prompt_injection`);
  `502` upstream failed; `504` upstream timed out. Always log `request_id` on the application side: support can find the matching gateway log line.
- **Policy:** edit the `policy:` section of your values (`pii.mode: redact|block`, rules, injection threshold) and run `helm upgrade`; pods roll automatically and `policy.version` is returned on every response.
- **Observability:** logs are JSON on stdout (`kubectl logs`); Prometheus metrics at `/metrics`
  (`gateway_requests_total`, `gateway_rule_hits_total`, `gateway_upstream_errors_total`, `gateway_upstream_latency_seconds`).

## 8. Upgrade and rollback
```bash
helm diff upgrade ...            # optional plugin: preview changes
helm upgrade guardrail charts/llm-guardrail -n guardrail --reuse-values --set policy.version=2026-12-01.1 \
  --atomic --timeout 3m          # --atomic rolls back automatically if pods do not become Ready
helm history guardrail -n guardrail
helm rollback guardrail <revision> -n guardrail --wait
```
Rollouts are rolling (`maxUnavailable: 0`), so there is no downtime for a healthy release, and a failing release keeps the old pods serving.
`scripts/upgrade-rollback-demo.sh` rehearses the full cycle (upgrade, verify the live policy version, history, rollback, verify again).
Take a note of the current revision (`helm history`) before every change window.

## 9. Uninstall
```bash
helm uninstall guardrail -n guardrail
kubectl delete namespace guardrail          # only if the namespace was created for this release
```
The chart creates no persistent volumes. Secrets you created yourself (`kubectl create secret`) are not removed by Helm.

## 10. Troubleshooting
| Symptom | Likely cause | Check | Fix |
|---|---|---|---|
| Pod `ImagePullBackOff` | Wrong tag, registry unreachable, missing pull secret | `kubectl describe pod` events | Correct tag or registry; offline bundle (section 5). Drill 1 |
| Pod `CreateContainerConfigError` | Secret or key missing in this namespace | `kubectl describe pod`; `kubectl get secrets` | Create the Secret; match `gateway.secret.key`. Drill 5 |
| Pod `CrashLoopBackOff`, reason `OOMKilled` | Memory limit too low | `kubectl describe pod` (Last State) | Raise `gateway.resources.limits.memory`. Drill 4 |
| Pod Running but `0/1` Ready | Upstream unreachable or policy not loaded | `kubectl logs <pod>` (`not ready` line shows the reason) | Fix upstream URL/DNS/egress; check ConfigMap. Drills 2, 3 |
| Clients get `502` | Upstream refused or returned an error | gateway log `decision: upstream_error`; test upstream directly | Repair upstream; check egress allowlist |
| Clients get `504` | Upstream slower than `gateway.upstream.timeoutSeconds` | gateway logs `upstream_ms`; `gateway_upstream_latency_seconds` | Fix upstream latency; adjust timeout only with the app owner |
| Clients get `403` | Policy blocked the request | response `reason` and `rules` | Review the policy; check false positives |
| Calls from an application time out (no HTTP status) | NetworkPolicy does not allow that namespace | `kubectl describe networkpolicy guardrail-gateway-ingress` | Add namespace to `allowedNamespaces`. Drill 6 proves enforcement |
| Name resolution errors in gateway logs | Egress policy without DNS rule, or CoreDNS down | `kubectl -n kube-system get pods -l k8s-app=kube-dns` | Restore DNS egress. Drill 3 |
| Policy change not applied | Edited the ConfigMap by hand instead of via Helm | `kubectl get pods` ages; `helm get values` | Change values and `helm upgrade` (checksum rolls pods) |
| `helm install` fails with a schema error | Invalid value | Message names the field | Correct the value |

Collect evidence before escalating: `scripts/collect-diagnostics.sh` produces a tarball (pod status, events, describes, logs including
previous containers, Helm values and manifest) with credentials redacted. Read it before sending it outside the organisation.
