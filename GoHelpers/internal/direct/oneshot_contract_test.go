package direct

import (
	"bytes"
	"context"
	"encoding/binary"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"math"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"time"

	"pulsephone/GoHelpers/internal/protocol"
)

func TestNormalizeAppProjectsSupportedMetadataAndFiltersHiddenApps(t *testing.T) {
	seen := map[string]struct{}{}
	value, failure := normalizeApp(map[string]any{
		"ApplicationType":            "User",
		"CFBundleDisplayName":        "Visible",
		"CFBundleIdentifier":         "com.example.visible",
		"CFBundleName":               "Fallback",
		"CFBundlePackageType":        "APPL",
		"CFBundleShortVersionString": "1.2.3",
	}, seen)
	if failure != nil {
		t.Fatalf("normalize visible app: %#v", failure)
	}
	expected := map[string]any{
		"applicationType": "user",
		"bundleID":        "com.example.visible",
		"displayName":     "Visible",
		"version":         "1.2.3",
	}
	for key, want := range expected {
		if value[key] != want {
			t.Fatalf("%s = %#v, want %#v", key, value[key], want)
		}
	}

	hidden, failure := normalizeApp(map[string]any{
		"CFBundleIdentifier":  "com.example.hidden",
		"CFBundlePackageType": "APPL",
		"SBAppTags":           []any{"hidden"},
	}, seen)
	if failure != nil || hidden != nil {
		t.Fatalf("hidden app = %#v, failure = %#v", hidden, failure)
	}
	if _, exists := seen["com.example.hidden"]; !exists {
		t.Fatal("hidden application was not consumed for duplicate detection")
	}
}

func TestNormalizeAppRejectsMalformedAndDuplicateEntries(t *testing.T) {
	tests := []map[string]any{
		{"CFBundleIdentifier": "com.example.duplicate", "CFBundlePackageType": "APPL"},
		{"CFBundleIdentifier": "", "CFBundlePackageType": "APPL"},
		{"CFBundleIdentifier": strings.Repeat("x", 256), "CFBundlePackageType": "APPL"},
		{"CFBundleIdentifier": "com.example.bad-tags", "CFBundlePackageType": "APPL", "SBAppTags": "hidden"},
		{"CFBundleIdentifier": "com.example.bad-tag", "CFBundlePackageType": "APPL", "SBAppTags": []any{"hidden", int64(1)}},
		{"CFBundleIdentifier": "com.example.bad-type", "CFBundlePackageType": int64(1)},
		{"CFBundleIdentifier": "com.example.bad-display", "CFBundlePackageType": "APPL", "CFBundleDisplayName": int64(1)},
		{"CFBundleIdentifier": "com.example.bad-name", "CFBundlePackageType": "APPL", "CFBundleName": int64(1)},
		{"CFBundleIdentifier": "com.example.bad-version", "CFBundlePackageType": "APPL", "CFBundleShortVersionString": int64(1)},
		{"CFBundleIdentifier": "com.example.bad-application-type", "CFBundlePackageType": "APPL", "ApplicationType": int64(1)},
	}
	seen := map[string]struct{}{"com.example.duplicate": {}}
	for index, value := range tests {
		if _, failure := normalizeApp(value, seen); failure == nil {
			t.Fatalf("case %d accepted malformed app", index)
		}
	}
}

func TestDirectRouteRejectsBrowsePayloadBeforeOpeningDevice(t *testing.T) {
	result, status := directRoute(OneShotConfig{RawTransportUDID: "not-used"}, protocol.Message{
		Payload: map[string]any{
			"backendPayload": map[string]any{"operation": "browse", "filter": "User"},
		},
	})
	if status != 1 {
		t.Fatalf("status = %d, want 1", status)
	}
	want := failureResult("backendFailed", "browseValidate")
	if !reflect.DeepEqual(result, want) {
		t.Fatalf("result = %#v, want %#v", result, want)
	}
}

func TestClassicMountedLookupAcceptsSignatureListLikePython(t *testing.T) {
	result, failure := projectMountedDeveloperImage(map[string]any{
		"ImageSignature": []any{[]byte("approved-signature")},
	})
	if failure != nil {
		t.Fatalf("signature list: %#v", failure)
	}
	if result["imageType"] != "Developer" || result["mounted"] != true {
		t.Fatalf("signature list result = %#v", result)
	}
}

