package helperapp

import (
	"bufio"
	"bytes"
	"io"
	"math"
	"strings"
	"testing"

	"pulsephone/GoHelpers/internal/protocol"
)

func TestUnsupportedSessionProcessHandshake(t *testing.T) {
	inputReader, inputWriter := io.Pipe()
	var output bytes.Buffer
	status := make(chan int, 1)
	go func() {
		status <- RunSession(inputReader, &output, Config{
			RuntimeEpoch: 1, ExecutorGeneration: 2, HelperBuildID: "build",
			HelperKind: "direct", ManifestHash: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
			ProcessStartIdentity: "pid:1", Facets: []any{"lockdown"},
		})
	}()

	write := func(fields map[string]any) {
		raw, err := protocol.EncodeLine(fields, protocol.RuntimeToHelper)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := inputWriter.Write(raw); err != nil {
			t.Fatal(err)
		}
	}
	write(map[string]any{"executorGeneration": int64(2), "manifestHash": "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", "messageID": "00000000-0000-0000-0000-000000000001", "runtimeEpoch": int64(1), "schemaVersion": int64(1), "type": "HelloAccepted"})
	requestID := "00000000-0000-0000-0000-000000000002"
	write(map[string]any{"executorGeneration": int64(2), "messageID": "00000000-0000-0000-0000-000000000003", "payload": map[string]any{"actionID": "00000000-0000-0000-0000-000000000004", "backendPayload": map[string]any{"operation": "barrier"}, "executorOperationID": "barrier"}, "requestID": requestID, "runtimeEpoch": int64(1), "schemaVersion": int64(1), "type": "Request"})
	write(map[string]any{"executorGeneration": int64(2), "messageID": "00000000-0000-0000-0000-000000000005", "payload": map[string]any{}, "runtimeEpoch": int64(1), "schemaVersion": int64(1), "type": "Shutdown"})
	_ = inputWriter.Close()
	if got := <-status; got != 0 {
		t.Fatalf("status = %d", got)
	}

	reader := bufio.NewReader(bytes.NewReader(output.Bytes()))
	var types []string
	for {
		raw, err := reader.ReadBytes('\n')
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatal(err)
		}
		message, err := protocol.DecodeLine(raw, protocol.HelperToRuntime)
		if err != nil {
			t.Fatal(err)
		}
		types = append(types, message.Type)
	}
	want := []string{"Hello", "Ready", "Accepted", "Started", "Result"}
	if len(types) != len(want) {
		t.Fatalf("types = %v", types)
	}
	for index := range want {
		if types[index] != want[index] {
			t.Fatalf("types = %v", types)
		}
	}
}

func TestRunSessionPreservesHighBitWireIdentities(t *testing.T) {
	high := uint64(math.MaxInt64) + 1
	var input bytes.Buffer
	writeSessionMessage(t, &input, map[string]any{
		"executorGeneration": high,
		"manifestHash":       strings.Repeat("a", 64),
		"messageID":          "00000000-0000-0000-0000-000000000001",
		"runtimeEpoch":       high,
		"schemaVersion":      int64(1),
		"type":               "HelloAccepted",
	})
	writeSessionMessage(t, &input, map[string]any{
		"executorGeneration": high,
		"messageID":          "00000000-0000-0000-0000-000000000002",
		"payload": map[string]any{
			"actionID":            "00000000-0000-0000-0000-000000000003",
			"backendPayload":      map[string]any{"operation": "warmGeneration"},
			"executorOperationID": "coredevice.warmGeneration",
		},
		"requestID":     "00000000-0000-0000-0000-000000000004",
		"runtimeEpoch":  high,
		"schemaVersion": int64(1),
		"type":          "Request",
	})
	writeSessionMessage(t, &input, map[string]any{
		"executorGeneration": high,
		"messageID":          "00000000-0000-0000-0000-000000000005",
		"payload":            map[string]any{},
		"runtimeEpoch":       high,
		"schemaVersion":      int64(1),
		"type":               "Shutdown",
	})
	var output bytes.Buffer
	status := RunSession(&input, &output, Config{
		RuntimeEpoch:         high,
		ExecutorGeneration:   high,
		HelperBuildID:        "build",
		HelperKind:           "coreDevice",
		ManifestHash:         strings.Repeat("a", 64),
		ProcessStartIdentity: "1.000002",
		HandleRequest: func(protocol.Message) RequestResult {
			return RequestResult{Value: map[string]any{"disposition": "ready"}}
		},
	})
	if status != 0 {
		t.Fatalf("status = %d, output = %q", status, output.String())
	}
	lines := bytes.Split(bytes.TrimSuffix(output.Bytes(), []byte{'\n'}), []byte{'\n'})
	if len(lines) != 5 {
		t.Fatalf("message count = %d, output = %q", len(lines), output.String())
	}
	for index, want := range []string{"Hello", "Ready", "Accepted", "Started", "Result"} {
		message, err := protocol.DecodeLine(append(lines[index], '\n'), protocol.HelperToRuntime)
		if err != nil || message.Type != want {
			t.Fatalf("message %d = %#v err=%v, want %s", index, message, err, want)
		}
		if message.RuntimeEpoch != high || message.ExecutorGeneration != high {
			t.Fatalf("message %d identities = (%d, %d), want (%d, %d)", index, message.RuntimeEpoch, message.ExecutorGeneration, high, high)
		}
	}
}

