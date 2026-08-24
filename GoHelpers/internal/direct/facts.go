package direct

import (
	"bufio"
	"context"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"strconv"
	"syscall"
	"time"

	"pulsephone/GoHelpers/internal/protocol"
)

const (
	RequestLimit  = 16 * 1024
	ResponseLimit = 256 * 1024
	DeviceLimit   = 256
	WorkTimeout   = 2 * time.Second
	LockdownPort  = 62078
)

type Failure struct {
	Code    string
	Details map[string]any
}

func (e *Failure) Error() string { return e.Code }

type FactsBackend interface {
	EnumerateDevices() ([]map[string]any, error)
	Probe(deviceID uint64, rawTransportUDID string) (map[string]any, error)
	Close()
}

func DecodeFactsRequest(payload []byte) (map[string]any, error) {
	if len(payload) == 0 || len(payload) > RequestLimit {
		return nil, errors.New("request cap")
	}
	value, err := protocol.DecodeJSON(payload)
	if err != nil {
		return nil, err
	}
	request, ok := value.(map[string]any)
	if !ok {
		return nil, errors.New("request object")
	}
	if !sameKeys(request, "operation", "payload", "requestID", "schemaVersion") {
		return nil, errors.New("request fields")
	}
	if number(request["schemaVersion"]) != 1 {
		return nil, errors.New("schema version")
	}
	requestID, ok := request["requestID"].(string)
	if !ok || !isUUID(requestID) {
		return nil, errors.New("request id")
	}
	operation, ok := request["operation"].(string)
	if !ok {
		return nil, errors.New("operation")
	}
	requestPayload, ok := request["payload"].(map[string]any)
	if !ok {
		return nil, errors.New("payload")
	}
	switch operation {
	case "enumerate":
		if len(requestPayload) != 0 {
			return nil, errors.New("enumerate payload")
		}
	case "probe":
		if !sameKeys(requestPayload, "deviceID", "rawTransportUDID") {
			return nil, errors.New("probe payload")
		}
		if _, ok := uintValue(requestPayload["deviceID"]); !ok {
			return nil, errors.New("device id")
		}
		raw, ok := requestPayload["rawTransportUDID"].(string)
		if !ok || len(raw) < 1 || len(raw) > 256 {
			return nil, errors.New("raw transport udid")
		}
	default:
		return nil, errors.New("operation")
	}
	return request, nil
}

func ProcessFactsRequest(request map[string]any, backend FactsBackend, observedAt int64) (map[string]any, *Failure) {
	operation := request["operation"].(string)
	devices, err := backend.EnumerateDevices()
	if err != nil {
		return nil, factsBackendFailure(err)
	}
	if len(devices) > DeviceLimit {
		return nil, &Failure{Code: "deviceEnumerationLimitExceeded", Details: map[string]any{"actual": int64(len(devices)), "limit": int64(DeviceLimit)}}
	}
	if operation == "enumerate" {
		encodedDevices := make([]any, len(devices))
		for index, device := range devices {
			encodedDevices[index] = device
		}
		return map[string]any{"devices": encodedDevices, "observedAtMonotonicNs": observedAt}, nil
	}
	payload := request["payload"].(map[string]any)
	deviceID, _ := uintValue(payload["deviceID"])
	raw := payload["rawTransportUDID"].(string)
	matches := 0
	for _, device := range devices {
		candidateID, idOK := uintValue(device["deviceID"])
		candidateRaw, rawOK := device["rawTransportUDID"].(string)
		if idOK && rawOK && candidateID == deviceID && candidateRaw == raw {
			matches++
		}
	}
	if matches != 1 {
		return nil, &Failure{Code: "deviceNotFound"}
	}
	result, err := backend.Probe(deviceID, raw)
	if err != nil {
		return nil, factsBackendFailure(err)
	}
	return result, nil
}

