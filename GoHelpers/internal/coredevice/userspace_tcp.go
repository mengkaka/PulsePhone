package coredevice

// This file is a deliberately small IPv6/TCP data plane for the USB
// CoreDeviceProxy tunnel. The tunnel exposes packets, not a host-routable
// socket. A full general-purpose TCP stack would be unnecessary for the
// short-lived RSD and RemoteXPC streams PulsePhone opens, so this implementation
// keeps the supported surface explicit: IPv6, TCP, bounded out-of-order data,
// ACKs, FIN, and one connection per four-tuple. Retransmission is not yet
// implemented, so the stack still surfaces an unrecoverable transport error
// rather than silently mis-handling a failed send.

import (
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"sync"
	"time"
)

const (
	ipv6HeaderSize      = 40
	tcpHeaderSize       = 20
	tcpFlagFIN          = 0x01
	tcpFlagSYN          = 0x02
	tcpFlagRST          = 0x04
	tcpFlagPSH          = 0x08
	tcpFlagACK          = 0x10
	tcpFlagECE          = 0x40
	tcpFlagCWR          = 0x80
	userspaceMSS        = 1200
	maxTCPPayload       = 16 * 1024
	maxTCPReorder       = 4 * 1024 * 1024
	tcpAdvertisedWindow = 32768
	tcpSynMSS           = 15940
)

type packetSender interface {
	sendPacket([]byte) error
}

type tcpStack struct {
	mu       sync.Mutex
	sender   packetSender
	localIP  net.IP
	remoteIP net.IP
	closed   bool
	ports    uint16
	conns    map[tcpTuple]*tcpConn
}

type tcpTuple struct {
	localPort  uint16
	remotePort uint16
}

func newTCPStack(sender packetSender, localIP, remoteIP net.IP) (*tcpStack, error) {
	local := normalizeIPv6(localIP)
	remote := normalizeIPv6(remoteIP)
	if local == nil || remote == nil {
		return nil, errors.New("invalid CoreDevice IPv6 address")
	}
	return &tcpStack{
		sender:   sender,
		localIP:  local,
		remoteIP: remote,
		ports:    49152,
		conns:    make(map[tcpTuple]*tcpConn),
	}, nil
}

func normalizeIPv6(value net.IP) net.IP {
	value = value.To16()
	if value == nil || value.To4() != nil {
		return nil
	}
	return append(net.IP(nil), value...)
}

func (stack *tcpStack) nextPort() uint16 {
	for i := 0; i < 16384; i++ {
		port := stack.ports
		stack.ports++
		if stack.ports < 49152 {
			stack.ports = 49152
		}
		if _, exists := stack.conns[tcpTuple{localPort: port}]; !exists {
			return port
		}
	}
	return 0
}

func (stack *tcpStack) Dial(remotePort uint16, deadline time.Time) (net.Conn, error) {
	if remotePort == 0 {
		return nil, errors.New("invalid TCP service port")
	}
	stack.mu.Lock()
	if stack.closed {
		stack.mu.Unlock()
		return nil, errors.New("TCP stack closed")
	}
	localPort := stack.nextPort()
	if localPort == 0 {
		stack.mu.Unlock()
		return nil, errors.New("TCP ephemeral ports exhausted")
	}
	conn := newTCPConn(stack, localPort, remotePort)
	stack.conns[tcpTuple{localPort: localPort, remotePort: remotePort}] = conn
	stack.mu.Unlock()

	if err := conn.sendSegment(tcpFlagSYN, nil, conn.sndNext); err != nil {
		conn.fail(err)
		return nil, err
	}
	conn.sndNext++
	if err := conn.waitState(tcpEstablished, deadline); err != nil {
		conn.Close()
		return nil, err
	}
	return conn, nil
}

