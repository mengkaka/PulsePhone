import Darwin
import Foundation

public enum AppleRegionWorkerMessageType: String, Codable, Sendable {
    case detect
    case hello
    case result
    case shutdown
}

public enum AppleRegionWorkerOutcome: String, Codable, Sendable {
    case failed
    case succeeded
    case unavailable
}

public struct AppleRegionWorkerRegion: Codable, Equatable, Sendable {
    public let detectionType: Int64
    public let height: Double
    public let width: Double
    public let x: Double
    public let y: Double

    public init(
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        detectionType: Int64
    ) {
        self.detectionType = detectionType
        self.height = height
        self.width = width
        self.x = x
        self.y = y
    }
}

public struct AppleRegionWorkerMessage: Codable, Equatable, Sendable {
    public static let expectedBackend = "macos-private-image-region"
    public static let expectedVersion = "apple-region-worker.v1"
    public static let protocolVersion: UInt64 = 1
    public static let maximumImageBytes = 16 * 1_024 * 1_024
    public static let maximumInputDimension: UInt64 = 16_384
    public static let maximumRegions = 2_048
    public static let maximumRequestFrameBytes = 17 * 1_024 * 1_024
    public static let maximumResponseFrameBytes = 1 * 1_024 * 1_024

    public let backend: String?
    public let elapsedMilliseconds: UInt64?
    public let errorCode: String?
    public let imageData: Data?
    public let inputHeight: UInt64?
    public let inputWidth: UInt64?
    public let outcome: AppleRegionWorkerOutcome?
    public let protocolVersion: UInt64
    public let regions: [AppleRegionWorkerRegion]?
    public let requestID: UInt64?
    public let type: AppleRegionWorkerMessageType
    public let version: String?

    public static func detect(
        requestID: UInt64,
        inputWidth: UInt64,
        inputHeight: UInt64,
        imageData: Data
    ) -> Self {
        Self(
            imageData: imageData,
            inputHeight: inputHeight,
            inputWidth: inputWidth,
            requestID: requestID,
            type: .detect
        )
    }

    public static func hello(
        outcome: AppleRegionWorkerOutcome,
        backend: String,
        version: String,
        errorCode: String? = nil
    ) -> Self {
        Self(
            backend: backend,
            errorCode: errorCode,
            outcome: outcome,
            type: .hello,
            version: version
        )
    }

    public static func result(
        requestID: UInt64,
        outcome: AppleRegionWorkerOutcome,
        elapsedMilliseconds: UInt64,
        regions: [AppleRegionWorkerRegion] = [],
        errorCode: String? = nil
    ) -> Self {
        Self(
            elapsedMilliseconds: elapsedMilliseconds,
            errorCode: errorCode,
            outcome: outcome,
            regions: regions,
            requestID: requestID,
            type: .result
        )
    }

    public static func shutdown() -> Self {
        Self(type: .shutdown)
    }

    private init(
        backend: String? = nil,
        elapsedMilliseconds: UInt64? = nil,
        errorCode: String? = nil,
        imageData: Data? = nil,
        inputHeight: UInt64? = nil,
        inputWidth: UInt64? = nil,
        outcome: AppleRegionWorkerOutcome? = nil,
        protocolVersion: UInt64 = Self.protocolVersion,
        regions: [AppleRegionWorkerRegion]? = nil,
        requestID: UInt64? = nil,
        type: AppleRegionWorkerMessageType,
        version: String? = nil
    ) {
        self.backend = backend
        self.elapsedMilliseconds = elapsedMilliseconds
        self.errorCode = errorCode
        self.imageData = imageData
        self.inputHeight = inputHeight
        self.inputWidth = inputWidth
        self.outcome = outcome
        self.protocolVersion = protocolVersion
        self.regions = regions
        self.requestID = requestID
        self.type = type
        self.version = version
    }

    public func validate() throws {
        guard protocolVersion == Self.protocolVersion else {
            throw AppleRegionWorkerError.invalidMessage
        }
        switch type {
        case .detect:
            guard let requestID, requestID > 0,
                  let inputWidth, (1...Self.maximumInputDimension).contains(inputWidth),
                  let inputHeight, (1...Self.maximumInputDimension).contains(inputHeight),
                  let imageData, !imageData.isEmpty,
                  imageData.count <= Self.maximumImageBytes,
                  backend == nil, elapsedMilliseconds == nil,
                  errorCode == nil, outcome == nil, regions == nil,
                  version == nil
            else { throw AppleRegionWorkerError.invalidMessage }
        case .hello:
            guard requestID == nil, imageData == nil, regions == nil,
                  elapsedMilliseconds == nil,
                  inputWidth == nil, inputHeight == nil,
                  let outcome, outcome != .failed,
                  Self.validBoundedASCII(backend, maximumBytes: 128),
                  Self.validBoundedASCII(version, maximumBytes: 128),
                  (outcome == .succeeded
                      ? errorCode == nil
                      : Self.validCode(errorCode))
            else { throw AppleRegionWorkerError.invalidMessage }
        case .result:
            guard let requestID, requestID > 0,
                  let outcome, outcome != .unavailable,
                  let elapsedMilliseconds,
                  elapsedMilliseconds <= 60_000,
                  let regions, regions.count <= Self.maximumRegions,
                  imageData == nil, inputWidth == nil, inputHeight == nil,
                  backend == nil, version == nil,
                  (outcome == .succeeded
                      ? errorCode == nil
                      : Self.validCode(errorCode)),
                  regions.allSatisfy(Self.valid(region:))
            else { throw AppleRegionWorkerError.invalidMessage }
        case .shutdown:
            guard requestID == nil, imageData == nil, outcome == nil,
                  regions == nil, backend == nil, version == nil,
                  elapsedMilliseconds == nil, errorCode == nil,
                  inputWidth == nil, inputHeight == nil
            else { throw AppleRegionWorkerError.invalidMessage }
        }
    }

