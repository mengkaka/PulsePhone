package main

import (
	"bufio"
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"testing"
	"time"

	"pulsephone/GoHelpers/internal/coredevice"
	"pulsephone/GoHelpers/internal/helperapp"
	"pulsephone/GoHelpers/internal/protocol"
)

func TestCoreDeviceRequestFailureMatchesPythonProductProjection(t *testing.T) {
	timing := map[string]any{
		"captureMicroseconds":      int64(7),
		"queueWaitMicroseconds":    int64(3),
		"serviceCloseMicroseconds": int64(0),
		"serviceOpenMicroseconds":  int64(1),
		"totalMicroseconds":        int64(11),
	}
	attempts := []any{map[string]any{
		"errorCode": "developerServicesUnavailable",
		"provider":  "dvt",
		"stage":     "dvtScreenshotCaptureOrValidate",
		"status":    "failed",
		"timings":   timing,
	}}
	result := coreDeviceRequestFailure(&coredevice.ProductError{
		Code:      "outcomeUnknown",
		Committed: true,
		Details: map[string]any{
			"_pulsephoneCaptureAttempts": attempts,
			"_pulsephoneInternalTiming":  timing,
		},
		OutcomeUnknown: true,
		Stage:          "orientation",
	})
	if result.ErrorCode != "outcomeUnknown" || !result.Committed || !result.OutcomeUnknown {
		t.Fatalf("result = %#v", result)
	}
	if result.ErrorDetails["phase"] != "executingProductRoute" || result.ErrorDetails["preparationGroupID"] != coredevice.PreparationGroupID || result.ErrorDetails["stage"] != "orientation" {
		t.Fatalf("details = %#v", result.ErrorDetails)
	}
	if !reflect.DeepEqual(result.ErrorDetails["_pulsephoneCaptureAttempts"], attempts) || !reflect.DeepEqual(result.ErrorDetails["_pulsephoneInternalTiming"], timing) {
		t.Fatalf("product evidence details = %#v", result.ErrorDetails)
	}

	generic := coreDeviceRequestFailure(errors.New("tunnel open"))
	if generic.ErrorCode != "developerServicesUnavailable" || generic.ErrorDetails["phase"] != "startingDeviceServices" || generic.ErrorDetails["preparationGroupID"] != coredevice.PreparationGroupID {
		t.Fatalf("generic = %#v", generic)
	}
}

func TestCoreDevicePasteboardSetFailureUsesRegisteredPublicError(t *testing.T) {
	result := coreDeviceRequestFailure(&coredevice.ProductError{Code: "internalFailure"})
	if result.ErrorCode != "internalFailure" || result.Committed || result.OutcomeUnknown {
		t.Fatalf("result = %#v", result)
	}
	if result.ErrorDetails["phase"] != "executingProductRoute" || result.ErrorDetails["preparationGroupID"] != coredevice.PreparationGroupID {
		t.Fatalf("details = %#v", result.ErrorDetails)
	}
	if _, exists := result.ErrorDetails["stage"]; exists {
		t.Fatalf("pasteboard SET failure unexpectedly exposes a stage: %#v", result.ErrorDetails)
	}
}

func TestCoreDeviceAppLaunchFailureUsesLegacyPublicProjection(t *testing.T) {
	result := coreDeviceRequestFailure(&coredevice.ProductError{Code: "appLaunchFailed"})
	if result.ErrorCode != "appLaunchFailed" || result.Committed || result.OutcomeUnknown {
		t.Fatalf("result = %#v", result)
	}
	if result.ErrorDetails["phase"] != "executingProductRoute" || result.ErrorDetails["preparationGroupID"] != coredevice.PreparationGroupID {
		t.Fatalf("details = %#v", result.ErrorDetails)
	}
	if _, exists := result.ErrorDetails["stage"]; exists {
		t.Fatalf("app launch failure unexpectedly exposes a stage: %#v", result.ErrorDetails)
	}
}

func TestCoreDeviceStreamFailureMatchesPythonStreamProjection(t *testing.T) {
	result := coreDeviceStreamFailure(&coredevice.ProductError{
		Code:  "invalidArgument",
		Stage: "openingInputService",
	})
	if result == nil || result.ErrorCode != "invalidArgument" {
		t.Fatalf("result = %#v", result)
	}
	if result.ErrorDetails["phase"] != "openingInputService" || result.ErrorDetails["preparationGroupID"] != coredevice.PreparationGroupID {
		t.Fatalf("details = %#v", result.ErrorDetails)
	}
	if _, exists := result.ErrorDetails["stage"]; exists {
		t.Fatalf("stream details unexpectedly contain stage: %#v", result.ErrorDetails)
	}
}

