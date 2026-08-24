package coredevice

import (
	"os"
	"path/filepath"
	"testing"
	"time"

	"pulsephone/GoHelpers/internal/protocol"
)

func TestRealDeviceCoreDeviceReadOnlySmoke(t *testing.T) {
	udid := os.Getenv("PULSEPHONE_REAL_DEVICE_UDID")
	if udid == "" {
		t.Skip("set PULSEPHONE_REAL_DEVICE_UDID to run the physical-device smoke")
	}
	deadline := time.Now().Add(45 * time.Second)
	tunnel, err := OpenUserspaceTunnel(udid, deadline)
	if err != nil {
		t.Fatalf("open tunnel: %v", err)
	}
	defer tunnel.Close()
	service, err := tunnel.RSD.StartService("com.apple.coredevice.deviceinfo", deadline)
	if err != nil {
		t.Fatalf("start deviceinfo: %v", err)
	}
	defer service.Close()
	value, err := service.Invoke("com.apple.coredevice.feature.getdeviceinfo", map[string]any{}, "")
	if err != nil {
		t.Fatalf("invoke getdeviceinfo: %v", err)
	}
	if len(value) == 0 {
		t.Fatal("device info response is empty")
	}
}

func TestRealDeviceTunnelCloseAndReopenSmoke(t *testing.T) {
	udid := os.Getenv("PULSEPHONE_REAL_DEVICE_UDID")
	if udid == "" || os.Getenv("PULSEPHONE_REAL_DEVICE_LIFECYCLE_SMOKE") != "1" {
		t.Skip("set PULSEPHONE_REAL_DEVICE_UDID and PULSEPHONE_REAL_DEVICE_LIFECYCLE_SMOKE=1 to run tunnel lifecycle smoke")
	}
	for cycle := 1; cycle <= 2; cycle++ {
		started := time.Now()
		deadline := time.Now().Add(45 * time.Second)
		tunnel, err := OpenUserspaceTunnel(udid, deadline)
		if err != nil {
			t.Fatalf("cycle %d open tunnel: %v", cycle, err)
		}
		service, err := tunnel.RSD.StartService("com.apple.coredevice.deviceinfo", deadline)
		if err != nil {
			_ = tunnel.Close()
			t.Fatalf("cycle %d start deviceinfo: %v", cycle, err)
		}
		_, invokeErr := service.Invoke("com.apple.coredevice.feature.getdeviceinfo", map[string]any{}, "")
		serviceErr := service.Close()
		tunnelErr := tunnel.Close()
		if invokeErr != nil {
			t.Fatalf("cycle %d invoke deviceinfo: %v", cycle, invokeErr)
		}
		if serviceErr != nil {
			t.Fatalf("cycle %d close deviceinfo: %v", cycle, serviceErr)
		}
		if tunnelErr != nil {
			t.Fatalf("cycle %d close tunnel: %v", cycle, tunnelErr)
		}
		t.Logf("cycle %d opened, invoked, and closed tunnel in %s", cycle, time.Since(started).Round(time.Millisecond))
	}
}

func TestRealDevicePersonalizedMounterQuerySmoke(t *testing.T) {
	udid := os.Getenv("PULSEPHONE_REAL_DEVICE_UDID")
	if udid == "" {
		t.Skip("set PULSEPHONE_REAL_DEVICE_UDID to run the physical-device smoke")
	}
	mounter, err := OpenCoreDevicePersonalizedMounter(udid, time.Now().Add(45*time.Second))
	if err != nil {
		t.Fatalf("open personalized mounter: %v", err)
	}
	defer mounter.Close()
	mounted, err := mounter.QueryMounted()
	if err != nil {
		t.Fatalf("query personalized mounted state: %v", err)
	}
	t.Logf("personalized developer image mounted=%t", mounted.Present)
	inputs, err := mounter.PersonalizationInputs()
	if err != nil {
		t.Fatalf("query personalization inputs: %v", err)
	}
	if inputs.ECID == 0 || len(inputs.Identifiers) == 0 || len(inputs.Nonce) == 0 {
		t.Fatalf("incomplete personalization inputs: ecid=%d identifiers=%d nonceBytes=%d", inputs.ECID, len(inputs.Identifiers), len(inputs.Nonce))
	}
	t.Logf("personalization input shape ecidPresent=true identifiers=%d nonceBytes=%d", len(inputs.Identifiers), len(inputs.Nonce))
	if mounted.Present {
		if err := mounter.ProbeServices([]string{"com.apple.coredevice.appservice"}, time.Now().Add(30*time.Second)); err != nil {
			t.Fatalf("probe personalized services: %v", err)
		}
	} else {
		t.Log("skipping CoreDevice service probe until a personalized image is mounted")
	}
}

