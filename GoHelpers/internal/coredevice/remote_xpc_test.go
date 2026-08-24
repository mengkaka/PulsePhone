package coredevice

import (
	"bytes"
	"fmt"
	"io"
	"net"
	"reflect"
	"testing"
	"time"
)

type remoteXPCDeadlineTrackingConn struct {
	net.Conn
	deadlines []time.Time
}

func (conn *remoteXPCDeadlineTrackingConn) SetDeadline(deadline time.Time) error {
	conn.deadlines = append(conn.deadlines, deadline)
	return conn.Conn.SetDeadline(deadline)
}

func TestHTTP2FrameRoundTripUsesNetworkByteOrderAndStreamMask(t *testing.T) {
	original := HTTP2Frame{Type: HTTP2Data, Flags: 1, StreamID: 7, Payload: []byte("payload")}
	encoded, err := original.Encode()
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := ReadHTTP2Frame(bytes.NewReader(encoded), RemoteXPCMaxFrame)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(decoded, original) {
		t.Fatalf("decoded = %#v, want %#v", decoded, original)
	}
	if _, err := ReadHTTP2Frame(bytes.NewReader(encoded), 2); err == nil {
		t.Fatal("accepted oversized frame")
	}
}

func TestRSDPeerInfoValidatesTargetAndServicePorts(t *testing.T) {
	value := map[string]any{
		"Properties": map[string]any{
			"BuildVersion":   "21A",
			"OSVersion":      "17.0",
			"ProductType":    "iPhone15,2",
			"UniqueChipID":   XPCUInt64(123),
			"UniqueDeviceID": "device",
		},
		"Services": map[string]any{
			"com.apple.coredevice.appservice": map[string]any{
				"Port":       uint64(1234),
				"Properties": map[string]any{"UsesRemoteXPC": true},
			},
		},
	}
	info, err := ParseRSDPeerInfo(value, "device")
	if err != nil {
		t.Fatal(err)
	}
	if info.ECID != 123 || info.Services["com.apple.coredevice.appservice"].Port != 1234 {
		t.Fatalf("info = %#v", info)
	}
	if _, err := ParseRSDPeerInfo(value, "other"); err == nil {
		t.Fatal("accepted wrong RSD target")
	}
	bad := map[string]any{
		"Properties": value["Properties"],
		"Services":   map[string]any{"broken": map[string]any{"Port": uint64(65536)}},
	}
	if _, err := ParseRSDPeerInfo(bad, "device"); err == nil {
		t.Fatal("accepted invalid RSD port")
	}
}

func TestRemoteXPCDeviceHandshakePayload(t *testing.T) {
	value := map[string]any{
		"MessageType":              "Handshake",
		"MessagingProtocolVersion": XPCUInt64(messagingProtocolVersion),
		"UUID":                     XPCUUID{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
		"Properties": map[string]any{
			"RemoteXPCVersionFlags":      XPCUInt64(remoteXPCVersionFlags),
			"SensitivePropertiesVisible": true,
		},
		"Services": map[string]any{},
	}
	encoded, err := EncodeXPCWrapper(value, 1, false)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := DecodeXPCWrapper(encoded, RemoteXPCMaxMessage)
	if err != nil {
		t.Fatal(err)
	}
	if decoded.MessageID != 1 || decoded.Flags != XPCAlwaysSet|XPCDataPresent {
		t.Fatalf("header = %#v", decoded)
	}
	if !reflect.DeepEqual(decoded.Payload, value) {
		t.Fatalf("payload = %#v, want %#v", decoded.Payload, value)
	}
	protocolVersion, ok := decoded.Payload.(map[string]any)["MessagingProtocolVersion"].(XPCUInt64)
	if !ok || protocolVersion != XPCUInt64(messagingProtocolVersion) {
		t.Fatalf("protocol version = %#v", decoded.Payload.(map[string]any)["MessagingProtocolVersion"])
	}
}

func TestRemoteXPCControlWrapperUsesZeroPayloadLength(t *testing.T) {
	wrapper := encodeXPCControl(0x0201, 0)
	want := "920bb0290102000000000000000000000000000000000000"
	if got := fmt.Sprintf("%x", wrapper); got != want {
		t.Fatalf("control wrapper = %s, want %s", got, want)
	}
	decoded, err := DecodeXPCWrapper(wrapper, RemoteXPCMaxMessage)
	if err != nil {
		t.Fatal(err)
	}
	if decoded.Payload != nil || decoded.Flags != 0x0201 {
		t.Fatalf("decoded control wrapper = %#v", decoded)
	}
}

func TestRemoteXPCHandshakeAcknowledgesPeerSettingsBeforeReturning(t *testing.T) {
	clientRaw, server := net.Pipe()
	client := &remoteXPCDeadlineTrackingConn{Conn: clientRaw}
	defer client.Close()
	defer server.Close()

	received := make(chan HTTP2Frame, 1)
	errors := make(chan error, 1)
	go func() {
		_ = server.SetDeadline(time.Now().Add(time.Second))
		preface := make([]byte, len(HTTP2Magic))
		if _, err := io.ReadFull(server, preface); err != nil {
			errors <- err
			return
		}
		if string(preface) != HTTP2Magic {
			errors <- fmt.Errorf("preface = %q", preface)
			return
		}
		for index := 0; index < 7; index++ {
			if _, err := ReadHTTP2Frame(server, RemoteXPCMaxFrame); err != nil {
				errors <- err
				return
			}
		}
		encoded, err := (HTTP2Frame{Type: HTTP2Settings}).Encode()
		if err != nil {
			errors <- err
			return
		}
		if _, err := server.Write(encoded); err != nil {
			errors <- err
			return
		}
		frame, err := ReadHTTP2Frame(server, RemoteXPCMaxFrame)
		if err != nil {
			errors <- err
			return
		}
		received <- frame
	}()

	connection := NewRemoteXPCConnection(client)
	var stages []string
	connection.SetHandshakeTrace(func(stage string) {
		stages = append(stages, stage)
	})
	if err := connection.Handshake(time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	if len(client.deadlines) != 2 || client.deadlines[0].IsZero() || !client.deadlines[1].IsZero() {
		t.Fatalf("handshake deadlines = %#v, want bounded then cleared", client.deadlines)
	}
	wantStages := []string{
		"initialWriteStart",
		"initialWriteComplete",
		"settingsReadStart",
		"settingsFrameType4Flags0",
		"settingsReadComplete",
		"settingsAckWriteStart",
		"settingsAckWriteComplete",
	}
	if !reflect.DeepEqual(stages, wantStages) {
		t.Fatalf("handshake stages = %#v, want %#v", stages, wantStages)
	}
	select {
	case err := <-errors:
		t.Fatal(err)
	case frame := <-received:
		if frame.Type != HTTP2Settings || frame.Flags != HTTP2SettingsAck || frame.StreamID != 0 || len(frame.Payload) != 0 {
			t.Fatalf("settings acknowledgement = %#v", frame)
		}
	case <-time.After(time.Second):
		t.Fatal("server did not receive settings acknowledgement")
	}
}
