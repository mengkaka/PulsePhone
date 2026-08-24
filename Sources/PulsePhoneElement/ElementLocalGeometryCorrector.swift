import Foundation
import PulsePhoneMedia

public struct ElementLocalGeometryPolicy: Equatable, Sendable {
    public let componentMinimumHeight: Int
    public let componentMinimumPixels: Int
    public let componentMinimumWidth: Int
    public let containerMinimumAreaRatio: Double
    public let containerMinimumAspectRatio: Double
    public let darkBackgroundMaximum: UInt8
    public let darkThreshold: UInt8
    public let dilationRadius: Int
    public let lightBackgroundMinimum: UInt8
    public let lightThreshold: UInt8
    public let maximumComponents: Int
    public let maximumBorderMedianDeviation: UInt8
    public let maximumContainers: Int
    public let maximumElapsedMilliseconds: UInt64
    public let maximumEdge: UInt64
    public let maximumRasterizedPixels: Int
    public let minimumForegroundContrast: UInt8
    public let minimumComponents: Int
    public let padding: Double
    public let refinementDilationRadius: Int
    public let refinementExpansionFactor: Double
    public let refinementMaximumAreaGrowth: Double
    public let refinementMaximumCandidates: Int
    public let refinementMinimumAreaGrowth: Double
    public let refinementPadding: Double
    public let refinementRequiredSeedContainment: Double
    public let requiredChildContainment: Double

    public init(
        containerMinimumAspectRatio: Double = 2.5,
        containerMinimumAreaRatio: Double = 0.045,
        requiredChildContainment: Double = 0.90,
        maximumEdge: UInt64 = 512,
        darkThreshold: UInt8 = 120,
        lightThreshold: UInt8 = 136,
        darkBackgroundMaximum: UInt8 = 88,
        lightBackgroundMinimum: UInt8 = 168,
        minimumForegroundContrast: UInt8 = 48,
        maximumBorderMedianDeviation: UInt8 = 24,
        dilationRadius: Int = 7,
        componentMinimumPixels: Int = 80,
        componentMinimumWidth: Int = 12,
        componentMinimumHeight: Int = 12,
        minimumComponents: Int = 2,
        maximumComponents: Int = 8,
        maximumContainers: Int = 8,
        maximumElapsedMilliseconds: UInt64 = 1_000,
        maximumRasterizedPixels: Int = 4 * 1_024 * 1_024,
        padding: Double = 6,
        refinementExpansionFactor: Double = 4,
        refinementRequiredSeedContainment: Double = 0.60,
        refinementMinimumAreaGrowth: Double = 1.15,
        refinementMaximumAreaGrowth: Double = 16,
        refinementDilationRadius: Int = 2,
        refinementMaximumCandidates: Int = 64,
        refinementPadding: Double = 3
    ) {
        precondition(containerMinimumAspectRatio > 0)
        precondition((0...1).contains(containerMinimumAreaRatio))
        precondition((0...1).contains(requiredChildContainment))
        precondition(maximumEdge > 0)
        precondition(darkBackgroundMaximum < lightBackgroundMinimum)
        precondition(darkThreshold < lightThreshold)
        precondition(minimumForegroundContrast > 0)
        precondition(dilationRadius >= 0)
        precondition(componentMinimumPixels > 0)
        precondition(componentMinimumWidth > 0)
        precondition(componentMinimumHeight > 0)
        precondition(minimumComponents > 0)
        precondition(maximumComponents >= minimumComponents)
        precondition(maximumContainers > 0)
        precondition(maximumElapsedMilliseconds > 0)
        precondition(maximumRasterizedPixels > 0)
        precondition(padding >= 0)
        precondition(refinementExpansionFactor > 1)
        precondition((0...1).contains(refinementRequiredSeedContainment))
        precondition(refinementMinimumAreaGrowth > 1)
        precondition(refinementMaximumAreaGrowth >= refinementMinimumAreaGrowth)
        precondition(refinementDilationRadius >= 0)
        precondition(refinementMaximumCandidates > 0)
        precondition(refinementPadding >= 0)
        self.componentMinimumHeight = componentMinimumHeight
        self.componentMinimumPixels = componentMinimumPixels
        self.componentMinimumWidth = componentMinimumWidth
        self.containerMinimumAreaRatio = containerMinimumAreaRatio
        self.containerMinimumAspectRatio = containerMinimumAspectRatio
        self.darkBackgroundMaximum = darkBackgroundMaximum
        self.darkThreshold = darkThreshold
        self.dilationRadius = dilationRadius
        self.lightBackgroundMinimum = lightBackgroundMinimum
        self.lightThreshold = lightThreshold
        self.maximumComponents = maximumComponents
        self.maximumBorderMedianDeviation = maximumBorderMedianDeviation
        self.maximumContainers = maximumContainers
        self.maximumElapsedMilliseconds = maximumElapsedMilliseconds
        self.maximumEdge = maximumEdge
        self.maximumRasterizedPixels = maximumRasterizedPixels
        self.minimumForegroundContrast = minimumForegroundContrast
        self.minimumComponents = minimumComponents
        self.padding = padding
        self.refinementDilationRadius = refinementDilationRadius
        self.refinementExpansionFactor = refinementExpansionFactor
        self.refinementMaximumAreaGrowth = refinementMaximumAreaGrowth
        self.refinementMaximumCandidates = refinementMaximumCandidates
        self.refinementMinimumAreaGrowth = refinementMinimumAreaGrowth
        self.refinementPadding = refinementPadding
        self.refinementRequiredSeedContainment =
            refinementRequiredSeedContainment
        self.requiredChildContainment = requiredChildContainment
    }
}

