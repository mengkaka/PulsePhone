package direct

import (
	"context"
	"errors"
	"io"
	"net"
	"reflect"
	"strconv"
	"testing"
	"time"
)

const uninstallTestBundleID = "com.example.UninstallFixture"

const installTestBundleID = "com.example.InstallFixture"

func TestInstallRouteCompletesLegacySequenceAndClosesResources(t *testing.T) {
	events := []string{}
	source := &fakeInstallRouteSource{events: &events}
	afc := &fakeInstallRouteAFC{events: &events, handle: 41}
	service := &fakeInstallRouteService{events: &events, responses: []map[string]any{{"Status": "Complete"}}}
	lockdown := &fakeInstallRouteLockdown{events: &events}
	deadline := time.Now().Add(time.Minute)
	result, failure := installAppWithDependencies(
		OneShotConfig{RawTransportUDID: "raw-device"},
		"00000000-0000-0000-0000-000000000001",
		installTestPayload(),
		deadline,
		installTestDependencies(t, &events, source, afc, service, lockdown),
	)
	if failure != nil {
		t.Fatalf("install failure = %#v", failure)
	}
	if want := map[string]any{"bundleID": installTestBundleID, "disposition": "installed"}; !reflect.DeepEqual(result, want) {
		t.Fatalf("result = %#v, want %#v", result, want)
	}
	if want := []map[string]any{{
		"ClientOptions": map[string]any{},
		"Command":       "Install",
		"PackagePath":   remoteStagingDirectory + "/00000000-0000-0000-0000-000000000001.ipa",
	}}; !reflect.DeepEqual(service.sent, want) {
		t.Fatalf("requests = %#v, want %#v", service.sent, want)
	}
	if len(service.deadlines) != 1 || !service.deadlines[0].Before(deadline) {
		t.Fatalf("response deadline = %#v, expected a reserved deadline before %s", service.deadlines, deadline)
	}
	if want := []string{
		"source.open",
		"lockdown.open",
		"service.open:" + AFCServiceName,
		"afc.create",
		"afc.exists:" + remoteStagingDirectory,
		"afc.mkdir:" + remoteStagingDirectory,
		"afc.upload:" + remoteStagingDirectory + "/00000000-0000-0000-0000-000000000001.ipa",
		"afc.finalize:41",
		"source.verify",
		"service.open:" + InstallationProxyService,
		"proxy.create",
		"deadline.set",
		"install.send",
		"install.receive",
		"proxy.close",
		"afc.remove:" + remoteStagingDirectory + "/00000000-0000-0000-0000-000000000001.ipa",
		"afc.close",
		"lockdown.close",
		"source.close",
	}; !reflect.DeepEqual(events, want) {
		t.Fatalf("events = %#v, want %#v", events, want)
	}
}

func TestInstallRouteDoesNotCreateExistingStagingDirectory(t *testing.T) {
	events := []string{}
	source := &fakeInstallRouteSource{events: &events}
	afc := &fakeInstallRouteAFC{events: &events, exists: true, handle: 41}
	service := &fakeInstallRouteService{events: &events, responses: []map[string]any{{"Status": "Complete"}}}
	lockdown := &fakeInstallRouteLockdown{events: &events}
	_, failure := installAppWithDependencies(
		OneShotConfig{RawTransportUDID: "raw-device"},
		"00000000-0000-0000-0000-000000000001",
		installTestPayload(),
		time.Now().Add(time.Minute),
		installTestDependencies(t, &events, source, afc, service, lockdown),
	)
	if failure != nil {
		t.Fatalf("install failure = %#v", failure)
	}
	if containsEvent(events, "afc.mkdir:"+remoteStagingDirectory) {
		t.Fatalf("existing staging directory was recreated: %#v", events)
	}
}