func EncodeFactsResponse(request map[string]any, result map[string]any, failure *Failure) ([]byte, error) {
	response := map[string]any{
		"ok":            failure == nil,
		"operation":     request["operation"],
		"requestID":     request["requestID"],
		"schemaVersion": int64(1),
	}
	if failure == nil {
		response["result"] = result
	} else {
		errorValue := map[string]any{"code": failure.Code}
		if failure.Details != nil {
			errorValue["details"] = failure.Details
		}
		response["error"] = errorValue
	}
	encoded, err := protocol.EncodeValue(response, false)
	if err != nil {
		return nil, err
	}
	if len(encoded)+1 > ResponseLimit {
		return nil, &Failure{Code: "protocolViolation"}
	}
	return append(encoded, '\n'), nil
}

func RunFacts(stdin io.Reader, stdout io.Writer, backend FactsBackend) int {
	if backend == nil {
		backend = NewUSBMuxLockdownBackend(time.Now().Add(WorkTimeout))
	}
	return runFactsWithWatchdog(
		stdin,
		stdout,
		backend,
		WorkTimeout,
		func() {
			// The Swift caller places the helper in its own process group. Killing
			// that group is the last-resort cleanup for a backend that ignores Close.
			_ = syscall.Kill(-os.Getpid(), syscall.SIGKILL)
		},
	)
}

func runFactsWithWatchdog(
	stdin io.Reader,
	stdout io.Writer,
	backend FactsBackend,
	timeout time.Duration,
	killProcessGroup func(),
) int {
	result := make(chan int, 1)
	go func() {
		result <- runFactsBody(stdin, stdout, backend)
	}()
	timer := time.NewTimer(timeout)
	defer timer.Stop()
	select {
	case status := <-result:
		return status
	case <-timer.C:
		backend.Close()
		killProcessGroup()
		return 1
	}
}

func runFactsBody(stdin io.Reader, stdout io.Writer, backend FactsBackend) int {
	defer backend.Close()
	started := time.Now()
	reader := bufio.NewReaderSize(stdin, RequestLimit+1)
	input, err := readFactsLine(reader)
	if err != nil {
		return 2
	}
	if _, err := reader.ReadByte(); err != io.EOF {
		return 2
	}
	request, err := DecodeFactsRequest(input)
	if err != nil {
		return 2
	}
	result, failure := ProcessFactsRequest(request, backend, time.Since(started).Nanoseconds())
	response, err := EncodeFactsResponse(request, result, failure)
	if err != nil {
		return 2
	}
	if _, err := stdout.Write(response); err != nil {
		return 2
	}
	return 0
}

func readFactsLine(reader *bufio.Reader) ([]byte, error) {
	line := make([]byte, 0, RequestLimit)
	for {
		part, err := reader.ReadSlice('\n')
		line = append(line, part...)
		if len(line) > RequestLimit {
			return nil, errors.New("request line cap")
		}
		if err == nil {
			return line[:len(line)-1], nil
		}
		if err != bufio.ErrBufferFull {
			return nil, err
		}
	}
}

type USBMuxLockdownBackend struct {
	deadline time.Time
	tag      uint32
}

func NewUSBMuxLockdownBackend(deadline time.Time) *USBMuxLockdownBackend {
	return &USBMuxLockdownBackend{deadline: deadline, tag: 1}
}
func (b *USBMuxLockdownBackend) Close() {}

func (b *USBMuxLockdownBackend) EnumerateDevices() ([]map[string]any, error) {
	conn, err := b.connectUSBDMux()
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	if err := b.sendMux(conn, map[string]any{"ClientVersionString": "PulsePhone", "MessageType": "ListDevices", "ProgName": "PulsePhone", "kLibUSBMuxVersion": int64(3)}); err != nil {
		return nil, err
	}
	response, err := b.receiveMux(conn)
	if err != nil {
		return nil, err
	}
	list, ok := response["DeviceList"].([]any)
	if !ok {
		return []map[string]any{}, nil
	}
	devices := make([]map[string]any, 0, len(list))
	for _, item := range list {
		row, ok := item.(map[string]any)
		if !ok {
			return nil, &Failure{Code: "protocolViolation"}
		}
		properties, ok := row["Properties"].(map[string]any)
		if !ok {
			return nil, &Failure{Code: "protocolViolation"}
		}
		deviceID, ok := uintValue(row["DeviceID"])
		if !ok {
			return nil, &Failure{Code: "protocolViolation"}
		}
		serial, ok := properties["SerialNumber"].(string)
		if !ok || serial == "" {
			return nil, &Failure{Code: "protocolViolation"}
		}
		connectionType, _ := properties["ConnectionType"].(string)
		transport := "network"
		if connectionType == "USB" {
			transport = "usb"
		}
		devices = append(devices, map[string]any{"deviceID": deviceID, "rawTransportUDID": serial, "transport": transport})
	}
	return devices, nil
}

