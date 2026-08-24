package processidentity

import (
	"encoding/binary"
	"fmt"
	"os"
	"syscall"
	"unsafe"
)

const (
	procInfoCallPIDInfo = 2
	procPIDTBSDInfo     = 3
	procBSDInfoSize     = 136
	startSecondsOffset  = 120
	startMicrosOffset   = 128
)

// CurrentProcessStartIdentity matches the proc_bsdinfo identity captured by
// the Swift supervisor and the legacy Python helper.
func CurrentProcessStartIdentity() (string, error) {
	return ProcessStartIdentity(os.Getpid())
}

func ProcessStartIdentity(pid int) (string, error) {
	if pid <= 0 {
		return "", fmt.Errorf("invalid pid")
	}
	var info [procBSDInfoSize]byte
	result, _, errno := syscall.Syscall6(
		syscall.SYS_PROC_INFO,
		procInfoCallPIDInfo,
		uintptr(pid),
		procPIDTBSDInfo,
		0,
		uintptr(unsafe.Pointer(&info[0])),
		uintptr(len(info)),
	)
	if errno != 0 {
		return "", fmt.Errorf("proc_pidinfo: %w", errno)
	}
	if result != procBSDInfoSize {
		return "", fmt.Errorf("proc_pidinfo size: %d", result)
	}
	return decodeStartIdentity(info[:])
}

func decodeStartIdentity(info []byte) (string, error) {
	if len(info) != procBSDInfoSize {
		return "", fmt.Errorf("proc_bsdinfo size: %d", len(info))
	}
	seconds := binary.LittleEndian.Uint64(info[startSecondsOffset : startSecondsOffset+8])
	microseconds := binary.LittleEndian.Uint64(info[startMicrosOffset : startMicrosOffset+8])
	if microseconds >= 1_000_000 {
		return "", fmt.Errorf("proc_bsdinfo microseconds: %d", microseconds)
	}
	return fmt.Sprintf("%d.%06d", seconds, microseconds), nil
}
