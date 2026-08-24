import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import PulsePhoneMedia
import UniformTypeIdentifiers

public final class ElementImageRenderer: @unchecked Sendable {
    struct GrayscaleSource {
        let dimensions: SnapshotImageDimensions
        let image: CIImage
    }

    private struct GrayscaleGeometry {
        let height: Int
        let scale: Double
        let width: Int
    }

    struct GrayscaleImage: Sendable {
        let height: Int
        let pixels: [UInt8]
        let scale: Double
        let width: Int
    }

    private let context = CIContext(options: [
        .cacheIntermediates: true,
    ])
    private let softwareContext = CIContext(options: [
        .cacheIntermediates: false,
        .useSoftwareRenderer: true,
    ])

    public init() {}

    public func pngMaterializer() -> SnapshotFrame.DerivedImageMaterializer {
        { [self] source, geometry in
            try renderPNG(source: source, geometry: geometry)
        }
    }

    public func renderPNG(
        source: SnapshotSourceImageLease,
        geometry: SnapshotDerivedImageGeometry
    ) throws -> SnapshotDerivedImagePayload {
        guard source.dimensions == geometry.sourceDimensions else {
            throw ElementAnalyzerError.invalidImageGeometry
        }
        let decodeStarted = ContinuousClock.now
        let sourceImage = try sourceImage(source)
        let sourceDecodeMicroseconds = ElementAnalyzerTiming.elapsedMicroseconds(
            since: decodeStarted
        )
        let renderStarted = ContinuousClock.now
        let rendered = try renderedImage(
            source: source,
            sourceImage: sourceImage,
            geometry: geometry
        )
        let resizeAndColorSpaceMicroseconds = ElementAnalyzerTiming.elapsedMicroseconds(
            since: renderStarted
        )
        let encodeStarted = ContinuousClock.now
        return try encodePNG(
            rendered,
            dimensions: geometry.inputDimensions,
            sourceDecodeMicroseconds: sourceDecodeMicroseconds,
            resizeAndColorSpaceMicroseconds: resizeAndColorSpaceMicroseconds,
            encodeStarted: encodeStarted
        )
    }

    func renderSourceImage(source: SnapshotSourceImageLease) throws -> CGImage {
        let dimensions = source.dimensions
        return try renderedImage(
            source: source,
            geometry: SnapshotDerivedImageGeometry(
                sourceDimensions: dimensions,
                inputDimensions: dimensions,
                sourceContentRect: try SnapshotPixelRect(
                    x: 0,
                    y: 0,
                    width: Double(dimensions.width),
                    height: Double(dimensions.height)
                ),
                inputContentRect: try SnapshotPixelRect(
                    x: 0,
                    y: 0,
                    width: Double(dimensions.width),
                    height: Double(dimensions.height)
                )
            )
        )
    }

