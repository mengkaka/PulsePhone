import CoreGraphics
import CoreMedia
import CoreVideo
import Dispatch
import Foundation
import PulsePhoneSharedDefinitions

public enum SnapshotFrameError: Error, Equatable, Sendable {
    case captureBeforeQueryFence
    case captureGenerationMismatch
    case connectionEpochMismatch
    case derivedImageDimensionsMismatch
    case emptyDerivedImage
    case emptyProfileID
    case frameFromFuture
    case frameSequenceNotAdvanced
    case frameStale
    case geometryOrientationMismatch
    case geometryRevisionMismatch
    case geometryRevisionInvalid
    case invalidCaptureGeneration
    case invalidColorSpace
    case invalidContentType
    case invalidDimensions
    case invalidEncodedImage
    case invalidImageRectangle
    case invalidMaximumFrameAge
    case invalidProfileID
    case invalidSourceIdentity
    case sourceEpochMismatch
    case sourceIDMismatch
    case sourceDimensionsMismatch
    case targetMismatch
}

public struct SnapshotImageDimensions: Equatable, Hashable, Sendable {
    public let width: UInt64
    public let height: UInt64

    public init(width: UInt64, height: UInt64) throws {
        guard width > 0, height > 0 else {
            throw SnapshotFrameError.invalidDimensions
        }
        self.width = width
        self.height = height
    }
}

public struct SnapshotPixelPoint: Equatable, Sendable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) throws {
        guard x.isFinite, y.isFinite else {
            throw SnapshotFrameError.invalidImageRectangle
        }
        self.x = x
        self.y = y
    }
}

public struct SnapshotPixelRect: Equatable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) throws {
        guard x.isFinite,
              y.isFinite,
              width.isFinite,
              height.isFinite,
              (x + width).isFinite,
              (y + height).isFinite,
              width > 0,
              height > 0
        else {
            throw SnapshotFrameError.invalidImageRectangle
        }
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public func intersection(_ other: SnapshotPixelRect) -> SnapshotPixelRect? {
        let clippedX = max(x, other.x)
        let clippedY = max(y, other.y)
        let clippedMaxX = min(maxX, other.maxX)
        let clippedMaxY = min(maxY, other.maxY)
        guard clippedMaxX > clippedX, clippedMaxY > clippedY else { return nil }
        return try? SnapshotPixelRect(
            x: clippedX,
            y: clippedY,
            width: clippedMaxX - clippedX,
            height: clippedMaxY - clippedY
        )
    }
}

public struct SnapshotImageInsets: Equatable, Sendable {
    public let top: Double
    public let left: Double
    public let bottom: Double
    public let right: Double

    public init(top: Double, left: Double, bottom: Double, right: Double) throws {
        guard top.isFinite,
              left.isFinite,
              bottom.isFinite,
              right.isFinite,
              top >= 0,
              left >= 0,
              bottom >= 0,
              right >= 0
        else {
            throw SnapshotFrameError.invalidImageRectangle
        }
        self.top = top
        self.left = left
        self.bottom = bottom
        self.right = right
    }
}

public struct SnapshotAxisAlignedTransform: Equatable, Sendable {
    public let scaleX: Double
    public let scaleY: Double
    public let translateX: Double
    public let translateY: Double

    public init(
        scaleX: Double,
        scaleY: Double,
        translateX: Double,
        translateY: Double
    ) throws {
        guard scaleX.isFinite,
              scaleY.isFinite,
              translateX.isFinite,
              translateY.isFinite,
              scaleX > 0,
              scaleY > 0
        else {
            throw SnapshotFrameError.invalidImageRectangle
        }
        self.scaleX = scaleX
        self.scaleY = scaleY
        self.translateX = translateX
        self.translateY = translateY
    }

    public func applying(to point: SnapshotPixelPoint) throws -> SnapshotPixelPoint {
        try SnapshotPixelPoint(
            x: point.x * scaleX + translateX,
            y: point.y * scaleY + translateY
        )
    }

