# vws-proto

Shared gRPC definitions of the VWS control plane. VWS manages Proxmox and AWS and hosts nothing itself. The desired state is stored in one place, the `spec` of the resources defined here. The server sets the observed state (`status.observed`) from the backend, Proxmox or AWS, which is the source of truth.

The `vws.compute.v1`, `vws.storage.v1` and `vws.network.v1` packages were removed in v1.0.0 (`docs/release.md`).

## Resources

Every resource uses the same envelope: `name`, `uid`, `generation`, `etag`, `labels`, `spec`, `status`, `create_time`, `update_time`, `delete_time`.

| Service | Resource name |
| --- | --- |
| `vws.iam.v1.UserService` | `projects/{project}/users/{user}` |
| `vws.iam.v1.GroupService` | `projects/{project}/groups/{group}` |
| `vws.iam.v1.RoleService` | `projects/{project}/roles/{role}` |
| `vws.iam.v1.PolicyService` | `projects/{project}/policies/{policy}`, `.../versions/{version}` |
| `vws.iam.v1.AccessKeyService` | `projects/{project}/users/{user}/accessKeys/{access_key}` |
| `vws.iam.v1.MfaDeviceService` | `projects/{project}/mfaDevices/{mfa_device}` |
| `vws.iam.v1.AccountService` | No resource. Account-level IAM reads and writes (`docs/iam.md`) |
| `vws.iam.v1.AuthService`, `TokenService` | No resource. Authentication, authorization, STS (`docs/iam.md`) |

IAM names and access key ids use AWS grammar (`docs/validation.md`). Every other id uses the `vws.common.v1.ResourceId` grammar.

## Clients

Terraform and Ansible use the same calls for every resource.

| Action | RPC |
| --- | --- |
| Read | `Get*` |
| List | `List*` |
| Create | `Create*` |
| Reconcile | `Update*`. To create when missing, `allow_missing` |
| Remove | `Delete*`. When already gone, `allow_missing` |
| Check first | `validate_only` |

A key pair's `status.fingerprint_sha256` is lower-case hex the server computes from the public key. `CreateKeyPair` and `GetKeyPair` return the same field.

Mutating RPCs return an operation. The client polls for completion with the same operation name. After completion, if `status.observed.generation` equals `generation` and `status.observed.state` is `READY`, the backend has matched the spec. A delete finishes after the resource is gone.

Sending the same `request_id` with the same body again returns the first operation. A create with the same id and the same desired state succeeds. A different body is `ALREADY_EXISTS`. The detailed rules are in `vws.common.v1.OperationMetadata`.

## Restart

The server stores the spec and the operation before returning the operation name. When the process comes back up, it continues unfinished operations from that record. The server writes what it observes from the backend into `status.observed`. An observation for an older generation is ignored.

## Errors

Errors are `google.rpc.Status`. `google.rpc.ErrorInfo.domain` is `vws.dev`, and `reason` is the `vws.common.v1.ErrorReason` name without `ERROR_REASON_`. Extra detail for backend failures is `ReconciliationFailure`.

## Dependency order

When creating, referenced resources come first. When deleting, the reverse.

1. Users, groups, policies, roles
2. Access keys, MFA devices, instance profiles

While a user has access keys, MFA devices or group memberships, or a policy is still attached, deleting the parent is `DEPENDENCY_MISSING`. Each service's comments list its refusal conditions.

## Go module

The repo root is the Go module `github.com/popododo0720/vws-proto`. The generated code is committed in `gen/go`. Tags have no prefix, like `v1.0.0`, not `gen/go/v1.0.0`. The version rules and the tagging procedure are in `docs/release.md`.

```sh
go get github.com/popododo0720/vws-proto@v1.0.0
```

This repo is private. Add `github.com/popododo0720/*` to `GOPRIVATE`; if it already has a value, join them with a comma. Replacing it wholesale with `go env -w` loses the existing value. This setting skips the module proxy and the checksum DB. git must be able to authenticate to GitHub. Go 1.26 or later is required. `go get` raises the calling module's `go` line to `1.26.0`.

In another repo's GitHub Actions, the default `GITHUB_TOKEN` reads only that repo. That job sets `GOPRIVATE=github.com/popododo0720/*` and fetches `https://github.com/popododo0720/vws-proto` with a credential that can read this repo's `contents`.

| proto package | Go import path | Go package |
| --- | --- | --- |
| `vws.common.v1` | `github.com/popododo0720/vws-proto/gen/go/vws/common/v1` | `commonv1` |

The `google.longrunning.Operation` that mutating RPCs return is `Operation` from `cloud.google.com/go/longrunning/autogen/longrunningpb`.

## Generation

The generated output goes in the same commit as the proto change. `gen/go` is never edited by hand; `buf generate` deletes and recreates that directory.

```sh
buf generate
go mod tidy
```

`option go_package` is `github.com/popododo0720/vws-proto/gen/go/<proto directory>;<domain><version>`. The package name of `vws/iam/v1` is `iamv1`.

## Checks

```sh
buf lint
buf build
scripts/check-generated-go.sh
go build ./...
```

`scripts/check-generated-go.sh` checks that `go_package` matches the file path, and that `gen`, `go.mod` and `go.sum` have no diff after `buf generate` and `go mod tidy`. It does not change the index. Untracked `gen` files also fail.

GitHub Actions runs `buf lint` and `buf build` on pull requests and pushes to `main`. It runs `buf breaking` only when the base has proto. The `go` job runs the same script and `go build ./...`.