func (stack *tcpStack) close() error {
	stack.mu.Lock()
	if stack.closed {
		stack.mu.Unlock()
		return nil
	}
	stack.closed = true
	connections := make([]*tcpConn, 0, len(stack.conns))
	for _, conn := range stack.conns {
		connections = append(connections, conn)
	}
	stack.mu.Unlock()
	for _, conn := range connections {
		_ = conn.Close()
	}
	return nil
}

func (stack *tcpStack) handlePacket(packet []byte) error {
	ip, tcp, payload, err := parseTCPPacket(packet)
	if err != nil {
		return err
	}
	if !ip.src.Equal(stack.remoteIP) || !ip.dst.Equal(stack.localIP) {
		return nil
	}
	stack.mu.Lock()
	conn := stack.conns[tcpTuple{localPort: tcp.dstPort, remotePort: tcp.srcPort}]
	stack.mu.Unlock()
	if conn == nil {
		return nil
	}
	return conn.handleSegment(tcp, payload)
}

type tcpConnState uint8

const (
	tcpSynSent tcpConnState = iota
	tcpEstablished
	tcpClosing
	tcpClosed
)

type tcpConn struct {
	stack          *tcpStack
	localPort      uint16
	remotePort     uint16
	mu             sync.Mutex
	state          tcpConnState
	sndUna         uint32
	sndNext        uint32
	rcvNext        uint32
	remoteTS       uint32
	timestampOK    bool
	recv           []byte
	pending        map[uint32]tcpPendingSegment
	pendingBytes   int
	eof            bool
	err            error
	readNotify     chan struct{}
	stateNotify    chan struct{}
	readDeadline   time.Time
	writeDeadline  time.Time
	transportTrace func(string)
}

func newTCPConn(stack *tcpStack, localPort, remotePort uint16) *tcpConn {
	var seed [4]byte
	_, _ = rand.Read(seed[:])
	initial := binary.BigEndian.Uint32(seed[:])
	return &tcpConn{
		stack:       stack,
		localPort:   localPort,
		remotePort:  remotePort,
		state:       tcpSynSent,
		sndUna:      initial,
		sndNext:     initial,
		pending:     make(map[uint32]tcpPendingSegment),
		readNotify:  make(chan struct{}),
		stateNotify: make(chan struct{}),
	}
}

func coreDeviceUUID() string {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "00000000-0000-4000-8000-000000000000"
	}
	value[6] = (value[6] & 0x0f) | 0x40
	value[8] = (value[8] & 0x3f) | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x", value[0:4], value[4:6], value[6:8], value[8:10], value[10:16])
}

func (conn *tcpConn) signalReadLocked() {
	close(conn.readNotify)
	conn.readNotify = make(chan struct{})
}

func (conn *tcpConn) signalStateLocked() {
	close(conn.stateNotify)
	conn.stateNotify = make(chan struct{})
}

// SetTransportTrace observes coarse transport boundaries for one connection.
// It is used only by the opt-in device-info diagnostic path.
func (conn *tcpConn) SetTransportTrace(trace func(string)) {
	if conn == nil {
		return
	}
	conn.mu.Lock()
	conn.transportTrace = trace
	conn.mu.Unlock()
}

func (conn *tcpConn) traceTransport(stage string) {
	conn.mu.Lock()
	trace := conn.transportTrace
	conn.mu.Unlock()
	if trace != nil {
		trace(stage)
	}
}

func (conn *tcpConn) fail(err error) {
	conn.mu.Lock()
	if conn.err == nil {
		conn.err = err
	}
	conn.state = tcpClosed
	conn.eof = true
	conn.signalReadLocked()
	conn.signalStateLocked()
	conn.mu.Unlock()
}

func (conn *tcpConn) waitState(want tcpConnState, deadline time.Time) error {
	for {
		conn.mu.Lock()
		state := conn.state
		err := conn.err
		notify := conn.stateNotify
		conn.mu.Unlock()
		if state == want {
			return nil
		}
		if err != nil {
			return err
		}
		if state == tcpClosed {
			return errors.New("TCP connection closed during handshake")
		}
		if err := waitChannel(notify, deadline); err != nil {
			return err
		}
	}
}

