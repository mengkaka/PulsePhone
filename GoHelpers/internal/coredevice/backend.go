package coredevice

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"math/bits"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"time"

	"pulsephone/GoHelpers/internal/direct"
	"pulsephone/GoHelpers/internal/protocol"
)

const (
	coreDeviceServiceAppControl  = "appControl"
	coreDeviceServiceButton      = "button"
	coreDeviceServiceHID         = "hid"
	coreDeviceServiceOrientation = "orientation"
	coreDeviceServiceScreenshot  = "screenshot"
	coreDeviceServiceDeviceInfo  = "deviceInfo"
	coreDeviceServicePasteboard  = "pasteboard"
)

var orientationConfirmationDelays = []time.Duration{0, 100 * time.Millisecond, 150 * time.Millisecond}

const (
	orientationGeometryQueryTimeout = 500 * time.Millisecond
	orientationRequestTimeout       = 10 * time.Second
)

var screenshotProviderAttemptTimeouts = map[string]time.Duration{
	"axAudit":    3 * time.Second,
	"coreDevice": 4 * time.Second,
	"dvt":        3 * time.Second,
}

var screenshotProviderRetireTimeout = 250 * time.Millisecond

const (
	screenshotOperationTimeout     = 7 * time.Second
	screenshotProviderProbeTimeout = 2 * time.Second
)

type ProductError struct {
	Code             string
	Committed        bool
	Details          map[string]any
	OutcomeUnknown   bool
	Phase            string
	RetireGeneration bool
	Stage            string
}

type reusableScreenshotProvider interface {
	Capture(deadline time.Time) ([]byte, string, error)
	Close() error
}

type screenshotProviderFactory func(udid string, deadline time.Time) (reusableScreenshotProvider, error)

type screenshotCaptureService interface {
	InvokeWithDeadline(feature string, input map[string]any, actionIdentifier string, deadline time.Time) (map[string]any, error)
	Close() error
}

type screenshotServiceTiming struct {
	capture      time.Duration
	serviceClose time.Duration
	serviceOpen  time.Duration
}

type screenshotCapture struct {
	image   []byte
	format  string
	stage   string
	timing  screenshotServiceTiming
	capture error
}

type screenshotClosable interface {
	Close() error
}

type screenshotCloser struct {
	resource screenshotClosable
	once     sync.Once
	done     chan struct{}
	err      error
}

type screenshotPanicError struct {
	value any
}

func (err *screenshotPanicError) Error() string {
	return "screenshot provider panic"
}

func rethrowScreenshotPanic(err error) {
	var panicErr *screenshotPanicError
	if errors.As(err, &panicErr) {
		panic(panicErr.value)
	}
}

func newScreenshotCloser(resource screenshotClosable) *screenshotCloser {
	return &screenshotCloser{resource: resource, done: make(chan struct{})}
}

func (closer *screenshotCloser) closeWithin(timeout time.Duration) (time.Duration, error) {
	if closer == nil || closer.resource == nil {
		return 0, nil
	}
	started := time.Now()
	closer.once.Do(func() {
		go func() {
			closer.err = closer.resource.Close()
			close(closer.done)
		}()
	})
	if timeout <= 0 {
		<-closer.done
		return time.Since(started), closer.err
	}
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case <-closer.done:
		return time.Since(started), closer.err
	case <-timer.C:
		return time.Since(started), context.DeadlineExceeded
	}
}

func scheduleScreenshotClose(resource screenshotClosable) {
	if resource == nil {
		return
	}
	go func() {
		_, _ = newScreenshotCloser(resource).closeWithin(screenshotProviderRetireTimeout)
	}()
}

type personalizedDeveloperSupport interface {
	QueryMounted(rawUDID string, deadline time.Time) (map[string]any, error)
	Execute(rawUDID string, connectionEpoch uint64, payload map[string]any, deadline time.Time) (map[string]any, error)
	Close()
}

func (err *ProductError) Error() string {
	if err == nil {
		return ""
	}
	return err.Code
}

type Backend struct {
	mu                         sync.Mutex
	runtimeEpoch               uint64
	rawUDID                    string
	connectionEpoch            uint64
	coordinator                *Coordinator
	facetNames                 map[string]string
	tunnel                     *CoreDeviceTunnelLease
	services                   map[string]*CoreDeviceService
	streams                    map[string]*backendStream
	keyboardID                 uint64
	keyboardReady              bool
	keyboardEpoch              uint64
	keyboardInitializing       bool
	keyboardInitializationDone chan struct{}
	openKeyboardService        func(deadline time.Time) (uint64, error)
	waitKeyboardReadiness      func(duration time.Duration, deadline time.Time) error
	executorGeneration         uint64
	surfaceRevision            string
	personalized               personalizedDeveloperSupport
	screenshotGate             chan struct{}
	dvtScreenshot              reusableScreenshotProvider
	axAuditScreenshot          reusableScreenshotProvider
	openDVTScreenshot          screenshotProviderFactory
	openAXAuditScreenshot      screenshotProviderFactory
	openPasteboardService      func(time.Time) (*CoreDeviceService, error)
	openScreenshotService      func(deadline time.Time) (screenshotCaptureService, error)
	openDisplayGeometryService func(deadline time.Time) (*CoreDeviceService, error)
	invokeDisplayGeometry      func(*CoreDeviceService, time.Time) (map[string]any, error)
	sendIndigoDigitizer        func(*CoreDeviceService, uint16, uint16, uint64, uint64) error
	orientationRequest         func(*CoreDeviceService, map[string]any, time.Time) (map[string]any, error)
	orientationObserver        func(time.Time) (map[string]any, error)
	orientationWait            func(time.Duration, time.Time) error
	closed                     bool
}

func NewBackend(rawUDID string, connectionEpoch uint64, facetNames map[string]string) (*Backend, error) {
	return NewBackendForRuntime(1, 1, rawUDID, connectionEpoch, facetNames)
}

func NewBackendForRuntime(runtimeEpoch, executorGeneration uint64, rawUDID string, connectionEpoch uint64, facetNames map[string]string) (*Backend, error) {
	return NewBackendForRuntimeWithTunnelOpener(runtimeEpoch, executorGeneration, rawUDID, connectionEpoch, facetNames, func(ctx context.Context, udid string) (TunnelLease, error) {
		deadline := time.Now().Add(60 * time.Second)
		if contextDeadline, ok := ctx.Deadline(); ok && contextDeadline.Before(deadline) {
			deadline = contextDeadline
		}
		return OpenUserspaceTunnel(udid, deadline)
	})
}

// NewBackendForRuntimeWithTunnelOpener is an explicit constructor seam for
// deterministic transport lifecycle tests. Production callers use
// NewBackendForRuntime, which always supplies the userspace tunnel opener.
func NewBackendForRuntimeWithTunnelOpener(runtimeEpoch, executorGeneration uint64, rawUDID string, connectionEpoch uint64, facetNames map[string]string, openTunnel TunnelOpener) (*Backend, error) {
	if runtimeEpoch == 0 || executorGeneration == 0 || rawUDID == "" || connectionEpoch == 0 || !validServiceNames(facetNames) {
		return nil, errors.New("invalid CoreDevice backend configuration")
	}
	coordinator, err := NewCoordinator(runtimeEpoch, rawUDID, openTunnel, executorGeneration, facetNames)
	if err != nil {
		return nil, err
	}
	if err := coordinator.Attach(connectionEpoch); err != nil {
		return nil, err
	}
	personalized := NewPersonalizedDeveloperSupportSession(nil, nil, nil)
	backend := &Backend{
		runtimeEpoch:       runtimeEpoch,
		rawUDID:            rawUDID,
		connectionEpoch:    connectionEpoch,
		coordinator:        coordinator,
		facetNames:         cloneStrings(facetNames),
		services:           make(map[string]*CoreDeviceService),
		streams:            make(map[string]*backendStream),
		surfaceRevision:    serviceSurfaceRevision(facetNames),
		executorGeneration: executorGeneration,
		personalized:       personalized,
		openAXAuditScreenshot: func(udid string, deadline time.Time) (reusableScreenshotProvider, error) {
			return direct.OpenAXAuditScreenshotSession(udid, deadline)
		},
		sendIndigoDigitizer: sendIndigoDigitizerEvent,
	}
	backend.openDVTScreenshot = func(_ string, deadline time.Time) (reusableScreenshotProvider, error) {
		return backend.openDVTScreenshotThroughRSD(deadline)
	}
	backend.screenshotGate = make(chan struct{}, 1)
	backend.screenshotGate <- struct{}{}
	backend.openScreenshotService = backend.openEphemeralScreenshotService
	return backend, nil
}

func (backend *Backend) openDVTScreenshotThroughRSD(deadline time.Time) (reusableScreenshotProvider, error) {
	if err := backend.ensureReady(deadline); err != nil {
		return nil, &direct.ScreenshotProviderError{Stage: "dvtScreenshotServiceOpen", Err: err}
	}
	backend.mu.Lock()
	if backend.closed || backend.tunnel == nil || backend.tunnel.RSD == nil {
		backend.mu.Unlock()
		return nil, &direct.ScreenshotProviderError{Stage: "dvtScreenshotServiceOpen", Err: errors.New("CoreDevice RSD unavailable")}
	}
	rsd := backend.tunnel.RSD
	backend.mu.Unlock()
	connection, err := rsd.OpenRawService(dvtRSDService, deadline)
	if err != nil {
		return nil, &direct.ScreenshotProviderError{Stage: "dvtScreenshotServiceOpen", Err: err}
	}
	return direct.OpenDVTScreenshotSessionOnConnection(connection, deadline)
}

func startupProductError(err error, fallbackStage string) *ProductError {
	productErr := &ProductError{Code: "developerServicesUnavailable", Stage: fallbackStage}
	var startupErr *GenerationStartupError
	if errors.As(err, &startupErr) && startupErr.Phase != "" {
		productErr.Phase = startupErr.Phase
		productErr.Stage = ""
	}
	return productErr
}