    public func applying(to rect: SnapshotPixelRect) throws -> SnapshotPixelRect {
        try SnapshotPixelRect(
            x: rect.x * scaleX + translateX,
            y: rect.y * scaleY + translateY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
    }

    public var inverse: SnapshotAxisAlignedTransform {
        try! SnapshotAxisAlignedTransform(
            scaleX: 1 / scaleX,
            scaleY: 1 / scaleY,
            translateX: -translateX / scaleX,
            translateY: -translateY / scaleY
        )
    }
}

public enum SnapshotCaptureProvider: String, Equatable, Sendable {
    case axAudit
    case coreDevice
    case dvt
    case legacyScreenshotR
    case liveVideo
}

public enum SnapshotFrameSettleReason: String, Equatable, Sendable {
    case queryFenceSatisfied
    case stableAfterVisualChange
    case unchangedAtDeadline
}

public struct SnapshotFreshnessFence: Equatable, Sendable {
    public let afterActionID: CanonicalUUID?
    public let baselineFrameSequence: UInt64
    public let maximumFrameAgeNanoseconds: UInt64
    public let queryStartedAtNanoseconds: UInt64
    public let validatedAtNanoseconds: UInt64

    public init(
        queryStartedAtNanoseconds: UInt64,
        baselineFrameSequence: UInt64,
        maximumFrameAgeNanoseconds: UInt64,
        validatedAtNanoseconds: UInt64,
        afterActionID: CanonicalUUID? = nil
    ) throws {
        guard maximumFrameAgeNanoseconds > 0 else {
            throw SnapshotFrameError.invalidMaximumFrameAge
        }
        guard validatedAtNanoseconds >= queryStartedAtNanoseconds else {
            throw SnapshotFrameError.frameFromFuture
        }
        self.afterActionID = afterActionID
        self.baselineFrameSequence = baselineFrameSequence
        self.maximumFrameAgeNanoseconds = maximumFrameAgeNanoseconds
        self.queryStartedAtNanoseconds = queryStartedAtNanoseconds
        self.validatedAtNanoseconds = validatedAtNanoseconds
    }

    public func validate(
        capturedAtNanoseconds: UInt64,
        frameSequence: UInt64
    ) throws {
        guard frameSequence > baselineFrameSequence else {
            throw SnapshotFrameError.frameSequenceNotAdvanced
        }
        guard capturedAtNanoseconds >= queryStartedAtNanoseconds else {
            throw SnapshotFrameError.captureBeforeQueryFence
        }
        guard capturedAtNanoseconds <= validatedAtNanoseconds else {
            throw SnapshotFrameError.frameFromFuture
        }
        guard validatedAtNanoseconds - capturedAtNanoseconds
                <= maximumFrameAgeNanoseconds
        else {
            throw SnapshotFrameError.frameStale
        }
    }
}

public struct SnapshotFrameMetadata: Equatable, Sendable {
    public let canonicalUDID: CanonicalUDID
    public let captureGeneration: UInt64
    public let capturedAtNanoseconds: UInt64
    public let connectionEpoch: UInt64
    public let frameSequence: UInt64
    public let freshnessFence: SnapshotFreshnessFence
    public let geometry: DisplayGeometryDTO
    public let pixelDimensions: SnapshotImageDimensions
    public let provider: SnapshotCaptureProvider
    public let settleReason: SnapshotFrameSettleReason
    public let sourceEpoch: UInt64?
    public let sourceID: String?

