package coredevice

import (
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"time"

	"pulsephone/GoHelpers/internal/direct"
)

const (
	coreDeviceProxyService = "com.apple.internal.devicecompute.CoreDeviceProxy"
	dvtRSDService          = "com.apple.instruments.dtservicehub"
	cdTunnelMagic          = "CDTunnel"
	cdTunnelMTU            = 16000
	maximumCDTunnelPacket  = 64 * 1024
	rsDiscoveryPort        = 58783
)

type CoreDeviceTunnelLease struct {
	RSD       *RSDClient
	link      *packetLink
	lockdown  *direct.Lockdown
	service   net.Conn
	stack     *tcpStack
	closeOnce sync.Once
	closeErr  error
}

func OpenUserspaceTunnel(udid string, deadline time.Time) (*CoreDeviceTunnelLease, error) {
	lockdown, err := direct.OpenLockdown(udid, deadline)
	if err != nil {
		return nil, err
	}
	service, err := lockdown.StartService(coreDeviceProxyService)
	if err != nil {
		lockdown.Close()
		return nil, err
	}
	parameters, err := establishCDTunnel(service, deadline)
	if err != nil {
		_ = service.Close()
		lockdown.Close()
		return nil, err
	}
	localIP := net.ParseIP(parameters.ClientAddress)
	remoteIP := net.ParseIP(parameters.ServerAddress)
	if localIP == nil || remoteIP == nil || parameters.ServerRSDPort == 0 {
		_ = service.Close()
		lockdown.Close()
		return nil, errors.New("invalid CoreDevice tunnel parameters")
	}
	if err := service.SetDeadline(time.Time{}); err != nil {
		_ = service.Close()
		lockdown.Close()
		return nil, err
	}
	link := &packetLink{conn: service}
	stack, err := newTCPStack(link, localIP, remoteIP)
	if err != nil {
		_ = service.Close()
		lockdown.Close()
		return nil, err
	}
	link.stack = stack
	link.start()
	rsd, err := openRSD(stack, remoteIP, parameters.ServerRSDPort, udid, deadline)
	if err != nil {
		_ = link.close()
		lockdown.Close()
		return nil, err
	}
	return &CoreDeviceTunnelLease{
		RSD:      rsd,
		link:     link,
		lockdown: lockdown,
		service:  service,
		stack:    stack,
	}, nil
}

func (lease *CoreDeviceTunnelLease) Close() error {
	if lease == nil {
		return nil
	}
	lease.closeOnce.Do(func() {
		if lease.RSD != nil {
			lease.closeErr = lease.RSD.Close()
		}
		if lease.stack != nil {
			_ = lease.stack.close()
		}
		if lease.link != nil {
			if err := lease.link.close(); lease.closeErr == nil {
				lease.closeErr = err
			}
		}
		if lease.lockdown != nil {
			lease.lockdown.Close()
		}
	})
	return lease.closeErr
}

// ServiceStarter adapts the tunnel to the generation lifecycle. Generation
// startup is bounded by its caller; service opening gets a short local
// deadline so a malformed service surface cannot block teardown indefinitely.
func (lease *CoreDeviceTunnelLease) ServiceStarter() ServiceStarter {
	var lock sync.Mutex
	opened := make(map[string]Closable)
	return func(name string) (Closable, error) {
		if lease == nil || lease.RSD == nil {
			return nil, errors.New("CoreDevice tunnel closed")
		}
		lock.Lock()
		defer lock.Unlock()
		if service := opened[name]; service != nil {
			return service, nil
		}
		service, err := lease.RSD.StartService(name, time.Now().Add(60*time.Second))
		if err != nil {
			return nil, err
		}
		opened[name] = service
		return service, nil
	}
}

type cdTunnelParameters struct {
	ClientAddress string
	ServerAddress string
	ServerRSDPort uint16
	MTU           int
}

