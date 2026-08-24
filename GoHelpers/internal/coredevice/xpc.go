package coredevice

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"math"
	"sort"
)

const (
	xpcNull         = 0x00001000
	xpcBool         = 0x00002000
	xpcInt64        = 0x00003000
	xpcUInt64       = 0x00004000
	xpcDouble       = 0x00005000
	xpcData         = 0x00008000
	xpcString       = 0x00009000
	xpcUUID         = 0x0000a000
	xpcArray        = 0x0000e000
	xpcDictionary   = 0x0000f000
	xpcFileTransfer = 0x0001a000
)

const (
	XPCAlwaysSet     uint32 = 0x00000001
	XPCDataPresent   uint32 = 0x00000100
	XPCWantingReply  uint32 = 0x00010000
	XPCReply         uint32 = 0x00020000
	XPCInitHandshake uint32 = 0x00400000
)

type XPCInt64 int64
type XPCUInt64 uint64
type XPCUUID [16]byte

type XPCOrderedDictionary struct {
	Entries []XPCDictionaryEntry
}

type XPCDictionaryEntry struct {
	Key   string
	Value any
}

type XPCWrapper struct {
	Flags     uint32
	MessageID uint64
	Payload   any
}

func EncodeXPCWrapper(value map[string]any, messageID uint64, wantingReply bool) ([]byte, error) {
	return encodeXPCWrapperObject(value, messageID, wantingReply)
}

func encodeXPCWrapperObject(value any, messageID uint64, wantingReply bool) ([]byte, error) {
	flags := XPCAlwaysSet
	if dictionaryHasEntries(value) {
		flags |= XPCDataPresent
	}
	if wantingReply {
		flags |= XPCWantingReply
	}
	payload, err := encodeXPCObject(value)
	if err != nil {
		return nil, err
	}
	var body bytes.Buffer
	_ = binary.Write(&body, binary.LittleEndian, uint32(0x42133742))
	_ = binary.Write(&body, binary.LittleEndian, uint32(5))
	body.Write(payload)
	messageLength := uint64(body.Len())
	var output bytes.Buffer
	_ = binary.Write(&output, binary.LittleEndian, uint32(0x29b00b92))
	_ = binary.Write(&output, binary.LittleEndian, flags)
	_ = binary.Write(&output, binary.LittleEndian, messageLength)
	_ = binary.Write(&output, binary.LittleEndian, messageID)
	if len(payload) > 0 {
		output.Write(body.Bytes())
	}
	return output.Bytes(), nil
}

func dictionaryHasEntries(value any) bool {
	switch dictionary := value.(type) {
	case map[string]any:
		return len(dictionary) > 0
	case XPCOrderedDictionary:
		return len(dictionary.Entries) > 0
	default:
		return true
	}
}

func DecodeXPCWrapper(data []byte, maximum int) (XPCWrapper, error) {
	if len(data) < 24 || len(data) > maximum {
		return XPCWrapper{}, errors.New("xpc wrapper size")
	}
	reader := bytes.NewReader(data)
	var magic, flags uint32
	var length, messageID uint64
	_ = binary.Read(reader, binary.LittleEndian, &magic)
	_ = binary.Read(reader, binary.LittleEndian, &flags)
	_ = binary.Read(reader, binary.LittleEndian, &length)
	_ = binary.Read(reader, binary.LittleEndian, &messageID)
	if magic != 0x29b00b92 || (length != 0 && length < 8) || length > uint64(len(data)-16) {
		return XPCWrapper{}, errors.New("xpc wrapper header")
	}
	if length == 0 && len(data) != 24 {
		return XPCWrapper{}, errors.New("xpc control wrapper size")
	}
	if reader.Len() == 0 {
		return XPCWrapper{Flags: flags, MessageID: messageID}, nil
	}
	var payloadMagic, version uint32
	if err := binary.Read(reader, binary.LittleEndian, &payloadMagic); err != nil {
		return XPCWrapper{}, err
	}
	if err := binary.Read(reader, binary.LittleEndian, &version); err != nil || payloadMagic != 0x42133742 || version != 5 {
		return XPCWrapper{}, errors.New("xpc payload header")
	}
	value, err := decodeXPCObject(reader, 0, maximum)
	if err != nil || reader.Len() != 0 {
		return XPCWrapper{}, errors.New("xpc payload")
	}
	return XPCWrapper{Flags: flags, MessageID: messageID, Payload: value}, nil
}