    public init(
        canonicalUDID: CanonicalUDID,
        connectionEpoch: UInt64,
        sourceEpoch: UInt64?,
        sourceID: String?,
        geometry: DisplayGeometryDTO,
        captureGeneration: UInt64,
        frameSequence: UInt64,
        capturedAtNanoseconds: UInt64,
        freshnessFence: SnapshotFreshnessFence,
        pixelDimensions: SnapshotImageDimensions,
        provider: SnapshotCaptureProvider,
        settleReason: SnapshotFrameSettleReason
    ) throws {
        guard connectionEpoch > 0,
              geometry.connectionEpoch == connectionEpoch
        else {
            throw SnapshotFrameError.connectionEpochMismatch
        }
        guard geometry.geometryRevision > 0 else {
            throw SnapshotFrameError.geometryRevisionInvalid
        }
        guard captureGeneration > 0 else {
            throw SnapshotFrameError.invalidCaptureGeneration
        }
        guard (sourceEpoch == nil) == (sourceID == nil),
              sourceEpoch.map({ $0 > 0 }) ?? true,
              sourceID.map({ !$0.isEmpty }) ?? true
        else {
            throw SnapshotFrameError.invalidSourceIdentity
        }
        if provider == .liveVideo {
            guard let sourceEpoch,
                  sourceEpoch > 0,
                  let sourceID,
                  !sourceID.isEmpty
            else {
                throw SnapshotFrameError.invalidSourceIdentity
            }
        }
        try freshnessFence.validate(
            capturedAtNanoseconds: capturedAtNanoseconds,
            frameSequence: frameSequence
        )
        self.canonicalUDID = canonicalUDID
        self.captureGeneration = captureGeneration
        self.capturedAtNanoseconds = capturedAtNanoseconds
        self.connectionEpoch = connectionEpoch
        self.frameSequence = frameSequence
        self.freshnessFence = freshnessFence
        self.geometry = geometry
        self.pixelDimensions = pixelDimensions
        self.provider = provider
        self.settleReason = settleReason
        self.sourceEpoch = sourceEpoch
        self.sourceID = sourceID
    }
}

public struct SnapshotFrameAuthority: Equatable, Sendable {
    public let canonicalUDID: CanonicalUDID
    public let captureGeneration: UInt64
    public let connectionEpoch: UInt64
    public let geometryRevision: UInt64
    public let orientation: DisplayOrientationDTO
    public let sourceEpoch: UInt64?
    public let sourceID: String?

    public init(
        canonicalUDID: CanonicalUDID,
        connectionEpoch: UInt64,
        sourceEpoch: UInt64?,
        sourceID: String?,
        geometryRevision: UInt64,
        orientation: DisplayOrientationDTO,
        captureGeneration: UInt64
    ) throws {
        guard connectionEpoch > 0 else {
            throw SnapshotFrameError.connectionEpochMismatch
        }
        guard geometryRevision > 0 else {
            throw SnapshotFrameError.geometryRevisionInvalid
        }
        guard captureGeneration > 0 else {
            throw SnapshotFrameError.invalidCaptureGeneration
        }
        guard (sourceEpoch == nil) == (sourceID == nil),
              sourceEpoch.map({ $0 > 0 }) ?? true,
              sourceID.map({ !$0.isEmpty }) ?? true
        else {
            throw SnapshotFrameError.invalidSourceIdentity
        }
        self.canonicalUDID = canonicalUDID
        self.captureGeneration = captureGeneration
        self.connectionEpoch = connectionEpoch
        self.geometryRevision = geometryRevision
        self.orientation = orientation
        self.sourceEpoch = sourceEpoch
        self.sourceID = sourceID
    }

    public init(
        canonicalUDID: CanonicalUDID,
        geometry: DisplayGeometryDTO,
        sourceEpoch: UInt64?,
        sourceID: String?,
        captureGeneration: UInt64
    ) throws {
        try self.init(
            canonicalUDID: canonicalUDID,
            connectionEpoch: geometry.connectionEpoch,
            sourceEpoch: sourceEpoch,
            sourceID: sourceID,
            geometryRevision: geometry.geometryRevision,
            orientation: geometry.orientation,
            captureGeneration: captureGeneration
        )
    }

    public func validate(_ metadata: SnapshotFrameMetadata) throws {
        guard metadata.canonicalUDID == canonicalUDID else {
            throw SnapshotFrameError.targetMismatch
        }
        guard metadata.connectionEpoch == connectionEpoch else {
            throw SnapshotFrameError.connectionEpochMismatch
        }
        guard metadata.sourceEpoch == sourceEpoch else {
            throw SnapshotFrameError.sourceEpochMismatch
        }
        guard metadata.sourceID == sourceID else {
            throw SnapshotFrameError.sourceIDMismatch
        }
        guard metadata.geometry.geometryRevision == geometryRevision else {
            throw SnapshotFrameError.geometryRevisionMismatch
        }
        guard metadata.geometry.orientation == orientation else {
            throw SnapshotFrameError.geometryOrientationMismatch
        }
        guard metadata.captureGeneration == captureGeneration else {
            throw SnapshotFrameError.captureGenerationMismatch
        }
    }
}

public enum SnapshotSourceImageKind: String, Equatable, Sendable {
    case cgImage
    case encoded
    case pixelBuffer
}

public final class SnapshotSourceImageLease: @unchecked Sendable {
    private final class LifetimeAnchor: @unchecked Sendable {
        private enum RetainedObject: @unchecked Sendable {
            case pixelBuffer(CVPixelBuffer)
            case sampleBuffer(CMSampleBuffer)
        }

