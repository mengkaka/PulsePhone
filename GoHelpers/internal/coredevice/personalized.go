package coredevice

import (
	"bytes"
	"crypto/sha256"
	"crypto/sha512"
	"encoding/hex"
	"errors"
	"fmt"
	"hash"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"syscall"
	"time"

	"pulsephone/GoHelpers/internal/direct"
	"pulsephone/GoHelpers/internal/protocol"
)

const (
	PersonalizedBuildManifest  = "personalized.buildManifest"
	PersonalizedImage          = "personalized.image"
	PersonalizedTrustCache     = "personalized.trustCache"
	PersonalizedMounterService = "com.apple.mobile.mobile_image_mounter.shim.remote"
	TSSRequestMaximum          = 4 * 1024 * 1024
	TSSResponseMaximum         = 4 * 1024 * 1024
	TSSTicketMaximum           = 1024 * 1024
	PersonalizedCatalogMaximum = 4 * 1024 * 1024
	BuildManifestMaximum       = 16 * 1024 * 1024
	PersonalizedImageMaximum   = 8 * 1024 * 1024 * 1024
	TrustCacheMaximum          = 64 * 1024 * 1024
	MounterResponseMaximum     = 64 * 1024
	PersonalizedTransferChunk  = 1024 * 1024
)

var (
	PersonalizedRequestTSSRoles = []string{PersonalizedBuildManifest, PersonalizedImage}
	PersonalizedMountRoles      = []string{PersonalizedBuildManifest, PersonalizedImage, PersonalizedTrustCache}
)

type PersonalizedError struct {
	Code                              string
	Phase                             string
	PersonalizationServiceUnavailable bool
}

func (err *PersonalizedError) Error() string {
	if err == nil {
		return ""
	}
	return err.Code
}

func personalizedError(code string) error { return &PersonalizedError{Code: code} }

func personalizedErrorAt(code, phase string) error {
	return &PersonalizedError{Code: code, Phase: phase}
}

func personalizationServiceUnavailableError() error {
	return &PersonalizedError{
		Code:                              "personalizationServiceUnavailable",
		PersonalizationServiceUnavailable: true,
	}
}

func isPersonalizationServiceUnavailable(err error) bool {
	var personalized *PersonalizedError
	return errors.As(err, &personalized) && (personalized.PersonalizationServiceUnavailable || personalized.Code == "personalizationServiceUnavailable")
}

type PersonalizedFileRecord struct {
	SHA256 string
	Size   int64
}

type PersonalizedCatalogReference struct {
	CatalogCanonicalSHA256 string
	CatalogRevision        string
	ContentManifestSHA256  string
	Files                  map[string]PersonalizedFileRecord
	ManifestBytes          []byte
	RequiredServices       []string
}

type PersonalizedMountedImage struct{ Present bool }

type CachedPersonalizedManifest struct {
	Bytes  []byte
	Source string
}

type PersonalizationInputs struct {
	Identifiers map[string]any
	ECID        uint64
	Nonce       []byte
}

// TrustedPersonalizedImageStore reads the catalog and asset lease using the
// same owner/mode/hash checks as the Python implementation. Root is injectable
// so all policy can be tested without touching the user's real cache.
type TrustedPersonalizedImageStore struct {
	Root            string
	EffectiveUserID uint32
}

func NewTrustedPersonalizedImageStore(root string) (*TrustedPersonalizedImageStore, error) {
	if root == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			return nil, err
		}
		root = filepath.Join(home, "Library", "Application Support", "PulsePhone", "DeveloperImages")
	}
	if !filepath.IsAbs(root) {
		return nil, personalizedError("store root identity")
	}
	return &TrustedPersonalizedImageStore{Root: root, EffectiveUserID: uint32(os.Geteuid())}, nil
}

// LoadReference verifies the exact catalog snapshot pinned by Runtime before
// resolving the content-addressed BaseImage directory. The helper deliberately
// never receives a remote URL or an entry ID: selection happened in Runtime.
func (store *TrustedPersonalizedImageStore) LoadReference(revision, catalogCanonicalSHA256, contentManifestSHA256 string) (PersonalizedCatalogReference, error) {
	if err := safePersonalizedComponent(revision, 256); err != nil {
		return PersonalizedCatalogReference{}, err
	}
	if !isLowerHex64(catalogCanonicalSHA256) || !isLowerHex64(contentManifestSHA256) {
		return PersonalizedCatalogReference{}, personalizedError("catalog identity")
	}
	root, err := store.openRoot()
	if err != nil {
		return PersonalizedCatalogReference{}, err
	}
	defer root.Close()
	catalogs, err := openPersonalizedDirectory(root, "Catalog", store.EffectiveUserID)
	if err != nil {
		return PersonalizedCatalogReference{}, err
	}
	defer catalogs.Close()
	catalogFile, err := openPersonalizedRegular(catalogs, "developer-image-catalog.v1.json", store.EffectiveUserID, PersonalizedCatalogMaximum, -1)
	if err != nil {
		return PersonalizedCatalogReference{}, err
	}
	data, readErr := readPersonalizedFile(catalogFile, PersonalizedCatalogMaximum)
	_ = catalogFile.Close()
	if readErr != nil {
		return PersonalizedCatalogReference{}, readErr
	}
	digest := sha256.Sum256(data)
	if hex.EncodeToString(digest[:]) != catalogCanonicalSHA256 {
		return PersonalizedCatalogReference{}, personalizedError("catalog hash")
	}
	document, err := protocol.ValidateDocument(data, PersonalizedCatalogMaximum)
	if err != nil {
		return PersonalizedCatalogReference{}, personalizedError("catalog document")
	}
	catalog := document.Root
	if len(catalog) != 6 || !isOne(catalog["schemaVersion"]) || catalog["catalogRevision"] != revision {
		return PersonalizedCatalogReference{}, personalizedError("catalog shape")
	}
	assets, ok := catalog["baseAssets"].([]any)
	if !ok {
		return PersonalizedCatalogReference{}, personalizedError("catalog base assets")
	}
	matched := false
	for _, value := range assets {
		asset, ok := value.(map[string]any)
		if !ok {
			return PersonalizedCatalogReference{}, personalizedError("catalog base asset")
		}
		if stringValue(asset["contentManifestSHA256"]) == contentManifestSHA256 {
			if matched || safePersonalizedComponent(stringValue(asset["baseAssetID"]), 256) != nil || !isLowerHex64(stringValue(asset["archiveSHA256"])) || !positiveCatalogSize(asset["archiveSize"]) || safePersonalizedURL(stringValue(asset["sourceURL"])) != nil {
				return PersonalizedCatalogReference{}, personalizedError("catalog base asset")
			}
			matched = true
		}
	}
	if !matched {
		return PersonalizedCatalogReference{}, personalizedError("catalog base asset")
	}
	baseImages, err := openPersonalizedDirectory(root, "BaseImage", store.EffectiveUserID)
	if err != nil {
		return PersonalizedCatalogReference{}, err
	}
	defer baseImages.Close()
	asset, err := openPersonalizedDirectory(baseImages, contentManifestSHA256, store.EffectiveUserID)
	if err != nil {
		return PersonalizedCatalogReference{}, err
	}
	defer asset.Close()
	manifest, err := openPersonalizedRegular(asset, "manifest.v1.json", store.EffectiveUserID, 16*1024, -1)
	if err != nil {
		return PersonalizedCatalogReference{}, err
	}
	manifestBytes, readErr := readPersonalizedFile(manifest, 16*1024)
	_ = manifest.Close()
	if readErr != nil {
		return PersonalizedCatalogReference{}, readErr
	}
	document, err = protocol.ValidateDocument(manifestBytes, 16*1024)
	if err != nil {
		return PersonalizedCatalogReference{}, personalizedError("asset manifest")
	}
	return personalizedContentManifestReference(revision, catalogCanonicalSHA256, contentManifestSHA256, document.Root, manifestBytes)
}

