# 에이전트 규칙

이 레포는 VWS 제어 평면의 공유 gRPC 정의다. 구현 서버, 배포, 테스트 환경은 여기서 만들지 않는다.

## 규칙표

| 항목 | 규칙 |
| --- | --- |
| 스타일 | Google API 스타일과 AIP. proto3, `Service` 접미사, 표준 메서드 이름 |
| Lint | `buf lint`. 기준은 `STANDARD` |
| Breaking | `buf breaking`. 기준은 `FILE` |
| 패키지 | `vws.<domain>.v1`. 디렉터리와 패키지가 일치한다 |
| 리소스 봉투 | 모든 리소스의 필드 1–10은 `vws/common/v1/resource.proto`의 봉투와 같다 |
| 상태 | `spec`가 원하는 상태다. `status.observed`는 노드가 보고한 상태다 |
| 변경 RPC | `google.longrunning.Operation`을 반환한다. 메타데이터는 `vws.common.v1.OperationMetadata` |
| 조회 RPC | 리소스 메시지를 반환한다 |
| Lint 예외 | `Get*`의 `RPC_RESPONSE_STANDARD_NAME`, 변경 RPC의 `RPC_RESPONSE_STANDARD_NAME`과 `RPC_REQUEST_RESPONSE_UNIQUE`만. AIP-131과 AIP-151 때문이다 |
| 멱등 | 생성, 수정, 삭제, 상태 보고는 `OperationMetadata`에 적힌 규칙으로 다시 실행해도 같은 결과에 닿는다 |
| 재시작 | 원하는 상태와 operation을 응답 전에 저장한다. 프로세스가 다시 뜨면 그 기록으로 맞춘다 |
| 식별자 | Object 키를 제외하면 `ResourceId` 문법. 컬렉션 이름은 AIP-122 camelCase |
| Go 패키지 | `option go_package = "github.com/popododo0720/vws-proto/gen/go/<proto 디렉터리>;<도메인><버전>"`. `vws/compute/v1`은 `computev1`. CI가 파일 경로와 대조한다 |
| 생성 코드 | `buf generate`와 `go mod tidy` 결과(`gen/go`, `go.mod`, `go.sum`)를 proto를 바꾼 커밋에 같이 넣는다. `gen/go`는 손으로 고치지 않는다 |
| 참조 | 다른 리소스는 전체 리소스 이름으로 가리킨다. 패키지 간 proto import로 연결하지 않는다 |
| 브랜치 | `main`에 직접 커밋하거나 푸시하지 않는다. 브랜치와 PR로 넣는다 |
| 커밋 | 원자적이다. 한 커밋은 한 목적만 담는다 |
| 고지 | 로고와 상표 고지를 넣지 않는다 |
| 내부자 위험 | PR은 main을 대상으로 하고 본문에 `Closes #N`이 있다. main에 PR 없이 들어온 커밋은 CI가 알린다. 이 파일은 아래 Insider-risk guardrails 1~7을 갖는다. 검사는 `scripts/guard-agents.sh`, `.github/workflows/repo-guard.yml`, `.github/workflows/direct-push-watch.yml`이 한다 |
| 도구 | Cursor 클라우드 에이전트를 쓰지 않는다. 작업 방식은 아래 poteto-mode 절을 따른다 |

## 브랜치와 커밋

`main`에서 작업하지 않는다. 브랜치를 만들고, 리뷰는 PR로 받는다.

한 커밋은 한 목적이다. 공통 계약, 도메인 API, CI, 문서를 한 커밋에 섞지 않는다. proto를 바꾼 PR의 최종 트리는 `buf lint`와 `buf build`를 통과하고, `gen/go`가 최신이어야 한다. CI가 그 트리를 검사한다.

## 작업 방식 (poteto-mode)