func (backend *Backend) Close() error {
	if backend == nil {
		return nil
	}
	backend.mu.Lock()
	if backend.closed {
		backend.mu.Unlock()
		return nil
	}
	backend.closed = true
	streams := make([]*backendStream, 0, len(backend.streams))
	for _, stream := range backend.streams {
		streams = append(streams, stream)
	}
	backend.services = nil
	backend.streams = nil
	backend.resetKeyboardLocked()
	backend.tunnel = nil
	screenshotProviders := backend.takeScreenshotProvidersLocked()
	backend.mu.Unlock()
	var first error
	backend.releaseStreams(streams)
	releaseScreenshotProviders(screenshotProviders)
	if backend.coordinator != nil {
		if _, err := backend.coordinator.RetireCurrentWithReason("quiesce"); err != nil && first == nil {
			first = err
		}
	}
	if backend.personalized != nil {
		backend.personalized.Close()
	}
	return first
}

func (backend *Backend) Warm(deadline time.Time) (map[string]any, error) {
	backend.mu.Lock()
	alreadyReady := backend.tunnel != nil && len(backend.services) != 0
	backend.mu.Unlock()
	if err := backend.ensureReady(deadline); err != nil {
		return nil, err
	}
	preferredScreenshotProvider, screenshotAttemptOrder := backend.probeScreenshotProviders(deadline)
	backend.mu.Lock()
	defer backend.mu.Unlock()
	disposition := "ready"
	if alreadyReady {
		disposition = "alreadyReady"
	}
	return map[string]any{
		"disposition":            disposition,
		"executorGeneration":     backend.executorGeneration,
		"facets":                 stringSliceAny(RequiredFacets),
		"screenshotAttemptOrder": stringSliceAny(screenshotAttemptOrder),
		"screenshotProvider":     preferredScreenshotProvider,
		"surfaceRevision":        backend.surfaceRevision,
	}, nil
}

func (backend *Backend) probeScreenshotProviders(operationDeadline time.Time) (string, []string) {
	providers := []string{"dvt", "coreDevice", "axAudit"}
	for index, provider := range providers {
		deadline := boundedScreenshotDeadline(operationDeadline, screenshotProviderProbeTimeout)
		if deadline.IsZero() || time.Until(deadline) <= 0 {
			break
		}
		if err := backend.probeScreenshotProvider(provider, deadline); err == nil {
			return provider, append([]string(nil), providers[index:]...)
		}
	}
	return "unavailable", []string{}
}

func (backend *Backend) probeScreenshotProvider(provider string, deadline time.Time) error {
	ctx, cancel := screenshotContext(deadline)
	defer cancel()
	switch provider {
	case "coreDevice":
		if backend.openScreenshotService == nil {
			return errors.New("screenshot provider unavailable")
		}
		service, err := openScreenshotCaptureService(ctx, deadline, backend.openScreenshotService)
		if err != nil {
			return err
		}
		_, _ = newScreenshotCloser(service).closeWithin(screenshotProviderRetireTimeout)
		return nil
	case "dvt", "axAudit":
		backend.mu.Lock()
		open := backend.openDVTScreenshot
		if provider == "axAudit" {
			open = backend.openAXAuditScreenshot
		}
		udid := backend.rawUDID
		backend.mu.Unlock()
		if open == nil {
			return errors.New("screenshot provider unavailable")
		}
		session, err := openReusableScreenshotProvider(ctx, deadline, udid, open)
		if err != nil {
			return err
		}
		_, _ = newScreenshotCloser(session).closeWithin(screenshotProviderRetireTimeout)
		return nil
	default:
		return errors.New("unknown screenshot provider")
	}
}

func (backend *Backend) ensureReady(deadline time.Time) error {
	backend.mu.Lock()
	if backend.closed {
		backend.mu.Unlock()
		return errors.New("CoreDevice backend closed")
	}
	if backend.tunnel != nil && len(backend.services) != 0 {
		backend.mu.Unlock()
		return nil
	}
	coordinator := backend.coordinator
	connectionEpoch := backend.connectionEpoch
	backend.mu.Unlock()
	if coordinator == nil {
		return errors.New("CoreDevice generation coordinator unavailable")
	}
	contextValue := context.Background()
	if !deadline.IsZero() {
		var cancel context.CancelFunc
		contextValue, cancel = context.WithDeadline(contextValue, deadline)
		defer cancel()
	}
	_, err := coordinator.AdmitDemand(contextValue, connectionEpoch, Demand{
		DemandID:             "backend-warm",
		Origin:               "finiteCommand",
		Persistence:          "epochBound",
		PreparationGroupID:   PreparationGroupID,
		PreparationAttemptID: "backend-warm",
	})
	if err != nil {
		return err
	}
	resources, ok := coordinator.CurrentResources()
	if !ok {
		return errors.New("CoreDevice generation resources unavailable")
	}
	tunnel, ok := resources.Tunnel.(*CoreDeviceTunnelLease)
	if !ok || tunnel == nil {
		return errors.New("unexpected CoreDevice tunnel lease")
	}
	opened := make(map[string]*CoreDeviceService, len(resources.Facets))
	for facet, resource := range resources.Facets {
		service, ok := resource.(*CoreDeviceService)
		if !ok || service == nil {
			return fmt.Errorf("unexpected CoreDevice service for %s", facet)
		}
		if facet == coreDeviceServicePasteboard {
			if err := service.Close(); err != nil {
				return fmt.Errorf("close CoreDevice %s warm channel: %w", facet, err)
			}
			continue
		}
		opened[facet] = service
	}
	backend.mu.Lock()
	if backend.closed {
		backend.mu.Unlock()
		_, _ = backend.coordinator.RetireCurrentWithReason("quiesce")
		return errors.New("CoreDevice backend closed")
	}
	backend.tunnel = tunnel
	backend.executorGeneration = resources.Snapshot.Identity.ExecutorGeneration
	for facet, service := range opened {
		backend.services[facet] = service
	}
	backend.mu.Unlock()
	return nil
}

func (backend *Backend) Reattach(connectionEpoch uint64) error {
	if connectionEpoch == 0 {
		return errors.New("invalid connection epoch")
	}
	backend.mu.Lock()
	if backend.closed {
		backend.mu.Unlock()
		return errors.New("CoreDevice backend closed")
	}
	if connectionEpoch < backend.connectionEpoch {
		backend.mu.Unlock()
		return errors.New("stale connection epoch")
	}
	if connectionEpoch == backend.connectionEpoch {
		backend.mu.Unlock()
		return nil
	}
	coordinator := backend.coordinator
	streams := make([]*backendStream, 0, len(backend.streams))
	for _, stream := range backend.streams {
		streams = append(streams, stream)
	}
	backend.streams = make(map[string]*backendStream)
	backend.resetKeyboardLocked()
	screenshotProviders := backend.takeScreenshotProvidersLocked()
	backend.mu.Unlock()
	if coordinator == nil {
		return errors.New("CoreDevice generation coordinator unavailable")
	}
	backend.releaseStreams(streams)
	releaseScreenshotProviders(screenshotProviders)
	if err := coordinator.Attach(connectionEpoch); err != nil {
		return err
	}
	backend.mu.Lock()
	backend.connectionEpoch = connectionEpoch
	backend.tunnel = nil
	backend.services = make(map[string]*CoreDeviceService)
	backend.streams = make(map[string]*backendStream)
	backend.resetKeyboardLocked()
	backend.mu.Unlock()
	return nil
}

func (backend *Backend) RetireGeneration(reason string) error {
	backend.mu.Lock()
	if backend.closed {
		backend.mu.Unlock()
		return nil
	}
	coordinator := backend.coordinator
	streams := make([]*backendStream, 0, len(backend.streams))
	for _, stream := range backend.streams {
		streams = append(streams, stream)
	}
	backend.tunnel = nil
	backend.services = make(map[string]*CoreDeviceService)
	backend.streams = make(map[string]*backendStream)
	backend.resetKeyboardLocked()
	screenshotProviders := backend.takeScreenshotProvidersLocked()
	backend.mu.Unlock()
	if coordinator == nil {
		return errors.New("CoreDevice generation coordinator unavailable")
	}
	backend.releaseStreams(streams)
	releaseScreenshotProviders(screenshotProviders)
	_, err := coordinator.RetireCurrentWithReason(reason)
	return err
}

func (backend *Backend) releaseStreams(streams []*backendStream) {
	for _, stream := range streams {
		if stream.pointerActive {
			_ = backend.releasePointer(stream)
		}
		if stream.keyboardID != 0 {
			_ = sendKeyboardReport(stream.hid, stream.keyboardID, nil)
		}
	}
}

func (backend *Backend) takeScreenshotProvidersLocked() []reusableScreenshotProvider {
	providers := make([]reusableScreenshotProvider, 0, 2)
	if backend.dvtScreenshot != nil {
		providers = append(providers, backend.dvtScreenshot)
		backend.dvtScreenshot = nil
	}
	if backend.axAuditScreenshot != nil {
		providers = append(providers, backend.axAuditScreenshot)
		backend.axAuditScreenshot = nil
	}
	return providers
}

func releaseScreenshotProviders(providers []reusableScreenshotProvider) {
	for _, provider := range providers {
		_ = provider.Close()
	}
}

func (backend *Backend) service(facet string, deadline time.Time) (*CoreDeviceService, error) {
	if err := backend.ensureReady(deadline); err != nil {
		return nil, err
	}
	backend.mu.Lock()
	service := backend.services[facet]
	backend.mu.Unlock()
	if service == nil {
		return nil, errors.New("CoreDevice facet unavailable")
	}
	return service, nil
}

func (backend *Backend) extraService(name string, deadline time.Time) (*CoreDeviceService, error) {
	if err := backend.ensureReady(deadline); err != nil {
		return nil, err
	}
	backend.mu.Lock()
	if service := backend.services[name]; service != nil {
		backend.mu.Unlock()
		return service, nil
	}
	tunnel := backend.tunnel
	backend.mu.Unlock()
	service, err := tunnel.RSD.StartService(name, deadline)
	if err != nil {
		return nil, err
	}
	backend.mu.Lock()
	backend.services[name] = service
	backend.mu.Unlock()
	return service, nil
}

