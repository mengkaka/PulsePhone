import Foundation
import PulsePhoneMedia

public struct ElementFusionPolicy: Equatable, Sendable {
    public let appleControlEvidenceOverlap: Double
    public let mergeThreshold: Double
    public let minimumControlPixels: Double
    public let nestedAreaRatio: Double
    public let omniparserMinimumConfidence: Double
    public let ocrControlIndividualCoverage: Double
    public let ocrControlUnionCoverage: Double

    public init(
        omniparserMinimumConfidence: Double = 0.10,
        minimumControlPixels: Double = 18,
        mergeThreshold: Double = 0.72,
        ocrControlIndividualCoverage: Double = 0.15,
        ocrControlUnionCoverage: Double = 0.60,
        appleControlEvidenceOverlap: Double = 0.45,
        nestedAreaRatio: Double = 0.65
    ) {
        precondition((0...1).contains(omniparserMinimumConfidence))
        precondition(minimumControlPixels >= 2)
        precondition((0...1).contains(mergeThreshold))
        precondition((0...1).contains(ocrControlIndividualCoverage))
        precondition((0...1).contains(ocrControlUnionCoverage))
        precondition((0...1).contains(appleControlEvidenceOverlap))
        precondition((0...1).contains(nestedAreaRatio))
        self.appleControlEvidenceOverlap = appleControlEvidenceOverlap
        self.mergeThreshold = mergeThreshold
        self.minimumControlPixels = minimumControlPixels
        self.nestedAreaRatio = nestedAreaRatio
        self.omniparserMinimumConfidence = omniparserMinimumConfidence
        self.ocrControlIndividualCoverage = ocrControlIndividualCoverage
        self.ocrControlUnionCoverage = ocrControlUnionCoverage
    }
}

public struct FusedElementCandidate: Equatable, Sendable {
    public let confidence: Double?
    public let frame: SnapshotPixelRect
    public let label: String?
    public let labelSource: ElementAnalyzerSource?
    public let sources: [ElementAnalyzerSource]
    public let type: ElementCandidateType

    public init(
        frame: SnapshotPixelRect,
        sources: [ElementAnalyzerSource],
        type: ElementCandidateType,
        confidence: Double?,
        label: String?,
        labelSource: ElementAnalyzerSource?
    ) {
        self.confidence = confidence
        self.frame = frame
        self.label = label
        self.labelSource = labelSource
        self.sources = sources
        self.type = type
    }
}

public enum ElementFusionError: Error, Equatable, Sendable {
    case invalidAnalyzerResult
    case tooManyFinalElements
}

public struct ElementFusionEngine: Sendable {
    private struct Candidate {
        var confidence: Double?
        var frame: SnapshotPixelRect
        var label: String?
        var labelSource: ElementAnalyzerSource?
        var sources: Set<ElementAnalyzerSource>
        var type: ElementCandidateType
    }

    public static let maximumFinalElements = 256
    private let policy: ElementFusionPolicy

    public init(policy: ElementFusionPolicy = .init()) {
        self.policy = policy
    }

    public func fuse(
        _ batch: ElementAnalyzerBatch,
        dimensions: SnapshotImageDimensions
    ) throws -> [FusedElementCandidate] {
        var candidates = [Candidate]()
        var successful = [ElementAnalyzerSource: ElementAnalyzerResult]()
        for result in batch.results where result.status == .succeeded {
            guard successful[result.source] == nil else {
                throw ElementFusionError.invalidAnalyzerResult
            }
            successful[result.source] = result
        }
        if let omni = successful[.omniparser] {
            try validate(omni)
            for value in sorted(omni.candidates) {
                guard value.confidence.map({
                    $0 >= policy.omniparserMinimumConfidence
                }) != false,
                      let frame = clip(value.frame, dimensions: dimensions),
                      frame.width >= policy.minimumControlPixels,
                      frame.height >= policy.minimumControlPixels
                else { continue }
                addOrMerge(Candidate(
                    confidence: value.confidence,
                    frame: frame,
                    label: nil,
                    labelSource: nil,
                    sources: [.omniparser],
                    type: .controlCandidate
                ), into: &candidates)
            }
        }
        if let vision = successful[.vision] {
            try validate(vision)
            for value in sorted(vision.candidates) {
                guard let frame = clip(value.frame, dimensions: dimensions) else {
                    continue
                }
                if consumeOCRGroup(
                    frame: frame,
                    label: value.label,
                    confidence: value.confidence,
                    candidates: &candidates
                ) { continue }
                addOrMerge(Candidate(
                    confidence: value.confidence,
                    frame: frame,
                    label: value.label,
                    labelSource: value.label == nil ? nil : .vision,
                    sources: [.vision],
                    type: .text
                ), into: &candidates)
            }
        }
        if let apple = successful[.appleRegion] {
            try validate(apple)
            for value in sorted(apple.candidates) {
                guard let frame = clip(value.frame, dimensions: dimensions) else {
                    continue
                }
                if consumeAppleEvidence(
                    frame: frame,
                    confidence: value.confidence,
                    candidates: &candidates
                ) { continue }
                addOrMerge(Candidate(
                    confidence: value.confidence,
                    frame: frame,
                    label: nil,
                    labelSource: nil,
                    sources: [.appleRegion],
                    type: .text
                ), into: &candidates)
            }
        }
        guard candidates.count <= Self.maximumFinalElements else {
            throw ElementFusionError.tooManyFinalElements
        }
        return candidates
            .sorted(by: Self.canonicalOrder)
            .map {
                FusedElementCandidate(
                    frame: $0.frame,
                    sources: $0.sources.sorted(by: Self.sourceOrder),
                    type: $0.type,
                    confidence: $0.confidence,
                    label: $0.label,
                    labelSource: $0.labelSource
                )
            }
    }

