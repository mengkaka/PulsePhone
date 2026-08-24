import Darwin
import Foundation
import PulsePhoneElement
import PulsePhoneSharedDefinitions

if Array(CommandLine.arguments.dropFirst()) == [AppleRegionSubprocessTransport.hiddenRole] {
  exit(AppleRegionPrivateWorkerServer.run())
}

if RuntimeLaunchArguments.isHelpRequest(CommandLine.arguments) {
  FileHandle.standardOutput.write(Data((RuntimeLaunchArguments.helpText + "\n").utf8))
  exit(0)
}

let readiness: ReadinessFD
do {
  readiness = try ReadinessFD(fileDescriptor: ReadinessFD.standardFileDescriptor)
} catch {
  exit(EX_OSERR)
}

do {
  let launch = try RuntimeLaunchArguments.parse(CommandLine.arguments)
  let server = try ProductionRuntimeServer.bundled(
    canonicalUDID: launch.canonicalUDID
  )
  try server.run(readiness: readiness)
} catch let error as RuntimeLaunchArgumentError {
  try? readiness.publishFailed(code: error.standardErrorCode)
  exit(EX_USAGE)
} catch {
  try? readiness.publishFailed(code: "internalFailure")
  exit(EX_SOFTWARE)
}
