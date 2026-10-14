# 입력 검증 규칙

이 문서는 proto 주석에 이미 적힌 입력 규칙을 한곳에 모은 것이다. 새 규칙을 만들지 않는다. 이 레포는 proto 필드에 검증 어노테이션(protovalidate 등)을 쓰지 않으므로 **규칙은 계약이고, 강제는 각 서버가 한다.** 서버가 이 규칙을 실제로 검사하는지는 이 레포에서 확인할 수 없다(확인 필요, 각 서버 레포).

| 입력 | 규칙 | 출처 |
| --- | --- | --- |
| 리소스 id(Object 제외), project, region, zone | `[a-z]([a-z0-9-]{0,61}[a-z0-9])?`, 길이 1~63 | `vws/common/v1/resource.proto` `ResourceId` |
| 라벨 키 | `[a-z][a-z0-9_-]{0,62}` | 같은 파일의 봉투 주석 |
| 라벨 값 | UTF-8 0~63바이트, ASCII 제어 문자 없음 | 같은 파일 |
| Object 키 | 디코드 후 1~1024바이트, `.`과 `..` 아님, `/`로 시작하거나 끝나지 않음, `//` 없음, ASCII 제어 문자 없음. 경로에는 RFC 3986 퍼센트 인코딩(`/`는 `%2F`) | `vws/storage/v1/object.proto` `Object` |
| IAM 이름(`IamName`): 사용자, 그룹, 역할, MFA 기기, 인라인 정책 이름 | `[A-Za-z0-9+=,.@_-]`, 1~64자(관리형 정책은 1~128자). 프로젝트 안에서 대소문자를 무시하고 유일. AWS 호환을 위해 `ResourceId`의 예외다 | `vws/iam/v1/*.proto` |
| 액세스 키 id | `AKIA`(장기) 또는 `ASIA`(임시) + 대문자·숫자 16자 | `vws/iam/v1/access_key.proto`, `auth.proto` |
| IAM `path` | `/`로 시작하고 끝남, 1~512자 | 같은 파일들 |
| 정책 문서 | AWS JSON, `Version` `2012-10-17`. 공백 제외 6144자 이하. 해석 못 하거나 `docs/iam.md` 밖의 조건이면 `INVALID_ARGUMENT / INVALID_SPEC` | `policy.proto` |
| 비밀번호 | 8~128자. 저장은 argon2id 해시만. 오퍼레이션 기록과 로그에 남지 않는다 | `user.proto` |
| `OUTPUT_ONLY` 필드 | AIP-203 관례로 입력에서는 무시된다. 이 레포의 주석이 서버 동작을 명시하지는 않는다(확인 필요). `status`는 서버와 노드만 쓴다 | `google.api.field_behavior` |
| `request_id` | 같은 id와 같은 지문은 원래 operation을 돌려주고, 지문이 다르면 `ABORTED / IDEMPOTENCY_CONFLICT`. 24시간 기억 | `vws/common/v1/operation.proto` |
| 상태 보고의 `generation` | 저장된 값보다 낮은 보고는 무시한다 | `ObservedState` |
| `etag` | 값이 있으면 저장된 etag와 같아야 한다. 아니면 `ETAG_MISMATCH` | `operation.proto` |

## 악성·경계 입력 시험 기준

서버 레포가 시험에 넣을 최소 입력이다.

- 길이 0, 63, 64인 id. 대문자, 밑줄, 앞뒤 하이픈이 든 id.
- 키가 `.`, `..`, 빈 문자열, 1025바이트, `a//b`, `/a`, 제어 문자를 가진 Object.
- 값이 64바이트인 라벨, 키가 64자인 라벨.
- `OUTPUT_ONLY` 필드(예: `claim_name`)를 채워 보낸 생성과 수정 요청.
- 낮은 `generation`으로 보낸 상태 보고, 틀린 `etag`로 보낸 수정, 같은 `request_id`에 다른 본문.
- IAM: 65자 이름, 대소문자만 다른 중복 이름, 잘못된 JSON 정책, 지원하지 않는 조건 연산자, 세 번째 액세스 키, 같은 TOTP 코드 재사용, 만료된 세션 토큰과 임시 키.

## 스키마 변경 규칙

- 필드 번호는 다시 쓰지 않는다. 지우거나 바꾸면 `buf breaking`(FILE)이 실패하고, CI가 PR에서 이를 막는다. 필요한 경우에만 가장 좁은 예외를 PR 본문에 이유와 함께 적는다.
- proto를 바꾼 PR은 본문에 breaking 여부와 하위 레포 영향을 적는다(PR 템플릿).