func (store *TrustedPersonalizedImageStore) OpenAsset(reference PersonalizedCatalogReference, roles []string) (*PersonalizedAssetLease, error) {
	if !equalStringSlice(roles, PersonalizedRequestTSSRoles) && !equalStringSlice(roles, PersonalizedMountRoles) {
		return nil, personalizedError("personalized roles")
	}
	root, err := store.openRoot()
	if err != nil {
		return nil, err
	}
	defer root.Close()
	locks, err := openPersonalizedDirectory(root, "locks", store.EffectiveUserID)
	if err != nil {
		return nil, err
	}
	lock, err := openPersonalizedRegular(locks, reference.ContentManifestSHA256+".lock", store.EffectiveUserID, 0, 0)
	_ = locks.Close()
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_SH); err != nil {
		_ = lock.Close()
		return nil, err
	}
	lease := &PersonalizedAssetLease{lock: lock, roles: map[string]*os.File{}}
	failed := true
	defer func() {
		if failed {
			_ = lease.Close()
		}
	}()
	assets, err := openPersonalizedDirectory(root, "BaseImage", store.EffectiveUserID)
	if err != nil {
		return nil, err
	}
	asset, err := openPersonalizedDirectory(assets, reference.ContentManifestSHA256, store.EffectiveUserID)
	_ = assets.Close()
	if err != nil {
		return nil, err
	}
	manifest, err := openPersonalizedRegular(asset, "manifest.v1.json", store.EffectiveUserID, 16*1024, int64(len(reference.ManifestBytes)))
	if err != nil {
		_ = asset.Close()
		return nil, err
	}
	manifestBytes, err := readPersonalizedFile(manifest, 16*1024)
	_ = manifest.Close()
	if err != nil || !bytes.Equal(manifestBytes, reference.ManifestBytes) {
		_ = asset.Close()
		return nil, personalizedError("asset manifest")
	}
	roleRoot, err := openPersonalizedDirectory(asset, "roles", store.EffectiveUserID)
	_ = asset.Close()
	if err != nil {
		return nil, err
	}
	for _, role := range roles {
		record, ok := reference.Files[role]
		if !ok {
			_ = roleRoot.Close()
			return nil, personalizedError("catalog role")
		}
		maximum, ok := personalizedRoleMaximum(role)
		if !ok {
			_ = roleRoot.Close()
			return nil, personalizedError("catalog role")
		}
		file, err := openPersonalizedRegular(roleRoot, role, store.EffectiveUserID, maximum, record.Size)
		if err != nil {
			_ = roleRoot.Close()
			return nil, err
		}
		digest, err := hashPersonalizedFile(file, sha256.New())
		if err != nil || digest != record.SHA256 {
			_ = file.Close()
			_ = roleRoot.Close()
			return nil, personalizedError("role hash")
		}
		_, _ = file.Seek(0, io.SeekStart)
		lease.roles[role] = file
	}
	_ = roleRoot.Close()
	failed = false
	return lease, nil
}

type PersonalizedAssetLease struct {
	lock   *os.File
	roles  map[string]*os.File
	closed bool
}

func (lease *PersonalizedAssetLease) OpenRole(role string) (*os.File, error) {
	if lease == nil || lease.closed || lease.roles[role] == nil {
		return nil, personalizedError("role not leased")
	}
	fd, err := syscall.Dup(int(lease.roles[role].Fd()))
	if err != nil {
		return nil, err
	}
	return os.NewFile(uintptr(fd), role), nil
}

func (lease *PersonalizedAssetLease) ReadRole(role string, maximum int64) ([]byte, error) {
	file, err := lease.OpenRole(role)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	data, err := readPersonalizedFile(file, maximum)
	if err != nil || len(data) == 0 {
		return nil, personalizedError("role size")
	}
	return data, nil
}

func (lease *PersonalizedAssetLease) SHA384Role(role string) ([]byte, error) {
	if lease == nil || lease.closed || lease.roles[role] == nil {
		return nil, personalizedError("role not leased")
	}
	digest, err := hashPersonalizedFile(lease.roles[role], sha512.New384())
	if err != nil {
		return nil, err
	}
	decoded, err := hexDecode(digest)
	if err != nil {
		return nil, err
	}
	return decoded, nil
}

func (lease *PersonalizedAssetLease) Close() error {
	if lease == nil || lease.closed {
		return nil
	}
	lease.closed = true
	var first error
	for _, file := range lease.roles {
		if err := file.Close(); err != nil && first == nil {
			first = err
		}
	}
	lease.roles = nil
	if lease.lock != nil {
		if err := syscall.Flock(int(lease.lock.Fd()), syscall.LOCK_UN); err != nil && first == nil {
			first = err
		}
		if err := lease.lock.Close(); err != nil && first == nil {
			first = err
		}
	}
	return first
}

