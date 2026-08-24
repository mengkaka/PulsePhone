package coredevice

import (
	"context"
	"errors"
	"net"
	"os"
	"path/filepath"
	"reflect"
	"sync"
	"testing"
	"time"

	"pulsephone/GoHelpers/internal/direct"
)

type testReusableScreenshotProvider struct {
	captures int
	closes   int
	err      error
	image    []byte
	panic    any
}

type testScreenshotCaptureService struct {
	closes      int
	closeErr    error
	closeDelay  time.Duration
	invocations int
	invokeDelay time.Duration
	response    map[string]any
	invokeErr   error
	panic       any
}

type blockingScreenshotCaptureService struct {
	closeCount int
	index      int
	started    chan<- int
	release    <-chan struct{}
}

type hangingScreenshotCaptureService struct {
	captureDone    chan<- struct{}
	captureRelease <-chan struct{}
	captureStarted chan<- struct{}
	closeDone      chan<- struct{}
	closeRelease   <-chan struct{}
	closeStarted   chan<- struct{}
	closes         int
	response       map[string]any
	startOnce      sync.Once
	closeStartOnce sync.Once
	closeDoneOnce  sync.Once
}

type hangingReusableScreenshotProvider struct {
	captureDone    chan<- struct{}
	captureRelease <-chan struct{}
	captureStarted chan<- struct{}
	closeDone      chan<- struct{}
	closeRelease   <-chan struct{}
	closeStarted   chan<- struct{}
	closes         int
	image          []byte
	startOnce      sync.Once
	closeStartOnce sync.Once
	closeDoneOnce  sync.Once
}

func (service *testScreenshotCaptureService) InvokeWithDeadline(string, map[string]any, string, time.Time) (map[string]any, error) {
	service.invocations++
	if service.panic != nil {
		panic(service.panic)
	}
	if service.invokeDelay > 0 {
		time.Sleep(service.invokeDelay)
	}
	return service.response, service.invokeErr
}

func (service *testScreenshotCaptureService) Close() error {
	service.closes++
	if service.closeDelay > 0 {
		time.Sleep(service.closeDelay)
	}
	return service.closeErr
}

func (service *blockingScreenshotCaptureService) InvokeWithDeadline(string, map[string]any, string, time.Time) (map[string]any, error) {
	service.started <- service.index
	if service.index == 1 {
		<-service.release
	}
	return map[string]any{"image": testScreenshotPNG("serialized"), "imageFormat": "png"}, nil
}

func (service *blockingScreenshotCaptureService) Close() error {
	service.closeCount++
	return nil
}

func (service *hangingScreenshotCaptureService) InvokeWithDeadline(string, map[string]any, string, time.Time) (map[string]any, error) {
	if service.captureStarted != nil {
		service.startOnce.Do(func() { close(service.captureStarted) })
	}
	if service.captureRelease != nil {
		<-service.captureRelease
	}
	if service.captureDone != nil {
		close(service.captureDone)
	}
	return service.response, nil
}

func (service *hangingScreenshotCaptureService) Close() error {
	service.closes++
	if service.closeStarted != nil {
		service.closeStartOnce.Do(func() { close(service.closeStarted) })
	}
	if service.closeRelease != nil {
		<-service.closeRelease
	}
	if service.closeDone != nil {
		service.closeDoneOnce.Do(func() { close(service.closeDone) })
	}
	return nil
}

func (provider *hangingReusableScreenshotProvider) Capture(time.Time) ([]byte, string, error) {
	if provider.captureStarted != nil {
		provider.startOnce.Do(func() { close(provider.captureStarted) })
	}
	if provider.captureRelease != nil {
		<-provider.captureRelease
	}
	if provider.captureDone != nil {
		close(provider.captureDone)
	}
	return provider.image, "png", nil
}

func (provider *hangingReusableScreenshotProvider) Close() error {
	provider.closes++
	if provider.closeStarted != nil {
		provider.closeStartOnce.Do(func() { close(provider.closeStarted) })
	}
	if provider.closeRelease != nil {
		<-provider.closeRelease
	}
	if provider.closeDone != nil {
		provider.closeDoneOnce.Do(func() { close(provider.closeDone) })
	}
	return nil
}

func (provider *testReusableScreenshotProvider) Capture(time.Time) ([]byte, string, error) {
	provider.captures++
	if provider.panic != nil {
		panic(provider.panic)
	}
	if provider.err != nil {
		return nil, "", provider.err
	}
	return provider.image, "png", nil
}

func (provider *testReusableScreenshotProvider) Close() error {
	provider.closes++
	return nil
}

func TestScreenshotProviderOrderMatchesFallbackContract(t *testing.T) {
	tests := []struct {
		name     string
		payload  map[string]any
		want     []string
		wantFail bool
	}{
		{name: "default", payload: map[string]any{}, want: []string{"coreDevice"}},
		{name: "explicit core device", payload: map[string]any{"captureProvider": "coreDevice"}, want: []string{"coreDevice"}},
		{name: "dvt internal provider", payload: map[string]any{"captureProvider": "dvt", "commandID": "element.snapshot"}, want: []string{"dvt"}},
		{name: "ordered fallback", payload: map[string]any{"captureProviderOrder": []any{"dvt", "coreDevice", "axAudit"}, "commandID": "element.snapshot"}, want: []string{"dvt", "coreDevice", "axAudit"}},
		{name: "provider order on public route", payload: map[string]any{"captureProvider": "dvt", "commandID": "screenshot.cli"}, wantFail: true},
		{name: "duplicate provider", payload: map[string]any{"captureProviderOrder": []any{"coreDevice", "coreDevice"}, "commandID": "element.snapshot"}, wantFail: true},
		{name: "mixed fields", payload: map[string]any{"captureProvider": "coreDevice", "captureProviderOrder": []any{"coreDevice"}}, wantFail: true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := screenshotProviderOrder(test.payload)
			if test.wantFail {
				if err == nil {
					t.Fatalf("accepted invalid payload: %#v", got)
				}
				return
			}
			if err != nil {
				t.Fatal(err)
			}
			if len(got) != len(test.want) {
				t.Fatalf("providers=%v, want %v", got, test.want)
			}
			for index := range got {
				if got[index] != test.want[index] {
					t.Fatalf("providers=%v, want %v", got, test.want)
				}
			}
		})
	}
}