    private func validate(_ result: ElementAnalyzerResult) throws {
        guard result.candidates.count <= 2_048,
              result.candidates.allSatisfy({ $0.source == result.source })
        else { throw ElementFusionError.invalidAnalyzerResult }
    }

    private func addOrMerge(
        _ incoming: Candidate,
        into candidates: inout [Candidate]
    ) {
        var bestIndex: Int?
        var bestScore = 0.0
        for index in candidates.indices {
            let score = overlapScore(candidates[index].frame, incoming.frame)
            if score > bestScore {
                bestIndex = index
                bestScore = score
            }
        }
        guard let bestIndex, bestScore >= policy.mergeThreshold else {
            candidates.append(incoming)
            return
        }
        let bestArea = area(candidates[bestIndex].frame)
        let incomingArea = area(incoming.frame)
        let sameDetector = candidates[bestIndex].sources.contains(.omniparser)
            && incoming.sources.contains(.omniparser)
        let sizeRatio = min(bestArea, incomingArea) / max(1, max(bestArea, incomingArea))
        if sameDetector && sizeRatio < policy.nestedAreaRatio {
            candidates.append(incoming)
            return
        }
        let bestHadOmni = candidates[bestIndex].sources.contains(.omniparser)
        candidates[bestIndex].sources.formUnion(incoming.sources)
        if let confidence = incoming.confidence {
            candidates[bestIndex].confidence = max(
                candidates[bestIndex].confidence ?? 0,
                confidence
            )
        }
        if candidates[bestIndex].label == nil, let label = incoming.label {
            candidates[bestIndex].label = label
            candidates[bestIndex].labelSource = incoming.labelSource
        }
        if incoming.type == .controlCandidate {
            candidates[bestIndex].type = .controlCandidate
        }
        if incoming.sources.contains(.omniparser), !bestHadOmni {
            candidates[bestIndex].frame = incoming.frame
        }
    }

    private func consumeOCRGroup(
        frame: SnapshotPixelRect,
        label: String?,
        confidence: Double?,
        candidates: inout [Candidate]
    ) -> Bool {
        let textArea = area(frame)
        let overlappingControls = candidates.indices.filter { index in
            let candidate = candidates[index]
            return candidate.type == .controlCandidate
                && candidate.sources.contains(.omniparser)
                && intersectionArea(candidate.frame, frame) / max(1, textArea)
                    >= policy.ocrControlIndividualCoverage
        }
        let controls = peerControlIndices(
            overlappingControls,
            candidates: candidates
        )
        guard controls.count >= 2 else { return false }
        let intersections = controls.compactMap {
            candidates[$0].frame.intersection(frame)
        }
        guard unionArea(intersections) / max(1, textArea)
                >= policy.ocrControlUnionCoverage
        else { return false }

        attachOrderedGroupLabels(
            label,
            confidence: confidence,
            controlIndices: controls,
            candidates: &candidates
        )
        return true
    }

