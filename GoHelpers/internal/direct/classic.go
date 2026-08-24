package direct

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"io"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"

	"pulsephone/GoHelpers/internal/protocol"
)

const (
	classicPreparationGroup = "prep.legacy.developer.v2"
	classicImageRole        = "classic.image"
	classicSignatureRole    = "classic.signature"
	classicImageMaximum     = int64(8 * 1024 * 1024 * 1024)
	classicSignatureMaximum = int64(1024 * 1024)
	classicCatalogMaximum   = 4 * 1024 * 1024
	classicResponseMaximum  = 64 * 1024
	classicUploadChunk      = 1 * 1024 * 1024
	// The Runtime allows this route five minutes in total. Reserve time for the
	// HelperWire terminal result so a device-side mount timeout remains typed.
	classicMountResponseReserve = 5 * time.Second
	classicMountDeadline        = 5*time.Minute - classicMountResponseReserve
	classicProbeDeadline        = 30 * time.Second
	classicQueryDeadline        = 10 * time.Second
	classicProbeRetryInitial    = 250 * time.Millisecond
	classicProbeRetryMaximum    = 2 * time.Second
)

var classicRequiredServices = []string{
	"com.apple.instruments.remoteserver.DVTSecureSocketProxy",
	"com.apple.mobile.screenshotr",
}

type classicFileRecord struct {
	size   int64
	sha256 string
}

type classicReference struct {
	catalogCanonicalSHA256 string
	catalogRevision        string
	contentManifestSHA256  string
	manifestBytes          []byte
	files                  map[string]classicFileRecord
	requiredServices       []string
}

type classicAssetLease struct {
	lock  *os.File
	roles map[string]*os.File
}

type classicLockdown interface {
	StartService(name string) (net.Conn, error)
	Close()
}

type classicLockdownOpener func(udid string, deadline time.Time) (classicLockdown, error)

func (l *classicAssetLease) Close() {
	for _, file := range l.roles {
		_ = file.Close()
	}
	l.roles = nil
	if l.lock != nil {
		_ = syscall.Flock(int(l.lock.Fd()), syscall.LOCK_UN)
		_ = l.lock.Close()
		l.lock = nil
	}
}

func classicRoute(config OneShotConfig, payload map[string]any, deadline time.Time) (map[string]any, *OperationFailure) {
	return classicRouteWithLockdown(config, payload, deadline, func(udid string, deadline time.Time) (classicLockdown, error) {
		return OpenLockdown(udid, deadline)
	})
}

func classicRouteWithLockdown(config OneShotConfig, payload map[string]any, deadline time.Time, openLockdown classicLockdownOpener) (map[string]any, *OperationFailure) {
	operation, failure := validateClassicPayload(config, payload)
	if failure != nil {
		return nil, failure
	}
	lockdown, err := openLockdown(config.RawTransportUDID, deadline)
	if err != nil {
		return nil, classicFailure("developerSupportUnavailable", operation)
	}
	defer lockdown.Close()
	conn, err := lockdown.StartService(MobileImageMounterService)
	if err != nil {
		return nil, classicFailure(classicMounterFailure(operation), operation)
	}
	service := newPlistService(conn, deadline)
	defer service.close()
	present, signature, err := classicQueryMounted(service)
	if err != nil {
		return nil, classicFailure(classicMounterFailure(operation), operation)
	}
	if operation == "queryMounted" {
		if !present {
			return map[string]any{"mounted": false}, nil
		}
		return map[string]any{"mounted": true, "provenance": "mountedUnknownUnverified"}, nil
	}
	if operation == "probeServices" {
		if !present {
			return nil, classicFailure("developerSupportUnavailable", operation)
		}
		if err := classicProbeServices(lockdown, classicRequiredServices, deadline); err != nil {
			return nil, classicFailure("developerServicesUnavailable", operation)
		}
		return map[string]any{"mounted": true, "provenance": "mountedUnknownUnverified", "requiredServiceCount": int64(len(classicRequiredServices)), "servicesReady": true}, nil
	}
	reference, err := loadClassicReference(
		payload["catalogRevision"].(string),
		payload["catalogCanonicalSHA256"].(string),
		payload["assetContentManifestSHA256"].(string),
	)
	if err != nil {
		return nil, classicFailure("developerImageCatalogMismatch", operation)
	}

	provenance := "approved"
	if present {
		provenance = classicProvenance(signature, reference)
	} else {
		lease, err := openClassicAsset(reference, payload["fileRoles"].([]any))
		if err != nil {
			return nil, classicFailure("developerImageIntegrityFailed", operation)
		}
		defer lease.Close()
		signatureFile := lease.roles[classicSignatureRole]
		signature, err = readBoundedFile(signatureFile, classicSignatureMaximum)
		if err != nil {
			return nil, classicFailure("developerImageIntegrityFailed", operation)
		}
		imageFile := lease.roles[classicImageRole]
		if err := classicUploadImage(service, imageFile, reference.files[classicImageRole].size, signature, deadline); err != nil {
			return nil, classicFailure("developerImageMountFailed", operation)
		}
		if err := classicMountImage(service, signature); err != nil {
			return nil, classicFailure("developerImageMountFailed", operation)
		}
		present, mountedSignature, err := classicQueryMounted(service)
		if err != nil || !present || !equalBytes(mountedSignature, signature) {
			return nil, classicFailure("developerImageMountFailed", operation)
		}
		provenance = "approved"
	}
	if err := classicProbeServices(lockdown, reference.requiredServices, deadline); err != nil {
		return nil, classicFailure("developerServicesUnavailable", operation)
	}
	return map[string]any{"mounted": true, "provenance": provenance, "requiredServiceCount": int64(len(reference.requiredServices)), "servicesReady": true}, nil
}

