import Darwin
import Foundation
import PulsePhoneDeveloperImageAssets
import PulsePhoneDeveloperSupportDefinitions
import PulsePhoneSharedDefinitions

enum ProductionSelectedXcodeSnapshot {
  private static let defaultHostDDIRestorePath =
    "/Library/Developer/DeveloperDiskImages/iOS_DDI/Restore"

  struct CommandResult: Sendable {
    let exitCode: Int32
    let stdout: Data
  }

  typealias CommandRunner =
    @Sendable (
      _ executable: String,
      _ arguments: [String]
    ) -> CommandResult

  static func capture(
    entry: DeveloperImageCatalogEntryV1,
    commandRunner: CommandRunner? = nil
  ) -> SelectedXcodeSnapshot? {
    let run = commandRunner ?? runCommand
    guard let xcode = captureReleaseXcode(commandRunner: run) else {
      return nil
    }

    var roleFiles: [String: SelectedXcodeRoleFile] = [:]
    roleFiles.reserveCapacity(entry.files.count)
    for file in entry.files {
      guard
        let path = DeveloperImageSourceResolver.selectedXcodeRolePath(
          developerPath: xcode.developerPath,
          ddiVersion: entry.ddiVersion,
          fileRole: file.fileRole
        ), let bytes = readRegularFile(at: path, maximumBytes: file.size),
        UInt64(bytes.count) == file.size,
        StableBytes.sha256Hex(bytes) == file.sha256
      else {
        return nil
      }
      roleFiles[file.fileRole] = SelectedXcodeRoleFile(
        path: path,
        sha256: file.sha256,
        size: file.size
      )
    }

    return SelectedXcodeSnapshot(
      appPath: xcode.appPath,
      bundleIdentifier: xcode.bundleIdentifier,
      developerPath: xcode.developerPath,
      gatekeeperAccepted: true,
      licenseType: "GM",
      pairs: [
        SelectedXcodePair(
          buildID: entry.buildID,
          ddiVersion: entry.ddiVersion,
          roleFiles: roleFiles
        )
      ],
      signatureValid: true
    )
  }

  /// Reads dynamic DDI roles from the selected release Xcode host inventory.
  /// The current Xcode layout names personalized payloads from the build
  /// manifest instead of exposing stable Image.dmg filenames. Each candidate
  /// is therefore checked against the catalog's complete content manifest
  /// before its bytes can be published.
  static func captureDynamicAssetFiles(
    for reference: DynamicDeveloperImageAssetReference,
    hostDDIRestorePath: String = defaultHostDDIRestorePath,
    commandRunner: CommandRunner? = nil
  ) -> [String: Data]? {
    let run = commandRunner ?? runCommand
    guard let xcode = captureReleaseXcode(commandRunner: run) else {
      return nil
    }
    switch reference.kind {
    case .baseImage:
      return DynamicDeveloperImageXcodeContentResolver.matchingBaseImageFiles(
        for: reference,
        root: hostDDIRestorePath
      )
    case .developerDiskImage:
      let root =
        xcode.developerPath
        + "/Platforms/iPhoneOS.platform/DeviceSupport"
      return DynamicDeveloperImageXcodeContentResolver.matchingDeveloperDiskImageFiles(
        for: reference,
        root: root
      )
    }
  }

  private struct ReleaseXcode {
    let appPath: String
    let bundleIdentifier: String
    let developerPath: String
  }

  private static func captureReleaseXcode(
    commandRunner run: CommandRunner
  ) -> ReleaseXcode? {
    let selection = run("/usr/bin/xcode-select", ["-p"])
    guard selection.exitCode == 0,
      selection.stdout.count <= 4_096,
      let selectedText = String(data: selection.stdout, encoding: .utf8)
    else {
      return nil
    }
    let developerPath = selectedText.trimmingCharacters(in: .newlines)
    guard !developerPath.isEmpty,
      !developerPath.contains("\n"),
      !developerPath.contains("\r"),
      developerPath.hasSuffix("/Contents/Developer"),
      URL(fileURLWithPath: developerPath).standardizedFileURL.path
        == developerPath
    else {
      return nil
    }
    let appPath = String(developerPath.dropLast("/Contents/Developer".count))
    let lowercasedPath = appPath.lowercased()
    guard appPath.hasPrefix("/"),
      !lowercasedPath.contains("beta"),
      !lowercasedPath.contains("preview")
    else {
      return nil
    }

    guard
      run(
        "/usr/bin/codesign",
        ["--verify", "--deep", "--strict", appPath]
      ).exitCode == 0
    else {
      return nil
    }
    guard
      run(
        "/usr/sbin/spctl",
        ["--assess", "--type", "execute", appPath]
      ).exitCode == 0
    else {
      return nil
    }

    guard
      let infoBytes = readRegularFile(
        at: appPath + "/Contents/Info.plist",
        maximumBytes: 1_048_576
      ),
      let info = try? PropertyListSerialization.propertyList(
        from: infoBytes,
        options: [],
        format: nil
      ) as? [String: Any],
      let bundleIdentifier = info["CFBundleIdentifier"] as? String,
      bundleIdentifier == "com.apple.dt.Xcode",
      let version = nonemptyMetadata(info["CFBundleShortVersionString"]),
      let build = nonemptyMetadata(info["DTXcodeBuild"]),
      !version.lowercased().contains("beta"),
      !version.lowercased().contains("preview"),
      !build.lowercased().contains("beta"),
      !build.lowercased().contains("preview")
    else {
      return nil
    }
    return ReleaseXcode(
      appPath: appPath,
      bundleIdentifier: bundleIdentifier,
      developerPath: developerPath
    )
  }

  private static func isCanonicalAbsolutePath(_ path: String) -> Bool {
    path.hasPrefix("/")
      && !path.hasSuffix("/")
      && URL(fileURLWithPath: path).standardizedFileURL.path == path
  }

  private static func nonemptyMetadata(_ value: Any?) -> String? {
    guard let value = value as? String,
      !value.isEmpty,
      value.utf8.count <= 256
    else {
      return nil
    }
    return value
  }

  private static func readRegularFile(
    at path: String,
    maximumBytes: UInt64
  ) -> Data? {
    let descriptor = Darwin.open(
      path,
      O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
    )
    guard descriptor >= 0 else { return nil }
    defer { Darwin.close(descriptor) }

    var before = stat()
    guard fstat(descriptor, &before) == 0,
      before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      before.st_nlink == 1,
      before.st_size >= 0,
      UInt64(before.st_size) <= maximumBytes,
      UInt64(before.st_size) <= UInt64(Int.max)
    else {
      return nil
    }
    var data = Data(count: Int(before.st_size))
    var offset = 0
    while offset < data.count {
      let count = data.withUnsafeMutableBytes { buffer in
        Darwin.read(
          descriptor,
          buffer.baseAddress!.advanced(by: offset),
          buffer.count - offset
        )
      }
      guard count >= 0 else {
        if errno == EINTR { continue }
        return nil
      }
      guard count > 0 else { return nil }
      offset += count
    }
    var after = stat()
    guard fstat(descriptor, &after) == 0,
      after.st_dev == before.st_dev,
      after.st_ino == before.st_ino,
      after.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
      after.st_nlink == 1,
      after.st_size == before.st_size
    else {
      return nil
    }
    return data
  }

  private static func runCommand(
    executable: String,
    arguments: [String]
  ) -> CommandResult {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      return CommandResult(
        exitCode: process.terminationStatus,
        stdout: output.fileHandleForReading.readDataToEndOfFile()
      )
    } catch {
      return CommandResult(exitCode: -1, stdout: Data())
    }
  }
}
