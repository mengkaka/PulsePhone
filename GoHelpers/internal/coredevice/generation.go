package coredevice

import (
	"context"
	"errors"
	"sync"
)

type GenerationIdentity struct {
	RuntimeEpoch       uint64
	ConnectionEpoch    uint64
	ExecutorGeneration uint64
}

type Demand struct {
	DemandID             string
	Origin               string
	Persistence          string
	PreparationGroupID   string
	PreparationAttemptID string
}

type TunnelLease interface {
	ServiceStarter() ServiceStarter
	Close() error
}

type TunnelOpener func(ctx context.Context, rawTransportUDID string) (TunnelLease, error)

// GenerationStartupError retains the externally observable startup boundary
// while allowing callers to keep the transport failure itself private.
type GenerationStartupError struct {
	Phase string
	Err   error
}

func (err *GenerationStartupError) Error() string {
	if err == nil || err.Err == nil {
		return "CoreDevice generation startup failed"
	}
	return err.Err.Error()
}

func (err *GenerationStartupError) Unwrap() error {
	if err == nil {
		return nil
	}
	return err.Err
}

type GenerationSnapshot struct {
	Identity             GenerationIdentity
	State                string
	PreparationAttemptID string
	Facets               []string
	SurfaceRevision      string
}

type GenerationResources struct {
	Snapshot GenerationSnapshot
	Tunnel   TunnelLease
	Facets   map[string]Closable
}

type generation struct {
	identity             GenerationIdentity
	rawTransportUDID     string
	preparationAttemptID string
	openTunnel           TunnelOpener
	state                string
	tunnel               TunnelLease
	services             *ServiceBundle
	mu                   sync.Mutex
	startOnce            sync.Once
	startDone            chan struct{}
	startCancel          context.CancelFunc
	startErr             error
}

func (g *generation) snapshot() GenerationSnapshot {
	g.mu.Lock()
	defer g.mu.Unlock()
	snapshot := GenerationSnapshot{Identity: g.identity, State: g.state, PreparationAttemptID: g.preparationAttemptID}
	if g.services != nil {
		snapshot.Facets = append([]string(nil), g.services.Facets...)
		snapshot.SurfaceRevision = g.services.SurfaceRevision
	}
	return snapshot
}

func (g *generation) ensureReady(ctx context.Context, serviceNames map[string]string) (GenerationSnapshot, error) {
	g.mu.Lock()
	if g.state == "ready" {
		snapshot := g.snapshotUnlocked()
		g.mu.Unlock()
		return snapshot, nil
	}
	if g.state == "retired" || g.state == "draining" {
		g.mu.Unlock()
		return GenerationSnapshot{}, errors.New("generation retired")
	}
	g.startOnce.Do(func() {
		g.startDone = make(chan struct{})
		startContext, cancel := context.WithCancel(ctx)
		g.startCancel = cancel
		go g.warm(startContext, serviceNames)
	})
	done := g.startDone
	g.mu.Unlock()
	<-done
	g.mu.Lock()
	snapshot := g.snapshotUnlocked()
	err := g.startErr
	g.mu.Unlock()
	if err != nil {
		return GenerationSnapshot{}, err
	}
	return snapshot, nil
}

func (g *generation) warm(ctx context.Context, serviceNames map[string]string) {
	tunnel, err := g.openTunnel(ctx, g.rawTransportUDID)
	if err != nil {
		g.finishStart(&GenerationStartupError{Phase: "openingTunnel", Err: err})
		return
	}
	g.mu.Lock()
	retiring := g.state != "starting"
	g.mu.Unlock()
	if retiring {
		_ = tunnel.Close()
		g.finishStart(errors.New("generation retired"))
		return
	}
	bundle, err := NewServiceBundle(serviceNames, tunnel.ServiceStarter())
	if err != nil {
		_ = tunnel.Close()
		g.finishStart(&GenerationStartupError{Phase: "startingDeviceServices", Err: err})
		return
	}
	g.mu.Lock()
	retiring = g.state != "starting"
	if !retiring {
		g.tunnel = tunnel
		g.services = bundle
		g.preparationAttemptID = ""
		g.state = "ready"
	}
	g.mu.Unlock()
	if retiring {
		_ = bundle.Close()
		_ = tunnel.Close()
		g.finishStart(errors.New("generation retired"))
		return
	}
	g.finishStart(nil)
}