func TestScreenshotFallbackSuccessRetiresGenerationAfterTerminalResult(t *testing.T) {
	timing := testScreenshotTiming()
	failedThenSucceeded := []any{
		screenshotAttempt("dvt", "failed", "dvtScreenshotServiceOpen", timing),
		screenshotAttempt("coreDevice", "succeeded", "", timing),
	}
	result := screenshotSuccessResult(
		"00000000-0000-0000-0000-000000000001",
		"coreDevice",
		[]byte("png"),
		failedThenSucceeded,
		timing,
	)
	if result["generationDisposition"] != "retiringAfterResult" || result["_pulsephoneRetireGenerationAfterResult"] != true {
		t.Fatalf("fallback result = %#v", result)
	}
	if result["captureProvider"] != "coreDevice" || result["byteCount"] != int64(3) {
		t.Fatalf("fallback projection = %#v", result)
	}
	assertScreenshotAttemptContract(t, failedThenSucceeded[0].(map[string]any), "dvt", "failed", "dvtScreenshotServiceOpen", timing)
	assertScreenshotAttemptContract(t, failedThenSucceeded[1].(map[string]any), "coreDevice", "succeeded", "", timing)
	if !reflect.DeepEqual(result["_pulsephoneInternalTiming"], timing) {
		t.Fatalf("internal timing = %#v, want %#v", result["_pulsephoneInternalTiming"], timing)
	}

	singleProvider := screenshotSuccessResult(
		"00000000-0000-0000-0000-000000000001",
		"coreDevice",
		[]byte("png"),
		[]any{screenshotAttempt("coreDevice", "succeeded", "", timing)},
		timing,
	)
	if _, exists := singleProvider["generationDisposition"]; exists {
		t.Fatalf("single provider retired generation: %#v", singleProvider)
	}
}

func TestScreenshotFailureRetiresGenerationAfterTerminalError(t *testing.T) {
	timing := testScreenshotTiming()
	attempts := []any{screenshotAttempt("coreDevice", "failed", "screenshotCaptureOrValidate", timing)}
	failure := screenshotFailureResult("screenshotCaptureOrValidate", attempts, timing)
	if failure.Code != "developerServicesUnavailable" || !failure.RetireGeneration || failure.Stage != "screenshotCaptureOrValidate" {
		t.Fatalf("failure = %#v", failure)
	}
	if !reflect.DeepEqual(failure.Details["_pulsephoneCaptureAttempts"], attempts) || !reflect.DeepEqual(failure.Details["_pulsephoneInternalTiming"], timing) {
		t.Fatalf("failure details = %#v", failure.Details)
	}
}

func TestScreenshotTimingAndStagesMatchRuntimeContract(t *testing.T) {
	timing := testScreenshotTiming()
	for _, value := range timing {
		microseconds, ok := value.(int64)
		if !ok || microseconds < 0 || microseconds > 30_000_000 {
			t.Fatalf("invalid timing value %#v", value)
		}
	}
	if screenshotCaptureStage("coreDevice") != "screenshotCaptureOrValidate" ||
		screenshotCaptureStage("dvt") != "dvtScreenshotCaptureOrValidate" ||
		screenshotCaptureStage("axAudit") != "axAuditScreenshotCaptureOrValidate" {
		t.Fatal("provider capture stages do not match the Runtime contract")
	}
}

func TestScreenshotProviderAttemptDeadlineMatchesPythonContract(t *testing.T) {
	now := time.Now()
	for provider, want := range map[string]time.Duration{
		"dvt":        3 * time.Second,
		"coreDevice": 4 * time.Second,
		"axAudit":    3 * time.Second,
	} {
		deadline := screenshotAttemptDeadline(provider, now.Add(time.Minute))
		if delta := deadline.Sub(now); delta < want-50*time.Millisecond || delta > want+50*time.Millisecond {
			t.Fatalf("%s deadline delta = %s, want about %s", provider, delta, want)
		}
	}
	operationDeadline := now.Add(100 * time.Millisecond)
	if deadline := screenshotAttemptDeadline("coreDevice", operationDeadline); !deadline.Equal(operationDeadline) {
		t.Fatalf("operation deadline was extended: %s", deadline)
	}
}

func TestScreenshotProviderFailureStagesPreserveDirectCaptureBoundary(t *testing.T) {
	for _, test := range []struct {
		name     string
		fallback string
		stage    string
	}{
		{name: "DVT", fallback: "dvtScreenshotServiceOpen", stage: "dvtScreenshotCaptureOrValidate"},
		{name: "AXAudit", fallback: "axAuditScreenshotServiceOpen", stage: "axAuditScreenshotCaptureOrValidate"},
	} {
		t.Run(test.name, func(t *testing.T) {
			err := &direct.ScreenshotProviderError{Stage: test.stage, Err: errors.New("capture failed")}
			if got := direct.ScreenshotProviderFailureStage(err, test.fallback); got != test.stage {
				t.Fatalf("stage = %q, want %q", got, test.stage)
			}
		})
	}
}

