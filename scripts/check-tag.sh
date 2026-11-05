#!/usr/bin/env bash
# Usage: scripts/check-tag.sh <tag> [main-ref]
# Checks a release tag against docs/release.md before it is pushed.
set -euo pipefail

tag=${1:?usage: check-tag.sh <tag> [main-ref]}
main=${2:-origin/main}
semver='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

fail() {
  echo "check-tag: $tag: $*" >&2
  exit 1
}

[[ $tag =~ $semver ]] || fail "name is not vMAJOR.MINOR.PATCH"
major=${BASH_REMATCH[1]} minor=${BASH_REMATCH[2]} patch=${BASH_REMATCH[3]}

[[ $(git cat-file -t "refs/tags/$tag" 2>/dev/null) == tag ]] ||
  fail "not an annotated tag (use git tag -a)"
commit=$(git rev-parse "refs/tags/$tag^{commit}")
git merge-base --is-ancestor "$commit" "$main" || fail "commit $commit is not on $main"

tags=$(git tag -l 'v*' | grep -E "$semver" | sort -V)
[[ $(tail -n1 <<<"$tags") == "$tag" ]] || fail "$(tail -n1 <<<"$tags") sorts above it; a new tag is the highest version"
prev=$(tail -n2 <<<"$tags" | head -n1 | grep -vxF "$tag" || true)
if [[ -z $prev ]]; then
  echo "check-tag: $tag: first release tag, ok"
  exit 0
fi
[[ $prev =~ $semver ]]
pmajor=${BASH_REMATCH[1]} pminor=${BASH_REMATCH[2]}

git merge-base --is-ancestor "refs/tags/$prev^{commit}" "$commit" ||
  fail "previous tag $prev is not an ancestor of $commit"
if [[ $(git rev-list --count "refs/tags/$prev^{commit}..$commit") -eq 0 ]]; then
  fail "no commits since $prev"
fi

if [[ $major != "$pmajor" ]]; then
  level=major
elif [[ $minor != "$pminor" ]]; then
  level=minor
else
  level=patch
fi
[[ $level == major && $minor$patch != 00 ]] && fail "a major bump resets minor and patch to 0"
[[ $level == minor && $patch != 0 ]] && fail "a minor bump resets patch to 0"

breaking=no
if ! buf breaking ".git#tag=$tag" --against ".git#tag=$prev" >&2; then
  breaking=yes
fi
proto=no
if ! git diff --quiet "refs/tags/$prev^{commit}" "$commit" -- '*.proto'; then
  proto=yes
fi

if [[ $breaking == yes && $major -ge 1 && $level != major ]]; then
  fail "buf breaking fails against $prev; from v1 a breaking change needs a major bump"
fi
if [[ $proto == yes && $level == patch ]]; then
  fail ".proto files changed since $prev; a proto change needs at least a minor bump"
fi

echo "check-tag: $tag: ok (previous $prev, $level bump, proto changed: $proto, buf breaking fails: $breaking)"
