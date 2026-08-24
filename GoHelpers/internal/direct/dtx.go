package direct

import (
	"encoding/binary"
	"fmt"
	"math"
	"net"
	"time"
)

const (
	dtxMagic             = uint32(0x1f3d5b79)
	dtxHeaderSize        = 32
	dtxPayloadHeaderSize = 16
	dtxExpectsReply      = uint32(1)
	dtxMaxMessageSize    = 128 * 1024 * 1024
)

type dtxMessage struct {
	typ          byte
	aux          []byte
	payload      []byte
	identifier   uint32
	conversation int32
	channel      int32
	flags        uint32
}

type dtxInt32 int32
type dtxString string

type dtxConnection struct {
	conn     net.Conn
	deadline time.Time
	nextID   uint32
}

func newDTXConnection(conn net.Conn, deadline time.Time) *dtxConnection {
	return &dtxConnection{conn: conn, deadline: deadline, nextID: 1}
}

func (connection *dtxConnection) close() error {
	if connection == nil || connection.conn == nil {
		return nil
	}
	err := connection.conn.Close()
	connection.conn = nil
	return err
}

func (connection *dtxConnection) handshake() error {
	return connection.handshakeWithCapabilities(map[string]any{
		"com.apple.private.DTXBlockCompression": int64(0),
		"com.apple.private.DTXConnection":       int64(1),
	})
}

func (connection *dtxConnection) handshakeWithCapabilities(capabilities map[string]any) error {
	if len(capabilities) == 0 {
		return fmt.Errorf("DTX capabilities missing")
	}
	if _, err := connection.sendDispatch(0, "_notifyOfPublishedCapabilities:", []any{capabilities}, false); err != nil {
		return err
	}
	for {
		message, err := connection.receive()
		if err != nil {
			return err
		}
		if message.conversation != 0 {
			continue
		}
		method, args, err := decodeDTXInvocation(message)
		if err != nil {
			return err
		}
		if method == "_notifyOfPublishedCapabilities:" && len(args) == 1 {
			if message.flags&dtxExpectsReply != 0 {
				return connection.sendReplyAck(message)
			}
			return nil
		}
	}
}

func (connection *dtxConnection) openChannel(identifier string) (int32, error) {
	code := int32(1)
	if _, err := connection.request(0, "_requestChannelWithCode:identifier:", []any{dtxInt32(code), identifier}); err != nil {
		return 0, err
	}
	return code, nil
}

func (connection *dtxConnection) invoke(channel int32, method string, args ...any) (any, error) {
	return connection.request(channel, method, args)
}

func (connection *dtxConnection) request(channel int32, method string, args []any) (any, error) {
	identifier, err := connection.sendDispatch(channel, method, args, true)
	if err != nil {
		return nil, err
	}
	for {
		message, err := connection.receive()
		if err != nil {
			return nil, err
		}
		if message.conversation == 0 {
			continue
		}
		if message.identifier != identifier {
			continue
		}
		switch message.typ {
		case 0:
			return nil, nil
		case 3:
			if len(message.payload) == 0 {
				return nil, nil
			}
			return decodeNSKeyedArchive(message.payload)
		case 4:
			value, decodeErr := decodeNSKeyedArchive(message.payload)
			if decodeErr != nil {
				return nil, fmt.Errorf("DTX service error")
			}
			return nil, fmt.Errorf("DTX service rejected request: %v", value)
		default:
			return nil, fmt.Errorf("unexpected DTX reply type %d", message.typ)
		}
	}
}

func (connection *dtxConnection) sendDispatch(channel int32, method string, args []any, expectsReply bool) (uint32, error) {
	identifier := connection.nextID
	connection.nextID++
	aux, err := encodeDTXAux(args)
	if err != nil {
		return 0, err
	}
	payload, err := encodeNSKeyedArchive(method)
	if err != nil {
		return 0, err
	}
	flags := uint32(0)
	if expectsReply {
		flags = dtxExpectsReply
	}
	return connection.send(dtxMessage{typ: 2, aux: aux, payload: payload, identifier: identifier, channel: channel, flags: flags})
}

func (connection *dtxConnection) sendReplyAck(request dtxMessage) error {
	_, err := connection.send(dtxMessage{typ: 0, identifier: request.identifier, conversation: request.conversation + 1, channel: request.channel})
	return err
}

