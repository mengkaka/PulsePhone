package direct

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"math"
	"sort"
	"unicode/utf8"
)

// plistUID is used only while building or resolving NSKeyedArchive graphs.
// Binary plist UID values are not ordinary application integers.
type plistUID uint64

type binaryPlistObject struct {
	kind    byte
	text    string
	data    []byte
	integer int64
	real    float64
	boolean bool
	refs    []uint64
	keys    []uint64
	values  []uint64
}

type plistDict struct {
	keys   []uint64
	values []uint64
}

type plistArray struct {
	refs []uint64
}

type plistUIDObject struct {
	target uint64
}
type plistRefValue uint64

type archiveBuilder struct {
	objects   []any
	primitive map[string]uint64
	classes   map[string]uint64
}

func newArchiveBuilder() *archiveBuilder {
	return &archiveBuilder{
		objects:   []any{"$null"},
		primitive: make(map[string]uint64),
		classes:   make(map[string]uint64),
	}
}

func encodeNSKeyedArchive(value any) ([]byte, error) {
	builder := newArchiveBuilder()
	root := builder.addArchive(value)
	archiveCount := len(builder.objects)

	objectRefs := make([]any, archiveCount)
	for index := range objectRefs {
		objectRefs[index] = plistRefValue(index)
	}
	objectsID := builder.addPlist(objectRefs)
	documentID := builder.addPlist(map[string]any{
		"$archiver": "NSKeyedArchiver",
		"$objects":  plistRefValue(objectsID),
		"$top":      map[string]any{"root": plistUID(root)},
		"$version":  int64(100000),
	})
	return encodeBinaryPlistObjects(builder.objects, documentID)
}

func (builder *archiveBuilder) addArchive(value any) uint64 {
	switch value := value.(type) {
	case nil:
		return 0
	case []any:
		index := builder.reserve()
		classID := builder.addClass("NSArray")
		refs := make([]any, len(value))
		for i, item := range value {
			refs[i] = plistUID(builder.addArchive(item))
		}
		builder.objects[index] = builder.dictValue(map[string]any{"$class": plistUID(classID), "NS.objects": refs})
		return index
	case map[string]any:
		index := builder.reserve()
		classID := builder.addClass("NSDictionary")
		keys := make([]string, 0, len(value))
		for key := range value {
			keys = append(keys, key)
		}
		sort.Strings(keys)
		keyRefs := make([]any, len(keys))
		valueRefs := make([]any, len(keys))
		for i, key := range keys {
			keyRefs[i] = plistUID(builder.addArchive(key))
			valueRefs[i] = plistUID(builder.addArchive(value[key]))
		}
		builder.objects[index] = builder.dictValue(map[string]any{
			"$class":     plistUID(classID),
			"NS.keys":    keyRefs,
			"NS.objects": valueRefs,
		})
		return index
	default:
		return builder.addPlist(value)
	}
}

func (builder *archiveBuilder) addClass(name string) uint64 {
	if index, ok := builder.classes[name]; ok {
		return index
	}
	index := builder.reserve()
	builder.classes[name] = index
	builder.objects[index] = builder.dictValue(map[string]any{
		"$classes":   []any{name},
		"$classname": name,
	})
	return index
}

func (builder *archiveBuilder) reserve() uint64 {
	index := uint64(len(builder.objects))
	builder.objects = append(builder.objects, nil)
	return index
}

