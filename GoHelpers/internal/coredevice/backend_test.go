package coredevice

import (
	"context"
	"errors"
	"fmt"
	"net"
	"testing"
	"time"

	"pulsephone/GoHelpers/internal/protocol"
)

func TestPersonalizedRequestFailureMatchesPythonLifecycle(t *testing.T) {
	tss := personalizedRequestFailure(personalizationServiceUnavailableError())
	if tss.Code != "personalizationServiceUnavailable" || tss.Phase != "personalizationTSS" || tss.RetireGeneration {
		t.Fatalf("TSS failure = %#v", tss)
	}

	other := personalizedRequestFailure(personalizedError("catalog shape"))
	if other.Code != "developerSupportUnavailable" || other.Phase != "startingDeviceServices" || !other.RetireGeneration {
		t.Fatalf("personalized failure = %#v", other)
	}
	probe := personalizedRequestFailure(personalizedErrorAt("service unavailable", "probingServices"))
	if probe.Code != "developerSupportUnavailable" || probe.Phase != "probingServices" || !probe.RetireGeneration {
		t.Fatalf("post-mount probe failure = %#v", probe)
	}
}

func TestBackendBindsRuntimeGenerationAndReconnectsCoordinator(t *testing.T) {
	backend, err := NewBackendForRuntime(9, 11, "device", 4, testServiceNames())
	if err != nil {
		t.Fatal(err)
	}
	if backend.runtimeEpoch != 9 || backend.executorGeneration != 11 {
		t.Fatalf("backend identity = runtime %d generation %d", backend.runtimeEpoch, backend.executorGeneration)
	}
	if err := backend.Reattach(5); err != nil {
		t.Fatal(err)
	}
	if backend.connectionEpoch != 5 {
		t.Fatalf("connection epoch = %d", backend.connectionEpoch)
	}
	if err := backend.RetireGeneration("incompatible"); err != nil {
		t.Fatal(err)
	}
	if err := backend.Close(); err != nil {
		t.Fatal(err)
	}
	if err := backend.Reattach(6); err == nil {
		t.Fatal("closed backend accepted reconnect")
	}
}

func TestBackendRejectsStaleOrDuplicateReattachWithoutDiscardingStreams(t *testing.T) {
	backend, err := NewBackendForRuntime(9, 11, "device", 4, testServiceNames())
	if err != nil {
		t.Fatal(err)
	}
	defer backend.Close()
	stream := &backendStream{route: "coredevice.pointerStream"}
	backend.streams["session"] = stream
	backend.keyboardID = 99
	backend.keyboardReady = true

	if err := backend.Reattach(4); err != nil {
		t.Fatalf("duplicate epoch reattach: %v", err)
	}
	if backend.streams["session"] != stream || backend.keyboardID != 99 || !backend.keyboardReady {
		t.Fatal("duplicate epoch discarded active backend state")
	}
	if err := backend.Reattach(3); err == nil {
		t.Fatal("stale reattach accepted")
	}
	if backend.streams["session"] != stream || backend.keyboardID != 99 || !backend.keyboardReady {
		t.Fatal("stale reattach discarded active backend state")
	}
}

func TestBackendWarmReportsAlreadyReadyForCachedGeneration(t *testing.T) {
	backend := &Backend{
		tunnel:             &CoreDeviceTunnelLease{},
		services:           map[string]*CoreDeviceService{coreDeviceServiceHID: {}},
		executorGeneration: 11,
		surfaceRevision:    "surface.test",
	}
	result, err := backend.Execute(protocol.Message{Payload: map[string]any{
		"backendPayload":      map[string]any{"operation": "warmGeneration", "preparationGroupID": PreparationGroupID},
		"executorOperationID": "coredevice.warmGeneration",
	}})
	if err != nil {
		t.Fatal(err)
	}
	if result["disposition"] != "alreadyReady" || result["executorGeneration"] != uint64(11) || result["surfaceRevision"] != "surface.test" {
		t.Fatalf("warm result = %#v", result)
	}
}

