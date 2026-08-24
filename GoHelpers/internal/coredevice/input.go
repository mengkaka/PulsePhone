package coredevice

import (
	"errors"
	"time"

	"pulsephone/GoHelpers/internal/protocol"
)

const (
	maximumTextBytes              = 64 * 1024
	keyboardServiceID             = uint64(0x100002001)
	keyboardServiceReadinessDelay = time.Second
	touchscreenServiceID          = uint64(257)
	keyboardReportID              = byte(0x01)
)

var keyboardUsagesByName = map[string]uint16{
	"a": 0x04, "b": 0x05, "c": 0x06, "d": 0x07, "e": 0x08, "f": 0x09,
	"g": 0x0a, "h": 0x0b, "i": 0x0c, "j": 0x0d, "k": 0x0e, "l": 0x0f,
	"m": 0x10, "n": 0x11, "o": 0x12, "p": 0x13, "q": 0x14, "r": 0x15,
	"s": 0x16, "t": 0x17, "u": 0x18, "v": 0x19, "w": 0x1a, "x": 0x1b,
	"y": 0x1c, "z": 0x1d,
	"1": 0x1e, "2": 0x1f, "3": 0x20, "4": 0x21, "5": 0x22, "6": 0x23,
	"7": 0x24, "8": 0x25, "9": 0x26, "0": 0x27,
	"return": 0x28, "escape": 0x29, "backspace": 0x2a, "tab": 0x2b,
	"space": 0x2c, "minus": 0x2d, "equal": 0x2e, "left-bracket": 0x2f,
	"right-bracket": 0x30, "backslash": 0x31, "semicolon": 0x33,
	"quote": 0x34, "grave": 0x35, "comma": 0x36, "period": 0x37,
	"slash": 0x38, "caps-lock": 0x39, "home": 0x4a, "page-up": 0x4b,
	"delete-forward": 0x4c, "end": 0x4d, "page-down": 0x4e, "right": 0x4f,
	"left": 0x50, "down": 0x51, "up": 0x52,
}

var modifierUsagesByName = map[string]uint16{
	"control": 0xe0, "shift": 0xe1, "option": 0xe2, "command": 0xe3,
}

var cursorMoves = map[string]struct {
	modifiers []string
	key       string
}{
	"left": {}, "right": {}, "up": {}, "down": {},
	"word-left":      {modifiers: []string{"option"}, key: "left"},
	"word-right":     {modifiers: []string{"option"}, key: "right"},
	"line-start":     {modifiers: []string{"command"}, key: "left"},
	"line-end":       {modifiers: []string{"command"}, key: "right"},
	"document-start": {modifiers: []string{"command"}, key: "up"},
	"document-end":   {modifiers: []string{"command"}, key: "down"},
}

var keyboardMonotonicNow = ContinuousMonotonicNanoseconds

var keyboardFallbackNow = func() uint64 {
	return uint64(time.Now().UnixNano())
}

type keyboardChord struct {
	modifiers []string
	key       string
}

