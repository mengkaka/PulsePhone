package direct

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"encoding/xml"
	"fmt"
	"math"
	"strconv"
	"unicode/utf16"
	"unicode/utf8"
)

func encodePlist(value map[string]any) ([]byte, error) {
	return encodePlistDocument(value)
}

func encodePlistDocument(value any) ([]byte, error) {
	var out bytes.Buffer
	out.WriteString("<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n")
	out.WriteString("<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n")
	out.WriteString("<plist version=\"1.0\">")
	if err := encodePlistValue(&out, value); err != nil {
		return nil, err
	}
	out.WriteString("</plist>")
	return out.Bytes(), nil
}

func encodePlistValue(out *bytes.Buffer, value any) error {
	switch value := value.(type) {
	case string:
		out.WriteString("<string>")
		xml.EscapeText(out, []byte(value))
		out.WriteString("</string>")
	case bool:
		if value {
			out.WriteString("<true/>")
		} else {
			out.WriteString("<false/>")
		}
	case int:
		fmt.Fprintf(out, "<integer>%d</integer>", value)
	case int64:
		fmt.Fprintf(out, "<integer>%d</integer>", value)
	case uint64:
		fmt.Fprintf(out, "<integer>%d</integer>", value)
	case []any:
		out.WriteString("<array>")
		for _, child := range value {
			if err := encodePlistValue(out, child); err != nil {
				return err
			}
		}
		out.WriteString("</array>")
	case []byte:
		out.WriteString("<data>")
		out.WriteString(base64.StdEncoding.EncodeToString(value))
		out.WriteString("</data>")
	case map[string]any:
		out.WriteString("<dict>")
		keys := make([]string, 0, len(value))
		for key := range value {
			keys = append(keys, key)
		}
		for i := 1; i < len(keys); i++ {
			key := keys[i]
			j := i
			for j > 0 && keys[j-1] > key {
				keys[j] = keys[j-1]
				j--
			}
			keys[j] = key
		}
		for _, key := range keys {
			out.WriteString("<key>")
			xml.EscapeText(out, []byte(key))
			out.WriteString("</key>")
			if err := encodePlistValue(out, value[key]); err != nil {
				return err
			}
		}
		out.WriteString("</dict>")
	default:
		return fmt.Errorf("unsupported plist value %T", value)
	}
	return nil
}

func decodePlist(data []byte) (map[string]any, error) {
	value, err := decodePlistValue(data)
	if err != nil {
		return nil, err
	}
	result, ok := value.(map[string]any)
	if !ok {
		return nil, fmt.Errorf("plist root is not a dictionary")
	}
	return result, nil
}

func decodePlistValue(data []byte) (any, error) {
	if bytes.HasPrefix(data, []byte("bplist00")) {
		return decodeBinaryPlist(data)
	}
	decoder := xml.NewDecoder(bytes.NewReader(data))
	for {
		token, err := decoder.Token()
		if err != nil {
			return nil, err
		}
		start, ok := token.(xml.StartElement)
		if !ok {
			continue
		}
		if start.Name.Local == "plist" {
			return nextPlistValue(decoder)
		}
	}
}

// EncodePlistDocument exposes the framed-plist codec to CoreDevice services
// that use the same plist wire format without making the parser public.
func EncodePlistDocument(value any) ([]byte, error) {
	return encodePlistDocument(value)
}

// DecodePlistValue exposes the framed-plist decoder to CoreDevice services.
func DecodePlistValue(data []byte) (any, error) {
	return decodePlistValue(data)
}