func TestBrowseRouteSendsContractNormalizesResultAndClosesResources(t *testing.T) {
	events := []string{}
	service := &fakeBrowseRouteService{
		events: &events,
		responses: []map[string]any{{
			"CurrentList": []any{map[string]any{
				"ApplicationType":            "User",
				"CFBundleDisplayName":        "Example",
				"CFBundleIdentifier":         "com.example.app",
				"CFBundlePackageType":        "APPL",
				"CFBundleShortVersionString": "1.0",
			}},
			"Status": "Complete",
		}},
	}
	lockdown := &fakeBrowseRouteLockdown{events: &events}
	result, failure := browseAppsWithDependencies("raw-device", time.Now().Add(time.Minute), browseRouteDependencies{
		openLockdown: func(udid string, deadline time.Time) (browseRouteLockdown, error) {
			if udid != "raw-device" || deadline.IsZero() {
				t.Fatal("unexpected lockdown opener input")
			}
			events = append(events, "lockdown.open")
			return lockdown, nil
		},
		newService: func(conn net.Conn, deadline time.Time) browseRouteService {
			if conn != lockdown.conn || deadline.IsZero() {
				t.Fatal("unexpected plist service input")
			}
			events = append(events, "service.create")
			service.conn = conn
			return service
		},
	})
	if failure != nil {
		t.Fatalf("browse failure = %#v", failure)
	}
	want := map[string]any{
		"apps": []any{map[string]any{
			"applicationType": "user",
			"bundleID":        "com.example.app",
			"displayName":     "Example",
			"version":         "1.0",
		}},
		"truncated": false,
	}
	if !reflect.DeepEqual(result, want) {
		t.Fatalf("result = %#v, want %#v", result, want)
	}
	if wantRequest := map[string]any{
		"ClientOptions": map[string]any{
			"ApplicationType": "Any",
			"ReturnAttributes": []any{
				"CFBundleIdentifier", "CFBundleDisplayName", "CFBundleName", "CFBundleShortVersionString",
				"ApplicationType", "CFBundlePackageType", "SBAppTags",
			},
		},
		"Command": "Browse",
	}; !reflect.DeepEqual(service.sent, []map[string]any{wantRequest}) {
		t.Fatalf("sent = %#v, want %#v", service.sent, []map[string]any{wantRequest})
	}
	if wantMaximums := []int{1024 * 1024}; !reflect.DeepEqual(service.maximums, wantMaximums) {
		t.Fatalf("receive maxima = %#v, want %#v", service.maximums, wantMaximums)
	}
	if wantEvents := []string{"lockdown.open", "service.open", "service.create", "browse.send", "browse.receive", "service.close", "lockdown.close"}; !reflect.DeepEqual(events, wantEvents) {
		t.Fatalf("events = %#v, want %#v", events, wantEvents)
	}
}

func TestBrowseRouteProjectsFailureStages(t *testing.T) {
	for _, test := range []struct {
		name       string
		deadline   time.Time
		openErr    error
		startErr   error
		sendErr    error
		receiveErr error
		code       string
		stage      string
	}{
		{name: "expired deadline", deadline: time.Now().Add(-time.Second), code: "executionTimeout", stage: "browseDeadline"},
		{name: "lockdown failure", deadline: time.Now().Add(time.Minute), openErr: errors.New("lockdown unavailable"), code: "backendFailed", stage: "serviceOpen"},
		{name: "trusted failure", deadline: time.Now().Add(time.Minute), openErr: &Failure{Code: "deviceNotTrusted"}, code: "deviceNotTrusted", stage: "serviceOpen"},
		{name: "service start failure", deadline: time.Now().Add(time.Minute), startErr: errors.New("installation proxy unavailable"), code: "backendFailed", stage: "serviceOpen"},
		{name: "browse send transport failure", deadline: time.Now().Add(time.Minute), sendErr: &Failure{Code: "transportFailure"}, code: "transportFailure", stage: "browseSend"},
		{name: "browse receive protocol failure", deadline: time.Now().Add(time.Minute), receiveErr: &Failure{Code: "protocolViolation"}, code: "backendFailed", stage: "browseReceive"},
		{name: "browse receive EOF", deadline: time.Now().Add(time.Minute), receiveErr: io.EOF, code: "transportFailure", stage: "browseReceive"},
		{name: "browse receive timeout", deadline: time.Now().Add(time.Minute), receiveErr: context.DeadlineExceeded, code: "executionTimeout", stage: "browseDeadline"},
	} {
		t.Run(test.name, func(t *testing.T) {
			events := []string{}
			service := &fakeBrowseRouteService{events: &events, sendErr: test.sendErr, receiveErr: test.receiveErr}
			lockdown := &fakeBrowseRouteLockdown{events: &events, startErr: test.startErr}
			_, failure := browseAppsWithDependencies("raw-device", test.deadline, browseRouteDependencies{
				openLockdown: func(string, time.Time) (browseRouteLockdown, error) {
					events = append(events, "lockdown.open")
					if test.openErr != nil {
						return nil, test.openErr
					}
					return lockdown, nil
				},
				newService: func(conn net.Conn, deadline time.Time) browseRouteService {
					events = append(events, "service.create")
					service.conn = conn
					return service
				},
			})
			if failure == nil || failure.Code != test.code || !reflect.DeepEqual(failure.Details, map[string]any{"stage": test.stage}) {
				t.Fatalf("failure = %#v", failure)
			}
			if test.name == "expired deadline" {
				if len(events) != 0 {
					t.Fatalf("expired deadline opened route: %#v", events)
				}
				return
			}
			if test.openErr != nil {
				if want := []string{"lockdown.open"}; !reflect.DeepEqual(events, want) {
					t.Fatalf("events = %#v, want %#v", events, want)
				}
				return
			}
			if test.startErr != nil {
				if want := []string{"lockdown.open", "service.open", "lockdown.close"}; !reflect.DeepEqual(events, want) {
					t.Fatalf("events = %#v, want %#v", events, want)
				}
				return
			}
			if want := []string{"lockdown.open", "service.open", "service.create", "browse.send", "service.close", "lockdown.close"}; test.receiveErr != nil {
				want = []string{"lockdown.open", "service.open", "service.create", "browse.send", "browse.receive", "service.close", "lockdown.close"}
				if !reflect.DeepEqual(events, want) {
					t.Fatalf("events = %#v, want %#v", events, want)
				}
			} else if !reflect.DeepEqual(events, want) {
				t.Fatalf("events = %#v, want %#v", events, want)
			}
		})
	}
}

