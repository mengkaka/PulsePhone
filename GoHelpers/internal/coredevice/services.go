package coredevice

import (
	"errors"
	"sort"

	"pulsephone/GoHelpers/internal/protocol"
)

const PreparationGroupID = "prep.coredevice.v2"

var RequiredFacets = []string{
	"appControl",
	"button",
	"hid",
	"keyboard",
	"orientation",
	"pasteboard",
}

// SupportedFacets is the complete CoreDevice surface advertised to the
// Runtime. Screenshot remains configured here, but is opened per capture so a
// broken screenshot service cannot prevent control services from preparing.
var SupportedFacets = append(
	append([]string(nil), RequiredFacets...),
	"screenshot",
)

type ServiceStarter func(name string) (Closable, error)

type Closable interface {
	Close() error
}

type ServiceBundle struct {
	Facets          []string
	SurfaceRevision string
	resources       []Closable
	byFacet         map[string]Closable
	closed          bool
}

func ParseFacetServiceMap(values []string) (map[string]string, error) {
	result := make(map[string]string, len(values))
	for _, value := range values {
		facet, service, ok := splitServiceArgument(value)
		if !ok || !contains(SupportedFacets, facet) {
			return nil, errors.New("invalid facet service argument")
		}
		if _, exists := result[facet]; exists || !asciiIdentifier(service, 256) {
			return nil, errors.New("invalid facet service argument")
		}
		result[facet] = service
	}
	if len(result) != len(SupportedFacets) {
		return nil, errors.New("incomplete facet service map")
	}
	return result, nil
}

func NewServiceBundle(serviceNames map[string]string, start ServiceStarter) (*ServiceBundle, error) {
	if !validServiceNames(serviceNames) || start == nil {
		return nil, errors.New("invalid service surface")
	}
	names := make(map[string]any, len(serviceNames))
	for _, facet := range SupportedFacets {
		service, ok := serviceNames[facet]
		if !ok || !asciiIdentifier(service, 256) {
			return nil, errors.New("invalid service surface")
		}
		names[facet] = service
	}
	encoded, err := protocol.EncodeValue(names, false)
	if err != nil {
		return nil, err
	}
	revision, err := protocol.DomainSeparatedSHA256Hex("pulsephone.coredevice-service-surface.v1", encoded)
	if err != nil {
		return nil, err
	}
	ordered := append([]string(nil), RequiredFacets...)
	sort.Strings(ordered)
	resources := make([]Closable, 0, len(names))
	byFacet := make(map[string]Closable, len(ordered))
	for _, facet := range ordered {
		resource, err := start(serviceNames[facet])
		if err != nil {
			for index := len(resources) - 1; index >= 0; index-- {
				_ = resources[index].Close()
			}
			return nil, errors.New("facet service open failed")
		}
		if resource == nil {
			for index := len(resources) - 1; index >= 0; index-- {
				_ = resources[index].Close()
			}
			return nil, errors.New("nil facet service")
		}
		resources = append(resources, resource)
		byFacet[facet] = resource
	}
	return &ServiceBundle{Facets: ordered, SurfaceRevision: revision, resources: resources, byFacet: byFacet}, nil
}

func (bundle *ServiceBundle) ResourcesByFacet() map[string]Closable {
	if bundle == nil {
		return nil
	}
	result := make(map[string]Closable, len(bundle.byFacet))
	for facet, resource := range bundle.byFacet {
		result[facet] = resource
	}
	return result
}

func serviceSurfaceRevision(serviceNames map[string]string) string {
	names := make(map[string]any, len(serviceNames))
	for _, facet := range SupportedFacets {
		names[facet] = serviceNames[facet]
	}
	encoded, err := protocol.EncodeValue(names, false)
	if err != nil {
		return ""
	}
	revision, err := protocol.DomainSeparatedSHA256Hex("pulsephone.coredevice-service-surface.v1", encoded)
	if err != nil {
		return ""
	}
	return revision
}

func validServiceNames(serviceNames map[string]string) bool {
	if len(serviceNames) != len(SupportedFacets) {
		return false
	}
	for _, facet := range SupportedFacets {
		service, ok := serviceNames[facet]
		if !ok || !asciiIdentifier(service, 256) {
			return false
		}
	}
	return true
}

func (bundle *ServiceBundle) Close() error {
	if bundle == nil || bundle.closed {
		return nil
	}
	bundle.closed = true
	var first error
	for index := len(bundle.resources) - 1; index >= 0; index-- {
		if err := bundle.resources[index].Close(); err != nil && first == nil {
			first = err
		}
	}
	bundle.resources = nil
	bundle.byFacet = nil
	return first
}

func splitServiceArgument(value string) (string, string, bool) {
	for index := 0; index < len(value); index++ {
		if value[index] == '=' {
			if index == 0 || index+1 == len(value) {
				return "", "", false
			}
			return value[:index], value[index+1:], true
		}
	}
	return "", "", false
}

func asciiIdentifier(value string, maximum int) bool {
	if len(value) == 0 || len(value) > maximum {
		return false
	}
	for _, character := range []byte(value) {
		if character < 0x21 || character > 0x7e {
			return false
		}
	}
	return true
}

func contains(values []string, value string) bool {
	for _, candidate := range values {
		if candidate == value {
			return true
		}
	}
	return false
}