func encodeXPCObject(value any) ([]byte, error) {
	var typeID uint32
	var body []byte
	switch item := value.(type) {
	case nil:
		typeID = xpcNull
	case bool:
		typeID = xpcBool
		body = make([]byte, 4)
		if item {
			binary.LittleEndian.PutUint32(body, 1)
		}
	case XPCInt64:
		typeID = xpcInt64
		body = make([]byte, 8)
		binary.LittleEndian.PutUint64(body, uint64(item))
	case int64:
		typeID = xpcInt64
		body = make([]byte, 8)
		binary.LittleEndian.PutUint64(body, uint64(item))
	case XPCUInt64:
		typeID = xpcUInt64
		body = make([]byte, 8)
		binary.LittleEndian.PutUint64(body, uint64(item))
	case uint64:
		typeID = xpcUInt64
		body = make([]byte, 8)
		binary.LittleEndian.PutUint64(body, item)
	case float64:
		typeID = xpcDouble
		body = make([]byte, 8)
		binary.LittleEndian.PutUint64(body, math.Float64bits(item))
	case string:
		typeID = xpcString
		body = prefixedString([]byte(item))
	case []byte:
		typeID = xpcData
		body = prefixedBytes(item)
	case XPCUUID:
		typeID = xpcUUID
		body = append([]byte(nil), item[:]...)
	case []any:
		typeID = xpcArray
		var inner bytes.Buffer
		_ = binary.Write(&inner, binary.LittleEndian, uint32(len(item)))
		for _, child := range item {
			encoded, err := encodeXPCObject(child)
			if err != nil {
				return nil, err
			}
			inner.Write(encoded)
		}
		body = prefixedBytes(inner.Bytes())
	case map[string]any:
		typeID = xpcDictionary
		keys := make([]string, 0, len(item))
		for key := range item {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		var inner bytes.Buffer
		_ = binary.Write(&inner, binary.LittleEndian, uint32(len(keys)))
		for _, key := range keys {
			inner.Write(align4(append([]byte(key), 0)))
			encoded, err := encodeXPCObject(item[key])
			if err != nil {
				return nil, err
			}
			inner.Write(encoded)
		}
		body = prefixedBytes(inner.Bytes())
	case XPCOrderedDictionary:
		typeID = xpcDictionary
		var inner bytes.Buffer
		_ = binary.Write(&inner, binary.LittleEndian, uint32(len(item.Entries)))
		for _, entry := range item.Entries {
			inner.Write(align4(append([]byte(entry.Key), 0)))
			encoded, err := encodeXPCObject(entry.Value)
			if err != nil {
				return nil, err
			}
			inner.Write(encoded)
		}
		body = prefixedBytes(inner.Bytes())
	default:
		return nil, fmt.Errorf("unsupported xpc value %T", value)
	}
	var output bytes.Buffer
	_ = binary.Write(&output, binary.LittleEndian, typeID)
	output.Write(body)
	return output.Bytes(), nil
}

func decodeXPCObject(reader *bytes.Reader, depth, maximum int) (any, error) {
	if depth > 32 {
		return nil, errors.New("xpc nesting")
	}
	var typeID uint32
	if err := binary.Read(reader, binary.LittleEndian, &typeID); err != nil {
		return nil, err
	}
	switch typeID {
	case xpcNull:
		return nil, nil
	case xpcBool:
		var value uint32
		if err := binary.Read(reader, binary.LittleEndian, &value); err != nil || value > 1 {
			return nil, errors.New("xpc bool")
		}
		return value == 1, nil
	case xpcInt64:
		var value int64
		if err := binary.Read(reader, binary.LittleEndian, &value); err != nil {
			return nil, err
		}
		return XPCInt64(value), nil
	case xpcUInt64:
		var value uint64
		if err := binary.Read(reader, binary.LittleEndian, &value); err != nil {
			return nil, err
		}
		return XPCUInt64(value), nil
	case xpcDouble:
		var bits uint64
		if err := binary.Read(reader, binary.LittleEndian, &bits); err != nil {
			return nil, err
		}
		value := math.Float64frombits(bits)
		if math.IsNaN(value) || math.IsInf(value, 0) {
			return nil, errors.New("xpc nonfinite double")
		}
		return value, nil
	case xpcString:
		data, err := readPrefixed(reader, maximum)
		if err != nil || len(data) == 0 || data[len(data)-1] != 0 {
			return nil, errors.New("xpc string")
		}
		return string(data[:len(data)-1]), nil
	case xpcData:
		data, err := readPrefixed(reader, maximum)
		return data, err
	case xpcUUID:
		var value XPCUUID
		if _, err := reader.Read(value[:]); err != nil {
			return nil, err
		}
		return value, nil
	case xpcArray:
		data, err := readPrefixed(reader, maximum)
		if err != nil || len(data) < 4 {
			return nil, errors.New("xpc array")
		}
		child := bytes.NewReader(data)
		var count uint32
		_ = binary.Read(child, binary.LittleEndian, &count)
		if count > 65536 {
			return nil, errors.New("xpc array count")
		}
		result := make([]any, 0, count)
		for index := uint32(0); index < count; index++ {
			value, err := decodeXPCObject(child, depth+1, maximum)
			if err != nil {
				return nil, err
			}
			result = append(result, value)
		}
		if child.Len() != 0 {
			return nil, errors.New("xpc array trailing")
		}
		return result, nil
	case xpcDictionary:
		data, err := readPrefixed(reader, maximum)
		if err != nil || len(data) < 4 {
			return nil, errors.New("xpc dictionary")
		}
		child := bytes.NewReader(data)
		var count uint32
		_ = binary.Read(child, binary.LittleEndian, &count)
		if count > 65536 {
			return nil, errors.New("xpc dictionary count")
		}
		result := make(map[string]any, count)
		for index := uint32(0); index < count; index++ {
			keyBytes, err := readAlignedCString(child, maximum)
			if err != nil {
				return nil, err
			}
			key := string(keyBytes)
			if _, exists := result[key]; exists {
				return nil, errors.New("xpc duplicate key")
			}
			value, err := decodeXPCObject(child, depth+1, maximum)
			if err != nil {
				return nil, err
			}
			result[key] = value
		}
		if child.Len() != 0 {
			return nil, errors.New("xpc dictionary trailing")
		}
		return result, nil
	default:
		return nil, fmt.Errorf("unsupported xpc type 0x%x", typeID)
	}
}

func prefixedBytes(value []byte) []byte {
	output := make([]byte, 4+len(value))
	binary.LittleEndian.PutUint32(output, uint32(len(value)))
	copy(output[4:], value)
	return append(output, make([]byte, (4-len(value)%4)%4)...)
}
func prefixedString(value []byte) []byte {
	return prefixedBytes(append(append([]byte(nil), value...), 0))
}
func align4(value []byte) []byte { return append(value, make([]byte, (4-len(value)%4)%4)...) }
func readPrefixed(reader *bytes.Reader, maximum int) ([]byte, error) {
	var length uint32
	if err := binary.Read(reader, binary.LittleEndian, &length); err != nil || length > uint32(maximum) {
		return nil, errors.New("xpc length")
	}
	if int(length) > reader.Len() {
		return nil, errors.New("xpc truncated")
	}
	value := make([]byte, length)
	_, _ = reader.Read(value)
	padding := (4 - int(length)%4) % 4
	if padding > reader.Len() {
		return nil, errors.New("xpc padding")
	}
	_, _ = reader.Seek(int64(padding), 1)
	return value, nil
}
func readAlignedCString(reader *bytes.Reader, maximum int) ([]byte, error) {
	limit := reader.Len()
	if limit > maximum {
		limit = maximum
	}
	value := make([]byte, 0, limit)
	for reader.Len() > 0 && len(value) <= maximum {
		byteValue, _ := reader.ReadByte()
		if byteValue == 0 {
			padding := (4 - (len(value)+1)%4) % 4
			if padding > reader.Len() {
				return nil, errors.New("xpc string padding")
			}
			_, _ = reader.Seek(int64(padding), 1)
			return value, nil
		}
		value = append(value, byteValue)
	}
	return nil, errors.New("xpc cstring")
}
