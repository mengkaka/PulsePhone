package direct

import (
	"context"
	"errors"
	"io"
	"net"
	"reflect"
	"testing"
	"time"
)

const launchTestBundleID = "com.example.LegacyApp"

func TestLaunchRouteCompletesLegacySequenceAndClosesResources(t *testing.T) {
	events := []string{}
	lockdown := &fakeLaunchLockdown{events: &events}
	dtx := &fakeLaunchDTX{events: &events, result: int64(42)}
	result, failure := launchAppWithDependencies(
		OneShotConfig{RawTransportUDID: "raw-device"},
		launchTestPayload(),
		time.Now().Add(time.Minute),
		launchTestDependencies(t, &events, lockdown, dtx, true, nil),
	)
	if failure != nil {
		t.Fatalf("launch failure = %#v", failure)
	}
	if want := map[string]any{
		"bundleID":        launchTestBundleID,
		"disposition":     "launchRequested",
		"resolvedRouteID": "legacy.dvtLaunch",
	}; !reflect.DeepEqual(result, want) {
		t.Fatalf("result = %#v, want %#v", result, want)
	}
	if want := []string{
		"lockdown.open",
		"lookup:" + launchTestBundleID,
		"service.open:" + dvtServiceName,
		"dtx.create",
		"dtx.handshake",
		"dtx.channel:com.apple.instruments.server.services.processcontrol",
		"dtx.invoke:launchSuspendedProcessWithDevicePath:bundleIdentifier:environment:arguments:options:",
		"dtx.close",
		"lockdown.close",
	}; !reflect.DeepEqual(events, want) {
		t.Fatalf("events = %#v, want %#v", events, want)
	}
	if dtx.channel != 1 || !reflect.DeepEqual(dtx.args, []any{
		"", launchTestBundleID, map[string]any{}, []any{}, map[string]any{
			"StartSuspendedKey": false,
			"KillExisting":      true,
		},
	}) {
		t.Fatalf("DTX invocation = channel=%d args=%#v", dtx.channel, dtx.args)
	}
}

func TestLaunchRouteProjectsPreAndPostSubmitFailures(t *testing.T) {
	for _, test := range []struct {
		name          string
		payload       map[string]any
		installed     bool
		startErr      error
		lookupErr     error
		dtxResult     any
		dtxInvokeErr  error
		code          string
		commitState   string
		outcome       string
		details       map[string]any
		wantDTXCreate bool
	}{
		{
			name:        "invalid payload does not open lockdown",
			payload:     map[string]any{"operation": "launch"},
			code:        "appLaunchFailed",
			commitState: "notCommitted",
			outcome:     "failed",
			details:     map[string]any{"commitState": "notCommitted", "stage": "requestValidation"},
		},
		{
			name:        "pre submit timeout is not committed",
			payload:     launchTestPayload(),
			lookupErr:   context.DeadlineExceeded,
			code:        "executionTimeout",
			commitState: "notCommitted",
			outcome:     "failed",
			details:     map[string]any{"commitState": "notCommitted", "stage": "launchDeadline"},
		},
		{
			name:        "missing app does not open DVT",
			payload:     launchTestPayload(),
			installed:   false,
			code:        "appNotInstalled",
			commitState: "notCommitted",
			outcome:     "failed",
			details:     map[string]any{"commitState": "notCommitted", "stage": "installationProxyLookup"},
		},
		{
			name:        "DVT startup failure preserves legacy preparation group",
			payload:     launchTestPayload(),
			installed:   true,
			startErr:    errors.New("DVT unavailable"),
			code:        "developerServicesUnavailable",
			commitState: "notCommitted",
			outcome:     "failed",
			details: map[string]any{
				"phase":              launchStartingServicesPhase,
				"preparationGroupID": legacyPreparationGroupID,
			},
		},
		{
			name:          "invalid DVT PID is known rejection",
			payload:       launchTestPayload(),
			installed:     true,
			dtxResult:     int64(0),
			code:          "appLaunchFailed",
			commitState:   "notCommitted",
			outcome:       "failed",
			details:       map[string]any{"commitState": "notCommitted", "stage": launchResponseStage},
			wantDTXCreate: true,
		},
		{
			name:          "post submit transport is outcome unknown",
			payload:       launchTestPayload(),
			installed:     true,
			dtxInvokeErr:  io.EOF,
			code:          "outcomeUnknown",
			commitState:   "unknown",
			outcome:       "outcomeUnknown",
			details:       map[string]any{"reason": "commitStateUnknown"},
			wantDTXCreate: true,
		},
		{
			name:          "post submit timeout is outcome unknown",
			payload:       launchTestPayload(),
			installed:     true,
			dtxInvokeErr:  context.DeadlineExceeded,
			code:          "outcomeUnknown",
			commitState:   "unknown",
			outcome:       "outcomeUnknown",
			details:       map[string]any{"reason": "commitStateUnknown"},
			wantDTXCreate: true,
		},
	} {
		t.Run(test.name, func(t *testing.T) {
			events := []string{}
			lockdown := &fakeLaunchLockdown{events: &events, startErr: test.startErr}
			dtx := &fakeLaunchDTX{events: &events, result: test.dtxResult, invokeErr: test.dtxInvokeErr}
			_, failure := launchAppWithDependencies(
				OneShotConfig{RawTransportUDID: "raw-device"},
				test.payload,
				time.Now().Add(time.Minute),
				launchTestDependencies(t, &events, lockdown, dtx, test.installed, test.lookupErr),
			)
			if failure == nil || failure.Code != test.code || failure.CommitState != test.commitState || failure.Outcome != test.outcome ||
				!reflect.DeepEqual(failure.Details, test.details) {
				t.Fatalf("failure = %#v", failure)
			}
			if test.wantDTXCreate != dtx.created {
				t.Fatalf("DTX created=%v, want %v; events=%#v", dtx.created, test.wantDTXCreate, events)
			}
			if test.name == "invalid payload does not open lockdown" && len(events) != 0 {
				t.Fatalf("invalid payload opened route: %#v", events)
			}
			if test.name == "missing app does not open DVT" {
				if want := []string{"lockdown.open", "lookup:" + launchTestBundleID, "lockdown.close"}; !reflect.DeepEqual(events, want) {
					t.Fatalf("events = %#v, want %#v", events, want)
				}
			}
		})
	}
}