type fakeBrowseRouteLockdown struct {
	conn     net.Conn
	events   *[]string
	startErr error
}

func (lockdown *fakeBrowseRouteLockdown) StartService(name string) (net.Conn, error) {
	if name != InstallationProxyService {
		return nil, errors.New("unexpected service")
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

func (lockdown *fakeBrowseRouteLockdown) Close() {
	*lockdown.events = append(*lockdown.events, "lockdown.close")
}

type fakeBrowseRouteService struct {
	conn       net.Conn
	events     *[]string
	maximums   []int
	receiveErr error
	responses  []map[string]any
	sendErr    error
	sent       []map[string]any
}

func (service *fakeBrowseRouteService) send(value map[string]any) error {
	*service.events = append(*service.events, "browse.send")
	service.sent = append(service.sent, value)
	return service.sendErr
}

func (service *fakeBrowseRouteService) receive(maximum int) (map[string]any, error) {
	*service.events = append(*service.events, "browse.receive")
	service.maximums = append(service.maximums, maximum)
	if service.receiveErr != nil {
		return nil, service.receiveErr
	}
	if len(service.responses) == 0 {
		return nil, errors.New("missing browse response")
	}
	response := service.responses[0]
	service.responses = service.responses[1:]
	return response, nil
}

func (service *fakeBrowseRouteService) close() {
	*service.events = append(*service.events, "service.close")
	if service.conn != nil {
		_ = service.conn.Close()
	}
}

func TestBrowsePlistServiceRejectsOversizedHeaderBeforeReadingBody(t *testing.T) {
	client, server := net.Pipe()
	serverDone := make(chan error, 1)
	go func() {
		header := make([]byte, 4)
		binary.BigEndian.PutUint32(header, 1024*1024+1)
		_, err := server.Write(header)
		_ = server.Close()
		serverDone <- err
	}()
	service := newPlistService(client, time.Now().Add(time.Minute))
	defer service.close()
	_, err := service.receive(1024 * 1024)
	if writeErr := <-serverDone; writeErr != nil {
		t.Fatal(writeErr)
	}
	var failure *Failure
	if !errors.As(err, &failure) || failure.Code != "protocolViolation" {
		t.Fatalf("oversized browse response failure = %#v", err)
	}
}

func TestBrowseProjectionConsumesLegacyIOSFixtures(t *testing.T) {
	_, sourceFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate test source")
	}
	root := filepath.Join(filepath.Dir(sourceFile), "..", "..", "..")
	for _, version := range []int{14, 15, 16} {
		t.Run(fmt.Sprintf("iOS %d", version), func(t *testing.T) {
			path := filepath.Join(root, "Fixtures", "product-actions", "app-list", fmt.Sprintf("installation-proxy-ios%d.v1.json", version))
			data, err := os.ReadFile(path)
			if err != nil {
				t.Fatal(err)
			}
			var fixture struct {
				Expected      []map[string]any `json:"expected"`
				Responses     []map[string]any `json:"responses"`
				SchemaVersion int              `json:"schemaVersion"`
			}
			if err := json.Unmarshal(data, &fixture); err != nil {
				t.Fatal(err)
			}
			if fixture.SchemaVersion != 1 || len(fixture.Responses) == 0 {
				t.Fatal("invalid legacy app-list fixture")
			}
			projection := newBrowseProjection()
			complete := false
			for _, response := range fixture.Responses {
				var failure *Failure
				complete, failure = projection.consume(response)
				if failure != nil {
					t.Fatalf("fixture browse failure = %#v", failure)
				}
			}
			if !complete {
				t.Fatal("fixture did not complete")
			}
			result, failure := projection.result()
			if failure != nil {
				t.Fatalf("fixture result failure = %#v", failure)
			}
			expectedApps := make([]any, len(fixture.Expected))
			for index, app := range fixture.Expected {
				expectedApps[index] = app
			}
			if want := map[string]any{"apps": expectedApps, "truncated": false}; !reflect.DeepEqual(result, want) {
				t.Fatalf("result = %#v, want %#v", result, want)
			}
		})
	}
}

func TestBrowseProjectionPreservesLegacyPackageAndTagFilteringOrder(t *testing.T) {
	projection := newBrowseProjection()
	complete, failure := projection.consume(map[string]any{
		"CurrentList": []any{
			map[string]any{"CFBundleIdentifier": "com.example.no-package"},
			map[string]any{"CFBundleIdentifier": "com.example.non-app", "CFBundlePackageType": "FMWK", "SBAppTags": int64(42)},
			map[string]any{"CFBundleIdentifier": "com.example.hidden", "CFBundlePackageType": "APPL", "SBAppTags": []any{"hidden"}},
			map[string]any{"CFBundleIdentifier": "com.example.upper", "CFBundlePackageType": "APPL", "SBAppTags": []any{"Hidden"}},
			map[string]any{"CFBundleIdentifier": "com.example.other", "CFBundlePackageType": "APPL", "SBAppTags": []any{"system"}},
			map[string]any{"CFBundleIdentifier": "com.example.absent", "CFBundlePackageType": "APPL"},
		},
		"Status": "Complete",
	})
	if failure != nil || !complete {
		t.Fatalf("complete=%v failure=%#v", complete, failure)
	}
	result, failure := projection.result()
	if failure != nil {
		t.Fatalf("result failure = %#v", failure)
	}
	apps, ok := result["apps"].([]any)
	if !ok {
		t.Fatalf("apps = %#v", result["apps"])
	}
	identifiers := make([]string, len(apps))
	for index, raw := range apps {
		identifiers[index] = raw.(map[string]any)["bundleID"].(string)
	}
	if want := []string{"com.example.absent", "com.example.other", "com.example.upper"}; !reflect.DeepEqual(identifiers, want) {
		t.Fatalf("bundle IDs = %#v, want %#v", identifiers, want)
	}
}

func TestLookupInstalledDistinguishesMissingMalformedAndPresent(t *testing.T) {
	const bundleID = "com.example.app"
	tests := []struct {
		name      string
		response  map[string]any
		installed bool
		valid     bool
	}{
		{
			name: "present",
			response: map[string]any{"LookupResult": map[string]any{
				bundleID: map[string]any{"CFBundleIdentifier": bundleID},
			}},
			installed: true,
			valid:     true,
		},
		{name: "missing result", response: map[string]any{}, valid: true},
		{name: "missing app", response: map[string]any{"LookupResult": map[string]any{}}, valid: true},
		{name: "backend error", response: map[string]any{"Error": "NoSuchApp"}, valid: false},
		{name: "malformed metadata", response: map[string]any{"LookupResult": map[string]any{bundleID: "bad"}}, valid: false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			installed, valid := lookupInstalled(test.response, bundleID)
			if installed != test.installed || valid != test.valid {
				t.Fatalf("installed=%v valid=%v, want %v/%v", installed, valid, test.installed, test.valid)
			}
		})
	}
}

