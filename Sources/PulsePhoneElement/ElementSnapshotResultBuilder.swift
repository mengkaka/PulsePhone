import Foundation
import PulsePhoneMedia
import PulsePhoneSharedDefinitions

public enum ElementSnapshotResultBuildError: Error, Equatable, Sendable {
    case encodedResultTooLarge
    case invalidAnalyzerBatch
    case invalidAnnotation
    case invalidCandidate
    case invalidCaptureDigest
    case invalidCaptureAttempts
    case invalidDimensions
    case invalidEngineMetadata
    case invalidTiming
    case labelTooLarge
    case tooManyElements
}

public enum ElementSnapshotCaptureAttemptStatus: String, Equatable, Sendable {
    case failed
    case succeeded
}

public enum ElementSnapshotCaptureFailureCode: String, Equatable, Sendable {
    case developerServicesUnavailable
}

public enum ElementSnapshotCaptureFailureStage: String, Equatable, Sendable {
    case captureOrValidate
    case serviceOpen
}

public struct ElementSnapshotCaptureAttemptTimings: Equatable, Sendable {
    public let captureMicroseconds: UInt64
    public let queueWaitMicroseconds: UInt64
    public let serviceCloseMicroseconds: UInt64
    public let serviceOpenMicroseconds: UInt64
    public let totalMicroseconds: UInt64

    public init(
        captureMicroseconds: UInt64,
        queueWaitMicroseconds: UInt64,
        serviceCloseMicroseconds: UInt64,
        serviceOpenMicroseconds: UInt64,
        totalMicroseconds: UInt64
    ) {
        self.captureMicroseconds = captureMicroseconds
        self.queueWaitMicroseconds = queueWaitMicroseconds
        self.serviceCloseMicroseconds = serviceCloseMicroseconds
        self.serviceOpenMicroseconds = serviceOpenMicroseconds
        self.totalMicroseconds = totalMicroseconds
    }
}

public struct ElementSnapshotCaptureAttempt: Equatable, Sendable {
    public let errorCode: ElementSnapshotCaptureFailureCode?
    public let failureStage: ElementSnapshotCaptureFailureStage?
    public let provider: SnapshotCaptureProvider
    public let status: ElementSnapshotCaptureAttemptStatus
    public let timings: ElementSnapshotCaptureAttemptTimings

    public init(
        provider: SnapshotCaptureProvider,
        status: ElementSnapshotCaptureAttemptStatus,
        errorCode: ElementSnapshotCaptureFailureCode?,
        failureStage: ElementSnapshotCaptureFailureStage?,
        timings: ElementSnapshotCaptureAttemptTimings
    ) {
        self.errorCode = errorCode
        self.failureStage = failureStage
        self.provider = provider
        self.status = status
        self.timings = timings
    }
}

public struct ElementSnapshotPipelineTimings: Equatable, Sendable {
    public let annotationMilliseconds: UInt64?
    public let captureMilliseconds: UInt64
    public let fusionMilliseconds: UInt64
    public let sourceDecodeMicroseconds: UInt64

    public init(
        captureMilliseconds: UInt64,
        fusionMilliseconds: UInt64,
        sourceDecodeMicroseconds: UInt64 = 0,
        annotationMilliseconds: UInt64? = nil
    ) {
        self.annotationMilliseconds = annotationMilliseconds
        self.captureMilliseconds = captureMilliseconds
        self.fusionMilliseconds = fusionMilliseconds
        self.sourceDecodeMicroseconds = sourceDecodeMicroseconds
    }
}

public struct ElementSnapshotResult: Sendable {
    public let annotationElements: [ElementSnapshotAnnotationElement]
    public let canonicalBytes: [UInt8]
    public let captureSHA256: String
    public let root: RepositoryJSONObject
    public let snapshotGeneration: UInt64
}

public struct ElementSnapshotAnnotationElement: Equatable, Sendable {
    public let frame: SnapshotPixelRect
    public let snapshotID: String
    public let sources: [ElementAnalyzerSource]
    public let type: ElementCandidateType
}

public struct ElementSnapshotAnnotationMetadata: Equatable, Sendable {
    public let artifactID: CanonicalUUID
    public let byteLength: UInt64
    public let captureSHA256: String
    public let outputPath: String?
    public let sha256: String
    public let snapshotGeneration: UInt64

    public init(
        artifactID: CanonicalUUID,
        byteLength: UInt64,
        captureSHA256: String,
        sha256: String,
        snapshotGeneration: UInt64,
        outputPath: String? = nil
    ) {
        self.artifactID = artifactID
        self.byteLength = byteLength
        self.captureSHA256 = captureSHA256
        self.outputPath = outputPath
        self.sha256 = sha256
        self.snapshotGeneration = snapshotGeneration
    }
}

public struct ElementSnapshotResultBuilder: Sendable {
    public static let maximumEncodedBytes = 256 * 1_024
    public static let maximumElements = 256
    public static let maximumImageDimension: UInt64 = 65_535
    public static let maximumLabelUTF8Bytes = 1_024
    public static let maximumCorrectionTimingMilliseconds: UInt64 = 60_000
    public static let maximumStageTimingMicroseconds: UInt64 = 60_000_000

    private static let coordinateScale: Int64 = 100_000_000
    private static let confidenceScale: Int64 = 1_000_000_000

