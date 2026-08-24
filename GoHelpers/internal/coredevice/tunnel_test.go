package coredevice

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"net"
	"testing"
	"time"
)

func TestCDTunnelHandshake(t *testing.T) {
	client, server := net.Pipe()
	defer client.Close()
	defer server.Close()
	result := make(chan error, 1)
	go func() {
		header := make([]byte, len(cdTunnelMagic)+2)
		if _, err := server.Read(header); err != nil {
			result <- err
			return
		}
		if string(header[:len(cdTunnelMagic)]) != cdTunnelMagic {
			result <- errInvalidFixture{}
			return
		}
		length := int(binary.BigEndian.Uint16(header[len(cdTunnelMagic):]))
		body := make([]byte, length)
		if _, err := server.Read(body); err != nil {
			result <- err
			return
		}
		var request map[string]any
		if err := json.Unmarshal(body, &request); err != nil {
			result <- err
			return
		}
		if request["type"] != "clientHandshakeRequest" {
			result <- errInvalidFixture{}
			return
		}
		responseBody, _ := json.Marshal(map[string]any{
			"serverAddress": "fd00::2", "serverRSDPort": 58783,
			"clientParameters": map[string]any{"address": "fd00::1", "mtu": 16000},
		})
		response := append([]byte(cdTunnelMagic), 0, 0)
		binary.BigEndian.PutUint16(response[len(cdTunnelMagic):], uint16(len(responseBody)))
		response = append(response, responseBody...)
		_, err := server.Write(response)
		result <- err
	}()
	parameters, err := establishCDTunnel(client, time.Now().Add(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if parameters.ClientAddress != "fd00::1" || parameters.ServerAddress != "fd00::2" || parameters.ServerRSDPort != 58783 || parameters.MTU != 16000 {
		t.Fatalf("parameters = %#v", parameters)
	}
	if err := <-result; err != nil {
		t.Fatal(err)
	}
}

type errInvalidFixture struct{}

func (errInvalidFixture) Error() string { return "invalid fixture" }

type deadlineRecordingConn struct {
	deadlines []time.Time
}

func (conn *deadlineRecordingConn) Read([]byte) (int, error)        { return 0, errors.New("read failure") }
func (conn *deadlineRecordingConn) Write(value []byte) (int, error) { return len(value), nil }
func (conn *deadlineRecordingConn) Close() error                    { return nil }
func (conn *deadlineRecordingConn) LocalAddr() net.Addr             { return deadlineRecordingAddr("local") }
func (conn *deadlineRecordingConn) RemoteAddr() net.Addr            { return deadlineRecordingAddr("remote") }
func (conn *deadlineRecordingConn) SetDeadline(deadline time.Time) error {
	conn.deadlines = append(conn.deadlines, deadline)
	return nil
}
func (conn *deadlineRecordingConn) SetReadDeadline(deadline time.Time) error {
	return conn.SetDeadline(deadline)
}
func (conn *deadlineRecordingConn) SetWriteDeadline(deadline time.Time) error {
	return conn.SetDeadline(deadline)
}

type deadlineRecordingAddr string

func (address deadlineRecordingAddr) Network() string { return "test" }
func (address deadlineRecordingAddr) String() string  { return string(address) }

func TestRawCoreDeviceRequestAppliesAndResetsDeadline(t *testing.T) {
	conn := &deadlineRecordingConn{}
	service := &CoreDeviceService{remote: NewRemoteXPCConnection(conn)}
	deadline := time.Unix(100, 0)
	if _, err := service.RequestAndReceiveWithDeadline(map[string]any{}, deadline); err == nil {
		t.Fatal("expected read failure")
	}
	if len(conn.deadlines) != 2 || !conn.deadlines[0].Equal(deadline) || !conn.deadlines[1].IsZero() {
		t.Fatalf("deadlines = %#v", conn.deadlines)
	}
}

func TestRSDIdentityMismatchClosesConnectionBeforeTypedFailure(t *testing.T) {
	conn := &closeRecordingConn{}
	_, err := newRSDClient(nil, net.ParseIP("fd00::2"), conn, map[string]any{
		"Properties": map[string]any{"UniqueDeviceID": "other-device"},
	}, "expected-device")
	var identityErr *RSDIdentityError
	if !errors.As(err, &identityErr) || !conn.closed {
		t.Fatalf("err=%v closed=%t", err, conn.closed)
	}
}

func TestRSDServiceDialFailureIsTyped(t *testing.T) {
	cause := errors.New("service open failed")
	client := &RSDClient{
		PeerInfo: RSDPeerInfo{Services: map[string]RSDService{
			"service.test": {Port: 1234, UsesRemoteXPC: true},
		}},
		dial: func(uint16, time.Time) (net.Conn, error) {
			return nil, cause
		},
	}
	_, err := client.StartService("service.test", time.Now().Add(time.Second))
	var serviceErr *RSDServiceError
	if !errors.As(err, &serviceErr) || !errors.Is(err, cause) {
		t.Fatalf("err=%v", err)
	}
}

func TestRSDOpenRawServiceDialsAdvertisedNonXPCPort(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	var dialedPort uint16
	client := &RSDClient{
		PeerInfo: RSDPeerInfo{Services: map[string]RSDService{
			"com.apple.instruments.dtservicehub": {Port: 4711},
		}},
		dial: func(port uint16, _ time.Time) (net.Conn, error) {
			dialedPort = port
			return clientConn, nil
		},
	}
	connection, err := client.OpenRawService("com.apple.instruments.dtservicehub", time.Now().Add(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if connection != clientConn || dialedPort != 4711 {
		t.Fatalf("connection=%v dialedPort=%d", connection, dialedPort)
	}
	if err := connection.Close(); err != nil {
		t.Fatal(err)
	}

	remote := &RSDClient{PeerInfo: RSDPeerInfo{Services: map[string]RSDService{
		"service.remote": {Port: 4712, UsesRemoteXPC: true},
	}}}
	if _, err := remote.OpenRawService("service.remote", time.Now().Add(time.Second)); err == nil {
		t.Fatal("accepted RemoteXPC service as raw DTX transport")
	}
}

type closeRecordingConn struct {
	deadlineRecordingConn
	closed bool
}

func (conn *closeRecordingConn) Close() error {
	conn.closed = true
	return nil
}