func TestBackendRotateMatchesLegacyConfirmationContract(t *testing.T) {
	type observation struct {
		geometry map[string]any
		err      error
	}
	type testCase struct {
		current          string
		direction        string
		name             string
		observations     []observation
		response         string
		wantError        bool
		wantOrientation  string
		wantObservations int
		wantSampleCount  int64
	}
	geometry := func(orientation string) map[string]any {
		width, height := int64(1170), int64(2532)
		if orientation == "landscapeLeft" || orientation == "landscapeRight" {
			width, height = height, width
		}
		return map[string]any{"logicalHeight": height, "logicalWidth": width, "orientation": orientation}
	}
	tests := []testCase{
		{name: "request timeout", current: "portrait", direction: "left", wantError: true},
		{name: "portrait right", current: "portrait", direction: "right", response: "landscapeRight", observations: []observation{{geometry: geometry("landscapeRight")}}, wantOrientation: "landscapeRight", wantObservations: 1, wantSampleCount: 1},
		{name: "landscape right right", current: "landscapeRight", direction: "right", response: "portraitUpsideDown", observations: []observation{{geometry: geometry("portraitUpsideDown")}}, wantOrientation: "portraitUpsideDown", wantObservations: 1, wantSampleCount: 1},
		{name: "upside down right", current: "portraitUpsideDown", direction: "right", response: "landscapeLeft", observations: []observation{{geometry: geometry("landscapeLeft")}}, wantOrientation: "landscapeLeft", wantObservations: 1, wantSampleCount: 1},
		{name: "landscape left right", current: "landscapeLeft", direction: "right", response: "portrait", observations: []observation{{geometry: geometry("portrait")}}, wantOrientation: "portrait", wantObservations: 1, wantSampleCount: 1},
		{name: "portrait left", current: "portrait", direction: "left", response: "landscapeLeft", observations: []observation{{geometry: geometry("landscapeLeft")}}, wantOrientation: "landscapeLeft", wantObservations: 1, wantSampleCount: 1},
		{name: "landscape left left", current: "landscapeLeft", direction: "left", response: "portraitUpsideDown", observations: []observation{{geometry: geometry("portraitUpsideDown")}}, wantOrientation: "portraitUpsideDown", wantObservations: 1, wantSampleCount: 1},
		{name: "upside down left", current: "portraitUpsideDown", direction: "left", response: "landscapeRight", observations: []observation{{geometry: geometry("landscapeRight")}}, wantOrientation: "landscapeRight", wantObservations: 1, wantSampleCount: 1},
		{name: "landscape right left", current: "landscapeRight", direction: "left", response: "portrait", observations: []observation{{geometry: geometry("portrait")}}, wantOrientation: "portrait", wantObservations: 1, wantSampleCount: 1},
		{name: "unchanged", current: "portrait", direction: "right", response: "portrait", observations: []observation{{geometry: geometry("portrait")}, {geometry: geometry("portrait")}, {geometry: geometry("portrait")}}, wantOrientation: "portrait", wantObservations: 3, wantSampleCount: 3},
		{name: "stale geometry does not repeat rotate", current: "portrait", direction: "right", response: "landscapeRight", observations: []observation{{geometry: geometry("portrait")}, {geometry: geometry("portrait")}, {geometry: geometry("portrait")}}, wantOrientation: "portrait", wantObservations: 3, wantSampleCount: 3},
		{name: "confirm after retry", current: "portrait", direction: "right", response: "landscapeRight", observations: []observation{{geometry: geometry("portrait")}, {geometry: geometry("landscapeRight")}}, wantOrientation: "landscapeRight", wantObservations: 2, wantSampleCount: 2},
		{name: "confirm on last sample", current: "portrait", direction: "right", response: "landscapeRight", observations: []observation{{geometry: geometry("portrait")}, {geometry: geometry("portrait")}, {geometry: geometry("landscapeRight")}}, wantOrientation: "landscapeRight", wantObservations: 3, wantSampleCount: 3},
		{name: "mismatch", current: "portrait", direction: "right", response: "portraitUpsideDown", observations: []observation{{geometry: geometry("landscapeLeft")}, {geometry: geometry("landscapeLeft")}, {geometry: geometry("landscapeLeft")}}, wantOrientation: "landscapeLeft", wantObservations: 3, wantSampleCount: 3},
		{name: "bounded observer failures", current: "portrait", direction: "right", response: "landscapeRight", observations: []observation{{err: errors.New("observer timeout")}, {err: errors.New("observer timeout")}, {err: errors.New("observer timeout")}}, wantError: true, wantObservations: 3},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			requests := 0
			observations := 0
			waits := 0
			backend := &Backend{
				connectionEpoch: 3,
				tunnel:          &CoreDeviceTunnelLease{},
				services:        map[string]*CoreDeviceService{coreDeviceServiceOrientation: {}},
				orientationRequest: func(_ *CoreDeviceService, request map[string]any, _ time.Time) (map[string]any, error) {
					requests++
					rotate, _ := request["payload"].(map[string]any)["rotate"].(map[string]any)
					if rotate["_0"] != test.direction {
						t.Fatalf("requested direction = %#v", rotate)
					}
					if test.name == "request timeout" {
						return nil, errors.New("rotate timeout")
					}
					return map[string]any{"currentDeviceOrientation": test.response}, nil
				},
				orientationObserver: func(time.Time) (map[string]any, error) {
					if observations == len(test.observations) {
						t.Fatal("extra geometry observation")
					}
					result := test.observations[observations]
					observations++
					return result.geometry, result.err
				},
				orientationWait: func(time.Duration, time.Time) error {
					waits++
					return nil
				},
			}
			result, err := backend.rotate(map[string]any{
				"connectionEpoch": int64(3), "direction": test.direction, "geometryRevision": int64(9),
				"logicalHeight": int64(2532), "logicalWidth": int64(1170), "orientation": test.current,
			}, time.Now().Add(time.Second))
			if test.wantError {
				productErr, ok := err.(*ProductError)
				if !ok || productErr.Code != "outcomeUnknown" || !productErr.Committed || !productErr.OutcomeUnknown || productErr.Stage != "orientation" {
					t.Fatalf("error = %#v", err)
				}
			} else if err != nil || result["orientation"] != test.wantOrientation || result["geometrySampleCount"] != test.wantSampleCount {
				t.Fatalf("result=%#v err=%v", result, err)
			}
			if requests != 1 || observations != test.wantObservations || waits != test.wantObservations {
				t.Fatalf("requests=%d observations=%d waits=%d", requests, observations, waits)
			}
		})
	}
}

