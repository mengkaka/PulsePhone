import Darwin
import Foundation
import PulsePhoneDeveloperSupportDefinitions
import PulsePhoneSharedDefinitions

public enum DynamicDeveloperImageAssetCacheError: Error, Equatable, Sendable {
  case archiveIntegrityFailed
  case cacheCapacityExceeded
  case contentManifestMismatch
  case sourceRejected
}

public final class DynamicDeveloperImageAssetLease: @unchecked Sendable {
  public let contentManifestSHA256: String
  public let roleFiles: [String: DeveloperImageRoleFile]
  private var lockDescriptor: Int32

  init(
    contentManifestSHA256: String,
    roleFiles: [String: DeveloperImageRoleFile],
    lockDescriptor: Int32
  ) {
    self.contentManifestSHA256 = contentManifestSHA256
    self.roleFiles = roleFiles
    self.lockDescriptor = lockDescriptor
  }

  deinit {
    if lockDescriptor >= 0 {
      _ = flock(lockDescriptor, LOCK_UN)
      Darwin.close(lockDescriptor)
    }
  }
}

/// Content-addressed dynamic DDI/BaseImage cache. The cache never records a
/// build mapping: selection is solely the pinned catalog snapshot's job.
public final class DynamicDeveloperImageAssetCache: @unchecked Sendable {
  public typealias ArchiveFetcher = @Sendable (_ url: URL, _ maximumBytes: UInt64) throws -> Data

  public let configuration: DynamicDeveloperImageCatalogStoreConfiguration
  public let rootURL: URL

  private let fetch: ArchiveFetcher
  private let fileManager: FileManager
  private let posix: AssetStorePOSIX

  public convenience init(
    rootURL: URL,
    configuration: DynamicDeveloperImageCatalogStoreConfiguration = .release
  ) throws {
    try self.init(
      rootURL: rootURL,
      configuration: configuration,
      fetch: BoundedHTTPSDataFetcher.fetch
    )
  }

  public init(
    rootURL: URL,
    configuration: DynamicDeveloperImageCatalogStoreConfiguration,
    fetch: @escaping ArchiveFetcher,
    fileManager: FileManager = .default
  ) throws {
    let standardized = rootURL.standardizedFileURL
    self.rootURL = standardized.deletingLastPathComponent()
      .resolvingSymlinksInPath()
      .appendingPathComponent(standardized.lastPathComponent, isDirectory: true)
    self.configuration = configuration
    self.fetch = fetch
    self.fileManager = fileManager
    self.posix = AssetStorePOSIX()
    try bootstrap()
  }

  public func openVerified(
    _ reference: DynamicDeveloperImageAssetReference
  ) throws -> DynamicDeveloperImageAssetLease? {
    try validate(reference)
    let lock = try posix.openLock(lockPath(reference), operation: LOCK_SH)
    do {
      guard fileManager.fileExists(atPath: contentPath(reference)) else {
        _ = flock(lock, LOCK_UN)
        Darwin.close(lock)
        return nil
      }
      let roles = try validatePublished(reference)
      return DynamicDeveloperImageAssetLease(
        contentManifestSHA256: reference.contentManifestSHA256,
        roleFiles: roles,
        lockDescriptor: lock
      )
    } catch {
      _ = flock(lock, LOCK_UN)
      Darwin.close(lock)
      throw error
    }
  }

  /// Downloads exactly one approved archive if the content-addressed cache is
  /// absent. Both the host-wide and per-content flock remain authoritative;
  /// PID, partial files and progress are never used as ownership proof.
  public func acquireRemote(
    _ reference: DynamicDeveloperImageAssetReference
  ) throws -> DynamicDeveloperImageAssetLease {
    try validate(reference)
    guard configuration.validatesArchiveURL(reference.sourceURL),
      let url = URL(string: reference.sourceURL)
    else {
      throw DynamicDeveloperImageAssetCacheError.sourceRejected
    }
    let storeLock = try posix.openLock(storeLockPath, operation: LOCK_EX)
    defer {
      _ = flock(storeLock, LOCK_UN)
      Darwin.close(storeLock)
    }
    let contentLock = try posix.openLock(lockPath(reference), operation: LOCK_EX)
    do {
      if fileManager.fileExists(atPath: contentPath(reference)) {
        let roles = try validatePublished(reference)
        return try makeSharedLease(
          reference: reference,
          roleFiles: roles,
          lockDescriptor: contentLock
        )
      }
      let archive = try fetch(url, reference.archiveSize)
      try validateArchiveBytes(archive, reference: reference)
      return try publishLocked(reference, archive: archive, lockDescriptor: contentLock)
    } catch {
      _ = flock(contentLock, LOCK_UN)
      Darwin.close(contentLock)
      throw error
    }
  }

