package coredevice

import (
	"errors"
	"fmt"
	"net"
	"strings"
	"sync"
	"testing"
	"time"
)

func launchFixture(t *testing.T, replies []map[string]any) (*CoreDeviceService, <-chan error) {
	t.Helper()
	client, server := net.Pipe()
	service := &CoreDeviceService{remote: NewRemoteXPCConnection(client)}
	t.Cleanup(func() { _ = service.Close() })
	done := make(chan error, 1)
	go func() {
		defer server.Close()
		_ = server.SetDeadline(time.Now().Add(3 * time.Second))
		for i, reply := range replies {
			frame, err := ReadHTTP2Frame(server, RemoteXPCMaxFrame)
			if err != nil {
				done <- err
				return
			}
			wrapper, err := DecodeXPCWrapper(frame.Payload, RemoteXPCMaxMessage)
			if err != nil {
				done <- err
				return
			}
			if wrapper.MessageID != uint64(i*2+1) {
				done <- fmt.Errorf("ID %d at request %d", wrapper.MessageID, i)
				return
			}
			if reply == nil {
				done <- nil
				return
			} // FIN after receiving the request
			encoded, err := EncodeXPCWrapper(reply, wrapper.MessageID, false)
			if err != nil {
				done <- err
				return
			}
			raw, err := (HTTP2Frame{Type: HTTP2Data, StreamID: 3, Payload: encoded}).Encode()
			if err == nil {
				_, err = server.Write(raw)
			}
			if err != nil {
				done <- err
				return
			}
		}
		done <- nil
	}()
	return service, done
}
func launchBackend(service *CoreDeviceService) *Backend {
	return &Backend{runtimeEpoch: 1, connectionEpoch: 1, executorGeneration: 1, tunnel: &CoreDeviceTunnelLease{}, services: map[string]*CoreDeviceService{coreDeviceServiceAppControl: service, coreDeviceServiceHID: {}}}
}
func launchOnce(backend *Backend) error {
	_, err := backend.launch(map[string]any{"bundleID": "com.example.Test", "environment": map[string]any{"PRIVATE_ENV": "private-value"}}, time.Now().Add(time.Second))
	return err
}
func requireProductError(t *testing.T, err error, code string) *ProductError {
	t.Helper()
	var failure *ProductError
	if !errors.As(err, &failure) || failure.Code != code {
		t.Fatalf("error=%#v want %s", err, code)
	}
	return failure
}
func successReply() map[string]any { return map[string]any{"CoreDevice.output": map[string]any{}} }

