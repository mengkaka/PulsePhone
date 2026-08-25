package coredevice

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"pulsephone/GoHelpers/internal/direct"
	"pulsephone/GoHelpers/internal/protocol"
)

func TestContentManifestCanonicalVectorMatchesSwiftRuntime(t *testing.T) {
	files := []any{
		map[string]any{
			"path":   "BuildManifest.plist",
			"sha256": "0d88148fc3bff2ea9f23785b42a583ce7d299f3998f2c447a7959a756f679724",
			"size":   int64(805005),
		},
		map[string]any{
			"path":   "Image.dmg",
			"sha256": "2663caa3008f256f413931dd30c518c7701fc1a91bc15052705303e85c994a69",
			"size":   int64(15687680),
		},
		map[string]any{
			"path":   "Image.dmg.trustcache",
			"sha256": "a7bffc13ed8d058c3670220ced9c37aa8e8b90a11273ab2b9c0202da5e92ffd6",
			"size":   int64(1895),
		},
	}
	encoded, err := protocol.EncodeValue(files, false)
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(encoded)
	if got, want := hex.EncodeToString(digest[:]), "2fcc544d8d4eaee948a56815604efb72d2425878d6248cb347ae6195f355cac5"; got != want {
		t.Fatalf("content manifest SHA-256 = %s, want %s", got, want)
	}
}

func TestLockdownECIDPreservesUnsignedIntegerBitPattern(t *testing.T) {
	tests := []struct {
		name  string
		value any
		want  uint64
		ok    bool
	}{
		{
			name:  "positive signed plist integer",
			value: int64(1234),
			want:  1234,
			ok:    true,
		},
		{
			name:  "high-bit signed plist integer",
			value: int64(-8305271335003973384),
			want:  uint64(10141472738705578232),
			ok:    true,
		},
		{
			name:  "unsigned integer",
			value: uint64(10141472738705578232),
			want:  uint64(10141472738705578232),
			ok:    true,
		},
		{
			name:  "decimal string",
			value: "10141472738705578232",
			want:  uint64(10141472738705578232),
			ok:    true,
		},
		{name: "zero", value: int64(0)},
		{name: "negative string", value: "-1"},
		{name: "non-integer", value: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, ok := lockdownECID(test.value)
			if ok != test.ok || got != test.want {
				t.Fatalf("lockdownECID(%#v) = (%d, %t), want (%d, %t)", test.value, got, ok, test.want, test.ok)
			}
		})
	}
}

func TestPersonalizedCatalogAndAssetLease(t *testing.T) {
	root := canonicalPersonalizedTestRoot(t)
	roleBytes := map[string][]byte{
		PersonalizedBuildManifest: []byte("build-manifest"),
		PersonalizedImage:         []byte("personalized-image"),
		PersonalizedTrustCache:    []byte("trust-cache"),
	}
	reference, _ := writePersonalizedStoreFixture(t, root, roleBytes)
	if reference.ContentManifestSHA256 == "" || len(reference.Files) != 3 {
		t.Fatalf("unexpected reference: %#v", reference)
	}
	store, err := NewTrustedPersonalizedImageStore(root)
	if err != nil {
		t.Fatal(err)
	}
	lease, err := store.OpenAsset(reference, PersonalizedMountRoles)
	if err != nil {
		t.Fatal(err)
	}
	image, err := lease.ReadRole(PersonalizedImage, 1024)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(image, roleBytes[PersonalizedImage]) {
		t.Fatalf("unexpected image bytes: %q", image)
	}
	sha384, err := lease.SHA384Role(PersonalizedImage)
	if err != nil || len(sha384) != 48 {
		t.Fatalf("unexpected SHA-384: %x, %v", sha384, err)
	}
	if err := lease.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := lease.ReadRole(PersonalizedImage, 1024); err == nil {
		t.Fatal("closed asset lease remained usable")
	}
}

