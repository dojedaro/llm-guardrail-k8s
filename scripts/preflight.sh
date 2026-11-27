#!/usr/bin/env bash
# Customer environment assessment. Read-only apart from the optional NetworkPolicy probe (PROBE_NETPOL=1),
# which creates and deletes a temporary namespace. Prints PASS / WARN / FAIL per check and saves the same
# report to reports/preflight-<time>.txt so it can be attached to the deployment ticket.
#
# Settings (environment variables):
#   NS=guardrail                         target namespace
#   UPSTREAM_URL=https://api.anthropic.com   external LLM endpoint to test (EXTERNAL_LLM=1 makes failure a FAIL)
#   REGISTRY_URL=https://registry-1.docker.io/v2/   registry to test (use the private one for air-gapped sites)
#   NEED_CPU_M=250 NEED_MEM_MI=320       what the chart requests with default values
#   PROBE_NETPOL=1                       also run an active NetworkPolicy enforcement probe
#   PROBE_IMAGE=busybox:1.36.1           image for the probe pods (must be pullable by the cluster)
set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need kubectl helm curl awk

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

# Convert Kubernetes quantities to millicores / MiB so we can compare numbers. Blank lines are skipped.
cpu_to_m() { awk 'NF { if ($1 ~ /m$/) { sub(/m/,"",$1); print $1 } else print $1*1000 }'; }
mem_to_mi() { awk 'NF { v=$1; if (v ~ /Ki$/) {sub(/Ki/,"",v); print v/1024} else if (v ~ /Mi$/) {sub(/Mi/,"",v); print v}
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

# 2. Permissions in the target namespace: everything `helm install/upgrade/test` creates, including the
#    Secret Helm itself uses to store release history.
missing=""
for verb_res in "create deployments.apps" "create services" "create configmaps" "create secrets" "update secrets" \
                "create pods" "create networkpolicies.networking.k8s.io" "create poddisruptionbudgets.policy"; do
  # $verb_res is a "verb resource" pair and must word-split into two arguments.
  # shellcheck disable=SC2086
  kubectl auth can-i $verb_res -n "$NS" >/dev/null 2>&1 || missing+="$verb_res; "
done
if [[ -z "$missing" ]]; then emit PASS "rbac in namespace $NS" "can create the objects the chart needs (incl. pods, PDBs, Helm release secrets)"
else emit FAIL "rbac in namespace $NS" "cannot: $missing"; fi

# 3. Node readiness and CPU architecture (the images must match it).
total="$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')"
notready="$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 !~ /^Ready/ {n++} END {print n+0}')"
if [[ "$total" -gt 0 && "$notready" -eq 0 ]]; then emit PASS "node readiness" "$total/$total nodes Ready"
else emit FAIL "node readiness" "$notready of $total nodes not Ready"; fi
archs="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.architecture}{"\n"}{end}' | sort -u | paste -sd, -)"
if [[ "$archs" == *,* ]]; then emit WARN "node architecture" "mixed ($archs): images must be multi-arch or pods need a nodeSelector"
else emit PASS "node architecture" "$archs (images must be built for this architecture)"; fi

# 4. Capacity: allocatable minus what is already REQUESTED by running pods, which is what the scheduler sees.
alloc_cpu="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.cpu}{"\n"}{end}' | cpu_to_m | awk '{s+=$1} END {print s+0}')"
alloc_mem="$(kubectl get nodes -o jsonpath='{range .items[*]}{.status.allocatable.memory}{"\n"}{end}' | mem_to_mi | awk '{s+=$1} END {printf "%d", s}')"
req_cpu="$(kubectl get pods -A --field-selector=status.phase!=Succeeded,status.phase!=Failed -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.resources.requests.cpu}{"\n"}{end}{end}' | cpu_to_m | awk '{s+=$1} END {print s+0}')"
req_mem="$(kubectl get pods -A --field-selector=status.phase!=Succeeded,status.phase!=Failed -o jsonpath='{range .items[*]}{range .spec.containers[*]}{.resources.requests.memory}{"\n"}{end}{end}' | mem_to_mi | awk '{s+=$1} END {printf "%d", s}')"
free_cpu=$((alloc_cpu - req_cpu)); free_mem=$((alloc_mem - req_mem))
detail="free to schedule ${free_cpu}m CPU / ${free_mem}Mi memory (allocatable ${alloc_cpu}m / ${alloc_mem}Mi minus requested ${req_cpu}m / ${req_mem}Mi) vs chart requests ${NEED_CPU_M}m / ${NEED_MEM_MI}Mi"
if   [[ "$free_cpu" -lt "$NEED_CPU_M" || "$free_mem" -lt "$NEED_MEM_MI" ]]; then emit FAIL "capacity" "$detail"
elif [[ "$free_cpu" -lt $((NEED_CPU_M*3)) || "$free_mem" -lt $((NEED_MEM_MI*3)) ]]; then emit WARN "capacity" "$detail (less than 3x headroom)"
else emit PASS "capacity" "$detail"; fi
if kubectl get nodes -o jsonpath='{.items[0].spec.providerID}' 2>/dev/null | grep -q '^kind://'; then
  echo "      note: kind nodes are containers sharing one host; the numbers above are the host's, not independent machines." | tee -a "$REPORT"
fi

# 5. Default StorageClass (the chart is stateless, so this is informational).
sc="$(kubectl get storageclass -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}' 2>/dev/null)"
if [[ -n "$sc" ]]; then emit PASS "default storageclass" "$sc"
else emit WARN "default storageclass" "none set (not needed by this chart; needed if you add persistence)"; fi

# 6. Ingress controller (only needed for ingress.enabled=true).
ic="$(kubectl get ingressclass --no-headers 2>/dev/null | awk '{print $1}' | paste -sd, -)"
if [[ -n "$ic" ]]; then emit PASS "ingress controller" "IngressClass: $ic"
else emit WARN "ingress controller" "no IngressClass found (use port-forward or install a controller)"; fi

# 7. Cluster DNS: found by label (CoreDNS pods are labelled k8s-app=kube-dns whatever the Deployment is called).
dns_ready="$(kubectl -n kube-system get pods -l k8s-app=kube-dns -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | grep -c true)"
dns_total="$(kubectl -n kube-system get pods -l k8s-app=kube-dns --no-headers 2>/dev/null | wc -l | tr -d ' ')"
if [[ "$dns_total" -gt 0 && "$dns_ready" -eq "$dns_total" ]]; then emit PASS "cluster dns" "$dns_ready/$dns_total kube-dns pods ready (label k8s-app=kube-dns)"
else emit FAIL "cluster dns" "ready $dns_ready/$dns_total (kubectl -n kube-system get pods -l k8s-app=kube-dns); if DNS runs elsewhere set networkPolicy.dns.* in the values"; fi

# 8. Pod Security Admission: ask the API server. The chart (default values) is rendered and sent as a server-side dry
#    run into the target namespace, so the namespace's own Pod Security labels are applied to the real pod templates and
#    to the helm test pod. Deployments are only warned about (enforcement happens when their pods are created), so
#    "would violate PodSecurity" warnings count as a failure just like a rejection does.
if ! kubectl get ns "$NS" >/dev/null 2>&1; then
  emit WARN "pod security (ns $NS)" "namespace does not exist yet: create it with its Pod Security labels and run this check again"
else
  psa="$(kubectl get ns "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}' 2>/dev/null)"
  psa_out="$(helm template "$RELEASE" "$CHART" -n "$NS" 2>&1 | kubectl apply --server-side --force-conflicts --dry-run=server --field-manager=preflight -n "$NS" -f - 2>&1)"
  if grep -qiE 'violates? PodSecurity|forbidden|denied the request' <<<"$psa_out"; then
    emit FAIL "pod security (ns $NS)" "enforce=${psa:-none}: the chart would not be admitted: $(grep -iE 'violates? PodSecurity|forbidden|denied' <<<"$psa_out" | head -2 | tr '\n' ' ')"
  elif grep -qiE '^error' <<<"$psa_out"; then
    emit WARN "pod security (ns $NS)" "server-side dry run failed for another reason: $(grep -i '^error' <<<"$psa_out" | head -1)"
  else
    emit PASS "pod security (ns $NS)" "enforce=${psa:-none}: server-side dry run of the chart was admitted with no PodSecurity warnings"
  fi
