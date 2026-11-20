#!/usr/bin/env bash
# Runs scripts/check-breaking.sh on a copy of the tree with one change each and checks
# the result. BASE is the ref to compare with (default origin/main).
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
base=${BASE:-origin/main}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

run() {
  local want=$1 name=$2 edit=$3 got
  rm -rf "$tmp/t" && mkdir "$tmp/t"
  (cd "$root" && git ls-files -z --cached --others --exclude-standard | xargs -0 cp --parents -t "$tmp/t")
  (cd "$tmp/t" && eval "$edit")
  if "$tmp/t/scripts/check-breaking.sh" "$root/.git#ref=$base" >"$tmp/out" 2>&1; then got=pass; else got=fail; fi
  if [[ $got != "$want" ]]; then
    echo "FAIL $name: want $want, got $got" >&2
    cat "$tmp/out" >&2
    exit 1
  fi
  echo "ok $want $name"
}

run pass "tree as is" true
run fail "reserved field deletion in an allowlisted file" \
  "sed -i 's/^  repeated Condition conditions = 3;/  reserved 3;\n  reserved \"conditions\";/' vws/common/v1/resource.proto"
run fail "node number reserved without the name" \
  "sed -i '/^  reserved \"node\";/d' vws/common/v1/resource.proto"
run fail "reserved field deletion in another file" \
  "sed -i 's/^  map<string, string> labels = 5;/  reserved 5;\n  reserved \"labels\";/' vws/iam/v1/key_pair.proto"
run fail "file deletion outside the allowlist" "rm vws/iam/v1/key_pair.proto"