        private static let releaseQueue = DispatchQueue(
            label: "com.pulsephone.snapshot-frame-release",
            qos: .utility
        )

        private let object: RetainedObject
        private let releaseObserver: (@Sendable () -> Void)?

        init(
            pixelBuffer: CVPixelBuffer,
            releaseObserver: (@Sendable () -> Void)?
        ) {
            self.object = .pixelBuffer(pixelBuffer)
            self.releaseObserver = releaseObserver
        }

        init(
            sampleBuffer: CMSampleBuffer,
            releaseObserver: (@Sendable () -> Void)?
        ) {
            self.object = .sampleBuffer(sampleBuffer)
            self.releaseObserver = releaseObserver
        }

        deinit {
            let retained = object
            let observer = releaseObserver
            Self.releaseQueue.async {
                withExtendedLifetime(retained) {
                    observer?()
                }
            }
        }
    }

    private enum Storage {
        case cgImage(CGImage)
        case encoded(bytes: [UInt8], contentType: String)
        case pixelBuffer(CVPixelBuffer)
        case sampleBuffer(sampleBuffer: CMSampleBuffer, pixelBuffer: CVPixelBuffer)
    }

    public let dimensions: SnapshotImageDimensions
    public let kind: SnapshotSourceImageKind
    private let lifetimeAnchor: LifetimeAnchor?
    private let storage: Storage

    public convenience init(pixelBuffer: CVPixelBuffer) throws {
        try self.init(pixelBuffer: pixelBuffer, releaseObserver: nil)
    }

    init(
        pixelBuffer: CVPixelBuffer,
        releaseObserver: (@Sendable () -> Void)?
    ) throws {
        let dimensions = try SnapshotImageDimensions(
            width: UInt64(CVPixelBufferGetWidth(pixelBuffer)),
            height: UInt64(CVPixelBufferGetHeight(pixelBuffer))
        )
        self.dimensions = dimensions
        self.kind = .pixelBuffer
        self.lifetimeAnchor = LifetimeAnchor(
            pixelBuffer: pixelBuffer,
            releaseObserver: releaseObserver
        )
        self.storage = .pixelBuffer(pixelBuffer)
    }

    public convenience init(sampleBuffer: CMSampleBuffer) throws {
        try self.init(sampleBuffer: sampleBuffer, releaseObserver: nil)
    }

    init(
        sampleBuffer: CMSampleBuffer,
        releaseObserver: (@Sendable () -> Void)?
    ) throws {
        guard CMSampleBufferIsValid(sampleBuffer),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else {
            throw SnapshotFrameError.invalidEncodedImage
        }
        let dimensions = try SnapshotImageDimensions(
            width: UInt64(CVPixelBufferGetWidth(pixelBuffer)),
            height: UInt64(CVPixelBufferGetHeight(pixelBuffer))
        )
        self.dimensions = dimensions
        self.kind = .pixelBuffer
        self.lifetimeAnchor = LifetimeAnchor(
            sampleBuffer: sampleBuffer,
            releaseObserver: releaseObserver
        )
        self.storage = .sampleBuffer(
            sampleBuffer: sampleBuffer,
            pixelBuffer: pixelBuffer
        )
    }

    public init(cgImage: CGImage) throws {
        let dimensions = try SnapshotImageDimensions(
            width: UInt64(cgImage.width),
            height: UInt64(cgImage.height)
        )
        self.dimensions = dimensions
        self.kind = .cgImage
        self.lifetimeAnchor = nil
        self.storage = .cgImage(cgImage)
    }

    public init(
        encodedBytes: [UInt8],
        contentType: String,
        dimensions: SnapshotImageDimensions
    ) throws {
        guard !encodedBytes.isEmpty else {
            throw SnapshotFrameError.invalidEncodedImage
        }
        guard Self.validToken(contentType) else {
            throw SnapshotFrameError.invalidContentType
        }
        self.dimensions = dimensions
        self.kind = .encoded
        self.lifetimeAnchor = nil
        self.storage = .encoded(bytes: encodedBytes, contentType: contentType)
    }

