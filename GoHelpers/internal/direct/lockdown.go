package direct

import (
	"crypto/tls"
	"encoding/binary"
	"fmt"
	"net"
	"time"
)

const (
	InstallationProxyService  = "com.apple.mobile.installation_proxy"
	MobileImageMounterService = "com.apple.mobile.mobile_image_mounter"
)

type Lockdown struct {
	deviceID   uint64
	udid       string
	deadline   time.Time
	conn       net.Conn
	pairRecord map[string]any
	sessionID  string
}

func OpenLockdown(udid string, deadline time.Time) (*Lockdown, error) {
	if len(udid) == 0 || len(udid) > 256 {
		return nil, &Failure{Code: "deviceNotTrusted"}
	}
	backend := NewUSBMuxLockdownBackend(deadline)
	devices, err := backend.EnumerateDevices()
	if err != nil {
		return nil, err
	}
	deviceID, found := findUSBDevice(devices, udid)
	if !found {
		return nil, &Failure{Code: "deviceNotFound"}
	}
	conn, err := backend.connectUSBDMux()
	if err != nil {
		return nil, err
	}
	lockdown := &Lockdown{deviceID: deviceID, udid: udid, deadline: deadline, conn: conn}
	if err := lockdown.sendMuxConnect(); err != nil {
		lockdown.Close()
		return nil, err
	}
	query, err := lockdown.request(map[string]any{"Label": "PulsePhone", "Request": "QueryType"})
	if err != nil {
		lockdown.Close()
		return nil, err
	}
	if query["Type"] != "com.apple.mobile.lockdown" {
		lockdown.Close()
		return nil, &Failure{Code: "protocolViolation"}
	}
	if err := lockdown.startSession(); err != nil {
		lockdown.Close()
		return nil, err
	}
	return lockdown, nil
}

func findUSBDevice(devices []map[string]any, rawTransportUDID string) (uint64, bool) {
	for _, device := range devices {
		if device["rawTransportUDID"] != rawTransportUDID || device["transport"] != "usb" {
			continue
		}
		if deviceID, ok := uintValue(device["deviceID"]); ok {
			return deviceID, true
		}
	}
	return 0, false
}

func (l *Lockdown) Close() {
	if l.conn != nil {
		if l.sessionID != "" {
			_, _ = l.request(map[string]any{
				"Label":     "PulsePhone",
				"Request":   "StopSession",
				"SessionID": l.sessionID,
			})
		}
		_ = l.conn.Close()
		l.conn = nil
		l.sessionID = ""
	}
}

func (l *Lockdown) startSession() error {
	pairRecord, err := readPairRecord(l.udid, l.deviceID, l.deadline)
	if err != nil {
		return err
	}
	hostID, hostOK := pairRecord["HostID"].(string)
	systemBUID, systemOK := pairRecord["SystemBUID"].(string)
	if !hostOK || hostID == "" || !systemOK || systemBUID == "" {
		return &Failure{Code: "deviceNotTrusted"}
	}
	response, err := l.requestPlain(map[string]any{
		"HostID":     hostID,
		"Label":      "PulsePhone",
		"Request":    "StartSession",
		"SystemBUID": systemBUID,
	})
	if err != nil {
		return err
	}
	sessionID, ok := response["SessionID"].(string)
	if !ok || sessionID == "" {
		return &Failure{Code: "protocolViolation"}
	}
	l.pairRecord = pairRecord
	l.sessionID = sessionID
	if enabled, _ := response["EnableSessionSSL"].(bool); enabled {
		if err := l.enableTLS(); err != nil {
			return &Failure{Code: "deviceNotTrusted"}
		}
	}
	return nil
}

func (l *Lockdown) enableTLS() error {
	certPEM, certOK := l.pairRecord["HostCertificate"].([]byte)
	keyPEM, keyOK := l.pairRecord["HostPrivateKey"].([]byte)
	if !certOK || !keyOK || len(certPEM) == 0 || len(keyPEM) == 0 {
		return fmt.Errorf("pairing record has no host key")
	}
	certificate, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return err
	}
	tlsConn := tls.Client(l.conn, &tls.Config{
		Certificates:       []tls.Certificate{certificate},
		InsecureSkipVerify: true, // lockdown authenticates the paired host certificate.
		MinVersion:         tls.VersionTLS12,
		MaxVersion:         tls.VersionTLS13,
		ServerName:         "",
	})
	_ = tlsConn.SetDeadline(l.deadline)
	if err := tlsConn.Handshake(); err != nil {
		return err
	}
	l.conn = tlsConn
	return nil
}

