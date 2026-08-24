package direct

import (
	"bytes"
	"encoding/binary"
	"image"
	"image/color"
	"image/jpeg"
	"image/png"
	"testing"
)

func TestNormalizeImageToPNGAcceptsPNGAndJPEG(t *testing.T) {
	original := append([]byte(nil), pngSignature...)
	original = append(original, []byte("opaque fixture")...)
	converted, err := NormalizeImageToPNG(original, "png")
	if err != nil || !bytes.Equal(converted, original) {
		t.Fatalf("PNG conversion = %x, err=%v", converted, err)
	}

	var jpegBytes bytes.Buffer
	jpegImage := image.NewRGBA(image.Rect(0, 0, 2, 1))
	jpegImage.SetRGBA(0, 0, color.RGBA{R: 12, G: 34, B: 56, A: 255})
	jpegImage.SetRGBA(1, 0, color.RGBA{R: 200, G: 180, B: 160, A: 255})
	if err := jpeg.Encode(&jpegBytes, jpegImage, &jpeg.Options{Quality: 90}); err != nil {
		t.Fatal(err)
	}
	converted, err = NormalizeImageToPNG(jpegBytes.Bytes(), "jpeg")
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := png.Decode(bytes.NewReader(converted))
	if err != nil {
		t.Fatal(err)
	}
	if decoded.Bounds().Dx() != 2 || decoded.Bounds().Dy() != 1 {
		t.Fatalf("converted JPEG bounds = %v", decoded.Bounds())
	}
}

func TestNormalizeImageToPNGRejectsOversizedJPEGBeforeDecode(t *testing.T) {
	var source bytes.Buffer
	if err := jpeg.Encode(&source, image.NewRGBA(image.Rect(0, 0, 1, 1)), nil); err != nil {
		t.Fatal(err)
	}
	data := source.Bytes()
	found := false
	for offset := 0; offset+8 < len(data); offset++ {
		if data[offset] != 0xff || data[offset+1] < 0xc0 || data[offset+1] > 0xc3 {
			continue
		}
		binary.BigEndian.PutUint16(data[offset+5:offset+7], 6000)
		binary.BigEndian.PutUint16(data[offset+7:offset+9], 6000)
		found = true
		break
	}
	if !found {
		t.Fatal("JPEG fixture did not contain a baseline SOF marker")
	}
	if _, err := NormalizeImageToPNG(data, "jpeg"); err == nil {
		t.Fatal("oversized JPEG was accepted")
	}
}

func TestNormalizeImageToPNGAcceptsLittleAndBigEndianTIFF(t *testing.T) {
	pixels := []byte{
		12, 34, 56, 200, 180, 160,
		1, 2, 3, 250, 240, 230,
	}
	for _, test := range []struct {
		name  string
		order binary.ByteOrder
		mark  [2]byte
	}{
		{name: "little", order: binary.LittleEndian, mark: [2]byte{'I', 'I'}},
		{name: "big", order: binary.BigEndian, mark: [2]byte{'M', 'M'}},
	} {
		t.Run(test.name, func(t *testing.T) {
			tiff := makeTIFFFixture(test.order, test.mark, pixels, false)
			converted, err := NormalizeImageToPNG(tiff, "tiff")
			if err != nil {
				t.Fatal(err)
			}
			decoded, err := png.Decode(bytes.NewReader(converted))
			if err != nil {
				t.Fatal(err)
			}
			if decoded.Bounds().Dx() != 2 || decoded.Bounds().Dy() != 2 {
				t.Fatalf("converted TIFF bounds = %v", decoded.Bounds())
			}
			if got := color.RGBAModel.Convert(decoded.At(0, 0)).(color.RGBA); got.R != 12 || got.G != 34 || got.B != 56 || got.A != 255 {
				t.Fatalf("converted TIFF first pixel = %#v", got)
			}
		})
	}
}

func TestNormalizeImageToPNGTIFFPackBitsAndValidation(t *testing.T) {
	pixels := []byte{10, 20, 30, 40, 50, 60}
	tiff := makeTIFFFixture(binary.LittleEndian, [2]byte{'I', 'I'}, pixels, true)
	converted, err := NormalizeImageToPNG(tiff, "")
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := png.Decode(bytes.NewReader(converted))
	if err != nil || decoded.Bounds().Dx() != 2 || decoded.Bounds().Dy() != 1 {
		t.Fatalf("PackBits TIFF decode bounds=%v err=%v", decoded.Bounds(), err)
	}

	if _, err := NormalizeImageToPNG([]byte{'I', 'I', 42, 0, 8, 0, 0, 0}, "tiff"); err == nil {
		t.Fatal("truncated TIFF accepted")
	}
	if _, err := decodeTIFFStrip([]byte{0x81, 0x01}, 32773, 1); err == nil {
		t.Fatal("PackBits expansion exceeded strip limit without rejection")
	}
	if DetectImageFormat([]byte("not an image")) != "" {
		t.Fatal("unknown image format detected")
	}
}

func makeTIFFFixture(order binary.ByteOrder, mark [2]byte, pixels []byte, packBits bool) []byte {
	const (
		width           = uint32(2)
		ifdOffset       = uint32(8)
		ifdEntryCount   = uint16(10)
		bitsOffset      = uint32(134)
		pixelDataOffset = uint32(140)
	)
	height := uint32(2)
	if packBits {
		height = 1
		// Keep the fixture small while exercising a PackBits literal packet.
		pixels = append([]byte{byte(len(pixels) - 1)}, pixels...)
	}
	data := make([]byte, int(pixelDataOffset)+len(pixels))
	data[0], data[1] = mark[0], mark[1]
	order.PutUint16(data[2:4], 42)
	order.PutUint32(data[4:8], ifdOffset)
	order.PutUint16(data[8:10], ifdEntryCount)
	entry := func(index int, tag, typeID uint16, count, value uint32) {
		offset := 10 + index*12
		order.PutUint16(data[offset:offset+2], tag)
		order.PutUint16(data[offset+2:offset+4], typeID)
		order.PutUint32(data[offset+4:offset+8], count)
		if typeID == 3 && count == 1 {
			order.PutUint16(data[offset+8:offset+10], uint16(value))
		} else {
			order.PutUint32(data[offset+8:offset+12], value)
		}
	}
	entry(0, 256, 4, 1, width)
	entry(1, 257, 4, 1, height)
	entry(2, 258, 3, 3, bitsOffset)
	entry(3, 259, 3, 1, map[bool]uint32{false: 1, true: 32773}[packBits])
	entry(4, 262, 3, 1, 2)
	entry(5, 273, 4, 1, pixelDataOffset)
	entry(6, 277, 3, 1, 3)
	entry(7, 278, 4, 1, map[bool]uint32{false: height, true: 1}[packBits])
	entry(8, 279, 4, 1, uint32(len(pixels)))
	entry(9, 284, 3, 1, 1)
	// The next-IFD pointer follows the entries. BitsPerSample is stored out of line.
	order.PutUint32(data[130:134], 0)
	order.PutUint16(data[134:136], 8)
	order.PutUint16(data[136:138], 8)
	order.PutUint16(data[138:140], 8)
	copy(data[pixelDataOffset:], pixels)
	return data
}
