#!/usr/bin/env bash
# Support bundle: what you would send the product team when something is wrong.
# Collects state, events, logs (including crashed/previous containers), Helm release info.
# Secret VALUES are never fetched, and everything is passed through redact() as a second guard.
#
#   scripts/collect-diagnostics.sh        -> diagnostics-<timestamp>.tar.gz in the repo root
set -uo pipefail   # no -e: one failing collector must not stop the rest
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
need kubectl tar

TS="$(date +%Y%m%d-%H%M%S)"
DIR="$REPO_ROOT/diagnostics-$TS"
mkdir -p "$DIR/pods"

# save <file> <command...> : run a command, redact its output, keep stderr too (errors are evidence).
save() { local f="$1"; shift; { "$@" 2>&1 || echo "(command exited non-zero: $*)"; } | redact > "$DIR/$f"; }

log "collecting from namespace '$NS' into $DIR"
{ date -u +%FT%TZ; kubectl version; kubectl config current-context; } 2>&1 | redact > "$DIR/00-environment.txt"
save 01-nodes.txt            kubectl get nodes -o wide
save 02-nodes-describe.txt   kubectl describe nodes
save 03-workloads.txt        kubectl -n "$NS" get all,cm,ingress,networkpolicy,pdb,hpa -o wide
save 04-events.txt           kubectl -n "$NS" get events --sort-by=.lastTimestamp
save 05-secrets-names.txt    kubectl -n "$NS" get secrets   # names/types only, never values
save 06-networkpolicies.txt  kubectl -n "$NS" get networkpolicy -o yaml
save 07-top.txt              kubectl -n "$NS" top pods      # needs metrics-server; may be empty
save 08-kube-system.txt      kubectl -n kube-system get pods -o wide

if command -v helm >/dev/null 2>&1; then
  save 10-helm-list.txt      helm list -n "$NS" -a
  save 11-helm-history.txt   helm history "$RELEASE" -n "$NS"
  save 12-helm-values.txt    helm get values "$RELEASE" -n "$NS" -a
  save 13-helm-manifest.txt  helm get manifest "$RELEASE" -n "$NS"
fi

for pod in $(kubectl -n "$NS" get pods -o name 2>/dev/null | sed 's#pod/##'); do
  save "pods/$pod.describe.txt"  kubectl -n "$NS" describe pod "$pod"
  save "pods/$pod.log"           kubectl -n "$NS" logs "$pod" --all-containers --tail=500
  # --previous only works if a container has restarted; the error message is useful evidence too.
  save "pods/$pod.previous.log"  kubectl -n "$NS" logs "$pod" --all-containers --previous --tail=500
done

# cd + relative names: Git Bash's tar reads "C:/..." as host:path ("Cannot connect to C") if given an absolute Windows path.
TAR="diagnostics-$TS.tar.gz"
( cd "$REPO_ROOT" && tar -czf "$TAR" "diagnostics-$TS" )
log "support bundle: $REPO_ROOT/$TAR"
echo "Redaction is a safety net, not a guarantee: read the bundle before it leaves your organisation."
