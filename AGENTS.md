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
| 참조 | 다른 리소스는 전체 리소스 이름으로 가리킨다. 패키지 간 proto import로 연결하지 않는다 |
| 브랜치 | `main`에 직접 커밋하거나 푸시하지 않는다. 브랜치와 PR로 넣는다 |
| 커밋 | 원자적이다. 한 커밋은 한 목적만 담는다 |
| 고지 | 로고와 상표 고지를 넣지 않는다 |

## 브랜치와 커밋

`main`에서 작업하지 않는다. 브랜치를 만들고, 리뷰는 PR로 받는다.

한 커밋은 한 목적이다. 공통 계약, 도메인 API, CI, 문서를 한 커밋에 섞지 않는다. proto를 건드린 커밋은 그 내용만으로 `buf lint`와 `buf build`가 통과해야 한다.

## pstack 사용

설계와 수정이 아래 중 하나에 걸리면 해당 절차를 쓴다.

| 상황 | 절차 |
| --- | --- |
| 함수 경계를 넘는 설계. 패키지, 서비스, 공통 계약이 함께 바뀐다 | architect |
| 다툼이 있는 설계. 계약에 남을 형태가 둘 이상이고 트레이드오프가 있다 | interrogate |
| 반복 실수. 같은 lint 위반, 봉투 불일치, 멱등 규칙 누락이 다시 나온다 | correct |