func waitChannel(channel <-chan struct{}, deadline time.Time) error {
	if deadline.IsZero() {
		<-channel
		return nil
	}
	remaining := time.Until(deadline)
	if remaining <= 0 {
		return osErrTimeout{}
	}
	timer := time.NewTimer(remaining)
	defer timer.Stop()
	select {
	case <-channel:
		return nil
	case <-timer.C:
		return osErrTimeout{}
	}
}

type osErrTimeout struct{}

func (osErrTimeout) Error() string   { return "TCP deadline exceeded" }
func (osErrTimeout) Timeout() bool   { return true }
func (osErrTimeout) Temporary() bool { return true }

func (conn *tcpConn) handleSegment(segment tcpSegment, payload []byte) error {
	conn.mu.Lock()
	if conn.state == tcpClosed {
		conn.mu.Unlock()
		return nil
	}
	if segment.flags&tcpFlagRST != 0 {
		conn.err = errors.New("device reset TCP connection")
		conn.state = tcpClosed
		conn.eof = true
		conn.signalReadLocked()
		conn.signalStateLocked()
		conn.mu.Unlock()
		return nil
	}
	if conn.state == tcpSynSent && segment.flags&tcpFlagSYN != 0 && segment.flags&tcpFlagACK != 0 {
		if segment.ack != conn.sndNext {
			conn.mu.Unlock()
			return fmt.Errorf("unexpected TCP SYN acknowledgement")
		}
		conn.sndUna = segment.ack
		conn.rcvNext = segment.seq + 1
		if segment.timestampOK {
			conn.remoteTS = segment.timestamp
			conn.timestampOK = true
		}
		conn.state = tcpEstablished
		conn.signalStateLocked()
		conn.mu.Unlock()
		return conn.sendSegment(tcpFlagACK, nil, conn.sndNext)
	}
	if conn.state != tcpEstablished && conn.state != tcpClosing {
		conn.mu.Unlock()
		return nil
	}
	ackAdvanced := false
	if segment.flags&tcpFlagACK != 0 && segment.ack > conn.sndUna && segment.ack <= conn.sndNext {
		conn.sndUna = segment.ack
		ackAdvanced = true
	}
	if segment.timestampOK {
		conn.remoteTS = segment.timestamp
		conn.timestampOK = true
	}
	fin := segment.flags&tcpFlagFIN != 0
	if len(payload) > maxTCPPayload {
		conn.mu.Unlock()
		return fmt.Errorf("TCP payload exceeds cap")
	}
	if err := conn.acceptDataLocked(segment.seq, payload, fin); err != nil {
		conn.mu.Unlock()
		return err
	}
	conn.mu.Unlock()
	if ackAdvanced {
		conn.traceTransport("tcpPeerAckAdvanced")
	}
	if len(payload) > 0 {
		conn.traceTransport("tcpPayloadReceived")
	}
	if len(payload) > 0 || fin || segment.flags&tcpFlagACK != 0 {
		return conn.sendSegment(tcpFlagACK, nil, conn.sndNext)
	}
	return nil
}

func (conn *tcpConn) acceptDataLocked(sequence uint32, payload []byte, fin bool) error {
	if sequence < conn.rcvNext {
		overlap := conn.rcvNext - sequence
		if uint64(overlap) >= uint64(len(payload)) {
			// A duplicate segment may still carry a duplicate FIN. It has
			// already been acknowledged and requires no further state change.
			return nil
		}
		payload = payload[overlap:]
		sequence = conn.rcvNext
	}
	if sequence > conn.rcvNext {
		if existing, ok := conn.pending[sequence]; ok {
			if existing.fin != fin || string(existing.payload) != string(payload) {
				return errors.New("conflicting TCP retransmission")
			}
			return nil
		}
		if conn.pendingBytes+len(payload) > maxTCPReorder {
			return errors.New("TCP reorder buffer exceeded")
		}
		conn.pending[sequence] = tcpPendingSegment{payload: append([]byte(nil), payload...), fin: fin}
		conn.pendingBytes += len(payload)
		return nil
	}

	conn.appendInOrderLocked(payload, fin)
	for {
		pending, ok := conn.pending[conn.rcvNext]
		if !ok {
			break
		}
		delete(conn.pending, conn.rcvNext)
		conn.pendingBytes -= len(pending.payload)
		conn.appendInOrderLocked(pending.payload, pending.fin)
		if conn.eof {
			break
		}
	}
	return nil
}