// decodeBinaryPlist covers the object types used by usbmuxd pairing records and
// keeps the parser independent of external plist tooling in the shipped helper.
func decodeBinaryPlist(data []byte) (any, error) {
	if len(data) < 40 || !bytes.Equal(data[:8], []byte("bplist00")) {
		return nil, fmt.Errorf("invalid binary plist header")
	}
	trailer := data[len(data)-32:]
	offsetSize := int(trailer[6])
	refSize := int(trailer[7])
	numObjects := binary.BigEndian.Uint64(trailer[8:16])
	topObject := binary.BigEndian.Uint64(trailer[16:24])
	offsetTable := binary.BigEndian.Uint64(trailer[24:32])
	if offsetSize < 1 || offsetSize > 8 || refSize < 1 || refSize > 8 ||
		numObjects == 0 || numObjects > 1<<20 || topObject >= numObjects ||
		offsetTable >= uint64(len(data)) {
		return nil, fmt.Errorf("invalid binary plist trailer")
	}
	tableBytes := numObjects * uint64(offsetSize)
	if tableBytes > uint64(len(data))-offsetTable {
		return nil, fmt.Errorf("invalid binary plist offset table")
	}
	offsets := make([]uint64, int(numObjects))
	for i := range offsets {
		start := int(offsetTable) + i*offsetSize
		offset, ok := readSizedUnsigned(data[start : start+offsetSize])
		if !ok || offset >= uint64(len(data)-32) {
			return nil, fmt.Errorf("invalid binary plist object offset")
		}
		offsets[i] = offset
	}
	parser := binaryPlistParser{
		data:       data,
		offsets:    offsets,
		refSize:    refSize,
		visiting:   make(map[uint64]bool),
		decoded:    make(map[uint64]any),
		maxObjects: numObjects,
	}
	return parser.object(topObject)
}

type binaryPlistParser struct {
	data       []byte
	offsets    []uint64
	refSize    int
	visiting   map[uint64]bool
	decoded    map[uint64]any
	maxObjects uint64
}