func TestDisplayGeometryProjectionMatchesPythonPrimaryInternalContract(t *testing.T) {
	result, err := displayGeometryResult(map[string]any{
		"displays": []any{
			map[string]any{"primary": true, "external": true, "nativeSize": []any{int64(1920), int64(1080)}, "currentOrientation": "rot0"},
			map[string]any{"primary": true, "external": false, "nativeSize": []any{int64(1170), int64(2532)}, "currentOrientation": "rot90"},
		},
	})
	if err != nil {
		t.Fatal(err)
	}
	if result["logicalWidth"] != int64(2532) || result["logicalHeight"] != int64(1170) || result["orientation"] != "landscapeRight" || result["resolvedRouteID"] != "coredevice.displayGeometry.query" {
		t.Fatalf("display projection = %#v", result)
	}

	valid := map[string]any{
		"displays": []any{map[string]any{"primary": true, "external": false, "nativeSize": []any{int64(1170), int64(2532)}, "currentOrientation": "rot0"}},
	}
	for name, response := range map[string]map[string]any{
		"missing primary": {"displays": []any{}},
		"duplicate primary": {"displays": []any{
			map[string]any{"primary": true, "external": false, "nativeSize": []any{int64(1), int64(1)}, "currentOrientation": "rot0"},
			map[string]any{"primary": true, "external": false, "nativeSize": []any{int64(1), int64(1)}, "currentOrientation": "rot0"},
		}},
		"invalid size":        {"displays": []any{map[string]any{"primary": true, "external": false, "nativeSize": []any{int64(0), int64(2532)}, "currentOrientation": "rot0"}}},
		"invalid orientation": {"displays": []any{map[string]any{"primary": true, "external": false, "nativeSize": []any{int64(1170), int64(2532)}, "currentOrientation": "faceUp"}}},
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := displayGeometryResult(response); err == nil {
				t.Fatalf("accepted invalid response %#v", response)
			}
		})
	}
	if _, err := displayGeometryResult(valid); err != nil {
		t.Fatalf("valid portrait response rejected: %v", err)
	}
}