    private func attachOrderedGroupLabels(
        _ label: String?,
        confidence: Double?,
        controlIndices: [Int],
        candidates: inout [Candidate]
    ) {
        guard let label else { return }
        let tokens = label.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count == controlIndices.count else { return }
        let horizontal = centerSpan(controlIndices, candidates: candidates, xAxis: true)
            >= centerSpan(controlIndices, candidates: candidates, xAxis: false)
        let ordered = controlIndices.sorted {
            let left = candidates[$0].frame
            let right = candidates[$1].frame
            let leftPrimary = horizontal
                ? left.x + left.width / 2 : left.y + left.height / 2
            let rightPrimary = horizontal
                ? right.x + right.width / 2 : right.y + right.height / 2
            if leftPrimary != rightPrimary { return leftPrimary < rightPrimary }
            return $0 < $1
        }
        for (index, token) in zip(ordered, tokens) where candidates[index].label == nil {
            candidates[index].label = token
            candidates[index].labelSource = .vision
            candidates[index].sources.insert(.vision)
            if let confidence {
                candidates[index].confidence = max(
                    candidates[index].confidence ?? 0,
                    confidence
                )
            }
        }
    }

    private func consumeAppleEvidence(
        frame: SnapshotPixelRect,
        confidence: Double?,
        candidates: inout [Candidate]
    ) -> Bool {
        let controls = candidates.indices.filter { index in
            candidates[index].type == .controlCandidate
                && overlapScore(candidates[index].frame, frame)
                    >= policy.appleControlEvidenceOverlap
        }
        guard !controls.isEmpty else { return false }
        if controls.count == 2,
           let merged = bridgedNumericControl(
               controls,
               appleFrame: frame,
               confidence: confidence,
               candidates: candidates
           )
        {
            for index in controls.sorted(by: >) { candidates.remove(at: index) }
            candidates.append(merged)
            return true
        }
        for index in controls {
            candidates[index].sources.insert(.appleRegion)
            if let confidence {
                candidates[index].confidence = max(
                    candidates[index].confidence ?? 0,
                    confidence
                )
            }
        }
        return true
    }

    private func bridgedNumericControl(
        _ indices: [Int],
        appleFrame: SnapshotPixelRect,
        confidence: Double?,
        candidates: [Candidate]
    ) -> Candidate? {
        guard indices.count == 2 else { return nil }
        let first = candidates[indices[0]]
        let second = candidates[indices[1]]
        let controlOverlap = intersectionArea(first.frame, second.frame)
            / max(1, min(area(first.frame), area(second.frame)))
        guard controlOverlap <= 0.20 else { return nil }
        let numeric: Candidate
        let companion: Candidate
        if isNumericLabel(first.label), second.label == nil {
            numeric = first
            companion = second
        } else if isNumericLabel(second.label), first.label == nil {
            numeric = second
            companion = first
        } else {
            return nil
        }
        let verticalOverlap = max(
            0,
            min(numeric.frame.maxY, companion.frame.maxY)
                - max(numeric.frame.y, companion.frame.y)
        )
        guard verticalOverlap / max(1, min(numeric.frame.height, companion.frame.height))
                >= 0.50
        else { return nil }
        let horizontalGap = max(
            0,
            max(numeric.frame.x, companion.frame.x)
                - min(numeric.frame.maxX, companion.frame.maxX)
        )
        guard horizontalGap <= max(numeric.frame.height, companion.frame.height) * 0.25,
              let frame = enclosingRect([numeric.frame, companion.frame, appleFrame])
        else { return nil }
        var sources = numeric.sources.union(companion.sources)
        sources.insert(.appleRegion)
        return Candidate(
            confidence: [numeric.confidence, companion.confidence, confidence]
                .compactMap { $0 }.max(),
            frame: frame,
            label: numeric.label,
            labelSource: numeric.labelSource,
            sources: sources,
            type: .controlCandidate
        )
    }

    private func peerControlIndices(
        _ indices: [Int],
        candidates: [Candidate]
    ) -> [Int] {
        let leaves = indices.filter { index in
            let frame = candidates[index].frame
            return !indices.contains { otherIndex in
                guard otherIndex != index else { return false }
                let other = candidates[otherIndex].frame
                return area(frame) > area(other)
                    && intersectionArea(frame, other) / max(1, area(other)) >= 0.80
            }
        }
        guard leaves.indices.allSatisfy({ leftOffset in
            leaves.indices.dropFirst(leftOffset + 1).allSatisfy { rightOffset in
                let left = candidates[leaves[leftOffset]].frame
                let right = candidates[leaves[rightOffset]].frame
                return intersectionArea(left, right)
                    / max(1, min(area(left), area(right))) <= 0.20
            }
        }) else { return [] }
        return leaves
    }

    private func isNumericLabel(_ label: String?) -> Bool {
        guard let label, !label.isEmpty else { return false }
        return label.unicodeScalars.allSatisfy(CharacterSet.decimalDigits.contains)
    }