func TestRealDeviceCoreDeviceDisplayAndScreenshotReadOnlySmoke(t *testing.T) {
	udid := os.Getenv("PULSEPHONE_REAL_DEVICE_UDID")
	if udid == "" {
		t.Skip("set PULSEPHONE_REAL_DEVICE_UDID to run the physical-device smoke")
	}
	deadline := time.Now().Add(45 * time.Second)
	tunnel, err := OpenUserspaceTunnel(udid, deadline)
	if err != nil {
		t.Fatalf("open tunnel: %v", err)
	}
	defer tunnel.Close()

	deviceInfo, err := tunnel.RSD.StartService("com.apple.coredevice.deviceinfo", deadline)
	if err != nil {
		t.Fatalf("start deviceinfo: %v", err)
	}
	geometry, err := deviceInfo.Invoke("com.apple.coredevice.feature.getdisplayinfo", map[string]any{}, "")
	_ = deviceInfo.Close()
	if err != nil {
		t.Fatalf("getdisplayinfo: %v", err)
	}
	if len(geometry) == 0 {
		t.Fatal("display info response is empty")
	}

	screenshot, err := tunnel.RSD.StartService("com.apple.coredevice.screencaptureservice", deadline)
	if err != nil {
		t.Fatalf("start screencapture: %v", err)
	}
	defer screenshot.Close()
	image, err := screenshot.Invoke("com.apple.coredevice.feature.capturescreenshot", map[string]any{
		"displayUniqueID": nil, "requestedFormat": "png",
	}, "com.apple.coredevice.action.capturescreenshot")
	if err != nil {
		t.Fatalf("capturescreenshot: %v", err)
	}
	data, ok := image["image"].([]byte)
	if !ok || len(data) == 0 {
		t.Fatalf("screenshot image = %#v", image["image"])
	}
	t.Logf("display keys=%v screenshot bytes=%d format=%v", mapKeys(geometry), len(data), image["imageFormat"])
}

