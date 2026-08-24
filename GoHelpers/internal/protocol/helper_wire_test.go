package protocol

import (
	"bufio"
	"fmt"
	"strings"
	"testing"
)

func TestReadHelperLineEnforcesBoundBeforeDecode(t *testing.T) {
	maxLine := strings.Repeat("x", MaxHelperLineBytes) + "\n"
	line, err := ReadHelperLine(bufio.NewReaderSize(strings.NewReader(maxLine), MaxHelperLineBytes+1))
	if err != nil {
		t.Fatalf("exact cap rejected: %v", err)
	}
	if len(line) != MaxHelperLineBytes+1 {
		t.Fatalf("exact cap line length = %d", len(line))
	}

	tooLarge := strings.Repeat("x", MaxHelperLineBytes+1)
	if _, err := ReadHelperLine(bufio.NewReaderSize(strings.NewReader(tooLarge), MaxHelperLineBytes+1)); err == nil {
		t.Fatal("unterminated oversized line accepted")
	}
}

func TestWireMachineHandshakeAndRequestLifecycle(t *testing.T) {
	machine := NewWireMachine(1, 2)
	hello := message("Hello", 1, 2, "00000000-0000-0000-0000-000000000001", nil)
	if err := machine.Receive(hello, HelperToRuntime); err != nil {
		t.Fatal(err)
	}
	accepted := message("HelloAccepted", 1, 2, "00000000-0000-0000-0000-000000000002", nil)
	if err := machine.Receive(accepted, RuntimeToHelper); err != nil {
		t.Fatal(err)
	}
	ready := message("Ready", 1, 2, "00000000-0000-0000-0000-000000000003", map[string]any{"facets": []any{}})
	if err := machine.Receive(ready, HelperToRuntime); err != nil {
		t.Fatal(err)
	}
	requestID := "00000000-0000-0000-0000-000000000004"
	request := message("Request", 1, 2, "00000000-0000-0000-0000-000000000005", map[string]any{
		"actionID":            "00000000-0000-0000-0000-000000000006",
		"backendPayload":      map[string]any{"operation": "barrier"},
		"executorOperationID": "barrier",
	})
	request.RequestID = &requestID
	if err := machine.Receive(request, RuntimeToHelper); err != nil {
		t.Fatal(err)
	}
	accepted = message("Accepted", 1, 2, "00000000-0000-0000-0000-000000000007", nil)
	accepted.RequestID = &requestID
	if err := machine.Receive(accepted, HelperToRuntime); err != nil {
		t.Fatal(err)
	}
	started := message("Started", 1, 2, "00000000-0000-0000-0000-000000000008", nil)
	started.RequestID = &requestID
	if err := machine.Receive(started, HelperToRuntime); err != nil {
		t.Fatal(err)
	}
	committed := message("Committed", 1, 2, "00000000-0000-0000-0000-000000000009", nil)
	committed.RequestID = &requestID
	if err := machine.Receive(committed, HelperToRuntime); err != nil {
		t.Fatal(err)
	}
	result := message("Result", 1, 2, "00000000-0000-0000-0000-00000000000a", map[string]any{"result": map[string]any{"commitState": "committed"}})
	result.RequestID = &requestID
	if err := machine.Receive(result, HelperToRuntime); err != nil {
		t.Fatal(err)
	}
	if len(machine.Requests) != 0 {
		t.Fatal("request remains active")
	}
}

func TestWireMachineRejectsMessagesAfterTerminalResult(t *testing.T) {
	machine := readyWireMachine(t)
	requestID := "00000000-0000-0000-0000-000000000004"
	request := message("Request", 1, 2, "00000000-0000-0000-0000-000000000005", map[string]any{
		"actionID":            "00000000-0000-0000-0000-000000000006",
		"backendPayload":      map[string]any{"operation": "barrier"},
		"executorOperationID": "barrier",
	})
	request.RequestID = &requestID
	if err := machine.Receive(request, RuntimeToHelper); err != nil {
		t.Fatal(err)
	}
	started := message("Started", 1, 2, "00000000-0000-0000-0000-000000000007", nil)
	started.RequestID = &requestID
	if err := machine.Receive(started, HelperToRuntime); err != nil {
		t.Fatal(err)
	}
	result := message("Result", 1, 2, "00000000-0000-0000-0000-000000000008", map[string]any{
		"result": map[string]any{"commitState": "notCommitted", "outcome": "succeeded"},
	})
	result.RequestID = &requestID
	if err := machine.Receive(result, HelperToRuntime); err != nil {
		t.Fatal(err)
	}

	duplicateResult := message("Result", 1, 2, "00000000-0000-0000-0000-000000000009", result.Payload)
	duplicateResult.RequestID = &requestID
	if err := machine.Receive(duplicateResult, HelperToRuntime); err == nil {
		t.Fatal("duplicate terminal result accepted")
	}
	lateProgress := message("Progress", 1, 2, "00000000-0000-0000-0000-00000000000a", map[string]any{})
	lateProgress.RequestID = &requestID
	if err := machine.Receive(lateProgress, HelperToRuntime); err == nil {
		t.Fatal("progress after terminal result accepted")
	}
}