func TestOneShotValidationFailsBeforeOpeningDevice(t *testing.T) {
	config := OneShotConfig{RawTransportUDID: "not-used"}
	deadline := time.Now().Add(time.Minute)
	if _, failure := installApp(config, "", map[string]any{
		"ipaPath":   "/tmp/missing.ipa",
		"operation": "install",
	}, deadline); failure == nil || failure.Code != "installFailed" || failure.Stage != "requestValidation" {
		t.Fatalf("missing install request ID = %#v", failure)
	}
	if _, failure := installApp(config, "request", map[string]any{
		"ipaPath":   "/tmp/missing.ipa",
		"operation": "install",
	}, deadline); failure == nil || failure.Code != "invalidIPA" || failure.Stage != "archivePreflight" {
		t.Fatalf("invalid install = %#v", failure)
	}
	if _, failure := uninstallApp(config, map[string]any{
		"bundleID":  "not-a-bundle",
		"operation": "uninstall",
	}, deadline); failure == nil || failure.Code != "uninstallFailed" || failure.Stage != "requestValidation" {
		t.Fatalf("invalid uninstall = %#v", failure)
	}
	if _, failure := launchApp(config, map[string]any{
		"bundleID":  "not-a-bundle",
		"commandID": "app.launch",
		"operation": "launch",
	}, deadline); failure == nil || failure.Code != "appLaunchFailed" || failure.Stage != "requestValidation" {
		t.Fatalf("invalid launch = %#v", failure)
	}
}