func establishCDTunnel(conn net.Conn, deadline time.Time) (cdTunnelParameters, error) {
	body, err := json.Marshal(map[string]any{"type": "clientHandshakeRequest", "mtu": cdTunnelMTU})
	if err != nil {
		return cdTunnelParameters{}, err
	}
	packet := make([]byte, len(cdTunnelMagic)+2+len(body))
	copy(packet, cdTunnelMagic)
	binary.BigEndian.PutUint16(packet[len(cdTunnelMagic):], uint16(len(body)))
	copy(packet[len(cdTunnelMagic)+2:], body)
	if err := writeWithDeadline(conn, packet, deadline); err != nil {
		return cdTunnelParameters{}, err
	}
	header := make([]byte, len(cdTunnelMagic)+2)
	if err := readWithDeadline(conn, header, deadline); err != nil {
		return cdTunnelParameters{}, err
	}
	if string(header[:len(cdTunnelMagic)]) != cdTunnelMagic {
		return cdTunnelParameters{}, errors.New("invalid CD tunnel magic")
	}
	length := int(binary.BigEndian.Uint16(header[len(cdTunnelMagic):]))
	if length == 0 || length > maximumCDTunnelPacket {
		return cdTunnelParameters{}, errors.New("invalid CD tunnel handshake length")
	}
	response := make([]byte, length)
	if err := readWithDeadline(conn, response, deadline); err != nil {
		return cdTunnelParameters{}, err
	}
	var value struct {
		ServerAddress    string `json:"serverAddress"`
		ServerRSDPort    uint16 `json:"serverRSDPort"`
		ClientParameters struct {
			Address string `json:"address"`
			MTU     int    `json:"mtu"`
		} `json:"clientParameters"`
	}
	if err := json.Unmarshal(response, &value); err != nil {
		return cdTunnelParameters{}, err
	}
	return cdTunnelParameters{
		ClientAddress: value.ClientParameters.Address,
		ServerAddress: value.ServerAddress,
		ServerRSDPort: value.ServerRSDPort,
		MTU:           value.ClientParameters.MTU,
	}, nil
}

type packetLink struct {
	conn      net.Conn
	stack     *tcpStack
	writeMu   sync.Mutex
	closeOnce sync.Once
	closeErr  error
	readDone  chan struct{}
}

func (link *packetLink) start() {
	link.readDone = make(chan struct{})
	go link.readLoop()
}

func (link *packetLink) sendPacket(packet []byte) error {
	link.writeMu.Lock()
	defer link.writeMu.Unlock()
	return writeWithDeadline(link.conn, packet, time.Time{})
}

func (link *packetLink) readLoop() {
	defer close(link.readDone)
	header := make([]byte, ipv6HeaderSize)
	for {
		if _, err := io.ReadFull(link.conn, header); err != nil {
			if !errors.Is(err, net.ErrClosed) {
				link.stack.failAll(err)
			}
			return
		}
		if header[0]>>4 != 6 {
			link.stack.failAll(errors.New("CoreDevice tunnel returned non-IPv6 packet"))
			return
		}
		length := int(binary.BigEndian.Uint16(header[4:6]))
		if length < tcpHeaderSize || length > maximumCDTunnelPacket-ipv6HeaderSize {
			link.stack.failAll(errors.New("CoreDevice tunnel returned invalid packet length"))
			return
		}
		packet := make([]byte, ipv6HeaderSize+length)
		copy(packet, header)
		if _, err := io.ReadFull(link.conn, packet[ipv6HeaderSize:]); err != nil {
			link.stack.failAll(err)
			return
		}
		if packet[6] != 6 {
			// Neighbor discovery and other IPv6 control traffic can share the
			// tunnel. The CoreDevice services use TCP; leave unrelated packets
			// to the device-side stack instead of retiring the whole tunnel.
			continue
		}
		if err := link.stack.handlePacket(packet); err != nil {
			link.stack.failAll(err)
			return
		}
	}
}

