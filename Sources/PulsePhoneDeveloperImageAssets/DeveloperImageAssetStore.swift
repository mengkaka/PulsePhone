import Darwin
import Foundation
import PulsePhoneDeveloperSupportDefinitions
import PulsePhoneSharedDefinitions

public final class DeveloperImageAssetStore: @unchecked Sendable {
  public let rootURL: URL
  public let limits: DeveloperImageAssetStoreLimits

  private let fileManager: FileManager
  private let posix: AssetStorePOSIX

  public init(
    rootURL: URL,
    limits: DeveloperImageAssetStoreLimits = DeveloperImageAssetStoreLimits(),
    fileManager: FileManager = .default
  ) throws {
    let standardized = rootURL.standardizedFileURL
    self.rootURL = standardized.deletingLastPathComponent()
      .resolvingSymlinksInPath()
      .appendingPathComponent(standardized.lastPathComponent, isDirectory: true)
    self.limits = try limits.validated()
    self.fileManager = fileManager
    self.posix = AssetStorePOSIX()
    try bootstrap()
  }

  public func createOrValidateCatalog(
    _ catalog: DeveloperImageCatalogV1
  ) throws -> DeveloperImageCatalogIdentity {
    let bytes = try DeveloperImageCatalog.canonicalBytes(catalog)
    let decoded = try DeveloperImageCatalog.decodeCanonical(bytes)
    let identity = try DeveloperImageCatalog.identity(catalog: decoded)
    try posix.validateSafeComponent(identity.revision)
    return try withStoreLock {
      try removeStalePublishTempsLocked()
      let path = catalogPath(revision: identity.revision)
      let catalogFiles = try regularChildren(in: catalogsPath)
      let catalogSizes = try catalogFiles.map(posix.regularFileSize)
      let catalogBytes = try catalogSizes.reduce(UInt64(0), adding)
      guard catalogFiles.count <= limits.maximumCatalogCount,
        catalogSizes.allSatisfy({ $0 <= limits.maximumCatalogBytes }),
        catalogBytes <= limits.maximumCatalogTotalBytes
      else {
        throw DeveloperImageAssetStoreError.capacityExceeded
      }
      try ensureCapacityLocked(reserving: 0, protectedAssetKeys: [])
      if fileManager.fileExists(atPath: path) {
        let existing = try posix.readRegularFile(path, maximumBytes: limits.maximumCatalogBytes)
        guard [UInt8](existing) == bytes else {
          throw DeveloperImageAssetStoreError.catalogMismatch
        }
        return identity
      }

      guard bytes.count <= Int(limits.maximumCatalogBytes),
        catalogFiles.count < limits.maximumCatalogCount,
        try adding(catalogBytes, UInt64(bytes.count)) <= limits.maximumCatalogTotalBytes
      else {
        throw DeveloperImageAssetStoreError.capacityExceeded
      }
      try ensureCapacityLocked(reserving: UInt64(bytes.count), protectedAssetKeys: [])
      try posix.atomicWrite(Data(bytes), to: path)
      return identity
    }
  }

  /// Returns every canonical catalog already accepted into this private store.
  /// Callers must still apply their own source policy before treating a catalog
  /// as an eligible remote source.
  public func acceptedCatalogs() throws -> [DeveloperImageCatalogV1] {
    try withStoreLock {
      try removeStalePublishTempsLocked()
      let paths = try regularChildren(in: catalogsPath)
      let sizes = try paths.map(posix.regularFileSize)
      let total = try sizes.reduce(UInt64(0), adding)
      guard paths.count <= limits.maximumCatalogCount,
        sizes.allSatisfy({ $0 <= limits.maximumCatalogBytes }),
        total <= limits.maximumCatalogTotalBytes
      else {
        throw DeveloperImageAssetStoreError.capacityExceeded
      }
      var catalogs: [DeveloperImageCatalogV1] = []
      catalogs.reserveCapacity(paths.count)
      for path in paths {
        let bytes = try posix.readRegularFile(
          path,
          maximumBytes: limits.maximumCatalogBytes
        )
        let catalog = try DeveloperImageCatalog.decodeCanonical([UInt8](bytes))
        let identity = try DeveloperImageCatalog.identity(catalog: catalog)
        guard catalogPath(revision: identity.revision) == path else {
          throw DeveloperImageAssetStoreError.catalogMismatch
        }
        catalogs.append(catalog)
      }
      return catalogs
    }
  }