func (g *generation) finishStart(err error) {
	g.mu.Lock()
	g.startErr = err
	if g.state != "retired" {
		if err != nil {
			g.state = "retired"
		}
	}
	done := g.startDone
	g.startDone = nil
	g.startCancel = nil
	g.mu.Unlock()
	if done != nil {
		close(done)
	}
}

func (g *generation) retire() (GenerationSnapshot, error) {
	g.mu.Lock()
	if g.state == "retired" {
		snapshot := g.snapshotUnlocked()
		g.mu.Unlock()
		return snapshot, nil
	}
	g.state = "draining"
	cancel := g.startCancel
	done := g.startDone
	if cancel != nil {
		cancel()
	}
	services := g.services
	tunnel := g.tunnel
	g.services = nil
	g.tunnel = nil
	g.preparationAttemptID = ""
	g.state = "retired"
	snapshot := g.snapshotUnlocked()
	g.mu.Unlock()
	if done != nil {
		<-done
	}
	var first error
	if services != nil {
		if err := services.Close(); err != nil {
			first = err
		}
	}
	if tunnel != nil {
		if err := tunnel.Close(); err != nil && first == nil {
			first = err
		}
	}
	return snapshot, first
}

func (g *generation) snapshotUnlocked() GenerationSnapshot {
	snapshot := GenerationSnapshot{Identity: g.identity, State: g.state, PreparationAttemptID: g.preparationAttemptID}
	if g.services != nil {
		snapshot.Facets = append([]string(nil), g.services.Facets...)
		snapshot.SurfaceRevision = g.services.SurfaceRevision
	}
	return snapshot
}

type Coordinator struct {
	runtimeEpoch           uint64
	rawTransportUDID       string
	openTunnel             TunnelOpener
	serviceNames           map[string]string
	connectionEpoch        uint64
	current                *generation
	lastRetiredGeneration  *GenerationSnapshot
	nextExecutorGeneration uint64
	acceptingDemands       bool
	mu                     sync.Mutex
}

func NewCoordinator(runtimeEpoch uint64, rawTransportUDID string, opener TunnelOpener, firstGeneration uint64, serviceNames map[string]string) (*Coordinator, error) {
	if runtimeEpoch == 0 || !asciiIdentifier(rawTransportUDID, 256) || opener == nil || firstGeneration == 0 {
		return nil, errors.New("invalid generation coordinator")
	}
	if !validServiceNames(serviceNames) {
		return nil, errors.New("invalid service map")
	}
	return &Coordinator{runtimeEpoch: runtimeEpoch, rawTransportUDID: rawTransportUDID, openTunnel: opener, serviceNames: cloneStrings(serviceNames), nextExecutorGeneration: firstGeneration, acceptingDemands: true}, nil
}

func (c *Coordinator) Attach(connectionEpoch uint64) error {
	if connectionEpoch == 0 {
		return errors.New("invalid connection epoch")
	}
	c.mu.Lock()
	if c.connectionEpoch != 0 && connectionEpoch < c.connectionEpoch {
		c.mu.Unlock()
		return errors.New("stale connection epoch")
	}
	if connectionEpoch == c.connectionEpoch {
		c.mu.Unlock()
		return nil
	}
	old := c.current
	c.current = nil
	c.connectionEpoch = connectionEpoch
	c.mu.Unlock()
	if old != nil {
		snapshot, _ := old.retire()
		c.mu.Lock()
		c.lastRetiredGeneration = &snapshot
		c.mu.Unlock()
	}
	return nil
}