func TestInstallRouteProjectsPreAndPostCommitFailures(t *testing.T) {
	for _, test := range []struct {
		name        string
		afcUpload   error
		openIPA     error
		receiveErr  error
		responses   []map[string]any
		verifyErr   error
		code        string
		commit      string
		outcome     string
		details     map[string]any
		wantService bool
	}{
		{
			name:    "IPA preflight failure",
			openIPA: errors.New("invalid archive"),
			code:    "invalidIPA",
			commit:  "notCommitted",
			outcome: "failed",
			details: map[string]any{"commitState": "notCommitted", "stage": "archivePreflight"},
		},
		{
			name:      "AFC upload failure is not committed",
			afcUpload: errors.New("read failure"),
			code:      "installFailed",
			commit:    "notCommitted",
			outcome:   "failed",
			details:   map[string]any{"commitState": "notCommitted", "stage": "afcUpload"},
		},
		{
			name:      "archive mutation is invalid IPA",
			verifyErr: errors.New("changed"),
			code:      "invalidIPA",
			commit:    "notCommitted",
			outcome:   "failed",
			details:   map[string]any{"commitState": "notCommitted", "stage": "archiveReadRace"},
		},
		{
			name:        "explicit rejection is committed failure",
			responses:   []map[string]any{{"Error": "ApplicationVerificationFailed"}},
			code:        "installFailed",
			commit:      "committed",
			outcome:     "failed",
			details:     map[string]any{"commitState": "committed", "stage": "installationProxyResponse"},
			wantService: true,
		},
		{
			name:        "response uncertainty is outcome unknown",
			receiveErr:  io.EOF,
			code:        "outcomeUnknown",
			commit:      "unknown",
			outcome:     "outcomeUnknown",
			details:     map[string]any{"reason": "commitStateUnknown"},
			wantService: true,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			events := []string{}
			source := &fakeInstallRouteSource{events: &events, verifyErr: test.verifyErr}
			afc := &fakeInstallRouteAFC{events: &events, handle: 41, uploadErr: test.afcUpload}
			service := &fakeInstallRouteService{events: &events, receiveErr: test.receiveErr, responses: test.responses}
			lockdown := &fakeInstallRouteLockdown{events: &events}
			dependencies := installTestDependencies(t, &events, source, afc, service, lockdown)
			if test.openIPA != nil {
				dependencies.openIPA = func(string) (installRouteSource, error) {
					events = append(events, "source.open")
					return nil, test.openIPA
				}
			}
			_, failure := installAppWithDependencies(
				OneShotConfig{RawTransportUDID: "raw-device"},
				"00000000-0000-0000-0000-000000000001",
				installTestPayload(),
				time.Now().Add(time.Minute),
				dependencies,
			)
			if failure == nil || failure.Code != test.code || failure.CommitState != test.commit || failure.Outcome != test.outcome ||
				!reflect.DeepEqual(failure.Details, test.details) {
				t.Fatalf("failure = %#v", failure)
			}
			if test.wantService && !containsEvent(events, "proxy.create") {
				t.Fatalf("service was not opened: %#v", events)
			}
			if test.openIPA == nil && (events[len(events)-1] != "source.close" || events[len(events)-2] != "lockdown.close") {
				t.Fatalf("resources were not closed in order: %#v", events)
			}
		})
	}
}

func TestInstallRouteRejectsPayloadBeforeOpeningSourceOrDevice(t *testing.T) {
	for _, test := range []struct {
		name      string
		requestID string
		payload   map[string]any
		code      string
		stage     string
	}{
		{name: "missing request ID", payload: installTestPayload(), code: "installFailed", stage: "requestValidation"},
		{name: "extra payload field", requestID: "request", payload: map[string]any{"ipaPath": "/tmp/Fixture.ipa", "operation": "install", "unexpected": true}, code: "invalidIPA", stage: "archivePreflight"},
		{name: "wrong path type", requestID: "request", payload: map[string]any{"ipaPath": int64(7), "operation": "install"}, code: "invalidIPA", stage: "archivePreflight"},
	} {
		t.Run(test.name, func(t *testing.T) {
			opened := false
			_, failure := installAppWithDependencies(
				OneShotConfig{RawTransportUDID: "raw-device"},
				test.requestID,
				test.payload,
				time.Now().Add(time.Minute),
				installDependencies{
					openIPA: func(string) (installRouteSource, error) {
						opened = true
						return nil, errors.New("must not open")
					},
				},
			)
			if opened || failure == nil || failure.Code != test.code || failure.CommitState != "notCommitted" ||
				!reflect.DeepEqual(failure.Details, map[string]any{"commitState": "notCommitted", "stage": test.stage}) {
				t.Fatalf("opened=%v failure=%#v", opened, failure)
			}
		})
	}
}

