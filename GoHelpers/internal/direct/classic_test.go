package direct

import (
	"crypto/sha256"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"

	"pulsephone/GoHelpers/internal/protocol"
)

func writeSecureTestFile(t *testing.T, filename string, data []byte) {
	t.Helper()
	if err := os.WriteFile(filename, data, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(filename, 0o600); err != nil {
		t.Fatal(err)
	}
}

func TestClassicReferenceAndAssetLeaseVerifyCanonicalHashes(t *testing.T) {
	home, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	root := filepath.Join(home, "Library", "Application Support", "PulsePhone", "DeveloperImages")
	for _, directory := range []string{
		root, filepath.Join(root, "Catalog"), filepath.Join(root, "locks"),
		filepath.Join(root, "DDI"),
	} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(directory, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	image := []byte("classic image")
	signature := []byte("classic signature")
	imageDigest := sha256.Sum256(image)
	signatureDigest := sha256.Sum256(signature)
	const revision = "2026-08-22.1"
	manifest := map[string]any{
		"files": []any{
			map[string]any{"fileRole": classicImageRole, "sha256": hex.EncodeToString(imageDigest[:]), "size": int64(len(image))},
			map[string]any{"fileRole": classicSignatureRole, "sha256": hex.EncodeToString(signatureDigest[:]), "size": int64(len(signature))},
		},
		"imageKind": "classic",
	}
	manifestBytes, err := protocol.EncodeValue(manifest, true)
	if err != nil {
		t.Fatal(err)
	}
	contentFiles := []any{
		map[string]any{"path": "DeveloperDiskImage.dmg", "sha256": hex.EncodeToString(imageDigest[:]), "size": int64(len(image))},
		map[string]any{"path": "DeveloperDiskImage.dmg.signature", "sha256": hex.EncodeToString(signatureDigest[:]), "size": int64(len(signature))},
	}
	contentBytes, err := protocol.EncodeValue(contentFiles, false)
	if err != nil {
		t.Fatal(err)
	}
	contentDigest := sha256.Sum256(contentBytes)
	contentManifestSHA256 := hex.EncodeToString(contentDigest[:])
	catalog := map[string]any{
		"baseAssets":                  []any{},
		"catalogEntry":                []any{},
		"catalogRevision":             revision,
		"defaultCandidateBaseAssetID": "base.unused",
		"developerDiskImages": []any{
			map[string]any{
				"archiveSHA256":         strings.Repeat("a", 64),
				"archiveSize":           int64(1),
				"contentManifestSHA256": contentManifestSHA256,
				"ddiVersion":            "16.2",
				"sourceURL":             "https://example.invalid/classic.tar",
			},
			map[string]any{
				"archiveSHA256":         strings.Repeat("a", 64),
				"archiveSize":           int64(1),
				"contentManifestSHA256": contentManifestSHA256,
				"ddiVersion":            "16.3",
				"sourceURL":             "https://example.invalid/classic.tar",
			},
		},
		"schemaVersion": int64(1),
	}
	catalogBytes, err := protocol.EncodeValue(catalog, true)
	if err != nil {
		t.Fatal(err)
	}
	catalogDigest := sha256.Sum256(catalogBytes)
	catalogCanonicalSHA256 := hex.EncodeToString(catalogDigest[:])
	writeSecureTestFile(t, filepath.Join(root, "Catalog", "developer-image-catalog.v1.json"), catalogBytes)
	assetRoot := filepath.Join(root, "DDI", contentManifestSHA256)
	if err := os.MkdirAll(filepath.Join(assetRoot, "roles"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(assetRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(filepath.Join(assetRoot, "roles"), 0o700); err != nil {
		t.Fatal(err)
	}
	writeSecureTestFile(t, filepath.Join(root, "locks", contentManifestSHA256+".lock"), nil)
	writeSecureTestFile(t, filepath.Join(assetRoot, "manifest.v1.json"), manifestBytes)
	writeSecureTestFile(t, filepath.Join(assetRoot, "roles", classicImageRole), image)
	writeSecureTestFile(t, filepath.Join(assetRoot, "roles", classicSignatureRole), signature)

	reference, err := loadClassicReference(revision, catalogCanonicalSHA256, contentManifestSHA256)
	if err != nil {
		t.Fatal(err)
	}
	if reference.contentManifestSHA256 != contentManifestSHA256 || len(reference.requiredServices) != 2 {
		t.Fatalf("reference = %#v", reference)
	}
	for _, candidate := range [][3]string{{"../catalog", catalogCanonicalSHA256, contentManifestSHA256}, {"wrong.revision", catalogCanonicalSHA256, contentManifestSHA256}, {revision, strings.Repeat("b", 64), contentManifestSHA256}} {
		if _, err := loadClassicReference(candidate[0], candidate[1], candidate[2]); err == nil {
			t.Fatalf("invalid catalog reference accepted: %#v", candidate)
		}
	}
	if _, err := openClassicAsset(reference, []any{classicImageRole, "path"}); err == nil {
		t.Fatal("unknown role accepted")
	}
	lease, err := openClassicAsset(reference, []any{classicImageRole, classicSignatureRole})
	if err != nil {
		t.Fatal(err)
	}
	gotSignature, err := readBoundedFile(lease.roles[classicSignatureRole], classicSignatureMaximum)
	if err != nil || string(gotSignature) != string(signature) {
		t.Fatalf("signature=%q err=%v", gotSignature, err)
	}
	lease.Close()

	roles := filepath.Join(assetRoot, "roles")
	if err := os.Rename(roles, filepath.Join(assetRoot, "roles-original")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("roles-original", roles); err != nil {
		t.Fatal(err)
	}
	if _, err := openClassicAsset(reference, []any{classicImageRole, classicSignatureRole}); err == nil {
		t.Fatal("intermediate in-store symlink accepted")
	}
}

func TestClassicPayloadRequiresExactRolesAndConnectionEpoch(t *testing.T) {
	payload := map[string]any{
		"assetContentManifestSHA256": strings.Repeat("a", 64),
		"catalogCanonicalSHA256":     strings.Repeat("b", 64),
		"catalogRevision":            "2026-08-22.1",
		"deviceContext":              map[string]any{"connectionEpoch": int64(7)},
		"fileRoles":                  []any{},
		"operation":                  "queryMounted",
		"preparationAttemptID":       "00000000-0000-0000-0000-000000000001",
		"preparationGroupID":         classicPreparationGroup,
	}
	operation, failure := validateClassicPayload(OneShotConfig{ConnectionEpoch: 7}, payload)
	if failure != nil || operation != "queryMounted" {
		t.Fatalf("operation=%q failure=%#v", operation, failure)
	}
	payload["deviceContext"] = map[string]any{"connectionEpoch": int64(8)}
	if _, failure := validateClassicPayload(OneShotConfig{ConnectionEpoch: 7}, payload); failure == nil {
		t.Fatal("wrong connection epoch accepted")
	}
	payload["deviceContext"] = map[string]any{"connectionEpoch": int64(7)}
	payload["operation"] = "extractImage"
	if _, failure := validateClassicPayload(OneShotConfig{ConnectionEpoch: 7}, payload); failure == nil {
		t.Fatal("unsupported operation accepted")
	}
}

func TestClassicOperationDeadlinesMatchRuntimeContract(t *testing.T) {
	now := time.Date(2026, time.August, 17, 12, 0, 0, 0, time.UTC)
	if classicMountResponseReserve <= 0 || classicMountDeadline+classicMountResponseReserve != 5*time.Minute {
		t.Fatalf("classic mount deadline/reserve = %s/%s", classicMountDeadline, classicMountResponseReserve)
	}
	for _, test := range []struct {
		operation string
		duration  time.Duration
	}{
		{operation: "queryMounted", duration: 10 * time.Second},
		{operation: "probeServices", duration: 30 * time.Second},
		{operation: "mount", duration: 5*time.Minute - classicMountResponseReserve},
	} {
		t.Run(test.operation, func(t *testing.T) {
			if got, want := classicOperationDeadline(test.operation, now), now.Add(test.duration); !got.Equal(want) {
				t.Fatalf("deadline = %s, want %s", got, want)
			}
		})
	}
}

func TestClassicMountedImageRejectsMalformedSignatureInsteadOfTreatingItAsAbsent(t *testing.T) {
	for _, test := range []struct {
		name     string
		response map[string]any
		present  bool
		wantErr  bool
	}{
		{name: "explicitly absent", response: map[string]any{"ImagePresent": false}},
		{name: "missing signature", response: map[string]any{}},
		{name: "empty signature list", response: map[string]any{"ImageSignature": []any{}}},
		{name: "signature", response: map[string]any{"ImageSignature": []byte("signature")}, present: true},
		{name: "first signature list item", response: map[string]any{"ImageSignature": []any{[]byte("signature"), []byte("ignored")}}, present: true},
		{name: "invalid signature type", response: map[string]any{"ImageSignature": "signature"}, wantErr: true},
		{name: "invalid list signature type", response: map[string]any{"ImageSignature": []any{"signature"}}, wantErr: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			present, _, err := classicMountedImage(test.response)
			if (err != nil) != test.wantErr {
				t.Fatalf("error = %v, want error=%v", err, test.wantErr)
			}
			if present != test.present {
				t.Fatalf("present = %v, want %v", present, test.present)
			}
		})
	}
}

func TestClassicMounterFailuresMatchLegacyOperationProjection(t *testing.T) {
	if got := classicMounterFailure("mount"); got != "developerImageMountFailed" {
		t.Fatalf("mount mounter error = %q", got)
	}
	for _, operation := range []string{"queryMounted", "probeServices"} {
		if got := classicMounterFailure(operation); got != "developerSupportUnavailable" {
			t.Fatalf("%s mounter error = %q", operation, got)
		}
	}
}

func TestClassicUploadImagePreflightsSourceAndPreservesChunkBoundaries(t *testing.T) {
	image := append(make([]byte, classicUploadChunk), byte('x'))
	path := filepath.Join(t.TempDir(), "DeveloperDiskImage.dmg")
	writeSecureTestFile(t, path, image)
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()

	client, server := net.Pipe()
	defer client.Close()
	serverResult := make(chan error, 1)
	deadline := time.Now().Add(time.Second)
	go func() {
		defer server.Close()
		service := newPlistService(server, deadline)
		request, err := service.receive(classicResponseMaximum)
		if err != nil {
			serverResult <- err
			return
		}
		if !reflect.DeepEqual(request, map[string]any{
			"Command":        "ReceiveBytes",
			"ImageSignature": []byte("signature"),
			"ImageSize":      int64(len(image)),
			"ImageType":      "Developer",
		}) {
			serverResult <- errors.New("ReceiveBytes request")
			return
		}
		if err := service.send(map[string]any{"Status": "ReceiveBytesAck"}); err != nil {
			serverResult <- err
			return
		}
		payload := make([]byte, len(image))
		if _, err := io.ReadFull(server, payload); err != nil {
			serverResult <- err
			return
		}
		if !reflect.DeepEqual(payload, image) {
			serverResult <- errors.New("image payload")
			return
		}
		serverResult <- service.send(map[string]any{"Status": "Complete"})
	}()
	service := newPlistService(client, deadline)
	if err := classicUploadImage(service, file, int64(len(image)), []byte("signature"), deadline); err != nil {
		t.Fatal(err)
	}
	if err := <-serverResult; err != nil {
		t.Fatal(err)
	}

	if _, err := file.Seek(0, io.SeekStart); err != nil {
		t.Fatal(err)
	}
	if err := os.Truncate(path, int64(len(image)-1)); err != nil {
		t.Fatal(err)
	}
	if err := classicUploadImage(service, file, int64(len(image)), []byte("signature"), deadline); err == nil {
		t.Fatal("truncated image was submitted")
	}
	if err := os.Truncate(path, int64(len(image)+1)); err != nil {
		t.Fatal(err)
	}
	if err := classicUploadImage(service, file, int64(len(image)), []byte("signature"), deadline); err == nil {
		t.Fatal("trailing image bytes were submitted")
	}
}

func TestValidateSecureFileRejectsWrongOwnerPermissionsAndHardlinks(t *testing.T) {
	path := filepath.Join(t.TempDir(), "asset")
	writeSecureTestFile(t, path, []byte("asset"))
	file, err := os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	owner := uint32(os.Geteuid())
	if err := validateSecureFileOwnedBy(file, int64(len("asset")), false, owner); err != nil {
		t.Fatalf("valid file rejected: %v", err)
	}
	if err := validateSecureFileOwnedBy(file, int64(len("asset")), false, owner+1); err == nil {
		t.Fatal("wrong owner accepted")
	}
	_ = file.Close()

	if err := os.Chmod(path, 0o644); err != nil {
		t.Fatal(err)
	}
	file, err = os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	if err := validateSecureFile(file, int64(len("asset")), false); err == nil {
		t.Fatal("world-readable file accepted")
	}
	_ = file.Close()

	if err := os.Chmod(path, 0o600); err != nil {
		t.Fatal(err)
	}
	hardlink := filepath.Join(t.TempDir(), "asset-link")
	if err := os.Link(path, hardlink); err != nil {
		t.Fatal(err)
	}
	file, err = os.Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	if err := validateSecureFile(file, int64(len("asset")), false); err == nil {
		t.Fatal("hardlinked file accepted")
	}
}

type classicRouteTestStore struct {
	assetRoot              string
	catalogCanonicalSHA256 string
	contentManifestSHA256  string
	image                  []byte
	revision               string
	signature              []byte
}

func createClassicRouteTestStore(t *testing.T) classicRouteTestStore {
	t.Helper()
	home, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	root := filepath.Join(home, "Library", "Application Support", "PulsePhone", "DeveloperImages")
	for _, directory := range []string{root, filepath.Join(root, "Catalog"), filepath.Join(root, "locks"), filepath.Join(root, "DDI")} {
		if err := os.MkdirAll(directory, 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.Chmod(directory, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	image := []byte("classic image")
	signature := []byte("classic signature")
	imageDigest := sha256.Sum256(image)
	signatureDigest := sha256.Sum256(signature)
	manifest := map[string]any{"files": []any{
		map[string]any{"fileRole": classicImageRole, "sha256": hex.EncodeToString(imageDigest[:]), "size": int64(len(image))},
		map[string]any{"fileRole": classicSignatureRole, "sha256": hex.EncodeToString(signatureDigest[:]), "size": int64(len(signature))},
	}, "imageKind": "classic"}
	manifestBytes, err := protocol.EncodeValue(manifest, true)
	if err != nil {
		t.Fatal(err)
	}
	contentBytes, err := protocol.EncodeValue([]any{
		map[string]any{"path": "DeveloperDiskImage.dmg", "sha256": hex.EncodeToString(imageDigest[:]), "size": int64(len(image))},
		map[string]any{"path": "DeveloperDiskImage.dmg.signature", "sha256": hex.EncodeToString(signatureDigest[:]), "size": int64(len(signature))},
	}, false)
	if err != nil {
		t.Fatal(err)
	}
	contentDigest := sha256.Sum256(contentBytes)
	contentManifestSHA256 := hex.EncodeToString(contentDigest[:])
	const revision = "2026-08-22.1"
	catalog := map[string]any{
		"baseAssets":                  []any{},
		"catalogEntry":                []any{},
		"catalogRevision":             revision,
		"defaultCandidateBaseAssetID": "base.unused",
		"developerDiskImages": []any{map[string]any{
			"archiveSHA256":         strings.Repeat("a", 64),
			"archiveSize":           int64(1),
			"contentManifestSHA256": contentManifestSHA256,
			"ddiVersion":            "16.3",
			"sourceURL":             "https://example.invalid/classic.tar",
		}},
		"schemaVersion": int64(1),
	}
	catalogBytes, err := protocol.EncodeValue(catalog, true)
	if err != nil {
		t.Fatal(err)
	}
	catalogDigest := sha256.Sum256(catalogBytes)
	catalogCanonicalSHA256 := hex.EncodeToString(catalogDigest[:])
	writeSecureTestFile(t, filepath.Join(root, "Catalog", "developer-image-catalog.v1.json"), catalogBytes)
	writeSecureTestFile(t, filepath.Join(root, "locks", contentManifestSHA256+".lock"), nil)
	assetRoot := filepath.Join(root, "DDI", contentManifestSHA256)
	if err := os.MkdirAll(filepath.Join(assetRoot, "roles"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(assetRoot, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(filepath.Join(assetRoot, "roles"), 0o700); err != nil {
		t.Fatal(err)
	}
	writeSecureTestFile(t, filepath.Join(assetRoot, "manifest.v1.json"), manifestBytes)
	writeSecureTestFile(t, filepath.Join(assetRoot, "roles", classicImageRole), image)
	writeSecureTestFile(t, filepath.Join(assetRoot, "roles", classicSignatureRole), signature)
	return classicRouteTestStore{
		assetRoot:              assetRoot,
		catalogCanonicalSHA256: catalogCanonicalSHA256,
		contentManifestSHA256:  contentManifestSHA256,
		image:                  image,
		revision:               revision,
		signature:              signature,
	}
}

func classicRouteTestPayload(store classicRouteTestStore, operation string, roles []any) map[string]any {
	return map[string]any{
		"assetContentManifestSHA256": store.contentManifestSHA256,
		"catalogCanonicalSHA256":     store.catalogCanonicalSHA256,
		"catalogRevision":            store.revision,
		"deviceContext":              map[string]any{"connectionEpoch": int64(7)},
		"fileRoles":                  roles,
		"operation":                  operation,
		"preparationAttemptID":       "00000000-0000-0000-0000-000000000001",
		"preparationGroupID":         classicPreparationGroup,
	}
}

type classicRouteTestLockdown struct {
	events        *[]string
	mounter       net.Conn
	mounterErr    error
	probeErr      error
	probeFailures int
}

func (l *classicRouteTestLockdown) StartService(name string) (net.Conn, error) {
	if name == MobileImageMounterService {
		if l.mounterErr != nil {
			return nil, l.mounterErr
		}
		*l.events = append(*l.events, "mounter.open")
		return l.mounter, nil
	}
	*l.events = append(*l.events, "probe:"+name)
	if l.probeErr != nil {
		return nil, l.probeErr
	}
	if l.probeFailures > 0 {
		l.probeFailures--
		return nil, &Failure{Code: "developerServicesUnavailable"}
	}
	client, peer := net.Pipe()
	_ = peer.Close()
	return client, nil
}

func TestClassicProbeServicesRetriesReadinessOnly(t *testing.T) {
	events := []string{}
	lockdown := &classicRouteTestLockdown{
		events:        &events,
		probeFailures: 1,
	}
	if err := classicProbeServices(lockdown, classicRequiredServices, time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	want := []string{
		"probe:com.apple.instruments.remoteserver.DVTSecureSocketProxy",
		"probe:com.apple.instruments.remoteserver.DVTSecureSocketProxy",
		"probe:com.apple.mobile.screenshotr",
	}
	if !reflect.DeepEqual(events, want) {
		t.Fatalf("events = %#v, want %#v", events, want)
	}
	lockdown = &classicRouteTestLockdown{
		events:   &events,
		probeErr: errors.New("not retryable"),
	}
	if err := classicProbeServices(lockdown, classicRequiredServices, time.Now().Add(time.Second)); err == nil {
		t.Fatal("non-readiness failure accepted")
	}
}

func (l *classicRouteTestLockdown) Close() {
	*l.events = append(*l.events, "lockdown.close")
}

type classicRouteRecordingConn struct {
	net.Conn
	events *[]string
	name   string
	closed bool
}

func (c *classicRouteRecordingConn) Close() error {
	if !c.closed {
		c.closed = true
		*c.events = append(*c.events, c.name+".close")
	}
	return c.Conn.Close()
}

func readClassicRouteTestPlist(conn net.Conn) (map[string]any, error) {
	header := make([]byte, 4)
	if _, err := io.ReadFull(conn, header); err != nil {
		return nil, err
	}
	length := binary.BigEndian.Uint32(header)
	if length == 0 || length > classicResponseMaximum {
		return nil, errors.New("invalid plist frame")
	}
	body := make([]byte, int(length))
	if _, err := io.ReadFull(conn, body); err != nil {
		return nil, err
	}
	return decodePlist(body)
}

func writeClassicRouteTestPlist(conn net.Conn, value map[string]any) error {
	body, err := encodePlist(value)
	if err != nil {
		return err
	}
	header := make([]byte, 4)
	binary.BigEndian.PutUint32(header, uint32(len(body)))
	if _, err := conn.Write(append(header, body...)); err != nil {
		return err
	}
	return nil
}

func serveClassicRouteMount(conn net.Conn, image, signature []byte, events *[]string) error {
	defer conn.Close()
	request, err := readClassicRouteTestPlist(conn)
	if err != nil || request["Command"] != "LookupImage" {
		return errors.New("initial LookupImage")
	}
	*events = append(*events, "mounter.query.absent")
	if err := writeClassicRouteTestPlist(conn, map[string]any{"ImagePresent": false}); err != nil {
		return err
	}
	request, err = readClassicRouteTestPlist(conn)
	if err != nil || request["Command"] != "ReceiveBytes" || request["ImageSize"] != int64(len(image)) || !equalBytes(request["ImageSignature"].([]byte), signature) {
		return errors.New("ReceiveBytes")
	}
	*events = append(*events, "mounter.upload")
	if err := writeClassicRouteTestPlist(conn, map[string]any{"Status": "ReceiveBytesAck"}); err != nil {
		return err
	}
	received := make([]byte, len(image))
	if _, err := io.ReadFull(conn, received); err != nil || !equalBytes(received, image) {
		return errors.New("image bytes")
	}
	if err := writeClassicRouteTestPlist(conn, map[string]any{"Status": "Complete"}); err != nil {
		return err
	}
	request, err = readClassicRouteTestPlist(conn)
	if err != nil || request["Command"] != "MountImage" || !equalBytes(request["ImageSignature"].([]byte), signature) {
		return errors.New("MountImage")
	}
	*events = append(*events, "mounter.mount")
	if err := writeClassicRouteTestPlist(conn, map[string]any{"Status": "Complete"}); err != nil {
		return err
	}
	request, err = readClassicRouteTestPlist(conn)
	if err != nil || request["Command"] != "LookupImage" {
		return errors.New("final LookupImage")
	}
	*events = append(*events, "mounter.query.present")
	return writeClassicRouteTestPlist(conn, map[string]any{"ImageSignature": signature})
}

func serveClassicRouteMountUntilClientCloses(conn net.Conn, image, signature []byte, events *[]string) error {
	defer conn.Close()
	request, err := readClassicRouteTestPlist(conn)
	if err != nil || request["Command"] != "LookupImage" {
		return errors.New("initial LookupImage")
	}
	*events = append(*events, "mounter.query.absent")
	if err := writeClassicRouteTestPlist(conn, map[string]any{"ImagePresent": false}); err != nil {
		return err
	}
	request, err = readClassicRouteTestPlist(conn)
	if err != nil || request["Command"] != "ReceiveBytes" || request["ImageSize"] != int64(len(image)) || !equalBytes(request["ImageSignature"].([]byte), signature) {
		return errors.New("ReceiveBytes")
	}
	*events = append(*events, "mounter.upload")
	if err := writeClassicRouteTestPlist(conn, map[string]any{"Status": "ReceiveBytesAck"}); err != nil {
		return err
	}
	received := make([]byte, len(image))
	if _, err := io.ReadFull(conn, received); err != nil || !equalBytes(received, image) {
		return errors.New("image bytes")
	}
	if err := writeClassicRouteTestPlist(conn, map[string]any{"Status": "Complete"}); err != nil {
		return err
	}
	request, err = readClassicRouteTestPlist(conn)
	if err != nil || request["Command"] != "MountImage" || !equalBytes(request["ImageSignature"].([]byte), signature) {
		return errors.New("MountImage")
	}
	*events = append(*events, "mounter.mount.stalled")
	_, err = conn.Read(make([]byte, 1))
	if err == nil {
		return errors.New("expected client close after mount deadline")
	}
	return nil
}

func serveClassicRouteQuery(conn net.Conn, signature []byte, events *[]string) error {
	defer conn.Close()
	request, err := readClassicRouteTestPlist(conn)
	if err != nil || request["Command"] != "LookupImage" {
		return errors.New("LookupImage")
	}
	*events = append(*events, "mounter.query.present")
	return writeClassicRouteTestPlist(conn, map[string]any{"ImageSignature": signature})
}

func TestClassicRouteMountMatchesLegacyOrderAndCleanup(t *testing.T) {
	store := createClassicRouteTestStore(t)
	events := []string{}
	client, server := net.Pipe()
	serverResult := make(chan error, 1)
	go func() { serverResult <- serveClassicRouteMount(server, store.image, store.signature, &events) }()
	lockdown := &classicRouteTestLockdown{events: &events, mounter: &classicRouteRecordingConn{Conn: client, events: &events, name: "mounter"}}
	result, failure := classicRouteWithLockdown(OneShotConfig{ConnectionEpoch: 7, RawTransportUDID: "raw-device"}, classicRouteTestPayload(store, "mount", []any{classicImageRole, classicSignatureRole}), time.Now().Add(time.Minute), func(udid string, deadline time.Time) (classicLockdown, error) {
		if udid != "raw-device" || deadline.IsZero() {
			t.Fatal("classic opener input")
		}
		events = append(events, "lockdown.open")
		return lockdown, nil
	})
	if err := <-serverResult; err != nil {
		t.Fatal(err)
	}
	if failure != nil {
		t.Fatalf("failure = %#v", failure)
	}
	wantResult := map[string]any{"mounted": true, "provenance": "approved", "requiredServiceCount": int64(2), "servicesReady": true}
	if !reflect.DeepEqual(result, wantResult) {
		t.Fatalf("result = %#v, want %#v", result, wantResult)
	}
	wantEvents := []string{"lockdown.open", "mounter.open", "mounter.query.absent", "mounter.upload", "mounter.mount", "mounter.query.present", "probe:com.apple.instruments.remoteserver.DVTSecureSocketProxy", "probe:com.apple.mobile.screenshotr", "mounter.close", "lockdown.close"}
	if !reflect.DeepEqual(events, wantEvents) {
		t.Fatalf("events = %#v, want %#v", events, wantEvents)
	}
}

func TestClassicRouteMountDeadlineProjectsTypedFailure(t *testing.T) {
	store := createClassicRouteTestStore(t)
	events := []string{}
	client, server := net.Pipe()
	serverResult := make(chan error, 1)
	go func() {
		serverResult <- serveClassicRouteMountUntilClientCloses(server, store.image, store.signature, &events)
	}()
	lockdown := &classicRouteTestLockdown{
		events:  &events,
		mounter: &classicRouteRecordingConn{Conn: client, events: &events, name: "mounter"},
	}
	_, failure := classicRouteWithLockdown(
		OneShotConfig{ConnectionEpoch: 7, RawTransportUDID: "raw-device"},
		classicRouteTestPayload(store, "mount", []any{classicImageRole, classicSignatureRole}),
		time.Now().Add(100*time.Millisecond),
		func(string, time.Time) (classicLockdown, error) { return lockdown, nil },
	)
	if err := <-serverResult; err != nil {
		t.Fatal(err)
	}
	if failure == nil || failure.Code != "developerImageMountFailed" || failure.CommitState != "notCommitted" || failure.Stage != "mounting" {
		t.Fatalf("failure = %#v", failure)
	}
}

func TestClassicRouteMountedUnknownNeedsNoAsset(t *testing.T) {
	store := createClassicRouteTestStore(t)
	if err := os.RemoveAll(store.assetRoot); err != nil {
		t.Fatal(err)
	}
	events := []string{}
	client, server := net.Pipe()
	serverResult := make(chan error, 1)
	go func() { serverResult <- serveClassicRouteQuery(server, []byte("unknown"), &events) }()
	lockdown := &classicRouteTestLockdown{events: &events, mounter: &classicRouteRecordingConn{Conn: client, events: &events, name: "mounter"}}
	result, failure := classicRouteWithLockdown(OneShotConfig{ConnectionEpoch: 7, RawTransportUDID: "raw-device"}, classicRouteTestPayload(store, "queryMounted", []any{}), time.Now().Add(time.Minute), func(string, time.Time) (classicLockdown, error) {
		events = append(events, "lockdown.open")
		return lockdown, nil
	})
	if err := <-serverResult; err != nil {
		t.Fatal(err)
	}
	if failure != nil {
		t.Fatalf("failure = %#v", failure)
	}
	if !reflect.DeepEqual(result, map[string]any{"mounted": true, "provenance": "mountedUnknownUnverified"}) {
		t.Fatalf("result = %#v", result)
	}
	if !reflect.DeepEqual(events, []string{"lockdown.open", "mounter.open", "mounter.query.present", "mounter.close", "lockdown.close"}) {
		t.Fatalf("events = %#v", events)
	}
}

func TestClassicRouteProjectsMounterAndServiceProbeFailures(t *testing.T) {
	store := createClassicRouteTestStore(t)
	for _, test := range []struct {
		name      string
		operation string
		roles     []any
		mounter   error
		probe     error
		code      string
		query     bool
	}{
		{name: "query mounter", operation: "queryMounted", roles: []any{}, mounter: errors.New("mounter"), code: "developerSupportUnavailable"},
		{name: "mount mounter", operation: "mount", roles: []any{classicImageRole, classicSignatureRole}, mounter: errors.New("mounter"), code: "developerImageMountFailed"},
		{name: "service probe", operation: "probeServices", roles: []any{}, probe: errors.New("probe"), code: "developerServicesUnavailable", query: true},
	} {
		t.Run(test.name, func(t *testing.T) {
			events := []string{}
			lockdown := &classicRouteTestLockdown{events: &events, mounterErr: test.mounter, probeErr: test.probe}
			var serverResult chan error
			if test.query {
				client, server := net.Pipe()
				lockdown.mounter = &classicRouteRecordingConn{Conn: client, events: &events, name: "mounter"}
				serverResult = make(chan error, 1)
				go func() { serverResult <- serveClassicRouteQuery(server, store.signature, &events) }()
			}
			_, failure := classicRouteWithLockdown(OneShotConfig{ConnectionEpoch: 7, RawTransportUDID: "raw-device"}, classicRouteTestPayload(store, test.operation, test.roles), time.Now().Add(time.Minute), func(string, time.Time) (classicLockdown, error) { return lockdown, nil })
			if serverResult != nil {
				if err := <-serverResult; err != nil {
					t.Fatal(err)
				}
			}
			if failure == nil || failure.Code != test.code || failure.CommitState != "notCommitted" {
				t.Fatalf("failure = %#v", failure)
			}
		})
	}
}
