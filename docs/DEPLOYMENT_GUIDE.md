# Deployment guide: LLM guardrail gateway

Audience: the customer's platform / infrastructure team. This guide installs the gateway into an existing Kubernetes cluster,
verifies it, connects applications to it, and covers upgrades, rollback and troubleshooting.

Placeholders: namespace `guardrail`, release name `guardrail`. Change them consistently if you prefer others.

## 1. What is being deployed
| Component | Kind | Purpose |
|---|---|---|
| `guardrail-gateway` | Deployment (2 replicas, spread over nodes), Service, PodDisruptionBudget (2+ replicas only), optional Ingress | Applies PII and prompt-injection policy, forwards allowed requests to the LLM |
| `guardrail-mock-llm` | Deployment, Service | Optional stand-in LLM for evaluation or air-gapped sites |
| `guardrail-policy` | ConfigMap | The policy file, versioned |
| API-key Secret | Secret | Only when an external LLM is used |
| NetworkPolicies | 5 objects | Default deny, plus explicit allows |

`gateway` and `mockLlm` also take `nodeSelector`, `tolerations` and `podAnnotations`.

Default resource requests: gateway 100m CPU / 128Mi x 2 replicas, mock LLM 50m / 64Mi. Total about 250m CPU and 320Mi.

## 2. Prerequisites
- Kubernetes 1.27 or newer (tested on v1.37.0 with kind v0.33.0).
- `kubectl` and **Helm 4** on the workstation used for the install (tested with Helm v4.3.2), with permission to create
  Deployments, Services, ConfigMaps, Secrets, Pods (for `helm test`), PodDisruptionBudgets and NetworkPolicies in the target namespace.
  Helm 3 has not been tested here. Known differences if you use it: `--atomic` instead of `--rollback-on-failure`; a field-ownership
  conflict (drill 7) would not be reported because Helm 3 does not use server-side apply; and the test hook keeps its pod after the run
  (the chart uses `before-hook-creation` only, because `hook-succeeded` together with `helm test --logs` is reported to fail on Helm 3, helm/helm#9098; not tested here).
- A CNI plugin that **enforces** NetworkPolicy (for example Calico or Cilium). Accepting the objects is not enough; see section 3.
- Container images available to the nodes (public registry, private registry, or the offline bundle in section 5).
- Optional: an ingress controller (only for `ingress.enabled=true`). The chart's Ingress is controller-agnostic (`ingress.className`). The kind
  rehearsal uses ingress-nginx, which was retired upstream in March 2026 and gets no further fixes; use your site's supported controller
  (on k3s the bundled Traefik was present and preflight found its IngressClass, see [EVIDENCE.md](EVIDENCE.md); no request was sent through a Traefik Ingress).
- For an external LLM: outbound HTTPS from the namespace to the provider, and the provider's IP ranges for the egress allowlist.

## 3. Environment assessment
Run the assessment and attach its report to the change ticket. It is read-only except for the optional probe, which creates and deletes a
temporary namespace.
```bash
scripts/preflight.sh                       # report saved under reports/
PROBE_NETPOL=1 scripts/preflight.sh        # also actively proves NetworkPolicy enforcement
EXTERNAL_LLM=1 UPSTREAM_URL=https://api.anthropic.com scripts/preflight.sh   # treat egress failure as FAIL
REGISTRY_URL=https://registry.customer.local/v2/ scripts/preflight.sh        # test the private registry
```
It checks: Kubernetes version, RBAC for everything `helm install/upgrade/test` creates (including pods, PDBs and Helm's release Secrets), node
readiness and CPU architecture, schedulable capacity (allocatable minus what is already requested), default StorageClass (informational; the
chart is stateless), ingress controller, cluster DNS (found by the `k8s-app=kube-dns` label), Pod Security Admission (the chart is sent to the API
server as a server-side dry run into the target namespace, so that namespace's own labels decide), NetworkPolicy support, registry reachability and
egress to the LLM endpoint.

The NetworkPolicy probe fetches a file from a server pod **before** a deny-all policy exists (positive control: if that fails, the result is
"inconclusive", never a pass) and then requires the fetch to **time out** after it. The last two checks run from the workstation: repeat them
from a pod inside the cluster if the cluster sits behind a different proxy or firewall.

Resolve every FAIL before installing. A WARN needs a conscious decision recorded in the ticket.

## 4. Install (online)
```bash
kubectl create namespace guardrail
helm upgrade --install guardrail charts/llm-guardrail -n guardrail --wait --timeout 180s
helm test guardrail -n guardrail --logs
```
With the default values the gateway uses the in-cluster mock LLM. To tune the policy or sizing, copy `values.yaml`, change only what you need
and pass it with `-f my-values.yaml`. `values.schema.json` rejects unknown keys (a typo such as `gateway.replica` fails instead of being ignored),
invalid values and the `latest` image tag, and the chart refuses inconsistent combinations (for example `kind: anthropic` without the egress
allowlist) at render time. On the local kind cluster add `-f charts/llm-guardrail/values-kind.yaml` to expose the gateway through the ingress.

### Using an external LLM
```bash
kubectl -n guardrail create secret generic anthropic-api-key --from-literal=api-key="$ANTHROPIC_API_KEY"
# Resolve the provider endpoint to the addresses your firewall team will approve, then allow only those:
helm upgrade --install guardrail charts/llm-guardrail -n guardrail \
  -f charts/llm-guardrail/values-external-llm.yaml \
  --set 'networkPolicy.externalLLM.cidrs={<ip-or-cidr>,<ip-or-cidr>}' --wait
```
Notes: NetworkPolicy matches IP ranges, not hostnames, so provider IP changes require updating the list; consider an egress proxy or a CNI
with FQDN policies if the provider's addresses change often. The model id is `gateway.upstream.model` (default `claude-haiku-5-5`). Current Claude models think by default and thinking tokens count against
`max_tokens`, so the gateway sends `gateway.upstream.maxTokens` (4096) and a low `gateway.upstream.effort`; raise `maxTokens` if answers come back
empty (the log says `stop_reason=max_tokens`). A model refusal is returned as `502 upstream_refused`.
Prefer `existingSecret` to `gateway.secret.apiKey`: a key passed to Helm is stored in the release history. **The Anthropic adapter has only been
tested against a mocked transport, not the real API.**

Enterprise network settings (rendered and schema-checked, **not exercised end to end** in this repo):
- Egress proxy: `gateway.extraEnv` with `HTTPS_PROXY` / `NO_PROXY`; the NetworkPolicy must then allow the proxy's address instead of the provider's.
- Private CA (TLS-inspecting proxy, private endpoint): `gateway.caBundle.configMapName` mounts a PEM bundle and sets `SSL_CERT_FILE`. That
  replaces the default trust store, so include the public roots if the gateway also needs them.
- Private registry with credentials: `global.imagePullSecrets: [regcred]`.
- DNS not in `kube-system` or node-local DNS: `networkPolicy.dns.namespaceLabels`, `podLabels`, `extraCidrs` (for example `169.254.20.10/32`).
- Ingress controller running with `hostNetwork`: its traffic arrives from the node IP, which a namespace selector cannot match; list the node
  CIDR in `networkPolicy.allowedIngressCidrs`.

## 5. Install in an air-gapped environment
On a connected machine:
```bash
scripts/airgap-bundle.sh        # produces dist/llm-guardrail-airgap-<version>.tar.gz and a .sha256 file
```
The bundle contains the image archive (gateway, mock LLM, registry), the packaged chart, `values-airgapped.yaml`, the installer script, a
manifest and internal checksums. Transfer it by the site's approved method. The `.sha256` next to it detects corruption in transit; it does not
prove who built the bundle. For that, send the checksum over a separate trusted channel or sign it. Then on the offline site:
```bash
scripts/airgap-install.sh dist/llm-guardrail-airgap-<version>.tar.gz
```
The script verifies the outer checksum and then the internal ones, loads the images, starts a private registry, pushes the images, and
installs the chart with `global.imageRegistry` pointing at that registry. It ends by printing the pod image names and the registry's own access log (manifest and blob requests from the nodes): that, not network
isolation, is the evidence the nodes used the bundle. Blob requests appear only when the nodes did not already hold the layers. The script configures kind nodes; at a real customer site you push the images to their existing
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
For a full check from the repository: `REQUIRE_CLUSTER=1 pytest tests/integration -v`, `drills/06-networkpolicy-enforcement.sh`, and
`python scripts/eval_guardrails.py` to measure the guardrails on the labelled corpus.

## 7. Integrating applications
- **Address:** `http://guardrail-gateway.guardrail.svc.cluster.local/v1/chat` (port 80). Request: `{"messages":[{"role":"user","content":"..."}]}`;
  roles are `system`, `user`, `assistant`. All roles are screened; at most 50 messages, 20,000 characters per message, 100,000 characters in total
  and a 1 MiB request body (`413 request_too_large` beyond that, before the body is read into memory). The gateway does not authenticate callers and
  does not rate-limit: access is controlled by the NetworkPolicy alone, so put an authenticating, rate-limiting proxy in front if callers are untrusted.
- **Who may call it:** pods in namespaces listed in `networkPolicy.allowedNamespaces` (matched on the `kubernetes.io/metadata.name` label; default
  `ingress-nginx`). Add the application's namespace: `--set 'networkPolicy.allowedNamespaces={ingress-nginx,payments}'`.
- **Ingress:** `--set ingress.enabled=true --set ingress.host=guardrail.example.internal` (class `nginx`). Only `/v1` is routed; `/metrics`,
  `/readyz` and `/healthz` answer 404 through the ingress. For TLS set `ingress.tls.enabled=true` and `ingress.tls.secretName` (an existing
  `kubernetes.io/tls` Secret); TLS was **not** exercised here, only rendered. Without it the ingress is plain HTTP.
- **Response handling:** `200` allowed or redacted (`decision` tells which); `403` blocked (`reason`: `pii` or `prompt_injection`, with the matching rule
  ids); `413` body too large; `422` invalid request; `502` upstream failed or the model refused; `504` upstream timed out. Always log `request_id` on the application side: support can find the
  matching gateway log line.
- **Policy:** edit the `policy:` section of your values (`pii.mode: redact|block`, rules, injection threshold) and run `helm upgrade`; pods roll
  automatically and `policy.version` is returned on every response. A policy file that is not valid YAML leaves the pod NotReady with a log line
  saying why, instead of crash-looping.
- **Observability:** logs are JSON on stdout (`kubectl logs`); Prometheus metrics at `/metrics` (`gateway_requests_total`, `gateway_rule_hits_total`,
  `gateway_upstream_errors_total`, `gateway_upstream_latency_seconds`) reachable inside the cluster or by port-forward. A Prometheus in another namespace is blocked by the default-deny policy: add its namespace to
  `networkPolicy.allowedNamespaces` (the policy is per port, and the metrics share the API port, so that namespace can call `/v1/chat` too).
- **Readiness semantics:** a gateway pod is Ready only when its policy loaded **and** the upstream answered the probe's own check (nothing is cached: every readiness probe asks the upstream). If the single upstream goes
  away, all gateway replicas leave the Service together (see the trade-off in ARCHITECTURE.md).

## 8. Upgrade and rollback
```bash
helm diff upgrade ...            # optional plugin: preview changes
helm upgrade guardrail charts/llm-guardrail -n guardrail -f my-values.yaml --set policy.version=2026-12-01.1 \
  --rollback-on-failure --timeout 3m    # Helm 4: roll back automatically if pods do not become Ready (Helm 3: --atomic)
helm history guardrail -n guardrail
helm rollback guardrail <revision> -n guardrail --wait
```
Pass the same values file every time instead of `--reuse-values`: that flag also freezes the old release's chart *defaults*, so defaults added
by a newer chart version silently do not apply.
Rollouts are rolling (`maxUnavailable: 0`, `maxSurge: 1`) with a preStop sleep, so a failing release keeps the old pods serving. The measured effect
(a request loop at 20 requests per second through the ingress across three upgrades and a rollback) is in [EVIDENCE.md](EVIDENCE.md); treat the number as a
measurement of that cluster, not a guarantee.
`scripts/upgrade-rollback-demo.sh` rehearses the full cycle twice (a config change, then an image upgrade from 0.1.0 to 0.1.1), verifies the live
policy and gateway version after each step, and rolls back by itself if a verification fails. Note the revision from `helm history` before every window.

Make changes only through Helm. A hand edit of a Helm-managed object (`kubectl set env`, `kubectl edit`) makes the next Helm 4 upgrade fail with a
field-ownership conflict: see drill 7 for the diagnosis and the fix.

## 9. Node maintenance
With two or more gateway replicas the chart renders a PodDisruptionBudget (`minAvailable: 1`) and spreads replicas over nodes. Drain one node at a
time, wait for the replacements to be Ready, then continue. Drill 8 shows a drain held by the budget and the request loop recording no errors.

## 10. Uninstall
```bash
helm uninstall guardrail -n guardrail
kubectl delete namespace guardrail          # only if the namespace was created for this release
```
The chart creates no persistent volumes. Secrets you created yourself (`kubectl create secret`) are not removed by Helm.

## 11. Troubleshooting
| Symptom | Likely cause | Check | Fix |
|---|---|---|---|
| Pod `ImagePullBackOff` | Wrong tag, registry unreachable, missing pull secret (the message `insufficient_scope` does not tell which) | `kubectl describe pod` events; compare with the previous revision's image | Correct tag or registry; `global.imagePullSecrets`; offline bundle (section 5). Drill 1 |
| Pod `CreateContainerConfigError` | Secret or key missing in this namespace | `kubectl describe pod`; `kubectl describe secret` | Create the Secret; match `gateway.secret.key`. Drill 5 |
| Pod `CrashLoopBackOff`, reason `OOMKilled` | Memory limit too low | `kubectl describe pod` (Last State) | Raise `gateway.resources.limits.memory`. Drill 4 |
| Pod Running but `0/1` Ready | Upstream unreachable or policy not loaded | `kubectl logs <pod>` (`not ready` line shows the reason) | Fix upstream URL/DNS/egress; check ConfigMap. Drills 2, 3 |
| Clients get `502` | Upstream refused or returned an error | gateway log `decision: upstream_error`; test upstream directly | Repair upstream; check egress allowlist |
| Clients get `504` | Upstream slower than `gateway.upstream.timeoutSeconds` | gateway logs `upstream_ms`; `gateway_upstream_latency_seconds` | Fix upstream latency; adjust timeout only with the app owner |
| Clients get `403` | Policy blocked the request | response `reason` and `rules` | Review the policy; check false positives |
| Calls from an application time out (no HTTP status) | NetworkPolicy does not allow that namespace | `kubectl describe networkpolicy guardrail-gateway-ingress` | Add namespace to `allowedNamespaces`. Drill 6 proves enforcement |
| Name resolution errors in gateway logs | Egress policy without DNS rule, or DNS down | `kubectl -n kube-system get pods -l k8s-app=kube-dns` | Restore DNS egress. Drill 3 |
| `helm upgrade` fails with "conflict with kubectl-..." | A hand edit owns a field Helm wants to set | `kubectl get <obj> --show-managed-fields` | Drill 7 |
| `kubectl drain` hangs, "violate the pod's disruption budget" | A budget is holding the last Ready replica; replacements cannot schedule | `kubectl get pdb -A`; `kubectl describe pod <pending>` | Drill 8 |
| `ImagePullBackOff` ("pull access denied") although the image is on the node | The kubelet keeps records of images it pulled itself; an image it pulled from one registry name (the air-gap registry) and that was later loaded out of band under another name (`kind load`) is checked against the registry again and fails | `ls /var/lib/kubelet/image_manager/pulled` on the node; `crictl images` shows the image | Use one delivery path per cluster. To recover a lab node: delete those record files and restart the kubelet (found on kind, 2026-11-27) |
| Policy change not applied | Edited the ConfigMap by hand instead of via Helm | `kubectl get pods` ages; `helm get values` | Change values and `helm upgrade` (checksum rolls pods) |
| `helm install` fails with a schema or `fail` error | Invalid or inconsistent value | Message names the field | Correct the value |

Collect evidence before escalating: `scripts/collect-diagnostics.sh` produces a tarball (pod status, events, describes, logs including previous
containers, Helm values and manifest). Credentials are redacted by a tested filter (`tests/scripts/test-redact.sh`), but redaction is a safety net,
not a guarantee: read the bundle before sending it outside the organisation.