func personalizedContentManifestReference(
	revision, catalogCanonicalSHA256, contentManifestSHA256 string,
	manifest map[string]any,
	manifestBytes []byte,
) (PersonalizedCatalogReference, error) {
	if len(manifest) != 2 || manifest["imageKind"] != "personalized" {
		return PersonalizedCatalogReference{}, personalizedError("asset manifest")
	}
	files, ok := manifest["files"].([]any)
	if !ok {
		return PersonalizedCatalogReference{}, personalizedError("files")
	}
	records := make(map[string]PersonalizedFileRecord, len(files))
	manifestFiles := make([]any, 0, len(files))
	for _, value := range files {
		file, ok := value.(map[string]any)
		if !ok {
			return PersonalizedCatalogReference{}, personalizedError("file")
		}
		role := stringValue(file["fileRole"])
		size, ok := positiveInt64(file["size"])
		digest := stringValue(file["sha256"])
		if !ok || !isLowerHex64(digest) || !containsString(PersonalizedMountRoles, role) {
			return PersonalizedCatalogReference{}, personalizedError("personalized file metadata")
		}
		if _, exists := records[role]; exists {
			return PersonalizedCatalogReference{}, personalizedError("personalized file role")
		}
		maximum, _ := personalizedRoleMaximum(role)
		if size > maximum {
			return PersonalizedCatalogReference{}, personalizedError("personalized file metadata")
		}
		records[role] = PersonalizedFileRecord{SHA256: digest, Size: size}
		manifestFiles = append(manifestFiles, map[string]any{"fileRole": role, "sha256": digest, "size": size})
	}
	roles := make([]string, 0, len(records))
	for role := range records {
		roles = append(roles, role)
	}
	sort.Strings(roles)
	expected := append([]string(nil), PersonalizedMountRoles...)
	sort.Strings(expected)
	if !equalStringSlice(roles, expected) {
		return PersonalizedCatalogReference{}, personalizedError("personalized role set")
	}
	sort.Slice(manifestFiles, func(i, j int) bool {
		left := stringValue(manifestFiles[i].(map[string]any)["fileRole"])
		right := stringValue(manifestFiles[j].(map[string]any)["fileRole"])
		return left < right
	})
	canonicalManifest, err := protocol.EncodeValue(map[string]any{"files": manifestFiles, "imageKind": "personalized"}, false)
	if err != nil || !bytes.Equal(canonicalManifest, manifestBytes) {
		return PersonalizedCatalogReference{}, personalizedError("asset manifest")
	}
	contentFiles := make([]any, 0, len(files))
	for _, value := range files {
		file := value.(map[string]any)
		role := stringValue(file["fileRole"])
		path := map[string]string{
			PersonalizedBuildManifest: "BuildManifest.plist",
			PersonalizedImage:         "Image.dmg",
			PersonalizedTrustCache:    "Image.dmg.trustcache",
		}[role]
		contentFiles = append(contentFiles, map[string]any{
			"path": path, "sha256": stringValue(file["sha256"]), "size": file["size"],
		})
	}
	sort.Slice(contentFiles, func(i, j int) bool {
		left := contentFiles[i].(map[string]any)
		right := contentFiles[j].(map[string]any)
		return stringValue(left["path"]) < stringValue(right["path"])
	})
	contentBytes, err := protocol.EncodeValue(contentFiles, false)
	if err != nil {
		return PersonalizedCatalogReference{}, err
	}
	digest := sha256.Sum256(contentBytes)
	if hex.EncodeToString(digest[:]) != contentManifestSHA256 {
		return PersonalizedCatalogReference{}, personalizedError("content manifest")
	}
	return PersonalizedCatalogReference{
		CatalogCanonicalSHA256: catalogCanonicalSHA256,
		CatalogRevision:        revision,
		ContentManifestSHA256:  contentManifestSHA256,
		Files:                  records,
		ManifestBytes:          manifestBytes,
		// Full readiness is verified by Runtime's CoreDevice facet warm-up.
		// The dynamic catalog intentionally contains only immutable asset facts.
		RequiredServices: []string{},
	}, nil
}

func positiveCatalogSize(value any) bool {
	size, ok := manifestUint(value)
	return ok && size > 0
}

func safePersonalizedURL(value string) error {
	if len(value) < len("https://x") || !strings.HasPrefix(value, "https://") || strings.ContainsAny(value, "\\\r\n") {
		return personalizedError("source URL")
	}
	return nil
}

func (store *TrustedPersonalizedImageStore) openRoot() (*os.File, error) {
	if !filepath.IsAbs(store.Root) {
		return nil, personalizedError("store root identity")
	}
	resolved, err := filepath.EvalSymlinks(store.Root)
	if err != nil || resolved != store.Root {
		return nil, personalizedError("store root identity")
	}
	return openPersonalizedPath(store.Root, store.EffectiveUserID, true, 0, -1)
}

func openPersonalizedPath(path string, owner uint32, directory bool, maximum, exact int64) (*os.File, error) {
	flags := syscall.O_RDONLY | syscall.O_NOFOLLOW | syscall.O_CLOEXEC
	if directory {
		flags |= syscall.O_DIRECTORY
	}
	fd, err := syscall.Open(path, flags, 0)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), path)
	if file == nil {
		_ = syscall.Close(fd)
		return nil, errors.New("file open")
	}
	if err := validatePersonalizedMetadata(file, owner, directory, maximum, exact); err != nil {
		_ = file.Close()
		return nil, err
	}
	return file, nil
}

func openPersonalizedDirectory(parent *os.File, name string, owner uint32) (*os.File, error) {
	if err := safePersonalizedComponent(name, 256); err != nil {
		return nil, err
	}
	return openPersonalizedPath(filepath.Join(parent.Name(), name), owner, true, 0, -1)
}

func openPersonalizedRegular(parent *os.File, name string, owner uint32, maximum, exact int64) (*os.File, error) {
	if err := safePersonalizedComponent(name, 320); err != nil {
		return nil, err
	}
	return openPersonalizedPath(filepath.Join(parent.Name(), name), owner, false, maximum, exact)
}

func validatePersonalizedMetadata(file *os.File, owner uint32, directory bool, maximum, exact int64) error {
	info, err := file.Stat()
	if err != nil {
		return err
	}
	statInfo, ok := info.Sys().(*syscall.Stat_t)
	if !ok || statInfo.Uid != owner {
		return personalizedError("unsafe file metadata")
	}
	if directory {
		if !info.IsDir() || info.Mode().Perm() != 0o700 {
			return personalizedError("unsafe directory")
		}
		return nil
	}
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || info.Size() > maximum || (exact >= 0 && info.Size() != exact) {
		return personalizedError("unsafe regular file")
	}
	if statInfo.Nlink != 1 {
		return personalizedError("unsafe regular file")
	}
	return nil
}

func readPersonalizedFile(file *os.File, maximum int64) ([]byte, error) {
	if maximum < 0 {
		return nil, personalizedError("file cap")
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	data, err := io.ReadAll(io.LimitReader(file, maximum+1))
	if err != nil || int64(len(data)) > maximum {
		return nil, personalizedError("file cap")
	}
	_, _ = file.Seek(0, io.SeekStart)
	return data, nil
}

func hashPersonalizedFile(file *os.File, hasher hash.Hash) (string, error) {
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return "", err
	}
	if _, err := io.CopyBuffer(hasher, file, make([]byte, PersonalizedTransferChunk)); err != nil {
		return "", err
	}
	_, _ = file.Seek(0, io.SeekStart)
	return fmt.Sprintf("%x", hasher.Sum(nil)), nil
}

func hexDecode(value string) ([]byte, error) {
	if len(value)%2 != 0 {
		return nil, errors.New("hex length")
	}
	data := make([]byte, len(value)/2)
	for i := range data {
		parsed, err := strconv.ParseUint(value[i*2:i*2+2], 16, 8)
		if err != nil {
			return nil, err
		}
		data[i] = byte(parsed)
	}
	return data, nil
}

