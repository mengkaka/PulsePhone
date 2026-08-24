package direct

import (
	"archive/zip"
	"bytes"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestOpenIPARejectsSymlinkAtOpenTime(t *testing.T) {
	target := writeFixtureIPA(t)
	link := filepath.Join(t.TempDir(), "link.ipa")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	if _, err := OpenIPA(link); err == nil {
		t.Fatal("OpenIPA accepted a symlink")
	}
}

func TestOpenIPAAcceptsDirectoryEntriesLikePythonPreflight(t *testing.T) {
	source, err := OpenIPA(writeFixtureIPA(t))
	if err != nil {
		t.Fatal(err)
	}
	defer source.Close()
	if source.BundleID() != "com.example.Fixture" {
		t.Fatalf("bundle ID = %q", source.BundleID())
	}
}

func TestIPAFileVerifyUnchangedDetectsMetadataChange(t *testing.T) {
	path := writeFixtureIPA(t)
	source, err := OpenIPA(path)
	if err != nil {
		t.Fatal(err)
	}
	defer source.Close()
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(time.Millisecond)
	if err := os.Chmod(path, info.Mode().Perm()^0o100); err != nil {
		t.Fatal(err)
	}
	if err := source.VerifyUnchanged(); err == nil {
		t.Fatal("VerifyUnchanged accepted a ctime-only mutation")
	}
}

func TestOpenIPARejectsInvalidCentralDirectoryBeforeZipParsing(t *testing.T) {
	path := writeFixtureIPA(t)
	raw, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	offset := bytes.LastIndex(raw, []byte{'P', 'K', 5, 6})
	if offset < 0 {
		t.Fatal("fixture has no end of central directory")
	}
	raw[offset+4] = 1 // multi-disk archives are outside the Python helper contract.
	if err := os.WriteFile(path, raw, 0o600); err != nil {
		t.Fatal(err)
	}
	if _, err := OpenIPA(path); err == nil {
		t.Fatal("OpenIPA accepted an invalid central directory")
	}
}

func TestOpenIPARejectsMalformedArchiveAndMetadataPlist(t *testing.T) {
	malformedArchive := filepath.Join(t.TempDir(), "MalformedArchive.ipa")
	if err := os.WriteFile(malformedArchive, []byte("not a zip archive"), 0o600); err != nil {
		t.Fatal(err)
	}
	malformedPlist := filepath.Join(t.TempDir(), "MalformedPlist.ipa")
	file, err := os.OpenFile(malformedPlist, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	archive := zip.NewWriter(file)
	for _, directory := range []string{"Payload/", "Payload/Fixture.app/"} {
		if _, err := archive.Create(directory); err != nil {
			t.Fatal(err)
		}
	}
	entry, err := archive.Create("Payload/Fixture.app/Info.plist")
	if err == nil {
		_, err = entry.Write([]byte("<plist><dict>"))
	}
	if closeErr := archive.Close(); err == nil {
		err = closeErr
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range []string{malformedArchive, malformedPlist} {
		if _, err := OpenIPA(path); err == nil {
			t.Fatalf("OpenIPA accepted malformed input %q", path)
		}
	}
}

func writeFixtureIPA(t *testing.T) string {
	t.Helper()
	path := filepath.Join(t.TempDir(), "Fixture.ipa")
	file, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	archive := zip.NewWriter(file)
	entry, err := archive.Create("Payload/Fixture.app/Info.plist")
	if err == nil {
		_, err = entry.Write([]byte("<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict><key>CFBundleIdentifier</key><string>com.example.Fixture</string></dict></plist>"))
	}
	if closeErr := archive.Close(); err == nil {
		err = closeErr
	}
	if closeErr := file.Close(); err == nil {
		err = closeErr
	}
	if err != nil {
		t.Fatal(err)
	}
	return path
}
