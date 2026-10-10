#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

status=0
while IFS= read -r f; do
  dir=$(dirname "$f")
  pkg=$(basename "$(dirname "$dir")")$(basename "$dir")
  want="option go_package = \"github.com/popododo0720/vws-proto/gen/go/${dir};${pkg}\";"
  if ! grep -qxF "$want" "$f"; then
    echo "go_package mismatch in $f" >&2
    echo "want $want" >&2
    status=1
  fi
done < <(git ls-files '*.proto')
test "$status" -eq 0

buf generate
go mod tidy
git diff --exit-code -- gen go.mod go.sum

untracked=$(git ls-files --others --exclude-standard -- gen)
if [[ -n "$untracked" ]]; then
  echo "untracked generated files:" >&2
  printf '%s\n' "$untracked" >&2
  exit 1
fi