func (connection *dtxConnection) send(message dtxMessage) (uint32, error) {
	if connection == nil || connection.conn == nil {
		return 0, fmt.Errorf("DTX connection closed")
	}
	payloadHeader := make([]byte, dtxPayloadHeaderSize)
	payloadHeader[0] = message.typ
	binary.LittleEndian.PutUint32(payloadHeader[4:8], uint32(len(message.aux)))
	binary.LittleEndian.PutUint32(payloadHeader[8:12], uint32(len(message.aux)+len(message.payload)))
	body := append(payloadHeader, message.aux...)
	body = append(body, message.payload...)
	if len(body) == 0 || len(body) > dtxMaxMessageSize {
		return 0, fmt.Errorf("DTX message size")
	}
	wireChannel := message.channel
	if message.conversation%2 != 0 {
		wireChannel = -wireChannel
	}
	header := make([]byte, dtxHeaderSize)
	binary.LittleEndian.PutUint32(header[0:4], dtxMagic)
	binary.LittleEndian.PutUint32(header[4:8], dtxHeaderSize)
	binary.LittleEndian.PutUint16(header[8:10], 0)
	binary.LittleEndian.PutUint16(header[10:12], 1)
	binary.LittleEndian.PutUint32(header[12:16], uint32(len(body)))
	binary.LittleEndian.PutUint32(header[16:20], message.identifier)
	binary.LittleEndian.PutUint32(header[20:24], uint32(message.conversation))
	binary.LittleEndian.PutUint32(header[24:28], uint32(wireChannel))
	binary.LittleEndian.PutUint32(header[28:32], message.flags)
	if err := writeDeadline(connection.conn, append(header, body...), connection.deadline); err != nil {
		return 0, err
	}
	return message.identifier, nil
}

func (connection *dtxConnection) receive() (dtxMessage, error) {
	var first dtxMessage
	firstHeader, err := connection.receiveFragmentHeader()
	if err != nil {
		return dtxMessage{}, err
	}
	if firstHeader.count == 0 || firstHeader.index >= firstHeader.count || firstHeader.dataSize == 0 {
		return dtxMessage{}, fmt.Errorf("invalid DTX fragment")
	}
	if firstHeader.headerSize > dtxHeaderSize {
		extra := make([]byte, firstHeader.headerSize-dtxHeaderSize)
		if err := readDeadline(connection.conn, extra, connection.deadline); err != nil {
			return dtxMessage{}, err
		}
	}
	var body []byte
	if firstHeader.count == 1 {
		body = make([]byte, firstHeader.dataSize)
		if err := readDeadline(connection.conn, body, connection.deadline); err != nil {
			return dtxMessage{}, err
		}
	} else {
		if firstHeader.dataSize > dtxMaxMessageSize {
			return dtxMessage{}, fmt.Errorf("DTX message too large")
		}
		body = make([]byte, 0, firstHeader.dataSize)
		for index := uint16(1); index < firstHeader.count; index++ {
			header, err := connection.receiveFragmentHeader()
			if err != nil {
				return dtxMessage{}, err
			}
			if header.index != index || header.identifier != firstHeader.identifier || header.dataSize == 0 {
				return dtxMessage{}, fmt.Errorf("invalid DTX fragment sequence")
			}
			if header.headerSize > dtxHeaderSize {
				extra := make([]byte, header.headerSize-dtxHeaderSize)
				if err := readDeadline(connection.conn, extra, connection.deadline); err != nil {
					return dtxMessage{}, err
				}
			}
			part := make([]byte, header.dataSize)
			if err := readDeadline(connection.conn, part, connection.deadline); err != nil {
				return dtxMessage{}, err
			}
			body = append(body, part...)
		}
		if len(body) != int(firstHeader.dataSize) {
			return dtxMessage{}, fmt.Errorf("DTX fragment size mismatch")
		}
	}
	if len(body) < dtxPayloadHeaderSize {
		return dtxMessage{}, fmt.Errorf("DTX payload header missing")
	}
	auxSize := binary.LittleEndian.Uint32(body[4:8])
	totalSize := binary.LittleEndian.Uint32(body[8:12])
	if totalSize != uint32(len(body)-dtxPayloadHeaderSize) || auxSize > totalSize {
		return dtxMessage{}, fmt.Errorf("DTX payload size mismatch")
	}
	first = dtxMessage{
		typ:          body[0],
		aux:          append([]byte(nil), body[dtxPayloadHeaderSize:dtxPayloadHeaderSize+int(auxSize)]...),
		payload:      append([]byte(nil), body[dtxPayloadHeaderSize+int(auxSize):]...),
		identifier:   firstHeader.identifier,
		conversation: firstHeader.conversation,
		channel:      firstHeader.channel,
		flags:        firstHeader.flags,
	}
	return first, nil
}

type dtxFragmentHeader struct {
	headerSize   uint32
	index        uint16
	count        uint16
	dataSize     uint32
	identifier   uint32
	conversation int32
	channel      int32
	flags        uint32
}

