#!/usr/bin/env bash
# Static checks for the Helm chart. No cluster needed. Used by `make chart-lint` and CI.
#   helm lint and helm template for every values file, strict duplicate-key YAML check,
#   kubeconform -strict (run from its container image so nothing needs installing),
#   and negative tests: bad values must be REJECTED.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need helm docker
mkdir -p "$REPO_ROOT/reports"
PYBIN="${PYBIN:-python}"
KUBE_VERSION="${KUBE_VERSION:-1.31.0}"
KUBECONFORM_IMAGE="${KUBECONFORM_IMAGE:-ghcr.io/yannh/kubeconform:v0.6.7}"
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
  "kind-ingress|-f $C/values-kind.yaml"
  "single-replica|--set gateway.replicas=1"
)
for c in "${CASES[@]}"; do
  name="${c%%|*}"; args="${c#*|}"
  step "$name"
  # shellcheck disable=SC2086
  run helm lint "$C" $args
  # shellcheck disable=SC2086
  helm template t "$C" $args > "$REPO_ROOT/reports/.render-$name.yaml" || { echo "FAILED: helm template ($name)"; fails=$((fails+1)); continue; }
  run "$PYBIN" "$REPO_ROOT/scripts/yaml_dupcheck.py" < "$REPO_ROOT/reports/.render-$name.yaml"
  docker run --rm -i "$KUBECONFORM_IMAGE" -strict -summary -kubernetes-version "$KUBE_VERSION" -ignore-missing-schemas - \
    < "$REPO_ROOT/reports/.render-$name.yaml" || { echo "FAILED: kubeconform ($name)"; fails=$((fails+1)); }
done

step "PDB is not rendered for a single replica"
grep -q 'kind: PodDisruptionBudget' "$REPO_ROOT/reports/.render-single-replica.yaml" && { echo "FAILED: PDB rendered with replicas=1"; fails=$((fails+1)); } || echo "ok"

step "bad values must be rejected"
expect_fail() {
  local why="$1"; shift
  if "$@" >/dev/null 2>&1; then echo "FAILED (accepted): $why"; fails=$((fails+1)); else echo "rejected: $why"; fi
}
expect_fail "image tag latest"                helm template t "$C" --set gateway.image.tag=latest
expect_fail "pii.mode=maybe"                  helm template t "$C" --set policy.pii.mode=maybe
expect_fail "typo gateway.replica"            helm template t "$C" --set gateway.replica=3
expect_fail "typo netwrokPolicy"              helm template t "$C" --set netwrokPolicy.enabled=false
expect_fail "external values without cidrs"   helm template t "$C" -f "$C/values-external-llm.yaml"
expect_fail "anthropic without egress allow"  helm template t "$C" --set gateway.upstream.kind=anthropic --set gateway.secret.existingSecret=k
expect_fail "mock kind with mockLlm disabled" helm template t "$C" --set mockLlm.enabled=false
expect_fail "tls enabled without secret"      helm template t "$C" --set ingress.enabled=true --set ingress.tls.enabled=true

echo
[[ "$fails" -eq 0 ]] && echo "chart-check: all checks passed" || { echo "chart-check: $fails FAILED"; exit 1; }
