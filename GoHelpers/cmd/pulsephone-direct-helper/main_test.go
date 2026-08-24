package main

import (
	"bytes"
	"os"
	"regexp"
	"strings"
	"testing"

	"pulsephone/GoHelpers/internal/protocol"
)

func TestRunDerivesProcessIdentityBeforeHello(t *testing.T) {
	input, err := os.CreateTemp(t.TempDir(), "direct-helper-input")
	if err != nil {
		t.Fatal(err)
	}
	defer input.Close()
	output, err := os.CreateTemp(t.TempDir(), "direct-helper-output")
	if err != nil {
		t.Fatal(err)
	}
	defer output.Close()
	manifestHash := strings.Repeat("a", 64)
	for _, fields := range []map[string]any{
		{
			"executorGeneration": int64(3),
			"manifestHash":       manifestHash,
			"messageID":          "00000000-0000-0000-0000-000000000001",
			"runtimeEpoch":       int64(7),
			"schemaVersion":      int64(1),
			"type":               "HelloAccepted",
		},
		{
			"executorGeneration": int64(3),
			"messageID":          "00000000-0000-0000-0000-000000000002",
			"payload": map[string]any{
				"actionID":            "00000000-0000-0000-0000-000000000003",
				"backendPayload":      map[string]any{"operation": "fixture"},
				"executorOperationID": "direct.fixture",
			},
			"requestID":     "00000000-0000-0000-0000-000000000010",
			"runtimeEpoch":  int64(7),
			"schemaVersion": int64(1),
			"type":          "Request",
		},
	} {
		raw, err := protocol.EncodeLine(fields, protocol.RuntimeToHelper)
		if err != nil {
			t.Fatal(err)
		}
		if _, err := input.Write(raw); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := input.Seek(0, 0); err != nil {
		t.Fatal(err)
	}

	previousArgs, previousStdin, previousStdout := os.Args, os.Stdin, os.Stdout
	os.Args = []string{
		"pulsephone-direct-helper",
		"--mode", "oneshot",
		"--runtime-epoch", "7",
		"--connection-epoch", "21",
		"--executor-generation", "3",
		"--raw-transport-udid", "raw-device",
		"--helper-build-id", "helper-build",
		"--manifest-hash", manifestHash,
	}
	os.Stdin, os.Stdout = input, output
	defer func() {
		os.Args, os.Stdin, os.Stdout = previousArgs, previousStdin, previousStdout
	}()
	t.Setenv("HOME", t.TempDir())
	if status := run(); status != 1 {
		t.Fatalf("status = %d, want 1 for fixture dispatch", status)
	}
	if _, err := output.Seek(0, 0); err != nil {
		t.Fatal(err)
	}
	rawOutput, err := os.ReadFile(output.Name())
	if err != nil {
		t.Fatal(err)
	}
	lines := bytes.Split(bytes.TrimSuffix(rawOutput, []byte{'\n'}), []byte{'\n'})
	if len(lines) != 5 {
		t.Fatalf("output messages = %q", rawOutput)
	}
	for index, want := range []string{"Hello", "Ready", "Accepted", "Started", "Result"} {
		message, err := protocol.DecodeLine(append(lines[index], '\n'), protocol.HelperToRuntime)
		if err != nil || message.Type != want {
			t.Fatalf("message %d = %#v err=%v, want %s", index, message, err, want)
		}
		if want == "Hello" {
			identity, _ := message.Fields["processStartIdentity"].(string)
			if !regexp.MustCompile(`^[0-9]+\.[0-9]{6}$`).MatchString(identity) {
				t.Fatalf("process start identity = %q", identity)
			}
		}
	}
}