func (link *packetLink) close() error {
	link.closeOnce.Do(func() {
		link.closeErr = link.conn.Close()
		if link.readDone != nil {
			<-link.readDone
		}
	})
	return link.closeErr
}

func (stack *tcpStack) failAll(err error) {
	stack.mu.Lock()
	connections := make([]*tcpConn, 0, len(stack.conns))
	for _, conn := range stack.conns {
		connections = append(connections, conn)
	}
	stack.mu.Unlock()
	for _, conn := range connections {
		conn.fail(err)
	}
}

func writeWithDeadline(conn net.Conn, data []byte, deadline time.Time) error {
	if !deadline.IsZero() {
		if err := conn.SetWriteDeadline(deadline); err != nil {
			return err
		}
	}
	for len(data) > 0 {
		count, err := conn.Write(data)
		if err != nil {
			return err
		}
		if count == 0 {
			return io.ErrShortWrite
		}
		data = data[count:]
	}
	return nil
}

func readWithDeadline(conn net.Conn, data []byte, deadline time.Time) error {
	if !deadline.IsZero() {
		if err := conn.SetReadDeadline(deadline); err != nil {
			return err
		}
	}
	_, err := io.ReadFull(conn, data)
	return err
}

type RSDClient struct {
	stack      *tcpStack
	address    net.IP
	connection net.Conn
	PeerInfo   RSDPeerInfo
	dial       func(port uint16, deadline time.Time) (net.Conn, error)
	servicesMu sync.Mutex
	services   []*CoreDeviceService
}

type RSDIdentityError struct {
	Err error
}

func (err *RSDIdentityError) Error() string {
	if err == nil || err.Err == nil {
		return "RSD target identity"
	}
	return err.Err.Error()
}

func (err *RSDIdentityError) Unwrap() error {
	if err == nil {
		return nil
	}
	return err.Err
}

type RSDServiceError struct {
	Err error
}

func (err *RSDServiceError) Error() string {
	if err == nil || err.Err == nil {
		return "RSD service"
	}
	return err.Err.Error()
}

func (err *RSDServiceError) Unwrap() error {
	if err == nil {
		return nil
	}
	return err.Err
}

func openRSD(stack *tcpStack, address net.IP, port uint16, expectedUDID string, deadline time.Time) (*RSDClient, error) {
	conn, err := stack.Dial(port, deadline)
	if err != nil {
		return nil, fmt.Errorf("RSD TCP connect: %w", err)
	}
	remote := NewRemoteXPCConnection(conn)
	if err := remote.Handshake(deadline); err != nil {
		_ = remote.Close()
		return nil, fmt.Errorf("RSD RemoteXPC handshake: %w", err)
	}
	if !deadline.IsZero() {
		if err := conn.SetDeadline(deadline); err != nil {
			_ = remote.Close()
			return nil, fmt.Errorf("RSD peer-info deadline: %w", err)
		}
		defer conn.SetDeadline(time.Time{})
	}
	if err := remote.SendDeviceHandshake(); err != nil {
		_ = remote.Close()
		return nil, fmt.Errorf("RSD device handshake: %w", err)
	}
	peer, err := remote.ReceiveResponse(RemoteXPCMaxMessage)
	if err != nil {
		_ = remote.Close()
		return nil, fmt.Errorf("RSD peer info: %w", err)
	}
	return newRSDClient(stack, address, conn, peer, expectedUDID)
}

func newRSDClient(stack *tcpStack, address net.IP, conn net.Conn, peer map[string]any, expectedUDID string) (*RSDClient, error) {
	info, err := ParseRSDPeerInfo(peer, expectedUDID)
	if err != nil {
		_ = conn.Close()
		return nil, &RSDIdentityError{Err: err}
	}
	_ = conn.SetDeadline(time.Time{})
	return &RSDClient{stack: stack, address: normalizeIPv6(address), connection: conn, PeerInfo: info}, nil
}

