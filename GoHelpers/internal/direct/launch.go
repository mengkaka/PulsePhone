package direct

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"syscall"
	"time"
)

const (
	dvtServiceName              = "com.apple.instruments.remoteserver.DVTSecureSocketProxy"
	legacyPreparationGroupID    = "prep.legacy.developer.v2"
	launchStartingServicesPhase = "startingDeviceServices"
	launchResponseStage         = "dvtLaunchResponse"
)

type launchLockdown interface {
	StartService(name string) (net.Conn, error)
	Close()
}

type launchDTX interface {
	close() error
	handshake() error
	openChannel(identifier string) (int32, error)
	invoke(channel int32, method string, args ...any) (any, error)
}

type launchDependencies struct {
	openLockdown    func(udid string, deadline time.Time) (launchLockdown, error)
	lookupInstalled func(lockdown launchLockdown, bundleID string, deadline time.Time) (bool, error)
	newDTX          func(conn net.Conn, deadline time.Time) launchDTX
}

func launchApp(config OneShotConfig, payload map[string]any, deadline time.Time) (map[string]any, *OperationFailure) {
	return launchAppWithDependencies(config, payload, deadline, launchDependencies{
		openLockdown: func(udid string, deadline time.Time) (launchLockdown, error) {
			return OpenLockdown(udid, deadline)
		},
		lookupInstalled: func(lockdown launchLockdown, bundleID string, deadline time.Time) (bool, error) {
			return directLookupInstalled(lockdown, bundleID, deadline)
		},
		newDTX: func(conn net.Conn, deadline time.Time) launchDTX {
			return newDTXConnection(conn, deadline)
		},
	})
}

func launchAppWithDependencies(config OneShotConfig, payload map[string]any, deadline time.Time, dependencies launchDependencies) (map[string]any, *OperationFailure) {
	if !sameStringKeys(payload, "bundleID", "commandID", "operation") || payload["commandID"] != "app.launch" || payload["operation"] != "launch" {
		return nil, operationFailure("appLaunchFailed", "notCommitted", "failed", "requestValidation")
	}
	bundleID, ok := payload["bundleID"].(string)
	if !ok || !validBundleID(bundleID) {
		return nil, operationFailure("appLaunchFailed", "notCommitted", "failed", "requestValidation")
	}
	if launchDeadlineExceeded(nil, deadline) {
		return nil, launchDeadlineFailure()
	}
	lockdown, err := dependencies.openLockdown(config.RawTransportUDID, deadline)
	if err != nil {
		if launchDeadlineExceeded(err, deadline) {
			return nil, launchDeadlineFailure()
		}
		return nil, operationFailureFrom(err, "developerServicesUnavailable", "notCommitted", "failed", "installationProxyOpen")
	}
	defer lockdown.Close()
	installed, err := dependencies.lookupInstalled(lockdown, bundleID, deadline)
	if err != nil {
		if launchDeadlineExceeded(err, deadline) {
			return nil, launchDeadlineFailure()
		}
		return nil, operationFailureFrom(err, "appLaunchFailed", "notCommitted", "failed", "installationProxyLookup")
	}
	if !installed {
		return nil, operationFailure("appNotInstalled", "notCommitted", "failed", "installationProxyLookup")
	}
	serviceConn, err := lockdown.StartService(dvtServiceName)
	if err != nil {
		if launchDeadlineExceeded(err, deadline) {
			return nil, launchDeadlineFailure()
		}
		return nil, launchStartupFailure(err)
	}
	dtx := dependencies.newDTX(serviceConn, deadline)
	defer dtx.close()
	if err := dtx.handshake(); err != nil {
		if launchDeadlineExceeded(err, deadline) {
			return nil, launchDeadlineFailure()
		}
		return nil, launchStartupFailure(err)
	}
	channel, err := dtx.openChannel("com.apple.instruments.server.services.processcontrol")
	if err != nil {
		if launchDeadlineExceeded(err, deadline) {
			return nil, launchDeadlineFailure()
		}
		return nil, launchStartupFailure(err)
	}
	result, err := dtx.invoke(channel, "launchSuspendedProcessWithDevicePath:bundleIdentifier:environment:arguments:options:",
		"", bundleID, map[string]any{}, []any{}, map[string]any{
			"StartSuspendedKey": false,
			"KillExisting":      true,
		})
	if err != nil {
		if launchDeadlineExceeded(err, deadline) || launchOutcomeUnknown(err) {
			return nil, launchOutcomeUnknownFailure()
		}
		return nil, launchRejectedFailure()
	}
	pid := number(result)
	if pid <= 0 {
		return nil, launchRejectedFailure()
	}
	return map[string]any{
		"bundleID":        bundleID,
		"disposition":     "launchRequested",
		"resolvedRouteID": "legacy.dvtLaunch",
	}, nil
}

func launchDeadlineFailure() *OperationFailure {
	return operationFailure("executionTimeout", "notCommitted", "failed", "launchDeadline")
}

func launchDeadlineExceeded(err error, deadline time.Time) bool {
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

func launchStartupFailure(err error) *OperationFailure {
	var failure *Failure
	if errors.As(err, &failure) {
		switch failure.Code {
		case "deviceNotFound", "deviceDisconnected":
			return &OperationFailure{Code: "deviceDisconnected", CommitState: "notCommitted", Outcome: "failed"}
		case "deviceLocked", "deviceNotTrusted", "transportFailure":
			return &OperationFailure{Code: failure.Code, CommitState: "notCommitted", Outcome: "failed"}
		}
	}
	return &OperationFailure{
		Code:        "developerServicesUnavailable",
		CommitState: "notCommitted",
		Outcome:     "failed",
		Details: map[string]any{
			"phase":              launchStartingServicesPhase,
			"preparationGroupID": legacyPreparationGroupID,
		},
	}
}

func launchRejectedFailure() *OperationFailure {
	return operationFailure("appLaunchFailed", "notCommitted", "failed", launchResponseStage)
}

func launchOutcomeUnknownFailure() *OperationFailure {
	return operationFailure("outcomeUnknown", "unknown", "outcomeUnknown", launchResponseStage)
}

func launchOutcomeUnknown(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, io.EOF) || errors.Is(err, net.ErrClosed) || errors.Is(err, syscall.EPIPE) ||
		errors.Is(err, syscall.ECONNRESET) || errors.Is(err, syscall.ECONNABORTED) {
		return true
	}
	var networkError net.Error
	return errors.As(err, &networkError) && (networkError.Timeout() || networkError.Temporary())
}

func directLookupInstalled(lockdown interface {
	StartService(name string) (net.Conn, error)
}, bundleID string, deadline time.Time) (bool, error) {
	conn, err := lockdown.StartService(InstallationProxyService)
	if err != nil {
		return false, err
	}
	service := newPlistService(conn, deadline)
	defer service.close()
	if err := service.send(map[string]any{
		"ClientOptions": map[string]any{
			"BundleIDs":        []any{bundleID},
			"ReturnAttributes": []any{"CFBundleIdentifier"},
		},
		"Command": "Lookup",
	}); err != nil {
		return false, err
	}
	response, err := service.receive(maximumInstallationResponseLen)
	if err != nil {
		return false, err
	}
	installed, valid := lookupInstalled(response, bundleID)
	if !valid {
		return false, fmt.Errorf("invalid installation lookup")
	}
	return installed, nil
}