    private struct FixedRect: Equatable {
        let maxX: Int64
        let maxY: Int64
        let x: Int64
        let y: Int64

        var area: Int64 {
            let (value, overflow) = (maxX - x).multipliedReportingOverflow(
                by: maxY - y
            )
            return overflow ? .max : value
        }

        var height: Int64 { maxY - y }
        var width: Int64 { maxX - x }
    }

    private struct CaptureFreshnessTimings {
        let fenceWaitMilliseconds: UInt64
        let frameAgeMilliseconds: UInt64
    }

    private struct PreparedCandidate {
        let candidate: FusedElementCandidate
        let confidence: RepositoryJSONValue
        let confidenceKey: String
        let identity: String
        let labelSource: String
        let logical: FixedRect
        let normalized: FixedRect
        let pixel: FixedRect
        let sourceKey: String
        let sources: [ElementAnalyzerSource]
    }

    public init() {}

    public func build(
        frame: SnapshotFrame,
        analyzerBatch: ElementAnalyzerBatch,
        localGeometry: ElementLocalGeometryResult,
        captureSHA256: String,
        timings: ElementSnapshotPipelineTimings,
        captureAttempts explicitCaptureAttempts: [ElementSnapshotCaptureAttempt]? = nil
    ) throws -> ElementSnapshotResult {
        guard StableBytes.isLowercaseHex(captureSHA256, byteCount: 32) else {
            throw ElementSnapshotResultBuildError.invalidCaptureDigest
        }
        try Self.validateDimensions(frame)
        guard localGeometry.candidates.count <= Self.maximumElements else {
            throw ElementSnapshotResultBuildError.tooManyElements
        }
        let captureFreshness = try Self.captureFreshnessTimings(frame)
        try Self.validateTimings(
            analyzer: analyzerBatch.elapsedMilliseconds,
            capture: timings.captureMilliseconds,
            correction: localGeometry.elapsedMilliseconds,
            fusion: timings.fusionMilliseconds,
            annotation: timings.annotationMilliseconds,
            sourceDecode: timings.sourceDecodeMicroseconds,
            captureFreshness: captureFreshness
        )
        let captureAttempts = try Self.captureAttempts(
            explicitCaptureAttempts,
            frame: frame,
            captureMilliseconds: timings.captureMilliseconds
        )

        let engineResults = try Self.validateAnalyzerBatch(analyzerBatch)
        let degradationSources = Self.analyzerOrder.filter {
            engineResults[$0]?.status != .succeeded
        }
        guard analyzerBatch.degraded == !degradationSources.isEmpty else {
            throw ElementSnapshotResultBuildError.invalidAnalyzerBatch
        }

        let prepared = try localGeometry.candidates.map {
            try Self.prepare($0, frame: frame)
        }.sorted(by: Self.canonicalOrder)
        let elements = try Self.elementValues(prepared)
        let root = try RepositoryJSONObject(members: [
            .init(
                key: "capture",
                value: .object(try Self.captureObject(
                    frame: frame,
                    captureSHA256: captureSHA256,
                    attempts: captureAttempts,
                    freshness: captureFreshness
                ))
            ),
            .init(
                key: "degradationReasons",
                value: .array(degradationSources.map { .string($0.rawValue) })
            ),
            .init(key: "degraded", value: .bool(!degradationSources.isEmpty)),
            .init(key: "elements", value: .array(elements.values)),
            .init(
                key: "engines",
                value: .object(try Self.enginesObject(engineResults))
            ),
            .init(
                key: "settleReason",
                value: .string(Self.settleReason(frame.metadata.settleReason))
            ),
            .init(
                key: "snapshotGeneration",
                value: .number(.uint64(frame.metadata.captureGeneration))
            ),
            .init(
                key: "timings",
                value: .object(try Self.timingsObject(
                    analyzer: analyzerBatch.elapsedMilliseconds,
                    capture: timings.captureMilliseconds,
                    correction: localGeometry.elapsedMilliseconds,
                    fusion: timings.fusionMilliseconds,
                    annotation: timings.annotationMilliseconds,
                    sourceDecode: timings.sourceDecodeMicroseconds
                ))
            ),
        ])
        let bytes = RepositoryCanonicalJSON.encodeDocument(root)
        guard bytes.count <= Self.maximumEncodedBytes else {
            throw ElementSnapshotResultBuildError.encodedResultTooLarge
        }
        return ElementSnapshotResult(
            annotationElements: elements.annotationElements,
            canonicalBytes: bytes,
            captureSHA256: captureSHA256,
            root: root,
            snapshotGeneration: frame.metadata.captureGeneration
        )
    }