func TestCoreDeviceHelperProjectsInjectedStartupFailurePhase(t *testing.T) {
	for _, test := range []struct {
		name       string
		openTunnel func(*startupFailureEvents) coredevice.TunnelOpener
		wantEvents []string
		wantPhase  string
	}{
		{
			name: "tunnel",
			openTunnel: func(*startupFailureEvents) coredevice.TunnelOpener {
				return func(context.Context, string) (coredevice.TunnelLease, error) {
					return nil, errors.New("tunnel open failed")
				}
			},
			wantPhase: "openingTunnel",
		},
		{
			name: "services",
			openTunnel: func(events *startupFailureEvents) coredevice.TunnelOpener {
				return func(context.Context, string) (coredevice.TunnelLease, error) {
					return &startupFailureTunnel{events: events, failService: true}, nil
				}
			},
			wantEvents: []string{"service.open:service.appControl", "tunnel.close"},
			wantPhase:  "startingDeviceServices",
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			var events startupFailureEvents
			var input bytes.Buffer
			writeCoreDeviceStartupFixtureInput(t, &input)
			var output bytes.Buffer
			status := runWith(coreDeviceStartupFixtureArguments(), &input, &output, io.Discard, func() (string, error) {
				return "1.000002", nil
			}, func(runtimeEpoch, executorGeneration uint64, rawTransportUDID string, connectionEpoch uint64, serviceNames map[string]string) (coreDeviceBackend, error) {
				return coredevice.NewBackendForRuntimeWithTunnelOpener(runtimeEpoch, executorGeneration, rawTransportUDID, connectionEpoch, serviceNames, test.openTunnel(&events))
			})
			if status != 0 {
				t.Fatalf("status = %d", status)
			}
			results := coreDeviceResults(t, output.Bytes())
			if len(results) != 1 {
				t.Fatalf("results = %#v", results)
			}
			errorValue, ok := results[0]["error"].(map[string]any)
			if !ok || errorValue["code"] != "developerServicesUnavailable" {
				t.Fatalf("result = %#v", results[0])
			}
			details, ok := errorValue["details"].(map[string]any)
			if !ok || details["phase"] != test.wantPhase || details["preparationGroupID"] != coredevice.PreparationGroupID {
				t.Fatalf("details = %#v", errorValue["details"])
			}
			if !reflect.DeepEqual([]string(events), test.wantEvents) {
				t.Fatalf("events = %#v, want %#v", events, test.wantEvents)
			}
		})
	}
}

func TestCoreDeviceHelperReturnsFailureAfterTerminalResultWhenBackendCloseFails(t *testing.T) {
	var input bytes.Buffer
	writeCoreDeviceFixtureInput(t, &input, map[string]any{
		"executorGeneration": int64(3), "manifestHash": strings.Repeat("a", 64),
		"messageID": "00000000-0000-0000-0000-000000000001", "runtimeEpoch": int64(7), "schemaVersion": int64(1), "type": "HelloAccepted",
	})
	writeCoreDeviceFixtureInput(t, &input, map[string]any{
		"executorGeneration": int64(3), "messageID": "00000000-0000-0000-0000-000000000002",
		"payload": map[string]any{
			"actionID": "00000000-0000-0000-0000-000000000003", "backendPayload": map[string]any{"operation": "screenshot"}, "executorOperationID": "coredevice.screenshot",
		}, "requestID": "00000000-0000-0000-0000-000000000004", "runtimeEpoch": int64(7), "schemaVersion": int64(1), "type": "Request",
	})
	backend := &terminalCloseFailureBackend{}
	var output bytes.Buffer
	status := runWith(coreDeviceStartupFixtureArguments(), &input, &output, io.Discard, func() (string, error) {
		return "1.000002", nil
	}, func(uint64, uint64, string, uint64, map[string]string) (coreDeviceBackend, error) {
		return backend, nil
	})
	if status != 2 || backend.closeCalls != 1 {
		t.Fatalf("status=%d closeCalls=%d", status, backend.closeCalls)
	}
	results := coreDeviceResults(t, output.Bytes())
	if len(results) != 1 {
		t.Fatalf("results = %#v", results)
	}
	errorValue, ok := results[0]["error"].(map[string]any)
	if !ok || errorValue["code"] != "developerServicesUnavailable" {
		t.Fatalf("result = %#v", results[0])
	}
	details, ok := errorValue["details"].(map[string]any)
	if !ok || details["stage"] != "screenshotServiceOpen" || details["phase"] != "executingProductRoute" {
		t.Fatalf("details = %#v", errorValue["details"])
	}
}

type terminalCloseFailureBackend struct {
	closeCalls int
}

func (backend *terminalCloseFailureBackend) Execute(protocol.Message) (map[string]any, error) {
	return nil, &coredevice.ProductError{
		Code: "developerServicesUnavailable", RetireGeneration: true, Stage: "screenshotServiceOpen",
	}
}

func (backend *terminalCloseFailureBackend) OpenStream(protocol.Message, time.Time) error { return nil }

func (backend *terminalCloseFailureBackend) SendFrame(protocol.Message, time.Time) error { return nil }

func (backend *terminalCloseFailureBackend) CloseStream(protocol.Message, time.Time) error {
	return nil
}

func (backend *terminalCloseFailureBackend) Close() error {
	backend.closeCalls++
	return errors.New("product close failed")
}

type startupFailureEvents []string

type startupFailureTunnel struct {
	events      *startupFailureEvents
	failService bool
}

func (t *startupFailureTunnel) ServiceStarter() coredevice.ServiceStarter {
	return func(name string) (coredevice.Closable, error) {
		*t.events = append(*t.events, "service.open:"+name)
		if t.failService {
			return nil, errors.New("service open failed")
		}
		return startupFailureCloser{}, nil
	}
}