func TestDisplayGeometryReopensServiceOnceAfterInvocationFailure(t *testing.T) {
	first := &CoreDeviceService{}
	second := &CoreDeviceService{}
	opens := 0
	invocations := 0
	backend := &Backend{
		services: make(map[string]*CoreDeviceService),
		openDisplayGeometryService: func(time.Time) (*CoreDeviceService, error) {
			opens++
			if opens == 1 {
				return first, nil
			}
			if opens == 2 {
				return second, nil
			}
			return nil, errors.New("unexpected display service open")
		},
		invokeDisplayGeometry: func(service *CoreDeviceService, _ time.Time) (map[string]any, error) {
			invocations++
			if service == first {
				return nil, errors.New("stale device-info service")
			}
			if service != second {
				return nil, errors.New("unexpected display service")
			}
			return map[string]any{
				"displays": []any{map[string]any{
					"currentOrientation": "rot0",
					"external":           false,
					"nativeSize":         []any{int64(1170), int64(2532)},
					"primary":            true,
				}},
			}, nil
		},
	}

	result, err := backend.displayGeometry(time.Now().Add(time.Second))

	if err != nil {
		t.Fatal(err)
	}
	if opens != 2 || invocations != 2 {
		t.Fatalf("opens=%d invocations=%d", opens, invocations)
	}
	if !first.closed || !second.closed {
		t.Fatalf("service close state first=%t second=%t", first.closed, second.closed)
	}
	if result["resolvedRouteID"] != "coredevice.displayGeometry.query" {
		t.Fatalf("display result = %#v", result)
	}
}

func TestDisplayGeometryOpensAndClosesFreshServiceForEveryQuery(t *testing.T) {
	first := &CoreDeviceService{}
	second := &CoreDeviceService{}
	services := []*CoreDeviceService{first, second}
	opens := 0
	invocations := 0
	backend := &Backend{
		openDisplayGeometryService: func(time.Time) (*CoreDeviceService, error) {
			if opens >= len(services) {
				return nil, errors.New("unexpected display service open")
			}
			service := services[opens]
			opens++
			return service, nil
		},
		invokeDisplayGeometry: func(service *CoreDeviceService, _ time.Time) (map[string]any, error) {
			invocations++
			if service != first && service != second {
				return nil, errors.New("unexpected display service")
			}
			return map[string]any{
				"displays": []any{map[string]any{
					"currentOrientation": "rot0",
					"external":           false,
					"nativeSize":         []any{int64(1170), int64(2532)},
					"primary":            true,
				}},
			}, nil
		},
	}

	for range 2 {
		if _, err := backend.displayGeometry(time.Now().Add(time.Second)); err != nil {
			t.Fatal(err)
		}
	}
	if opens != 2 || invocations != 2 {
		t.Fatalf("opens=%d invocations=%d", opens, invocations)
	}
	if !first.closed || !second.closed {
		t.Fatalf("service close state first=%t second=%t", first.closed, second.closed)
	}
}