func TestPersonalizedAssetLeaseRejectsSymlink(t *testing.T) {
	root := canonicalPersonalizedTestRoot(t)
	roleBytes := map[string][]byte{
		PersonalizedBuildManifest: []byte("build"),
		PersonalizedImage:         []byte("image"),
		PersonalizedTrustCache:    []byte("trust"),
	}
	reference, manifest := writePersonalizedStoreFixture(t, root, roleBytes)
	external := filepath.Join(root, "external")
	writePersonalizedTestFile(t, external, roleBytes[PersonalizedTrustCache], 0o600)
	rolePath := filepath.Join(root, "BaseImage", reference.ContentManifestSHA256, "roles", PersonalizedTrustCache)
	if err := os.Remove(rolePath); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(external, rolePath); err != nil {
		t.Fatal(err)
	}
	store, err := NewTrustedPersonalizedImageStore(root)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.OpenAsset(reference, PersonalizedMountRoles); err == nil {
		t.Fatal("symlinked personalized role was accepted")
	}
	if _, err := os.Stat(filepath.Join(root, "BaseImage", reference.ContentManifestSHA256, "manifest.v1.json")); err != nil {
		t.Fatal(err)
	}
	if len(manifest) == 0 {
		t.Fatal("fixture manifest was empty")
	}
}

func TestBuildTSSRequestAndTicketDecode(t *testing.T) {
	buildManifest := map[string]any{
		"BuildIdentities": []any{map[string]any{
			"ApBoardID": "0x1",
			"ApChipID":  "0x2",
			"Manifest": map[string]any{
				"LoadableTrustCache": map[string]any{
					"Digest":  []byte("digest"),
					"Info":    map[string]any{"RestoreRequestRules": []any{map[string]any{"Conditions": map[string]any{"ApCurrentProductionMode": true}, "Actions": map[string]any{"Applied": true}}}},
					"Trusted": true,
				},
			},
		}},
	}
	request, err := BuildTSSRequest(buildManifest, PersonalizationInputs{
		Identifiers: map[string]any{"Ap,ProductType": "iPhone", "BoardId": int64(1), "ChipID": int64(2)},
		ECID:        1234,
		Nonce:       []byte("nonce"),
	})
	if err != nil {
		t.Fatal(err)
	}
	if request["ApECID"] != uint64(1234) || !bytes.Equal(request["ApNonce"].([]byte), []byte("nonce")) {
		t.Fatalf("unexpected personalization inputs: %#v", request)
	}
	entry := request["LoadableTrustCache"].(map[string]any)
	if entry["Applied"] != true || entry["Info"] != nil {
		t.Fatalf("restore rules were not applied: %#v", entry)
	}
	body, err := EncodeTSSRequest(request)
	if err != nil || !bytes.Contains(body, []byte("ApImg4Ticket")) {
		t.Fatalf("unexpected TSS body: %v", err)
	}
	ticketPlist, err := direct.EncodePlistDocument(map[string]any{"ApImg4Ticket": []byte("ticket")})
	if err != nil {
		t.Fatal(err)
	}
	ticket, err := DecodeTSSTicket(append([]byte("MESSAGE=SUCCESS\nREQUEST_STRING="), ticketPlist...))
	if err != nil || !bytes.Equal(ticket, []byte("ticket")) {
		t.Fatalf("ticket decode failed: %x, %v", ticket, err)
	}
	encoded := append([]byte("MESSAGE=SUCCESS\nREQUEST_STRING="), []byte(strings.ReplaceAll(string(ticketPlist), "<", "%3C"))...)
	if _, err := DecodeTSSTicket(encoded); err != nil {
		t.Fatalf("escaped ticket decode failed: %v", err)
	}
	transport := &fakeTSSRoundTripper{response: append([]byte("MESSAGE=SUCCESS\nREQUEST_STRING="), ticketPlist...)}
	requestedTicket, err := (&AppleTSSClient{Client: &http.Client{Transport: transport}}).RequestTicket(request)
	if err != nil || !bytes.Equal(requestedTicket, []byte("ticket")) {
		t.Fatalf("fixed TSS request = %x, %v", requestedTicket, err)
	}
	if transport.url != "https://gs.apple.com/TSS/controller?action=2" || bytes.Contains(transport.body, []byte("https://")) || bytes.Contains(transport.body, []byte("gs.apple.com")) {
		t.Fatalf("unexpected fixed TSS request: url=%q body=%q", transport.url, transport.body)
	}
}

type fakeTSSRoundTripper struct {
	body     []byte
	response []byte
	url      string
}