func (t *startupFailureTunnel) Close() error {
	*t.events = append(*t.events, "tunnel.close")
	return nil
}

type startupFailureCloser struct{}

func (startupFailureCloser) Close() error { return nil }

func coreDeviceStartupFixtureArguments() []string {
	arguments := []string{
		"--runtime-epoch", "7",
		"--connection-epoch", "8",
		"--executor-generation", "3",
		"--raw-transport-udid", "test-device",
		"--helper-build-id", "pulsephone.coredevice-helper.v1",
		"--manifest-hash", strings.Repeat("a", 64),
	}
	for _, facet := range coredevice.SupportedFacets {
		arguments = append(arguments, "--facet-service", facet+"=service."+facet)
	}
	return arguments
}

func writeCoreDeviceStartupFixtureInput(t *testing.T, writer io.Writer) {
	t.Helper()
	writeCoreDeviceFixtureInput(t, writer, map[string]any{
		"executorGeneration": int64(3), "manifestHash": strings.Repeat("a", 64),
		"messageID": "00000000-0000-0000-0000-000000000001", "runtimeEpoch": int64(7), "schemaVersion": int64(1), "type": "HelloAccepted",
	})
	writeCoreDeviceFixtureInput(t, writer, map[string]any{
		"deliveryAttemptID": "00000000-0000-0000-0000-000000000002", "executorGeneration": int64(3),
		"messageID": "00000000-0000-0000-0000-000000000003", "payload": map[string]any{
			"actionID": "00000000-0000-0000-0000-000000000004", "interactionID": "00000000-0000-0000-0000-000000000005",
			"streamKind": "pointer", "streamPayload": map[string]any{"routeID": "coredevice.pointerStream"},
		}, "runtimeEpoch": int64(7), "schemaVersion": int64(1), "sessionID": "00000000-0000-0000-0000-000000000006", "type": "StreamOpen",
	})
	writeCoreDeviceFixtureInput(t, writer, map[string]any{
		"executorGeneration": int64(3), "messageID": "00000000-0000-0000-0000-000000000007",
		"payload": map[string]any{
			"actionID": "00000000-0000-0000-0000-000000000008", "backendPayload": map[string]any{"operation": "barrier"}, "executorOperationID": "coredevice.barrier",
		}, "requestID": "00000000-0000-0000-0000-000000000009", "runtimeEpoch": int64(7), "schemaVersion": int64(1), "type": "Request",
	})
	writeCoreDeviceFixtureInput(t, writer, map[string]any{
		"executorGeneration": int64(3), "messageID": "00000000-0000-0000-0000-00000000000a",
		"payload": map[string]any{}, "runtimeEpoch": int64(7), "schemaVersion": int64(1), "type": "Shutdown",
	})
}

func TestCoreDevicePreparationSuccessRemainsNotCommitted(t *testing.T) {
	for name, backendPayload := range map[string]map[string]any{
		"warm generation": {"operation": "warmGeneration"},
		"barrier":         {"operation": "barrier"},
		"personalized": {
			"catalogRevision": "catalog.test.v1",
			"operation":       "mount",
		},
	} {
		t.Run(name, func(t *testing.T) {
			message := protocol.Message{Payload: map[string]any{"backendPayload": backendPayload}}
			result := coreDeviceRequestResult(message, map[string]any{"disposition": "ready"}, nil)
			if result.CommitState != "notCommitted" {
				t.Fatalf("commit state = %q", result.CommitState)
			}
		})
	}

	product := protocol.Message{Payload: map[string]any{"backendPayload": map[string]any{"operation": "normalTouch"}}}
	if got := coreDeviceRequestCommitState(product); got != "committed" {
		t.Fatalf("product commit state = %q", got)
	}
}

func TestCoreDeviceScreenshotRetirementMarkerStaysInsideHelper(t *testing.T) {
	value := map[string]any{
		"_pulsephoneRetireGenerationAfterResult": true,
		"captureProvider":                        "coreDevice",
		"generationDisposition":                  "retiringAfterResult",
	}
	message := protocol.Message{Payload: map[string]any{
		"backendPayload": map[string]any{},
	}}
	result := coreDeviceRequestResult(message, value, nil)
	if !result.ExitAfterResult {
		t.Fatal("fallback result did not exit after the terminal result")
	}
	if _, exists := result.Value["_pulsephoneRetireGenerationAfterResult"]; exists {
		t.Fatalf("internal retirement marker leaked onto HelperWire: %#v", result.Value)
	}
	if result.Value["generationDisposition"] != "retiringAfterResult" {
		t.Fatalf("runtime retirement disposition missing: %#v", result.Value)
	}
	if value["_pulsephoneRetireGenerationAfterResult"] != true {
		t.Fatalf("request result mutated backend value: %#v", value)
	}
}

