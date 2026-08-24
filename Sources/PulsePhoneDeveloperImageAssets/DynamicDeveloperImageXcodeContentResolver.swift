import Darwin
import Foundation
import PulsePhoneDeveloperSupportDefinitions
import PulsePhoneSharedDefinitions

/// Resolves an iOS 17+ BaseImage from Xcode's host DDI inventory. Xcode names
/// personalized payload files in BuildManifest.plist, so the catalog content
/// manifest remains the sole authority for selecting a usable tuple.
public enum DynamicDeveloperImageXcodeContentResolver {
  public static func matchingBaseImageFiles(
    for reference: DynamicDeveloperImageAssetReference,
    root: String
  ) -> [String: Data]? {
    guard reference.kind == .baseImage, isCanonicalAbsolutePath(root),
      let manifest = readRegularFile(
        at: root + "/BuildManifest.plist",
        maximumBytes: UInt64(Int.max)
      )
    else {
      return nil
    }

    let fixed = [
      "BuildManifest.plist": manifest,
      "Image.dmg": readRegularFile(
        at: root + "/Image.dmg",
        maximumBytes: UInt64(Int.max)
      ),
      "Image.dmg.trustcache": readRegularFile(
        at: root + "/Image.dmg.trustcache",
        maximumBytes: UInt64(Int.max)
      ),
    ]
    if let files = fixedRoleFiles(fixed), matches(reference: reference, files: files) {
      return files
    }

    guard let rolePaths = personalizedRolePaths(in: manifest) else {
      return nil
    }
    for (imagePath, trustCachePath) in rolePaths {
      guard let image = readRegularFile(
        at: root + "/" + imagePath,
        maximumBytes: UInt64(Int.max)
      ), let trustCache = readRegularFile(
        at: root + "/" + trustCachePath,
        maximumBytes: UInt64(Int.max)
      ) else {
        continue
      }
      let files = [
        "BuildManifest.plist": manifest,
        "Image.dmg": image,
        "Image.dmg.trustcache": trustCache,
      ]
      if matches(reference: reference, files: files) {
        return files
      }
    }
    return nil
  }

  /// Finds a classic DDI by its catalog-authorized content identity, rather
  /// than by an Xcode directory name. Xcode releases are free to rearrange
  /// their DeviceSupport directories; only the complete role-file manifest is
  /// an admission credential.
  public static func matchingDeveloperDiskImageFiles(
    for reference: DynamicDeveloperImageAssetReference,
    root: String
  ) -> [String: Data]? {
    guard reference.kind == .developerDiskImage,
      isCanonicalAbsolutePath(root),
      let directories = directChildDirectories(in: root)
    else {
      return nil
    }
    for directory in directories {
      let candidate = root + "/" + directory
      let fixed = [
        "DeveloperDiskImage.dmg": readRegularFile(
          at: candidate + "/DeveloperDiskImage.dmg",
          maximumBytes: UInt64(Int.max)
        ),
        "DeveloperDiskImage.dmg.signature": readRegularFile(
          at: candidate + "/DeveloperDiskImage.dmg.signature",
          maximumBytes: UInt64(Int.max)
        ),
      ]
      guard let files = fixedRoleFiles(fixed) else { continue }
      if matches(reference: reference, files: files) {
        return files
      }
    }
    return nil
  }

  private static func fixedRoleFiles(
    _ candidates: [String: Data?]
  ) -> [String: Data]? {
    var result = [String: Data]()
    result.reserveCapacity(candidates.count)
    for (path, bytes) in candidates {
      guard let bytes, result.updateValue(bytes, forKey: path) == nil else {
        return nil
      }
    }
    return result
  }

  private static func personalizedRolePaths(
    in manifestBytes: Data
  ) -> [(String, String)]? {
    guard let propertyList = try? PropertyListSerialization.propertyList(
      from: manifestBytes,
      options: [],
      format: nil
    ) as? [String: Any], let identities = propertyList["BuildIdentities"] as? [[String: Any]]
    else {
      return nil
    }

    var pairs = Set<RolePathPair>()
    for identity in identities {
      guard
        let manifest = identity["Manifest"] as? [String: Any],
        let image = manifest["PersonalizedDMG"] as? [String: Any],
        let imageInfo = image["Info"] as? [String: Any],
        let imagePath = imageInfo["Path"] as? String,
        let trustCache = manifest["LoadableTrustCache"] as? [String: Any],
        let trustCacheInfo = trustCache["Info"] as? [String: Any],
        let trustCachePath = trustCacheInfo["Path"] as? String,
        isSafeRelativePath(imagePath),
        isSafeRelativePath(trustCachePath)
      else {
        continue
      }
      pairs.insert(RolePathPair(image: imagePath, trustCache: trustCachePath))
    }
    let ordered = pairs.sorted {
      if $0.image != $1.image { return $0.image.utf8.lexicographicallyPrecedes($1.image.utf8) }
      return $0.trustCache.utf8.lexicographicallyPrecedes($1.trustCache.utf8)
    }
    return ordered.isEmpty ? nil : ordered.map { ($0.image, $0.trustCache) }
  }

  private static func matches(
    reference: DynamicDeveloperImageAssetReference,
    files: [String: Data]
  ) -> Bool {
    guard Set(files.keys) == DynamicDeveloperImageContentManifest.requiredPaths(for: reference.kind) else {
      return false
    }
    let manifest = files.map { path, bytes in
      DynamicDeveloperImageContentFile(
        path: path,
        sha256: StableBytes.sha256Hex(bytes),
        size: UInt64(bytes.count)
      )
    }.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    return (try? DynamicDeveloperImageContentManifest.sha256(manifest))
      == reference.contentManifestSHA256
  }

  private static func directChildDirectories(in root: String) -> [String]? {
    guard isDirectory(root) else { return nil }
    do {
      return try FileManager.default.contentsOfDirectory(atPath: root)
        .filter { isSafeDirectChildName($0) && isDirectory(root + "/" + $0) }
        .sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
    } catch {
      return nil
    }
  }

  private static func isCanonicalAbsolutePath(_ path: String) -> Bool {
    path.hasPrefix("/")
      && !path.hasSuffix("/")
      && URL(fileURLWithPath: path).standardizedFileURL.path == path
  }

  private static func isDirectory(_ path: String) -> Bool {
    var status = stat()
    return lstat(path, &status) == 0
      && status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR)
  }

  private static func isSafeDirectChildName(_ value: String) -> Bool {
    !value.isEmpty
      && value != "."
      && value != ".."
      && !value.contains("/")
      && !value.contains("\0")
  }

  private static func isSafeRelativePath(_ path: String) -> Bool {
    !path.isEmpty
      && !path.hasPrefix("/")
      && path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy {
        !$0.isEmpty
          && $0 != "."
          && $0 != ".."
          && $0.utf8.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39)
              || ($0 >= 0x41 && $0 <= 0x5A)
              || ($0 >= 0x61 && $0 <= 0x7A)
              || $0 == 0x2D || $0 == 0x2E || $0 == 0x5F
          }
      }
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

  private struct RolePathPair: Hashable {
    let image: String
    let trustCache: String
  }
}