fi

# 9. NetworkPolicy support: identify the CNI. Names alone do not prove enforcement.
pods="$(kubectl -n kube-system get pods --no-headers 2>/dev/null | awk '{print $1}')"
if   grep -qiE 'calico|cilium|antrea|weave' <<<"$pods"; then
  emit PASS "networkpolicy support" "CNI known to enforce NetworkPolicy: $(grep -oiE 'calico|cilium|antrea|weave' <<<"$pods" | head -1) (PROBE_NETPOL=1 proves it)"
elif kubectl version 2>/dev/null | grep -q '+k3s'; then
  emit PASS "networkpolicy support" "k3s: embedded network policy controller (kube-router) enforces it (PROBE_NETPOL=1 proves it)"
elif grep -qi 'kindnet' <<<"$pods"; then
  emit WARN "networkpolicy support" "kindnet: enforcement depends on its version; prove it with PROBE_NETPOL=1 or drills/06-networkpolicy-enforcement.sh"
else
  emit WARN "networkpolicy support" "CNI not recognised; prove enforcement with PROBE_NETPOL=1 or drills/06"
fi

# 9b. Active probe. A server pod serves a file; a client must fetch it BEFORE deny-all (positive control: proves the
#     path works and the images pulled) and must then be BLOCKED after deny-all: a timeout (dropped, e.g. Calico)
#     or "connection refused" (rejected, e.g. k3s/kube-router). Refused counts only because the same server answered
#     the control seconds earlier. Any other failure is "inconclusive", never a pass.
if [[ "${PROBE_NETPOL:-0}" == "1" ]]; then
  img="${PROBE_IMAGE:-busybox:1.36.1}"; pns=np-probe
  kubectl delete ns "$pns" --ignore-not-found --wait=true >/dev/null 2>&1
  kubectl create ns "$pns" >/dev/null 2>&1
  probe() { # probe <pod-name>: run a client pod to completion and print wget's output plus its exit code.
    # (Not `kubectl run -i --rm`: attaching races the container and can lose the output.)
    local n="$1" phase
    kubectl -n "$pns" run "$n" --restart=Never --image="$img" --command -- \
      sh -c "wget -q -T 4 -O- http://$ip:8080/ 2>&1; echo exit=\$?" >/dev/null 2>&1
    for _ in $(seq 1 60); do
      phase="$(kubectl -n "$pns" get pod "$n" -o jsonpath='{.status.phase}' 2>/dev/null)"
      [[ "$phase" == Succeeded || "$phase" == Failed ]] && break
      sleep 1
    done
    kubectl -n "$pns" logs "$n" 2>&1
    kubectl -n "$pns" delete pod "$n" --wait=false >/dev/null 2>&1
  }
  kubectl -n "$pns" run srv --image="$img" --restart=Never --port=8080 --command -- \
    sh -c 'mkdir -p /www && echo probe-ok > /www/index.html && exec httpd -f -p 8080 -h /www' >/dev/null 2>&1
  if ! kubectl -n "$pns" wait --for=condition=Ready pod/srv --timeout=90s >/dev/null 2>&1; then
    emit WARN "networkpolicy enforcement" "probe inconclusive: server pod did not become Ready (image $img pullable?)"
  else
    ip="$(kubectl -n "$pns" get pod srv -o jsonpath='{.status.podIP}')"
    control="$(probe ctl-before)"
    if ! grep -q 'probe-ok' <<<"$control" || ! grep -q 'exit=0' <<<"$control"; then
      emit WARN "networkpolicy enforcement" "probe inconclusive: positive control failed before any policy existed: $(tail -2 <<<"$control" | tr '\n' ' ')"
    else
      kubectl -n "$pns" apply -f - >/dev/null <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: { name: deny-all-ingress }