func classicOperationDeadline(operation string, now time.Time) time.Time {
	duration := classicMountDeadline
	switch operation {
	case "queryMounted":
		duration = classicQueryDeadline
	case "probeServices":
		duration = classicProbeDeadline
	}
	return now.Add(duration)
}

func validateClassicPayload(config OneShotConfig, payload map[string]any) (string, *OperationFailure) {
	if !sameStringKeys(payload, "assetContentManifestSHA256", "catalogCanonicalSHA256", "catalogRevision", "deviceContext", "fileRoles", "operation", "preparationAttemptID", "preparationGroupID") || payload["preparationGroupID"] != classicPreparationGroup {
		return "", classicFailure("developerSupportUnavailable", "")
	}
	operation, ok := payload["operation"].(string)
	if !ok || (operation != "mount" && operation != "probeServices" && operation != "queryMounted") {
		return "", classicFailure("developerSupportUnavailable", operation)
	}
	if !isUUIDString(payload["preparationAttemptID"]) {
		return "", classicFailure("developerSupportUnavailable", operation)
	}
	if !lowerHexDigest(stringValue(payload["catalogCanonicalSHA256"])) || !lowerHexDigest(stringValue(payload["assetContentManifestSHA256"])) || !safeClassicComponent(stringValue(payload["catalogRevision"]), 256) {
		return "", classicFailure("developerSupportUnavailable", operation)
	}
	context, ok := payload["deviceContext"].(map[string]any)
	if !ok || len(context) != 1 || uintNumber(context["connectionEpoch"]) != config.ConnectionEpoch {
		return "", classicFailure("developerSupportUnavailable", operation)
	}
	roles, ok := payload["fileRoles"].([]any)
	if !ok {
		return "", classicFailure("developerSupportUnavailable", operation)
	}
	if operation == "mount" {
		if len(roles) != 2 || roles[0] != classicImageRole || roles[1] != classicSignatureRole {
			return "", classicFailure("developerSupportUnavailable", operation)
		}
	} else if len(roles) != 0 {
		return "", classicFailure("developerSupportUnavailable", operation)
	}
	return operation, nil
}