func TestOperationFailureResultPreservesCommitAndOutcomeState(t *testing.T) {
	result := operationFailureResult(operationFailure("installFailed", "unknown", "outcomeUnknown", "installationProxyResponse"))
	if result["commitState"] != "unknown" || result["outcome"] != "outcomeUnknown" {
		t.Fatalf("result state = %#v", result)
	}
	errorValue, ok := result["error"].(map[string]any)
	if !ok || errorValue["code"] != "installFailed" {
		t.Fatalf("error projection = %#v", result["error"])
	}
	details, ok := errorValue["details"].(map[string]any)
	if !ok || details["reason"] != "commitStateUnknown" {
		t.Fatalf("error details = %#v", errorValue["details"])
	}
}

type directInstallProjectionFixture struct {
	Cases         []directInstallProjectionCase `json:"cases"`
	SchemaVersion int                           `json:"schemaVersion"`
}

type directInstallProjectionCase struct {
	CommitState    string         `json:"commitState"`
	ExpectedResult map[string]any `json:"expectedResult"`
	Name           string         `json:"name"`
	Operation      string         `json:"operation"`
	Stage          string         `json:"stage"`
	Transition     string         `json:"transition"`
}

func TestInstallProjectionSharedFixture(t *testing.T) {
	_, sourceFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate test source")
	}
	path := filepath.Join(filepath.Dir(sourceFile), "..", "..", "..", "Fixtures", "helper-wire", "direct-install-projection.v1.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read shared fixture: %v", err)
	}
	var fixture directInstallProjectionFixture
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
			case "failure":
				switch item.Operation {
				case "install":
					failure = installFailure(item.CommitState, item.Stage)
				case "uninstall":
					failure = uninstallFailure(item.CommitState, item.Stage)
				default:
					t.Fatalf("unsupported fixture operation %q", item.Operation)
				}
			case "outcomeUnknown":
				failure = installationOutcomeUnknown()
			default:
				t.Fatalf("unsupported fixture transition %q", item.Transition)
			}
			if actual := operationFailureResult(failure); !reflect.DeepEqual(actual, item.ExpectedResult) {
				t.Fatalf("result = %#v, want %#v", actual, item.ExpectedResult)
			}
		})
	}
}

type directLaunchProjectionFixture struct {
	Cases         []directLaunchProjectionCase `json:"cases"`
	SchemaVersion int                          `json:"schemaVersion"`
}

type directLaunchProjectionCase struct {
	ExpectedResult map[string]any `json:"expectedResult"`
	Name           string         `json:"name"`
	Transition     string         `json:"transition"`
}

func TestLaunchProjectionSharedFixture(t *testing.T) {
	_, sourceFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate test source")
	}
	path := filepath.Join(filepath.Dir(sourceFile), "..", "..", "..", "Fixtures", "helper-wire", "direct-launch-projection.v1.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read shared fixture: %v", err)
	}
	var fixture directLaunchProjectionFixture
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
			case "startupUnavailable":
				failure = launchStartupFailure(errors.New("DVT unavailable"))
			case "rejected":
				failure = launchRejectedFailure()
			case "outcomeUnknown":
				failure = launchOutcomeUnknownFailure()
			default:
				t.Fatalf("unsupported fixture transition %q", item.Transition)
			}
			if actual := operationFailureResult(failure); !reflect.DeepEqual(actual, item.ExpectedResult) {
				t.Fatalf("result = %#v, want %#v", actual, item.ExpectedResult)
			}
		})
	}
}

func TestLaunchStartupPreservesPublicDeviceErrorWithoutStageDetails(t *testing.T) {
	failure := launchStartupFailure(&Failure{Code: "deviceNotFound"})
	want := map[string]any{
		"commitState": "notCommitted",
		"error":       map[string]any{"code": "deviceDisconnected"},
		"outcome":     "failed",
	}
	if actual := operationFailureResult(failure); !reflect.DeepEqual(actual, want) {
		t.Fatalf("result = %#v, want %#v", actual, want)
	}
}

func TestLaunchDeadlineMatchesLegacyContract(t *testing.T) {
	now := time.Date(2026, time.August, 17, 12, 0, 0, 0, time.UTC)
	if appLaunchDeadline != time.Minute {
		t.Fatalf("app launch deadline = %s, want %s", appLaunchDeadline, time.Minute)
	}
	if got, want := directOperationDeadline("launch", now), now.Add(time.Minute); !got.Equal(want) {
		t.Fatalf("launch deadline = %s, want %s", got, want)
	}
}

