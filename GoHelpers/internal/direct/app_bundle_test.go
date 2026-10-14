package direct

import (
	"archive/zip"
	"bytes"
	"encoding/binary"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"
)

func fixtureDeviceApp(t *testing.T) string {
	t.Helper()
	app := filepath.Join(t.TempDir(), "Fixture.app")
	if err := os.MkdirAll(filepath.Join(app, "_CodeSignature"), 0o755); err != nil {
		t.Fatal(err)
	}
	metadata := `<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>com.example.Fixture</string><key>CFBundlePackageType</key><string>APPL</string><key>CFBundleExecutable</key><string>Fixture</string><key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array><key>DTPlatformName</key><string>iphoneos</string></dict></plist>`
	files := map[string][]byte{
		"Info.plist": []byte(metadata), "Fixture": fixtureDeviceMachO(2),
		"_CodeSignature/CodeResources": []byte("signature must remain unchanged"),
		"embedded.mobileprovision":     []byte("provisioning must remain unchanged"),
	}
	for name, data := range files {
		if err := os.WriteFile(filepath.Join(app, name), data, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Chmod(filepath.Join(app, "Fixture"), 0o755); err != nil {
		t.Fatal(err)
	}
	return app
}

func fixtureDeviceMachO(platform uint32) []byte {
	data := make([]byte, 56)
	for index, value := range []uint32{0xfeedfacf, 0x0100000c, 0, 2, 1, 24, 0, 0, 0x32, 24, platform, 14 << 16, 14 << 16, 0} {
		binary.LittleEndian.PutUint32(data[index*4:], value)
	}
	return data
}

func TestAppBundleArchivesOriginalBytesPermissionsAndRelativeLinks(t *testing.T) {
	app := fixtureDeviceApp(t)
	resource := bytes.Repeat([]byte("resource"), afcWriteChunkBytes/8+1)
	if err := os.WriteFile(filepath.Join(app, "Resource"), resource, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("Resource", filepath.Join(app, "ResourceLink")); err != nil {
		t.Fatal(err)
	}
	source, err := openAppBundle(app, time.Now().Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	temp := source.temp
	t.Cleanup(func() { _ = source.Close() })
	if source.BundleID() != "com.example.Fixture" {
		t.Fatal(source.BundleID())
	}
	for path, mode := range map[string]os.FileMode{temp: 0o700, filepath.Join(temp, "Application.ipa"): 0o600} {
		info, err := os.Stat(path)
		if err != nil || info.Mode().Perm() != mode {
			t.Fatalf("private staging mode = %v, %v", info, err)
		}
	}
	archive, err := zip.OpenReader(filepath.Join(temp, "Application.ipa"))
	if err != nil {
		t.Fatal(err)
	}
	entries := map[string]*zip.File{}
	for _, entry := range archive.File {
		entries[entry.Name] = entry
	}
	for _, name := range []string{"Fixture", "Info.plist", "Resource", "_CodeSignature/CodeResources", "embedded.mobileprovision", "ResourceLink"} {
		entry := entries["Payload/Fixture.app/"+name]
		if entry == nil {
			t.Fatalf("missing %s", name)
		}
		reader, err := entry.Open()
		if err != nil {
			t.Fatal(err)
		}
		got, err := io.ReadAll(reader)
		reader.Close()
		if err != nil {
			t.Fatal(err)
		}
		var want []byte
		if name == "ResourceLink" {
			want = []byte("Resource")
			if entry.Mode()&os.ModeSymlink == 0 {
				t.Fatal("symlink dereferenced")
			}
		} else {
			want, err = os.ReadFile(filepath.Join(app, name))
			if err != nil {
				t.Fatal(err)
			}
			info, _ := os.Stat(filepath.Join(app, name))
			if entry.Mode().Perm() != info.Mode().Perm() {
				t.Fatal("file permissions changed")
			}
		}
		if !bytes.Equal(got, want) {
			t.Fatalf("archive changed %s", name)
		}
	}
	archive.Close()
	if err := source.VerifyUnchanged(); err != nil {
		t.Fatal(err)
	}
	if err := source.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(temp); !os.IsNotExist(err) {
		t.Fatal("temporary archive was not removed")
	}
}

func TestAppBundleRejectsSimulatorMetadataAndMachO(t *testing.T) {
	for _, scenario := range []string{"simulator metadata", "simulator executable", "macOS executable", "no platform load command"} {
		t.Run(scenario, func(t *testing.T) {
			app := fixtureDeviceApp(t)
			if scenario == "simulator metadata" {
				file := filepath.Join(app, "Info.plist")
				data, _ := os.ReadFile(file)
				if err := os.WriteFile(file, bytes.ReplaceAll(data, []byte("iPhoneOS"), []byte("iPhoneSimulator")), 0o600); err != nil {
					t.Fatal(err)
				}
			} else {
				platform := uint32(7)
				if scenario == "macOS executable" {
					platform = 1
				}
				data := fixtureDeviceMachO(platform)
				if scenario == "no platform load command" {
					data = data[:32]
					binary.LittleEndian.PutUint32(data[16:20], 0)
					binary.LittleEndian.PutUint32(data[20:24], 0)
				}
				if err := os.WriteFile(filepath.Join(app, "Fixture"), data, 0o755); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := openAppBundle(app, time.Now().Add(time.Minute)); !errors.Is(err, errAppPlatform) {
				t.Fatalf("expected platform rejection, got %v", err)
			}
		})
	}
}

func TestAppBundleRejectsUnsafeSources(t *testing.T) {
	for _, scenario := range []string{"root symlink", "external symlink", "absolute internal symlink", "fifo", "missing executable", "non executable", "bad metadata", "expired deadline"} {
		t.Run(scenario, func(t *testing.T) {
			app := fixtureDeviceApp(t)
			deadline := time.Now().Add(time.Minute)
			var err error
			switch scenario {
			case "root symlink":
				link := filepath.Join(t.TempDir(), "Link.app")
				err = os.Symlink(app, link)
				app = link
			case "external symlink":
				err = os.Symlink("../../outside", filepath.Join(app, "Link"))
			case "absolute internal symlink":
				err = os.Symlink(filepath.Join(app, "Fixture"), filepath.Join(app, "Link"))
			case "fifo":
				err = syscall.Mkfifo(filepath.Join(app, "Pipe"), 0o600)
			case "missing executable":
				err = os.Remove(filepath.Join(app, "Fixture"))
			case "non executable":
				err = os.Chmod(filepath.Join(app, "Fixture"), 0o600)
			case "bad metadata":
				err = os.WriteFile(filepath.Join(app, "Info.plist"), []byte("bad plist"), 0o600)
			case "expired deadline":
				deadline = time.Now().Add(-time.Second)
			}
			if err != nil {
				t.Fatal(err)
			}
			if source, err := openAppBundle(app, deadline); err == nil {
				source.Close()
				t.Fatal("unsafe app accepted")
			}
		})
	}
}

func TestAppBundleDetectsSourceMutationBeforeInstallationAndCleansUp(t *testing.T) {
	for _, scenario := range []string{"file content", "file mode", "new entry", "removed entry", "root replacement"} {
		t.Run(scenario, func(t *testing.T) {
			app := fixtureDeviceApp(t)
			source, err := openAppBundle(app, time.Now().Add(time.Minute))
			if err != nil {
				t.Fatal(err)
			}
			temp := source.temp
			switch scenario {
			case "file content":
				err = os.WriteFile(filepath.Join(app, "Fixture"), []byte("new build"), 0o755)
			case "file mode":
				err = os.Chmod(filepath.Join(app, "Fixture"), 0o700)
			case "new entry":
				err = os.WriteFile(filepath.Join(app, "New"), []byte("new"), 0o600)
			case "removed entry":
				err = os.Remove(filepath.Join(app, "embedded.mobileprovision"))
			case "root replacement":
				err = os.Rename(app, app+".old")
				if err == nil {
					err = os.Mkdir(app, 0o755)
				}
			}
			if err != nil {
				t.Fatal(err)
			}
			if err := source.VerifyUnchanged(); err == nil {
				t.Fatal("changed source accepted")
			}
			if err := source.Close(); err != nil {
				t.Fatal(err)
			}
			if _, err := os.Stat(temp); !os.IsNotExist(err) {
				t.Fatal("temp leaked")
			}
		})
	}
}

func TestOversizedAppBundleRejectsBeforeCreatingPrivateTemp(t *testing.T) {
	temp := t.TempDir()
	t.Setenv("TMPDIR", temp)
	app := fixtureDeviceApp(t)
	// A sparse source exercises the cap without allocating or reading 4 GiB.
	file, err := os.Create(filepath.Join(app, "Huge"))
	if err != nil {
		t.Fatal(err)
	}
	err = file.Truncate(maximumAppArchiveBytes)
	file.Close()
	if err != nil {
		t.Fatal(err)
	}
	if source, err := openAppBundle(app, time.Now().Add(time.Minute)); err == nil {
		source.Close()
		t.Fatal("oversized bundle accepted")
	}
	entries, err := os.ReadDir(temp)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.HasPrefix(entry.Name(), "pulsephone-app-install-") {
			t.Fatal("private temp leaked")
		}
	}
}

type mutatingAppAFC struct {
	*fakeInstallRouteAFC
	mutate func()
}

func (afc *mutatingAppAFC) CloseFile(handle uint64) error {
	afc.mutate()
	return afc.fakeInstallRouteAFC.CloseFile(handle)
}

func TestAppBundleInstallRouteCleanupAndMutationBeforeCommit(t *testing.T) {
	for _, scenario := range []string{"success", "service failure", "source mutation"} {
		t.Run(scenario, func(t *testing.T) {
			app := fixtureDeviceApp(t)
			events := []string{}
			afc := &fakeInstallRouteAFC{events: &events, handle: 41}
			service := &fakeInstallRouteService{events: &events, responses: []map[string]any{{"Status": "Complete"}}}
			lockdown := &fakeInstallRouteLockdown{events: &events}
			dependencies := installTestDependencies(t, &events, nil, afc, service, lockdown)
			deadline := time.Now().Add(time.Minute)
			var temp string
			dependencies.openIPA = func(path string) (installRouteSource, error) {
				source, err := openInstallSource(path, deadline)
				if err == nil {
					temp = source.(*appBundleSource).temp
				}
				return source, err
			}
			if scenario == "service failure" {
				lockdown.startErr = errors.New("unavailable")
			}
			if scenario == "source mutation" {
				base := dependencies.newAFC
				dependencies.newAFC = func(conn net.Conn, deadline time.Time) installRouteAFC {
					base(conn, deadline)
					return &mutatingAppAFC{afc, func() {
						if err := os.WriteFile(filepath.Join(app, "Resource"), []byte("changed"), 0o600); err != nil {
							t.Fatal(err)
						}
					}}
				}
			}
			result, failure := installAppWithDependencies(OneShotConfig{RawTransportUDID: "raw-device"},
				"00000000-0000-0000-0000-000000000001", map[string]any{"operation": "install", "ipaPath": app}, deadline, dependencies)
			switch scenario {
			case "success":
				if failure != nil || result["bundleID"] != "com.example.Fixture" {
					t.Fatalf("result = %v, failure = %v", result, failure)
				}
			case "service failure":
				if failure == nil || failure.Stage != "serviceOpen" || failure.CommitState != "notCommitted" {
					t.Fatalf("failure = %#v", failure)
				}
			case "source mutation":
				if failure == nil || failure.Code != "invalidIPA" || failure.Stage != "archiveReadRace" || containsEvent(events, "proxy.create") {
					t.Fatalf("failure = %#v, events = %v", failure, events)
				}
			}
			if temp == "" {
				t.Fatal("app was not packaged")
			}
			if _, err := os.Stat(temp); !os.IsNotExist(err) {
				t.Fatal("temporary app archive leaked")
			}
		})
	}
}

func TestAppBundleRejectsUnboundedMachOCommandTable(t *testing.T) {
	app := fixtureDeviceApp(t)
	data := fixtureDeviceMachO(2)
	binary.LittleEndian.PutUint32(data[20:24], 1<<30)
	if err := os.WriteFile(filepath.Join(app, "Fixture"), data, 0o755); err != nil {
		t.Fatal(err)
	}
	if source, err := openAppBundle(app, time.Now().Add(time.Minute)); err == nil {
		source.Close()
		t.Fatal("unbounded executable accepted")
	}
}

func TestAppBundleAcceptsUniversalAndLegacyDeviceExecutables(t *testing.T) {
	for _, variant := range []string{"universal", "legacy"} {
		t.Run(variant, func(t *testing.T) {
			app := fixtureDeviceApp(t)
			data := fixtureDeviceMachO(2)
			if variant == "legacy" {
				data = data[:48]
				binary.LittleEndian.PutUint32(data[20:24], 16)
				binary.LittleEndian.PutUint32(data[32:36], 0x25)
				binary.LittleEndian.PutUint32(data[36:40], 16)
			} else {
				fat := make([]byte, 32+len(data))
				for i, v := range []uint32{0xcafebabe, 1, 0x0100000c, 0, 32, uint32(len(data)), 3} {
					binary.BigEndian.PutUint32(fat[i*4:], v)
				}
				copy(fat[32:], data)
				data = fat
			}
			if err := os.WriteFile(filepath.Join(app, "Fixture"), data, 0o755); err != nil {
				t.Fatal(err)
			}
			source, err := openAppBundle(app, time.Now().Add(time.Minute))
			if err != nil {
				t.Fatal(err)
			}
			source.Close()
		})
	}
}