func loadClassicReference(revision, catalogCanonicalSHA256, contentManifestSHA256 string) (classicReference, error) {
	if !safeClassicComponent(revision, 256) || !lowerHexDigest(catalogCanonicalSHA256) || !lowerHexDigest(contentManifestSHA256) {
		return classicReference{}, errors.New("catalog component")
	}
	store, err := openClassicStore()
	if err != nil {
		return classicReference{}, err
	}
	defer store.Close()
	catalogs, err := openClassicDirectory(store, "Catalog")
	if err != nil {
		return classicReference{}, err
	}
	defer catalogs.Close()
	catalogFile, err := openClassicRegular(catalogs, "developer-image-catalog.v1.json", os.O_RDONLY, classicCatalogMaximum, -1, false)
	if err != nil {
		return classicReference{}, err
	}
	defer catalogFile.Close()
	data, err := readClassicFile(catalogFile, classicCatalogMaximum)
	if err != nil {
		return classicReference{}, err
	}
	catalogDigest := sha256.Sum256(data)
	if hex.EncodeToString(catalogDigest[:]) != catalogCanonicalSHA256 {
		return classicReference{}, errors.New("catalog hash")
	}
	document, err := protocol.ValidateDocument(data, classicCatalogMaximum)
	if err != nil {
		return classicReference{}, err
	}
	catalog := document.Root
	if len(catalog) != 6 || uintNumber(catalog["schemaVersion"]) != 1 || catalog["catalogRevision"] != revision {
		return classicReference{}, errors.New("catalog shape")
	}
	entries, ok := catalog["developerDiskImages"].([]any)
	if !ok {
		return classicReference{}, errors.New("catalog disk images")
	}
	matched := false
	for _, raw := range entries {
		entry, ok := raw.(map[string]any)
		if !ok {
			return classicReference{}, errors.New("catalog disk image")
		}
		if entry["contentManifestSHA256"] == contentManifestSHA256 {
			// Multiple iOS versions may legitimately reference the same immutable
			// DDI content. The helper is bound to that content hash and the full
			// canonical catalog snapshot, not to a unique version label.
			if !safeClassicComponent(stringValue(entry["ddiVersion"]), 256) || !lowerHexDigest(stringValue(entry["archiveSHA256"])) || uintNumber(entry["archiveSize"]) == 0 || !safeHTTPSURL(stringValue(entry["sourceURL"])) {
				return classicReference{}, errors.New("catalog disk image")
			}
			matched = true
		}
	}
	if !matched {
		return classicReference{}, errors.New("catalog disk image")
	}
	assets, err := openClassicDirectory(store, "DDI")
	if err != nil {
		return classicReference{}, err
	}
	defer assets.Close()
	asset, err := openClassicDirectory(assets, contentManifestSHA256)
	if err != nil {
		return classicReference{}, err
	}
	defer asset.Close()
	manifestFile, err := openClassicRegular(asset, "manifest.v1.json", os.O_RDONLY, 16*1024, -1, false)
	if err != nil {
		return classicReference{}, err
	}
	manifestBytes, err := readClassicFile(manifestFile, 16*1024)
	_ = manifestFile.Close()
	if err != nil {
		return classicReference{}, err
	}
	manifestDocument, err := protocol.ValidateDocument(manifestBytes, 16*1024)
	if err != nil {
		return classicReference{}, errors.New("asset manifest")
	}
	manifest := manifestDocument.Root
	if len(manifest) != 2 || manifest["imageKind"] != "classic" {
		return classicReference{}, errors.New("asset manifest")
	}
	files, ok := manifest["files"].([]any)
	if !ok {
		return classicReference{}, errors.New("catalog files")
	}
	records := map[string]classicFileRecord{}
	manifestFiles := make([]any, 0, len(files))
	for _, raw := range files {
		file, ok := raw.(map[string]any)
		if !ok {
			return classicReference{}, errors.New("catalog file")
		}
		role, roleOK := file["fileRole"].(string)
		digest, digestOK := file["sha256"].(string)
		size := int64(uintNumber(file["size"]))
		maximum := classicSignatureMaximum
		if role == classicImageRole {
			maximum = classicImageMaximum
		}
		if !roleOK || (role != classicImageRole && role != classicSignatureRole) || !digestOK || !lowerHexDigest(digest) || size < 1 || size > maximum {
			return classicReference{}, errors.New("catalog file metadata")
		}
		if _, exists := records[role]; exists {
			return classicReference{}, errors.New("duplicate catalog role")
		}
		records[role] = classicFileRecord{size: size, sha256: digest}
		manifestFiles = append(manifestFiles, map[string]any{"fileRole": role, "sha256": digest, "size": size})
	}
	if len(records) != 2 {
		return classicReference{}, errors.New("catalog role set")
	}
	sort.Slice(manifestFiles, func(i, j int) bool {
		return manifestFiles[i].(map[string]any)["fileRole"].(string) < manifestFiles[j].(map[string]any)["fileRole"].(string)
	})
	canonicalManifest, err := protocol.EncodeValue(map[string]any{"files": manifestFiles, "imageKind": "classic"}, false)
	if err != nil || !equalBytes(canonicalManifest, manifestBytes) {
		return classicReference{}, errors.New("asset manifest")
	}
	contentFiles := make([]any, 0, len(manifestFiles))
	for _, raw := range manifestFiles {
		file := raw.(map[string]any)
		role := stringValue(file["fileRole"])
		path := map[string]string{classicImageRole: "DeveloperDiskImage.dmg", classicSignatureRole: "DeveloperDiskImage.dmg.signature"}[role]
		contentFiles = append(contentFiles, map[string]any{"path": path, "sha256": stringValue(file["sha256"]), "size": file["size"]})
	}
	sort.Slice(contentFiles, func(i, j int) bool {
		left := contentFiles[i].(map[string]any)
		right := contentFiles[j].(map[string]any)
		return stringValue(left["path"]) < stringValue(right["path"])
	})
	contentBytes, err := protocol.EncodeValue(contentFiles, false)
	if err != nil {
		return classicReference{}, err
	}
	contentDigest := sha256.Sum256(contentBytes)
	if hex.EncodeToString(contentDigest[:]) != contentManifestSHA256 {
		return classicReference{}, errors.New("content manifest")
	}
	return classicReference{
		catalogCanonicalSHA256: catalogCanonicalSHA256,
		catalogRevision:        revision,
		contentManifestSHA256:  contentManifestSHA256,
		manifestBytes:          manifestBytes,
		files:                  records,
		requiredServices:       classicRequiredServices,
	}, nil
}

