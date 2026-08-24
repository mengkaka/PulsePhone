package direct

import (
	"bufio"
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"sort"
	"syscall"
	"time"

	"pulsephone/GoHelpers/internal/protocol"
)

type OneShotConfig struct {
	RuntimeEpoch         uint64
	ConnectionEpoch      uint64
	ExecutorGeneration   uint64
	RawTransportUDID     string
	HelperBuildID        string
	ManifestHash         string
	ProcessStartIdentity string
}

func RunOneShot(stdin io.Reader, stdout io.Writer, config OneShotConfig) int {
	return runOneShotWithRoute(stdin, stdout, config, directRoute)
}

type oneShotRoute func(config OneShotConfig, request protocol.Message) (map[string]any, int)

func runOneShotWithRoute(stdin io.Reader, stdout io.Writer, config OneShotConfig, route oneShotRoute) int {
	machine := protocol.NewWireMachine(config.RuntimeEpoch, config.ExecutorGeneration)
	base := func(kind string) map[string]any {
		return map[string]any{"executorGeneration": config.ExecutorGeneration, "messageID": newUUID(), "runtimeEpoch": config.RuntimeEpoch, "schemaVersion": int64(1), "type": kind}
	}
	send := func(fields map[string]any) error {
		raw, err := protocol.EncodeLine(fields, protocol.HelperToRuntime)
		if err != nil {
			return err
		}
		message, err := protocol.DecodeLine(raw, protocol.HelperToRuntime)
		if err != nil {
			return err
		}
		if err := machine.Receive(message, protocol.HelperToRuntime); err != nil {
			return err
		}
		_, err = stdout.Write(raw)
		return err
	}
	hello := base("Hello")
	hello["helperBuildID"] = config.HelperBuildID
	hello["helperKind"] = "direct"
	hello["manifestHash"] = config.ManifestHash
	hello["processStartIdentity"] = config.ProcessStartIdentity
	if err := send(hello); err != nil {
		return 2
	}
	reader := bufio.NewReaderSize(stdin, protocol.MaxHelperLineBytes+1)
	receive := func() (protocol.Message, error) {
		raw, err := protocol.ReadHelperLine(reader)
		if err != nil {
			return protocol.Message{}, err
		}
		message, err := protocol.DecodeLine(raw, protocol.RuntimeToHelper)
		if err != nil {
			return protocol.Message{}, err
		}
		if err := machine.Receive(message, protocol.RuntimeToHelper); err != nil {
			return protocol.Message{}, err
		}
		return message, nil
	}
	helloAccepted, err := receive()
	if err != nil || helloAccepted.Type != "HelloAccepted" || helloAccepted.Fields["manifestHash"] != config.ManifestHash {
		return 2
	}
	ready := base("Ready")
	ready["payload"] = map[string]any{"facets": []any{"afc", "installationProxy", "lockdown", "mobileImageMounter"}}
	if err := send(ready); err != nil {
		return 2
	}
	request, err := receive()
	if err != nil || request.Type != "Request" || request.RequestID == nil {
		return 2
	}
	requestID := *request.RequestID
	requestAccepted := base("Accepted")
	requestAccepted["requestID"] = requestID
	if err := send(requestAccepted); err != nil {
		return 2
	}
	started := base("Started")
	started["requestID"] = requestID
	if err := send(started); err != nil {
		return 2
	}
	result, status := route(config, request)
	response := base("Result")
	response["requestID"] = requestID
	response["payload"] = map[string]any{"fallbackDisposition": "terminal", "result": result}
	if err := send(response); err != nil {
		return 2
	}
	return status
}

