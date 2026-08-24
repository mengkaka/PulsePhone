import Darwin
import Foundation

public struct HelperProcessStartIdentity: Codable, Hashable, Sendable {
    public let seconds: UInt64
    public let microseconds: UInt64

    public init(seconds: UInt64, microseconds: UInt64) {
        self.seconds = seconds
        self.microseconds = microseconds
    }

    public var wireValue: String {
        "\(seconds).\(String(format: "%06llu", microseconds))"
    }
}

public struct HelperProcessIdentity: Codable, Hashable, Sendable {
    public let pid: pid_t
    public let processGroupID: pid_t
    public let processStartIdentity: HelperProcessStartIdentity
    public let executablePath: String

    public init(
        pid: pid_t,
        processGroupID: pid_t,
        processStartIdentity: HelperProcessStartIdentity,
        executablePath: String
    ) {
        self.pid = pid
        self.processGroupID = processGroupID
        self.processStartIdentity = processStartIdentity
        self.executablePath = executablePath
    }

    public static func capture(
        pid: pid_t,
        expectedExecutablePath: String
    ) throws -> HelperProcessIdentity {
        guard pid > 0,
              let expectedPath = canonicalPath(expectedExecutablePath),
              let observedPath = currentExecutablePath(pid: pid),
              observedPath == expectedPath
        else {
            throw HelperProcessIdentityError.executableMismatch
        }
        guard let start = processStart(pid: pid) else {
            throw HelperProcessIdentityError.processUnavailable
        }
        let processGroupID = getpgid(pid)
        guard processGroupID == pid else {
            throw HelperProcessIdentityError.processGroupMismatch
        }
        return HelperProcessIdentity(
            pid: pid,
            processGroupID: processGroupID,
            processStartIdentity: start,
            executablePath: expectedPath
        )
    }

    public func matchesCurrentProcess() -> Bool {
        guard let observedPath = Self.currentExecutablePath(pid: pid),
              observedPath == executablePath,
              Self.processStart(pid: pid) == processStartIdentity,
              getpgid(pid) == processGroupID,
              processGroupID == pid
        else {
            return false
        }
        return true
    }

    private static func processStart(
        pid: pid_t
    ) -> HelperProcessStartIdentity? {
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(size))
        }
        guard result == Int32(size),
              info.pbi_start_tvusec < 1_000_000
        else {
            return nil
        }
        return HelperProcessStartIdentity(
            seconds: info.pbi_start_tvsec,
            microseconds: info.pbi_start_tvusec
        )
    }

    static func currentExecutablePath(pid: pid_t) -> String? {
        var buffer = [CChar](
            repeating: 0,
            count: 4 * Int(MAXPATHLEN)
        )
        let count = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
        }
        guard count > 0 else { return nil }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        let bytes = buffer[..<end].map { UInt8(bitPattern: $0) }
        return canonicalPath(String(decoding: bytes, as: UTF8.self))
    }

    private static func canonicalPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              let resolved = realpath(path, nil)
        else {
            return nil
        }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

public enum HelperProcessIdentityError: Error, Equatable, Sendable {
    case processUnavailable
    case executableMismatch
    case processGroupMismatch
}