func (transport *fakeTSSRoundTripper) RoundTrip(request *http.Request) (*http.Response, error) {
	data, err := io.ReadAll(request.Body)
	if err != nil {
		return nil, err
	}
	transport.body = data
	transport.url = request.URL.String()
	return &http.Response{
		StatusCode: http.StatusOK,
		Body:       io.NopCloser(bytes.NewReader(transport.response)),
		Header:     make(http.Header),
	}, nil
}

func TestCoreDevicePersonalizedMounterReopensServiceAfterManifestMiss(t *testing.T) {
	events := []string{}
	original := &fakeRawPersonalizedMounterService{events: &events, name: "original", response: map[string]any{"Status": "Complete"}}
	replacement := &fakeRawPersonalizedMounterService{events: &events, name: "replacement"}
	mounter := &CoreDevicePersonalizedMounter{
		service: original,
		openService: func(time.Time) (personalizedMounterService, error) {
			events = append(events, "rsd.start-mounter")
			return replacement, nil
		},
	}

	manifest, err := mounter.QueryReusableManifest(bytes.Repeat([]byte{'x'}, 48))
	if err != nil || manifest != nil {
		t.Fatalf("manifest miss = %x, %v", manifest, err)
	}
	if mounter.service != replacement {
		t.Fatal("mounter did not retain the replacement service")
	}
	if want := []string{"original.query", "original.close", "rsd.start-mounter"}; !equalStringSlice(events, want) {
		t.Fatalf("reopen events = %#v, want %#v", events, want)
	}
	if err := mounter.Close(); err != nil {
		t.Fatal(err)
	}
	if want := []string{"original.query", "original.close", "rsd.start-mounter", "replacement.close"}; !equalStringSlice(events, want) {
		t.Fatalf("close events = %#v, want %#v", events, want)
	}
}

func TestPersonalizedPayloadRejectsSecretMaterialWrongEpochAndRoles(t *testing.T) {
	secret := personalizedTestPayload("queryMounted")
	secret["deviceContext"] = map[string]any{"connectionEpoch": int64(21), "nonce": "secret"}
	if _, err := validatePersonalizedPayload(21, secret); err == nil {
		t.Fatal("payload accepted secret material")
	}

	wrongEpoch := personalizedTestPayload("queryMounted")
	wrongEpoch["deviceContext"] = map[string]any{"connectionEpoch": int64(22)}
	if _, err := validatePersonalizedPayload(21, wrongEpoch); err == nil {
		t.Fatal("payload accepted wrong connection epoch")
	}

	wrongRoles := personalizedTestPayload("requestTSS")
	wrongRoles["fileRoles"] = []any{PersonalizedBuildManifest, "path"}
	if _, err := validatePersonalizedPayload(21, wrongRoles); err == nil {
		t.Fatal("payload accepted invalid roles")
	}
}