func TestRealDeviceCoreDeviceBackendReadOnlyRoutes(t *testing.T) {
	udid := os.Getenv("PULSEPHONE_REAL_DEVICE_UDID")
	if udid == "" {
		t.Skip("set PULSEPHONE_REAL_DEVICE_UDID to run the physical-device smoke")
	}
	backend, err := NewBackend(udid, 1, map[string]string{
		"appControl":  "com.apple.coredevice.appservice",
		"button":      "com.apple.coredevice.hid.indigo",
		"hid":         "com.apple.coredevice.hid.universalhidservice",
		"keyboard":    "com.apple.coredevice.hid.universalhidservice",
		"orientation": "com.apple.coredevice.devicecontrol",
		"pasteboard":  "com.apple.coredevice.pasteboardservice",
		"screenshot":  "com.apple.coredevice.screencaptureservice",
	})
	if err != nil {
		t.Fatal(err)
	}
	defer backend.Close()
	if _, err := backend.Warm(time.Now().Add(45 * time.Second)); err != nil {
		t.Fatalf("warm backend: %v", err)
	}

	display, err := backend.Execute(protocol.Message{Payload: map[string]any{
		"executorOperationID": "coredevice.displayGeometry.query",
		"backendPayload":      map[string]any{},
	}})
	if err != nil {
		t.Fatalf("display route: %v", err)
	}
	if display["resolvedRouteID"] != "coredevice.displayGeometry.query" {
		t.Fatalf("display result = %#v", display)
	}

	geometryRevision := any(int64(1))
	logicalWidth := display["logicalWidth"]
	logicalHeight := display["logicalHeight"]
	orientation := display["orientation"]
	rotate := func(direction string) map[string]any {
		value, routeErr := backend.Execute(protocol.Message{Payload: map[string]any{
			"executorOperationID": "coredevice.orientation.rotate",
			"backendPayload": map[string]any{
				"connectionEpoch":  int64(1),
				"direction":        direction,
				"geometryRevision": geometryRevision,
				"logicalHeight":    logicalHeight,
				"logicalWidth":     logicalWidth,
				"orientation":      orientation,
			},
		}})
		if routeErr != nil {
			t.Fatalf("rotate %s: %v", direction, routeErr)
		}
		geometryRevision = value["geometryRevision"].(uint64)
		logicalWidth = value["logicalWidth"]
		logicalHeight = value["logicalHeight"]
		orientation = value["orientation"]
		return value
	}
	left := rotate("left")
	if left["orientation"] == "" {
		t.Fatalf("left rotation result = %#v", left)
	}
	right := rotate("right")
	if right["orientation"] == "" {
		t.Fatalf("right rotation result = %#v", right)
	}
	touch, err := backend.Execute(protocol.Message{Payload: map[string]any{
		"executorOperationID": "coredevice.normalTouch",
		"backendPayload": map[string]any{"frames": []any{
			map[string]any{"elapsedMs": int64(0), "kind": "begin", "x": "0.5", "y": "0.5"},
			map[string]any{"elapsedMs": int64(0), "kind": "end", "x": "0.5", "y": "0.5"},
		}},
	}})
	if err != nil {
		t.Fatalf("touch route: %v", err)
	}
	if touch["resolvedRouteID"] != "coredevice.normalTouch" {
		t.Fatalf("touch result = %#v", touch)
	}
	launch, err := backend.Execute(protocol.Message{Payload: map[string]any{
		"executorOperationID": "coredevice.appLaunch",
		"backendPayload":      map[string]any{"bundleID": "com.apple.Preferences"},
	}})
	if err != nil {
		t.Fatalf("launch route: %v", err)
	}
	if launch["resolvedRouteID"] != "coredevice.appLaunch" {
		t.Fatalf("launch result = %#v", launch)
	}

	artifactID := "11111111-1111-4111-8111-111111111111"
	reservation := filepath.Join(t.TempDir(), artifactID+".png")
	file, err := os.OpenFile(reservation, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	screenshot, err := backend.Execute(protocol.Message{Payload: map[string]any{
		"executorOperationID": "coredevice.screenshot",
		"backendPayload": map[string]any{
			"artifactID":      artifactID,
			"reservationPath": reservation,
		},
	}})
	if err != nil {
		t.Fatalf("screenshot route: %v", err)
	}
	if screenshot["format"] != "png" {
		t.Fatalf("screenshot result = %#v", screenshot)
	}
	info, err := os.Stat(reservation)
	if err != nil {
		t.Fatalf("reservation stat: %v", err)
	}
	if info.Size() == 0 {
		t.Fatal("reservation is empty")
	}

	fallbackArtifactID := "22222222-2222-4222-8222-222222222222"
	fallbackReservation := filepath.Join(t.TempDir(), fallbackArtifactID+".png")
	file, err = os.OpenFile(fallbackReservation, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	fallback, err := backend.Execute(protocol.Message{Payload: map[string]any{
		"executorOperationID": "coredevice.screenshot",
		"backendPayload": map[string]any{
			"artifactID":           fallbackArtifactID,
			"captureProviderOrder": []any{"dvt", "coreDevice"},
			"commandID":            "element.snapshot",
			"reservationPath":      fallbackReservation,
		},
	}})
	if err != nil {
		t.Fatalf("screenshot fallback route: %v", err)
	}
	if fallback["captureProvider"] != "coreDevice" {
		t.Fatalf("screenshot fallback result = %#v", fallback)
	}
	t.Logf("screenshot fallback attempts=%v winner=%v", fallback["_pulsephoneCaptureAttempts"], fallback["captureProvider"])
}

func TestRealDeviceBackendGenerationReplacementSmoke(t *testing.T) {
	udid := os.Getenv("PULSEPHONE_REAL_DEVICE_UDID")
	if udid == "" || os.Getenv("PULSEPHONE_REAL_DEVICE_GENERATION_SMOKE") != "1" {
		t.Skip("set PULSEPHONE_REAL_DEVICE_UDID and PULSEPHONE_REAL_DEVICE_GENERATION_SMOKE=1 to run generation smoke")
	}
	backend, err := NewBackend(udid, 1, map[string]string{
		"appControl":  "com.apple.coredevice.appservice",
		"button":      "com.apple.coredevice.hid.indigo",
		"hid":         "com.apple.coredevice.hid.universalhidservice",
		"keyboard":    "com.apple.coredevice.hid.universalhidservice",
		"orientation": "com.apple.coredevice.devicecontrol",
		"pasteboard":  "com.apple.coredevice.pasteboardservice",
		"screenshot":  "com.apple.coredevice.screencaptureservice",
	})
	if err != nil {
		t.Fatal(err)
	}
	defer backend.Close()
	if _, err := backend.Warm(time.Now().Add(60 * time.Second)); err != nil {
		t.Fatalf("initial warm: %v", err)
	}
	started := time.Now()
	if err := backend.RetireGeneration("incompatible"); err != nil {
		t.Fatalf("retire generation: %v", err)
	}
	if err := backend.Reattach(2); err != nil {
		t.Fatalf("reattach generation: %v", err)
	}
	if _, err := backend.Warm(time.Now().Add(60 * time.Second)); err != nil {
		t.Fatalf("replacement warm: %v", err)
	}
	t.Logf("real backend generation replacement completed in %s", time.Since(started).Round(time.Millisecond))
}

func TestRealDeviceCoreDeviceInputAndStreamSmoke(t *testing.T) {
	udid := os.Getenv("PULSEPHONE_REAL_DEVICE_UDID")
	if udid == "" || os.Getenv("PULSEPHONE_REAL_DEVICE_INPUT_SMOKE") == "" {
		t.Skip("set PULSEPHONE_REAL_DEVICE_UDID and PULSEPHONE_REAL_DEVICE_INPUT_SMOKE to run input smoke")
	}
	backend, err := NewBackend(udid, 2, map[string]string{
		"appControl":  "com.apple.coredevice.appservice",
		"button":      "com.apple.coredevice.hid.indigo",
		"hid":         "com.apple.coredevice.hid.universalhidservice",
		"keyboard":    "com.apple.coredevice.hid.universalhidservice",
		"orientation": "com.apple.coredevice.devicecontrol",
		"pasteboard":  "com.apple.coredevice.pasteboardservice",
		"screenshot":  "com.apple.coredevice.screencaptureservice",
	})
	if err != nil {
		t.Fatal(err)
	}
	defer backend.Close()
	if _, err := backend.Warm(time.Now().Add(90 * time.Second)); err != nil {
		t.Fatalf("warm backend: %v", err)
	}

	for _, command := range []string{"button.home", "button.volumeUp", "button.volumeDown"} {
		if _, err := backend.Execute(protocol.Message{Payload: map[string]any{
			"executorOperationID": "coredevice." + command,
			"backendPayload":      map[string]any{"commandID": command},
		}}); err != nil {
			t.Fatalf("button %s: %v", command, err)
		}
	}
	macro, err := backend.Execute(protocol.Message{Payload: map[string]any{
		"executorOperationID": "coredevice.keyboardMacro",
		"backendPayload": map[string]any{
			"commandID": "text.key", "key": "a", "modifiers": []any{}, "repeat": int64(1),
		},
	}})
	if err != nil || macro["disposition"] != "keyDispatched" {
		t.Fatalf("keyboard macro: %#v %v", macro, err)
	}
	textResult, err := backend.Execute(protocol.Message{Payload: map[string]any{
		"executorOperationID": "coredevice.pasteboardSetAndPaste",
		"backendPayload":      map[string]any{"text": "PulsePhone-Go-input-smoke"},
	}})
	if err != nil || textResult["disposition"] != "pasteDispatched" {
		t.Fatalf("pasteboard text: %#v %v", textResult, err)
	}
	if _, err := backend.Execute(protocol.Message{Payload: map[string]any{
		"executorOperationID": "coredevice.softwareKeyboardToggle",
		"backendPayload":      map[string]any{"commandID": "gui.softwareKeyboard.toggle"},
	}}); err != nil {
		t.Fatalf("software keyboard toggle: %v", err)
	}

	interactionID := "00000000-0000-4000-8000-000000000002"
	sessionID := "00000000-0000-4000-8000-000000000003"
	deliveryID := "delivery-input-smoke"
	stream := protocol.Message{
		SessionID:         &sessionID,
		DeliveryAttemptID: &deliveryID,
		Payload: map[string]any{
			"interactionID": interactionID,
			"streamPayload": map[string]any{"routeID": "coredevice.pointerStream"},
		},
	}
	if err := backend.OpenStream(stream, time.Now().Add(60*time.Second)); err != nil {
		t.Fatalf("pointer stream open: %v", err)
	}
	stream.Payload["framePayload"] = map[string]any{"kind": "begin", "x": "0.5", "y": "0.5"}
	if err := backend.SendFrame(stream, time.Now().Add(60*time.Second)); err != nil {
		t.Fatalf("pointer stream frame: %v", err)
	}
	stream.Payload["framePayload"] = map[string]any{"kind": "end", "x": "0.5", "y": "0.5"}
	if err := backend.SendFrame(stream, time.Now().Add(60*time.Second)); err != nil {
		t.Fatalf("pointer stream end: %v", err)
	}
	if err := backend.CloseStream(stream, time.Now().Add(60*time.Second)); err != nil {
		t.Fatalf("pointer stream close: %v", err)
	}

	keyboardSessionID := "00000000-0000-4000-8000-000000000004"
	keyboardDeliveryID := "delivery-keyboard-smoke"
	keyboardStream := protocol.Message{
		SessionID:         &keyboardSessionID,
		DeliveryAttemptID: &keyboardDeliveryID,
		Payload: map[string]any{
			"interactionID": interactionID,
			"streamPayload": map[string]any{"routeID": "coredevice.keyboardStream"},
		},
	}
	if err := backend.OpenStream(keyboardStream, time.Now().Add(60*time.Second)); err != nil {
		t.Fatalf("keyboard stream open: %v", err)
	}
	keyboardStream.Payload["framePayload"] = map[string]any{"kind": "pressedSet", "usages": []any{int64(0x04)}}
	if err := backend.SendFrame(keyboardStream, time.Now().Add(60*time.Second)); err != nil {
		t.Fatalf("keyboard stream frame: %v", err)
	}
	if err := backend.CloseStream(keyboardStream, time.Now().Add(60*time.Second)); err != nil {
		t.Fatalf("keyboard stream close: %v", err)
	}
}

func TestRealDeviceTouchSequenceAfterScreenshotSmoke(t *testing.T) {
	udid := os.Getenv("PULSEPHONE_REAL_DEVICE_UDID")
	if udid == "" || os.Getenv("PULSEPHONE_REAL_DEVICE_TOUCH_SEQUENCE_SMOKE") != "1" {
		t.Skip("set PULSEPHONE_REAL_DEVICE_UDID and PULSEPHONE_REAL_DEVICE_TOUCH_SEQUENCE_SMOKE=1 to run the touch sequence smoke")
	}
	backend, err := NewBackend(udid, 3, map[string]string{
		"appControl":  "com.apple.coredevice.appservice",
		"button":      "com.apple.coredevice.hid.indigo",
		"hid":         "com.apple.coredevice.hid.universalhidservice",
		"keyboard":    "com.apple.coredevice.hid.universalhidservice",
		"orientation": "com.apple.coredevice.devicecontrol",
		"pasteboard":  "com.apple.coredevice.pasteboardservice",
		"screenshot":  "com.apple.coredevice.screencaptureservice",
	})
	if err != nil {
		t.Fatal(err)
	}
	defer backend.Close()
	if _, err := backend.Warm(time.Now().Add(90 * time.Second)); err != nil {
		t.Fatalf("warm backend: %v", err)
	}

	executeTouch := func(label string, frames []any) {
		t.Helper()
		value, routeErr := backend.Execute(protocol.Message{Payload: map[string]any{
			"executorOperationID": "coredevice.normalTouch",
			"backendPayload":      map[string]any{"frames": frames},
		}})
		if routeErr != nil {
			t.Fatalf("%s: %v", label, routeErr)
		}
		if value["resolvedRouteID"] != "coredevice.normalTouch" {
			t.Fatalf("%s result = %#v", label, value)
		}
	}
	linearFrames := func(fromX, fromY, toX, toY uint64, duration uint64) []any {
		interpolate := func(from, to, elapsed uint64) uint64 {
			if elapsed == 0 || from == to {
				return from
			}
			if elapsed == duration {
				return to
			}
			if to > from {
				return from + ((to-from)*elapsed+duration/2)/duration
			}
			return from - ((from-to)*elapsed+duration/2)/duration
		}
		intervalCount := (duration-1)/16 + 1
		frames := make([]any, 0, intervalCount+1)
		for index := uint64(0); index <= intervalCount; index++ {
			elapsed := index * 16
			kind := "move"
			if index == 0 {
				kind = "begin"
			} else if index == intervalCount {
				elapsed = duration
				kind = "end"
			}
			frames = append(frames, map[string]any{
				"elapsedMs": elapsed,
				"kind":      kind,
				"x":         interpolate(fromX, toX, elapsed),
				"y":         interpolate(fromY, toY, elapsed),
			})
		}
		return frames
	}

	if _, err := backend.Execute(protocol.Message{Payload: map[string]any{
		"executorOperationID": "coredevice.button.home",
		"backendPayload":      map[string]any{"commandID": "button.home"},
	}}); err != nil {
		t.Fatalf("home: %v", err)
	}
	for index := 0; index < 3; index++ {
		executeTouch("prestate right swipe", linearFrames(9830, 32768, 55705, 32768, 300))
	}
	executeTouch("prestate left swipe", linearFrames(55705, 32768, 9830, 32768, 300))

	artifactID := "33333333-3333-4333-8333-333333333333"
	reservation := filepath.Join(t.TempDir(), artifactID+".png")
	file, err := os.OpenFile(reservation, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	screenshot, err := backend.Execute(protocol.Message{Payload: map[string]any{
		"executorOperationID": "coredevice.screenshot",
		"backendPayload": map[string]any{
			"artifactID":      artifactID,
			"reservationPath": reservation,
		},
	}})
	if err != nil {
		t.Fatalf("prestate screenshot: %v", err)
	}
	if screenshot["format"] != "png" {
		t.Fatalf("prestate screenshot result = %#v", screenshot)
	}

	executeTouch("tap", linearFrames(32768, 32768, 32768, 32768, 35))
	executeTouch("drag", linearFrames(22937, 39321, 42598, 39321, 200))
	executeTouch("swipe", linearFrames(32768, 49151, 32768, 22937, 200))
}

func mapKeys(value map[string]any) []string {
	keys := make([]string, 0, len(value))
	for key := range value {
		keys = append(keys, key)
	}
	return keys
}
