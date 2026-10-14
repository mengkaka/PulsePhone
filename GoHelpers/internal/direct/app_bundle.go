package direct

import (
	"archive/zip"
	"encoding/binary"
	"errors"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const maximumAppBundleNodes = 65_532 // Payload plus source tree must fit a non-ZIP64 archive.
const maximumAppArchiveBytes int64 = 1<<32 - 1

var errAppPlatform = errors.New("app platform is not iPhoneOS arm64")

type appBundleSource struct {
	*IPAFile
	root     *os.Root
	path     string
	temp     string
	snapshot map[string]os.FileInfo
	deadline time.Time
}

func openInstallSource(filename string, deadline time.Time) (installRouteSource, error) {
	if strings.EqualFold(filepath.Ext(filename), ".app") {
		return openAppBundle(filename, deadline)
	}
	return OpenIPA(filename)
}

func openAppBundle(filename string, deadline time.Time) (_ *appBundleSource, resultErr error) {
	if !validInstallationPath(filename) || !strings.EqualFold(filepath.Ext(filename), ".app") {
		return nil, errors.New("invalid app path")
	}
	initial, err := os.Lstat(filename)
	if err != nil || !initial.IsDir() {
		return nil, errors.New("invalid app directory")
	}
	root, err := os.OpenRoot(filename)
	if err != nil {
		return nil, err
	}
	source := &appBundleSource{root: root, path: filename, deadline: deadline}
	defer func() {
		if resultErr != nil {
			_ = source.Close()
		}
	}()
	anchored, err := root.Stat(".")
	if err != nil || !sameAppNode(initial, anchored) {
		return nil, errors.New("app directory changed")
	}
	source.snapshot, err = source.scan()
	if err != nil {
		return nil, err
	}
	if err := source.validate(); err != nil {
		return nil, err
	}
	source.temp, err = os.MkdirTemp("", "pulsephone-app-install-")
	if err != nil {
		return nil, err
	}
	archivePath := filepath.Join(source.temp, "Application.ipa")
	archive, err := os.OpenFile(archivePath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		return nil, err
	}
	err = source.archive(archive)
	if closeErr := archive.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		return nil, err
	}
	source.IPAFile, err = OpenIPA(archivePath)
	if err != nil {
		return nil, err
	}
	if err := source.VerifyUnchanged(); err != nil {
		return nil, err
	}
	return source, nil
}

func validInstallationPath(filename string) bool {
	if filename == "" || len(filename) > 4096 || !filepath.IsAbs(filename) || strings.Contains(filename, "\x00") ||
		strings.Contains(filename, "//") || strings.HasSuffix(filename, "/") || filepath.Clean(filename) != filename {
		return false
	}
	ext := filepath.Ext(filename)
	return strings.EqualFold(ext, ".ipa") || strings.EqualFold(ext, ".app")
}

func sameAppNode(before, after os.FileInfo) bool {
	if before == nil || after == nil || !os.SameFile(before, after) || before.Mode() != after.Mode() ||
		before.Size() != after.Size() || !before.ModTime().Equal(after.ModTime()) {
		return false
	}
	b, bok := before.Sys().(*syscall.Stat_t)
	a, aok := after.Sys().(*syscall.Stat_t)
	return bok && aok && b.Ctimespec == a.Ctimespec
}

func (s *appBundleSource) checkDeadline() error {
	if !time.Now().Before(s.deadline) {
		return errors.New("app preparation deadline")
	}
	return nil
}

func (s *appBundleSource) scan() (map[string]os.FileInfo, error) {
	nodes := make(map[string]os.FileInfo)
	var bytes int64
	err := fs.WalkDir(s.root.FS(), ".", func(name string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if err := s.checkDeadline(); err != nil {
			return err
		}
		info, err := s.root.Lstat(name)
		if err != nil {
			return err
		}
		if len(nodes) >= maximumAppBundleNodes {
			return errors.New("app node cap")
		}
		switch {
		case info.IsDir():
		case info.Mode().IsRegular():
			bytes += info.Size()
			if bytes >= maximumAppArchiveBytes {
				return errors.New("app archive cap")
			}
		case info.Mode()&os.ModeSymlink != 0:
			// Root.Stat checks the complete symlink chain, rejects absolute/escaping
			// links and cycles, and never traverses outside the anchored source.
			if _, err := s.root.Stat(name); err != nil {
				return errors.New("invalid app symlink")
			}
		default:
			return errors.New("invalid app node type")
		}
		nodes[name] = info
		return nil
	})
	return nodes, err
}

