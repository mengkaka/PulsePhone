package coredevice

import (
	"context"
	"errors"
	"sync"
	"testing"
)

type testTunnel struct {
	started *[]string
	closed  *[]bool
}

func (t *testTunnel) ServiceStarter() ServiceStarter {
	return func(name string) (Closable, error) {
		*t.started = append(*t.started, name)
		return testCloser{id: name, closed: new([]string)}, nil
	}
}

func (t *testTunnel) Close() error {
	*t.closed = append(*t.closed, true)
	return nil
}

func TestCoordinatorWarmAndRetireClosesServicesBeforeTunnel(t *testing.T) {
	closed := []bool{}
	started := []string{}
	var tunnel *testTunnel
	coordinator, err := NewCoordinator(1, "device", func(_ context.Context, _ string) (TunnelLease, error) {
		tunnel = &testTunnel{started: &started, closed: &closed}
		return tunnel, nil
	}, 2, testServiceNames())
	if err != nil {
		t.Fatal(err)
	}
	if err := coordinator.Attach(3); err != nil {
		t.Fatal(err)
	}
	snapshot, err := coordinator.AdmitDemand(context.Background(), 3, Demand{
		DemandID:             "demand",
		Origin:               "finiteCommand",
		Persistence:          "epochBound",
		PreparationGroupID:   PreparationGroupID,
		PreparationAttemptID: "attempt",
	})
	if err != nil {
		t.Fatal(err)
	}
	if snapshot.State != "ready" || snapshot.Identity.ExecutorGeneration != 2 || len(snapshot.Facets) != 7 {
		t.Fatalf("snapshot = %#v", snapshot)
	}
	coordinator.RetireCurrent()
	if tunnel == nil || len(closed) != 1 {
		t.Fatalf("tunnel close = %v", closed)
	}
}

func TestCoordinatorRejectsStaleAndConflictingDemands(t *testing.T) {
	coordinator, err := NewCoordinator(1, "device", func(context.Context, string) (TunnelLease, error) {
		return nil, errors.New("not reached")
	}, 1, testServiceNames())
	if err != nil {
		t.Fatal(err)
	}
	if err := coordinator.Attach(5); err != nil {
		t.Fatal(err)
	}
	if err := coordinator.Attach(4); err == nil {
		t.Fatal("accepted stale attach")
	}
	_, err = coordinator.AdmitDemand(context.Background(), 5, Demand{
		DemandID: "demand", Origin: "finiteCommand", Persistence: "persistentAcrossReconnect",
		PreparationGroupID: PreparationGroupID, PreparationAttemptID: "attempt",
	})
	if err == nil {
		t.Fatal("accepted invalid demand persistence")
	}
}

func TestCoordinatorDeduplicatesConcurrentStartup(t *testing.T) {
	var mu sync.Mutex
	openCount := 0
	coordinator, err := NewCoordinator(1, "device", func(_ context.Context, _ string) (TunnelLease, error) {
		mu.Lock()
		openCount++
		mu.Unlock()
		return &testTunnel{started: new([]string), closed: new([]bool)}, nil
	}, 1, testServiceNames())
	if err != nil {
		t.Fatal(err)
	}
	if err := coordinator.Attach(3); err != nil {
		t.Fatal(err)
	}
	demand := Demand{DemandID: "demand", Origin: "finiteCommand", Persistence: "epochBound", PreparationGroupID: PreparationGroupID, PreparationAttemptID: "attempt"}
	results := make(chan error, 2)
	for range 2 {
		go func() {
			_, demandErr := coordinator.AdmitDemand(context.Background(), 3, demand)
			results <- demandErr
		}()
	}
	for range 2 {
		if demandErr := <-results; demandErr != nil {
			t.Fatal(demandErr)
		}
	}
	mu.Lock()
	defer mu.Unlock()
	if openCount != 1 {
		t.Fatalf("opened %d tunnels for one generation", openCount)
	}
}

