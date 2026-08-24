package coredevice

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"sort"
	"strconv"
	"time"
)

const (
	HTTP2Data                byte = 0x0
	HTTP2Headers             byte = 0x1
	HTTP2Settings            byte = 0x4
	HTTP2WindowUpdate        byte = 0x8
	HTTP2EndHeaders          byte = 0x4
	HTTP2SettingsAck         byte = 0x1
	HTTP2Magic                    = "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"
	RemoteXPCMaxFrame             = 16 * 1024 * 1024
	RemoteXPCMaxMessage           = 16 * 1024 * 1024
	remoteXPCVersionFlags         = uint64(0x0100000000000006)
	messagingProtocolVersion      = uint64(7)
)

type HTTP2Frame struct {
	Type     byte
	Flags    byte
	StreamID uint32
	Payload  []byte
}

func (frame HTTP2Frame) Encode() ([]byte, error) {
	if len(frame.Payload) > 0xffffff || frame.StreamID&0x80000000 != 0 {
		return nil, errors.New("invalid HTTP/2 frame")
	}
	encoded := make([]byte, 9+len(frame.Payload))
	encoded[0] = byte(len(frame.Payload) >> 16)
	encoded[1] = byte(len(frame.Payload) >> 8)
	encoded[2] = byte(len(frame.Payload))
	encoded[3] = frame.Type
	encoded[4] = frame.Flags
	binary.BigEndian.PutUint32(encoded[5:9], frame.StreamID)
	copy(encoded[9:], frame.Payload)
	return encoded, nil
}

func ReadHTTP2Frame(reader io.Reader, maximum int) (HTTP2Frame, error) {
	var header [9]byte
	if _, err := io.ReadFull(reader, header[:]); err != nil {
		return HTTP2Frame{}, err
	}
	length := int(header[0])<<16 | int(header[1])<<8 | int(header[2])
	if length > maximum || maximum <= 0 {
		return HTTP2Frame{}, errors.New("HTTP/2 frame cap")
	}
	payload := make([]byte, length)
	if _, err := io.ReadFull(reader, payload); err != nil {
		return HTTP2Frame{}, err
	}
	return HTTP2Frame{Type: header[3], Flags: header[4], StreamID: binary.BigEndian.Uint32(header[5:9]) & 0x7fffffff, Payload: payload}, nil
}

type RemoteXPCConnection struct {
	conn           net.Conn
	reader         *bufio.Reader
	nextMessage    map[uint32]uint64
	previousData   []byte
	handshakeTrace func(string)
	closed         bool
}

func NewRemoteXPCConnection(conn net.Conn) *RemoteXPCConnection {
	return &RemoteXPCConnection{conn: conn, reader: bufio.NewReader(conn), nextMessage: map[uint32]uint64{1: 0, 3: 0}}
}

// SetHandshakeTrace observes handshake phase boundaries. Callers use it only
// for opt-in diagnostics before a connection is exposed to other operations.
func (connection *RemoteXPCConnection) SetHandshakeTrace(trace func(string)) {
	if connection != nil {
		connection.handshakeTrace = trace
	}
}

func (connection *RemoteXPCConnection) traceHandshake(stage string) {
	if connection != nil && connection.handshakeTrace != nil {
		connection.handshakeTrace(stage)
	}
}

