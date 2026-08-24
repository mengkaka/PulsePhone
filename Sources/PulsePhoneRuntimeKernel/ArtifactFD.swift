import PulsePhoneHostPaths
import PulsePhoneSharedDefinitions

public enum ArtifactFDPurpose: String, Equatable, Sendable {
    case deviceScreenshot
    case elementAnnotation
}

public struct ElementAnnotationArtifactBinding: Equatable, Sendable {
    public let captureSHA256: String
    public let pixelHeight: UInt64
    public let pixelWidth: UInt64
    public let snapshotGeneration: UInt64

    public init(
        snapshotGeneration: UInt64,
        captureSHA256: String,
        pixelWidth: UInt64,
        pixelHeight: UInt64
    ) throws {
        guard snapshotGeneration > 0,
              StableBytes.isLowercaseHex(captureSHA256, byteCount: 32),
              pixelWidth > 0,
              pixelHeight > 0,
              pixelWidth <= 65_535,
              pixelHeight <= 65_535
        else {
            throw ArtifactFDProtocolError.invalidMetadata
        }
        self.captureSHA256 = captureSHA256
        self.pixelHeight = pixelHeight
        self.pixelWidth = pixelWidth
        self.snapshotGeneration = snapshotGeneration
    }
}

public enum ArtifactFDContentBinding: Equatable, Sendable {
    case deviceScreenshot
    case elementAnnotation(ElementAnnotationArtifactBinding)

    public var purpose: ArtifactFDPurpose {
        switch self {
        case .deviceScreenshot: .deviceScreenshot
        case .elementAnnotation: .elementAnnotation
        }
    }

    public var elementAnnotation: ElementAnnotationArtifactBinding? {
        guard case .elementAnnotation(let value) = self else { return nil }
        return value
    }
}

public struct ArtifactFDMetadata: Equatable, Sendable {
    public let artifactID: CanonicalUUID
    public let binding: ArtifactFDContentBinding
    public let contentType: String
    public let requestID: CanonicalUUID
    public let sizeBytes: UInt64

    public init(
        requestID: CanonicalUUID,
        artifactID: CanonicalUUID,
        sizeBytes: UInt64,
        contentType: String = "image/png"
    ) {
        self.requestID = requestID
        self.artifactID = artifactID
        self.sizeBytes = sizeBytes
        self.contentType = contentType
        self.binding = .deviceScreenshot
    }

    public init(
        requestID: CanonicalUUID,
        artifactID: CanonicalUUID,
        sizeBytes: UInt64,
        elementAnnotation: ElementAnnotationArtifactBinding,
        contentType: String = "image/png"
    ) {
        self.requestID = requestID
        self.artifactID = artifactID
        self.sizeBytes = sizeBytes
        self.contentType = contentType
        self.binding = .elementAnnotation(elementAnnotation)
    }

    public var elementAnnotation: ElementAnnotationArtifactBinding? {
        binding.elementAnnotation
    }

    public var purpose: ArtifactFDPurpose { binding.purpose }
}

public struct ArtifactFDHandle: Equatable, Sendable {
    public let metadata: ArtifactFDMetadata
    public let node: ScreenshotReservationNode
    public let pngValid: Bool
    public let readOnly: Bool

    public init(
        metadata: ArtifactFDMetadata,
        node: ScreenshotReservationNode,
        readOnly: Bool,
        pngValid: Bool
    ) {
        self.metadata = metadata
        self.node = node
        self.readOnly = readOnly
        self.pngValid = pngValid
    }
}

public enum ArtifactFDOutboundFrame: Equatable, Sendable {
    case artifactFD(ArtifactFDMetadata)
    case successResponse(requestID: CanonicalUUID, artifactID: CanonicalUUID)
}

public enum ArtifactFDProtocolError: Error, Equatable, Sendable {
    case insufficientOutboundCapacity
    case invalidAncillary
    case invalidDescriptor
    case invalidHeader
    case invalidMetadata
    case mismatch
    case responseBeforeArtifact
    case unexpectedArtifactOnFailure
}

