# IAM (vws.iam.v1)

The contract of the vws-iam service. The design is vws-iam#1, and this API is vws-proto#24. The implementation is the vws-iam repo.

## Resources and names

- A project is an AWS account. ARNs look like `arn:vws:iam::{project}:user{path}{user}`, and STS is `arn:vws:sts::{project}:assumed-role/{role}/{session}`.
- Users, groups, roles, managed policies (+ versions), access keys and MFA devices are resources. Names are IamName (`docs/validation.md`).
- Attaching policies is not a separate RPC: `spec.attached_policies` (managed) and `spec.inline_policies` (inline) change through `Update*`. Group membership is `Group.spec.members`. console-api maps the AWS Query API (`AttachUserPolicy`, `AddUserToGroup` and so on) to these Updates with the etag.

## Operations

There is no state for a node to reconcile, so the server stores the resource and its status (`observed` READY, same generation) at once and returns a finished operation. Decisions (vws-proto#24 review): AWS name grammar, no operation for secret RPCs, IAM operations READY at once, project = account ARN. `CreateAccessKey` and `CreateVirtualMfaDevice`, whose responses carry a secret, and `SetLoginProfile` and `ChangePassword`, which take a password, are not operations (so no secret stays in an operation record). These four are the exceptions to this repo's AIP-151 rule.

## Authentication and authorization (AuthService, TokenService)

| RPC | Caller | What it does |
| --- | --- | --- |
| `Authenticate` | console-api SigV4 verification | `access_key_id`, `date`, `region`, `service`, `canonical_request`, `string_to_sign`, `signature`, `session_token` (the same as console-api `sigv4.AuthRequest`) -> `account`, `arn`, `is_root` (+ `principal` with MFA and session information). Secrets never leave vws-iam |
| `Authorize` | every console-api handler, other services | principal, action, resource ARN, condition keys -> ALLOW / DENY_EXPLICIT / DENY_IMPLICIT |
| `Login`, `ValidateSession`, `Logout` | console-api console sign-in (vws-console-api#95) | password (+ TOTP) -> a session token for an HttpOnly cookie |
| `AssumeRole`, `GetSessionToken` | console-api STS Query API | temporary credentials (`ASIA…`, secret, session token, expiry) |

AuthService and TokenService are for in-cluster use only. The chart's NetworkPolicy admits only console-api (vws-deploy#243).

## Policy evaluation (Phase 1)

- Explicit Deny > Allow > implicit deny. Identity policies (user, groups, role) and role trust policies.
- `Action`/`NotAction`, `Resource`/`NotResource`, `*` and `?` wildcards.
- Conditions: `StringEquals`, `StringNotEquals`, `StringLike`, `StringNotLike`, `ArnLike`, `ArnEquals`, `Bool` (`aws:MultiFactorAuthPresent`, `aws:SecureTransport`), `IpAddress`/`NotIpAddress` (`aws:SourceIp`), `DateLessThan`/`DateGreaterThan` (`aws:CurrentTime`), `NumericLessThan` (`aws:MultiFactorAuthAge`), `aws:RequestedRegion`. `...IfExists` and `ForAnyValue:`/`ForAllValues:` are not in Phase 1.
- Not included: resource policies other than role trust policies (S3 bucket policies come later), SCPs, permission boundaries, session policies.
- `aws:MultiFactorAuthPresent`, `aws:PrincipalArn` and `aws:username` are filled by the server; request values are ignored.

## Errors

IAM reasons were added to `vws.common.v1.ErrorReason`. `UNAUTHENTICATED`: `INVALID_CREDENTIALS`, `MFA_REQUIRED`, `TOKEN_EXPIRED`. `PERMISSION_DENIED`: `ACCESS_DENIED` (for example, an AssumeRole trust policy denial). A denial from `Authorize` is not an error but the `decision` in the response. Limits (2 keys, 5 policy versions, 10 attached policies) are `RESOURCE_EXHAUSTED / QUOTA_EXCEEDED`; a state that cannot be deleted (AWS DeleteConflict) is `FAILED_PRECONDITION / DEPENDENCY_MISSING`.

## Not in Phase 1

- Renaming a user (`NewUserName` in AWS `UpdateUser`). The name is the resource id.
- Tags (`TagUser` and so on). Whether `labels` replace them is undecided.
- Session policies (AssumeRole `Policy`/`PolicyArns`).
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
