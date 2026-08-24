package coredevice

import (
	"encoding/binary"
	"net"
	"reflect"
	"testing"
	"time"
)

type collectingSender struct {
	packets chan []byte
}

func (sender *collectingSender) sendPacket(packet []byte) error {
	sender.packets <- append([]byte(nil), packet...)
	return nil
}

func TestTCPStackHandshakeWriteAndRead(t *testing.T) {
	sender := &collectingSender{packets: make(chan []byte, 16)}
	local := net.ParseIP("fd00::1")
	remote := net.ParseIP("fd00::2")
	stack, err := newTCPStack(sender, local, remote)
	if err != nil {
		t.Fatal(err)
	}
	deadline := time.Now().Add(time.Second)
	connectionReady := make(chan net.Conn, 1)
	connectionError := make(chan error, 1)
	go func() {
		connection, err := stack.Dial(1234, deadline)
		if err != nil {
			connectionError <- err
			return
		}
		connectionReady <- connection
	}()
	syn := <-sender.packets
	_, synSegment, _, err := parseTCPPacket(syn)
	if err != nil || synSegment.flags&tcpFlagSYN == 0 {
		t.Fatalf("SYN = %x, %v", syn, err)
	}
	synAck, err := buildTCPPacket(remote, local, 1234, synSegment.srcPort, 800, synSegment.seq+1, tcpFlagSYN|tcpFlagACK, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := stack.handlePacket(synAck); err != nil {
		t.Fatal(err)
	}
	var connection net.Conn
	select {
	case connection = <-connectionReady:
	case err := <-connectionError:
		t.Fatal(err)
	case <-time.After(time.Second):
		t.Fatal("TCP handshake did not complete")
	}
	tcpConnection, ok := connection.(*tcpConn)
	if !ok {
		t.Fatalf("connection type = %T", connection)
	}
	var transportStages []string
	tcpConnection.SetTransportTrace(func(stage string) {
		transportStages = append(transportStages, stage)
	})
	if _, err := connection.Write([]byte("hello")); err != nil {
		t.Fatal(err)
	}
	_ = <-sender.packets // ACK completing the SYN exchange.
	dataPacket := <-sender.packets
	_, dataSegment, data, err := parseTCPPacket(dataPacket)
	if err != nil || string(data) != "hello" || dataSegment.flags&tcpFlagPSH == 0 {
		t.Fatalf("data packet = %x, payload=%q, err=%v", dataPacket, data, err)
	}
	ack, err := buildTCPPacket(remote, local, 1234, dataSegment.srcPort, 900, dataSegment.seq+uint32(len(data)), tcpFlagACK, nil)
	if err != nil {
		t.Fatal(err)
	}
	if err := stack.handlePacket(ack); err != nil {
		t.Fatal(err)
	}
	response, err := buildTCPPacket(remote, local, 1234, dataSegment.srcPort, 806, dataSegment.seq+uint32(len(data)), tcpFlagACK|tcpFlagPSH, []byte("world"))
	if err != nil {
		t.Fatal(err)
	}
	if err := stack.handlePacket(response); err != nil {
		t.Fatal(err)
	}
	response, err = buildTCPPacket(remote, local, 1234, dataSegment.srcPort, 801, dataSegment.seq+uint32(len(data)), tcpFlagACK|tcpFlagPSH, []byte("hello"))
	if err != nil {
		t.Fatal(err)
	}
	if err := stack.handlePacket(response); err != nil {
		t.Fatal(err)
	}
	buffer := make([]byte, 10)
	if _, err := connection.Read(buffer); err != nil {
		t.Fatal(err)
	}
	if string(buffer) != "helloworld" {
		t.Fatalf("response = %q", buffer)
	}
	if want := []string{"tcpDataSegmentSent", "tcpPeerAckAdvanced", "tcpPayloadReceived", "tcpPayloadReceived"}; !reflect.DeepEqual(transportStages, want) {
		t.Fatalf("transport stages = %#v, want %#v", transportStages, want)
	}
	_ = connection.Close()
}

func TestTCPPacketChecksumAndIPv6Length(t *testing.T) {
	packet, err := buildTCPPacket(net.ParseIP("fd00::1"), net.ParseIP("fd00::2"), 1000, 2000, 1, 2, tcpFlagACK, []byte{1, 2, 3})
	if err != nil {
		t.Fatal(err)
	}
	if got := int(binary.BigEndian.Uint16(packet[4:6])); got != len(packet)-ipv6HeaderSize {
		t.Fatalf("IPv6 payload length = %d", got)
	}
	if _, _, payload, err := parseTCPPacket(packet); err != nil || len(payload) != 3 {
		t.Fatalf("parse payload = %x, %v", payload, err)
	}
}
