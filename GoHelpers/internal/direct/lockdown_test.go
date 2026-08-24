package direct

import "testing"

func TestFindUSBDeviceRejectsNetworkTransport(t *testing.T) {
	devices := []map[string]any{
		{"deviceID": int64(7), "rawTransportUDID": "raw-device", "transport": "network"},
		{"deviceID": int64(8), "rawTransportUDID": "other-device", "transport": "usb"},
	}
	if _, ok := findUSBDevice(devices, "raw-device"); ok {
		t.Fatal("network device accepted as direct USB device")
	}
}

func TestFindUSBDeviceSelectsMatchingUSBRecord(t *testing.T) {
	devices := []map[string]any{
		{"deviceID": int64(7), "rawTransportUDID": "raw-device", "transport": "network"},
		{"deviceID": int64(9), "rawTransportUDID": "raw-device", "transport": "usb"},
	}
	deviceID, ok := findUSBDevice(devices, "raw-device")
	if !ok || deviceID != 9 {
		t.Fatalf("selected device = %d, %v", deviceID, ok)
	}
}