public struct ElementLocalGeometryResult: Equatable, Sendable {
    public let appliedParentCount: Int
    public let candidates: [FusedElementCandidate]
    public let componentCount: Int
    public let elapsedMilliseconds: UInt64
}

public struct ElementLocalGeometryCorrector: Sendable {
    private struct WorkBudget {
        let deadline: ContinuousClock.Instant
        var remainingRasterizedPixels: Int

        var canContinue: Bool {
            !Task.isCancelled && ContinuousClock.now < deadline
        }

        mutating func reserve(pixels: Int) -> Bool {
            guard canContinue,
                  pixels > 0,
                  pixels <= remainingRasterizedPixels
            else { return false }
            remainingRasterizedPixels -= pixels
            return true
        }
    }

    private struct Component {
        let count: Int
        let maxX: Int
        let maxY: Int
        let minX: Int
        let minY: Int
    }

    private let policy: ElementLocalGeometryPolicy
    private let renderer: ElementImageRenderer

    public init(
        policy: ElementLocalGeometryPolicy = .init(),
        renderer: ElementImageRenderer = ElementImageRenderer()
    ) {
        self.policy = policy
        self.renderer = renderer
    }

    public func correct(
        frame: SnapshotFrame,
        candidates: [FusedElementCandidate]
    ) async -> ElementLocalGeometryResult {
        let policy = self.policy
        let renderer = self.renderer
        return await Task.detached(priority: Task.currentPriority) {
            Self.correct(
                source: frame.sourceImage,
                dimensions: frame.metadata.pixelDimensions,
                candidates: candidates,
                policy: policy,
                renderer: renderer
            )
        }.value
    }