func BuildTSSRequest(buildManifest map[string]any, inputs PersonalizationInputs) (map[string]any, error) {
	boardID, ok := manifestUint(inputs.Identifiers["BoardId"])
	if !ok {
		return nil, personalizedError("BoardId")
	}
	chipID, ok := manifestUint(inputs.Identifiers["ChipID"])
	if !ok || inputs.ECID == 0 || len(inputs.Nonce) < 1 || len(inputs.Nonce) > 256 {
		return nil, personalizedError("personalization inputs")
	}
	identities, ok := buildManifest["BuildIdentities"].([]any)
	if !ok || len(identities) == 0 || len(identities) > 256 {
		return nil, personalizedError("build identities")
	}
	var match map[string]any
	for _, value := range identities {
		identity, ok := value.(map[string]any)
		if !ok {
			return nil, personalizedError("build identity")
		}
		identityBoard, boardOK := manifestUint(identity["ApBoardID"])
		identityChip, chipOK := manifestUint(identity["ApChipID"])
		if boardOK && chipOK && identityBoard == boardID && identityChip == chipID {
			if match != nil {
				return nil, personalizedError("build identity match")
			}
			match = identity
		}
	}
	if match == nil {
		return nil, personalizedError("build identity match")
	}
	manifest, ok := match["Manifest"].(map[string]any)
	if !ok || len(manifest) == 0 || len(manifest) > 4096 {
		return nil, personalizedError("manifest")
	}
	for key := range manifest {
		if err := boundedASCII(key, 256); err != nil {
			return nil, err
		}
	}
	request := map[string]any{
		"@ApImg4Ticket": true, "@BBTicket": true, "@HostPlatformInfo": "mac", "@VersionInfo": "libauthinstall-1033.0.0.1.2",
		"ApBoardID": boardID, "ApChipID": chipID, "ApECID": inputs.ECID, "ApNonce": append([]byte(nil), inputs.Nonce...),
		"ApProductionMode": true, "ApSecurityDomain": uint64(1), "ApSecurityMode": true, "SepNonce": make([]byte, 20), "UID_MODE": false,
	}
	for key, value := range inputs.Identifiers {
		if strings.HasPrefix(key, "Ap,") {
			if err := boundedASCII(key, 256); err != nil {
				return nil, err
			}
			request[key] = value
		}
	}
	parameters := map[string]any{"ApProductionMode": true, "ApSecurityMode": true, "ApSupportsImg4": true}
	loadable, _ := manifest["LoadableTrustCache"].(map[string]any)
	loadableInfo, _ := loadable["Info"].(map[string]any)
	sharedRules := loadableInfo["RestoreRequestRules"]
	trustedEntries := 0
	keys := make([]string, 0, len(manifest))
	for key := range manifest {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	for _, key := range keys {
		entry, ok := manifest[key].(map[string]any)
		if !ok {
			return nil, personalizedError("manifest entry")
		}
		info, infoOK := entry["Info"].(map[string]any)
		trusted, trustedOK := entry["Trusted"].(bool)
		if !infoOK || !trustedOK || !trusted {
			continue
		}
		result := cloneAnyMap(entry)
		delete(result, "Info")
		rules := sharedRules
		if rules == nil {
			rules = info["RestoreRequestRules"]
		}
		if rules != nil {
			applied, applyErr := ApplyRestoreRules(result, parameters, rules)
			if applyErr != nil {
				return nil, applyErr
			}
			result = applied
		}
		if result["Digest"] == nil {
			result["Digest"] = []byte{}
		}
		request[key] = result
		trustedEntries++
	}
	if trustedEntries == 0 {
		return nil, personalizedError("trusted manifest entries")
	}
	if _, err := EncodeTSSRequest(request); err != nil {
		return nil, err
	}
	return request, nil
}

func ApplyRestoreRules(entry, parameters map[string]any, rules any) (map[string]any, error) {
	items, ok := rules.([]any)
	if !ok || len(items) > 256 {
		return nil, personalizedError("restore request rules")
	}
	result := cloneAnyMap(entry)
	aliases := map[string]string{"ApCurrentProductionMode": "ApProductionMode", "ApRawProductionMode": "ApProductionMode", "ApRawSecurityMode": "ApSecurityMode", "ApRequiresImage4": "ApSupportsImg4"}
	for _, value := range items {
		rule, ok := value.(map[string]any)
		if !ok {
			return nil, personalizedError("restore request rule")
		}
		conditions, conditionsOK := rule["Conditions"].(map[string]any)
		actions, actionsOK := rule["Actions"].(map[string]any)
		if !conditionsOK || !actionsOK {
			return nil, personalizedError("restore request rule")
		}
		matched := true
		for key, expected := range conditions {
			parameter, known := aliases[key]
			if !known || parameters[parameter] != expected {
				matched = false
				break
			}
		}
		if !matched {
			continue
		}
		for key, value := range actions {
			if err := boundedASCII(key, 256); err != nil {
				return nil, err
			}
			if !is255(value) {
				result[key] = value
			}
		}
	}
	return result, nil
}

func EncodeTSSRequest(request map[string]any) ([]byte, error) {
	body, err := direct.EncodePlistDocument(request)
	if err != nil || len(body) == 0 || len(body) > TSSRequestMaximum {
		return nil, personalizedError("TSS request encoding")
	}
	return body, nil
}

func DecodeTSSTicket(response []byte) ([]byte, error) {
	if len(response) == 0 || len(response) > TSSResponseMaximum || !bytes.Contains(response, []byte("MESSAGE=SUCCESS")) {
		return nil, personalizedError("TSS rejected")
	}
	marker := []byte("REQUEST_STRING=")
	index := bytes.Index(response, marker)
	if index < 0 {
		return nil, personalizedError("TSS rejected")
	}
	payload := response[index+len(marker):]
	if bytes.HasPrefix(payload, []byte("%3C")) || bytes.HasPrefix(payload, []byte("%3c")) {
		decoded, err := url.PathUnescape(string(payload))
		if err != nil {
			return nil, personalizedError("TSS response plist")
		}
		payload = []byte(decoded)
	}
	value, err := direct.DecodePlistValue(payload)
	if err != nil {
		return nil, personalizedError("TSS response plist")
	}
	document, ok := value.(map[string]any)
	if !ok {
		return nil, personalizedError("TSS ticket")
	}
	ticket, ok := document["ApImg4Ticket"].([]byte)
	if !ok || len(ticket) == 0 || len(ticket) > TSSTicketMaximum {
		return nil, personalizedError("TSS ticket")
	}
	return append([]byte(nil), ticket...), nil
}

type AppleTSSClient struct {
	Client *http.Client
}

func (client *AppleTSSClient) RequestTicket(request map[string]any) ([]byte, error) {
	body, err := EncodeTSSRequest(request)
	if err != nil {
		return nil, err
	}
	httpClient := client.Client
	if httpClient == nil {
		httpClient = &http.Client{Timeout: 30 * time.Second}
	}
	httpRequest, err := http.NewRequest(http.MethodPost, "https://gs.apple.com/TSS/controller?action=2", bytes.NewReader(body))
	if err != nil {
		return nil, personalizedError("TSS unavailable")
	}
	httpRequest.Header.Set("Cache-Control", "no-cache")
	httpRequest.Header.Set("Content-Type", `text/xml; charset="utf-8"`)
	httpRequest.Header.Set("Expect", "")
	httpRequest.Header.Set("User-Agent", "PulsePhone/1")
	response, err := httpClient.Do(httpRequest)
	if err != nil {
		return nil, personalizedError("TSS unavailable")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK {
		return nil, personalizedError("TSS HTTP status")
	}
	data, err := io.ReadAll(io.LimitReader(response.Body, TSSResponseMaximum+1))
	if err != nil || len(data) == 0 || len(data) > TSSResponseMaximum {
		return nil, personalizedError("TSS response cap")
	}
	return DecodeTSSTicket(data)
}

func manifestUint(value any) (uint64, bool) {
	switch value := value.(type) {
	case int64:
		return uint64(value), value >= 0
	case uint64:
		return value, true
	case int:
		return uint64(value), value >= 0
	case string:
		parsed, err := strconv.ParseUint(value, 0, 64)
		return parsed, err == nil
	default:
		return 0, false
	}
}

func positiveInt64(value any) (int64, bool) {
	switch value := value.(type) {
	case int64:
		return value, value >= 1
	case uint64:
		return int64(value), value >= 1 && value <= uint64(^uint64(0)>>1)
	case int:
		return int64(value), value >= 1
	default:
		return 0, false
	}
}

func personalizedRoleMaximum(role string) (int64, bool) {
	switch role {
	case PersonalizedBuildManifest:
		return BuildManifestMaximum, true
	case PersonalizedImage:
		return PersonalizedImageMaximum, true
	case PersonalizedTrustCache:
		return TrustCacheMaximum, true
	default:
		return 0, false
	}
}

func boundedASCII(value string, maximum int) error {
	if len(value) == 0 || len(value) > maximum {
		return personalizedError("ASCII identifier")
	}
	for _, character := range []byte(value) {
		if character < 0x21 || character > 0x7e {
			return personalizedError("ASCII identifier")
		}
	}
	return nil
}

func safePersonalizedComponent(value string, maximum int) error {
	if err := boundedASCII(value, maximum); err != nil || value == "." || value == ".." || strings.ContainsAny(value, `/\\`) {
		return personalizedError("component")
	}
	return nil
}

func isLowerHex64(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, character := range []byte(value) {
		if !((character >= '0' && character <= '9') || (character >= 'a' && character <= 'f')) {
			return false
		}
	}
	return true
}

func cloneAnyMap(value map[string]any) map[string]any {
	result := make(map[string]any, len(value))
	for key, item := range value {
		result[key] = item
	}
	return result
}

func is255(value any) bool {
	parsed, ok := manifestUint(value)
	return ok && parsed == 255
}

func isOne(value any) bool {
	parsed, ok := manifestUint(value)
	return ok && parsed == 1
}

func equalStringSlice(left, right []string) bool {
	if len(left) != len(right) {
		return false
	}
	for index := range left {
		if left[index] != right[index] {
			return false
		}
	}
	return true
}

func sortedUniqueStrings(values []string) []string {
	result := append([]string(nil), values...)
	sort.Strings(result)
	unique := result[:0]
	for _, value := range result {
		if len(unique) == 0 || unique[len(unique)-1] != value {
			unique = append(unique, value)
		}
	}
	return unique
}

func containsString(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}

type PersonalizedMounter interface {
	QueryMounted() (PersonalizedMountedImage, error)
	QueryReusableManifest(imageSHA384 []byte) ([]byte, error)
	PersonalizationInputs() (PersonalizationInputs, error)
	Upload(image *os.File, imageSize int64, ticket []byte, deadline time.Time) error
	Mount(ticket, trustCache []byte) error
	ProbeServices(serviceNames []string, deadline time.Time) error
	Close() error
}

type PersonalizedMounterOpener func(rawUDID string, deadline time.Time) (PersonalizedMounter, error)

type PersonalizedTSSClient interface {
	RequestTicket(request map[string]any) ([]byte, error)
}

type CoreDevicePersonalizedMounter struct {
	lockdown    *direct.Lockdown
	service     personalizedMounterService
	openService func(deadline time.Time) (personalizedMounterService, error)
	rawUDID     string
	ecid        uint64
	closed      bool
}

type personalizedMounterService interface {
	SendReceivePlist(request map[string]any, maximum int) (map[string]any, error)
	ReceivePlist(maximum int) (map[string]any, error)
	WriteRaw(data []byte) error
	Close() error
}

// lockdownPersonalizedMounterService adapts the direct USB lockdown plist
// transport to the personalized mounter's small service contract. Modern DDI
// mounting is a lockdown service operation; opening CoreDevice/RSD before a
// DDI exists makes a cold device preparation depend on the capability it is
// trying to establish.
type lockdownPersonalizedMounterService struct {
	service *direct.PlistService
}

func (service *lockdownPersonalizedMounterService) SendReceivePlist(
	request map[string]any,
	maximum int,
) (map[string]any, error) {
	value, err := service.service.SendReceive(request, maximum)
	if err != nil {
		return nil, err
	}
	response, ok := value.(map[string]any)
	if !ok {
		return nil, personalizedError("mounter response")
	}
	return response, nil
}

func (service *lockdownPersonalizedMounterService) ReceivePlist(
	maximum int,
) (map[string]any, error) {
	value, err := service.service.ReceiveValue(maximum)
	if err != nil {
		return nil, err
	}
	response, ok := value.(map[string]any)
	if !ok {
		return nil, personalizedError("mounter response")
	}
	return response, nil
}

func (service *lockdownPersonalizedMounterService) WriteRaw(data []byte) error {
	return service.service.WriteRaw(data)
}

func (service *lockdownPersonalizedMounterService) Close() error {
	return service.service.Close()
}

func OpenCoreDevicePersonalizedMounter(rawUDID string, deadline time.Time) (PersonalizedMounter, error) {
	lockdown, err := direct.OpenLockdown(rawUDID, deadline)
	if err != nil {
		return nil, err
	}
	ecID, err := lockdown.GetValue("UniqueChipID")
	if err != nil {
		lockdown.Close()
		return nil, err
	}
	ecid, ok := manifestUint(ecID)
	if !ok || ecid == 0 {
		lockdown.Close()
		return nil, personalizedError("personalization ECID")
	}
	openService := func(deadline time.Time) (personalizedMounterService, error) {
		connection, err := lockdown.StartService(direct.MobileImageMounterService)
		if err != nil {
			return nil, err
		}
		return &lockdownPersonalizedMounterService{
			service: direct.NewPlistService(connection, deadline),
		}, nil
	}
	service, err := openService(deadline)
	if err != nil {
		lockdown.Close()
		return nil, err
	}
	return &CoreDevicePersonalizedMounter{
		lockdown:    lockdown,
		service:     service,
		openService: openService,
		rawUDID:     rawUDID,
		ecid:        ecid,
	}, nil
}

func (mounter *CoreDevicePersonalizedMounter) QueryMounted() (PersonalizedMountedImage, error) {
	response, err := mounter.sendReceive(map[string]any{"Command": "LookupImage", "ImageType": "Personalized"})
	if err != nil {
		return PersonalizedMountedImage{}, err
	}
	present := true
	if value, exists := response["ImagePresent"]; exists {
		var ok bool
		present, ok = value.(bool)
		if !ok {
			return PersonalizedMountedImage{}, personalizedError("mounter response")
		}
	}
	if signature, ok := response["ImageSignature"].([]any); ok && len(signature) == 0 {
		present = false
	}
	return PersonalizedMountedImage{Present: present}, nil
}

func (mounter *CoreDevicePersonalizedMounter) QueryReusableManifest(imageSHA384 []byte) ([]byte, error) {
	response, err := mounter.sendReceive(map[string]any{
		"Command": "QueryPersonalizationManifest", "ImageSignature": imageSHA384,
		"ImageType": "DeveloperDiskImage", "PersonalizedImageType": "DeveloperDiskImage",
	})
	if err != nil {
		return nil, err
	}
	manifest, ok := response["ImageSignature"].([]byte)
	if !ok {
		if response["ImageSignature"] == nil {
			if err := mounter.service.Close(); err != nil {
				return nil, err
			}
			service, err := mounter.openService(time.Now().Add(30 * time.Second))
			if err != nil {
				return nil, err
			}
			mounter.service = service
			return nil, nil
		}
		return nil, personalizedError("reusable manifest")
	}
	if len(manifest) == 0 || len(manifest) > 1024*1024 {
		return nil, personalizedError("reusable manifest")
	}
	return append([]byte(nil), manifest...), nil
}

func (mounter *CoreDevicePersonalizedMounter) PersonalizationInputs() (PersonalizationInputs, error) {
	identifiersResponse, err := mounter.sendReceive(map[string]any{
		"Command": "QueryPersonalizationIdentifiers", "PersonalizedImageType": "DeveloperDiskImage",
	})
	if err != nil {
		return PersonalizationInputs{}, err
	}
	nonceResponse, err := mounter.sendReceive(map[string]any{
		"Command": "QueryNonce", "PersonalizedImageType": "DeveloperDiskImage",
	})
	if err != nil {
		return PersonalizationInputs{}, err
	}
	identifiers, ok := identifiersResponse["PersonalizationIdentifiers"].(map[string]any)
	if !ok {
		return PersonalizationInputs{}, personalizedError("personalization inputs")
	}
	nonce, ok := nonceResponse["PersonalizationNonce"].([]byte)
	if !ok || len(nonce) == 0 {
		return PersonalizationInputs{}, personalizedError("personalization inputs")
	}
	if mounter.ecid == 0 {
		return PersonalizationInputs{}, personalizedError("personalization ECID")
	}
	return PersonalizationInputs{Identifiers: identifiers, ECID: mounter.ecid, Nonce: append([]byte(nil), nonce...)}, nil
}

func (mounter *CoreDevicePersonalizedMounter) Upload(image *os.File, imageSize int64, ticket []byte, deadline time.Time) error {
	if image == nil || imageSize < 1 || imageSize > PersonalizedImageMaximum || len(ticket) == 0 || len(ticket) > 1024*1024 {
		return personalizedError("image bounds")
	}
	current, err := image.Seek(0, io.SeekCurrent)
	if err != nil {
		return personalizedError("image source")
	}
	end, err := image.Seek(0, io.SeekEnd)
	if err != nil || end-current != imageSize {
		return personalizedError("image extent")
	}
	if _, err := image.Seek(current, io.SeekStart); err != nil {
		return err
	}
	response, err := mounter.sendReceive(map[string]any{
		"Command": "ReceiveBytes", "ImageSignature": ticket, "ImageSize": imageSize, "ImageType": "Personalized",
	})
	if err != nil || response["Status"] != "ReceiveBytesAck" {
		return personalizedError("ReceiveBytes")
	}
	buffer := make([]byte, PersonalizedTransferChunk)
	remaining := imageSize
	for remaining > 0 {
		count := int64(len(buffer))
		if remaining < count {
			count = remaining
		}
		read, readErr := io.ReadFull(image, buffer[:count])
		if readErr != nil || int64(read) != count {
			return personalizedError("image short read")
		}
		if err := mounter.service.WriteRaw(buffer[:read]); err != nil {
			return err
		}
		remaining -= count
	}
	completion, err := mounter.service.ReceivePlist(MounterResponseMaximum)
	if err != nil || completion["Status"] != "Complete" {
		return personalizedError("ReceiveBytes completion")
	}
	return nil
}

func (mounter *CoreDevicePersonalizedMounter) Mount(ticket, trustCache []byte) error {
	if len(ticket) == 0 || len(ticket) > 1024*1024 || len(trustCache) == 0 || len(trustCache) > TrustCacheMaximum {
		return personalizedError("trust cache")
	}
	response, err := mounter.sendReceive(map[string]any{
		"Command": "MountImage", "ImageSignature": ticket, "ImageTrustCache": trustCache, "ImageType": "Personalized",
	})
	if err != nil || response["Status"] != "Complete" {
		return personalizedError("MountImage")
	}
	return nil
}

func (mounter *CoreDevicePersonalizedMounter) ProbeServices(serviceNames []string, deadline time.Time) error {
	tunnel, err := OpenUserspaceTunnel(mounter.rawUDID, deadline)
	if err != nil {
		return err
	}
	defer tunnel.Close()
	services := make([]*CoreDeviceService, 0, len(serviceNames))
	for _, name := range serviceNames {
		service, err := tunnel.RSD.StartService(name, deadline)
		if err != nil {
			for index := len(services) - 1; index >= 0; index-- {
				_ = services[index].Close()
			}
			return err
		}
		services = append(services, service)
	}
	var first error
	for index := len(services) - 1; index >= 0; index-- {
		if err := services[index].Close(); err != nil && first == nil {
			first = err
		}
	}
	return first
}

func (mounter *CoreDevicePersonalizedMounter) Close() error {
	if mounter == nil || mounter.closed {
		return nil
	}
	mounter.closed = true
	var first error
	if mounter.service != nil {
		first = mounter.service.Close()
	}
	if mounter.lockdown != nil {
		mounter.lockdown.Close()
	}
	return first
}

func (mounter *CoreDevicePersonalizedMounter) sendReceive(request map[string]any) (map[string]any, error) {
	response, err := mounter.service.SendReceivePlist(request, MounterResponseMaximum)
	if err != nil {
		return nil, err
	}
	encoded, err := direct.EncodePlistDocument(response)
	if err != nil || len(encoded) > MounterResponseMaximum {
		return nil, personalizedError("mounter response cap")
	}
	return response, nil
}

type PersonalizedDeveloperSupportSession struct {
	Store       *TrustedPersonalizedImageStore
	OpenMounter PersonalizedMounterOpener
	TSS         PersonalizedTSSClient
	manifests   map[string]CachedPersonalizedManifest
	approved    map[string]bool
}

func NewPersonalizedDeveloperSupportSession(store *TrustedPersonalizedImageStore, opener PersonalizedMounterOpener, tss PersonalizedTSSClient) *PersonalizedDeveloperSupportSession {
	if store == nil {
		store, _ = NewTrustedPersonalizedImageStore("")
	}
	if opener == nil {
		opener = OpenCoreDevicePersonalizedMounter
	}
	if tss == nil {
		tss = &AppleTSSClient{}
	}
	return &PersonalizedDeveloperSupportSession{Store: store, OpenMounter: opener, TSS: tss, manifests: map[string]CachedPersonalizedManifest{}, approved: map[string]bool{}}
}

// QueryMounted observes only device state. It intentionally does not load a
// catalog entry or host asset, because an already-mounted image has source
// precedence over every host-side acquisition source.
func (session *PersonalizedDeveloperSupportSession) QueryMounted(rawUDID string, deadline time.Time) (map[string]any, error) {
	if session == nil || session.OpenMounter == nil {
		return nil, personalizedError("developerSupportUnavailable")
	}
	mounter, err := session.OpenMounter(rawUDID, deadline)
	if err != nil {
		return nil, personalizedError("developerSupportUnavailable")
	}
	defer mounter.Close()
	mounted, err := mounter.QueryMounted()
	if err != nil {
		return nil, personalizedError("developerSupportUnavailable")
	}
	if !mounted.Present {
		return map[string]any{"mounted": false}, nil
	}
	return map[string]any{
		"mounted":    true,
		"provenance": "mountedUnknownUnverified",
	}, nil
}

func (session *PersonalizedDeveloperSupportSession) Execute(rawUDID string, connectionEpoch uint64, payload map[string]any, deadline time.Time) (map[string]any, error) {
	validated, err := validatePersonalizedPayload(connectionEpoch, payload)
	if err != nil {
		return nil, err
	}
	reference, err := session.Store.LoadReference(
		validated.catalogRevision,
		validated.catalogCanonicalSHA256,
		validated.assetContentManifestSHA256,
	)
	if err != nil {
		return nil, err
	}
	mounter, err := session.OpenMounter(rawUDID, deadline)
	if err != nil {
		return nil, personalizedError("developerSupportUnavailable")
	}
	mounterClosed := false
	defer func() {
		if !mounterClosed {
			_ = mounter.Close()
		}
	}()
	mounted, err := mounter.QueryMounted()
	if err != nil {
		return nil, personalizedError("developerSupportUnavailable")
	}
	switch validated.operation {
	case "queryMounted":
		return session.mountedResult(validated, mounted), nil
	case "requestTSS":
		if mounted.Present {
			result := session.mountedResult(validated, mounted)
			result["manifestSource"] = "noneAlreadyMounted"
			result["tssRequested"] = false
			return result, nil
		}
		manifest, err := session.resolveManifest(validated, reference, mounter, deadline)
		if err != nil {
			return nil, err
		}
		return map[string]any{"manifestReady": true, "manifestSource": manifest.Source, "mounted": false, "tssRequested": manifest.Source == "appleTSS"}, nil
	case "mount":
		if mounted.Present {
			if err := mounter.ProbeServices(reference.RequiredServices, deadline); err != nil {
				return nil, personalizedError("developerSupportUnavailable")
			}
			result := session.mountedResult(validated, mounted)
			result["requiredServiceCount"] = int64(len(reference.RequiredServices))
			result["servicesReady"] = true
			result["tssRequested"] = false
			return result, nil
		}
		key := validated.manifestKey()
		manifest, ok := session.manifests[key]
		if !ok {
			withAsset, assetErr := session.Store.OpenAsset(reference, PersonalizedMountRoles)
			if assetErr != nil {
				return nil, assetErr
			}
			imageSHA384, hashErr := withAsset.SHA384Role(PersonalizedImage)
			if hashErr != nil {
				_ = withAsset.Close()
				return nil, hashErr
			}
			reusable, queryErr := mounter.QueryReusableManifest(imageSHA384)
			_ = withAsset.Close()
			if queryErr != nil {
				return nil, queryErr
			}
			if reusable == nil {
				return nil, personalizationServiceUnavailableError()
			}
			manifest = CachedPersonalizedManifest{Bytes: reusable, Source: "reusableDeviceManifest"}
			session.manifests[key] = manifest
		}
		asset, err := session.Store.OpenAsset(reference, PersonalizedMountRoles)
		if err != nil {
			return nil, err
		}
		trustCache, err := asset.ReadRole(PersonalizedTrustCache, TrustCacheMaximum)
		if err == nil {
			image, imageErr := asset.OpenRole(PersonalizedImage)
			if imageErr != nil {
				err = imageErr
			} else {
				err = mounter.Upload(image, reference.Files[PersonalizedImage].Size, manifest.Bytes, deadline)
				_ = image.Close()
			}
		}
		if err == nil {
			err = mounter.Mount(manifest.Bytes, trustCache)
		}
		_ = asset.Close()
		if err != nil {
			return nil, err
		}
		// MountImage has committed. Some devices reset the pre-mount mounter
		// connection while changing the service surface, so its close result
		// cannot overturn the committed mount outcome. The Runtime verifies
		// readiness by opening PulsePhone's complete RequiredFacets surface;
		// a mounter-only probe cannot prove that surface is usable.
		_ = mounter.Close()
		mounterClosed = true
		delete(session.manifests, key)
		session.approved[validated.mountKey()] = true
		return map[string]any{"manifestSource": manifest.Source, "mountCommitted": true, "mounted": true, "provenance": "approved", "requiredServiceCount": int64(len(reference.RequiredServices)), "tssRequested": manifest.Source == "appleTSS"}, nil
	case "probeServices":
		if !mounted.Present {
			return nil, personalizedError("developerSupportUnavailable")
		}
		if err := mounter.ProbeServices(reference.RequiredServices, deadline); err != nil {
			return nil, personalizedError("developerSupportUnavailable")
		}
		result := session.mountedResult(validated, mounted)
		result["requiredServiceCount"] = int64(len(reference.RequiredServices))
		result["servicesReady"] = true
		return result, nil
	default:
		return nil, personalizedError("developerSupportUnavailable")
	}
}

type validatedPersonalizedPayload struct {
	assetContentManifestSHA256 string
	catalogCanonicalSHA256     string
	catalogRevision            string
	connectionEpoch            uint64
	fileRoles                  []string
	operation                  string
	preparationAttemptID       string
}

func validatePersonalizedPayload(connectionEpoch uint64, payload map[string]any) (validatedPersonalizedPayload, error) {
	if payload == nil || len(payload) != 8 {
		return validatedPersonalizedPayload{}, personalizedError("payload shape")
	}
	allowed := map[string]bool{"assetContentManifestSHA256": true, "catalogCanonicalSHA256": true, "catalogRevision": true, "deviceContext": true, "fileRoles": true, "operation": true, "preparationAttemptID": true, "preparationGroupID": true}
	for key := range payload {
		if !allowed[key] {
			return validatedPersonalizedPayload{}, personalizedError("payload shape")
		}
	}
	revision, revisionOK := payload["catalogRevision"].(string)
	catalogSHA256, catalogOK := payload["catalogCanonicalSHA256"].(string)
	contentSHA256, contentOK := payload["assetContentManifestSHA256"].(string)
	attempt, attemptOK := payload["preparationAttemptID"].(string)
	group, groupOK := payload["preparationGroupID"].(string)
	operation, operationOK := payload["operation"].(string)
	if !revisionOK || !catalogOK || !contentOK || !attemptOK || !groupOK || !operationOK || safePersonalizedComponent(revision, 256) != nil || !isLowerHex64(catalogSHA256) || !isLowerHex64(contentSHA256) || safePersonalizedComponent(attempt, 128) != nil || group != PreparationGroupID {
		return validatedPersonalizedPayload{}, personalizedError("payload shape")
	}
	context, contextOK := payload["deviceContext"].(map[string]any)
	if !contextOK || len(context) != 1 {
		return validatedPersonalizedPayload{}, personalizedError("device context")
	}
	actualEpoch, epochOK := manifestUint(context["connectionEpoch"])
	if !epochOK || actualEpoch == 0 || actualEpoch != connectionEpoch {
		return validatedPersonalizedPayload{}, personalizedError("connection epoch")
	}
	roleSets := map[string][]string{"mount": PersonalizedMountRoles, "probeServices": {}, "queryMounted": {}, "requestTSS": PersonalizedRequestTSSRoles}
	rolesValue, rolesOK := payload["fileRoles"].([]any)
	if !rolesOK {
		return validatedPersonalizedPayload{}, personalizedError("file roles")
	}
	expectedRoles, operationOK := roleSets[operation]
	if !operationOK || len(rolesValue) != len(expectedRoles) {
		return validatedPersonalizedPayload{}, personalizedError("operation")
	}
	roles := make([]string, len(rolesValue))
	for index, value := range rolesValue {
		var ok bool
		roles[index], ok = value.(string)
		if !ok || roles[index] != expectedRoles[index] {
			return validatedPersonalizedPayload{}, personalizedError("file roles")
		}
	}
	return validatedPersonalizedPayload{assetContentManifestSHA256: contentSHA256, catalogCanonicalSHA256: catalogSHA256, catalogRevision: revision, connectionEpoch: actualEpoch, fileRoles: roles, operation: operation, preparationAttemptID: attempt}, nil
}

func (payload validatedPersonalizedPayload) manifestKey() string {
	return fmt.Sprintf("%d:%s:%s", payload.connectionEpoch, payload.preparationAttemptID, payload.assetContentManifestSHA256)
}

func (payload validatedPersonalizedPayload) mountKey() string {
	return fmt.Sprintf("%d:%s", payload.connectionEpoch, payload.assetContentManifestSHA256)
}

func (session *PersonalizedDeveloperSupportSession) mountedResult(payload validatedPersonalizedPayload, mounted PersonalizedMountedImage) map[string]any {
	if !mounted.Present {
		return map[string]any{"mounted": false}
	}
	provenance := "mountedUnknownUnverified"
	if session.approved[payload.mountKey()] {
		provenance = "approved"
	}
	return map[string]any{"mounted": true, "provenance": provenance}
}

func (session *PersonalizedDeveloperSupportSession) resolveManifest(payload validatedPersonalizedPayload, reference PersonalizedCatalogReference, mounter PersonalizedMounter, deadline time.Time) (CachedPersonalizedManifest, error) {
	key := payload.manifestKey()
	if manifest, ok := session.manifests[key]; ok {
		return manifest, nil
	}
	if len(session.manifests) >= 8 {
		return CachedPersonalizedManifest{}, personalizedError("manifest cache capacity")
	}
	asset, err := session.Store.OpenAsset(reference, PersonalizedRequestTSSRoles)
	if err != nil {
		return CachedPersonalizedManifest{}, err
	}
	defer asset.Close()
	imageSHA384, err := asset.SHA384Role(PersonalizedImage)
	if err != nil {
		return CachedPersonalizedManifest{}, err
	}
	reusable, err := mounter.QueryReusableManifest(imageSHA384)
	if err != nil {
		return CachedPersonalizedManifest{}, err
	}
	if reusable != nil {
		manifest := CachedPersonalizedManifest{Bytes: reusable, Source: "reusableDeviceManifest"}
		session.manifests[key] = manifest
		return manifest, nil
	}
	buildBytes, err := asset.ReadRole(PersonalizedBuildManifest, BuildManifestMaximum)
	if err != nil {
		return CachedPersonalizedManifest{}, err
	}
	value, err := direct.DecodePlistValue(buildBytes)
	if err != nil {
		return CachedPersonalizedManifest{}, personalizedError("build manifest")
	}
	buildManifest, ok := value.(map[string]any)
	if !ok {
		return CachedPersonalizedManifest{}, personalizedError("build manifest")
	}
	inputs, err := mounter.PersonalizationInputs()
	if err != nil {
		return CachedPersonalizedManifest{}, err
	}
	request, err := BuildTSSRequest(buildManifest, inputs)
	if err != nil {
		return CachedPersonalizedManifest{}, personalizationServiceUnavailableError()
	}
	ticket, err := session.TSS.RequestTicket(request)
	if err != nil {
		return CachedPersonalizedManifest{}, personalizationServiceUnavailableError()
	}
	manifest := CachedPersonalizedManifest{Bytes: ticket, Source: "appleTSS"}
	session.manifests[key] = manifest
	return manifest, nil
}

func (session *PersonalizedDeveloperSupportSession) Close() {
	if session == nil {
		return
	}
	session.manifests = map[string]CachedPersonalizedManifest{}
	session.approved = map[string]bool{}
}