func TestCoordinatorAdmitsOriginsAndReplacesGenerationAfterDetach(t *testing.T) {
	closed := []bool{}
	started := []string{}
	openCount := 0
	coordinator, err := NewCoordinator(7, "device", func(_ context.Context, _ string) (TunnelLease, error) {
		openCount++
		return &testTunnel{started: &started, closed: &closed}, nil
	}, 1, testServiceNames())
	if err != nil {
		t.Fatal(err)
	}
	if err := coordinator.Attach(12); err != nil {
		t.Fatal(err)
	}

	var first GenerationSnapshot
	for _, demand := range []Demand{
		{DemandID: "explicit", Origin: "explicitPrepare", Persistence: "epochBound", PreparationGroupID: PreparationGroupID, PreparationAttemptID: "shared"},
		{DemandID: "command", Origin: "finiteCommand", Persistence: "epochBound", PreparationGroupID: PreparationGroupID, PreparationAttemptID: "shared"},
		{DemandID: "live", Origin: "livePrewarm", Persistence: "persistentAcrossReconnect", PreparationGroupID: PreparationGroupID, PreparationAttemptID: "shared"},
	} {
		snapshot, admitErr := coordinator.AdmitDemand(context.Background(), 12, demand)
		if admitErr != nil {
			t.Fatal(admitErr)
		}
		if first.Identity == (GenerationIdentity{}) {
			first = snapshot
		} else if snapshot.Identity != first.Identity {
			t.Fatalf("origin started a different generation: %#v, first %#v", snapshot.Identity, first.Identity)
		}
	}
	if openCount != 1 || first.State != "ready" {
		t.Fatalf("opens=%d snapshot=%#v", openCount, first)
	}

	retired, err := coordinator.Detach(12)
	if err != nil || retired == nil || retired.State != "retired" || len(closed) != 1 {
		t.Fatalf("detach retired=%#v err=%v closed=%d", retired, err, len(closed))
	}
	if err := coordinator.Attach(13); err != nil {
		t.Fatal(err)
	}
	reconnected, err := coordinator.AdmitDemand(context.Background(), 13, Demand{
		DemandID: "reconnect", Origin: "livePrewarm", Persistence: "persistentAcrossReconnect", PreparationGroupID: PreparationGroupID, PreparationAttemptID: "reconnect",
	})
	if err != nil {
		t.Fatal(err)
	}
	if openCount != 2 || reconnected.Identity.ConnectionEpoch != 13 || reconnected.Identity.ExecutorGeneration != 2 || reconnected.Identity == first.Identity {
		t.Fatalf("opens=%d reconnected=%#v first=%#v", openCount, reconnected.Identity, first.Identity)
	}
}

func TestCoordinatorRejectsNonCoreDemandWithoutOpeningTunnel(t *testing.T) {
	openCount := 0
	coordinator, err := NewCoordinator(7, "device", func(context.Context, string) (TunnelLease, error) {
		openCount++
		return nil, errors.New("unexpected tunnel open")
	}, 1, testServiceNames())
	if err != nil {
		t.Fatal(err)
	}
	if err := coordinator.Attach(11); err != nil {
		t.Fatal(err)
	}
	_, err = coordinator.AdmitDemand(context.Background(), 11, Demand{
		DemandID: "direct-install", Origin: "finiteCommand", Persistence: "epochBound", PreparationGroupID: "prep.direct.lockdown.v1", PreparationAttemptID: "attempt",
	})
	if err == nil || openCount != 0 {
		t.Fatalf("non-CoreDevice demand err=%v opens=%d", err, openCount)
	}
}