func (backend *Backend) discardExtraService(name string, stale *CoreDeviceService) {
	backend.mu.Lock()
	if backend.services[name] == stale {
		delete(backend.services, name)
	}
	backend.mu.Unlock()
	_ = stale.Close()
}

func (backend *Backend) displayGeometryService(deadline time.Time) (*CoreDeviceService, error) {
	if backend.openDisplayGeometryService != nil {
		return backend.openDisplayGeometryService(deadline)
	}
	if err := backend.ensureReady(deadline); err != nil {
		return nil, err
	}
	backend.mu.Lock()
	tunnel := backend.tunnel
	backend.mu.Unlock()
	return tunnel.RSD.StartService("com.apple.coredevice.deviceinfo", deadline)
}

// pasteboardService opens one dedicated device pasteboard session. The device
// may close this one-shot service after a request, so it must never be kept in
// the generation's facet cache or reused for the read-back exchange.
func (backend *Backend) pasteboardService(deadline time.Time) (*CoreDeviceService, error) {
	if backend.openPasteboardService != nil {
		return backend.openPasteboardService(deadline)
	}
	if err := backend.ensureReady(deadline); err != nil {
		return nil, err
	}
	backend.mu.Lock()
	tunnel := backend.tunnel
	name := backend.facetNames[coreDeviceServicePasteboard]
	backend.mu.Unlock()
	if tunnel == nil || tunnel.RSD == nil || name == "" {
		return nil, errors.New("CoreDevice pasteboard service unavailable")
	}
	return tunnel.RSD.StartService(name, deadline)
}

func (backend *Backend) invokeDisplayGeometryService(service *CoreDeviceService, deadline time.Time) (map[string]any, error) {
	if backend.invokeDisplayGeometry != nil {
		return backend.invokeDisplayGeometry(service, deadline)
	}
	return service.InvokeWithDeadline("com.apple.coredevice.feature.getdisplayinfo", map[string]any{}, "", deadline)
}

const (
	defaultBackendRequestTimeout          = 60 * time.Second
	personalizedPreparationRequestTimeout = 5 * time.Minute
	personalizedMountRequestTimeout       = 5 * time.Minute
)

func backendRequestDeadline(route string, now time.Time) time.Time {
	timeout := defaultBackendRequestTimeout
	if route == "coredevice.developerSupport.requestTSS" {
		timeout = personalizedPreparationRequestTimeout
	}
	if route == "coredevice.developerSupport.mount" {
		timeout = personalizedMountRequestTimeout
	}
	return now.Add(timeout)
}

func (backend *Backend) Execute(message protocol.Message) (map[string]any, error) {
	payload := message.Payload
	route, _ := payload["executorOperationID"].(string)
	backendPayload, ok := payload["backendPayload"].(map[string]any)
	if !ok || route == "" {
		return nil, &ProductError{Code: "invalidArgument", Stage: "requestValidation"}
	}
	deadline := backendRequestDeadline(route, time.Now())
	operation, _ := backendPayload["operation"].(string)
	if operation == "warmGeneration" {
		if backendPayload["preparationGroupID"] != PreparationGroupID {
			return nil, &ProductError{Code: "invalidArgument", Stage: "preparation"}
		}
		return backend.Warm(deadline)
	}
	if operation == "barrier" {
		return map[string]any{"disposition": "acknowledged"}, nil
	}
	if route == "coredevice.developerSupport.queryMounted" && operation == "queryMounted" {
		if backend.personalized == nil {
			return nil, &ProductError{Code: "developerSupportUnavailable", Stage: "startingDeviceServices"}
		}
		value, err := backend.personalized.QueryMounted(backend.rawUDID, deadline)
		if err == nil {
			return value, nil
		}
		return nil, personalizedRequestFailure(err)
	}
	if _, personalized := backendPayload["catalogRevision"]; personalized {
		value, err := backend.personalized.Execute(backend.rawUDID, backend.connectionEpoch, backendPayload, deadline)
		if err == nil {
			return value, nil
		}
		return nil, personalizedRequestFailure(err)
	}
	if err := backend.ensureReady(deadline); err != nil {
		return nil, startupProductError(err, "openingTunnel")
	}
	switch route {
	case "coredevice.appLaunch":
		return backend.launch(backendPayload, deadline)
	case "coredevice.displayGeometry.query":
		return backend.displayGeometry(deadline)
	case "coredevice.screenshot":
		return backend.screenshot(backendPayload, deadline)
	case "coredevice.orientation.rotate":
		return backend.rotate(backendPayload, deadline)
	case "coredevice.normalTouch":
		return backend.touch(backendPayload, deadline)
	case "coredevice.pasteboardSetAndPaste":
		return backend.pasteboardSetAndPaste(backendPayload, deadline)
	case "coredevice.keyboardMacro":
		return backend.keyboardMacro(backendPayload, deadline)
	case "coredevice.softwareKeyboardToggle":
		return backend.softwareKeyboardToggle(deadline)
	default:
		if strings.HasPrefix(route, "coredevice.button.") {
			return backend.button(route, backendPayload, deadline)
		}
		return nil, &ProductError{Code: "capabilityUnavailable", Stage: "executingProductRoute"}
	}
}

func personalizedRequestFailure(err error) *ProductError {
	if isPersonalizationServiceUnavailable(err) {
		return &ProductError{
			Code:  "personalizationServiceUnavailable",
			Phase: "personalizationTSS",
		}
	}
	var personalized *PersonalizedError
	if errors.As(err, &personalized) && personalized.Phase != "" {
		return &ProductError{
			Code:             "developerSupportUnavailable",
			Phase:            personalized.Phase,
			RetireGeneration: true,
		}
	}
	return &ProductError{
		Code:             "developerSupportUnavailable",
		Phase:            "startingDeviceServices",
		RetireGeneration: true,
	}
}

type backendStream struct {
	deliveryAttemptID string
	route             string
	interactionID     string
	hid               *CoreDeviceService
	pointer           *CoreDeviceService
	keyboardID        uint64
	pointerActive     bool
	pointerEdge       string
	pointerIndigo     bool
	lastX             uint16
	lastY             uint16
}

func (backend *Backend) OpenStream(message protocol.Message, deadline time.Time) error {
	sessionID := optionalMessageString(message.SessionID)
	deliveryID := optionalMessageString(message.DeliveryAttemptID)
	streamPayload, ok := message.Payload["streamPayload"].(map[string]any)
	if sessionID == "" || deliveryID == "" || !ok {
		return &ProductError{Code: "invalidArgument", Stage: "openingInputService"}
	}
	route := stringValue(streamPayload["routeID"])
	if route != "coredevice.pointerStream" && route != "coredevice.keyboardStream" {
		return &ProductError{Code: "capabilityUnavailable", Stage: "openingInputService"}
	}
	interactionID := stringValue(message.Payload["interactionID"])
	if interactionID == "" {
		return &ProductError{Code: "invalidArgument", Stage: "openingInputService"}
	}
	hid, err := backend.service(coreDeviceServiceHID, deadline)
	if err != nil {
		return startupProductError(err, "openingInputService")
	}
	stream := &backendStream{
		deliveryAttemptID: deliveryID,
		route:             route,
		interactionID:     interactionID,
		hid:               hid,
		pointerEdge:       "none",
		lastX:             32768,
		lastY:             32768,
	}
	if route == "coredevice.pointerStream" {
		stream.pointer, err = backend.service(coreDeviceServiceButton, deadline)
		if err != nil {
			return &ProductError{Code: "developerServicesUnavailable", Stage: "openingInputService"}
		}
	}
	if route == "coredevice.keyboardStream" {
		stream.keyboardID, err = backend.ensureKeyboardService(deadline)
		if err != nil {
			return &ProductError{Code: "developerServicesUnavailable", Stage: "openingInputService"}
		}
	}
	backend.mu.Lock()
	if backend.closed {
		backend.mu.Unlock()
		return &ProductError{Code: "developerServicesUnavailable", Stage: "openingInputService"}
	}
	if _, exists := backend.streams[sessionID]; exists {
		backend.mu.Unlock()
		return &ProductError{Code: "invalidArgument", Stage: "openingInputService"}
	}
	backend.streams[sessionID] = stream
	backend.mu.Unlock()
	return nil
}

func (backend *Backend) SendFrame(message protocol.Message, deadline time.Time) error {
	sessionID := optionalMessageString(message.SessionID)
	stream, err := backend.streamForMessage(sessionID, message)
	if err != nil {
		return err
	}
	frame, ok := message.Payload["framePayload"].(map[string]any)
	if !ok {
		return &ProductError{Code: "invalidArgument", Stage: "frameAccepted"}
	}
	kind := stringValue(frame["kind"])
	if stream.route == "coredevice.pointerStream" {
		x, okX := normalizedAxisValue(frame["x"])
		y, okY := normalizedAxisValue(frame["y"])
		if !okX || !okY || (kind != "begin" && kind != "move" && kind != "end" && kind != "cancel") {
			return &ProductError{Code: "invalidArgument", Stage: "frameAccepted"}
		}
		if kind == "begin" {
			edge := stream.pointerEdge
			if edge == "" {
				edge = "none"
			}
			if suppliedEdge, exists := frame["edge"]; exists {
				value, valid := suppliedEdge.(string)
				if !valid {
					return &ProductError{Code: "invalidArgument", Stage: "frameAccepted"}
				}
				edge = value
			}
			if !validPointerEdge(edge) {
				return &ProductError{Code: "invalidArgument", Stage: "frameAccepted"}
			}
			stream.pointerEdge = edge
			stream.pointerIndigo = edge != "none"
		}
		tracePointerStreamFrame("sendStart", sessionID, kind, x, y, nil)
		if err := backend.sendPointerFrame(stream, kind, x, y); err != nil {
			tracePointerStreamFrame("sendFailed", sessionID, kind, x, y, err)
			return &ProductError{Code: "outcomeUnknown", Committed: true, OutcomeUnknown: true, Stage: "frameAccepted"}
		}
		tracePointerStreamFrame("sendComplete", sessionID, kind, x, y, nil)
		stream.lastX, stream.lastY = x, y
		stream.pointerActive = kind != "end" && kind != "cancel"
		return nil
	}
	usages, ok := keyboardUsages(frame["usages"])
	if !ok {
		return &ProductError{Code: "invalidArgument", Stage: "frameAccepted"}
	}
	if err := sendKeyboardReport(stream.hid, stream.keyboardID, usages); err != nil {
		return &ProductError{Code: "outcomeUnknown", Committed: true, OutcomeUnknown: true, Stage: "frameAccepted"}
	}
	return nil
}