func (s *appBundleSource) openRegular(name string) (*os.File, error) {
	info := s.snapshot[name]
	if info == nil || !info.Mode().IsRegular() {
		return nil, errors.New("invalid app file")
	}
	file, err := s.root.Open(name)
	if err != nil {
		return nil, err
	}
	current, err := file.Stat()
	if err != nil || !sameAppNode(info, current) {
		_ = file.Close()
		return nil, errors.New("app file changed")
	}
	return file, nil
}

func (s *appBundleSource) validate() error {
	file, err := s.openRegular("Info.plist")
	if err != nil {
		return err
	}
	metadata, err := io.ReadAll(io.LimitReader(file, maximumInfoPlistBytes+1))
	_ = file.Close()
	if err != nil || len(metadata) > maximumInfoPlistBytes {
		return errors.New("invalid app metadata size")
	}
	info, err := decodePlist(metadata)
	if err != nil {
		return errors.New("invalid app metadata")
	}
	bundle, _ := info["CFBundleIdentifier"].(string)
	executable, _ := info["CFBundleExecutable"].(string)
	if !validBundleID(bundle) || info["CFBundlePackageType"] != "APPL" || executable == "" ||
		filepath.Base(executable) != executable || executable == "." || executable == ".." || strings.Contains(executable, "\x00") {
		return errors.New("invalid app bundle metadata")
	}
	platforms, ok := info["CFBundleSupportedPlatforms"].([]any)
	if !ok || len(platforms) != 1 || platforms[0] != "iPhoneOS" {
		return errAppPlatform
	}
	if platform, present := info["DTPlatformName"]; present && platform != "iphoneos" {
		return errAppPlatform
	}
	file, err = s.openRegular(executable)
	if err != nil {
		return err
	}
	defer file.Close()
	if s.snapshot[executable].Mode().Perm()&0o111 == 0 {
		return errors.New("app executable permission")
	}
	return validateDeviceExecutable(file, 0, s.snapshot[executable].Size(), true)
}

// Read only bounded headers and platform commands, never symbol/debug tables.
func validateDeviceExecutable(file io.ReaderAt, offset, size int64, allowFat bool) error {
	var header [32]byte
	if size < 32 {
		return errors.New("invalid app executable header")
	}
	if _, err := file.ReadAt(header[:], offset); err != nil {
		return err
	}
	order := binary.ByteOrder(binary.BigEndian)
	magic := order.Uint32(header[:4])
	if magic == 0xcefaedfe || magic == 0xcffaedfe || magic == 0xbebafeca {
		order = binary.LittleEndian
		magic = order.Uint32(header[:4])
	}
	switch magic {
	case 0xfeedface, 0xfeedfacf:
		if magic != 0xfeedfacf || order.Uint32(header[4:8]) != 0x0100000c || order.Uint32(header[12:16]) != 2 {
			return errAppPlatform
		}
		count, commandBytes := order.Uint32(header[16:20]), order.Uint32(header[20:24])
		if commandBytes > afcWriteChunkBytes || int64(commandBytes)+32 > size || uint64(count)*8 > uint64(commandBytes) {
			return errors.New("app executable load command cap")
		}
		cursor, end := offset+32, offset+32+int64(commandBytes)
		foundPlatform := false
		for index := uint32(0); index < count; index++ {
			var command [8]byte
			if cursor+8 > end {
				return errors.New("invalid app load command")
			}
			if _, err := file.ReadAt(command[:], cursor); err != nil {
				return err
			}
			kind, length := order.Uint32(command[:4]), int64(order.Uint32(command[4:8]))
			if length < 8 || length%8 != 0 || cursor+length > end {
				return errors.New("invalid app load command bounds")
			}
			switch kind {
			case 0x32: // LC_BUILD_VERSION: iOS=2, simulator=7.
				if length < 24 {
					return errors.New("invalid app build version")
				}
				var platform [4]byte
				if _, err := file.ReadAt(platform[:], cursor+8); err != nil {
					return err
				}
				if order.Uint32(platform[:]) != 2 {
					return errAppPlatform
				}
				foundPlatform = true
			case 0x25: // LC_VERSION_MIN_IPHONEOS for older device builds.
				if length < 16 {
					return errors.New("invalid app minimum version")
				}
				foundPlatform = true
			case 0x24, 0x2f, 0x30: // macOS, tvOS, watchOS.
				return errAppPlatform
			}
			cursor += length
		}
		if cursor != end {
			return errors.New("invalid app load command table")
		}
		if !foundPlatform {
			return errAppPlatform
		}
		return nil
	case 0xcafebabe:
		count := order.Uint32(header[4:8])
		if !allowFat || count == 0 || count > 128 || 8+int64(count)*20 > size {
			return errors.New("app executable architecture cap")
		}
		var arch [20]byte
		for index := uint32(0); index < count; index++ {
			if _, err := file.ReadAt(arch[:], offset+8+int64(index)*20); err != nil {
				return err
			}
			start, length := int64(order.Uint32(arch[8:12])), int64(order.Uint32(arch[12:16]))
			if start < 8+int64(count)*20 || start+length > size {
				return errors.New("invalid app architecture bounds")
			}
			if order.Uint32(arch[:4]) == 0x0100000c {
				return validateDeviceExecutable(file, offset+start, length, false)
			}
		}
		return errAppPlatform
	default:
		return errors.New("invalid app executable magic")
	}
}