func openClassicAsset(reference classicReference, roles []any) (*classicAssetLease, error) {
	if len(roles) != 2 || roles[0] != classicImageRole || roles[1] != classicSignatureRole {
		return nil, errors.New("classic roles")
	}
	store, err := openClassicStore()
	if err != nil {
		return nil, err
	}
	defer store.Close()
	locks, err := openClassicDirectory(store, "locks")
	if err != nil {
		return nil, err
	}
	lock, err := openClassicRegular(locks, reference.contentManifestSHA256+".lock", os.O_RDWR, 0, 0, true)
	_ = locks.Close()
	if err != nil {
		return nil, err
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_SH); err != nil {
		_ = lock.Close()
		return nil, err
	}
	lease := &classicAssetLease{lock: lock, roles: map[string]*os.File{}}
	closeOnError := true
	defer func() {
		if closeOnError {
			lease.Close()
		}
	}()
	assets, err := openClassicDirectory(store, "DDI")
	if err != nil {
		return nil, err
	}
	defer assets.Close()
	asset, err := openClassicDirectory(assets, reference.contentManifestSHA256)
	if err != nil {
		return nil, err
	}
	defer asset.Close()
	manifestFile, err := openClassicRegular(asset, "manifest.v1.json", os.O_RDONLY, 16*1024, int64(len(reference.manifestBytes)), false)
	if err != nil {
		return nil, err
	}
	manifest, err := readClassicFile(manifestFile, 16*1024)
	_ = manifestFile.Close()
	if err != nil || string(manifest) != string(reference.manifestBytes) {
		return nil, errors.New("asset manifest")
	}
	roleRoot, err := openClassicDirectory(asset, "roles")
	if err != nil {
		return nil, err
	}
	defer roleRoot.Close()
	for _, role := range []string{classicImageRole, classicSignatureRole} {
		maximum := classicSignatureMaximum
		if role == classicImageRole {
			maximum = classicImageMaximum
		}
		record := reference.files[role]
		file, err := openClassicRegular(roleRoot, role, os.O_RDONLY, maximum, record.size, false)
		if err != nil {
			return nil, err
		}
		digest, err := hashFile(file)
		if err != nil || digest != record.sha256 {
			_ = file.Close()
			return nil, errors.New("asset role hash")
		}
		_, _ = file.Seek(0, io.SeekStart)
		lease.roles[role] = file
	}
	closeOnError = false
	return lease, nil
}

