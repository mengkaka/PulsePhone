package direct

import (
	"errors"
	"fmt"
	"net"
	"time"
)

const (
	dvtScreenshotChannel     = "com.apple.instruments.server.services.screenshot"
	dvtScreenshotMethod      = "takeScreenshot"
	dvtTerminationCapability = "com.apple.instruments.client.processcontrol.capability.terminationCallback"
	axAuditServiceName       = "com.apple.accessibility.axAuditDaemon.remoteserver"
	axAuditScreenshotMethod  = "deviceCaptureScreenshot"
	maximumAXAuditNodes      = 4096
	maximumAXAuditDepth      = 64
)

// ScreenshotProviderError keeps the failure boundary needed by the CoreDevice
// fallback contract without exposing transport details on HelperWire.
type ScreenshotProviderError struct {
	Stage string
	Err   error
}

type DVTScreenshotSession struct {
	lockdown *Lockdown
	dtx      *dtxConnection
	channel  int32
}

type AXAuditScreenshotSession struct {
	lockdown *Lockdown
	dtx      *dtxConnection
}

func (err *ScreenshotProviderError) Error() string {
	if err == nil || err.Err == nil {
		return "screenshot provider failed"
	}
	return err.Err.Error()
}

func (err *ScreenshotProviderError) Unwrap() error {
	if err == nil {
		return nil
	}
	return err.Err
}

func screenshotProviderFailure(stage string, err error) error {
	if err == nil {
		err = errors.New("screenshot provider failed")
	}
	return &ScreenshotProviderError{Stage: stage, Err: err}
}

// ScreenshotProviderFailureStage returns a provider's internal failure stage
// when present, or the caller's conservative service-open fallback.
func ScreenshotProviderFailureStage(err error, fallback string) string {
	var providerErr *ScreenshotProviderError
	if errors.As(err, &providerErr) && providerErr.Stage != "" {
		return providerErr.Stage
	}
	return fallback
}

// CaptureDVTScreenshot implements the narrow DVT screenshot contract used by
// element snapshot fallback. It intentionally does not expose a general DTX
// service surface.
func CaptureDVTScreenshot(udid string, deadline time.Time) ([]byte, string, error) {
	session, err := OpenDVTScreenshotSession(udid, deadline)
	if err != nil {
		return nil, "", err
	}
	defer session.Close()
	return session.Capture(deadline)
}

// OpenDVTScreenshotSession establishes the generation-owned DVT channel used
// by element snapshot capture. Callers must close it after generation retirement.
func OpenDVTScreenshotSession(udid string, deadline time.Time) (*DVTScreenshotSession, error) {
	lockdown, err := OpenLockdown(udid, deadline)
	if err != nil {
		return nil, screenshotProviderFailure("dvtScreenshotServiceOpen", err)
	}
	connection, err := lockdown.StartService(dvtServiceName)
	if err != nil {
		lockdown.Close()
		return nil, screenshotProviderFailure("dvtScreenshotServiceOpen", err)
	}
	session, err := OpenDVTScreenshotSessionOnConnection(connection, deadline)
	if err != nil {
		lockdown.Close()
		return nil, err
	}
	session.lockdown = lockdown
	return session, nil
}

// OpenDVTScreenshotSessionOnConnection opens the DTX screenshot channel on an
// already connected DVT transport. The caller transfers connection ownership
// to the returned session, including on a successful RSD direct service dial.
func OpenDVTScreenshotSessionOnConnection(connection net.Conn, deadline time.Time) (*DVTScreenshotSession, error) {
	return openDVTScreenshotSession(connection, deadline)
}

func openDVTScreenshotSession(connection net.Conn, deadline time.Time) (*DVTScreenshotSession, error) {
	dtx := newDTXConnection(connection, deadline)
	if err := dtx.handshakeWithCapabilities(map[string]any{
		"com.apple.private.DTXBlockCompression": int64(0),
		"com.apple.private.DTXConnection":       int64(1),
		dvtTerminationCapability:                int64(1),
	}); err != nil {
		_ = dtx.close()
		return nil, screenshotProviderFailure("dvtScreenshotServiceOpen", err)
	}
	channel, err := dtx.openChannel(dvtScreenshotChannel)
	if err != nil {
		_ = dtx.close()
		return nil, screenshotProviderFailure("dvtScreenshotServiceOpen", err)
	}
	return &DVTScreenshotSession{dtx: dtx, channel: channel}, nil
}

func captureDVTScreenshotConnection(connection net.Conn, deadline time.Time) ([]byte, string, error) {
	session, err := openDVTScreenshotSession(connection, deadline)
	if err != nil {
		return nil, "", err
	}
	defer session.Close()
	return session.Capture(deadline)
}

func (session *DVTScreenshotSession) Capture(deadline time.Time) ([]byte, string, error) {
	if session == nil || session.dtx == nil {
		return nil, "", screenshotProviderFailure("dvtScreenshotCaptureOrValidate", errors.New("DVT screenshot session closed"))
	}
	session.dtx.deadline = deadline
	value, err := session.dtx.invoke(session.channel, dvtScreenshotMethod)
	if err != nil {
		return nil, "", screenshotProviderFailure("dvtScreenshotCaptureOrValidate", err)
	}
	image, format, err := screenshotBytes(value)
	if err != nil {
		return nil, "", screenshotProviderFailure("dvtScreenshotCaptureOrValidate", err)
	}
	return image, format, nil
}