public enum ArtifactFDOutboundPlanner {
    public static let requiredFinalControlFrames = 2

    public static func plan(
        metadata: ArtifactFDMetadata,
        availableFinalControlFrames: Int
    ) throws -> [ArtifactFDOutboundFrame] {
        guard availableFinalControlFrames >= requiredFinalControlFrames else {
            throw ArtifactFDProtocolError.insufficientOutboundCapacity
        }
        return [
            .artifactFD(metadata),
            .successResponse(
                requestID: metadata.requestID,
                artifactID: metadata.artifactID
            ),
        ]
    }
}

public struct ArtifactFDSCMRightsTranscript: Equatable, Sendable {
    public let firstSendByteCount: Int
    public let firstSendFDCount: Int
    public let headerByteCount: Int
    public let payloadAncillaryFDCount: Int
    public let remainingHeaderFDCount: Int
    public let receiverControlTruncated: Bool

    public init(
        headerByteCount: Int,
        firstSendByteCount: Int,
        firstSendFDCount: Int,
        remainingHeaderFDCount: Int,
        payloadAncillaryFDCount: Int,
        receiverControlTruncated: Bool
    ) {
        self.headerByteCount = headerByteCount
        self.firstSendByteCount = firstSendByteCount
        self.firstSendFDCount = firstSendFDCount
        self.remainingHeaderFDCount = remainingHeaderFDCount
        self.payloadAncillaryFDCount = payloadAncillaryFDCount
        self.receiverControlTruncated = receiverControlTruncated
    }

    public func validate() throws {
        guard headerByteCount == 16,
              firstSendByteCount >= 1,
              firstSendByteCount <= headerByteCount
        else {
            throw ArtifactFDProtocolError.invalidHeader
        }
        guard firstSendFDCount == 1,
              remainingHeaderFDCount == 0,
              payloadAncillaryFDCount == 0,
              !receiverControlTruncated
        else {
            throw ArtifactFDProtocolError.invalidAncillary
        }
    }
}

public enum ArtifactFDClientDisposition: Equatable, Sendable {
    case complete(ArtifactFDHandle)
    case waitingForResponse
}

public struct ArtifactFDClientBinder: Sendable {
    private var pending: ArtifactFDHandle?

    public init() {}

    public mutating func receiveArtifact(
        _ handle: ArtifactFDHandle,
        expectedBinding: ArtifactFDContentBinding = .deviceScreenshot
    ) throws -> ArtifactFDClientDisposition {
        guard pending == nil else { throw ArtifactFDProtocolError.mismatch }
        guard handle.readOnly,
              handle.node.kind == .regularFile,
              handle.node.mode == 0o600,
              handle.pngValid,
              handle.metadata.contentType == "image/png",
              handle.metadata.binding == expectedBinding,
              handle.metadata.sizeBytes
                <= ScreenshotReservationValidator.maximumArtifactBytes
        else {
            throw ArtifactFDProtocolError.invalidDescriptor
        }
        pending = handle
        return .waitingForResponse
    }

    public mutating func receiveSuccessResponse(
        requestID: CanonicalUUID,
        artifactID: CanonicalUUID
    ) throws -> ArtifactFDClientDisposition {
        guard let handle = pending else {
            throw ArtifactFDProtocolError.responseBeforeArtifact
        }
        guard handle.metadata.requestID == requestID,
              handle.metadata.artifactID == artifactID
        else {
            pending = nil
            throw ArtifactFDProtocolError.mismatch
        }
        pending = nil
        return .complete(handle)
    }

    public mutating func receiveFailureResponse() throws {
        guard pending == nil else {
            pending = nil
            throw ArtifactFDProtocolError.unexpectedArtifactOnFailure
        }
    }

    public mutating func closeOnEOF() {
        pending = nil
    }
}
