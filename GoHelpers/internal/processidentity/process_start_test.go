package processidentity

import (
	"encoding/binary"
	"regexp"
	"testing"
)

func TestDecodeStartIdentity(t *testing.T) {
	info := make([]byte, procBSDInfoSize)
	binary.LittleEndian.PutUint64(info[startSecondsOffset:startSecondsOffset+8], 1_234_567_890)
	binary.LittleEndian.PutUint64(info[startMicrosOffset:startMicrosOffset+8], 42)
	identity, err := decodeStartIdentity(info)
	if err != nil {
		t.Fatal(err)
	}
	if identity != "1234567890.000042" {
		t.Fatalf("identity = %q", identity)
	}
	binary.LittleEndian.PutUint64(info[startMicrosOffset:startMicrosOffset+8], 1_000_000)
	if _, err := decodeStartIdentity(info); err == nil {
		t.Fatal("out-of-range microseconds accepted")
	}
}

func TestCurrentProcessStartIdentityHasWireShape(t *testing.T) {
	identity, err := CurrentProcessStartIdentity()
	if err != nil {
		t.Fatal(err)
	}
	if !regexp.MustCompile(`^[0-9]+\.[0-9]{6}$`).MatchString(identity) {
		t.Fatalf("identity = %q", identity)
	}
}