func (session *DVTScreenshotSession) Close() error {
	if session == nil {
		return nil
	}
	dtx := session.dtx
	lockdown := session.lockdown
	session.dtx = nil
	session.lockdown = nil
	var first error
	if dtx != nil {
		first = dtx.close()
	}
	if lockdown != nil {
		lockdown.Close()
	}
	return first
}

// CaptureAXAuditScreenshot implements the legacy AXAudit fallback over its
// lockdown DTX control channel. Responses can contain nested audit metadata;
// only bounded PNG/JPEG/TIFF byte candidates are accepted.
func CaptureAXAuditScreenshot(udid string, deadline time.Time) ([]byte, string, error) {
	session, err := OpenAXAuditScreenshotSession(udid, deadline)
	if err != nil {
		return nil, "", err
	}
	defer session.Close()
	return session.Capture(deadline)
}

// OpenAXAuditScreenshotSession establishes the generation-owned AXAudit
// session used only by the element screenshot fallback chain.
func OpenAXAuditScreenshotSession(udid string, deadline time.Time) (*AXAuditScreenshotSession, error) {
	lockdown, err := OpenLockdown(udid, deadline)
	if err != nil {
		return nil, screenshotProviderFailure("axAuditScreenshotServiceOpen", err)
	}
	connection, err := lockdown.StartServiceRaw(axAuditServiceName)
	if err != nil {
		lockdown.Close()
		return nil, screenshotProviderFailure("axAuditScreenshotServiceOpen", err)
	}
	session, err := openAXAuditScreenshotSession(connection, deadline)
	if err != nil {
		lockdown.Close()
		return nil, err
	}
	session.lockdown = lockdown
	return session, nil
}

func openAXAuditScreenshotSession(connection net.Conn, deadline time.Time) (*AXAuditScreenshotSession, error) {
	dtx := newDTXConnection(connection, deadline)
	if err := dtx.handshake(); err != nil {
		_ = dtx.close()
		return nil, screenshotProviderFailure("axAuditScreenshotServiceOpen", err)
	}
	return &AXAuditScreenshotSession{dtx: dtx}, nil
}

func captureAXAuditScreenshotConnection(connection net.Conn, deadline time.Time) ([]byte, string, error) {
	session, err := openAXAuditScreenshotSession(connection, deadline)
	if err != nil {
		return nil, "", err
	}
	defer session.Close()
	return session.Capture(deadline)
}

func (session *AXAuditScreenshotSession) Capture(deadline time.Time) ([]byte, string, error) {
	if session == nil || session.dtx == nil {
		return nil, "", screenshotProviderFailure("axAuditScreenshotCaptureOrValidate", errors.New("AXAudit screenshot session closed"))
	}
	session.dtx.deadline = deadline
	value, err := session.dtx.invoke(0, axAuditScreenshotMethod)
	if err != nil {
		return nil, "", screenshotProviderFailure("axAuditScreenshotCaptureOrValidate", err)
	}
	image, err := largestScreenshot(value)
	if err != nil {
		return nil, "", screenshotProviderFailure("axAuditScreenshotCaptureOrValidate", err)
	}
	return image, imageFormat(image), nil
}

func (session *AXAuditScreenshotSession) Close() error {
	if session == nil {
		return nil
	}
	dtx := session.dtx
	lockdown := session.lockdown
	session.dtx = nil
	session.lockdown = nil
	var first error
	if dtx != nil {
		first = dtx.close()
	}
	if lockdown != nil {
		lockdown.Close()
	}
	return first
}

func screenshotBytes(value any) ([]byte, string, error) {
	image, ok := value.([]byte)
	if !ok || len(image) == 0 || len(image) > maximumScreenshotBytes {
		return nil, "", errors.New("invalid screenshot response")
	}
	format := imageFormat(image)
	if format == "" {
		return nil, "", errors.New("unsupported screenshot response")
	}
	return append([]byte(nil), image...), format, nil
}

func largestScreenshot(value any) ([]byte, error) {
	var candidates [][]byte
	var visit func(any, int) error
	nodes := 0
	visit = func(current any, depth int) error {
		nodes++
		if nodes > maximumAXAuditNodes || depth > maximumAXAuditDepth {
			return errors.New("AXAudit screenshot response too complex")
		}
		switch item := current.(type) {
		case []byte:
			if format := imageFormat(item); format != "" {
				if len(item) > maximumScreenshotBytes {
					return errors.New("AXAudit screenshot response too large")
				}
				candidates = append(candidates, append([]byte(nil), item...))
			}
		case []any:
			for _, child := range item {
				if err := visit(child, depth+1); err != nil {
					return err
				}
			}
		case map[string]any:
			for _, child := range item {
				if err := visit(child, depth+1); err != nil {
					return err
				}
			}
		}
		return nil
	}
	if err := visit(value, 0); err != nil {
		return nil, err
	}
	if len(candidates) == 0 {
		return nil, errors.New("AXAudit screenshot payload missing")
	}
	largest := candidates[0]
	for _, candidate := range candidates[1:] {
		if len(candidate) > len(largest) {
			largest = candidate
		}
	}
	return largest, nil
}

func imageFormat(image []byte) string {
	return DetectImageFormat(image)
}

func screenshotProviderError(provider string, err error) error {
	if err == nil {
		return fmt.Errorf("%s screenshot failed", provider)
	}
	return fmt.Errorf("%s screenshot failed: %w", provider, err)
}