func TestInstallationResponseDeadlineReservesRuntimeResultGrace(t *testing.T) {
	deadline := time.Now().Add(time.Minute)
	remaining := time.Until(installationResponseDeadline(deadline))
	if remaining < time.Minute-installationResponseGrace-time.Millisecond || remaining > time.Minute-installationResponseGrace {
		t.Fatalf("response deadline leaves %s, want %s", remaining, time.Minute-installationResponseGrace)
	}
	nearDeadline := time.Now().Add(time.Millisecond)
	responseDeadline := installationResponseDeadline(nearDeadline)
	if !responseDeadline.Equal(nearDeadline) {
		t.Fatalf("near deadline = %s, want %s", responseDeadline, nearDeadline)
	}
}

func TestLaunchOutcomeUnknownOnlyCoversPostSubmitTransportFailures(t *testing.T) {
	for _, failure := range []error{io.EOF, net.ErrClosed, syscall.EPIPE, syscall.ECONNRESET} {
		if !launchOutcomeUnknown(failure) {
			t.Fatalf("transport failure %v was not classified", failure)
		}
	}
	if launchOutcomeUnknown(errors.New("DTX service rejected request")) {
		t.Fatal("service rejection was classified as unknown")
	}
	if launchOutcomeUnknown(errors.New("invalid response payload")) {
		t.Fatal("response validation failure was classified as unknown")
	}
}

func TestAppListResultCapFailsClosedAtNormalization(t *testing.T) {
	result := map[string]any{
		"apps": []any{map[string]any{
			"applicationType": "user",
			"bundleID":        "com.example.large",
			"displayName":     strings.Repeat("x", maximumAppListResultBytes),
		}},
		"truncated": false,
	}
	failure := validateAppListResult(result)
	if failure == nil || failure.Code != "backendFailed" || failure.Details["stage"] != "resultNormalize" {
		t.Fatalf("failure = %#v", failure)
	}
}

func TestConsumeBrowsePageRejectsMalformedOptionalFields(t *testing.T) {
	base := map[string]any{
		"CFBundleIdentifier":  "com.example.page",
		"CFBundlePackageType": "APPL",
	}
	cases := []struct {
		name     string
		response map[string]any
	}{
		{name: "empty page", response: map[string]any{}},
		{name: "null current list", response: map[string]any{"CurrentList": nil, "Status": "Complete"}},
		{name: "wrong current list", response: map[string]any{"CurrentList": "not-a-list", "Status": "Complete"}},
		{name: "wrong status", response: map[string]any{"CurrentList": []any{base}, "Status": int64(1)}},
		{name: "missing current list before complete", response: map[string]any{"Status": "Processing"}},
	}
	for _, test := range cases {
		t.Run(test.name, func(t *testing.T) {
			apps := []any{}
			_, failure := consumeBrowsePage(test.response, &apps, map[string]struct{}{})
			if failure == nil || failure.Code != "backendFailed" || failure.Details["stage"] != "browseValidate" {
				t.Fatalf("failure = %#v", failure)
			}
		})
	}
}

func TestConsumeBrowsePageAcceptsCompleteWithoutCurrentList(t *testing.T) {
	apps := []any{}
	complete, failure := consumeBrowsePage(map[string]any{"Status": "Complete"}, &apps, map[string]struct{}{})
	if failure != nil || !complete || len(apps) != 0 {
		t.Fatalf("complete=%v failure=%#v apps=%#v", complete, failure, apps)
	}
}

type directBrowseProjectionFixture struct {
	Cases         []directBrowseProjectionCase `json:"cases"`
	SchemaVersion int                          `json:"schemaVersion"`
}

type directBrowseProjectionCase struct {
	ExpectedFailure *directBrowseProjectionFailure `json:"expectedFailure"`
	ExpectedResult  map[string]any                 `json:"expectedResult"`
	Name            string                         `json:"name"`
	Pages           []map[string]any               `json:"pages"`
}

type directBrowseProjectionFailure struct {
	Code  string `json:"code"`
	Stage string `json:"stage"`
}