func TestCoordinatorRejectsWrongEpochAndConflictingAttempt(t *testing.T) {
	started := make(chan struct{})
	release := make(chan struct{})
	coordinator, err := NewCoordinator(7, "device", func(context.Context, string) (TunnelLease, error) {
		close(started)
		<-release
		return &testTunnel{started: new([]string), closed: new([]bool)}, nil
	}, 1, testServiceNames())
	if err != nil {
		t.Fatal(err)
	}
	if err := coordinator.Attach(16); err != nil {
		t.Fatal(err)
	}
	valid := Demand{DemandID: "first", Origin: "explicitPrepare", Persistence: "epochBound", PreparationGroupID: PreparationGroupID, PreparationAttemptID: "attempt.shared"}
	if _, err := coordinator.AdmitDemand(context.Background(), 15, valid); err == nil {
		t.Fatal("accepted wrong connection epoch")
	}
	first := make(chan error, 1)
	go func() {
		_, admitErr := coordinator.AdmitDemand(context.Background(), 16, valid)
		first <- admitErr
	}()
	<-started
	_, err = coordinator.AdmitDemand(context.Background(), 16, Demand{
		DemandID: "conflict", Origin: "finiteCommand", Persistence: "epochBound", PreparationGroupID: PreparationGroupID, PreparationAttemptID: "attempt.other",
	})
	if err == nil {
		t.Fatal("accepted conflicting preparation attempt")
	}
	close(release)
	if err := <-first; err != nil {
		t.Fatal(err)
	}
}

func TestCoordinatorRetireCancelsStartupAndChecksOverflow(t *testing.T) {
	started := make(chan struct{})
	coordinator, err := NewCoordinator(1, "device", func(ctx context.Context, _ string) (TunnelLease, error) {
		close(started)
		<-ctx.Done()
		return nil, ctx.Err()
	}, 1, testServiceNames())
	if err != nil {
		t.Fatal(err)
	}
	if err := coordinator.Attach(3); err != nil {
		t.Fatal(err)
	}
	demandResult := make(chan error, 1)
	go func() {
		_, demandErr := coordinator.AdmitDemand(context.Background(), 3, Demand{DemandID: "demand", Origin: "finiteCommand", Persistence: "epochBound", PreparationGroupID: PreparationGroupID, PreparationAttemptID: "attempt"})
		demandResult <- demandErr
	}()
	<-started
	coordinator.RetireCurrent()
	if demandErr := <-demandResult; demandErr == nil {
		t.Fatal("startup cancellation was reported as success")
	}
	overflow, err := NewCoordinator(1, "device", func(context.Context, string) (TunnelLease, error) {
		return nil, errors.New("not reached")
	}, ^uint64(0), testServiceNames())
	if err != nil {
		t.Fatal(err)
	}
	if err := overflow.Attach(3); err != nil {
		t.Fatal(err)
	}
	if _, err := overflow.AdmitDemand(context.Background(), 3, Demand{DemandID: "demand", Origin: "finiteCommand", Persistence: "epochBound", PreparationGroupID: PreparationGroupID, PreparationAttemptID: "attempt"}); err == nil {
		t.Fatal("generation overflow was accepted")
	}
}

func TestCoordinatorExposesCurrentResourcesAndRetiresThem(t *testing.T) {
	closed := []bool{}
	started := []string{}
	coordinator, err := NewCoordinator(9, "device", func(_ context.Context, _ string) (TunnelLease, error) {
		return &testTunnel{started: &started, closed: &closed}, nil
	}, 11, testServiceNames())
	if err != nil {
		t.Fatal(err)
	}
	if err := coordinator.Attach(4); err != nil {
		t.Fatal(err)
	}
	_, err = coordinator.AdmitDemand(context.Background(), 4, Demand{
		DemandID:             "resource-demand",
		Origin:               "finiteCommand",
		Persistence:          "epochBound",
		PreparationGroupID:   PreparationGroupID,
		PreparationAttemptID: "resource-attempt",
	})
	if err != nil {
		t.Fatal(err)
	}
	resources, ok := coordinator.CurrentResources()
	if !ok || resources.Tunnel == nil || len(resources.Facets) != len(RequiredFacets) {
		t.Fatalf("current resources = %#v, ok=%t", resources, ok)
	}
	if resources.Snapshot.Identity != (GenerationIdentity{RuntimeEpoch: 9, ConnectionEpoch: 4, ExecutorGeneration: 11}) {
		t.Fatalf("resource identity = %#v", resources.Snapshot.Identity)
	}
	if _, err := coordinator.RetireCurrentWithReason("incompatible"); err != nil {
		t.Fatal(err)
	}
	if _, ok := coordinator.CurrentResources(); ok {
		t.Fatal("retired generation still exposed resources")
	}
	if len(closed) != 1 {
		t.Fatalf("retired tunnel close count = %d", len(closed))
	}
}

