package direct

import (
	"context"
	"errors"
	"io"
	"net"
	"os"
	"syscall"
	"time"
)

const (
	AFCServiceName                 = "com.apple.afc"
	maximumAppListResultBytes      = 256 * 1024
	appLaunchDeadline              = time.Minute
	installDeadline                = 30 * time.Minute
	uninstallDeadline              = 5 * time.Minute
	installationResponseGrace      = 5 * time.Second
	maximumInstallationResponses   = 10_000
	maximumInstallationResponseLen = 64 * 1024
	remoteStagingDirectory         = "/PublicStaging/PulsePhone"
)

type OperationFailure struct {
	Code        string
	CommitState string
	Outcome     string
	Stage       string
	Details     map[string]any
}

func (e *OperationFailure) Error() string { return e.Code }

type installRouteSource interface {
	io.ReaderAt
	BundleID() string
	Close() error
	Size() int64
	VerifyUnchanged() error
}

type installRouteAFC interface {
	Close() error
	CloseFile(handle uint64) error
	Exists(path string) (bool, error)
	MakeDir(path string) error
	Remove(path string) error
	Upload(path string, source io.ReaderAt, size int64) (uint64, error)
}

type installRouteService interface {
	close()
	receive(maximum int) (map[string]any, error)
	send(value map[string]any) error
	setDeadline(deadline time.Time)
}

type installRouteLockdown interface {
	Close()
	StartService(name string) (net.Conn, error)
}

type installDependencies struct {
	newAFC       func(conn net.Conn, deadline time.Time) installRouteAFC
	newService   func(conn net.Conn, deadline time.Time) installRouteService
	openIPA      func(path string) (installRouteSource, error)
	openLockdown func(udid string, deadline time.Time) (installRouteLockdown, error)
}

func installApp(config OneShotConfig, requestID string, payload map[string]any, deadline time.Time) (map[string]any, *OperationFailure) {
	return installAppWithDependencies(config, requestID, payload, deadline, installDependencies{
		newAFC: func(conn net.Conn, deadline time.Time) installRouteAFC {
			return NewAFCClient(conn, deadline)
		},
		newService: func(conn net.Conn, deadline time.Time) installRouteService {
			return newPlistService(conn, deadline)
		},
		openIPA: func(path string) (installRouteSource, error) {
			return OpenIPA(path)
		},
		openLockdown: func(udid string, deadline time.Time) (installRouteLockdown, error) {
			return OpenLockdown(udid, deadline)
		},
	})
}

func installAppWithDependencies(config OneShotConfig, requestID string, payload map[string]any, deadline time.Time, dependencies installDependencies) (map[string]any, *OperationFailure) {
	if !sameStringKeys(payload, "ipaPath", "operation") || payload["operation"] != "install" {
		return nil, operationFailure("invalidIPA", "notCommitted", "failed", "archivePreflight")
	}
	path, ok := payload["ipaPath"].(string)
	if !ok {
		return nil, operationFailure("invalidIPA", "notCommitted", "failed", "archivePreflight")
	}
	if requestID == "" {
		return nil, operationFailure("installFailed", "notCommitted", "failed", "requestValidation")
	}
	source, err := dependencies.openIPA(path)
	if err != nil {
		return nil, operationFailure("invalidIPA", "notCommitted", "failed", "archivePreflight")
	}
	defer source.Close()

	lockdown, err := dependencies.openLockdown(config.RawTransportUDID, deadline)
	if err != nil {
		return nil, installFailure("notCommitted", "serviceOpen")
	}
	defer lockdown.Close()
	afcConn, err := lockdown.StartService(AFCServiceName)
	if err != nil {
		return nil, installFailure("notCommitted", "serviceOpen")
	}
	afc := dependencies.newAFC(afcConn, deadline)
	defer afc.Close()
	exists, err := afc.Exists(remoteStagingDirectory)
	if err != nil {
		return nil, installFailure("notCommitted", "afcOpen")
	}
	if !exists {
		if err := afc.MakeDir(remoteStagingDirectory); err != nil {
			return nil, installFailure("notCommitted", "afcOpen")
		}
	}
	remotePath := remoteStagingDirectory + "/" + requestID + ".ipa"
	defer func() { _ = afc.Remove(remotePath) }()
	handle, err := afc.Upload(remotePath, source, source.Size())
	if err != nil {
		return nil, installFailure("notCommitted", "afcUpload")
	}
	if err := afc.CloseFile(handle); err != nil {
		return nil, installFailure("notCommitted", "afcFinalize")
	}
	if err := source.VerifyUnchanged(); err != nil {
		return nil, operationFailure("invalidIPA", "notCommitted", "failed", "archiveReadRace")
	}
	installConn, err := lockdown.StartService(InstallationProxyService)
	if err != nil {
		return nil, installFailure("notCommitted", "serviceOpen")
	}
	service := dependencies.newService(installConn, deadline)
	defer service.close()
	responseDeadline := installationResponseDeadline(deadline)
	service.setDeadline(responseDeadline)
	if !time.Now().Before(responseDeadline) {
		return nil, installFailure("notCommitted", "installationProxyRequest")
	}
	if err := service.send(map[string]any{
		"ClientOptions": map[string]any{},
		"Command":       "Install",
		"PackagePath":   remotePath,
	}); err != nil {
		return nil, installationOutcomeUnknown()
	}
	for index := 0; index < maximumInstallationResponses; index++ {
		response, err := service.receive(maximumInstallationResponseLen)
		if err != nil {
			return nil, committedUnknownFailure(err, "installationProxyResponse")
		}
		if response["Error"] != nil {
			return nil, installFailure("committed", "installationProxyResponse")
		}
		if response["Status"] == "Complete" {
			return map[string]any{"bundleID": source.BundleID(), "disposition": "installed"}, nil
		}
	}
	return nil, committedUnknownFailure(errors.New("installation response count"), "installationProxyResponse")
}