    public func attachingAnnotation(
        _ annotation: ElementSnapshotAnnotationMetadata,
        elapsedMilliseconds: UInt64,
        to result: ElementSnapshotResult
    ) throws -> ElementSnapshotResult {
        guard result.root["annotation"] == nil,
              annotation.snapshotGeneration == result.snapshotGeneration,
              annotation.captureSHA256 == result.captureSHA256,
              annotation.byteLength > 0,
              annotation.byteLength <= 64 * 1_024 * 1_024,
              StableBytes.isLowercaseHex(annotation.sha256, byteCount: 32),
              elapsedMilliseconds <= 5_000,
              annotation.outputPath.map({ path in
                  !path.isEmpty && path.utf8.count <= 4_096 && path.count <= 4_096
              }) ?? true,
              let existingTimings = result.root["timings"]?.objectValue,
              existingTimings["annotationMilliseconds"].map(Self.isNull) == true
        else {
            throw ElementSnapshotResultBuildError.invalidAnnotation
        }
        var annotationMembers: [RepositoryJSONMember] = [
            .init(
                key: "artifactID",
                value: .string(annotation.artifactID.canonicalString)
            ),
            .init(
                key: "byteLength",
                value: .number(.uint64(annotation.byteLength))
            ),
            .init(
                key: "captureSHA256",
                value: .string(annotation.captureSHA256)
            ),
            .init(key: "contentType", value: .string("image/png")),
            .init(key: "sha256", value: .string(annotation.sha256)),
            .init(
                key: "snapshotGeneration",
                value: .number(.uint64(annotation.snapshotGeneration))
            ),
        ]
        if let outputPath = annotation.outputPath {
            annotationMembers.append(.init(
                key: "outputPath",
                value: .string(outputPath)
            ))
        }
        let updatedTimings = try RepositoryJSONObject(members: existingTimings.members.map {
            $0.key == "annotationMilliseconds"
                ? .init(
                    key: $0.key,
                    value: .number(.uint64(elapsedMilliseconds))
                )
                : $0
        })
        var rootMembers = result.root.members.filter {
            $0.key != "timings" && $0.key != "annotation"
        }
        rootMembers.append(.init(
            key: "annotation",
            value: .object(try RepositoryJSONObject(members: annotationMembers))
        ))
        rootMembers.append(.init(key: "timings", value: .object(updatedTimings)))
        let root = try RepositoryJSONObject(members: rootMembers)
        let bytes = RepositoryCanonicalJSON.encodeDocument(root)
        guard bytes.count <= Self.maximumEncodedBytes else {
            throw ElementSnapshotResultBuildError.encodedResultTooLarge
        }
        return ElementSnapshotResult(
            annotationElements: result.annotationElements,
            canonicalBytes: bytes,
            captureSHA256: result.captureSHA256,
            root: root,
            snapshotGeneration: result.snapshotGeneration
        )
    }

    private static let analyzerOrder: [ElementAnalyzerSource] = [
        .omniparser,
        .vision,
        .appleRegion,
    ]

    private static let sourceOrder: [ElementAnalyzerSource] = [
        .omniparser,
        .vision,
        .appleRegion,
        .localGeometry,
    ]

    private static func validateDimensions(_ frame: SnapshotFrame) throws {
        let pixel = frame.metadata.pixelDimensions
        let geometry = frame.metadata.geometry
        guard pixel.width <= maximumImageDimension,
              pixel.height <= maximumImageDimension,
              geometry.logicalWidth <= maximumImageDimension,
              geometry.logicalHeight <= maximumImageDimension
        else {
            throw ElementSnapshotResultBuildError.invalidDimensions
        }
    }

    private static func validateAnalyzerBatch(
        _ batch: ElementAnalyzerBatch
    ) throws -> [ElementAnalyzerSource: ElementAnalyzerResult] {
        guard batch.results.count == analyzerOrder.count else {
            throw ElementSnapshotResultBuildError.invalidAnalyzerBatch
        }
        var output = [ElementAnalyzerSource: ElementAnalyzerResult]()
        for result in batch.results {
            guard analyzerOrder.contains(result.source),
                  output[result.source] == nil,
                  result.candidates.count <= 2_048,
                  result.candidates.allSatisfy({ $0.source == result.source }),
                  result.status == .succeeded || result.candidates.isEmpty,
                  validRequiredString(result.profileID, maximumBytes: 128),
                  validOptionalString(result.backend, maximumBytes: 128),
                  validOptionalString(result.version, maximumBytes: 128),
                  result.elapsedMilliseconds.map({ $0 <= 10_000 }) ?? true,
                  result.inferenceMilliseconds.map({ $0 <= 10_000 }) ?? true,
                  result.queueWaitMilliseconds.map({ $0 <= 10_000 }) ?? true,
                  validStageTimings(result),
                  result.inputDimensions.map({ dimensions in
                      dimensions.width <= maximumImageDimension
                          && dimensions.height <= maximumImageDimension
                  }) ?? true
            else {
                throw ElementSnapshotResultBuildError.invalidEngineMetadata
            }
            output[result.source] = result
        }
        guard analyzerOrder.allSatisfy({ output[$0] != nil }),
              output.values.contains(where: { $0.status == .succeeded })
        else {
            throw ElementSnapshotResultBuildError.invalidAnalyzerBatch
        }
        return output
    }

