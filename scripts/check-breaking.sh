#!/usr/bin/env bash
# Usage: scripts/check-breaking.sh AGAINST
# Runs `buf breaking` with the buf.yaml FILE set against AGAINST (a buf input such as
# .git#branch=origin/main). Fails on every finding except the exact lines in
# scripts/breaking-allow-v1.0.0.txt, the one-time v1.0.0 deletions. An allowed field
# deletion must also keep its number and name reserved.
set -euo pipefail
against=${1:?usage: check-breaking.sh AGAINST}
root=$(cd "$(dirname "$0")/.." && pwd)
allow=$root/scripts/breaking-allow-v1.0.0.txt
cd "$root"

out=$(buf breaking --against "$against" --error-format=json) && exit 0
[[ -n $out ]] || { echo "buf breaking failed without findings" >&2; exit 1; }

reserved='{"version":"v2","breaking":{"use":["FIELD_NO_DELETE_UNLESS_NUMBER_RESERVED","FIELD_NO_DELETE_UNLESS_NAME_RESERVED"]}}'
buf breaking --against "$against" --config "$reserved" >&2 || { echo "a deleted field is not reserved" >&2; exit 1; }

python3 -I - "$allow" "$out" <<'PY'
import json, sys
allow = set()
try:
    for l in open(sys.argv[1]):
        if l.strip() and not l.startswith("#"):
            allow.add(l.rstrip("\n"))
except FileNotFoundError:
    pass
bad = []
for l in sys.argv[2].splitlines():
    d = json.loads(l)
    key = f'{d["type"]}|{d.get("path", "")}|{d["message"]}'
    if key not in allow:
        bad.append(key)
for b in bad:
    print("breaking: " + b, file=sys.stderr)
if bad:
    sys.exit(1)
print("buf breaking: only the v1.0.0 allowlisted deletions")
PY