func (c *Coordinator) AdmitDemand(ctx context.Context, connectionEpoch uint64, demand Demand) (GenerationSnapshot, error) {
	if demand.PreparationGroupID != PreparationGroupID {
		return GenerationSnapshot{}, errors.New("demand not applicable")
	}
	if !asciiIdentifier(demand.DemandID, 128) || !asciiIdentifier(demand.PreparationAttemptID, 128) {
		return GenerationSnapshot{}, errors.New("invalid demand")
	}
	if (demand.Origin == "explicitPrepare" || demand.Origin == "finiteCommand") && demand.Persistence != "epochBound" {
		return GenerationSnapshot{}, errors.New("invalid demand persistence")
	}
	if demand.Origin == "livePrewarm" && demand.Persistence != "persistentAcrossReconnect" {
		return GenerationSnapshot{}, errors.New("invalid demand persistence")
	}
	if demand.Origin != "explicitPrepare" && demand.Origin != "finiteCommand" && demand.Origin != "livePrewarm" {
		return GenerationSnapshot{}, errors.New("invalid demand origin")
	}
	c.mu.Lock()
	if !c.acceptingDemands {
		c.mu.Unlock()
		return GenerationSnapshot{}, errors.New("runtime not accepting demand")
	}
	if c.connectionEpoch == 0 || connectionEpoch != c.connectionEpoch {
		c.mu.Unlock()
		return GenerationSnapshot{}, errors.New("wrong connection epoch")
	}
	g := c.current
	state := "retired"
	preparationAttemptID := ""
	if g != nil {
		g.mu.Lock()
		state = g.state
		preparationAttemptID = g.preparationAttemptID
		g.mu.Unlock()
	}
	if g == nil || state == "retired" {
		if c.nextExecutorGeneration == ^uint64(0) {
			c.mu.Unlock()
			return GenerationSnapshot{}, errors.New("generation overflow")
		}
		g = &generation{identity: GenerationIdentity{RuntimeEpoch: c.runtimeEpoch, ConnectionEpoch: connectionEpoch, ExecutorGeneration: c.nextExecutorGeneration}, rawTransportUDID: c.rawTransportUDID, preparationAttemptID: demand.PreparationAttemptID, openTunnel: c.openTunnel, state: "starting"}
		c.nextExecutorGeneration++
		c.current = g
	} else if state != "ready" && preparationAttemptID != demand.PreparationAttemptID {
		c.mu.Unlock()
		return GenerationSnapshot{}, errors.New("conflicting preparation attempt")
	}
	c.mu.Unlock()
	return g.ensureReady(ctx, c.serviceNames)
}

func (c *Coordinator) CurrentResources() (GenerationResources, bool) {
	c.mu.Lock()
	g := c.current
	c.mu.Unlock()
	if g == nil {
		return GenerationResources{}, false
	}
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.state != "ready" || g.tunnel == nil || g.services == nil {
		return GenerationResources{}, false
	}
	return GenerationResources{
		Snapshot: g.snapshotUnlocked(),
		Tunnel:   g.tunnel,
		Facets:   g.services.ResourcesByFacet(),
	}, true
}

func (c *Coordinator) RetireCurrent() {
	_, _ = c.RetireCurrentWithReason("quiesce")
}

func (c *Coordinator) Detach(connectionEpoch uint64) (*GenerationSnapshot, error) {
	c.mu.Lock()
	if connectionEpoch != c.connectionEpoch {
		c.mu.Unlock()
		return nil, nil
	}
	generation := c.current
	c.current = nil
	c.connectionEpoch = 0
	c.mu.Unlock()
	if generation == nil {
		return nil, nil
	}
	snapshot, err := generation.retire()
	c.mu.Lock()
	c.lastRetiredGeneration = &snapshot
	c.mu.Unlock()
	return &snapshot, err
}

func (c *Coordinator) RetireCurrentWithReason(reason string) (*GenerationSnapshot, error) {
	if reason != "fatal" && reason != "incompatible" && reason != "quiesce" {
		return nil, errors.New("retirement reason")
	}
	c.mu.Lock()
	g := c.current
	c.current = nil
	if reason == "fatal" || reason == "quiesce" {
		c.acceptingDemands = false
	}
	c.mu.Unlock()
	if g != nil {
		snapshot, err := g.retire()
		c.mu.Lock()
		c.lastRetiredGeneration = &snapshot
		c.mu.Unlock()
		return &snapshot, err
	}
	return nil, nil
}

func cloneStrings(value map[string]string) map[string]string {
	result := make(map[string]string, len(value))
	for key, item := range value {
		result[key] = item
	}
	return result
}