- 간결하게 쓰고 변경은 가장 작게 한다. 지울 수 있으면 지운다.
- 코드를 쓰기 전에 데이터 모양을 먼저 정한다. 같은 실수가 반복되면 문장 대신 lint나 CI 검사로 막는다.
- 실제로 돌린 것만 검증했다고 쓴다. 돌리지 못한 것은 "미검증"으로 표시한다. 이 레포의 검증은 `buf lint`, `buf build`, `scripts/check-generated-go.sh`, `go build ./...`다.
- 커밋 메시지와 PR 설명은 짧은 평서문으로 쓴다. 근거 없는 주장과 만들어낸 링크를 넣지 않는다.
- Cursor 클라우드 에이전트(CloudAgent)를 쓰지 않는다. 사용량이 소진된 상태이고, 작업은 `gh`와 `git`으로 한다.

## pstack 사용

설계와 수정이 아래 중 하나에 걸리면 해당 절차를 쓴다.

| 상황 | 절차 |
| --- | --- |
| 함수 경계를 넘는 설계. 패키지, 서비스, 공통 계약이 함께 바뀐다 | architect |
| 다툼이 있는 설계. 계약에 남을 형태가 둘 이상이고 트레이드오프가 있다 | interrogate |
| 반복 실수. 같은 lint 위반, 봉투 불일치, 멱등 규칙 누락이 다시 나온다 | correct |

## Insider-risk guardrails

봇도 내부자 위험이다. 아래는 예외 없는 규칙이다. 설계는 vws-deploy#33이다.

1. **검증 독립**: 중요 결과(머지, 보안, 데이터)는 작성한 봇/모델이 스스로 검증하지 않는다. 검증은 작성 봇이 아닌 다른 봇(또는 사람)이 한다. (프로세스 규칙, CI로 강제 불가)
2. **기록**: 모든 변경은 이슈 → PR(`Closes #N`) → 커밋으로 남긴다. 작업 로그는 PR 본문/이슈 코멘트에 사람이 읽을 수 있게 쓴다. force-push·히스토리 재작성 금지(사용자 승인 시 예외). 이 레포에서는 proto 변경 PR 본문에 하위 레포(vws-compute, vws-storage, vws-network, vws-deploy) 영향과 breaking 여부를 적는다.
3. **실패 테스트**: 새 기능은 정상 경로만 테스트하지 않는다. 전원 차단/재시작, 멱등 재실행, 악성·경계 입력 케이스를 최소 1개씩 포함하거나 불가 사유를 PR에 적는다. 이 레포에서는 필드 번호를 바꾸거나 지웠을 때 `buf breaking`이 실패하는 것을 PR에서 확인하고, 입력 검증 규칙은 `docs/validation.md`에 적는다.
4. **최소 권한**: main 직접 푸시 금지. 모든 변경은 main에서 딴 독립 브랜치의 단일 PR. 스택 PR 금지. 로컬 머지 금지. 토큰은 해당 레포 범위만. RBAC은 서비스 코드가 실제 호출하는 리소스만, 가능하면 Role(네임스페이스 범위).
5. **감사 분리**: 작성 봇 ≠ 검증 봇 ≠ 머지 판단. 작성 봇은 자기 PR을 머지하지 않는다. 머지는 base==main 이고 head 커밋 CI가 전부 success일 때만.
6. **격리·비상정지**: 봇/에이전트 즉시 중단은 사용자 요청 또는 오케스트레이터가 해당 봇 세션 중단 + 토큰 폐기(`gh auth`/PAT revoke). 위험 작업은 샌드박스(박스/임시 클러스터)에서만. 운영 클러스터 접근 금지.
7. **사고 공개**: 규칙 위반·사고는 숨기지 않고 이슈에 `원인 / 영향 / 조치 / 재발방지`로 기록한다 (라벨 `incident`).

이 레포의 서버측 보호는 없다(private, 무료 플랜). 1, 5, 6은 프로세스 규칙이고, 2와 4의 일부는 `.github/workflows/repo-guard.yml`이 PR의 base와 `Closes #N`을 검사하고 `.github/workflows/direct-push-watch.yml`이 main에 PR 없이 들어온 커밋을 사후에 알린다. 차단이 아니라 탐지다. 복사 방법은 vws-deploy `docs/insider-risk.md`에 있다.
