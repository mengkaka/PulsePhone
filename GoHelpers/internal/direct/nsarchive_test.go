package direct

import (
	"bytes"
	"encoding/base64"
	"reflect"
	"testing"
)

func TestNSKeyedArchiveRoundTrip(t *testing.T) {
	values := []any{
		"runningProcesses",
		map[string]any{"KillExisting": true, "StartSuspendedKey": false},
		[]any{"", "com.apple.Preferences", map[string]any{}, []any{}, map[string]any{"foo": "bar"}},
	}
	for _, input := range values {
		encoded, err := encodeNSKeyedArchive(input)
		if err != nil {
			t.Fatalf("encode %#v: %v", input, err)
		}
		decoded, err := decodeNSKeyedArchive(encoded)
		if err != nil {
			t.Fatalf("decode %#v: %v", input, err)
		}
		if !reflect.DeepEqual(decoded, input) {
			t.Fatalf("round trip %#v -> %#v", input, decoded)
		}
	}
}

func TestNSKeyedArchiveDecodesPythonGolden(t *testing.T) {
	encoded, err := base64.StdEncoding.DecodeString("YnBsaXN0MDDUAQIDBAUGHB9ZJGFyY2hpdmVyWCRvYmplY3RzVCR0b3BYJHZlcnNpb25fEA9OU0tleWVkQXJjaGl2ZXKnBwgTGBkaG1UkbnVsbNMJCgsMDRBWJGNsYXNzV05TLmtleXNaTlMub2JqZWN0c4ACog4PgAOABaIREoAEgAbSFBUWF1gkY2xhc3Nlc1okY2xhc3NuYW1loRdcTlNEaWN0aW9uYXJ5XEtpbGxFeGlzdGluZwlfEBFTdGFydFN1c3BlbmRlZEtleQjRHR5Ucm9vdIABEgABhqAIERskKTJETFJZYGhzdXh6fH+Bg4iRnJ6ruLnNztHW2AAAAAAAAAEBAAAAAAAAACAAAAAAAAAAAAAAAAAAAADd")
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := decodeNSKeyedArchive(encoded)
	if err != nil {
		t.Fatal(err)
	}
	expected := map[string]any{"KillExisting": true, "StartSuspendedKey": false}
	if !reflect.DeepEqual(decoded, expected) {
		t.Fatalf("decoded = %#v", decoded)
	}
	if bytes.HasPrefix(encoded, []byte("<?xml")) {
		t.Fatal("archive must use binary plist")
	}
}