func TestPersistentScreenshotProvidersReuseAndRetireWithGeneration(t *testing.T) {
	backend, err := NewBackendForRuntime(1, 1, "test-device", 1, testServiceNames())
	if err != nil {
		t.Fatal(err)
	}
	dvt := &testReusableScreenshotProvider{image: []byte("dvt")}
	openCalls := 0
	backend.openDVTScreenshot = func(string, time.Time) (reusableScreenshotProvider, error) {
		openCalls++
		return dvt, nil
	}
	for captureIndex := 0; captureIndex < 2; captureIndex++ {
		image, format, stage, err := backend.capturePersistentScreenshotProvider("dvt", time.Now().Add(time.Second))
		if err != nil || string(image) != "dvt" || format != "png" || stage != "dvtScreenshotCaptureOrValidate" {
			t.Fatalf("DVT capture %d image=%q format=%q stage=%q err=%v", captureIndex, image, format, stage, err)
		}
	}
	if openCalls != 1 || dvt.captures != 2 || dvt.closes != 0 {
		t.Fatalf("DVT lifecycle open=%d captures=%d closes=%d", openCalls, dvt.captures, dvt.closes)
	}
	if err := backend.RetireGeneration("incompatible"); err != nil {
		t.Fatal(err)
	}
	if dvt.closes != 1 || backend.dvtScreenshot != nil {
		t.Fatalf("DVT retirement closes=%d provider=%#v", dvt.closes, backend.dvtScreenshot)
	}

	axAudit := &testReusableScreenshotProvider{image: []byte("axaudit")}
	axAuditOpenCalls := 0
	backend.openAXAuditScreenshot = func(string, time.Time) (reusableScreenshotProvider, error) {
		axAuditOpenCalls++
		return axAudit, nil
	}
	for captureIndex := 0; captureIndex < 2; captureIndex++ {
		if _, _, _, err := backend.capturePersistentScreenshotProvider("axAudit", time.Now().Add(time.Second)); err != nil {
			t.Fatal(err)
		}
	}
	if axAuditOpenCalls != 1 || axAudit.captures != 2 || axAudit.closes != 0 {
		t.Fatalf("AXAudit lifecycle open=%d captures=%d closes=%d", axAuditOpenCalls, axAudit.captures, axAudit.closes)
	}
	if err := backend.Reattach(2); err != nil {
		t.Fatal(err)
	}
	if axAudit.closes != 1 || backend.axAuditScreenshot != nil {
		t.Fatalf("AXAudit reconnect closes=%d provider=%#v", axAudit.closes, backend.axAuditScreenshot)
	}
	if err := backend.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestPersistentScreenshotProviderFailureRetiresSession(t *testing.T) {
	backend, err := NewBackendForRuntime(1, 1, "test-device", 1, testServiceNames())
	if err != nil {
		t.Fatal(err)
	}
	defer backend.Close()
	failed := &testReusableScreenshotProvider{err: errors.New("capture interrupted")}
	backend.openDVTScreenshot = func(string, time.Time) (reusableScreenshotProvider, error) {
		return failed, nil
	}
	_, _, stage, err := backend.capturePersistentScreenshotProvider("dvt", time.Now().Add(time.Second))
	if err == nil || stage != "dvtScreenshotCaptureOrValidate" {
		t.Fatalf("failure stage=%q err=%v", stage, err)
	}
	if failed.closes != 1 || backend.dvtScreenshot != nil {
		t.Fatalf("failed provider closes=%d provider=%#v", failed.closes, backend.dvtScreenshot)
	}
}

func TestDefaultDVTProviderUsesRSDServiceRatherThanLockdown(t *testing.T) {
	clientConn, serverConn := net.Pipe()
	defer serverConn.Close()
	dialedPort := uint16(0)
	backend, err := NewBackendForRuntime(1, 1, "not-used-for-dvt", 1, testServiceNames())
	if err != nil {
		t.Fatal(err)
	}
	defer backend.Close()
	backend.tunnel = &CoreDeviceTunnelLease{RSD: &RSDClient{
		PeerInfo: RSDPeerInfo{Services: map[string]RSDService{
			dvtRSDService: {Port: 4711},
		}},
		dial: func(port uint16, _ time.Time) (net.Conn, error) {
			dialedPort = port
			return clientConn, nil
		},
	}}
	backend.services = map[string]*CoreDeviceService{coreDeviceServiceHID: {}}
	if err := serverConn.Close(); err != nil {
		t.Fatal(err)
	}
	_, err = backend.openDVTScreenshot("not-used-for-dvt", time.Now().Add(time.Second))
	if err == nil || dialedPort != 4711 {
		t.Fatalf("err=%v dialedPort=%d", err, dialedPort)
	}
	if stage := direct.ScreenshotProviderFailureStage(err, "fallback"); stage != "dvtScreenshotServiceOpen" {
		t.Fatalf("stage=%q err=%v", stage, err)
	}
}

func TestCoreDeviceScreenshotUsesAndClosesEphemeralServicePerCapture(t *testing.T) {
	backend, err := NewBackendForRuntime(1, 1, "test-device", 1, testServiceNames())
	if err != nil {
		t.Fatal(err)
	}
	defer backend.Close()
	png := []byte("png")
	first := &testScreenshotCaptureService{response: map[string]any{"image": png, "imageFormat": "png"}}
	second := &testScreenshotCaptureService{response: map[string]any{"image": png, "imageFormat": "png"}}
	services := []screenshotCaptureService{first, second}
	backend.openScreenshotService = func(time.Time) (screenshotCaptureService, error) {
		if len(services) == 0 {
			return nil, errors.New("unexpected extra screenshot service")
		}
		service := services[0]
		services = services[1:]
		return service, nil
	}
	for captureIndex := 0; captureIndex < 2; captureIndex++ {
		image, format, stage, err := backend.captureScreenshotProvider("coreDevice", time.Now().Add(time.Second))
		if err != nil || string(image) != "png" || format != "png" || stage != "screenshotCaptureOrValidate" {
			t.Fatalf("capture %d image=%q format=%q stage=%q err=%v", captureIndex, image, format, stage, err)
		}
	}
	for index, service := range []*testScreenshotCaptureService{first, second} {
		if service.invocations != 1 || service.closes != 1 {
			t.Fatalf("service %d invocations=%d closes=%d", index, service.invocations, service.closes)
		}
	}

	closingFailure := &testScreenshotCaptureService{
		closeErr: errors.New("close failed"),
		response: map[string]any{"image": png, "imageFormat": "png"},
	}
	backend.openScreenshotService = func(time.Time) (screenshotCaptureService, error) {
		return closingFailure, nil
	}
	_, _, stage, err := backend.captureScreenshotProvider("coreDevice", time.Now().Add(time.Second))
	if err == nil || stage != "screenshotCaptureOrValidate" || closingFailure.closes != 1 {
		t.Fatalf("close failure stage=%q err=%v closes=%d", stage, err, closingFailure.closes)
	}
}

func TestScreenshotRouteMeasuresOneShotServiceLifecycle(t *testing.T) {
	png := testScreenshotPNG("timed-core-device")
	first := &testScreenshotCaptureService{response: map[string]any{"image": png, "imageFormat": "png"}, invokeDelay: 6 * time.Millisecond, closeDelay: 6 * time.Millisecond}
	second := &testScreenshotCaptureService{response: map[string]any{"image": png, "imageFormat": "png"}, invokeDelay: 6 * time.Millisecond, closeDelay: 6 * time.Millisecond}
	services := []screenshotCaptureService{first, second}
	backend := &Backend{openScreenshotService: func(time.Time) (screenshotCaptureService, error) {
		time.Sleep(6 * time.Millisecond)
		service := services[0]
		services = services[1:]
		return service, nil
	}}
	for captureIndex := 0; captureIndex < 2; captureIndex++ {
		payload, _ := screenshotRoutePayload(t)
		result, err := backend.screenshot(payload, time.Now().Add(time.Second))
		if err != nil {
			t.Fatal(err)
		}
		timing, ok := result["_pulsephoneInternalTiming"].(map[string]any)
		if !ok || timing["serviceOpenMicroseconds"].(int64) < 5_000 || timing["captureMicroseconds"].(int64) < 5_000 || timing["serviceCloseMicroseconds"].(int64) < 5_000 {
			t.Fatalf("capture %d timing = %#v", captureIndex, result)
		}
	}
	if first.invocations != 1 || second.invocations != 1 || first.closes != 1 || second.closes != 1 {
		t.Fatalf("one-shot lifecycle first=%#v second=%#v", first, second)
	}

	backend.openScreenshotService = func(time.Time) (screenshotCaptureService, error) {
		time.Sleep(6 * time.Millisecond)
		return nil, errors.New("service open failed")
	}
	payload, _ := screenshotRoutePayload(t)
	_, err := backend.screenshot(payload, time.Now().Add(time.Second))
	failure, ok := err.(*ProductError)
	if !ok || failure.Stage != "screenshotServiceOpen" || !failure.RetireGeneration {
		t.Fatalf("failure = %#v", err)
	}
	timing, ok := failure.Details["_pulsephoneInternalTiming"].(map[string]any)
	if !ok || timing["serviceOpenMicroseconds"].(int64) < 5_000 {
		t.Fatalf("open failure timing = %#v", failure.Details)
	}
}

func TestScreenshotRouteSerializesConcurrentCaptures(t *testing.T) {
	started := make(chan int, 2)
	release := make(chan struct{})
	first := &blockingScreenshotCaptureService{index: 1, started: started, release: release}
	second := &blockingScreenshotCaptureService{index: 2, started: started, release: release}
	services := []screenshotCaptureService{first, second}
	backend := &Backend{openScreenshotService: func(time.Time) (screenshotCaptureService, error) {
		service := services[0]
		services = services[1:]
		return service, nil
	}}
	type outcome struct {
		result map[string]any
		err    error
	}
	capture := func() <-chan outcome {
		result := make(chan outcome, 1)
		payload, _ := screenshotRoutePayload(t)
		go func() {
			value, err := backend.screenshot(payload, time.Now().Add(time.Second))
			result <- outcome{result: value, err: err}
		}()
		return result
	}
	firstResult := capture()
	if got := <-started; got != 1 {
		t.Fatalf("first capture = %d", got)
	}
	secondResult := capture()
	select {
	case got := <-started:
		t.Fatalf("capture %d bypassed serialization", got)
	case <-time.After(10 * time.Millisecond):
	}
	close(release)
	if result := <-firstResult; result.err != nil {
		t.Fatalf("first capture: %v", result.err)
	}
	if got := <-started; got != 2 {
		t.Fatalf("second capture = %d", got)
	}
	secondOutcome := <-secondResult
	if secondOutcome.err != nil {
		t.Fatalf("second capture: %v", secondOutcome.err)
	}
	if first.closeCount != 1 || second.closeCount != 1 {
		t.Fatalf("service closes first=%d second=%d", first.closeCount, second.closeCount)
	}
	timing, ok := secondOutcome.result["_pulsephoneInternalTiming"].(map[string]any)
	if !ok || timing["queueWaitMicroseconds"].(int64) < 5_000 {
		t.Fatalf("second queue timing = %#v", secondOutcome.result)
	}
}

func TestScreenshotRouteCancelsQueuedWaiterWithoutOpeningChannel(t *testing.T) {
	releaseFirst := make(chan struct{})
	firstStarted := make(chan int, 1)
	first := &blockingScreenshotCaptureService{index: 1, started: firstStarted, release: releaseFirst}
	recovered := &blockingScreenshotCaptureService{index: 2, started: make(chan int, 1), release: make(chan struct{})}
	services := []screenshotCaptureService{first, recovered}
	backend := &Backend{openScreenshotService: func(time.Time) (screenshotCaptureService, error) {
		service := services[0]
		services = services[1:]
		return service, nil
	}}
	firstPayload, _ := screenshotRoutePayload(t)
	firstResult := make(chan error, 1)
	go func() {
		_, err := backend.screenshot(firstPayload, time.Now().Add(time.Second))
		firstResult <- err
	}()
	if got := <-firstStarted; got != 1 {
		t.Fatalf("first capture = %d", got)
	}

	ctx, cancel := context.WithCancel(context.Background())
	cancelledPayload, cancelledPath := screenshotRoutePayload(t)
	cancelledResult := make(chan error, 1)
	go func() {
		_, err := backend.screenshotWithContext(ctx, cancelledPayload, time.Now().Add(time.Second))
		cancelledResult <- err
	}()
	time.Sleep(5 * time.Millisecond)
	cancel()
	if err := <-cancelledResult; !errors.Is(err, context.Canceled) {
		t.Fatalf("cancelled waiter err = %v", err)
	}
	if data, err := os.ReadFile(cancelledPath); err != nil || len(data) != 0 {
		t.Fatalf("cancelled waiter artifact = %x err=%v", data, err)
	}
	close(releaseFirst)
	if err := <-firstResult; err != nil {
		t.Fatalf("first capture: %v", err)
	}
	recoveredPayload, _ := screenshotRoutePayload(t)
	if _, err := backend.screenshot(recoveredPayload, time.Now().Add(time.Second)); err != nil {
		t.Fatalf("recovered capture: %v", err)
	}
	if len(services) != 0 || first.closeCount != 1 || recovered.closeCount != 1 {
		t.Fatalf("services remaining=%d first=%d recovered=%d", len(services), first.closeCount, recovered.closeCount)
	}
}

func TestScreenshotRouteContextDeadlineClosesCaptureAndRecovers(t *testing.T) {
	captureStarted := make(chan struct{})
	captureRelease := make(chan struct{})
	captureDone := make(chan struct{})
	closeDone := make(chan struct{})
	hung := &hangingScreenshotCaptureService{
		captureDone: captureDone, captureRelease: captureRelease, captureStarted: captureStarted,
		closeDone: closeDone,
	}
	recovered := &testScreenshotCaptureService{response: map[string]any{"image": testScreenshotPNG("recovered"), "imageFormat": "png"}}
	services := []screenshotCaptureService{hung, recovered}
	backend := &Backend{openScreenshotService: func(time.Time) (screenshotCaptureService, error) {
		service := services[0]
		services = services[1:]
		return service, nil
	}}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()
	payload, path := screenshotRoutePayload(t)
	_, err := backend.screenshotWithContext(ctx, payload, time.Now().Add(time.Second))
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("deadline err = %v", err)
	}
	if data, readErr := os.ReadFile(path); readErr != nil || len(data) != 0 {
		t.Fatalf("timed-out artifact = %x err=%v", data, readErr)
	}
	select {
	case <-captureStarted:
	default:
		t.Fatal("capture did not start")
	}
	select {
	case <-closeDone:
	case <-time.After(100 * time.Millisecond):
		t.Fatal("deadline did not close hung capture")
	}
	if hung.closes != 1 {
		t.Fatalf("hung capture closes = %d", hung.closes)
	}
	recoveredPayload, _ := screenshotRoutePayload(t)
	if _, err := backend.screenshot(recoveredPayload, time.Now().Add(time.Second)); err != nil {
		t.Fatalf("recovered capture: %v", err)
	}
	close(captureRelease)
	select {
	case <-captureDone:
	case <-time.After(100 * time.Millisecond):
		t.Fatal("hung capture did not retire")
	}
}