func (connection *RemoteXPCConnection) Handshake(deadline time.Time) error {
	if connection == nil || connection.conn == nil || connection.closed {
		return errors.New("remote XPC connection closed")
	}
	if !deadline.IsZero() {
		if err := connection.conn.SetDeadline(deadline); err != nil {
			return err
		}
		// Facet services outlive their startup handshake. A startup deadline must
		// not make the first one-way HID request after an idle period fail.
		defer connection.conn.SetDeadline(time.Time{})
	}
	settings := make([]byte, 12)
	binary.BigEndian.PutUint16(settings[0:2], 0x3)
	binary.BigEndian.PutUint32(settings[2:6], 100)
	binary.BigEndian.PutUint16(settings[6:8], 0x4)
	binary.BigEndian.PutUint32(settings[8:12], 16*1024*1024)
	var increment [4]byte
	binary.BigEndian.PutUint32(increment[:], 16*1024*1024-65_535)
	emptyRequest, err := EncodeXPCWrapper(map[string]any{}, connection.nextMessage[1], false)
	if err != nil {
		return err
	}
	connection.traceHandshake("initialWriteStart")
	if err := connection.writePrefixedFrames(HTTP2Magic,
		HTTP2Frame{Type: HTTP2Settings, Payload: settings},
		HTTP2Frame{Type: HTTP2WindowUpdate, Payload: increment[:]},
		HTTP2Frame{Type: HTTP2Headers, Flags: HTTP2EndHeaders, StreamID: 1},
		HTTP2Frame{Type: HTTP2Data, StreamID: 1, Payload: emptyRequest},
		HTTP2Frame{Type: HTTP2Headers, Flags: HTTP2EndHeaders, StreamID: 3},
		HTTP2Frame{Type: HTTP2Data, StreamID: 1, Payload: encodeXPCControl(0x0201, 0)},
		HTTP2Frame{Type: HTTP2Data, StreamID: 3, Payload: encodeXPCControl(XPCInitHandshake|XPCAlwaysSet, 0)},
	); err != nil {
		connection.traceHandshake("initialWriteFailed")
		return err
	}
	connection.traceHandshake("initialWriteComplete")
	connection.nextMessage[1]++
	connection.nextMessage[3]++
	for {
		connection.traceHandshake("settingsReadStart")
		frame, err := connection.readFrame()
		if err != nil {
			connection.traceHandshake("settingsReadFailed")
			return err
		}
		connection.traceHandshake(fmt.Sprintf("settingsFrameType%dFlags%d", frame.Type, frame.Flags))
		if frame.Type == HTTP2Settings && frame.Flags&HTTP2SettingsAck == 0 {
			break
		}
		if frame.Type == HTTP2WindowUpdate || (frame.Type == HTTP2Settings && frame.Flags&HTTP2SettingsAck != 0) {
			continue
		}
		return errors.New("remote XPC settings handshake")
	}
	connection.traceHandshake("settingsReadComplete")
	// Match the Python transport: complete the HTTP/2 settings exchange before
	// exposing the service, so an initial one-way HID event is not coalesced
	// with the pending acknowledgement.
	connection.traceHandshake("settingsAckWriteStart")
	if err := connection.writeFrame(HTTP2Frame{Type: HTTP2Settings, Flags: HTTP2SettingsAck}); err != nil {
		connection.traceHandshake("settingsAckWriteFailed")
		return err
	}
	connection.traceHandshake("settingsAckWriteComplete")
	return nil
}

func (connection *RemoteXPCConnection) SendRequest(value map[string]any, wantingReply bool) error {
	if connection == nil || connection.closed {
		return errors.New("remote XPC connection closed")
	}
	return connection.sendRequestLocked(value, wantingReply)
}

// SendDeviceHandshake announces the modern RemoteXPC capabilities on the RSD
// control connection. Service connections do not send this message.
func (connection *RemoteXPCConnection) SendDeviceHandshake() error {
	if connection == nil || connection.closed {
		return errors.New("remote XPC connection closed")
	}
	var identifier XPCUUID
	if _, err := rand.Read(identifier[:]); err != nil {
		return fmt.Errorf("generate RemoteXPC handshake UUID: %w", err)
	}
	identifier[6] = (identifier[6] & 0x0f) | 0x40
	identifier[8] = (identifier[8] & 0x3f) | 0x80
	return connection.sendRequestLockedOrdered(XPCOrderedDictionary{Entries: []XPCDictionaryEntry{
		{Key: "MessageType", Value: "Handshake"},
		{Key: "MessagingProtocolVersion", Value: XPCUInt64(messagingProtocolVersion)},
		{Key: "UUID", Value: identifier},
		{Key: "Properties", Value: XPCOrderedDictionary{Entries: []XPCDictionaryEntry{
			{Key: "RemoteXPCVersionFlags", Value: XPCUInt64(remoteXPCVersionFlags)},
			{Key: "SensitivePropertiesVisible", Value: true},
		}}},
		{Key: "Services", Value: map[string]any{}},
	}}, false)
}

