package helperapp

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"pulsephone/GoHelpers/internal/protocol"
)

func TestOwnedSessionPreservesExitStatus(t *testing.T) {
	for _, status := range []int{0, 1, 2} {
		reader, writer := testPipe(t)
		input, _ := testPipe(t)
		got := runOwned(reader, input, time.Second, func(context.Context) int { return status })
		if got != status {
			t.Fatalf("status = %d, want %d", got, status)
		}
		_ = writer.Close()
	}
}

func TestOwnedSessionCleanupWaitsForActiveRequest(t *testing.T) {
	lifetime, owner := testPipe(t)
	input, commands := testPipe(t)
	started, cancelled, release, cleaned := make(chan struct{}), make(chan struct{}), make(chan struct{}), make(chan struct{})
	result := make(chan int, 1)
	var output bytes.Buffer
	go func() {
		result <- runOwned(lifetime, input, time.Second, func(ctx context.Context) int {
			config := sessionTestConfig(func() error { close(cleaned); return nil })
			config.Context = ctx
			config.HandleRequest = func(protocol.Message) RequestResult {
				close(started)
				<-ctx.Done()
				close(cancelled)
				<-release
				return RequestResult{}
			}
			return RunSession(input, &output, config)
		})
	}()
	writeSessionMessage(t, commands, helloAcceptedMessage())
	writeSessionMessage(t, commands, sessionBarrierRequest("00000000-0000-0000-0000-000000000002"))
	waitTestSignal(t, started)
	_ = owner.Close()
	waitTestSignal(t, cancelled)
	select {
	case <-cleaned:
		t.Fatal("cleanup ran concurrently with the active request")
	default:
	}
	close(release)
	select {
	case status := <-result:
		if status != 2 {
			t.Fatalf("cancelled request status = %d", status)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("session did not return")
	}
	waitTestSignal(t, cleaned)
	if bytes.Contains(output.Bytes(), []byte(`"type":"Result"`)) {
		t.Fatal("published a result after owner loss")
	}
}

// The child deliberately wedges execution or cleanup. Only its process entry
// point can terminate the worker and release the inherited lease.
func TestOwnedProcessChild(t *testing.T) {
	mode := os.Getenv("PULSEPHONE_LIFETIME_CHILD")
	if mode == "" {
		t.Skip("subprocess fixture")
	}
	if mode == "owner" {
		lifetime, writer, err := os.Pipe()
		if err != nil {
			os.Exit(8)
		}
		input, commands, err := os.Pipe()
		if err != nil {
			os.Exit(8)
		}
		lease := os.NewFile(4, "lease")
		child := exec.Command(os.Args[0], "-test.run=^TestOwnedProcessChild$")
		child.Env = append(os.Environ(), "PULSEPHONE_LIFETIME_CHILD=blocked")
		child.Stdin = input
		child.ExtraFiles = []*os.File{lifetime, lease}
		output, err := child.StdoutPipe()
		if err != nil || child.Start() != nil {
			os.Exit(8)
		}
		_ = lifetime.Close()
		_ = lease.Close()
		if _, err = bufio.NewReader(output).ReadString('\n'); err != nil {
			os.Exit(8)
		}
		fmt.Println(child.Process.Pid)
		// Keep only this simulated Runtime's writer ends alive until SIGKILL.
		defer writer.Close()
		defer commands.Close()
		select {}
	}
	os.Exit(RunOwned(os.Stdin, func(ctx context.Context) int {
		fmt.Println("ready")
		switch mode {
		case "blocked":
			select {}
		case "cleanup":
			defer func() { select {} }()
			<-ctx.Done()
			return 0
		case "idle":
			_, _ = io.Copy(io.Discard, os.Stdin)
			return 0
		default:
			return 7
		}
	}))
}

func TestKilledOwnerReleasesDescendantLeaseAndAllowsReplacement(t *testing.T) {
	leasePath := filepath.Join(t.TempDir(), "runtime.lock")
	lease, err := os.OpenFile(leasePath, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Close()
	if err := syscall.Flock(int(lease.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	placeholder, _ := testPipe(t)
	owner := exec.Command(os.Args[0], "-test.run=^TestOwnedProcessChild$")
	owner.Env = append(os.Environ(), "PULSEPHONE_LIFETIME_CHILD=owner")
	owner.ExtraFiles = []*os.File{placeholder, lease}
	output, err := owner.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	if err := owner.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = owner.Process.Kill() }()
	_ = lease.Close()
	ready := make(chan int, 1)
	go func() {
		var pid int
		_, _ = fmt.Fscanln(output, &pid)
		ready <- pid
	}()
	var childPID int
	select {
	case childPID = <-ready:
	case <-time.After(5 * time.Second):
		_ = owner.Process.Kill()
		_ = owner.Wait()
		t.Fatal("owner failed to spawn child")
	}
	if childPID <= 0 {
		_ = owner.Wait()
		t.Fatal("invalid child identity")
	}
	// A failed test must not leave the exact child we just launched running.
	defer syscall.Kill(childPID, syscall.SIGKILL)
	probe, err := os.OpenFile(leasePath, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer probe.Close()
	if err := syscall.Flock(int(probe.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != syscall.EWOULDBLOCK {
		t.Fatalf("lease not held: %v", err)
	}
	_ = owner.Process.Kill()
	_ = owner.Wait()
	deadline := time.Now().Add(4 * time.Second)
	for {
		err = syscall.Flock(int(probe.Fd()), syscall.LOCK_EX|syscall.LOCK_NB)
		if err == nil {
			break
		}
		if time.Now().After(deadline) {
			t.Fatalf("descendant retained lease after owner SIGKILL: %v", err)
		}
		time.Sleep(10 * time.Millisecond)
	}
	_ = syscall.Flock(int(probe.Fd()), syscall.LOCK_UN)
	// The same protocol can now start a replacement and preserve its exit code.
	replacement := exec.Command(os.Args[0], "-test.run=^TestOwnedProcessChild$")
	replacement.Env = append(os.Environ(), "PULSEPHONE_LIFETIME_CHILD=normal")
	assertOwnedProcess(t, replacement, true, false)
}

func TestOwnerLossReleasesProcessLeaseDespiteBlockedWorkOrCleanup(t *testing.T) {
	for _, mode := range []string{"idle", "blocked", "cleanup", "normal"} {
		t.Run(mode, func(t *testing.T) {
			cmd := exec.Command(os.Args[0], "-test.run=^TestOwnedProcessChild$")
			cmd.Env = append(os.Environ(), "PULSEPHONE_LIFETIME_CHILD="+mode)
			assertOwnedProcess(t, cmd, mode == "normal", mode == "blocked" || mode == "cleanup")
		})
	}
}

func TestProductionHelperEntrypointsObserveInheritedLifetime(t *testing.T) {
	for _, kind := range []string{"coredevice", "direct"} {
		t.Run(kind, func(t *testing.T) {
			binary := filepath.Join(t.TempDir(), "helper")
			build := exec.Command("go", "build", "-o", binary, "../../cmd/pulsephone-"+kind+"-helper")
			if output, err := build.CombinedOutput(); err != nil {
				t.Fatalf("build: %v %s", err, output)
			}
			args := []string{"--runtime-epoch", "1", "--connection-epoch", "1", "--executor-generation", "1", "--raw-transport-udid", "fixture", "--helper-build-id", "fixture", "--manifest-hash", strings.Repeat("a", 64)}
			if kind == "direct" {
				args = append(args, "--mode", "oneshot")
			} else {
				for _, facet := range []string{"appControl", "button", "hid", "keyboard", "orientation", "pasteboard", "screenshot"} {
					args = append(args, "--facet-service", facet+"=service."+facet)
				}
			}
			// Wait for Hello, then lose the Runtime before HelloAccepted. No device I/O.
			assertOwnedProcess(t, exec.Command(binary, args...), false, false)
		})
	}
}

func assertOwnedProcess(t *testing.T, cmd *exec.Cmd, normal, timeout bool) {
	t.Helper()
	lifetime, owner := testPipe(t)
	input, _ := testPipe(t)
	leasePath := filepath.Join(t.TempDir(), "runtime.lock")
	lease, err := os.OpenFile(leasePath, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		t.Fatal(err)
	}
	defer lease.Close()
	if err := syscall.Flock(int(lease.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatal(err)
	}
	cmd.Stdin = input
	cmd.ExtraFiles = []*os.File{lifetime, lease}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		t.Fatal(err)
	}
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = cmd.Process.Kill() }()
	_ = lifetime.Close()
	_ = lease.Close()
	ready := make(chan error, 1)
	go func() { _, err := bufio.NewReader(stdout).ReadString('\n'); ready <- err }()
	select {
	case err := <-ready:
		if err != nil {
			_ = cmd.Wait()
			t.Fatalf("startup: %v %s", err, stderr.Bytes())
		}
	case <-time.After(5 * time.Second):
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		t.Fatal("no startup signal")
	}
	probe, err := os.OpenFile(leasePath, os.O_RDWR, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer probe.Close()
	if !normal {
		if err := syscall.Flock(int(probe.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != syscall.EWOULDBLOCK {
			t.Fatalf("child failed to retain lease: %v", err)
		}
		_ = owner.Close()
	}
	finished := make(chan error, 1)
	go func() { finished <- cmd.Wait() }()
	select {
	case <-finished:
	case <-time.After(5 * time.Second):
		_ = cmd.Process.Kill()
		<-finished
		t.Fatal("owner loss failed to stop child")
	}
	if normal && cmd.ProcessState.ExitCode() != 7 {
		t.Fatalf("normal exit overwritten: %v", cmd.ProcessState)
	}
	if timeout && cmd.ProcessState.ExitCode() != 2 {
		t.Fatalf("timeout exit: %v", cmd.ProcessState)
	}
	if err := syscall.Flock(int(probe.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		t.Fatalf("lease retained after child exit: %v", err)
	}
	_ = syscall.Flock(int(probe.Fd()), syscall.LOCK_UN)
}

func testPipe(t *testing.T) (*os.File, *os.File) {
	t.Helper()
	r, w, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = r.Close(); _ = w.Close() })
	return r, w
}

func waitTestSignal(t *testing.T, signal <-chan struct{}) {
	t.Helper()
	select {
	case <-signal:
	case <-time.After(3 * time.Second):
		t.Fatal("missing lifecycle signal")
	}
}