// addPlist adds an ordinary plist node. It is also used for the metadata
// outside the archive's $objects array and for class descriptors.
func (builder *archiveBuilder) addPlist(value any) uint64 {
	switch value := value.(type) {
	case plistUID:
		index := builder.reserve()
		builder.objects[index] = plistUIDObject{target: uint64(value)}
		return index
	case plistRefValue:
		return uint64(value)
	case nil:
		return 0
	case string:
		key := "s:" + value
		if index, ok := builder.primitive[key]; ok {
			return index
		}
		index := builder.reserve()
		builder.objects[index] = value
		builder.primitive[key] = index
		return index
	case []byte:
		key := "d:" + string(value)
		if index, ok := builder.primitive[key]; ok {
			return index
		}
		index := builder.reserve()
		builder.objects[index] = append([]byte(nil), value...)
		builder.primitive[key] = index
		return index
	case bool:
		key := "b:" + fmt.Sprint(value)
		if index, ok := builder.primitive[key]; ok {
			return index
		}
		index := builder.reserve()
		builder.objects[index] = value
		builder.primitive[key] = index
		return index
	case int:
		return builder.addPlist(int64(value))
	case int64:
		key := fmt.Sprintf("i:%d", value)
		if index, ok := builder.primitive[key]; ok {
			return index
		}
		index := builder.reserve()
		builder.objects[index] = value
		builder.primitive[key] = index
		return index
	case uint64:
		if value <= math.MaxInt64 {
			return builder.addPlist(int64(value))
		}
		key := fmt.Sprintf("u:%d", value)
		if index, ok := builder.primitive[key]; ok {
			return index
		}
		index := builder.reserve()
		builder.objects[index] = value
		builder.primitive[key] = index
		return index
	case float64:
		key := fmt.Sprintf("f:%016x", math.Float64bits(value))
		if index, ok := builder.primitive[key]; ok {
			return index
		}
		index := builder.reserve()
		builder.objects[index] = value
		builder.primitive[key] = index
		return index
	case []any:
		index := builder.reserve()
		refs := make([]uint64, len(value))
		for i, item := range value {
			refs[i] = builder.addPlist(item)
		}
		builder.objects[index] = plistArray{refs: refs}
		return index
	case map[string]any:
		index := builder.reserve()
		builder.objects[index] = builder.dictValue(value)
		return index
	default:
		return 0
	}
}

