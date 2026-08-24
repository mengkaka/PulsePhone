import Darwin
import Foundation
import PulsePhoneAvailability
import PulsePhoneCLI
import PulsePhoneClientCore
import PulsePhoneCommandCatalog
import PulsePhoneCommandPlanner
import PulsePhoneDeveloperSupportDefinitions
import PulsePhoneGUI
import PulsePhoneHostPaths
import PulsePhoneMedia
import PulsePhoneSharedDefinitions
import PulsePhoneWire

let arguments = Array(CommandLine.arguments.dropFirst())
if GUIHostProcessEntrypoint.handles(arguments) {
    exit(GUIHostProcessEntrypoint.run(arguments: arguments))
}
if arguments.starts(with: ["device", "prepare"]) {
    // The shared Runtime attempt, rather than an observer signal, owns the
    // terminal. Ctrl-C must not abandon this explicit observation path.
    _ = Darwin.signal(SIGINT, SIG_IGN)
}
let outputMode = CLIArgumentPreflight.outputMode(in: arguments)
let terminal = PulsePhoneCLIProcess.bundled(preparationProgressOutput: { progress in
    guard outputMode == .human else { return }
    var message = "Preparing \(progress.preparationGroupID): \(progress.phase.rawValue)"
    let fraction = progress.fraction ?? {
        guard let completed = progress.completedBytes,
              let total = progress.totalBytes,
              total > 0
        else { return nil }
        return Double(completed) / Double(total)
    }()
    if let fraction {
        message += " \(Int((fraction * 100).rounded(.down)))%"
    }
    FileHandle.standardError.write(Data((message + "\n").utf8))
}) {
    canonicalUDID, requestID, selectSource in
    let canonicalAppPath = try CanonicalAppPath.resolveCurrentExecutable()
    let hostPaths = try POSIXHostPathSystem().makeHostPathLayout()
    let launcher = try LiveLauncher(
        canonicalAppPath: canonicalAppPath,
        hostPaths: hostPaths,
        launcherBuildID: "pulsephone.client.v1",
        launcherInstanceID: CanonicalUUID(value: UUID()),
        transport: ProductionGUIHostTransport(canonicalAppPath: canonicalAppPath)
    )
    let result = try launcher.openLive(
        canonicalUDID: canonicalUDID,
        requestID: requestID,
        sourceSelectionPolicy: selectSource ? .forceChooser : .automatic,
        startedAtNanoseconds: SystemMonotonicClock().now().nanoseconds
    )
    guard let liveOwnerID = result.windowID,
          !liveOwnerID.hasPrefix("window-")
    else {
        throw CLIProductionBackendError.standard(
            code: "windowCreateFailed",
            message: "GUIHost did not create a production AppKit window"
        )
    }
    if let errorCode = result.errorCode {
        throw CLIProductionBackendError.standard(code: errorCode.rawValue)
    }
    return CLILiveOpenResult(
        disposition: result.disposition.rawValue,
        liveOwnerID: liveOwnerID
    )
}.run(arguments: arguments)
for line in terminal.chunk.stdout {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
}
for line in terminal.chunk.stderr {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
exit(terminal.exitCode)