func classicQueryMounted(service *plistService) (bool, []byte, error) {
	if err := service.send(map[string]any{"Command": "LookupImage", "ImageType": "Developer"}); err != nil {
		return false, nil, err
	}
	response, err := service.receive(classicResponseMaximum)
	if err != nil {
		return false, nil, err
	}
	return classicMountedImage(response)
}

func classicMountedImage(response map[string]any) (bool, []byte, error) {
	if present, ok := response["ImagePresent"].(bool); ok && !present {
		return false, nil, nil
	}
	value, exists := response["ImageSignature"]
	if !exists || value == nil {
		return false, nil, nil
	}
	if values, listOK := value.([]any); listOK {
		if len(values) == 0 {
			return false, nil, nil
		}
		value = values[0]
	}
	signature, ok := value.([]byte)
	if !ok || len(signature) == 0 || len(signature) > int(classicSignatureMaximum) {
		return false, nil, errors.New("invalid LookupImage signature")
	}
	return true, signature, nil
}

func classicUploadImage(service *plistService, image *os.File, size int64, signature []byte, deadline time.Time) error {
	if size <= 0 || size > classicImageMaximum || len(signature) == 0 || len(signature) > int(classicSignatureMaximum) {
		return errors.New("image bounds")
	}
	info, err := image.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() != size {
		return errors.New("image source size")
	}
	if err := service.send(map[string]any{"Command": "ReceiveBytes", "ImageSignature": signature, "ImageSize": size, "ImageType": "Developer"}); err != nil {
		return err
	}
	ack, err := service.receive(classicResponseMaximum)
	if err != nil || ack["Status"] != "ReceiveBytesAck" {
		return errors.New("image receive acknowledgement")
	}
	if _, err := image.Seek(0, io.SeekStart); err != nil {
		return err
	}
	buffer := make([]byte, classicUploadChunk)
	var sent int64
	for sent < size {
		count := int64(len(buffer))
		if remaining := size - sent; remaining < count {
			count = remaining
		}
		read, err := io.ReadFull(image, buffer[:count])
		if err != nil || int64(read) != count {
			return io.ErrUnexpectedEOF
		}
		if err := writeDeadline(service.conn, buffer[:read], deadline); err != nil {
			return err
		}
		sent += count
	}
	complete, err := service.receive(classicResponseMaximum)
	if err != nil || complete["Status"] != "Complete" {
		return errors.New("image receive completion")
	}
	return nil
}

func classicMountImage(service *plistService, signature []byte) error {
	if err := service.send(map[string]any{"Command": "MountImage", "ImageSignature": signature, "ImageType": "Developer"}); err != nil {
		return err
	}
	response, err := service.receive(classicResponseMaximum)
	if err != nil || response["Status"] != "Complete" {
		return errors.New("image mount completion")
	}
	return nil
}

func classicProbeServices(lockdown classicLockdown, services []string, deadline time.Time) error {
	probeDeadline := time.Now().Add(classicProbeDeadline)
	if deadline.Before(probeDeadline) {
		probeDeadline = deadline
	}
	retryDelay := classicProbeRetryInitial
	for {
		var probeError error
		for _, name := range services {
			conn, err := lockdown.StartService(name)
			if err != nil {
				probeError = err
				break
			}
			_ = conn.SetDeadline(probeDeadline)
			_ = conn.Close()
		}
		if probeError == nil {
			return nil
		}
		if !classicProbeRetryable(probeError) || !time.Now().Before(probeDeadline) {
			return probeError
		}
		if remaining := time.Until(probeDeadline); remaining < retryDelay {
			time.Sleep(remaining)
		} else {
			time.Sleep(retryDelay)
		}
		if retryDelay < classicProbeRetryMaximum {
			retryDelay *= 2
			if retryDelay > classicProbeRetryMaximum {
				retryDelay = classicProbeRetryMaximum
			}
		}
	}
}

