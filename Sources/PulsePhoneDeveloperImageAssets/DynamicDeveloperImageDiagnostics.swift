import Darwin
import Foundation
import PulsePhoneDeveloperSupportDefinitions
import PulsePhoneSharedDefinitions

public enum DynamicDeveloperImageDiagnosticAvailability: String, Codable, Equatable, Sendable {
  case available
  case candidateOnly
  case downloadable
  case unavailable
}

public enum DynamicDeveloperImageDiagnosticCheckStatus: String, Codable, Equatable, Sendable {
  case candidateAvailable
  case locallyValidatedAvailable
  case ready
  case unavailable
  case unsupported
  case verifiedAvailable
}

public enum DynamicDeveloperImageDiagnosticMappingStatus: String, Codable, Equatable, Sendable {
  case defaultCandidate
  case localValidated
  case remoteVerified
}

public enum DynamicDeveloperImageDiagnosticSource: String, Codable, Equatable, Sendable {
  case approvedRemote
  case matchingXcode
  case pulseCache
}

public enum DynamicDeveloperImageDiagnosticRoute: String, Codable, Equatable, Sendable {
  case classic
  case personalized
}

public struct DynamicDeveloperImageSupportRecord: Codable, Equatable, Sendable {
  public let buildID: String?
  public let ddiVersion: String?
  public let iosVersion: String?
  public let mappingStatus: DynamicDeveloperImageDiagnosticMappingStatus
  public let route: DynamicDeveloperImageDiagnosticRoute
  public let selectedAssetID: String
  public let sources: [DynamicDeveloperImageDiagnosticSource]
  public let state: DynamicDeveloperImageDiagnosticAvailability
}

public struct DynamicDeveloperImageSupportListResult: Codable, Equatable, Sendable {
  public let catalogCanonicalSHA256: String
  public let catalogRevision: String
  public let defaultCandidate: DynamicDeveloperImageSupportRecord
  public let records: [DynamicDeveloperImageSupportRecord]
  public let staleCatalog: Bool
}

public struct DynamicDeveloperImageCheckResult: Codable, Equatable, Sendable {
  public let buildID: String
  public let catalogCanonicalSHA256: String
  public let catalogRevision: String
  public let ddiVersion: String?
  public let iosVersion: String
  public let mappingStatus: DynamicDeveloperImageDiagnosticMappingStatus?
  public let nextStep: String
  public let route: DynamicDeveloperImageDiagnosticRoute?
  public let selectedAssetID: String?
  public let sources: [DynamicDeveloperImageDiagnosticSource]
  public let staleCatalog: Bool
  public let status: DynamicDeveloperImageDiagnosticCheckStatus
}

/// Read-only support diagnostics. It shares the same catalog snapshot and
/// content-addressed cache as preparation, but never acquires an archive,
/// requests TSS, mounts an image, or writes a local candidate record.
public struct DynamicDeveloperImageDiagnostics: @unchecked Sendable {
  public typealias XcodeMatcher = @Sendable (
    DynamicDeveloperImageAssetReference
  ) -> Bool

  private let assetCache: DynamicDeveloperImageAssetCache
  private let catalogStore: DynamicDeveloperImageCatalogStore
  private let xcodeMatcher: XcodeMatcher

  public init(
    catalogStore: DynamicDeveloperImageCatalogStore,
    assetCache: DynamicDeveloperImageAssetCache
  ) {
    self.init(
      catalogStore: catalogStore,
      assetCache: assetCache,
      xcodeMatcher: SelectedXcodeDynamicAssetInventory.matches
    )
  }

  public init(
    catalogStore: DynamicDeveloperImageCatalogStore,
    assetCache: DynamicDeveloperImageAssetCache,
    xcodeMatcher: @escaping XcodeMatcher
  ) {
    self.catalogStore = catalogStore
    self.assetCache = assetCache
    self.xcodeMatcher = xcodeMatcher
  }

