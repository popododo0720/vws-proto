# Release tags

Consumers (vws-iam, vws-console-api, vws-deploy) pin a tag of this repo, never a branch or a bare commit. `scripts/check-tag.sh` checks the rules below, and the `tag` workflow runs it on every pushed `v*` tag.

## Version rules

Tags are `vMAJOR.MINOR.PATCH` with no prefix (`v0.9.0`, not `gen/go/v0.9.0`). A new tag is the highest version and sits on a commit of `main` that comes after the previous tag.

| Change since the previous tag | Bump while `v0.x` | Bump from `v1.0.0` |
| --- | --- | --- |
| Any `.proto` change that `buf breaking` accepts: new field, RPC, message, service or enum value | minor | minor |
| A change `buf breaking` rejects: deleted field, RPC or file, changed number or type | minor | major |
| No `.proto` change: docs, scripts, CI, a generator bump | patch | patch |

`buf breaking` runs with the previous tag's `buf.yaml`, so loosening the config in the same range does not hide a breaking change. A bump resets the lower parts to 0. A `v2` or later tag needs the `/vN` suffix on the module path in `go.mod`, the `go_package` options and `gen/go`, because Go cannot fetch it otherwise. A PR that `buf breaking` rejects says so in its body and lists what each consumer must change. A deleted field's number and name go in `reserved`, and `buf breaking` rejects a deletion that reserves only one of them; a number is never reused.

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

## v1.0.0

v1.0.0 is a major release, the first one from `v0.24.0`. It removes what VWS no longer hosts: VWS manages Proxmox and AWS, and Proxmox or AWS is the source of truth for observed state. `buf breaking` against `v0.24.0` fails on purpose (`FILE_NO_DELETE` for 14 files, `FIELD_NO_DELETE` for 2 fields), and that check uses the `v0.24.0` config. The required `buf` check on the PR must still pass, so `buf.yaml` carries a release exception that covers only these deletions: `breaking.ignore` lists `vws/compute`, `vws/storage` and `vws/network` (they no longer exist, so it hides only a re-added package), and `FIELD_NO_DELETE` is replaced by `FIELD_NO_DELETE_UNLESS_NUMBER_RESERVED` and `FIELD_NO_DELETE_UNLESS_NAME_RESERVED`, which is the `reserved` rule below for every later field deletion. Remove the `ignore` block in the first minor after `v1.0.0`. The change is made in one PR whose body says so and lists what each consumer must change.

Removed:

- The `vws.compute.v1`, `vws.storage.v1` (volumes, snapshots, buckets, objects) and `vws.network.v1` packages: every `.proto` file under `vws/compute`, `vws/storage` and `vws/network`, with their generated Go under `gen/go/vws/`. This includes `LookupOperation` from `vws/compute/v1/operation_lookup.proto`. Nothing in `vws.common.v1` or `vws.iam.v1` imported them.
- `vws.common.v1.ObservedState.node` (field 4) and `vws.common.v1.ReconciliationFailure.node` (field 3). The numbers and the name `node` are `reserved`. The server sets `status.observed` and `ReconciliationFailure` from the backend; no node reports them.

Kept: `vws.common.v1` and `vws.iam.v1`. The `ERROR_REASON_INVALID_BUCKET_NAMESPACE` value stays, so its number is not freed. Go needs no `/v2` path for v1, so the module path is unchanged.

Consumers (vws-iam, vws-console-api, vws-deploy): move to `v1.0.0`, stop importing `computev1`, `storagev1` and `networkv1`, and drop uses of `ObservedState.Node` and `ReconciliationFailure.Node`. vws-compute, vws-storage and vws-network stay on `v0.24.0`.

Tag after merge: `scripts/check-tag.sh v1.0.0` expects an annotated `v1.0.0` on a `main` commit after `v0.24.0`, a major bump with minor and patch 0, `buf breaking` failing against `v0.24.0` (allowed for a major from v1 on) and a `.proto` change. This PR creates no tag. There is no `CHANGELOG`; the tag message is the release note.

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