func classicProbeRetryable(err error) bool {
	var failure *Failure
	return errors.As(err, &failure) && failure.Code == "developerServicesUnavailable"
}

func classicMountedResult(present bool, signature []byte, reference classicReference) map[string]any {
	if !present {
		return map[string]any{"mounted": false}
	}
	return map[string]any{"mounted": true, "provenance": classicProvenance(signature, reference)}
}

func classicProvenance(signature []byte, reference classicReference) string {
	digest := sha256.Sum256(signature)
	return map[bool]string{true: "approved", false: "mountedUnknownUnverified"}[hex.EncodeToString(digest[:]) == reference.files[classicSignatureRole].sha256]
}

func classicFailure(code, operation string) *OperationFailure {
	return &OperationFailure{Code: code, CommitState: "notCommitted", Outcome: "failed", Stage: classicStage(operation), Details: map[string]any{"phase": classicStage(operation), "preparationGroupID": classicPreparationGroup}}
}

func classicMounterFailure(operation string) string {
	if operation == "mount" {
		return "developerImageMountFailed"
	}
	return "developerSupportUnavailable"
}

func classicStage(operation string) string {
	switch operation {
	case "mount":
		return "mounting"
	case "probeServices":
		return "probingServices"
	case "queryMounted":
		return "queryingMountedImage"
	default:
		return "resolvingDeveloperSupport"
	}
}

func classicStorePath() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(home, "Library", "Application Support", "PulsePhone", "DeveloperImages"), nil
}

func openClassicStore() (*os.Root, error) {
	path, err := classicStorePath()
	if err != nil || !filepath.IsAbs(path) {
		return nil, errors.New("classic store root")
	}
	resolved, err := filepath.EvalSymlinks(path)
	if err != nil || resolved != path {
		return nil, errors.New("classic store root identity")
	}
	before, err := os.Lstat(path)
	if err != nil || validateClassicDirectoryInfo(before, uint32(os.Geteuid())) != nil {
		return nil, errors.New("classic store root metadata")
	}
	root, err := os.OpenRoot(path)
	if err != nil {
		return nil, err
	}
	after, err := root.Stat(".")
	if err != nil || validateClassicDirectoryInfo(after, uint32(os.Geteuid())) != nil || !sameClassicIdentity(before, after) {
		_ = root.Close()
		return nil, errors.New("classic store root identity")
	}
	return root, nil
}

func openClassicDirectory(parent *os.Root, name string) (*os.Root, error) {
	if parent == nil || !safeClassicComponent(name, 256) {
		return nil, errors.New("classic directory component")
	}
	before, err := parent.Lstat(name)
	if err != nil || validateClassicDirectoryInfo(before, uint32(os.Geteuid())) != nil {
		return nil, errors.New("classic directory metadata")
	}
	child, err := parent.OpenRoot(name)
	if err != nil {
		return nil, err
	}
	after, err := child.Stat(".")
	if err != nil || validateClassicDirectoryInfo(after, uint32(os.Geteuid())) != nil || !sameClassicIdentity(before, after) {
		_ = child.Close()
		return nil, errors.New("classic directory identity")
	}
	return child, nil
}

func openClassicRegular(parent *os.Root, name string, flags int, maximum, exact int64, lock bool) (*os.File, error) {
	if parent == nil || !safeClassicComponent(name, 320) {
		return nil, errors.New("classic file component")
	}
	before, err := parent.Lstat(name)
	if err != nil || validateClassicRegularInfo(before, uint32(os.Geteuid()), maximum, exact, lock) != nil {
		return nil, errors.New("classic file metadata")
	}
	file, err := parent.OpenFile(name, flags, 0)
	if err != nil {
		return nil, err
	}
	after, err := file.Stat()
	if err != nil || validateClassicRegularInfo(after, uint32(os.Geteuid()), maximum, exact, lock) != nil || !sameClassicIdentity(before, after) {
		_ = file.Close()
		return nil, errors.New("classic file identity")
	}
	return file, nil
}

func validateSecureFile(file *os.File, exact int64, lock bool) error {
	return validateSecureFileOwnedBy(file, exact, lock, uint32(os.Geteuid()))
}