func TestBrowseProjectionSharedFixture(t *testing.T) {
	_, sourceFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate test source")
	}
	path := filepath.Join(filepath.Dir(sourceFile), "..", "..", "..", "Fixtures", "helper-wire", "direct-browse-projection.v1.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read shared fixture: %v", err)
	}
	var fixture directBrowseProjectionFixture
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatalf("decode shared fixture: %v", err)
	}
	if fixture.SchemaVersion != 1 || len(fixture.Cases) == 0 {
		t.Fatal("invalid shared fixture")
	}

	for _, item := range fixture.Cases {
		item := item
		t.Run(item.Name, func(t *testing.T) {
			projection := newBrowseProjection()
			var failure *Failure
			complete := false
			for _, page := range item.Pages {
				complete, failure = projection.consume(page)
				if failure != nil || complete {
					break
				}
			}
			if item.ExpectedFailure != nil {
				if failure == nil {
					_, failure = projection.result()
				}
				if failure == nil || failure.Code != item.ExpectedFailure.Code || failure.Details["stage"] != item.ExpectedFailure.Stage {
					t.Fatalf("failure = %#v, want code=%s stage=%s", failure, item.ExpectedFailure.Code, item.ExpectedFailure.Stage)
				}
				return
			}
			if failure != nil || !complete {
				t.Fatalf("complete=%v failure=%#v", complete, failure)
			}
			result, failure := projection.result()
			if failure != nil {
				t.Fatalf("result failure = %#v", failure)
			}
			if !reflect.DeepEqual(result, item.ExpectedResult) {
				t.Fatalf("result = %#v, want %#v", result, item.ExpectedResult)
			}
		})
	}
}

type directOneShotFailureFixture struct {
	Cases         []directOneShotFailureCase `json:"cases"`
	SchemaVersion int                        `json:"schemaVersion"`
}

type directOneShotFailureCase struct {
	BackendPayload any            `json:"backendPayload"`
	ExpectedResult map[string]any `json:"expectedResult"`
	Name           string         `json:"name"`
}

