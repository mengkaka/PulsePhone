import Darwin
import Foundation

public enum BundledHelperKind: String, CaseIterable, Sendable {
    case direct
    case coreDevice

    public var executableName: String {
        switch self {
        case .direct:
            return "PulsePhoneDirectHelper"
        case .coreDevice:
            return "PulsePhoneCoreDeviceHelper"
        }
    }
}

public struct BundledHelperExecutableSet: Equatable, Sendable {
    public let helpersURL: URL

    public init(resourcesURL: URL) {
        // App paths may be reached through aliases such as /tmp -> /private/tmp.
        // Resolve the existing parent chain before the executable is validated.
        let normalized = Self.canonicalized(resourcesURL)
        if normalized.lastPathComponent == "Resources",
           normalized.deletingLastPathComponent().lastPathComponent == "Contents"
        {
            self.helpersURL = normalized
                .deletingLastPathComponent()
                .appendingPathComponent("Helpers", isDirectory: true)
        } else if normalized.lastPathComponent == "Contents" {
            self.helpersURL = normalized
                .appendingPathComponent("Helpers", isDirectory: true)
        } else if normalized.pathExtension == "app" {
            self.helpersURL = normalized
                .appendingPathComponent("Contents", isDirectory: true)
                .appendingPathComponent("Helpers", isDirectory: true)
        } else if Self.isSourceTreeContractRoot(normalized) {
            // Swift tests and local runtime smoke use the source contract root,
            // while Go products are built separately from that root.
            self.helpersURL = normalized
                .appendingPathComponent("build", isDirectory: true)
                .appendingPathComponent("go", isDirectory: true)
                .appendingPathComponent("debug", isDirectory: true)
        } else {
            self.helpersURL = normalized
                .appendingPathComponent("Helpers", isDirectory: true)
        }
    }

    private static func isSourceTreeContractRoot(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(
            atPath: url.appendingPathComponent("Package.swift").path
        ) && fileManager.fileExists(
            atPath: url.appendingPathComponent("GoHelpers/go.mod").path
        ) && fileManager.fileExists(
            atPath: url.appendingPathComponent("Registries").path
        )
    }

    private static func canonicalized(_ url: URL) -> URL {
        let fileManager = FileManager.default
        var existing = url.standardizedFileURL
        var suffix = [String]()
        while !fileManager.fileExists(atPath: existing.path) {
            let parent = existing.deletingLastPathComponent()
            guard parent.path != existing.path else {
                return url.standardizedFileURL
            }
            suffix.insert(existing.lastPathComponent, at: 0)
            existing = parent
        }

        guard let pointer = realpath(existing.path, nil) else {
            return url.standardizedFileURL
        }
        defer { free(pointer) }
        var result = URL(fileURLWithPath: String(cString: pointer))
        for component in suffix {
            result.appendPathComponent(component, isDirectory: true)
        }
        return result
    }

    public func executableURL(for kind: BundledHelperKind) -> URL {
        helpersURL.appendingPathComponent(kind.executableName, isDirectory: false)
    }

    public var directExecutableURL: URL {
        executableURL(for: .direct)
    }

    public var coreDeviceExecutableURL: URL {
        executableURL(for: .coreDevice)
    }
}
