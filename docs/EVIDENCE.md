# Evidence

Every output below was produced on 2026-11-27 on one workstation by the commands named in each section; nothing is edited except
where a line is marked cut. Full logs are not committed (`reports/` is gitignored); the drill writeups contain their own full captures.

## Environment
| Component | Version |
|---|---|
| Host | Windows 11 Home 10.0.26200, Git Bash, Docker Desktop 29.9.3 (12 CPUs, 8 GB for the VM) |
| kind | v0.33.0, node image `kindest/node` (Kubernetes v1.37.0, containerd 2.3.4), 1 control plane + 2 workers |
| CNI / ingress | Calico v3.28.2, ingress-nginx (kind's documented manifest) |
| Helm / kubectl | Helm v4.3.2, kubectl client v1.36.1 |
| Gateway image | `python:3.12.16-slim-bookworm`, fastapi 0.165.0, starlette 1.10.0, pydantic 2.14.4 |
| Local Python | 3.14.2 with newer dependencies than the image (unit tests were also run in the 3.12.16 image environment) |
| kubeconform / Trivy / shellcheck | v0.6.7 / 0.58.1 / koalaman/shellcheck:stable, all run from container images |

CI: the GitHub Actions workflow has **not** been run (repo not pushed). Its steps are the commands in this file.

## Failures found by running it, and what was done
| Found | How | Fix |
|---|---|---|
| Duplicate `app.kubernetes.io/instance` label keys in the Deployments | `kubeconform -strict` and the duplicate-key check failed on the previous commit | label helpers split; check is part of `scripts/chart-check.sh` |
| NetworkPolicy preflight probe could not fail (404 and non-zero exit read as "blocked") | review, then positive control added; bad probe image now yields "inconclusive" | rewritten probe |
| `test_upstream_failure_codes[504]` failed | the coordinator suspected mock latency delaying `/healthz`; it was not: the test's port-forward was bound to a gateway pod that the upgrade replaced | tests open a fresh port-forward |
| ingress-nginx controller landed on a worker, so `localhost:8080` was dead | ingress test; the manifest no longer pins the node | `cluster-up.sh` patches the nodeSelector |
| Drill wait loops matched stale events from earlier runs and returned at once | drill 2 run | wait on the pod's own events |
| Support bundle leaked `value: hunter2-planted` (env var name and value on separate lines) | planted-credential test | redactor rule and test added; rerun shows nothing leaked |
| `crictl rmi` on the registry-named image removed the local image sharing its ID and left an unpullable stub | the next default install went to `ImagePullBackOff` | step removed; the registry's access log is the evidence instead |
| Availability probe measured about 0.5 requests/s | `localhost` resolves IPv6 first on Windows (~2 s) | probe uses 127.0.0.1 and four loops |
| Trivy: 3 HIGH starlette CVEs | image scan | dependencies and base image bumped |
| `containerd config dump` shows an empty registry `config_path`, yet `certs.d` is honoured | air-gap install | check is a warning, proven by the registry log |

## Static checks (`scripts/chart-check.sh`)
```text
--- default
ok: 12 documents, no duplicate keys
Summary: 12 resources found parsing stdin - Valid: 12, Invalid: 0, Errors: 0, Skipped: 0
--- airgapped
ok: 12 documents, no duplicate keys
Summary: 12 resources found parsing stdin - Valid: 12, Invalid: 0, Errors: 0, Skipped: 0
--- external-llm
ok: 9 documents, no duplicate keys
Summary: 9 resources found parsing stdin - Valid: 9, Invalid: 0, Errors: 0, Skipped: 0
--- ingress+tls+extras
ok: 13 documents, no duplicate keys
Summary: 13 resources found parsing stdin - Valid: 13, Invalid: 0, Errors: 0, Skipped: 0
--- kind-ingress
ok: 13 documents, no duplicate keys
Summary: 13 resources found parsing stdin - Valid: 13, Invalid: 0, Errors: 0, Skipped: 0
--- single-replica
ok: 11 documents, no duplicate keys
Summary: 11 resources found parsing stdin - Valid: 11, Invalid: 0, Errors: 0, Skipped: 0
--- PDB is not rendered for a single replica
--- bad values must be rejected
rejected: image tag latest
rejected: pii.mode=maybe
rejected: typo gateway.replica
rejected: typo netwrokPolicy
rejected: external values without cidrs
rejected: anthropic without egress allow
rejected: mock kind with mockLlm disabled
rejected: tls enabled without secret
chart-check: all checks passed
```

The previous commit's chart, same checks:
```text
# chart at commit 349e5dc (before round 2), 2026-11-27T02:01:08Z
FAIL: duplicate key 'app.kubernetes.io/instance'
  in "<stdin>", line 247, column 5
stdin - Deployment t-gateway failed validation: error unmarshalling resource: error converting YAML to JSON: yaml: unmarshal errors:
  line 12: key "app.kubernetes.io/instance" already set in map
  line 32: key "app.kubernetes.io/instance" already set in map
```

## Unit tests, linters, redaction test
```text
Python 3.12.16
fastapi==0.165.0
httpx==0.29.0
prometheus_client==0.26.0
pydantic==2.14.4
pydantic_core==2.50.5
pytest==9.2.0
pytest-asyncio==1.5.0
PyYAML==6.0.4
ruff==0.17.6
starlette==1.10.0
uvicorn==0.54.0
96 passed, 1 warning in 5.05s
All checks passed!
32 files already formatted
```
```text
# 2026-11-27T02:40:18Z local venv: Python 3.14.2 with NEWER deps than the image (fastapi 0.165.0, starlette 1.10.0, pytest 9.2.0)
96 passed, 1 warning in 27.74s
All checks passed!
redact tests passed
```
Shell: `shellcheck -x` over `scripts/`, `drills/`, `tests/scripts/` exits 0 (`.shellcheckrc` lists four deliberate exceptions).

## Install and helm test
```text
# 2026-11-27T03:19:23Z
Phase:          Succeeded

POD LOGS: guardrail-smoke-test (smoke)
PASS readyz is 200
PASS policy version matches release
PASS chat returns 200
PASS email redacted before upstream
PASS X-Request-ID header present
PASS output guardrail redacts upstream leak
PASS prompt injection blocked with 403

```

## Preflight with the NetworkPolicy probe
```text
PASS  kubernetes version           server v1.37.0 (need >= 1.27); Client Version: v1.36.1
PASS  rbac in namespace guardrail  can create the objects the chart needs (incl. pods, PDBs, Helm release secrets)
PASS  node readiness               3/3 nodes Ready
PASS  node architecture            amd64 (images must be built for this architecture)
PASS  capacity                     free to schedule 34050m CPU / 22746Mi memory (allocatable 36000m / 23396Mi minus requested 1950m / 650Mi) vs chart requests 250m / 320Mi
PASS  default storageclass         standard
PASS  ingress controller           IngressClass: nginx
PASS  cluster dns                  2/2 kube-dns pods ready (label k8s-app=kube-dns)
PASS  pod security (ns guardrail)  enforce=none; chart complies with the restricted profile
PASS  networkpolicy support        CNI known to enforce NetworkPolicy: calico (PROBE_NETPOL=1 proves it)
PASS  networkpolicy enforcement    active probe: fetch worked before deny-all (control) and TIMED OUT after it
PASS  registry reachable           https://registry-1.docker.io/v2/ -> HTTP 401 (401 is normal for registries)
PASS  egress to upstream llm       https://api.anthropic.com -> HTTP 404
Summary: 13 PASS, 0 WARN, 0 FAIL   (report: reports/preflight-20261127-115050.txt)
```
Negative case, earlier probe implementation with an unpullable probe image: `WARN networkpolicy enforcement  probe inconclusive: server pod did not become Ready` (12 PASS, 1 WARN, 0 FAIL), not a PASS.

## Integration tests
```text
tests/integration/test_gateway_cluster.py::test_ready_and_policy_version PASSED [ 10%]
tests/integration/test_gateway_cluster.py::test_pii_redacted_end_to_end PASSED [ 20%]
tests/integration/test_gateway_cluster.py::test_output_guardrail_redacts_upstream_leak PASSED [ 30%]
tests/integration/test_gateway_cluster.py::test_prompt_injection_blocked PASSED [ 40%]
tests/integration/test_gateway_cluster.py::test_request_id_appears_in_pod_logs_without_pii PASSED [ 50%]
tests/integration/test_gateway_cluster.py::test_metrics_increment PASSED [ 60%]
tests/integration/test_gateway_cluster.py::test_upstream_failure_codes[fault0-502] PASSED [ 70%]
tests/integration/test_gateway_cluster.py::test_upstream_failure_codes[fault1-504] PASSED [ 80%]
tests/integration/test_gateway_cluster.py::test_security_context_is_enforced_on_the_running_pod PASSED [ 90%]
tests/integration/test_gateway_cluster.py::test_ingress_exposes_only_the_api PASSED [100%]
======================== 10 passed in 64.84s (0:01:04) ========================
```

## Drills
Full captures (inject, describe, events, logs, restore) are in each writeup: [01](../drills/01-bad-image-tag.md), [02](../drills/02-upstream-failure.md),
[03](../drills/03-dns-egress-blocked.md), [04](../drills/04-oomkilled.md), [05](../drills/05-missing-secret.md),
[06](../drills/06-networkpolicy-enforcement.md), [07](../drills/07-config-drift.md) (incident report), [08](../drills/08-node-drain.md).
They were captured on the image built before the final dependency bump; the behaviour they exercise is unchanged.

## Upgrade and rollback (`scripts/upgrade-rollback-demo.sh`)
```text
==> baseline: revision 5, pii.mode=redact, gateway image tag 0.1.0
    readyz: {"version":"0.1.0","policy_loaded":true,"upstream_reachable":true,"policy_version":"2026-11-27.1"}
    chat with an email address -> HTTP 200 (expected 200 for pii.mode=redact)
==> A. config change: pii.mode=block
    readyz: {"version":"0.1.0","policy_loaded":true,"upstream_reachable":true,"policy_version":"upgrade-demo-114746"}
    chat with an email address -> HTTP 403 (expected 403 for pii.mode=block)
==> A. rollback to revision 5
    readyz: {"version":"0.1.0","policy_loaded":true,"upstream_reachable":true,"policy_version":"2026-11-27.1"}
    chat with an email address -> HTTP 200 (expected 200 for pii.mode=redact)
==> B. image upgrade: build gateway 0.1.1 and load it into kind
    readyz: {"version":"0.1.1","policy_loaded":true,"upstream_reachable":true,"policy_version":"2026-11-27.1"}
    chat with an email address -> HTTP 200 (expected 200 for pii.mode=redact)
guardrail-gateway-5ff9b8cdd8-kq64l  llm-guardrail/gateway:0.1.1
guardrail-gateway-5ff9b8cdd8-qpml4  llm-guardrail/gateway:0.1.1
guardrail-gateway-86f69d77d7-r9wkp  llm-guardrail/gateway:0.1.0
==> B. rollback to revision 7
    readyz: {"version":"0.1.0","policy_loaded":true,"upstream_reachable":true,"policy_version":"2026-11-27.1"}
    chat with an email address -> HTTP 200 (expected 200 for pii.mode=redact)
==> OK: config change and image upgrade both verified, and both rolled back
exit code: 0
```

## Availability during rollouts (`scripts/rollout-availability.sh`)
```text
==> request loop: 20/s for 150s through the ingress
==> rollout 1: policy.version change
==> rollout 2: policy.version change
==> rollout 3: gateway image 0.1.1
==> rollback to revision 9
requests sent: 2994 in 150s (target 20/s, 4 concurrent loops)
  HTTP 200: 2994
failed requests: 0 of 2994
```
Negative control (delete the single upstream pod while the loop runs):
```text
requests sent: 691 in 45s (target 20/s, 4 concurrent loops)
  HTTP 200: 572
  HTTP 502: 47
  HTTP 503: 64
  transport error: TimeoutError: 8
failed requests: 119 of 691
first failure at t+8.1s (HTTP 502), last at t+26.6s (HTTP 503)
```

## Air-gapped install
```text
==> bundle ready: dist/llm-guardrail-airgap-0.1.0.tar.gz (65M)
  llm-guardrail/gateway:0.1.0  sha256:0ea3fad2c101ed3ffc5020df49d253abda9eea4316befea8d936f0773bc59b20
  llm-guardrail/mock-llm:0.1.0  sha256:52ce29dd78f365585638aaed53b9e9f5e09d34de12f616e9099a13ed5a1c5950
  registry:2.8.3  sha256:a3d8aaa63ed8681a604f1dea0aa03f100d5895b6a58ace528858a7b332415373
-rw-r--r-- 1 user group 67787188 Nov 27 11:55 llm-guardrail-airgap-0.1.0.tar.gz
-rw-r--r-- 1 user group      100 Nov 27 11:55 llm-guardrail-airgap-0.1.0.tar.gz.sha256
897720f00e104c6ac9a57946a697c35d83c7276a60d5109e85a85e8c25f5299e *llm-guardrail-airgap-0.1.0.tar.gz
```
```text
# negative test: one byte of the bundle overwritten after the checksum was made, 2026-11-27T02:55:48Z
==> verifying the bundle file against its .sha256 (outer checksum)
llm-guardrail-airgap-0.1.0.tar.gz: FAILED
sha256sum: WARNING: 1 computed checksum did NOT match
exit code: 1
```
```text
==> verifying the bundle file against its .sha256 (outer checksum)
llm-guardrail-airgap-0.1.0.tar.gz: OK
==> verifying the checksums inside the bundle
images.tar: OK
./llm-guardrail-0.1.0.tgz: OK
values-airgapped.yaml: OK
airgap-install.sh: OK
lib.sh: OK
MANIFEST.txt: OK
==> loading images into the local Docker daemon
==> starting private registry 'kind-registry'
==> teaching each kind node's containerd to use the registry over plain HTTP
==> pushing images to the registry
registry catalog:
{"repositories":["llm-guardrail/gateway","llm-guardrail/mock-llm"]}
==> installing the chart FROM THE BUNDLE with registry kind-registry:5000
==> evidence 1: images the pods run (all must start with kind-registry:5000/)
guardrail-gateway-7c9b9d9c-f7b64  kind-registry:5000/llm-guardrail/gateway:0.1.0
guardrail-gateway-7c9b9d9c-zv5vw  kind-registry:5000/llm-guardrail/gateway:0.1.0
guardrail-mock-llm-678984d54d-tpd84  kind-registry:5000/llm-guardrail/mock-llm:0.1.0
==> evidence 2: the registry's own access log shows the nodes fetching the images from it
172.18.0.2 - - [27/Nov/2026:03:16:20 +0000] "GET /v2/llm-guardrail/gateway/manifests/sha256:0ea3fad2c101ed3ffc5020df49d253abda9eea4316befea8d936f0773bc59b20 HTTP/1.1" 200 856 "" "containerd/v2.3.4"
172.18.0.4 - - [27/Nov/2026:03:16:20 +0000] "GET /v2/llm-guardrail/mock-llm/manifests/sha256:52ce29dd78f365585638aaed53b9e9f5e09d34de12f616e9099a13ed5a1c5950 HTTP/1.1" 200 856 "" "containerd/v2.3.4"
172.18.0.4 - - [27/Nov/2026:03:16:20 +0000] "GET /v2/llm-guardrail/gateway/manifests/sha256:0ea3fad2c101ed3ffc5020df49d253abda9eea4316befea8d936f0773bc59b20 HTTP/1.1" 200 856 "" "containerd/v2.3.4"
PASS readyz is 200
PASS policy version matches release
PASS chat returns 200
PASS email redacted before upstream
PASS X-Request-ID header present
PASS output guardrail redacts upstream leak
PASS prompt injection blocked with 403
exit code: 0
```

## Support bundle redaction test
```text
# collect-diagnostics redaction test on the live release, 2026-11-27T03:15:14Z
$ plant fake credentials: two env vars in the Deployment, a ConfigMap value, and a key inside a request body
upgraded
$ scripts/collect-diagnostics.sh
==> collecting from namespace 'guardrail' into diagnostics-20261127-121531
==> support bundle: diagnostics-20261127-121531.tar.gz
Redaction is a safety net, not a guarantee: read the bundle before it leaves your organisation.
bundle: diagnostics-20261127-121531.tar.gz (16K), files: 28
$ grep for the planted values in the bundle (expect nothing)
none found
$ env var NAMES are kept, values are not:
            - name: PLANTED_API_KEY
              value: <redacted>
            - name: PLANTED_PASSWORD
              value: <redacted>
$ matches inside the tarball itself (expect 0)
0
```

## Guardrail evaluation
Before this round of fixes (all 50 prompts then in the corpus, deployed 0.1.0 image of the previous commit):
```text
MISS b02  dev      benign    near-miss          HTTP 403 blocked {'inj_ignore_previous': 1}
MISS b03  dev      benign    near-miss          HTTP 403 blocked {'inj_reveal_system_prompt': 1}
MISS p05  dev      pii       card-after-number  HTTP 200 allow rules={} leaked=['<19 chars>']
MISS p07  dev      pii       secret             HTTP 200 allow rules={} leaked=['<36 chars>']
MISS p13  heldout  pii       us-phone           HTTP 200 allow rules={} leaked=['<8 chars>']
MISS p18  heldout  pii       dotted-phone       HTTP 200 allow rules={} leaked=['<13 chars>']
MISS i04  dev      injection system-role        HTTP 200 allow rules={}
MISS i05  dev      injection role-trick         HTTP 200 allow rules={'inj_role_override': 1}
MISS i07  dev      injection korean             HTTP 200 allow rules={}
MISS i11  heldout  injection classic            HTTP 200 allow rules={}
MISS i12  heldout  injection role-trick         HTTP 200 allow rules={}
MISS i13  heldout  injection fake-tag           HTTP 200 allow rules={'inj_fake_system_tag': 1}
MISS i14  heldout  injection korean             HTTP 200 allow rules={}
MISS i15  heldout  injection assistant-role     HTTP 200 allow rules={}
MISS i16  heldout  injection prompt-leak        HTTP 200 allow rules={}
MISS i17  heldout  injection obfuscated         HTTP 200 allow rules={}
  false positives (benign blocked or redacted): 2/9 = 22%
  false negatives, PII not redacted:            2/8 = 25%
  false negatives, injection not blocked:       3/8 = 38%
  false positives (benign blocked or redacted): 0/10 = 0%
  false negatives, PII not redacted:            2/8 = 25%
  false negatives, injection not blocked:       7/7 = 100%
[all] 50 prompts
  false positives (benign blocked or redacted): 2/19 = 11%
  false negatives, PII not redacted:            4/16 = 25%
  false negatives, injection not blocked:       10/15 = 67%
```
After (60 prompts; see the README for how to read the splits):
```text
MISS i13  heldout  injection fake-tag           HTTP 200 allow rules={'inj_fake_system_tag': 1}
MISS i17  heldout  injection obfuscated         HTTP 200 allow rules={}
MISS f08  fresh    injection fake-tag           HTTP 200 allow rules={}
MISS f10  fresh    injection other-language     HTTP 200 allow rules={}

[dev] 25 prompts
  false positives (benign blocked or redacted): 0/9 = 0%
  false negatives, PII not redacted:            0/8 = 0%
  false negatives, injection not blocked:       0/8 = 0%
[heldout] 25 prompts
  false positives (benign blocked or redacted): 0/10 = 0%
  false negatives, PII not redacted:            0/8 = 0%
  false negatives, injection not blocked:       2/7 = 29%
[fresh] 10 prompts
  false positives (benign blocked or redacted): 0/4 = 0%
  false negatives, PII not redacted:            0/3 = 0%
  false negatives, injection not blocked:       2/3 = 67%
[all] 60 prompts
  false positives (benign blocked or redacted): 0/23 = 0%
  false negatives, PII not redacted:            0/19 = 0%
  false negatives, injection not blocked:       4/18 = 22%
```

## Image scan
`docker run aquasec/trivy:0.58.1 image --severity CRITICAL,HIGH --ignore-unfixed` on the first image: Python packages **Total: 3 (HIGH: 3)**, all
starlette 0.41.3 (CVE-2025-62727, CVE-2026-48818, CVE-2026-54283), plus Debian perl packages. After bumping the pins and the base image (log
`2026-11-27T03:20Z`): **Total: 4 (HIGH: 4)**, all `libpam*` 1.5.2-6+deb12u2 (fixed in deb12u3), no Python findings.
