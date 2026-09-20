package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"syscall"
	"time"

	"pulsephone/GoHelpers/internal/coredevice"
	"pulsephone/GoHelpers/internal/helperapp"
	"pulsephone/GoHelpers/internal/processidentity"
	"pulsephone/GoHelpers/internal/protocol"
)

type stringList []string

type coreDeviceBackend interface {
	Execute(protocol.Message) (map[string]any, error)
	OpenStream(protocol.Message, time.Time) error
	SendFrame(protocol.Message, time.Time) error
	CloseStream(protocol.Message, time.Time) error
	Close() error
}

type coreDeviceBackendFactory func(runtimeEpoch, executorGeneration uint64, rawTransportUDID string, connectionEpoch uint64, serviceNames map[string]string) (coreDeviceBackend, error)

func (values *stringList) String() string { return fmt.Sprint([]string(*values)) }

func (values *stringList) Set(value string) error {
	*values = append(*values, value)
	return nil
}

func main() {
	_ = syscall.Setpgid(0, 0)
	os.Exit(run())
}

func run() int {
	lifetime := inheritedLifetime()
	if lifetime == nil {
		return 2
	}
	defer lifetime.Close()
	return runWithLifetime(os.Args[1:], os.Stdin, os.Stdout, os.Stderr, lifetime, processidentity.CurrentProcessStartIdentity, func(runtimeEpoch, executorGeneration uint64, rawTransportUDID string, connectionEpoch uint64, serviceNames map[string]string) (coreDeviceBackend, error) {
		return coredevice.NewBackendForRuntime(runtimeEpoch, executorGeneration, rawTransportUDID, connectionEpoch, serviceNames)
	})
}

func inheritedLifetime() *os.File {
	lifetime := os.NewFile(3, "runtime-lifetime")
	if lifetime == nil {
		return nil
	}
	if _, err := lifetime.Stat(); err != nil {
		_ = lifetime.Close()
		return nil
	}
	return lifetime
}

func runWith(arguments []string, stdin io.Reader, stdout io.Writer, stderr io.Writer, currentProcessStartIdentity func() (string, error), newBackend coreDeviceBackendFactory) int {
	return runWithLifetime(arguments, stdin, stdout, stderr, nil, currentProcessStartIdentity, newBackend)
}

func runWithLifetime(arguments []string, stdin io.Reader, stdout io.Writer, stderr io.Writer, lifetime io.Reader, currentProcessStartIdentity func() (string, error), newBackend coreDeviceBackendFactory) int {
	flags := flag.NewFlagSet("pulsephone-coredevice-helper", flag.ContinueOnError)
	flags.SetOutput(stderr)
	runtimeEpoch := flags.Uint64("runtime-epoch", 0, "runtime epoch")
	connectionEpoch := flags.Uint64("connection-epoch", 0, "connection epoch")
	executorGeneration := flags.Uint64("executor-generation", 0, "executor generation")
	rawTransportUDID := flags.String("raw-transport-udid", "", "transport UDID")
	helperBuildID := flags.String("helper-build-id", "", "helper build ID")
	manifestHash := flags.String("manifest-hash", "", "manifest hash")
	processStartIdentity := flags.String("process-start-identity", "", "process start identity")
	var facetServices stringList
	flags.Var(&facetServices, "facet-service", "facet=service mapping")
	if err := flags.Parse(arguments); err != nil {
		return 2
	}
	if flags.NArg() != 0 || *runtimeEpoch == 0 || *connectionEpoch == 0 || *executorGeneration == 0 || *rawTransportUDID == "" || *helperBuildID == "" || *manifestHash == "" {
		return 2
	}
	if _, err := coredevice.ParseFacetServiceMap(facetServices); err != nil {
		return 2
	}
	if *processStartIdentity == "" {
		identity, err := currentProcessStartIdentity()
		if err != nil {
			return 2
		}
		*processStartIdentity = identity
	}
	serviceNames, err := coredevice.ParseFacetServiceMap(facetServices)
	if err != nil {
		return 2
	}
	backend, err := newBackend(*runtimeEpoch, *executorGeneration, *rawTransportUDID, *connectionEpoch, serviceNames)
	if err != nil {
		return 2
	}
	return helperapp.RunSession(stdin, stdout, helperapp.Config{
		RuntimeEpoch:         *runtimeEpoch,
		ConnectionEpoch:      *connectionEpoch,
		ExecutorGeneration:   *executorGeneration,
		RawTransportUDID:     *rawTransportUDID,
		HelperBuildID:        *helperBuildID,
		HelperKind:           "coreDevice",
		ManifestHash:         *manifestHash,
		ProcessStartIdentity: *processStartIdentity,
		Lifetime:             lifetime,
		Facets:               []any{"appControl", "button", "hid", "keyboard", "orientation", "pasteboard", "screenshot"},
		AcceptedMonotonicNs:  coredevice.ContinuousMonotonicNanoseconds,
		HandleRequest: func(message protocol.Message) helperapp.RequestResult {
			value, requestErr := backend.Execute(message)
			if requestErr == nil {
				if operation, _ := message.Payload["backendPayload"].(map[string]any)["operation"].(string); operation == "warmGeneration" {
					value["executorGeneration"] = *executorGeneration
				}
			}
			return coreDeviceRequestResult(message, value, requestErr)
		},
		HandleStreamOpen: func(message protocol.Message) *helperapp.RequestResult {
			if streamErr := backend.OpenStream(message, time.Now().Add(60*time.Second)); streamErr != nil {
				return coreDeviceStreamFailure(streamErr)
			}
			return nil
		},
		HandleFrame: func(message protocol.Message) error {
			return backend.SendFrame(message, time.Now().Add(60*time.Second))
		},
		HandleStreamClose: func(message protocol.Message) *helperapp.RequestResult {
			if streamErr := backend.CloseStream(message, time.Now().Add(60*time.Second)); streamErr != nil {
				return coreDeviceStreamFailure(streamErr)
			}
			return nil
		},
		Close: func() error {
			return backend.Close()
		},
	})
}