func (conn *tcpConn) appendInOrderLocked(payload []byte, fin bool) {
	if len(payload) > 0 {
		conn.recv = append(conn.recv, payload...)
		conn.rcvNext += uint32(len(payload))
		conn.signalReadLocked()
	}
	if fin {
		conn.rcvNext++
		conn.eof = true
		conn.signalReadLocked()
	}
}

func (conn *tcpConn) sendSegment(flags byte, payload []byte, sequence uint32) error {
	conn.mu.Lock()
	timestampOK := conn.timestampOK
	remoteTS := conn.remoteTS
	conn.mu.Unlock()
	window := uint16(tcpAdvertisedWindow)
	options := []byte(nil)
	if flags&tcpFlagSYN != 0 {
		flags |= tcpFlagECE | tcpFlagCWR
		options = tcpSynOptions(timestampNow())
		window = 0xffff
	} else if timestampOK {
		options = tcpTimestampOptions(timestampNow(), remoteTS)
	}
	packet, err := buildTCPPacketWithOptions(conn.stack.localIP, conn.stack.remoteIP, conn.localPort, conn.remotePort, sequence, conn.rcvNext, flags, window, options, payload)
	if err != nil {
		return err
	}
	if err := conn.stack.sender.sendPacket(packet); err != nil {
		return err
	}
	if len(payload) > 0 {
		conn.traceTransport("tcpDataSegmentSent")
	}
	return nil
}

func (conn *tcpConn) Read(buffer []byte) (int, error) {
	for {
		conn.mu.Lock()
		if len(conn.recv) > 0 {
			count := copy(buffer, conn.recv)
			conn.recv = conn.recv[count:]
			conn.mu.Unlock()
			return count, nil
		}
		if conn.err != nil {
			err := conn.err
			conn.mu.Unlock()
			return 0, err
		}
		if conn.eof || conn.state == tcpClosed {
			conn.mu.Unlock()
			return 0, io.EOF
		}
		notify := conn.readNotify
		deadline := conn.readDeadline
		conn.mu.Unlock()
		if err := waitChannel(notify, deadline); err != nil {
			return 0, err
		}
	}
}

func (conn *tcpConn) Write(data []byte) (int, error) {
	if len(data) == 0 {
		return 0, nil
	}
	written := 0
	for written < len(data) {
		count := len(data) - written
		if count > userspaceMSS {
			count = userspaceMSS
		}
		conn.mu.Lock()
		if conn.state != tcpEstablished {
			err := conn.err
			if err == nil {
				err = errors.New("TCP connection is not established")
			}
			conn.mu.Unlock()
			return written, err
		}
		sequence := conn.sndNext
		conn.sndNext += uint32(count)
		deadline := conn.writeDeadline
		conn.mu.Unlock()
		if err := conn.sendSegment(tcpFlagACK|tcpFlagPSH, data[written:written+count], sequence); err != nil {
			conn.fail(err)
			return written, err
		}
		written += count
		if !deadline.IsZero() && time.Now().After(deadline) {
			return written, osErrTimeout{}
		}
	}
	return written, nil
}

