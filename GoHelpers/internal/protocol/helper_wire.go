package protocol

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"regexp"
	"strings"

	"pulsephone/GoHelpers/internal/protocol/generated"
)

const MaxHelperLineBytes = 512 * 1024

// ReadHelperLine bounds input before JSON decoding so a peer cannot make a
// helper retain an unbounded unterminated line.
func ReadHelperLine(reader *bufio.Reader) ([]byte, error) {
	line := make([]byte, 0, MaxHelperLineBytes+1)
	for {
		part, err := reader.ReadSlice('\n')
		line = append(line, part...)
		if len(line) > MaxHelperLineBytes {
			if err == nil && len(line) == MaxHelperLineBytes+1 && line[len(line)-1] == '\n' {
				return line, nil
			}
			return nil, wireError("line cap")
		}
		if err == nil {
			return line, nil
		}
		if !errors.Is(err, bufio.ErrBufferFull) {
			return nil, err
		}
	}
}

type Direction string

const (
	RuntimeToHelper Direction = "runtimeToHelper"
	HelperToRuntime Direction = "helperToRuntime"
)

type Message struct {
	Type               string
	RuntimeEpoch       uint64
	ExecutorGeneration uint64
	MessageID          string
	RequestID          *string
	SessionID          *string
	DeliveryAttemptID  *string
	Payload            map[string]any
	Fields             map[string]any
}

