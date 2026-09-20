package helperapp

import (
	"bufio"
	"context"
	"crypto/rand"
	"fmt"
	"io"
	"os"
	"sync"

	"pulsephone/GoHelpers/internal/protocol"
)

type Config struct {
	RuntimeEpoch         uint64
	ConnectionEpoch      uint64
	ExecutorGeneration   uint64
	RawTransportUDID     string
	HelperBuildID        string
	HelperKind           string
	ManifestHash         string
	ProcessStartIdentity string
	Facets               []any
	AcceptedMonotonicNs  func() (uint64, bool)
	HandleRequest        func(protocol.Message) RequestResult
	HandleStreamOpen     func(protocol.Message) *RequestResult
	HandleFrame          func(protocol.Message) error
	HandleStreamClose    func(protocol.Message) *RequestResult
	Close                func() error
	Context              context.Context
}

type RequestResult struct {
	Value           map[string]any
	CommitState     string
	Outcome         string
	Fallback        string
	ErrorCode       string
	ErrorStage      string
	ErrorDetails    map[string]any
	Committed       bool
	OutcomeUnknown  bool
	ExitAfterResult bool
}

// RunSession owns the CoreDevice helper process lifecycle. Capability handlers
// are deliberately kept behind this boundary while protocol implementation
// and device evidence are completed.
func RunSession(stdin io.Reader, stdout io.Writer, config Config) (status int) {
	var closeOnce sync.Once
	var closeErr error
	closeSession := func() {
		closeOnce.Do(func() {
			if config.Close != nil {
				closeErr = config.Close()
			}
		})
	}
	defer func() {
		closeSession()
		if closeErr != nil {
			status = 2
		}
	}()

	machine := protocol.NewWireMachine(config.RuntimeEpoch, config.ExecutorGeneration)
	send := func(fields map[string]any, direction protocol.Direction) error {
		if err := sessionCancelled(config.Context); err != nil {
			return err
		}
		raw, err := protocol.EncodeLine(fields, direction)
		if err != nil {
			return err
		}
		message, err := protocol.DecodeLine(raw, direction)
		if err != nil {
			return err
		}
		if err := machine.Receive(message, direction); err != nil {
			return err
		}
		_, err = stdout.Write(raw)
		return err
	}
	base := func(kind string) map[string]any {
		return map[string]any{
			"executorGeneration": config.ExecutorGeneration,
			"messageID":          newUUID(),
			"runtimeEpoch":       config.RuntimeEpoch,
			"schemaVersion":      int64(1),
			"type":               kind,
		}
	}
	hello := base("Hello")
	hello["helperBuildID"] = config.HelperBuildID
	hello["helperKind"] = config.HelperKind
	hello["manifestHash"] = config.ManifestHash
	hello["processStartIdentity"] = config.ProcessStartIdentity
	if err := send(hello, protocol.HelperToRuntime); err != nil {
		return 2
	}
	reader := bufio.NewReaderSize(stdin, protocol.MaxHelperLineBytes+1)
	var pendingBarrierResult *RequestResult
	receive := func() (protocol.Message, error) {
		if err := sessionCancelled(config.Context); err != nil {
			return protocol.Message{}, err
		}
		raw, err := protocol.ReadHelperLine(reader)
		if err != nil {
			return protocol.Message{}, err
		}
		if err := sessionCancelled(config.Context); err != nil {
			return protocol.Message{}, err
		}
		message, err := protocol.DecodeLine(raw, protocol.RuntimeToHelper)
		if err != nil {
			return protocol.Message{}, err
		}
		if err := machine.Receive(message, protocol.RuntimeToHelper); err != nil {
			return protocol.Message{}, err
		}
		return message, nil
	}
	accepted, err := receive()
	if err != nil || accepted.Type != "HelloAccepted" || accepted.Fields["manifestHash"] != config.ManifestHash {
		return 2
	}
	ready := base("Ready")
	ready["payload"] = map[string]any{"facets": config.Facets}
	if err := send(ready, protocol.HelperToRuntime); err != nil {
		return 2
	}
	for {
		message, err := receive()
		if err == io.EOF {
			return 0
		}
		if err != nil {
			return 2
		}
		switch message.Type {
		case "Shutdown":
			return 0
		case "StreamOpen":
			if config.HandleStreamOpen != nil {
				if failure := config.HandleStreamOpen(message); failure != nil {
					pendingBarrierResult = failure
				}
			}
			continue
		case "Frame":
			if config.HandleFrame != nil {
				if err := config.HandleFrame(message); err != nil {
					return 2
				}
			}
			response := base("FrameAccepted")
			response["deliveryAttemptID"] = optionalString(message.DeliveryAttemptID)
			response["sessionID"] = optionalString(message.SessionID)
			payload := map[string]any{"interactionID": message.Payload["interactionID"], "seq": message.Payload["seq"]}
			if config.AcceptedMonotonicNs != nil {
				if acceptedMonotonicNs, available := config.AcceptedMonotonicNs(); available {
					payload["acceptedMonotonicNs"] = acceptedMonotonicNs
				}
			}
			response["payload"] = payload
			if err := send(response, protocol.HelperToRuntime); err != nil {
				return 2
			}
		case "Close", "Cancel":
			if config.HandleStreamClose != nil {
				if failure := config.HandleStreamClose(message); failure != nil {
					pendingBarrierResult = failure
					continue
				}
			}
			if err := machine.CompleteStreamCleanup(optionalString(message.SessionID), optionalString(message.DeliveryAttemptID)); err != nil {
				return 2
			}
		case "Request":
			if message.RequestID == nil {
				return 2
			}
			accepted := base("Accepted")
			accepted["requestID"] = *message.RequestID
			if err := send(accepted, protocol.HelperToRuntime); err != nil {
				return 2
			}
			started := base("Started")
			started["requestID"] = *message.RequestID
			if err := send(started, protocol.HelperToRuntime); err != nil {
				return 2
			}
			result := base("Result")
			result["requestID"] = *message.RequestID
			requestResult := RequestResult{ErrorCode: "capabilityUnavailable", ErrorStage: "executingProductRoute"}
			backendPayload, _ := message.Payload["backendPayload"].(map[string]any)
			if backendPayload != nil && backendPayload["operation"] == "barrier" && pendingBarrierResult != nil {
				requestResult = *pendingBarrierResult
				pendingBarrierResult = nil
			} else if config.HandleRequest != nil {
				requestResult = config.HandleRequest(message)
			}
			result["payload"] = map[string]any{"fallbackDisposition": valueOr(requestResult.Fallback, "terminal"), "result": requestResult.toValue()}
			if err := send(result, protocol.HelperToRuntime); err != nil {
				return 2
			}
			if requestResult.ExitAfterResult {
				return 1
			}
		case "ProtocolError":
			return 2
		}
	}
}

