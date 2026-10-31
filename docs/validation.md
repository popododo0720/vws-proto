# Input validation rules

This document gathers in one place the input rules already written in the proto comments. It creates no new rules. This repo does not use validation annotations (protovalidate or similar) on proto fields, so **the rules are a contract, and each server enforces them.** Whether a server really checks these rules cannot be confirmed in this repo (needs checking, in each server repo).

A failed rule returns the status shape and `ErrorInfo.reason` in the [gRPC error contract](errors.md).

| Input | Rule | Source |
| --- | --- | --- |
| Resource id (except Object), project, region, zone | `[a-z]([a-z0-9-]{0,61}[a-z0-9])?`, length 1-63 | `vws/common/v1/resource.proto` `ResourceId` |
| Label key | `[a-z][a-z0-9_-]{0,62}` | the envelope comment in the same file |
| Label value | UTF-8, 0-63 bytes, no ASCII control characters | the same file |
| Annotation key and value (Instance, Volume, Vpc, Subnet) | Key 1-128 and value 0-256 characters of UTF-8 with no control characters, counted in Unicode characters, not bytes. At most 50 user entries. A key beginning with `aws:` is reserved: it does not count toward the 50, and a user create or update that sets or changes one is `INVALID_ARGUMENT / INVALID_SPEC`. Servers accept at least 64 KiB per resource. Stored and returned verbatim, not filterable, no generation change; an identical write is a no-op. EC2 accepts any character in a tag, so this rule is deliberately stricter on control characters; the envelope comment gives the reason. A malformed key or value is `INVALID_ARGUMENT / INVALID_SPEC` with the EC2 `InvalidParameterValue` sentence, for example `Value (<value>) for parameter tagValue is invalid.` | the envelope comment in `vws/common/v1/resource.proto` |
| Annotation write | `CreateTags` merges: a key in the request overwrites the value of the same key, a key repeated within one request keeps the last value, and keys the request does not name stay. The 50-entry limit applies to the merged user entries. UpdateMask path `annotations` replaces the user entries but keeps every existing server-set `aws:` key and its value, so a write that omits one leaves it in place; sending a stored `aws:` key with its stored value unchanged is accepted | the same file |
| Object key | 1-1024 bytes after decoding, not `.` or `..`, does not start or end with `/`, no `//`, no ASCII control characters. RFC 3986 percent-encoding in paths (`/` is `%2F`) | `vws/storage/v1/object.proto` `Object` |
| Volume `type` | One of the EBS types `GP2`, `GP3`, `IO1`, `IO2`, `ST1`, `SC1`, `STANDARD` (EC2 `VolumeType`). `UNSPECIFIED` is invalid. `SSD` is deprecated: clients do not send it, and a stored `SSD` volume reads as `GP2` unless the admin maps it otherwise (vws-storage#123). Immutable | `vws/storage/v1/volume.proto` `VolumeType` |
| Volume `iops` and `throughput_mibps` | As in EC2 CreateVolume. GP3: `iops` 3000-80000 (0 uses 3000) and `throughput_mibps` 125-2000 (0 uses 125). IO1: `iops` 100-64000, required. IO2: `iops` 100-256000, required. Every other type, and `throughput_mibps` on every type but GP3: must be 0 | `vws/storage/v1/volume.proto` `VolumeSpec` |
| Instance `user_data` and `user_data_raw` | Each at most 32768 bytes. `user_data` is a proto3 string and must be valid UTF-8; `user_data_raw` carries any bytes, including non-UTF-8 EC2 UserData, and is passed to the guest unchanged. Both set is `INVALID_ARGUMENT / INVALID_SPEC` | `vws/compute/v1/instance.proto` `InstanceSpec` |
| Volume attachment `delete_on_termination` | Optional bool. Unset means true for the `boot = true` attachment and false for every other attachment. Any value is valid; servers do not reject it | `vws/compute/v1/instance.proto` `VolumeAttachment` |
| IAM name (`IamName`): user, group, role, MFA device and inline policy names | `[A-Za-z0-9+=,.@_-]`. Users, roles and MFA devices 1-64 characters. Groups, managed policies and inline policies 1-128 characters (AWS CreateGroup GroupName, CreatePolicy and Put{User,Group,Role}Policy PolicyName). Unique within a project, ignoring case. An exception to `ResourceId` for AWS compatibility | `vws/iam/v1/*.proto` |
| Access key id | `AKIA` (long-term) or `ASIA` (temporary) + 16 upper-case letters and digits | `vws/iam/v1/access_key.proto`, `auth.proto` |
| `expected_user_path` | AIP-122 user resource name `projects/{project}/users/{user}`. When set and different from the access key's parent user, `FAILED_PRECONDITION` and no state change | `vws/iam/v1/access_key.proto` `UpdateAccessKeyRequest`, `DeleteAccessKeyRequest` |
| `expected_user_arn` | IAM user ARN `arn:vws:iam::{project}:user{path}{user}`. When set and different from the parent user's current ARN, `FAILED_PRECONDITION` and no state change. Omitted means no check. The ARN contains the IAM path, so this catches a path move by `UpdateUser` | `vws/iam/v1/access_key.proto` `UpdateAccessKeyRequest`, `DeleteAccessKeyRequest` |
| IAM `path` | Starts and ends with `/`, 1-512 characters | the same files |
| Policy document | AWS JSON, `Version` `2012-10-17`. At most 6144 characters excluding whitespace. Unparseable, or a condition outside `docs/iam.md`, is `INVALID_ARGUMENT / INVALID_SPEC` | `policy.proto` |
| IAM tag key | 1-128 characters of `[\p{L}\p{Z}\p{N}_.:/=+\-@]`, not beginning with `aws:`. Case sensitive. At most 50 tags per policy or virtual MFA device. `INVALID_ARGUMENT / INVALID_SPEC` when invalid, `RESOURCE_EXHAUSTED / QUOTA_EXCEEDED` past 50 | `policy.proto` `Tag`, `mfa_device.proto` `TagMFADevice` |
| IAM tag value | 0-256 characters of the same alphabet, not beginning with `aws:` | `policy.proto` `Tag`, `mfa_device.proto` `TagMFADevice` |
| Password | 8-128 characters. Stored only as an argon2id hash. Never in operation records or logs | `user.proto` |
| `OUTPUT_ONLY` fields | Ignored on input by the AIP-203 convention. The comments in this repo do not state the server behaviour (needs checking). `status` is written only by servers and nodes | `google.api.field_behavior` |
| `request_id` | The same id with the same fingerprint returns the original operation; a different fingerprint is `ABORTED / IDEMPOTENCY_CONFLICT`. Remembered for 24 hours | `vws/common/v1/operation.proto` |
| `LookupOperation` `request_id` and `parent` | `request_id` is a UUID4 and required; `parent` is `projects/{project}`. Unset or malformed is `INVALID_ARGUMENT / INVALID_SPEC`. A `parent` other than the caller's project, or a `request_id` older than 24 hours, is `NOT_FOUND`, never `PERMISSION_DENIED` | `vws/compute/v1/operation_lookup.proto` |
| `generation` in status reports | A report lower than the stored value is ignored | `ObservedState` |
| `etag` | When set, it must equal the stored etag; otherwise `ETAG_MISMATCH` | `operation.proto` |

## Malicious and boundary input test baseline

The minimum inputs server repos put in their tests:

- Ids of length 0, 63 and 64. Ids with upper case, underscores, or leading or trailing hyphens.
- Objects whose key is `.`, `..`, the empty string, 1025 bytes, `a//b`, `/a`, or has control characters.
- A label with a 64-byte value, a label with a 64-character key.
- Annotations with a 128-character key and a 256-character value of multibyte characters (for example `é` or `漢`), which must be accepted because lengths are counted in Unicode characters, not bytes.
- Annotations with a 129-character key, a 257-character value, an empty key, a control character, and 51 user entries. The control-character case returns the `InvalidParameterValue` sentence above.
- A user create with an `aws:` key must be rejected, and 50 user entries plus server-set `aws:` entries must be accepted.
- An annotations UpdateMask write that omits a server-set `aws:` key leaves the key and its value in place, and one that sends that key with its stored value is accepted.
- Create and update requests with an `OUTPUT_ONLY` field (for example `claim_name`) filled in.
- A status report with a lower `generation`, an update with a wrong `etag`, a different body for the same `request_id`.
- IAM: a 65-character name, duplicate names differing only in case, an invalid JSON policy, an unsupported condition operator, a third access key, reuse of the same TOTP code, an expired session token and temporary key.

## Schema change rules

- Field numbers are never reused. Removing or changing one fails `buf breaking` (FILE), and CI blocks it on the PR. Only when needed, write the narrowest exception in the PR body with its reason.
- A PR that changes proto states in its body whether it is breaking and its downstream impact (PR template).