func (connection *RemoteXPCConnection) ReceiveResponse(maximum int) (map[string]any, error) {
	if connection == nil || connection.closed {
		return nil, errors.New("remote XPC connection closed")
	}
	if maximum <= 0 || maximum > RemoteXPCMaxMessage {
		maximum = RemoteXPCMaxMessage
	}
	for {
		frame, err := connection.readFrame()
		if err != nil {
			return nil, err
		}
		if frame.Type != HTTP2Data {
			continue
		}
		if frame.StreamID%2 == 0 && len(frame.Payload) > 0 {
			var increment [4]byte
			binary.BigEndian.PutUint32(increment[:], uint32(len(frame.Payload)))
			if err := connection.writeFrame(HTTP2Frame{Type: HTTP2WindowUpdate, Payload: increment[:]}); err != nil {
				return nil, err
			}
			if err := connection.writeFrame(HTTP2Frame{Type: HTTP2WindowUpdate, StreamID: frame.StreamID, Payload: increment[:]}); err != nil {
				return nil, err
			}
		}
		connection.previousData = append(connection.previousData, frame.Payload...)
		if len(connection.previousData) > maximum {
			return nil, errors.New("remote XPC message cap")
		}
		wrapper, err := DecodeXPCWrapper(connection.previousData, maximum)
		if err != nil {
			continue
		}
		connection.previousData = nil
		connection.nextMessage[frame.StreamID] = wrapper.MessageID + 1
		if wrapper.Payload == nil {
			continue
		}
		value, ok := wrapper.Payload.(map[string]any)
		if !ok {
			return nil, errors.New("remote XPC response object")
		}
		// pymobiledevice3 ignores empty dictionaries emitted by the
		// RemoteXPC initialization exchange; the peer-info response follows.
		if len(value) == 0 {
			continue
		}
		return value, nil
	}
}

func (connection *RemoteXPCConnection) Close() error {
	if connection == nil || connection.closed {
		return nil
	}
	connection.closed = true
	return connection.conn.Close()
}

func (connection *RemoteXPCConnection) sendRequestLocked(value map[string]any, wantingReply bool) error {
	return connection.sendRequestObjectLocked(value, wantingReply)
}

func (connection *RemoteXPCConnection) sendRequestLockedOrdered(value XPCOrderedDictionary, wantingReply bool) error {
	return connection.sendRequestObjectLocked(value, wantingReply)
}

func (connection *RemoteXPCConnection) sendRequestObjectLocked(value any, wantingReply bool) error {
	encoded, err := encodeXPCWrapperObject(value, connection.nextMessage[1], wantingReply)
	if err != nil {
		return err
	}
	if err := connection.writeFrame(HTTP2Frame{Type: HTTP2Data, StreamID: 1, Payload: encoded}); err != nil {
		return err
	}
	connection.nextMessage[1]++
	return nil
}

func (connection *RemoteXPCConnection) openChannelLocked(streamID uint32, flags uint32) error {
	if err := connection.writeFrame(HTTP2Frame{Type: HTTP2Headers, Flags: HTTP2EndHeaders, StreamID: streamID}); err != nil {
		return err
	}
	if err := connection.writeFrame(HTTP2Frame{Type: HTTP2Data, StreamID: streamID, Payload: encodeXPCControl(flags|XPCAlwaysSet, 0)}); err != nil {
		return err
	}
	connection.nextMessage[streamID]++
	return nil
}

func (connection *RemoteXPCConnection) readFrame() (HTTP2Frame, error) {
	return ReadHTTP2Frame(connection.reader, RemoteXPCMaxFrame)
}

func (connection *RemoteXPCConnection) writeFrame(frame HTTP2Frame) error {
	return connection.writeFrames(frame)
}

func (connection *RemoteXPCConnection) writeFrames(frames ...HTTP2Frame) error {
	return connection.writePrefixedFrames("", frames...)
}