func (backend *Backend) ensureKeyboardService(deadline time.Time) (uint64, error) {
	for {
		backend.mu.Lock()
		if backend.closed {
			backend.mu.Unlock()
			return 0, errors.New("CoreDevice backend closed")
		}
		if backend.keyboardID != 0 && backend.keyboardReady {
			id := backend.keyboardID
			backend.mu.Unlock()
			return id, nil
		}
		if backend.keyboardInitializing {
			done := backend.keyboardInitializationDone
			backend.mu.Unlock()
			if err := waitForKeyboardInitialization(done, deadline); err != nil {
				return 0, err
			}
			continue
		}
		id := backend.keyboardID
		epoch := backend.keyboardEpoch
		done := make(chan struct{})
		backend.keyboardInitializing = true
		backend.keyboardInitializationDone = done
		opener := backend.openKeyboardService
		readinessWait := backend.waitKeyboardReadiness
		backend.mu.Unlock()

		var err error
		if id == 0 {
			if opener == nil {
				id, err = backend.createKeyboardService(deadline)
			} else {
				id, err = opener(deadline)
			}
		}
		if err == nil && id == 0 {
			err = errors.New("keyboard service creation returned no service ID")
		}
		if err == nil {
			if readinessWait == nil {
				err = waitForKeyboardReadiness(keyboardServiceReadinessDelay, deadline)
			} else {
				err = readinessWait(keyboardServiceReadinessDelay, deadline)
			}
		}

		backend.mu.Lock()
		stale := backend.closed || backend.keyboardEpoch != epoch
		if !stale && id != 0 {
			// Preserve a successfully-created service across an interrupted readiness wait.
			backend.keyboardID = id
		}
		if !stale && err == nil {
			backend.keyboardReady = true
		}
		if backend.keyboardInitializing && backend.keyboardInitializationDone == done {
			backend.keyboardInitializing = false
			backend.keyboardInitializationDone = nil
			close(done)
		}
		backend.mu.Unlock()
		if stale {
			return 0, errors.New("keyboard service retired during initialization")
		}
		if err != nil {
			return 0, err
		}
		return id, nil
	}
}

func (backend *Backend) createKeyboardService(deadline time.Time) (uint64, error) {
	hid, err := backend.service(coreDeviceServiceHID, deadline)
	if err != nil {
		return 0, err
	}
	response, err := hid.RequestAndReceive(map[string]any{
		"featureIdentifier": "com.apple.coredevice.feature.remote.universalhidservice",
		"messageType":       "Request",
		"payload": map[string]any{
			"createService": map[string]any{
				"_0": keyboardServiceDescriptor(),
			},
		},
	})
	if err != nil {
		return 0, err
	}
	id := numberValue(response["serviceID"])
	if id == 0 {
		id = keyboardServiceID
	}
	return id, nil
}

func waitForKeyboardReadiness(duration time.Duration, deadline time.Time) error {
	select {
	case <-time.After(duration):
	case <-deadlineChannel(deadline):
		return errors.New("keyboard service readiness timeout")
	}
	return nil
}

func waitForKeyboardInitialization(done <-chan struct{}, deadline time.Time) error {
	select {
	case <-done:
		return nil
	case <-deadlineChannel(deadline):
		return errors.New("keyboard service readiness timeout")
	}
}

func (backend *Backend) resetKeyboardLocked() {
	backend.keyboardEpoch++
	backend.keyboardID = 0
	backend.keyboardReady = false
}

func keyboardServiceDescriptor() map[string]any {
	descriptor := []byte{
		0x05, 0x01, 0x09, 0x06, 0xa1, 0x01, 0x05, 0x07, 0x19, 0xe0,
		0x29, 0xe7, 0x15, 0x00, 0x25, 0x01, 0x95, 0x08, 0x75, 0x01,
		0x81, 0x02, 0x95, 0x01, 0x75, 0x08, 0x81, 0x01, 0x05, 0x07,
		0x19, 0x00, 0x29, 0xff, 0x15, 0x00, 0x26, 0xff, 0x00, 0x95,
		0x06, 0x75, 0x08, 0x81, 0x00, 0x05, 0x08, 0x19, 0x01, 0x29,
		0x05, 0x15, 0x00, 0x25, 0x01, 0x95, 0x05, 0x75, 0x01, 0x91,
		0x02, 0x95, 0x01, 0x75, 0x03, 0x91, 0x01, 0xc0,
	}
	usagePage := XPCInt64(1)
	usage := XPCInt64(6)
	vendor := XPCInt64(0x05ac)
	productID := XPCInt64(0x0250)
	serviceID := XPCUInt64(keyboardServiceID)
	topPair := map[string]any{"DeviceUsage": usage, "DeviceUsagePage": usagePage}
	storage := map[string]any{
		"Manufacturer":                   map[string]any{"string": "PulsePhone"},
		"Product":                        map[string]any{"string": "PulsePhone virtual keyboard"},
		"ProductID":                      map[string]any{"int": productID},
		"VendorID":                       map[string]any{"int": vendor},
		"PrimaryUsage":                   map[string]any{"int": usage},
		"PrimaryUsagePage":               map[string]any{"int": usagePage},
		"DeviceUsagePairs":               map[string]any{"array": []any{map[string]any{"dictionary": map[string]any{"DeviceUsage": map[string]any{"int": usage}, "DeviceUsagePage": map[string]any{"int": usagePage}}}}},
		"Transport":                      map[string]any{"string": "USB"},
		"ReportDescriptor":               map[string]any{"data": descriptor},
		"UniversalControlVirtualService": map[string]any{"bool": true},
		"_ServiceID":                     map[string]any{"uint": serviceID},
	}
	return map[string]any{
		"DeviceUsagePairs":                   []any{topPair},
		"PrimaryUsage":                       XPCUInt64(6),
		"PrimaryUsagePage":                   XPCUInt64(1),
		"Product":                            "PulsePhone virtual keyboard",
		"ProductID":                          productID,
		"VendorID":                           vendor,
		"_CoreDevice_codablePropertyStorage": storage,
		"_ServiceID":                         serviceID,
	}
}