func TestBackendExecuteMatchesLegacyModernRouteTranscript(t *testing.T) {
	openPasteboardService, verifyPasteboardSessions := newPasteboardSessionOpener(t, []pasteboardSessionExpectation{
		{command: "SET", text: "你好"},
		{command: "PULL", text: "你好"},
		{command: "SET", text: ""},
		{command: "PULL", text: ""},
	})

	launchClient, launchServer := net.Pipe()
	defer launchClient.Close()
	launchResult := make(chan error, 1)
	go func() {
		defer launchServer.Close()
		frame, err := ReadHTTP2Frame(launchServer, RemoteXPCMaxFrame)
		if err != nil {
			launchResult <- err
			return
		}
		wrapper, err := DecodeXPCWrapper(frame.Payload, RemoteXPCMaxMessage)
		if err != nil {
			launchResult <- err
			return
		}
		request, ok := wrapper.Payload.(map[string]any)
		input, ok := request["CoreDevice.input"].(map[string]any)
		specifier, ok := input["applicationSpecifier"].(map[string]any)
		bundle, ok := specifier["bundleIdentifier"].(map[string]any)
		if !ok || bundle["_0"] != "com.example.App" {
			launchResult <- fmt.Errorf("launch request = %#v", wrapper.Payload)
			return
		}
		payload, err := EncodeXPCWrapper(map[string]any{"CoreDevice.output": map[string]any{}}, 0, false)
		if err != nil {
			launchResult <- err
			return
		}
		raw, err := (HTTP2Frame{Type: HTTP2Data, StreamID: 1, Payload: payload}).Encode()
		if err != nil {
			launchResult <- err
			return
		}
		_, err = launchServer.Write(raw)
		launchResult <- err
	}()

	hid := &CoreDeviceService{remote: NewRemoteXPCConnection(&deadlineRecordingConn{})}
	appControl := &CoreDeviceService{remote: NewRemoteXPCConnection(launchClient)}
	orientationRequests := 0
	backend := &Backend{
		connectionEpoch: 3,
		tunnel:          &CoreDeviceTunnelLease{},
		services: map[string]*CoreDeviceService{
			coreDeviceServiceAppControl:  appControl,
			coreDeviceServiceHID:         hid,
			coreDeviceServiceOrientation: {},
		},
		openKeyboardService:   func(time.Time) (uint64, error) { return 17, nil },
		waitKeyboardReadiness: func(time.Duration, time.Time) error { return nil },
		openPasteboardService: openPasteboardService,
		orientationRequest: func(_ *CoreDeviceService, request map[string]any, _ time.Time) (map[string]any, error) {
			orientationRequests++
			payload, ok := request["payload"].(map[string]any)
			rotate, ok := payload["rotate"].(map[string]any)
			if !ok || rotate["_0"] != "left" {
				return nil, fmt.Errorf("orientation request = %#v", request)
			}
			return map[string]any{"currentDeviceOrientation": "landscapeLeft"}, nil
		},
		orientationObserver: func(time.Time) (map[string]any, error) {
			return map[string]any{"logicalHeight": int64(1170), "logicalWidth": int64(2532), "orientation": "landscapeLeft"}, nil
		},
		orientationWait: func(time.Duration, time.Time) error { return nil },
	}
	execute := func(route string, payload map[string]any) (map[string]any, error) {
		return backend.Execute(protocol.Message{Payload: map[string]any{"executorOperationID": route, "backendPayload": payload}})
	}
	rotated, err := execute("coredevice.orientation.rotate", map[string]any{
		"connectionEpoch": int64(3), "direction": "left", "geometryRevision": int64(9),
		"logicalHeight": int64(2532), "logicalWidth": int64(1170), "orientation": "portrait",
	})
	if err != nil || rotated["orientation"] != "landscapeLeft" || rotated["geometryRevision"] != uint64(10) || !rotated["visibleOrientationConfirmed"].(bool) {
		t.Fatalf("orientation result=%#v err=%v", rotated, err)
	}
	for _, text := range []string{"你好", ""} {
		result, err := execute("coredevice.pasteboardSetAndPaste", map[string]any{"text": text})
		if err != nil || result["disposition"] != "pasteDispatched" || result["textByteCount"] != int64(len([]byte(text))) {
			t.Fatalf("pasteboard result=%#v err=%v", result, err)
		}
	}
	launched, err := execute("coredevice.appLaunch", map[string]any{"bundleID": "com.example.App"})
	if err != nil || launched["disposition"] != "launchRequested" || launched["bundleID"] != "com.example.App" {
		t.Fatalf("launch result=%#v err=%v", launched, err)
	}
	if orientationRequests != 1 || hid.remote.nextMessage[1] != 6 {
		t.Fatalf("orientation requests=%d HID reports=%d", orientationRequests, hid.remote.nextMessage[1])
	}
	verifyPasteboardSessions()
	if err := <-launchResult; err != nil {
		t.Fatal(err)
	}
}

func TestBackendDispatchesPersonalizedRequestBeforeCoreDeviceWarmIO(t *testing.T) {
	backend, err := NewBackendForRuntime(9, 11, "device", 4, testServiceNames())
	if err != nil {
		t.Fatal(err)
	}
	personalized := &fakeBackendPersonalizedSupport{result: map[string]any{"mounted": false}}
	backend.personalized = personalized
	warmCalls := 0
	coordinator, err := NewCoordinator(9, "device", func(context.Context, string) (TunnelLease, error) {
		warmCalls++
		return nil, errors.New("unexpected CoreDevice warm")
	}, 11, testServiceNames())
	if err != nil {
		t.Fatal(err)
	}
	if err := coordinator.Attach(4); err != nil {
		t.Fatal(err)
	}
	backend.coordinator = coordinator

	payload := map[string]any{"catalogRevision": "catalog.personalized.test", "operation": "queryMounted"}
	result, err := backend.Execute(protocol.Message{Payload: map[string]any{
		"executorOperationID": "coredevice.personalizedDeveloperSupport",
		"backendPayload":      payload,
	}})
	if err != nil {
		t.Fatal(err)
	}
	if result["mounted"] != false || warmCalls != 0 {
		t.Fatalf("result = %#v, warm calls = %d", result, warmCalls)
	}
	if personalized.rawUDID != "device" || personalized.connectionEpoch != 4 || personalized.payload["catalogRevision"] != "catalog.personalized.test" {
		t.Fatalf("personalized dispatch = %#v", personalized)
	}
	if err := backend.Close(); err != nil {
		t.Fatal(err)
	}
	if !personalized.closed {
		t.Fatal("backend close did not close personalized support")
	}
}