func (l *Lockdown) StartService(name string) (net.Conn, error) {
	response, err := l.request(map[string]any{"Label": "PulsePhone", "Request": "StartService", "Service": name})
	if err != nil {
		return nil, err
	}
	return l.connectStartedService(response, false)
}

// GetValue returns a single lockdownd value for an already authenticated
// session. Callers must validate the returned value's type before using it.
func (l *Lockdown) GetValue(key string) (any, error) {
	if key == "" || len(key) > 256 {
		return nil, &Failure{Code: "protocolViolation"}
	}
	response, err := l.request(map[string]any{
		"Key":     key,
		"Label":   "PulsePhone",
		"Request": "GetValue",
	})
	if err != nil {
		return nil, err
	}
	value, ok := response["Value"]
	if !ok {
		return nil, &Failure{Code: "protocolViolation"}
	}
	return value, nil
}

// StartServiceRaw performs the service TLS handshake when lockdownd requests
// it, then deliberately returns the underlying stream. A small set of legacy
// DTX services (notably AXAudit) use TLS only as a negotiation wrapper and
// expect their application protocol on the raw stream afterward.
func (l *Lockdown) StartServiceRaw(name string) (net.Conn, error) {
	response, err := l.request(map[string]any{"Label": "PulsePhone", "Request": "StartService", "Service": name})
	if err != nil {
		return nil, err
	}
	return l.connectStartedService(response, true)
}

func (l *Lockdown) connectStartedService(response map[string]any, stripSSL bool) (net.Conn, error) {
	port, ok := uintValue(response["Port"])
	if !ok || port == 0 || port > 65535 {
		return nil, &Failure{Code: "developerServicesUnavailable"}
	}
	conn, err := connectDevicePort(l.deviceID, uint16(port), l.deadline)
	if err != nil {
		return nil, &Failure{Code: "transportFailure"}
	}
	if enabled, _ := response["EnableServiceSSL"].(bool); enabled {
		certPEM, certOK := l.pairRecord["HostCertificate"].([]byte)
		keyPEM, keyOK := l.pairRecord["HostPrivateKey"].([]byte)
		if !certOK || !keyOK || len(certPEM) == 0 || len(keyPEM) == 0 {
			_ = conn.Close()
			return nil, &Failure{Code: "deviceNotTrusted"}
		}
		certificate, certErr := tls.X509KeyPair(certPEM, keyPEM)
		if certErr != nil {
			_ = conn.Close()
			return nil, &Failure{Code: "deviceNotTrusted"}
		}
		tlsConn := tls.Client(conn, &tls.Config{
			Certificates:       []tls.Certificate{certificate},
			InsecureSkipVerify: true,
			MinVersion:         tls.VersionTLS12,
			MaxVersion:         tls.VersionTLS13,
			ServerName:         "",
		})
		_ = tlsConn.SetDeadline(l.deadline)
		if err := tlsConn.Handshake(); err != nil {
			_ = conn.Close()
			return nil, &Failure{Code: "transportFailure"}
		}
		if stripSSL {
			return tlsConn.NetConn(), nil
		}
		conn = tlsConn
	}
	return conn, nil
}

func (l *Lockdown) sendMuxConnect() error {
	client := &USBMuxLockdownBackend{deadline: l.deadline, tag: 1}
	if err := client.sendMux(l.conn, map[string]any{"ClientVersionString": "PulsePhone", "DeviceID": l.deviceID, "MessageType": "Connect", "PortNumber": int64(swap16(LockdownPort)), "ProgName": "PulsePhone", "kLibUSBMuxVersion": int64(3)}); err != nil {
		return &Failure{Code: "transportFailure"}
	}
	response, err := client.receiveMux(l.conn)
	if err != nil {
		return err
	}
	if number(response["Number"]) != 0 {
		return &Failure{Code: "deviceDisconnected"}
	}
	return nil
}