    public var pixelBuffer: CVPixelBuffer? {
        switch storage {
        case .pixelBuffer(let value), .sampleBuffer(_, let value):
            return value
        case .cgImage, .encoded:
            return nil
        }
    }

    public var sampleBuffer: CMSampleBuffer? {
        guard case .sampleBuffer(let value, _) = storage else { return nil }
        return value
    }

    public var cgImage: CGImage? {
        guard case .cgImage(let value) = storage else { return nil }
        return value
    }

    public var encodedImage: (bytes: [UInt8], contentType: String)? {
        guard case .encoded(let bytes, let contentType) = storage else { return nil }
        return (bytes, contentType)
    }

    private static func validToken(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 127
            && value.utf8.allSatisfy { byte in
                byte >= 0x21 && byte <= 0x7e && byte != 0x22 && byte != 0x5c
            }
    }
}

public enum SnapshotDerivedImageEncoding: String, Equatable, Hashable, Sendable {
    case jpeg
    case png
    case rawBGRA
}

public enum SnapshotDerivedImageColorSpace: Equatable, Hashable, Sendable {
    case displayP3
    case source
    case sRGB
    case named(String)

    fileprivate var isValid: Bool {
        switch self {
        case .displayP3, .source, .sRGB:
            true
        case .named(let value):
            !value.isEmpty && value.utf8.count <= 127 && !value.utf8.contains(0)
        }
    }
}

public enum SnapshotDerivedImageResize: Equatable, Hashable, Sendable {
    case aspectFill(width: UInt64, height: UInt64)
    case aspectFit(width: UInt64, height: UInt64)
    case longestEdge(UInt64)
    case source
}

public struct SnapshotDerivedImageProfile: Equatable, Hashable, Sendable {
    public let colorSpace: SnapshotDerivedImageColorSpace
    public let encoding: SnapshotDerivedImageEncoding
    public let profileID: String
    public let resize: SnapshotDerivedImageResize

    public init(
        profileID: String,
        resize: SnapshotDerivedImageResize,
        colorSpace: SnapshotDerivedImageColorSpace,
        encoding: SnapshotDerivedImageEncoding
    ) throws {
        guard !profileID.isEmpty else { throw SnapshotFrameError.emptyProfileID }
        guard profileID.utf8.count <= 127,
              profileID.utf8.allSatisfy({ byte in
                  byte >= 0x21 && byte <= 0x7e && byte != 0x22 && byte != 0x5c
              })
        else {
            throw SnapshotFrameError.invalidProfileID
        }
        guard colorSpace.isValid else { throw SnapshotFrameError.invalidColorSpace }
        switch resize {
        case .aspectFill(let width, let height), .aspectFit(let width, let height):
            guard width > 0, height > 0 else {
                throw SnapshotFrameError.invalidDimensions
            }
        case .longestEdge(let maximum):
            guard maximum > 0 else { throw SnapshotFrameError.invalidDimensions }
        case .source:
            break
        }
        self.colorSpace = colorSpace
        self.encoding = encoding
        self.profileID = profileID
        self.resize = resize
    }

