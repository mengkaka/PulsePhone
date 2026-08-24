package direct

import (
	"bytes"
	"testing"
)

func TestDecodePlistXMLDataIgnoresFormattingWhitespace(t *testing.T) {
	value, err := decodePlist([]byte(`<?xml version="1.0"?><plist><dict><key>Payload</key><data> AQI=
 </data></dict></plist>`))
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(value["Payload"].([]byte), []byte{1, 2}) {
		t.Fatalf("payload = %#v", value["Payload"])
	}
}

func TestDecodePlistBinaryDictionary(t *testing.T) {
	// bplist00 {"Foo": <data 01 02>} with one-byte offsets/references.
	fixture := []byte{
		'b', 'p', 'l', 'i', 's', 't', '0', '0',
		0xd1, 0x01, 0x02,
		0x53, 'F', 'o', 'o',
		0x42, 0x01, 0x02,
		0x08, 0x0b, 0x0f,
		0, 0, 0, 0, 0, 0, 1, 1,
		0, 0, 0, 0, 0, 0, 0, 3,
		0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 18,
	}
	value, err := decodePlist(fixture)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(value["Foo"].([]byte), []byte{1, 2}) {
		t.Fatalf("value = %#v", value["Foo"])
	}
}

func TestDecodePlistBinaryIntegerMarkerUsesPowerOfTwoSize(t *testing.T) {
	// bplist00 [0x10 0x2a] with one-byte offsets/references.
	fixture := []byte{
		'b', 'p', 'l', 'i', 's', 't', '0', '0',
		0xa1, 0x01,
		0x10, 0x2a,
		0x08, 0x0a,
		0, 0, 0, 0, 0, 0, 1, 1,
		0, 0, 0, 0, 0, 0, 0, 2,
		0, 0, 0, 0, 0, 0, 0, 0,
		0, 0, 0, 0, 0, 0, 0, 12,
	}
	value, err := decodePlistValue(fixture)
	if err != nil {
		t.Fatal(err)
	}
	array, ok := value.([]any)
	if !ok || len(array) != 1 || array[0] != int64(42) {
		t.Fatalf("value = %#v", value)
	}
}

func TestPlistDocumentRoundTripsArrayRoot(t *testing.T) {
	encoded, err := encodePlistDocument([]any{"DLMessageVersionExchange", int64(2), true})
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := decodePlistValue(encoded)
	if err != nil {
		t.Fatal(err)
	}
	array, ok := decoded.([]any)
	if !ok || len(array) != 3 || array[0] != "DLMessageVersionExchange" || array[1] != int64(2) || array[2] != true {
		t.Fatalf("decoded = %#v", decoded)
	}
}
