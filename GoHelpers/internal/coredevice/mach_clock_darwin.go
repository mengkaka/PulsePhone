//go:build darwin && arm64

package coredevice

import "math/bits"

type machTimebaseInfo struct {
	numer uint32
	denom uint32
}

//go:cgo_import_dynamic libc_mach_continuous_time mach_continuous_time "/usr/lib/libSystem.B.dylib"
//go:cgo_import_dynamic libc_mach_timebase_info mach_timebase_info "/usr/lib/libSystem.B.dylib"

func machContinuousTime() uint64
func getMachTimebaseInfo(info *machTimebaseInfo) int32

// ContinuousMonotonicNanoseconds returns a timestamp in the same clock domain
// as the Swift Runtime's SystemMonotonicClock. The HelperWire field is optional,
// so an unavailable or unrepresentable reading is omitted by the caller.
func ContinuousMonotonicNanoseconds() (uint64, bool) {
	var timebase machTimebaseInfo
	if getMachTimebaseInfo(&timebase) != 0 {
		return 0, false
	}
	return machTicksToNanoseconds(machContinuousTime(), timebase.numer, timebase.denom)
}

func machTicksToNanoseconds(ticks uint64, numer, denom uint32) (uint64, bool) {
	if numer == 0 || denom == 0 {
		return 0, false
	}
	denominator := uint64(denom)
	numerator := uint64(numer)
	wholeTicks := ticks / denominator
	wholeHigh, wholeNanoseconds := bits.Mul64(wholeTicks, numerator)
	if wholeHigh != 0 {
		return 0, false
	}
	remainderNanoseconds := ((ticks % denominator) * numerator) / denominator
	value, carry := bits.Add64(wholeNanoseconds, remainderNanoseconds, 0)
	return value, carry == 0
}
