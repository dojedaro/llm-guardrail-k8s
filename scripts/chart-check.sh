#!/usr/bin/env bash
# Static checks for the Helm chart. No cluster needed. Used by CI.
#   helm lint and helm template for every values file, strict duplicate-key YAML check,
#   kubeconform -strict (run from its container image so nothing needs installing),
#   and negative tests: bad values must be REJECTED, and for the stated reason.
set -uo pipefail
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need helm docker
mkdir -p "$REPO_ROOT/reports"
KUBE_VERSION="${KUBE_VERSION:-1.31.0}"
KUBECONFORM_IMAGE="${KUBECONFORM_IMAGE:-ghcr.io/yannh/kubeconform@sha256:0925177fb05b44ce18574076141b5c3d83235e1904d3f952182ac99ddc45762c}" # v0.6.7
C="$CHART"
fails=0
step() { printf '\n--- %s\n' "$*"; }
run()  { "$@" || { echo "FAILED: $*"; fails=$((fails+1)); }; }

# name | helm args (values files and --set) used for lint, template, dup-check and kubeconform
CASES=(
  "default|"
  "airgapped|-f $C/values-airgapped.yaml"
  "external-llm|-f $C/values-external-llm.yaml --set networkPolicy.externalLLM.cidrs={203.0.113.10/32}"
  "ingress+tls+extras|--set ingress.enabled=true --set ingress.tls.enabled=true --set ingress.tls.secretName=t --set gateway.extraEnv[0].name=HTTPS_PROXY --set gateway.extraEnv[0].value=http://p:3128 --set gateway.caBundle.configMapName=ca --set global.imagePullSecrets[0]=regcred --set networkPolicy.allowedIngressCidrs={10.0.0.0/8} --set networkPolicy.dns.extraCidrs={169.254.20.10/32}"
  "k3s-traefik|--set ingress.enabled=true --set ingress.className=traefik --set networkPolicy.allowedNamespaces={kube-system}"
  "scheduling|--set gateway.nodeSelector.pool=ai --set gateway.tolerations[0].key=dedicated --set gateway.tolerations[0].operator=Exists --set gateway.podAnnotations.team=platform --set mockLlm.nodeSelector.pool=ai --set mockLlm.podAnnotations.team=platform"
  "kind-ingress|-f $C/values-kind.yaml"
  "single-replica|--set gateway.replicas=1"
)
for c in "${CASES[@]}"; do
  name="${c%%|*}"; args="${c#*|}"
  step "$name"
  # $args holds several arguments and must word-split.
  # shellcheck disable=SC2086
  run helm lint "$C" $args
  # shellcheck disable=SC2086
  helm template t "$C" $args > "$REPO_ROOT/reports/.render-$name.yaml" || { echo "FAILED: helm template ($name)"; fails=$((fails+1)); continue; }
  run "$PYTHON" "$REPO_ROOT/scripts/yaml_dupcheck.py" < "$REPO_ROOT/reports/.render-$name.yaml"
  docker run --rm -i "$KUBECONFORM_IMAGE" -strict -summary -kubernetes-version "$KUBE_VERSION" -ignore-missing-schemas - \
    < "$REPO_ROOT/reports/.render-$name.yaml" || { echo "FAILED: kubeconform ($name)"; fails=$((fails+1)); }
done

step "PDB is not rendered for a single replica"
if grep -q 'kind: PodDisruptionBudget' "$REPO_ROOT/reports/.render-single-replica.yaml"; then
  echo "FAILED: PDB rendered with replicas=1"; fails=$((fails+1))
else echo "ok"; fi

step "scheduling values reach both Deployments"
if [[ "$(grep -c -E '^ +(nodeSelector:|team: platform)' "$REPO_ROOT/reports/.render-scheduling.yaml")" -eq 4 ]] &&
   grep -q 'key: dedicated' "$REPO_ROOT/reports/.render-scheduling.yaml"; then echo "ok"
else echo "FAILED: nodeSelector, tolerations or podAnnotations missing from the rendered Deployments"; fails=$((fails+1)); fi

step "bad values must be rejected, for the stated reason"
# expect_fail <why> <pattern the error must contain> <command...>
expect_fail() {
  local why="$1" pattern="$2" out; shift 2
  if out="$("$@" 2>&1)"; then echo "FAILED (accepted): $why"; fails=$((fails+1))
  elif grep -qF -- "$pattern" <<<"$out"; then echo "rejected: $why  [$pattern]"
  else echo "FAILED (rejected for another reason): $why. Wanted '$pattern', got: $(head -c 300 <<<"$out")"; fails=$((fails+1)); fi
}
expect_fail "image tag latest"                "/gateway/image/tag"                         helm template t "$C" --set gateway.image.tag=latest
expect_fail "pii.mode=maybe"                  "value must be one of 'redact', 'block'"     helm template t "$C" --set policy.pii.mode=maybe
expect_fail "injection threshold 0"           "/policy/injection/threshold"                helm template t "$C" --set policy.injection.threshold=0
expect_fail "unknown effort"                  "/gateway/upstream/effort"                   helm template t "$C" --set gateway.upstream.effort=extreme
expect_fail "typo gateway.replica"            "additional properties 'replica' not allowed" helm template t "$C" --set gateway.replica=3
expect_fail "typo netwrokPolicy"              "additional properties 'netwrokPolicy' not allowed" helm template t "$C" --set netwrokPolicy.enabled=false
expect_fail "external values without cidrs"   "externalLLM.cidrs"                          helm template t "$C" -f "$C/values-external-llm.yaml"
expect_fail "anthropic without egress allow"  "default-deny blocks every upstream call"    helm template t "$C" --set gateway.upstream.kind=anthropic --set gateway.secret.existingSecret=k
expect_fail "mock kind with mockLlm disabled" "has no upstream"                            helm template t "$C" --set mockLlm.enabled=false
expect_fail "tls enabled without secret"      "ingress.tls.secretName is required"         helm template t "$C" --set ingress.enabled=true --set ingress.tls.enabled=true

echo
if [[ "$fails" -eq 0 ]]; then echo "chart-check: all checks passed"; else echo "chart-check: $fails FAILED"; exit 1; fi
