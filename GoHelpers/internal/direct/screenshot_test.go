package direct

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"image/png"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestScreenshotReservationValidationAndWrite(t *testing.T) {
	root := t.TempDir()
	artifactID := "01234567-89ab-cdef-8123-456789abcdef"
	filename := filepath.Join(root, artifactID+".png")
	file, err := os.OpenFile(filename, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	if !validReservationPath(filename, artifactID) || validReservationPath(filename+"/../x", artifactID) {
		t.Fatal("reservation path validation mismatch")
	}
	image := append([]byte(nil), pngSignature...)
	image = append(image, 1, 2, 3)
	if err := writeReservedScreenshot(filename, image); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(filename)
	if err != nil {
		t.Fatal(err)
	}
	if string(data) != string(image) {
		t.Fatalf("image = %x", data)
	}
}

func TestWriteReservedScreenshotRejectsHardlinkedReservation(t *testing.T) {
	root := t.TempDir()
	filename := filepath.Join(root, "capture.png")
	file, err := os.OpenFile(filename, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	if err := os.Link(filename, filepath.Join(root, "alias.png")); err != nil {
		t.Fatal(err)
	}
	if err := writeReservedScreenshot(filename, append([]byte(nil), pngSignature...)); err == nil {
		t.Fatal("hardlinked reservation was accepted")
	}
}

func TestCaptureScreenshotFromServiceCompletesLegacyHandshakeAndWritesReservation(t *testing.T) {
	root := t.TempDir()
	artifactID := "00000000-0000-0000-0000-000000000001"
	reservationPath := filepath.Join(root, artifactID+".png")
	reservation, err := os.OpenFile(reservationPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if err := reservation.Close(); err != nil {
		t.Fatal(err)
	}
	image := append([]byte(nil), pngSignature...)
	image = append(image, []byte("fixture")...)
	service := &fakeScreenshotService{values: []any{
		[]any{"DLMessageVersionExchange", "DLVersionsOk", int64(300)},
		[]any{"DLMessageDeviceReady"},
		[]any{"DLMessageProcessMessage", map[string]any{
			"MessageType":    "ScreenShotReply",
			"ScreenShotData": image,
		}},
	}}

	value, failure := captureScreenshotFromService(service, reservationPath, artifactID, time.Now().Add(time.Minute))
	if failure != nil {
		t.Fatalf("capture failure = %#v", failure)
	}
	if want := map[string]any{"artifactID": artifactID, "byteCount": int64(len(image)), "format": "png"}; !reflect.DeepEqual(value, want) {
		t.Fatalf("value = %#v, want %#v", value, want)
	}
	if want := []int{64 * 1024, 64 * 1024, maximumScreenshotBytes}; !reflect.DeepEqual(service.maximums, want) {
		t.Fatalf("receive maxima = %#v, want %#v", service.maximums, want)
	}
	if want := []any{
		[]any{"DLMessageVersionExchange", "DLVersionsOk", int64(300)},
		[]any{"DLMessageProcessMessage", map[string]any{"MessageType": "ScreenShotRequest"}},
	}; !reflect.DeepEqual(service.sent, want) {
		t.Fatalf("sent = %#v, want %#v", service.sent, want)
	}
	data, err := os.ReadFile(reservationPath)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(data, image) {
		t.Fatalf("reservation = %x, want %x", data, image)
	}
}

func TestCaptureScreenshotFromServiceProjectsHandshakeFailures(t *testing.T) {
	artifactID := "00000000-0000-0000-0000-000000000001"
	tests := []struct {
		name     string
		service  *fakeScreenshotService
		deadline time.Time
		code     string
		details  map[string]any
	}{
		{
			name:     "malformed version exchange is legacy service unavailable",
			service:  &fakeScreenshotService{values: []any{[]any{"DLMessageVersionExchange"}}},
			deadline: time.Now().Add(time.Minute),
			code:     "developerServicesUnavailable",
			details: map[string]any{
				"phase":              launchStartingServicesPhase,
				"preparationGroupID": legacyPreparationGroupID,
			},
		},
		{
			name:     "device trust failure remains public",
			service:  &fakeScreenshotService{receiveErrors: []error{&Failure{Code: "deviceNotTrusted"}}},
			deadline: time.Now().Add(time.Minute),
			code:     "deviceNotTrusted",
		},
		{
			name:     "service timeout uses screenshot deadline",
			service:  &fakeScreenshotService{receiveErrors: []error{context.DeadlineExceeded}},
			deadline: time.Now().Add(time.Minute),
			code:     "executionTimeout",
			details:  map[string]any{"commitState": "notCommitted", "stage": "screenshotDeadline"},
		},
		{
			name: "invalid screenshot reply is artifact validation failure",
			service: &fakeScreenshotService{values: []any{
				[]any{"DLMessageVersionExchange", "DLVersionsOk", int64(300)},
				[]any{"DLMessageDeviceReady"},
				[]any{"DLMessageProcessMessage", map[string]any{"MessageType": "UnexpectedReply"}},
			}},
			deadline: time.Now().Add(time.Minute),
			code:     "artifactValidationFailed",
			details:  map[string]any{"stage": "formatConversion"},
		},
		{
			name:     "expired deadline does not read from the service",
			service:  &fakeScreenshotService{},
			deadline: time.Now().Add(-time.Second),
			code:     "executionTimeout",
			details:  map[string]any{"commitState": "notCommitted", "stage": "screenshotDeadline"},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			reservationPath := filepath.Join(t.TempDir(), artifactID+".png")
			reservation, err := os.OpenFile(reservationPath, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
			if err != nil {
				t.Fatal(err)
			}
			if err := reservation.Close(); err != nil {
				t.Fatal(err)
			}
			_, failure := captureScreenshotFromService(test.service, reservationPath, artifactID, test.deadline)
			if failure == nil || failure.Code != test.code || failure.CommitState != "notCommitted" || failure.Outcome != "failed" ||
				!reflect.DeepEqual(failure.Details, test.details) {
				t.Fatalf("failure = %#v", failure)
			}
			if test.deadline.Before(time.Now()) && len(test.service.maximums) != 0 {
				t.Fatalf("expired deadline read from service: %#v", test.service.maximums)
			}
		})
	}
}

func TestCaptureScreenshotRouteClosesServiceThenLockdown(t *testing.T) {
	artifactID, reservationPath := reserveScreenshotForRouteTest(t)
	events := []string{}
	image := makeTIFFFixture(binary.LittleEndian, [2]byte{'I', 'I'}, []byte{
		12, 34, 56, 200, 180, 160,
		1, 2, 3, 250, 240, 230,
	}, false)
	service := &fakeScreenshotRouteService{
		fakeScreenshotService: fakeScreenshotService{values: []any{
			[]any{"DLMessageVersionExchange", "DLVersionsOk", int64(300)},
			[]any{"DLMessageDeviceReady"},
			[]any{"DLMessageProcessMessage", map[string]any{
				"MessageType":    "ScreenShotReply",
				"ScreenShotData": image,
			}},
		}},
		events: &events,
	}
	lockdown := &fakeScreenshotLockdown{events: &events}
	value, failure := captureScreenshotWithDependencies(
		OneShotConfig{RawTransportUDID: "raw-device"},
		screenshotRoutePayload(artifactID, reservationPath, "screenshot.gui"),
		time.Now().Add(time.Minute),
		screenshotRouteDependencies{
			openLockdown: func(udid string, deadline time.Time) (screenshotLockdown, error) {
				if udid != "raw-device" || deadline.IsZero() {
					t.Fatal("unexpected lockdown opener input")
				}
				events = append(events, "lockdown.open")
				return lockdown, nil
			},
			newService: func(conn net.Conn, deadline time.Time) screenshotRouteService {
				if conn != lockdown.conn || deadline.IsZero() {
					t.Fatal("unexpected plist service input")
				}
				events = append(events, "service.create")
				service.conn = conn
				return service
			},
		},
	)
	if failure != nil {
		t.Fatalf("capture failure = %#v", failure)
	}
	data, err := os.ReadFile(reservationPath)
	if err != nil {
		t.Fatal(err)
	}
	decoded, err := png.Decode(bytes.NewReader(data))
	if err != nil || decoded.Bounds().Dx() != 2 || decoded.Bounds().Dy() != 2 {
		t.Fatalf("route TIFF normalization bounds=%v err=%v", decoded.Bounds(), err)
	}
	if want := map[string]any{"artifactID": artifactID, "byteCount": int64(len(data)), "format": "png"}; !reflect.DeepEqual(value, want) {
		t.Fatalf("value = %#v, want %#v", value, want)
	}
	if want := []string{"lockdown.open", "service.open", "service.create", "service.close", "lockdown.close"}; !reflect.DeepEqual(events, want) {
		t.Fatalf("events = %#v, want %#v", events, want)
	}
}

func TestCaptureScreenshotRouteRejectsInvalidPayloadBeforeOpeningLockdown(t *testing.T) {
	artifactID := "01234567-89ab-cdef-8123-456789abcdef"
	validPath := filepath.Join(t.TempDir(), artifactID+".png")
	for _, test := range []struct {
		name    string
		payload map[string]any
	}{
		{name: "unexpected field", payload: map[string]any{"operation": "screenshot", "unexpected": true}},
		{name: "uppercase artifact ID", payload: screenshotRoutePayload(strings.ToUpper(artifactID), validPath, "screenshot.cli")},
		{name: "unsupported command", payload: screenshotRoutePayload(artifactID, validPath, "device.screenshot")},
		{name: "unclean reservation path", payload: screenshotRoutePayload(artifactID, validPath+"/../"+artifactID+".png", "screenshot.cli")},
	} {
		t.Run(test.name, func(t *testing.T) {
			called := false
			_, failure := captureScreenshotWithDependencies(
				OneShotConfig{RawTransportUDID: "raw-device"},
				test.payload,
				time.Now().Add(time.Minute),
				screenshotRouteDependencies{
					openLockdown: func(string, time.Time) (screenshotLockdown, error) {
						called = true
						return nil, errors.New("must not open lockdown")
					},
				},
			)
			if called {
				t.Fatal("invalid screenshot payload opened lockdown")
			}
			if failure == nil || failure.Code != "artifactValidationFailed" || !reflect.DeepEqual(failure.Details, map[string]any{"stage": "reservation"}) {
				t.Fatalf("failure = %#v", failure)
			}
		})
	}
}

func TestCaptureScreenshotFromServiceRejectsInvalidArtifactInputs(t *testing.T) {
	for _, test := range []struct {
		name            string
		prepare         func(t *testing.T, path string)
		source          []byte
		code            string
		stage           string
		expectedContent []byte
	}{
		{
			name:   "unsupported format leaves reservation empty",
			source: []byte("not-an-image"),
			code:   "unsupportedScreenshotFormat",
			stage:  "formatConversion",
		},
		{
			name: "wrong reservation mode is not truncated",
			prepare: func(t *testing.T, path string) {
				t.Helper()
				if err := os.Chmod(path, 0o644); err != nil {
					t.Fatal(err)
				}
			},
			source: append([]byte(nil), pngSignature...),
			code:   "artifactValidationFailed",
			stage:  "helperWrite",
		},
		{
			name: "nonempty reservation is not truncated",
			prepare: func(t *testing.T, path string) {
				t.Helper()
				if err := os.WriteFile(path, []byte("do-not-truncate"), 0o600); err != nil {
					t.Fatal(err)
				}
			},
			source:          append([]byte(nil), pngSignature...),
			code:            "artifactValidationFailed",
			stage:           "helperWrite",
			expectedContent: []byte("do-not-truncate"),
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			artifactID, reservationPath := reserveScreenshotForRouteTest(t)
			if test.prepare != nil {
				test.prepare(t, reservationPath)
			}
			service := &fakeScreenshotService{values: []any{
				[]any{"DLMessageVersionExchange", "DLVersionsOk", int64(300)},
				[]any{"DLMessageDeviceReady"},
				[]any{"DLMessageProcessMessage", map[string]any{
					"MessageType":    "ScreenShotReply",
					"ScreenShotData": test.source,
				}},
			}}
			_, failure := captureScreenshotFromService(service, reservationPath, artifactID, time.Now().Add(time.Minute))
			if failure == nil || failure.Code != test.code || !reflect.DeepEqual(failure.Details, map[string]any{"stage": test.stage}) {
				t.Fatalf("failure = %#v", failure)
			}
			data, err := os.ReadFile(reservationPath)
			if err != nil {
				t.Fatal(err)
			}
			if string(data) != string(test.expectedContent) {
				t.Fatalf("reservation = %q, want %q", data, test.expectedContent)
			}
		})
	}
}

func TestCaptureScreenshotRouteProjectsServiceOpenFailure(t *testing.T) {
	artifactID, reservationPath := reserveScreenshotForRouteTest(t)
	events := []string{}
	lockdown := &fakeScreenshotLockdown{events: &events, startErr: errors.New("developer service unavailable")}
	_, failure := captureScreenshotWithDependencies(
		OneShotConfig{RawTransportUDID: "raw-device"},
		screenshotRoutePayload(artifactID, reservationPath, "screenshot.cli"),
		time.Now().Add(time.Minute),
		screenshotRouteDependencies{
			openLockdown: func(string, time.Time) (screenshotLockdown, error) {
				events = append(events, "lockdown.open")
				return lockdown, nil
			},
			newService: func(net.Conn, time.Time) screenshotRouteService {
				t.Fatal("service constructed after StartService failure")
				return nil
			},
		},
	)
	if failure == nil || failure.Code != "developerServicesUnavailable" || failure.CommitState != "notCommitted" || failure.Outcome != "failed" ||
		!reflect.DeepEqual(failure.Details, map[string]any{"phase": launchStartingServicesPhase, "preparationGroupID": legacyPreparationGroupID}) {
		t.Fatalf("failure = %#v", failure)
	}
	if want := []string{"lockdown.open", "service.open", "lockdown.close"}; !reflect.DeepEqual(events, want) {
		t.Fatalf("events = %#v, want %#v", events, want)
	}
}

func reserveScreenshotForRouteTest(t *testing.T) (string, string) {
	t.Helper()
	artifactID := "00000000-0000-0000-0000-000000000001"
	path := filepath.Join(t.TempDir(), artifactID+".png")
	file, err := os.OpenFile(path, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	return artifactID, path
}

func screenshotRoutePayload(artifactID, reservationPath, commandID string) map[string]any {
	return map[string]any{
		"artifactID":      artifactID,
		"commandID":       commandID,
		"operation":       "screenshot",
		"reservationPath": reservationPath,
	}
}

type fakeScreenshotLockdown struct {
	conn     net.Conn
	events   *[]string
	startErr error
}

func (lockdown *fakeScreenshotLockdown) StartService(name string) (net.Conn, error) {
	if name != ScreenshotServiceName {
		return nil, errors.New("unexpected screenshot service")
	}
	*lockdown.events = append(*lockdown.events, "service.open")
	if lockdown.startErr != nil {
		return nil, lockdown.startErr
	}
	client, server := net.Pipe()
	_ = server.Close()
	lockdown.conn = client
	return client, nil
}

func (lockdown *fakeScreenshotLockdown) Close() {
	*lockdown.events = append(*lockdown.events, "lockdown.close")
}

type fakeScreenshotRouteService struct {
	fakeScreenshotService
	conn   net.Conn
	events *[]string
}

func (service *fakeScreenshotRouteService) close() {
	*service.events = append(*service.events, "service.close")
	if service.conn != nil {
		_ = service.conn.Close()
	}
}

type fakeScreenshotService struct {
	maximums      []int
	receiveErrors []error
	sendErrors    []error
	sent          []any
	values        []any
}

func (service *fakeScreenshotService) receiveValue(maximum int) (any, error) {
	service.maximums = append(service.maximums, maximum)
	if len(service.receiveErrors) > 0 {
		err := service.receiveErrors[0]
		service.receiveErrors = service.receiveErrors[1:]
		if err != nil {
			return nil, err
		}
	}
	if len(service.values) == 0 {
		return nil, errors.New("missing fake screenshot response")
	}
	value := service.values[0]
	service.values = service.values[1:]
	return value, nil
}

func (service *fakeScreenshotService) sendValue(value any) error {
	service.sent = append(service.sent, value)
	if len(service.sendErrors) == 0 {
		return nil
	}
	err := service.sendErrors[0]
	service.sendErrors = service.sendErrors[1:]
	return err
}

type directScreenshotProjectionFixture struct {
	Cases         []directScreenshotProjectionCase `json:"cases"`
	SchemaVersion int                              `json:"schemaVersion"`
}

type directScreenshotProjectionCase struct {
	Code           string         `json:"code"`
	ExpectedResult map[string]any `json:"expectedResult"`
	Name           string         `json:"name"`
	Stage          string         `json:"stage"`
	Transition     string         `json:"transition"`
}

func TestScreenshotProjectionSharedFixture(t *testing.T) {
	_, sourceFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate test source")
	}
	path := filepath.Join(filepath.Dir(sourceFile), "..", "..", "..", "Fixtures", "helper-wire", "direct-screenshot-projection.v1.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read shared fixture: %v", err)
	}
	var fixture directScreenshotProjectionFixture
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatalf("decode shared fixture: %v", err)
	}
	if fixture.SchemaVersion != 1 || len(fixture.Cases) == 0 {
		t.Fatal("invalid shared fixture")
	}
	for _, item := range fixture.Cases {
		item := item
		t.Run(item.Name, func(t *testing.T) {
			var failure *OperationFailure
			switch item.Transition {
			case "artifactFailure":
				failure = screenshotArtifactFailure(item.Code, item.Stage)
			case "deadline":
				failure = screenshotServiceFailure(context.DeadlineExceeded, time.Now().Add(time.Minute))
			case "serviceUnavailable":
				failure = screenshotServiceFailure(&Failure{Code: "protocolViolation"}, time.Now().Add(time.Minute))
			case "deviceDisconnected":
				failure = screenshotServiceFailure(&Failure{Code: "deviceNotFound"}, time.Now().Add(time.Minute))
			case "deviceNotTrusted", "deviceLocked", "transportFailure":
				failure = screenshotServiceFailure(&Failure{Code: item.Transition}, time.Now().Add(time.Minute))
			default:
				t.Fatalf("unsupported fixture transition %q", item.Transition)
			}
			if actual := operationFailureResult(failure); !reflect.DeepEqual(actual, item.ExpectedResult) {
				t.Fatalf("result = %#v, want %#v", actual, item.ExpectedResult)
			}
		})
	}
}

func TestValidScreenshotReservationRequiresCurrentOwnerAndSingleLink(t *testing.T) {
	root := t.TempDir()
	filename := filepath.Join(root, "capture.png")
	if err := os.WriteFile(filename, nil, 0o600); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(filename)
	if err != nil {
		t.Fatal(err)
	}
	if !validScreenshotReservation(info) {
		t.Fatal("secure reservation rejected")
	}
	metadata, ok := info.Sys().(*syscall.Stat_t)
	if !ok || metadata.Nlink != 1 {
		t.Fatalf("unexpected stat metadata: %#v", info.Sys())
	}
}