    private static func prepare(
        _ candidate: FusedElementCandidate,
        frame: SnapshotFrame
    ) throws -> PreparedCandidate {
        let sources = candidate.sources.sorted {
            sourceOrder.firstIndex(of: $0)! < sourceOrder.firstIndex(of: $1)!
        }
        guard !sources.isEmpty,
              sources.count <= sourceOrder.count,
              Set(sources).count == sources.count,
              candidate.confidence.map({ $0.isFinite && (0...1).contains($0) })
                ?? true
        else {
            throw ElementSnapshotResultBuildError.invalidCandidate
        }
        if let label = candidate.label {
            guard !label.isEmpty else {
                throw ElementSnapshotResultBuildError.invalidCandidate
            }
            guard label.utf8.count <= maximumLabelUTF8Bytes,
                  label.count <= 1_024
            else {
                throw ElementSnapshotResultBuildError.labelTooLarge
            }
            guard candidate.labelSource == .vision, sources.contains(.vision) else {
                throw ElementSnapshotResultBuildError.invalidCandidate
            }
        } else if candidate.labelSource != nil {
            throw ElementSnapshotResultBuildError.invalidCandidate
        }

        let pixel = try fixedPixelRect(
            candidate.frame,
            dimensions: frame.metadata.pixelDimensions
        )
        let logical = try project(
            pixel,
            sourceWidth: frame.metadata.pixelDimensions.width,
            sourceHeight: frame.metadata.pixelDimensions.height,
            targetWidth: frame.metadata.geometry.logicalWidth,
            targetHeight: frame.metadata.geometry.logicalHeight
        )
        let normalized = try project(
            pixel,
            sourceWidth: frame.metadata.pixelDimensions.width,
            sourceHeight: frame.metadata.pixelDimensions.height,
            targetWidth: 1,
            targetHeight: 1
        )
        let sourceKey = sources.map(\.rawValue).joined(separator: ",")
        let identityPayload = [
            String(pixel.x),
            String(pixel.y),
            String(pixel.maxX),
            String(pixel.maxY),
            sourceKey,
        ].joined(separator: ":")
        let identity = try StableBytes.domainSeparatedSHA256Hex(
            domainID: "pulsephone.element.snapshot-id.v1",
            payload: identityPayload.utf8
        )
        let confidence = try candidate.confidence.map(Self.confidenceValue) ?? .null
        return PreparedCandidate(
            candidate: candidate,
            confidence: confidence,
            confidenceKey: confidenceSortKey(confidence),
            identity: identity,
            labelSource: candidate.labelSource == .vision ? "vision" : "none",
            logical: logical,
            normalized: normalized,
            pixel: pixel,
            sourceKey: sourceKey,
            sources: sources
        )
    }

    private static func fixedPixelRect(
        _ rect: SnapshotPixelRect,
        dimensions: SnapshotImageDimensions
    ) throws -> FixedRect {
        let bounds = try SnapshotPixelRect(
            x: 0,
            y: 0,
            width: Double(dimensions.width),
            height: Double(dimensions.height)
        )
        guard let clipped = rect.intersection(bounds) else {
            throw ElementSnapshotResultBuildError.invalidCandidate
        }
        let output = FixedRect(
            maxX: try fixedUnits(clipped.maxX),
            maxY: try fixedUnits(clipped.maxY),
            x: try fixedUnits(clipped.x),
            y: try fixedUnits(clipped.y)
        )
        guard output.width > 0, output.height > 0 else {
            throw ElementSnapshotResultBuildError.invalidCandidate
        }
        return output
    }

    private static func project(
        _ source: FixedRect,
        sourceWidth: UInt64,
        sourceHeight: UInt64,
        targetWidth: UInt64,
        targetHeight: UInt64
    ) throws -> FixedRect {
        func axis(_ value: Int64, source: UInt64, target: UInt64) throws -> Int64 {
            let projected = Double(value) * Double(target) / Double(source)
            guard projected.isFinite,
                  projected >= 0,
                  projected <= Double(Int64.max)
            else {
                throw ElementSnapshotResultBuildError.invalidDimensions
            }
            return Int64(projected.rounded())
        }
        let output = FixedRect(
            maxX: try axis(source.maxX, source: sourceWidth, target: targetWidth),
            maxY: try axis(source.maxY, source: sourceHeight, target: targetHeight),
            x: try axis(source.x, source: sourceWidth, target: targetWidth),
            y: try axis(source.y, source: sourceHeight, target: targetHeight)
        )
        guard output.width > 0, output.height > 0 else {
            throw ElementSnapshotResultBuildError.invalidCandidate
        }
        return output
    }

    private static func fixedUnits(_ value: Double) throws -> Int64 {
        let scaled = value * Double(coordinateScale)
        guard value.isFinite,
              value >= 0,
              scaled.isFinite,
              scaled <= Double(Int64.max)
        else {
            throw ElementSnapshotResultBuildError.invalidCandidate
        }
        return Int64(scaled.rounded())
    }

    private static func confidenceValue(_ value: Double) throws -> RepositoryJSONValue {
        let scaled = value * Double(confidenceScale)
        guard scaled.isFinite, scaled >= 0, scaled <= Double(confidenceScale) else {
            throw ElementSnapshotResultBuildError.invalidCandidate
        }
        return try fixedNumber(
            units: Int64(scaled.rounded()),
            scale: confidenceScale
        )
    }