func TestUninstallRouteCompletesLegacySequenceAndClosesResources(t *testing.T) {
	events := []string{}
	service := &fakeUninstallRouteService{
		events: &events,
		responses: []map[string]any{
			{"LookupResult": map[string]any{
				uninstallTestBundleID: map[string]any{"CFBundleIdentifier": uninstallTestBundleID},
			}},
			{"Status": "Complete"},
		},
	}
	lockdown := &fakeUninstallRouteLockdown{events: &events}
	deadline := time.Now().Add(time.Minute)
	result, failure := uninstallAppWithDependencies(
		OneShotConfig{RawTransportUDID: "raw-device"},
		uninstallTestPayload(),
		deadline,
		uninstallTestDependencies(t, &events, lockdown, service),
	)
	if failure != nil {
		t.Fatalf("uninstall failure = %#v", failure)
	}
	if want := map[string]any{"bundleID": uninstallTestBundleID, "disposition": "uninstalled"}; !reflect.DeepEqual(result, want) {
		t.Fatalf("result = %#v, want %#v", result, want)
	}
	wantRequests := []map[string]any{
		{
			"ClientOptions": map[string]any{
				"BundleIDs":        []any{uninstallTestBundleID},
				"ReturnAttributes": []any{"CFBundleIdentifier"},
			},
			"Command": "Lookup",
		},
		{
			"ApplicationIdentifier": uninstallTestBundleID,
			"ClientOptions":         map[string]any{},
			"Command":               "Uninstall",
		},
	}
	if !reflect.DeepEqual(service.sent, wantRequests) {
		t.Fatalf("requests = %#v, want %#v", service.sent, wantRequests)
	}
	if len(service.deadlines) != 1 || !service.deadlines[0].Before(deadline) {
		t.Fatalf("response deadline = %#v, expected a reserved deadline before %s", service.deadlines, deadline)
	}
	if wantEvents := []string{
		"lockdown.open",
		"service.open",
		"service.create",
		"lookup.send",
		"lookup.receive",
		"deadline.set",
		"uninstall.send",
		"uninstall.receive",
		"service.close",
		"lockdown.close",
	}; !reflect.DeepEqual(events, wantEvents) {
		t.Fatalf("events = %#v, want %#v", events, wantEvents)
	}
}

func TestUninstallRouteMissingAppDoesNotSubmit(t *testing.T) {
	events := []string{}
	service := &fakeUninstallRouteService{events: &events, responses: []map[string]any{{"LookupResult": map[string]any{}}}}
	lockdown := &fakeUninstallRouteLockdown{events: &events}
	_, failure := uninstallAppWithDependencies(
		OneShotConfig{RawTransportUDID: "raw-device"},
		uninstallTestPayload(),
		time.Now().Add(time.Minute),
		uninstallTestDependencies(t, &events, lockdown, service),
	)
	if failure == nil || failure.Code != "appNotInstalled" || failure.CommitState != "notCommitted" || failure.Outcome != "failed" ||
		!reflect.DeepEqual(failure.Details, map[string]any{"commitState": "notCommitted", "stage": "installationProxyLookup"}) {
		t.Fatalf("failure = %#v", failure)
	}
	if want := []map[string]any{{
		"ClientOptions": map[string]any{
			"BundleIDs":        []any{uninstallTestBundleID},
			"ReturnAttributes": []any{"CFBundleIdentifier"},
		},
		"Command": "Lookup",
	}}; !reflect.DeepEqual(service.sent, want) {
		t.Fatalf("requests = %#v, want %#v", service.sent, want)
	}
	if want := []string{"lockdown.open", "service.open", "service.create", "lookup.send", "lookup.receive", "service.close", "lockdown.close"}; !reflect.DeepEqual(events, want) {
		t.Fatalf("events = %#v, want %#v", events, want)
	}
}

