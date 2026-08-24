package protocol

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"math"
	"strconv"
	"unicode/utf8"
)

const (
	Int64Min  = -1 << 63
	Int64Max  = 1<<63 - 1
	Uint64Max = ^uint64(0)
)

type CanonicalError struct {
	Kind   string
	Detail string
}

func (e *CanonicalError) Error() string {
	if e.Detail == "" {
		return e.Kind
	}
	return e.Kind + ": " + e.Detail
}

type Document struct {
	Root  map[string]any
	Bytes []byte
}

func ValidateDocument(data []byte, maximumByteCount int) (Document, error) {
	if maximumByteCount < 0 {
		return Document{}, &CanonicalError{Kind: "invalidMaximumByteCount"}
	}
	if len(data) > maximumByteCount {
		return Document{}, &CanonicalError{Kind: "hardCapExceeded"}
	}
	if bytes.HasPrefix(data, []byte{0xef, 0xbb, 0xbf}) {
		return Document{}, &CanonicalError{Kind: "bom"}
	}
	if !utf8.Valid(data) {
		return Document{}, &CanonicalError{Kind: "invalidUTF8"}
	}
	p := parser{data: data, integersOnly: true}
	value, err := p.parseValue()
	if err != nil {
		return Document{}, err
	}
	p.skipSpace()
	if p.index != len(data) {
		return Document{}, &CanonicalError{Kind: "invalidSyntax", Detail: "trailing bytes"}
	}
	root, ok := value.(map[string]any)
	if !ok {
		return Document{}, &CanonicalError{Kind: "topLevelObject"}
	}
	encoded, err := EncodeValue(root, true)
	if err != nil {
		return Document{}, err
	}
	if !bytes.Equal(encoded, data) {
		return Document{}, &CanonicalError{Kind: "nonCanonical"}
	}
	return Document{Root: root, Bytes: append([]byte(nil), data...)}, nil
}

// DecodeJSON accepts the wire's non-canonical whitespace/key order while
// retaining duplicate-key, UTF-8, integer-boundary, and finite-number checks.
func DecodeJSON(data []byte) (any, error) {
	if !utf8.Valid(data) {
		return nil, &CanonicalError{Kind: "invalidUTF8"}
	}
	p := parser{data: data}
	value, err := p.parseValue()
	if err != nil {
		return nil, err
	}
	p.skipSpace()
	if p.index != len(data) {
		return nil, &CanonicalError{Kind: "invalidSyntax", Detail: "trailing bytes"}
	}
	return value, nil
}

func EncodeValue(value any, integersOnly bool) ([]byte, error) {
	var out bytes.Buffer
	if err := encodeValue(&out, value, integersOnly); err != nil {
		return nil, err
	}
	return out.Bytes(), nil
}