func (client *RSDClient) Close() error {
	if client == nil {
		return nil
	}
	client.servicesMu.Lock()
	services := append([]*CoreDeviceService(nil), client.services...)
	client.services = nil
	client.servicesMu.Unlock()
	for _, service := range services {
		_ = service.Close()
	}
	return client.connection.Close()
}

func (client *RSDClient) StartService(name string, deadline time.Time) (*CoreDeviceService, error) {
	info, ok := client.PeerInfo.Services[name]
	if !ok {
		return nil, &RSDServiceError{Err: fmt.Errorf("RSD service unavailable: %s", name)}
	}
	dial := client.dial
	if dial == nil {
		if client.stack == nil {
			return nil, &RSDServiceError{Err: errors.New("RSD transport unavailable")}
		}
		dial = client.stack.Dial
	}
	if name == "com.apple.coredevice.deviceinfo" {
		traceDisplayGeometry("rsdDialStart")
	}
	conn, err := dial(info.Port, deadline)
	if err != nil {
		if name == "com.apple.coredevice.deviceinfo" {
			traceDisplayGeometry("rsdDialFailed")
		}
		return nil, &RSDServiceError{Err: err}
	}
	if name == "com.apple.coredevice.deviceinfo" {
		traceDisplayGeometry("rsdDialComplete")
		if transport, ok := conn.(interface{ SetTransportTrace(func(string)) }); ok {
			transport.SetTransportTrace(func(stage string) {
				traceDisplayGeometry(stage)
			})
		}
	}
	service := &CoreDeviceService{rsd: client, name: name}
	if info.UsesRemoteXPC {
		service.remote = NewRemoteXPCConnection(conn)
		if name == "com.apple.coredevice.deviceinfo" {
			service.remote.SetHandshakeTrace(func(stage string) {
				traceDisplayGeometry("rsdHandshake" + stage)
			})
			traceDisplayGeometry("rsdHandshakeStart")
		}
		if err := service.remote.Handshake(deadline); err != nil {
			if name == "com.apple.coredevice.deviceinfo" {
				traceDisplayGeometry("rsdHandshakeFailed")
			}
			_ = service.Close()
			return nil, &RSDServiceError{Err: err}
		}
		if name == "com.apple.coredevice.deviceinfo" {
			traceDisplayGeometry("rsdHandshakeComplete")
		}
	} else {
		service.plist = direct.NewPlistService(conn, deadline)
		checkin := map[string]any{"Label": "PulsePhone", "ProtocolVersion": "2", "Request": "RSDCheckin"}
		value, err := service.plist.SendReceive(checkin, 64*1024)
		if err != nil {
			_ = service.Close()
			return nil, &RSDServiceError{Err: err}
		}
		response, ok := value.(map[string]any)
		if !ok || response["Request"] != "RSDCheckin" {
			_ = service.Close()
			return nil, &RSDServiceError{Err: errors.New("invalid RSD check-in response")}
		}
		value, err = service.plist.ReceiveValue(64 * 1024)
		if err != nil {
			_ = service.Close()
			return nil, &RSDServiceError{Err: err}
		}
		response, ok = value.(map[string]any)
		if !ok || response["Request"] != "StartService" || response["Error"] != nil {
			_ = service.Close()
			return nil, &RSDServiceError{Err: errors.New("RSD service start rejected")}
		}
	}
	client.servicesMu.Lock()
	client.services = append(client.services, service)
	client.servicesMu.Unlock()
	return service, nil
}