func sendKeyboardReport(service *CoreDeviceService, serviceID uint64, usages []uint16) error {
	return sendUniversalReport(service, serviceID, buildKeyboardReport(usages, keyboardReportTimestamp()))
}

func keyboardReportTimestamp() uint64 {
	if timestamp, available := keyboardMonotonicNow(); available {
		return timestamp
	}
	return keyboardFallbackNow()
}

func buildKeyboardReport(usages []uint16, stamp uint64) []byte {
	report := make([]byte, 39)
	report[0] = keyboardReportID
	for _, usage := range usages {
		if usage < 240 {
			report[1+usage/8] |= 1 << (usage % 8)
		}
	}
	stamp &= (uint64(1) << 48) - 1
	for index := 0; index < 6; index++ {
		report[31+index] = byte(stamp >> (8 * index))
	}
	return report
}

func keyboardUsages(value any) ([]uint16, bool) {
	items, ok := value.([]any)
	if !ok || len(items) > 16 {
		return nil, false
	}
	result := make([]uint16, 0, len(items))
	seen := make(map[uint16]struct{}, len(items))
	for _, item := range items {
		usage, valid := unsignedNumber(item)
		if !valid || usage > 0xe7 {
			return nil, false
		}
		code := uint16(usage)
		if _, exists := seen[code]; exists {
			return nil, false
		}
		seen[code] = struct{}{}
		result = append(result, code)
	}
	return result, true
}