type cappedArchiveWriter struct {
	io.Writer
	bytes int64
}

func (w *cappedArchiveWriter) Write(data []byte) (int, error) {
	if w.bytes+int64(len(data)) >= maximumAppArchiveBytes {
		return 0, errors.New("app archive cap")
	}
	n, err := w.Writer.Write(data)
	w.bytes += int64(n)
	return n, err
}

func (s *appBundleSource) archive(output io.Writer) error {
	archive := zip.NewWriter(&cappedArchiveWriter{Writer: output})
	prefix := "Payload/" + filepath.Base(s.path) + "/"
	if _, err := archive.Create("Payload/"); err != nil {
		return err
	}
	buffer := make([]byte, afcWriteChunkBytes)
	// WalkDir is sorted and does not descend into symlinks.
	err := fs.WalkDir(s.root.FS(), ".", func(name string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if err := s.checkDeadline(); err != nil {
			return err
		}
		info := s.snapshot[name]
		current, err := s.root.Lstat(name)
		if err != nil || !sameAppNode(info, current) {
			return errors.New("app tree changed during archive")
		}
		header, err := zip.FileInfoHeader(info)
		if err != nil {
			return err
		}
		header.Name = prefix
		if name != "." {
			header.Name += filepath.ToSlash(name)
			if info.IsDir() {
				header.Name += "/"
			}
		}
		header.Method = zip.Store
		writer, err := archive.CreateHeader(header)
		if err != nil || info.IsDir() {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			link, err := s.root.Readlink(name)
			if err != nil {
				return err
			}
			_, err = io.WriteString(writer, link)
			return err
		}
		file, err := s.openRegular(name)
		if err != nil {
			return err
		}
		defer file.Close()
		remaining := info.Size()
		for remaining > 0 {
			if err := s.checkDeadline(); err != nil {
				return err
			}
			n := int64(len(buffer))
			if remaining < n {
				n = remaining
			}
			if _, err := io.ReadFull(file, buffer[:n]); err != nil {
				return err
			}
			if _, err := writer.Write(buffer[:n]); err != nil {
				return err
			}
			remaining -= n
		}
		current, err = file.Stat()
		if err != nil || !sameAppNode(info, current) {
			return errors.New("app file changed during archive")
		}
		return nil
	})
	if err != nil {
		return err
	}
	return archive.Close()
}

func (s *appBundleSource) VerifyUnchanged() error {
	if s.root == nil || s.IPAFile == nil {
		return errors.New("app source closed")
	}
	current, err := os.Lstat(s.path)
	if err != nil || !sameAppNode(s.snapshot["."], current) {
		return errors.New("app source replaced")
	}
	nodes, err := s.scan()
	if err != nil || len(nodes) != len(s.snapshot) {
		return errors.New("app tree changed")
	}
	for name, before := range s.snapshot {
		if !sameAppNode(before, nodes[name]) {
			return errors.New("app node changed")
		}
	}
	return s.IPAFile.VerifyUnchanged()
}

func (s *appBundleSource) Close() error {
	var errs []error
	if s.IPAFile != nil {
		errs = append(errs, s.IPAFile.Close())
		s.IPAFile = nil
	}
	if s.root != nil {
		errs = append(errs, s.root.Close())
		s.root = nil
	}
	if s.temp != "" {
		errs = append(errs, os.RemoveAll(s.temp))
		s.temp = ""
	}
	return errors.Join(errs...)
}