    private static func valid(region: AppleRegionWorkerRegion) -> Bool {
        [region.x, region.y, region.width, region.height].allSatisfy(\.isFinite)
            && region.x >= 0 && region.y >= 0
            && region.width > 0 && region.height > 0
    }

    private static func validCode(_ value: String?) -> Bool {
        validBoundedASCII(value, maximumBytes: 64)
    }

    private static func validBoundedASCII(
        _ value: String?,
        maximumBytes: Int
    ) -> Bool {
        guard let value else { return false }
        let bytes = Array(value.utf8)
        return (1...maximumBytes).contains(bytes.count)
            && bytes.allSatisfy { (0x21...0x7e).contains($0) }
    }
}

public enum AppleRegionWorkerError: Error, Equatable, Sendable {
    case circuitOpen
    case invalidExecutable
    case invalidMessage
    case invalidResponse
    case processExited
    case spawnFailed(errno: Int32)
    case systemCall(operation: String, errno: Int32)
    case timedOut
    case unavailable
}

public enum AppleRegionWorkerCodec {
    public static func encode(_ message: AppleRegionWorkerMessage) throws -> Data {
        try message.validate()
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        return try encoder.encode(message)
    }

    public static func decode(
        _ payload: Data,
        maximumBytes: Int
    ) throws -> AppleRegionWorkerMessage {
        guard !payload.isEmpty, payload.count <= maximumBytes else {
            throw AppleRegionWorkerError.invalidMessage
        }
        let message: AppleRegionWorkerMessage
        do {
            message = try PropertyListDecoder().decode(
                AppleRegionWorkerMessage.self,
                from: payload
            )
        } catch {
            throw AppleRegionWorkerError.invalidMessage
        }
        try message.validate()
        return message
    }
}

public enum AppleRegionWorkerStream {
    public static func readFrame(
        descriptor: Int32,
        maximumBytes: Int
    ) throws -> Data? {
        guard maximumBytes > 0, maximumBytes <= Int(UInt32.max) else {
            throw AppleRegionWorkerError.invalidMessage
        }
        guard let header = try readExact(descriptor: descriptor, count: 4) else {
            return nil
        }
        let length = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        guard length > 0, length <= UInt32(maximumBytes) else {
            throw AppleRegionWorkerError.invalidMessage
        }
        return try readExact(descriptor: descriptor, count: Int(length))
    }

    public static func writeFrame(descriptor: Int32, payload: Data) throws {
        guard !payload.isEmpty, payload.count <= Int(UInt32.max) else {
            throw AppleRegionWorkerError.invalidMessage
        }
        let length = UInt32(payload.count)
        var framed = Data([
            UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff), UInt8(length & 0xff),
        ])
        framed.append(payload)
        try framed.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else {
                throw AppleRegionWorkerError.invalidMessage
            }
            var offset = 0
            while offset < bytes.count {
                let written = Darwin.write(
                    descriptor,
                    base.advanced(by: offset),
                    bytes.count - offset
                )
                if written > 0 {
                    offset += written
                } else if written < 0, errno == EINTR {
                    continue
                } else {
                    throw AppleRegionWorkerError.systemCall(
                        operation: "write-worker-frame",
                        errno: written < 0 ? errno : EIO
                    )
                }
            }
        }
    }

    private static func readExact(
        descriptor: Int32,
        count: Int
    ) throws -> Data? {
        var data = Data(count: count)
        var offset = 0
        while offset < count {
            let readCount = data.withUnsafeMutableBytes { bytes in
                Darwin.read(
                    descriptor,
                    bytes.baseAddress!.advanced(by: offset),
                    count - offset
                )
            }
            if readCount > 0 {
                offset += readCount
            } else if readCount == 0 {
                if offset == 0 { return nil }
                throw AppleRegionWorkerError.processExited
            } else if errno == EINTR {
                continue
            } else {
                throw AppleRegionWorkerError.systemCall(
                    operation: "read-worker-frame",
                    errno: errno
                )
            }
        }
        return data
    }
}
