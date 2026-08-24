package direct

import (
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"math"
)

const (
	maximumScreenshotPixels = 32 * 1024 * 1024
	tiffHeaderSize          = 8
)

var (
	jpegSignature         = []byte{0xff, 0xd8, 0xff}
	tiffLittle            = []byte{'I', 'I', 42, 0}
	tiffBig               = []byte{'M', 'M', 0, 42}
	errScreenshotTooLarge = errors.New("screenshot exceeds byte limit")
)

// NormalizeImageToPNG keeps the image contract independent of the provider.
// PNG is passed through after signature validation; JPEG and common TIFF
// layouts emitted by legacy device services are decoded and re-encoded.
func NormalizeImageToPNG(data []byte, format string) ([]byte, error) {
	if len(data) > maximumScreenshotBytes {
		return nil, errScreenshotTooLarge
	}
	if format == "" {
		format = DetectImageFormat(data)
	}
	switch format {
	case "png":
		if !hasPrefix(data, pngSignature) {
			return nil, errors.New("invalid PNG signature")
		}
		return append([]byte(nil), data...), nil
	case "jpeg":
		if !bytes.HasPrefix(data, jpegSignature) {
			return nil, errors.New("invalid JPEG signature")
		}
		configuration, err := jpeg.DecodeConfig(bytes.NewReader(data))
		if err != nil {
			return nil, fmt.Errorf("inspect JPEG: %w", err)
		}
		if !screenshotPixelCountOK(configuration.Width, configuration.Height) {
			return nil, errors.New("screenshot dimensions")
		}
		decoded, err := jpeg.Decode(bytes.NewReader(data))
		if err != nil {
			return nil, fmt.Errorf("decode JPEG: %w", err)
		}
		return encodeScreenshotPNG(decoded)
	case "tiff":
		decoded, err := decodeScreenshotTIFF(data)
		if err != nil {
			return nil, fmt.Errorf("decode TIFF: %w", err)
		}
		return encodeScreenshotPNG(decoded)
	default:
		return nil, errors.New("unsupported screenshot format")
	}
}

func DetectImageFormat(data []byte) string {
	switch {
	case hasPrefix(data, pngSignature):
		return "png"
	case bytes.HasPrefix(data, jpegSignature):
		return "jpeg"
	case hasPrefix(data, tiffLittle), hasPrefix(data, tiffBig):
		return "tiff"
	default:
		return ""
	}
}

func encodeScreenshotPNG(decoded image.Image) ([]byte, error) {
	if decoded == nil {
		return nil, errors.New("empty screenshot")
	}
	bounds := decoded.Bounds()
	if bounds.Dx() <= 0 || bounds.Dy() <= 0 || !screenshotPixelCountOK(bounds.Dx(), bounds.Dy()) {
		return nil, errors.New("screenshot dimensions")
	}
	var output bytes.Buffer
	if err := png.Encode(&output, decoded); err != nil {
		return nil, fmt.Errorf("encode PNG: %w", err)
	}
	if len(output.Bytes()) > maximumScreenshotBytes {
		return nil, errScreenshotTooLarge
	}
	return output.Bytes(), nil
}

func screenshotPixelCountOK(width, height int) bool {
	if width <= 0 || height <= 0 {
		return false
	}
	return uint64(width) <= maximumScreenshotPixels/uint64(height)
}

func hasPrefix(value, prefix []byte) bool {
	return len(value) >= len(prefix) && bytes.Equal(value[:len(prefix)], prefix)
}

type tiffReader struct {
	data  []byte
	order binary.ByteOrder
}

type tiffField struct {
	tag      uint16
	typeID   uint16
	count    uint32
	valueRaw [4]byte
}

