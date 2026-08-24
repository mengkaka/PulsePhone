package coredevice

import (
	"bytes"
	"errors"
	"fmt"
	"net"
	"reflect"
	"sync"
	"testing"
	"time"

	"pulsephone/GoHelpers/internal/protocol"
)

func TestBuildKeyboardReportUsesFullPressedSetAndTimestamp(t *testing.T) {
	report := buildKeyboardReport([]uint16{0xe3, 0x19}, 0x010203040506)
	if report[0] != 0x01 || report[1+0xe3/8]&(1<<(0xe3%8)) == 0 || report[1+0x19/8]&(1<<(0x19%8)) == 0 {
		t.Fatalf("keyboard report bitmap = %x", report)
	}
	if !bytes.Equal(report[31:37], []byte{6, 5, 4, 3, 2, 1}) {
		t.Fatalf("keyboard timestamp = %x", report[31:37])
	}
}

func TestKeyboardReportTimestampPrefersMonotonicClock(t *testing.T) {
	previousMonotonic := keyboardMonotonicNow
	previousFallback := keyboardFallbackNow
	t.Cleanup(func() {
		keyboardMonotonicNow = previousMonotonic
		keyboardFallbackNow = previousFallback
	})
	keyboardMonotonicNow = func() (uint64, bool) { return 0x010203040506, true }
	keyboardFallbackNow = func() uint64 { return 0x999999999999 }
	if got := keyboardReportTimestamp(); got != 0x010203040506 {
		t.Fatalf("timestamp = %#x", got)
	}

	keyboardMonotonicNow = func() (uint64, bool) { return 0, false }
	if got := keyboardReportTimestamp(); got != 0x999999999999 {
		t.Fatalf("fallback timestamp = %#x", got)
	}
}

func TestKeyboardMacroPlanMatchesPythonContract(t *testing.T) {
	steps, disposition, err := buildKeyboardMacro(map[string]any{
		"commandID": "text.key",
		"key":       "a",
		"modifiers": []any{"command", "shift"},
		"repeat":    int64(2),
	})
	if err != nil || disposition != "keyDispatched" || len(steps) != 2 {
		t.Fatalf("plan = %#v %q %v", steps, disposition, err)
	}
	if _, _, err := buildKeyboardMacro(map[string]any{
		"commandID": "text.key",
		"key":       "a",
		"modifiers": []any{"shift", "command"},
		"repeat":    int64(1),
	}); err == nil {
		t.Fatal("expected non-canonical modifier order to fail")
	}
	if _, _, err := buildKeyboardMacro(map[string]any{
		"commandID": "text.key",
		"key":       "a",
		"modifiers": []any{},
		"repeat":    int64(101),
	}); err == nil {
		t.Fatal("expected repeat cap to fail")
	}
	if _, _, err := buildKeyboardMacro(map[string]any{
		"commandID": "text.key",
		"key":       "not-a-hid-key",
		"modifiers": []any{},
		"repeat":    int64(1),
	}); err == nil {
		t.Fatal("expected unknown key to fail")
	}
	if _, ok := keyboardUsages([]any{int64(-1)}); ok {
		t.Fatal("expected negative HID usage to fail")
	}
}