  public func openVerifiedAsset(
    catalog: DeveloperImageCatalogV1,
    entryID: String
  ) throws -> DeveloperImageAssetLease? {
    _ = try createOrValidateCatalog(catalog)
    let entry = try catalogEntry(catalog, entryID: entryID)
    let manifest = try entry.assetManifest.validated()
    let assetKey = try manifest.assetKey
    let lock = try openAssetLock(assetKey: assetKey, operation: LOCK_SH)
    do {
      guard fileManager.fileExists(atPath: assetPath(assetKey: assetKey)) else {
        _ = flock(lock, LOCK_UN)
        Darwin.close(lock)
        return nil
      }
      let roleFiles = try validatePublishedAsset(manifest: manifest, assetKey: assetKey)
      return DeveloperImageAssetLease(
        assetKey: assetKey,
        roleFiles: roleFiles,
        lockDescriptor: lock
      )
    } catch {
      _ = flock(lock, LOCK_UN)
      Darwin.close(lock)
      throw error
    }
  }

  public func publish(
    catalog: DeveloperImageCatalogV1,
    entryID: String,
    archiveEntries: [DeveloperImageArchiveEntry],
    fault: DeveloperImagePublishFault = .none
  ) throws -> DeveloperImagePublishedAsset {
    _ = try createOrValidateCatalog(catalog)
    let entry = try catalogEntry(catalog, entryID: entryID)
    let manifest = try entry.assetManifest.validated()
    let assetKey = try manifest.assetKey

    return try withStoreLock {
      try withAssetLock(assetKey: assetKey, operation: LOCK_EX) {
        if fileManager.fileExists(atPath: assetPath(assetKey: assetKey)) {
          do {
            _ = try validatePublishedAsset(manifest: manifest, assetKey: assetKey)
            try updateIndexLocked(assetKey: assetKey, monotonicNs: nil, preserveExisting: true)
            return try publishedAsset(manifest: manifest, assetKey: assetKey)
          } catch {
            try removeVerifiedAssetDirectoryLocked(assetKey: assetKey)
          }
        }

        let reservation = try adding(entry.archiveSize, entry.extractedUpperBound)
        try ensureCapacityLocked(reserving: reservation, protectedAssetKeys: [assetKey])
        let filesByRole = try validateArchive(entries: archiveEntries, entry: entry)
        let temporaryName = ".(assetKey).(UUID().uuidString.lowercased()).tmp"
        let temporaryPath = assetsPath + "/" + temporaryName
        try posix.ensureDirectory(temporaryPath)
        var committed = false
        defer {
          if !committed {
            try? removeOwnedTree(temporaryPath)
          }
        }

        let rolesPath = temporaryPath + "/roles"
        try posix.ensureDirectory(rolesPath)
        try posix.createRoleFile(Data(try manifest.canonicalBytes), at: temporaryPath + "/manifest.v1.json")
        for (index, file) in manifest.files.enumerated() {
          guard let bytes = filesByRole[file.fileRole] else {
            throw DeveloperImageAssetStoreError.invalidArchive(file.fileRole)
          }
          try posix.createRoleFile(bytes, at: rolesPath + "/" + file.fileRole)
          if fault == .afterFirstRoleFsync && index == 0 {
            throw DeveloperImageAssetStoreError.systemCall(
              operation: "fault-after-first-role-fsync",
              errno: EIO
            )
          }
        }
        try posix.fsyncDirectory(rolesPath)
        try posix.fsyncDirectory(temporaryPath)
        if fault == .beforeAtomicRename {
          throw DeveloperImageAssetStoreError.systemCall(
            operation: "fault-before-atomic-rename",
            errno: EIO
          )
        }
        let finalPath = assetPath(assetKey: assetKey)
        guard !fileManager.fileExists(atPath: finalPath) else {
          throw DeveloperImageAssetStoreError.integrityMismatch(assetKey)
        }
        do {
          try fileManager.moveItem(atPath: temporaryPath, toPath: finalPath)
        } catch {
          throw DeveloperImageAssetStoreError.systemCall(operation: "rename-asset", errno: EIO)
        }
        committed = true
        try posix.fsyncDirectory(assetsPath)
        _ = try validatePublishedAsset(manifest: manifest, assetKey: assetKey)
        try updateIndexLocked(assetKey: assetKey, monotonicNs: nil, preserveExisting: true)
        return try publishedAsset(manifest: manifest, assetKey: assetKey)
      }
    }
  }