  public func list(
    forceRefresh: Bool = false
  ) throws -> DynamicDeveloperImageSupportListResult {
    let snapshot = try catalogStore.snapshot(forceRefresh: forceRefresh)
    var records = [DynamicDeveloperImageSupportRecord]()
    records.reserveCapacity(
      snapshot.catalog.developerDiskImages.count
        + snapshot.catalog.catalogEntry.count
    )

    for asset in snapshot.catalog.developerDiskImages {
      let reference = DynamicDeveloperImageAssetReference(
        archiveSHA256: asset.archiveSHA256,
        archiveSize: asset.archiveSize,
        assetID: asset.ddiVersion,
        contentManifestSHA256: asset.contentManifestSHA256,
        ddiVersion: asset.ddiVersion,
        kind: .developerDiskImage,
        sourceURL: asset.sourceURL
      )
      records.append(record(
        reference: reference,
        route: .classic,
        iosVersion: asset.ddiVersion,
        buildID: nil,
        mappingStatus: .remoteVerified
      ))
    }

    let locallyValidated = try catalogStore.localCandidateRecords(snapshot: snapshot)
    let localByBuild = Dictionary(
      uniqueKeysWithValues: locallyValidated.map { ($0.buildID, $0) }
    )
    for entry in snapshot.catalog.catalogEntry {
      guard let selection = DynamicDeveloperImageCatalog.exactBaseAsset(
        in: snapshot.catalog,
        buildID: entry.buildID
      ) else { continue }
      records.append(record(
        reference: selection.asset,
        route: .personalized,
        iosVersion: entry.iosVersion,
        buildID: entry.buildID,
        mappingStatus: .remoteVerified
      ))
      _ = localByBuild[entry.buildID]
    }
    for local in locallyValidated where snapshot.catalog.catalogEntry.allSatisfy({
      $0.buildID != local.buildID
    }) {
      guard let selection = DynamicDeveloperImageCatalog.baseAsset(
        in: snapshot.catalog,
        baseAssetID: local.baseAssetID,
        provenance: .localValidated
      ), selection.asset.contentManifestSHA256 == local.baseContentManifestSHA256
      else { continue }
      records.append(record(
        reference: selection.asset,
        route: .personalized,
        iosVersion: local.iosVersion,
        buildID: local.buildID,
        mappingStatus: .localValidated
      ))
    }
    records.sort { lhs, rhs in
      let lhsRoute = lhs.route.rawValue
      let rhsRoute = rhs.route.rawValue
      if lhsRoute != rhsRoute {
        return lhsRoute.utf8.lexicographicallyPrecedes(rhsRoute.utf8)
      }
      let lhsBuild = lhs.buildID ?? lhs.iosVersion ?? ""
      let rhsBuild = rhs.buildID ?? rhs.iosVersion ?? ""
      return lhsBuild.utf8.lexicographicallyPrecedes(rhsBuild.utf8)
    }

    guard let candidate = DynamicDeveloperImageCatalog.baseAsset(
      in: snapshot.catalog,
      baseAssetID: snapshot.catalog.defaultCandidateBaseAssetID,
      provenance: .defaultCandidate
    ) else {
      throw DynamicDeveloperImageCatalogStoreError.candidateIncompatible
    }
    return DynamicDeveloperImageSupportListResult(
      catalogCanonicalSHA256: snapshot.identity.canonicalSHA256,
      catalogRevision: snapshot.identity.revision,
      defaultCandidate: record(
        reference: candidate.asset,
        route: .personalized,
        iosVersion: nil,
        buildID: nil,
        mappingStatus: .defaultCandidate
      ),
      records: records,
      staleCatalog: snapshot.staleCatalog
    )
  }

  public func check(
    iosVersion: String,
    buildID: String,
    developerServicesReady: Bool,
    forceRefresh: Bool = false
  ) throws -> DynamicDeveloperImageCheckResult {
    guard let major = iosVersion.split(separator: ".").first.flatMap({
      UInt64($0)
    }) else {
      return unavailable(
        iosVersion: iosVersion,
        buildID: buildID,
        status: .unavailable,
        nextStep: "Unable to determine the device iOS route."
      )
    }
    guard major >= 14 else {
      return unavailable(
        iosVersion: iosVersion,
        buildID: buildID,
        status: .unsupported,
        nextStep: "This iOS version is outside the PulsePhone product route."
      )
    }

    let snapshot = try catalogStore.snapshot(forceRefresh: forceRefresh)
    if major < 17 {
      guard let asset = DynamicDeveloperImageCatalog.classicDDI(
        in: snapshot.catalog,
        iosVersion: iosVersion
      ) else {
        return unavailable(
          iosVersion: iosVersion,
          buildID: buildID,
          snapshot: snapshot,
          status: .unavailable,
          nextStep: "No approved classic Developer Disk Image matches this iOS version."
        )
      }
      return checkResult(
        reference: asset,
        route: .classic,
        iosVersion: iosVersion,
        buildID: buildID,
        mappingStatus: .remoteVerified,
        developerServicesReady: developerServicesReady,
        snapshot: snapshot
      )
    }

    let selection = try DynamicDeveloperImageCatalog.exactBaseAsset(
      in: snapshot.catalog,
      buildID: buildID
    ) ?? catalogStore.localCandidate(buildID: buildID, snapshot: snapshot)
      ?? DynamicDeveloperImageCatalog.baseAsset(
        in: snapshot.catalog,
        baseAssetID: snapshot.catalog.defaultCandidateBaseAssetID,
        provenance: .defaultCandidate
      )
    guard let selection else {
      return unavailable(
        iosVersion: iosVersion,
        buildID: buildID,
        snapshot: snapshot,
        status: .unavailable,
        nextStep: "No approved Developer Image asset is available for this device."
      )
    }
    return checkResult(
      reference: selection.asset,
      route: .personalized,
      iosVersion: iosVersion,
      buildID: buildID,
      mappingStatus: mappingStatus(selection.provenance),
      developerServicesReady: developerServicesReady,
      snapshot: snapshot
    )
  }