func (backend *Backend) CloseStream(message protocol.Message, deadline time.Time) error {
	sessionID := optionalMessageString(message.SessionID)
	stream, err := backend.streamForMessage(sessionID, message)
	if err != nil {
		return err
	}
	defer func() {
		backend.mu.Lock()
		delete(backend.streams, sessionID)
		backend.mu.Unlock()
	}()
	if stream.pointerActive {
		if err := backend.releasePointer(stream); err != nil {
			return &ProductError{Code: "outcomeUnknown", Committed: true, OutcomeUnknown: true, Stage: "closingInputService"}
		}
	}
	if stream.keyboardID != 0 {
		if err := sendKeyboardReport(stream.hid, stream.keyboardID, nil); err != nil {
			return &ProductError{Code: "outcomeUnknown", Committed: true, OutcomeUnknown: true, Stage: "closingInputService"}
		}
	}
	return nil
}

func (backend *Backend) sendPointerFrame(stream *backendStream, kind string, x, y uint16) error {
	if stream.pointerIndigo {
		eventType := uint64(1)
		if kind == "begin" {
			eventType = 0
		} else if kind == "end" || kind == "cancel" {
			eventType = 2
		}
		return backend.sendIndigoDigitizerEvent(stream.pointer, x, y, eventType, pointerEdgeCode(stream.pointerEdge))
	}
	state := byte(0xc2)
	if kind == "end" || kind == "cancel" {
		state = 0x02
	}
	return sendUniversalReport(stream.hid, 257, buildTouchscreenReport(state, x, y))
}

func (backend *Backend) releasePointer(stream *backendStream) error {
	if stream.pointerIndigo {
		return backend.sendIndigoDigitizerEvent(stream.pointer, stream.lastX, stream.lastY, 2, pointerEdgeCode(stream.pointerEdge))
	}
	return sendUniversalReport(stream.hid, 257, buildTouchscreenReport(0x02, stream.lastX, stream.lastY))
}

func (backend *Backend) sendIndigoDigitizerEvent(service *CoreDeviceService, x, y uint16, eventType, edge uint64) error {
	sender := backend.sendIndigoDigitizer
	if sender == nil {
		sender = sendIndigoDigitizerEvent
	}
	return sender(service, x, y, eventType, edge)
}

func sendIndigoDigitizerEvent(service *CoreDeviceService, x, y uint16, eventType, edge uint64) error {
	if service == nil || eventType > 2 || edge > 4 {
		return errors.New("invalid Indigo digitizer event")
	}
	return service.SendRequest(indigoDigitizerRequest(x, y, eventType, edge), false)
}

func indigoDigitizerRequest(x, y uint16, eventType, edge uint64) map[string]any {
	return map[string]any{
		"featureIdentifier": "com.apple.coredevice.feature.remote.hid.digitizer",
		"messageType":       "IndigoDigitizerEvent",
		"payload": map[string]any{
			"edge":      XPCUInt64(edge),
			"eventType": XPCUInt64(eventType),
			"pointOne": map[string]any{
				"x": float64(x) / 65535,
				"y": float64(y) / 65535,
			},
			"target": XPCUInt64(0),
		},
	}
}

func validPointerEdge(value string) bool {
	return value == "none" || value == "top" || value == "left" || value == "bottom" || value == "right"
}

func pointerEdgeCode(value string) uint64 {
	return map[string]uint64{"none": 0, "top": 1, "left": 2, "bottom": 3, "right": 4}[value]
}

func tracePointerStreamFrame(
	stage, sessionID, kind string,
	x, y uint16,
	err error,
) {
	if os.Getenv("PULSEPHONE_RUNTIME_TOUCH_STAGE_TRACE") != "1" {
		return
	}
	if err != nil {
		fmt.Fprintf(
			os.Stderr,
			"pulsephone pointer-stream stage=%s sessionID=%s kind=%s x=%d y=%d error=%v\n",
			stage,
			sessionID,
			kind,
			x,
			y,
			err,
		)
		return
	}
	fmt.Fprintf(
		os.Stderr,
		"pulsephone pointer-stream stage=%s sessionID=%s kind=%s x=%d y=%d\n",
		stage,
		sessionID,
		kind,
		x,
		y,
	)
}

func (backend *Backend) streamForMessage(sessionID string, message protocol.Message) (*backendStream, error) {
	if sessionID == "" || stringValue(message.Payload["interactionID"]) == "" {
		return nil, &ProductError{Code: "invalidArgument", Stage: "frameAccepted"}
	}
	backend.mu.Lock()
	stream := backend.streams[sessionID]
	backend.mu.Unlock()
	if stream == nil ||
		stream.deliveryAttemptID != optionalMessageString(message.DeliveryAttemptID) ||
		stream.interactionID != stringValue(message.Payload["interactionID"]) {
		return nil, &ProductError{Code: "invalidArgument", Stage: "frameAccepted"}
	}
	return stream, nil
}

func (backend *Backend) launch(payload map[string]any, deadline time.Time) (map[string]any, error) {
	bundleID, ok := payload["bundleID"].(string)
	if !ok || bundleID == "" || len(bundleID) > 255 {
		return nil, &ProductError{Code: "invalidArgument", Stage: "requestValidation"}
	}
	service, err := backend.service(coreDeviceServiceAppControl, deadline)
	if err != nil {
		return nil, &ProductError{Code: "developerServicesUnavailable", Stage: "openingInputService"}
	}
	_, err = service.InvokeWithDeadline("com.apple.coredevice.feature.launchapplication", map[string]any{
		"applicationSpecifier": map[string]any{"bundleIdentifier": map[string]any{"_0": bundleID}},
		"options": map[string]any{
			"arguments": []any{}, "environmentVariables": map[string]any{},
			"standardIOUsesPseudoterminals": true, "startStopped": false,
			"terminateExisting": true, "user": map[string]any{"shortName": "mobile"},
			"platformSpecificOptions": []byte("<?xml version=\"1.0\" encoding=\"UTF-8\"?><plist version=\"1.0\"><dict/></plist>"),
		},
		"standardIOIdentifiers": map[string]any{},
	}, "", deadline)
	if err != nil {
		return nil, &ProductError{Code: "appLaunchFailed"}
	}
	return map[string]any{"bundleID": bundleID, "disposition": "launchRequested", "resolvedRouteID": "coredevice.appLaunch"}, nil
}

func (backend *Backend) displayGeometry(deadline time.Time) (map[string]any, error) {
	traceDisplayGeometry("serviceAcquireStart")
	service, err := backend.displayGeometryService(deadline)
	if err != nil {
		traceDisplayGeometry("serviceAcquireFailed")
		return nil, &ProductError{Code: "developerServicesUnavailable", Stage: "displayGeometry"}
	}
	traceDisplayGeometry("serviceAcquireComplete")
	traceDisplayGeometry("invokeFirstStart")
	response, err := backend.invokeDisplayGeometryService(service, deadline)
	_ = service.Close()
	if err != nil {
		traceDisplayGeometry("invokeFirstFailed")
		// Mirror Python's context-managed device-info lifecycle: each retry gets
		// a new read-only service rather than reusing a one-shot connection.
		traceDisplayGeometry("serviceReopenStart")
		service, err = backend.displayGeometryService(deadline)
		if err == nil {
			traceDisplayGeometry("serviceReopenComplete")
			traceDisplayGeometry("invokeRetryStart")
			response, err = backend.invokeDisplayGeometryService(service, deadline)
			_ = service.Close()
			if err != nil {
				traceDisplayGeometry("invokeRetryFailed")
			}
		} else {
			traceDisplayGeometry("serviceReopenFailed")
		}
		if err != nil {
			return nil, &ProductError{Code: "developerServicesUnavailable", Stage: "displayGeometry"}
		}
	}
	traceDisplayGeometry("invokeComplete")
	result, err := displayGeometryResult(response)
	if err != nil {
		return nil, &ProductError{Code: "backendFailed", Stage: "displayGeometry"}
	}
	return result, nil
}

func traceDisplayGeometry(stage string) {
	if os.Getenv("PULSEPHONE_RUNTIME_TOUCH_STAGE_TRACE") != "1" {
		return
	}
	fmt.Fprintf(os.Stderr, "pulsephone display-geometry stage=%s\n", stage)
}

func displayGeometryResult(response map[string]any) (map[string]any, error) {
	displays, ok := response["displays"].([]any)
	if !ok {
		return nil, errors.New("invalid display inventory")
	}
	var primary map[string]any
	for _, value := range displays {
		item, ok := value.(map[string]any)
		if ok && item["primary"] == true && item["external"] == false {
			if primary != nil {
				return nil, errors.New("ambiguous primary display")
			}
			primary = item
		}
	}
	if primary == nil {
		return nil, errors.New("primary display unavailable")
	}
	native, ok := primary["nativeSize"].([]any)
	if !ok || len(native) != 2 {
		return nil, errors.New("invalid primary display size")
	}
	width, okW := positiveInteger(native[0])
	height, okH := positiveInteger(native[1])
	orientation := map[string]string{"rot0": "portrait", "rot90": "landscapeRight", "rot180": "portraitUpsideDown", "rot270": "landscapeLeft"}[stringValue(primary["currentOrientation"])]
	if !okW || !okH || orientation == "" {
		return nil, errors.New("invalid primary display geometry")
	}
	if strings.HasPrefix(orientation, "landscape") {
		width, height = height, width
	}
	return map[string]any{"disposition": "acknowledged", "logicalHeight": int64(height), "logicalWidth": int64(width), "orientation": orientation, "resolvedRouteID": "coredevice.displayGeometry.query"}, nil
}