    private static func elementValues(
        _ candidates: [PreparedCandidate]
    ) throws -> (
        values: [RepositoryJSONValue],
        annotationElements: [ElementSnapshotAnnotationElement]
    ) {
        var collisionCounts = [String: Int]()
        var values = [RepositoryJSONValue]()
        var annotationElements = [ElementSnapshotAnnotationElement]()
        for candidate in candidates {
            let collision = (collisionCounts[candidate.identity] ?? 0) + 1
            collisionCounts[candidate.identity] = collision
            let snapshotID = collision == 1
                ? "element.\(candidate.identity)"
                : "element.\(candidate.identity).\(collision)"
            guard snapshotID.utf8.count <= 128 else {
                throw ElementSnapshotResultBuildError.invalidCandidate
            }
            values.append(.object(try RepositoryJSONObject(members: [
                .init(
                    key: "center",
                    value: .object(try centerObject(
                        pixel: candidate.pixel,
                        logical: candidate.logical,
                        normalized: candidate.normalized
                    ))
                ),
                .init(key: "confidence", value: candidate.confidence),
                .init(
                    key: "elementType",
                    value: .string(candidate.candidate.type.rawValue)
                ),
                .init(key: "enabled", value: .null),
                .init(
                    key: "frame",
                    value: .object(try frameObject(
                        pixel: candidate.pixel,
                        logical: candidate.logical,
                        normalized: candidate.normalized
                    ))
                ),
                .init(key: "hittable", value: .null),
                .init(key: "identifier", value: .null),
                .init(
                    key: "label",
                    value: candidate.candidate.label.map(RepositoryJSONValue.string)
                        ?? .null
                ),
                .init(key: "labelSource", value: .string(candidate.labelSource)),
                .init(key: "selected", value: .null),
                .init(key: "snapshotID", value: .string(snapshotID)),
                .init(
                    key: "sources",
                    value: .array(candidate.sources.map { .string($0.rawValue) })
                ),
                .init(key: "trackingID", value: .null),
            ])))
            if candidate.candidate.type == .controlCandidate {
                annotationElements.append(ElementSnapshotAnnotationElement(
                    frame: try pixelRect(candidate.pixel),
                    snapshotID: snapshotID,
                    sources: candidate.sources,
                    type: candidate.candidate.type
                ))
            }
        }
        return (values, annotationElements)
    }

    private static func canonicalOrder(
        _ left: PreparedCandidate,
        _ right: PreparedCandidate
    ) -> Bool {
        if left.pixel.y != right.pixel.y { return left.pixel.y < right.pixel.y }
        if left.pixel.x != right.pixel.x { return left.pixel.x < right.pixel.x }
        if left.pixel.area != right.pixel.area { return left.pixel.area < right.pixel.area }
        if left.sourceKey != right.sourceKey { return left.sourceKey < right.sourceKey }
        if left.candidate.type.rawValue != right.candidate.type.rawValue {
            return left.candidate.type.rawValue < right.candidate.type.rawValue
        }
        if left.confidenceKey != right.confidenceKey {
            return left.confidenceKey < right.confidenceKey
        }
        return (left.candidate.label ?? "").utf8.lexicographicallyPrecedes(
            (right.candidate.label ?? "").utf8
        )
    }

    private static func captureObject(
        frame: SnapshotFrame,
        captureSHA256: String,
        attempts: [ElementSnapshotCaptureAttempt],
        freshness: CaptureFreshnessTimings
    ) throws -> RepositoryJSONObject {
        let metadata = frame.metadata
        let fallbackReason = attempts.dropLast().last
        return try RepositoryJSONObject(members: [
            .init(
                key: "attempts",
                value: .array(try attempts.map {
                    .object(try captureAttemptObject($0))
                })
            ),
            .init(
                key: "capturedAtMonotonicNanoseconds",
                value: .number(.uint64(metadata.capturedAtNanoseconds))
            ),
            .init(
                key: "connectionEpoch",
                value: .number(.uint64(metadata.connectionEpoch))
            ),
            .init(
                key: "fallbackReason",
                value: try fallbackReason.map {
                    .object(try captureFallbackReasonObject($0))
                } ?? .null
            ),
            .init(
                key: "fenceWaitMilliseconds",
                value: .number(.uint64(freshness.fenceWaitMilliseconds))
            ),
            .init(
                key: "frameAgeMilliseconds",
                value: .number(.uint64(freshness.frameAgeMilliseconds))
            ),
            .init(
                key: "geometryRevision",
                value: .number(.uint64(metadata.geometry.geometryRevision))
            ),
            .init(
                key: "logicalHeight",
                value: .number(.uint64(metadata.geometry.logicalHeight))
            ),
            .init(
                key: "logicalWidth",
                value: .number(.uint64(metadata.geometry.logicalWidth))
            ),
            .init(
                key: "orientation",
                value: .string(metadata.geometry.orientation.rawValue)
            ),
            .init(
                key: "pixelHeight",
                value: .number(.uint64(metadata.pixelDimensions.height))
            ),
            .init(
                key: "pixelWidth",
                value: .number(.uint64(metadata.pixelDimensions.width))
            ),
            .init(key: "provider", value: .string(provider(metadata.provider))),
            .init(key: "sha256", value: .string(captureSHA256)),
        ])
    }