  public func publishSelectedXcode(
    catalog: DeveloperImageCatalogV1,
    entryID: String,
    snapshot: SelectedXcodeSnapshot
  ) throws -> DeveloperImagePublishedAsset? {
    _ = try createOrValidateCatalog(catalog)
    let entry = try catalogEntry(catalog, entryID: entryID)
    guard let rolePaths = try DeveloperImageSourceResolver.validatedXcodeRolePaths(
      snapshot: snapshot,
      entry: entry
    ) else {
      return nil
    }

    var archiveEntries: [DeveloperImageArchiveEntry] = []
    archiveEntries.reserveCapacity(entry.files.count)
    for file in entry.files {
      guard let path = rolePaths[file.fileRole] else {
        throw DeveloperImageAssetStoreError.integrityMismatch(file.fileRole)
      }
      let bytes = try posix.readExternalRegularFile(path, maximumBytes: file.size)
      guard UInt64(bytes.count) == file.size,
        StableBytes.sha256Hex(bytes) == file.sha256
      else {
        throw DeveloperImageAssetStoreError.integrityMismatch(file.fileRole)
      }
      archiveEntries.append(DeveloperImageArchiveEntry(
        path: file.archiveRelativePath,
        kind: .regularFile,
        bytes: bytes
      ))
    }
    return try publish(
      catalog: catalog,
      entryID: entryID,
      archiveEntries: archiveEntries
    )
  }

  public func persistPartial(
    state: PartialDownloadStateV1,
    bytes: Data
  ) throws {
    _ = try state.validated(partialFileSize: UInt64(bytes.count))
    guard StableBytes.isLowercaseHex(state.assetKey, byteCount: 32) else {
      throw DeveloperImageAssetStoreError.invalidAssetKey
    }
    let sidecar = try canonicalData(state, maximumBytes: PartialDownloadStateV1.maximumCanonicalBytes)
    try withStoreLock {
      try withAssetLock(assetKey: state.assetKey, operation: LOCK_EX) {
        try ensureCapacityLocked(
          reserving: try adding(UInt64(bytes.count), UInt64(sidecar.count)),
          protectedAssetKeys: [state.assetKey]
        )
        try posix.atomicWrite(bytes, to: partialPath(assetKey: state.assetKey))
        do {
          try posix.atomicWrite(sidecar, to: partialStatePath(assetKey: state.assetKey))
        } catch {
          _ = unlink(partialPath(assetKey: state.assetKey))
          throw error
        }
      }
    }
  }

  public func adoptPartial(
    catalog: DeveloperImageCatalogV1,
    entryID: String,
    sourceIndex: UInt64
  ) throws -> PartialDownloadAdoption {
    let identity = try createOrValidateCatalog(catalog)
    let entry = try catalogEntry(catalog, entryID: entryID)
    let assetKey = try entry.assetManifest.assetKey
    return try withStoreLock {
      try withAssetLock(assetKey: assetKey, operation: LOCK_EX) {
        let partial = partialPath(assetKey: assetKey)
        let sidecar = partialStatePath(assetKey: assetKey)
        let hasPartial = fileManager.fileExists(atPath: partial)
        let hasSidecar = fileManager.fileExists(atPath: sidecar)
        guard hasPartial || hasSidecar else { return .absent }
        guard hasPartial && hasSidecar else {
          try discardPartialLocked(assetKey: assetKey)
          return .discarded
        }
        do {
          let partialSize = try posix.regularFileSize(partial)
          let sidecarBytes = try posix.readRegularFile(
            sidecar,
            maximumBytes: UInt64(PartialDownloadStateV1.maximumCanonicalBytes)
          )
          _ = try RepositoryCanonicalJSON.validateCanonicalDocument(
            [UInt8](sidecarBytes),
            maximumByteCount: PartialDownloadStateV1.maximumCanonicalBytes
          )
          let state = try JSONDecoder().decode(PartialDownloadStateV1.self, from: sidecarBytes)
          guard try DeveloperImageSourcePolicy.mayAdopt(
            state: state,
            partialFileSize: partialSize,
            catalogIdentity: identity,
            entryID: entry.entryID,
            assetKey: assetKey
          ),
            state.archiveSize == entry.archiveSize,
            state.archiveSHA256 == entry.archiveSHA256,
            state.sourceIndex == sourceIndex,
            sourceIndex < UInt64(entry.sourceURLs.count),
            state.sourceURLIdentityHash
              == (try DeveloperImageSourcePolicy.sourceURLIdentityHash(
                entry.sourceURLs[Int(sourceIndex)]
              )),
            state.strongETag != nil
          else {
            throw DeveloperImageAssetStoreError.invalidPartialState
          }
          return .adopted(state)
        } catch {
          try discardPartialLocked(assetKey: assetKey)
          return .discarded
        }
      }
    }
  }

  public func accounting() throws -> DeveloperImageStoreAccounting {
    try withStoreLock { try accountingLocked() }
  }

  public func rebuildIndex() throws -> DeveloperImageCacheIndexV1 {
    try withStoreLock {
      let entries = try rebuildIndexLocked()
      let data = try canonicalIndexData(entries)
      return try JSONDecoder().decode(DeveloperImageCacheIndexV1.self, from: data)
    }
  }