func (backend *Backend) rotate(payload map[string]any, deadline time.Time) (map[string]any, error) {
	request, err := parseRotateRequest(payload, backend.connectionEpoch)
	if err != nil {
		return nil, &ProductError{Code: "invalidArgument", Stage: "requestValidation"}
	}
	service, err := backend.service(coreDeviceServiceOrientation, deadline)
	if err != nil {
		return nil, &ProductError{Code: "developerServicesUnavailable", Stage: "orientation"}
	}
	response, err := backend.requestOrientation(service, map[string]any{
		"featureIdentifier": "com.apple.coredevice.feature.remote.devicecontrol.orientation",
		"messageType":       "OrientationRequest",
		"payload":           map[string]any{"rotate": map[string]any{"_0": request.direction}},
	}, shorterDeadline(deadline, time.Now().Add(orientationRequestTimeout)))
	if err != nil {
		return nil, &ProductError{Code: "outcomeUnknown", Committed: true, OutcomeUnknown: true, Stage: "orientation"}
	}
	responseOrientation := stringValue(response["currentDeviceOrientation"])
	if !validOrientation(responseOrientation) {
		return nil, &ProductError{Code: "outcomeUnknown", Committed: true, OutcomeUnknown: true, Stage: "orientation"}
	}
	started := time.Now()
	var observed map[string]any
	samples := 0
	for _, delay := range orientationConfirmationDelays {
		if err := backend.waitForOrientation(delay, deadline); err != nil {
			return nil, &ProductError{Code: "outcomeUnknown", Committed: true, OutcomeUnknown: true, Stage: "orientation"}
		}
		samples++
		value, observationErr := backend.observeOrientationGeometry(shorterDeadline(deadline, time.Now().Add(orientationGeometryQueryTimeout)))
		if observationErr != nil || !validDisplayGeometry(value) {
			continue
		}
		observed = value
		if stringValue(value["orientation"]) == responseOrientation && responseOrientation != request.orientation {
			break
		}
	}
	if observed == nil || request.geometryRevision == ^uint64(0) {
		return nil, &ProductError{Code: "outcomeUnknown", Committed: true, OutcomeUnknown: true, Stage: "orientation"}
	}
	return orientationResult(request, responseOrientation, observed, samples, time.Since(started)), nil
}

func (backend *Backend) requestOrientation(service *CoreDeviceService, request map[string]any, deadline time.Time) (map[string]any, error) {
	if backend.orientationRequest != nil {
		return backend.orientationRequest(service, request, deadline)
	}
	return service.RequestAndReceiveWithDeadline(request, deadline)
}

func (backend *Backend) observeOrientationGeometry(deadline time.Time) (map[string]any, error) {
	if backend.orientationObserver != nil {
		return backend.orientationObserver(deadline)
	}
	return backend.displayGeometry(deadline)
}

func (backend *Backend) waitForOrientation(delay time.Duration, deadline time.Time) error {
	if backend.orientationWait != nil {
		return backend.orientationWait(delay, deadline)
	}
	return waitForTouchFrame(delay, deadline)
}

func shorterDeadline(operationDeadline, localDeadline time.Time) time.Time {
	if operationDeadline.IsZero() || localDeadline.Before(operationDeadline) {
		return localDeadline
	}
	return operationDeadline
}

type rotateRequest struct {
	direction        string
	geometryRevision uint64
	orientation      string
}

func parseRotateRequest(payload map[string]any, connectionEpoch uint64) (rotateRequest, error) {
	direction, ok := payload["direction"].(string)
	if !ok || (direction != "left" && direction != "right") {
		return rotateRequest{}, errors.New("invalid rotation direction")
	}
	payloadEpoch, err := protocol.RequireUInt64(payload["connectionEpoch"])
	if err != nil || payloadEpoch == 0 || payloadEpoch != connectionEpoch {
		return rotateRequest{}, errors.New("invalid rotation connection epoch")
	}
	revision, err := protocol.RequireUInt64(payload["geometryRevision"])
	if err != nil || revision == 0 {
		return rotateRequest{}, errors.New("invalid rotation geometry revision")
	}
	for _, key := range []string{"logicalWidth", "logicalHeight"} {
		value, err := protocol.RequireUInt64(payload[key])
		if err != nil || value == 0 {
			return rotateRequest{}, errors.New("invalid rotation geometry")
		}
	}
	orientation := stringValue(payload["orientation"])
	if !validOrientation(orientation) {
		return rotateRequest{}, errors.New("invalid rotation orientation")
	}
	return rotateRequest{direction: direction, geometryRevision: revision, orientation: orientation}, nil
}

func validOrientation(value string) bool {
	return value == "portrait" || value == "portraitUpsideDown" || value == "landscapeLeft" || value == "landscapeRight"
}

func validDisplayGeometry(value map[string]any) bool {
	if value == nil || !validOrientation(stringValue(value["orientation"])) {
		return false
	}
	for _, key := range []string{"logicalWidth", "logicalHeight"} {
		dimension, err := protocol.RequireUInt64(value[key])
		if err != nil || dimension == 0 {
			return false
		}
	}
	return true
}

func orientationResult(request rotateRequest, responseOrientation string, observed map[string]any, samples int, sampleWindow time.Duration) map[string]any {
	orientation := stringValue(observed["orientation"])
	logicalWidth, _ := protocol.RequireUInt64(observed["logicalWidth"])
	logicalHeight, _ := protocol.RequireUInt64(observed["logicalHeight"])
	displayChanged := orientation != request.orientation
	visibleConfirmed := orientation == responseOrientation && displayChanged
	reason := "unchanged"
	if visibleConfirmed {
		reason = "confirmed"
	} else if displayChanged {
		reason = "mismatch"
	}
	return map[string]any{
		"currentDisplayOrientation":        orientation,
		"direction":                        request.direction,
		"displayOrientationChanged":        displayChanged,
		"geometryConfirmationReason":       reason,
		"geometryRevision":                 request.geometryRevision + 1,
		"geometrySampleCount":              int64(samples),
		"geometrySampleWindowMilliseconds": int64(sampleWindow / time.Millisecond),
		"logicalHeight":                    logicalHeight,
		"logicalWidth":                     logicalWidth,
		"orientation":                      orientation,
		"previousDisplayOrientation":       request.orientation,
		"requestedDirection":               request.direction,
		"resolvedRouteID":                  "coredevice.orientation.rotate",
		"rotateResponseOrientation":        responseOrientation,
		"visibleOrientationConfirmed":      visibleConfirmed,
	}
}

func (backend *Backend) button(route string, payload map[string]any, deadline time.Time) (map[string]any, error) {
	started := time.Now()
	command, ok := payload["commandID"].(string)
	if !ok {
		return nil, &ProductError{Code: "invalidArgument", Stage: "requestValidation"}
	}
	presses, valid := buttonPresses(command)
	if !valid {
		return nil, &ProductError{Code: "invalidArgument", Stage: "requestValidation"}
	}
	service, err := backend.service(coreDeviceServiceButton, deadline)
	if err != nil {
		return nil, &ProductError{Code: "developerServicesUnavailable", Stage: "button"}
	}
	serviceOpened := time.Now()
	send := func(usage uint16, state uint64) error {
		return service.SendRequest(map[string]any{
			"messageType":       "IndigoButtonEvent",
			"payload":           map[string]any{"state": XPCUInt64(state), "usagePage": XPCUInt64(0x0c), "usageCode": XPCUInt64(usage)},
			"featureIdentifier": "com.apple.coredevice.feature.remote.hid.button",
		}, false)
	}
	if err := executeButtonPresses(presses, send, func(duration time.Duration) error {
		return waitForTouchFrame(duration, deadline)
	}); err != nil {
		return nil, &ProductError{Code: "outcomeUnknown", Committed: true, OutcomeUnknown: true, Stage: "button"}
	}
	sequenceCompleted := time.Now()
	return buttonResult(route, started, serviceOpened, sequenceCompleted, time.Now()), nil
}

type buttonPress struct {
	hold  time.Duration
	usage uint16
}

type buttonUsageEventSender func(usage uint16, state uint64) error

func executeButtonPresses(presses []buttonPress, send buttonUsageEventSender, wait func(time.Duration) error) error {
	for index, press := range presses {
		if err := send(press.usage, 1); err != nil {
			return err
		}
		// Once down is sent, always make the matching up attempt before returning a wait failure.
		holdErr := wait(press.hold)
		releaseErr := send(press.usage, 2)
		if holdErr != nil {
			return holdErr
		}
		if releaseErr != nil {
			return releaseErr
		}
		if index+1 < len(presses) {
			if err := wait(120 * time.Millisecond); err != nil {
				return err
			}
		}
	}
	return nil
}

func buttonPresses(command string) ([]buttonPress, bool) {
	switch command {
	case "button.home":
		return []buttonPress{{usage: 0x40, hold: 50 * time.Millisecond}}, true
	case "button.appSwitcher":
		return []buttonPress{{usage: 0x40, hold: 35 * time.Millisecond}, {usage: 0x40, hold: 35 * time.Millisecond}}, true
	case "button.lock":
		return []buttonPress{{usage: 0x30, hold: 500 * time.Millisecond}}, true
	case "button.mute":
		return []buttonPress{{usage: 0xe2, hold: 50 * time.Millisecond}}, true
	case "button.volumeDown":
		return []buttonPress{{usage: 0xea, hold: 50 * time.Millisecond}}, true
	case "button.volumeUp":
		return []buttonPress{{usage: 0xe9, hold: 50 * time.Millisecond}}, true
	default:
		return nil, false
	}
}