    private static func captureAttempts(
        _ explicit: [ElementSnapshotCaptureAttempt]?,
        frame: SnapshotFrame,
        captureMilliseconds: UInt64
    ) throws -> [ElementSnapshotCaptureAttempt] {
        let attempts: [ElementSnapshotCaptureAttempt]
        if let explicit {
            attempts = explicit
        } else {
            let totalMicroseconds = captureMilliseconds * 1_000
            attempts = [ElementSnapshotCaptureAttempt(
                provider: frame.metadata.provider,
                status: .succeeded,
                errorCode: nil,
                failureStage: nil,
                timings: ElementSnapshotCaptureAttemptTimings(
                    captureMicroseconds: totalMicroseconds,
                    queueWaitMicroseconds: 0,
                    serviceCloseMicroseconds: 0,
                    serviceOpenMicroseconds: 0,
                    totalMicroseconds: totalMicroseconds
                )
            )]
        }
        guard (1...3).contains(attempts.count),
              attempts.last?.provider == frame.metadata.provider,
              validCaptureProviderOrder(attempts.map(\.provider))
        else {
            throw ElementSnapshotResultBuildError.invalidCaptureAttempts
        }
        for (index, attempt) in attempts.enumerated() {
            let shouldSucceed = index == attempts.index(before: attempts.endIndex)
            guard attempt.status == (shouldSucceed ? .succeeded : .failed),
                  validCaptureFailure(attempt),
                  validCaptureAttemptTimings(attempt.timings)
            else {
                throw ElementSnapshotResultBuildError.invalidCaptureAttempts
            }
        }
        return attempts
    }

    private static func validCaptureProviderOrder(
        _ providers: [SnapshotCaptureProvider]
    ) -> Bool {
        guard let first = providers.first else { return false }
        if first == .liveVideo || first == .legacyScreenshotR {
            return providers.count == 1
        }
        let deviceOrder: [SnapshotCaptureProvider] = [.dvt, .coreDevice, .axAudit]
        guard let firstIndex = deviceOrder.firstIndex(of: first) else {
            return false
        }
        return Array(deviceOrder[firstIndex...].prefix(providers.count)) == providers
    }

    private static func validCaptureFailure(
        _ attempt: ElementSnapshotCaptureAttempt
    ) -> Bool {
        switch attempt.status {
        case .succeeded:
            return attempt.errorCode == nil && attempt.failureStage == nil
        case .failed:
            return attempt.errorCode != nil && attempt.failureStage != nil
        }
    }

    private static func validCaptureAttemptTimings(
        _ timings: ElementSnapshotCaptureAttemptTimings
    ) -> Bool {
        let values = [
            timings.captureMicroseconds,
            timings.queueWaitMicroseconds,
            timings.serviceCloseMicroseconds,
            timings.serviceOpenMicroseconds,
            timings.totalMicroseconds,
        ]
        return values.allSatisfy { $0 <= 30_000_000 }
    }

    private static func captureAttemptObject(
        _ attempt: ElementSnapshotCaptureAttempt
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(members: [
            .init(
                key: "errorCode",
                value: attempt.errorCode.map { .string($0.rawValue) } ?? .null
            ),
            .init(
                key: "failureStage",
                value: attempt.failureStage.map { .string($0.rawValue) } ?? .null
            ),
            .init(key: "provider", value: .string(provider(attempt.provider))),
            .init(key: "status", value: .string(attempt.status.rawValue)),
            .init(
                key: "timings",
                value: .object(try captureAttemptTimingsObject(attempt.timings))
            ),
        ])
    }

    private static func captureFallbackReasonObject(
        _ attempt: ElementSnapshotCaptureAttempt
    ) throws -> RepositoryJSONObject {
        guard let errorCode = attempt.errorCode,
              let failureStage = attempt.failureStage
        else {
            throw ElementSnapshotResultBuildError.invalidCaptureAttempts
        }
        return try RepositoryJSONObject(members: [
            .init(key: "errorCode", value: .string(errorCode.rawValue)),
            .init(key: "failedProvider", value: .string(provider(attempt.provider))),
            .init(key: "failureStage", value: .string(failureStage.rawValue)),
        ])
    }

    private static func captureAttemptTimingsObject(
        _ timings: ElementSnapshotCaptureAttemptTimings
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(members: [
            .init(
                key: "captureMicroseconds",
                value: .number(.uint64(timings.captureMicroseconds))
            ),
            .init(
                key: "queueWaitMicroseconds",
                value: .number(.uint64(timings.queueWaitMicroseconds))
            ),
            .init(
                key: "serviceCloseMicroseconds",
                value: .number(.uint64(timings.serviceCloseMicroseconds))
            ),
            .init(
                key: "serviceOpenMicroseconds",
                value: .number(.uint64(timings.serviceOpenMicroseconds))
            ),
            .init(
                key: "totalMicroseconds",
                value: .number(.uint64(timings.totalMicroseconds))
            ),
        ])
    }

    private static func enginesObject(
        _ results: [ElementAnalyzerSource: ElementAnalyzerResult]
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(members: analyzerOrder.map { source in
            RepositoryJSONMember(
                key: source.rawValue,
                value: .object(try engineObject(results[source]!))
            )
        })
    }