func (p *binaryPlistParser) object(reference uint64) (any, error) {
	if reference >= p.maxObjects {
		return nil, fmt.Errorf("binary plist object reference out of range")
	}
	if value, ok := p.decoded[reference]; ok {
		return value, nil
	}
	if p.visiting[reference] {
		return nil, fmt.Errorf("binary plist cycle")
	}
	p.visiting[reference] = true
	defer delete(p.visiting, reference)
	start := p.offsets[reference]
	if start >= uint64(len(p.data)) {
		return nil, fmt.Errorf("binary plist object offset out of range")
	}
	marker := p.data[start]
	kind, info := marker>>4, marker&0x0f
	position := start + 1
	var length, next uint64
	var err error
	switch kind {
	case 0x1:
		if info > 3 {
			return nil, fmt.Errorf("invalid binary plist integer size")
		}
		length = uint64(1) << info
		next = position
	case 0x2:
		if info != 2 && info != 3 {
			return nil, fmt.Errorf("invalid binary plist real size")
		}
		length = uint64(1) << info
		next = position
	case 0x3:
		if info != 3 {
			return nil, fmt.Errorf("invalid binary plist date size")
		}
		length = 8
		next = position
	case 0x8:
		if info > 7 {
			return nil, fmt.Errorf("invalid binary plist uid size")
		}
		length = uint64(info) + 1
		next = position
	default:
		length, next, err = p.length(info, position)
		if err != nil {
			return nil, err
		}
	}
	position = next
	var value any
	switch kind {
	case 0x0:
		switch info {
		case 0x0:
			value = nil
		case 0x8:
			value = false
		case 0x9:
			value = true
		default:
			return nil, fmt.Errorf("unsupported binary plist simple object")
		}
	case 0x1:
		if length == 0 || length > 8 || position+length > uint64(len(p.data)) {
			return nil, fmt.Errorf("invalid binary plist integer")
		}
		number, _ := readSizedUnsigned(p.data[position : position+length])
		if length == 8 {
			value = int64(number)
		} else {
			value = int64(number)
		}
	case 0x2:
		if length != 4 && length != 8 || position+length > uint64(len(p.data)) {
			return nil, fmt.Errorf("invalid binary plist real")
		}
		if length == 4 {
			value = float64(math.Float32frombits(binary.BigEndian.Uint32(p.data[position : position+4])))
		} else {
			value = math.Float64frombits(binary.BigEndian.Uint64(p.data[position : position+8]))
		}
	case 0x3:
		if length != 8 || position+length > uint64(len(p.data)) {
			return nil, fmt.Errorf("invalid binary plist date")
		}
		// Pair records do not use dates. Preserve the raw value rather than
		// silently inventing a timezone conversion if one is encountered.
		value = math.Float64frombits(binary.BigEndian.Uint64(p.data[position : position+8]))
	case 0x4:
		if position+length > uint64(len(p.data)) {
			return nil, fmt.Errorf("invalid binary plist data")
		}
		value = append([]byte(nil), p.data[position:position+length]...)
	case 0x5:
		if position+length > uint64(len(p.data)) || !utf8.Valid(p.data[position:position+length]) {
			return nil, fmt.Errorf("invalid binary plist ascii string")
		}
		value = string(p.data[position : position+length])
	case 0x6:
		if length > (uint64(len(p.data))-position)/2 {
			return nil, fmt.Errorf("invalid binary plist unicode string")
		}
		units := make([]uint16, length)
		for i := range units {
			units[i] = binary.BigEndian.Uint16(p.data[position+uint64(i*2) : position+uint64(i*2+2)])
		}
		value = string(utf16.Decode(units))
	case 0x7:
		if position+length > uint64(len(p.data)) || !utf8.Valid(p.data[position:position+length]) {
			return nil, fmt.Errorf("invalid binary plist utf8 string")
		}
		value = string(p.data[position : position+length])
	case 0x8:
		if length == 0 || length > 8 || position+length > uint64(len(p.data)) {
			return nil, fmt.Errorf("invalid binary plist uid")
		}
		uid, _ := readSizedUnsigned(p.data[position : position+length])
		value = uid
	case 0xa, 0xc:
		refs, err := p.references(position, length)
		if err != nil {
			return nil, err
		}
		array := make([]any, len(refs))
		for i, ref := range refs {
			array[i], err = p.object(ref)
			if err != nil {
				return nil, err
			}
		}
		value = array
	case 0xd:
		if length > (uint64(len(p.data))-position)/uint64(p.refSize*2) {
			return nil, fmt.Errorf("invalid binary plist dictionary")
		}
		keys, err := p.references(position, length)
		if err != nil {
			return nil, err
		}
		values, err := p.references(position+length*uint64(p.refSize), length)
		if err != nil {
			return nil, err
		}
		result := make(map[string]any, len(keys))
		for i, keyRef := range keys {
			keyValue, err := p.object(keyRef)
			if err != nil {
				return nil, err
			}
			key, ok := keyValue.(string)
			if !ok || key == "" {
				return nil, fmt.Errorf("binary plist dictionary key is not a string")
			}
			if _, exists := result[key]; exists {
				return nil, fmt.Errorf("duplicate binary plist key")
			}
			result[key], err = p.object(values[i])
			if err != nil {
				return nil, err
			}
		}
		value = result
	default:
		return nil, fmt.Errorf("unsupported binary plist object type %#x", kind)
	}
	p.decoded[reference] = value
	return value, nil
}

func (p *binaryPlistParser) length(info byte, position uint64) (uint64, uint64, error) {
	if info < 0x0f {
		return uint64(info), position, nil
	}
	if position >= uint64(len(p.data)) {
		return 0, 0, fmt.Errorf("binary plist length missing")
	}
	marker := p.data[position]
	if marker>>4 != 0x1 {
		return 0, 0, fmt.Errorf("binary plist length is not an integer")
	}
	size := 1 << (marker & 0x0f)
	if size > 8 || position+1+uint64(size) > uint64(len(p.data)) {
		return 0, 0, fmt.Errorf("binary plist length integer invalid")
	}
	length, _ := readSizedUnsigned(p.data[position+1 : position+1+uint64(size)])
	return length, position + 1 + uint64(size), nil
}