  public func publish(
    _ reference: DynamicDeveloperImageAssetReference,
    archive: Data
  ) throws -> DynamicDeveloperImageAssetLease {
    try validate(reference)
    let storeLock = try posix.openLock(storeLockPath, operation: LOCK_EX)
    defer {
      _ = flock(storeLock, LOCK_UN)
      Darwin.close(storeLock)
    }
    let contentLock = try posix.openLock(lockPath(reference), operation: LOCK_EX)
    do {
      return try publishLocked(reference, archive: archive, lockDescriptor: contentLock)
    } catch {
      _ = flock(contentLock, LOCK_UN)
      Darwin.close(contentLock)
      throw error
    }
  }

  /// Imports the fixed content set of an already-selected asset. The caller
  /// owns source trust (the production caller uses the selected signed Xcode),
  /// while this method makes source substitution impossible by recomputing the
  /// catalog-approved content manifest before publishing it into the private
  /// content-addressed cache.
  public func importVerifiedContent(
    _ reference: DynamicDeveloperImageAssetReference,
    files: [String: Data]
  ) throws -> DynamicDeveloperImageAssetLease {
    try validate(reference)
    let storeLock = try posix.openLock(storeLockPath, operation: LOCK_EX)
    defer {
      _ = flock(storeLock, LOCK_UN)
      Darwin.close(storeLock)
    }
    let contentLock = try posix.openLock(lockPath(reference), operation: LOCK_EX)
    do {
      if fileManager.fileExists(atPath: contentPath(reference)) {
        let roles = try validatePublished(reference)
        return try makeSharedLease(
          reference: reference,
          roleFiles: roles,
          lockDescriptor: contentLock
        )
      }
      let roleData = try validatedLocalRoleData(files, reference: reference)
      let requiredBytes = roleData.values.reduce(UInt64(0)) {
        $0 + UInt64($1.count)
      }
      try ensureSpace(requiredBytes: requiredBytes + requiredBytes)
      return try publishRoleDataLocked(
        reference,
        roleData: roleData,
        lockDescriptor: contentLock
      )
    } catch {
      _ = flock(contentLock, LOCK_UN)
      Darwin.close(contentLock)
      throw error
    }
  }

  private var baseImagePath: String { rootURL.path + "/BaseImage" }
  private var developerDiskImagePath: String { rootURL.path + "/DDI" }
  private var locksPath: String { rootURL.path + "/locks" }
  private var storeLockPath: String { locksPath + "/asset-store.lock" }

  private func bootstrap() throws {
    try posix.ensureDirectory(rootURL.path)
    try posix.ensureDirectory(baseImagePath)
    try posix.ensureDirectory(developerDiskImagePath)
    try posix.ensureDirectory(locksPath)
    let descriptor = try posix.openLock(storeLockPath, operation: LOCK_EX)
    _ = flock(descriptor, LOCK_UN)
    Darwin.close(descriptor)
  }

