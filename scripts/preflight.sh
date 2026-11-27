#!/usr/bin/env bash
# Customer environment assessment. Read-only: it only runs `kubectl get/auth` and `curl`.
# Prints PASS / WARN / FAIL per check and saves the same report to reports/preflight-<time>.txt
# so it can be attached to the deployment ticket.
#
# Settings (environment variables):
#   NS=guardrail                         target namespace
#   UPSTREAM_URL=https://api.anthropic.com   external LLM endpoint to test (EXTERNAL_LLM=1 makes failure a FAIL)
#   REGISTRY_URL=https://registry-1.docker.io/v2/   registry to test (use the private one for air-gapped sites)
#   NEED_CPU_M=250 NEED_MEM_MI=320       what the chart requests with default values
#   PROBE_NETPOL=1                       also run an active NetworkPolicy enforcement probe (creates a temp namespace)
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need kubectl curl awk

UPSTREAM_URL="${UPSTREAM_URL:-https://api.anthropic.com}"
REGISTRY_URL="${REGISTRY_URL:-https://registry-1.docker.io/v2/}"
NEED_CPU_M="${NEED_CPU_M:-250}"
NEED_MEM_MI="${NEED_MEM_MI:-320}"
MIN_MINOR=27 # chart kubeVersion >=1.27

mkdir -p "$REPO_ROOT/reports"
REPORT="$REPO_ROOT/reports/preflight-$(date +%Y%m%d-%H%M%S).txt"
PASS=0 WARNS=0 FAILS=0

emit() { # emit LEVEL "check" "detail"
  printf '%-5s %-28s %s\n' "$1" "$2" "$3" | tee -a "$REPORT"
  case "$1" in PASS) PASS=$((PASS+1));; WARN) WARNS=$((WARNS+1));; FAIL) FAILS=$((FAILS+1));; esac
}

# Convert Kubernetes quantities to millicores / MiB so we can compare numbers.
cpu_to_m() { awk '{ if ($1 ~ /m$/) { sub(/m/,"",$1); print $1 } else print $1*1000 }'; }
mem_to_mi() { awk '{ v=$1; if (v ~ /Ki$/) {sub(/Ki/,"",v); print v/1024} else if (v ~ /Mi$/) {sub(/Mi/,"",v); print v}
                    else if (v ~ /Gi$/) {sub(/Gi/,"",v); print v*1024} else print v/1048576 }'; }

{
  echo "LLM guardrail gateway - environment assessment"
  echo "date: $(date -u +%FT%TZ)   context: $(kubectl config current-context 2>/dev/null || echo none)"
  echo "-----------------------------------------------------------------------"
} | tee "$REPORT"

# 1. Cluster reachable + version. The chart needs Kubernetes >= 1.27.
if ! kubectl get --raw /version >"$REPORT.ver" 2>/dev/null; then
  emit FAIL "cluster reachable" "kubectl cannot reach the API server (check kubeconfig/context)"
  rm -f "$REPORT.ver"; echo "FAIL: $FAILS" | tee -a "$REPORT"; exit 1
