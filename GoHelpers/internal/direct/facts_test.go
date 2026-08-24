package direct

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"sync"
	"testing"
	"time"
)

type fakeFactsBackend struct {
	devices      []map[string]any
	enumerateErr error
	probeCalls   int
	probeErr     error
	closed       bool
}

func (f *fakeFactsBackend) EnumerateDevices() ([]map[string]any, error) {
	if f.enumerateErr != nil {
		return nil, f.enumerateErr
	}
	return append([]map[string]any(nil), f.devices...), nil
}
func (f *fakeFactsBackend) Probe(_ uint64, raw string) (map[string]any, error) {
	f.probeCalls++
	if f.probeErr != nil {
		return nil, f.probeErr
	}
	return map[string]any{"facts": map[string]any{"uniqueDeviceID": raw}}, nil
}
func (f *fakeFactsBackend) Close() { f.closed = true }

func TestFactsRequestAndBoundedEnumeration(t *testing.T) {
	const id = "00000000-0000-0000-0000-000000000001"
	request, err := DecodeFactsRequest([]byte(`{"operation":"enumerate","payload":{},"requestID":"` + id + `","schemaVersion":1}`))
	if err != nil {
		t.Fatal(err)
	}
	backend := &fakeFactsBackend{}
	for i := 0; i < 257; i++ {
		backend.devices = append(backend.devices, map[string]any{"deviceID": int64(i), "rawTransportUDID": strings.Repeat("x", 1), "transport": "usb"})
	}
	_, failure := ProcessFactsRequest(request, backend, 1)
	if failure == nil || failure.Code != "deviceEnumerationLimitExceeded" {
		t.Fatalf("failure = %#v", failure)
	}
	if failure.Details["actual"] != int64(257) {
		t.Fatalf("details = %#v", failure.Details)
	}
}

func TestFactsRunnerEmitsOneLineAndClosesBackend(t *testing.T) {
	const id = "00000000-0000-0000-0000-000000000001"
	backend := &fakeFactsBackend{devices: []map[string]any{{"deviceID": int64(17), "rawTransportUDID": "raw", "transport": "usb"}}}
	var output bytes.Buffer
	status := RunFacts(strings.NewReader(`{"operation":"enumerate","payload":{},"requestID":"`+id+`","schemaVersion":1}`+"\n"), &output, backend)
	if status != 0 || bytes.Count(output.Bytes(), []byte{'\n'}) != 1 || !backend.closed {
		t.Fatalf("status=%d output=%q closed=%v", status, output.String(), backend.closed)
	}
}

func TestFactsDuplicateKeyRejected(t *testing.T) {
	_, err := DecodeFactsRequest([]byte(`{"operation":"enumerate","operation":"probe","payload":{},"requestID":"00000000-0000-0000-0000-000000000001","schemaVersion":1}`))
	if err == nil {
		t.Fatal("duplicate key accepted")
	}
}

func TestFactsRequestRejectsUndeclaredFields(t *testing.T) {
	_, err := DecodeFactsRequest([]byte(`{"actionID":"forbidden","operation":"enumerate","payload":{},"requestID":"00000000-0000-0000-0000-000000000001","schemaVersion":1}`))
	if err == nil {
		t.Fatal("undeclared field accepted")
	}
}

func TestFactsBackendSourceContainsNoMutatingLockdownRequests(t *testing.T) {
	_, sourceFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate test source")
	}
	source, err := os.ReadFile(filepath.Join(filepath.Dir(sourceFile), "facts.go"))
	if err != nil {
		t.Fatal(err)
	}
	for _, forbidden := range []string{"Pair", "StartSession", "StartService", "SetValue"} {
		if bytes.Contains(source, []byte(`"`+forbidden+`"`)) {
			t.Fatalf("facts backend contains mutating lockdown request %q", forbidden)
		}
	}
}

func TestFactsProbeRejectsNonUniqueDeviceIdentity(t *testing.T) {
	const id = "00000000-0000-0000-0000-000000000001"
	request, err := DecodeFactsRequest([]byte(`{"operation":"probe","payload":{"deviceID":17,"rawTransportUDID":"raw"},"requestID":"` + id + `","schemaVersion":1}`))
	if err != nil {
		t.Fatal(err)
	}
	backend := &fakeFactsBackend{devices: []map[string]any{
		{"deviceID": int64(17), "rawTransportUDID": "raw", "transport": "usb"},
		{"deviceID": int64(17), "rawTransportUDID": "raw", "transport": "usb"},
	}}
	_, failure := ProcessFactsRequest(request, backend, 1)
	if failure == nil || failure.Code != "deviceNotFound" {
		t.Fatalf("failure = %#v", failure)
	}
	if backend.probeCalls != 0 {
		t.Fatalf("probe calls = %d, want 0", backend.probeCalls)
	}
}

type factsErrorProjectionFixture struct {
	Cases         []factsErrorProjectionCase `json:"cases"`
	SchemaVersion int                        `json:"schemaVersion"`
}

type factsErrorProjectionCase struct {
	Devices            []factsErrorProjectionDevice `json:"devices"`
	ExpectedCode       string                       `json:"expectedCode"`
	ExpectedProbeCalls int                          `json:"expectedProbeCalls"`
	FailureAt          string                       `json:"failureAt"`
	FailureCode        string                       `json:"failureCode"`
	FailureKind        string                       `json:"failureKind"`
	Name               string                       `json:"name"`
}