func directRoute(config OneShotConfig, request protocol.Message) (map[string]any, int) {
	backend, ok := request.Payload["backendPayload"].(map[string]any)
	if !ok {
		return failureResult("backendFailed", "requestValidation"), 1
	}
	operation, _ := backend["operation"].(string)
	if preparationGroup, _ := backend["preparationGroupID"].(string); preparationGroup == classicPreparationGroup {
		value, failure := classicRoute(config, backend, classicOperationDeadline(operation, time.Now()))
		if failure != nil {
			return operationFailureResult(failure), 1
		}
		return successResult(value, "notCommitted"), 0
	}
	deadline := directOperationDeadline(operation, time.Now())
	switch operation {
	case "install":
		value, failure := installApp(config, optionalRequestID(request), backend, deadline)
		if failure != nil {
			return operationFailureResult(failure), 1
		}
		return successResult(value, "committed"), 0
	case "uninstall":
		value, failure := uninstallApp(config, backend, deadline)
		if failure != nil {
			return operationFailureResult(failure), 1
		}
		return successResult(value, "committed"), 0
	case "screenshot":
		value, failure := captureScreenshot(config, backend, deadline)
		if failure != nil {
			return operationFailureResult(failure), 1
		}
		return successResult(value, "notCommitted"), 0
	case "browse":
		if !sameStringKeys(backend, "operation") || backend["operation"] != "browse" {
			return failureResult("backendFailed", "browseValidate"), 1
		}
		value, failure := browseApps(config.RawTransportUDID, deadline)
		if failure != nil {
			stage := "browse"
			if failure.Details != nil {
				if detailStage, ok := failure.Details["stage"].(string); ok && detailStage != "" {
					stage = detailStage
				}
			}
			return failureResult(failure.Code, stage), 1
		}
		return successResult(value, "notCommitted"), 0
	case "launch":
		value, failure := launchApp(config, backend, deadline)
		if failure != nil {
			return operationFailureResult(failure), 1
		}
		return successResult(value, "committed"), 0
	case "queryMounted":
		value, failure := queryMounted(config.RawTransportUDID, deadline)
		if failure != nil {
			return failureResult(failure.Code, "queryMounted"), 1
		}
		return successResult(value, "notCommitted"), 0
	default:
		return failureResult("capabilityUnavailable", "directDispatcher"), 1
	}
}

func directOperationDeadline(operation string, now time.Time) time.Time {
	duration := 30 * time.Second
	switch operation {
	case "install":
		duration = installDeadline
	case "uninstall":
		duration = uninstallDeadline
	case "launch":
		duration = appLaunchDeadline
	}
	return now.Add(duration)
}

func optionalRequestID(request protocol.Message) string {
	if request.RequestID == nil {
		return ""
	}
	return *request.RequestID
}

func operationFailureResult(failure *OperationFailure) map[string]any {
	errorValue := map[string]any{"code": failure.Code}
	if failure.Details != nil {
		errorValue["details"] = failure.Details
	}
	result := map[string]any{"error": errorValue, "outcome": failure.Outcome}
	if failure.CommitState != "" {
		result["commitState"] = failure.CommitState
	}
	return result
}

func successResult(value map[string]any, commitState string) map[string]any {
	return map[string]any{"commitState": commitState, "outcome": "succeeded", "value": value}
}
func failureResult(code, stage string) map[string]any {
	return map[string]any{"commitState": "notCommitted", "error": map[string]any{"code": code, "details": map[string]any{"commitState": "notCommitted", "stage": stage}}, "outcome": "failed"}
}

type browseRouteService interface {
	send(value map[string]any) error
	receive(maximum int) (map[string]any, error)
	close()
}

type browseRouteLockdown interface {
	StartService(name string) (net.Conn, error)
	Close()
}

type browseRouteDependencies struct {
	openLockdown func(udid string, deadline time.Time) (browseRouteLockdown, error)
	newService   func(conn net.Conn, deadline time.Time) browseRouteService
}

func browseApps(udid string, deadline time.Time) (map[string]any, *Failure) {
	return browseAppsWithDependencies(udid, deadline, browseRouteDependencies{
		openLockdown: func(udid string, deadline time.Time) (browseRouteLockdown, error) {
			return OpenLockdown(udid, deadline)
		},
		newService: func(conn net.Conn, deadline time.Time) browseRouteService {
			return newPlistService(conn, deadline)
		},
	})
}