func TestRealDeviceHelperWireTouchSequenceSmoke(t *testing.T) {
	udid := os.Getenv("PULSEPHONE_REAL_DEVICE_UDID")
	if udid == "" || os.Getenv("PULSEPHONE_REAL_DEVICE_HELPER_WIRE_TOUCH_SMOKE") != "1" {
		t.Skip("set PULSEPHONE_REAL_DEVICE_UDID and PULSEPHONE_REAL_DEVICE_HELPER_WIRE_TOUCH_SMOKE=1 to run the HelperWire physical-device smoke")
	}

	contextValue, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	helperPath := filepath.Join(t.TempDir(), "PulsePhoneCoreDeviceHelper")
	build := exec.CommandContext(contextValue, "go", "build", "-o", helperPath, ".")
	if output, err := build.CombinedOutput(); err != nil {
		t.Fatalf("build CoreDevice helper: %v\n%s", err, output)
	}

	arguments := []string{
		"--runtime-epoch", "7",
		"--connection-epoch", "1",
		"--executor-generation", "3",
		"--raw-transport-udid", udid,
		"--helper-build-id", "pulsephone.coredevice-helper.v1",
		"--manifest-hash", strings.Repeat("a", 64),
	}
	for facet, service := range map[string]string{
		"appControl":  "com.apple.coredevice.appservice",
		"button":      "com.apple.coredevice.hid.indigo",
		"hid":         "com.apple.coredevice.hid.universalhidservice",
		"keyboard":    "com.apple.coredevice.hid.universalhidservice",
		"orientation": "com.apple.coredevice.devicecontrol",
		"pasteboard":  "com.apple.coredevice.pasteboardservice",
		"screenshot":  "com.apple.coredevice.screencaptureservice",
	} {
		arguments = append(arguments, "--facet-service", facet+"="+service)
	}
	command := exec.CommandContext(contextValue, helperPath, arguments...)
	input, err := command.StdinPipe()
	if err != nil {
		t.Fatal(err)
	}
	output, err := command.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer
	command.Stderr = &stderr
	if err := command.Start(); err != nil {
		t.Fatalf("start CoreDevice helper: %v", err)
	}
	defer func() {
		_ = input.Close()
		if t.Failed() && command.Process != nil {
			_ = command.Process.Kill()
		}
		if err := command.Wait(); err != nil && contextValue.Err() == nil && !t.Failed() {
			t.Errorf("CoreDevice helper exit: %v\n%s", err, stderr.String())
		}
	}()

	session := newHelperWireTouchSmokeSession(t, input, output)
	session.handshake(strings.Repeat("a", 64))
	session.request("coredevice.warmGeneration", map[string]any{
		"operation":            "warmGeneration",
		"preparationAttemptID": "00000000-0000-4000-8000-000000000001",
		"preparationGroupID":   coredevice.PreparationGroupID,
	})
	session.request("coredevice.button.home", map[string]any{"commandID": "button.home"})
	for index := 0; index < 3; index++ {
		session.request("coredevice.normalTouch", helperWireLinearTouchFrames(9830, 32768, 55705, 32768, 300))
	}
	session.request("coredevice.normalTouch", helperWireLinearTouchFrames(55705, 32768, 9830, 32768, 300))

	artifactID := "33333333-3333-4333-8333-333333333333"
	reservation := filepath.Join(t.TempDir(), artifactID+".png")
	file, err := os.OpenFile(reservation, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	session.request("coredevice.screenshot", map[string]any{
		"artifactID": artifactID, "reservationPath": reservation,
	})
	info, err := os.Stat(reservation)
	if err != nil || info.Size() == 0 {
		t.Fatalf("screenshot reservation: info=%#v err=%v", info, err)
	}

	session.request("coredevice.normalTouch", helperWireLinearTouchFrames(32768, 32768, 32768, 32768, 35))
	session.request("coredevice.normalTouch", helperWireLinearTouchFrames(22937, 39321, 42598, 39321, 200))
	session.request("coredevice.normalTouch", helperWireLinearTouchFrames(32768, 49151, 32768, 22937, 200))
	session.shutdown()
}

type helperWireTouchSmokeSession struct {
	input   io.Writer
	machine *protocol.WireMachine
	nextID  uint64
	reader  *bufio.Reader
	t       *testing.T
}

func newHelperWireTouchSmokeSession(t *testing.T, input io.Writer, output io.Reader) *helperWireTouchSmokeSession {
	return &helperWireTouchSmokeSession{
		input: input, machine: protocol.NewWireMachine(7, 3), reader: bufio.NewReaderSize(output, protocol.MaxHelperLineBytes+1), t: t,
	}
}

func (session *helperWireTouchSmokeSession) handshake(manifestHash string) {
	session.t.Helper()
	hello := session.receive(15 * time.Second)
	if hello.Type != "Hello" || hello.Fields["manifestHash"] != manifestHash {
		session.t.Fatalf("helper hello = %#v", hello)
	}
	session.send("HelloAccepted", nil, map[string]any{"manifestHash": manifestHash})
	ready := session.receive(15 * time.Second)
	if ready.Type != "Ready" {
		session.t.Fatalf("helper ready = %#v", ready)
	}
}

func (session *helperWireTouchSmokeSession) request(route string, backendPayload map[string]any) {
	session.t.Helper()
	requestID := session.uuid()
	session.send("Request", &requestID, map[string]any{
		"payload": map[string]any{
			"actionID":            session.uuid(),
			"backendPayload":      backendPayload,
			"executorOperationID": route,
		},
	})
	accepted := false
	started := false
	for {
		message := session.receive(15 * time.Second)
		if message.RequestID == nil || *message.RequestID != requestID {
			session.t.Fatalf("%s received request mismatch: %#v", route, message)
		}
		switch message.Type {
		case "Accepted":
			accepted = true
		case "Started":
			started = true
		case "Result":
			if !accepted || !started {
				session.t.Fatalf("%s terminal before accepted/started: %#v", route, message)
			}
			result, ok := message.Payload["result"].(map[string]any)
			if !ok || result["outcome"] != "succeeded" {
				session.t.Fatalf("%s result = %#v", route, message.Payload)
			}
			return
		default:
			session.t.Fatalf("%s unexpected helper message: %#v", route, message)
		}
	}
}

func (session *helperWireTouchSmokeSession) shutdown() {
	session.t.Helper()
	session.send("Shutdown", nil, map[string]any{"payload": map[string]any{"reason": "testComplete"}})
}

func (session *helperWireTouchSmokeSession) send(kind string, requestID *string, additional map[string]any) {
	session.t.Helper()
	fields := map[string]any{
		"executorGeneration": int64(3),
		"messageID":          session.uuid(),
		"runtimeEpoch":       int64(7),
		"schemaVersion":      int64(1),
		"type":               kind,
	}
	if requestID != nil {
		fields["requestID"] = *requestID
	}
	for key, value := range additional {
		fields[key] = value
	}
	raw, err := protocol.EncodeLine(fields, protocol.RuntimeToHelper)
	if err != nil {
		session.t.Fatalf("encode %s: %v", kind, err)
	}
	message, err := protocol.DecodeLine(raw, protocol.RuntimeToHelper)
	if err != nil {
		session.t.Fatalf("decode %s: %v", kind, err)
	}
	if err := session.machine.Receive(message, protocol.RuntimeToHelper); err != nil {
		session.t.Fatalf("receive %s: %v", kind, err)
	}
	if _, err := session.input.Write(raw); err != nil {
		session.t.Fatalf("write %s: %v", kind, err)
	}
}

func (session *helperWireTouchSmokeSession) receive(timeout time.Duration) protocol.Message {
	session.t.Helper()
	type response struct {
		message protocol.Message
		err     error
	}
	responses := make(chan response, 1)
	go func() {
		raw, err := protocol.ReadHelperLine(session.reader)
		if err != nil {
			responses <- response{err: err}
			return
		}
		message, err := protocol.DecodeLine(raw, protocol.HelperToRuntime)
		responses <- response{message: message, err: err}
	}()
	select {
	case response := <-responses:
		if response.err != nil {
			session.t.Fatalf("read helper response: %v", response.err)
		}
		if err := session.machine.Receive(response.message, protocol.HelperToRuntime); err != nil {
			session.t.Fatalf("receive helper response: %v", err)
		}
		return response.message
	case <-time.After(timeout):
		session.t.Fatalf("helper response timed out after %s", timeout)
		return protocol.Message{}
	}
}

func (session *helperWireTouchSmokeSession) uuid() string {
	session.nextID++
	return fmt.Sprintf("f0000000-0000-4000-8000-%012x", session.nextID)
}

func helperWireLinearTouchFrames(fromX, fromY, toX, toY uint64, duration uint64) map[string]any {
	interpolate := func(from, to, elapsed uint64) uint64 {
		if elapsed == 0 || from == to {
			return from
		}
		if elapsed == duration {
			return to
		}
		if to > from {
			return from + ((to-from)*elapsed+duration/2)/duration
		}
		return from - ((from-to)*elapsed+duration/2)/duration
	}
	intervalCount := (duration-1)/16 + 1
	frames := make([]any, 0, intervalCount+1)
	for index := uint64(0); index <= intervalCount; index++ {
		elapsed := index * 16
		kind := "move"
		if index == 0 {
			kind = "begin"
		} else if index == intervalCount {
			elapsed = duration
			kind = "end"
		}
		frames = append(frames, map[string]any{
			"elapsedMs": elapsed,
			"kind":      kind,
			"x":         interpolate(fromX, toX, elapsed),
			"y":         interpolate(fromY, toY, elapsed),
		})
	}
	return map[string]any{"frames": frames}
}

type coreDeviceErrorProjectionFixture struct {
	Cases         []coreDeviceErrorProjectionCase `json:"cases"`
	SchemaVersion int                             `json:"schemaVersion"`
}

type coreDeviceErrorProjectionCase struct {
	Error          coreDeviceErrorProjectionInput `json:"error"`
	ExpectedResult map[string]any                 `json:"expectedResult"`
	Mode           string                         `json:"mode"`
	Name           string                         `json:"name"`
}

type coreDeviceErrorProjectionInput struct {
	Code             string `json:"code"`
	Committed        bool   `json:"committed"`
	Kind             string `json:"kind"`
	OutcomeUnknown   bool   `json:"outcomeUnknown"`
	Phase            string `json:"phase"`
	RetireGeneration bool   `json:"retireGeneration"`
	Stage            string `json:"stage"`
}

func TestCoreDeviceErrorProjectionSharedFixture(t *testing.T) {
	_, sourceFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate test source")
	}
	path := filepath.Join(filepath.Dir(sourceFile), "..", "..", "..", "Fixtures", "helper-wire", "coredevice-error-projection.v1.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read shared fixture: %v", err)
	}
	var fixture coreDeviceErrorProjectionFixture
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatalf("decode shared fixture: %v", err)
	}
	if fixture.SchemaVersion != 1 || len(fixture.Cases) == 0 {
		t.Fatal("invalid shared fixture")
	}

	for _, item := range fixture.Cases {
		item := item
		t.Run(item.Name, func(t *testing.T) {
			result, status, types := runCoreDeviceProjectionFixture(t, item)
			wantStatus := map[bool]int{true: 1, false: 0}[(item.Mode == "oneShot" && (item.Error.Kind == "generic" || item.Error.RetireGeneration)) ||
				item.Mode == "screenshotRetirementSuccess"]
			if status != wantStatus {
				t.Fatalf("status = %d, want %d", status, wantStatus)
			}
			if want := []string{"Hello", "Ready", "Accepted", "Started", "Result"}; !reflect.DeepEqual(types, want) {
				t.Fatalf("message types = %#v, want %#v", types, want)
			}
			if !reflect.DeepEqual(result, item.ExpectedResult) {
				t.Fatalf("result = %#v, want %#v", result, item.ExpectedResult)
			}
		})
	}
}