func useScreenshotTimeouts(t *testing.T, attempts map[string]time.Duration, retire time.Duration) {
	t.Helper()
	previousAttempts := screenshotProviderAttemptTimeouts
	previousRetire := screenshotProviderRetireTimeout
	screenshotProviderAttemptTimeouts = attempts
	screenshotProviderRetireTimeout = retire
	t.Cleanup(func() {
		screenshotProviderAttemptTimeouts = previousAttempts
		screenshotProviderRetireTimeout = previousRetire
	})
}

func waitForScreenshotSignal(t *testing.T, description string, signal <-chan struct{}) {
	t.Helper()
	select {
	case <-signal:
	case <-time.After(100 * time.Millisecond):
		t.Fatalf("timed out waiting for %s", description)
	}
}

func TestScreenshotRouteFallsBackAfterDVTCaptureDeadline(t *testing.T) {
	useScreenshotTimeouts(t, map[string]time.Duration{"dvt": 10 * time.Millisecond, "coreDevice": 50 * time.Millisecond, "axAudit": 50 * time.Millisecond}, 10*time.Millisecond)
	dvtStarted := make(chan struct{})
	dvtRelease := make(chan struct{})
	dvtDone := make(chan struct{})
	dvtClosed := make(chan struct{})
	dvt := &hangingReusableScreenshotProvider{captureDone: dvtDone, captureRelease: dvtRelease, captureStarted: dvtStarted, closeDone: dvtClosed}
	core := &testScreenshotCaptureService{response: map[string]any{"image": testScreenshotPNG("core-fallback"), "imageFormat": "png"}}
	backend := &Backend{
		rawUDID:               "device",
		openDVTScreenshot:     func(string, time.Time) (reusableScreenshotProvider, error) { return dvt, nil },
		openScreenshotService: func(time.Time) (screenshotCaptureService, error) { return core, nil },
	}
	payload, reservation := screenshotRoutePayload(t)
	payload["commandID"] = "element.snapshot"
	payload["captureProviderOrder"] = []any{"dvt", "coreDevice"}
	started := time.Now()
	result, err := backend.screenshot(payload, time.Now().Add(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if elapsed := time.Since(started); elapsed > 200*time.Millisecond {
		t.Fatalf("fallback elapsed = %s", elapsed)
	}
	if result["captureProvider"] != "coreDevice" || result["generationDisposition"] != "retiringAfterResult" {
		t.Fatalf("fallback result = %#v", result)
	}
	attempts := result["_pulsephoneCaptureAttempts"].([]any)
	if len(attempts) != 2 || attempts[0].(map[string]any)["stage"] != "dvtScreenshotCaptureOrValidate" {
		t.Fatalf("attempts = %#v", attempts)
	}
	if data, readErr := os.ReadFile(reservation); readErr != nil || !reflect.DeepEqual(data, testScreenshotPNG("core-fallback")) {
		t.Fatalf("artifact = %x err=%v", data, readErr)
	}
	waitForScreenshotSignal(t, "DVT capture", dvtStarted)
	waitForScreenshotSignal(t, "DVT close", dvtClosed)
	if dvt.closes != 1 || backend.dvtScreenshot != nil || core.closes != 1 {
		t.Fatalf("DVT closes=%d cached=%#v core closes=%d", dvt.closes, backend.dvtScreenshot, core.closes)
	}
	close(dvtRelease)
	waitForScreenshotSignal(t, "DVT capture retirement", dvtDone)
}

func TestScreenshotRouteFallsBackAfterProviderOpenAndCaptureDeadlines(t *testing.T) {
	useScreenshotTimeouts(t, map[string]time.Duration{"dvt": 10 * time.Millisecond, "coreDevice": 10 * time.Millisecond, "axAudit": 50 * time.Millisecond}, 10*time.Millisecond)
	dvtOpenStarted := make(chan struct{})
	dvtOpenRelease := make(chan struct{})
	dvtClosed := make(chan struct{})
	dvt := &hangingReusableScreenshotProvider{closeDone: dvtClosed}
	coreStarted := make(chan struct{})
	coreRelease := make(chan struct{})
	coreDone := make(chan struct{})
	coreClosed := make(chan struct{})
	core := &hangingScreenshotCaptureService{captureDone: coreDone, captureRelease: coreRelease, captureStarted: coreStarted, closeDone: coreClosed}
	axAudit := &testReusableScreenshotProvider{image: testScreenshotPNG("axaudit-fallback")}
	backend := &Backend{
		rawUDID: "device",
		openDVTScreenshot: func(string, time.Time) (reusableScreenshotProvider, error) {
			close(dvtOpenStarted)
			<-dvtOpenRelease
			return dvt, nil
		},
		openScreenshotService: func(time.Time) (screenshotCaptureService, error) { return core, nil },
		openAXAuditScreenshot: func(string, time.Time) (reusableScreenshotProvider, error) { return axAudit, nil },
	}
	payload, _ := screenshotRoutePayload(t)
	payload["commandID"] = "element.snapshot"
	payload["captureProviderOrder"] = []any{"dvt", "coreDevice", "axAudit"}
	result, err := backend.screenshot(payload, time.Now().Add(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if result["captureProvider"] != "axAudit" {
		t.Fatalf("fallback result = %#v", result)
	}
	attempts := result["_pulsephoneCaptureAttempts"].([]any)
	if len(attempts) != 3 || attempts[0].(map[string]any)["stage"] != "dvtScreenshotServiceOpen" || attempts[1].(map[string]any)["stage"] != "screenshotCaptureOrValidate" {
		t.Fatalf("attempts = %#v", attempts)
	}
	waitForScreenshotSignal(t, "DVT open", dvtOpenStarted)
	waitForScreenshotSignal(t, "CoreDevice capture", coreStarted)
	waitForScreenshotSignal(t, "CoreDevice close", coreClosed)
	close(dvtOpenRelease)
	waitForScreenshotSignal(t, "late DVT close", dvtClosed)
	if core.closes != 1 || dvt.closes != 1 || axAudit.captures != 1 {
		t.Fatalf("CoreDevice closes=%d DVT closes=%d AXAudit captures=%d", core.closes, dvt.closes, axAudit.captures)
	}
	close(coreRelease)
	waitForScreenshotSignal(t, "CoreDevice capture retirement", coreDone)
}

func TestScreenshotRouteDiscardsImageAfterCoreDeviceCloseDeadline(t *testing.T) {
	useScreenshotTimeouts(t, map[string]time.Duration{"dvt": 50 * time.Millisecond, "coreDevice": 50 * time.Millisecond, "axAudit": 50 * time.Millisecond}, 5*time.Millisecond)
	closeStarted := make(chan struct{})
	closeRelease := make(chan struct{})
	closeDone := make(chan struct{})
	coreImage := testScreenshotPNG("poisoned-core")
	core := &hangingScreenshotCaptureService{
		closeDone: closeDone, closeRelease: closeRelease, closeStarted: closeStarted,
		response: map[string]any{"image": coreImage, "imageFormat": "png"},
	}
	axAuditImage := testScreenshotPNG("clean-axaudit")
	axAudit := &testReusableScreenshotProvider{image: axAuditImage}
	backend := &Backend{
		rawUDID:               "device",
		openScreenshotService: func(time.Time) (screenshotCaptureService, error) { return core, nil },
		openAXAuditScreenshot: func(string, time.Time) (reusableScreenshotProvider, error) { return axAudit, nil },
	}
	payload, reservation := screenshotRoutePayload(t)
	payload["commandID"] = "element.snapshot"
	payload["captureProviderOrder"] = []any{"coreDevice", "axAudit"}
	result, err := backend.screenshot(payload, time.Now().Add(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if result["captureProvider"] != "axAudit" || result["generationDisposition"] != "retiringAfterResult" {
		t.Fatalf("fallback result = %#v", result)
	}
	if data, readErr := os.ReadFile(reservation); readErr != nil || !reflect.DeepEqual(data, axAuditImage) {
		t.Fatalf("artifact = %x err=%v", data, readErr)
	}
	attempts := result["_pulsephoneCaptureAttempts"].([]any)
	if len(attempts) != 2 || attempts[0].(map[string]any)["stage"] != "screenshotCaptureOrValidate" {
		t.Fatalf("attempts = %#v", attempts)
	}
	waitForScreenshotSignal(t, "CoreDevice close", closeStarted)
	if core.closes != 1 || axAudit.captures != 1 {
		t.Fatalf("CoreDevice closes=%d AXAudit captures=%d", core.closes, axAudit.captures)
	}
	close(closeRelease)
	waitForScreenshotSignal(t, "CoreDevice late close", closeDone)
}

func TestScreenshotRouteReturnsBoundedFailureAfterAllProviderDeadlines(t *testing.T) {
	useScreenshotTimeouts(t, map[string]time.Duration{"dvt": 10 * time.Millisecond, "coreDevice": 10 * time.Millisecond, "axAudit": 10 * time.Millisecond}, 10*time.Millisecond)
	newProvider := func() (*hangingReusableScreenshotProvider, chan struct{}, chan struct{}, chan struct{}, chan struct{}) {
		started := make(chan struct{})
		release := make(chan struct{})
		done := make(chan struct{})
		closed := make(chan struct{})
		return &hangingReusableScreenshotProvider{captureDone: done, captureRelease: release, captureStarted: started, closeDone: closed}, started, release, done, closed
	}
	dvt, dvtStarted, dvtRelease, dvtDone, dvtClosed := newProvider()
	axAudit, axAuditStarted, axAuditRelease, axAuditDone, axAuditClosed := newProvider()
	coreStarted := make(chan struct{})
	coreRelease := make(chan struct{})
	coreDone := make(chan struct{})
	coreClosed := make(chan struct{})
	core := &hangingScreenshotCaptureService{captureDone: coreDone, captureRelease: coreRelease, captureStarted: coreStarted, closeDone: coreClosed}
	backend := &Backend{
		rawUDID:               "device",
		openDVTScreenshot:     func(string, time.Time) (reusableScreenshotProvider, error) { return dvt, nil },
		openScreenshotService: func(time.Time) (screenshotCaptureService, error) { return core, nil },
		openAXAuditScreenshot: func(string, time.Time) (reusableScreenshotProvider, error) { return axAudit, nil },
	}
	payload, reservation := screenshotRoutePayload(t)
	payload["commandID"] = "element.snapshot"
	payload["captureProviderOrder"] = []any{"dvt", "coreDevice", "axAudit"}
	started := time.Now()
	_, err := backend.screenshot(payload, time.Now().Add(time.Second))
	if elapsed := time.Since(started); elapsed > 200*time.Millisecond {
		t.Fatalf("all-provider failure elapsed = %s", elapsed)
	}
	failure, ok := err.(*ProductError)
	if !ok || failure.Code != "developerServicesUnavailable" || !failure.RetireGeneration || failure.Stage != "axAuditScreenshotCaptureOrValidate" {
		t.Fatalf("failure = %#v", err)
	}
	attempts, ok := failure.Details["_pulsephoneCaptureAttempts"].([]any)
	if !ok || len(attempts) != 3 {
		t.Fatalf("attempts = %#v", failure.Details)
	}
	for index, provider := range []string{"dvt", "coreDevice", "axAudit"} {
		attempt, ok := attempts[index].(map[string]any)
		if !ok || attempt["provider"] != provider || attempt["status"] != "failed" {
			t.Fatalf("attempt %d = %#v", index, attempts[index])
		}
	}
	if data, readErr := os.ReadFile(reservation); readErr != nil || len(data) != 0 {
		t.Fatalf("failed providers published artifact=%x err=%v", data, readErr)
	}
	for description, signal := range map[string]<-chan struct{}{
		"DVT capture":        dvtStarted,
		"DVT close":          dvtClosed,
		"CoreDevice capture": coreStarted,
		"CoreDevice close":   coreClosed,
		"AXAudit capture":    axAuditStarted,
		"AXAudit close":      axAuditClosed,
	} {
		waitForScreenshotSignal(t, description, signal)
	}
	if dvt.closes != 1 || core.closes != 1 || axAudit.closes != 1 {
		t.Fatalf("provider closes DVT=%d CoreDevice=%d AXAudit=%d", dvt.closes, core.closes, axAudit.closes)
	}
	close(dvtRelease)
	close(coreRelease)
	close(axAuditRelease)
	for description, signal := range map[string]<-chan struct{}{
		"DVT capture retirement":        dvtDone,
		"CoreDevice capture retirement": coreDone,
		"AXAudit capture retirement":    axAuditDone,
	} {
		waitForScreenshotSignal(t, description, signal)
	}
}

func TestScreenshotRouteOuterCancellationDoesNotWaitForHungClose(t *testing.T) {
	useScreenshotTimeouts(t, map[string]time.Duration{"dvt": 50 * time.Millisecond, "coreDevice": 50 * time.Millisecond, "axAudit": 50 * time.Millisecond}, 5*time.Millisecond)
	captureStarted := make(chan struct{})
	captureRelease := make(chan struct{})
	captureDone := make(chan struct{})
	closeStarted := make(chan struct{})
	closeRelease := make(chan struct{})
	closeDone := make(chan struct{})
	service := &hangingScreenshotCaptureService{
		captureDone: captureDone, captureRelease: captureRelease, captureStarted: captureStarted,
		closeDone: closeDone, closeRelease: closeRelease, closeStarted: closeStarted,
	}
	backend := &Backend{openScreenshotService: func(time.Time) (screenshotCaptureService, error) { return service, nil }}
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Millisecond)
	defer cancel()
	payload, _ := screenshotRoutePayload(t)
	started := time.Now()
	_, err := backend.screenshotWithContext(ctx, payload, time.Now().Add(time.Second))
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("outer cancellation err = %v", err)
	}
	if elapsed := time.Since(started); elapsed > 100*time.Millisecond {
		t.Fatalf("outer cancellation elapsed = %s", elapsed)
	}
	waitForScreenshotSignal(t, "capture", captureStarted)
	waitForScreenshotSignal(t, "hung close start", closeStarted)
	if service.closes != 1 {
		t.Fatalf("service closes = %d", service.closes)
	}
	close(captureRelease)
	close(closeRelease)
	waitForScreenshotSignal(t, "capture retirement", captureDone)
	waitForScreenshotSignal(t, "close retirement", closeDone)
}

func TestScreenshotCapturePanicClosesProviderAndRethrows(t *testing.T) {
	assertRethrowsAfterClose := func(t *testing.T, invoke func(), closes func() int) {
		t.Helper()
		defer func() {
			if recovered := recover(); recovered != "capture abort" {
				t.Fatalf("panic = %#v", recovered)
			}
			if got := closes(); got != 1 {
				t.Fatalf("closes = %d", got)
			}
		}()
		invoke()
	}

	t.Run("one-shot core device", func(t *testing.T) {
		service := &testScreenshotCaptureService{panic: "capture abort"}
		backend := &Backend{openScreenshotService: func(time.Time) (screenshotCaptureService, error) { return service, nil }}
		assertRethrowsAfterClose(t, func() {
			_, _, _, _ = backend.captureScreenshotProvider("coreDevice", time.Now().Add(time.Second))
		}, func() int { return service.closes })
	})

	t.Run("persistent DVT", func(t *testing.T) {
		provider := &testReusableScreenshotProvider{panic: "capture abort"}
		backend := &Backend{rawUDID: "device", openDVTScreenshot: func(string, time.Time) (reusableScreenshotProvider, error) { return provider, nil }}
		assertRethrowsAfterClose(t, func() {
			_, _, _, _ = backend.captureScreenshotProvider("dvt", time.Now().Add(time.Second))
		}, func() int { return provider.closes })
		if backend.dvtScreenshot != nil {
			t.Fatal("panic left persistent provider cached")
		}
	})
}

func TestScreenshotRouteWritesReservationAndRetiresFailedCoreDeviceCapture(t *testing.T) {
	png := testScreenshotPNG("core-device-route")
	failed := &testScreenshotCaptureService{invokeErr: errors.New("capture disconnected")}
	succeeded := &testScreenshotCaptureService{response: map[string]any{"image": png, "imageFormat": "png"}}
	services := []screenshotCaptureService{failed, succeeded}
	backend := &Backend{
		openScreenshotService: func(time.Time) (screenshotCaptureService, error) {
			if len(services) == 0 {
				return nil, errors.New("unexpected screenshot service")
			}
			service := services[0]
			services = services[1:]
			return service, nil
		},
	}
	payload, reservation := screenshotRoutePayload(t)

	_, err := backend.screenshot(payload, time.Now().Add(time.Second))
	failure, ok := err.(*ProductError)
	if !ok || failure.Code != "developerServicesUnavailable" || !failure.RetireGeneration || failure.Stage != "screenshotCaptureOrValidate" {
		t.Fatalf("failure = %#v", err)
	}
	if failed.invocations != 1 || failed.closes != 1 {
		t.Fatalf("failed service invocations=%d closes=%d", failed.invocations, failed.closes)
	}
	if data, readErr := os.ReadFile(reservation); readErr != nil || len(data) != 0 {
		t.Fatalf("failed capture published artifact=%x err=%v", data, readErr)
	}

	result, err := backend.screenshot(payload, time.Now().Add(time.Second))
	if err != nil {
		t.Fatal(err)
	}
	if result["byteCount"] != int64(len(png)) || result["format"] != "png" || result["resolvedRouteID"] != "coredevice.screenshot" {
		t.Fatalf("result = %#v", result)
	}
	if data, readErr := os.ReadFile(reservation); readErr != nil || !reflect.DeepEqual(data, png) {
		t.Fatalf("artifact = %x want %x err=%v", data, png, readErr)
	}
	if succeeded.invocations != 1 || succeeded.closes != 1 {
		t.Fatalf("successful service invocations=%d closes=%d", succeeded.invocations, succeeded.closes)
	}
}

func TestScreenshotRouteProviderFallbackPublishesOnlySuccessfulAttempt(t *testing.T) {
	t.Run("failed DVT falls back to CoreDevice", func(t *testing.T) {
		png := testScreenshotPNG("fallback-core")
		failedDVT := &testReusableScreenshotProvider{err: errors.New("DVT disconnected")}
		core := &testScreenshotCaptureService{response: map[string]any{"image": png, "imageFormat": "png"}}
		backend := &Backend{
			rawUDID:               "device",
			openDVTScreenshot:     func(string, time.Time) (reusableScreenshotProvider, error) { return failedDVT, nil },
			openScreenshotService: func(time.Time) (screenshotCaptureService, error) { return core, nil },
		}
		payload, reservation := screenshotRoutePayload(t)
		payload["commandID"] = "element.snapshot"
		payload["captureProviderOrder"] = []any{"dvt", "coreDevice"}
		result, err := backend.screenshot(payload, time.Now().Add(time.Second))
		if err != nil {
			t.Fatal(err)
		}
		if result["captureProvider"] != "coreDevice" || result["generationDisposition"] != "retiringAfterResult" || result["_pulsephoneRetireGenerationAfterResult"] != true {
			t.Fatalf("fallback result = %#v", result)
		}
		attempts, ok := result["_pulsephoneCaptureAttempts"].([]any)
		if !ok || len(attempts) != 2 {
			t.Fatalf("attempts = %#v", result["_pulsephoneCaptureAttempts"])
		}
		assertScreenshotAttemptContract(t, attempts[0].(map[string]any), "dvt", "failed", "dvtScreenshotCaptureOrValidate", attempts[0].(map[string]any)["timings"].(map[string]any))
		assertScreenshotAttemptContract(t, attempts[1].(map[string]any), "coreDevice", "succeeded", "", attempts[1].(map[string]any)["timings"].(map[string]any))
		if data, readErr := os.ReadFile(reservation); readErr != nil || !reflect.DeepEqual(data, png) {
			t.Fatalf("artifact = %x want %x err=%v", data, png, readErr)
		}
		if failedDVT.closes != 1 || core.closes != 1 {
			t.Fatalf("fallback cleanup DVT=%d CoreDevice=%d", failedDVT.closes, core.closes)
		}
	})

	t.Run("successful DVT does not open CoreDevice", func(t *testing.T) {
		png := testScreenshotPNG("dvt-wins")
		dvt := &testReusableScreenshotProvider{image: png}
		coreOpened := 0
		backend := &Backend{
			rawUDID:           "device",
			openDVTScreenshot: func(string, time.Time) (reusableScreenshotProvider, error) { return dvt, nil },
			openScreenshotService: func(time.Time) (screenshotCaptureService, error) {
				coreOpened++
				return nil, errors.New("unexpected CoreDevice fallback")
			},
		}
		payload, _ := screenshotRoutePayload(t)
		payload["commandID"] = "element.snapshot"
		payload["captureProviderOrder"] = []any{"dvt", "coreDevice"}
		result, err := backend.screenshot(payload, time.Now().Add(time.Second))
		if err != nil {
			t.Fatal(err)
		}
		if result["captureProvider"] != "dvt" || result["generationDisposition"] != nil || coreOpened != 0 {
			t.Fatalf("successful DVT result = %#v coreOpened=%d", result, coreOpened)
		}
		if err := backend.Close(); err != nil || dvt.closes != 1 {
			t.Fatalf("DVT cleanup err=%v closes=%d", err, dvt.closes)
		}
	})

	t.Run("DVT and CoreDevice fall back to AXAudit", func(t *testing.T) {
		png := testScreenshotPNG("fallback-axaudit")
		dvt := &testReusableScreenshotProvider{err: errors.New("DVT unavailable")}
		axAudit := &testReusableScreenshotProvider{image: png}
		core := &testScreenshotCaptureService{invokeErr: errors.New("CoreDevice unavailable")}
		backend := &Backend{
			rawUDID:               "device",
			openDVTScreenshot:     func(string, time.Time) (reusableScreenshotProvider, error) { return dvt, nil },
			openAXAuditScreenshot: func(string, time.Time) (reusableScreenshotProvider, error) { return axAudit, nil },
			openScreenshotService: func(time.Time) (screenshotCaptureService, error) { return core, nil },
		}
		payload, reservation := screenshotRoutePayload(t)
		payload["commandID"] = "element.snapshot"
		payload["captureProviderOrder"] = []any{"dvt", "coreDevice", "axAudit"}
		result, err := backend.screenshot(payload, time.Now().Add(time.Second))
		if err != nil {
			t.Fatal(err)
		}
		if result["captureProvider"] != "axAudit" || result["generationDisposition"] != "retiringAfterResult" {
			t.Fatalf("fallback result = %#v", result)
		}
		attempts, ok := result["_pulsephoneCaptureAttempts"].([]any)
		if !ok || len(attempts) != 3 {
			t.Fatalf("attempts = %#v", result["_pulsephoneCaptureAttempts"])
		}
		for index, want := range []struct{ provider, status string }{{"dvt", "failed"}, {"coreDevice", "failed"}, {"axAudit", "succeeded"}} {
			attempt, ok := attempts[index].(map[string]any)
			if !ok || attempt["provider"] != want.provider || attempt["status"] != want.status {
				t.Fatalf("attempt %d = %#v", index, attempts[index])
			}
		}
		if data, readErr := os.ReadFile(reservation); readErr != nil || !reflect.DeepEqual(data, png) {
			t.Fatalf("artifact = %x want %x err=%v", data, png, readErr)
		}
		if err := backend.Close(); err != nil || dvt.closes != 1 || core.closes != 1 || axAudit.closes != 1 {
			t.Fatalf("fallback cleanup err=%v DVT=%d CoreDevice=%d AXAudit=%d", err, dvt.closes, core.closes, axAudit.closes)
		}
	})
}

func TestScreenshotRouteThreeProviderFailureClosesEveryChannel(t *testing.T) {
	dvt := &testReusableScreenshotProvider{err: errors.New("DVT unavailable")}
	axAudit := &testReusableScreenshotProvider{err: errors.New("AXAudit unavailable")}
	core := &testScreenshotCaptureService{invokeErr: errors.New("CoreDevice unavailable")}
	backend := &Backend{
		rawUDID:               "device",
		openDVTScreenshot:     func(string, time.Time) (reusableScreenshotProvider, error) { return dvt, nil },
		openAXAuditScreenshot: func(string, time.Time) (reusableScreenshotProvider, error) { return axAudit, nil },
		openScreenshotService: func(time.Time) (screenshotCaptureService, error) { return core, nil },
	}
	payload, reservation := screenshotRoutePayload(t)
	payload["commandID"] = "element.snapshot"
	payload["captureProviderOrder"] = []any{"dvt", "coreDevice", "axAudit"}
	_, err := backend.screenshot(payload, time.Now().Add(time.Second))
	failure, ok := err.(*ProductError)
	if !ok || failure.Code != "developerServicesUnavailable" || !failure.RetireGeneration || failure.Stage != "axAuditScreenshotCaptureOrValidate" {
		t.Fatalf("failure = %#v", err)
	}
	attempts, ok := failure.Details["_pulsephoneCaptureAttempts"].([]any)
	if !ok || len(attempts) != 3 {
		t.Fatalf("attempts = %#v", failure.Details)
	}
	for index, provider := range []string{"dvt", "coreDevice", "axAudit"} {
		attempt, ok := attempts[index].(map[string]any)
		if !ok || attempt["provider"] != provider || attempt["status"] != "failed" {
			t.Fatalf("attempt %d = %#v", index, attempts[index])
		}
	}
	if data, readErr := os.ReadFile(reservation); readErr != nil || len(data) != 0 {
		t.Fatalf("failed providers published artifact=%x err=%v", data, readErr)
	}
	if dvt.closes != 1 || axAudit.closes != 1 || core.closes != 1 {
		t.Fatalf("provider closes DVT=%d CoreDevice=%d AXAudit=%d", dvt.closes, core.closes, axAudit.closes)
	}
}

func screenshotRoutePayload(t *testing.T) (map[string]any, string) {
	t.Helper()
	artifactID := "11111111-1111-4111-8111-111111111111"
	reservation := filepath.Join(t.TempDir(), artifactID+".png")
	file, err := os.OpenFile(reservation, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0o600)
	if err != nil {
		t.Fatal(err)
	}
	if err := file.Close(); err != nil {
		t.Fatal(err)
	}
	return map[string]any{"artifactID": artifactID, "reservationPath": reservation}, reservation
}

func testScreenshotPNG(label string) []byte {
	return append([]byte{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a}, []byte(label)...)
}

func testScreenshotTiming() map[string]any {
	started := time.Unix(1, 0)
	return screenshotTiming(started, started, started.Add(3*time.Microsecond), started.Add(11*time.Microsecond), screenshotServiceTiming{})
}

func assertScreenshotAttemptContract(t *testing.T, attempt map[string]any, provider, status, stage string, timing map[string]any) {
	t.Helper()
	if attempt["provider"] != provider || attempt["status"] != status || !reflect.DeepEqual(attempt["timings"], timing) {
		t.Fatalf("attempt = %#v", attempt)
	}
	if status == "failed" {
		if attempt["errorCode"] != "developerServicesUnavailable" || attempt["stage"] != stage {
			t.Fatalf("failed attempt = %#v", attempt)
		}
		return
	}
	if attempt["errorCode"] != nil || attempt["stage"] != nil {
		t.Fatalf("succeeded attempt = %#v", attempt)
	}
}