func (builder *archiveBuilder) dictValue(value map[string]any) plistDict {
	keys := make([]string, 0, len(value))
	for key := range value {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	keyRefs := make([]uint64, len(keys))
	valueRefs := make([]uint64, len(keys))
	for index, key := range keys {
		keyRefs[index] = builder.addPlist(key)
		valueRefs[index] = builder.addPlist(value[key])
	}
	return plistDict{keys: keyRefs, values: valueRefs}
}

func encodeBinaryPlistObjects(objects []any, top uint64) ([]byte, error) {
	encoded := make([]binaryPlistObject, len(objects))
	for index, value := range objects {
		object, err := binaryPlistObjectFromValue(value)
		if err != nil {
			return nil, fmt.Errorf("binary plist object %d: %w", index, err)
		}
		encoded[index] = object
	}
	if top >= uint64(len(encoded)) {
		return nil, fmt.Errorf("binary plist top object out of range")
	}
	var body bytes.Buffer
	offsets := make([]uint64, len(encoded))
	for index, object := range encoded {
		offsets[index] = uint64(8 + body.Len())
		if err := writeBinaryPlistObject(&body, object, uint64(refWidth(len(encoded)))); err != nil {
			return nil, err
		}
	}
	offsetSize := offsetWidth(uint64(8 + body.Len()))
	offsetTable := uint64(8 + body.Len())
	var result bytes.Buffer
	result.WriteString("bplist00")
	result.Write(body.Bytes())
	for _, offset := range offsets {
		writeSizedUnsigned(&result, offset, offsetSize)
	}
	trailer := make([]byte, 32)
	trailer[6] = byte(offsetSize)
	trailer[7] = byte(refWidth(len(encoded)))
	binary.BigEndian.PutUint64(trailer[8:16], uint64(len(encoded)))
	binary.BigEndian.PutUint64(trailer[16:24], top)
	binary.BigEndian.PutUint64(trailer[24:32], offsetTable)
	result.Write(trailer)
	return result.Bytes(), nil
}

func binaryPlistObjectFromValue(value any) (binaryPlistObject, error) {
	switch value := value.(type) {
	case nil:
		return binaryPlistObject{kind: 0x00}, nil
	case bool:
		return binaryPlistObject{kind: 0x09, boolean: value}, nil
	case string:
		return binaryPlistObject{kind: 0x50, text: value}, nil
	case []byte:
		return binaryPlistObject{kind: 0x40, data: value}, nil
	case int:
		return binaryPlistObject{kind: 0x10, integer: int64(value)}, nil
	case int64:
		return binaryPlistObject{kind: 0x10, integer: value}, nil
	case uint64:
		if value > math.MaxInt64 {
			return binaryPlistObject{}, fmt.Errorf("unsigned integer exceeds plist signed range")
		}
		return binaryPlistObject{kind: 0x10, integer: int64(value)}, nil
	case float64:
		return binaryPlistObject{kind: 0x23, real: value}, nil
	case plistArray:
		return binaryPlistObject{kind: 0xa0, refs: value.refs}, nil
	case plistDict:
		return binaryPlistObject{kind: 0xd0, keys: value.keys, values: value.values}, nil
	case plistUIDObject:
		return binaryPlistObject{kind: 0x80, integer: int64(value.target)}, nil
	default:
		return binaryPlistObject{}, fmt.Errorf("unsupported plist object %T", value)
	}
}

func writeBinaryPlistObject(out *bytes.Buffer, object binaryPlistObject, refSize uint64) error {
	switch object.kind {
	case 0x00:
		out.WriteByte(0x00)
	case 0x08, 0x09:
		if object.boolean {
			out.WriteByte(0x09)
		} else {
			out.WriteByte(0x08)
		}
	case 0x10:
		value := object.integer
		size := 8
		if value >= 0 && value <= math.MaxUint8 {
			size = 1
		} else if value >= math.MinInt16 && value <= math.MaxInt16 {
			size = 2
		} else if value >= math.MinInt32 && value <= math.MaxInt32 {
			size = 4
		}
		info := byte(0)
		for (1 << info) < size {
			info++
		}
		out.WriteByte(0x10 | info)
		writeSignedBigEndian(out, value, size)
	case 0x23:
		out.WriteByte(0x23)
		binary.Write(out, binary.BigEndian, math.Float64bits(object.real))
	case 0x40:
		writeLengthMarker(out, 0x40, uint64(len(object.data)))
		out.Write(object.data)
	case 0x50:
		data := []byte(object.text)
		marker := byte(0x50)
		if !isASCII(data) {
			marker = 0x70
		}
		writeLengthMarker(out, marker, uint64(len(data)))
		out.Write(data)
	case 0xa0:
		writeLengthMarker(out, 0xa0, uint64(len(object.refs)))
		for _, ref := range object.refs {
			writeSizedUnsigned(out, ref, int(refSize))
		}
	case 0xd0:
		writeLengthMarker(out, 0xd0, uint64(len(object.keys)))
		for _, ref := range object.keys {
			writeSizedUnsigned(out, ref, int(refSize))
		}
		for _, ref := range object.values {
			writeSizedUnsigned(out, ref, int(refSize))
		}
	case 0x80:
		target := uint64(object.integer)
		size := int(refSize)
		if target <= 0xff {
			size = 1
		} else if target <= 0xffff {
			size = 2
		} else if target <= 0xffffffff {
			size = 4
		}
		out.WriteByte(0x80 | byte(size-1))
		writeSizedUnsigned(out, target, size)
	default:
		return fmt.Errorf("unsupported binary plist object marker %#x", object.kind)
	}
	return nil
}

func writeLengthMarker(out *bytes.Buffer, marker byte, length uint64) {
	if length < 15 {
		out.WriteByte(marker | byte(length))
		return
	}
	out.WriteByte(marker | 0x0f)
	size := 1
	for uint64(1<<uint(size*8)) <= length && size < 8 {
		size++
	}
	info := byte(0)
	for (1 << info) < size {
		info++
	}
	out.WriteByte(0x10 | info)
	writeSizedUnsigned(out, length, size)
}

func writeSignedBigEndian(out *bytes.Buffer, value int64, size int) {
	var raw uint64
	if size == 8 {
		raw = uint64(value)
	} else {
		raw = uint64(value) & ((uint64(1) << uint(size*8)) - 1)
	}
	writeSizedUnsigned(out, raw, size)
}

func writeSizedUnsigned(out *bytes.Buffer, value uint64, size int) {
	var raw [8]byte
	binary.BigEndian.PutUint64(raw[:], value)
	out.Write(raw[8-size:])
}

func refWidth(count int) int {
	if count <= 0xff {
		return 1
	}
	if count <= 0xffff {
		return 2
	}
	if uint64(count) <= 0xffffffff {
		return 4
	}
	return 8
}

func offsetWidth(value uint64) int {
	if value <= 0xff {
		return 1
	}
	if value <= 0xffff {
		return 2
	}
	if value <= 0xffffffff {
		return 4
	}
	return 8
}

func isASCII(value []byte) bool {
	return utf8.Valid(value) && bytes.IndexFunc(value, func(r rune) bool { return r > 0x7f }) < 0
}

func decodeNSKeyedArchive(data []byte) (any, error) {
	root, err := decodePlistValue(data)
	if err != nil {
		return nil, err
	}
	document, ok := root.(map[string]any)
	if !ok || document["$archiver"] != "NSKeyedArchiver" {
		return nil, fmt.Errorf("not an NSKeyedArchive")
	}
	objects, ok := document["$objects"].([]any)
	if !ok || len(objects) == 0 {
		return nil, fmt.Errorf("archive objects missing")
	}
	top, ok := document["$top"].(map[string]any)
	if !ok {
		return nil, fmt.Errorf("archive top missing")
	}
	rootRef, ok := archiveReference(top["root"])
	if !ok {
		return nil, fmt.Errorf("archive root missing")
	}
	return resolveArchiveObject(objects, rootRef, make(map[uint64]any), make(map[uint64]bool))
}

func resolveArchiveObject(objects []any, reference uint64, cache map[uint64]any, visiting map[uint64]bool) (any, error) {
	if reference >= uint64(len(objects)) {
		return nil, fmt.Errorf("archive reference out of range")
	}
	if value, ok := cache[reference]; ok {
		return value, nil
	}
	if visiting[reference] {
		return nil, fmt.Errorf("archive cycle")
	}
	visiting[reference] = true
	defer delete(visiting, reference)
	raw := objects[reference]
	if reference == 0 || raw == nil {
		cache[reference] = nil
		return nil, nil
	}
	if array, ok := raw.([]any); ok {
		result := make([]any, len(array))
		for i, item := range array {
			ref, ok := archiveReference(item)
			if !ok {
				return nil, fmt.Errorf("archive array item is not a UID")
			}
			result[i], _ = resolveArchiveObject(objects, ref, cache, visiting)
		}
		cache[reference] = result
		return result, nil
	}
	object, ok := raw.(map[string]any)
	if !ok {
		cache[reference] = raw
		return raw, nil
	}
	if classRef, exists := object["$class"]; exists {
		classID, ok := archiveReference(classRef)
		if !ok {
			return nil, fmt.Errorf("archive class UID missing")
		}
		class, _ := objects[classID].(map[string]any)
		name, _ := class["$classname"].(string)
		switch name {
		case "NSArray", "NSMutableArray":
			items, ok := object["NS.objects"].([]any)
			if !ok {
				return nil, fmt.Errorf("archive array payload missing")
			}
			result := make([]any, len(items))
			for i, item := range items {
				ref, ok := archiveReference(item)
				if !ok {
					return nil, fmt.Errorf("archive array UID missing")
				}
				result[i], _ = resolveArchiveObject(objects, ref, cache, visiting)
			}
			cache[reference] = result
			return result, nil
		case "NSDictionary":
			keys, keysOK := object["NS.keys"].([]any)
			values, valuesOK := object["NS.objects"].([]any)
			if !keysOK || !valuesOK || len(keys) != len(values) {
				return nil, fmt.Errorf("archive dictionary payload missing")
			}
			result := make(map[string]any, len(keys))
			for i := range keys {
				keyRef, ok := archiveReference(keys[i])
				if !ok {
					return nil, fmt.Errorf("archive dictionary key UID missing")
				}
				key, err := resolveArchiveObject(objects, keyRef, cache, visiting)
				if err != nil {
					return nil, err
				}
				keyString, ok := key.(string)
				if !ok {
					return nil, fmt.Errorf("archive dictionary key is not string")
				}
				valueRef, ok := archiveReference(values[i])
				if !ok {
					return nil, fmt.Errorf("archive dictionary value UID missing")
				}
				result[keyString], err = resolveArchiveObject(objects, valueRef, cache, visiting)
				if err != nil {
					return nil, err
				}
			}
			cache[reference] = result
			return result, nil
		}
	}
	result := make(map[string]any, len(object))
	for key, value := range object {
		if key == "$class" {
			continue
		}
		if ref, ok := archiveReference(value); ok {
			result[key], _ = resolveArchiveObject(objects, ref, cache, visiting)
		} else {
			result[key] = value
		}
	}
	cache[reference] = result
	return result, nil
}

func archiveReference(value any) (uint64, bool) {
	switch value := value.(type) {
	case plistUID:
		return uint64(value), true
	case uint64:
		return value, true
	case int64:
		return uint64(value), value >= 0
	default:
		return 0, false
	}
}
