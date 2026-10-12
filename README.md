# vws-proto

VWS 제어 평면의 공유 gRPC 정의다. 원하는 상태는 여기 정의된 리소스 `spec` 한곳에 저장되고, 노드는 그 `spec`에 실제 상태를 맞춘다.

## 리소스

모든 리소스는 같은 봉투를 쓴다. `name`, `uid`, `generation`, `etag`, `labels`, `spec`, `status`, `create_time`, `update_time`, `delete_time`.

| 서비스 | 리소스 이름 |
| --- | --- |
| `vws.compute.v1.InstanceService` | `projects/{project}/zones/{zone}/instances/{instance}` |
| `vws.compute.v1.ImageService` | `projects/{project}/regions/{region}/images/{image}` |
| `vws.compute.v1.KeyPairService` | `projects/{project}/regions/{region}/keyPairs/{key_pair}` |
| `vws.storage.v1.VolumeService` | `projects/{project}/zones/{zone}/volumes/{volume}` |
| `vws.storage.v1.SnapshotService` | `projects/{project}/regions/{region}/snapshots/{snapshot}` |
| `vws.storage.v1.BucketService` | `projects/{project}/buckets/{bucket}` |
| `vws.storage.v1.ObjectService` | `projects/{project}/buckets/{bucket}/objects/{object}` |
| `vws.network.v1.VpcService` | `projects/{project}/regions/{region}/vpcs/{vpc}` |
| `vws.network.v1.SubnetService` | `projects/{project}/regions/{region}/vpcs/{vpc}/subnets/{subnet}` |
| `vws.network.v1.SecurityGroupService` | `projects/{project}/regions/{region}/vpcs/{vpc}/securityGroups/{security_group}` |
| `vws.network.v1.AddressService` | `projects/{project}/regions/{region}/addresses/{address}` |

`Address`는 정적 공인 주소다. 연결 대상은 주소 `spec.association`에만 둔다. `spec.vpc`는 만들 때 정하는 VPC 할당이다. 비어 있으면 VPC에 묶이지 않는다. 볼륨 연결은 인스턴스 `spec`에만 둔다. 보안 그룹 규칙은 그룹 `spec`의 목록이다. 인스턴스 배치는 쿠버네티스 스케줄러가 하고 이 계약에는 노드 개념이 없다.

Object의 `{object}`만 퍼센트 인코딩된 키다. 나머지 id는 `vws.common.v1.ResourceId` 문법이다.

## 클라이언트

Terraform과 Ansible은 리소스마다 같은 호출을 쓴다.

| 동작 | RPC |
| --- | --- |
| 읽기 | `Get*` |
| 목록 | `List*` |
| 만들기 | `Create*` |
| 맞추기 | `Update*`. 없으면 만들려면 `allow_missing` |
| 없애기 | `Delete*`. 이미 없으면 `allow_missing` |
| 미리 검사 | `validate_only` |
| 오브젝트 본문 쓰기 | `WriteObject`. 상한은 4194304바이트. 만들 때는 `CreateObject` |
| 오브젝트 본문 읽기 | `ReadObject`. `GetObject`는 메타데이터만 반환한다 |
| 인스턴스 상태 보고 | `ReportInstanceStatus` |

`Object.etag`는 동시성 토큰이다. 본문 다이제스트는 `spec.sha256`와 `status.md5`다. 키 페어 `status.fingerprint_sha256`는 서버가 공개 키에서 계산한 소문자 hex다. `CreateKeyPair`와 `GetKeyPair`가 같은 필드를 돌려준다.

변경 RPC는 operation을 반환한다. 클라이언트는 같은 operation 이름으로 완료를 조회한다. 완료 후 `status.observed.generation`이 `generation`과 같고 `status.observed.state`가 `READY`이면 노드가 spec에 맞춘 것이다. 삭제는 리소스가 사라진 뒤에 끝난다.

같은 `request_id`와 같은 본문을 다시 보내면 처음 operation을 돌려받는다. id가 같고 원하는 상태가 같으면 생성은 성공이다. 본문이 다르면 `ALREADY_EXISTS`다. 상세 규칙은 `vws.common.v1.OperationMetadata`에 있다.

## 재시작