fi
minor="$(sed -n 's/.*"minor": *"\([0-9]*\).*/\1/p' "$REPORT.ver")"
gitver="$(sed -n 's/.*"gitVersion": *"\([^"]*\)".*/\1/p' "$REPORT.ver")"
rm -f "$REPORT.ver"
client="$(kubectl version --client 2>/dev/null | head -1)"
if [[ "${minor:-0}" -ge "$MIN_MINOR" ]]; then
  emit PASS "kubernetes version" "server $gitver (need >= 1.$MIN_MINOR); $client"
else
  emit FAIL "kubernetes version" "server $gitver is older than 1.$MIN_MINOR"
fi

# 2. Permissions in the target namespace.
missing=""
for verb_res in "create deployments" "create services" "create configmaps" "create secrets" "create networkpolicies"; do
  kubectl auth can-i $verb_res -n "$NS" >/dev/null 2>&1 || missing+="$verb_res; "
done
if [[ -z "$missing" ]]; then emit PASS "rbac in namespace $NS" "can create the objects the chart needs"
else emit FAIL "rbac in namespace $NS" "cannot: $missing"; fi

# 3. Node readiness.
total="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
notready="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 !~ /^Ready/ {n++} END {print n+0}')"
if [[ "$total" -gt 0 && "$notready" -eq 0 ]]; then emit PASS "node readiness" "$total/$total nodes Ready"
else emit FAIL "node readiness" "$notready of $total nodes not Ready"; fi

# 4. Capacity: allocatable (not capacity) is what the scheduler can really use.
alloc_cpu="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.cpu}{"\n"}{end}' | cpu_to_m | awk '{s+=$1} END {print s+0}')"
alloc_mem="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' | mem_to_mi | awk '{s+=$1} END {printf "%d", s}')"
detail="allocatable ${alloc_cpu}m CPU / ${alloc_mem}Mi memory vs chart requests ${NEED_CPU_M}m / ${NEED_MEM_MI}Mi"
if   [[ "$alloc_cpu" -lt "$NEED_CPU_M" || "$alloc_mem" -lt "$NEED_MEM_MI" ]]; then emit FAIL "capacity" "$detail"
elif [[ "$alloc_cpu" -lt $((NEED_CPU_M*3)) || "$alloc_mem" -lt $((NEED_MEM_MI*3)) ]]; then emit WARN "capacity" "$detail (less than 3x headroom; other workloads also need room)"
else emit PASS "capacity" "$detail"; fi

# 5. Default StorageClass (the chart is stateless, so this is informational).
sc="$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}' 2>/dev/null)"
if [[ -n "$sc" ]]; then emit PASS "default storageclass" "$sc"
else emit WARN "default storageclass" "none set (not needed by this chart; needed if you add persistence)"; fi

# 6. Ingress controller (only needed for ingress.enabled=true).
ic="$(kubectl get ingressclass --no-headers 2>/dev/null | awk '{print $1}' | paste -sd, -)"
if [[ -n "$ic" ]]; then emit PASS "ingress controller" "IngressClass: $ic"
else emit WARN "ingress controller" "no IngressClass found (use port-forward or install a controller)"; fi

# 7. CoreDNS: the gateway resolves the upstream by name, so broken DNS means 502s.
want="$(kubectl -n kube-system get deploy coredns -o jsonpath='{.spec.replicas}' 2>/dev/null)"
have="$(kubectl -n kube-system get deploy coredns -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
if [[ -n "$want" && "${have:-0}" -ge 1 && "${have:-0}" -eq "$want" ]]; then emit PASS "coredns" "$have/$want ready"
else emit FAIL "coredns" "ready ${have:-0}/${want:-?} (kubectl -n kube-system get deploy coredns)"; fi

# 8. NetworkPolicy support: identify the CNI. Names alone do not prove enforcement.
pods="$(kubectl -n kube-system get pods --no-headers 2>/dev/null | awk '{print $1}')"
if   grep -qiE 'calico|cilium|antrea|weave' <<<"$pods"; then
  emit PASS "networkpolicy support" "CNI known to enforce NetworkPolicy: $(grep -oiE 'calico|cilium|antrea|weave' <<<"$pods" | head -1)"
elif grep -qi 'kindnet' <<<"$pods"; then
  emit WARN "networkpolicy support" "kindnet: enforcement depends on its version; prove it with drills/06-networkpolicy-enforcement.sh"
else
  emit WARN "networkpolicy support" "CNI not recognised; prove enforcement with drills/06 or PROBE_NETPOL=1"
fi
if [[ "${PROBE_NETPOL:-0}" == "1" ]]; then
  probe_img="${PROBE_IMAGE:-busybox:1.36.1}"
  kubectl create ns np-probe >/dev/null 2>&1 || true
  kubectl -n np-probe run srv --image="$probe_img" --restart=Never --port=8080 -- httpd -f -p 8080 >/dev/null 2>&1
  kubectl -n np-probe wait --for=condition=Ready pod/srv --timeout=60s >/dev/null 2>&1
  ip="$(kubectl -n np-probe get pod srv -o jsonpath='{.status.podIP}')"
  kubectl -n np-probe apply -f - >/dev/null <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: deny-all-ingress }
spec: { podSelector: {}, policyTypes: [Ingress] }
YAML
  sleep 3
  if kubectl -n np-probe run cli --rm -i --restart=Never --image="$probe_img" -- wget -q -T 4 -O- "http://$ip:8080" >/dev/null 2>&1; then
    emit FAIL "networkpolicy enforcement" "active probe: traffic still flowed under deny-all (policies are NOT enforced)"
  else
    emit PASS "networkpolicy enforcement" "active probe: deny-all blocked traffic"
  fi
  kubectl delete ns np-probe --wait=false >/dev/null 2>&1
fi

# 9. Image registry reachable from where this script runs.
code="$(curl -s -o "$DEVNULL" -m 6 -w '%{http_code}' "$REGISTRY_URL" || true)"
if [[ "$code" != "000" && -n "$code" ]]; then emit PASS "registry reachable" "$REGISTRY_URL -> HTTP $code (401 is normal for registries)"
else emit WARN "registry reachable" "$REGISTRY_URL unreachable from this host; use the air-gapped bundle (docs/DEPLOYMENT_GUIDE.md)"; fi

# 10. Egress to the upstream LLM API. Any HTTP status proves DNS + routing + TLS work.
code="$(curl -s -o "$DEVNULL" -m 6 -w '%{http_code}' "$UPSTREAM_URL" || true)"
if [[ "$code" != "000" && -n "$code" ]]; then emit PASS "egress to upstream llm" "$UPSTREAM_URL -> HTTP $code"
elif [[ "${EXTERNAL_LLM:-0}" == "1" ]]; then emit FAIL "egress to upstream llm" "$UPSTREAM_URL unreachable: open the egress path before installing"
else emit WARN "egress to upstream llm" "$UPSTREAM_URL unreachable (fine for mock/air-gapped installs)"; fi
echo "  (checks 9 and 10 run from this workstation; confirm from a pod in the cluster before go-live)" | tee -a "$REPORT"

echo "-----------------------------------------------------------------------" | tee -a "$REPORT"
echo "Summary: $PASS PASS, $WARNS WARN, $FAILS FAIL   (report: $REPORT)" | tee -a "$REPORT"
[[ "$FAILS" -eq 0 ]]