func (backend *Backend) pasteboardSetAndPaste(payload map[string]any, deadline time.Time) (map[string]any, error) {
	text, ok := payload["text"].(string)
	if !ok || len([]byte(text)) > maximumTextBytes {
		if !ok {
			return nil, &ProductError{Code: "invalidArgument", Stage: "requestValidation"}
		}
		return nil, &ProductError{Code: "argumentTooLarge", Stage: "requestValidation"}
	}
	if _, err := backend.ensureKeyboardService(deadline); err != nil {
		return nil, &ProductError{Code: "developerServicesUnavailable", Stage: "openingInputService"}
	}
	setSession, err := backend.pasteboardService(deadline)
	if err != nil {
		return nil, &ProductError{Code: "developerServicesUnavailable", Stage: "openingInputService"}
	}
	item := map[string]any{
		"types": []any{"public.utf8-plain-text", "public.plain-text", "public.text"},
		"data": map[string]any{
			"public.utf8-plain-text": map[string]any{"data": []byte(text)},
			"public.plain-text":      map[string]any{"data": []byte(text)},
			"public.text":            map[string]any{"data": []byte(text)},
		},
	}
	_, setErr := setSession.RequestAndReceiveWithDeadline(map[string]any{
		"command": "SET", "pasteboardName": "general", "items": []any{item}, "sourceMetadata": nil,
	}, deadline)
	_ = setSession.Close()
	if setErr != nil {
		// The legacy helper intentionally collapses this internal adapter error to
		// the registered public error code before it reaches HelperWire.
		return nil, &ProductError{Code: "internalFailure"}
	}
	pullSession, err := backend.pasteboardService(deadline)
	if err != nil {
		return nil, &ProductError{Code: "backendFailed", Committed: true, Stage: "pasteboardReadBack"}
	}
	reply, pullErr := pullSession.RequestAndReceiveWithDeadline(map[string]any{
		"command": "PULL", "pasteboardName": "general", "dataPolicy": map[string]any{"allResolved": map[string]any{}},
	}, deadline)
	_ = pullSession.Close()
	if pullErr != nil {
		return nil, &ProductError{Code: "backendFailed", Committed: true, Stage: "pasteboardReadBack"}
	}
	readBack, ok := pasteboardText(reply)
	if !ok || readBack != text {
		return nil, &ProductError{Code: "backendFailed", Committed: true, Stage: "pasteboardReadBack"}
	}
	keyboardID, _ := backend.ensureKeyboardService(deadline)
	hid, _ := backend.service(coreDeviceServiceHID, deadline)
	if err := sendKeyboardChord(hid, keyboardID, []uint16{modifierUsagesByName["command"]}, keyboardUsagesByName["v"], 20*time.Millisecond, 80*time.Millisecond); err != nil {
		_ = sendKeyboardReport(hid, keyboardID, nil)
		return nil, &ProductError{Code: "outcomeUnknown", Committed: true, OutcomeUnknown: true, Stage: "paste"}
	}
	if err := sendKeyboardReport(hid, keyboardID, nil); err != nil {
		return nil, &ProductError{Code: "outcomeUnknown", Committed: true, OutcomeUnknown: true, Stage: "cleanup"}
	}
	return map[string]any{"disposition": "pasteDispatched", "resolvedRouteID": "coredevice.pasteboardSetAndPaste", "textByteCount": int64(len([]byte(text)))}, nil
}

func (backend *Backend) keyboardMacro(payload map[string]any, deadline time.Time) (map[string]any, error) {
	steps, disposition, err := buildKeyboardMacro(payload)
	if err != nil {
		return nil, &ProductError{Code: "invalidArgument", Stage: "requestValidation"}
	}
	keyboardID, err := backend.ensureKeyboardService(deadline)
	if err != nil {
		return nil, &ProductError{Code: "developerServicesUnavailable", Stage: "openingInputService"}
	}
	hid, err := backend.service(coreDeviceServiceHID, deadline)
	if err != nil {
		return nil, &ProductError{Code: "developerServicesUnavailable", Stage: "openingInputService"}
	}
	report := func(usages []uint16) error {
		return sendKeyboardReport(hid, keyboardID, usages)
	}
	committed, stage, err := executeKeyboardMacro(steps, report, time.Sleep)
	if err != nil {
		return nil, &ProductError{Code: "outcomeUnknown", Committed: committed, OutcomeUnknown: committed, Stage: stage}
	}
	return map[string]any{"disposition": disposition, "resolvedRouteID": "coredevice.keyboardMacro"}, nil
}

func (backend *Backend) softwareKeyboardToggle(deadline time.Time) (map[string]any, error) {
	button, err := backend.service(coreDeviceServiceButton, deadline)
	if err != nil {
		return nil, &ProductError{Code: "developerServicesUnavailable", Stage: "openingInputService"}
	}
	send := func(state uint64) error {
		return button.SendRequest(map[string]any{
			"messageType":       "IndigoButtonEvent",
			"payload":           map[string]any{"state": XPCUInt64(state), "usagePage": XPCUInt64(0x0c), "usageCode": XPCUInt64(0xb8)},
			"featureIdentifier": "com.apple.coredevice.feature.remote.hid.button",
		}, false)
	}
	if err := executeSoftwareKeyboardToggle(send, func(duration time.Duration) error {
		return waitForTouchFrame(duration, deadline)
	}); err != nil {
		return nil, &ProductError{Code: "outcomeUnknown", Committed: true, OutcomeUnknown: true, Stage: "softwareKeyboardToggle"}
	}
	return map[string]any{"disposition": "acknowledged", "resolvedRouteID": "coredevice.softwareKeyboardToggle", "stateUnknown": true}, nil
}

