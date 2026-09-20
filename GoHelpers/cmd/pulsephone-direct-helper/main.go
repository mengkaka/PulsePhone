package main

import (
	"context"
	"flag"
	"os"
	"syscall"

	"pulsephone/GoHelpers/internal/direct"
	"pulsephone/GoHelpers/internal/helperapp"
	"pulsephone/GoHelpers/internal/processidentity"
)

func main() {
	_ = syscall.Setpgid(0, 0)
	os.Exit(run())
}

func run() int {
	return runWithOwner(helperapp.RunOwned)
}

func runWithOwner(owner func(*os.File, func(context.Context) int) int) int {
	flags := flag.NewFlagSet(os.Args[0], flag.ContinueOnError)
	flags.SetOutput(os.Stderr)
	mode := flags.String("mode", "", "facts or oneshot")
	runtimeEpoch := flags.Uint64("runtime-epoch", 0, "runtime epoch")
	connectionEpoch := flags.Uint64("connection-epoch", 0, "connection epoch")
	executorGeneration := flags.Uint64("executor-generation", 0, "executor generation")
	rawTransportUDID := flags.String("raw-transport-udid", "", "transport UDID")
	helperBuildID := flags.String("helper-build-id", "", "helper build ID")
	manifestHash := flags.String("manifest-hash", "", "manifest hash")
	processStartIdentity := flags.String("process-start-identity", "", "process start identity")
	if err := flags.Parse(os.Args[1:]); err != nil {
		return 2
	}
	if flags.NArg() != 0 || *mode == "" {
		return 2
	}
	if *mode == "facts" {
		if *runtimeEpoch != 0 || *connectionEpoch != 0 || *executorGeneration != 0 || *rawTransportUDID != "" || *helperBuildID != "" || *manifestHash != "" || *processStartIdentity != "" {
			return 2
		}
		return direct.RunFacts(os.Stdin, os.Stdout, nil)
	}
	if *mode != "oneshot" || *helperBuildID == "" || *manifestHash == "" || *rawTransportUDID == "" || *runtimeEpoch == 0 || *connectionEpoch == 0 || *executorGeneration == 0 {
		return 2
	}
	if *processStartIdentity == "" {
		identity, err := processidentity.CurrentProcessStartIdentity()
		if err != nil {
			return 2
		}
		*processStartIdentity = identity
	}
	_ = connectionEpoch
	return owner(os.Stdin, func(ctx context.Context) int {
		return direct.RunOneShot(os.Stdin, os.Stdout, direct.OneShotConfig{Context: ctx, RuntimeEpoch: *runtimeEpoch, ConnectionEpoch: *connectionEpoch, ExecutorGeneration: *executorGeneration, RawTransportUDID: *rawTransportUDID, HelperBuildID: *helperBuildID, ManifestHash: *manifestHash, ProcessStartIdentity: *processStartIdentity})
	})
}