func TestDirectLookupInstalledSendsExactBundleFilter(t *testing.T) {
	client, server := net.Pipe()
	serverResult := make(chan map[string]any, 1)
	serverError := make(chan error, 1)
	go func() {
		service := newPlistService(server, time.Now().Add(time.Minute))
		defer service.close()
		request, err := service.receive(64 * 1024)
		if err == nil {
			err = service.send(map[string]any{"LookupResult": map[string]any{
				launchTestBundleID: map[string]any{"CFBundleIdentifier": launchTestBundleID},
			}})
		}
		serverResult <- request
		serverError <- err
	}()
	lockdown := &fakeLaunchLockdown{connections: map[string]net.Conn{InstallationProxyService: client}}
	installed, err := directLookupInstalled(lockdown, launchTestBundleID, time.Now().Add(time.Minute))
	if err != nil || !installed {
		t.Fatalf("installed=%v err=%v", installed, err)
	}
	request := <-serverResult
	if err := <-serverError; err != nil {
		t.Fatal(err)
	}
	want := map[string]any{
		"ClientOptions": map[string]any{
			"BundleIDs":        []any{launchTestBundleID},
			"ReturnAttributes": []any{"CFBundleIdentifier"},
		},
		"Command": "Lookup",
	}
	if !reflect.DeepEqual(request, want) {
		t.Fatalf("lookup request = %#v, want %#v", request, want)
	}
}

func launchTestPayload() map[string]any {
	return map[string]any{
		"bundleID":  launchTestBundleID,
		"commandID": "app.launch",
		"operation": "launch",
	}
}

func launchTestDependencies(t *testing.T, events *[]string, lockdown *fakeLaunchLockdown, dtx *fakeLaunchDTX, installed bool, lookupErr error) launchDependencies {
	t.Helper()
	return launchDependencies{
		openLockdown: func(udid string, deadline time.Time) (launchLockdown, error) {
			if udid != "raw-device" || deadline.IsZero() {
				t.Fatal("unexpected lockdown opener input")
			}
			*events = append(*events, "lockdown.open")
			return lockdown, nil
		},
		lookupInstalled: func(_ launchLockdown, bundleID string, deadline time.Time) (bool, error) {
			if deadline.IsZero() {
				t.Fatal("lookup deadline")
			}
			*events = append(*events, "lookup:"+bundleID)
			return installed, lookupErr
		},
		newDTX: func(conn net.Conn, deadline time.Time) launchDTX {
			if conn != lockdown.conn || deadline.IsZero() {
				t.Fatal("unexpected DTX input")
			}
			*events = append(*events, "dtx.create")
			dtx.conn = conn
			dtx.created = true
			return dtx
		},
	}
}

type fakeLaunchLockdown struct {
	conn        net.Conn
	connections map[string]net.Conn
	events      *[]string
	startErr    error
}

func (lockdown *fakeLaunchLockdown) StartService(name string) (net.Conn, error) {
	if lockdown.events != nil {
		*lockdown.events = append(*lockdown.events, "service.open:"+name)
	}
	if lockdown.startErr != nil {
		return nil, lockdown.startErr
	}
	if conn, ok := lockdown.connections[name]; ok {
		lockdown.conn = conn
		return conn, nil
	}
	client, server := net.Pipe()
	_ = server.Close()
	lockdown.conn = client
	return client, nil
}

func (lockdown *fakeLaunchLockdown) Close() {
	if lockdown.events != nil {
		*lockdown.events = append(*lockdown.events, "lockdown.close")
	}
}

type fakeLaunchDTX struct {
	args         []any
	channel      int32
	conn         net.Conn
	created      bool
	events       *[]string
	handshakeErr error
	invokeErr    error
	result       any
}

func (dtx *fakeLaunchDTX) close() error {
	*dtx.events = append(*dtx.events, "dtx.close")
	if dtx.conn != nil {
		return dtx.conn.Close()
	}
	return nil
}

func (dtx *fakeLaunchDTX) handshake() error {
	*dtx.events = append(*dtx.events, "dtx.handshake")
	return dtx.handshakeErr
}

func (dtx *fakeLaunchDTX) openChannel(identifier string) (int32, error) {
	*dtx.events = append(*dtx.events, "dtx.channel:"+identifier)
	return 1, nil
}

func (dtx *fakeLaunchDTX) invoke(channel int32, method string, args ...any) (any, error) {
	*dtx.events = append(*dtx.events, "dtx.invoke:"+method)
	dtx.channel = channel
	dtx.args = args
	return dtx.result, dtx.invokeErr
}