    public func geometry(
        sourceDimensions: SnapshotImageDimensions
    ) throws -> SnapshotDerivedImageGeometry {
        switch resize {
        case .source:
            return try SnapshotDerivedImageGeometry.fullFrame(
                sourceDimensions: sourceDimensions,
                inputDimensions: sourceDimensions
            )
        case .longestEdge(let maximum):
            let sourceLongest = max(sourceDimensions.width, sourceDimensions.height)
            guard sourceLongest > maximum else {
                return try SnapshotDerivedImageGeometry.fullFrame(
                    sourceDimensions: sourceDimensions,
                    inputDimensions: sourceDimensions
                )
            }
            let scale = Double(maximum) / Double(sourceLongest)
            let input = try SnapshotImageDimensions(
                width: try Self.roundedDimension(
                    Double(sourceDimensions.width) * scale
                ),
                height: try Self.roundedDimension(
                    Double(sourceDimensions.height) * scale
                )
            )
            return try SnapshotDerivedImageGeometry.fullFrame(
                sourceDimensions: sourceDimensions,
                inputDimensions: input
            )
        case .aspectFit(let width, let height):
            let input = try SnapshotImageDimensions(width: width, height: height)
            let scale = min(
                Double(width) / Double(sourceDimensions.width),
                Double(height) / Double(sourceDimensions.height)
            )
            let contentWidth = Double(sourceDimensions.width) * scale
            let contentHeight = Double(sourceDimensions.height) * scale
            return try SnapshotDerivedImageGeometry(
                sourceDimensions: sourceDimensions,
                inputDimensions: input,
                sourceContentRect: SnapshotDerivedImageGeometry.fullRect(sourceDimensions),
                inputContentRect: SnapshotPixelRect(
                    x: (Double(width) - contentWidth) / 2,
                    y: (Double(height) - contentHeight) / 2,
                    width: contentWidth,
                    height: contentHeight
                )
            )
        case .aspectFill(let width, let height):
            let input = try SnapshotImageDimensions(width: width, height: height)
            let scale = max(
                Double(width) / Double(sourceDimensions.width),
                Double(height) / Double(sourceDimensions.height)
            )
            let sourceContentWidth = Double(width) / scale
            let sourceContentHeight = Double(height) / scale
            return try SnapshotDerivedImageGeometry(
                sourceDimensions: sourceDimensions,
                inputDimensions: input,
                sourceContentRect: SnapshotPixelRect(
                    x: (Double(sourceDimensions.width) - sourceContentWidth) / 2,
                    y: (Double(sourceDimensions.height) - sourceContentHeight) / 2,
                    width: sourceContentWidth,
                    height: sourceContentHeight
                ),
                inputContentRect: SnapshotDerivedImageGeometry.fullRect(input)
            )
        }
    }

    private static func roundedDimension(_ value: Double) throws -> UInt64 {
        let rounded = value.rounded()
        guard rounded.isFinite,
              rounded >= 1,
              rounded < Double(UInt64.max)
        else {
            throw SnapshotFrameError.invalidDimensions
        }
        return UInt64(rounded)
    }
}

public struct SnapshotDerivedImageGeometry: Equatable, Sendable {
    public let crop: SnapshotImageInsets
    public let inputContentRect: SnapshotPixelRect
    public let inputDimensions: SnapshotImageDimensions
    public let inputToSource: SnapshotAxisAlignedTransform
    public let padding: SnapshotImageInsets
    public let sourceContentRect: SnapshotPixelRect
    public let sourceDimensions: SnapshotImageDimensions
    public let sourceToInput: SnapshotAxisAlignedTransform

    public init(
        sourceDimensions: SnapshotImageDimensions,
        inputDimensions: SnapshotImageDimensions,
        sourceContentRect: SnapshotPixelRect,
        inputContentRect: SnapshotPixelRect
    ) throws {
        let sourceBounds = Self.fullRect(sourceDimensions)
        let inputBounds = Self.fullRect(inputDimensions)
        guard sourceBounds.intersection(sourceContentRect) == sourceContentRect,
              inputBounds.intersection(inputContentRect) == inputContentRect
        else {
            throw SnapshotFrameError.invalidImageRectangle
        }
        let scaleX = inputContentRect.width / sourceContentRect.width
        let scaleY = inputContentRect.height / sourceContentRect.height
        let transform = try SnapshotAxisAlignedTransform(
            scaleX: scaleX,
            scaleY: scaleY,
            translateX: inputContentRect.x - sourceContentRect.x * scaleX,
            translateY: inputContentRect.y - sourceContentRect.y * scaleY
        )
        self.crop = try SnapshotImageInsets(
            top: sourceContentRect.y,
            left: sourceContentRect.x,
            bottom: Double(sourceDimensions.height) - sourceContentRect.maxY,
            right: Double(sourceDimensions.width) - sourceContentRect.maxX
        )
        self.inputContentRect = inputContentRect
        self.inputDimensions = inputDimensions
        self.inputToSource = transform.inverse
        self.padding = try SnapshotImageInsets(
            top: inputContentRect.y,
            left: inputContentRect.x,
            bottom: Double(inputDimensions.height) - inputContentRect.maxY,
            right: Double(inputDimensions.width) - inputContentRect.maxX
        )
        self.sourceContentRect = sourceContentRect
        self.sourceDimensions = sourceDimensions
        self.sourceToInput = transform
    }