func TestRunSessionClosesOnceWhenClientEOFsAfterReady(t *testing.T) {
	inputReader, inputWriter := io.Pipe()
	var output bytes.Buffer
	closeCalls := 0
	status := make(chan int, 1)
	go func() {
		status <- RunSession(inputReader, &output, sessionTestConfig(func() error {
			closeCalls++
			return nil
		}))
	}()

	writeSessionMessage(t, inputWriter, helloAcceptedMessage())
	if err := inputWriter.Close(); err != nil {
		t.Fatal(err)
	}
	if got := <-status; got != 0 {
		t.Fatalf("status = %d, want 0", got)
	}
	if closeCalls != 1 {
		t.Fatalf("close calls = %d, want 1", closeCalls)
	}
}

func TestRequestResultPreservesExplicitErrorDetails(t *testing.T) {
	value := (RequestResult{
		ErrorCode:  "outcomeUnknown",
		ErrorStage: "mustNotReplaceExplicitPhase",
		ErrorDetails: map[string]any{
			"phase":              "executingProductRoute",
			"preparationGroupID": "prep.coredevice.v2",
			"stage":              "orientation",
		},
		Committed:      true,
		OutcomeUnknown: true,
	}).toValue()
	if value["commitState"] != "committed" || value["outcome"] != "outcomeUnknown" {
		t.Fatalf("result state = %#v", value)
	}
	errorValue, ok := value["error"].(map[string]any)
	if !ok || errorValue["code"] != "outcomeUnknown" {
		t.Fatalf("error = %#v", value["error"])
	}
	details, ok := errorValue["details"].(map[string]any)
	if !ok || details["phase"] != "executingProductRoute" || details["preparationGroupID"] != "prep.coredevice.v2" || details["stage"] != "orientation" {
		t.Fatalf("details = %#v", errorValue["details"])
	}
}