    private static func engineObject(
        _ result: ElementAnalyzerResult
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(members: [
            .init(
                key: "backend",
                value: result.backend.map(RepositoryJSONValue.string) ?? .null
            ),
            .init(
                key: "candidateCount",
                value: .number(.uint64(UInt64(result.candidates.count)))
            ),
            .init(
                key: "elapsedMilliseconds",
                value: result.elapsedMilliseconds.map {
                    .number(.uint64($0))
                } ?? .null
            ),
            .init(
                key: "inferenceMilliseconds",
                value: result.inferenceMilliseconds.map {
                    .number(.uint64($0))
                } ?? .null
            ),
            .init(
                key: "inputHeight",
                value: result.inputDimensions.map {
                    .number(.uint64($0.height))
                } ?? .null
            ),
            .init(
                key: "inputWidth",
                value: result.inputDimensions.map {
                    .number(.uint64($0.width))
                } ?? .null
            ),
            .init(key: "profileID", value: .string(result.profileID)),
            .init(
                key: "queueWaitMilliseconds",
                value: result.queueWaitMilliseconds.map {
                    .number(.uint64($0))
                } ?? .null
            ),
            .init(key: "status", value: .string(result.status.rawValue)),
            .init(
                key: "stageTimings",
                value: .object(try analyzerStageTimingsObject(result.stageTimings))
            ),
            .init(
                key: "version",
                value: result.version.map(RepositoryJSONValue.string) ?? .null
            ),
        ])
    }

    private static func timingsObject(
        analyzer: UInt64,
        capture: UInt64,
        correction: UInt64,
        fusion: UInt64,
        annotation: UInt64?,
        sourceDecode: UInt64
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(members: [
            .init(
                key: "analyzerWallMilliseconds",
                value: .number(.uint64(analyzer))
            ),
            .init(
                key: "annotationMilliseconds",
                value: annotation.map { .number(.uint64($0)) } ?? .null
            ),
            .init(
                key: "captureMilliseconds",
                value: .number(.uint64(capture))
            ),
            .init(
                key: "correctionMilliseconds",
                value: .number(.uint64(correction))
            ),
            .init(
                key: "fusionMilliseconds",
                value: .number(.uint64(fusion))
            ),
            .init(
                key: "sourceDecodeMicroseconds",
                value: .number(.uint64(sourceDecode))
            ),
        ])
    }

    private static func analyzerStageTimingsObject(
        _ timings: ElementAnalyzerStageTimings
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(members: [
            .init(
                key: "inputEncodeMicroseconds",
                value: timingValue(timings.inputEncodeMicroseconds)
            ),
            .init(
                key: "requestEncodeMicroseconds",
                value: timingValue(timings.requestEncodeMicroseconds)
            ),
            .init(
                key: "resizeAndColorSpaceMicroseconds",
                value: timingValue(timings.resizeAndColorSpaceMicroseconds)
            ),
            .init(
                key: "responseDecodeMicroseconds",
                value: timingValue(timings.responseDecodeMicroseconds)
            ),
            .init(
                key: "transportOverheadMicroseconds",
                value: timingValue(timings.transportOverheadMicroseconds)
            ),
            .init(
                key: "transportRoundTripMicroseconds",
                value: timingValue(timings.transportRoundTripMicroseconds)
            ),
        ])
    }

    private static func timingValue(_ value: UInt64?) -> RepositoryJSONValue {
        value.map { .number(.uint64($0)) } ?? .null
    }

    private static func validateTimings(
        analyzer: UInt64,
        capture: UInt64,
        correction: UInt64,
        fusion: UInt64,
        annotation: UInt64?,
        sourceDecode: UInt64,
        captureFreshness: CaptureFreshnessTimings
    ) throws {
        guard analyzer <= 10_000,
              capture <= 30_000,
              correction <= maximumCorrectionTimingMilliseconds,
              fusion <= 1_000,
              annotation.map({ $0 <= 5_000 }) ?? true,
              sourceDecode <= 30_000_000,
              captureFreshness.fenceWaitMilliseconds <= 30_000,
              captureFreshness.frameAgeMilliseconds <= 30_000
        else {
            throw ElementSnapshotResultBuildError.invalidTiming
        }
    }

    private static func validStageTimings(_ result: ElementAnalyzerResult) -> Bool {
        let timings = result.stageTimings
        let values = [
            timings.inputEncodeMicroseconds,
            timings.requestEncodeMicroseconds,
            timings.resizeAndColorSpaceMicroseconds,
            timings.responseDecodeMicroseconds,
            timings.transportOverheadMicroseconds,
            timings.transportRoundTripMicroseconds,
        ]
        guard values.allSatisfy({
            $0.map({ $0 <= maximumStageTimingMicroseconds }) ?? true
        }) else { return false }
        if let overhead = timings.transportOverheadMicroseconds {
            guard let roundTrip = timings.transportRoundTripMicroseconds,
                  overhead <= roundTrip
            else { return false }
        }
        guard result.status == .succeeded else { return true }
        switch result.source {
        case .omniparser:
            return values.allSatisfy { $0 != nil }
        case .appleRegion:
            return timings.resizeAndColorSpaceMicroseconds != nil
                && timings.inputEncodeMicroseconds != nil
                && timings.requestEncodeMicroseconds == nil
                && timings.transportRoundTripMicroseconds != nil
                && timings.transportOverheadMicroseconds != nil
                && timings.responseDecodeMicroseconds != nil
        case .vision:
            return timings.resizeAndColorSpaceMicroseconds == 0
                && timings.inputEncodeMicroseconds == 0
                && timings.requestEncodeMicroseconds == 0
                && timings.transportRoundTripMicroseconds == 0
                && timings.transportOverheadMicroseconds == 0
                && timings.responseDecodeMicroseconds != nil
        case .localGeometry:
            return false
        }
    }