func TestRunOneShotProjectsSharedFailureFixture(t *testing.T) {
	t.Setenv("HOME", t.TempDir())
	_, sourceFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("cannot locate test source")
	}
	path := filepath.Join(filepath.Dir(sourceFile), "..", "..", "..", "Fixtures", "helper-wire", "direct-oneshot-failure-projection.v1.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read shared fixture: %v", err)
	}
	var fixture directOneShotFailureFixture
	if err := json.Unmarshal(data, &fixture); err != nil {
		t.Fatalf("decode shared fixture: %v", err)
	}
	if fixture.SchemaVersion != 1 || len(fixture.Cases) == 0 {
		t.Fatal("invalid shared fixture")
	}

	for index, item := range fixture.Cases {
		item := item
		t.Run(item.Name, func(t *testing.T) {
			result, status, types := runOneShotFixtureCase(t, item.BackendPayload, index)
			if status != 1 {
				t.Fatalf("status = %d, want 1", status)
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

func TestRunOneShotHandlesOneRequestAndWritesResultAfterRouteCleanup(t *testing.T) {
	input := bytes.Buffer{}
	writeOneShotInput(t, &input, map[string]any{
		"executorGeneration": int64(3),
		"manifestHash":       strings.Repeat("a", 64),
		"messageID":          "00000000-0000-0000-0000-000000000001",
		"runtimeEpoch":       int64(7),
		"schemaVersion":      int64(1),
		"type":               "HelloAccepted",
	})
	for _, requestID := range []string{
		"00000000-0000-0000-0000-000000000010",
		"00000000-0000-0000-0000-000000000011",
	} {
		writeOneShotInput(t, &input, map[string]any{
			"executorGeneration": int64(3),
			"messageID":          requestID,
			"payload": map[string]any{
				"actionID":            "00000000-0000-0000-0000-000000000015",
				"backendPayload":      map[string]any{"operation": "fixture"},
				"executorOperationID": "direct.fixture",
			},
			"requestID":     requestID,
			"runtimeEpoch":  int64(7),
			"schemaVersion": int64(1),
			"type":          "Request",
		})
	}
	events := []string{}
	output := &oneShotRecordingWriter{events: &events}
	status := runOneShotWithRoute(&input, output, OneShotConfig{
		RuntimeEpoch:         7,
		ConnectionEpoch:      8,
		ExecutorGeneration:   3,
		RawTransportUDID:     "test-transport",
		HelperBuildID:        "pulsephone.direct-helper.v1",
		ManifestHash:         strings.Repeat("a", 64),
		ProcessStartIdentity: "1.000002",
	}, func(_ OneShotConfig, request protocol.Message) (map[string]any, int) {
		events = append(events, "handled:"+*request.RequestID)
		events = append(events, "cleanup:"+*request.RequestID)
		return map[string]any{"ok": true}, 0
	})
	if status != 0 {
		t.Fatalf("status = %d", status)
	}
	if want := []string{
		"handled:00000000-0000-0000-0000-000000000010",
		"cleanup:00000000-0000-0000-0000-000000000010",
		"result",
	}; !reflect.DeepEqual(events, want) {
		t.Fatalf("events = %#v, want %#v", events, want)
	}
	rawMessages := bytes.Split(bytes.TrimSuffix(output.Bytes(), []byte{'\n'}), []byte{'\n'})
	if len(rawMessages) != 5 {
		t.Fatalf("messages = %q", output.String())
	}
	for index, want := range []string{"Hello", "Ready", "Accepted", "Started", "Result"} {
		message, err := protocol.DecodeLine(append(rawMessages[index], '\n'), protocol.HelperToRuntime)
		if err != nil || message.Type != want {
			t.Fatalf("message %d = %#v err=%v, want %s", index, message, err, want)
		}
		if want == "Result" && (message.RequestID == nil || *message.RequestID != "00000000-0000-0000-0000-000000000010") {
			t.Fatalf("result request ID = %#v", message.RequestID)
		}
	}
}

func TestRunOneShotPreservesHighBitWireIdentities(t *testing.T) {
	high := uint64(math.MaxInt64) + 1
	input := bytes.Buffer{}
	writeOneShotInput(t, &input, map[string]any{
		"executorGeneration": high,
		"manifestHash":       strings.Repeat("a", 64),
		"messageID":          "00000000-0000-0000-0000-000000000001",
		"runtimeEpoch":       high,
		"schemaVersion":      int64(1),
		"type":               "HelloAccepted",
	})
	writeOneShotInput(t, &input, map[string]any{
		"executorGeneration": high,
		"messageID":          "00000000-0000-0000-0000-000000000002",
		"payload": map[string]any{
			"actionID":            "00000000-0000-0000-0000-000000000003",
			"backendPayload":      map[string]any{"operation": "fixture"},
			"executorOperationID": "direct.fixture",
		},
		"requestID":     "00000000-0000-0000-0000-000000000004",
		"runtimeEpoch":  high,
		"schemaVersion": int64(1),
		"type":          "Request",
	})
	var output bytes.Buffer
	status := runOneShotWithRoute(&input, &output, OneShotConfig{
		RuntimeEpoch:         high,
		ExecutorGeneration:   high,
		HelperBuildID:        "pulsephone.direct-helper.v1",
		ManifestHash:         strings.Repeat("a", 64),
		ProcessStartIdentity: "1.000002",
	}, func(_ OneShotConfig, _ protocol.Message) (map[string]any, int) {
		return map[string]any{"ok": true}, 0
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

type oneShotRecordingWriter struct {
	bytes.Buffer
	events *[]string
}

func (writer *oneShotRecordingWriter) Write(data []byte) (int, error) {
	if bytes.Contains(data, []byte(`"type":"Result"`)) {
		*writer.events = append(*writer.events, "result")
	}
	return writer.Buffer.Write(data)
}

func runOneShotFixtureCase(t *testing.T, backendPayload any, index int) (map[string]any, int, []string) {
	t.Helper()
	inputReader, inputWriter := io.Pipe()
	var output bytes.Buffer
	status := make(chan int, 1)
	go func() {
		status <- RunOneShot(inputReader, &output, OneShotConfig{
			RuntimeEpoch:         7,
			ConnectionEpoch:      8,
			ExecutorGeneration:   3,
			RawTransportUDID:     "test-transport",
			HelperBuildID:        "pulsephone.direct-helper.v1",
			ManifestHash:         strings.Repeat("a", 64),
			ProcessStartIdentity: "1.000002",
		})
	}()

	writeOneShotInput(t, inputWriter, map[string]any{
		"executorGeneration": int64(3),
		"manifestHash":       strings.Repeat("a", 64),
		"messageID":          "00000000-0000-0000-0000-000000000001",
		"runtimeEpoch":       int64(7),
		"schemaVersion":      int64(1),
		"type":               "HelloAccepted",
	})
	writeOneShotInput(t, inputWriter, map[string]any{
		"executorGeneration": int64(3),
		"messageID":          oneShotFixtureUUID(index, 2),
		"payload": map[string]any{
			"actionID":            oneShotFixtureUUID(index, 3),
			"backendPayload":      backendPayload,
			"executorOperationID": "direct.fixture",
		},
		"requestID":     oneShotFixtureUUID(index, 4),
		"runtimeEpoch":  int64(7),
		"schemaVersion": int64(1),
		"type":          "Request",
	})
	if err := inputWriter.Close(); err != nil {
		t.Fatal(err)
	}
	if got := <-status; got != 1 {
		return nil, got, nil
	}

	rawMessages := bytes.Split(bytes.TrimSuffix(output.Bytes(), []byte{'\n'}), []byte{'\n'})
	if len(rawMessages) == 0 {
		t.Fatalf("no output messages: %q", output.String())
	}
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
	return terminal, 1, types
}

func oneShotFixtureUUID(index, offset int) string {
	return fmt.Sprintf("00000000-0000-0000-0000-%012d", index*10+offset)
}

func writeOneShotInput(t *testing.T, writer io.Writer, fields map[string]any) {
	t.Helper()
	raw, err := protocol.EncodeLine(fields, protocol.RuntimeToHelper)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := writer.Write(raw); err != nil {
		t.Fatal(err)
	}
}