func buttonResult(route string, started, serviceOpened, sequenceCompleted, completed time.Time) map[string]any {
	microseconds := func(start, end time.Time) int64 {
		if end.Before(start) {
			return 0
		}
		return int64(end.Sub(start) / time.Microsecond)
	}
	return map[string]any{
		"_pulsephoneInternalTiming": map[string]any{
			"buttonSequenceMicroseconds": microseconds(serviceOpened, sequenceCompleted),
			"serviceCloseMicroseconds":   microseconds(sequenceCompleted, completed),
			"serviceOpenMicroseconds":    microseconds(started, serviceOpened),
			"totalMicroseconds":          microseconds(started, completed),
		},
		"disposition":     "acknowledged",
		"resolvedRouteID": route,
	}
}

func (backend *Backend) touch(payload map[string]any, deadline time.Time) (map[string]any, error) {
	frames, err := parseTimedTouchFrames(payload["frames"])
	if err != nil {
		return nil, &ProductError{Code: "invalidArgument", Stage: "requestValidation"}
	}
	service, err := backend.service(coreDeviceServiceHID, deadline)
	if err != nil {
		return nil, &ProductError{Code: "developerServicesUnavailable", Stage: "touch"}
	}
	active := false
	lastX, lastY := uint16(32768), uint16(32768)
	err = runTimedTouchFrames(frames, deadline, time.Now, waitForTouchFrame, func(frame timedTouchFrame) error {
		if err := sendUniversalReport(service, touchscreenServiceID, buildTouchscreenReport(frame.state, frame.x, frame.y)); err != nil {
			return err
		}
		lastX, lastY = frame.x, frame.y
		active = frame.state != 0x02
		return nil
	})
	if err != nil {
		if active {
			_ = sendUniversalReport(service, touchscreenServiceID, buildTouchscreenReport(0x02, lastX, lastY))
		}
		return nil, &ProductError{Code: "outcomeUnknown", Committed: true, OutcomeUnknown: true, Stage: "touch"}
	}
	return map[string]any{"disposition": "acknowledged", "resolvedRouteID": "coredevice.normalTouch"}, nil
}

type timedTouchFrame struct {
	elapsed time.Duration
	state   byte
	x       uint16
	y       uint16
}

func parseTimedTouchFrames(value any) ([]timedTouchFrame, error) {
	rawFrames, ok := value.([]any)
	if !ok || len(rawFrames) == 0 {
		return nil, errors.New("missing touch frames")
	}
	frames := make([]timedTouchFrame, 0, len(rawFrames))
	for _, raw := range rawFrames {
		frame, ok := raw.(map[string]any)
		if !ok {
			return nil, errors.New("invalid touch frame")
		}
		elapsedMilliseconds, err := protocol.RequireUInt64(frame["elapsedMs"])
		if err != nil || elapsedMilliseconds > uint64((1<<63-1)/int64(time.Millisecond)) {
			return nil, errors.New("invalid touch elapsed time")
		}
		x, okX := normalizedAxisValue(frame["x"])
		y, okY := normalizedAxisValue(frame["y"])
		state, okState := touchState(stringValue(frame["kind"]))
		if !okX || !okY || !okState {
			return nil, errors.New("invalid touch frame")
		}
		frames = append(frames, timedTouchFrame{
			elapsed: time.Duration(elapsedMilliseconds) * time.Millisecond,
			state:   state,
			x:       x,
			y:       y,
		})
	}
	return frames, nil
}

func touchState(kind string) (byte, bool) {
	switch kind {
	case "begin", "move":
		return 0xc2, true
	case "end":
		return 0x02, true
	default:
		return 0, false
	}
}

func runTimedTouchFrames(
	frames []timedTouchFrame,
	deadline time.Time,
	now func() time.Time,
	wait func(time.Duration, time.Time) error,
	send func(timedTouchFrame) error,
) error {
	started := now()
	for _, frame := range frames {
		if remaining := started.Add(frame.elapsed).Sub(now()); remaining > 0 {
			if err := wait(remaining, deadline); err != nil {
				return err
			}
		}
		if err := send(frame); err != nil {
			return err
		}
	}
	return nil
}

func waitForTouchFrame(duration time.Duration, deadline time.Time) error {
	if duration <= 0 {
		return nil
	}
	if deadline.IsZero() {
		time.Sleep(duration)
		return nil
	}
	remaining := time.Until(deadline)
	if remaining <= 0 || duration >= remaining {
		return errors.New("touch deadline exceeded")
	}
	timer := time.NewTimer(duration)
	defer timer.Stop()
	deadlineTimer := time.NewTimer(remaining)
	defer deadlineTimer.Stop()
	select {
	case <-timer.C:
		return nil
	case <-deadlineTimer.C:
		return errors.New("touch deadline exceeded")
	}
}

func sendUniversalReport(service *CoreDeviceService, serviceID uint64, report []byte) error {
	return service.SendRequest(map[string]any{
		"featureIdentifier": "com.apple.coredevice.feature.remote.universalhidservice",
		"messageType":       "Request",
		"payload":           map[string]any{"send": map[string]any{"_0": report, "_1": XPCUInt64(serviceID)}},
	}, false)
}

func buildTouchscreenReport(state byte, x, y uint16) []byte {
	report := make([]byte, 58)
	report[0], report[1], report[2], report[3] = 0x09, 0x01, 0x05, state
	report[4] = byte(x)
	report[5] = byte(x >> 8)
	report[6] = byte(y)
	report[7] = byte(y >> 8)
	report[40] = 0x02
	stamp := uint64(time.Now().UnixNano()) & ((uint64(1) << 48) - 1)
	for index := 0; index < 6; index++ {
		report[44+index] = byte(stamp >> (8 * index))
	}
	return report
}

func (backend *Backend) screenshot(payload map[string]any, deadline time.Time) (map[string]any, error) {
	deadline = boundedScreenshotDeadline(deadline, screenshotOperationTimeout)
	ctx := context.Background()
	if !deadline.IsZero() {
		var cancel context.CancelFunc
		ctx, cancel = context.WithDeadline(ctx, deadline)
		defer cancel()
	}
	result, err := backend.screenshotWithContext(ctx, payload, deadline)
	if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
		return nil, &ProductError{Code: "developerServicesUnavailable", RetireGeneration: true, Stage: "screenshotCapture"}
	}
	return result, err
}

func (backend *Backend) screenshotWithContext(ctx context.Context, payload map[string]any, deadline time.Time) (map[string]any, error) {
	deadline = boundedScreenshotDeadline(deadline, screenshotOperationTimeout)
	if ctx == nil {
		ctx = context.Background()
	}
	artifactID, okID := payload["artifactID"].(string)
	reservation, okPath := payload["reservationPath"].(string)
	if !okID || !okPath || !isUUID(artifactID) || !validReservationPath(reservation, artifactID) {
		return nil, &ProductError{Code: "artifactValidationFailed", Stage: "reservation"}
	}
	providers, err := screenshotProviderOrder(payload)
	if err != nil {
		return nil, &ProductError{Code: "invalidArgument", Stage: "requestValidation"}
	}
	queueWaitStarted := time.Now()
	if err := backend.acquireScreenshot(ctx); err != nil {
		return nil, err
	}
	captureAdmitted := time.Now()
	defer backend.releaseScreenshot()

	attempts := make([]any, 0, len(providers))
	var lastTiming map[string]any
	for _, provider := range providers {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		attemptStarted := time.Now()
		attemptDeadline := screenshotAttemptDeadline(provider, deadline)
		attemptContext, cancelAttempt := context.WithDeadline(ctx, attemptDeadline)
		capture := backend.captureScreenshotProviderWithContext(attemptContext, provider, attemptDeadline)
		cancelAttempt()
		attemptTiming := screenshotTiming(attemptStarted, queueWaitStarted, captureAdmitted, time.Now(), capture.timing)
		if capture.capture != nil {
			if err := ctx.Err(); err != nil {
				return nil, err
			}
			attempts = append(attempts, screenshotAttempt(provider, "failed", capture.stage, attemptTiming))
			lastTiming = attemptTiming
			continue
		}
		pngBytes, normalizeErr := normalizeImageToPNG(capture.image, capture.format)
		attemptTiming = screenshotTiming(attemptStarted, queueWaitStarted, captureAdmitted, time.Now(), capture.timing)
		if normalizeErr != nil {
			attempts = append(attempts, screenshotAttempt(provider, "failed", screenshotCaptureStage(provider), attemptTiming))
			lastTiming = attemptTiming
			continue
		}
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		if err := writeReservedPNG(reservation, pngBytes); err != nil {
			return nil, &ProductError{Code: "artifactValidationFailed", Stage: "helperWrite"}
		}
		attemptTiming = screenshotTiming(attemptStarted, queueWaitStarted, captureAdmitted, time.Now(), capture.timing)
		attempts = append(attempts, screenshotAttempt(provider, "succeeded", "", attemptTiming))
		return screenshotSuccessResult(artifactID, provider, pngBytes, attempts, screenshotTiming(queueWaitStarted, queueWaitStarted, captureAdmitted, time.Now(), capture.timing)), nil
	}
	stage := "screenshotCapture"
	if len(attempts) > 0 {
		if last, ok := attempts[len(attempts)-1].(map[string]any); ok {
			stage = stringValue(last["stage"])
		}
	}
	return nil, screenshotFailureResult(stage, attempts, screenshotOverallTiming(lastTiming, queueWaitStarted, captureAdmitted, time.Now()))
}

func (backend *Backend) acquireScreenshot(ctx context.Context) error {
	backend.mu.Lock()
	if backend.screenshotGate == nil {
		backend.screenshotGate = make(chan struct{}, 1)
		backend.screenshotGate <- struct{}{}
	}
	gate := backend.screenshotGate
	backend.mu.Unlock()
	select {
	case <-ctx.Done():
		return ctx.Err()
	case <-gate:
		return nil
	}
}