    func encodePNG(
        _ image: CGImage,
        dimensions: SnapshotImageDimensions,
        sourceDecodeMicroseconds: UInt64 = 0,
        resizeAndColorSpaceMicroseconds: UInt64 = 0,
        encodeStarted: ContinuousClock.Instant = .now
    ) throws -> SnapshotDerivedImagePayload {
        guard image.width == Int(dimensions.width),
              image.height == Int(dimensions.height)
        else {
            throw ElementAnalyzerError.invalidImageGeometry
        }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            bytes,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw ElementAnalyzerError.imageEncodeFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination), bytes.length > 0 else {
            throw ElementAnalyzerError.imageEncodeFailed
        }
        return try SnapshotDerivedImagePayload(
            bytes: [UInt8](bytes as Data),
            contentType: "image/png",
            dimensions: dimensions,
            timings: SnapshotDerivedImagePayloadTimings(
                sourceDecodeMicroseconds: sourceDecodeMicroseconds,
                resizeAndColorSpaceMicroseconds: resizeAndColorSpaceMicroseconds,
                inputEncodeMicroseconds: ElementAnalyzerTiming.elapsedMicroseconds(
                    since: encodeStarted
                )
            )
        )
    }

    func renderGrayscale(
        source: SnapshotSourceImageLease,
        sourceRect: SnapshotPixelRect,
        maximumEdge: UInt64
    ) throws -> GrayscaleImage {
        try renderGrayscale(
            source: prepareGrayscaleSource(source),
            sourceRect: sourceRect,
            maximumEdge: maximumEdge
        )
    }

    func prepareGrayscaleSource(
        _ source: SnapshotSourceImageLease
    ) throws -> GrayscaleSource {
        GrayscaleSource(
            dimensions: source.dimensions,
            image: try sourceImage(source)
        )
    }

    func grayscalePixelCount(
        sourceRect: SnapshotPixelRect,
        maximumEdge: UInt64
    ) throws -> Int {
        let geometry = try grayscaleGeometry(
            sourceRect: sourceRect,
            maximumEdge: maximumEdge
        )
        let (count, overflow) = geometry.width.multipliedReportingOverflow(
            by: geometry.height
        )
        guard !overflow else { throw ElementAnalyzerError.invalidImageGeometry }
        return count
    }

    func renderGrayscale(
        source: GrayscaleSource,
        sourceRect: SnapshotPixelRect,
        maximumEdge: UInt64
    ) throws -> GrayscaleImage {
        let rasterGeometry = try grayscaleGeometry(
            sourceRect: sourceRect,
            maximumEdge: maximumEdge
        )
        let input = try SnapshotImageDimensions(
            width: UInt64(rasterGeometry.width),
            height: UInt64(rasterGeometry.height)
        )
        let derivedGeometry = try SnapshotDerivedImageGeometry(
            sourceDimensions: source.dimensions,
            inputDimensions: input,
            sourceContentRect: sourceRect,
            inputContentRect: try SnapshotPixelRect(
                x: 0,
                y: 0,
                width: Double(input.width),
                height: Double(input.height)
            )
        )
        let rendered = try renderedImage(
            sourceImage: source.image,
            sourceDimensions: source.dimensions,
            geometry: derivedGeometry
        )
        let width = Int(input.width)
        let height = Int(input.height)
        var pixels = [UInt8](repeating: 0, count: width * height)
        let context = try pixels.withUnsafeMutableBytes { buffer -> CGContext in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue
            ) else { throw ElementAnalyzerError.imageDecodeFailed }
            return context
        }
        context.draw(rendered, in: CGRect(x: 0, y: 0, width: width, height: height))
        return GrayscaleImage(
            height: height,
            pixels: pixels,
            scale: rasterGeometry.scale,
            width: width
        )
    }

    private func grayscaleGeometry(
        sourceRect: SnapshotPixelRect,
        maximumEdge: UInt64
    ) throws -> GrayscaleGeometry {
        guard maximumEdge > 0,
              sourceRect.width > 0,
              sourceRect.height > 0
        else { throw ElementAnalyzerError.invalidImageGeometry }
        let scale = min(1, Double(maximumEdge) / max(
            sourceRect.width,
            sourceRect.height
        ))
        return GrayscaleGeometry(
            height: max(1, Int((sourceRect.height * scale).rounded())),
            scale: scale,
            width: max(1, Int((sourceRect.width * scale).rounded()))
        )
    }

    private func renderedImage(
        source: SnapshotSourceImageLease,
        geometry: SnapshotDerivedImageGeometry
    ) throws -> CGImage {
        guard source.dimensions == geometry.sourceDimensions else {
            throw ElementAnalyzerError.invalidImageGeometry
        }
        let decoded = try sourceImage(source)
        return try renderedImage(
            source: source,
            sourceImage: decoded,
            geometry: geometry
        )
    }

    private func renderedImage(
        source: SnapshotSourceImageLease,
        sourceImage: CIImage,
        geometry: SnapshotDerivedImageGeometry
    ) throws -> CGImage {
        do {
            return try renderedImage(
                sourceImage: sourceImage,
                sourceDimensions: source.dimensions,
                geometry: geometry
            )
        } catch let error as ElementAnalyzerError
            where error == .imageEncodeFailed
        {
            guard let sourceCGImage = source.cgImage else { throw error }
            return try renderedImage(
                sourceCGImage: sourceCGImage,
                sourceDimensions: source.dimensions,
                geometry: geometry
            )
        }
    }

    private func renderedImage(
        sourceImage image: CIImage,
        sourceDimensions: SnapshotImageDimensions,
        geometry: SnapshotDerivedImageGeometry
    ) throws -> CGImage {
        guard sourceDimensions == geometry.sourceDimensions else {
            throw ElementAnalyzerError.invalidImageGeometry
        }
        let sourceRect = geometry.sourceContentRect
        let inputRect = geometry.inputContentRect
        let sourceBottomY = Double(sourceDimensions.height) - sourceRect.maxY
        let inputBottomY = Double(geometry.inputDimensions.height) - inputRect.maxY
        let cropped = image
            .cropped(to: CGRect(
                x: sourceRect.x,
                y: sourceBottomY,
                width: sourceRect.width,
                height: sourceRect.height
            ))
            .transformed(by: CGAffineTransform(
                translationX: -sourceRect.x,
                y: -sourceBottomY
            ))
            .transformed(by: CGAffineTransform(
                scaleX: inputRect.width / sourceRect.width,
                y: inputRect.height / sourceRect.height
            ))
            .transformed(by: CGAffineTransform(
                translationX: inputRect.x,
                y: inputBottomY
            ))
        let outputBounds = CGRect(
            x: 0,
            y: 0,
            width: Double(geometry.inputDimensions.width),
            height: Double(geometry.inputDimensions.height)
        )
        let background = CIImage(color: .clear).cropped(to: outputBounds)
        let output = cropped.composited(over: background)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let rendered = context.createCGImage(
            output,
            from: outputBounds,
            format: .RGBA8,
            colorSpace: colorSpace
        ) ?? softwareContext.createCGImage(
            output,
            from: outputBounds,
            format: .RGBA8,
            colorSpace: colorSpace
        )
        guard let rendered else {
            throw ElementAnalyzerError.imageEncodeFailed
        }
        return rendered
    }

    private func renderedImage(
        sourceCGImage image: CGImage,
        sourceDimensions: SnapshotImageDimensions,
        geometry: SnapshotDerivedImageGeometry
    ) throws -> CGImage {
        guard sourceDimensions == geometry.sourceDimensions,
              image.width == Int(sourceDimensions.width),
              image.height == Int(sourceDimensions.height)
        else {
            throw ElementAnalyzerError.invalidImageGeometry
        }
        let outputWidth = Int(geometry.inputDimensions.width)
        let outputHeight = Int(geometry.inputDimensions.height)
        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: outputWidth * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw ElementAnalyzerError.imageEncodeFailed
        }

        let sourceRect = geometry.sourceContentRect
        let inputRect = geometry.inputContentRect
        let destination = CGRect(
            x: inputRect.x,
            y: Double(outputHeight) - inputRect.maxY,
            width: inputRect.width,
            height: inputRect.height
        )
        let sourceBottomY = Double(sourceDimensions.height) - sourceRect.maxY
        let scaleX = inputRect.width / sourceRect.width
        let scaleY = inputRect.height / sourceRect.height
        context.clear(CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        // Core Image can be unavailable in restricted hosts even for CGImage input.
        context.interpolationQuality = .none
        context.saveGState()
        context.clip(to: destination)
        context.concatenate(CGAffineTransform(
            a: scaleX,
            b: 0,
            c: 0,
            d: scaleY,
            tx: destination.minX - sourceRect.x * scaleX,
            ty: destination.minY - sourceBottomY * scaleY
        ))
        context.draw(image, in: CGRect(
            x: 0,
            y: 0,
            width: image.width,
            height: image.height
        ))
        context.restoreGState()
        guard let rendered = context.makeImage() else {
            throw ElementAnalyzerError.imageEncodeFailed
        }
        return rendered
    }

    private func sourceImage(_ source: SnapshotSourceImageLease) throws -> CIImage {
        if let pixelBuffer = source.pixelBuffer {
            return CIImage(cvPixelBuffer: pixelBuffer)
        }
        if let cgImage = source.cgImage {
            return CIImage(cgImage: cgImage)
        }
        if let encoded = source.encodedImage {
            let data = Data(encoded.bytes) as CFData
            guard let imageSource = CGImageSourceCreateWithData(data, nil),
                  let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil),
                  cgImage.width == Int(source.dimensions.width),
                  cgImage.height == Int(source.dimensions.height)
            else {
                throw ElementAnalyzerError.imageDecodeFailed
            }
            return CIImage(cgImage: cgImage)
        }
        throw ElementAnalyzerError.imageDecodeFailed
    }
}