    private func enclosingRect(_ frames: [SnapshotPixelRect]) -> SnapshotPixelRect? {
        guard let first = frames.first else { return nil }
        let minX = frames.dropFirst().reduce(first.x) { min($0, $1.x) }
        let minY = frames.dropFirst().reduce(first.y) { min($0, $1.y) }
        let maxX = frames.dropFirst().reduce(first.maxX) { max($0, $1.maxX) }
        let maxY = frames.dropFirst().reduce(first.maxY) { max($0, $1.maxY) }
        return try? SnapshotPixelRect(
            x: minX,
            y: minY,
            width: maxX - minX,
            height: maxY - minY
        )
    }

    private func centerSpan(
        _ indices: [Int],
        candidates: [Candidate],
        xAxis: Bool
    ) -> Double {
        let values = indices.map {
            let frame = candidates[$0].frame
            return xAxis ? frame.x + frame.width / 2 : frame.y + frame.height / 2
        }
        guard let minimum = values.min(), let maximum = values.max() else { return 0 }
        return maximum - minimum
    }

    private func unionArea(_ frames: [SnapshotPixelRect]) -> Double {
        let xValues = Array(Set(frames.flatMap { [$0.x, $0.maxX] })).sorted()
        guard xValues.count >= 2 else { return 0 }
        var total = 0.0
        for pair in zip(xValues, xValues.dropFirst()) {
            let (left, right) = pair
            guard right > left else { continue }
            let intervals = frames.compactMap { frame -> (Double, Double)? in
                guard frame.x < right, frame.maxX > left else { return nil }
                return (frame.y, frame.maxY)
            }.sorted { $0.0 < $1.0 }
            guard var current = intervals.first else { continue }
            var height = 0.0
            for interval in intervals.dropFirst() {
                if interval.0 <= current.1 {
                    current.1 = max(current.1, interval.1)
                } else {
                    height += current.1 - current.0
                    current = interval
                }
            }
            height += current.1 - current.0
            total += (right - left) * height
        }
        return total
    }

    private func clip(
        _ frame: SnapshotPixelRect,
        dimensions: SnapshotImageDimensions
    ) -> SnapshotPixelRect? {
        let bounds = try! SnapshotPixelRect(
            x: 0,
            y: 0,
            width: Double(dimensions.width),
            height: Double(dimensions.height)
        )
        guard let clipped = frame.intersection(bounds),
              clipped.width >= 2,
              clipped.height >= 2
        else { return nil }
        return clipped
    }

    private func overlapScore(
        _ left: SnapshotPixelRect,
        _ right: SnapshotPixelRect
    ) -> Double {
        let overlap = intersectionArea(left, right)
        guard overlap > 0 else { return 0 }
        let union = area(left) + area(right) - overlap
        let containment = overlap / max(1, min(area(left), area(right)))
        return max(overlap / max(1, union), containment)
    }

    private func intersectionArea(
        _ left: SnapshotPixelRect,
        _ right: SnapshotPixelRect
    ) -> Double {
        left.intersection(right).map(area) ?? 0
    }

    private func area(_ frame: SnapshotPixelRect) -> Double {
        frame.width * frame.height
    }

    private func sorted(
        _ values: [ElementAnalyzerCandidate]
    ) -> [ElementAnalyzerCandidate] {
        values.sorted {
            if $0.frame.y != $1.frame.y { return $0.frame.y < $1.frame.y }
            if $0.frame.x != $1.frame.x { return $0.frame.x < $1.frame.x }
            return area($0.frame) < area($1.frame)
        }
    }

    private static func canonicalOrder(_ left: Candidate, _ right: Candidate) -> Bool {
        if left.frame.y != right.frame.y { return left.frame.y < right.frame.y }
        if left.frame.x != right.frame.x { return left.frame.x < right.frame.x }
        let leftArea = left.frame.width * left.frame.height
        let rightArea = right.frame.width * right.frame.height
        if leftArea != rightArea { return leftArea < rightArea }
        return left.sources.sorted(by: sourceOrder).map(\.rawValue)
            .lexicographicallyPrecedes(
                right.sources.sorted(by: sourceOrder).map(\.rawValue)
            )
    }

    private static func sourceOrder(
        _ left: ElementAnalyzerSource,
        _ right: ElementAnalyzerSource
    ) -> Bool {
        rank(left) < rank(right)
    }

    private static func rank(_ source: ElementAnalyzerSource) -> Int {
        switch source {
        case .omniparser: 0
        case .vision: 1
        case .appleRegion: 2
        case .localGeometry: 3
        }
    }
}