func (l *Lockdown) request(payload map[string]any) (map[string]any, error) {
	return l.requestPlain(payload)
}

func (l *Lockdown) requestPlain(payload map[string]any) (map[string]any, error) {
	if l.conn == nil {
		return nil, fmt.Errorf("lockdown closed")
	}
	body, err := encodePlist(payload)
	if err != nil || len(body) > 64*1024 {
		return nil, &Failure{Code: "protocolViolation"}
	}
	header := make([]byte, 4)
	binary.BigEndian.PutUint32(header, uint32(len(body)))
	if err := writeDeadline(l.conn, append(header, body...), l.deadline); err != nil {
		return nil, &Failure{Code: "transportFailure"}
	}
	if err := readDeadline(l.conn, header, l.deadline); err != nil {
		return nil, &Failure{Code: "deviceDisconnected"}
	}
	length := binary.BigEndian.Uint32(header)
	if length == 0 || length > 64*1024 {
		return nil, &Failure{Code: "protocolViolation"}
	}
	data := make([]byte, int(length))
	if err := readDeadline(l.conn, data, l.deadline); err != nil {
		return nil, &Failure{Code: "deviceDisconnected"}
	}
	response, err := decodePlist(data)
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
			return nil, &Failure{Code: "developerServicesUnavailable"}
		}
	}
	return response, nil
}

func connectDevicePort(deviceID uint64, port uint16, deadline time.Time) (net.Conn, error) {
	dialer := net.Dialer{Deadline: deadline}
	conn, err := dialer.Dial("unix", "/var/run/usbmuxd")
	if err != nil {
		return nil, err
	}
	client := &USBMuxLockdownBackend{deadline: deadline, tag: 1}
	if err := client.sendMux(conn, map[string]any{
		"ClientVersionString": "PulsePhone",
		"DeviceID":            deviceID,
		"MessageType":         "Connect",
		"PortNumber":          int64(swap16(port)),
		"ProgName":            "PulsePhone",
		"kLibUSBMuxVersion":   int64(3),
	}); err != nil {
		_ = conn.Close()
		return nil, err
	}
	response, err := client.receiveMux(conn)
	if err != nil {
		_ = conn.Close()
		return nil, err
	}
	if number(response["Number"]) != 0 {
		_ = conn.Close()
		return nil, &Failure{Code: "deviceDisconnected"}
	}
	return conn, nil
}

func readPairRecord(udid string, deviceID uint64, deadline time.Time) (map[string]any, error) {
	dialer := net.Dialer{Deadline: deadline}
	conn, err := dialer.Dial("unix", "/var/run/usbmuxd")
	if err != nil {
		return nil, &Failure{Code: "deviceNotTrusted"}
	}
	defer conn.Close()
	client := &USBMuxLockdownBackend{deadline: deadline, tag: 1}
	if err := client.sendMux(conn, map[string]any{
		"MessageType":  "ReadPairRecord",
		"PairRecordID": udid,
		"DeviceID":     deviceID,
	}); err != nil {
		return nil, &Failure{Code: "deviceNotTrusted"}
	}
	response, err := client.receiveMux(conn)
	if err != nil {
		return nil, &Failure{Code: "deviceNotTrusted"}
	}
	if responseNumber, exists := response["Number"]; exists && number(responseNumber) != 0 {
		return nil, &Failure{Code: "deviceNotTrusted"}
	}
	payload, ok := response["PairRecordData"].([]byte)
	if !ok || len(payload) == 0 {
		return nil, &Failure{Code: "deviceNotTrusted"}
	}
	record, err := decodePlist(payload)
	if err != nil {
		return nil, &Failure{Code: "protocolViolation"}
	}
	return record, nil
}

type plistService struct {
	conn     net.Conn
	deadline time.Time
}

// PlistService is the framed plist transport shared by lockdown and RSD
// developer services. The wire is intentionally exposed as a small adapter so
// CoreDevice can reuse the parser without importing a second plist stack.
type PlistService struct {
	conn     net.Conn
	deadline time.Time
}