type uninstallRouteService interface {
	send(value map[string]any) error
	receive(maximum int) (map[string]any, error)
	close()
	setDeadline(deadline time.Time)
}

type uninstallRouteLockdown interface {
	StartService(name string) (net.Conn, error)
	Close()
}

type uninstallDependencies struct {
	openLockdown func(udid string, deadline time.Time) (uninstallRouteLockdown, error)
	newService   func(conn net.Conn, deadline time.Time) uninstallRouteService
}

func uninstallApp(config OneShotConfig, payload map[string]any, deadline time.Time) (map[string]any, *OperationFailure) {
	return uninstallAppWithDependencies(config, payload, deadline, uninstallDependencies{
		openLockdown: func(udid string, deadline time.Time) (uninstallRouteLockdown, error) {
			return OpenLockdown(udid, deadline)
		},
		newService: func(conn net.Conn, deadline time.Time) uninstallRouteService {
			return newPlistService(conn, deadline)
		},
	})
}

func uninstallAppWithDependencies(config OneShotConfig, payload map[string]any, deadline time.Time, dependencies uninstallDependencies) (map[string]any, *OperationFailure) {
	if !sameStringKeys(payload, "bundleID", "operation") || payload["operation"] != "uninstall" {
		return nil, operationFailure("uninstallFailed", "notCommitted", "failed", "requestValidation")
	}
	bundleID, ok := payload["bundleID"].(string)
	if !ok || !validBundleID(bundleID) {
		return nil, operationFailure("uninstallFailed", "notCommitted", "failed", "requestValidation")
	}
	if uninstallDeadlineExceeded(nil, deadline) {
		return nil, uninstallFailure("notCommitted", "uninstallDeadline")
	}
	lockdown, err := dependencies.openLockdown(config.RawTransportUDID, deadline)
	if err != nil {
		if uninstallDeadlineExceeded(err, deadline) {
			return nil, uninstallFailure("notCommitted", "uninstallDeadline")
		}
		return nil, uninstallFailure("notCommitted", "serviceOpen")
	}
	defer lockdown.Close()
	conn, err := lockdown.StartService(InstallationProxyService)
	if err != nil {
		if uninstallDeadlineExceeded(err, deadline) {
			return nil, uninstallFailure("notCommitted", "uninstallDeadline")
		}
		return nil, uninstallFailure("notCommitted", "serviceOpen")
	}
	service := dependencies.newService(conn, deadline)
	defer service.close()
	if err := service.send(map[string]any{
		"ClientOptions": map[string]any{
			"BundleIDs":        []any{bundleID},
			"ReturnAttributes": []any{"CFBundleIdentifier"},
		},
		"Command": "Lookup",
	}); err != nil {
		if uninstallDeadlineExceeded(err, deadline) {
			return nil, uninstallFailure("notCommitted", "uninstallDeadline")
		}
		return nil, uninstallFailure("notCommitted", "installationProxyLookup")
	}
	lookup, err := service.receive(maximumInstallationResponseLen)
	if err != nil {
		if uninstallDeadlineExceeded(err, deadline) {
			return nil, uninstallFailure("notCommitted", "uninstallDeadline")
		}
		return nil, uninstallFailure("notCommitted", "installationProxyLookup")
	}
	installed, valid := lookupInstalled(lookup, bundleID)
	if !valid {
		return nil, uninstallFailure("notCommitted", "installationProxyLookup")
	}
	if !installed {
		return nil, operationFailure("appNotInstalled", "notCommitted", "failed", "installationProxyLookup")
	}
	responseDeadline := installationResponseDeadline(deadline)
	service.setDeadline(responseDeadline)
	if !time.Now().Before(responseDeadline) {
		return nil, uninstallFailure("notCommitted", "installationProxyRequest")
	}
	if err := service.send(map[string]any{
		"ApplicationIdentifier": bundleID,
		"ClientOptions":         map[string]any{},
		"Command":               "Uninstall",
	}); err != nil {
		return nil, installationOutcomeUnknown()
	}
	for index := 0; index < maximumInstallationResponses; index++ {
		response, err := service.receive(maximumInstallationResponseLen)
		if err != nil {
			return nil, committedUnknownFailure(err, "installationProxyResponse")
		}
		if response["Error"] != nil {
			return nil, uninstallFailure("committed", "installationProxyResponse")
		}
		if response["Status"] == "Complete" {
			return map[string]any{"bundleID": bundleID, "disposition": "uninstalled"}, nil
		}
	}
	return nil, committedUnknownFailure(errors.New("uninstallation response count"), "installationProxyResponse")
}