func browseAppsWithDependencies(udid string, deadline time.Time, dependencies browseRouteDependencies) (map[string]any, *Failure) {
	if browseDeadlineExceeded(nil, deadline) {
		return nil, browseDeadlineFailure()
	}
	lockdown, err := dependencies.openLockdown(udid, deadline)
	if err != nil {
		return nil, browseRouteFailure(err, "serviceOpen", deadline)
	}
	defer lockdown.Close()
	conn, err := lockdown.StartService(InstallationProxyService)
	if err != nil {
		return nil, browseRouteFailure(err, "serviceOpen", deadline)
	}
	service := dependencies.newService(conn, deadline)
	defer service.close()
	if err := service.send(map[string]any{"ClientOptions": map[string]any{"ApplicationType": "Any", "ReturnAttributes": []any{"CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "CFBundleShortVersionString", "ApplicationType", "CFBundlePackageType", "SBAppTags"}}, "Command": "Browse"}); err != nil {
		return nil, browseRouteFailure(err, "browseSend", deadline)
	}
	projection := newBrowseProjection()
	for {
		response, err := service.receive(1024 * 1024)
		if err != nil {
			return nil, browseRouteFailure(err, "browseReceive", deadline)
		}
		complete, failure := projection.consume(response)
		if failure != nil {
			return nil, failure
		}
		if complete {
			break
		}
	}
	return projection.result()
}

func browseDeadlineFailure() *Failure {
	return &Failure{Code: "executionTimeout", Details: map[string]any{"stage": "browseDeadline"}}
}

func browseRouteFailure(err error, stage string, deadline time.Time) *Failure {
	if browseDeadlineExceeded(err, deadline) {
		return browseDeadlineFailure()
	}
	var failure *Failure
	if errors.As(err, &failure) {
		switch failure.Code {
		case "deviceNotFound", "deviceDisconnected":
			return &Failure{Code: "deviceDisconnected", Details: map[string]any{"stage": stage}}
		case "deviceNotTrusted", "deviceLocked", "transportFailure":
			return &Failure{Code: failure.Code, Details: map[string]any{"stage": stage}}
		}
	}
	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) || errors.Is(err, net.ErrClosed) ||
		errors.Is(err, syscall.EPIPE) || errors.Is(err, syscall.ECONNRESET) || errors.Is(err, syscall.ECONNABORTED) {
		return &Failure{Code: "transportFailure", Details: map[string]any{"stage": stage}}
	}
	var networkError net.Error
	if errors.As(err, &networkError) {
		return &Failure{Code: "transportFailure", Details: map[string]any{"stage": stage}}
	}
	return &Failure{Code: "backendFailed", Details: map[string]any{"stage": stage}}
}

func browseDeadlineExceeded(err error, deadline time.Time) bool {
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

type browseProjection struct {
	apps []any
	seen map[string]struct{}
}

func newBrowseProjection() *browseProjection {
	return &browseProjection{apps: []any{}, seen: map[string]struct{}{}}
}

func (projection *browseProjection) consume(response map[string]any) (bool, *Failure) {
	return consumeBrowsePage(response, &projection.apps, projection.seen)
}

func (projection *browseProjection) result() (map[string]any, *Failure) {
	sort.Slice(projection.apps, func(left, right int) bool {
		return projection.apps[left].(map[string]any)["bundleID"].(string) < projection.apps[right].(map[string]any)["bundleID"].(string)
	})
	result := map[string]any{"apps": projection.apps, "truncated": false}
	if err := validateAppListResult(result); err != nil {
		return nil, err
	}
	return result, nil
}

func consumeBrowsePage(response map[string]any, apps *[]any, seen map[string]struct{}) (bool, *Failure) {
	if response["Error"] != nil {
		return false, &Failure{Code: "backendFailed", Details: map[string]any{"stage": "browseReceive"}}
	}
	currentList, hasCurrentList := response["CurrentList"]
	if hasCurrentList {
		list, ok := currentList.([]any)
		if !ok {
			return false, &Failure{Code: "backendFailed", Details: map[string]any{"stage": "browseValidate"}}
		}
		for _, raw := range list {
			item, valid := raw.(map[string]any)
			if !valid {
				return false, &Failure{Code: "backendFailed", Details: map[string]any{"stage": "browseValidate"}}
			}
			normalized, failure := normalizeApp(item, seen)
			if failure != nil {
				if failure.Details == nil {
					failure.Details = map[string]any{"stage": "browseValidate"}
				}
				return false, failure
			}
			if normalized != nil {
				*apps = append(*apps, normalized)
			}
		}
	}
	status := ""
	if rawStatus, exists := response["Status"]; exists {
		var ok bool
		status, ok = rawStatus.(string)
		if !ok {
			return false, &Failure{Code: "backendFailed", Details: map[string]any{"stage": "browseValidate"}}
		}
	}
	if status == "Complete" {
		return true, nil
	}
	if !hasCurrentList {
		return false, &Failure{Code: "backendFailed", Details: map[string]any{"stage": "browseValidate"}}
	}
	return false, nil
}

func validateAppListResult(result map[string]any) *Failure {
	encoded, err := protocol.EncodeValue(result, false)
	if err != nil || len(encoded) > maximumAppListResultBytes {
		return &Failure{Code: "backendFailed", Details: map[string]any{"stage": "resultNormalize"}}
	}
	return nil
}

func normalizeApp(item map[string]any, seen map[string]struct{}) (map[string]any, *Failure) {
	bundleID, ok := item["CFBundleIdentifier"].(string)
	if !ok || len(bundleID) == 0 || len(bundleID) > 255 {
		return nil, &Failure{Code: "backendFailed"}
	}
	if _, exists := seen[bundleID]; exists {
		return nil, &Failure{Code: "backendFailed"}
	}
	seen[bundleID] = struct{}{}
	packageType, _ := item["CFBundlePackageType"].(string)
	if raw, exists := item["CFBundlePackageType"]; exists {
		if _, ok := raw.(string); !ok {
			return nil, &Failure{Code: "backendFailed"}
		}
	}
	if packageType != "APPL" {
		return nil, nil
	}
	if raw, exists := item["SBAppTags"]; exists {
		tags, ok := raw.([]any)
		if !ok {
			return nil, &Failure{Code: "backendFailed"}
		}
		hidden := false
		for _, tag := range tags {
			if _, ok := tag.(string); !ok {
				return nil, &Failure{Code: "backendFailed"}
			}
			if tag == "hidden" {
				hidden = true
			}
		}
		if hidden {
			return nil, nil
		}
	}
	for _, key := range []string{"CFBundleDisplayName", "CFBundleName", "CFBundleShortVersionString", "ApplicationType"} {
		if raw, exists := item[key]; exists {
			if _, ok := raw.(string); !ok {
				return nil, &Failure{Code: "backendFailed"}
			}
		}
	}
	result := map[string]any{"applicationType": "unknown", "bundleID": bundleID}
	if item["ApplicationType"] == "System" {
		result["applicationType"] = "system"
	}
	if item["ApplicationType"] == "User" {
		result["applicationType"] = "user"
	}
	if value, ok := item["CFBundleDisplayName"].(string); ok && value != "" {
		result["displayName"] = value
	} else if value, ok := item["CFBundleName"].(string); ok && value != "" {
		result["displayName"] = value
	}
	if value, ok := item["CFBundleShortVersionString"].(string); ok && value != "" {
		result["version"] = value
	}
	return result, nil
}

func queryMounted(udid string, deadline time.Time) (map[string]any, *Failure) {
	lockdown, err := OpenLockdown(udid, deadline)
	if err != nil {
		return nil, asFailure(err, "deviceDisconnected")
	}
	defer lockdown.Close()
	conn, err := lockdown.StartService(MobileImageMounterService)
	if err != nil {
		return nil, asFailure(err, "developerServicesUnavailable")
	}
	service := newPlistService(conn, deadline)
	defer service.close()
	if err := service.send(map[string]any{"Command": "LookupImage", "ImageType": "Developer"}); err != nil {
		return nil, asFailure(err, "queryMounted")
	}
	response, err := service.receive(64 * 1024)
	if err != nil {
		return nil, asFailure(err, "queryMounted")
	}
	return projectMountedDeveloperImage(response)
}

func projectMountedDeveloperImage(response map[string]any) (map[string]any, *Failure) {
	present, _, err := classicMountedImage(response)
	if err != nil {
		return nil, asFailure(err, "queryMounted")
	}
	return map[string]any{"imageType": "Developer", "mounted": present}, nil
}

func newUUID() string {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "00000000-0000-4000-8000-000000000000"
	}
	value[6] = (value[6] & 0x0f) | 0x40
	value[8] = (value[8] & 0x3f) | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x", value[0:4], value[4:6], value[6:8], value[8:10], value[10:16])
}