    private static func correct(
        source: SnapshotSourceImageLease,
        dimensions: SnapshotImageDimensions,
        candidates: [FusedElementCandidate],
        policy: ElementLocalGeometryPolicy,
        renderer: ElementImageRenderer
    ) -> ElementLocalGeometryResult {
        let started = ContinuousClock.now
        var budget = WorkBudget(
            deadline: started.advanced(by: .milliseconds(
                policy.maximumElapsedMilliseconds
            )),
            remainingRasterizedPixels: policy.maximumRasterizedPixels
        )
        guard let preparedSource = try? renderer.prepareGrayscaleSource(source) else {
            return ElementLocalGeometryResult(
                appliedParentCount: 0,
                candidates: candidates.sorted(by: canonicalOrder),
                componentCount: 0,
                elapsedMilliseconds: ElementAnalyzerTiming.elapsedMilliseconds(
                    since: started
                )
            )
        }
        let viewportArea = Double(dimensions.width) * Double(dimensions.height)
        let parents = candidates.filter { candidate in
            candidate.frame.width >= policy.containerMinimumAspectRatio
                * candidate.frame.height
                && area(candidate.frame) >= viewportArea
                    * policy.containerMinimumAreaRatio
                && candidates.contains { child in
                    child != candidate
                        && intersectionArea(candidate.frame, child.frame)
                            / max(1, area(child.frame))
                            >= policy.requiredChildContainment
                }
        }.prefix(policy.maximumContainers)
        var output = candidates
        var applied = 0
        var componentCount = 0
        for parent in parents {
            guard budget.canContinue,
                  let parentIndex = output.firstIndex(of: parent),
                  let rasterizedPixels = try? renderer.grayscalePixelCount(
                    sourceRect: parent.frame,
                    maximumEdge: policy.maximumEdge
                  ),
                  budget.reserve(pixels: rasterizedPixels),
                  let image = try? renderer.renderGrayscale(
                    source: preparedSource,
                    sourceRect: parent.frame,
                    maximumEdge: policy.maximumEdge
                  )
            else { continue }
            let components = components(
                in: image,
                policy: policy,
                budget: budget
            )
            guard (policy.minimumComponents...policy.maximumComponents)
                .contains(components.count)
            else { continue }
            output.remove(at: parentIndex)
            applied += 1
            componentCount += components.count
            for component in components {
                guard let frame = componentFrame(
                    component,
                    parent: parent.frame,
                    image: image,
                    dimensions: dimensions,
                    padding: policy.padding
                ) else { continue }
                mergeLocal(frame, into: &output)
            }
        }
        refineExistingFrames(
            dimensions: dimensions,
            candidates: &output,
            policy: policy,
            renderer: renderer,
            preparedSource: preparedSource,
            budget: &budget
        )
        output.sort(by: canonicalOrder)
        if output.count > ElementFusionEngine.maximumFinalElements {
            output = candidates
            applied = 0
            componentCount = 0
        }
        return ElementLocalGeometryResult(
            appliedParentCount: applied,
            candidates: output,
            componentCount: componentCount,
            elapsedMilliseconds: ElementAnalyzerTiming.elapsedMilliseconds(
                since: started
            )
        )
    }

    private static func components(
        in image: ElementImageRenderer.GrayscaleImage,
        policy: ElementLocalGeometryPolicy,
        budget: WorkBudget,
        dilationRadius: Int? = nil,
        allowMidtoneContrast: Bool = false
    ) -> [Component] {
        guard budget.canContinue,
              var mask = foregroundMask(
            in: image,
            policy: policy,
            allowMidtoneContrast: allowMidtoneContrast
        ) else {
            return []
        }
        let dilationRadius = dilationRadius ?? policy.dilationRadius
        if dilationRadius > 0 {
            mask = dilate(
                mask,
                width: image.width,
                height: image.height,
                radius: dilationRadius,
                budget: budget
            )
        }
        guard budget.canContinue else { return [] }
        var visited = [Bool](repeating: false, count: mask.count)
        var output = [Component]()
        for startY in 0..<image.height {
            if !budget.canContinue { return [] }
            for startX in 0..<image.width {
                let start = startY * image.width + startX
                guard mask[start], !visited[start] else { continue }
                var queue = [start]
                visited[start] = true
                var cursor = 0
                var count = 0
                var minX = startX
                var maxX = startX
                var minY = startY
                var maxY = startY
                while cursor < queue.count {
                    let index = queue[cursor]
                    cursor += 1
                    count += 1
                    let x = index % image.width
                    let y = index / image.width
                    minX = min(minX, x)
                    maxX = max(maxX, x)
                    minY = min(minY, y)
                    maxY = max(maxY, y)
                    for (nextX, nextY) in [
                        (x - 1, y), (x + 1, y),
                        (x, y - 1), (x, y + 1),
                    ] where nextX >= 0 && nextX < image.width
                        && nextY >= 0 && nextY < image.height {
                        let next = nextY * image.width + nextX
                        if mask[next], !visited[next] {
                            visited[next] = true
                            queue.append(next)
                        }
                    }
                }
                guard count >= policy.componentMinimumPixels,
                      maxX - minX + 1 >= policy.componentMinimumWidth,
                      maxY - minY + 1 >= policy.componentMinimumHeight
                else { continue }
                output.append(Component(
                    count: count,
                    maxX: maxX,
                    maxY: maxY,
                    minX: minX,
                    minY: minY
                ))
            }
        }
        return output
    }