func TestCatalogIndependentMountedQueryDoesNotReadHostAssets(t *testing.T) {
	mounter := &fakePersonalizedMounter{mounted: true}
	session := NewPersonalizedDeveloperSupportSession(
		nil,
		func(string, time.Time) (PersonalizedMounter, error) { return mounter, nil },
		&fakePersonalizedTSS{},
	)
	defer session.Close()

	result, err := session.QueryMounted("raw-device", time.Now().Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if result["mounted"] != true || result["provenance"] != "mountedUnknownUnverified" {
		t.Fatalf("mounted query result = %#v", result)
	}
	if mounter.queriedManifest || mounter.uploaded || mounter.probed {
		t.Fatalf("mounted query touched asset-dependent device operations: %#v", mounter)
	}
}

type fakeRawPersonalizedMounterService struct {
	events   *[]string
	name     string
	response map[string]any
}

func (service *fakeRawPersonalizedMounterService) SendReceivePlist(map[string]any, int) (map[string]any, error) {
	*service.events = append(*service.events, service.name+".query")
	return service.response, nil
}

func (*fakeRawPersonalizedMounterService) ReceivePlist(int) (map[string]any, error) {
	return nil, errors.New("unexpected receive")
}

func (*fakeRawPersonalizedMounterService) WriteRaw([]byte) error {
	return errors.New("unexpected write")
}

func (service *fakeRawPersonalizedMounterService) Close() error {
	*service.events = append(*service.events, service.name+".close")
	return nil
}

func TestPersonalizedSessionRequestTSSMountAndAlreadyMounted(t *testing.T) {
	buildManifest, err := direct.EncodePlistDocument(map[string]any{
		"BuildIdentities": []any{map[string]any{
			"ApBoardID": "0x1", "ApChipID": "0x2",
			"Manifest": map[string]any{"LoadableTrustCache": map[string]any{"Digest": []byte("digest"), "Info": map[string]any{}, "Trusted": true}},
		}},
	})
	if err != nil {
		t.Fatal(err)
	}
	root := canonicalPersonalizedTestRoot(t)
	reference, _ := writePersonalizedStoreFixture(t, root, map[string][]byte{
		PersonalizedBuildManifest: buildManifest,
		PersonalizedImage:         []byte("image"),
		PersonalizedTrustCache:    []byte("trust"),
	})
	store, err := NewTrustedPersonalizedImageStore(root)
	if err != nil {
		t.Fatal(err)
	}
	// A device may reset the old mounter connection after MountImage commits.
	// That cleanup error must not mask the committed-mount checkpoint.
	mounter := &fakePersonalizedMounter{
		reusable: nil,
		closeErr: errors.New("post-mount mounter connection reset"),
	}
	tss := &fakePersonalizedTSS{ticket: []byte("tss-ticket")}
	openCalls := 0
	session := NewPersonalizedDeveloperSupportSession(store, func(string, time.Time) (PersonalizedMounter, error) {
		openCalls++
		return mounter, nil
	}, tss)
	requestPayload := personalizedTestPayload("requestTSS", reference)
	result, err := session.Execute("raw-device", 21, requestPayload, time.Now().Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if result["manifestSource"] != "appleTSS" || result["tssRequested"] != true || tss.calls != 1 {
		t.Fatalf("unexpected TSS result: %#v calls=%d", result, tss.calls)
	}
	if _, exists := result["nonce"]; exists {
		t.Fatal("nonce leaked into result")
	}
	if _, exists := result["ecid"]; exists {
		t.Fatal("ECID leaked into result")
	}
	wrongAttempt := personalizedTestPayload("mount", reference)
	wrongAttempt["preparationAttemptID"] = "attempt.other"
	if _, err := session.Execute("raw-device", 21, wrongAttempt, time.Now().Add(time.Minute)); !isPersonalizationServiceUnavailable(err) {
		t.Fatalf("wrong attempt mount failure classification = %v", err)
	}
	mountResult, err := session.Execute("raw-device", 21, personalizedTestPayload("mount", reference), time.Now().Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if mountResult["mounted"] != true || mountResult["mountCommitted"] != true || mountResult["provenance"] != "approved" || !mounter.uploaded || mounter.probed {
		t.Fatalf("unexpected committed mount result: %#v mounter=%#v", mountResult, mounter)
	}
	if _, exists := mountResult["servicesReady"]; exists {
		t.Fatalf("mounter-only mount result claimed service readiness: %#v", mountResult)
	}
	if openCalls != 3 || mounter.closed != 3 {
		t.Fatalf("committed mount lifecycle opened a fresh mounter: opens=%d mounter=%#v", openCalls, mounter)
	}
	if len(session.manifests) != 0 || reference.ContentManifestSHA256 == "" {
		t.Fatal("manifest cache was not retired")
	}

	alreadyMounted := &fakePersonalizedMounter{mounted: true}
	alreadySession := NewPersonalizedDeveloperSupportSession(store, func(string, time.Time) (PersonalizedMounter, error) {
		return alreadyMounted, nil
	}, &fakePersonalizedTSS{ticket: []byte("unused")})
	alreadyResult, err := alreadySession.Execute("raw-device", 21, requestPayload, time.Now().Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	if alreadyResult["mounted"] != true || alreadyResult["provenance"] != "mountedUnknownUnverified" || alreadyResult["manifestSource"] != "noneAlreadyMounted" || alreadyResult["tssRequested"] != false || alreadyMounted.queriedManifest {
		t.Fatalf("already-mounted path touched manifest: %#v fake=%#v", alreadyResult, alreadyMounted)
	}

	tssFailureMounter := &fakePersonalizedMounter{}
	tssFailure := NewPersonalizedDeveloperSupportSession(store, func(string, time.Time) (PersonalizedMounter, error) {
		return tssFailureMounter, nil
	}, &fakePersonalizedTSS{err: errors.New("offline")})
	if _, err := tssFailure.Execute("raw-device", 21, requestPayload, time.Now().Add(time.Minute)); !isPersonalizationServiceUnavailable(err) {
		t.Fatalf("TSS failure classification = %v", err)
	}
	if tssFailureMounter.uploaded || tssFailureMounter.mounted {
		t.Fatalf("TSS failure mounted image: %#v", tssFailureMounter)
	}

	missingManifest := NewPersonalizedDeveloperSupportSession(store, func(string, time.Time) (PersonalizedMounter, error) {
		return &fakePersonalizedMounter{}, nil
	}, &fakePersonalizedTSS{})
	if _, err := missingManifest.Execute("raw-device", 21, personalizedTestPayload("mount", reference), time.Now().Add(time.Minute)); !isPersonalizationServiceUnavailable(err) {
		t.Fatalf("reusable manifest failure classification = %v", err)
	}
	session.Close()
	if len(session.manifests) != 0 || len(session.approved) != 0 {
		t.Fatal("session close retained personalization state")
	}
}

type fakePersonalizedMounter struct {
	mounted         bool
	reusable        []byte
	queriedManifest bool
	uploaded        bool
	probed          bool
	closed          int
	closeErr        error
}

func (mounter *fakePersonalizedMounter) QueryMounted() (PersonalizedMountedImage, error) {
	return PersonalizedMountedImage{Present: mounter.mounted}, nil
}

func (mounter *fakePersonalizedMounter) QueryReusableManifest([]byte) ([]byte, error) {
	mounter.queriedManifest = true
	return append([]byte(nil), mounter.reusable...), nil
}

func (mounter *fakePersonalizedMounter) PersonalizationInputs() (PersonalizationInputs, error) {
	return PersonalizationInputs{Identifiers: map[string]any{"BoardId": int64(1), "ChipID": int64(2)}, ECID: 1234, Nonce: []byte("nonce")}, nil
}

func (mounter *fakePersonalizedMounter) Upload(*os.File, int64, []byte, time.Time) error {
	mounter.uploaded = true
	return nil
}

func (mounter *fakePersonalizedMounter) Mount([]byte, []byte) error {
	mounter.mounted = true
	return nil
}

func (mounter *fakePersonalizedMounter) ProbeServices([]string, time.Time) error {
	mounter.probed = true
	return nil
}

func (mounter *fakePersonalizedMounter) Close() error {
	mounter.closed++
	return mounter.closeErr
}

type fakePersonalizedTSS struct {
	ticket []byte
	calls  int
	err    error
}

func (tss *fakePersonalizedTSS) RequestTicket(map[string]any) ([]byte, error) {
	tss.calls++
	if tss.err != nil {
		return nil, tss.err
	}
	return append([]byte(nil), tss.ticket...), nil
}

func personalizedTestPayload(operation string, references ...PersonalizedCatalogReference) map[string]any {
	roles := []any{}
	if operation == "requestTSS" {
		roles = []any{PersonalizedBuildManifest, PersonalizedImage}
	}
	if operation == "mount" {
		roles = []any{PersonalizedBuildManifest, PersonalizedImage, PersonalizedTrustCache}
	}
	catalogCanonicalSHA256 := strings.Repeat("a", 64)
	contentManifestSHA256 := strings.Repeat("b", 64)
	if len(references) == 1 {
		catalogCanonicalSHA256 = references[0].CatalogCanonicalSHA256
		contentManifestSHA256 = references[0].ContentManifestSHA256
	}
	return map[string]any{
		"assetContentManifestSHA256": contentManifestSHA256,
		"catalogCanonicalSHA256":     catalogCanonicalSHA256,
		"catalogRevision":            "2026-08-22.1",
		"deviceContext":              map[string]any{"connectionEpoch": int64(21)}, "fileRoles": roles,
		"operation": operation, "preparationAttemptID": "attempt.shared", "preparationGroupID": PreparationGroupID,
	}
}

func writePersonalizedStoreFixture(t *testing.T, root string, roleBytes map[string][]byte) (PersonalizedCatalogReference, []byte) {
	t.Helper()
	for _, name := range []string{"Catalog", "BaseImage", "locks"} {
		mkdirPersonalizedTest(t, filepath.Join(root, name), 0o700)
	}
	rolePaths := map[string]string{
		PersonalizedBuildManifest: "BuildManifest.plist",
		PersonalizedImage:         "Image.dmg",
		PersonalizedTrustCache:    "Image.dmg.trustcache",
	}
	manifestFiles := make([]any, 0, len(PersonalizedMountRoles))
	contentFiles := make([]any, 0, len(PersonalizedMountRoles))
	for _, role := range PersonalizedMountRoles {
		bytes, ok := roleBytes[role]
		if !ok {
			t.Fatalf("missing fixture role %s", role)
		}
		digest := sha256.Sum256(bytes)
		record := map[string]any{
			"fileRole": role,
			"sha256":   hex.EncodeToString(digest[:]),
			"size":     int64(len(bytes)),
		}
		manifestFiles = append(manifestFiles, record)
		contentFiles = append(contentFiles, map[string]any{
			"path": rolePaths[role], "sha256": record["sha256"], "size": record["size"],
		})
	}
	sort.Slice(manifestFiles, func(i, j int) bool {
		return stringValue(manifestFiles[i].(map[string]any)["fileRole"]) < stringValue(manifestFiles[j].(map[string]any)["fileRole"])
	})
	sort.Slice(contentFiles, func(i, j int) bool {
		return stringValue(contentFiles[i].(map[string]any)["path"]) < stringValue(contentFiles[j].(map[string]any)["path"])
	})
	manifest, err := protocol.EncodeValue(map[string]any{"files": manifestFiles, "imageKind": "personalized"}, false)
	if err != nil {
		t.Fatalf("encode asset manifest: %v", err)
	}
	contentBytes, err := protocol.EncodeValue(contentFiles, false)
	if err != nil {
		t.Fatalf("encode content manifest: %v", err)
	}
	contentDigest := sha256.Sum256(contentBytes)
	contentManifestSHA256 := hex.EncodeToString(contentDigest[:])
	const revision = "2026-08-22.1"
	baseAssets := []any{map[string]any{
		"archiveSHA256":         strings.Repeat("a", 64),
		"archiveSize":           int64(1),
		"baseAssetID":           "base.personalized.test",
		"contentManifestSHA256": contentManifestSHA256,
		"sourceURL":             "https://example.invalid/base.tar",
	}}
	catalog, err := protocol.EncodeValue(map[string]any{
		"baseAssets":                  baseAssets,
		"catalogEntry":                []any{},
		"catalogRevision":             revision,
		"defaultCandidateBaseAssetID": "base.personalized.test",
		"developerDiskImages":         []any{},
		"schemaVersion":               int64(1),
	}, true)
	if err != nil {
		t.Fatalf("encode dynamic catalog: %v", err)
	}
	catalogDigest := sha256.Sum256(catalog)
	catalogCanonicalSHA256 := hex.EncodeToString(catalogDigest[:])
	writePersonalizedTestFile(t, filepath.Join(root, "Catalog", "developer-image-catalog.v1.json"), catalog, 0o600)
	writePersonalizedTestFile(t, filepath.Join(root, "locks", contentManifestSHA256+".lock"), nil, 0o600)
	assetRoot := filepath.Join(root, "BaseImage", contentManifestSHA256)
	roleRoot := filepath.Join(assetRoot, "roles")
	mkdirPersonalizedTest(t, assetRoot, 0o700)
	mkdirPersonalizedTest(t, roleRoot, 0o700)
	writePersonalizedTestFile(t, filepath.Join(assetRoot, "manifest.v1.json"), manifest, 0o600)
	for role, value := range roleBytes {
		writePersonalizedTestFile(t, filepath.Join(roleRoot, role), value, 0o600)
	}
	store, err := NewTrustedPersonalizedImageStore(root)
	if err != nil {
		t.Fatal(err)
	}
	reference, err := store.LoadReference(revision, catalogCanonicalSHA256, contentManifestSHA256)
	if err != nil {
		t.Fatal(err)
	}
	return reference, manifest
}

func canonicalPersonalizedTestRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.EvalSymlinks(t.TempDir())
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(root, 0o700); err != nil {
		t.Fatal(err)
	}
	return root
}

func mkdirPersonalizedTest(t *testing.T, path string, mode os.FileMode) {
	t.Helper()
	if err := os.Mkdir(path, mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
}

func writePersonalizedTestFile(t *testing.T, path string, data []byte, mode os.FileMode) {
	t.Helper()
	if err := os.WriteFile(path, data, mode); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(path, mode); err != nil {
		t.Fatal(err)
	}
}