func TestRunSessionClosesAfterTerminalExitAfterResult(t *testing.T) {
	var input bytes.Buffer
	writeSessionMessage(t, &input, map[string]any{
		"executorGeneration": int64(2),
		"manifestHash":       strings.Repeat("a", 64),
		"messageID":          "00000000-0000-0000-0000-000000000001",
		"runtimeEpoch":       int64(1),
		"schemaVersion":      int64(1),
		"type":               "HelloAccepted",
	})
	writeSessionMessage(t, &input, map[string]any{
		"executorGeneration": int64(2),
		"messageID":          "00000000-0000-0000-0000-000000000002",
		"payload": map[string]any{
			"actionID":            "00000000-0000-0000-0000-000000000003",
			"backendPayload":      map[string]any{"operation": "warmGeneration"},
			"executorOperationID": "coredevice.warmGeneration",
		},
		"requestID":     "00000000-0000-0000-0000-000000000004",
		"runtimeEpoch":  int64(1),
		"schemaVersion": int64(1),
		"type":          "Request",
	})
	var output bytes.Buffer
	closed := 0
	status := RunSession(&input, &output, Config{
		RuntimeEpoch:         1,
		ExecutorGeneration:   2,
		HelperBuildID:        "build",
		HelperKind:           "coreDevice",
		ManifestHash:         strings.Repeat("a", 64),
		ProcessStartIdentity: "1.000002",
		HandleRequest: func(protocol.Message) RequestResult {
			return RequestResult{
				ErrorCode:       "developerServicesUnavailable",
				ErrorStage:      "startingDeviceServices",
				ExitAfterResult: true,
			}
		},
		Close: func() error {
			closed++
			return nil
		},
	})
	if status != 1 || closed != 1 {
		t.Fatalf("status=%d closed=%d", status, closed)
	}
	lines := bytes.Split(bytes.TrimSuffix(output.Bytes(), []byte{'\n'}), []byte{'\n'})
	if len(lines) != 5 {
		t.Fatalf("message count = %d: %q", len(lines), output.String())
	}
	last, err := protocol.DecodeLine(append(lines[4], '\n'), protocol.HelperToRuntime)
	if err != nil || last.Type != "Result" {
		t.Fatalf("terminal = %#v err=%v", last, err)
	}
}

func TestRunSessionUsesInjectedFrameAcceptedClock(t *testing.T) {
	var input bytes.Buffer
	writeSessionMessage(t, &input, helloAcceptedMessage())
	writeSessionMessage(t, &input, map[string]any{
		"executorGeneration": int64(2),
		"messageID":          "00000000-0000-0000-0000-000000000002",
		"payload": map[string]any{
			"actionID":      "00000000-0000-0000-0000-000000000007",
			"interactionID": "00000000-0000-0000-0000-000000000003",
			"streamKind":    "pointer",
			"streamPayload": map[string]any{"routeID": "coredevice.pointerStream"},
		},
		"deliveryAttemptID": "00000000-0000-0000-0000-000000000004",
		"runtimeEpoch":      int64(1),
		"schemaVersion":     int64(1),
		"sessionID":         "00000000-0000-0000-0000-000000000005",
		"type":              "StreamOpen",
	})
	writeSessionMessage(t, &input, map[string]any{
		"executorGeneration": int64(2),
		"messageID":          "00000000-0000-0000-0000-000000000006",
		"payload": map[string]any{
			"interactionID": "00000000-0000-0000-0000-000000000003",
			"framePayload":  map[string]any{},
			"seq":           int64(0),
		},
		"deliveryAttemptID": "00000000-0000-0000-0000-000000000004",
		"runtimeEpoch":      int64(1),
		"schemaVersion":     int64(1),
		"sessionID":         "00000000-0000-0000-0000-000000000005",
		"type":              "Frame",
	})
	var output bytes.Buffer
	status := RunSession(&input, &output, Config{
		RuntimeEpoch:         1,
		ExecutorGeneration:   2,
		HelperBuildID:        "build",
		HelperKind:           "coreDevice",
		ManifestHash:         "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		ProcessStartIdentity: "1.000002",
		AcceptedMonotonicNs: func() (uint64, bool) {
			return 388_407_297_500_000, true
		},
	})
	if status != 0 {
		t.Fatalf("status=%d output=%q", status, output.String())
	}
	lines := bytes.Split(bytes.TrimSuffix(output.Bytes(), []byte{'\n'}), []byte{'\n'})
	if len(lines) != 3 {
		t.Fatalf("message count = %d: %q", len(lines), output.String())
	}
	accepted, err := protocol.DecodeLine(append(lines[2], '\n'), protocol.HelperToRuntime)
	if err != nil || accepted.Type != "FrameAccepted" {
		t.Fatalf("frame accepted = %#v err=%v", accepted, err)
	}
	if accepted.Payload["acceptedMonotonicNs"] != int64(388_407_297_500_000) {
		t.Fatalf("accepted timestamp = %#v", accepted.Payload)
	}
}