func (conn *tcpConn) Close() error {
	conn.mu.Lock()
	if conn.state == tcpClosed {
		conn.mu.Unlock()
		return nil
	}
	sequence := conn.sndNext
	conn.sndNext++
	conn.state = tcpClosing
	conn.signalStateLocked()
	conn.mu.Unlock()
	err := conn.sendSegment(tcpFlagFIN|tcpFlagACK, nil, sequence)
	conn.mu.Lock()
	conn.state = tcpClosed
	conn.eof = true
	conn.signalReadLocked()
	conn.signalStateLocked()
	conn.mu.Unlock()
	conn.stack.mu.Lock()
	delete(conn.stack.conns, tcpTuple{localPort: conn.localPort, remotePort: conn.remotePort})
	conn.stack.mu.Unlock()
	return err
}

func (conn *tcpConn) LocalAddr() net.Addr {
	return &net.TCPAddr{IP: append(net.IP(nil), conn.stack.localIP...), Port: int(conn.localPort)}
}

func (conn *tcpConn) RemoteAddr() net.Addr {
	return &net.TCPAddr{IP: append(net.IP(nil), conn.stack.remoteIP...), Port: int(conn.remotePort)}
}

func (conn *tcpConn) SetDeadline(deadline time.Time) error {
	conn.mu.Lock()
	conn.readDeadline = deadline
	conn.writeDeadline = deadline
	conn.mu.Unlock()
	return nil
}

func (conn *tcpConn) SetReadDeadline(deadline time.Time) error {
	conn.mu.Lock()
	conn.readDeadline = deadline
	conn.mu.Unlock()
	return nil
}

func (conn *tcpConn) SetWriteDeadline(deadline time.Time) error {
	conn.mu.Lock()
	conn.writeDeadline = deadline
	conn.mu.Unlock()
	return nil
}

type ipv6Header struct {
	src net.IP
	dst net.IP
}

type tcpSegment struct {
	srcPort     uint16
	dstPort     uint16
	seq         uint32
	ack         uint32
	flags       byte
	window      uint16
	timestampOK bool
	timestamp   uint32
}

type tcpPendingSegment struct {
	payload []byte
	fin     bool
}

func parseTCPPacket(packet []byte) (ipv6Header, tcpSegment, []byte, error) {
	if len(packet) < ipv6HeaderSize+tcpHeaderSize || packet[0]>>4 != 6 {
		return ipv6Header{}, tcpSegment{}, nil, errors.New("invalid IPv6 TCP packet")
	}
	if packet[6] != 6 {
		return ipv6Header{}, tcpSegment{}, nil, errors.New("unsupported IPv6 next header")
	}
	payloadLength := int(binary.BigEndian.Uint16(packet[4:6]))
	if payloadLength < tcpHeaderSize || ipv6HeaderSize+payloadLength > len(packet) {
		return ipv6Header{}, tcpSegment{}, nil, errors.New("invalid IPv6 payload length")
	}
	tcpBytes := packet[ipv6HeaderSize : ipv6HeaderSize+payloadLength]
	dataOffset := int(tcpBytes[12]>>4) * 4
	if dataOffset < tcpHeaderSize || dataOffset > len(tcpBytes) {
		return ipv6Header{}, tcpSegment{}, nil, errors.New("invalid TCP header length")
	}
	segment := tcpSegment{
		srcPort: binary.BigEndian.Uint16(tcpBytes[0:2]),
		dstPort: binary.BigEndian.Uint16(tcpBytes[2:4]),
		seq:     binary.BigEndian.Uint32(tcpBytes[4:8]),
		ack:     binary.BigEndian.Uint32(tcpBytes[8:12]),
		flags:   tcpBytes[13],
		window:  binary.BigEndian.Uint16(tcpBytes[14:16]),
	}
	parseTCPOptions(tcpBytes[tcpHeaderSize:dataOffset], &segment)
	return ipv6Header{src: append(net.IP(nil), packet[8:24]...), dst: append(net.IP(nil), packet[24:40]...)}, segment, tcpBytes[dataOffset:], nil
}