  public func setAccessRecency(assetKey: String, monotonicNs: UInt64?) throws {
    try validateAssetKey(assetKey)
    try withStoreLock {
      guard fileManager.fileExists(atPath: assetPath(assetKey: assetKey)) else {
        throw DeveloperImageAssetStoreError.integrityMismatch(assetKey)
      }
      try updateIndexLocked(assetKey: assetKey, monotonicNs: monotonicNs, preserveExisting: false)
    }
  }

  @discardableResult
  public func prune(
    to targetBytes: UInt64? = nil,
    activeAssetKeys: Set<String> = [],
    requiredAssetKeys: Set<String> = []
  ) throws -> [String] {
    try withStoreLock {
      try pruneLocked(
        to: targetBytes ?? limits.softTargetBytes,
        protectedAssetKeys: activeAssetKeys.union(requiredAssetKeys)
      )
    }
  }

  public func withAcquisitionOwnership<Result>(
    assetKey: String,
    _ body: () throws -> Result
  ) throws -> Result {
    try validateAssetKey(assetKey)
    return try withStoreLock {
      try withAssetLock(assetKey: assetKey, operation: LOCK_EX, body)
    }
  }

  /// Persists only the eligibility to re-check an already prepared device in a
  /// later Runtime process. The receipt itself never represents readiness.
  public func recordPreparationRehydrationEligibility(
    _ receipt: DeveloperSupportRehydrationEligibilityReceipt
  ) throws {
    try validatePreparationRehydrationEligibility(receipt)
    let bytes = try canonicalData(
      receipt,
      maximumBytes: Self.maximumPreparationRehydrationReceiptBytes
    )
    try withStoreLock {
      let component = preparationRehydrationComponent(
        targetIdentityHash: receipt.targetIdentityHash
      )
      let existing = try childNames(in: preparationRehydrationPath)
      guard existing.allSatisfy({
        Self.validPreparationRehydrationComponent($0)
      }) else {
        throw DeveloperImageAssetStoreError.unsafeNode(
          preparationRehydrationPath
        )
      }
      guard existing.contains(component)
        || existing.count < Self.maximumPreparationRehydrationReceiptCount
      else {
        throw DeveloperImageAssetStoreError.capacityExceeded
      }
      try posix.atomicWrite(
        bytes,
        to: preparationRehydrationPath + "/" + component
      )
    }
  }

  /// Returns true only for a canonical, exact receipt. Corrupt receipt bytes
  /// are treated as absent so callers remain fail-closed and run normal
  /// preparation instead of trusting host metadata.
  public func hasPreparationRehydrationEligibility(
    _ expected: DeveloperSupportRehydrationEligibilityReceipt
  ) throws -> Bool {
    try validatePreparationRehydrationEligibility(expected)
    return try withStoreLock {
      let path = preparationRehydrationPath + "/"
        + preparationRehydrationComponent(
          targetIdentityHash: expected.targetIdentityHash
        )
      guard fileManager.fileExists(atPath: path) else { return false }
      do {
        let bytes = try posix.readRegularFile(
          path,
          maximumBytes: UInt64(Self.maximumPreparationRehydrationReceiptBytes)
        )
        _ = try RepositoryCanonicalJSON.validateCanonicalDocument(
          [UInt8](bytes),
          maximumByteCount: Self.maximumPreparationRehydrationReceiptBytes
        )
        let receipt = try JSONDecoder().decode(
          DeveloperSupportRehydrationEligibilityReceipt.self,
          from: bytes
        )
        try validatePreparationRehydrationEligibility(receipt)
        return receipt == expected
      } catch {
        return false
      }
    }
  }

  private var catalogsPath: String { rootURL.path + "/catalogs" }
  private var assetsPath: String { rootURL.path + "/assets" }
  private var downloadsPath: String { rootURL.path + "/downloads" }
  private var locksPath: String { rootURL.path + "/locks" }
  private var statePath: String { rootURL.path + "/state" }
  private var preparationRehydrationPath: String {
    statePath + "/preparation-rehydration"
  }
  private var storeLockPath: String { locksPath + "/asset-store.lock" }
  private var indexPath: String { statePath + "/cache-index.v1.json" }

  private static let maximumPreparationRehydrationReceiptBytes = 4 * 1_024
  private static let maximumPreparationRehydrationReceiptCount = 64

  private func bootstrap() throws {
    try posix.ensureDirectory(rootURL.path)
    for path in [
      catalogsPath, assetsPath, downloadsPath, locksPath, statePath,
      preparationRehydrationPath,
    ] {
      try posix.ensureDirectory(path)
    }
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableRoot = rootURL
    do {
      try mutableRoot.setResourceValues(values)
    } catch {
      throw DeveloperImageAssetStoreError.systemCall(
        operation: "exclude-developer-images-from-backup",
        errno: EIO
      )
    }
    let descriptor = try posix.openLock(storeLockPath, operation: LOCK_EX)
    _ = flock(descriptor, LOCK_UN)
    Darwin.close(descriptor)
  }

