package protocol

import (
	"bytes"
	"testing"
)

func TestCanonicalDocumentBoundaries(t *testing.T) {
	tests := []struct {
		name  string
		input string
		kind  string
	}{
		{"duplicate", `{"a":1,"a":2}`, "duplicateKey"},
		{"fraction", `{"a":1.0}`, "unsupportedNumber"},
		{"negativeZero", `{"a":-0}`, "negativeZero"},
		{"signedOverflow", `{"a":-9223372036854775809}`, "signedOverflow"},
		{"unsignedOverflow", `{"a":18446744073709551616}`, "unsignedOverflow"},
		{"surrogate", `{"a":"\ud800"}`, "invalidUnicodeEscape"},
		{"bom", "\xef\xbb\xbf{}", "bom"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			_, err := ValidateDocument([]byte(test.input), len(test.input))
			if err == nil || !hasKind(err, test.kind) {
				t.Fatalf("error = %v, want %s", err, test.kind)
			}
		})
	}
}

func TestCanonicalUTF8ByteOrderingAndEscaping(t *testing.T) {
	input := []byte(`{"z":"é","a":"line\n","中":"ok"}`)
	document, err := ValidateDocument(input, 1024)
	if err == nil || !hasKind(err, "nonCanonical") {
		t.Fatalf("expected nonCanonical, got %v", err)
	}
	value, err := DecodeJSON([]byte(`{"z":"é","a":"line\n","中":"ok"}`))
	if err != nil {
		t.Fatal(err)
	}
	encoded, err := EncodeValue(value, true)
	if err != nil {
		t.Fatal(err)
	}
	want := []byte(`{"a":"line\n","z":"é","中":"ok"}`)
	if !bytes.Equal(encoded, want) {
		t.Fatalf("encoded = %s, want %s", encoded, want)
	}
	_ = document
}

func TestDecodeWireAllowsNonCanonicalOrderButRejectsNonFinite(t *testing.T) {
	if _, err := DecodeJSON([]byte(`{"b":1,"a":2}`)); err != nil {
		t.Fatal(err)
	}
	if _, err := DecodeJSON([]byte(`{"a":NaN}`)); err == nil {
		t.Fatal("NaN accepted")
	}
	if _, err := DecodeJSON([]byte(`{"a":1e999}`)); err == nil {
		t.Fatal("infinite number accepted")
	}
}

func hasKind(err error, kind string) bool {
	canonical, ok := err.(*CanonicalError)
	return ok && canonical.Kind == kind
}
