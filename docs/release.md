# Release tags

Consumers (vws-compute, vws-storage, vws-network, vws-deploy, vws-iam) pin a tag of this repo, never a branch or a bare commit. `scripts/check-tag.sh` checks the rules below, and the `tag` workflow runs it on every pushed `v*` tag.

## Version rules

Tags are `vMAJOR.MINOR.PATCH` with no prefix (`v0.9.0`, not `gen/go/v0.9.0`). A new tag is the highest version and sits on a commit of `main` that comes after the previous tag.

| Change since the previous tag | Bump while `v0.x` | Bump from `v1.0.0` |
| --- | --- | --- |
| Any `.proto` change that `buf breaking` accepts: new field, RPC, message, service or enum value | minor | minor |
| A change `buf breaking` rejects: deleted field, RPC or file, changed number or type | minor | major |
| No `.proto` change: docs, scripts, CI, a generator bump | patch | patch |

`buf breaking` runs with the previous tag's `buf.yaml`, so loosening the config in the same range does not hide a breaking change. A bump resets the lower parts to 0. A `v2` or later tag needs the `/vN` suffix on the module path in `go.mod`, the `go_package` options and `gen/go`, because Go cannot fetch it otherwise. A PR that `buf breaking` rejects says so in its body and lists what each consumer must change. A deleted field's number and name go in `reserved`; a number is never reused.

## Who tags

The one who makes the merge decision tags: the orchestrator or a person. The author bot of a change does not tag it (insider-risk guardrails 1 and 5). Tag only a merged `main` commit whose CI checks all succeeded:

```sh
git fetch origin main --tags
gh api repos/popododo0720/vws-proto/commits/<commit>/check-runs --jq '.check_runs[] | [.name, .conclusion] | @tsv'
git tag -a vX.Y.Z <commit> -F notes.txt
scripts/check-tag.sh vX.Y.Z
git push origin vX.Y.Z
```

When `scripts/check-tag.sh` fails, delete the local tag with `git tag -d vX.Y.Z` and fix it before you push. A pushed tag is never moved or deleted. A wrong pushed tag is fixed by the next tag and recorded in an `incident` issue. `v0.3.0` to `v0.7.0` are lightweight tags from before this procedure; they stay as they are.

## Release notes

The annotated tag message is the release note. It holds:

- the previous tag and whether `buf breaking` fails against it;
- the PRs in the range, with the fields, RPCs and enum values they added, changed or removed;
- for each consumer, what it must do, or `nothing`.

`git log --oneline <previous>..vX.Y.Z` lists the PRs and `buf breaking --against .git#tag=<previous>` gives the breaking result.

## Consumers

A consumer requires the tag as a Go module (`go get github.com/popododo0720/vws-proto@vX.Y.Z`, setup in `README.md`). `go.mod` and `go.sum` record the version and its checksum, so this repo has no `VERSION` file.

A consumer that still vendors `third_party/vws-proto` with a `replace` replaces the whole directory with the tag's tree and never edits it by hand:

```sh
rm -rf third_party/vws-proto && mkdir -p third_party/vws-proto
git -C <vws-proto clone> archive vX.Y.Z | tar -x -C third_party/vws-proto
go mod tidy && go build ./... && go test ./...
```

It records the tag and commit in its README and moves to `require` with no `replace` in its next release.

After a tag that a consumer must act on, the tagger opens an issue in that consumer's repo with the tag, the commit and the release note. The consumer's PR body names the tag, the commit and the build and test commands it ran.

## Compute client fingerprints (next minor release)

Ship the additive compute `client_fingerprint` request fields and
`LookupOperationResponse.request_fingerprint` in v0.23.0. This is not a breaking wire change.

The lookup uses the same string field 2 and name as the network lookup in #151.
`vws-compute` must validate the 256-byte bound, persist the supplied value with
the operation atomically, compare it on replay, and return it from lookup.
`vws-console-api` must send its canonical parameter fingerprint and compare the
lookup value before treating a retry as the same request. Neither behavior is
implemented by generated stubs alone.

`vws-network` uses the parallel lookup contract from #151. `vws-storage` and
`vws-deploy` need no API or deployment change for these additive fields.
Consumers can keep their existing release pins until their implementations are ready.