type factsErrorProjectionDevice struct {
	DeviceID         int64  `json:"deviceID"`
	RawTransportUDID string `json:"rawTransportUDID"`
	Transport        string `json:"transport"`
}

func TestFactsErrorProjectionSharedFixture(t *testing.T) {
	const id = "00000000-0000-0000-0000-000000000001"
	request, err := DecodeFactsRequest([]byte(`{"operation":"probe","payload":{"deviceID":17,"rawTransportUDID":"raw"},"requestID":"` + id + `","schemaVersion":1}`))
	if err != nil {
		t.Fatal(err)
	}
	_, sourceFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate test source")
	}
	data, err := os.ReadFile(filepath.Join(filepath.Dir(sourceFile), "..", "..", "..", "Fixtures", "facts-probe", "facts-error-projection.v1.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fixture factsErrorProjectionFixture
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatal(err)
	}
	if fixture.SchemaVersion != 1 || len(fixture.Cases) == 0 {
		t.Fatal("invalid facts error projection fixture")
	}

	for _, item := range fixture.Cases {
		item := item
		t.Run(item.Name, func(t *testing.T) {
			devices := make([]map[string]any, len(item.Devices))
			for index, device := range item.Devices {
				devices[index] = map[string]any{"deviceID": device.DeviceID, "rawTransportUDID": device.RawTransportUDID, "transport": device.Transport}
			}
			backend := fakeFactsBackend{devices: devices}
			injectedError := factsFixtureFailure(t, item)
			switch item.FailureAt {
			case "none":
			case "enumerate":
				backend.enumerateErr = injectedError
			case "probe":
				backend.probeErr = injectedError
			default:
				t.Fatalf("unsupported failureAt %q", item.FailureAt)
			}
			result, projectedFailure := ProcessFactsRequest(request, &backend, 1)
			if result != nil || projectedFailure == nil || projectedFailure.Code != item.ExpectedCode {
				t.Fatalf("result=%#v failure=%#v, want %s", result, projectedFailure, item.ExpectedCode)
			}
			if backend.probeCalls != item.ExpectedProbeCalls {
				t.Fatalf("probe calls = %d, want %d", backend.probeCalls, item.ExpectedProbeCalls)
			}
			encoded, err := EncodeFactsResponse(request, result, projectedFailure)
			if err != nil {
				t.Fatal(err)
			}
			if !bytes.Contains(encoded, []byte(`"code":"`+item.ExpectedCode+`"`)) {
				t.Fatalf("response does not project failure %q: %s", item.ExpectedCode, encoded)
			}
		})
	}
}

func factsFixtureFailure(t *testing.T, item factsErrorProjectionCase) error {
	t.Helper()
	switch item.FailureKind {
	case "none":
		return nil
	case "typed":
		return &Failure{Code: item.FailureCode}
	case "timeout":
		return context.DeadlineExceeded
	case "os":
		return &os.PathError{Op: "read", Path: "fixture", Err: os.ErrNotExist}
	case "generic":
		return errors.New("fixture unexpected backend failure")
	default:
		t.Fatalf("unsupported failureKind %q", item.FailureKind)
		return nil
	}
}

func TestFactsLineReaderRejectsTrailingInputAndCapsLine(t *testing.T) {
	const id = "00000000-0000-0000-0000-000000000001"
	backend := &fakeFactsBackend{}
	var output bytes.Buffer
	status := RunFacts(
		strings.NewReader(`{"operation":"enumerate","payload":{},"requestID":"`+id+`","schemaVersion":1}`+"\nextra"),
		&output,
		backend,
	)
	if status != 2 || output.Len() != 0 {
		t.Fatalf("status=%d output=%q", status, output.String())
	}

	backend = &fakeFactsBackend{}
	output.Reset()
	status = RunFacts(strings.NewReader(strings.Repeat("x", RequestLimit)+"\n"), &output, backend)
	if status != 2 || output.Len() != 0 {
		t.Fatalf("oversized status=%d output=%q", status, output.String())
	}
}

type blockingFactsBackend struct {
	once   sync.Once
	closed chan struct{}
}

func newBlockingFactsBackend() *blockingFactsBackend {
	return &blockingFactsBackend{closed: make(chan struct{})}
}

func (b *blockingFactsBackend) EnumerateDevices() ([]map[string]any, error) {
	<-b.closed
	return nil, &Failure{Code: "probeUnavailable"}
}

func (b *blockingFactsBackend) Probe(uint64, string) (map[string]any, error) {
	<-b.closed
	return nil, &Failure{Code: "probeUnavailable"}
}

func (b *blockingFactsBackend) Close() {
	b.once.Do(func() { close(b.closed) })
}

func TestFactsWatchdogClosesBackendAndKillsProcessGroup(t *testing.T) {
	const id = "00000000-0000-0000-0000-000000000001"
	backend := newBlockingFactsBackend()
	var output bytes.Buffer
	killed := make(chan struct{}, 1)
	started := time.Now()
	status := runFactsWithWatchdog(
		strings.NewReader(`{"operation":"enumerate","payload":{},"requestID":"`+id+`","schemaVersion":1}`+"\n"),
		&output,
		backend,
		20*time.Millisecond,
		func() { killed <- struct{}{} },
	)
	if status != 1 || time.Since(started) > time.Second {
		t.Fatalf("status=%d elapsed=%s", status, time.Since(started))
	}
	select {
	case <-killed:
	case <-time.After(time.Second):
		t.Fatal("watchdog did not invoke process-group cleanup")
	}
	select {
	case <-backend.closed:
	default:
		t.Fatal("watchdog did not close backend")
	}
}