    private static func foregroundMask(
        in image: ElementImageRenderer.GrayscaleImage,
        policy: ElementLocalGeometryPolicy,
        allowMidtoneContrast: Bool
    ) -> [Bool]? {
        let border = borderPixels(in: image)
        guard !border.isEmpty else { return nil }
        let background = median(border)
        let deviation = median(border.map {
            UInt8(abs(Int($0) - Int(background)))
        })
        guard deviation <= policy.maximumBorderMedianDeviation else {
            return nil
        }

        if background >= policy.lightBackgroundMinimum {
            let contrastThreshold = Int(background)
                - Int(policy.minimumForegroundContrast)
            let threshold = UInt8(max(
                0,
                min(Int(policy.darkThreshold), contrastThreshold)
            ))
            return image.pixels.map { $0 < threshold }
        }
        if background <= policy.darkBackgroundMaximum {
            let contrastThreshold = Int(background)
                + Int(policy.minimumForegroundContrast)
            let threshold = UInt8(min(
                255,
                max(Int(policy.lightThreshold), contrastThreshold)
            ))
            return image.pixels.map { $0 > threshold }
        }
        guard allowMidtoneContrast else { return nil }
        return image.pixels.map {
            abs(Int($0) - Int(background)) >= Int(policy.minimumForegroundContrast)
        }
    }

    private static func borderPixels(
        in image: ElementImageRenderer.GrayscaleImage
    ) -> [UInt8] {
        guard image.width > 0, image.height > 0 else { return [] }
        var pixels = [UInt8]()
        pixels.reserveCapacity(2 * (image.width + image.height))
        for x in 0..<image.width {
            pixels.append(image.pixels[x])
            if image.height > 1 {
                pixels.append(image.pixels[(image.height - 1) * image.width + x])
            }
        }
        if image.height > 2 {
            for y in 1..<(image.height - 1) {
                pixels.append(image.pixels[y * image.width])
                if image.width > 1 {
                    pixels.append(image.pixels[y * image.width + image.width - 1])
                }
            }
        }
        return pixels
    }

    private static func median(_ values: [UInt8]) -> UInt8 {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        if sorted.count.isMultiple(of: 2) {
            return UInt8((UInt16(sorted[middle - 1]) + UInt16(sorted[middle])) / 2)
        }
        return sorted[middle]
    }

    private static func dilate(
        _ input: [Bool],
        width: Int,
        height: Int,
        radius: Int,
        budget: WorkBudget
    ) -> [Bool] {
        var horizontal = [Bool](repeating: false, count: input.count)
        for y in 0..<height {
            if !budget.canContinue { return [] }
            var darkCount = (0...min(radius, width - 1)).reduce(0) {
                $0 + (input[y * width + $1] ? 1 : 0)
            }
            for x in 0..<width {
                horizontal[y * width + x] = darkCount > 0
                let removeX = x - radius
                if removeX >= 0, input[y * width + removeX] { darkCount -= 1 }
                let addX = x + radius + 1
                if addX < width, input[y * width + addX] { darkCount += 1 }
            }
        }
        var output = [Bool](repeating: false, count: input.count)
        for x in 0..<width {
            if !budget.canContinue { return [] }
            var darkCount = (0...min(radius, height - 1)).reduce(0) {
                $0 + (horizontal[$1 * width + x] ? 1 : 0)
            }
            for y in 0..<height {
                output[y * width + x] = darkCount > 0
                let removeY = y - radius
                if removeY >= 0, horizontal[removeY * width + x] { darkCount -= 1 }
                let addY = y + radius + 1
                if addY < height, horizontal[addY * width + x] { darkCount += 1 }
            }
        }
        return output
    }