func uninstallDeadlineExceeded(err error, deadline time.Time) bool {
	if !deadline.IsZero() && !time.Now().Before(deadline) {
		return true
	}
	if err == nil {
		return false
	}
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, os.ErrDeadlineExceeded) || errors.Is(err, syscall.ETIMEDOUT) {
		return true
	}
	var networkError net.Error
	return errors.As(err, &networkError) && networkError.Timeout()
}

func lookupInstalled(response map[string]any, bundleID string) (bool, bool) {
	if response["Error"] != nil {
		return false, false
	}
	lookup, exists := response["LookupResult"]
	if !exists || lookup == nil {
		return false, true
	}
	values, ok := lookup.(map[string]any)
	if !ok {
		return false, false
	}
	metadata, exists := values[bundleID]
	if !exists {
		return false, true
	}
	metadataMap, ok := metadata.(map[string]any)
	if !ok || metadataMap["CFBundleIdentifier"] != bundleID {
		return false, false
	}
	return true, true
}

func sameStringKeys(value map[string]any, keys ...string) bool {
	if len(value) != len(keys) {
		return false
	}
	for _, key := range keys {
		if _, ok := value[key]; !ok {
			return false
		}
	}
	return true
}

func operationFailure(code, commitState, outcome, stage string) *OperationFailure {
	details := map[string]any{"commitState": commitState, "stage": stage}
	if outcome == "outcomeUnknown" {
		details = map[string]any{"reason": "commitStateUnknown"}
	}
	return &OperationFailure{Code: code, CommitState: commitState, Outcome: outcome, Stage: stage, Details: details}
}

func installFailure(commitState, stage string) *OperationFailure {
	return operationFailure("installFailed", commitState, "failed", stage)
}

func uninstallFailure(commitState, stage string) *OperationFailure {
	return operationFailure("uninstallFailed", commitState, "failed", stage)
}

func operationFailureFrom(err error, code, commitState, outcome, stage string) *OperationFailure {
	var failure *Failure
	if errors.As(err, &failure) && failure.Code != "" {
		code = failure.Code
	}
	return operationFailure(code, commitState, outcome, stage)
}

func committedUnknownFailure(_ error, stage string) *OperationFailure {
	return installationOutcomeUnknown()
}

func installationOutcomeUnknown() *OperationFailure {
	return operationFailure("outcomeUnknown", "unknown", "outcomeUnknown", "")
}

func installationResponseDeadline(deadline time.Time) time.Time {
	graceDeadline := deadline.Add(-installationResponseGrace)
	if graceDeadline.After(time.Now()) {
		return graceDeadline
	}
	return deadline
}
