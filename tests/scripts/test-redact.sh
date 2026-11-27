#!/usr/bin/env bash
# Proves scripts/lib.sh redact() masks credentials and leaves ordinary config alone.
# Fake credentials are assembled from pieces so this file itself contains no key-shaped string.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib.sh"

fails=0
must_hide() {  # must_hide <secret-fragment> <input>
  local out; out="$(printf '%s\n' "$2" | redact)"
  if grep -qF -- "$1" <<<"$out"; then echo "LEAKED: '$1' survived in: $out"; fails=$((fails+1)); else echo "ok   hidden: ${2:0:48}..."; fi
}
must_keep() {  # must_keep <input>  (unchanged by redaction)
  local out; out="$(printf '%s\n' "$1" | redact)"
  if [[ "$out" == "$1" ]]; then echo "ok   kept:   $1"; else echo "OVER-REDACTED: '$1' became '$out'"; fails=$((fails+1)); fi
}

A="sk-ant-""api03-abcdefghijklmnopqrstuvwxyz0123"
B="sk-proj-""Ab3dEf6hIj9kLm2nOp5qRs8tUv1w"
G="ghp_""0123456789abcdefghijklmnopqrstuvwxyz"
P="github_pat_""11ABCDEFG0123456789_abcdefghijklmnop"
X="xoxb-""1234567890-abcdefghij"
K="AKIA""IOSFODNN7EXAMPLE"
J="eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.abcdefghijklmnop"
T="Zm9vYmFyYmF6cXV4"

must_hide "$A" "ANTHROPIC_API_KEY=$A"
must_hide "$B" "log line mentions $B in prose"
must_hide "$G" "token $G"
must_hide "$P" "pat $P"
must_hide "$X" "slack $X"
must_hide "$K" "aws $K"
must_hide "$J" "jwt $J"
must_hide "$T" "Authorization: Bearer $T"
must_hide "$T" "curl -H 'authorization: bearer $T'"
must_hide "hunter2" 'password: hunter2'
must_hide "hunter2" '"password": "hunter2"'
must_hide "hunter2" 'DB_PASSWORD=hunter2'
must_hide "$T" "  api-key: $T"
must_hide "$T" "client_secret = $T"
# env lists as `helm get manifest` / `kubectl get -o yaml|json` print them: the secret is on the line AFTER the name
must_hide "hunter2" "$(printf -- '- name: DB_PASSWORD
  value: hunter2')"
must_hide "hunter2" "$(printf -- '            - name: PLANTED_PASSWORD
              value: hunter2')"
must_hide "hunter2" '{"name":"SOME_API_TOKEN","value":"hunter2"}'
must_hide "MIIEvQIBADANBgkq" "$(printf -- '-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkq\n-----END PRIVATE KEY-----')"

must_keep "$(printf -- '- name: LOG_LEVEL
  value: INFO')"
must_keep "secretName: guardrail-llm-key"
must_keep "  secretKeyRef:"
must_keep "image: llm-guardrail/gateway:0.1.0"
must_keep "NAME    TYPE    DATA   AGE"
must_keep "the task-management-system-configuration page"

[[ "$fails" -eq 0 ]] && echo "redact tests passed" || { echo "$fails redact test(s) failed"; exit 1; }
