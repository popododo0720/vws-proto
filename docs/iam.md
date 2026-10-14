# IAM (vws.iam.v1)

vws-iam 서비스의 계약이다. 설계는 vws-iam#1, 이 API는 vws-proto#24다. 구현은 vws-iam 레포다.

## 리소스와 이름

- 프로젝트가 AWS 계정이다. ARN은 `arn:vws:iam::{project}:user{path}{user}` 꼴이고 STS는 `arn:vws:sts::{project}:assumed-role/{role}/{session}`이다.
- 사용자, 그룹, 역할, 관리형 정책(+버전), 액세스 키, MFA 기기가 리소스다. 이름은 IamName이다(`docs/validation.md`).
- 정책 연결은 별도 RPC가 아니라 `spec.attached_policies`(관리형)와 `spec.inline_policies`(인라인)를 `Update*`로 바꾼다. 그룹 멤버십은 `Group.spec.members`다. AWS Query API(`AttachUserPolicy`, `AddUserToGroup` 등)는 console-api가 etag와 함께 이 Update로 옮긴다.

## 오퍼레이션

노드가 맞추는 상태가 없어서 서버는 리소스와 status(`observed` READY, 같은 generation)를 한 번에 저장하고 끝난 operation을 돌려준다. 비밀이 응답에 실리는 `CreateAccessKey`, `CreateVirtualMfaDevice`와 비밀번호를 받는 `SetLoginProfile`, `ChangePassword`는 operation이 아니다(operation 기록에 비밀이 남지 않게). 이 넷이 이 레포의 AIP-151 규칙의 예외다.

## 인증과 인가 (AuthService, TokenService)

| RPC | 쓰는 쪽 | 하는 일 |
| --- | --- | --- |
| `GetSigningCredential` | console-api sigv4 `Lookup` | 액세스 키 id(+임시 키의 세션 토큰) -> 주체와 비밀. 짧은 캐시(`cache_until`) |
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

## 확인 필요

- 서버가 이 규칙을 실제로 지키는지는 vws-iam 레포에서 확인한다.
- AWS `UpdateUser`의 이름 바꾸기, 태그(`labels`로 대체 여부), `ListAttachedUserPolicies` 같은 역방향 조회는 Phase 1 계약에 없다.