func TestCoreDeviceHelperKeepsRunningAfterNonTerminalFailure(t *testing.T) {
	for _, test := range []struct {
		name           string
		backendPayload map[string]any
		failure        helperapp.RequestResult
		wantCode       string
		wantPhase      string
		wantStage      string
	}{
		{
			name:           "product failure",
			backendPayload: map[string]any{"operation": "button"},
			failure: coreDeviceRequestFailure(&coredevice.ProductError{
				Code: "backendFailed", Committed: true, Stage: "pasteboardReadBack",
			}),
			wantCode: "backendFailed", wantPhase: "executingProductRoute", wantStage: "pasteboardReadBack",
		},
		{
			name: "personalization TSS failure",
			backendPayload: map[string]any{
				"assetContentManifestSHA256": strings.Repeat("a", 64),
				"catalogCanonicalSHA256":     strings.Repeat("b", 64),
				"catalogRevision":            "2026-08-22.1",
				"deviceContext":              map[string]any{"connectionEpoch": int64(8)},
				"fileRoles":                  []any{"personalized.buildManifest", "personalized.image", "personalized.trustCache"},
				"operation":                  "requestTSS",
				"preparationAttemptID":       "00000000-0000-0000-0000-000000000008",
				"preparationGroupID":         coredevice.PreparationGroupID,
			},
			failure: coreDeviceRequestFailure(&coredevice.ProductError{
				Code: "personalizationServiceUnavailable", Phase: "personalizationTSS",
			}),
			wantCode: "personalizationServiceUnavailable", wantPhase: "personalizationTSS",
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			var input bytes.Buffer
			writeCoreDeviceFixtureInput(t, &input, map[string]any{
				"executorGeneration": int64(3), "manifestHash": strings.Repeat("a", 64),
				"messageID": "00000000-0000-0000-0000-000000000001", "runtimeEpoch": int64(7), "schemaVersion": int64(1), "type": "HelloAccepted",
			})
			for index, requestID := range []string{"00000000-0000-0000-0000-000000000003", "00000000-0000-0000-0000-000000000005"} {
				writeCoreDeviceFixtureInput(t, &input, map[string]any{
					"executorGeneration": int64(3), "messageID": fmt.Sprintf("00000000-0000-0000-0000-%012d", index+2),
					"payload": map[string]any{
						"actionID": "00000000-0000-0000-0000-000000000006", "backendPayload": test.backendPayload, "executorOperationID": "coredevice.fixture",
					},
					"requestID": requestID, "runtimeEpoch": int64(7), "schemaVersion": int64(1), "type": "Request",
				})
			}
			writeCoreDeviceFixtureInput(t, &input, map[string]any{
				"executorGeneration": int64(3), "messageID": "00000000-0000-0000-0000-000000000007",
				"payload": map[string]any{}, "runtimeEpoch": int64(7), "schemaVersion": int64(1), "type": "Shutdown",
			})

			calls := 0
			closed := 0
			var output bytes.Buffer
			status := helperapp.RunSession(&input, &output, helperapp.Config{
				RuntimeEpoch: 7, ExecutorGeneration: 3, HelperBuildID: "pulsephone.coredevice-helper.v1", HelperKind: "coreDevice",
				ManifestHash: strings.Repeat("a", 64), ProcessStartIdentity: "1.000002",
				HandleRequest: func(message protocol.Message) helperapp.RequestResult {
					calls++
					if calls == 1 {
						return test.failure
					}
					return coreDeviceRequestResult(message, map[string]any{"disposition": "ready"}, nil)
				},
				Close: func() error {
					closed++
					return nil
				},
			})
			if status != 0 || calls != 2 || closed != 1 {
				t.Fatalf("status=%d calls=%d closed=%d", status, calls, closed)
			}
			results := coreDeviceResults(t, output.Bytes())
			if len(results) != 2 {
				t.Fatalf("results = %#v", results)
			}
			first := results[0]
			errorValue, ok := first["error"].(map[string]any)
			if !ok || errorValue["code"] != test.wantCode || first["outcome"] != "failed" {
				t.Fatalf("first result = %#v", first)
			}
			details, ok := errorValue["details"].(map[string]any)
			if !ok || details["phase"] != test.wantPhase {
				t.Fatalf("failure details = %#v", errorValue["details"])
			}
			if test.wantStage == "" {
				if _, exists := details["stage"]; exists {
					t.Fatalf("unexpected failure stage = %#v", details)
				}
			} else if details["stage"] != test.wantStage {
				t.Fatalf("failure stage = %#v", details)
			}
			if results[1]["outcome"] != "succeeded" || results[1]["value"].(map[string]any)["disposition"] != "ready" {
				t.Fatalf("second result = %#v", results[1])
			}
		})
	}
}