func TestBackendQueriesMountedPersonalizedSupportWithoutCatalogBeforeCoreDeviceWarmIO(t *testing.T) {
	backend, err := NewBackendForRuntime(9, 11, "device", 4, testServiceNames())
	if err != nil {
		t.Fatal(err)
	}
	personalized := &fakeBackendPersonalizedSupport{
		queryResult: map[string]any{
			"mounted":    true,
			"provenance": "mountedUnknownUnverified",
		},
	}
	backend.personalized = personalized
	warmCalls := 0
	coordinator, err := NewCoordinator(9, "device", func(context.Context, string) (TunnelLease, error) {
		warmCalls++
		return nil, errors.New("unexpected CoreDevice warm")
	}, 11, testServiceNames())
	if err != nil {
		t.Fatal(err)
	}
	if err := coordinator.Attach(4); err != nil {
		t.Fatal(err)
	}
	backend.coordinator = coordinator

	result, err := backend.Execute(protocol.Message{Payload: map[string]any{
		"executorOperationID": "coredevice.developerSupport.queryMounted",
		"backendPayload":      map[string]any{"operation": "queryMounted"},
	}})
	if err != nil {
		t.Fatal(err)
	}
	if result["mounted"] != true || result["provenance"] != "mountedUnknownUnverified" || warmCalls != 0 {
		t.Fatalf("result = %#v, warm calls = %d", result, warmCalls)
	}
	if personalized.queryRawUDID != "device" || personalized.queryCalls != 1 {
		t.Fatalf("mounted query = %#v", personalized)
	}
	if err := backend.Close(); err != nil {
		t.Fatal(err)
	}
	if !personalized.closed {
		t.Fatal("backend close did not close personalized support")
	}
}

func TestBackendRequestDeadlineExtendsPersonalizedPreparation(t *testing.T) {
	now := time.Unix(1_700_000_000, 123)
	for _, test := range []struct {
		route   string
		timeout time.Duration
	}{
		{route: "coredevice.button.home", timeout: 60 * time.Second},
		{route: "coredevice.developerSupport.requestTSS", timeout: 5 * time.Minute},
		{route: "coredevice.developerSupport.mount", timeout: 5 * time.Minute},
	} {
		if got, want := backendRequestDeadline(test.route, now), now.Add(test.timeout); !got.Equal(want) {
			t.Fatalf("deadline for %s = %s, want %s", test.route, got, want)
		}
	}
}

type fakeBackendPersonalizedSupport struct {
	rawUDID         string
	connectionEpoch uint64
	payload         map[string]any
	deadline        time.Time
	result          map[string]any
	err             error
	queryCalls      int
	queryDeadline   time.Time
	queryErr        error
	queryRawUDID    string
	queryResult     map[string]any
	closed          bool
}

func (support *fakeBackendPersonalizedSupport) QueryMounted(rawUDID string, deadline time.Time) (map[string]any, error) {
	support.queryCalls++
	support.queryRawUDID = rawUDID
	support.queryDeadline = deadline
	return support.queryResult, support.queryErr
}

func (support *fakeBackendPersonalizedSupport) Execute(rawUDID string, connectionEpoch uint64, payload map[string]any, deadline time.Time) (map[string]any, error) {
	support.rawUDID = rawUDID
	support.connectionEpoch = connectionEpoch
	support.payload = payload
	support.deadline = deadline
	return support.result, support.err
}

func (support *fakeBackendPersonalizedSupport) Close() {
	support.closed = true
}