    private static func componentFrame(
        _ component: Component,
        parent: SnapshotPixelRect,
        image: ElementImageRenderer.GrayscaleImage,
        dimensions: SnapshotImageDimensions,
        padding: Double
    ) -> SnapshotPixelRect? {
        let inverseScale = 1 / image.scale
        let x = parent.x + Double(component.minX) * inverseScale
            - padding * inverseScale
        let y = parent.y + Double(component.minY) * inverseScale
            - padding * inverseScale
        let maxX = parent.x + Double(component.maxX + 1) * inverseScale
            + padding * inverseScale
        let maxY = parent.y + Double(component.maxY + 1) * inverseScale
            + padding * inverseScale
        guard let frame = try? SnapshotPixelRect(
            x: x,
            y: y,
            width: maxX - x,
            height: maxY - y
        ), let clipped = frame.intersection(try! SnapshotPixelRect(
            x: 0,
            y: 0,
            width: Double(dimensions.width),
            height: Double(dimensions.height)
        )), clipped.width >= 2, clipped.height >= 2
        else { return nil }
        return clipped
    }

    private static func refineExistingFrames(
        dimensions: SnapshotImageDimensions,
        candidates: inout [FusedElementCandidate],
        policy: ElementLocalGeometryPolicy,
        renderer: ElementImageRenderer,
        preparedSource: ElementImageRenderer.GrayscaleSource,
        budget: inout WorkBudget
    ) {
        let bounds = try! SnapshotPixelRect(
            x: 0,
            y: 0,
            width: Double(dimensions.width),
            height: Double(dimensions.height)
        )
        let candidateCount = min(
            candidates.count,
            policy.refinementMaximumCandidates
        )
        for index in 0..<candidateCount {
            guard budget.canContinue else { return }
            let seed = candidates[index]
            guard !seed.sources.contains(.omniparser),
                  !seed.sources.contains(.localGeometry),
                  seed.frame.width >= 6,
                  seed.frame.height >= 6,
                  let search = expandedSearchRect(
                    seed.frame,
                    factor: policy.refinementExpansionFactor,
                    bounds: bounds
                  ),
                  let rasterizedPixels = try? renderer.grayscalePixelCount(
                    sourceRect: search,
                    maximumEdge: policy.maximumEdge
                  ),
                  budget.reserve(pixels: rasterizedPixels),
                  let image = try? renderer.renderGrayscale(
                    source: preparedSource,
                    sourceRect: search,
                    maximumEdge: policy.maximumEdge
                  )
            else { continue }
            let localComponents = components(
                in: image,
                policy: policy,
                budget: budget,
                dilationRadius: policy.refinementDilationRadius,
                allowMidtoneContrast: true
            )
            guard !localComponents.isEmpty,
                  localComponents.count <= policy.maximumComponents * 4,
                  let refined = bestRefinement(
                    components: localComponents,
                    seed: seed.frame,
                    search: search,
                    image: image,
                    dimensions: dimensions,
                    policy: policy
                  ),
                  !candidates.contains(where: {
                    $0.sources.contains(.omniparser)
                        && $0.type == .controlCandidate
                        && overlapScore($0.frame, refined) >= 0.45
                  })
            else { continue }

            var sources = Set(seed.sources)
            sources.insert(.localGeometry)
            candidates[index] = FusedElementCandidate(
                frame: refined,
                sources: sources.sorted(by: sourceOrder),
                type: seed.type,
                confidence: seed.confidence,
                label: seed.label,
                labelSource: seed.labelSource
            )
        }
    }

    private static func expandedSearchRect(
        _ seed: SnapshotPixelRect,
        factor: Double,
        bounds: SnapshotPixelRect
    ) -> SnapshotPixelRect? {
        let targetWidth = max(seed.width * factor, seed.width + 24)
        let targetHeight = max(seed.height * factor, seed.height + 24)
        guard let expanded = try? SnapshotPixelRect(
            x: seed.x - (targetWidth - seed.width) / 2,
            y: seed.y - (targetHeight - seed.height) / 2,
            width: targetWidth,
            height: targetHeight
        ), let clipped = expanded.intersection(bounds),
              clipped.width >= seed.width + 4,
              clipped.height >= seed.height + 4
        else { return nil }
        return clipped
    }