func TestCoreDeviceHelperRetiresAfterFailureWithTiming(t *testing.T) {
	var input bytes.Buffer
	writeCoreDeviceFixtureInput(t, &input, map[string]any{
		"executorGeneration": int64(3), "manifestHash": strings.Repeat("a", 64),
		"messageID": "00000000-0000-0000-0000-000000000001", "runtimeEpoch": int64(7), "schemaVersion": int64(1), "type": "HelloAccepted",
	})
	writeCoreDeviceFixtureInput(t, &input, map[string]any{
		"executorGeneration": int64(3), "messageID": "00000000-0000-0000-0000-000000000002",
		"payload": map[string]any{
			"actionID": "00000000-0000-0000-0000-000000000003", "backendPayload": map[string]any{"operation": "screenshot"}, "executorOperationID": "coredevice.screenshot",
		},
		"requestID": "00000000-0000-0000-0000-000000000004", "runtimeEpoch": int64(7), "schemaVersion": int64(1), "type": "Request",
	})
	closed := 0
	var output bytes.Buffer
	status := helperapp.RunSession(&input, &output, helperapp.Config{
		RuntimeEpoch: 7, ExecutorGeneration: 3, HelperBuildID: "pulsephone.coredevice-helper.v1", HelperKind: "coreDevice",
		ManifestHash: strings.Repeat("a", 64), ProcessStartIdentity: "1.000002",
		HandleRequest: func(protocol.Message) helperapp.RequestResult {
			return coreDeviceRequestFailure(&coredevice.ProductError{
				Code: "developerServicesUnavailable", RetireGeneration: true, Stage: "screenshotCaptureOrValidate",
				Details: map[string]any{"_pulsephoneInternalTiming": map[string]any{"totalMicroseconds": int64(15)}},
			})
		},
		Close: func() error {
			closed++
			return nil
		},
	})
	if status != 1 || closed != 1 {
		t.Fatalf("status=%d closed=%d", status, closed)
	}
	types := coreDeviceOutputTypes(t, output.Bytes())
	if want := []string{"Hello", "Ready", "Accepted", "Started", "Result"}; !reflect.DeepEqual(types, want) {
		t.Fatalf("types = %#v, want %#v", types, want)
	}
	results := coreDeviceResults(t, output.Bytes())
	if len(results) != 1 {
		t.Fatalf("results = %#v", results)
	}
	result := results[0]
	errorValue, ok := result["error"].(map[string]any)
	if !ok || errorValue["code"] != "developerServicesUnavailable" || result["commitState"] != "notCommitted" || result["outcome"] != "failed" {
		t.Fatalf("result = %#v", result)
	}
	details, ok := errorValue["details"].(map[string]any)
	if !ok || details["stage"] != "screenshotCaptureOrValidate" || details["_pulsephoneInternalTiming"].(map[string]any)["totalMicroseconds"] != int64(15) {
		t.Fatalf("details = %#v", errorValue["details"])
	}
}