서버는 operation 이름을 돌려주기 전에 spec과 operation을 저장한다. 프로세스가 다시 올라오면 그 기록으로 미완료 operation을 이어 간다. 노드는 `Report*Status`로 관찰 결과를 쓴다. 더 오래된 generation 보고는 무시한다.

## 오류

오류는 `google.rpc.Status`다. `google.rpc.ErrorInfo.domain`은 `vws.dev`이고, `reason`은 `vws.common.v1.ErrorReason` 이름에서 `ERROR_REASON_`를 뺀 값이다. 노드 실패의 추가 상세는 `ReconciliationFailure`다.

## 의존 순서

만들 때는 참조 대상이 먼저다. 지울 때는 반대다.

1. VPC, 버킷, 키 페어, 이미지, 스냅샷, 노드
2. 서브넷, 보안 그룹, 볼륨
3. 인스턴스, 오브젝트
4. 주소 연결

부모가 남아 있는 동안 서브넷, 보안 그룹, 오브젝트가 있으면 부모 삭제는 `DEPENDENCY_MISSING`이다. `spec.vpc`가 VPC를 가리키는 주소가 있어도 VPC 삭제는 거절된다. 각 서비스 주석에 거절 조건이 있다.

## Go 모듈

레포 루트가 Go 모듈 `github.com/popododo0720/vws-proto`다. 생성 코드는 `gen/go`에 커밋되어 있다. 태그는 `v0.1.0`처럼 접두사 없이 붙인다. `gen/go/v0.1.0`이 아니다.

```sh
go get github.com/popododo0720/vws-proto@v0.1.0
```

이 레포는 비공개다. `GOPRIVATE`에 `github.com/popododo0720/*`를 넣는다. 이미 값이 있으면 쉼표로 잇는다. `go env -w`로 통째로 바꾸면 기존 값이 사라진다. 이 설정은 모듈 프록시와 체크섬 DB를 건너뛴다. git이 GitHub에 인증할 수 있어야 한다. Go 1.26 이상이 필요하다. `go get`은 호출하는 모듈의 `go` 줄을 `1.26.0`으로 올린다.

다른 레포의 GitHub Actions에서 기본 `GITHUB_TOKEN`은 그 레포만 읽는다. 그 잡은 `GOPRIVATE=github.com/popododo0720/*`를 설정하고, 이 레포의 `contents`를 읽을 수 있는 자격 증명으로 `https://github.com/popododo0720/vws-proto`를 받게 한다.

| proto 패키지 | Go import 경로 | Go 패키지 |
| --- | --- | --- |
| `vws.common.v1` | `github.com/popododo0720/vws-proto/gen/go/vws/common/v1` | `commonv1` |
| `vws.compute.v1` | `github.com/popododo0720/vws-proto/gen/go/vws/compute/v1` | `computev1` |
| `vws.storage.v1` | `github.com/popododo0720/vws-proto/gen/go/vws/storage/v1` | `storagev1` |
| `vws.network.v1` | `github.com/popododo0720/vws-proto/gen/go/vws/network/v1` | `networkv1` |

변경 RPC가 돌려주는 `google.longrunning.Operation`은 `cloud.google.com/go/longrunning/autogen/longrunningpb`의 `Operation`이다.

## 생성

proto를 바꾼 커밋에 생성 결과를 같이 넣는다. `gen/go`는 손으로 고치지 않는다. `buf generate`가 그 디렉터리를 지우고 다시 만든다.

```sh
buf generate
go mod tidy
```

`option go_package`는 `github.com/popododo0720/vws-proto/gen/go/<proto 디렉터리>;<도메인><버전>`이다. `vws/compute/v1`의 패키지 이름은 `computev1`이다.

## 검사

```sh
buf lint
buf build
scripts/check-generated-go.sh
go build ./...
```

`scripts/check-generated-go.sh`는 `go_package`가 파일 경로와 같은지 보고, `buf generate`와 `go mod tidy` 뒤에 `gen`, `go.mod`, `go.sum`의 diff가 없는지 본다. 인덱스를 바꾸지 않는다. 추적되지 않은 `gen` 파일도 실패다.

GitHub Actions가 pull request와 `main` push에서 `buf lint`, `buf build`를 실행한다. base에 proto가 있을 때만 `buf breaking`을 실행한다. `go` 잡은 같은 스크립트와 `go build ./...`를 실행한다.