func TestKeyboardServiceReadinessRetryReusesCreatedService(t *testing.T) {
	var mu sync.Mutex
	createCalls := 0
	readinessCalls := 0
	backend := &Backend{
		openKeyboardService: func(time.Time) (uint64, error) {
			mu.Lock()
			defer mu.Unlock()
			createCalls++
			return 17, nil
		},
		waitKeyboardReadiness: func(duration time.Duration, _ time.Time) error {
			if duration != keyboardServiceReadinessDelay {
				t.Fatalf("readiness delay = %s", duration)
			}
			mu.Lock()
			defer mu.Unlock()
			readinessCalls++
			if readinessCalls == 1 {
				return errors.New("readiness interrupted")
			}
			return nil
		},
	}

	if _, err := backend.ensureKeyboardService(time.Now().Add(time.Second)); err == nil {
		t.Fatal("expected interrupted readiness")
	}
	id, err := backend.ensureKeyboardService(time.Now().Add(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	mu.Lock()
	defer mu.Unlock()
	if id != 17 || createCalls != 1 || readinessCalls != 2 {
		t.Fatalf("id=%d create=%d readiness=%d", id, createCalls, readinessCalls)
	}
	if backend.keyboardID != 17 || !backend.keyboardReady {
		t.Fatalf("keyboard state = id %d ready %v", backend.keyboardID, backend.keyboardReady)
	}
}

func TestKeyboardServiceInitializationIsSingleFlight(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	var mu sync.Mutex
	createCalls := 0
	backend := &Backend{
		openKeyboardService: func(time.Time) (uint64, error) {
			mu.Lock()
			createCalls++
			mu.Unlock()
			close(started)
			<-release
			return 17, nil
		},
		waitKeyboardReadiness: func(time.Duration, time.Time) error { return nil },
	}
	type result struct {
		id  uint64
		err error
	}
	first := make(chan result, 1)
	second := make(chan result, 1)
	go func() {
		id, err := backend.ensureKeyboardService(time.Now().Add(time.Second))
		first <- result{id: id, err: err}
	}()
	<-started
	go func() {
		id, err := backend.ensureKeyboardService(time.Now().Add(time.Second))
		second <- result{id: id, err: err}
	}()
	select {
	case value := <-second:
		t.Fatalf("second initialization completed early: %#v", value)
	case <-time.After(20 * time.Millisecond):
	}
	close(release)
	for _, result := range []result{<-first, <-second} {
		if result.err != nil || result.id != 17 {
			t.Fatalf("initialization result = %#v", result)
		}
	}
	mu.Lock()
	defer mu.Unlock()
	if createCalls != 1 {
		t.Fatalf("keyboard service created %d times", createCalls)
	}
}

func TestKeyboardMacroExecutorReleasesEveryChordAndPreservesTiming(t *testing.T) {
	var reports [][]uint16
	var pauses []time.Duration
	steps := []keyboardChord{
		{modifiers: []string{"command"}, key: "a"},
		{key: "backspace"},
	}
	committed, stage, err := executeKeyboardMacro(steps, func(usages []uint16) error {
		reports = append(reports, append([]uint16(nil), usages...))
		return nil
	}, func(duration time.Duration) {
		pauses = append(pauses, duration)
	})
	if err != nil || !committed || stage != "" {
		t.Fatalf("execution = committed %v stage %q error %v", committed, stage, err)
	}
	wantReports := [][]uint16{{0xe3}, {0xe3, 0x04}, nil, {0x2a}, nil}
	if !reflect.DeepEqual(reports, wantReports) {
		t.Fatalf("reports = %#v, want %#v", reports, wantReports)
	}
	wantPauses := []time.Duration{12 * time.Millisecond, 12 * time.Millisecond, 12 * time.Millisecond}
	if !reflect.DeepEqual(pauses, wantPauses) {
		t.Fatalf("pauses = %#v, want %#v", pauses, wantPauses)
	}
}

func TestKeyboardMacroExecutorFailureAttemptsRelease(t *testing.T) {
	var reports [][]uint16
	committed, stage, err := executeKeyboardMacro([]keyboardChord{{modifiers: []string{"command"}, key: "a"}}, func(usages []uint16) error {
		reports = append(reports, append([]uint16(nil), usages...))
		if len(reports) == 2 {
			return errors.New("send failed")
		}
		return nil
	}, func(time.Duration) {})
	if err == nil || !committed || stage != "keyboardMacro" {
		t.Fatalf("execution = committed %v stage %q error %v", committed, stage, err)
	}
	want := [][]uint16{{0xe3}, {0xe3, 0x04}, nil}
	if !reflect.DeepEqual(reports, want) {
		t.Fatalf("reports = %#v, want %#v", reports, want)
	}
}

func TestKeyboardMacroExecutorReleaseFailureRetriesCleanup(t *testing.T) {
	var reports [][]uint16
	committed, stage, err := executeKeyboardMacro([]keyboardChord{{key: "a"}}, func(usages []uint16) error {
		reports = append(reports, append([]uint16(nil), usages...))
		if len(reports) == 2 {
			return errors.New("release failed")
		}
		return nil
	}, func(time.Duration) {})
	if err == nil || !committed || stage != "cleanup" {
		t.Fatalf("execution = committed %v stage %q error %v", committed, stage, err)
	}
	want := [][]uint16{{0x04}, nil, nil}
	if !reflect.DeepEqual(reports, want) {
		t.Fatalf("reports = %#v, want %#v", reports, want)
	}
}

func TestPasteChordMatchesPythonTiming(t *testing.T) {
	var reports [][]uint16
	var pauses []time.Duration
	err := sendKeyboardChordWithSender(func(usages []uint16) error {
		reports = append(reports, append([]uint16(nil), usages...))
		return nil
	}, func(duration time.Duration) {
		pauses = append(pauses, duration)
	}, []uint16{modifierUsagesByName["command"]}, keyboardUsagesByName["v"], 20*time.Millisecond, 80*time.Millisecond)
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(reports, [][]uint16{{0xe3}, {0xe3, 0x19}}) {
		t.Fatalf("reports = %#v", reports)
	}
	if !reflect.DeepEqual(pauses, []time.Duration{20 * time.Millisecond, 80 * time.Millisecond}) {
		t.Fatalf("pauses = %#v", pauses)
	}
}

func TestSoftwareKeyboardToggleReleasesAfterInterruptedWait(t *testing.T) {
	var states []uint64
	err := executeSoftwareKeyboardToggle(func(state uint64) error {
		states = append(states, state)
		return nil
	}, func(time.Duration) error {
		return errors.New("toggle interrupted")
	})
	if err == nil {
		t.Fatal("expected interrupted wait")
	}
	if !reflect.DeepEqual(states, []uint64{1, 2}) {
		t.Fatalf("button states = %#v", states)
	}
}

func TestSoftwareKeyboardTogglePreservesHoldAndReleaseFailure(t *testing.T) {
	var states []uint64
	var waits []time.Duration
	err := executeSoftwareKeyboardToggle(func(state uint64) error {
		states = append(states, state)
		if state == 2 {
			return errors.New("release failed")
		}
		return nil
	}, func(duration time.Duration) error {
		waits = append(waits, duration)
		return nil
	})
	if err == nil {
		t.Fatal("expected release failure")
	}
	if !reflect.DeepEqual(states, []uint64{1, 2}) || !reflect.DeepEqual(waits, []time.Duration{50 * time.Millisecond}) {
		t.Fatalf("states=%#v waits=%#v", states, waits)
	}
}

func TestPasteboardTextProjection(t *testing.T) {
	value := map[string]any{
		"pasteboard": map[string]any{
			"items": []any{map[string]any{
				"data": map[string]any{
					"public.utf8-plain-text": map[string]any{"data": []byte("hello")},
				},
			}},
		},
	}
	text, ok := pasteboardText(value)
	if !ok || text != "hello" {
		t.Fatalf("projection = %q %v", text, ok)
	}
}

type pasteboardSessionExpectation struct {
	command string
	text    string
}

func newPasteboardSessionOpener(
	t *testing.T,
	expectations []pasteboardSessionExpectation,
) (func(time.Time) (*CoreDeviceService, error), func()) {
	t.Helper()
	var mu sync.Mutex
	next := 0
	services := make([]*CoreDeviceService, 0, len(expectations))
	results := make(chan error, len(expectations))

	opener := func(time.Time) (*CoreDeviceService, error) {
		mu.Lock()
		if next >= len(expectations) {
			mu.Unlock()
			return nil, errors.New("unexpected pasteboard session")
		}
		expectation := expectations[next]
		next++
		client, server := net.Pipe()
		service := &CoreDeviceService{remote: NewRemoteXPCConnection(client)}
		services = append(services, service)
		mu.Unlock()

		go func() {
			defer server.Close()
			frame, err := ReadHTTP2Frame(server, RemoteXPCMaxFrame)
			if err != nil {
				results <- err
				return
			}
			wrapper, err := DecodeXPCWrapper(frame.Payload, RemoteXPCMaxMessage)
			if err != nil {
				results <- err
				return
			}
			request, ok := wrapper.Payload.(map[string]any)
			if !ok || request["command"] != expectation.command {
				results <- fmt.Errorf("pasteboard request = %#v, want %s", wrapper.Payload, expectation.command)
				return
			}
			response := map[string]any{"status": "set"}
			if expectation.command == "SET" {
				items, ok := request["items"].([]any)
				if !ok || len(items) != 1 {
					results <- fmt.Errorf("pasteboard SET items = %#v", request["items"])
					return
				}
				item, ok := items[0].(map[string]any)
				data, ok := item["data"].(map[string]any)
				utf8, ok := data["public.utf8-plain-text"].(map[string]any)
				bytes, ok := utf8["data"].([]byte)
				if !ok || string(bytes) != expectation.text {
					results <- fmt.Errorf("pasteboard SET text = %#v, want %q", item, expectation.text)
					return
				}
			} else {
				response = map[string]any{"pasteboard": map[string]any{"items": []any{map[string]any{"data": map[string]any{
					"public.utf8-plain-text": map[string]any{"data": []byte(expectation.text)},
				}}}}}
			}
			payload, err := EncodeXPCWrapper(response, 0, false)
			if err != nil {
				results <- err
				return
			}
			raw, err := (HTTP2Frame{Type: HTTP2Data, StreamID: 1, Payload: payload}).Encode()
			if err != nil {
				results <- err
				return
			}
			_, err = server.Write(raw)
			results <- err
		}()
		return service, nil
	}

	verify := func() {
		t.Helper()
		for range expectations {
			if err := <-results; err != nil {
				t.Fatal(err)
			}
		}
		mu.Lock()
		defer mu.Unlock()
		if len(services) != len(expectations) {
			t.Fatalf("pasteboard sessions = %d, want %d", len(services), len(expectations))
		}
		for index, service := range services {
			if !service.closed {
				t.Fatalf("pasteboard session %d was not closed", index)
			}
		}
	}
	return opener, verify
}

func TestPasteboardSessionsAreIndependentAcrossConsecutiveTextCommands(t *testing.T) {
	opener, verify := newPasteboardSessionOpener(t, []pasteboardSessionExpectation{
		{command: "SET", text: "first"},
		{command: "PULL", text: "first"},
		{command: "SET", text: "second"},
		{command: "PULL", text: "second"},
	})
	backend := &Backend{
		tunnel:                &CoreDeviceTunnelLease{},
		services:              map[string]*CoreDeviceService{coreDeviceServiceHID: {remote: NewRemoteXPCConnection(&deadlineRecordingConn{})}},
		openKeyboardService:   func(time.Time) (uint64, error) { return 17, nil },
		waitKeyboardReadiness: func(time.Duration, time.Time) error { return nil },
		openPasteboardService: opener,
	}
	for _, text := range []string{"first", "second"} {
		result, err := backend.pasteboardSetAndPaste(map[string]any{"text": text}, time.Now().Add(time.Second))
		if err != nil || result["disposition"] != "pasteDispatched" {
			t.Fatalf("text %q result=%#v err=%v", text, result, err)
		}
	}
	verify()
}

func TestPasteboardReadBackMismatchStopsBeforePasteChord(t *testing.T) {
	opener, verify := newPasteboardSessionOpener(t, []pasteboardSessionExpectation{
		{command: "SET", text: "expected"},
		{command: "PULL", text: "different"},
	})
	backend := &Backend{
		tunnel:                &CoreDeviceTunnelLease{},
		services:              map[string]*CoreDeviceService{},
		openKeyboardService:   func(time.Time) (uint64, error) { return 17, nil },
		waitKeyboardReadiness: func(time.Duration, time.Time) error { return nil },
		openPasteboardService: opener,
	}
	_, err := backend.pasteboardSetAndPaste(map[string]any{"text": "expected"}, time.Now().Add(time.Second))
	productErr, ok := err.(*ProductError)
	if !ok || productErr.Code != "backendFailed" || !productErr.Committed || productErr.Stage != "pasteboardReadBack" {
		t.Fatalf("error = %#v", err)
	}
	verify()
}

func TestNormalizedAxisValueKeepsCanonicalBoundary(t *testing.T) {
	if value, ok := normalizedAxisValue("0.5"); !ok || value != 32768 {
		t.Fatalf("0.5 = %d %v", value, ok)
	}
	if value, ok := normalizedAxisValue("1"); !ok || value != 65535 {
		t.Fatalf("1 = %d %v", value, ok)
	}
	if _, ok := normalizedAxisValue("0.50"); ok {
		t.Fatal("expected non-canonical axis to fail")
	}
	if _, ok := normalizedAxisValue("0.123456789012345678"); !ok {
		t.Fatal("expected 18-digit canonical axis to succeed")
	}
	if _, ok := normalizedAxisValue("0.1234567890123456789"); ok {
		t.Fatal("expected 19-digit axis to fail")
	}
	for coordinate, want := range map[any]uint16{
		int64(0):     0,
		int64(32768): 32768,
		int64(65535): 65535,
	} {
		value, ok := normalizedAxisValue(coordinate)
		if !ok || value != want {
			t.Fatalf("integer coordinate %#v = %d, %v", coordinate, value, ok)
		}
	}
	for _, invalid := range []any{int64(-1), int64(65536), float64(0.5), true} {
		if _, ok := normalizedAxisValue(invalid); ok {
			t.Fatalf("invalid coordinate %#v accepted", invalid)
		}
	}
}

func TestTimedTouchFramesMatchPythonElapsedSchedule(t *testing.T) {
	frames, err := parseTimedTouchFrames([]any{
		map[string]any{"elapsedMs": int64(0), "kind": "begin", "x": "0.25", "y": "0.5"},
		map[string]any{"elapsedMs": int64(100), "kind": "move", "x": "0.5", "y": "0.5"},
		map[string]any{"elapsedMs": int64(150), "kind": "end", "x": "0.75", "y": "0.5"},
	})
	if err != nil {
		t.Fatal(err)
	}
	now := time.Unix(0, 0)
	var waits []time.Duration
	var sent []byte
	err = runTimedTouchFrames(frames, time.Time{}, func() time.Time { return now }, func(duration time.Duration, _ time.Time) error {
		waits = append(waits, duration)
		now = now.Add(duration)
		return nil
	}, func(frame timedTouchFrame) error {
		sent = append(sent, frame.state)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if len(waits) != 2 || waits[0] != 100*time.Millisecond || waits[1] != 50*time.Millisecond {
		t.Fatalf("wait schedule = %#v", waits)
	}
	if !bytes.Equal(sent, []byte{0xc2, 0xc2, 0x02}) {
		t.Fatalf("sent states = %x", sent)
	}
}

func TestTimedTouchFramesRejectInvalidElapsedMilliseconds(t *testing.T) {
	for _, elapsed := range []any{nil, int64(-1), float64(1), "1", true, uint64((1<<63)/uint64(time.Millisecond)) + 1} {
		_, err := parseTimedTouchFrames([]any{map[string]any{
			"elapsedMs": elapsed,
			"kind":      "begin",
			"x":         "0.5",
			"y":         "0.5",
		}})
		if err == nil {
			t.Fatalf("elapsedMs %#v accepted", elapsed)
		}
	}
}

func TestTimedTouchFramesStopAtDeadline(t *testing.T) {
	frames := []timedTouchFrame{{elapsed: 100 * time.Millisecond, state: 0xc2}}
	err := runTimedTouchFrames(frames, time.Now().Add(time.Second), time.Now, func(time.Duration, time.Time) error {
		return errors.New("touch deadline exceeded")
	}, func(timedTouchFrame) error {
		t.Fatal("sent frame after deadline")
		return nil
	})
	if err == nil {
		t.Fatal("expected deadline failure")
	}
}

func TestRotationResultMatchesRuntimeProjectionContract(t *testing.T) {
	request, err := parseRotateRequest(map[string]any{
		"connectionEpoch":  int64(4),
		"direction":        "left",
		"geometryRevision": int64(9),
		"logicalHeight":    int64(2532),
		"logicalWidth":     int64(1170),
		"orientation":      "portrait",
	}, 4)
	if err != nil {
		t.Fatal(err)
	}
	result := orientationResult(request, "landscapeLeft", map[string]any{
		"logicalHeight": int64(1170),
		"logicalWidth":  int64(2532),
		"orientation":   "landscapeLeft",
	}, 2, 125*time.Millisecond)
	if result["geometryRevision"] != uint64(10) || result["logicalWidth"] != uint64(2532) || result["logicalHeight"] != uint64(1170) {
		t.Fatalf("rotation geometry = %#v", result)
	}
	if result["previousDisplayOrientation"] != "portrait" || result["currentDisplayOrientation"] != "landscapeLeft" || result["rotateResponseOrientation"] != "landscapeLeft" || result["visibleOrientationConfirmed"] != true {
		t.Fatalf("rotation projection = %#v", result)
	}
}

func TestRotationRejectsIncompleteOrStaleGeometry(t *testing.T) {
	valid := map[string]any{
		"connectionEpoch":  int64(4),
		"direction":        "left",
		"geometryRevision": int64(9),
		"logicalHeight":    int64(2532),
		"logicalWidth":     int64(1170),
		"orientation":      "portrait",
	}
	if _, err := parseRotateRequest(valid, 4); err != nil {
		t.Fatal(err)
	}
	for key, invalid := range map[string]any{
		"connectionEpoch":  int64(5),
		"geometryRevision": int64(0),
		"logicalHeight":    int64(0),
		"logicalWidth":     int64(-1),
		"orientation":      "faceUp",
	} {
		payload := make(map[string]any, len(valid))
		for name, value := range valid {
			payload[name] = value
		}
		payload[key] = invalid
		if _, err := parseRotateRequest(payload, 4); err == nil {
			t.Fatalf("%s=%#v accepted", key, invalid)
		}
	}
}

func TestOrientationDeadlinesMatchPythonContract(t *testing.T) {
	if orientationRequestTimeout != 10*time.Second || orientationGeometryQueryTimeout != 500*time.Millisecond {
		t.Fatalf("orientation deadlines = request %s geometry %s", orientationRequestTimeout, orientationGeometryQueryTimeout)
	}
	local := time.Unix(20, 0)
	operation := time.Unix(30, 0)
	if got := shorterDeadline(operation, local); !got.Equal(local) {
		t.Fatalf("local deadline = %s, want %s", got, local)
	}
	if got := shorterDeadline(local, operation); !got.Equal(local) {
		t.Fatalf("operation deadline = %s, want %s", got, local)
	}
}

func TestButtonResultIncludesLegacyTimingFields(t *testing.T) {
	started := time.Unix(0, 0)
	result := buttonResult(
		"coredevice.button.home",
		started,
		started.Add(2*time.Millisecond),
		started.Add(52*time.Millisecond),
		started.Add(55*time.Millisecond),
	)
	timing, ok := result["_pulsephoneInternalTiming"].(map[string]any)
	if !ok {
		t.Fatalf("timing = %#v", result)
	}
	if timing["serviceOpenMicroseconds"] != int64(2_000) || timing["buttonSequenceMicroseconds"] != int64(50_000) || timing["serviceCloseMicroseconds"] != int64(3_000) || timing["totalMicroseconds"] != int64(55_000) {
		t.Fatalf("timing = %#v", timing)
	}
}

func TestButtonPressesMatchPythonDurationsAndRouteProjection(t *testing.T) {
	presses, ok := buttonPresses("button.appSwitcher")
	if !ok || !reflect.DeepEqual(presses, []buttonPress{
		{usage: 0x40, hold: 35 * time.Millisecond},
		{usage: 0x40, hold: 35 * time.Millisecond},
	}) {
		t.Fatalf("app switcher presses = %#v", presses)
	}
	if _, ok := buttonPresses("button.unknown"); ok {
		t.Fatal("unknown button command accepted")
	}
	result := buttonResult(
		"coredevice.button.doubleHome",
		time.Unix(0, 0),
		time.Unix(0, 0),
		time.Unix(0, 0),
		time.Unix(0, 0),
	)
	if result["resolvedRouteID"] != "coredevice.button.doubleHome" {
		t.Fatalf("resolved route = %#v", result)
	}
}

func TestButtonExecutorMatchesPythonSequenceAndReleasesAfterInterruptedHold(t *testing.T) {
	type event struct {
		usage uint16
		state uint64
	}
	var events []event
	var waits []time.Duration
	err := executeButtonPresses([]buttonPress{{usage: 0x40, hold: 35 * time.Millisecond}, {usage: 0x40, hold: 35 * time.Millisecond}}, func(usage uint16, state uint64) error {
		events = append(events, event{usage: usage, state: state})
		return nil
	}, func(duration time.Duration) error {
		waits = append(waits, duration)
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(events, []event{{usage: 0x40, state: 1}, {usage: 0x40, state: 2}, {usage: 0x40, state: 1}, {usage: 0x40, state: 2}}) {
		t.Fatalf("button events = %#v", events)
	}
	if !reflect.DeepEqual(waits, []time.Duration{35 * time.Millisecond, 120 * time.Millisecond, 35 * time.Millisecond}) {
		t.Fatalf("button waits = %#v", waits)
	}

	events = nil
	err = executeButtonPresses([]buttonPress{{usage: 0x40, hold: 50 * time.Millisecond}}, func(usage uint16, state uint64) error {
		events = append(events, event{usage: usage, state: state})
		return nil
	}, func(time.Duration) error {
		return errors.New("hold interrupted")
	})
	if err == nil {
		t.Fatal("expected interrupted hold")
	}
	if !reflect.DeepEqual(events, []event{{usage: 0x40, state: 1}, {usage: 0x40, state: 2}}) {
		t.Fatalf("button release after interruption = %#v", events)
	}
}

func TestSoftwareKeyboardToggleReusesGenerationButtonService(t *testing.T) {
	buttonConnection := &deadlineRecordingConn{}
	button := &CoreDeviceService{remote: NewRemoteXPCConnection(buttonConnection)}
	backend := &Backend{
		tunnel:   &CoreDeviceTunnelLease{},
		services: map[string]*CoreDeviceService{coreDeviceServiceButton: button},
	}
	deadline := time.Now().Add(time.Second)
	for range 2 {
		result, err := backend.softwareKeyboardToggle(deadline)
		if err != nil {
			t.Fatal(err)
		}
		if result["resolvedRouteID"] != "coredevice.softwareKeyboardToggle" || result["stateUnknown"] != true {
			t.Fatalf("result = %#v", result)
		}
	}
	if got := button.remote.nextMessage[1]; got != 4 {
		t.Fatalf("button requests = %d, want 4", got)
	}
}

func TestStreamsReuseGenerationInputServices(t *testing.T) {
	hidConnection := &deadlineRecordingConn{}
	hid := &CoreDeviceService{remote: NewRemoteXPCConnection(hidConnection)}
	button := &CoreDeviceService{}
	keyboardServiceOpens := 0
	keyboardReadinessWaits := 0
	backend := &Backend{
		tunnel: &CoreDeviceTunnelLease{},
		services: map[string]*CoreDeviceService{
			coreDeviceServiceButton: button,
			coreDeviceServiceHID:    hid,
		},
		streams: make(map[string]*backendStream),
		openKeyboardService: func(time.Time) (uint64, error) {
			keyboardServiceOpens++
			return 17, nil
		},
		waitKeyboardReadiness: func(time.Duration, time.Time) error {
			keyboardReadinessWaits++
			return nil
		},
	}
	deadline := time.Now().Add(time.Second)
	for index := 0; index < 2; index++ {
		sessionID := fmt.Sprintf("pointer-%d", index)
		deliveryID := fmt.Sprintf("pointer-delivery-%d", index)
		interactionID := fmt.Sprintf("pointer-interaction-%d", index)
		stream := streamMessage(sessionID, deliveryID, interactionID, "coredevice.pointerStream")
		if err := backend.OpenStream(stream, deadline); err != nil {
			t.Fatal(err)
		}
		for _, kind := range []string{"begin", "end"} {
			stream.Payload["framePayload"] = map[string]any{"kind": kind, "x": "0.5", "y": "0.5"}
			if err := backend.SendFrame(stream, deadline); err != nil {
				t.Fatal(err)
			}
		}
		if err := backend.CloseStream(stream, deadline); err != nil {
			t.Fatal(err)
		}
	}
	for index := 0; index < 2; index++ {
		sessionID := fmt.Sprintf("keyboard-%d", index)
		deliveryID := fmt.Sprintf("keyboard-delivery-%d", index)
		interactionID := fmt.Sprintf("keyboard-interaction-%d", index)
		stream := streamMessage(sessionID, deliveryID, interactionID, "coredevice.keyboardStream")
		if err := backend.OpenStream(stream, deadline); err != nil {
			t.Fatal(err)
		}
		for _, usages := range []any{[]any{int64(0x04)}, []any{}} {
			stream.Payload["framePayload"] = map[string]any{"kind": "pressedSet", "usages": usages}
			if err := backend.SendFrame(stream, deadline); err != nil {
				t.Fatal(err)
			}
		}
		if err := backend.CloseStream(stream, deadline); err != nil {
			t.Fatal(err)
		}
	}
	if keyboardServiceOpens != 1 || keyboardReadinessWaits != 1 {
		t.Fatalf("keyboard opens=%d readiness waits=%d", keyboardServiceOpens, keyboardReadinessWaits)
	}
	if got := hid.remote.nextMessage[1]; got != 10 {
		t.Fatalf("HID reports = %d, want 10", got)
	}
	if backend.services[coreDeviceServiceHID] != hid || backend.services[coreDeviceServiceButton] != button {
		t.Fatal("streams did not retain generation services")
	}
}

func streamMessage(sessionID, deliveryID, interactionID, route string) protocol.Message {
	return protocol.Message{
		DeliveryAttemptID: &deliveryID,
		SessionID:         &sessionID,
		Payload: map[string]any{
			"interactionID": interactionID,
			"streamPayload": map[string]any{"routeID": route},
		},
	}
}

func TestPointerStreamLatchesEdgeAndUsesIndigoDigitizer(t *testing.T) {
	sessionID := "pointer-session"
	interactionID := "pointer-interaction"
	type digitizerEvent struct {
		x, y      uint16
		eventType uint64
		edge      uint64
	}
	var events []digitizerEvent
	backend := &Backend{
		streams: map[string]*backendStream{
			sessionID: {route: "coredevice.pointerStream", interactionID: interactionID, pointer: &CoreDeviceService{}, pointerEdge: "none"},
		},
		sendIndigoDigitizer: func(_ *CoreDeviceService, x, y uint16, eventType, edge uint64) error {
			events = append(events, digitizerEvent{x: x, y: y, eventType: eventType, edge: edge})
			return nil
		},
	}
	frame := func(kind, edge, x, y string) protocol.Message {
		return protocol.Message{
			SessionID: &sessionID,
			Payload: map[string]any{
				"interactionID": interactionID,
				"framePayload":  map[string]any{"kind": kind, "edge": edge, "x": x, "y": y},
			},
		}
	}
	deadline := time.Now().Add(time.Second)
	if err := backend.SendFrame(frame("begin", "bottom", "0.5", "1"), deadline); err != nil {
		t.Fatal(err)
	}
	if err := backend.SendFrame(frame("move", "none", "0.5", "0.75"), deadline); err != nil {
		t.Fatal(err)
	}
	if err := backend.CloseStream(protocol.Message{SessionID: &sessionID, Payload: map[string]any{"interactionID": interactionID}}, deadline); err != nil {
		t.Fatal(err)
	}
	want := []digitizerEvent{
		{x: 32768, y: 65535, eventType: 0, edge: 3},
		{x: 32768, y: 49151, eventType: 1, edge: 3},
		{x: 32768, y: 49151, eventType: 2, edge: 3},
	}
	if !reflect.DeepEqual(events, want) {
		t.Fatalf("digitizer events = %#v, want %#v", events, want)
	}
	if _, exists := backend.streams[sessionID]; exists {
		t.Fatal("closed pointer stream remains registered")
	}
}

func TestPointerStreamRejectsInvalidBeginEdge(t *testing.T) {
	sessionID := "pointer-session"
	interactionID := "pointer-interaction"
	calls := 0
	backend := &Backend{
		streams: map[string]*backendStream{
			sessionID: {route: "coredevice.pointerStream", interactionID: interactionID, pointer: &CoreDeviceService{}, pointerEdge: "none"},
		},
		sendIndigoDigitizer: func(_ *CoreDeviceService, _ uint16, _ uint16, _ uint64, _ uint64) error {
			calls++
			return nil
		},
	}
	err := backend.SendFrame(protocol.Message{
		SessionID: &sessionID,
		Payload: map[string]any{
			"interactionID": interactionID,
			"framePayload":  map[string]any{"kind": "begin", "edge": "diagonal", "x": "0.5", "y": "0.5"},
		},
	}, time.Now().Add(time.Second))
	productErr, ok := err.(*ProductError)
	if !ok || productErr.Code != "invalidArgument" || productErr.Stage != "frameAccepted" {
		t.Fatalf("error = %#v", err)
	}
	if calls != 0 {
		t.Fatalf("invalid edge sent %d digitizer events", calls)
	}
}

func TestStreamRejectsStaleDeliveryAttempt(t *testing.T) {
	sessionID := "pointer-session"
	interactionID := "pointer-interaction"
	staleDeliveryID := "delivery-stale"
	backend := &Backend{
		streams: map[string]*backendStream{
			sessionID: {
				deliveryAttemptID: "delivery-current",
				interactionID:     interactionID,
				pointer:           &CoreDeviceService{},
				pointerEdge:       "none",
				route:             "coredevice.pointerStream",
			},
		},
	}
	err := backend.SendFrame(protocol.Message{
		DeliveryAttemptID: &staleDeliveryID,
		SessionID:         &sessionID,
		Payload: map[string]any{
			"interactionID": interactionID,
			"framePayload":  map[string]any{"kind": "begin", "edge": "none", "x": "0.5", "y": "0.5"},
		},
	}, time.Now().Add(time.Second))
	productErr, ok := err.(*ProductError)
	if !ok || productErr.Code != "invalidArgument" || productErr.Stage != "frameAccepted" {
		t.Fatalf("error = %#v", err)
	}
}

func TestCloseStreamRemovesSessionAfterReleaseFailure(t *testing.T) {
	sessionID := "pointer-session"
	interactionID := "pointer-interaction"
	deliveryID := "delivery-current"
	backend := &Backend{
		streams: map[string]*backendStream{
			sessionID: {
				deliveryAttemptID: deliveryID,
				interactionID:     interactionID,
				lastX:             32768,
				lastY:             32768,
				pointer:           &CoreDeviceService{},
				pointerActive:     true,
				pointerEdge:       "none",
				pointerIndigo:     true,
				route:             "coredevice.pointerStream",
			},
		},
		sendIndigoDigitizer: func(_ *CoreDeviceService, _ uint16, _ uint16, _ uint64, _ uint64) error {
			return errors.New("release failed")
		},
	}
	err := backend.CloseStream(protocol.Message{
		DeliveryAttemptID: &deliveryID,
		SessionID:         &sessionID,
		Payload:           map[string]any{"interactionID": interactionID},
	}, time.Now().Add(time.Second))
	productErr, ok := err.(*ProductError)
	if !ok || productErr.Code != "outcomeUnknown" || productErr.Stage != "closingInputService" {
		t.Fatalf("error = %#v", err)
	}
	if _, exists := backend.streams[sessionID]; exists {
		t.Fatal("failed stream cleanup retained the session")
	}
}

func TestIndigoDigitizerRequestMatchesPythonProjection(t *testing.T) {
	request := indigoDigitizerRequest(32768, 65535, 1, 3)
	if request["featureIdentifier"] != "com.apple.coredevice.feature.remote.hid.digitizer" || request["messageType"] != "IndigoDigitizerEvent" {
		t.Fatalf("request envelope = %#v", request)
	}
	payload, ok := request["payload"].(map[string]any)
	if !ok || payload["eventType"] != XPCUInt64(1) || payload["edge"] != XPCUInt64(3) || payload["target"] != XPCUInt64(0) {
		t.Fatalf("payload = %#v", request["payload"])
	}
	point, ok := payload["pointOne"].(map[string]any)
	if !ok || point["x"] != float64(32768)/65535 || point["y"] != float64(1) {
		t.Fatalf("point = %#v", payload["pointOne"])
	}
}