func SHA256Hex(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func DomainSeparatedSHA256Hex(domain string, payload []byte) (string, error) {
	if !isASCII(domain, true, 256) || bytes.IndexByte([]byte(domain), 0) >= 0 {
		return "", &CanonicalError{Kind: "invalidDomainID"}
	}
	h := sha256.New()
	_, _ = h.Write([]byte(domain))
	_, _ = h.Write([]byte{0})
	_, _ = h.Write(payload)
	return hex.EncodeToString(h.Sum(nil)), nil
}

func RequireUInt64(value any) (uint64, error) {
	switch value := value.(type) {
	case uint:
		return uint64(value), nil
	case uint8:
		return uint64(value), nil
	case uint16:
		return uint64(value), nil
	case uint32:
		return uint64(value), nil
	case uint64:
		return value, nil
	case int:
		if value >= 0 {
			return uint64(value), nil
		}
	case int8:
		if value >= 0 {
			return uint64(value), nil
		}
	case int16:
		if value >= 0 {
			return uint64(value), nil
		}
	case int32:
		if value >= 0 {
			return uint64(value), nil
		}
	case int64:
		if value >= 0 {
			return uint64(value), nil
		}
	}
	return 0, &CanonicalError{Kind: "integerNotUInt64"}
}

func RequireInt64(value any) (int64, error) {
	switch value := value.(type) {
	case int:
		return int64(value), nil
	case int8:
		return int64(value), nil
	case int16:
		return int64(value), nil
	case int32:
		return int64(value), nil
	case int64:
		return value, nil
	case uint:
		if uint64(value) <= math.MaxInt64 {
			return int64(value), nil
		}
	case uint8:
		return int64(value), nil
	case uint16:
		return int64(value), nil
	case uint32:
		return int64(value), nil
	case uint64:
		if value <= math.MaxInt64 {
			return int64(value), nil
		}
	}
	return 0, &CanonicalError{Kind: "integerNotInt64"}
}

type parser struct {
	data         []byte
	index        int
	integersOnly bool
}

func (p *parser) parseValue() (any, error) {
	p.skipSpace()
	if p.index >= len(p.data) {
		return nil, p.syntax("value")
	}
	switch p.data[p.index] {
	case '{':
		return p.parseObject()
	case '[':
		return p.parseArray()
	case '"':
		return p.parseString()
	case 't':
		return p.literal("true", true)
	case 'f':
		return p.literal("false", false)
	case 'n':
		return p.literal("null", nil)
	default:
		if p.data[p.index] == '-' || (p.data[p.index] >= '0' && p.data[p.index] <= '9') {
			return p.parseNumber()
		}
		return nil, p.syntax("value")
	}
}

func (p *parser) parseObject() (map[string]any, error) {
	p.index++
	result := make(map[string]any)
	p.skipSpace()
	if p.take('}') {
		return result, nil
	}
	for {
		p.skipSpace()
		if p.index >= len(p.data) || p.data[p.index] != '"' {
			return nil, p.syntax("object key")
		}
		key, err := p.parseString()
		if err != nil {
			return nil, err
		}
		if _, exists := result[key]; exists {
			return nil, &CanonicalError{Kind: "duplicateKey"}
		}
		p.skipSpace()
		if !p.take(':') {
			return nil, p.syntax("colon")
		}
		value, err := p.parseValue()
		if err != nil {
			return nil, err
		}
		result[key] = value
		p.skipSpace()
		if p.take('}') {
			return result, nil
		}
		if !p.take(',') {
			return nil, p.syntax("object separator")
		}
	}
}

func (p *parser) parseArray() ([]any, error) {
	p.index++
	result := make([]any, 0)
	p.skipSpace()
	if p.take(']') {
		return result, nil
	}
	for {
		value, err := p.parseValue()
		if err != nil {
			return nil, err
		}
		result = append(result, value)
		p.skipSpace()
		if p.take(']') {
			return result, nil
		}
		if !p.take(',') {
			return nil, p.syntax("array separator")
		}
	}
}

func (p *parser) parseString() (string, error) {
	if !p.take('"') {
		return "", p.syntax("string")
	}
	var out []byte
	for p.index < len(p.data) {
		c := p.data[p.index]
		p.index++
		switch c {
		case '"':
			value := string(out)
			if !utf8.ValidString(value) {
				return "", &CanonicalError{Kind: "invalidUnicodeEscape"}
			}
			return value, nil
		case '\\':
			if p.index >= len(p.data) {
				return "", p.syntax("escape")
			}
			escape := p.data[p.index]
			p.index++
			switch escape {
			case '"', '\\', '/':
				out = append(out, escape)
			case 'b':
				out = append(out, '\b')
			case 'f':
				out = append(out, '\f')
			case 'n':
				out = append(out, '\n')
			case 'r':
				out = append(out, '\r')
			case 't':
				out = append(out, '\t')
			case 'u':
				r, err := p.parseUnicodeEscape()
				if err != nil {
					return "", err
				}
				var buffer [utf8.UTFMax]byte
				n := utf8.EncodeRune(buffer[:], r)
				out = append(out, buffer[:n]...)
			default:
				return "", p.syntax("escape")
			}
		default:
			if c < 0x20 {
				return "", &CanonicalError{Kind: "invalidStringControl"}
			}
			if c >= 0x80 {
				// The complete input was checked for UTF-8 validity. Copying bytes
				// here preserves scalar values without normalizing them.
				out = append(out, c)
			} else {
				out = append(out, c)
			}
		}
	}
	return "", p.syntax("string terminator")
}

func (p *parser) parseUnicodeEscape() (rune, error) {
	if p.index+4 > len(p.data) {
		return 0, p.syntax("unicode escape")
	}
	value, ok := hex4(p.data[p.index : p.index+4])
	p.index += 4
	if !ok {
		return 0, p.syntax("unicode escape")
	}
	r := rune(value)
	if r >= 0xd800 && r <= 0xdbff {
		if p.index+6 > len(p.data) || p.data[p.index] != '\\' || p.data[p.index+1] != 'u' {
			return 0, &CanonicalError{Kind: "invalidUnicodeEscape"}
		}
		low, ok := hex4(p.data[p.index+2 : p.index+6])
		if !ok || low < 0xdc00 || low > 0xdfff {
			return 0, &CanonicalError{Kind: "invalidUnicodeEscape"}
		}
		p.index += 6
		return 0x10000 + ((r - 0xd800) << 10) + rune(low-0xdc00), nil
	}
	if r >= 0xdc00 && r <= 0xdfff {
		return 0, &CanonicalError{Kind: "invalidUnicodeEscape"}
	}
	return r, nil
}

func (p *parser) parseNumber() (any, error) {
	start := p.index
	negative := p.take('-')
	if p.index >= len(p.data) || p.data[p.index] < '0' || p.data[p.index] > '9' {
		return nil, p.syntax("number")
	}
	if p.data[p.index] == '0' {
		p.index++
		if p.index < len(p.data) && p.data[p.index] >= '0' && p.data[p.index] <= '9' {
			return nil, p.syntax("leading zero")
		}
	} else {
		for p.index < len(p.data) && p.data[p.index] >= '0' && p.data[p.index] <= '9' {
			p.index++
		}
	}
	decimal := false
	if p.index < len(p.data) && (p.data[p.index] == '.' || p.data[p.index] == 'e' || p.data[p.index] == 'E') {
		decimal = true
		for p.index < len(p.data) && ((p.data[p.index] >= '0' && p.data[p.index] <= '9') || p.data[p.index] == '.' || p.data[p.index] == 'e' || p.data[p.index] == 'E' || p.data[p.index] == '+' || p.data[p.index] == '-') {
			p.index++
		}
	}
	token := string(p.data[start:p.index])
	if decimal {
		if p.integersOnly {
			return nil, &CanonicalError{Kind: "unsupportedNumber", Detail: token}
		}
		value, err := strconv.ParseFloat(token, 64)
		if err != nil || math.IsNaN(value) || math.IsInf(value, 0) {
			return nil, &CanonicalError{Kind: "unsupportedNumber", Detail: token}
		}
		return value, nil
	}
	if negative {
		if token == "-0" {
			return nil, &CanonicalError{Kind: "negativeZero"}
		}
		value, err := strconv.ParseInt(token, 10, 64)
		if err != nil {
			return nil, &CanonicalError{Kind: "signedOverflow", Detail: token}
		}
		return value, nil
	}
	value, err := strconv.ParseUint(token, 10, 64)
	if err != nil {
		return nil, &CanonicalError{Kind: "unsignedOverflow", Detail: token}
	}
	if value <= math.MaxInt64 {
		return int64(value), nil
	}
	return value, nil
}

func (p *parser) literal(literal string, value any) (any, error) {
	if p.index+len(literal) > len(p.data) || string(p.data[p.index:p.index+len(literal)]) != literal {
		return nil, p.syntax(literal)
	}
	p.index += len(literal)
	return value, nil
}

func (p *parser) skipSpace() {
	for p.index < len(p.data) {
		switch p.data[p.index] {
		case ' ', '\t', '\r', '\n':
			p.index++
		default:
			return
		}
	}
}

func (p *parser) take(value byte) bool {
	if p.index < len(p.data) && p.data[p.index] == value {
		p.index++
		return true
	}
	return false
}

func (p *parser) syntax(detail string) error {
	return &CanonicalError{Kind: "invalidSyntax", Detail: detail}
}

func hex4(value []byte) (int, bool) {
	if len(value) != 4 {
		return 0, false
	}
	result := 0
	for _, c := range value {
		result <<= 4
		switch {
		case c >= '0' && c <= '9':
			result += int(c - '0')
		case c >= 'a' && c <= 'f':
			result += int(c-'a') + 10
		case c >= 'A' && c <= 'F':
			result += int(c-'A') + 10
		default:
			return 0, false
		}
	}
	return result, true
}

func encodeValue(out *bytes.Buffer, value any, integersOnly bool) error {
	switch value := value.(type) {
	case nil:
		out.WriteString("null")
	case bool:
		if value {
			out.WriteString("true")
		} else {
			out.WriteString("false")
		}
	case int:
		return encodeInteger(out, int64(value), integersOnly)
	case int8:
		return encodeInteger(out, int64(value), integersOnly)
	case int16:
		return encodeInteger(out, int64(value), integersOnly)
	case int32:
		return encodeInteger(out, int64(value), integersOnly)
	case int64:
		return encodeInteger(out, value, integersOnly)
	case uint:
		return encodeUnsigned(out, uint64(value), integersOnly)
	case uint8:
		return encodeUnsigned(out, uint64(value), integersOnly)
	case uint16:
		return encodeUnsigned(out, uint64(value), integersOnly)
	case uint32:
		return encodeUnsigned(out, uint64(value), integersOnly)
	case uint64:
		return encodeUnsigned(out, value, integersOnly)
	case float64:
		if integersOnly || math.IsNaN(value) || math.IsInf(value, 0) {
			return &CanonicalError{Kind: "unsupportedNumber"}
		}
		out.WriteString(strconv.FormatFloat(value, 'g', -1, 64))
	case string:
		return encodeString(out, value)
	case []any:
		out.WriteByte('[')
		for index, item := range value {
			if index > 0 {
				out.WriteByte(',')
			}
			if err := encodeValue(out, item, integersOnly); err != nil {
				return err
			}
		}
		out.WriteByte(']')
	case map[string]any:
		keys := make([]string, 0, len(value))
		for key := range value {
			keys = append(keys, key)
		}
		sortUTF8(keys)
		out.WriteByte('{')
		for index, key := range keys {
			if index > 0 {
				out.WriteByte(',')
			}
			if err := encodeString(out, key); err != nil {
				return err
			}
			out.WriteByte(':')
			if err := encodeValue(out, value[key], integersOnly); err != nil {
				return err
			}
		}
		out.WriteByte('}')
	default:
		return &CanonicalError{Kind: "unsupportedValue", Detail: fmt.Sprintf("%T", value)}
	}
	return nil
}

func encodeInteger(out *bytes.Buffer, value int64, integersOnly bool) error {
	if !integersOnly || value >= Int64Min {
		out.WriteString(strconv.FormatInt(value, 10))
		return nil
	}
	return &CanonicalError{Kind: "signedOverflow"}
}

func encodeUnsigned(out *bytes.Buffer, value uint64, integersOnly bool) error {
	if !integersOnly || value <= Uint64Max {
		out.WriteString(strconv.FormatUint(value, 10))
		return nil
	}
	return &CanonicalError{Kind: "unsignedOverflow"}
}

func encodeString(out *bytes.Buffer, value string) error {
	if !utf8.ValidString(value) {
		return &CanonicalError{Kind: "invalidUnicodeEscape"}
	}
	out.WriteByte('"')
	for _, r := range value {
		switch r {
		case '"':
			out.WriteString("\\\"")
		case '\\':
			out.WriteString("\\\\")
		case '\b':
			out.WriteString("\\b")
		case '\t':
			out.WriteString("\\t")
		case '\n':
			out.WriteString("\\n")
		case '\f':
			out.WriteString("\\f")
		case '\r':
			out.WriteString("\\r")
		default:
			if r < 0x20 {
				fmt.Fprintf(out, "\\u%04x", r)
			} else {
				_, _ = out.WriteRune(r)
			}
		}
	}
	out.WriteByte('"')
	return nil
}

func sortUTF8(values []string) {
	for i := 1; i < len(values); i++ {
		value := values[i]
		j := i
		for j > 0 && bytes.Compare([]byte(values[j-1]), []byte(value)) > 0 {
			values[j] = values[j-1]
			j--
		}
		values[j] = value
	}
}

func isASCII(value string, requireNonEmpty bool, maximum int) bool {
	bytes := []byte(value)
	if (requireNonEmpty && len(bytes) == 0) || len(bytes) > maximum {
		return false
	}
	for _, c := range bytes {
		if c < 0x20 || c > 0x7e {
			return false
		}
	}
	return true
}

var _ = errors.Is