func TestUninstallRouteProjectsCommitBoundaryFailures(t *testing.T) {
	for _, test := range []struct {
		name       string
		sendErrors []error
		responses  []map[string]any
		receiveErr []error
		code       string
		commit     string
		outcome    string
		details    map[string]any
	}{
		{
			name: "explicit rejection is committed failure",
			responses: []map[string]any{
				uninstallLookupInstalledResponse(),
				{"Error": "rejected"},
			},
			code:    "uninstallFailed",
			commit:  "committed",
			outcome: "failed",
			details: map[string]any{"commitState": "committed", "stage": "installationProxyResponse"},
		},
		{
			name:       "lookup timeout is known not committed failure",
			receiveErr: []error{context.DeadlineExceeded},
			code:       "uninstallFailed",
			commit:     "notCommitted",
			outcome:    "failed",
			details:    map[string]any{"commitState": "notCommitted", "stage": "uninstallDeadline"},
		},
		{
			name:       "uninstall request uncertainty is outcome unknown",
			sendErrors: []error{nil, errors.New("send failed")},
			responses:  []map[string]any{uninstallLookupInstalledResponse()},
			code:       "outcomeUnknown",
			commit:     "unknown",
			outcome:    "outcomeUnknown",
			details:    map[string]any{"reason": "commitStateUnknown"},
		},
		{
			name:       "uninstall response uncertainty is outcome unknown",
			responses:  []map[string]any{uninstallLookupInstalledResponse()},
			receiveErr: []error{nil, io.EOF},
			code:       "outcomeUnknown",
			commit:     "unknown",
			outcome:    "outcomeUnknown",
			details:    map[string]any{"reason": "commitStateUnknown"},
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			events := []string{}
			service := &fakeUninstallRouteService{
				events:        &events,
				receiveErrors: test.receiveErr,
				responses:     test.responses,
				sendErrors:    test.sendErrors,
			}
			lockdown := &fakeUninstallRouteLockdown{events: &events}
			_, failure := uninstallAppWithDependencies(
				OneShotConfig{RawTransportUDID: "raw-device"},
				uninstallTestPayload(),
				time.Now().Add(time.Minute),
				uninstallTestDependencies(t, &events, lockdown, service),
			)
			if failure == nil || failure.Code != test.code || failure.CommitState != test.commit || failure.Outcome != test.outcome ||
				!reflect.DeepEqual(failure.Details, test.details) {
				t.Fatalf("failure = %#v", failure)
			}
			if want := "service.close"; events[len(events)-2] != want || events[len(events)-1] != "lockdown.close" {
				t.Fatalf("resources were not closed in order: %#v", events)
			}
		})
	}
}

func TestUninstallRouteRejectsPayloadBeforeDeviceAndProjectsServiceOpen(t *testing.T) {
	for _, payload := range []map[string]any{
		{"operation": "uninstall"},
		{"bundleID": uninstallTestBundleID, "operation": "uninstall", "unexpected": true},
		{"bundleID": "", "operation": "uninstall"},
		{"bundleID": 7, "operation": "uninstall"},
	} {
		called := false
		_, failure := uninstallAppWithDependencies(
			OneShotConfig{RawTransportUDID: "raw-device"},
			payload,
			time.Now().Add(time.Minute),
			uninstallDependencies{
				openLockdown: func(string, time.Time) (uninstallRouteLockdown, error) {
					called = true
					return nil, errors.New("must not open")
				},
			},
		)
		if called || failure == nil || failure.Code != "uninstallFailed" || failure.CommitState != "notCommitted" ||
			!reflect.DeepEqual(failure.Details, map[string]any{"commitState": "notCommitted", "stage": "requestValidation"}) {
			t.Fatalf("payload %#v produced called=%v failure=%#v", payload, called, failure)
		}
	}

	_, failure := uninstallAppWithDependencies(
		OneShotConfig{RawTransportUDID: "raw-device"},
		uninstallTestPayload(),
		time.Now().Add(time.Minute),
		uninstallDependencies{
			openLockdown: func(string, time.Time) (uninstallRouteLockdown, error) {
				return nil, errors.New("service unavailable")
			},
		},
	)
	if failure == nil || failure.Code != "uninstallFailed" || failure.CommitState != "notCommitted" ||
		!reflect.DeepEqual(failure.Details, map[string]any{"commitState": "notCommitted", "stage": "serviceOpen"}) {
		t.Fatalf("service-open failure = %#v", failure)
	}
}

func uninstallTestPayload() map[string]any {
	return map[string]any{"bundleID": uninstallTestBundleID, "operation": "uninstall"}
}

func uninstallLookupInstalledResponse() map[string]any {
	return map[string]any{"LookupResult": map[string]any{
		uninstallTestBundleID: map[string]any{"CFBundleIdentifier": uninstallTestBundleID},
	}}
}