// OpenRawService dials a non-RemoteXPC RSD service without the CoreDevice
// RSDCheckin exchange. DVT advertises this form of service and expects DTX
// framing immediately, which matches pymobiledevice's RSD DvtProvider path.
func (client *RSDClient) OpenRawService(name string, deadline time.Time) (net.Conn, error) {
	if client == nil {
		return nil, &RSDServiceError{Err: errors.New("RSD client unavailable")}
	}
	info, ok := client.PeerInfo.Services[name]
	if !ok {
		return nil, &RSDServiceError{Err: fmt.Errorf("RSD service unavailable: %s", name)}
	}
	if info.UsesRemoteXPC {
		return nil, &RSDServiceError{Err: fmt.Errorf("RSD service requires RemoteXPC: %s", name)}
	}
	dial := client.dial
	if dial == nil {
		if client.stack == nil {
			return nil, &RSDServiceError{Err: errors.New("RSD transport unavailable")}
		}
		dial = client.stack.Dial
	}
	conn, err := dial(info.Port, deadline)
	if err != nil {
		return nil, &RSDServiceError{Err: err}
	}
	return conn, nil
}

type CoreDeviceService struct {
	rsd    *RSDClient
	name   string
	remote *RemoteXPCConnection
	plist  *direct.PlistService
	mu     sync.Mutex
	closed bool
}

func (service *CoreDeviceService) Close() error {
	if service == nil {
		return nil
	}
	service.mu.Lock()
	if service.closed {
		service.mu.Unlock()
		return nil
	}
	service.closed = true
	remote := service.remote
	plist := service.plist
	service.mu.Unlock()
	if remote != nil {
		return remote.Close()
	}
	if plist != nil {
		return plist.Close()
	}
	return nil
}

func (service *CoreDeviceService) SendRequest(value map[string]any, wantingReply bool) error {
	service.mu.Lock()
	defer service.mu.Unlock()
	if service.closed || service.remote == nil {
		return errors.New("CoreDevice service is not RemoteXPC")
	}
	return service.remote.SendRequest(value, wantingReply)
}

func (service *CoreDeviceService) ReceiveResponse(maximum int) (map[string]any, error) {
	service.mu.Lock()
	defer service.mu.Unlock()
	if service.closed || service.remote == nil {
		return nil, errors.New("CoreDevice service is not RemoteXPC")
	}
	return service.remote.ReceiveResponse(maximum)
}

func (service *CoreDeviceService) requestAndReceive(value map[string]any) (map[string]any, error) {
	return service.requestAndReceiveWithDeadline(value, time.Time{})
}

func (service *CoreDeviceService) requestAndReceiveWithDeadline(value map[string]any, deadline time.Time) (map[string]any, error) {
	service.mu.Lock()
	defer service.mu.Unlock()
	if service.closed || service.remote == nil {
		return nil, errors.New("CoreDevice service is not RemoteXPC")
	}
	if !deadline.IsZero() {
		if err := service.remote.conn.SetDeadline(deadline); err != nil {
			return nil, err
		}
		defer service.remote.conn.SetDeadline(time.Time{})
	}
	if err := service.remote.SendRequest(value, true); err != nil {
		return nil, err
	}
	return service.remote.ReceiveResponse(RemoteXPCMaxMessage)
}

// RequestAndReceive sends a raw RemoteXPC request and waits for its reply.
// Some CoreDevice services (notably pasteboard and universal HID) expose a
// direct request envelope rather than the CoreDevice invocation envelope.
func (service *CoreDeviceService) RequestAndReceive(value map[string]any) (map[string]any, error) {
	return service.requestAndReceive(value)
}

// RequestAndReceiveWithDeadline bounds a raw RemoteXPC request/reply exchange.
func (service *CoreDeviceService) RequestAndReceiveWithDeadline(value map[string]any, deadline time.Time) (map[string]any, error) {
	return service.requestAndReceiveWithDeadline(value, deadline)
}

func (service *CoreDeviceService) SendPlist(value map[string]any) error {
	service.mu.Lock()
	defer service.mu.Unlock()
	if service.closed || service.plist == nil {
		return errors.New("CoreDevice service is not plist")
	}
	return service.plist.SendValue(value)
}

