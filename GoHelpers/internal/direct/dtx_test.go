package direct

import (
	"encoding/binary"
	"net"
	"reflect"
	"testing"
	"time"
)

func TestDTXAuxRoundTrip(t *testing.T) {
	input := []any{dtxInt32(7), map[string]any{"name": "PulsePhone", "enabled": true}, []any{"a", int64(2)}}
	encoded, err := encodeDTXAux(input)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := decodeDTXAux(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(decoded, []any{int32(7), input[1], input[2]}) {
		t.Fatalf("decoded = %#v", decoded)
	}
}

func TestDTXAuxWritesNullKeyForEveryArgument(t *testing.T) {
	encoded, err := encodeDTXAux([]any{dtxInt32(7), dtxInt32(8)})
	if err != nil {
		t.Fatal(err)
	}
	if got, want := binary.LittleEndian.Uint64(encoded[8:16]), uint64(24); got != want {
		t.Fatalf("body length = %d, want %d", got, want)
	}
	want := []byte{
		10, 0, 0, 0, 3, 0, 0, 0, 7, 0, 0, 0,
		10, 0, 0, 0, 3, 0, 0, 0, 8, 0, 0, 0,
	}
	if got := encoded[16:]; !reflect.DeepEqual(got, want) {
		t.Fatalf("aux body = %x, want %x", got, want)
	}
}

func TestDTXAuxRejectsMissingNullKey(t *testing.T) {
	body := []byte{
		10, 0, 0, 0, 3, 0, 0, 0, 7, 0, 0, 0,
		3, 0, 0, 0, 8, 0, 0, 0,
	}
	encoded := make([]byte, 16+len(body))
	binary.LittleEndian.PutUint32(encoded[0:4], 0x1f0)
	binary.LittleEndian.PutUint64(encoded[8:16], uint64(len(body)))
	copy(encoded[16:], body)
	if _, err := decodeDTXAux(encoded); err == nil {
		t.Fatal("decodeDTXAux accepted a second value without a null key")
	}
}

func TestDTXAuxEmptyArguments(t *testing.T) {
	encoded, err := encodeDTXAux(nil)
	if err != nil {
		t.Fatal(err)
	}
	if got, want := binary.LittleEndian.Uint64(encoded[8:16]), uint64(0); got != want {
		t.Fatalf("body length = %d, want %d", got, want)
	}
	decoded, err := decodeDTXAux(encoded)
	if err != nil {
		t.Fatal(err)
	}
	if len(decoded) != 0 {
		t.Fatalf("decoded = %#v, want no arguments", decoded)
	}
}

func TestDTXFrameRoundTrip(t *testing.T) {
	left, right := net.Pipe()
	defer left.Close()
	defer right.Close()
	deadline := time.Now().Add(time.Second)
	sender := newDTXConnection(left, deadline)
	receiver := newDTXConnection(right, deadline)
	done := make(chan error, 1)
	go func() {
		_, err := sender.sendDispatch(1, "ping", []any{"value"}, true)
		done <- err
	}()
	message, err := receiver.receive()
	if err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	method, args, err := decodeDTXInvocation(message)
	if err != nil {
		t.Fatal(err)
	}
	if method != "ping" || !reflect.DeepEqual(args, []any{"value"}) || message.channel != 1 || message.flags != dtxExpectsReply {
		t.Fatalf("message=%#v method=%q args=%#v", message, method, args)
	}
}
