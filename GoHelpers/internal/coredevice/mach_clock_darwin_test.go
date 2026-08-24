//go:build darwin && arm64

package coredevice

import "testing"

func TestMachTicksToNanosecondsMatchesSwiftAndPythonFormula(t *testing.T) {
	value, ok := machTicksToNanoseconds(7, 125, 3)
	if !ok || value != 291 {
		t.Fatalf("value=%d available=%t", value, ok)
	}
	if _, ok := machTicksToNanoseconds(1, 0, 1); ok {
		t.Fatal("zero numerator accepted")
	}
	if _, ok := machTicksToNanoseconds(1, 1, 0); ok {
		t.Fatal("zero denominator accepted")
	}
	if _, ok := machTicksToNanoseconds(^uint64(0), ^uint32(0), 1); ok {
		t.Fatal("overflow accepted")
	}
}

func TestContinuousMonotonicNanosecondsIsAvailableAndIncreasing(t *testing.T) {
	first, ok := ContinuousMonotonicNanoseconds()
	if !ok || first == 0 {
		t.Fatalf("first=%d available=%t", first, ok)
	}
	second, ok := ContinuousMonotonicNanoseconds()
	if !ok || second < first {
		t.Fatalf("first=%d second=%d available=%t", first, second, ok)
	}
}