func (result RequestResult) toValue() map[string]any {
	if result.ErrorCode != "" {
		commitState := result.CommitState
		if commitState == "" {
			if result.Committed {
				commitState = "committed"
			} else {
				commitState = "notCommitted"
			}
		}
		outcome := result.Outcome
		if outcome == "" {
			if result.OutcomeUnknown {
				outcome = "outcomeUnknown"
			} else {
				outcome = "failed"
			}
		}
		details := cloneDetails(result.ErrorDetails)
		if result.ErrorStage != "" && details["phase"] == nil {
			details["phase"] = result.ErrorStage
		}
		return map[string]any{"commitState": commitState, "error": map[string]any{"code": result.ErrorCode, "details": details}, "outcome": outcome}
	}
	commitState := result.CommitState
	if commitState == "" {
		commitState = "committed"
	}
	outcome := result.Outcome
	if outcome == "" {
		outcome = "succeeded"
	}
	value := result.Value
	if value == nil {
		value = map[string]any{}
	}
	return map[string]any{"commitState": commitState, "outcome": outcome, "value": value}
}

func cloneDetails(value map[string]any) map[string]any {
	if len(value) == 0 {
		return map[string]any{}
	}
	clone := make(map[string]any, len(value))
	for key, item := range value {
		clone[key] = item
	}
	return clone
}

func valueOr(value, fallback string) string {
	if value == "" {
		return fallback
	}
	return value
}

// RunUnsupportedSession remains as a source-compatible test helper during the
// migration. Production entry points use RunSession.
func RunUnsupportedSession(stdin io.Reader, stdout io.Writer, config Config) int {
	return RunSession(stdin, stdout, config)
}

func newUUID() string {
	var value [16]byte
	if _, err := rand.Read(value[:]); err != nil {
		return "00000000-0000-4000-8000-000000000000"
	}
	value[6] = (value[6] & 0x0f) | 0x40
	value[8] = (value[8] & 0x3f) | 0x80
	return fmt.Sprintf("%08x-%04x-%04x-%04x-%012x", value[0:4], value[4:6], value[6:8], value[8:10], value[10:16])
}

func optionalString(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}

var _ = os.Getpid