func (connection *RemoteXPCConnection) writePrefixedFrames(prefix string, frames ...HTTP2Frame) error {
	var output bytes.Buffer
	output.WriteString(prefix)
	for _, frame := range frames {
		encoded, err := frame.Encode()
		if err != nil {
			return err
		}
		output.Write(encoded)
	}
	_, err := connection.conn.Write(output.Bytes())
	return err
}

func encodeXPCControl(flags uint32, messageID uint64) []byte {
	var output bytes.Buffer
	_ = binary.Write(&output, binary.LittleEndian, uint32(0x29b00b92))
	_ = binary.Write(&output, binary.LittleEndian, flags)
	_ = binary.Write(&output, binary.LittleEndian, uint64(0))
	_ = binary.Write(&output, binary.LittleEndian, messageID)
	return output.Bytes()
}

type RSDService struct {
	Port          uint16
	UsesRemoteXPC bool
}

type RSDPeerInfo struct {
	UniqueDeviceID string
	ProductType    string
	OSVersion      string
	BuildVersion   string
	ECID           XPCUInt64
	Services       map[string]RSDService
}

func ParseRSDPeerInfo(value map[string]any, expectedUDID string) (RSDPeerInfo, error) {
	properties, ok := value["Properties"].(map[string]any)
	if !ok {
		return RSDPeerInfo{}, errors.New("RSD properties")
	}
	udid, ok := properties["UniqueDeviceID"].(string)
	if !ok || udid != expectedUDID || udid == "" {
		return RSDPeerInfo{}, errors.New("RSD target identity")
	}
	product, productOK := properties["ProductType"].(string)
	osVersion, osOK := properties["OSVersion"].(string)
	build, buildOK := properties["BuildVersion"].(string)
	if !productOK || !osOK || !buildOK || product == "" || osVersion == "" || build == "" {
		return RSDPeerInfo{}, errors.New("RSD properties")
	}
	servicesValue, ok := value["Services"].(map[string]any)
	if !ok || len(servicesValue) == 0 {
		return RSDPeerInfo{}, errors.New("RSD services")
	}
	services := make(map[string]RSDService, len(servicesValue))
	for name, raw := range servicesValue {
		entry, ok := raw.(map[string]any)
		if !ok {
			return RSDPeerInfo{}, errors.New("RSD service entry")
		}
		portValue, ok := numberAsUint16(entry["Port"])
		if !ok || portValue == 0 {
			return RSDPeerInfo{}, errors.New("RSD service port")
		}
		uses, _ := entry["Properties"].(map[string]any)
		remote, _ := uses["UsesRemoteXPC"].(bool)
		services[name] = RSDService{Port: portValue, UsesRemoteXPC: remote}
	}
	result := RSDPeerInfo{UniqueDeviceID: udid, ProductType: product, OSVersion: osVersion, BuildVersion: build, Services: services}
	if ecid, ok := properties["UniqueChipID"].(XPCUInt64); ok {
		result.ECID = ecid
	}
	return result, nil
}

func (info RSDPeerInfo) ServiceNames() []string {
	result := make([]string, 0, len(info.Services))
	for name := range info.Services {
		result = append(result, name)
	}
	sort.Strings(result)
	return result
}

func numberAsUint16(value any) (uint16, bool) {
	switch number := value.(type) {
	case XPCUInt64:
		if number <= 0 || number > 65535 {
			return 0, false
		}
		return uint16(number), true
	case uint64:
		if number == 0 || number > 65535 {
			return 0, false
		}
		return uint16(number), true
	case int64:
		if number <= 0 || number > 65535 {
			return 0, false
		}
		return uint16(number), true
	case string:
		parsed, err := strconv.ParseUint(number, 10, 16)
		if err != nil || parsed == 0 {
			return 0, false
		}
		return uint16(parsed), true
	default:
		return 0, false
	}
}

func (info RSDPeerInfo) String() string {
	return fmt.Sprintf("%s %s %s %s", info.ProductType, info.OSVersion, info.BuildVersion, info.UniqueDeviceID)
}
