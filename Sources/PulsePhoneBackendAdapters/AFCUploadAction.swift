public enum AFCUploadError: Error, Equatable, Sendable {
    case invalidSourceChunk(actualBytes: Int)
    case transportFailure
}

public protocol AFCUploadTransport: Sendable {
    func readSourceChunk(
        offset: UInt64,
        maximumBytes: Int
    ) throws -> [UInt8]
    func writeDeviceChunk(
        _ bytes: [UInt8],
        offset: UInt64
    ) throws
}

public struct AFCUploadResult: Equatable, Sendable {
    public let bytesUploaded: UInt64
    public let chunkCount: UInt64

    public init(bytesUploaded: UInt64, chunkCount: UInt64) {
        self.bytesUploaded = bytesUploaded
        self.chunkCount = chunkCount
    }
}

public struct AFCUploadAction: Sendable {
    public static let maximumChunkBytes = 1 * 1_024 * 1_024

    private let transport: any AFCUploadTransport

    public init(transport: any AFCUploadTransport) {
        self.transport = transport
    }

    public func execute() throws -> AFCUploadResult {
        var offset: UInt64 = 0
        var chunkCount: UInt64 = 0
        while true {
            let chunk: [UInt8]
            do {
                chunk = try transport.readSourceChunk(
                    offset: offset,
                    maximumBytes: Self.maximumChunkBytes
                )
            } catch {
                throw AFCUploadError.transportFailure
            }
            guard chunk.count <= Self.maximumChunkBytes else {
                throw AFCUploadError.invalidSourceChunk(actualBytes: chunk.count)
            }
            guard !chunk.isEmpty else { break }
            do {
                try transport.writeDeviceChunk(chunk, offset: offset)
            } catch {
                throw AFCUploadError.transportFailure
            }
            let (nextOffset, overflow) = offset.addingReportingOverflow(
                UInt64(chunk.count)
            )
            guard !overflow else {
                throw AFCUploadError.transportFailure
            }
            offset = nextOffset
            chunkCount += 1
        }
        return AFCUploadResult(
            bytesUploaded: offset,
            chunkCount: chunkCount
        )
    }
}