func TestRunSessionRoutesRequestAndStreamCallbacks(t *testing.T) {
	var input bytes.Buffer
	writeSessionMessage(t, &input, helloAcceptedMessage())
	writeSessionMessage(t, &input, sessionProductRequest("00000000-0000-0000-0000-000000000002", "00000000-0000-0000-0000-000000000003"))
	writeSessionMessage(t, &input, sessionStreamOpen("00000000-0000-0000-0000-000000000004"))
	writeSessionMessage(t, &input, sessionFrame("00000000-0000-0000-0000-000000000005"))
	writeSessionMessage(t, &input, sessionStreamClose("00000000-0000-0000-0000-000000000006"))
	writeSessionMessage(t, &input, sessionShutdownMessage("00000000-0000-0000-0000-000000000007"))

	events := []string{}
	var output bytes.Buffer
	status := RunSession(&input, &output, Config{
		RuntimeEpoch:         1,
		ExecutorGeneration:   2,
		HelperBuildID:        "build",
		HelperKind:           "coreDevice",
		ManifestHash:         "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		ProcessStartIdentity: "1.000002",
		AcceptedMonotonicNs: func() (uint64, bool) {
			return 388_407_297_500_000, true
		},
		HandleRequest: func(message protocol.Message) RequestResult {
			events = append(events, "request:"+message.Payload["executorOperationID"].(string))
			return RequestResult{Value: map[string]any{"disposition": "acknowledged"}}
		},
		HandleStreamOpen: func(protocol.Message) *RequestResult {
			events = append(events, "stream-open")
			return nil
		},
		HandleFrame: func(protocol.Message) error {
			events = append(events, "frame")
			return nil
		},
		HandleStreamClose: func(protocol.Message) *RequestResult {
			events = append(events, "stream-close")
			return nil
		},
		Close: func() error {
			events = append(events, "backend-close")
			return nil
		},
	})
	if status != 0 {
		t.Fatalf("status=%d output=%q", status, output.String())
	}
	wantEvents := []string{"request:coredevice.button.home", "stream-open", "frame", "stream-close", "backend-close"}
	if strings.Join(events, ",") != strings.Join(wantEvents, ",") {
		t.Fatalf("events=%v want=%v", events, wantEvents)
	}
	types := sessionOutputTypes(t, output.Bytes())
	wantTypes := []string{"Hello", "Ready", "Accepted", "Started", "Result", "FrameAccepted"}
	if strings.Join(types, ",") != strings.Join(wantTypes, ",") {
		t.Fatalf("types=%v want=%v", types, wantTypes)
	}
}

func TestRunSessionReturnsStreamFailuresFromBarrier(t *testing.T) {
	for _, test := range []struct {
		name             string
		barrierMessageID string
		stage            string
		writeFailure     func(t *testing.T, input *bytes.Buffer)
		configFailure    func(protocol.Message) *RequestResult
	}{
		{
			name:             "open",
			barrierMessageID: "00000000-0000-0000-0000-000000000005",
			stage:            "openingInputService",
			writeFailure: func(t *testing.T, input *bytes.Buffer) {
				writeSessionMessage(t, input, sessionStreamOpen("00000000-0000-0000-0000-000000000004"))
			},
			configFailure: func(protocol.Message) *RequestResult {
				return &RequestResult{ErrorCode: "invalidArgument", ErrorStage: "openingInputService"}
			},
		},
		{
			name:             "cleanup",
			barrierMessageID: "00000000-0000-0000-0000-000000000005",
			stage:            "closingInputService",
			writeFailure: func(t *testing.T, input *bytes.Buffer) {
				writeSessionMessage(t, input, sessionStreamOpen("00000000-0000-0000-0000-000000000004"))
				writeSessionMessage(t, input, sessionStreamClose("00000000-0000-0000-0000-000000000006"))
			},
			configFailure: func(protocol.Message) *RequestResult {
				return &RequestResult{ErrorCode: "outcomeUnknown", ErrorStage: "closingInputService", Committed: true, OutcomeUnknown: true}
			},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			var input bytes.Buffer
			writeSessionMessage(t, &input, helloAcceptedMessage())
			test.writeFailure(t, &input)
			writeSessionMessage(t, &input, sessionBarrierRequest(test.barrierMessageID))
			writeSessionMessage(t, &input, sessionShutdownMessage("00000000-0000-0000-0000-000000000007"))
			var output bytes.Buffer
			status := RunSession(&input, &output, Config{
				RuntimeEpoch: 1, ExecutorGeneration: 2, HelperBuildID: "build", HelperKind: "coreDevice",
				ManifestHash: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef", ProcessStartIdentity: "1.000002",
				HandleStreamOpen: func(message protocol.Message) *RequestResult {
					if test.name == "open" {
						return test.configFailure(message)
					}
					return nil
				},
				HandleStreamClose: func(message protocol.Message) *RequestResult {
					if test.name == "cleanup" {
						return test.configFailure(message)
					}
					return nil
				},
			})
			if status != 0 {
				t.Fatalf("status=%d output=%q", status, output.String())
			}
			lines := bytes.Split(bytes.TrimSuffix(output.Bytes(), []byte{'\n'}), []byte{'\n'})
			last, err := protocol.DecodeLine(append(lines[len(lines)-1], '\n'), protocol.HelperToRuntime)
			if err != nil || last.Type != "Result" {
				t.Fatalf("terminal=%#v err=%v", last, err)
			}
			result, ok := last.Payload["result"].(map[string]any)
			if !ok {
				t.Fatalf("missing result: %#v", last.Payload)
			}
			errorValue, ok := result["error"].(map[string]any)
			if !ok || errorValue["code"] == "" {
				t.Fatalf("error result=%#v", result)
			}
			details, ok := errorValue["details"].(map[string]any)
			if !ok || details["phase"] != test.stage {
				t.Fatalf("details=%#v want phase=%q", errorValue["details"], test.stage)
			}
		})
	}
}

