package coredevice

import (
	"errors"
	"reflect"
	"testing"
)

type testCloser struct {
	id     string
	closed *[]string
	err    error
}

func (value testCloser) Close() error {
	*value.closed = append(*value.closed, value.id)
	return value.err
}

func testServiceNames() map[string]string {
	return map[string]string{
		"appControl":  "com.apple.coredevice.appservice",
		"button":      "com.apple.coredevice.hid.indigo",
		"hid":         "com.apple.coredevice.hid.universalhidservice",
		"keyboard":    "com.apple.coredevice.hid.universalhidservice",
		"orientation": "com.apple.coredevice.devicecontrol",
		"pasteboard":  "com.apple.coredevice.pasteboardservice",
		"screenshot":  "com.apple.coredevice.screencaptureservice",
	}
}

func TestParseFacetServiceMapRequiresExactSurface(t *testing.T) {
	values := []string{
		"appControl=app",
		"button=button",
		"hid=hid",
		"keyboard=keyboard",
		"orientation=orientation",
		"pasteboard=pasteboard",
		"screenshot=screenshot",
	}
	parsed, err := ParseFacetServiceMap(values)
	if err != nil || len(parsed) != len(SupportedFacets) {
		t.Fatalf("parse = %#v, %v", parsed, err)
	}
	for _, invalid := range [][]string{
		values[:len(values)-1],
		append(append([]string(nil), values...), "button=duplicate"),
		[]string{"appControl=bad service"},
		[]string{"unknown=service"},
	} {
		if _, err := ParseFacetServiceMap(invalid); err == nil {
			t.Fatalf("accepted invalid service map: %v", invalid)
		}
	}
}

func TestServiceBundleUsesSortedUniqueResourcesAndClosesReverse(t *testing.T) {
	closed := []string{}
	started := []string{}
	bundle, err := NewServiceBundle(testServiceNames(), func(name string) (Closable, error) {
		started = append(started, name)
		return testCloser{id: name, closed: &closed}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if !reflect.DeepEqual(bundle.Facets, append([]string(nil), RequiredFacets...)) {
		t.Fatalf("facets = %v", bundle.Facets)
	}
	if len(bundle.SurfaceRevision) != 64 {
		t.Fatalf("surface revision = %q", bundle.SurfaceRevision)
	}
	resources := bundle.ResourcesByFacet()
	if len(resources) != len(RequiredFacets) {
		t.Fatalf("resources by facet = %v", resources)
	}
	for _, facet := range RequiredFacets {
		if resources[facet] == nil {
			t.Fatalf("missing resource for facet %s", facet)
		}
	}
	if err := bundle.Close(); err != nil {
		t.Fatal(err)
	}
	want := []string{
		"com.apple.coredevice.pasteboardservice",
		"com.apple.coredevice.devicecontrol",
		"com.apple.coredevice.hid.universalhidservice",
		"com.apple.coredevice.hid.universalhidservice",
		"com.apple.coredevice.hid.indigo",
		"com.apple.coredevice.appservice",
	}
	if !reflect.DeepEqual(closed, want) {
		t.Fatalf("closed = %v, want %v", closed, want)
	}
	if len(started) != len(RequiredFacets) {
		t.Fatalf("started = %v", started)
	}
	if err := bundle.Close(); err != nil {
		t.Fatal(err)
	}
}

func TestServiceBundleKeepsScreenshotConfiguredButDoesNotOpenItForReadiness(t *testing.T) {
	started := []string{}
	closed := []string{}
	bundle, err := NewServiceBundle(testServiceNames(), func(name string) (Closable, error) {
		started = append(started, name)
		return testCloser{id: name, closed: &closed}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	defer bundle.Close()
	if len(bundle.Facets) != len(RequiredFacets) {
		t.Fatalf("readiness facets = %v", bundle.Facets)
	}
	for _, name := range started {
		if name == testServiceNames()["screenshot"] {
			t.Fatalf("readiness opened screenshot service: %v", started)
		}
	}
}

func TestServiceBundleClosesAlreadyStartedResourcesOnFailure(t *testing.T) {
	closed := []string{}
	count := 0
	_, err := NewServiceBundle(testServiceNames(), func(name string) (Closable, error) {
		count++
		if count == 3 {
			return nil, errors.New("service unavailable")
		}
		return testCloser{id: name, closed: &closed}, nil
	})
	if err == nil {
		t.Fatal("expected service start failure")
	}
	if len(closed) != 2 {
		t.Fatalf("closed = %v", closed)
	}
}