    public func mapSourceRectToInput(
        _ rect: SnapshotPixelRect
    ) throws -> SnapshotPixelRect? {
        guard let clipped = rect.intersection(sourceContentRect) else { return nil }
        return try sourceToInput.applying(to: clipped)
    }

    public func mapInputRectToSource(
        _ rect: SnapshotPixelRect
    ) throws -> SnapshotPixelRect? {
        guard let clipped = rect.intersection(inputContentRect) else { return nil }
        return try inputToSource.applying(to: clipped)
    }

    fileprivate static func fullFrame(
        sourceDimensions: SnapshotImageDimensions,
        inputDimensions: SnapshotImageDimensions
    ) throws -> SnapshotDerivedImageGeometry {
        try SnapshotDerivedImageGeometry(
            sourceDimensions: sourceDimensions,
            inputDimensions: inputDimensions,
            sourceContentRect: fullRect(sourceDimensions),
            inputContentRect: fullRect(inputDimensions)
        )
    }

    fileprivate static func fullRect(
        _ dimensions: SnapshotImageDimensions
    ) -> SnapshotPixelRect {
        try! SnapshotPixelRect(
            x: 0,
            y: 0,
            width: Double(dimensions.width),
            height: Double(dimensions.height)
        )
    }
}

public struct SnapshotDerivedImagePayloadTimings: Equatable, Sendable {
    public let inputEncodeMicroseconds: UInt64
    public let resizeAndColorSpaceMicroseconds: UInt64
    public let sourceDecodeMicroseconds: UInt64

    public init(
        sourceDecodeMicroseconds: UInt64,
        resizeAndColorSpaceMicroseconds: UInt64,
        inputEncodeMicroseconds: UInt64
    ) {
        self.inputEncodeMicroseconds = inputEncodeMicroseconds
        self.resizeAndColorSpaceMicroseconds = resizeAndColorSpaceMicroseconds
        self.sourceDecodeMicroseconds = sourceDecodeMicroseconds
    }

    public static let zero = SnapshotDerivedImagePayloadTimings(
        sourceDecodeMicroseconds: 0,
        resizeAndColorSpaceMicroseconds: 0,
        inputEncodeMicroseconds: 0
    )
}

public struct SnapshotDerivedImagePayload: Equatable, Sendable {
    public let bytes: [UInt8]
    public let contentType: String
    public let dimensions: SnapshotImageDimensions
    public let timings: SnapshotDerivedImagePayloadTimings

    public init(
        bytes: [UInt8],
        contentType: String,
        dimensions: SnapshotImageDimensions,
        timings: SnapshotDerivedImagePayloadTimings = .zero
    ) throws {
        guard !bytes.isEmpty else { throw SnapshotFrameError.emptyDerivedImage }
        guard !contentType.isEmpty,
              contentType.utf8.count <= 127,
              !contentType.utf8.contains(0)
        else {
            throw SnapshotFrameError.invalidContentType
        }
        self.bytes = bytes
        self.contentType = contentType
        self.dimensions = dimensions
        self.timings = timings
    }
}

public struct SnapshotDerivedImage: Equatable, Sendable {
    public let geometry: SnapshotDerivedImageGeometry
    public let orientation: DisplayOrientationDTO
    public let payload: SnapshotDerivedImagePayload
    public let profile: SnapshotDerivedImageProfile
}

private actor SnapshotDerivedImageStore {
    typealias Materializer = @Sendable (
        SnapshotSourceImageLease,
        SnapshotDerivedImageGeometry
    ) async throws -> SnapshotDerivedImagePayload

    private struct InFlight {
        let id: UUID
        let task: Task<SnapshotDerivedImage, Error>
        var waiters: [UUID: CheckedContinuation<SnapshotDerivedImage, Error>]
    }

    private var completed = [SnapshotDerivedImageProfile: SnapshotDerivedImage]()
    private var inFlight = [SnapshotDerivedImageProfile: InFlight]()
    private let orientation: DisplayOrientationDTO
    private let source: SnapshotSourceImageLease

    init(source: SnapshotSourceImageLease, orientation: DisplayOrientationDTO) {
        self.orientation = orientation
        self.source = source
    }

    func image(
        profile: SnapshotDerivedImageProfile,
        materialize: @escaping Materializer
    ) async throws -> SnapshotDerivedImage {
        if let image = completed[profile] { return image }
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            let image = try await withCheckedThrowingContinuation { continuation in
                enqueue(
                    profile: profile,
                    waiterID: waiterID,
                    materialize: materialize,
                    continuation: continuation
                )
            }
            try Task.checkCancellation()
            return image
        } onCancel: {
            Task { await self.cancelWaiter(
                profile: profile,
                waiterID: waiterID
            ) }
        }
    }