func (b *USBMuxLockdownBackend) Probe(deviceID uint64, rawTransportUDID string) (map[string]any, error) {
	conn, err := b.connectUSBDMux()
	if err != nil {
		return nil, err
	}
	defer conn.Close()
	if err := b.sendMux(conn, map[string]any{"ClientVersionString": "PulsePhone", "DeviceID": deviceID, "MessageType": "Connect", "PortNumber": int64(swap16(LockdownPort)), "ProgName": "PulsePhone", "kLibUSBMuxVersion": int64(3)}); err != nil {
		return nil, err
	}
	response, err := b.receiveMux(conn)
	if err != nil {
		return nil, err
	}
	if number(response["Number"]) != 0 {
		return nil, &Failure{Code: "deviceDisconnected"}
	}
	if _, err := b.lockdownRequest(conn, map[string]any{"Label": "PulsePhone", "Request": "QueryType"}); err != nil {
		return nil, err
	}
	facts := map[string]any{}
	for _, key := range []string{"BuildVersion", "DeviceClass", "DeviceName", "ProductType", "ProductVersion", "UniqueDeviceID"} {
		response, err := b.lockdownRequest(conn, map[string]any{"Key": key, "Label": "PulsePhone", "Request": "GetValue"})
		if err != nil {
			return nil, err
		}
		value, ok := response["Value"].(string)
		if !ok {
			return nil, &Failure{Code: "probeUnavailable"}
		}
		name := key[:1]
		name = string([]byte(name)[0]+32) + key[1:]
		facts[name] = value
	}
	if facts["uniqueDeviceID"] != rawTransportUDID {
		return nil, &Failure{Code: "deviceNotFound"}
	}
	return map[string]any{"condition": map[string]any{"connected": true, "locked": false, "trusted": true}, "facts": facts, "provenance": map[string]any{"autopair": false, "mode": "directHelperFacts", "queriedKeys": []any{"BuildVersion", "DeviceClass", "DeviceName", "ProductType", "ProductVersion", "UniqueDeviceID"}}}, nil
}