func decodeScreenshotTIFF(data []byte) (image.Image, error) {
	if len(data) < tiffHeaderSize {
		return nil, errors.New("short header")
	}
	reader := &tiffReader{data: data}
	switch {
	case bytes.Equal(data[:4], tiffLittle):
		reader.order = binary.LittleEndian
	case bytes.Equal(data[:4], tiffBig):
		reader.order = binary.BigEndian
	default:
		return nil, errors.New("invalid byte order or version")
	}
	ifdOffset := uint64(reader.order.Uint32(data[4:8]))
	if ifdOffset > uint64(len(data)-2) {
		return nil, errors.New("IFD outside file")
	}
	count := int(reader.order.Uint16(data[ifdOffset : ifdOffset+2]))
	if count > 4096 || ifdOffset+2+uint64(count)*12+4 > uint64(len(data)) {
		return nil, errors.New("invalid IFD")
	}
	fields := make(map[uint16]tiffField, count)
	for index := 0; index < count; index++ {
		offset := ifdOffset + 2 + uint64(index)*12
		field := tiffField{
			tag:    reader.order.Uint16(data[offset : offset+2]),
			typeID: reader.order.Uint16(data[offset+2 : offset+4]),
			count:  reader.order.Uint32(data[offset+4 : offset+8]),
		}
		copy(field.valueRaw[:], data[offset+8:offset+12])
		fields[field.tag] = field
	}

	width, err := reader.scalarField(fields, 256)
	if err != nil {
		return nil, fmt.Errorf("width: %w", err)
	}
	height, err := reader.scalarField(fields, 257)
	if err != nil {
		return nil, fmt.Errorf("height: %w", err)
	}
	if width == 0 || height == 0 || width > math.MaxInt || height > math.MaxInt || !screenshotPixelCountOK(int(width), int(height)) {
		return nil, errors.New("invalid dimensions")
	}

	compression, err := reader.scalarFieldDefault(fields, 259, 1)
	if err != nil {
		return nil, fmt.Errorf("compression: %w", err)
	}
	if compression != 1 && compression != 32773 {
		return nil, fmt.Errorf("unsupported compression %d", compression)
	}
	photometric, err := reader.scalarFieldDefault(fields, 262, 2)
	if err != nil {
		return nil, fmt.Errorf("photometric: %w", err)
	}
	samples, err := reader.scalarFieldDefault(fields, 277, 1)
	if err != nil {
		return nil, fmt.Errorf("samples per pixel: %w", err)
	}
	planar, err := reader.scalarFieldDefault(fields, 284, 1)
	if err != nil {
		return nil, fmt.Errorf("planar configuration: %w", err)
	}
	if planar != 1 || (samples != 1 && samples != 3 && samples != 4) ||
		(samples == 1 && photometric != 0 && photometric != 1) ||
		(samples != 1 && photometric != 2) {
		return nil, errors.New("unsupported TIFF pixel layout")
	}
	bits, err := reader.valuesField(fields, 258)
	if err != nil {
		return nil, fmt.Errorf("bits per sample: %w", err)
	}
	if len(bits) == 0 {
		bits = []uint64{8}
	}
	for _, bitDepth := range bits {
		if bitDepth != 8 {
			return nil, fmt.Errorf("unsupported bit depth %d", bitDepth)
		}
	}
	if len(bits) != 1 && len(bits) != int(samples) {
		return nil, errors.New("bits per sample count")
	}

	rowsPerStrip, err := reader.scalarFieldDefault(fields, 278, height)
	if err != nil || rowsPerStrip == 0 {
		return nil, errors.New("rows per strip")
	}
	offsets, err := reader.valuesField(fields, 273)
	if err != nil || len(offsets) == 0 {
		return nil, errors.New("strip offsets")
	}
	byteCounts, err := reader.valuesField(fields, 279)
	if err != nil || len(byteCounts) != len(offsets) {
		return nil, errors.New("strip byte counts")
	}
	predictor, err := reader.scalarFieldDefault(fields, 317, 1)
	if err != nil || (predictor != 1 && predictor != 2) {
		return nil, errors.New("unsupported TIFF predictor")
	}

	rowBytes64 := width * samples
	if rowBytes64 == 0 || rowBytes64 > uint64(math.MaxInt) {
		return nil, errors.New("row size")
	}
	rowBytes := int(rowBytes64)
	raw := make([]byte, int(width*height*samples))
	row := uint64(0)
	for index := range offsets {
		stripRows := rowsPerStrip
		if remaining := height - row; remaining < stripRows {
			stripRows = remaining
		}
		if stripRows == 0 {
			break
		}
		start, size := offsets[index], byteCounts[index]
		if start > uint64(len(data)) || size > uint64(len(data))-start {
			return nil, errors.New("strip outside file")
		}
		expected := uint64(rowBytes) * stripRows
		strip, err := decodeTIFFStrip(data[start:start+size], compression, expected)
		if err != nil {
			return nil, fmt.Errorf("strip %d: %w", index, err)
		}
		if uint64(len(strip)) != expected {
			return nil, fmt.Errorf("strip %d length %d, want %d", index, len(strip), expected)
		}
		if predictor == 2 {
			for rowIndex := uint64(0); rowIndex < stripRows; rowIndex++ {
				line := strip[rowIndex*uint64(rowBytes) : (rowIndex+1)*uint64(rowBytes)]
				for pixel := int(samples); pixel < len(line); pixel++ {
					line[pixel] += line[pixel-int(samples)]
				}
			}
		}
		copy(raw[row*uint64(rowBytes):], strip)
		row += stripRows
	}
	if row != height {
		return nil, errors.New("incomplete TIFF strips")
	}

	result := image.NewRGBA(image.Rect(0, 0, int(width), int(height)))
	for y := 0; y < int(height); y++ {
		line := raw[y*rowBytes : (y+1)*rowBytes]
		for x := 0; x < int(width); x++ {
			pixel := line[x*int(samples) : (x+1)*int(samples)]
			switch samples {
			case 1:
				value := pixel[0]
				if photometric == 0 {
					value = 255 - value
				}
				result.SetRGBA(x, y, color.RGBA{R: value, G: value, B: value, A: 255})
			case 3:
				result.SetRGBA(x, y, color.RGBA{R: pixel[0], G: pixel[1], B: pixel[2], A: 255})
			case 4:
				result.SetRGBA(x, y, color.RGBA{R: pixel[0], G: pixel[1], B: pixel[2], A: pixel[3]})
			}
		}
	}
	return result, nil
}