    private static func bestRefinement(
        components: [Component],
        seed: SnapshotPixelRect,
        search: SnapshotPixelRect,
        image: ElementImageRenderer.GrayscaleImage,
        dimensions: SnapshotImageDimensions,
        policy: ElementLocalGeometryPolicy
    ) -> SnapshotPixelRect? {
        let seedArea = area(seed)
        let seedCenterX = seed.x + seed.width / 2
        let seedCenterY = seed.y + seed.height / 2
        var eligible = [(frame: SnapshotPixelRect, score: Double)]()
        for component in components {
            guard !touchesCropBoundary(component, image: image),
                  let frame = componentFrame(
                    component,
                    parent: search,
                    image: image,
                    dimensions: dimensions,
                    padding: policy.refinementPadding
                  )
            else { continue }
            let overlap = intersectionArea(seed, frame)
            let seedContainment = overlap / max(1, seedArea)
            let growth = area(frame) / max(1, seedArea)
            guard seedContainment >= policy.refinementRequiredSeedContainment,
                  growth >= policy.refinementMinimumAreaGrowth,
                  growth <= policy.refinementMaximumAreaGrowth
            else { continue }
            let centerX = frame.x + frame.width / 2
            let centerY = frame.y + frame.height / 2
            let distance = hypot(centerX - seedCenterX, centerY - seedCenterY)
            let maximumDistance = max(seed.width, seed.height)
                * policy.refinementExpansionFactor / 2
            guard distance <= maximumDistance else { continue }
            eligible.append((
                frame: frame,
                score: seedContainment * 4 - growth * 0.01
            ))
        }
        eligible.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if area($0.frame) != area($1.frame) {
                return area($0.frame) < area($1.frame)
            }
            return canonicalFrameOrder($0.frame, $1.frame)
        }
        guard let best = eligible.first else { return nil }
        if eligible.count > 1,
           abs(best.score - eligible[1].score) < 0.05,
           overlapScore(best.frame, eligible[1].frame) < 0.72
        {
            return nil
        }
        return best.frame
    }

    private static func touchesCropBoundary(
        _ component: Component,
        image: ElementImageRenderer.GrayscaleImage
    ) -> Bool {
        component.minX <= 0 || component.minY <= 0
            || component.maxX >= image.width - 1
            || component.maxY >= image.height - 1
    }

    private static func canonicalFrameOrder(
        _ left: SnapshotPixelRect,
        _ right: SnapshotPixelRect
    ) -> Bool {
        if left.y != right.y { return left.y < right.y }
        if left.x != right.x { return left.x < right.x }
        return area(left) < area(right)
    }

    private static func mergeLocal(
        _ frame: SnapshotPixelRect,
        into output: inout [FusedElementCandidate]
    ) {
        var bestIndex: Int?
        var bestScore = 0.0
        for index in output.indices {
            let score = overlapScore(output[index].frame, frame)
            if score > bestScore {
                bestIndex = index
                bestScore = score
            }
        }
        if let bestIndex, bestScore >= 0.72 {
            let existing = output[bestIndex]
            var sources = Set(existing.sources)
            sources.insert(.localGeometry)
            output[bestIndex] = FusedElementCandidate(
                frame: existing.frame,
                sources: sources.sorted(by: sourceOrder),
                type: existing.type,
                confidence: existing.confidence,
                label: existing.label,
                labelSource: existing.labelSource
            )
        } else {
            output.append(FusedElementCandidate(
                frame: frame,
                sources: [.localGeometry],
                type: .unknown,
                confidence: nil,
                label: nil,
                labelSource: nil
            ))
        }
    }

    private static func overlapScore(
        _ left: SnapshotPixelRect,
        _ right: SnapshotPixelRect
    ) -> Double {
        let overlap = intersectionArea(left, right)
        guard overlap > 0 else { return 0 }
        let union = area(left) + area(right) - overlap
        return max(
            overlap / max(1, union),
            overlap / max(1, min(area(left), area(right)))
        )
    }

    private static func intersectionArea(
        _ left: SnapshotPixelRect,
        _ right: SnapshotPixelRect
    ) -> Double {
        left.intersection(right).map(area) ?? 0
    }

    private static func area(_ frame: SnapshotPixelRect) -> Double {
        frame.width * frame.height
    }

    private static func canonicalOrder(
        _ left: FusedElementCandidate,
        _ right: FusedElementCandidate
    ) -> Bool {
        if left.frame.y != right.frame.y { return left.frame.y < right.frame.y }
        if left.frame.x != right.frame.x { return left.frame.x < right.frame.x }
        return area(left.frame) < area(right.frame)
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
