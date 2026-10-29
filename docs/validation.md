# Input validation rules

This document gathers in one place the input rules already written in the proto comments. It creates no new rules. This repo does not use validation annotations (protovalidate or similar) on proto fields, so **the rules are a contract, and each server enforces them.** Whether a server really checks these rules cannot be confirmed in this repo (needs checking, in each server repo).

| Input | Rule | Source |
| --- | --- | --- |
| Resource id (except Object), project, region, zone | `[a-z]([a-z0-9-]{0,61}[a-z0-9])?`, length 1-63 | `vws/common/v1/resource.proto` `ResourceId` |
| Label key | `[a-z][a-z0-9_-]{0,62}` | the envelope comment in the same file |
| Label value | UTF-8, 0-63 bytes, no ASCII control characters | the same file |
| Object key | 1-1024 bytes after decoding, not `.` or `..`, does not start or end with `/`, no `//`, no ASCII control characters. RFC 3986 percent-encoding in paths (`/` is `%2F`) | `vws/storage/v1/object.proto` `Object` |
| Volume `type` | One of the EBS types `GP2`, `GP3`, `IO1`, `IO2`, `ST1`, `SC1`, `STANDARD` (EC2 `VolumeType`). `UNSPECIFIED` is invalid. `SSD` is deprecated: clients do not send it, and a stored `SSD` volume reads as `GP2` unless the admin maps it otherwise (vws-storage#123). Immutable | `vws/storage/v1/volume.proto` `VolumeType` |
| Volume `iops` and `throughput_mibps` | As in EC2 CreateVolume. GP3: `iops` 3000-80000 (0 uses 3000) and `throughput_mibps` 125-2000 (0 uses 125). IO1: `iops` 100-64000, required. IO2: `iops` 100-256000, required. Every other type, and `throughput_mibps` on every type but GP3: must be 0 | `vws/storage/v1/volume.proto` `VolumeSpec` |
| IAM name (`IamName`): user, group, role, MFA device and inline policy names | `[A-Za-z0-9+=,.@_-]`, 1-64 characters (managed policies 1-128). Unique within a project, ignoring case. An exception to `ResourceId` for AWS compatibility | `vws/iam/v1/*.proto` |
| Access key id | `AKIA` (long-term) or `ASIA` (temporary) + 16 upper-case letters and digits | `vws/iam/v1/access_key.proto`, `auth.proto` |
| `expected_user_path` | AIP-122 user resource name `projects/{project}/users/{user}`. When set and different from the access key's parent user, `FAILED_PRECONDITION` and no state change | `vws/iam/v1/access_key.proto` `UpdateAccessKeyRequest`, `DeleteAccessKeyRequest` |
| IAM `path` | Starts and ends with `/`, 1-512 characters | the same files |
| Policy document | AWS JSON, `Version` `2012-10-17`. At most 6144 characters excluding whitespace. Unparseable, or a condition outside `docs/iam.md`, is `INVALID_ARGUMENT / INVALID_SPEC` | `policy.proto` |
| IAM tag key | 1-128 characters of `[\p{L}\p{Z}\p{N}_.:/=+\-@]`, not beginning with `aws:`. Case sensitive. At most 50 tags per policy or virtual MFA device. `INVALID_ARGUMENT / INVALID_SPEC` when invalid, `RESOURCE_EXHAUSTED / QUOTA_EXCEEDED` past 50 | `policy.proto` `Tag`, `mfa_device.proto` `TagMFADevice` |
| IAM tag value | 0-256 characters of the same alphabet, not beginning with `aws:` | `policy.proto` `Tag`, `mfa_device.proto` `TagMFADevice` |
| Password | 8-128 characters. Stored only as an argon2id hash. Never in operation records or logs | `user.proto` |
| `OUTPUT_ONLY` fields | Ignored on input by the AIP-203 convention. The comments in this repo do not state the server behaviour (needs checking). `status` is written only by servers and nodes | `google.api.field_behavior` |
| `request_id` | The same id with the same fingerprint returns the original operation; a different fingerprint is `ABORTED / IDEMPOTENCY_CONFLICT`. Remembered for 24 hours | `vws/common/v1/operation.proto` |
| `generation` in status reports | A report lower than the stored value is ignored | `ObservedState` |
| `etag` | When set, it must equal the stored etag; otherwise `ETAG_MISMATCH` | `operation.proto` |

## Malicious and boundary input test baseline

The minimum inputs server repos put in their tests:

- Ids of length 0, 63 and 64. Ids with upper case, underscores, or leading or trailing hyphens.
- Objects whose key is `.`, `..`, the empty string, 1025 bytes, `a//b`, `/a`, or has control characters.
- A label with a 64-byte value, a label with a 64-character key.
- Create and update requests with an `OUTPUT_ONLY` field (for example `claim_name`) filled in.
- A status report with a lower `generation`, an update with a wrong `etag`, a different body for the same `request_id`.
- IAM: a 65-character name, duplicate names differing only in case, an invalid JSON policy, an unsupported condition operator, a third access key, reuse of the same TOTP code, an expired session token and temporary key.

## Schema change rules

- Field numbers are never reused. Removing or changing one fails `buf breaking` (FILE), and CI blocks it on the PR. Only when needed, write the narrowest exception in the PR body with its reason.
- A PR that changes proto states in its body whether it is breaking and its downstream impact (PR template).