func (reader *tiffReader) scalarField(fields map[uint16]tiffField, tag uint16) (uint64, error) {
	values, err := reader.valuesField(fields, tag)
	if err != nil || len(values) != 1 {
		if err != nil {
			return 0, err
		}
		return 0, errors.New("expected one value")
	}
	return values[0], nil
}

func (reader *tiffReader) scalarFieldDefault(fields map[uint16]tiffField, tag uint16, fallback uint64) (uint64, error) {
	if _, exists := fields[tag]; !exists {
		return fallback, nil
	}
	return reader.scalarField(fields, tag)
}

func (reader *tiffReader) valuesField(fields map[uint16]tiffField, tag uint16) ([]uint64, error) {
	field, exists := fields[tag]
	if !exists {
		return nil, errors.New("missing field")
	}
	typeSize, ok := tiffTypeSize(field.typeID)
	if !ok || field.count == 0 || field.count > 1<<20 {
		return nil, errors.New("invalid field type or count")
	}
	byteCount := uint64(typeSize) * uint64(field.count)
	var source []byte
	if byteCount <= 4 {
		source = field.valueRaw[:byteCount]
	} else {
		if byteCount > uint64(len(reader.data)) {
			return nil, errors.New("field too large")
		}
		offset := uint64(reader.order.Uint32(field.valueRaw[:]))
		if offset > uint64(len(reader.data)) || byteCount > uint64(len(reader.data))-offset {
			return nil, errors.New("field outside file")
		}
		source = reader.data[offset : offset+byteCount]
	}
	values := make([]uint64, field.count)
	for index := range values {
		offset := uint64(index * typeSize)
		switch field.typeID {
		case 1, 2, 6, 7:
			values[index] = uint64(source[offset])
		case 3:
			values[index] = uint64(reader.order.Uint16(source[offset : offset+2]))
		case 4:
			values[index] = uint64(reader.order.Uint32(source[offset : offset+4]))
		case 8:
			values[index] = uint64(int16(reader.order.Uint16(source[offset : offset+2])))
		case 9:
			values[index] = uint64(int32(reader.order.Uint32(source[offset : offset+4])))
		default:
			return nil, errors.New("unsupported field type")
		}
	}
	return values, nil
}

func tiffTypeSize(typeID uint16) (int, bool) {
	switch typeID {
	case 1, 2, 6, 7:
		return 1, true
	case 3, 8:
		return 2, true
	case 4, 9:
		return 4, true
	default:
		return 0, false
	}
}

func decodeTIFFStrip(data []byte, compression, maximumOutput uint64) ([]byte, error) {
	if maximumOutput > uint64(math.MaxInt) {
		return nil, errors.New("PackBits output limit")
	}
	if compression == 1 {
		if uint64(len(data)) > maximumOutput {
			return nil, errors.New("strip exceeds expected output")
		}
		return append([]byte(nil), data...), nil
	}
	output := make([]byte, 0, len(data))
	for index := 0; index < len(data); {
		control := int8(data[index])
		index++
		switch {
		case control >= 0:
			count := int(control) + 1
			if count > len(data)-index {
				return nil, errors.New("PackBits literal overrun")
			}
			output = append(output, data[index:index+count]...)
			if uint64(len(output)) > maximumOutput {
				return nil, errors.New("PackBits output exceeds expected size")
			}
			index += count
		case control != -128:
			count := 1 - int(control)
			if index >= len(data) {
				return nil, errors.New("PackBits repeat overrun")
			}
			for repeat := 0; repeat < count; repeat++ {
				output = append(output, data[index])
			}
			if uint64(len(output)) > maximumOutput {
				return nil, errors.New("PackBits output exceeds expected size")
			}
			index++
		}
	}
	return output, nil
}