  private func withStoreLock<Result>(_ body: () throws -> Result) throws -> Result {
    let descriptor = try posix.openLock(storeLockPath, operation: LOCK_EX)
    defer {
      _ = flock(descriptor, LOCK_UN)
      Darwin.close(descriptor)
    }
    return try body()
  }

  private func withAssetLock<Result>(
    assetKey: String,
    operation: Int32,
    nonblocking: Bool = false,
    _ body: () throws -> Result
  ) throws -> Result {
    let descriptor = try openAssetLock(
      assetKey: assetKey,
      operation: operation,
      nonblocking: nonblocking
    )
    defer {
      _ = flock(descriptor, LOCK_UN)
      Darwin.close(descriptor)
    }
    return try body()
  }

  private func openAssetLock(
    assetKey: String,
    operation: Int32,
    nonblocking: Bool = false
  ) throws -> Int32 {
    try validateAssetKey(assetKey)
    return try posix.openLock(
      locksPath + "/" + assetKey + ".lock",
      operation: operation,
      nonblocking: nonblocking
    )
  }

  private func catalogPath(revision: String) -> String {
    catalogsPath + "/" + revision + ".json"
  }

  private func assetPath(assetKey: String) -> String {
    assetsPath + "/" + assetKey
  }

  private func partialPath(assetKey: String) -> String {
    downloadsPath + "/" + assetKey + ".partial"
  }

  private func partialStatePath(assetKey: String) -> String {
    downloadsPath + "/" + assetKey + ".partial.v1.json"
  }

  private func preparationRehydrationComponent(
    targetIdentityHash: String
  ) -> String {
    targetIdentityHash + ".v1.json"
  }

  private static func validPreparationRehydrationComponent(
    _ component: String
  ) -> Bool {
    guard component.hasSuffix(".v1.json") else { return false }
    let hash = String(component.dropLast(".v1.json".utf8.count))
    return StableBytes.isLowercaseHex(hash, byteCount: 32)
  }

  private func validatePreparationRehydrationEligibility(
    _ receipt: DeveloperSupportRehydrationEligibilityReceipt
  ) throws {
    guard receipt.schemaVersion == 1,
      StableBytes.isLowercaseHex(receipt.targetIdentityHash, byteCount: 32),
      validPreparationRehydrationText(receipt.buildVersion),
      validPreparationRehydrationText(receipt.preparationGroupID),
      validPreparationRehydrationText(receipt.productType),
      validPreparationRehydrationText(receipt.productVersion)
    else {
      throw DeveloperImageAssetStoreError.invalidPreparationRehydrationEligibility
    }
  }

  private func validPreparationRehydrationText(_ value: String) -> Bool {
    let bytes = value.utf8
    return !bytes.isEmpty
      && bytes.count <= 128
      && bytes.allSatisfy { (0x21...0x7e).contains($0) }
  }

  private func catalogEntry(
    _ catalog: DeveloperImageCatalogV1,
    entryID: String
  ) throws -> DeveloperImageCatalogEntryV1 {
    guard let entry = catalog.entries.first(where: { $0.entryID == entryID }) else {
      throw DeveloperImageAssetStoreError.invalidCatalogEntry(entryID)
    }
    return entry
  }

  private func validateArchive(
    entries: [DeveloperImageArchiveEntry],
    entry: DeveloperImageCatalogEntryV1
  ) throws -> [String: Data] {
    var byPath: [String: DeveloperImageArchiveEntry] = [:]
    var total: UInt64 = 0
    for archiveEntry in entries {
      try posix.validateArchivePath(archiveEntry.path)
      guard archiveEntry.kind == .regularFile,
        byPath.updateValue(archiveEntry, forKey: archiveEntry.path) == nil
      else {
        throw DeveloperImageAssetStoreError.invalidArchive(archiveEntry.path)
      }
      total = try adding(total, UInt64(archiveEntry.bytes.count))
    }
    guard total <= entry.extractedUpperBound,
      Set(byPath.keys) == Set(entry.files.map(\.archiveRelativePath))
    else {
      throw DeveloperImageAssetStoreError.invalidArchive("manifest coverage")
    }
    var result: [String: Data] = [:]
    for file in entry.files {
      guard let archiveEntry = byPath[file.archiveRelativePath],
        archiveEntry.bytes.count == Int(file.size),
        StableBytes.sha256Hex(archiveEntry.bytes) == file.sha256
      else {
        throw DeveloperImageAssetStoreError.integrityMismatch(file.fileRole)
      }
      result[file.fileRole] = archiveEntry.bytes
    }
    return result
  }

