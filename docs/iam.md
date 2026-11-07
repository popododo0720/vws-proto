# IAM (vws.iam.v1)

The contract of the vws-iam service. The design is vws-iam#1, and this API is vws-proto#24. The implementation is the vws-iam repo.

## Resources and names

- A project is an AWS account. ARNs look like `arn:vws:iam::{project}:user{path}{user}`, and STS is `arn:vws:sts::{project}:assumed-role/{role}/{session}`.
- Users, groups, roles, managed policies (+ versions), access keys and MFA devices are resources. Names are IamName (`docs/validation.md`).
- Attaching policies is not a separate RPC: `spec.attached_policies` (managed) and `spec.inline_policies` (inline) change through `Update*`. Group membership is `Group.spec.members`. console-api maps the AWS Query API (`AttachUserPolicy`, `AddUserToGroup` and so on) to these Updates with the etag.

## Operations

There is no state for a node to reconcile, so the server stores the resource and its status (`observed` READY, same generation) at once and returns a finished operation. Decisions (vws-proto#24 review): AWS name grammar, no operation for secret RPCs, IAM operations READY at once, project = account ARN. `CreateAccessKey` and `CreateVirtualMfaDevice`, whose responses carry a secret, and `SetLoginProfile`, `ChangePassword` and `ResyncMfaDevice`, which take a password or TOTP codes, are not operations (so no secret stays in an operation record). `PutRolePermissionsBoundary` is not an operation either, because the AWS call is synchronous and the server stores the boundary in one conditional write. These are the exceptions to this repo's AIP-151 rule.

## Authentication and authorization (AuthService, TokenService)

| RPC | Caller | What it does |
| --- | --- | --- |
| `Authenticate` | console-api SigV4 verification | `access_key_id`, `date`, `region`, `service`, `canonical_request`, `string_to_sign`, `signature`, `session_token` (the same as console-api `sigv4.AuthRequest`) -> `account`, `arn`, `is_root` (+ `principal` with MFA and session information). Secrets never leave vws-iam |
| `Authorize` | every console-api handler, other services | principal, action, resource ARN, condition keys -> ALLOW / DENY_EXPLICIT / DENY_IMPLICIT, and `encoded_message` on a deny |
| `Login`, `ValidateSession`, `Logout` | console-api console sign-in (vws-console-api#95) | password (+ TOTP) -> a session token for an HttpOnly cookie |
| `AssumeRole`, `GetSessionToken` | console-api STS Query API | temporary credentials (`ASIA…`, secret, session token, expiry) |
| `DecodeAuthorizationMessage` | console-api STS Query API | `encoded_message` -> the decoded JSON of the deny |
| `GetAccessKeyInfo` | console-api STS Query API | `access_key_id` -> the `account` (project) that owns the key |
| `GetFederationToken` | console-api STS Query API | `name`, session policies -> federated user credentials, `federated_user`, `packed_policy_size` |
| `AssumeRoleWithSAML` | console-api STS Query API, no caller credential | `role_arn`, `principal_arn`, signed `saml_assertion`, session policies -> role credentials, `assumed_role_user`, `packed_policy_size` and the SAML subject fields |

AuthService and TokenService are for in-cluster use only. The chart's NetworkPolicy admits only console-api (vws-deploy#243).

## Policy evaluation (Phase 1)

- Explicit Deny > Allow > implicit deny. Identity policies (user, groups, role) and role trust policies.
- `Action`/`NotAction`, `Resource`/`NotResource`, `*` and `?` wildcards.
- Conditions: `StringEquals`, `StringNotEquals`, `StringLike`, `StringNotLike`, `ArnLike`, `ArnEquals`, `Bool` (`aws:MultiFactorAuthPresent`, `aws:SecureTransport`), `IpAddress`/`NotIpAddress` (`aws:SourceIp`), `DateLessThan`/`DateGreaterThan` (`aws:CurrentTime`), `NumericLessThan` (`aws:MultiFactorAuthAge`), `aws:RequestedRegion`. `...IfExists` and `ForAnyValue:`/`ForAllValues:` are not in Phase 1.
- Not included: resource policies other than role trust policies (S3 bucket policies come later), SCPs, permission boundaries. Session policies apply only to federated user sessions and SAML role sessions (see "Get federation token (#86)" and "Assume role with SAML (#87)").
- `aws:MultiFactorAuthPresent`, `aws:PrincipalArn` and `aws:username` are filled by the server; request values are ignored.

## Errors

IAM reasons were added to `vws.common.v1.ErrorReason`. `UNAUTHENTICATED`: `INVALID_CREDENTIALS`, `MFA_REQUIRED`, `TOKEN_EXPIRED`. `PERMISSION_DENIED`: `ACCESS_DENIED` (for example, an AssumeRole trust policy denial). A denial from `Authorize` is not an error but the `decision` in the response. Limits (2 keys, 5 policy versions, 10 attached policies) are `RESOURCE_EXHAUSTED / QUOTA_EXCEEDED`; a state that cannot be deleted (AWS DeleteConflict) is `FAILED_PRECONDITION / DEPENDENCY_MISSING`.

## Not in Phase 1

- Tags on resources other than a managed policy and a virtual MFA device (`TagUser`, `TagRole` and so on; `TagPolicy`, `UntagPolicy`, `ListPolicyTags`, `TagMFADevice`, `UntagMFADevice` and `ListMFADeviceTags` are in Phase 1).
- AssumeRole session policies (`Policy`/`PolicyArns`), and session tags on any STS call.
- The conditions `...IfExists`, `ForAnyValue:` and `ForAllValues:`.
- `SimulatePrincipalPolicy`, `SimulateCustomPolicy`.
- Reverse lookup lists (`ListAttachedUserPolicies`, `ListGroupsForUser`, `ListEntitiesForPolicy` and so on). console-api builds them from spec and status (`User.status.groups`).

## Needs checking

- Whether the server really follows these rules is checked in the vws-iam repo.

## STS caller and secret fields (#28)

- `AssumeRole` and `GetSessionToken` do not trust the request's `caller`. The field is deprecated and the server ignores it. Trusting a principal sent by the client would let anyone who reaches this service act as any principal (impersonation). The server verifies the `authentication` oneof (`sigv4` or `console_session_token`) itself and derives the caller from it. Without it, the result is `UNAUTHENTICATED / INVALID_CREDENTIALS`.
- Removing the `caller` field is blocked by `buf breaking` (FILE), so it stays deprecated for compatibility with v0.2.0. Actually removing it and turning its number into `reserved` happens in the next breaking release.
- `AuthService` and `TokenService` are cluster-internal only, so they have no `google.api.http` paths (gRPC only).
- Secret fields (secret access key, session token, password, TOTP code, MFA seed and otpauth URI) are `OUTPUT_ONLY` or `INPUT_ONLY` with `debug_redact = true`, so they are hidden in protobuf text/debug output. They are never logged.

## MFA device lockout status (#32)

- `MfaDeviceStatus.failed_attempts` (5) is the number of wrong codes since the last success or lock. After 5 wrong codes, the device locks for 15 minutes.
- `MfaDeviceStatus.locked_until` (6) is set only while locked. Until then, even a correct code is refused.
- Both are output-only fields inside status. They carry no seed or code.

## Session revocation (#31)

- `UserService.RevokeUserSessions` and `RoleService.RevokeRoleSessions` are the AWS console's "Revoke active sessions". STS sessions issued before that moment (`GetSessionToken` for users, `AssumeRole` for roles) are refused. Credentials issued later are not affected.
- It is a change to the desired state, so it returns an operation and is idempotent by `request_id`. No secret is exchanged, so it is not an operation exception. The response is the User/Role with `status.sessions_revoke_time` set.
- The permission is `iam:RevokeUserSessions` / `iam:RevokeRoleSessions` on the target ARN.

## Policy tags (#74, #75, #76)

- `PolicyService.TagPolicy`, `UntagPolicy` and `ListPolicyTags` carry AWS customer managed policy tags.
- A tag is not an envelope label: AWS tag keys may be 128 characters with spaces, upper case and punctuation, which the envelope label grammar (`[a-z][a-z0-9_-]{0,62}`) rejects. Tags are therefore a `tags` map on the stored policy, next to its versions, and not `labels`.
- The limits are the AWS ones: 50 tags per policy, key 1-128 and value 0-256 characters of `[\p{L}\p{Z}\p{N}_.:/=+\-@]`, no key or value beginning with `aws:`. Invalid input is `INVALID_ARGUMENT / INVALID_SPEC`; the 51st tag is `RESOURCE_EXHAUSTED / QUOTA_EXCEEDED`.
- Key case is significant for a policy, as in AWS. A later `TagPolicy` overwrites the value of a key it names. `UntagPolicy` ignores a key that is not attached.
- `TagPolicy` and `UntagPolicy` are operations (AIP-151) and idempotent by `request_id`. `ListPolicyTags` sorts by key and pages.

## MFA device tags (#77, #78, #79)

- `MfaDeviceService.TagMFADevice`, `UntagMFADevice` and `ListMFADeviceTags` carry AWS virtual MFA device tags. The requests name the device by its resource name; console-api resolves the AWS `SerialNumber` (the device ARN) to that name, and a device that does not exist is `NoSuchEntity`.
- The tag rules are the same as for a policy: a tag is a `tags` map on the stored device, not an envelope label; 50 tags per device, key 1-128 and value 0-256 characters of `[\p{L}\p{Z}\p{N}_.:/=+\-@]`, no key or value beginning with `aws:`; key case significant, so a differently cased key is a second tag.
- Invalid input is `INVALID_ARGUMENT / INVALID_SPEC`; the 51st tag is `RESOURCE_EXHAUSTED / QUOTA_EXCEEDED`. A later `TagMFADevice` overwrites the value of a key it names. `UntagMFADevice` ignores a key that is not attached.
- A tag change does not change any timestamp of the device: AWS has no update time for a virtual MFA device, so `create_time`, `update_time` and `status.enable_time` stay as they were.
- `TagMFADevice` and `UntagMFADevice` are operations (AIP-151) and idempotent by `request_id`. `ListMFADeviceTags` sorts by key and pages.

## MFA device resync (#113)

- `MfaDeviceService.ResyncMfaDevice` is AWS `ResyncMFADevice`. It finds two consecutive codes within +/-10 minutes of the server clock and stores the device clock drift.
- It is not an operation. The request carries TOTP codes, and no secret belongs in an operation record. The response is empty, as AWS returns only a request id.
- Errors: a length or pattern fault is `INVALID_ARGUMENT / INVALID_SPEC`. An unknown user, or a serial that is not a device enabled for the user, is `NOT_FOUND / RESOURCE_NOT_FOUND`. A wrong, out-of-window or already used pair is `UNAUTHENTICATED / INVALID_CREDENTIALS` and counts towards the device lockout. A locked device is `PERMISSION_DENIED / ACCESS_DENIED`. A write that keeps losing to concurrent writes is `ABORTED / GENERATION_CONFLICT`.
- Retry: codes are single use, so a retry of a request that already succeeded is `UNAUTHENTICATED`. The stored drift stays, and the client resyncs again with two new codes.

## Role permissions boundary (#115)

- `RoleService.PutRolePermissionsBoundary` is AWS `PutRolePermissionsBoundary`. It sets `RoleSpec.permissions_boundary_arn` to a managed policy of the role's project and replaces any boundary the role has. `GetRole` returns it; AWS `PermissionsBoundaryType` is always `PermissionsBoundaryPolicy`. `CreateRole` and `UpdateRole` do not change it.
- The boundary is stored only. `Authorize` does not apply it, as permission boundaries are not in Phase 1 policy evaluation.
- It is not an operation. The response is empty, as AWS returns only a request id.
- Errors: a role name or ARN length or pattern fault is `INVALID_ARGUMENT / INVALID_SPEC` (`ValidationError`), and an ARN that is not a managed policy ARN is `INVALID_ARGUMENT / INVALID_SPEC` (`InvalidInput`). An unknown role, or a policy that is not a managed policy of the project (path included), is `NOT_FOUND / RESOURCE_NOT_FOUND` (`NoSuchEntity`). A service-linked role is `FAILED_PRECONDITION / UNMODIFIABLE_ENTITY` (`UnmodifiableEntity`). A write that keeps losing to concurrent writes is `ABORTED / GENERATION_CONFLICT` (`ConcurrentModification`).
- Retry: a role that already has this boundary succeeds without a write, so a retry after a lost response succeeds. A retry after another caller set a different boundary replaces it (last writer wins, as in AWS).
- Authorization (`iam:PutRolePermissionsBoundary`) is console-api's.

## Decode authorization message (#84)

- `TokenService.DecodeAuthorizationMessage` is AWS STS `DecodeAuthorizationMessage`. It opens the `AuthorizeResponse.encoded_message` that vws-iam sets on a `DENY_*` decision; console-api returns that message the way AWS does, for example as the EC2 `UnauthorizedOperation` "Encoded authorization failure message". It is empty on `ALLOW`.
- The caller comes only from the `authentication` oneof, as on `AssumeRole`. It needs `sts:DecodeAuthorizationMessage` on `*`, checked before the message is opened.
- `source_ip` is set by console-api from the connection it observed, never from a client value. On the `console_session_token` path vws-iam uses it as `aws:SourceIp`, so an `IpAddress` Deny on `sts:DecodeAuthorizationMessage` applies to the current request, not the IP stored at Login. Empty means unknown: the key is absent and `IpAddress` does not match. On the `sigv4` path `sigv4.source_ip` is used.
- Errors: no authentication is `UNAUTHENTICATED / INVALID_CREDENTIALS` (`MissingAuthenticationToken`). Missing permission, or a SigV4 request signed for another action, is `PERMISSION_DENIED / ACCESS_DENIED` (`AccessDenied`); a replayed SigV4 request is refused as for AssumeRole. An empty or over-long `encoded_message` is `INVALID_ARGUMENT / INVALID_SPEC` (`ValidationError`). A malformed, tampered, expired, other-project or unknown-key message is `INVALID_ARGUMENT / INVALID_SPEC` (`InvalidAuthorizationMessageException`, HTTP 400).
- It is not an operation: read only, and a repeat returns the same JSON. The encoded and decoded messages are `debug_redact` and never logged.

## Get access key info (#85)

- `TokenService.GetAccessKeyInfo` is AWS STS `GetAccessKeyInfo`. It returns the project (`account`) that owns `access_key_id`. The key may belong to any project, not only the caller's.
- The caller comes only from the `authentication` oneof, as on `AssumeRole`. It needs `sts:GetAccessKeyInfo` on `*`, checked before the key is looked up, so a caller without it learns nothing about the key.
- `source_ip` is set by console-api from the connection it observed, never from a client value. On the `console_session_token` path vws-iam uses it as `aws:SourceIp`; empty means unknown and the key is absent. On the `sigv4` path `sigv4.source_ip` is used.
- Errors: no authentication is `UNAUTHENTICATED / INVALID_CREDENTIALS` (`MissingAuthenticationToken`). Missing permission, or a SigV4 request signed for another action, is `PERMISSION_DENIED / ACCESS_DENIED` (`AccessDenied`); a replayed SigV4 request is refused as for AssumeRole. An `access_key_id` shorter than 16, longer than 128, or with a character outside `[\w]` is `INVALID_ARGUMENT / INVALID_SPEC` (`ValidationError`). A key that does not exist (never created, deleted, or not yet active) is `NOT_FOUND / RESOURCE_NOT_FOUND` (`InvalidClientTokenId`).
- The key's state does not change the answer: an active or inactive key returns its project. It is not an operation: read only, and a repeat returns the same account.

## Get federation token (#86)

- `TokenService.GetFederationToken` is AWS STS `GetFederationToken`. It issues credentials for the federated user `arn:vws:sts::{project}:federated-user/{name}` (`federated_user_id` `{project}:{name}`). vws-iam seals the session into the token and stores nothing.
- The caller comes only from the `authentication` oneof. Only a long-term key of an IAM user or the root user may call it. A console session, a session token, an assumed-role or a federated caller is `PERMISSION_DENIED / ACCESS_DENIED` (`AccessDenied`). The caller needs `sts:GetFederationToken` on the federated-user ARN.
- `duration_seconds` is 900-129600, zero means 43200, and a root caller's session is capped at 3600.
- The session's permissions are the intersection of the caller's policies and the session policies (`policy`, `policy_arns`). No session policy means no permissions. A federated session cannot call IAM or STS, except `GetCallerIdentity`. Session tags are not supported.
- `GetFederationToken` returns credentials, not a `Principal`. When a later request is signed with them, `Authenticate` resolves them to a `PRINCIPAL_TYPE_FEDERATED_USER` principal whose `session_context` carries the session policies, sealed by vws-iam and bound to the session's `arn`, `unique_id`, project and expiry. console-api passes that principal to `Authorize` unchanged, as it does for every principal. A principal with type `FEDERATED_USER` or a federated-user ARN whose `session_context` is missing, does not open, has expired or is bound to another session is `DENY_IMPLICIT`, so the gateway never authorizes a federated session as its IAM user.
- Errors: no authentication is `UNAUTHENTICATED / INVALID_CREDENTIALS` (`MissingAuthenticationToken`). Missing permission, or a SigV4 request signed for another action, is `PERMISSION_DENIED / ACCESS_DENIED` (`AccessDenied`); a replayed SigV4 request is refused as for AssumeRole. A bad `name`, `duration_seconds`, `policy` length or character, or more than 10 `policy_arns` is `INVALID_ARGUMENT / INVALID_SPEC` (`ValidationError`). A policy that does not parse, or a `policy_arns` entry that is not a managed policy of the project, is `INVALID_ARGUMENT / INVALID_SPEC` (`MalformedPolicyDocument`). The plaintext of `policy` plus `policy_arns` over 2048 characters in total is `INVALID_ARGUMENT / INVALID_SPEC` (`PackedPolicyTooLarge`); VWS has no separate packed binary limit, and `packed_policy_size` is the percentage of that 2048-character limit. AWS `RegionDisabled` does not occur.
- It is not an operation and stores nothing. A repeat issues new credentials, as in AWS. `policy` and `session_context` are never logged.

## Assume role with SAML (#87)

- `TokenService.AssumeRoleWithSAML` is AWS STS `AssumeRoleWithSAML`. It issues credentials for `role_arn` from a SAML 2.0 response of the identity provider `principal_arn` (`arn:vws:iam::{project}:saml-provider/{name}`). The session is `arn:vws:sts::{project}:assumed-role/{role}/{session}`, with `assumed_role_id` `{role id}:{session}`; the session name is the assertion's RoleSessionName. vws-iam seals the session into the token and stores nothing.
- It has no `authentication` oneof and takes no caller credential. vws-iam verifies the response signature against the certificates the provider lists. The trust policy must allow `sts:AssumeRoleWithSAML` for the `Federated` provider, and the assertion's Role attribute must grant the (`role_arn`, `principal_arn`) pair.
- `duration_seconds` is 900-43200, zero means 3600, and it may not exceed the role's `max_session_duration_seconds`.
- The session's permissions are the role's policies, intersected with the session policies (`policy`, `policy_arns`) when any are given. As for federated users, `Authenticate` carries those session policies in `Principal.session_context`. Session tags from the assertion and `MinimumSessionTokenSize` are not supported.
- `source_ip` is set by console-api from the connection it observed, never from a client value. Empty means unknown.
- Errors: a bad `role_arn`, `principal_arn` or `saml_assertion` length, `duration_seconds`, a `policy` over 2048 characters or with another character, or more than 10 `policy_arns` is `INVALID_ARGUMENT / INVALID_SPEC` (`ValidationError`). A policy that does not parse, or a `policy_arns` entry that is not a managed policy of the project, is `INVALID_ARGUMENT / INVALID_SPEC` (`MalformedPolicyDocument`). When each passes its own limit, the plaintext of `policy` plus `policy_arns` over 2048 characters in total is `INVALID_ARGUMENT / INVALID_SPEC` (`PackedPolicyTooLarge`). A response that is not base64 or XML, unsigned, signed by an unlisted certificate, wrapped (more than one assertion), addressed to another audience, recipient or destination, from another issuer, missing the Role or RoleSessionName attribute, or naming an unknown SAML provider is `INVALID_ARGUMENT / INVALID_SPEC` (`InvalidIdentityToken`). An expired assertion is `UNAUTHENTICATED / TOKEN_EXPIRED` (`ExpiredToken`). A response whose status is not Success is `PERMISSION_DENIED / ACCESS_DENIED` (`IDPRejectedClaim`). A Role attribute that does not grant the pair, an unknown role, or a trust policy that does not allow the call is `PERMISSION_DENIED / ACCESS_DENIED` (`AccessDenied`). AWS `RegionDisabled` does not occur.
- It is not an operation and stores nothing. A repeat with the same unexpired response issues new credentials, as in AWS. `saml_assertion`, `policy` and `session_context` are never logged.