func sessionProductRequest(messageID, requestID string) map[string]any {
	return map[string]any{
		"executorGeneration": int64(2), "messageID": messageID,
		"payload": map[string]any{
			"actionID": "00000000-0000-0000-0000-000000000008", "backendPayload": map[string]any{"commandID": "button.home"}, "executorOperationID": "coredevice.button.home",
		},
		"requestID": requestID, "runtimeEpoch": int64(1), "schemaVersion": int64(1), "type": "Request",
	}
}

func sessionBarrierRequest(messageID string) map[string]any {
	return map[string]any{
		"executorGeneration": int64(2), "messageID": messageID,
		"payload": map[string]any{
			"actionID": "00000000-0000-0000-0000-000000000008", "backendPayload": map[string]any{"operation": "barrier"}, "executorOperationID": "coredevice.barrier",
		},
		"requestID": "00000000-0000-0000-0000-000000000009", "runtimeEpoch": int64(1), "schemaVersion": int64(1), "type": "Request",
	}
}

func sessionStreamOpen(messageID string) map[string]any {
	return map[string]any{
		"deliveryAttemptID": "00000000-0000-0000-0000-00000000000a", "executorGeneration": int64(2), "messageID": messageID,
		"payload": map[string]any{
			"actionID": "00000000-0000-0000-0000-000000000008", "interactionID": "00000000-0000-0000-0000-00000000000b", "streamKind": "pointer", "streamPayload": map[string]any{"routeID": "coredevice.pointerStream"},
		},
		"runtimeEpoch": int64(1), "schemaVersion": int64(1), "sessionID": "00000000-0000-0000-0000-00000000000c", "type": "StreamOpen",
	}
}

func sessionFrame(messageID string) map[string]any {
	return map[string]any{
		"deliveryAttemptID": "00000000-0000-0000-0000-00000000000a", "executorGeneration": int64(2), "messageID": messageID,
		"payload": map[string]any{
			"framePayload": map[string]any{}, "interactionID": "00000000-0000-0000-0000-00000000000b", "seq": int64(0),
		},
		"runtimeEpoch": int64(1), "schemaVersion": int64(1), "sessionID": "00000000-0000-0000-0000-00000000000c", "type": "Frame",
	}
}

func sessionStreamClose(messageID string) map[string]any {
	return map[string]any{
		"deliveryAttemptID": "00000000-0000-0000-0000-00000000000a", "executorGeneration": int64(2), "messageID": messageID,
		"payload": map[string]any{
			"interactionID": "00000000-0000-0000-0000-00000000000b", "reason": "completed",
		},
		"runtimeEpoch": int64(1), "schemaVersion": int64(1), "sessionID": "00000000-0000-0000-0000-00000000000c", "type": "Close",
	}
}