  private func validatePublishedAsset(
    manifest: AssetContentManifestV1,
    assetKey: String
  ) throws -> [String: DeveloperImageRoleFile] {
    let root = assetPath(assetKey: assetKey)
    try posix.validateDirectory(root)
    try posix.validateDirectory(root + "/roles")
    let manifestBytes = try posix.readRegularFile(root + "/manifest.v1.json", maximumBytes: 64 * 1_024)
    _ = try RepositoryCanonicalJSON.validateCanonicalDocument(
      [UInt8](manifestBytes),
      maximumByteCount: 64 * 1_024
    )
    let stored = try JSONDecoder().decode(AssetContentManifestV1.self, from: manifestBytes)
    guard try stored.validated() == manifest,
      try stored.assetKey == assetKey,
      [UInt8](manifestBytes) == (try stored.canonicalBytes)
    else {
      throw DeveloperImageAssetStoreError.integrityMismatch(assetKey)
    }
    let actualRoleNames = try childNames(in: root + "/roles")
    guard actualRoleNames == Set(manifest.files.map(\.fileRole)) else {
      throw DeveloperImageAssetStoreError.integrityMismatch("role coverage")
    }
    var handles: [String: DeveloperImageRoleFile] = [:]
    do {
      for file in manifest.files {
        handles[file.fileRole] = try posix.openValidatedRoleFile(
          root + "/roles/" + file.fileRole,
          fileRole: file.fileRole,
          expectedSize: file.size,
          expectedSHA256: file.sha256
        )
      }
      return handles
    } catch {
      handles.removeAll()
      throw error
    }
  }

  private func publishedAsset(
    manifest: AssetContentManifestV1,
    assetKey: String
  ) throws -> DeveloperImagePublishedAsset {
    var rolePaths: [String: String] = [:]
    for file in manifest.files {
      rolePaths[file.fileRole] = try DeveloperImageAssetIdentity.canonicalRoleRelativePath(
        assetKey: assetKey,
        fileRole: file.fileRole
      )
    }
    return DeveloperImagePublishedAsset(assetKey: assetKey, roleRelativePaths: rolePaths)
  }

  private func ensureCapacityLocked(
    reserving: UInt64,
    protectedAssetKeys: Set<String>
  ) throws {
    guard reserving <= limits.hardCapBytes else {
      throw DeveloperImageAssetStoreError.capacityExceeded
    }
    var accounting = try accountingLocked()
    if try adding(accounting.totalBytes, reserving) > limits.hardCapBytes {
      let target = min(limits.softTargetBytes, limits.hardCapBytes - reserving)
      _ = try pruneLocked(to: target, protectedAssetKeys: protectedAssetKeys)
      accounting = try accountingLocked()
    }
    guard try adding(accounting.totalBytes, reserving) <= limits.hardCapBytes else {
      throw DeveloperImageAssetStoreError.capacityExceeded
    }
  }

  private func pruneLocked(
    to targetBytes: UInt64,
    protectedAssetKeys: Set<String>
  ) throws -> [String] {
    var entries = try loadOrRebuildIndexEntriesLocked()
    entries.sort(by: evictionLessThan)
    var removed: [String] = []
    var current = try accountingLocked().totalBytes
    for entry in entries where current > targetBytes {
      guard !protectedAssetKeys.contains(entry.assetKey) else { continue }
      do {
        try withAssetLock(
          assetKey: entry.assetKey,
          operation: LOCK_EX,
          nonblocking: true
        ) {
          guard fileManager.fileExists(atPath: assetPath(assetKey: entry.assetKey)) else { return }
          try removeVerifiedAssetDirectoryLocked(assetKey: entry.assetKey)
          removed.append(entry.assetKey)
        }
      } catch DeveloperImageAssetStoreError.lockUnavailable {
        continue
      }
      current = try accountingLocked().totalBytes
    }
    _ = try rebuildIndexLocked()
    return removed
  }