func TestLaunchRecoversBeforeSendAndReusesHealthyReplacement(t *testing.T) {
	old := &CoreDeviceService{closed: true}
	service, done := launchFixture(t, []map[string]any{successReply(), successReply()})
	backend := launchBackend(old)
	hid, tunnel := backend.services[coreDeviceServiceHID], backend.tunnel
	opens := 0
	deadline := time.Now().Add(time.Second)
	backend.openAppControlService = func(got time.Time) (*CoreDeviceService, error) {
		opens++
		if !got.Equal(deadline) {
			t.Errorf("replacement changed deadline")
		}
		return service, nil
	}
	for i := 0; i < 2; i++ {
		if _, err := backend.launch(map[string]any{"bundleID": "com.example.Test"}, deadline); err != nil {
			t.Fatal(err)
		}
	}
	if opens != 1 || backend.services[coreDeviceServiceAppControl] != service || backend.services[coreDeviceServiceHID] != hid || backend.tunnel != tunnel {
		t.Fatal("did not limit repair to appControl")
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}
func TestLaunchPostSendEOFDoesNotReplayAndNextCallRecovers(t *testing.T) {
	old, done := launchFixture(t, []map[string]any{nil})
	next, nextDone := launchFixture(t, []map[string]any{successReply()})
	backend := launchBackend(old)
	opens := 0
	backend.openAppControlService = func(time.Time) (*CoreDeviceService, error) { opens++; return next, nil }
	failure := requireProductError(t, launchOnce(backend), "outcomeUnknown")
	if !failure.OutcomeUnknown || failure.CommitState != "unknown" || opens != 0 || backend.services[coreDeviceServiceAppControl] != nil || !old.closed || failure.RetireGeneration {
		t.Fatalf("unsafe recovery %#v opens=%d", failure, opens)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if err := launchOnce(backend); err != nil {
		t.Fatal(err)
	}
	if opens != 1 {
		t.Fatalf("opens=%d", opens)
	}
	if err := <-nextDone; err != nil {
		t.Fatal(err)
	}
}
func TestLaunchExplicitRefusalKeepsConnectionAndSanitizesNativeError(t *testing.T) {
	rejection := map[string]any{"CoreDevice.error": map[string]any{"domain": "com.apple.dt.CoreDeviceError", "code": XPCInt64(10002), "userInfo": map[string]any{"NSLocalizedDescription": "private-value", "NSUnderlyingError": map[string]any{"domain": "NSOSStatusErrorDomain", "code": XPCInt64(-10814), "userInfo": map[string]any{"path": "private-path"}}}}}
	service, done := launchFixture(t, []map[string]any{rejection, successReply()})
	backend := launchBackend(service)
	failure := requireProductError(t, launchOnce(backend), "appNotInstalled")
	want := "com.apple.dt.CoreDeviceError:10002/NSOSStatusErrorDomain:-10814"
	if failure.Details["normalizedBackendCode"] != want || failure.OutcomeUnknown || failure.Committed || service.closed {
		t.Fatalf("failure %#v", failure)
	}
	if strings.Contains(fmt.Sprint(failure.Details), "private") {
		t.Fatal("private details exposed")
	}
	if err := launchOnce(backend); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}
func TestLaunchMalformedResponseAndUnknownRefusal(t *testing.T) {
	for _, tc := range []struct {
		name, code string
		reply      map[string]any
		unknown    bool
	}{
		{"malformed", "outcomeUnknown", map[string]any{"unexpected": "private"}, true},
		{"refusal", "appLaunchFailed", map[string]any{"CoreDevice.error": map[string]any{"domain": "private-domain", "code": XPCInt64(123), "userInfo": map[string]any{"private": "secret"}}}, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			service, done := launchFixture(t, []map[string]any{tc.reply})
			backend := launchBackend(service)
			failure := requireProductError(t, launchOnce(backend), tc.code)
			if failure.OutcomeUnknown != tc.unknown || service.closed != tc.unknown || strings.Contains(fmt.Sprint(failure.Details), "private") {
				t.Fatalf("failure %#v", failure)
			}
			if err := <-done; err != nil {
				t.Fatal(err)
			}
		})
	}
}
func TestLaunchBoundsBeforeSendRetryAndDeadline(t *testing.T) {
	backend := launchBackend(&CoreDeviceService{closed: true})
	opens := 0
	backend.openAppControlService = func(time.Time) (*CoreDeviceService, error) { opens++; return &CoreDeviceService{closed: true}, nil }
	requireProductError(t, launchOnce(backend), "developerServicesUnavailable")
	if opens != 1 {
		t.Fatalf("opens=%d", opens)
	}
	_, err := backend.launch(map[string]any{"bundleID": "test"}, time.Now().Add(-time.Second))
	requireProductError(t, err, "executionTimeout")
	if opens != 1 {
		t.Fatal("expired request reopened service")
	}
	// Waiting for another launch also consumes the original deadline.
	if err := backend.acquireAppControl(time.Now().Add(time.Second)); err != nil {
		t.Fatal(err)
	}
	_, err = backend.launch(map[string]any{"bundleID": "test"}, time.Now().Add(10*time.Millisecond))
	backend.releaseAppControl()
	requireProductError(t, err, "executionTimeout")
}
func TestLaunchConcurrentCallsSerializeOnSameConnection(t *testing.T) {
	const count = 12
	replies := make([]map[string]any, count)
	for i := range replies {
		replies[i] = successReply()
	}
	service, done := launchFixture(t, replies)
	backend := launchBackend(service)
	var wg sync.WaitGroup
	failures := make(chan error, count)
	for i := 0; i < count; i++ {
		wg.Add(1)
		go func() { defer wg.Done(); failures <- launchOnce(backend) }()
	}
	wg.Wait()
	close(failures)
	for err := range failures {
		if err != nil {
			t.Fatal(err)
		}
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
}
func TestLaunchReplacementCannotSurviveRetirement(t *testing.T) {
	service := &CoreDeviceService{}
	backend := launchBackend(&CoreDeviceService{closed: true})
	opened, release := make(chan struct{}), make(chan struct{})
	backend.openAppControlService = func(time.Time) (*CoreDeviceService, error) { close(opened); <-release; return service, nil }
	done := make(chan error, 1)
	go func() { done <- launchOnce(backend) }()
	<-opened
	backend.mu.Lock()
	backend.closed = true
	backend.services = map[string]*CoreDeviceService{}
	backend.mu.Unlock()
	close(release)
	requireProductError(t, <-done, "developerServicesUnavailable")
	if !service.closed || backend.services[coreDeviceServiceAppControl] != nil {
		t.Fatal("retirement resurrected service")
	}
}
func TestKnownTCPFINRejectsWriteBeforeTransmission(t *testing.T) {
	conn := &tcpConn{state: tcpEstablished, eof: true}
	if err := NewRemoteXPCConnection(conn).preflight(time.Now().Add(time.Second)); err == nil {
		t.Fatal("FIN passed preflight")
	}
	if n, err := conn.Write([]byte("request")); err == nil || n != 0 {
		t.Fatalf("write %d %v", n, err)
	}
}

type ambiguousWriteConn struct {
	net.Conn
	writes int
}

func (conn *ambiguousWriteConn) Write([]byte) (int, error) {
	conn.writes++
	return 0, errors.New("uncertain underlying packet write")
}
func TestLaunchZeroByteWriteErrorIsUnknownAndNotReplayed(t *testing.T) {
	client, server := net.Pipe()
	defer server.Close()
	conn := &ambiguousWriteConn{Conn: client}
	service := &CoreDeviceService{remote: NewRemoteXPCConnection(conn)}
	backend := launchBackend(service)
	backend.openAppControlService = func(time.Time) (*CoreDeviceService, error) { t.Fatal("replayed ambiguous write"); return nil, nil }
	failure := requireProductError(t, launchOnce(backend), "outcomeUnknown")
	if failure.CommitState != "unknown" || conn.writes != 1 || !service.closed {
		t.Fatalf("failure %#v writes=%d", failure, conn.writes)
	}
}
func TestLaunchPostSendTimeoutAndPartialResponseAreUnknown(t *testing.T) {
	for _, partial := range []bool{false, true} {
		t.Run(fmt.Sprint(partial), func(t *testing.T) {
			client, server := net.Pipe()
			done := make(chan error, 1)
			go func() {
				defer server.Close()
				_, err := ReadHTTP2Frame(server, RemoteXPCMaxFrame)
				if err == nil && partial {
					_, err = server.Write([]byte{0, 0, 30, HTTP2Data})
				}
				if err == nil {
					buffer := make([]byte, 1)
					_, _ = server.Read(buffer)
				}
				done <- err
			}()
			service := &CoreDeviceService{remote: NewRemoteXPCConnection(client)}
			backend := launchBackend(service)
			_, err := backend.launch(map[string]any{"bundleID": "test"}, time.Now().Add(30*time.Millisecond))
			failure := requireProductError(t, err, "outcomeUnknown")
			if failure.CommitState != "unknown" || !service.closed {
				t.Fatalf("failure %#v", failure)
			}
			if err := <-done; err != nil {
				t.Fatal(err)
			}
		})
	}
}

func TestLaunchReplacementOwnedByCurrentGenerationAndClosedOnBackendClose(t *testing.T) {
	old := &CoreDeviceService{closed: true}
	replacement, done := launchFixture(t, []map[string]any{successReply()})
	backend := launchBackend(old)
	hid := backend.services[coreDeviceServiceHID]
	identity := backend.generationIdentityLocked()
	g := &generation{identity: identity, state: "ready", tunnel: backend.tunnel, services: &ServiceBundle{byFacet: map[string]Closable{coreDeviceServiceAppControl: old, coreDeviceServiceHID: hid}, resources: []Closable{old, hid}}}
	backend.coordinator = &Coordinator{current: g}
	backend.openAppControlService = func(time.Time) (*CoreDeviceService, error) { return replacement, nil }
	if err := launchOnce(backend); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	resources, ok := backend.coordinator.CurrentResources()
	if !ok || resources.Facets[coreDeviceServiceAppControl] != replacement || resources.Facets[coreDeviceServiceHID] != hid {
		t.Fatal("replacement ownership lost")
	}
	if err := backend.Close(); err != nil {
		t.Fatal(err)
	}
	if !replacement.closed || !hid.closed {
		t.Fatal("generation leaked repaired connection or other facet")
	}
}
func TestLaunchReplacementCannotSurviveConnectionEpochChange(t *testing.T) {
	service := &CoreDeviceService{}
	backend := launchBackend(&CoreDeviceService{closed: true})
	opened, release := make(chan struct{}), make(chan struct{})
	backend.openAppControlService = func(time.Time) (*CoreDeviceService, error) { close(opened); <-release; return service, nil }
	done := make(chan error, 1)
	go func() { done <- launchOnce(backend) }()
	<-opened
	backend.mu.Lock()
	backend.connectionEpoch++
	backend.mu.Unlock()
	close(release)
	requireProductError(t, <-done, "developerServicesUnavailable")
	if !service.closed || backend.services[coreDeviceServiceAppControl] != nil {
		t.Fatal("reopen installed a stale epoch")
	}
}

func TestAppControlSharedTransportFailureEscalatesGeneration(t *testing.T) {
	backend := launchBackend(&CoreDeviceService{closed: true})
	backend.tunnel.stack = &tcpStack{closed: true}
	backend.openAppControlService = func(time.Time) (*CoreDeviceService, error) { return nil, errors.New("transport failed") }
	failure := requireProductError(t, launchOnce(backend), "developerServicesUnavailable")
	if !failure.RetireGeneration || failure.OutcomeUnknown {
		t.Fatalf("failure %#v", failure)
	}
}
func TestClosedAppControlRemovedFromRSDOwnership(t *testing.T) {
	rsd := &RSDClient{}
	old, other := &CoreDeviceService{rsd: rsd}, &CoreDeviceService{rsd: rsd}
	rsd.services = []*CoreDeviceService{old, other}
	if err := old.Close(); err != nil {
		t.Fatal(err)
	}
	if len(rsd.services) != 1 || rsd.services[0] != other {
		t.Fatal("RSD retained closed replacement predecessor")
	}
	if err := rsd.Close(); err != nil {
		t.Fatal(err)
	}
	if !other.closed || !rsd.closed {
		t.Fatal("RSD close did not release live services")
	}
	if _, err := rsd.StartService("app", time.Now().Add(time.Second)); err == nil {
		t.Fatal("retired RSD accepted reopen")
	}
}
