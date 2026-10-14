package coredevice

import (
	"errors"
	"fmt"
	"time"
)

// invocationError records the submission boundary, never device userInfo.
// attempted includes partial or uncertain writes: zero bytes is not proof of
// non-submission in the userspace TCP stack.
type invocationError struct {
	attempted    bool
	rejected     bool
	notInstalled bool
	nativeCode   string
	stage        string
	err          error
}

func (e *invocationError) Error() string { return "CoreDevice invocation failed at " + e.stage }
func (e *invocationError) Unwrap() error { return e.err }

func nativeErrorCode(value map[string]any) (string, int64, bool) {
	domain, ok := value["domain"].(string)
	// Only known system domains are public; arbitrary device strings can contain
	// private data even when they look like a syntactically valid identifier.
	switch domain {
	case "com.apple.dt.CoreDeviceError", "NSOSStatusErrorDomain", "NSPOSIXErrorDomain", "NSCocoaErrorDomain", "com.apple.SpringBoardServices":
	default:
		return "", 0, false
	}
	if !ok {
		return "", 0, false
	}
	var code int64
	switch v := value["code"].(type) {
	case XPCInt64:
		code = int64(v)
	case int64:
		code = v
	case int:
		code = int64(v)
	default:
		return "", 0, false
	}
	if code < -2147483648 || code > 2147483647 {
		return "", 0, false
	}
	return domain, code, true
}
func normalizeInvocationRejection(value map[string]any) *invocationError {
	failure := &invocationError{attempted: true, rejected: true, stage: "deviceRejection"}
	// Bound traversal for malformed or cyclic local fixtures.
	for depth := 0; value != nil && depth < 3; depth++ {
		domain, code, ok := nativeErrorCode(value)
		if ok {
			if failure.nativeCode != "" {
				failure.nativeCode += "/"
			}
			failure.nativeCode += fmt.Sprintf("%s:%d", domain, code)
			if domain == "NSOSStatusErrorDomain" && code == -10814 {
				failure.notInstalled = true
			}
		}
		info, _ := value["userInfo"].(map[string]any)
		value, _ = info["NSUnderlyingError"].(map[string]any)
	}
	return failure
}

// preflight can prove a local close, known FIN/reset, or expired deadline before
// launch transmission. It cannot predict a peer disconnect racing with Write.
func (connection *RemoteXPCConnection) preflight(deadline time.Time) error {
	if connection == nil || connection.closed || connection.conn == nil {
		return errors.New("remote XPC connection closed")
	}
	if !deadline.IsZero() && !time.Now().Before(deadline) {
		return osErrTimeout{}
	}
	if conn, ok := connection.conn.(*tcpConn); ok {
		conn.mu.Lock()
		defer conn.mu.Unlock()
		if conn.eof || conn.err != nil || conn.state != tcpEstablished {
			return errors.New("remote XPC TCP connection unavailable")
		}
	}
	return nil
}

func (backend *Backend) acquireAppControl(deadline time.Time) error {
	backend.mu.Lock()
	if backend.appControlGate == nil {
		backend.appControlGate = make(chan struct{}, 1)
	}
	gate := backend.appControlGate
	backend.mu.Unlock()
	if deadline.IsZero() {
		gate <- struct{}{}
		return nil
	}
	if !time.Now().Before(deadline) {
		return osErrTimeout{}
	}
	timer := time.NewTimer(time.Until(deadline))
	defer timer.Stop()
	select {
	case gate <- struct{}{}:
		return nil
	case <-timer.C:
		return osErrTimeout{}
	}
}
func (backend *Backend) releaseAppControl() {
	backend.mu.Lock()
	gate := backend.appControlGate
	backend.mu.Unlock()
	<-gate
}

func (backend *Backend) generationIdentityLocked() GenerationIdentity {
	return GenerationIdentity{RuntimeEpoch: backend.runtimeEpoch, ConnectionEpoch: backend.connectionEpoch, ExecutorGeneration: backend.executorGeneration}
}

func (backend *Backend) appControlService(deadline time.Time) (*CoreDeviceService, error) {
	if err := backend.ensureReady(deadline); err != nil {
		return nil, err
	}
	backend.mu.Lock()
	if backend.closed {
		backend.mu.Unlock()
		return nil, errors.New("backend closed")
	}
	if service := backend.services[coreDeviceServiceAppControl]; service != nil {
		backend.mu.Unlock()
		return service, nil
	}
	identity, tunnel, opener := backend.generationIdentityLocked(), backend.tunnel, backend.openAppControlService
	name := backend.facetNames[coreDeviceServiceAppControl]
	backend.mu.Unlock()
	if !deadline.IsZero() && !time.Now().Before(deadline) {
		return nil, osErrTimeout{}
	}
	var service *CoreDeviceService
	var err error
	if opener != nil {
		service, err = opener(deadline)
	} else if tunnel != nil && tunnel.RSD != nil {
		service, err = tunnel.RSD.StartService(name, deadline)
	} else {
		err = errors.New("RSD unavailable")
	}
	if err != nil {
		if service != nil {
			_ = service.Close()
		}
		return nil, err
	}
	if service == nil {
		return nil, errors.New("nil appControl service")
	}
	backend.mu.Lock()
	valid := !backend.closed && backend.tunnel == tunnel && backend.generationIdentityLocked() == identity && backend.services[coreDeviceServiceAppControl] == nil && (deadline.IsZero() || time.Now().Before(deadline))
	if valid && backend.coordinator != nil {
		valid = backend.coordinator.replaceFacet(identity, coreDeviceServiceAppControl, nil, service)
	}
	if valid {
		backend.services[coreDeviceServiceAppControl] = service
	}
	backend.mu.Unlock()
	if !valid {
		_ = service.Close()
		return nil, errors.New("appControl generation retired or deadline expired")
	}
	return service, nil
}

func (backend *Backend) invalidateAppControl(service *CoreDeviceService) {
	backend.mu.Lock()
	if backend.services[coreDeviceServiceAppControl] == service {
		if backend.coordinator != nil {
			backend.coordinator.replaceFacet(backend.generationIdentityLocked(), coreDeviceServiceAppControl, service, nil)
		}
		delete(backend.services, coreDeviceServiceAppControl)
	}
	backend.mu.Unlock()
	_ = service.Close()
}

// Only a known failure of the shared transport escalates generation retirement.
// A single appControl FIN does not imply that HID or the tunnel is unusable.
func (backend *Backend) sharedTunnelUnavailable() bool {
	backend.mu.Lock()
	tunnel := backend.tunnel
	backend.mu.Unlock()
	if tunnel == nil {
		return false
	}
	if tunnel.stack != nil {
		tunnel.stack.mu.Lock()
		closed := tunnel.stack.closed
		tunnel.stack.mu.Unlock()
		if closed {
			return true
		}
	}
	if tunnel.RSD != nil {
		tunnel.RSD.servicesMu.Lock()
		closed := tunnel.RSD.closed
		tunnel.RSD.servicesMu.Unlock()
		return closed
	}
	return false
}