  private func accountingLocked() throws -> DeveloperImageStoreAccounting {
    var assetBytes: UInt64 = 0
    var catalogBytes: UInt64 = 0
    var downloadBytes: UInt64 = 0
    var metadataBytes: UInt64 = 0
    guard let enumerator = fileManager.enumerator(
      at: rootURL,
      includingPropertiesForKeys: nil,
      options: []
    ) else {
      throw DeveloperImageAssetStoreError.unsafeNode(rootURL.path)
    }
    for case let url as URL in enumerator {
      var metadata = stat()
      guard lstat(url.path, &metadata) == 0 else {
        throw DeveloperImageAssetStoreError.systemCall(operation: "lstat-accounting", errno: errno)
      }
      let kind = metadata.st_mode & mode_t(S_IFMT)
      if kind == mode_t(S_IFDIR) {
        guard metadata.st_uid == geteuid(), metadata.st_mode & 0o7777 == 0o700 else {
          throw DeveloperImageAssetStoreError.unsafeNode(url.path)
        }
        continue
      }
      guard kind == mode_t(S_IFREG),
        metadata.st_uid == geteuid(),
        metadata.st_mode & 0o7777 == 0o600,
        metadata.st_nlink == 1,
        metadata.st_size >= 0
      else {
        throw DeveloperImageAssetStoreError.unsafeNode(url.path)
      }
      let size = UInt64(metadata.st_size)
      let components = url.pathComponents
      guard let rootIndex = components.lastIndex(of: rootURL.lastPathComponent),
        rootIndex + 1 < components.count
      else {
        throw DeveloperImageAssetStoreError.unsafeNode(url.path)
      }
      let topLevel = components[rootIndex + 1]
      if topLevel == "assets" {
        assetBytes = try adding(assetBytes, size)
      } else if topLevel == "catalogs" {
        catalogBytes = try adding(catalogBytes, size)
      } else if topLevel == "downloads" {
        downloadBytes = try adding(downloadBytes, size)
      } else {
        metadataBytes = try adding(metadataBytes, size)
      }
    }
    return DeveloperImageStoreAccounting(
      assetBytes: assetBytes,
      catalogBytes: catalogBytes,
      downloadBytes: downloadBytes,
      metadataBytes: metadataBytes
    )
  }

  private struct IndexEntry: Codable, Equatable {
    let assetKey: String
    let lastAccessMonotonicNs: UInt64?
  }

  private struct IndexDocument: Codable {
    let entries: [IndexEntry]
    let schemaVersion: UInt64
  }

  private func loadOrRebuildIndexEntriesLocked() throws -> [IndexEntry] {
    guard fileManager.fileExists(atPath: indexPath) else {
      return try rebuildIndexLocked()
    }
    do {
      let bytes = try posix.readRegularFile(indexPath, maximumBytes: 4 * 1_024 * 1_024)
      _ = try RepositoryCanonicalJSON.validateCanonicalDocument(
        [UInt8](bytes),
        maximumByteCount: 4 * 1_024 * 1_024
      )
      let document = try JSONDecoder().decode(IndexDocument.self, from: bytes)
      guard document.schemaVersion == 1,
        Set(document.entries.map(\.assetKey)).count == document.entries.count,
        document.entries.allSatisfy({ StableBytes.isLowercaseHex($0.assetKey, byteCount: 32) })
      else {
        return try rebuildIndexLocked()
      }
      return document.entries
    } catch let error as DeveloperImageAssetStoreError {
      throw error
    } catch {
      return try rebuildIndexLocked()
    }
  }

  private func rebuildIndexLocked() throws -> [IndexEntry] {
    let previous = try loadIndexRecencyWithoutRebuild()
    let keys = try validAssetKeysLocked()
    let entries = keys.sorted(by: asciiLessThan).map {
      IndexEntry(assetKey: $0, lastAccessMonotonicNs: previous[$0] ?? nil)
    }
    try posix.atomicWrite(try canonicalIndexData(entries), to: indexPath)
    return entries
  }

  private func loadIndexRecencyWithoutRebuild() throws -> [String: UInt64?] {
    guard fileManager.fileExists(atPath: indexPath) else { return [:] }
    let bytes = try posix.readRegularFile(indexPath, maximumBytes: 4 * 1_024 * 1_024)
    do {
      _ = try RepositoryCanonicalJSON.validateCanonicalDocument(
        [UInt8](bytes),
        maximumByteCount: 4 * 1_024 * 1_024
      )
      let document = try JSONDecoder().decode(IndexDocument.self, from: bytes)
      guard document.schemaVersion == 1,
        Set(document.entries.map(\.assetKey)).count == document.entries.count
      else { return [:] }
      return Dictionary(uniqueKeysWithValues: document.entries.map {
        ($0.assetKey, $0.lastAccessMonotonicNs)
      })
    } catch let error as DeveloperImageAssetStoreError {
      throw error
    } catch {
      return [:]
    }
  }

  private func updateIndexLocked(
    assetKey: String,
    monotonicNs: UInt64?,
    preserveExisting: Bool
  ) throws {
    var entries = try loadOrRebuildIndexEntriesLocked()
    let existing = entries.first(where: { $0.assetKey == assetKey })
    entries.removeAll(where: { $0.assetKey == assetKey })
    entries.append(
      IndexEntry(
        assetKey: assetKey,
        lastAccessMonotonicNs: preserveExisting ? existing?.lastAccessMonotonicNs : monotonicNs
      )
    )
    entries.sort { asciiLessThan($0.assetKey, $1.assetKey) }
    try posix.atomicWrite(try canonicalIndexData(entries), to: indexPath)
  }

  private func canonicalIndexData(_ entries: [IndexEntry]) throws -> Data {
    let document = IndexDocument(entries: entries, schemaVersion: 1)
    return try canonicalData(document, maximumBytes: 4 * 1_024 * 1_024)
  }