    private func enqueue(
        profile: SnapshotDerivedImageProfile,
        waiterID: UUID,
        materialize: @escaping Materializer,
        continuation: CheckedContinuation<SnapshotDerivedImage, Error>
    ) {
        guard !Task.isCancelled else {
            continuation.resume(throwing: CancellationError())
            return
        }
        if var existing = inFlight[profile] {
            existing.waiters[waiterID] = continuation
            inFlight[profile] = existing
            return
        }
        do {
            let geometry = try profile.geometry(sourceDimensions: source.dimensions)
            let source = source
            let orientation = orientation
            let id = UUID()
            let task = Task.detached(priority: Task.currentPriority) {
                try Task.checkCancellation()
                let payload = try await materialize(source, geometry)
                try Task.checkCancellation()
                guard payload.dimensions == geometry.inputDimensions else {
                    throw SnapshotFrameError.derivedImageDimensionsMismatch
                }
                return SnapshotDerivedImage(
                    geometry: geometry,
                    orientation: orientation,
                    payload: payload,
                    profile: profile
                )
            }
            inFlight[profile] = InFlight(
                id: id,
                task: task,
                waiters: [waiterID: continuation]
            )
            Task { [weak self] in
                let result = await task.result
                await self?.complete(
                    profile: profile,
                    flightID: id,
                    result: result
                )
            }
        } catch {
            continuation.resume(throwing: error)
        }
    }

    private func complete(
        profile: SnapshotDerivedImageProfile,
        flightID: UUID,
        result: Result<SnapshotDerivedImage, Error>
    ) {
        guard let current = inFlight[profile], current.id == flightID else { return }
        inFlight.removeValue(forKey: profile)
        if case .success(let image) = result {
            completed[profile] = image
        }
        for continuation in current.waiters.values {
            continuation.resume(with: result)
        }
    }

    private func cancelWaiter(
        profile: SnapshotDerivedImageProfile,
        waiterID: UUID
    ) {
        guard var current = inFlight[profile],
              let continuation = current.waiters.removeValue(forKey: waiterID)
        else { return }
        continuation.resume(throwing: CancellationError())
        guard current.waiters.isEmpty else {
            inFlight[profile] = current
            return
        }
        inFlight.removeValue(forKey: profile)
        current.task.cancel()
    }
}

public struct SnapshotFrame: Sendable {
    public typealias DerivedImageMaterializer = @Sendable (
        SnapshotSourceImageLease,
        SnapshotDerivedImageGeometry
    ) async throws -> SnapshotDerivedImagePayload

    public let authority: SnapshotFrameAuthority
    public let metadata: SnapshotFrameMetadata
    public let sourceImage: SnapshotSourceImageLease
    private let derivedImages: SnapshotDerivedImageStore

    public init(
        authority: SnapshotFrameAuthority,
        metadata: SnapshotFrameMetadata,
        sourceImage: SnapshotSourceImageLease
    ) throws {
        try authority.validate(metadata)
        guard metadata.pixelDimensions == sourceImage.dimensions else {
            throw SnapshotFrameError.sourceDimensionsMismatch
        }
        self.authority = authority
        self.metadata = metadata
        self.sourceImage = sourceImage
        self.derivedImages = SnapshotDerivedImageStore(
            source: sourceImage,
            orientation: metadata.geometry.orientation
        )
    }

    public func derivedImage(
        for profile: SnapshotDerivedImageProfile,
        materialize: @escaping DerivedImageMaterializer
    ) async throws -> SnapshotDerivedImage {
        try await derivedImages.image(profile: profile, materialize: materialize)
    }
}