func parseTCPOptions(options []byte, segment *tcpSegment) {
	for offset := 0; offset < len(options); {
		kind := options[offset]
		if kind == 0 {
			return
		}
		if kind == 1 {
			offset++
			continue
		}
		if offset+1 >= len(options) {
			return
		}
		length := int(options[offset+1])
		if length < 2 || offset+length > len(options) {
			return
		}
		if kind == 8 && length == 10 {
			segment.timestampOK = true
			segment.timestamp = binary.BigEndian.Uint32(options[offset+2 : offset+6])
		}
		offset += length
	}
}

func timestampNow() uint32 {
	return uint32(time.Now().UnixNano() / int64(time.Millisecond))
}

func tcpSynOptions(timestamp uint32) []byte {
	mss := uint16(tcpSynMSS)
	options := []byte{
		2, 4, byte(mss >> 8), byte(mss),
		4, 2,
		1, 3, 3, 7,
		8, 10,
		byte(timestamp >> 24), byte(timestamp >> 16), byte(timestamp >> 8), byte(timestamp),
		0, 0, 0, 0,
		0x22, 2, 1, 1,
	}
	return options
}

func tcpTimestampOptions(timestamp, echo uint32) []byte {
	return []byte{
		8, 10,
		byte(timestamp >> 24), byte(timestamp >> 16), byte(timestamp >> 8), byte(timestamp),
		byte(echo >> 24), byte(echo >> 16), byte(echo >> 8), byte(echo),
		1, 1,
	}
}

func buildTCPPacket(srcIP, dstIP net.IP, srcPort, dstPort uint16, sequence, acknowledgment uint32, flags byte, payload []byte) ([]byte, error) {
	return buildTCPPacketWithOptions(srcIP, dstIP, srcPort, dstPort, sequence, acknowledgment, flags, 0xffff, nil, payload)
}

func buildTCPPacketWithOptions(srcIP, dstIP net.IP, srcPort, dstPort uint16, sequence, acknowledgment uint32, flags byte, window uint16, options, payload []byte) ([]byte, error) {
	src := normalizeIPv6(srcIP)
	dst := normalizeIPv6(dstIP)
	if src == nil || dst == nil || len(payload) > maxTCPPayload || len(options)%4 != 0 || len(options) > 40 {
		return nil, errors.New("invalid TCP packet address or payload")
	}
	tcp := make([]byte, tcpHeaderSize+len(options)+len(payload))
	binary.BigEndian.PutUint16(tcp[0:2], srcPort)
	binary.BigEndian.PutUint16(tcp[2:4], dstPort)
	binary.BigEndian.PutUint32(tcp[4:8], sequence)
	binary.BigEndian.PutUint32(tcp[8:12], acknowledgment)
	tcp[12] = byte((tcpHeaderSize + len(options)) / 4 << 4)
	tcp[13] = flags
	binary.BigEndian.PutUint16(tcp[14:16], window)
	copy(tcp[tcpHeaderSize:], options)
	copy(tcp[tcpHeaderSize+len(options):], payload)
	binary.BigEndian.PutUint16(tcp[16:18], tcpChecksum(src, dst, tcp))
	packet := make([]byte, ipv6HeaderSize+len(tcp))
	packet[0] = 0x60
	binary.BigEndian.PutUint16(packet[4:6], uint16(len(tcp)))
	packet[6] = 6
	packet[7] = 64
	copy(packet[8:24], src)
	copy(packet[24:40], dst)
	copy(packet[40:], tcp)
	return packet, nil
}

func tcpChecksum(src, dst net.IP, packet []byte) uint16 {
	var sum uint32
	add := func(data []byte) {
		for len(data) >= 2 {
			sum += uint32(binary.BigEndian.Uint16(data))
			data = data[2:]
		}
		if len(data) == 1 {
			sum += uint32(data[0]) << 8
		}
	}
	add(src)
	add(dst)
	var pseudo [8]byte
	binary.BigEndian.PutUint32(pseudo[0:4], uint32(len(packet)))
	pseudo[7] = 6
	add(pseudo[:])
	add(packet)
	for sum>>16 != 0 {
		sum = (sum & 0xffff) + sum>>16
	}
	return ^uint16(sum)
}