  private func publishLocked(
    _ reference: DynamicDeveloperImageAssetReference,
    archive: Data,
    lockDescriptor: Int32
  ) throws -> DynamicDeveloperImageAssetLease {
    if fileManager.fileExists(atPath: contentPath(reference)) {
      let roles = try validatePublished(reference)
      return try makeSharedLease(
        reference: reference,
        roleFiles: roles,
        lockDescriptor: lockDescriptor
      )
    }
    try validateArchiveBytes(archive, reference: reference)
    let expectedPaths = DynamicDeveloperImageContentManifest.requiredPaths(for: reference.kind)
    let entries: [DeveloperImageArchiveEntry]
    do {
      entries = try DeveloperImageUSTARArchive.parse(
        archive,
        expectedPaths: expectedPaths,
        extractedUpperBound: reference.archiveSize
      )
    } catch {
      throw DynamicDeveloperImageAssetCacheError.archiveIntegrityFailed
    }
    let roleData = try validatedRoleData(entries, reference: reference)
    try ensureSpace(requiredBytes: UInt64(archive.count) + roleData.values.reduce(0) {
      $0 + UInt64($1.count)
    })

    return try publishRoleDataLocked(
      reference,
      roleData: roleData,
      lockDescriptor: lockDescriptor
    )
  }

  private func publishRoleDataLocked(
    _ reference: DynamicDeveloperImageAssetReference,
    roleData: [String: Data],
    lockDescriptor: Int32
  ) throws -> DynamicDeveloperImageAssetLease {
    let manifest = try makeStoredManifest(roleData: roleData, kind: reference.kind)
    let parent = contentParentPath(reference)
    let temporary = parent + "/." + UUID().uuidString.lowercased() + ".tmp"
    try posix.ensureDirectory(temporary)
    var published = false
    defer {
      if !published { try? removeOwnedTree(temporary) }
    }
    let rolesPath = temporary + "/roles"
    try posix.ensureDirectory(rolesPath)
    try posix.createRoleFile(Data(try manifest.canonicalBytes), at: temporary + "/manifest.v1.json")
    for file in manifest.files {
      guard let bytes = roleData[file.fileRole] else {
        throw DynamicDeveloperImageAssetCacheError.contentManifestMismatch
      }
      try posix.createRoleFile(bytes, at: rolesPath + "/" + file.fileRole)
    }
    try posix.fsyncDirectory(rolesPath)
    try posix.fsyncDirectory(temporary)
    do {
      try fileManager.moveItem(atPath: temporary, toPath: contentPath(reference))
    } catch {
      throw DynamicDeveloperImageAssetCacheError.archiveIntegrityFailed
    }
    published = true
    try posix.fsyncDirectory(parent)
    let roles = try validatePublished(reference)
    return try makeSharedLease(
      reference: reference,
      roleFiles: roles,
      lockDescriptor: lockDescriptor
    )
  }

  private func makeSharedLease(
    reference: DynamicDeveloperImageAssetReference,
    roleFiles: [String: DeveloperImageRoleFile],
    lockDescriptor: Int32
  ) throws -> DynamicDeveloperImageAssetLease {
    try posix.downgradeToSharedLock(lockDescriptor)
    return DynamicDeveloperImageAssetLease(
      contentManifestSHA256: reference.contentManifestSHA256,
      roleFiles: roleFiles,
      lockDescriptor: lockDescriptor
    )
  }

  private func validateArchiveBytes(
    _ archive: Data,
    reference: DynamicDeveloperImageAssetReference
  ) throws {
    guard UInt64(archive.count) == reference.archiveSize,
      StableBytes.sha256Hex(archive) == reference.archiveSHA256
    else {
      throw DynamicDeveloperImageAssetCacheError.archiveIntegrityFailed
    }
  }

  private func validatedRoleData(
    _ entries: [DeveloperImageArchiveEntry],
    reference: DynamicDeveloperImageAssetReference
  ) throws -> [String: Data] {
    let expectedPaths = DynamicDeveloperImageContentManifest.requiredPaths(for: reference.kind)
    guard Set(entries.map(\.path)) == expectedPaths,
      entries.allSatisfy({ $0.kind == .regularFile })
    else {
      throw DynamicDeveloperImageAssetCacheError.archiveIntegrityFailed
    }
    let files = entries.map {
      DynamicDeveloperImageContentFile(
        path: $0.path,
        sha256: StableBytes.sha256Hex($0.bytes),
        size: UInt64($0.bytes.count)
      )
    }.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    guard try DynamicDeveloperImageContentManifest.sha256(files)
      == reference.contentManifestSHA256
    else {
      throw DynamicDeveloperImageAssetCacheError.contentManifestMismatch
    }
    var result = [String: Data]()
    for entry in entries {
      guard let role = role(for: entry.path, kind: reference.kind),
        result.updateValue(entry.bytes, forKey: role) == nil
      else {
        throw DynamicDeveloperImageAssetCacheError.archiveIntegrityFailed
      }
    }
    return result
  }