func (backend *Backend) releaseScreenshot() {
	backend.mu.Lock()
	gate := backend.screenshotGate
	backend.mu.Unlock()
	if gate != nil {
		gate <- struct{}{}
	}
}

func screenshotSuccessResult(artifactID, provider string, pngBytes []byte, attempts []any, internalTiming map[string]any) map[string]any {
	result := map[string]any{
		"_pulsephoneCaptureAttempts": attempts,
		"_pulsephoneInternalTiming":  internalTiming,
		"artifactID":                 artifactID,
		"byteCount":                  int64(len(pngBytes)),
		"captureProvider":            provider,
		"disposition":                "acknowledged",
		"format":                     "png",
		"resolvedRouteID":            "coredevice.screenshot",
	}
	if len(attempts) > 1 {
		result["_pulsephoneRetireGenerationAfterResult"] = true
		result["generationDisposition"] = "retiringAfterResult"
	}
	return result
}

func screenshotFailureResult(stage string, attempts []any, internalTiming map[string]any) *ProductError {
	details := map[string]any{}
	if len(attempts) > 0 {
		details["_pulsephoneCaptureAttempts"] = attempts
	}
	if len(internalTiming) > 0 {
		details["_pulsephoneInternalTiming"] = internalTiming
	}
	return &ProductError{
		Code:             "developerServicesUnavailable",
		Details:          details,
		RetireGeneration: true,
		Stage:            stage,
	}
}

func screenshotAttempt(provider, status, stage string, timing map[string]any) map[string]any {
	var errorCode any
	var failedStage any
	if status == "failed" {
		errorCode = "developerServicesUnavailable"
		failedStage = stage
	}
	return map[string]any{
		"errorCode": errorCode,
		"provider":  provider,
		"stage":     failedStage,
		"status":    status,
		"timings":   timing,
	}
}

func screenshotCaptureStage(provider string) string {
	switch provider {
	case "coreDevice":
		return "screenshotCaptureOrValidate"
	case "dvt":
		return "dvtScreenshotCaptureOrValidate"
	case "axAudit":
		return "axAuditScreenshotCaptureOrValidate"
	default:
		return "requestValidation"
	}
}

func screenshotAttemptDeadline(provider string, operationDeadline time.Time) time.Time {
	timeout, ok := screenshotProviderAttemptTimeouts[provider]
	if !ok {
		return operationDeadline
	}
	deadline := time.Now().Add(timeout)
	if !operationDeadline.IsZero() && operationDeadline.Before(deadline) {
		return operationDeadline
	}
	return deadline
}

func boundedScreenshotDeadline(parent time.Time, timeout time.Duration) time.Time {
	deadline := time.Now().Add(timeout)
	if !parent.IsZero() && parent.Before(deadline) {
		return parent
	}
	return deadline
}

func screenshotTiming(started, queueWaitStarted, captureAdmitted, completed time.Time, service screenshotServiceTiming) map[string]any {
	microseconds := func(start, end time.Time) int64 {
		if end.Before(start) {
			return 0
		}
		return int64(end.Sub(start) / time.Microsecond)
	}
	return map[string]any{
		"captureMicroseconds":      int64(service.capture / time.Microsecond),
		"queueWaitMicroseconds":    microseconds(queueWaitStarted, captureAdmitted),
		"serviceCloseMicroseconds": int64(service.serviceClose / time.Microsecond),
		"serviceOpenMicroseconds":  int64(service.serviceOpen / time.Microsecond),
		"totalMicroseconds":        microseconds(started, completed),
	}
}

func screenshotOverallTiming(lastTiming map[string]any, started, captureAdmitted, completed time.Time) map[string]any {
	if len(lastTiming) == 0 {
		return screenshotTiming(started, started, captureAdmitted, completed, screenshotServiceTiming{})
	}
	result := make(map[string]any, len(lastTiming))
	for key, value := range lastTiming {
		result[key] = value
	}
	result["totalMicroseconds"] = screenshotTiming(started, started, captureAdmitted, completed, screenshotServiceTiming{})["totalMicroseconds"]
	return result
}

func screenshotProviderOrder(payload map[string]any) ([]string, error) {
	raw, exists := payload["captureProviderOrder"]
	if !exists || raw == nil {
		provider := "coreDevice"
		if rawProvider, exists := payload["captureProvider"]; exists {
			value, ok := rawProvider.(string)
			if !ok {
				return nil, errors.New("invalid screenshot provider")
			}
			provider = value
		}
		if provider != "coreDevice" && provider != "dvt" && provider != "axAudit" {
			return nil, errors.New("unknown screenshot provider")
		}
		return []string{provider}, nil
	}
	if _, exists := payload["captureProvider"]; exists {
		return nil, errors.New("provider and provider order are mutually exclusive")
	}
	rawProviders, ok := raw.([]any)
	if !ok || len(rawProviders) < 1 || len(rawProviders) > 3 {
		return nil, errors.New("invalid screenshot provider order")
	}
	providers := make([]string, len(rawProviders))
	for index, rawProvider := range rawProviders {
		value, ok := rawProvider.(string)
		if !ok {
			return nil, errors.New("invalid screenshot provider")
		}
		providers[index] = value
	}
	allowed := map[string]bool{
		"coreDevice": true,
		"dvt":        true,
		"axAudit":    true,
	}
	seen := make(map[string]bool, len(providers))
	for _, provider := range providers {
		if !allowed[provider] || seen[provider] {
			return nil, errors.New("invalid screenshot provider order")
		}
		seen[provider] = true
	}
	canonical := []string{"dvt", "coreDevice", "axAudit"}
	position := 0
	for _, provider := range providers {
		for position < len(canonical) && canonical[position] != provider {
			position++
		}
		if position == len(canonical) {
			return nil, errors.New("invalid screenshot provider order")
		}
		position++
	}
	if strings.Join(providers, ",") == "" {
		return nil, errors.New("invalid screenshot provider order")
	}
	return providers, nil
}

func (backend *Backend) captureScreenshotProvider(provider string, deadline time.Time) ([]byte, string, string, error) {
	capture := backend.captureScreenshotProviderWithTiming(provider, deadline)
	return capture.image, capture.format, capture.stage, capture.capture
}

func (backend *Backend) captureScreenshotProviderWithTiming(provider string, deadline time.Time) screenshotCapture {
	ctx, cancel := screenshotContext(deadline)
	defer cancel()
	return backend.captureScreenshotProviderWithContext(ctx, provider, deadline)
}

func screenshotContext(deadline time.Time) (context.Context, context.CancelFunc) {
	if deadline.IsZero() {
		return context.WithCancel(context.Background())
	}
	return context.WithDeadline(context.Background(), deadline)
}

func (backend *Backend) captureScreenshotProviderWithContext(ctx context.Context, provider string, deadline time.Time) screenshotCapture {
	switch provider {
	case "coreDevice":
		return backend.captureCoreDeviceScreenshotWithContext(ctx, deadline)
	case "dvt":
		return backend.capturePersistentScreenshotProviderWithContext(ctx, "dvt", deadline)
	case "axAudit":
		return backend.capturePersistentScreenshotProviderWithContext(ctx, "axAudit", deadline)
	default:
		return screenshotCapture{stage: "requestValidation", capture: errors.New("unknown screenshot provider")}
	}
}

func (backend *Backend) captureCoreDeviceScreenshotWithContext(ctx context.Context, deadline time.Time) screenshotCapture {
	openService := backend.openScreenshotService
	if openService == nil {
		return screenshotCapture{stage: "screenshotServiceOpen", capture: errors.New("CoreDevice screenshot service unavailable")}
	}
	openedAt := time.Now()
	service, err := openScreenshotCaptureService(ctx, deadline, openService)
	timing := screenshotServiceTiming{serviceOpen: time.Since(openedAt)}
	if err != nil {
		rethrowScreenshotPanic(err)
		return screenshotCapture{stage: "screenshotServiceOpen", timing: timing, capture: err}
	}
	closer := newScreenshotCloser(service)
	closed := false
	defer func() {
		if !closed {
			_, _ = closer.closeWithin(screenshotProviderRetireTimeout)
		}
	}()
	captureStarted := time.Now()
	response, err := invokeScreenshotCaptureService(ctx, service, deadline)
	timing.capture = time.Since(captureStarted)
	closeDuration, closeErr := closer.closeWithin(screenshotProviderRetireTimeout)
	closed = true
	timing.serviceClose = closeDuration
	if err != nil {
		rethrowScreenshotPanic(err)
		return screenshotCapture{stage: "screenshotCaptureOrValidate", timing: timing, capture: err}
	}
	if closeErr != nil {
		return screenshotCapture{stage: "screenshotCaptureOrValidate", timing: timing, capture: closeErr}
	}
	imageBytes, ok := response["image"].([]byte)
	if !ok || len(imageBytes) == 0 {
		return screenshotCapture{stage: "screenshotCaptureOrValidate", timing: timing, capture: errors.New("invalid CoreDevice screenshot response")}
	}
	return screenshotCapture{image: imageBytes, format: stringValue(response["imageFormat"]), stage: "screenshotCaptureOrValidate", timing: timing}
}

func openScreenshotCaptureService(ctx context.Context, deadline time.Time, open func(time.Time) (screenshotCaptureService, error)) (screenshotCaptureService, error) {
	type result struct {
		service screenshotCaptureService
		err     error
	}
	results := make(chan result, 1)
	go func() {
		defer func() {
			if panicValue := recover(); panicValue != nil {
				results <- result{err: &screenshotPanicError{value: panicValue}}
			}
		}()
		service, err := open(deadline)
		results <- result{service: service, err: err}
	}()
	select {
	case result := <-results:
		return result.service, result.err
	case <-ctx.Done():
		go func() {
			result := <-results
			if result.service != nil {
				scheduleScreenshotClose(result.service)
			}
		}()
		return nil, ctx.Err()
	}
}