  private func checkResult(
    reference: DynamicDeveloperImageAssetReference,
    route: DynamicDeveloperImageDiagnosticRoute,
    iosVersion: String,
    buildID: String,
    mappingStatus: DynamicDeveloperImageDiagnosticMappingStatus,
    developerServicesReady: Bool,
    snapshot: DynamicDeveloperImageCatalogSnapshot
  ) -> DynamicDeveloperImageCheckResult {
    let sources = availableSources(for: reference)
    let status: DynamicDeveloperImageDiagnosticCheckStatus
    let nextStep: String
    if developerServicesReady {
      status = .ready
      nextStep = "Developer services are ready."
    } else {
      switch mappingStatus {
      case .remoteVerified:
        status = .verifiedAvailable
        nextStep = "Run PulsePhone device prepare before using Developer Image capabilities."
      case .localValidated:
        status = .locallyValidatedAvailable
        nextStep = "Run PulsePhone device prepare to revalidate the current device state."
      case .defaultCandidate:
        status = .candidateAvailable
        nextStep = "Run PulsePhone device prepare; TSS, mount, and service probes must succeed before this device is confirmed."
      }
    }
    return DynamicDeveloperImageCheckResult(
      buildID: buildID,
      catalogCanonicalSHA256: snapshot.identity.canonicalSHA256,
      catalogRevision: snapshot.identity.revision,
      ddiVersion: reference.ddiVersion,
      iosVersion: iosVersion,
      mappingStatus: mappingStatus,
      nextStep: nextStep,
      route: route,
      selectedAssetID: reference.assetID,
      sources: sources,
      staleCatalog: snapshot.staleCatalog,
      status: status
    )
  }

  private func unavailable(
    iosVersion: String,
    buildID: String,
    snapshot: DynamicDeveloperImageCatalogSnapshot? = nil,
    status: DynamicDeveloperImageDiagnosticCheckStatus,
    nextStep: String
  ) -> DynamicDeveloperImageCheckResult {
    DynamicDeveloperImageCheckResult(
      buildID: buildID,
      catalogCanonicalSHA256: snapshot?.identity.canonicalSHA256 ?? "",
      catalogRevision: snapshot?.identity.revision ?? "",
      ddiVersion: nil,
      iosVersion: iosVersion,
      mappingStatus: nil,
      nextStep: nextStep,
      route: nil,
      selectedAssetID: nil,
      sources: [],
      staleCatalog: snapshot?.staleCatalog ?? false,
      status: status
    )
  }

  private func record(
    reference: DynamicDeveloperImageAssetReference,
    route: DynamicDeveloperImageDiagnosticRoute,
    iosVersion: String?,
    buildID: String?,
    mappingStatus: DynamicDeveloperImageDiagnosticMappingStatus
  ) -> DynamicDeveloperImageSupportRecord {
    let sources = availableSources(for: reference)
    let state: DynamicDeveloperImageDiagnosticAvailability
    switch mappingStatus {
    case .defaultCandidate:
      state = .candidateOnly
    case .remoteVerified, .localValidated:
      state = sources.contains(.pulseCache) || sources.contains(.matchingXcode)
        ? .available : .downloadable
    }
    return DynamicDeveloperImageSupportRecord(
      buildID: buildID,
      ddiVersion: reference.ddiVersion,
      iosVersion: iosVersion,
      mappingStatus: mappingStatus,
      route: route,
      selectedAssetID: reference.assetID,
      sources: sources,
      state: state
    )
  }