  private func validatedLocalRoleData(
    _ files: [String: Data],
    reference: DynamicDeveloperImageAssetReference
  ) throws -> [String: Data] {
    let expectedPaths = DynamicDeveloperImageContentManifest.requiredPaths(for: reference.kind)
    guard Set(files.keys) == expectedPaths,
      files.values.allSatisfy({ !$0.isEmpty })
    else {
      throw DynamicDeveloperImageAssetCacheError.contentManifestMismatch
    }
    let contentFiles = try files.map { path, bytes -> DynamicDeveloperImageContentFile in
      guard let role = role(for: path, kind: reference.kind), !role.isEmpty else {
        throw DynamicDeveloperImageAssetCacheError.contentManifestMismatch
      }
      return DynamicDeveloperImageContentFile(
        path: path,
        sha256: StableBytes.sha256Hex(bytes),
        size: UInt64(bytes.count)
      )
    }.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    guard try DynamicDeveloperImageContentManifest.sha256(contentFiles)
      == reference.contentManifestSHA256
    else {
      throw DynamicDeveloperImageAssetCacheError.contentManifestMismatch
    }
    var roleData = [String: Data]()
    for (path, bytes) in files {
      guard let role = role(for: path, kind: reference.kind),
        roleData.updateValue(bytes, forKey: role) == nil
      else {
        throw DynamicDeveloperImageAssetCacheError.contentManifestMismatch
      }
    }
    return roleData
  }

  private func makeStoredManifest(
    roleData: [String: Data],
    kind: DynamicDeveloperImageAssetKind
  ) throws -> AssetContentManifestV1 {
    let imageKind: DeveloperImageKind = kind == .baseImage ? .personalized : .classic
    let files = try roleData.map { role, bytes in
      try DeveloperImageAssetIdentity.validate(role: role)
      return AssetContentFileV1(
        fileRole: role,
        sha256: StableBytes.sha256Hex(bytes),
        size: UInt64(bytes.count)
      )
    }.sorted { $0.fileRole.utf8.lexicographicallyPrecedes($1.fileRole.utf8) }
    return try AssetContentManifestV1(files: files, imageKind: imageKind).validated()
  }

  private func validatePublished(
    _ reference: DynamicDeveloperImageAssetReference
  ) throws -> [String: DeveloperImageRoleFile] {
    let root = contentPath(reference)
    try posix.validateDirectory(root)
    try posix.validateDirectory(root + "/roles")
    let bytes = try posix.readRegularFile(root + "/manifest.v1.json", maximumBytes: 64 * 1_024)
    _ = try RepositoryCanonicalJSON.validateCanonicalDocument(
      [UInt8](bytes),
      maximumByteCount: 64 * 1_024
    )
    let manifest = try JSONDecoder().decode(AssetContentManifestV1.self, from: bytes)
    let expectedKind: DeveloperImageKind = reference.kind == .baseImage ? .personalized : .classic
    guard manifest.imageKind == expectedKind,
      try manifest.validated() == manifest,
      [UInt8](bytes) == (try manifest.canonicalBytes)
    else {
      throw DynamicDeveloperImageAssetCacheError.contentManifestMismatch
    }
    var contentFiles = [DynamicDeveloperImageContentFile]()
    var handles = [String: DeveloperImageRoleFile]()
    do {
      for file in manifest.files {
        let path = try archivePath(for: file.fileRole, kind: reference.kind)
        contentFiles.append(DynamicDeveloperImageContentFile(
          path: path,
          sha256: file.sha256,
          size: file.size
        ))
        handles[file.fileRole] = try posix.openValidatedRoleFile(
          root + "/roles/" + file.fileRole,
          fileRole: file.fileRole,
          expectedSize: file.size,
          expectedSHA256: file.sha256
        )
      }
      guard try DynamicDeveloperImageContentManifest.sha256(
        contentFiles.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
      ) == reference.contentManifestSHA256,
        Set(handles.keys) == expectedRoles(for: reference.kind)
      else {
        throw DynamicDeveloperImageAssetCacheError.contentManifestMismatch
      }
      return handles
    } catch {
      handles.removeAll()
      throw error
    }
  }

