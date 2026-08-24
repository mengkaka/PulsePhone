import CoreGraphics
import Foundation
import PulsePhoneMedia
import PulsePhoneSharedDefinitions

public enum ElementAnnotationRendererError: Error, Equatable, Sendable {
    case canvasTooLarge
    case encodedArtifactTooLarge
    case invalidElementGeometry
    case resultFrameMismatch
    case renderingDeadlineExceeded
}

public struct ElementAnnotationRenderResult: Equatable, Sendable {
    public let bytes: [UInt8]
    public let captureSHA256: String
    public let contentType: String
    public let dimensions: SnapshotImageDimensions
    public let elapsedMilliseconds: UInt64
    public let sha256: String
    public let snapshotGeneration: UInt64
}

public struct ElementAnnotationRenderer: Sendable {
    public static let maximumArtifactBytes: UInt64 = 64 * 1_024 * 1_024
    public static let maximumCanvasPixels: UInt64 = 16 * 1_024 * 1_024
    public static let maximumElapsedMilliseconds: UInt64 = 5_000

    private let imageRenderer: ElementImageRenderer

    public init(imageRenderer: ElementImageRenderer = ElementImageRenderer()) {
        self.imageRenderer = imageRenderer
    }

    public func render(
        frame: SnapshotFrame,
        result: ElementSnapshotResult
    ) async throws -> ElementAnnotationRenderResult {
        let imageRenderer = self.imageRenderer
        return try await Task.detached(priority: Task.currentPriority) {
            try Self.render(
                frame: frame,
                result: result,
                imageRenderer: imageRenderer
            )
        }.value
    }

    private static func render(
        frame: SnapshotFrame,
        result: ElementSnapshotResult,
        imageRenderer: ElementImageRenderer
    ) throws -> ElementAnnotationRenderResult {
        let metadata = frame.metadata
        guard let capture = result.root["capture"]?.objectValue,
              result.snapshotGeneration == metadata.captureGeneration,
              capture["sha256"]?.stringValue == result.captureSHA256,
              uint(capture["connectionEpoch"]) == metadata.connectionEpoch,
              uint(capture["geometryRevision"]) == metadata.geometry.geometryRevision,
              uint(capture["pixelWidth"]) == metadata.pixelDimensions.width,
              uint(capture["pixelHeight"]) == metadata.pixelDimensions.height,
              capture["orientation"]?.stringValue == metadata.geometry.orientation.rawValue,
              result.root["annotation"] == nil,
              result.root["timings"]?.objectValue?["annotationMilliseconds"]
                .map(isNull) == true,
              result.annotationElements.count <= ElementSnapshotResultBuilder.maximumElements
        else {
            throw ElementAnnotationRendererError.resultFrameMismatch
        }
        let dimensions = frame.metadata.pixelDimensions
        let (pixelCount, overflow) = dimensions.width.multipliedReportingOverflow(
            by: dimensions.height
        )
        guard !overflow, pixelCount <= maximumCanvasPixels else {
            throw ElementAnnotationRendererError.canvasTooLarge
        }
        let bounds = try SnapshotPixelRect(
            x: 0,
            y: 0,
            width: Double(dimensions.width),
            height: Double(dimensions.height)
        )
        guard result.annotationElements.allSatisfy({ element in
            element.frame.x >= bounds.x
                && element.frame.y >= bounds.y
                && element.frame.maxX <= bounds.maxX
                && element.frame.maxY <= bounds.maxY
                && !element.sources.isEmpty
                && !element.snapshotID.isEmpty
        }) else {
            throw ElementAnnotationRendererError.invalidElementGeometry
        }

        let started = ContinuousClock.now
        let source = try imageRenderer.renderSourceImage(source: frame.sourceImage)
        let width = Int(dimensions.width)
        let height = Int(dimensions.height)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let annotated = try pixels.withUnsafeMutableBytes { buffer -> CGImage in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue
                    | CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                throw ElementAnalyzerError.imageEncodeFailed
            }
            context.setShouldAntialias(false)
            context.draw(
                source,
                in: CGRect(x: 0, y: 0, width: width, height: height)
            )
            draw(
                result.annotationElements,
                in: context,
                dimensions: dimensions
            )
            guard let image = context.makeImage() else {
                throw ElementAnalyzerError.imageEncodeFailed
            }
            return image
        }
        let payload = try imageRenderer.encodePNG(annotated, dimensions: dimensions)
        guard UInt64(payload.bytes.count) <= maximumArtifactBytes else {
            throw ElementAnnotationRendererError.encodedArtifactTooLarge
        }
        let elapsed = ElementAnalyzerTiming.elapsedMilliseconds(since: started)
        guard elapsed <= maximumElapsedMilliseconds else {
            throw ElementAnnotationRendererError.renderingDeadlineExceeded
        }
        return ElementAnnotationRenderResult(
            bytes: payload.bytes,
            captureSHA256: result.captureSHA256,
            contentType: payload.contentType,
            dimensions: dimensions,
            elapsedMilliseconds: elapsed,
            sha256: StableBytes.sha256Hex(payload.bytes),
            snapshotGeneration: result.snapshotGeneration
        )
    }

    private static func draw(
        _ elements: [ElementSnapshotAnnotationElement],
        in context: CGContext,
        dimensions: SnapshotImageDimensions
    ) {
        let longestEdge = Double(max(dimensions.width, dimensions.height))
        let outerWidth = max(2, min(4, longestEdge / 640))
        let innerWidth = max(1, outerWidth * 0.55)
        for element in elements {
            let inset = outerWidth / 2
            let frame = CGRect(
                x: element.frame.x,
                y: Double(dimensions.height) - element.frame.maxY,
                width: element.frame.width,
                height: element.frame.height
            ).insetBy(dx: inset, dy: inset)
            guard frame.width > 0, frame.height > 0 else { continue }
            context.setStrokeColor(CGColor(gray: 0, alpha: 0.72))
            context.setLineWidth(outerWidth)
            context.stroke(frame)
            context.setStrokeColor(color(for: element.sources))
            context.setLineWidth(innerWidth)
            context.stroke(frame)
        }
    }

    private static func color(for sources: [ElementAnalyzerSource]) -> CGColor {
        if sources.contains(.omniparser) {
            return CGColor(red: 0.08, green: 0.78, blue: 0.42, alpha: 1)
        }
        if sources.contains(.vision) {
            return CGColor(red: 0.12, green: 0.58, blue: 1, alpha: 1)
        }
        if sources.contains(.appleRegion) {
            return CGColor(red: 0.88, green: 0.24, blue: 0.74, alpha: 1)
        }
        return CGColor(red: 1, green: 0.58, blue: 0.12, alpha: 1)
    }

    private static func isNull(_ value: RepositoryJSONValue) -> Bool {
        guard case .null = value else { return false }
        return true
    }

    private static func uint(_ value: RepositoryJSONValue?) -> UInt64? {
        guard let number = value?.numberValue else { return nil }
        return try? number.requireUInt64()
    }
}
