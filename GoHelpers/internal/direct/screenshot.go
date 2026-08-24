package direct

import (
	"context"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

const (
	ScreenshotServiceName  = "com.apple.mobile.screenshotr"
	maximumScreenshotBytes = 64 * 1024 * 1024
)

var pngSignature = []byte{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a}

type screenshotService interface {
	receiveValue(maximum int) (any, error)
	sendValue(value any) error
}

type screenshotRouteService interface {
	screenshotService
	close()
}

type screenshotLockdown interface {
	StartService(name string) (net.Conn, error)
	Close()
}

type screenshotRouteDependencies struct {
	openLockdown func(udid string, deadline time.Time) (screenshotLockdown, error)
	newService   func(conn net.Conn, deadline time.Time) screenshotRouteService
}

func captureScreenshot(config OneShotConfig, payload map[string]any, deadline time.Time) (map[string]any, *OperationFailure) {
	return captureScreenshotWithDependencies(config, payload, deadline, screenshotRouteDependencies{
		openLockdown: func(udid string, deadline time.Time) (screenshotLockdown, error) {
			return OpenLockdown(udid, deadline)
		},
		newService: func(conn net.Conn, deadline time.Time) screenshotRouteService {
			return newPlistService(conn, deadline)
		},
	})
}

func captureScreenshotWithDependencies(config OneShotConfig, payload map[string]any, deadline time.Time, dependencies screenshotRouteDependencies) (map[string]any, *OperationFailure) {
	if !sameStringKeys(payload, "artifactID", "commandID", "operation", "reservationPath") {
		return nil, screenshotArtifactFailure("artifactValidationFailed", "reservation")
	}
	artifactID, artifactOK := payload["artifactID"].(string)
	commandID, commandOK := payload["commandID"].(string)
	operation, operationOK := payload["operation"].(string)
	reservationPath, pathOK := payload["reservationPath"].(string)
	if !artifactOK || !isUUID(artifactID) || !commandOK || !pathOK ||
		(commandID != "screenshot.cli" && commandID != "screenshot.gui") ||
		!operationOK || operation != "screenshot" || !validReservationPath(reservationPath, artifactID) {
		return nil, screenshotArtifactFailure("artifactValidationFailed", "reservation")
	}
	if screenshotDeadlineExceeded(nil, deadline) {
		return nil, screenshotDeadlineFailure()
	}

	lockdown, err := dependencies.openLockdown(config.RawTransportUDID, deadline)
	if err != nil {
		return nil, screenshotServiceFailure(err, deadline)
	}
	defer lockdown.Close()
	conn, err := lockdown.StartService(ScreenshotServiceName)
	if err != nil {
		return nil, screenshotServiceFailure(err, deadline)
	}
	service := dependencies.newService(conn, deadline)
	defer service.close()
	return captureScreenshotFromService(service, reservationPath, artifactID, deadline)
}

func captureScreenshotFromService(service screenshotService, reservationPath, artifactID string, deadline time.Time) (map[string]any, *OperationFailure) {
	if screenshotDeadlineExceeded(nil, deadline) {
		return nil, screenshotDeadlineFailure()
	}
	initial, err := service.receiveValue(64 * 1024)
	if err != nil {
		return nil, screenshotServiceFailure(err, deadline)
	}
	initialArray, ok := initial.([]any)
	if !ok || len(initialArray) < 3 {
		return nil, screenshotServiceUnavailableFailure()
	}
	if err := service.sendValue([]any{"DLMessageVersionExchange", "DLVersionsOk", initialArray[2]}); err != nil {
		return nil, screenshotServiceFailure(err, deadline)
	}
	ready, err := service.receiveValue(64 * 1024)
	if err != nil {
		return nil, screenshotServiceFailure(err, deadline)
	}
	readyArray, ok := ready.([]any)
	if !ok || len(readyArray) == 0 || readyArray[0] != "DLMessageDeviceReady" {
		return nil, screenshotServiceUnavailableFailure()
	}
	if err := service.sendValue([]any{"DLMessageProcessMessage", map[string]any{"MessageType": "ScreenShotRequest"}}); err != nil {
		return nil, screenshotServiceFailure(err, deadline)
	}
	response, err := service.receiveValue(maximumScreenshotBytes)
	if err != nil {
		return nil, screenshotServiceFailure(err, deadline)
	}
	responseArray, ok := response.([]any)
	if !ok || len(responseArray) != 2 || responseArray[0] != "DLMessageProcessMessage" {
		return nil, screenshotArtifactFailure("artifactValidationFailed", "formatConversion")
	}
	message, ok := responseArray[1].(map[string]any)
	if !ok || message["MessageType"] != "ScreenShotReply" {
		return nil, screenshotArtifactFailure("artifactValidationFailed", "formatConversion")
	}
	image, ok := message["ScreenShotData"].([]byte)
	if !ok {
		return nil, screenshotArtifactFailure("artifactValidationFailed", "formatConversion")
	}
	if len(image) > maximumScreenshotBytes {
		return nil, screenshotArtifactFailure("artifactTooLarge", "formatConversion")
	}
	format := DetectImageFormat(image)
	if format == "" {
		return nil, screenshotArtifactFailure("unsupportedScreenshotFormat", "formatConversion")
	}
	png, err := NormalizeImageToPNG(image, format)
	if err != nil {
		if errors.Is(err, errScreenshotTooLarge) {
			return nil, screenshotArtifactFailure("artifactTooLarge", "formatConversion")
		}
		return nil, screenshotArtifactFailure("artifactValidationFailed", "formatConversion")
	}
	if screenshotDeadlineExceeded(nil, deadline) {
		return nil, screenshotDeadlineFailure()
	}
	if err := writeReservedScreenshot(reservationPath, png); err != nil {
		return nil, screenshotArtifactFailure("artifactValidationFailed", "helperWrite")
	}
	if screenshotDeadlineExceeded(nil, deadline) {
		return nil, screenshotDeadlineFailure()
	}
	return map[string]any{"artifactID": artifactID, "byteCount": int64(len(png)), "format": "png"}, nil
}

func screenshotArtifactFailure(code, stage string) *OperationFailure {
	return &OperationFailure{
		Code:        code,
		CommitState: "notCommitted",
		Outcome:     "failed",
		Details:     map[string]any{"stage": stage},
	}
}

func screenshotDeadlineFailure() *OperationFailure {
	return operationFailure("executionTimeout", "notCommitted", "failed", "screenshotDeadline")
}

func screenshotServiceUnavailableFailure() *OperationFailure {
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

func screenshotServiceFailure(err error, deadline time.Time) *OperationFailure {
	if screenshotDeadlineExceeded(err, deadline) {
		return screenshotDeadlineFailure()
	}
	var failure *Failure
	if !errors.As(err, &failure) {
		return screenshotServiceUnavailableFailure()
	}
	switch failure.Code {
	case "deviceNotFound", "deviceDisconnected":
		return &OperationFailure{Code: "deviceDisconnected", CommitState: "notCommitted", Outcome: "failed"}
	case "deviceNotTrusted", "deviceLocked", "transportFailure":
		return &OperationFailure{Code: failure.Code, CommitState: "notCommitted", Outcome: "failed"}
	default:
		return screenshotServiceUnavailableFailure()
	}
}

func screenshotDeadlineExceeded(err error, deadline time.Time) bool {
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

func validReservationPath(value, artifactID string) bool {
	return value != "" && len(value) <= 4096 && strings.HasPrefix(value, "/") &&
		!strings.Contains(value, "\x00") && filepath.Clean(value) == value &&
		filepath.Base(value) == artifactID+".png"
}

func writeReservedScreenshot(path string, image []byte) error {
	fd, err := syscall.Open(path, syscall.O_WRONLY|syscall.O_CLOEXEC|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return err
	}
	file := os.NewFile(uintptr(fd), path)
	if file == nil {
		_ = syscall.Close(fd)
		return errors.New("reservation file")
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !validScreenshotReservation(info) {
		return errors.New("invalid reservation file")
	}
	if err := file.Truncate(0); err != nil {
		return err
	}
	written := 0
	for written < len(image) {
		count, err := file.Write(image[written:])
		if err != nil {
			return err
		}
		if count == 0 {
			return fmt.Errorf("short reservation write")
		}
		written += count
	}
	return file.Sync()
}

func validScreenshotReservation(info os.FileInfo) bool {
	if !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 ||
		info.Mode()&(os.ModeSetuid|os.ModeSetgid|os.ModeSticky) != 0 || info.Size() != 0 {
		return false
	}
	metadata, ok := info.Sys().(*syscall.Stat_t)
	return ok && metadata.Uid == uint32(os.Geteuid()) && metadata.Nlink == 1
}