func (service *CoreDeviceService) ReceivePlist(maximum int) (map[string]any, error) {
	service.mu.Lock()
	defer service.mu.Unlock()
	if service.closed || service.plist == nil {
		return nil, errors.New("CoreDevice service is not plist")
	}
	value, err := service.plist.ReceiveValue(maximum)
	if err != nil {
		return nil, err
	}
	result, ok := value.(map[string]any)
	if !ok {
		return nil, errors.New("CoreDevice plist response is not a dictionary")
	}
	return result, nil
}

func (service *CoreDeviceService) SendReceivePlist(value map[string]any, maximum int) (map[string]any, error) {
	if err := service.SendPlist(value); err != nil {
		return nil, err
	}
	return service.ReceivePlist(maximum)
}

func (service *CoreDeviceService) WriteRaw(data []byte) error {
	service.mu.Lock()
	defer service.mu.Unlock()
	if service.closed || service.plist == nil {
		return errors.New("CoreDevice service is not plist")
	}
	return service.plist.WriteRaw(data)
}

func (service *CoreDeviceService) Invoke(feature string, input map[string]any, actionIdentifier string) (map[string]any, error) {
	return service.invoke(feature, input, actionIdentifier, time.Time{})
}

// InvokeWithDeadline bounds a RemoteXPC invocation without changing the
// default deadline policy for other CoreDevice services.
func (service *CoreDeviceService) InvokeWithDeadline(feature string, input map[string]any, actionIdentifier string, deadline time.Time) (map[string]any, error) {
	return service.invoke(feature, input, actionIdentifier, deadline)
}

func (service *CoreDeviceService) invoke(feature string, input map[string]any, actionIdentifier string, deadline time.Time) (map[string]any, error) {
	request := map[string]any{
		"CoreDevice.CoreDeviceDDIProtocolVersion": XPCInt64(2),
		"CoreDevice.coreDeviceVersion": map[string]any{
			"components":              []any{XPCUInt64(629), XPCUInt64(3)},
			"originalComponentsCount": XPCInt64(2),
			"stringValue":             "629.3",
		},
		"CoreDevice.deviceIdentifier":     coreDeviceUUID(),
		"CoreDevice.input":                input,
		"CoreDevice.invocationIdentifier": coreDeviceUUID(),
	}
	if feature != "" {
		request["CoreDevice.featureIdentifier"] = feature
		request["CoreDevice.action"] = map[string]any{}
	}
	if actionIdentifier != "" {
		request["CoreDevice.actionIdentifier"] = actionIdentifier
	}
	service.mu.Lock()
	defer service.mu.Unlock()
	if service.closed || service.remote == nil {
		return nil, errors.New("CoreDevice service is not RemoteXPC")
	}
	if !deadline.IsZero() {
		if err := service.remote.conn.SetDeadline(deadline); err != nil {
			return nil, err
		}
		defer service.remote.conn.SetDeadline(time.Time{})
	}
	if feature == "com.apple.coredevice.feature.getdisplayinfo" {
		traceDisplayGeometry("remoteXPCSendStart")
	}
	if err := service.remote.SendRequest(request, true); err != nil {
		if feature == "com.apple.coredevice.feature.getdisplayinfo" {
			traceDisplayGeometry("remoteXPCSendFailed")
		}
		return nil, err
	}
	if feature == "com.apple.coredevice.feature.getdisplayinfo" {
		traceDisplayGeometry("remoteXPCRequestSent")
		traceDisplayGeometry("remoteXPCReceiveStart")
	}
	response, err := service.remote.ReceiveResponse(RemoteXPCMaxMessage)
	if err != nil {
		if feature == "com.apple.coredevice.feature.getdisplayinfo" {
			traceDisplayGeometry("remoteXPCReceiveFailed")
		}
		return nil, err
	}
	if feature == "com.apple.coredevice.feature.getdisplayinfo" {
		traceDisplayGeometry("remoteXPCResponseReceived")
	}
	output, ok := response["CoreDevice.output"].(map[string]any)
	if !ok {
		return nil, fmt.Errorf("CoreDevice invocation failed for %s", feature)
	}
	return output, nil
}
