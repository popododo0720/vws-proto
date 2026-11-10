package tests

import (
	computev1 "github.com/popododo0720/vws-proto/gen/go/vws/compute/v1"
	"google.golang.org/protobuf/proto"
	"google.golang.org/protobuf/reflect/protoreflect"
	"testing"
)

func TestComputeClientFingerprintWireRoundTrip(t *testing.T) {
	requests := []proto.Message{
		&computev1.CreateInstanceRequest{}, &computev1.UpdateInstanceRequest{}, &computev1.DeleteInstanceRequest{}, &computev1.RebootInstanceRequest{},
		&computev1.CreateImageRequest{}, &computev1.UpdateImageRequest{}, &computev1.DeleteImageRequest{},
		&computev1.CreateKeyPairRequest{}, &computev1.UpdateKeyPairRequest{}, &computev1.DeleteKeyPairRequest{},
	}
	for _, msg := range requests {
		t.Run(string(msg.ProtoReflect().Descriptor().Name()), func(t *testing.T) {
			field := msg.ProtoReflect().Descriptor().Fields().ByName("client_fingerprint")
			if field == nil || field.Kind() != protoreflect.StringKind {
				t.Fatal("missing opaque string fingerprint")
			}
			if msg.ProtoReflect().Get(field).String() != "" {
				t.Fatal("legacy request has nonempty default")
			}
			for _, value := range []string{"", "sha256:0123456789abcdef", string(make([]byte, 256))} {
				msg.ProtoReflect().Set(field, protoreflect.ValueOfString(value))
				wire, err := proto.Marshal(msg)
				if err != nil {
					t.Fatal(err)
				}
				restored := msg.ProtoReflect().New().Interface()
				if err := proto.Unmarshal(wire, restored); err != nil {
					t.Fatal(err)
				}
				if restored.ProtoReflect().Get(field).String() != value {
					t.Fatal("fingerprint changed on round trip")
				}
			}
		})
	}
}

func TestComputeLookupFingerprintMatchesNetworkShape(t *testing.T) {
	msg := &computev1.LookupOperationResponse{RequestFingerprint: "original-parameters"}
	field := msg.ProtoReflect().Descriptor().Fields().ByName("request_fingerprint")
	if field.Number() != 2 || field.Kind() != protoreflect.StringKind {
		t.Fatal("lookup differs from network string field 2")
	}
	wire, err := proto.Marshal(msg)
	if err != nil {
		t.Fatal(err)
	}
	restored := &computev1.LookupOperationResponse{}
	if err := proto.Unmarshal(wire, restored); err != nil {
		t.Fatal(err)
	}
	if restored.GetRequestFingerprint() != msg.GetRequestFingerprint() {
		t.Fatal("lookup lost original fingerprint")
	}
}