func coreDeviceResults(t *testing.T, output []byte) []map[string]any {
	t.Helper()
	lines := bytes.Split(bytes.TrimSuffix(output, []byte{'\n'}), []byte{'\n'})
	results := make([]map[string]any, 0, len(lines))
	for _, line := range lines {
		message, err := protocol.DecodeLine(append(line, '\n'), protocol.HelperToRuntime)
		if err != nil {
			t.Fatal(err)
		}
		if message.Type != "Result" {
			continue
		}
		result, ok := message.Payload["result"].(map[string]any)
		if !ok {
			t.Fatalf("result = %#v", message.Payload)
		}
		results = append(results, result)
	}
	return results
}

func coreDeviceOutputTypes(t *testing.T, output []byte) []string {
	t.Helper()
	lines := bytes.Split(bytes.TrimSuffix(output, []byte{'\n'}), []byte{'\n'})
	types := make([]string, 0, len(lines))
	for _, line := range lines {
		message, err := protocol.DecodeLine(append(line, '\n'), protocol.HelperToRuntime)
		if err != nil {
			t.Fatal(err)
		}
		types = append(types, message.Type)
	}
	return types
}

func runCoreDeviceProjectionFixture(t *testing.T, item coreDeviceErrorProjectionCase) (map[string]any, int, []string) {
	t.Helper()
	requestError := coreDeviceFixtureError(item.Error)
	backendPayload := map[string]any{"operation": "unsupported"}
	if item.Mode == "streamBarrier" {
		backendPayload = map[string]any{"operation": "barrier"}
	} else if item.Mode == "personalizedSuccess" {
		backendPayload = map[string]any{
			"assetContentManifestSHA256": strings.Repeat("a", 64),
			"catalogCanonicalSHA256":     strings.Repeat("b", 64),
			"catalogRevision":            "2026-08-22.1",
			"deviceContext":              map[string]any{"connectionEpoch": int64(8)},
			"fileRoles":                  []any{"personalized.buildManifest", "personalized.image", "personalized.trustCache"},
			"operation":                  "mount",
			"preparationAttemptID":       "00000000-0000-0000-0000-000000000008",
			"preparationGroupID":         coredevice.PreparationGroupID,
		}
	}
	var input bytes.Buffer
	writeCoreDeviceFixtureInput(t, &input, map[string]any{
		"executorGeneration": int64(3),
		"manifestHash":       strings.Repeat("a", 64),
		"messageID":          "00000000-0000-0000-0000-000000000001",
		"runtimeEpoch":       int64(7),
		"schemaVersion":      int64(1),
		"type":               "HelloAccepted",
	})
	if item.Mode == "streamBarrier" {
		writeCoreDeviceFixtureInput(t, &input, map[string]any{
			"deliveryAttemptID":  "delivery-1",
			"executorGeneration": int64(3),
			"messageID":          "00000000-0000-0000-0000-000000000002",
			"payload":            map[string]any{"streamPayload": map[string]any{"routeID": "coredevice.pointerStream"}},
			"runtimeEpoch":       int64(7),
			"schemaVersion":      int64(1),
			"sessionID":          "00000000-0000-0000-0000-000000000003",
			"type":               "StreamOpen",
		})
	}
	writeCoreDeviceFixtureInput(t, &input, map[string]any{
		"executorGeneration": int64(3),
		"messageID":          "00000000-0000-0000-0000-000000000004",
		"payload": map[string]any{
			"actionID":            "00000000-0000-0000-0000-000000000005",
			"backendPayload":      backendPayload,
			"executorOperationID": "coredevice.fixture",
		},
		"requestID":     "00000000-0000-0000-0000-000000000006",
		"runtimeEpoch":  int64(7),
		"schemaVersion": int64(1),
		"type":          "Request",
	})
	writeCoreDeviceFixtureInput(t, &input, map[string]any{
		"executorGeneration": int64(3),
		"messageID":          "00000000-0000-0000-0000-000000000007",
		"payload":            map[string]any{},
		"runtimeEpoch":       int64(7),
		"schemaVersion":      int64(1),
		"type":               "Shutdown",
	})

	var output bytes.Buffer
	closeCalls := 0
	status := helperapp.RunSession(&input, &output, helperapp.Config{
		RuntimeEpoch:         7,
		ExecutorGeneration:   3,
		HelperBuildID:        "pulsephone.coredevice-helper.v1",
		HelperKind:           "coreDevice",
		ManifestHash:         strings.Repeat("a", 64),
		ProcessStartIdentity: "1.000002",
		HandleRequest: func(message protocol.Message) helperapp.RequestResult {
			if item.Mode == "personalizedSuccess" {
				return coreDeviceRequestResult(message, map[string]any{"disposition": "ready"}, nil)
			}
			if item.Mode == "screenshotRetirementSuccess" {
				return coreDeviceRequestResult(message, map[string]any{
					"_pulsephoneRetireGenerationAfterResult": true,
					"captureProvider":                        "coreDevice",
					"generationDisposition":                  "retiringAfterResult",
				}, nil)
			}
			return coreDeviceRequestFailure(requestError)
		},
		HandleStreamOpen: func(protocol.Message) *helperapp.RequestResult {
			if item.Mode != "streamBarrier" {
				return nil
			}
			return coreDeviceStreamFailure(requestError)
		},
		Close: func() error {
			closeCalls++
			return nil
		},
	})
	if status == 1 && closeCalls != 1 {
		t.Fatalf("terminal exit closed %d times, want 1", closeCalls)
	}

	rawMessages := bytes.Split(bytes.TrimSuffix(output.Bytes(), []byte{'\n'}), []byte{'\n'})
	types := make([]string, 0, len(rawMessages))
	var terminal map[string]any
	for index, raw := range rawMessages {
		message, err := protocol.DecodeLine(append(raw, '\n'), protocol.HelperToRuntime)
		if err != nil {
			t.Fatalf("message %d: %v", index, err)
		}
		types = append(types, message.Type)
		if message.Type == "Result" {
			terminal, _ = message.Payload["result"].(map[string]any)
		}
	}
	if terminal == nil {
		t.Fatalf("missing terminal result: %q", output.String())
	}
	return terminal, status, types
}

func coreDeviceFixtureError(input coreDeviceErrorProjectionInput) error {
	if input.Kind == "generic" {
		return errors.New("fixture generic failure")
	}
	return &coredevice.ProductError{
		Code:             input.Code,
		Committed:        input.Committed,
		OutcomeUnknown:   input.OutcomeUnknown,
		Phase:            input.Phase,
		RetireGeneration: input.RetireGeneration,
		Stage:            input.Stage,
	}
}

func writeCoreDeviceFixtureInput(t *testing.T, writer io.Writer, fields map[string]any) {
	t.Helper()
	raw, err := protocol.EncodeLine(fields, protocol.RuntimeToHelper)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write(raw); err != nil {
		t.Fatal(err)
	}
}
