package helperapp

import (
	"context"
	"os"
	"syscall"
	"time"
)

const RuntimeLossExitTimeout = 2 * time.Second

// RunOwned runs only at the process entry point: the caller must os.Exit with
// its result. On timeout the worker may still be blocked in device I/O; no
// other goroutine closes its backend or releases the generation lease early.
func RunOwned(input *os.File, run func(context.Context) int) int {
	var lifetimeStat, leaseStat syscall.Stat_t
	if syscall.Fstat(3, &lifetimeStat) != nil || lifetimeStat.Mode&syscall.S_IFMT != syscall.S_IFIFO ||
		syscall.Fstat(4, &leaseStat) != nil || leaseStat.Mode&syscall.S_IFMT != syscall.S_IFREG {
		return 2
	}
	// Keep the lifetime pipe blocking. EOF from the parent is the ownership
	// signal; the process entry point closes it during normal teardown.
	lifetime := os.NewFile(3, "runtime-lifetime")
	return runOwned(lifetime, input, RuntimeLossExitTimeout, run)
}

func runOwned(lifetime *os.File, input *os.File, timeout time.Duration, run func(context.Context) int) int {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	stopped := make(chan struct{})
	lost := make(chan struct{})
	go func() {
		var byte [1]byte
		// The lifetime channel carries no messages; data is also a protocol fault.
		_, _ = lifetime.Read(byte[:])
		select {
		case <-stopped:
			return
		default:
			cancel()
			close(lost)
		}
	}()
	defer func() {
		close(stopped)
		_ = lifetime.Close()
	}()
	result := make(chan int, 1)
	go func() { result <- run(ctx) }()
	select {
	case status := <-result:
		return status
	case <-lost:
		timer := time.NewTimer(timeout)
		defer timer.Stop()
		// Wake an idle protocol reader. Active device operations stay serial
		// with their own deferred cleanup and are bounded by the process timer.
		go func() { _ = input.Close() }()
		select {
		case status := <-result:
			return status
		case <-timer.C:
			return 2
		}
	}
}

func sessionCancelled(ctx context.Context) error {
	if ctx == nil {
		return nil
	}
	return ctx.Err()
}