func uninstallTestDependencies(t *testing.T, events *[]string, lockdown *fakeUninstallRouteLockdown, service *fakeUninstallRouteService) uninstallDependencies {
	t.Helper()
	return uninstallDependencies{
		openLockdown: func(udid string, deadline time.Time) (uninstallRouteLockdown, error) {
			if udid != "raw-device" || deadline.IsZero() {
				t.Fatal("unexpected lockdown opener input")
			}
			*events = append(*events, "lockdown.open")
			return lockdown, nil
		},
		newService: func(conn net.Conn, deadline time.Time) uninstallRouteService {
			if conn != lockdown.conn || deadline.IsZero() {
				t.Fatal("unexpected service input")
			}
			*events = append(*events, "service.create")
			service.conn = conn
			return service
		},
	}
}

type fakeUninstallRouteLockdown struct {
	conn     net.Conn
	events   *[]string
	startErr error
}

func (lockdown *fakeUninstallRouteLockdown) StartService(name string) (net.Conn, error) {
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

func (lockdown *fakeUninstallRouteLockdown) Close() {
	*lockdown.events = append(*lockdown.events, "lockdown.close")
}

type fakeUninstallRouteService struct {
	conn          net.Conn
	deadlines     []time.Time
	events        *[]string
	receiveErrors []error
	responses     []map[string]any
	sendErrors    []error
	sent          []map[string]any
}

func (service *fakeUninstallRouteService) send(value map[string]any) error {
	command, _ := value["Command"].(string)
	*service.events = append(*service.events, map[string]string{"Lookup": "lookup.send", "Uninstall": "uninstall.send"}[command])
	service.sent = append(service.sent, value)
	if len(service.sendErrors) == 0 {
		return nil
	}
	err := service.sendErrors[0]
	service.sendErrors = service.sendErrors[1:]
	return err
}

func (service *fakeUninstallRouteService) receive(maximum int) (map[string]any, error) {
	if maximum != maximumInstallationResponseLen {
		return nil, errors.New("unexpected maximum response length")
	}
	command := "lookup"
	if len(service.sent) > 1 {
		command = "uninstall"
	}
	*service.events = append(*service.events, command+".receive")
	if len(service.receiveErrors) > 0 {
		err := service.receiveErrors[0]
		service.receiveErrors = service.receiveErrors[1:]
		if err != nil {
			return nil, err
		}
	}
	if len(service.responses) == 0 {
		return nil, errors.New("missing response")
	}
	response := service.responses[0]
	service.responses = service.responses[1:]
	return response, nil
}

func (service *fakeUninstallRouteService) close() {
	*service.events = append(*service.events, "service.close")
	if service.conn != nil {
		_ = service.conn.Close()
	}
}

func (service *fakeUninstallRouteService) setDeadline(deadline time.Time) {
	*service.events = append(*service.events, "deadline.set")
	service.deadlines = append(service.deadlines, deadline)
}

func installTestPayload() map[string]any {
	return map[string]any{"ipaPath": "/tmp/Fixture.ipa", "operation": "install"}
}

func installTestDependencies(t *testing.T, events *[]string, source *fakeInstallRouteSource, afc *fakeInstallRouteAFC, service *fakeInstallRouteService, lockdown *fakeInstallRouteLockdown) installDependencies {
	t.Helper()
	return installDependencies{
		openIPA: func(path string) (installRouteSource, error) {
			if path != "/tmp/Fixture.ipa" {
				t.Fatalf("IPA path = %q", path)
			}
			*events = append(*events, "source.open")
			return source, nil
		},
		openLockdown: func(udid string, deadline time.Time) (installRouteLockdown, error) {
			if udid != "raw-device" || deadline.IsZero() {
				t.Fatal("unexpected lockdown opener input")
			}
			*events = append(*events, "lockdown.open")
			return lockdown, nil
		},
		newAFC: func(conn net.Conn, deadline time.Time) installRouteAFC {
			if conn != lockdown.connections[0] || deadline.IsZero() {
				t.Fatal("unexpected AFC input")
			}
			*events = append(*events, "afc.create")
			afc.conn = conn
			return afc
		},
		newService: func(conn net.Conn, deadline time.Time) installRouteService {
			if conn != lockdown.connections[1] || deadline.IsZero() {
				t.Fatal("unexpected InstallationProxy input")
			}
			*events = append(*events, "proxy.create")
			service.conn = conn
			return service
		},
	}
}

type fakeInstallRouteSource struct {
	closed    bool
	events    *[]string
	verifyErr error
}

func (source *fakeInstallRouteSource) BundleID() string { return installTestBundleID }

func (source *fakeInstallRouteSource) Close() error {
	source.closed = true
	*source.events = append(*source.events, "source.close")
	return nil
}

func (source *fakeInstallRouteSource) ReadAt(buffer []byte, offset int64) (int, error) {
	if offset != 0 || len(buffer) != 3 {
		return 0, errors.New("unexpected source read")
	}
	copy(buffer, []byte("ipa"))
	return len(buffer), nil
}

func (source *fakeInstallRouteSource) Size() int64 { return 3 }

func (source *fakeInstallRouteSource) VerifyUnchanged() error {
	*source.events = append(*source.events, "source.verify")
	return source.verifyErr
}

type fakeInstallRouteAFC struct {
	conn          net.Conn
	events        *[]string
	exists        bool
	existsErr     error
	handle        uint64
	makeDirErrors map[string]error
	uploadErr     error
}

func (afc *fakeInstallRouteAFC) Close() error {
	*afc.events = append(*afc.events, "afc.close")
	if afc.conn != nil {
		return afc.conn.Close()
	}
	return nil
}

func (afc *fakeInstallRouteAFC) CloseFile(handle uint64) error {
	*afc.events = append(*afc.events, "afc.finalize:"+strconv.FormatUint(handle, 10))
	return nil
}

func (afc *fakeInstallRouteAFC) Exists(path string) (bool, error) {
	*afc.events = append(*afc.events, "afc.exists:"+path)
	return afc.exists, afc.existsErr
}

func (afc *fakeInstallRouteAFC) MakeDir(path string) error {
	*afc.events = append(*afc.events, "afc.mkdir:"+path)
	return afc.makeDirErrors[path]
}

func (afc *fakeInstallRouteAFC) Remove(path string) error {
	*afc.events = append(*afc.events, "afc.remove:"+path)
	return nil
}

func (afc *fakeInstallRouteAFC) Upload(path string, source io.ReaderAt, size int64) (uint64, error) {
	*afc.events = append(*afc.events, "afc.upload:"+path)
	if afc.uploadErr != nil {
		return 0, afc.uploadErr
	}
	buffer := make([]byte, size)
	read, err := source.ReadAt(buffer, 0)
	if err != nil || int64(read) != size {
		return 0, errors.New("unexpected upload source")
	}
	return afc.handle, nil
}

type fakeInstallRouteLockdown struct {
	connections []net.Conn
	events      *[]string
	next        int
	startErr    error
}

func (lockdown *fakeInstallRouteLockdown) Close() {
	*lockdown.events = append(*lockdown.events, "lockdown.close")
}

func (lockdown *fakeInstallRouteLockdown) StartService(name string) (net.Conn, error) {
	*lockdown.events = append(*lockdown.events, "service.open:"+name)
	if lockdown.startErr != nil {
		return nil, lockdown.startErr
	}
	if lockdown.next == len(lockdown.connections) {
		client, server := net.Pipe()
		_ = server.Close()
		lockdown.connections = append(lockdown.connections, client)
	}
	conn := lockdown.connections[lockdown.next]
	lockdown.next++
	return conn, nil
}

type fakeInstallRouteService struct {
	conn       net.Conn
	deadlines  []time.Time
	events     *[]string
	receiveErr error
	responses  []map[string]any
	sent       []map[string]any
}

func (service *fakeInstallRouteService) close() {
	*service.events = append(*service.events, "proxy.close")
	if service.conn != nil {
		_ = service.conn.Close()
	}
}

func (service *fakeInstallRouteService) receive(maximum int) (map[string]any, error) {
	if maximum != maximumInstallationResponseLen {
		return nil, errors.New("unexpected maximum response length")
	}
	*service.events = append(*service.events, "install.receive")
	if service.receiveErr != nil {
		return nil, service.receiveErr
	}
	if len(service.responses) == 0 {
		return nil, errors.New("missing response")
	}
	response := service.responses[0]
	service.responses = service.responses[1:]
	return response, nil
}

func (service *fakeInstallRouteService) send(value map[string]any) error {
	*service.events = append(*service.events, "install.send")
	service.sent = append(service.sent, value)
	return nil
}

func (service *fakeInstallRouteService) setDeadline(deadline time.Time) {
	*service.events = append(*service.events, "deadline.set")
	service.deadlines = append(service.deadlines, deadline)
}

func containsEvent(events []string, want string) bool {
	for _, event := range events {
		if event == want {
			return true
		}
	}
	return false
}
