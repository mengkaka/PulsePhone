package direct

import (
	"archive/zip"
	"bytes"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"path"
	"strings"
	"syscall"
)

const (
	maximumArchiveEntries       = 200_000
	maximumCentralDirectorySize = 64 * 1024 * 1024
	maximumInfoPlistBytes       = 4 * 1024 * 1024
)

type IPAFile struct {
	file     *os.File
	bundleID string
	size     int64
	device   int32
	inode    uint64
	mtime    syscall.Timespec
	ctime    syscall.Timespec
	closed   bool
}

func OpenIPA(filename string) (*IPAFile, error) {
	if !validIPAPath(filename) {
		return nil, errors.New("invalid ipa path")
	}
	fd, err := syscall.Open(filename, syscall.O_RDONLY|syscall.O_CLOEXEC|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return nil, errors.New("invalid ipa file")
	}
	file := os.NewFile(uintptr(fd), filename)
	if file == nil {
		_ = syscall.Close(fd)
		return nil, errors.New("invalid ipa file")
	}
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() <= 0 {
		_ = file.Close()
		return nil, errors.New("invalid ipa file")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		_ = file.Close()
		return nil, errors.New("invalid ipa metadata")
	}
	bundleID, err := extractBundleID(file, info.Size())
	if err != nil {
		_ = file.Close()
		return nil, err
	}
	return &IPAFile{
		file: file, bundleID: bundleID, size: info.Size(), device: stat.Dev, inode: stat.Ino,
		mtime: stat.Mtimespec, ctime: stat.Ctimespec,
	}, nil
}

func (f *IPAFile) BundleID() string { return f.bundleID }

func (f *IPAFile) Size() int64 { return f.size }

func (f *IPAFile) ReadAt(buffer []byte, offset int64) (int, error) {
	if f.closed || f.file == nil {
		return 0, errors.New("ipa closed")
	}
	if offset < 0 || len(buffer) == 0 || len(buffer) > afcWriteChunkBytes {
		return 0, errors.New("invalid ipa read")
	}
	return f.file.ReadAt(buffer, offset)
}

func (f *IPAFile) VerifyUnchanged() error {
	if f.closed || f.file == nil {
		return errors.New("ipa closed")
	}
	current, err := f.file.Stat()
	if err != nil || !current.Mode().IsRegular() || current.Size() != f.size {
		return errors.New("ipa changed during upload")
	}
	stat, ok := current.Sys().(*syscall.Stat_t)
	if !ok || stat.Dev != f.device || stat.Ino != f.inode || stat.Mtimespec != f.mtime || stat.Ctimespec != f.ctime {
		return errors.New("ipa changed during upload")
	}
	return nil
}

func (f *IPAFile) Close() error {
	if f.closed {
		return nil
	}
	f.closed = true
	return f.file.Close()
}

func validIPAPath(filename string) bool {
	if filename == "" || !strings.HasPrefix(filename, "/") || strings.Contains(filename, "\x00") ||
		strings.Contains(filename, "//") || strings.HasSuffix(filename, "/") ||
		path.Clean(filename) != filename || !strings.EqualFold(path.Ext(filename), ".ipa") {
		return false
	}
	for _, part := range strings.Split(filename, "/") {
		if part == ".." {
			return false
		}
	}
	return true
}

func extractBundleID(file *os.File, size int64) (string, error) {
	if err := validateCentralDirectory(file, size); err != nil {
		return "", err
	}
	archive, err := zip.NewReader(file, size)
	if err != nil {
		return "", fmt.Errorf("invalid ipa archive: %w", err)
	}
	if len(archive.File) == 0 || len(archive.File) > maximumArchiveEntries {
		return "", errors.New("invalid ipa entry count")
	}
	var candidate *zip.File
	for _, entry := range archive.File {
		parts := strings.Split(entry.Name, "/")
		if len(parts) == 3 && parts[0] == "Payload" && strings.HasSuffix(parts[1], ".app") && parts[2] == "Info.plist" {
			if candidate != nil {
				return "", errors.New("multiple ipa app metadata files")
			}
			candidate = entry
		}
	}
	if candidate == nil || candidate.UncompressedSize64 > maximumInfoPlistBytes || candidate.Flags&0x1 != 0 {
		return "", errors.New("ipa app metadata missing or too large")
	}
	reader, err := candidate.Open()
	if err != nil {
		return "", err
	}
	metadata, readErr := io.ReadAll(io.LimitReader(reader, maximumInfoPlistBytes+1))
	_ = reader.Close()
	if readErr != nil || len(metadata) > maximumInfoPlistBytes {
		return "", errors.New("ipa app metadata read")
	}
	plist, err := decodePlist(metadata)
	if err != nil {
		return "", errors.New("ipa app metadata plist")
	}
	bundleID, ok := plist["CFBundleIdentifier"].(string)
	if !ok || !validBundleID(bundleID) {
		return "", errors.New("invalid ipa bundle id")
	}
	return bundleID, nil
}

func validateCentralDirectory(file *os.File, size int64) error {
	tailSize := size
	if tailSize > 65_557 {
		tailSize = 65_557
	}
	tail := make([]byte, int(tailSize))
	read, err := file.ReadAt(tail, size-tailSize)
	if (err != nil && !(err == io.EOF && read == len(tail))) || read != len(tail) {
		return errors.New("ipa eocd read")
	}
	offset := bytes.LastIndex(tail, []byte{'P', 'K', 5, 6})
	if offset < 0 || len(tail)-offset < 22 {
		return errors.New("ipa eocd")
	}
	eocd := tail[offset : offset+22]
	disk := binary.LittleEndian.Uint16(eocd[4:6])
	centralDisk := binary.LittleEndian.Uint16(eocd[6:8])
	diskEntries := binary.LittleEndian.Uint16(eocd[8:10])
	entries := binary.LittleEndian.Uint16(eocd[10:12])
	centralSize := int64(binary.LittleEndian.Uint32(eocd[12:16]))
	centralOffset := int64(binary.LittleEndian.Uint32(eocd[16:20]))
	commentSize := int(binary.LittleEndian.Uint16(eocd[20:22]))
	if disk != 0 || centralDisk != 0 || diskEntries != entries || entries == 0 || int(entries) > maximumArchiveEntries ||
		centralSize > maximumCentralDirectorySize || centralOffset+centralSize > size || offset+22+commentSize != len(tail) {
		return errors.New("ipa central directory")
	}
	return nil
}

func validBundleID(value string) bool {
	if len(value) == 0 || len(value) > 255 || !strings.Contains(value, ".") {
		return false
	}
	for _, segment := range strings.Split(value, ".") {
		if segment == "" {
			return false
		}
		for index, character := range segment {
			asciiAlphaNumeric := (character >= 'a' && character <= 'z') || (character >= 'A' && character <= 'Z') || (character >= '0' && character <= '9')
			if index == 0 && !asciiAlphaNumeric {
				return false
			}
			if !asciiAlphaNumeric && character != '-' {
				return false
			}
		}
	}
	return true
}