func buildKeyboardMacro(payload map[string]any) ([]keyboardChord, string, error) {
	command, ok := payload["commandID"].(string)
	if !ok {
		return nil, "", errors.New("command")
	}
	switch command {
	case "text.key":
		if !samePayloadKeys(payload, "commandID", "key", "modifiers", "repeat") {
			return nil, "", errors.New("shape")
		}
		key, ok := payload["key"].(string)
		mods, okMods := parseModifiers(payload["modifiers"])
		repeat, okRepeat := boundedRepeat(payload["repeat"])
		if !ok || !okMods || !okRepeat {
			return nil, "", errors.New("key")
		}
		steps := repeatedChord(mods, key, repeat)
		if len(steps) != repeat {
			return nil, "", errors.New("key")
		}
		return steps, "keyDispatched", nil
	case "text.cursor":
		if !samePayloadKeys(payload, "commandID", "count", "move", "select") {
			return nil, "", errors.New("shape")
		}
		move, ok := payload["move"].(string)
		selectValue, okSelect := payload["select"].(bool)
		count, okCount := boundedRepeat(payload["count"])
		cursor, okCursor := cursorMoves[move]
		if !ok || !okSelect || !okCount || !okCursor {
			return nil, "", errors.New("cursor")
		}
		mods := append([]string(nil), cursor.modifiers...)
		if selectValue {
			mods = append(mods, "shift")
		}
		return repeatedChord(mods, cursor.key, count), "cursorMoveDispatched", nil
	case "text.clear":
		if len(payload) != 1 {
			return nil, "", errors.New("shape")
		}
		return []keyboardChord{{modifiers: []string{"command"}, key: "a"}, {key: "backspace"}}, "clearDispatched", nil
	case "text.inputSource.next":
		if len(payload) != 1 {
			return nil, "", errors.New("shape")
		}
		return []keyboardChord{{modifiers: []string{"control"}, key: "space"}}, "inputSourceCycleDispatched", nil
	default:
		return nil, "", errors.New("unknown")
	}
}

type keyboardReportSender func(usages []uint16) error

type keyboardPause func(time.Duration)

type buttonEventSender func(state uint64) error

func executeSoftwareKeyboardToggle(send buttonEventSender, wait func(time.Duration) error) error {
	if err := send(1); err != nil {
		return err
	}
	// Once down is sent, always make the matching up attempt, even if the wait is
	// interrupted by the operation deadline.
	waitErr := wait(50 * time.Millisecond)
	releaseErr := send(2)
	if waitErr != nil {
		return waitErr
	}
	return releaseErr
}

func executeKeyboardMacro(steps []keyboardChord, send keyboardReportSender, pause keyboardPause) (bool, string, error) {
	committed := false
	for _, step := range steps {
		committed = true
		modifiers := make([]uint16, 0, len(step.modifiers))
		for _, modifier := range step.modifiers {
			modifiers = append(modifiers, modifierUsagesByName[modifier])
		}
		if err := sendKeyboardChordWithSender(send, pause, modifiers, keyboardUsagesByName[step.key], 12*time.Millisecond, 12*time.Millisecond); err != nil {
			_ = send(nil)
			return committed, "keyboardMacro", err
		}
		if err := send(nil); err != nil {
			// Match the legacy executor's outer cleanup attempt after release failure.
			_ = send(nil)
			return committed, "cleanup", err
		}
	}
	return committed, "", nil
}