func (p *binaryPlistParser) references(position, count uint64) ([]uint64, error) {
	bytesNeeded := count * uint64(p.refSize)
	if p.refSize <= 0 || bytesNeeded > uint64(len(p.data))-position {
		return nil, fmt.Errorf("binary plist references out of range")
	}
	refs := make([]uint64, int(count))
	for i := range refs {
		start := position + uint64(i*p.refSize)
		ref, ok := readSizedUnsigned(p.data[start : start+uint64(p.refSize)])
		if !ok || ref >= p.maxObjects {
			return nil, fmt.Errorf("binary plist reference out of range")
		}
		refs[i] = ref
	}
	return refs, nil
}

func readSizedUnsigned(value []byte) (uint64, bool) {
	if len(value) == 0 || len(value) > 8 {
		return 0, false
	}
	var result uint64
	for _, byteValue := range value {
		result = result<<8 | uint64(byteValue)
	}
	return result, true
}

func decodePlistDict(decoder *xml.Decoder) (map[string]any, error) {
	result := map[string]any{}
	for {
		token, err := decoder.Token()
		if err != nil {
			return nil, err
		}
		switch token := token.(type) {
		case xml.EndElement:
			if token.Name.Local == "dict" {
				return result, nil
			}
		case xml.StartElement:
			if token.Name.Local != "key" {
				return nil, fmt.Errorf("plist dict key expected")
			}
			var key string
			if err := decoder.DecodeElement(&key, &token); err != nil {
				return nil, err
			}
			if _, exists := result[key]; exists {
				return nil, fmt.Errorf("duplicate plist key")
			}
			value, err := nextPlistValue(decoder)
			if err != nil {
				return nil, err
			}
			result[key] = value
		}
	}
}

func decodePlistArray(decoder *xml.Decoder) ([]any, error) {
	result := []any{}
	for {
		token, err := decoder.Token()
		if err != nil {
			return nil, err
		}
		switch token := token.(type) {
		case xml.EndElement:
			if token.Name.Local == "array" {
				return result, nil
			}
		case xml.StartElement:
			decoderInput, err := decodePlistElement(decoder, token)
			if err != nil {
				return nil, err
			}
			result = append(result, decoderInput)
		}
	}
}

func nextPlistValue(decoder *xml.Decoder) (any, error) {
	for {
		token, err := decoder.Token()
		if err != nil {
			return nil, err
		}
		if start, ok := token.(xml.StartElement); ok {
			return decodePlistElement(decoder, start)
		}
		if end, ok := token.(xml.EndElement); ok && end.Name.Local == "dict" {
			return nil, fmt.Errorf("plist value missing")
		}
	}
}

func decodePlistElement(decoder *xml.Decoder, start xml.StartElement) (any, error) {
	switch start.Name.Local {
	case "dict":
		return decodePlistDict(decoder)
	case "array":
		return decodePlistArray(decoder)
	case "string":
		var value string
		err := decoder.DecodeElement(&value, &start)
		return value, err
	case "integer":
		var value string
		if err := decoder.DecodeElement(&value, &start); err != nil {
			return nil, err
		}
		parsed, err := strconv.ParseInt(value, 10, 64)
		if err != nil {
			return nil, err
		}
		return parsed, nil
	case "real":
		var value string
		if err := decoder.DecodeElement(&value, &start); err != nil {
			return nil, err
		}
		parsed, err := strconv.ParseFloat(value, 64)
		if err != nil {
			return nil, err
		}
		return parsed, nil
	case "true":
		if err := decoder.Skip(); err != nil {
			return nil, err
		}
		return true, nil
	case "false":
		if err := decoder.Skip(); err != nil {
			return nil, err
		}
		return false, nil
	case "data":
		var value string
		if err := decoder.DecodeElement(&value, &start); err != nil {
			return nil, err
		}
		decoded, err := base64.StdEncoding.DecodeString(string(bytes.Join(bytes.Fields([]byte(value)), nil)))
		if err != nil {
			return nil, err
		}
		return decoded, nil
	default:
		return nil, fmt.Errorf("unsupported plist element %s", start.Name.Local)
	}
}