func coreDeviceRequestResult(message protocol.Message, value map[string]any, requestErr error) helperapp.RequestResult {
	if requestErr != nil {
		return coreDeviceRequestFailure(requestErr)
	}
	resultValue := value
	exitAfterResult := false
	if value != nil {
		if _, exists := value["_pulsephoneRetireGenerationAfterResult"]; exists {
			resultValue = make(map[string]any, len(value)-1)
			for key, item := range value {
				if key == "_pulsephoneRetireGenerationAfterResult" {
					exitAfterResult = item == true
					continue
				}
				resultValue[key] = item
			}
		}
	}
	return helperapp.RequestResult{
		Value:           resultValue,
		CommitState:     coreDeviceRequestCommitState(message),
		ExitAfterResult: exitAfterResult,
	}
}

func coreDeviceRequestCommitState(message protocol.Message) string {
	backendPayload, _ := message.Payload["backendPayload"].(map[string]any)
	if backendPayload == nil {
		return "committed"
	}
	operation, _ := backendPayload["operation"].(string)
	if operation == "warmGeneration" || operation == "barrier" {
		return "notCommitted"
	}
	if _, personalized := backendPayload["catalogRevision"]; personalized {
		return "notCommitted"
	}
	return "committed"
}

func coreDeviceRequestFailure(err error) helperapp.RequestResult {
	productErr, ok := err.(*coredevice.ProductError)
	if !ok {
		return coreDeviceFailureResult(
			"developerServicesUnavailable",
			"startingDeviceServices",
			"",
			nil,
			false,
			false,
			true,
		)
	}
	phase := productErr.Phase
	if phase == "" {
		phase = "executingProductRoute"
	}
	return coreDeviceFailureResult(
		productErr.Code,
		phase,
		productErr.Stage,
		productErr.Details,
		productErr.Committed,
		productErr.OutcomeUnknown,
		productErr.RetireGeneration,
	)
}

func coreDeviceStreamFailure(err error) *helperapp.RequestResult {
	productErr, ok := err.(*coredevice.ProductError)
	if !ok {
		result := coreDeviceStreamFailureResult("developerServicesUnavailable", "executingProductRoute", false, false)
		return &result
	}
	phase := productErr.Phase
	if phase == "" {
		phase = productErr.Stage
	}
	if phase == "" {
		phase = "executingProductRoute"
	}
	result := coreDeviceStreamFailureResult(
		productErr.Code,
		phase,
		productErr.Committed,
		productErr.OutcomeUnknown,
	)
	return &result
}

func coreDeviceFailureResult(code, phase, stage string, additionalDetails map[string]any, committed, outcomeUnknown, exitAfterResult bool) helperapp.RequestResult {
	details := map[string]any{
		"phase":              phase,
		"preparationGroupID": coredevice.PreparationGroupID,
	}
	if stage != "" {
		details["stage"] = stage
	}
	for key, value := range additionalDetails {
		details[key] = value
	}
	return helperapp.RequestResult{
		ErrorCode:       code,
		ErrorDetails:    details,
		ErrorStage:      phase,
		Committed:       committed,
		OutcomeUnknown:  outcomeUnknown,
		ExitAfterResult: exitAfterResult,
	}
}

func coreDeviceStreamFailureResult(code, phase string, committed, outcomeUnknown bool) helperapp.RequestResult {
	return helperapp.RequestResult{
		ErrorCode: code,
		ErrorDetails: map[string]any{
			"phase":              phase,
			"preparationGroupID": coredevice.PreparationGroupID,
		},
		ErrorStage:     phase,
		Committed:      committed,
		OutcomeUnknown: outcomeUnknown,
	}
}