func sendKeyboardChord(service *CoreDeviceService, serviceID uint64, modifiers []uint16, key uint16, modifierDelay, keyDelay time.Duration) error {
	return sendKeyboardChordWithSender(func(usages []uint16) error {
		return sendKeyboardReport(service, serviceID, usages)
	}, time.Sleep, modifiers, key, modifierDelay, keyDelay)
}

func sendKeyboardChordWithSender(send keyboardReportSender, pause keyboardPause, modifiers []uint16, key uint16, modifierDelay, keyDelay time.Duration) error {
	if len(modifiers) > 0 {
		if err := send(modifiers); err != nil {
			return err
		}
		pause(modifierDelay)
	}
	pressed := append(append([]uint16(nil), modifiers...), key)
	if err := send(pressed); err != nil {
		return err
	}
	pause(keyDelay)
	return nil
}

func parseModifiers(value any) ([]string, bool) {
	items, ok := value.([]any)
	if !ok || len(items) > len(modifierUsagesByName) {
		return nil, false
	}
	result := make([]string, 0, len(items))
	previous := ""
	for _, raw := range items {
		modifier, ok := raw.(string)
		if !ok || modifierUsagesByName[modifier] == 0 || (previous != "" && modifier <= previous) {
			return nil, false
		}
		previous = modifier
		result = append(result, modifier)
	}
	return result, true
}

func boundedRepeat(value any) (int, bool) {
	repeat, ok := unsignedNumber(value)
	return int(repeat), ok && repeat >= 1 && repeat <= 100
}

func repeatedChord(modifiers []string, key string, count int) []keyboardChord {
	if _, ok := keyboardUsagesByName[key]; !ok {
		return nil
	}
	result := make([]keyboardChord, count)
	for index := range result {
		result[index] = keyboardChord{modifiers: append([]string(nil), modifiers...), key: key}
	}
	return result
}

func samePayloadKeys(payload map[string]any, expected ...string) bool {
	if len(payload) != len(expected) {
		return false
	}
	for _, key := range expected {
		if _, ok := payload[key]; !ok {
			return false
		}
	}
	return true
}

func pasteboardText(value map[string]any) (string, bool) {
	snapshot, _ := value["pasteboard"].(map[string]any)
	if snapshot == nil {
		snapshot = value
	}
	items, _ := snapshot["items"].([]any)
	for _, rawItem := range items {
		item, _ := rawItem.(map[string]any)
		dataMap, _ := item["data"].(map[string]any)
		for _, uti := range []string{"public.utf8-plain-text", "public.plain-text", "public.text"} {
			datum, _ := dataMap[uti].(map[string]any)
			raw, ok := datum["data"]
			if !ok {
				continue
			}
			switch value := raw.(type) {
			case []byte:
				return string(value), true
			case string:
				return value, true
			}
		}
	}
	return "", false
}

func normalizedAxisValue(value any) (uint16, bool) {
	if text, ok := value.(string); ok {
		return normalizedAxis(text)
	}
	coordinate, err := protocol.RequireUInt64(value)
	if err != nil || coordinate > 65535 {
		return 0, false
	}
	return uint16(coordinate), true
}

func numberValue(value any) uint64 {
	parsed, _ := unsignedNumber(value)
	return parsed
}

func unsignedNumber(value any) (uint64, bool) {
	switch value := value.(type) {
	case XPCUInt64:
		return uint64(value), true
	case XPCInt64:
		if value >= 0 {
			return uint64(value), true
		}
	case uint64:
		return value, true
	case int64:
		if value >= 0 {
			return uint64(value), true
		}
	case int:
		if value >= 0 {
			return uint64(value), true
		}
	case float64:
		if value >= 0 && value == float64(uint64(value)) {
			return uint64(value), true
		}
	}
	return 0, false
}

func optionalMessageString(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}

func deadlineChannel(deadline time.Time) <-chan time.Time {
	if deadline.IsZero() {
		return nil
	}
	return time.After(time.Until(deadline))
}
