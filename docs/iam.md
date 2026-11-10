# IAM (vws.iam.v1)

The contract of the vws-iam service. The design is vws-iam#1, and this API is vws-proto#24. The implementation is the vws-iam repo.

## Resources and names

- A project is an AWS account. ARNs look like `arn:vws:iam::{project}:user{path}{user}`, and STS is `arn:vws:sts::{project}:assumed-role/{role}/{session}`.
- Users, groups, roles, managed policies (+ versions), access keys and MFA devices are resources. Names are IamName (`docs/validation.md`).
- Attaching policies is not a separate RPC: `spec.attached_policies` (managed) and `spec.inline_policies` (inline) change through `Update*`. Group membership is `Group.spec.members`. console-api maps the AWS Query API (`AttachUserPolicy`, `AddUserToGroup` and so on) to these Updates with the etag.

## Operations

There is no state for a node to reconcile, so the server stores the resource and its status (`observed` READY, same generation) at once and returns a finished operation. Decisions (vws-proto#24 review): AWS name grammar, no operation for secret RPCs, IAM operations READY at once, project = account ARN. `CreateAccessKey` and `CreateVirtualMfaDevice`, whose responses carry a secret, and `SetLoginProfile`, `ChangePassword` and `ResyncMfaDevice`, which take a password or TOTP codes, are not operations (so no secret stays in an operation record). `PutRolePermissionsBoundary`, `DeleteRolePermissionsBoundary`, `PutUserPermissionsBoundary` and `DeleteUserPermissionsBoundary` are not operations either, because the AWS calls are synchronous and the server stores or clears the boundary in one conditional write. `CreateServiceLinkedRole` is not an operation, because the AWS call returns the role and the server stores it in one write. `DeleteServiceLinkedRole` is not an operation, because the AWS call returns the deletion task id and the role is deleted from the store when it returns. `AddRoleToInstanceProfile` and `RemoveRoleFromInstanceProfile` are not operations, because the AWS calls are synchronous and the server adds or removes the role in one conditional write. `DeleteInstanceProfile` is not an operation, because the AWS call is synchronous and the server deletes the profile in one conditional write. These are the exceptions to this repo's AIP-151 rule.

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
| `AssumeRoleWithWebIdentity` | console-api STS Query API, no caller credential | `role_arn`, `role_session_name`, signed OIDC `web_identity_token`, session policies -> role credentials, `assumed_role_user`, `packed_policy_size` and the token's `audience`, `provider`, subject and source identity |

AuthService and TokenService are for in-cluster use only. The chart's NetworkPolicy admits only console-api (vws-deploy#243).

## Policy evaluation (Phase 1)

- Explicit Deny > Allow > implicit deny. Identity policies (user, groups, role) and role trust policies.
- `Action`/`NotAction`, `Resource`/`NotResource`, `*` and `?` wildcards.
- Conditions: `StringEquals`, `StringNotEquals`, `StringLike`, `StringNotLike`, `ArnLike`, `ArnEquals`, `Bool` (`aws:MultiFactorAuthPresent`, `aws:SecureTransport`), `IpAddress`/`NotIpAddress` (`aws:SourceIp`), `DateLessThan`/`DateGreaterThan` (`aws:CurrentTime`), `NumericLessThan` (`aws:MultiFactorAuthAge`), `aws:RequestedRegion`. `...IfExists` and `ForAnyValue:`/`ForAllValues:` are not in Phase 1.
- Not included: resource policies other than role trust policies (S3 bucket policies come later), SCPs, permission boundaries. Session policies apply only to federated user sessions, SAML role sessions and web identity role sessions (see "Get federation token (#86)", "Assume role with SAML (#87)" and "Assume role with web identity (#105)").
- `aws:MultiFactorAuthPresent`, `aws:PrincipalArn` and `aws:username` are filled by the server; request values are ignored.

## Errors

IAM reasons were added to `vws.common.v1.ErrorReason`. `UNAUTHENTICATED`: `INVALID_CREDENTIALS`, `MFA_REQUIRED`, `TOKEN_EXPIRED`. `PERMISSION_DENIED`: `ACCESS_DENIED` (for example, an AssumeRole trust policy denial). A denial from `Authorize` is not an error but the `decision` in the response. Limits (2 keys, 5 policy versions, 10 attached policies) are `RESOURCE_EXHAUSTED / QUOTA_EXCEEDED`; a state that cannot be deleted (AWS DeleteConflict) is `FAILED_PRECONDITION / DEPENDENCY_MISSING`.

## Not in Phase 1

- Write tag RPCs on resources other than a managed policy and a virtual MFA device (`TagUser` and so on; `TagPolicy`, `UntagPolicy`, `ListPolicyTags`, `TagMFADevice`, `UntagMFADevice`, `ListMFADeviceTags`, `TagRole`, `UntagRole` and `ListRoleTags` are in).
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
- `RoleService.DeleteRolePermissionsBoundary` (#114) is AWS `DeleteRolePermissionsBoundary`. It clears `RoleSpec.permissions_boundary_arn`; the trust and permission policies stay. It is not an operation, and the response is empty.
- Errors: a role name length or pattern fault is `INVALID_ARGUMENT / INVALID_SPEC` (`ValidationError`). An unknown role is `NOT_FOUND / RESOURCE_NOT_FOUND` (`NoSuchEntity`). A service-linked role is `FAILED_PRECONDITION / UNMODIFIABLE_ENTITY` (`UnmodifiableEntity`). A write that keeps losing to concurrent writes is `ABORTED / GENERATION_CONFLICT` (`ConcurrentModification`).
- Retry: a role with no boundary succeeds without a write, so a retry after a lost response succeeds.
- Authorization (`iam:DeleteRolePermissionsBoundary`) is console-api's.

## Role tags (#139)

- `RoleService.ListRoleTags` is AWS `ListRoleTags`. `name` is `projects/{project}/roles/{role}`; the role id is AWS `RoleName`. It returns the role's stored tags as `vws.iam.v1.Tag` (key, value), sorted by key, in pages. `page_size` is AWS `MaxItems` (1-1000; 0 is unset, server default 100) and `page_token` and `next_page_token` are AWS `Marker`; `next_page_token` is set exactly when AWS `IsTruncated` is true. It is a read RPC, not an operation.
- A tag is not an envelope label: the rules are the same as for a policy (50 tags, key 1-128 and value 0-256 characters of `[\p{L}\p{Z}\p{N}_.:/=+\-@]`, no key or value beginning with `aws:`; key case significant). `TagRole` and `UntagRole` (#263) write them.
- Errors: a bad project, a `RoleName` outside the AWS pattern, a `page_size` outside 1-1000 or a `page_token` character outside `[\u0020-\u00FF]` is `INVALID_ARGUMENT / INVALID_SPEC` (`ValidationError`). A well-formed `page_token` the server did not issue is `INVALID_ARGUMENT / INVALID_SPEC` (`InvalidInput`). All of these are checked before any store access. An unknown role is `NOT_FOUND / RESOURCE_NOT_FOUND` (`NoSuchEntity`, `The role with name X cannot be found.`). Any other failure is `INTERNAL` (`ServiceFailure`). console-api answers an explicit `MaxItems=0` as `ValidationError` itself, since 0 means unset here.
- Pages: deterministic in key order. A tag that exists for the whole listing is returned once. The call only reads, so a retry is safe.
- Authorization (`iam:ListRoleTags`) is console-api's.
- `RoleService.TagRole` and `UntagRole` (#263) are AWS `TagRole` and `UntagRole`. `name` is `projects/{project}/roles/{role}`; the role id is AWS `RoleName`. `tags` is AWS `Tags` (1-50 `vws.iam.v1.Tag`) and `tag_keys` is AWS `TagKeys` (1-50 keys). Both are operations (AIP-151), returned done with the `Role` as the response, and idempotent by `request_id`.
- A later `TagRole` overwrites the value of a key it names; a key repeated in one request keeps the last value. `UntagRole` ignores a key that is not attached. The whole request stores nothing when one tag is invalid or the role would keep more than 50 tags. A tag change leaves the other fields of the role as they were.
- Errors: an invalid tag, key or `RoleName`, an empty list, or more than 50 tags in one request is `INVALID_ARGUMENT / INVALID_SPEC` (`InvalidInput`, or `ValidationError` for the name). The 51st tag on the role is `RESOURCE_EXHAUSTED / QUOTA_EXCEEDED` (`LimitExceeded`). An unknown role is `NOT_FOUND / RESOURCE_NOT_FOUND` (`NoSuchEntity`). Authorization (`iam:TagRole`, `iam:UntagRole`) is console-api's.

## User permissions boundary (#116, #117)

- `UserService.PutUserPermissionsBoundary` (#117) is AWS `PutUserPermissionsBoundary`. It sets `UserSpec.permissions_boundary_arn` to a managed policy of the user's project and replaces any boundary the user has; the attached and inline policies stay. It is not an operation, and the response is empty, as AWS returns only a request id.
- Errors: a user name or ARN length or pattern fault is `INVALID_ARGUMENT / INVALID_SPEC` (`ValidationError`), and an ARN that is not a managed policy ARN is `INVALID_ARGUMENT / INVALID_SPEC` (`InvalidInput`). An unknown user, or a policy that is not a managed policy of the user's project (path included), is `NOT_FOUND / RESOURCE_NOT_FOUND` (`NoSuchEntity`). A user being renamed, or a write that keeps losing to concurrent writes, is `ABORTED / GENERATION_CONFLICT` (`ConcurrentModification`).
- Retry: a user that already has this boundary succeeds without a write, so a retry after a lost response succeeds. A retry after another caller set a different boundary replaces it (last writer wins, as in AWS).
- Authorization (`iam:PutUserPermissionsBoundary`) is console-api's.
- `UserService.DeleteUserPermissionsBoundary` is AWS `DeleteUserPermissionsBoundary`. It clears `UserSpec.permissions_boundary_arn`; the attached and inline policies stay. It is not an operation, and the response is empty, as AWS returns only a request id.
- `UserSpec.permissions_boundary_arn` is output only. `GetUser` returns it; AWS `PermissionsBoundaryType` is always `PermissionsBoundaryPolicy`. `CreateUser` and `UpdateUser` do not change it. The boundary is stored only; `Authorize` does not apply it.
- Errors: a user name length or pattern fault is `INVALID_ARGUMENT / INVALID_SPEC` (`ValidationError`). An unknown user is `NOT_FOUND / RESOURCE_NOT_FOUND` (`NoSuchEntity`). A user being renamed, or a write that keeps losing to concurrent writes, is `ABORTED / GENERATION_CONFLICT` (`ConcurrentModification`).
- Retry: a user with no boundary succeeds without a write, so a retry after a lost response succeeds.
- Authorization (`iam:DeleteUserPermissionsBoundary`) is console-api's.

## Instance profiles (#118, #119, #120, #121, #122, #124)

- `InstanceProfile` is the resource `projects/{project}/instanceProfiles/{instance_profile}`; the id is AWS `InstanceProfileName`. `spec.path` is AWS `Path`. `spec.roles` holds the full resource names of its roles (at most one) and is output only: only `AddRoleToInstanceProfile` and `RemoveRoleFromInstanceProfile` change it. `status.arn` is `arn:vws:iam::{project}:instance-profile{path}{instance_profile}`, `status.unique_id` is AWS `InstanceProfileId` (`AIPA...`), and `status.roles` is the `Role` of each `spec.roles` entry, as AWS `InstanceProfile.Roles` carries.
- `InstanceProfileService.AddRoleToInstanceProfile` is AWS `AddRoleToInstanceProfile`. `name` is `projects/{project}/instanceProfiles/{instance_profile}` and `role_name` is the AWS `RoleName` of a role in the same project. It adds the role to the profile. It is not an operation, and the response is empty, as AWS returns only a request id.
- Errors: an instance profile name or role name length or pattern fault is `INVALID_ARGUMENT / INVALID_SPEC` (`ValidationError`). An unknown instance profile or role is `NOT_FOUND / RESOURCE_NOT_FOUND` (`NoSuchEntity`). A profile that already holds a role, the same role included, is `RESOURCE_EXHAUSTED / QUOTA_EXCEEDED` (`LimitExceeded`; one role per instance profile, a fixed AWS quota). A service-linked role is `FAILED_PRECONDITION / UNMODIFIABLE_ENTITY` (`UnmodifiableEntity`). A write that keeps losing to concurrent writes is `ABORTED / GENERATION_CONFLICT` (`ConcurrentModification`).
- Retry: a repeat after success is `RESOURCE_EXHAUSTED / QUOTA_EXCEEDED` (`LimitExceeded`), as in AWS. The store is unchanged by the repeat.
- Authorization (`iam:AddRoleToInstanceProfile`, and `iam:PassRole` on the role) is console-api's.
- `InstanceProfileService.RemoveRoleFromInstanceProfile` is AWS `RemoveRoleFromInstanceProfile`. `name` is `projects/{project}/instanceProfiles/{instance_profile}` and `role_name` is the AWS `RoleName` of a role in the same project. It removes the role from the profile; the role and the profile stay. It is not an operation, and the response is empty, as AWS returns only a request id.
- Errors: an instance profile name or role name length or pattern fault is `INVALID_ARGUMENT / INVALID_SPEC` (`ValidationError`). An unknown instance profile, an unknown role, or a role that is not in the profile is `NOT_FOUND / RESOURCE_NOT_FOUND` (`NoSuchEntity`). A service-linked role is `FAILED_PRECONDITION / UNMODIFIABLE_ENTITY` (`UnmodifiableEntity`). A write that keeps losing to concurrent writes is `ABORTED / GENERATION_CONFLICT` (`ConcurrentModification`).
- Retry: a repeat after success is `NOT_FOUND / RESOURCE_NOT_FOUND` (`NoSuchEntity`), as in AWS. The store is unchanged by the repeat.
- Authorization (`iam:RemoveRoleFromInstanceProfile`) is console-api's.
- `InstanceProfileService.ListInstanceProfilesForRole` (#120) is AWS `ListInstanceProfilesForRole`. `parent` is `projects/{project}` and `role_name` is the AWS `RoleName` of a role in that project. It returns the profiles that hold the role, ordered by case-folded name. `page_size` is AWS `MaxItems` (1-1000; 0 is unset, server default 100) and `page_token` and `next_page_token` are AWS `Marker`; `next_page_token` is set exactly when AWS `IsTruncated` is true. It is a read RPC, not an operation.
- Errors: a `role_name`, `page_size` or `page_token` length or pattern fault is `INVALID_ARGUMENT / INVALID_SPEC` (`ValidationError`). A well-formed `page_token` the server did not issue is `INVALID_ARGUMENT / INVALID_SPEC` (`InvalidInput`). An unknown role is `NOT_FOUND / RESOURCE_NOT_FOUND` (`NoSuchEntity`). A role in no profile is an empty, complete page. console-api answers an explicit `MaxItems=0` as `ValidationError` itself, since 0 means unset here.
- Pages: deterministic in case-folded name order. A profile that exists and holds the role for the whole listing is returned once. The call only reads, so a retry is safe.
- Authorization (`iam:ListInstanceProfilesForRole`) is console-api's.
- `InstanceProfileService.ListInstanceProfiles` (#121) is AWS `ListInstanceProfiles`. `parent` is `projects/{project}`. `path_prefix` is AWS `PathPrefix` (empty is unset: `/`, every profile) and matches the start of `spec.path` case-sensitively. It returns the matching profiles, ordered by case-folded name. `page_size` is AWS `MaxItems` (1-1000; 0 is unset, server default 100) and `page_token` and `next_page_token` are AWS `Marker`; `next_page_token` is set exactly when AWS `IsTruncated` is true. It is a read RPC, not an operation.
- Errors: a `path_prefix`, `page_size` or `page_token` length or pattern fault is `INVALID_ARGUMENT / INVALID_SPEC` (`ValidationError`). A well-formed `page_token` the server did not issue is `INVALID_ARGUMENT / INVALID_SPEC` (`InvalidInput`). No matching profile is an empty, complete page. console-api answers an explicit `MaxItems=0` as `ValidationError` itself, since 0 means unset here.
- Pages: deterministic in case-folded name order. A profile that exists and matches for the whole listing is returned once. The call only reads, so a retry is safe.
- Authorization (`iam:ListInstanceProfiles`) is console-api's.
- `InstanceProfileService.GetInstanceProfile` (#122) is AWS `GetInstanceProfile`. `name` is `projects/{project}/instanceProfiles/{instance_profile}`. It returns the `InstanceProfile` under its stored name, with `status.roles` holding its role (empty when it holds none). Names compare case-insensitively. It is a read RPC, not an operation. AWS also returns `Tags`; vws-iam does not model instance profile tags yet, so a `tags` field is added with that work.
- Errors: a name length or pattern fault is `INVALID_ARGUMENT / INVALID_SPEC` (`ValidationError`). An unknown profile is `NOT_FOUND / RESOURCE_NOT_FOUND` (`NoSuchEntity`). The call only reads, so a retry is safe.
- Authorization (`iam:GetInstanceProfile`) is console-api's.
- `InstanceProfileService.DeleteInstanceProfile` (#124) is AWS `DeleteInstanceProfile`. `name` is `projects/{project}/instanceProfiles/{instance_profile}`. It deletes the profile. Names compare case-insensitively. It is not an operation, and the response is empty, as AWS returns only a request id.
- Errors: a name length or pattern fault is `INVALID_ARGUMENT / INVALID_SPEC` (`ValidationError`). An unknown profile is `NOT_FOUND / RESOURCE_NOT_FOUND` (`NoSuchEntity`). A profile that still holds a role is `FAILED_PRECONDITION / DEPENDENCY_MISSING` (`DeleteConflict`, `Cannot delete entity, must remove roles from instance profile first.`).
- Retry: the delete is conditional on the version read, so it never races a concurrent `AddRoleToInstanceProfile`. A repeat after a lost response is `NOT_FOUND` (`NoSuchEntity`), as in AWS.
- Authorization (`iam:DeleteInstanceProfile`) is console-api's.
- The other instance profile actions (#126) join this service.

## Account authorization details (#137)

- `AccountService.GetAccountAuthorizationDetails` is AWS `GetAccountAuthorizationDetails`. `parent` is `projects/{project}`. `filter` is AWS `Filter`: each value is one of `User`, `Role`, `Group`, `LocalManagedPolicy`, `AWSManagedPolicy` (case sensitive); empty means all; duplicates are allowed. `max_items` is AWS `MaxItems` (1-1000; 0 is unset, server default 100) and `marker` is AWS `Marker`. The response lists `user_detail_list`, `group_detail_list`, `role_detail_list` and `policies` (customer managed), in that order, each by case-folded name. `is_truncated` and `marker` are AWS `IsTruncated` and `Marker`; `marker` is set exactly when `is_truncated` is true. It is a read RPC, not an operation.
- Documents (`user_policy_list`, `group_policy_list`, `role_policy_list`, `assume_role_policy_document`, and `policy_version_list.document`) are plain JSON. URL encoding (RFC 3986) is console-api's wire concern.
- `AWSManagedPolicy` selects nothing (AWS managed policies are not modeled, popododo0720/vws-iam#260). `UserDetail.tags`, `RoleDetail.tags` and `RoleLastUsed` are not modeled yet (popododo0720/vws-iam#265) and are left unset.
- The AWS `InstanceProfile` and `PolicyVersion` data types are `AuthorizationInstanceProfile` and `AuthorizationPolicyVersion` in this contract, because `InstanceProfile` and `PolicyVersion` already name the resource envelopes. `AuthorizationInstanceProfile.roles` is a slim `AuthorizationRole` (not `RoleDetail`), so the list does not recurse. `permissions_boundary` is unset when the user or role has none; `permissions_boundary_type` is `Policy` when the message is set.
- Errors: a bad `parent`, an unknown `filter` value, a `max_items` outside 1-1000 or a `marker` character outside `[\u0020-\u00FF]` is `INVALID_ARGUMENT / INVALID_SPEC` (`ValidationError`). A well-formed `marker` the server did not issue is `INVALID_ARGUMENT / INVALID_SPEC` (`InvalidInput`). All of these are checked before any store access. Any other failure is `INTERNAL` (`ServiceFailure`). console-api answers an explicit `MaxItems=0` as `ValidationError` itself, since 0 means unset here.
- Pages: the marker continues after the last returned entry (users, then groups, then roles, then policies, each by case-folded name), so a change between pages does not shift the listing. The call only reads, so a retry is safe.
- Authorization (`iam:GetAccountAuthorizationDetails`) is console-api's.

## Account summary (#138)

- `AccountService.GetAccountSummary` is AWS `GetAccountSummary`. `parent` is `projects/{project}`. It returns the project's entity usage and enforced quotas as `summary_map` (AWS `SummaryMap`). A key absent from the map is not reported and must not be filled with 0 (popododo0720/vws-iam#268). It is a read RPC, not an operation.
- Keys returned today: `Users`, `Groups`, `Roles`, `Policies`, `InstanceProfiles`, `MFADevices`, `MFADevicesInUse`, `AccountAccessKeysPresent`, and the enforced quotas `AccessKeysPerUserQuota`, `AttachedPoliciesPerGroupQuota`, `AttachedPoliciesPerRoleQuota`, `AttachedPoliciesPerUserQuota`, `GroupPolicySizeQuota`, `GroupsPerUserQuota`, `PolicySizeQuota`, `RolePolicySizeQuota`, `UserPolicySizeQuota`, `VersionsPerPolicyQuota`.
- Errors: a bad `parent` is `INVALID_ARGUMENT / INVALID_SPEC` (`ValidationError`) before any store access. Any other failure is `INTERNAL` (`ServiceFailure`). The call only reads, so a retry is safe.
- Authorization (`iam:GetAccountSummary`) is console-api's.

## Account password policy (#136)

- `AccountService.GetAccountPasswordPolicy` is AWS `GetAccountPasswordPolicy`. `parent` is `projects/{project}`. It returns the project's custom `PasswordPolicy`. `max_password_age` (1-1095 days) and `password_reuse_prevention` (1-24) are optional: they are unset when AWS would omit them (passwords never expire, or no reuse check). `expire_passwords` is true exactly when `max_password_age` is set and greater than 0. `minimum_password_length` is 6-128. It is a read RPC, not an operation.
- Errors: a bad `parent` is `INVALID_ARGUMENT / INVALID_SPEC` (`ValidationError`) before any store access. An account without a custom policy is `NOT_FOUND / RESOURCE_NOT_FOUND` (`NoSuchEntity`, `The Password Policy with domain name <project> cannot be found.`). Any other failure is `INTERNAL` (`ServiceFailure`). The call only reads, so a retry is safe.
- Authorization (`iam:GetAccountPasswordPolicy`) is console-api's.

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

## Assume role with web identity (#105)

- `TokenService.AssumeRoleWithWebIdentity` is AWS STS `AssumeRoleWithWebIdentity`. It issues credentials for `role_arn` from an OIDC ID token (a JWT). The session is `arn:vws:sts::{project}:assumed-role/{role}/{role_session_name}`, with `assumed_role_id` `{role id}:{role_session_name}`. vws-iam seals the session into the token and stores nothing.
- It has no `authentication` oneof and takes no caller credential. vws-iam verifies the token signature (RS256, RS384, RS512, ES256, ES384 or ES512) against the JWKS of the OIDC provider for the token's `iss` in the role's project, and the token's `aud` must be in that provider's client id list. The trust policy must allow `sts:AssumeRoleWithWebIdentity` for the `Federated` provider.
- `provider_id` is for OAuth 2.0 access tokens from `www.amazon.com` or `graph.facebook.com`. VWS accepts only OIDC ID tokens, so a non-empty `provider_id` is refused.
- `duration_seconds` is 900-43200, zero means 3600, and it may not exceed the role's `max_session_duration_seconds`.
- The session's permissions are the role's policies, intersected with the session policies (`policy`, `policy_arns`) when any are given. As for federated users, `Authenticate` carries those session policies in `Principal.session_context`. Session tags, transitive tags and `MinimumSessionTokenSize` are not supported.
- The response's `audience` is the token's `azp`, else its `aud`; `provider` is its `iss`; `subject_from_web_identity_token` is its `sub`; `source_identity` is its `https://aws.amazon.com/source_identity` claim.
- `source_ip` is set by console-api from the connection it observed, never from a client value. Empty means unknown.
- Errors: a bad `role_arn`, `role_session_name`, `web_identity_token` or `provider_id` length or character, `duration_seconds`, a `policy` over 2048 characters or with another character, or more than 10 `policy_arns` is `INVALID_ARGUMENT / INVALID_SPEC` (`ValidationError`). A policy that does not parse, or a `policy_arns` entry that is not a managed policy of the project, is `INVALID_ARGUMENT / INVALID_SPEC` (`MalformedPolicyDocument`). When each passes its own limit, the plaintext of `policy` plus `policy_arns` over 2048 characters in total is `INVALID_ARGUMENT / INVALID_SPEC` (`PackedPolicyTooLarge`). A token that is not a compact JWS, uses another algorithm, has a bad signature, comes from an issuer with no OIDC provider in the project, has no audience in the provider's client id list, has a non-integer `exp`, `nbf` or `iat`, or a future `nbf` or `iat`, or a request with `provider_id`, is `INVALID_ARGUMENT / INVALID_SPEC` (`InvalidIdentityToken`). An expired token is `UNAUTHENTICATED / TOKEN_EXPIRED` (`ExpiredToken`). A JWKS that cannot be fetched is `UNAVAILABLE / RECONCILIATION_FAILED` with `retryable=true` (`IDPCommunicationError`): retry with bounded backoff, as `docs/errors.md` says. An unknown role, or a trust policy that does not allow the call, is `PERMISSION_DENIED / ACCESS_DENIED` (`AccessDenied`). AWS `RegionDisabled` does not occur.
- It is not an operation and stores nothing. A repeat with the same unexpired token issues new credentials, as in AWS. `web_identity_token`, `policy` and `session_context` are never logged.

## Delete service-linked role (#106)

- `RoleService.DeleteServiceLinkedRole` is AWS `DeleteServiceLinkedRole`. It deletes a service-linked role from the store and returns `deletion_task_id`, AWS `DeletionTaskId` (`task/aws-service-role/{service-principal}/{role-name}/{uuid}`, at most 1000 characters).
- It is not an operation. The deletion has completed when the call returns. `GetServiceLinkedRoleDeletionStatus` is a separate request (vws-iam follow-up).
- Errors: a malformed `name` or role id is `INVALID_ARGUMENT / INVALID_SPEC` (`ValidationError`). A role that does not exist, or a role that is not service-linked (created with `CreateRole`), is `NOT_FOUND / RESOURCE_NOT_FOUND` (`NoSuchEntity`).
- Retry: the task id is derived from the role's `uid`, so concurrent or repeated requests for the same role return the same id while it exists. After the role is gone a repeat is `NOT_FOUND` (`NoSuchEntity`). This differs from AWS, where the deletion is asynchronous and a repeat returns the same task id until the deletion completes; VWS deletes synchronously.
- Authorization (`iam:DeleteServiceLinkedRole` on the role ARN) is console-api's, as for the other `RoleService` mutations.

## Create service-linked role (#112)

- `RoleService.CreateServiceLinkedRole` is AWS `CreateServiceLinkedRole`. It creates the role a VWS service uses and returns it in `role`: path `/aws-service-role/{aws_service_name}/`, name `AWSServiceRoleFor{service role name}[_{custom_suffix}]`, and a trust policy for the service principal. vws-iam keeps the table of service principals, their role names and whether they accept a suffix.
- It is not an operation. The role is stored when the call returns.
- Errors: an `aws_service_name`, `custom_suffix` or `description` length or character fault is `INVALID_ARGUMENT / INVALID_SPEC` (`ValidationError`). An unknown service principal, a `custom_suffix` the service does not allow, or a resulting role name over 64 characters is `INVALID_ARGUMENT / INVALID_SPEC` (`InvalidInput`). A role name already taken in the project, compared case folded, is `INVALID_ARGUMENT / INVALID_SPEC` (`InvalidInput`, "Service role name ... has been taken in this account, please try a different suffix."), not `ALREADY_EXISTS`, as in AWS.
- Retry: this is an exception to the shared create rule in `vws/common/v1/operation.proto` (an identical repeat returns the existing resource), decided by #112 for AWS parity. There is no `request_id`, as in AWS. A repeat after a success, a lost response included, is the taken-name `InvalidInput`; the role exists, and `ListRoles` returns it with `spec.path` `/aws-service-role/{aws_service_name}/`. Two concurrent requests for the same name create one role; the other gets the taken-name error. A restart leaves either the stored role or no role.
- Authorization (`iam:CreateServiceLinkedRole`, condition key `iam:AWSServiceName`) is console-api's.

## Console sessions (#254)

- `ConsoleSessionService` (`console_session.proto`) keeps console sign-in sessions in the IAM store, so two console-api instances share them and a restart signs nobody out (design 10.1.3). RPCs: `CreateConsoleSession`, `GetConsoleSession`, `RevokeConsoleSession`, `ListConsoleSessions` (the sessions of one user).
- No message carries a session token. console-api keeps the token in the cookie and sends only its SHA-256 digest (`spec.token_digest`, input only, redacted, never returned). `Login`, `ValidateSession` and `Logout` are unchanged.
- The session id is chosen by console-api, so `CreateConsoleSession` is idempotent by id and `request_id`. Create and revoke are operations returned done. `status.revoke_time` keeps the first revocation.
- Project mappings live in the admin registry, so there is no binding RPC.
- Downstream: vws-iam implements the service and the `IamConsoleSession` kind (vws-iam P3-03); console-api replaces its in-memory sessions. Additive, not breaking.