  private func validate(_ reference: DynamicDeveloperImageAssetReference) throws {
    guard StableBytes.isLowercaseHex(reference.archiveSHA256, byteCount: 32),
      StableBytes.isLowercaseHex(reference.contentManifestSHA256, byteCount: 32),
      reference.archiveSize > 0
    else {
      throw DynamicDeveloperImageAssetCacheError.contentManifestMismatch
    }
  }

  private func contentParentPath(_ reference: DynamicDeveloperImageAssetReference) -> String {
    reference.kind == .baseImage ? baseImagePath : developerDiskImagePath
  }

  private func contentPath(_ reference: DynamicDeveloperImageAssetReference) -> String {
    contentParentPath(reference) + "/" + reference.contentManifestSHA256
  }

  private func lockPath(_ reference: DynamicDeveloperImageAssetReference) -> String {
    locksPath + "/" + reference.contentManifestSHA256 + ".lock"
  }

  private func ensureSpace(requiredBytes: UInt64) throws {
    var stats = statfs()
    guard statfs(rootURL.path, &stats) == 0 else {
      throw DynamicDeveloperImageAssetCacheError.cacheCapacityExceeded
    }
    let available = UInt64(stats.f_bavail) * UInt64(stats.f_bsize)
    guard available >= requiredBytes else {
      throw DynamicDeveloperImageAssetCacheError.cacheCapacityExceeded
    }
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
          throw DynamicDeveloperImageAssetCacheError.archiveIntegrityFailed
        }
      }
    }
    try fileManager.removeItem(atPath: path)
  }

  private func expectedRoles(for kind: DynamicDeveloperImageAssetKind) -> Set<String> {
    switch kind {
    case .baseImage:
      return [
        DeveloperImageFileRole.personalizedBuildManifest.rawValue,
        DeveloperImageFileRole.personalizedImage.rawValue,
        DeveloperImageFileRole.personalizedTrustCache.rawValue,
      ]
    case .developerDiskImage:
      return [
        DeveloperImageFileRole.classicImage.rawValue,
        DeveloperImageFileRole.classicSignature.rawValue,
      ]
    }
  }

  private func role(for path: String, kind: DynamicDeveloperImageAssetKind) -> String? {
    switch (kind, path) {
    case (.baseImage, "BuildManifest.plist"):
      return DeveloperImageFileRole.personalizedBuildManifest.rawValue
    case (.baseImage, "Image.dmg"):
      return DeveloperImageFileRole.personalizedImage.rawValue
    case (.baseImage, "Image.dmg.trustcache"):
      return DeveloperImageFileRole.personalizedTrustCache.rawValue
    case (.developerDiskImage, "DeveloperDiskImage.dmg"):
      return DeveloperImageFileRole.classicImage.rawValue
    case (.developerDiskImage, "DeveloperDiskImage.dmg.signature"):
      return DeveloperImageFileRole.classicSignature.rawValue
    default:
      return nil
    }
  }

  private func archivePath(for role: String, kind: DynamicDeveloperImageAssetKind) throws -> String {
    switch (kind, DeveloperImageFileRole(rawValue: role)) {
    case (.baseImage, .personalizedBuildManifest): return "BuildManifest.plist"
    case (.baseImage, .personalizedImage): return "Image.dmg"
    case (.baseImage, .personalizedTrustCache): return "Image.dmg.trustcache"
    case (.developerDiskImage, .classicImage): return "DeveloperDiskImage.dmg"
    case (.developerDiskImage, .classicSignature): return "DeveloperDiskImage.dmg.signature"
    default: throw DynamicDeveloperImageAssetCacheError.contentManifestMismatch
    }
  }
}