  private func validAssetKeysLocked() throws -> [String] {
    let names = try childNames(in: assetsPath).filter { !$0.hasPrefix(".") }
    var result: [String] = []
    for name in names.sorted(by: asciiLessThan) {
      guard StableBytes.isLowercaseHex(name, byteCount: 32) else {
        throw DeveloperImageAssetStoreError.unsafeNode(name)
      }
      try posix.validateDirectory(assetPath(assetKey: name))
      let manifestPath = assetPath(assetKey: name) + "/manifest.v1.json"
      do {
        let bytes = try posix.readRegularFile(manifestPath, maximumBytes: 64 * 1_024)
        let manifest = try JSONDecoder().decode(AssetContentManifestV1.self, from: bytes)
        _ = try validatePublishedAsset(manifest: manifest, assetKey: name)
        result.append(name)
      } catch DeveloperImageAssetStoreError.integrityMismatch {
        continue
      } catch is DecodingError {
        continue
      } catch is RepositoryCanonicalJSONError {
        continue
      }
    }
    return result
  }

  private func canonicalData<Value: Encodable>(
    _ value: Value,
    maximumBytes: Int
  ) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(value)
    let canonical = try RepositoryCanonicalJSON.validateCanonicalDocument(
      [UInt8](data),
      maximumByteCount: maximumBytes
    )
    return Data(canonical.exactBytes)
  }

  private func removeVerifiedAssetDirectoryLocked(assetKey: String) throws {
    let path = assetPath(assetKey: assetKey)
    guard fileManager.fileExists(atPath: path) else { return }
    try posix.validateDirectory(path)
    try removeOwnedTree(path)
    try posix.fsyncDirectory(assetsPath)
  }

  private func removeOwnedTree(_ path: String) throws {
    let root = URL(fileURLWithPath: path)
    if let enumerator = fileManager.enumerator(at: root, includingPropertiesForKeys: nil) {
      for case let url as URL in enumerator {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0,
          metadata.st_uid == geteuid(),
          metadata.st_mode & mode_t(S_IFMT) != mode_t(S_IFLNK)
        else {
          throw DeveloperImageAssetStoreError.unsafeNode(url.path)
        }
      }
    }
    try fileManager.removeItem(atPath: path)
  }

  private func removeStalePublishTempsLocked() throws {
    for name in try childNames(in: assetsPath) where name.hasPrefix(".") && name.hasSuffix(".tmp") {
      let path = assetsPath + "/" + name
      try posix.validateDirectory(path)
      try removeOwnedTree(path)
    }
  }

  private func discardPartialLocked(assetKey: String) throws {
    for path in [partialPath(assetKey: assetKey), partialStatePath(assetKey: assetKey)] {
      var metadata = stat()
      if lstat(path, &metadata) != 0 {
        guard errno == ENOENT else {
          throw DeveloperImageAssetStoreError.systemCall(operation: "lstat-partial", errno: errno)
        }
        continue
      }
      _ = try posix.regularFileSize(path)
      if unlink(path) != 0 {
        throw DeveloperImageAssetStoreError.systemCall(operation: "unlink-partial", errno: errno)
      }
    }
    try posix.fsyncDirectory(downloadsPath)
  }

  private func childNames(in path: String) throws -> Set<String> {
    try posix.validateDirectory(path)
    return Set(try fileManager.contentsOfDirectory(atPath: path))
  }

  private func regularChildren(in path: String) throws -> [String] {
    try childNames(in: path).sorted(by: asciiLessThan).map { path + "/" + $0 }
  }

  private func validateAssetKey(_ assetKey: String) throws {
    guard StableBytes.isLowercaseHex(assetKey, byteCount: 32) else {
      throw DeveloperImageAssetStoreError.invalidAssetKey
    }
  }

  private func adding(_ lhs: UInt64, _ rhs: UInt64) throws -> UInt64 {
    let (value, overflow) = lhs.addingReportingOverflow(rhs)
    guard !overflow else { throw DeveloperImageAssetStoreError.capacityExceeded }
    return value
  }

  private func evictionLessThan(_ lhs: IndexEntry, _ rhs: IndexEntry) -> Bool {
    switch (lhs.lastAccessMonotonicNs, rhs.lastAccessMonotonicNs) {
    case (nil, nil):
      return asciiLessThan(lhs.assetKey, rhs.assetKey)
    case (nil, _):
      return true
    case (_, nil):
      return false
    case (.some(let left), .some(let right)):
      return left == right ? asciiLessThan(lhs.assetKey, rhs.assetKey) : left < right
    }
  }

  private func asciiLessThan(_ lhs: String, _ rhs: String) -> Bool {
    lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
  }
}
