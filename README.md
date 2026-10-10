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

`Address`는 정적 공인 주소다. 연결 대상은 주소 `spec`에만 둔다. 볼륨 연결은 인스턴스 `spec`에만 둔다. 보안 그룹 규칙은 그룹 `spec`의 목록이다.

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

변경 RPC는 operation을 반환한다. 클라이언트는 같은 operation 이름으로 완료를 조회한다. 완료 후 `status.observed.generation`이 `generation`과 같고 `status.observed.state`가 `READY`이면 노드가 spec에 맞춘 것이다. 삭제는 리소스가 사라진 뒤에 끝난다.

같은 `request_id`와 같은 본문을 다시 보내면 처음 operation을 돌려받는다. id가 같고 원하는 상태가 같으면 생성은 성공이다. 본문이 다르면 `ALREADY_EXISTS`다. 상세 규칙은 `vws.common.v1.OperationMetadata`에 있다.

## 재시작

서버는 operation 이름을 돌려주기 전에 spec과 operation을 저장한다. 프로세스가 다시 올라오면 그 기록으로 미완료 operation을 이어 간다. 노드는 `Report*Status`로 관찰 결과를 쓴다. 더 오래된 generation 보고는 무시한다.

## 오류

오류는 `google.rpc.Status`다. `google.rpc.ErrorInfo.domain`은 `vws.dev`이고, `reason`은 `vws.common.v1.ErrorReason` 이름에서 `ERROR_REASON_`를 뺀 값이다. 노드 실패의 추가 상세는 `ReconciliationFailure`다.

## 의존 순서

만들 때는 참조 대상이 먼저다. 지울 때는 반대다.

1. VPC, 버킷, 키 페어, 이미지, 스냅샷
2. 서브넷, 보안 그룹, 볼륨
3. 인스턴스, 오브젝트
4. 주소 연결

부모가 남아 있는 동안 서브넷, 보안 그룹, 오브젝트가 있으면 부모 삭제는 `DEPENDENCY_MISSING`이다. 각 서비스 주석에 거절 조건이 있다.

## Go 모듈

레포 루트가 Go 모듈 `github.com/popododo0720/vws-proto`다. 생성 코드는 `gen/go`에 커밋되어 있다. 태그는 `v0.1.0`처럼 접두사 없이 붙인다. `gen/go/v0.1.0`이 아니다.

```sh
go env -w GOPRIVATE=github.com/popododo0720/*
go get github.com/popododo0720/vws-proto@v0.1.0
```

이 레포는 비공개다. `GOPRIVATE`는 모듈 프록시와 체크섬 DB를 건너뛴다. git이 GitHub에 인증할 수 있어야 한다. Go 1.26 이상이 필요하다. `go get`은 호출하는 모듈의 `go` 줄을 `1.26.0`으로 올린다.

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
buf generate
go mod tidy
git add --intent-to-add --all
git diff --exit-code
```

GitHub Actions가 pull request와 `main` push에서 `buf lint`, `buf build`를 실행한다. base에 proto가 있을 때만 `buf breaking`을 실행한다. `go` 잡은 `go_package`가 파일 경로와 같은지, `gen/go`와 `go.mod`와 `go.sum`이 최신인지, `go build ./...`가 통과하는지를 본다.