    private static func captureFreshnessTimings(
        _ frame: SnapshotFrame
    ) throws -> CaptureFreshnessTimings {
        let metadata = frame.metadata
        let fence = metadata.freshnessFence
        guard metadata.capturedAtNanoseconds >= fence.queryStartedAtNanoseconds,
              fence.validatedAtNanoseconds >= metadata.capturedAtNanoseconds
        else {
            throw ElementSnapshotResultBuildError.invalidTiming
        }
        return CaptureFreshnessTimings(
            fenceWaitMilliseconds: (
                metadata.capturedAtNanoseconds - fence.queryStartedAtNanoseconds
            ) / 1_000_000,
            frameAgeMilliseconds: (
                fence.validatedAtNanoseconds - metadata.capturedAtNanoseconds
            ) / 1_000_000
        )
    }

    private static func frameObject(
        pixel: FixedRect,
        logical: FixedRect,
        normalized: FixedRect
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(members: [
            .init(key: "logicalPoints", value: .object(try rectObject(logical))),
            .init(key: "normalized", value: .object(try rectObject(normalized))),
            .init(key: "pixel", value: .object(try rectObject(pixel))),
        ])
    }

    private static func centerObject(
        pixel: FixedRect,
        logical: FixedRect,
        normalized: FixedRect
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(members: [
            .init(key: "logicalPoints", value: .object(try pointObject(logical))),
            .init(key: "normalized", value: .object(try pointObject(normalized))),
            .init(key: "pixel", value: .object(try pointObject(pixel))),
        ])
    }

    private static func rectObject(_ rect: FixedRect) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(members: [
            .init(
                key: "height",
                value: try fixedNumber(units: rect.height, scale: coordinateScale)
            ),
            .init(
                key: "width",
                value: try fixedNumber(units: rect.width, scale: coordinateScale)
            ),
            .init(
                key: "x",
                value: try fixedNumber(units: rect.x, scale: coordinateScale)
            ),
            .init(
                key: "y",
                value: try fixedNumber(units: rect.y, scale: coordinateScale)
            ),
        ])
    }

    private static func pointObject(_ rect: FixedRect) throws -> RepositoryJSONObject {
        let (xSum, xOverflow) = rect.x.addingReportingOverflow(rect.maxX)
        let (ySum, yOverflow) = rect.y.addingReportingOverflow(rect.maxY)
        let (xUnits, xScaleOverflow) = xSum.multipliedReportingOverflow(by: 5)
        let (yUnits, yScaleOverflow) = ySum.multipliedReportingOverflow(by: 5)
        guard !xOverflow, !yOverflow, !xScaleOverflow, !yScaleOverflow else {
            throw ElementSnapshotResultBuildError.invalidDimensions
        }
        return try RepositoryJSONObject(members: [
            .init(
                key: "x",
                value: try fixedNumber(units: xUnits, scale: confidenceScale)
            ),
            .init(
                key: "y",
                value: try fixedNumber(units: yUnits, scale: confidenceScale)
            ),
        ])
    }

    private static func fixedNumber(
        units: Int64,
        scale: Int64
    ) throws -> RepositoryJSONValue {
        guard units >= 0, scale > 0 else {
            throw ElementSnapshotResultBuildError.invalidCandidate
        }
        let whole = units / scale
        let remainder = units % scale
        guard remainder != 0 else {
            return .number(.uint64(UInt64(whole)))
        }
        let fractionDigits = String(scale).count - 1
        var fraction = String(remainder)
        fraction = String(repeating: "0", count: fractionDigits - fraction.count)
            + fraction
        while fraction.last == "0" { fraction.removeLast() }
        let decimal = try RepositoryJSONDecimal("\(whole).\(fraction)")
        return .number(.decimal(decimal))
    }

    private static func pixelRect(_ rect: FixedRect) throws -> SnapshotPixelRect {
        try SnapshotPixelRect(
            x: Double(rect.x) / Double(coordinateScale),
            y: Double(rect.y) / Double(coordinateScale),
            width: Double(rect.width) / Double(coordinateScale),
            height: Double(rect.height) / Double(coordinateScale)
        )
    }

    private static func isNull(_ value: RepositoryJSONValue) -> Bool {
        guard case .null = value else { return false }
        return true
    }

    private static func confidenceSortKey(_ value: RepositoryJSONValue) -> String {
        guard case .number(let number) = value else { return "" }
        switch number {
        case .decimal(let decimal): return decimal.canonicalString
        case .int64(let integer): return String(integer)
        case .uint64(let integer): return String(integer)
        }
    }

    private static func validRequiredString(
        _ value: String,
        maximumBytes: Int
    ) -> Bool {
        !value.isEmpty && value.utf8.count <= maximumBytes
    }

    private static func validOptionalString(
        _ value: String?,
        maximumBytes: Int
    ) -> Bool {
        value.map { $0.utf8.count <= maximumBytes } ?? true
    }

    private static func provider(_ value: SnapshotCaptureProvider) -> String {
        switch value {
        case .liveVideo: "liveFrame"
        case .axAudit, .coreDevice, .dvt, .legacyScreenshotR: value.rawValue
        }
    }

    private static func settleReason(_ value: SnapshotFrameSettleReason) -> String {
        switch value {
        case .queryFenceSatisfied: "freshFrame"
        case .stableAfterVisualChange: "visualChangeStable"
        case .unchangedAtDeadline: "deadlineLatestTrusted"
        }
    }
}