func TestDecodeLineRejectsShapeDirectionAndDuplicate(t *testing.T) {
	raw := []byte(`{"type":"Hello","executorGeneration":2,"helperBuildID":"b","manifestHash":"h","messageID":"00000000-0000-0000-0000-000000000001","processStartIdentity":"p","runtimeEpoch":1,"schemaVersion":1}` + "\n")
	if _, err := DecodeLine(raw, RuntimeToHelper); err == nil {
		t.Fatal("wrong direction accepted")
	}
	duplicate := []byte(`{"type":"Hello","type":"Hello","executorGeneration":2,"helperBuildID":"b","manifestHash":"h","messageID":"00000000-0000-0000-0000-000000000001","processStartIdentity":"p","runtimeEpoch":1,"schemaVersion":1}` + "\n")
	if _, err := DecodeLine(duplicate, HelperToRuntime); err == nil {
		t.Fatal("duplicate accepted")
	}
}

func TestDecodeLineRejectsFrameAboveGeneratedMessageCap(t *testing.T) {
	raw := fmt.Sprintf(
		`{"deliveryAttemptID":"delivery","executorGeneration":2,"messageID":"00000000-0000-0000-0000-000000000001","payload":{"padding":"%s"},"runtimeEpoch":1,"schemaVersion":1,"sessionID":"00000000-0000-0000-0000-000000000002","type":"Frame"}`+"\n",
		strings.Repeat("x", 8*1024),
	)
	if _, err := DecodeLine([]byte(raw), RuntimeToHelper); err == nil {
		t.Fatal("oversized Frame accepted")
	}
}

func TestWireMachineDeveloperSupportDetectionMatchesLegacyOracle(t *testing.T) {
	machine := readyWireMachine(t)
	requestID := "00000000-0000-0000-0000-000000000004"
	partial := message("Request", 1, 2, "00000000-0000-0000-0000-000000000005", map[string]any{
		"actionID":            "00000000-0000-0000-0000-000000000006",
		"executorOperationID": "mount",
		"backendPayload": map[string]any{
			"catalogCanonicalSHA256": "entry-only",
		},
	})
	partial.RequestID = &requestID
	if err := machine.Receive(partial, RuntimeToHelper); err == nil {
		t.Fatal("partial developer-support payload accepted")
	}

	valid := developerSupportPayload()
	valid["catalogRevision"] = "catalog..revision"
	requestID = "00000000-0000-0000-0000-000000000007"
	request := message("Request", 1, 2, "00000000-0000-0000-0000-000000000008", map[string]any{
		"actionID":            "00000000-0000-0000-0000-000000000009",
		"executorOperationID": "mount",
		"backendPayload":      valid,
	})
	request.RequestID = &requestID
	if err := machine.Receive(request, RuntimeToHelper); err != nil {
		t.Fatalf("ordinary double-dot string rejected: %v", err)
	}

	forbidden := developerSupportPayload()
	forbidden["deviceContext"] = map[string]any{"relative": "images/../DeveloperDiskImage.dmg"}
	requestID = "00000000-0000-0000-0000-00000000000a"
	request = message("Request", 1, 2, "00000000-0000-0000-0000-00000000000b", map[string]any{
		"actionID":            "00000000-0000-0000-0000-00000000000c",
		"executorOperationID": "mount",
		"backendPayload":      forbidden,
	})
	request.RequestID = &requestID
	if err := machine.Receive(request, RuntimeToHelper); err == nil {
		t.Fatal("parent traversal path accepted")
	}
}

func readyWireMachine(t *testing.T) *WireMachine {
	t.Helper()
	machine := NewWireMachine(1, 2)
	if err := machine.Receive(message("Hello", 1, 2, "00000000-0000-0000-0000-000000000001", nil), HelperToRuntime); err != nil {
		t.Fatal(err)
	}
	if err := machine.Receive(message("HelloAccepted", 1, 2, "00000000-0000-0000-0000-000000000002", nil), RuntimeToHelper); err != nil {
		t.Fatal(err)
	}
	if err := machine.Receive(message("Ready", 1, 2, "00000000-0000-0000-0000-000000000003", map[string]any{"facets": []any{}}), HelperToRuntime); err != nil {
		t.Fatal(err)
	}
	return machine
}

func developerSupportPayload() map[string]any {
	return map[string]any{
		"preparationAttemptID":       "attempt-1",
		"preparationGroupID":         "prep.direct.lockdown.v1",
		"catalogRevision":            "catalog-r1",
		"catalogCanonicalSHA256":     "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
		"assetContentManifestSHA256": "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789",
		"fileRoles":                  []any{"classic.image", "classic.signature"},
		"operation":                  "mount",
		"deviceContext":              map[string]any{"service": "lockdown"},
	}
}

func message(kind string, epoch, generation uint64, id string, payload map[string]any) Message {
	return Message{Type: kind, RuntimeEpoch: epoch, ExecutorGeneration: generation, MessageID: id, Payload: payload, Fields: map[string]any{"type": kind}}
}