  private func availableSources(
    for reference: DynamicDeveloperImageAssetReference
  ) -> [DynamicDeveloperImageDiagnosticSource] {
    var sources = [DynamicDeveloperImageDiagnosticSource]()
    if (try? assetCache.openVerified(reference)) != nil {
      sources.append(.pulseCache)
    }
    if xcodeMatcher(reference) {
      sources.append(.matchingXcode)
    }
    // A reference only enters this diagnostic after it has been authorized by
    // the active, canonical catalog snapshot.
    sources.append(.approvedRemote)
    return sources
  }

  private func mappingStatus(
    _ provenance: DynamicDeveloperImageSelectionProvenance
  ) -> DynamicDeveloperImageDiagnosticMappingStatus {
    switch provenance {
    case .remoteVerified: .remoteVerified
    case .localValidated: .localValidated
    case .defaultCandidate: .defaultCandidate
    }
  }
}

enum SelectedXcodeDynamicAssetInventory {
  private static let baseImageDirectory =
    "/Library/Developer/DeveloperDiskImages/iOS_DDI/Restore"
  private static let selectedDeveloperPath = selectedReleaseDeveloperPath()
  // Release Xcode's deep signature validation can exceed five seconds on a
  // cold host. Keep diagnostics bounded while allowing that required check.
  private static let commandTimeout = DispatchTimeInterval.seconds(30)

  static func matches(_ reference: DynamicDeveloperImageAssetReference) -> Bool {
    guard let developerPath = selectedDeveloperPath else { return false }
    switch reference.kind {
    case .baseImage:
      return DynamicDeveloperImageXcodeContentResolver.matchingBaseImageFiles(
        for: reference,
        root: baseImageDirectory
      ) != nil
    case .developerDiskImage:
      let root = developerPath + "/Platforms/iPhoneOS.platform/DeviceSupport"
      return DynamicDeveloperImageXcodeContentResolver.matchingDeveloperDiskImageFiles(
        for: reference,
        root: root
      ) != nil
    }
  }

  private static func selectedReleaseDeveloperPath() -> String? {
    guard let selected = command("/usr/bin/xcode-select", ["-p"]),
      selected.status == 0,
      selected.stdout.count <= 4_096,
      let text = String(data: selected.stdout, encoding: .utf8)
    else { return nil }
    let developerPath = text.trimmingCharacters(in: .newlines)
    guard developerPath.hasSuffix("/Contents/Developer"),
      developerPath.hasPrefix("/"), !developerPath.contains("\n"),
      !developerPath.contains("\r"),
      URL(fileURLWithPath: developerPath).standardizedFileURL.path == developerPath
    else { return nil }
    let appPath = String(developerPath.dropLast("/Contents/Developer".count))
    let lowered = appPath.lowercased()
    guard !lowered.contains("beta"), !lowered.contains("preview"),
      command("/usr/bin/codesign", ["--verify", "--deep", "--strict", appPath])?.status == 0,
      command("/usr/sbin/spctl", ["--assess", "--type", "execute", appPath])?.status == 0,
      let infoData = readRegularFile(appPath + "/Contents/Info.plist"),
      let info = try? PropertyListSerialization.propertyList(
        from: infoData, options: [], format: nil
      ) as? [String: Any],
      info["CFBundleIdentifier"] as? String == "com.apple.dt.Xcode",
      let version = info["CFBundleShortVersionString"] as? String,
      let build = info["DTXcodeBuild"] as? String,
      !version.isEmpty, !build.isEmpty,
      !version.lowercased().contains("beta"), !version.lowercased().contains("preview"),
      !build.lowercased().contains("beta"), !build.lowercased().contains("preview")
    else { return nil }
    return developerPath
  }

  static func command(
    _ executable: String,
    _ arguments: [String],
    timeout: DispatchTimeInterval = commandTimeout
  ) -> (
    status: Int32, stdout: Data
  )? {
    let process = Process()
    let output = Pipe()
    let termination = DispatchSemaphore(value: 0)
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    process.terminationHandler = { _ in termination.signal() }
    do {
      try process.run()
      guard termination.wait(timeout: .now() + timeout) == .success else {
        process.terminate()
        _ = termination.wait(timeout: .now() + .seconds(1))
        return nil
      }
      let data = output.fileHandleForReading.readDataToEndOfFile()
      guard data.count <= 1_048_576 else { return nil }
      return (process.terminationStatus, data)
    } catch {
      return nil
    }
  }

  private static func readRegularFile(_ path: String) -> Data? {
    var status = stat()
    guard lstat(path, &status) == 0,
      (status.st_mode & S_IFMT) == S_IFREG,
      status.st_size > 0
    else { return nil }
    return try? Data(contentsOf: URL(fileURLWithPath: path), options: .mappedIfSafe)
  }
}