func invokeScreenshotCaptureService(ctx context.Context, service screenshotCaptureService, deadline time.Time) (map[string]any, error) {
	type result struct {
		response map[string]any
		err      error
	}
	results := make(chan result, 1)
	go func() {
		defer func() {
			if panicValue := recover(); panicValue != nil {
				results <- result{err: &screenshotPanicError{value: panicValue}}
			}
		}()
		response, err := service.InvokeWithDeadline("com.apple.coredevice.feature.capturescreenshot", map[string]any{"displayUniqueID": nil, "requestedFormat": "png"}, "com.apple.coredevice.action.capturescreenshot", deadline)
		results <- result{response: response, err: err}
	}()
	select {
	case result := <-results:
		return result.response, result.err
	case <-ctx.Done():
		return nil, ctx.Err()
	}
}

func (backend *Backend) openEphemeralScreenshotService(deadline time.Time) (screenshotCaptureService, error) {
	if err := backend.ensureReady(deadline); err != nil {
		return nil, err
	}
	backend.mu.Lock()
	if backend.closed || backend.tunnel == nil {
		backend.mu.Unlock()
		return nil, errors.New("CoreDevice backend closed")
	}
	tunnel := backend.tunnel
	serviceName := backend.facetNames[coreDeviceServiceScreenshot]
	backend.mu.Unlock()
	if serviceName == "" {
		return nil, errors.New("CoreDevice screenshot facet unavailable")
	}
	return tunnel.RSD.StartService(serviceName, deadline)
}

func (backend *Backend) capturePersistentScreenshotProvider(provider string, deadline time.Time) ([]byte, string, string, error) {
	ctx, cancel := screenshotContext(deadline)
	defer cancel()
	capture := backend.capturePersistentScreenshotProviderWithContext(ctx, provider, deadline)
	return capture.image, capture.format, capture.stage, capture.capture
}

func (backend *Backend) capturePersistentScreenshotProviderWithContext(ctx context.Context, provider string, deadline time.Time) screenshotCapture {
	backend.mu.Lock()
	if backend.closed {
		backend.mu.Unlock()
		return screenshotCapture{stage: screenshotCaptureStage(provider), capture: errors.New("CoreDevice backend closed")}
	}
	var session reusableScreenshotProvider
	var openSession screenshotProviderFactory
	var serviceOpenStage string
	switch provider {
	case "dvt":
		session = backend.dvtScreenshot
		openSession = backend.openDVTScreenshot
		serviceOpenStage = "dvtScreenshotServiceOpen"
	case "axAudit":
		session = backend.axAuditScreenshot
		openSession = backend.openAXAuditScreenshot
		serviceOpenStage = "axAuditScreenshotServiceOpen"
	}
	udid := backend.rawUDID
	backend.mu.Unlock()
	if openSession == nil {
		return screenshotCapture{stage: serviceOpenStage, capture: errors.New("screenshot provider unavailable")}
	}
	timing := screenshotServiceTiming{}
	if session == nil {
		openedAt := time.Now()
		opened, err := openReusableScreenshotProvider(ctx, deadline, udid, openSession)
		timing.serviceOpen = time.Since(openedAt)
		if err != nil {
			rethrowScreenshotPanic(err)
			return screenshotCapture{stage: direct.ScreenshotProviderFailureStage(err, serviceOpenStage), timing: timing, capture: err}
		}
		backend.mu.Lock()
		if backend.closed {
			backend.mu.Unlock()
			scheduleScreenshotClose(opened)
			return screenshotCapture{stage: serviceOpenStage, timing: timing, capture: errors.New("CoreDevice backend closed")}
		}
		switch provider {
		case "dvt":
			session = backend.dvtScreenshot
			if session == nil {
				backend.dvtScreenshot = opened
				session = opened
			}
		case "axAudit":
			session = backend.axAuditScreenshot
			if session == nil {
				backend.axAuditScreenshot = opened
				session = opened
			}
		}
		backend.mu.Unlock()
		if session != opened {
			scheduleScreenshotClose(opened)
		}
	}
	closer := newScreenshotCloser(session)
	defer func() {
		if panicValue := recover(); panicValue != nil {
			backend.detachScreenshotProvider(provider, session)
			_, _ = closer.closeWithin(screenshotProviderRetireTimeout)
			panic(panicValue)
		}
	}()
	captureStarted := time.Now()
	image, format, err := captureReusableScreenshotProvider(ctx, session, deadline)
	timing.capture = time.Since(captureStarted)
	if err == nil {
		return screenshotCapture{image: image, format: format, stage: screenshotCaptureStage(provider), timing: timing}
	}
	stage := direct.ScreenshotProviderFailureStage(err, screenshotCaptureStage(provider))
	backend.detachScreenshotProvider(provider, session)
	closeDuration, _ := closer.closeWithin(screenshotProviderRetireTimeout)
	timing.serviceClose = closeDuration
	rethrowScreenshotPanic(err)
	return screenshotCapture{stage: stage, timing: timing, capture: err}
}

func openReusableScreenshotProvider(ctx context.Context, deadline time.Time, udid string, open screenshotProviderFactory) (reusableScreenshotProvider, error) {
	type result struct {
		provider reusableScreenshotProvider
		err      error
	}
	results := make(chan result, 1)
	go func() {
		defer func() {
			if panicValue := recover(); panicValue != nil {
				results <- result{err: &screenshotPanicError{value: panicValue}}
			}
		}()
		provider, err := open(udid, deadline)
		results <- result{provider: provider, err: err}
	}()
	select {
	case result := <-results:
		return result.provider, result.err
	case <-ctx.Done():
		go func() {
			result := <-results
			if result.provider != nil {
				scheduleScreenshotClose(result.provider)
			}
		}()
		return nil, ctx.Err()
	}
}

func captureReusableScreenshotProvider(ctx context.Context, provider reusableScreenshotProvider, deadline time.Time) ([]byte, string, error) {
	type result struct {
		image  []byte
		format string
		err    error
	}
	results := make(chan result, 1)
	go func() {
		defer func() {
			if panicValue := recover(); panicValue != nil {
				results <- result{err: &screenshotPanicError{value: panicValue}}
			}
		}()
		image, format, err := provider.Capture(deadline)
		results <- result{image: image, format: format, err: err}
	}()
	select {
	case result := <-results:
		return result.image, result.format, result.err
	case <-ctx.Done():
		return nil, "", ctx.Err()
	}
}

func (backend *Backend) detachScreenshotProvider(provider string, session reusableScreenshotProvider) {
	backend.mu.Lock()
	if provider == "dvt" && backend.dvtScreenshot == session {
		backend.dvtScreenshot = nil
	}
	if provider == "axAudit" && backend.axAuditScreenshot == session {
		backend.axAuditScreenshot = nil
	}
	backend.mu.Unlock()
}

func (backend *Backend) discardScreenshotProvider(provider string, session reusableScreenshotProvider) {
	backend.detachScreenshotProvider(provider, session)
	_, _ = newScreenshotCloser(session).closeWithin(screenshotProviderRetireTimeout)
}

func normalizeImageToPNG(data []byte, format string) ([]byte, error) {
	return direct.NormalizeImageToPNG(data, format)
}

func writeReservedPNG(path string, data []byte) error {
	fd, err := syscall.Open(path, syscall.O_WRONLY|syscall.O_CLOEXEC|syscall.O_NOFOLLOW, 0)
	if err != nil {
		return err
	}
	file := os.NewFile(uintptr(fd), path)
	if file == nil {
		_ = syscall.Close(fd)
		return errors.New("reservation file")
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 || info.Size() != 0 {
		return errors.New("invalid reservation file")
	}
	if err := file.Truncate(0); err != nil {
		return err
	}
	if _, err := io.Copy(file, bytes.NewReader(data)); err != nil {
		return err
	}
	return file.Sync()
}

func validReservationPath(value, artifactID string) bool {
	return value != "" && len(value) <= 4096 && filepath.IsAbs(value) && !strings.ContainsRune(value, 0) && filepath.Clean(value) == value && filepath.Base(value) == artifactID+".png"
}

func normalizedAxis(value string) (uint16, bool) {
	if value == "0" {
		return 0, true
	}
	if value == "1" {
		return 65535, true
	}
	if !strings.HasPrefix(value, "0.") || strings.HasSuffix(value, "0") || len(value) < 3 || len(value) > 20 {
		return 0, false
	}
	fraction := value[2:]
	if len(fraction) > 18 {
		return 0, false
	}
	var numerator uint64
	for _, char := range fraction {
		if char < '0' || char > '9' {
			return 0, false
		}
		numerator = numerator*10 + uint64(char-'0')
	}
	scale := uint64(1)
	for range fraction {
		scale *= 10
	}
	high, low := bits.Mul64(numerator, 65535)
	low, carry := bits.Add64(low, scale/2, 0)
	high += carry
	projected, _ := bits.Div64(high, low, scale)
	return uint16(projected), true
}

func positiveInteger(value any) (int, bool) {
	switch number := value.(type) {
	case int64:
		if number > 0 {
			return int(number), true
		}
	case uint64:
		if number > 0 && number <= uint64(^uint(0)>>1) {
			return int(number), true
		}
	case float64:
		if number > 0 && number == float64(int(number)) {
			return int(number), true
		}
	}
	return 0, false
}

func stringValue(value any) string { valueString, _ := value.(string); return valueString }
func stringSliceAny(values []string) []any {
	result := make([]any, len(values))
	for i, value := range values {
		result[i] = value
	}
	return result
}
func isUUID(value string) bool {
	if len(value) != 36 {
		return false
	}
	for index, char := range value {
		if index == 8 || index == 13 || index == 18 || index == 23 {
			if char != '-' {
				return false
			}
			continue
		}
		if !((char >= '0' && char <= '9') || (char >= 'a' && char <= 'f')) {
			return false
		}
	}
	return true
}