func (connection *dtxConnection) receiveFragmentHeader() (dtxFragmentHeader, error) {
	header := make([]byte, dtxHeaderSize)
	if err := readDeadline(connection.conn, header, connection.deadline); err != nil {
		return dtxFragmentHeader{}, err
	}
	if binary.LittleEndian.Uint32(header[0:4]) != dtxMagic {
		return dtxFragmentHeader{}, fmt.Errorf("invalid DTX magic")
	}
	return dtxFragmentHeader{
		headerSize:   binary.LittleEndian.Uint32(header[4:8]),
		index:        binary.LittleEndian.Uint16(header[8:10]),
		count:        binary.LittleEndian.Uint16(header[10:12]),
		dataSize:     binary.LittleEndian.Uint32(header[12:16]),
		identifier:   binary.LittleEndian.Uint32(header[16:20]),
		conversation: int32(binary.LittleEndian.Uint32(header[20:24])),
		channel:      int32(binary.LittleEndian.Uint32(header[24:28])),
		flags:        binary.LittleEndian.Uint32(header[28:32]),
	}, nil
}

func decodeDTXInvocation(message dtxMessage) (string, []any, error) {
	value, err := decodeNSKeyedArchive(message.payload)
	if err != nil {
		return "", nil, err
	}
	method, ok := value.(string)
	if !ok {
		return "", nil, fmt.Errorf("DTX method is not string")
	}
	args, err := decodeDTXAux(message.aux)
	return method, args, err
}

func encodeDTXAux(args []any) ([]byte, error) {
	var body []byte
	appendPrimitive := func(value []byte) { body = append(body, value...) }
	for _, arg := range args {
		// PrimitiveDictionary writes one key/value pair per positional
		// argument, even when every key is the same null primitive.
		key := make([]byte, 4)
		binary.LittleEndian.PutUint32(key, 10)
		appendPrimitive(key)
		switch value := arg.(type) {
		case dtxInt32:
			primitive := make([]byte, 8)
			binary.LittleEndian.PutUint32(primitive[0:4], 3)
			binary.LittleEndian.PutUint32(primitive[4:8], uint32(int32(value)))
			appendPrimitive(primitive)
		default:
			var archive []byte
			var err error
			if value == nil {
				archive = nil
			} else {
				archive, err = encodeNSKeyedArchive(value)
				if err != nil {
					return nil, err
				}
			}
			primitive := make([]byte, 8)
			binary.LittleEndian.PutUint32(primitive[0:4], 2)
			binary.LittleEndian.PutUint32(primitive[4:8], uint32(len(archive)))
			appendPrimitive(primitive)
			appendPrimitive(archive)
		}
	}
	header := make([]byte, 16)
	binary.LittleEndian.PutUint32(header[0:4], 0x1f0)
	binary.LittleEndian.PutUint64(header[8:16], uint64(len(body)))
	return append(header, body...), nil
}

func decodeDTXAux(data []byte) ([]any, error) {
	if len(data) == 0 {
		return nil, nil
	}
	if len(data) < 16 || binary.LittleEndian.Uint32(data[0:4])&0xff != 0xf0 {
		return nil, fmt.Errorf("invalid DTX aux dictionary")
	}
	bodySize := binary.LittleEndian.Uint64(data[8:16])
	if bodySize > uint64(len(data)-16) {
		return nil, fmt.Errorf("DTX aux body size")
	}
	body := data[16 : 16+int(bodySize)]
	args := make([]any, 0)
	for len(body) > 0 {
		if len(body) < 4 || binary.LittleEndian.Uint32(body[:4]) != 10 {
			return nil, fmt.Errorf("DTX aux null key")
		}
		body = body[4:]
		if len(body) < 4 {
			return nil, fmt.Errorf("DTX aux primitive header")
		}
		typ := binary.LittleEndian.Uint32(body[:4])
		body = body[4:]
		switch typ {
		case 2:
			if len(body) < 4 {
				return nil, fmt.Errorf("DTX aux buffer length")
			}
			length := binary.LittleEndian.Uint32(body[:4])
			body = body[4:]
			if uint64(length) > uint64(len(body)) {
				return nil, fmt.Errorf("DTX aux buffer")
			}
			if length == 0 {
				args = append(args, nil)
			} else {
				value, err := decodeNSKeyedArchive(body[:length])
				if err != nil {
					return nil, err
				}
				args = append(args, value)
			}
			body = body[length:]
		case 3:
			if len(body) < 4 {
				return nil, fmt.Errorf("DTX aux int32")
			}
			args = append(args, int32(binary.LittleEndian.Uint32(body[:4])))
			body = body[4:]
		case 6:
			if len(body) < 8 {
				return nil, fmt.Errorf("DTX aux int64")
			}
			args = append(args, int64(binary.LittleEndian.Uint64(body[:8])))
			body = body[8:]
		case 9:
			if len(body) < 8 {
				return nil, fmt.Errorf("DTX aux double")
			}
			args = append(args, math.Float64frombits(binary.LittleEndian.Uint64(body[:8])))
			body = body[8:]
		default:
			return nil, fmt.Errorf("unsupported DTX aux primitive %d", typ)
		}
	}
	return args, nil
}