func sessionShutdownMessage(messageID string) map[string]any {
	return map[string]any{
		"executorGeneration": int64(2), "messageID": messageID, "payload": map[string]any{"reason": "runtimeStopping"},
		"runtimeEpoch": int64(1), "schemaVersion": int64(1), "type": "Shutdown",
	}
}

func sessionOutputTypes(t *testing.T, output []byte) []string {
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

func TestRunSessionClosesOnceOnMalformedMessage(t *testing.T) {
	inputReader, inputWriter := io.Pipe()
	var output bytes.Buffer
	closeCalls := 0
	status := make(chan int, 1)
	go func() {
		status <- RunSession(inputReader, &output, sessionTestConfig(func() error {
			closeCalls++
			return nil
		}))
	}()

	writeSessionMessage(t, inputWriter, helloAcceptedMessage())
	if _, err := io.WriteString(inputWriter, "{not-json}\n"); err != nil {
		t.Fatal(err)
	}
	if err := inputWriter.Close(); err != nil {
		t.Fatal(err)
	}
	if got := <-status; got != 2 {
		t.Fatalf("status = %d, want 2", got)
	}
	if closeCalls != 1 {
		t.Fatalf("close calls = %d, want 1", closeCalls)
	}
}

func TestRunSessionClosesOnceOnOversizedUnterminatedMessage(t *testing.T) {
	accepted, err := protocol.EncodeLine(helloAcceptedMessage(), protocol.RuntimeToHelper)
	if err != nil {
		t.Fatal(err)
	}
	input := append(accepted, bytes.Repeat([]byte("x"), protocol.MaxHelperLineBytes+1)...)
	var output bytes.Buffer
	closeCalls := 0
	status := RunSession(bytes.NewReader(input), &output, sessionTestConfig(func() error {
		closeCalls++
		return nil
	}))
	if status != 2 {
		t.Fatalf("status = %d, want 2", status)
	}
	if closeCalls != 1 {
		t.Fatalf("close calls = %d, want 1", closeCalls)
	}
}

func TestRunSessionClosesOnceOnShutdown(t *testing.T) {
	inputReader, inputWriter := io.Pipe()
	var output bytes.Buffer
	closeCalls := 0
	status := make(chan int, 1)
	go func() {
		status <- RunSession(inputReader, &output, sessionTestConfig(func() error {
			closeCalls++
			return nil
		}))
	}()

	writeSessionMessage(t, inputWriter, helloAcceptedMessage())
	writeSessionMessage(t, inputWriter, map[string]any{
		"executorGeneration": int64(2),
		"messageID":          "00000000-0000-0000-0000-000000000006",
		"payload":            map[string]any{},
		"runtimeEpoch":       int64(1),
		"schemaVersion":      int64(1),
		"type":               "Shutdown",
	})
	if err := inputWriter.Close(); err != nil {
		t.Fatal(err)
	}
	if got := <-status; got != 0 {
		t.Fatalf("status = %d, want 0", got)
	}
	if closeCalls != 1 {
		t.Fatalf("close calls = %d, want 1", closeCalls)
	}
}

func sessionTestConfig(close func() error) Config {
	return Config{
		RuntimeEpoch:         1,
		ExecutorGeneration:   2,
		HelperBuildID:        "build",
		HelperKind:           "direct",
		ManifestHash:         "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		ProcessStartIdentity: "pid:1",
		Facets:               []any{"lockdown"},
		Close:                close,
	}
}

func helloAcceptedMessage() map[string]any {
	return map[string]any{
		"executorGeneration": int64(2),
		"manifestHash":       "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		"messageID":          "00000000-0000-0000-0000-000000000001",
		"runtimeEpoch":       int64(1),
		"schemaVersion":      int64(1),
		"type":               "HelloAccepted",
	}
}

func writeSessionMessage(t *testing.T, writer io.Writer, fields map[string]any) {
	t.Helper()
	raw, err := protocol.EncodeLine(fields, protocol.RuntimeToHelper)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write(raw); err != nil {
		t.Fatal(err)
	}
}
