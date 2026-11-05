#!/usr/bin/env bash
set -euo pipefail
script=$(cd "$(dirname "$0")" && pwd)/check-tag.sh
repo=$(mktemp -d)
trap 'rm -rf "$repo"' EXIT
cd "$repo"
git init -q -b main
git config user.email t@example.com
git config user.name t
git config tag.gpgSign false
printf 'version: v2\n' >buf.yaml
mkdir -p a/v1

commit() {
  printf 'syntax = "proto3";\npackage a.v1;\n%s\n' "$1" >a/v1/a.proto
  git add -A
  git commit -qm "$2" --allow-empty
}
expect() {
  local want=$1 tag=$2 out
  if out=$("$script" "$tag" main 2>&1); then got=pass; else got=fail; fi
  if [[ $got != "$want" ]]; then
    echo "FAIL $tag: want $want, got $got" >&2
    echo "$out" >&2
    exit 1
  fi
  echo "ok $want $tag: $(tail -n1 <<<"$out")"
}

commit 'message M { string a = 1; }' base
git tag -a v0.1.0 -m v0.1.0
expect pass v0.1.0

commit 'message M { string a = 1; string b = 2; }' add
git tag v0.2.0
expect fail v0.2.0
git tag -d v0.2.0 >/dev/null
git tag -a v0.1.1 -m v0.1.1
expect fail v0.1.1
git tag -d v0.1.1 >/dev/null
git tag -a 0.2.0 -m x
expect fail 0.2.0
git tag -d 0.2.0 >/dev/null
git tag -a v0.2.1 -m x
expect fail v0.2.1
git tag -d v0.2.1 >/dev/null
git tag -a v0.2.0 -m v0.2.0
expect pass v0.2.0
git tag -a v0.3.0 -m x
expect fail v0.3.0
git tag -d v0.3.0 >/dev/null

git commit -qm docs --allow-empty
git tag -a v0.2.1 -m v0.2.1
expect pass v0.2.1

commit 'message M { string a = 1; int64 b = 2; }' breaking
git tag -a v0.3.0 -m v0.3.0
expect pass v0.3.0
git commit -qm docs2 --allow-empty
git tag -a v0.2.2 -m x
expect fail v0.2.2
git tag -d v0.2.2 >/dev/null
git tag -a v1.0.0 -m v1.0.0
expect pass v1.0.0

commit 'message M { string a = 1; }' breaking-again
git tag -a v1.1.0 -m v1.1.0
expect fail v1.1.0
git tag -d v1.1.0 >/dev/null
git tag -a v2.1.0 -m x
expect fail v2.1.0
git tag -d v2.1.0 >/dev/null
git tag -a v2.0.0 -m v2.0.0
expect pass v2.0.0

commit 'message M {' syntax-error
git tag -a v2.1.0 -m x
expect fail v2.1.0
git tag -d v2.1.0 >/dev/null

commit 'message M { string a = 1; string c = 3; }' add-after-error
git tag -a v2.1.0 -m x
mkdir fakebuf
printf '#!/bin/sh\n[ "$1" = build ] && exit 0\nexit 127\n' >fakebuf/buf
chmod +x fakebuf/buf
PATH=$PWD/fakebuf:$PATH expect fail v2.1.0
rm -r fakebuf
git tag -d v2.1.0 >/dev/null

git checkout -qb side
git commit -qm side --allow-empty
git tag -a v2.0.1 -m x
expect fail v2.0.1