spec: { podSelector: {}, policyTypes: [Ingress] }
YAML
      verdict=""
      for attempt in 1 2 3 4 5; do   # policy programming is asynchronous: allow a few seconds
        after="$(probe ctl-after-$attempt)"
        if grep -q 'probe-ok' <<<"$after"; then verdict=flowed; sleep 3
        elif grep -qi 'timed out' <<<"$after"; then verdict=timeout; break
        elif grep -qi 'refused' <<<"$after"; then verdict=refused; break
        else verdict="other: $(tail -2 <<<"$after" | tr '\n' ' ')"; break; fi
      done
      case "$verdict" in
        timeout) emit PASS "networkpolicy enforcement" "active probe: fetch worked before deny-all (control) and TIMED OUT after it (dropped)" ;;
        refused) emit PASS "networkpolicy enforcement" "active probe: fetch worked before deny-all (control) and was REFUSED after it (rejected)" ;;
        flowed)  emit FAIL "networkpolicy enforcement" "active probe: traffic still flowed after deny-all (policies are NOT enforced)" ;;
        *)       emit WARN "networkpolicy enforcement" "probe inconclusive after deny-all: $verdict" ;;
      esac
    fi
  fi
  kubectl delete ns "$pns" --wait=false >/dev/null 2>&1
fi

# 10. Image registry reachable from where this script runs.
code="$(curl -s -o "$DEVNULL" -m 6 -w '%{http_code}' "$REGISTRY_URL" || true)"
if [[ "$code" != "000" && -n "$code" ]]; then emit PASS "registry reachable" "$REGISTRY_URL -> HTTP $code (401 is normal for registries)"
else emit WARN "registry reachable" "$REGISTRY_URL unreachable from this host; use the air-gapped bundle (docs/DEPLOYMENT_GUIDE.md)"; fi

# 11. Egress to the upstream LLM API. Any HTTP status proves DNS + routing + TLS work.
code="$(curl -s -o "$DEVNULL" -m 6 -w '%{http_code}' "$UPSTREAM_URL" || true)"
if [[ "$code" != "000" && -n "$code" ]]; then emit PASS "egress to upstream llm" "$UPSTREAM_URL -> HTTP $code"
elif [[ "${EXTERNAL_LLM:-0}" == "1" ]]; then emit FAIL "egress to upstream llm" "$UPSTREAM_URL unreachable: open the egress path before installing"
else emit WARN "egress to upstream llm" "$UPSTREAM_URL unreachable (fine for mock/air-gapped installs)"; fi
echo "  (the last two checks run from this workstation; confirm from a pod in the cluster before go-live)" | tee -a "$REPORT"

echo "-----------------------------------------------------------------------" | tee -a "$REPORT"
echo "Summary: $PASS PASS, $WARNS WARN, $FAILS FAIL   (report: $REPORT)" | tee -a "$REPORT"
[[ "$FAILS" -eq 0 ]]