func validateSecureFileOwnedBy(file *os.File, exact int64, lock bool, owner uint32) error {
	if file == nil {
		return errors.New("file metadata")
	}
	info, err := file.Stat()
	if err != nil {
		return err
	}
	return validateClassicRegularInfo(info, owner, exact, exact, lock)
}

func validateClassicDirectoryInfo(info os.FileInfo, owner uint32) error {
	statInfo, ok := classicStat(info)
	if !ok || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm() != 0o700 || statInfo.Uid != owner {
		return errors.New("directory metadata")
	}
	return nil
}

func validateClassicRegularInfo(info os.FileInfo, owner uint32, maximum, exact int64, lock bool) error {
	statInfo, ok := classicStat(info)
	if !ok || !info.Mode().IsRegular() || info.Mode()&os.ModeSymlink != 0 || info.Mode().Perm() != 0o600 || statInfo.Uid != owner || statInfo.Nlink != 1 || (maximum >= 0 && info.Size() > maximum) || (exact >= 0 && info.Size() != exact) {
		return errors.New("file metadata")
	}
	if lock && info.Size() != 0 {
		return errors.New("lock metadata")
	}
	return nil
}

func classicStat(info os.FileInfo) (*syscall.Stat_t, bool) {
	if info == nil {
		return nil, false
	}
	value, ok := info.Sys().(*syscall.Stat_t)
	return value, ok
}

func sameClassicIdentity(left, right os.FileInfo) bool {
	leftStat, leftOK := classicStat(left)
	rightStat, rightOK := classicStat(right)
	return leftOK && rightOK && leftStat.Dev == rightStat.Dev && leftStat.Ino == rightStat.Ino
}

func readClassicFile(file *os.File, maximum int64) ([]byte, error) {
	if file == nil || maximum < 0 {
		return nil, errors.New("classic file cap")
	}
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	data, err := io.ReadAll(io.LimitReader(file, maximum+1))
	if err != nil || int64(len(data)) > maximum {
		return nil, errors.New("classic file cap")
	}
	_, _ = file.Seek(0, io.SeekStart)
	return data, nil
}

func hashFile(file *os.File) (string, error) {
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return "", err
	}
	hash := sha256.New()
	if _, err := io.Copy(hash, file); err != nil {
		return "", err
	}
	return hex.EncodeToString(hash.Sum(nil)), nil
}

func readBoundedFile(file *os.File, maximum int64) ([]byte, error) {
	if _, err := file.Seek(0, io.SeekStart); err != nil {
		return nil, err
	}
	data, err := io.ReadAll(io.LimitReader(file, maximum+1))
	if err != nil || len(data) == 0 || int64(len(data)) > maximum {
		return nil, errors.New("file cap")
	}
	return data, nil
}

func safeClassicComponent(value string, maximum int) bool {
	if len(value) == 0 || len(value) > maximum || value == "." || value == ".." || strings.ContainsAny(value, "/\\") {
		return false
	}
	for _, character := range []byte(value) {
		if character < 0x21 || character > 0x7e {
			return false
		}
	}
	return true
}

func lowerHexDigest(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, character := range []byte(value) {
		if !(character >= '0' && character <= '9') && !(character >= 'a' && character <= 'f') {
			return false
		}
	}
	return true
}

func safeHTTPSURL(value string) bool {
	return len(value) >= len("https://x") &&
		strings.HasPrefix(value, "https://") &&
		!strings.ContainsAny(value, "\\\r\n")
}

func uintNumber(value any) uint64 {
	switch value := value.(type) {
	case int64:
		if value < 0 {
			return 0
		}
		return uint64(value)
	case uint64:
		return value
	case int:
		if value < 0 {
			return 0
		}
		return uint64(value)
	default:
		return 0
	}
}

func stringValue(value any) string {
	result, _ := value.(string)
	return result
}

func isUUIDString(value any) bool {
	stringValue, ok := value.(string)
	return ok && isUUID(stringValue)
}

func equalStrings(left, right []string) bool {
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

func containsService(services []string, fragment string) bool {
	for _, service := range services {
		if strings.Contains(service, fragment) {
			return true
		}
	}
	return false
}

func equalBytes(left, right []byte) bool {
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
