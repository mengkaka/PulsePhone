import Darwin
import Foundation
import PulsePhoneSharedDefinitions

public enum CanonicalAppPathError: Error, Equatable, Sendable {
    case invalidSyntax
    case currentExecutablePathUnavailable
    case realpathFailed(errno: Int32)
    case executableOpenFailed(errno: Int32)
    case executableMetadataFailed(errno: Int32)
    case executablePathLookupFailed(errno: Int32)
    case executableNotRegularFile
    case filesystemIdentityMismatch
    case bundleSuffixMismatch
}

public struct CanonicalAppPath: Hashable, Comparable, Sendable,
    CustomStringConvertible
{
    public static let hashDomainID = "pulsephone.gui.app-path.v1"
    public static let executableSuffix =
        "/PulsePhone.app/Contents/MacOS/PulsePhone"
    public static let bundleSuffix = "/PulsePhone.app"

    public let bundlePath: String

    public init(canonicalBundlePath: String) throws {
        guard Self.isCanonicalAbsolutePath(canonicalBundlePath),
              canonicalBundlePath.hasSuffix(Self.bundleSuffix)
        else {
            throw CanonicalAppPathError.invalidSyntax
        }
        self.bundlePath = canonicalBundlePath
    }

    public var description: String {
        bundlePath
    }

    public var bundleURL: URL {
        URL(fileURLWithPath: bundlePath, isDirectory: true)
    }

    public var resourcesURL: URL {
        bundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
    }

    public var guiHostHash: String {
        do {
            return try StableBytes.domainSeparatedSHA256Hex(
                domainID: Self.hashDomainID,
                payload: bundlePath.utf8
            )
        } catch {
            preconditionFailure("Canonical app hash domain must remain ASCII")
        }
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.bundlePath.utf8.lexicographicallyPrecedes(rhs.bundlePath.utf8)
    }

    public static func resolveCurrentExecutable(
        system: POSIXHostPathSystem = POSIXHostPathSystem()
    ) throws -> Self {
        let executablePath = try system.currentExecutablePath()
        return try resolve(executablePath: executablePath, system: system)
    }

    public static func resolve(
        executablePath: String,
        system: POSIXHostPathSystem = POSIXHostPathSystem()
    ) throws -> Self {
        guard Self.isCanonicalAbsolutePath(executablePath) else {
            throw CanonicalAppPathError.invalidSyntax
        }

        let realPath = try system.realPath(executablePath)
        let descriptor = try system.openReadOnlyNoFollow(realPath)
        defer { system.closeFileDescriptor(descriptor) }

        let descriptorMetadata = try system.metadata(
            forFileDescriptor: descriptor,
            error: CanonicalAppPathError.executableMetadataFailed
        )
        guard descriptorMetadata.kind == .regularFile else {
            throw CanonicalAppPathError.executableNotRegularFile
        }

        let fileSystemPath = try system.path(forFileDescriptor: descriptor)
        guard Self.isCanonicalAbsolutePath(fileSystemPath) else {
            throw CanonicalAppPathError.invalidSyntax
        }
        let pathMetadata = try system.metadataNoFollow(
            atPath: fileSystemPath,
            error: CanonicalAppPathError.executableMetadataFailed
        )
        guard descriptorMetadata.identity == pathMetadata.identity else {
            throw CanonicalAppPathError.filesystemIdentityMismatch
        }
        guard fileSystemPath.hasSuffix(Self.executableSuffix) else {
            throw CanonicalAppPathError.bundleSuffixMismatch
        }

        let executableTail = "/Contents/MacOS/PulsePhone"
        let bundlePath = String(fileSystemPath.dropLast(executableTail.count))
        return try Self(canonicalBundlePath: bundlePath)
    }

    static func isCanonicalAbsolutePath(_ path: String) -> Bool {
        let bytes = Array(path.utf8)
        guard bytes.first == 0x2f,
              bytes.count > 1,
              bytes.last != 0x2f,
              !bytes.contains(0)
        else {
            return false
        }

        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.first?.isEmpty == true else {
            return false
        }
        return components.dropFirst().allSatisfy { component in
            !component.isEmpty && component != "." && component != ".."
        }
    }
}