func (b *USBMuxLockdownBackend) connectUSBDMux() (net.Conn, error) {
	dialer := net.Dialer{Deadline: b.deadline}
	conn, err := dialer.Dial("unix", "/var/run/usbmuxd")
	if err != nil {
		return nil, &Failure{Code: "probeUnavailable"}
	}
	return conn, nil
}
func (b *USBMuxLockdownBackend) sendMux(conn net.Conn, payload map[string]any) error {
	body, err := encodePlist(payload)
	if err != nil {
		return err
	}
	header := make([]byte, 16)
	binary.LittleEndian.PutUint32(header[0:4], uint32(16+len(body)))
	binary.LittleEndian.PutUint32(header[4:8], 1)
	binary.LittleEndian.PutUint32(header[8:12], 8)
	binary.LittleEndian.PutUint32(header[12:16], b.tag)
	b.tag++
	return writeDeadline(conn, append(header, body...), b.deadline)
}
func (b *USBMuxLockdownBackend) receiveMux(conn net.Conn) (map[string]any, error) {
	header := make([]byte, 16)
	if err := readDeadline(conn, header, b.deadline); err != nil {
		return nil, &Failure{Code: "deviceDisconnected"}
	}
	length, version, message := binary.LittleEndian.Uint32(header[0:4]), binary.LittleEndian.Uint32(header[4:8]), binary.LittleEndian.Uint32(header[8:12])
	if version != 1 || message != 8 || length < 16 || length > 1024*1024 {
		return nil, &Failure{Code: "protocolViolation"}
	}
	body := make([]byte, int(length)-16)
	if err := readDeadline(conn, body, b.deadline); err != nil {
		return nil, &Failure{Code: "deviceDisconnected"}
	}
	result, err := decodePlist(body)
	if err != nil {
		return nil, &Failure{Code: "protocolViolation"}
	}
	return result, nil
}
func (b *USBMuxLockdownBackend) lockdownRequest(conn net.Conn, payload map[string]any) (map[string]any, error) {
	body, err := encodePlist(payload)
	if err != nil || len(body) > 64*1024 {
		return nil, &Failure{Code: "protocolViolation"}
	}
	header := make([]byte, 4)
	binary.BigEndian.PutUint32(header, uint32(len(body)))
	if err := writeDeadline(conn, append(header, body...), b.deadline); err != nil {
		return nil, &Failure{Code: "transportFailure"}
	}
	if err := readDeadline(conn, header, b.deadline); err != nil {
		return nil, &Failure{Code: "deviceDisconnected"}
	}
	length := binary.BigEndian.Uint32(header)
	if length == 0 || length > 64*1024 {
		return nil, &Failure{Code: "protocolViolation"}
	}
	responseBytes := make([]byte, int(length))
	if err := readDeadline(conn, responseBytes, b.deadline); err != nil {
		return nil, &Failure{Code: "deviceDisconnected"}
	}
	response, err := decodePlist(responseBytes)
	if err != nil {
		return nil, &Failure{Code: "protocolViolation"}
	}
	if errorValue, ok := response["Error"].(string); ok {
		switch errorValue {
		case "PasswordProtected", "DeviceLocked":
			return nil, &Failure{Code: "deviceLocked"}
		case "InvalidHostID", "PairingDialogResponsePending":
			return nil, &Failure{Code: "deviceNotTrusted"}
		default:
			return nil, &Failure{Code: "probeUnavailable"}
		}
	}
	return response, nil
}
func writeDeadline(conn net.Conn, data []byte, deadline time.Time) error {
	_ = conn.SetWriteDeadline(deadline)
	for len(data) > 0 {
		n, err := conn.Write(data)
		if err != nil {
			return err
		}
		if n == 0 {
			return io.ErrUnexpectedEOF
		}
		data = data[n:]
	}
	return nil
}
func readDeadline(conn net.Conn, data []byte, deadline time.Time) error {
	_ = conn.SetReadDeadline(deadline)
	_, err := io.ReadFull(conn, data)
	return err
}
func swap16(value uint16) uint16 { return value<<8 | value>>8 }
func sameKeys(value map[string]any, expected ...string) bool {
	if len(value) != len(expected) {
		return false
	}
	for _, key := range expected {
		if _, ok := value[key]; !ok {
			return false
		}
	}
	return true
}
func number(value any) int64 {
	switch value := value.(type) {
	case int64:
		return value
	case uint64:
		return int64(value)
	case int:
		return int64(value)
	default:
		return -1
	}
}
func uintValue(value any) (uint64, bool) {
	switch value := value.(type) {
	case int64:
		return uint64(value), value >= 0
	case uint64:
		return value, true
	default:
		return 0, false
	}
}
func isUUID(value string) bool {
	if len(value) != 36 {
		return false
	}
	for index, character := range value {
		if index == 8 || index == 13 || index == 18 || index == 23 {
			if character != '-' {
				return false
			}
		} else if !((character >= '0' && character <= '9') || (character >= 'a' && character <= 'f')) {
			return false
		}
	}
	return true
}
func asFailure(err error, fallback string) *Failure {
	var failure *Failure
	if errors.As(err, &failure) {
		return failure
	}
	return &Failure{Code: fallback}
}

func factsBackendFailure(err error) *Failure {
	var failure *Failure
	if errors.As(err, &failure) {
		return failure
	}
	if errors.Is(err, context.DeadlineExceeded) || os.IsTimeout(err) {
		return &Failure{Code: "probeUnavailable"}
	}
	var network *net.OpError
	if errors.As(err, &network) {
		return &Failure{Code: "probeUnavailable"}
	}
	var filesystem *os.PathError
	if errors.As(err, &filesystem) {
		return &Failure{Code: "probeUnavailable"}
	}
	return &Failure{Code: "internalFailure"}
}

var _ = fmt.Sprintf
var _ = strconv.IntSize
