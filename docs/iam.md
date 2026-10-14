# IAM (vws.iam.v1)

vws-iam 서비스의 계약이다. 설계는 vws-iam#1, 이 API는 vws-proto#24다. 구현은 vws-iam 레포다.

## 리소스와 이름

- 프로젝트가 AWS 계정이다. ARN은 `arn:vws:iam::{project}:user{path}{user}` 꼴이고 STS는 `arn:vws:sts::{project}:assumed-role/{role}/{session}`이다.
- 사용자, 그룹, 역할, 관리형 정책(+버전), 액세스 키, MFA 기기가 리소스다. 이름은 IamName이다(`docs/validation.md`).
- 정책 연결은 별도 RPC가 아니라 `spec.attached_policies`(관리형)와 `spec.inline_policies`(인라인)를 `Update*`로 바꾼다. 그룹 멤버십은 `Group.spec.members`다. AWS Query API(`AttachUserPolicy`, `AddUserToGroup` 등)는 console-api가 etag와 함께 이 Update로 옮긴다.

## 오퍼레이션

노드가 맞추는 상태가 없어서 서버는 리소스와 status(`observed` READY, 같은 generation)를 한 번에 저장하고 끝난 operation을 돌려준다. 결정(vws-proto#24 리뷰): AWS 이름 문법, 비밀 RPC의 비 operation, IAM operation 즉시 READY, 프로젝트 = 계정 ARN. 비밀이 응답에 실리는 `CreateAccessKey`, `CreateVirtualMfaDevice`와 비밀번호를 받는 `SetLoginProfile`, `ChangePassword`는 operation이 아니다(operation 기록에 비밀이 남지 않게). 이 넷이 이 레포의 AIP-151 규칙의 예외다.

## 인증과 인가 (AuthService, TokenService)

| RPC | 쓰는 쪽 | 하는 일 |
| --- | --- | --- |
| `Authenticate` | console-api sigv4 검증 | `access_key_id`, `date`, `region`, `service`, `canonical_request`, `string_to_sign`, `signature`, `session_token`(console-api `sigv4.AuthRequest`와 같다) -> `account`, `arn`, `is_root`(+ MFA, 세션 정보를 담은 `principal`). 비밀은 vws-iam 밖으로 나가지 않는다 |
| `Authorize` | console-api 모든 핸들러, 다른 서비스 | 주체, 액션, 리소스 ARN, 조건 키 -> ALLOW / DENY_EXPLICIT / DENY_IMPLICIT |
| `Login`, `ValidateSession`, `Logout` | console-api 콘솔 로그인(vws-console-api#95) | 비밀번호(+TOTP) -> HttpOnly 쿠키용 세션 토큰 |
| `AssumeRole`, `GetSessionToken` | console-api STS Query API | 임시 자격 증명(`ASIA…`, 비밀, 세션 토큰, 만료) |

AuthService와 TokenService는 클러스터 안 전용이다. 차트의 NetworkPolicy가 console-api만 들인다(vws-deploy#243).

## 정책 평가 (Phase 1)

- 명시적 Deny > Allow > 암묵적 거부. 신원 정책(사용자, 그룹들, 역할)과 역할 신뢰 정책.
- `Action`/`NotAction`, `Resource`/`NotResource`, `*`와 `?` 와일드카드.
- 조건: `StringEquals`, `StringNotEquals`, `StringLike`, `StringNotLike`, `ArnLike`, `ArnEquals`, `Bool`(`aws:MultiFactorAuthPresent`, `aws:SecureTransport`), `IpAddress`/`NotIpAddress`(`aws:SourceIp`), `DateLessThan`/`DateGreaterThan`(`aws:CurrentTime`), `NumericLessThan`(`aws:MultiFactorAuthAge`), `aws:RequestedRegion`. `...IfExists`와 `ForAnyValue:`/`ForAllValues:`는 Phase 1에 없다.
- 없음: 역할 신뢰 정책 외 리소스 정책(S3 버킷 정책은 후속), SCP, 권한 경계, 세션 정책.
- `aws:MultiFactorAuthPresent`, `aws:PrincipalArn`, `aws:username`은 서버가 채우고 요청 값은 무시한다.

## 오류

`vws.common.v1.ErrorReason`에 IAM 이유를 더했다. `UNAUTHENTICATED`: `INVALID_CREDENTIALS`, `MFA_REQUIRED`, `TOKEN_EXPIRED`. `PERMISSION_DENIED`: `ACCESS_DENIED`(예: AssumeRole 신뢰 정책 거부). `Authorize`의 거부는 오류가 아니라 응답의 `decision`이다. 한도(키 2개, 정책 버전 5개, 연결 정책 10개)는 `RESOURCE_EXHAUSTED / QUOTA_EXCEEDED`, 지울 수 없는 상태(AWS DeleteConflict)는 `FAILED_PRECONDITION / DEPENDENCY_MISSING`.

## Phase 1에 없는 것

- 사용자 이름 바꾸기(AWS `UpdateUser`의 `NewUserName`). 이름이 리소스 id다.
- 태그(`TagUser` 등). `labels`로 대체할지는 정하지 않았다.
- 세션 정책(AssumeRole `Policy`/`PolicyArns`).
- 조건 `...IfExists`, `ForAnyValue:`, `ForAllValues:`.
- `SimulatePrincipalPolicy`, `SimulateCustomPolicy`.
- 역방향 조회 목록(`ListAttachedUserPolicies`, `ListGroupsForUser`, `ListEntitiesForPolicy` 등). console-api가 spec과 status(`User.status.groups`)에서 만든다.

## 확인 필요

- 서버가 이 규칙을 실제로 지키는지는 vws-iam 레포에서 확인한다.

## STS 호출자와 비밀 필드 (#28)

- `AssumeRole`, `GetSessionToken`은 요청의 `caller`를 믿지 않는다. 이 필드는 deprecated이고 서버는 무시한다. 클라이언트가 보낸 principal을 믿으면 이 서비스에 닿는 누구나 아무 principal로 행세할 수 있다(사칭). 서버는 `authentication` oneof(`sigv4` 또는 `console_session_token`)를 직접 검증하고 호출자를 그것에서 얻는다. 없으면 `UNAUTHENTICATED / INVALID_CREDENTIALS`다.
- `caller` 필드를 지우는 것은 `buf breaking`(FILE)이 막으므로 v0.2.0과 호환되게 deprecated로 남긴다. 실제로 지우고 번호를 `reserved`로 돌리는 것은 다음 breaking 릴리스에서 한다.
- `AuthService`와 `TokenService`는 클러스터 내부 전용이라 `google.api.http` 경로가 없다(gRPC만).
- 비밀 필드(secret access key, session token, 비밀번호, TOTP 코드, MFA seed와 otpauth URI)는 `OUTPUT_ONLY` 또는 `INPUT_ONLY`이고 `debug_redact = true`라 protobuf 텍스트/디버그 출력에서 가려진다. 로그에 남기지 않는다.

## MFA 장치 잠금 상태 (#32)

- `MfaDeviceStatus.failed_attempts`(5)는 마지막 성공이나 잠금 뒤 틀린 코드 수다. 5번 틀리면 장치가 15분 잠긴다.
- `MfaDeviceStatus.locked_until`(6)은 잠긴 동안만 채워진다. 그때까지는 맞는 코드도 거부된다.
- 둘 다 status 안의 출력 전용 필드다. seed와 코드는 싣지 않는다.

## 세션 폐기 (#31)

- `UserService.RevokeUserSessions`, `RoleService.RevokeRoleSessions`는 AWS 콘솔의 "Revoke active sessions"다. 그 시점 전에 발급된 STS 세션(사용자는 `GetSessionToken`, 역할은 `AssumeRole`)을 거부하게 한다. 뒤에 발급된 자격 증명은 영향이 없다.
- 원하는 상태를 바꾸는 변경이라 operation을 돌려주고 `request_id`로 멱등이다. 비밀이 오가지 않으므로 operation 예외가 아니다. 응답은 `status.sessions_revoke_time`이 채워진 User/Role이다.
- 권한은 대상 ARN에 대한 `iam:RevokeUserSessions` / `iam:RevokeRoleSessions`다.
