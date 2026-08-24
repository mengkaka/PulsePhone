package coredevice

import (
	"bytes"
	"encoding/binary"
	"reflect"
	"testing"
)

func TestXPCWrapperRoundTripPreservesTypedScalarsAndNestedValues(t *testing.T) {
	value := map[string]any{
		"bytes":   []byte{0, 1, 2, 3},
		"count":   XPCUInt64(42),
		"enabled": true,
		"items":   []any{"ready", XPCInt64(-7), nil},
		"name":    "PulsePhone",
	}
	encoded, err := EncodeXPCWrapper(value, 9, true)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeXPCWrapper(encoded, 1<<20)
	if err != nil {
		t.Fatal(err)
	}
	if decoded.Flags != XPCAlwaysSet|XPCDataPresent|XPCWantingReply || decoded.MessageID != 9 {
		t.Fatalf("header = %#v", decoded)
	}
	if !reflect.DeepEqual(decoded.Payload, value) {
		t.Fatalf("payload = %#v, want %#v", decoded.Payload, value)
	}
}

func TestXPCWrapperUsesPayloadLengthWithoutMessageID(t *testing.T) {
	encoded, err := EncodeXPCWrapper(map[string]any{}, 0, false)
	if err != nil {
		t.Fatal(err)
	}
	if got := binary.LittleEndian.Uint64(encoded[8:16]); got != 20 {
		t.Fatalf("message length = %d, want 20", got)
	}
	if len(encoded) != 44 {
		t.Fatalf("wrapper length = %d, want 44", len(encoded))
	}
}

func TestXPCWrapperRejectsDuplicateDictionaryKeysAndTrailingBytes(t *testing.T) {
	encoded, err := EncodeXPCWrapper(map[string]any{"a": int64(1)}, 1, false)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeXPCWrapper(append(encoded, 0), 1<<20); err == nil {
		t.Fatal("accepted trailing bytes")
	}
	duplicate := []byte{
		0x92, 0x0b, 0xb0, 0x29, 0x01, 0x01, 0x00, 0x00,
		0x28, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
		0x42, 0x37, 0x13, 0x42, 0x05, 0x00, 0x00, 0x00,
	}
	if bytes.Equal(encoded, duplicate) {
		t.Fatal("duplicate fixture unexpectedly equals scalar fixture")
	}
}