func NewPlistService(conn net.Conn, deadline time.Time) *PlistService {
	return &PlistService{conn: conn, deadline: deadline}
}

func (s *PlistService) Close() error {
	if s == nil || s.conn == nil {
		return nil
	}
	err := s.conn.Close()
	s.conn = nil
	return err
}

func (s *PlistService) SendValue(value any) error {
	if s == nil || s.conn == nil {
		return fmt.Errorf("plist service closed")
	}
	body, err := encodePlistDocument(value)
	if err != nil || len(body) > 1024*1024 {
		return &Failure{Code: "protocolViolation"}
	}
	header := make([]byte, 4)
	binary.BigEndian.PutUint32(header, uint32(len(body)))
	return writeDeadline(s.conn, append(header, body...), s.deadline)
}

// WriteRaw writes a payload that follows a plist command on services such as
// mobile_image_mounter. The caller owns chunking and must keep the payload
// bounded by the negotiated operation contract.
func (s *PlistService) WriteRaw(data []byte) error {
	if s == nil || s.conn == nil {
		return fmt.Errorf("plist service closed")
	}
	return writeDeadline(s.conn, data, s.deadline)
}

func (s *PlistService) ReceiveValue(maximum int) (any, error) {
	if s == nil || s.conn == nil {
		return nil, fmt.Errorf("plist service closed")
	}
	header := make([]byte, 4)
	if err := readDeadline(s.conn, header, s.deadline); err != nil {
		return nil, &Failure{Code: "transportFailure"}
	}
	length := binary.BigEndian.Uint32(header)
	if length == 0 || maximum <= 0 || length > uint32(maximum) {
		return nil, &Failure{Code: "protocolViolation"}
	}
	data := make([]byte, int(length))
	if err := readDeadline(s.conn, data, s.deadline); err != nil {
		return nil, &Failure{Code: "transportFailure"}
	}
	value, err := decodePlistValue(data)
	if err != nil {
		return nil, &Failure{Code: "protocolViolation"}
	}
	return value, nil
}

func (s *PlistService) SendReceive(value any, maximum int) (any, error) {
	if err := s.SendValue(value); err != nil {
		return nil, err
	}
	return s.ReceiveValue(maximum)
}

func newPlistService(conn net.Conn, deadline time.Time) *plistService {
	return &plistService{conn: conn, deadline: deadline}
}
func (s *plistService) close() {
	if s.conn != nil {
		_ = s.conn.Close()
		s.conn = nil
	}
}
func (s *plistService) setDeadline(deadline time.Time) {
	s.deadline = deadline
}
func (s *plistService) send(value map[string]any) error {
	return s.sendValue(value)
}

func (s *plistService) sendValue(value any) error {
	body, err := encodePlistDocument(value)
	if err != nil || len(body) > 1024*1024 {
		return &Failure{Code: "protocolViolation"}
	}
	header := make([]byte, 4)
	binary.BigEndian.PutUint32(header, uint32(len(body)))
	return writeDeadline(s.conn, append(header, body...), s.deadline)
}
func (s *plistService) receive(maximum int) (map[string]any, error) {
	value, err := s.receiveValue(maximum)
	if err != nil {
		return nil, err
	}
	result, ok := value.(map[string]any)
	if !ok {
		return nil, &Failure{Code: "protocolViolation"}
	}
	return result, nil
}

func (s *plistService) receiveValue(maximum int) (any, error) {
	header := make([]byte, 4)
	if err := readDeadline(s.conn, header, s.deadline); err != nil {
		return nil, &Failure{Code: "transportFailure"}
	}
	length := binary.BigEndian.Uint32(header)
	if length == 0 || length > uint32(maximum) {
		return nil, &Failure{Code: "protocolViolation"}
	}
	data := make([]byte, int(length))
	if err := readDeadline(s.conn, data, s.deadline); err != nil {
		return nil, &Failure{Code: "transportFailure"}
	}
	value, err := decodePlistValue(data)
	if err != nil {
		return nil, &Failure{Code: "protocolViolation"}
	}
	return value, nil
}