var uuidPattern = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`)

var topLevelKeys = map[string]map[string]struct{}{
	"Accepted":           keys("executorGeneration", "messageID", "requestID", "runtimeEpoch", "schemaVersion", "type"),
	"Cancel":             keys("deliveryAttemptID", "executorGeneration", "messageID", "payload", "runtimeEpoch", "schemaVersion", "sessionID", "type"),
	"Close":              keys("deliveryAttemptID", "executorGeneration", "messageID", "payload", "runtimeEpoch", "schemaVersion", "sessionID", "type"),
	"Committed":          keys("executorGeneration", "messageID", "requestID", "runtimeEpoch", "schemaVersion", "type"),
	"DeviceDisconnected": keys("executorGeneration", "messageID", "payload", "runtimeEpoch", "schemaVersion", "type"),
	"Frame":              keys("deliveryAttemptID", "executorGeneration", "messageID", "payload", "runtimeEpoch", "schemaVersion", "sessionID", "type"),
	"FrameAccepted":      keys("deliveryAttemptID", "executorGeneration", "messageID", "payload", "runtimeEpoch", "schemaVersion", "sessionID", "type"),
	"Hello":              keys("executorGeneration", "helperBuildID", "helperKind", "manifestHash", "messageID", "processStartIdentity", "runtimeEpoch", "schemaVersion", "type"),
	"HelloAccepted":      keys("executorGeneration", "manifestHash", "messageID", "runtimeEpoch", "schemaVersion", "type"),
	"Progress":           keys("executorGeneration", "messageID", "payload", "requestID", "runtimeEpoch", "schemaVersion", "type"),
	"ProtocolError":      keys("executorGeneration", "messageID", "payload", "runtimeEpoch", "schemaVersion", "type"),
	"Ready":              keys("executorGeneration", "messageID", "payload", "runtimeEpoch", "schemaVersion", "type"),
	"Request":            keys("executorGeneration", "messageID", "payload", "requestID", "runtimeEpoch", "schemaVersion", "type"),
	"Result":             keys("executorGeneration", "messageID", "payload", "requestID", "runtimeEpoch", "schemaVersion", "type"),
	"Shutdown":           keys("executorGeneration", "messageID", "payload", "runtimeEpoch", "schemaVersion", "type"),
	"Started":            keys("executorGeneration", "messageID", "requestID", "runtimeEpoch", "schemaVersion", "type"),
	"StreamOpen":         keys("deliveryAttemptID", "executorGeneration", "messageID", "payload", "runtimeEpoch", "schemaVersion", "sessionID", "type"),
}

var runtimeToHelper = map[string]struct{}{
	"Cancel": {}, "Close": {}, "Frame": {}, "HelloAccepted": {}, "Request": {}, "Shutdown": {}, "StreamOpen": {},
}

var helperToRuntime = map[string]struct{}{
	"Accepted": {}, "Committed": {}, "DeviceDisconnected": {}, "FrameAccepted": {}, "Hello": {}, "Progress": {}, "Ready": {}, "Result": {}, "Started": {},
}

var fixedRoles = map[string]struct{}{
	"classic.image": {}, "classic.signature": {}, "personalized.buildManifest": {}, "personalized.image": {}, "personalized.trustCache": {},
}

var forbiddenKeys = map[string]struct{}{
	"absolutePath": {}, "clientPath": {}, "ecid": {}, "nonce": {}, "path": {}, "sourceURL": {}, "ticket": {}, "url": {},
}

func DecodeLine(raw []byte, direction Direction) (Message, error) {
	if len(raw) == 0 || raw[len(raw)-1] != '\n' || bytes.Count(raw, []byte{'\n'}) != 1 || bytes.Contains(raw[:len(raw)-1], []byte{'\r'}) {
		return Message{}, wireError("invalid line")
	}
	document := raw[:len(raw)-1]
	if len(document) == 0 || len(document) > MaxHelperLineBytes {
		return Message{}, wireError("line cap")
	}
	value, err := DecodeJSON(document)
	if err != nil {
		return Message{}, wireError("invalid json: %v", err)
	}
	fields, ok := value.(map[string]any)
	if !ok {
		return Message{}, wireError("object required")
	}
	messageType, ok := fields["type"].(string)
	if !ok || !generated.IsHelperMessageID(messageType) {
		return Message{}, wireError("unknown type")
	}
	maximum, ok := generated.HelperMessageMaximumEncodedBytes(messageType)
	if !ok || len(document) > maximum {
		return Message{}, wireError("line cap")
	}
	if !sameKeys(fields, topLevelKeys[messageType]) {
		return Message{}, wireError("shape")
	}
	if !allowedDirection(messageType, direction) {
		return Message{}, wireError("direction")
	}
	if numberUint(fields["schemaVersion"]) != 1 {
		return Message{}, wireError("schema")
	}
	runtimeEpoch, ok := numberUintOK(fields["runtimeEpoch"])
	if !ok {
		return Message{}, wireError("runtime epoch")
	}
	generation, ok := numberUintOK(fields["executorGeneration"])
	if !ok {
		return Message{}, wireError("executor generation")
	}
	messageID, ok := fields["messageID"].(string)
	if !ok || !uuidPattern.MatchString(messageID) {
		return Message{}, wireError("message id")
	}
	requestID, err := optionalUUID(fields["requestID"])
	if err != nil {
		return Message{}, err
	}
	sessionID, err := optionalUUID(fields["sessionID"])
	if err != nil {
		return Message{}, err
	}
	delivery, ok := fields["deliveryAttemptID"]
	if ok && delivery != nil {
		value, valid := delivery.(string)
		if !valid || !ascii(value, 128) {
			return Message{}, wireError("delivery")
		}
	}
	var payload map[string]any
	if rawPayload, exists := fields["payload"]; exists && rawPayload != nil {
		var valid bool
		payload, valid = rawPayload.(map[string]any)
		if !valid {
			return Message{}, wireError("payload")
		}
	}
	return Message{
		Type: messageType, RuntimeEpoch: runtimeEpoch, ExecutorGeneration: generation,
		MessageID: messageID, RequestID: requestID, SessionID: sessionID,
		DeliveryAttemptID: stringPointer(fields, "deliveryAttemptID"), Payload: payload, Fields: fields,
	}, nil
}

func EncodeLine(fields map[string]any, direction Direction) ([]byte, error) {
	encoded, err := EncodeValue(fields, false)
	if err != nil {
		return nil, err
	}
	encoded = append(encoded, '\n')
	if _, err := DecodeLine(encoded, direction); err != nil {
		return nil, err
	}
	return encoded, nil
}

type WireMachine struct {
	RuntimeEpoch       uint64
	ExecutorGeneration uint64
	State              string
	Seen               map[string]struct{}
	Requests           map[string]string
	TerminalRequests   map[string]struct{}
	Streams            map[string]*streamState
}

type streamState struct {
	Delivery string
	Next     uint64
	Pending  map[uint64]struct{}
	Closing  bool
}

func NewWireMachine(runtimeEpoch, executorGeneration uint64) *WireMachine {
	return &WireMachine{
		RuntimeEpoch: runtimeEpoch, ExecutorGeneration: executorGeneration, State: "preAccepted",
		Seen: map[string]struct{}{}, Requests: map[string]string{}, TerminalRequests: map[string]struct{}{}, Streams: map[string]*streamState{},
	}
}

func (m *WireMachine) Receive(message Message, direction Direction) error {
	if message.RuntimeEpoch != m.RuntimeEpoch || message.ExecutorGeneration != m.ExecutorGeneration {
		return wireError("generation")
	}
	if _, exists := m.Seen[message.MessageID]; exists {
		return wireError("duplicate message")
	}
	m.Seen[message.MessageID] = struct{}{}
	if message.Type == "ProtocolError" {
		m.State = "closed"
		return nil
	}
	switch m.State {
	case "preAccepted":
		if direction != HelperToRuntime || message.Type != "Hello" {
			return wireError("protocol")
		}
		m.State = "helloReceived"
		return nil
	case "helloReceived":
		if direction != RuntimeToHelper || message.Type != "HelloAccepted" {
			return wireError("protocol")
		}
		m.State = "accepted"
		return nil
	case "accepted":
		if direction != HelperToRuntime || message.Type != "Ready" {
			return wireError("protocol")
		}
		m.State = "ready"
		return nil
	case "ready":
	default:
		return wireError("closed")
	}
	if direction == RuntimeToHelper && message.Type == "Request" {
		return m.openRequest(message)
	}
	if direction == HelperToRuntime {
		switch message.Type {
		case "Accepted", "Started", "Committed":
			return m.advanceRequest(message, message.Type)
		case "Progress":
			phase := m.Requests[optionalValue(message.RequestID)]
			if phase != "started" && phase != "committed" {
				return wireError("protocol")
			}
			return nil
		case "Result":
			return m.completeRequest(message)
		case "FrameAccepted":
			return m.frameAccepted(message)
		}
	}
	if direction == RuntimeToHelper {
		switch message.Type {
		case "StreamOpen":
			return m.openStream(message)
		case "Frame":
			return m.frame(message)
		case "Close", "Cancel":
			stream, err := m.stream(message)
			if err != nil {
				return err
			}
			if stream.Closing {
				return wireError("protocol")
			}
			stream.Closing = true
			return nil
		}
	}
	if message.Type == "Shutdown" || message.Type == "DeviceDisconnected" {
		return nil
	}
	return wireError("state")
}

func (m *WireMachine) CompleteStreamCleanup(sessionID, delivery string) error {
	stream, exists := m.Streams[sessionID]
	if !exists || stream.Delivery != delivery || !stream.Closing || len(stream.Pending) != 0 {
		return wireError("protocol")
	}
	delete(m.Streams, sessionID)
	return nil
}

func (m *WireMachine) openRequest(message Message) error {
	requestID := optionalValue(message.RequestID)
	if requestID == "" {
		return wireError("protocol")
	}
	if _, exists := m.Requests[requestID]; exists {
		return wireError("protocol")
	}
	if message.Payload == nil {
		return wireError("protocol")
	}
	for _, key := range []string{"actionID", "backendPayload", "executorOperationID"} {
		if _, ok := message.Payload[key]; !ok {
			return wireError("protocol")
		}
	}
	backend, ok := message.Payload["backendPayload"].(map[string]any)
	if !ok {
		return wireError("protocol")
	}
	if hasDeveloperSupportField(backend) {
		if err := validateDeveloperSupport(backend); err != nil {
			return err
		}
	}
	m.Requests[requestID] = "requested"
	return nil
}

func hasDeveloperSupportField(value map[string]any) bool {
	for _, key := range []string{"assetContentManifestSHA256", "catalogCanonicalSHA256", "catalogRevision", "fileRoles"} {
		if _, exists := value[key]; exists {
			return true
		}
	}
	return false
}

func (m *WireMachine) advanceRequest(message Message, messageType string) error {
	requestID := optionalValue(message.RequestID)
	current, exists := m.Requests[requestID]
	if !exists {
		return wireError("protocol")
	}
	order := map[string]int{"requested": 0, "Accepted": 1, "Started": 2, "Committed": 3}
	if order[messageType] <= order[current] {
		return wireError("protocol")
	}
	phase := map[string]string{"Accepted": "accepted", "Started": "started", "Committed": "committed"}[messageType]
	m.Requests[requestID] = phase
	return nil
}

func (m *WireMachine) completeRequest(message Message) error {
	requestID := optionalValue(message.RequestID)
	current, exists := m.Requests[requestID]
	if !exists {
		return wireError("protocol")
	}
	if _, terminal := m.TerminalRequests[requestID]; terminal {
		return wireError("protocol")
	}
	if message.Payload == nil {
		return wireError("protocol")
	}
	result, ok := message.Payload["result"].(map[string]any)
	if !ok {
		return wireError("protocol")
	}
	if current == "committed" && stringValue(result["commitState"]) != "committed" {
		return wireError("protocol")
	}
	delete(m.Requests, requestID)
	m.TerminalRequests[requestID] = struct{}{}
	return nil
}

func (m *WireMachine) openStream(message Message) error {
	sessionID, delivery, err := streamIDs(message)
	if err != nil {
		return err
	}
	if _, exists := m.Streams[sessionID]; exists {
		return wireError("protocol")
	}
	m.Streams[sessionID] = &streamState{Delivery: delivery, Pending: map[uint64]struct{}{}}
	return nil
}

func (m *WireMachine) stream(message Message) (*streamState, error) {
	sessionID, delivery, err := streamIDs(message)
	if err != nil {
		return nil, err
	}
	stream, exists := m.Streams[sessionID]
	if !exists || stream.Delivery != delivery {
		return nil, wireError("protocol")
	}
	return stream, nil
}

func (m *WireMachine) frame(message Message) error {
	stream, err := m.stream(message)
	if err != nil {
		return err
	}
	if stream.Closing || message.Payload == nil {
		return wireError("protocol")
	}
	sequence, ok := numberUintOK(message.Payload["seq"])
	if !ok || sequence != stream.Next {
		return wireError("protocol")
	}
	stream.Pending[sequence] = struct{}{}
	stream.Next++
	return nil
}

func (m *WireMachine) frameAccepted(message Message) error {
	stream, err := m.stream(message)
	if err != nil {
		return err
	}
	if message.Payload == nil {
		return wireError("protocol")
	}
	sequence, ok := numberUintOK(message.Payload["seq"])
	if !ok {
		return wireError("protocol")
	}
	if _, exists := stream.Pending[sequence]; !exists {
		return wireError("protocol")
	}
	delete(stream.Pending, sequence)
	return nil
}

func validateDeveloperSupport(payload map[string]any) error {
	required := map[string]struct{}{"assetContentManifestSHA256": {}, "catalogCanonicalSHA256": {}, "catalogRevision": {}, "deviceContext": {}, "fileRoles": {}, "operation": {}, "preparationAttemptID": {}, "preparationGroupID": {}}
	if !sameKeys(payload, required) {
		return wireError("developer shape")
	}
	if !ascii(stringValue(payload["catalogRevision"]), 256) || !lowerHex64(stringValue(payload["catalogCanonicalSHA256"])) || !lowerHex64(stringValue(payload["assetContentManifestSHA256"])) {
		return wireError("catalog identity")
	}
	roles, ok := payload["fileRoles"].([]any)
	if !ok || len(roles) > 5 {
		return wireError("roles")
	}
	seen := map[string]struct{}{}
	for _, raw := range roles {
		role, valid := raw.(string)
		if !valid {
			return wireError("roles")
		}
		if _, exists := fixedRoles[role]; !exists {
			return wireError("roles")
		}
		if _, exists := seen[role]; exists {
			return wireError("roles")
		}
		seen[role] = struct{}{}
	}
	context, ok := payload["deviceContext"].(map[string]any)
	if !ok || forbidden(context) {
		return wireError("path material")
	}
	return nil
}

func lowerHex64(value string) bool {
	if len(value) != 64 {
		return false
	}
	for _, character := range []byte(value) {
		if !(character >= '0' && character <= '9') && !(character >= 'a' && character <= 'f') {
			return false
		}
	}
	return true
}

func forbidden(value any) bool {
	switch value := value.(type) {
	case map[string]any:
		for key, child := range value {
			if _, exists := forbiddenKeys[key]; exists || forbidden(child) {
				return true
			}
		}
	case []any:
		for _, child := range value {
			if forbidden(child) {
				return true
			}
		}
	case string:
		if strings.HasPrefix(value, "/") || strings.Contains(value, "://") || strings.ContainsRune(value, '\\') {
			return true
		}
		for _, segment := range strings.Split(value, "/") {
			if segment == ".." {
				return true
			}
		}
		return false
	}
	return false
}

func keys(values ...string) map[string]struct{} {
	result := make(map[string]struct{}, len(values))
	for _, value := range values {
		result[value] = struct{}{}
	}
	return result
}

func sameKeys(value map[string]any, expected map[string]struct{}) bool {
	if len(value) != len(expected) {
		return false
	}
	for key := range value {
		if _, exists := expected[key]; !exists {
			return false
		}
	}
	return true
}

func allowedDirection(messageType string, direction Direction) bool {
	if messageType == "ProtocolError" {
		return true
	}
	if direction == RuntimeToHelper {
		_, ok := runtimeToHelper[messageType]
		return ok
	}
	if direction == HelperToRuntime {
		_, ok := helperToRuntime[messageType]
		return ok
	}
	return false
}

func optionalUUID(value any) (*string, error) {
	if value == nil {
		return nil, nil
	}
	stringValue, ok := value.(string)
	if !ok || !uuidPattern.MatchString(stringValue) {
		return nil, wireError("uuid")
	}
	return &stringValue, nil
}

func stringPointer(fields map[string]any, key string) *string {
	value, ok := fields[key].(string)
	if !ok {
		return nil
	}
	return &value
}

func streamIDs(message Message) (string, string, error) {
	session := optionalValue(message.SessionID)
	delivery := optionalValue(message.DeliveryAttemptID)
	if session == "" || delivery == "" {
		return "", "", wireError("stream identity")
	}
	return session, delivery, nil
}

func optionalValue(value *string) string {
	if value == nil {
		return ""
	}
	return *value
}

func stringValue(value any) string { stringValue, _ := value.(string); return stringValue }

func numberUint(value any) uint64 { parsed, _ := numberUintOK(value); return parsed }

func numberUintOK(value any) (uint64, bool) {
	switch value := value.(type) {
	case int64:
		return uint64(value), value >= 0
	case uint64:
		return value, true
	case int:
		return uint64(value), value >= 0
	default:
		return 0, false
	}
}

func ascii(value string, maximum int) bool { return isASCII(value, true, maximum) }

func wireError(format string, values ...any) error {
	return fmt.Errorf("helper wire: "+format, values...)
}