type orderedTunnel struct {
	events *[]string
	starts int
}

func (t *orderedTunnel) ServiceStarter() ServiceStarter {
	return func(name string) (Closable, error) {
		t.starts++
		*t.events = append(*t.events, "open:"+name)
		if t.starts == 3 {
			return nil, errors.New("injected service open failure")
		}
		return orderedCloser{name: name, events: t.events}, nil
	}
}

func (t *orderedTunnel) Close() error {
	*t.events = append(*t.events, "close:tunnel")
	return nil
}

type orderedCloser struct {
	name   string
	events *[]string
}

func (c orderedCloser) Close() error {
	*c.events = append(*c.events, "close:"+c.name)
	return nil
}

func TestCoordinatorPartialServiceOpenClosesResourcesBeforeTunnel(t *testing.T) {
	events := []string{}
	tunnel := &orderedTunnel{events: &events}
	coordinator, err := NewCoordinator(1, "device", func(context.Context, string) (TunnelLease, error) {
		return tunnel, nil
	}, 1, testServiceNames())
	if err != nil {
		t.Fatal(err)
	}
	if err := coordinator.Attach(3); err != nil {
		t.Fatal(err)
	}
	_, err = coordinator.AdmitDemand(context.Background(), 3, Demand{
		DemandID:             "failure-demand",
		Origin:               "finiteCommand",
		Persistence:          "epochBound",
		PreparationGroupID:   PreparationGroupID,
		PreparationAttemptID: "failure-attempt",
	})
	if err == nil {
		t.Fatal("service open failure accepted")
	}
	want := []string{
		"open:com.apple.coredevice.appservice",
		"open:com.apple.coredevice.hid.indigo",
		"open:com.apple.coredevice.hid.universalhidservice",
		"close:com.apple.coredevice.hid.indigo",
		"close:com.apple.coredevice.appservice",
		"close:tunnel",
	}
	if len(events) != len(want) {
		t.Fatalf("events = %v, want %v", events, want)
	}
	for index := range want {
		if events[index] != want[index] {
			t.Fatalf("events = %v, want %v", events, want)
		}
	}
	if resources, ok := coordinator.CurrentResources(); ok || resources.Tunnel != nil {
		t.Fatalf("failed generation still exposes resources: %#v", resources)
	}
}

func TestCoordinatorRetireSurfacesCloseFailureAfterClosingAllResources(t *testing.T) {
	closeErr := errors.New("product close failed")
	events := []string{}
	tunnel := &retirementFailureTunnel{events: &events, closeErr: closeErr}
	coordinator, err := NewCoordinator(1, "device", func(context.Context, string) (TunnelLease, error) {
		return tunnel, nil
	}, 1, testServiceNames())
	if err != nil {
		t.Fatal(err)
	}
	if err := coordinator.Attach(3); err != nil {
		t.Fatal(err)
	}
	if _, err := coordinator.AdmitDemand(context.Background(), 3, Demand{
		DemandID: "close-failure", Origin: "finiteCommand", Persistence: "epochBound",
		PreparationGroupID: PreparationGroupID, PreparationAttemptID: "close-failure",
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := coordinator.RetireCurrentWithReason("fatal"); !errors.Is(err, closeErr) {
		t.Fatalf("retire error = %v", err)
	}
	if len(events) != len(RequiredFacets)+1 || events[len(events)-1] != "close:tunnel" {
		t.Fatalf("close events = %#v", events)
	}
}

type retirementFailureTunnel struct {
	events   *[]string
	closeErr error
}

func (t *retirementFailureTunnel) ServiceStarter() ServiceStarter {
	return func(name string) (Closable, error) {
		return orderedCloser{name: name, events: t.events}, nil
	}
}

func (t *retirementFailureTunnel) Close() error {
	*t.events = append(*t.events, "close:tunnel")
	return t.closeErr
}
