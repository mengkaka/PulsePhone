import Darwin
import Foundation
import PulsePhoneBackendAdapters
import PulsePhoneClientCore
import PulsePhoneHostPaths
import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions
import PulsePhoneWire

public final class ProductionAcceptedPointerDeliveryTelemetryObserver:
    PointerAcceptedDeliveryObserver,
    @unchecked Sendable
{
    private let buffer: RuntimePointerDeliveryTelemetryBuffer

    public init(buffer: RuntimePointerDeliveryTelemetryBuffer) {
        self.buffer = buffer
    }

    public func recordAcceptedDelivery(
        _ observation: PointerAcceptedDeliveryObservation
    ) {
        guard let kind = RuntimePointerFrameKind(
            rawValue: observation.frameKind.rawValue
        ) else { return }
        buffer.record(RuntimeAcceptedPointerDeliveryTelemetry(
            sessionID: observation.sessionID,
            interactionID: observation.interactionID,
            sequence: observation.sequence,
            frameKind: kind,
            connectionEpoch: observation.expectedConnectionEpoch,
            geometryRevision: observation.expectedGeometryRevision,
            clientSubmittedMonotonicNanoseconds:
                observation.clientSubmittedMonotonicNanoseconds,
            acceptedMonotonicNanoseconds:
                observation.acceptedMonotonicNanoseconds
        ))
    }
}

public enum ProductionPerformanceTelemetryHub {
    public static let pointerBuffer = try! RuntimePointerDeliveryTelemetryBuffer()
    public static let acceptedPointerObserver =
        ProductionAcceptedPointerDeliveryTelemetryObserver(buffer: pointerBuffer)
}

struct ProductionPointerTelemetrySummary: Sendable {
    let byFrameKind: [String: UInt64]
    let count: UInt64
    let dropped: UInt64
    let maximumMicroseconds: UInt64
    let p50Microseconds: UInt64
    let p95Microseconds: UInt64
    let p99Microseconds: UInt64
    let unconfirmed: UInt64

    var dictionary: [String: Any] {
        [
            "byFrameKind": byFrameKind,
            "coalesced": 0,
            "count": count,
            "max": maximumMicroseconds,
            "p50": p50Microseconds,
            "p95": p95Microseconds,
            "p99": p99Microseconds,
            "rejected": 0,
            "unconfirmed": unconfirmed,
        ]
    }
}

struct ProductionProcessTelemetrySummary: Sendable {
    let cpuMilliPercent: [UInt64]
    let rssKibibytes: [UInt64]
    let wholeRunCPUMaximumMilliPercent: UInt64
    let wholeRunRSSMaximumKibibytes: UInt64
    let rssGrowthKibibytesPerHour: Int64
    let runtimeEpochs: [UInt64]
    let gapCount: UInt64

    var hasCompleteSteadySamples: Bool {
        gapCount == 0 && !cpuMilliPercent.isEmpty && !rssKibibytes.isEmpty
    }
}

struct ProductionReconnectAttempt: Sendable {
    enum Outcome: Sendable {
        case notRecovered(reason: String)
        case recovered(milliseconds: UInt64)
    }

    let attemptID: String
    let control: Outcome
    let video: Outcome

    var dictionary: [String: Any] {
        [
            "attemptID": attemptID,
            "control": Self.dictionary(control),
            "video": Self.dictionary(video),
        ]
    }

    private static func dictionary(_ outcome: Outcome) -> [String: Any] {
        switch outcome {
        case .notRecovered(let reason):
            return ["outcome": "notRecovered", "reason": reason]
        case .recovered(let milliseconds):
            return ["ms": milliseconds, "outcome": "recovered"]
        }
    }
}

struct ProductionPerformanceTelemetrySnapshot: Sendable {
    let connectionEpochs: [UInt64]
    let pointer: ProductionPointerTelemetrySummary
    let process: ProductionProcessTelemetrySummary
    let reconnects: [ProductionReconnectAttempt]
    let runtimeCleanupComplete: Bool
}

struct ProductionControlReadinessTracker: Sendable {
    private(set) var connectionEpochs = [UInt64]()
    private var currentConnectionEpoch = UInt64(0)
    private var lastConnected: Bool?

    mutating func observe(
        connected: Bool?,
        runtimeReady: Bool
    ) -> (connectionEpoch: UInt64?, controlReady: Bool) {
        guard let connected else {
            return (nil, false)
        }
        guard connected else {
            lastConnected = false
            return (nil, false)
        }
        if lastConnected != true {
            guard currentConnectionEpoch < UInt64.max else {
                return (nil, false)
            }
            currentConnectionEpoch += 1
            connectionEpochs.append(currentConnectionEpoch)
        }
        lastConnected = true
        return (currentConnectionEpoch, runtimeReady)
    }
}

final class ProductionPerformanceTelemetrySession: @unchecked Sendable {
    typealias ProcessSnapshotProvider = @Sendable () throws
        -> ProductionProcessSetSnapshot
    typealias DevicePresenceProvider = @Sendable () throws -> Bool
    typealias RuntimeCleanup = @Sendable () -> Bool

    private var controlTracker = ProductionControlReadinessTracker()
    private let devicePresenceProvider: DevicePresenceProvider?
    private let pointerBuffer: RuntimePointerDeliveryTelemetryBuffer
    private let processSampler: ProductionProcessSetSampler
    private let processSnapshotProvider: ProcessSnapshotProvider?
    private let runtimeCleanup: RuntimeCleanup?
    private var pointerDroppedObservationCount = UInt64(0)
    private var pointerObservations = [RuntimeAcceptedPointerDeliveryTelemetry]()
    private var reconnectTracker: ProductionReconnectTracker

    init(
        requiredReconnectCount: Int,
        pointerBuffer: RuntimePointerDeliveryTelemetryBuffer,
        processSnapshotProvider: ProcessSnapshotProvider?,
        devicePresenceProvider: DevicePresenceProvider?,
        runtimeCleanup: RuntimeCleanup? = nil
    ) {
        self.pointerBuffer = pointerBuffer
        self.processSnapshotProvider = processSnapshotProvider
        self.devicePresenceProvider = devicePresenceProvider
        self.runtimeCleanup = runtimeCleanup
        self.processSampler = ProductionProcessSetSampler()
        self.reconnectTracker = ProductionReconnectTracker(
            requiredAttemptCount: requiredReconnectCount
        )
    }

    static func bundled(
        target: CanonicalUDID,
        requiredReconnectCount: Int
    ) -> ProductionPerformanceTelemetrySession {
        guard Bundle.main.bundleURL.pathExtension == "app",
              let resources = Bundle.main.resourceURL,
              let provider = try? ProductionRuntimeProcessSetProvider(target: target)
        else {
            return ProductionPerformanceTelemetrySession(
                requiredReconnectCount: requiredReconnectCount,
                pointerBuffer: ProductionPerformanceTelemetryHub.pointerBuffer,
                processSnapshotProvider: nil,
                devicePresenceProvider: nil,
                runtimeCleanup: nil
            )
        }
        let helper = BundledHelperExecutableSet(
            resourcesURL: resources
        ).directExecutableURL
        let discovery = USBDeviceDiscovery(
            factsProvider: LocalDeviceFactsProbe(executablePath: helper.path)
        )
        return ProductionPerformanceTelemetrySession(
            requiredReconnectCount: requiredReconnectCount,
            pointerBuffer: ProductionPerformanceTelemetryHub.pointerBuffer,
            processSnapshotProvider: { try provider.snapshot() },
            devicePresenceProvider: {
                try discovery.discover().device(for: target) != nil
            },
            runtimeCleanup: { provider.shutdownOwnedRuntime() }
        )
    }

    func begin(
        atMonotonicNanoseconds now: UInt64,
        video: ProductionVideoSnapshot?
    ) {
        let stale = pointerBuffer.drain()
        precondition(stale.observations.count <= RuntimePointerDeliveryTelemetryBuffer
            .hardMaximumObservations)
        pointerDroppedObservationCount = 0
        pointerObservations.removeAll(keepingCapacity: true)
        observe(atMonotonicNanoseconds: now, video: video)
    }

    func observe(
        atMonotonicNanoseconds now: UInt64,
        video: ProductionVideoSnapshot?
    ) {
        consumePointerBatch()
        let rawProcessSnapshot: ProductionProcessSetSnapshot?
        if let processSnapshotProvider {
            do {
                rawProcessSnapshot = try processSnapshotProvider()
            } catch {
                rawProcessSnapshot = nil
            }
        } else {
            rawProcessSnapshot = nil
        }

        let connected: Bool?
        if let devicePresenceProvider {
            connected = try? devicePresenceProvider()
        } else {
            connected = nil
        }
        let control = controlTracker.observe(
            connected: connected,
            runtimeReady: rawProcessSnapshot?.controlReady ?? false
        )
        let processSnapshot = rawProcessSnapshot.map {
            ProductionProcessSetSnapshot(
                connectionEpoch: control.connectionEpoch,
                controlReady: control.controlReady,
                processes: $0.processes,
                runtimeEpoch: $0.runtimeEpoch
            )
        }
        if let processSnapshot {
            processSampler.record(
                processSnapshot,
                atMonotonicNanoseconds: now
            )
        } else {
            processSampler.recordGap()
        }
        reconnectTracker.observe(
            atMonotonicNanoseconds: now,
            connected: connected,
            controlReady: control.controlReady,
            connectionEpoch: control.connectionEpoch,
            sourceEpoch: video?.sourceEpoch,
            latestVideoEnqueueMonotonicNanoseconds:
                video?.enqueueMonotonicNanoseconds.last
        )
    }

    func finish() -> ProductionPerformanceTelemetrySnapshot {
        consumePointerBatch()
        return ProductionPerformanceTelemetrySnapshot(
            connectionEpochs: controlTracker.connectionEpochs,
            pointer: Self.summarize(
                observations: pointerObservations,
                droppedObservationCount: pointerDroppedObservationCount
            ),
            process: processSampler.summary(),
            reconnects: reconnectTracker.finish(),
            runtimeCleanupComplete: runtimeCleanup?() ?? true
        )
    }

    private static func summarize(
        observations: [RuntimeAcceptedPointerDeliveryTelemetry],
        droppedObservationCount: UInt64
    ) -> ProductionPointerTelemetrySummary {
        var byFrameKind = [
            "begin": UInt64(0),
            "cancel": UInt64(0),
            "end": UInt64(0),
            "move": UInt64(0),
        ]
        var samples = [UInt64]()
        var unconfirmed = UInt64(0)
        for observation in observations {
            guard observation.connectionEpoch > 0,
                  observation.geometryRevision > 0,
                  let submitted = observation.clientSubmittedMonotonicNanoseconds,
                  let accepted = observation.acceptedMonotonicNanoseconds,
                  accepted >= submitted
            else {
                unconfirmed = Self.saturatingIncrement(unconfirmed)
                continue
            }
            byFrameKind[observation.frameKind.rawValue, default: 0] += 1
            samples.append((accepted - submitted) / 1_000)
        }
        samples.sort()
        return ProductionPointerTelemetrySummary(
            byFrameKind: byFrameKind,
            count: UInt64(samples.count),
            dropped: droppedObservationCount,
            maximumMicroseconds: samples.last ?? 0,
            p50Microseconds: percentile(samples, percent: 50),
            p95Microseconds: percentile(samples, percent: 95),
            p99Microseconds: percentile(samples, percent: 99),
            unconfirmed: unconfirmed
        )
    }

    private static func percentile(
        _ sorted: [UInt64],
        percent: Int
    ) -> UInt64 {
        guard !sorted.isEmpty else { return 0 }
        let rank = (sorted.count * percent + 99) / 100
        return sorted[max(0, rank - 1)]
    }

    private static func saturatingIncrement(_ value: UInt64) -> UInt64 {
        value == UInt64.max ? value : value + 1
    }

    private func consumePointerBatch() {
        let batch = pointerBuffer.drain()
        let dropped = pointerDroppedObservationCount.addingReportingOverflow(
            batch.droppedObservationCount
        )
        pointerDroppedObservationCount = dropped.overflow
            ? UInt64.max
            : dropped.partialValue
        pointerObservations.append(contentsOf: batch.observations)
    }
}

struct ProductionProcessIdentity: Hashable, Sendable {
    let executablePath: String
    let pid: pid_t
    let startMicroseconds: UInt64
    let startSeconds: UInt64
}

struct ProductionProcessResource: Sendable {
    let identity: ProductionProcessIdentity
    let residentBytes: UInt64
    let totalCPUNanoseconds: UInt64
}

struct ProductionProcessSetSnapshot: Sendable {
    let connectionEpoch: UInt64?
    let controlReady: Bool
    let processes: [ProductionProcessResource]
    let runtimeEpoch: UInt64
}

final class ProductionProcessSetSampler: @unchecked Sendable {
    private static let warmupNanoseconds: UInt64 = 10_000_000_000

    private var allRSSKibibytes = [UInt64]()
    private var allCPUMilliPercent = [UInt64]()
    private var cpuMilliPercent = [UInt64]()
    private var gapCount = UInt64(0)
    private var lastConnectionEpoch: UInt64?
    private var lastObservedAt: UInt64?
    private var lastProcessCPU = [ProductionProcessIdentity: UInt64]()
    private var rssKibibytes = [UInt64]()
    private var runtimeEpochs = Set<UInt64>()
    private var warmupStartedAt: UInt64?

    func record(
        _ snapshot: ProductionProcessSetSnapshot,
        atMonotonicNanoseconds now: UInt64
    ) {
        guard !snapshot.processes.isEmpty,
              Set(snapshot.processes.map(\.identity)).count
                == snapshot.processes.count
        else {
            recordGap()
            return
        }
        runtimeEpochs.insert(snapshot.runtimeEpoch)
        if warmupStartedAt == nil || lastConnectionEpoch != snapshot.connectionEpoch {
            warmupStartedAt = now
            lastObservedAt = nil
            lastProcessCPU.removeAll(keepingCapacity: true)
            lastConnectionEpoch = snapshot.connectionEpoch
        }
        let rssBytes = snapshot.processes.reduce(UInt64(0)) { partial, process in
            partial.addingReportingOverflow(process.residentBytes).overflow
                ? UInt64.max
                : partial + process.residentBytes
        }
        let rssKiB = rssBytes / 1_024
        allRSSKibibytes.append(rssKiB)

        let currentCPU = Dictionary(
            uniqueKeysWithValues: snapshot.processes.map {
                ($0.identity, $0.totalCPUNanoseconds)
            }
        )
        defer {
            lastObservedAt = now
            lastProcessCPU = currentCPU
        }
        guard let previousAt = lastObservedAt,
              now > previousAt,
              Set(currentCPU.keys) == Set(lastProcessCPU.keys)
        else { return }
        var deltaCPU = UInt64(0)
        for (identity, current) in currentCPU {
            guard let previous = lastProcessCPU[identity], current >= previous else {
                recordGap()
                return
            }
            let delta = current - previous
            let sum = deltaCPU.addingReportingOverflow(delta)
            guard !sum.overflow else {
                recordGap()
                return
            }
            deltaCPU = sum.partialValue
        }
        let elapsed = now - previousAt
        let scaled = Self.scaledCPU(delta: deltaCPU, elapsed: elapsed)
        allCPUMilliPercent.append(scaled)
        guard let warmupStartedAt,
              now >= warmupStartedAt,
              now - warmupStartedAt >= Self.warmupNanoseconds
        else { return }
        cpuMilliPercent.append(scaled)
        rssKibibytes.append(rssKiB)
    }

    func recordGap() {
        if gapCount < UInt64.max { gapCount += 1 }
        lastObservedAt = nil
        lastProcessCPU.removeAll(keepingCapacity: true)
    }

    func summary() -> ProductionProcessTelemetrySummary {
        let sortedCPU = cpuMilliPercent.sorted()
        let sortedRSS = rssKibibytes.sorted()
        return ProductionProcessTelemetrySummary(
            cpuMilliPercent: sortedCPU,
            rssKibibytes: sortedRSS,
            wholeRunCPUMaximumMilliPercent: allCPUMilliPercent.max() ?? 0,
            wholeRunRSSMaximumKibibytes: allRSSKibibytes.max() ?? 0,
            rssGrowthKibibytesPerHour: Self.growth(
                samples: rssKibibytes
            ),
            runtimeEpochs: runtimeEpochs.sorted(),
            gapCount: gapCount
        )
    }

    private static func scaledCPU(delta: UInt64, elapsed: UInt64) -> UInt64 {
        guard elapsed > 0 else { return 0 }
        let whole = delta / elapsed
        let remainder = delta % elapsed
        let wholeScaled = whole.multipliedReportingOverflow(by: 100_000)
        let remainderScaled = remainder.multipliedReportingOverflow(by: 100_000)
        guard !wholeScaled.overflow, !remainderScaled.overflow else {
            return UInt64.max
        }
        let fraction = remainderScaled.partialValue / elapsed
        let total = wholeScaled.partialValue.addingReportingOverflow(fraction)
        return total.overflow ? UInt64.max : total.partialValue
    }

    private static func growth(samples: [UInt64]) -> Int64 {
        guard samples.count >= 600 else { return 0 }
        let first = median(Array(samples.prefix(300)))
        let last = median(Array(samples.suffix(300)))
        let hours = Double(samples.count) / 3_600.0
        guard hours > 0 else { return 0 }
        let difference = Double(last) - Double(first)
        let value = difference / hours
        if value >= Double(Int64.max) { return Int64.max }
        if value <= Double(Int64.min) { return Int64.min }
        return Int64(value.rounded())
    }

    private static func median(_ values: [UInt64]) -> UInt64 {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        if sorted.count.isMultiple(of: 2) {
            let lower = sorted[sorted.count / 2 - 1]
            let upper = sorted[sorted.count / 2]
            return lower + (upper - lower) / 2
        }
        return sorted[sorted.count / 2]
    }
}

struct ProductionReconnectTracker: Sendable {
    private struct Pending: Sendable {
        let attachMonotonicNanoseconds: UInt64
        let attemptID: String
        let priorConnectionEpoch: UInt64?
        let priorSourceEpoch: UInt64?
        var control: ProductionReconnectAttempt.Outcome?
        var video: ProductionReconnectAttempt.Outcome?
    }

    private let requiredAttemptCount: Int
    private var completed = [ProductionReconnectAttempt]()
    private var lastConnected: Bool?
    private var lastConnectionEpoch: UInt64?
    private var lastSourceEpoch: UInt64?
    private var pending: Pending?
    private var sawDetach = false

    init(requiredAttemptCount: Int) {
        self.requiredAttemptCount = requiredAttemptCount
    }

    mutating func observe(
        atMonotonicNanoseconds now: UInt64,
        connected: Bool?,
        controlReady: Bool,
        connectionEpoch: UInt64?,
        sourceEpoch: UInt64?,
        latestVideoEnqueueMonotonicNanoseconds: UInt64?
    ) {
        defer {
            if let connectionEpoch { lastConnectionEpoch = connectionEpoch }
            if let sourceEpoch { lastSourceEpoch = sourceEpoch }
            if let connected { lastConnected = connected }
        }
        guard requiredAttemptCount > 0, let connected else { return }
        if lastConnected == true, !connected {
            sawDetach = true
            return
        }
        if lastConnected == false, connected, sawDetach {
            if let pending { completed.append(finalize(pending)) }
            self.pending = Pending(
                attachMonotonicNanoseconds: now,
                attemptID: String(
                    format: "physical-reconnect-%04d",
                    completed.count + 1
                ),
                priorConnectionEpoch: lastConnectionEpoch,
                priorSourceEpoch: lastSourceEpoch,
                control: nil,
                video: nil
            )
            sawDetach = false
        }
        guard var pending else { return }
        if pending.control == nil,
           controlReady,
           let connectionEpoch,
           connectionEpoch > (pending.priorConnectionEpoch ?? 0)
        {
            pending.control = .recovered(milliseconds: Self.elapsed(
                from: pending.attachMonotonicNanoseconds,
                to: now
            ))
        }
        if pending.video == nil,
           let sourceEpoch,
           sourceEpoch > (pending.priorSourceEpoch ?? 0),
           let enqueue = latestVideoEnqueueMonotonicNanoseconds,
           enqueue >= pending.attachMonotonicNanoseconds
        {
            pending.video = .recovered(milliseconds: Self.elapsed(
                from: pending.attachMonotonicNanoseconds,
                to: enqueue
            ))
        }
        self.pending = pending
    }

    mutating func finish() -> [ProductionReconnectAttempt] {
        if let pending {
            completed.append(finalize(pending))
            self.pending = nil
        }
        while completed.count < requiredAttemptCount {
            completed.append(ProductionReconnectAttempt(
                attemptID: String(
                    format: "required-reconnect-%04d",
                    completed.count + 1
                ),
                control: .notRecovered(reason: "physicalReconnectNotObserved"),
                video: .notRecovered(reason: "physicalReconnectNotObserved")
            ))
        }
        return Array(completed.prefix(requiredAttemptCount))
    }

    private func finalize(_ pending: Pending) -> ProductionReconnectAttempt {
        ProductionReconnectAttempt(
            attemptID: pending.attemptID,
            control: pending.control
                ?? .notRecovered(reason: "controlReadinessNotObserved"),
            video: pending.video
                ?? .notRecovered(reason: "newEpochVideoFrameNotObserved")
        )
    }

    private static func elapsed(from start: UInt64, to end: UInt64) -> UInt64 {
        end >= start ? (end - start) / 1_000_000 : 0
    }
}

private final class ProductionRuntimeProcessSetProvider: @unchecked Sendable {
    private let appPath: CanonicalAppPath
    private let client: RuntimeClient
    private let hostPaths: HostPathLayoutV1
    private var lastRuntimeEpoch: UInt64?
    private var ownedRuntime: LaunchedRuntimeGeneration?
    private var runtimeBootstrapAttempted = false
    private let target: CanonicalUDID

    init(target: CanonicalUDID) throws {
        appPath = try CanonicalAppPath.resolveCurrentExecutable()
        client = try RuntimeClient.bundled(role: .gui)
        hostPaths = try POSIXHostPathSystem().makeHostPathLayout()
        self.target = target
    }

    func snapshot() throws -> ProductionProcessSetSnapshot {
        try rejectParallelGUIHost()
        try ensureRuntime()
        let health = try client.health(
            canonicalUDID: target,
            activation: .existingOnly
        )
        let healthValue = try successfulValue(health.result)
        let runtimePID = try pid(healthValue, key: "pid")
        let runtimeEpoch = try uint(healthValue, key: "runtimeEpoch")
        guard healthValue["canonicalUDID"]?.stringValue == target.rawValue,
              healthValue["runtimeState"]?.stringValue == "ready"
        else { throw ProviderError.invalid }
        if let ownedRuntime {
            guard runtimePID == ownedRuntime.pid else {
                throw ProviderError.invalid
            }
            _ = try processIdentity(
                pid: runtimePID,
                expectedPath: ownedRuntime.executablePath,
                expectedStart: StartIdentity(
                    seconds: ownedRuntime.processStartIdentity.seconds,
                    microseconds: ownedRuntime.processStartIdentity.microseconds
                )
            )
        }
        let manifest = try loadManifest(
            expectedRuntimePID: runtimePID,
            expectedRuntimeEpoch: runtimeEpoch
        )
        var identities = [try processIdentity(
            pid: getpid(),
            expectedPath: appPath.bundlePath + "/Contents/MacOS/PulsePhone"
        )]
        identities.append(try processIdentity(
            pid: runtimePID,
            expectedPath: appPath.bundlePath + "/Contents/Helpers/PulsePhoneRuntime",
            expectedStart: manifest.runtimeProcessStartIdentity
        ))
        for helper in manifest.helpers {
            guard helper.processGroupID == helper.pid,
                  isDescendant(helper.pid, of: runtimePID)
            else { throw ProviderError.invalid }
            identities.append(try processIdentity(
                pid: helper.pid,
                expectedPath: helper.executablePath,
                expectedStart: helper.processStartIdentity
            ))
        }
        guard Set(identities.map(\.pid)).count == identities.count else {
            throw ProviderError.invalid
        }
        lastRuntimeEpoch = runtimeEpoch
        return ProductionProcessSetSnapshot(
            connectionEpoch: nil,
            controlReady: true,
            processes: try identities.map(resource),
            runtimeEpoch: runtimeEpoch
        )
    }

    func shutdownOwnedRuntime() -> Bool {
        guard runtimeBootstrapAttempted, let ownedRuntime else { return true }
        do {
            _ = try processIdentity(
                pid: ownedRuntime.pid,
                expectedPath: ownedRuntime.executablePath,
                expectedStart: StartIdentity(
                    seconds: ownedRuntime.processStartIdentity.seconds,
                    microseconds: ownedRuntime.processStartIdentity.microseconds
                )
            )
            let health = try client.health(
                canonicalUDID: target,
                activation: .existingOnly
            )
            let healthValue = try successfulValue(health.result)
            let runtimePID = try pid(healthValue, key: "pid")
            let runtimeEpoch = try uint(healthValue, key: "runtimeEpoch")
            guard runtimePID == ownedRuntime.pid,
                  lastRuntimeEpoch == nil || lastRuntimeEpoch == runtimeEpoch
            else { return false }
            let stop = try client.request(
                operation: .runtimeStopIfIdle,
                canonicalUDID: target,
                body: try object([
                    ("canonicalUDID", .string(target.rawValue)),
                ]),
                activation: .existingOnly
            )
            let stopValue = try successfulValue(stop.result)
            guard stopValue["disposition"]?.stringValue == "stopping",
                  try uint(stopValue, key: "runtimeEpoch") == runtimeEpoch
            else { return false }
            return waitForOwnedRuntimeCleanup(pid: ownedRuntime.pid)
        } catch {
            return !processExists(ownedRuntime.pid) && ownedRuntimeNodesAreAbsent()
        }
    }

    private func ensureRuntime() throws {
        guard !runtimeBootstrapAttempted else { return }
        runtimeBootstrapAttempted = true
        switch try RuntimeBootstrapCoordinator().ensureRunning(
            for: target,
            from: appPath
        ) {
        case .existing:
            ownedRuntime = nil
        case .launched(let generation):
            ownedRuntime = generation
        }
    }

    private func waitForOwnedRuntimeCleanup(pid: pid_t) -> Bool {
        let deadline = SystemMonotonicClock().now().nanoseconds + 3_000_000_000
        while SystemMonotonicClock().now().nanoseconds < deadline {
            var status: Int32 = 0
            let waited = waitpid(pid, &status, WNOHANG)
            if waited == pid || !processExists(pid) {
                if ownedRuntimeNodesAreAbsent() { return true }
            } else if waited < 0, errno != EINTR, errno != ECHILD {
                return false
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        return !processExists(pid) && ownedRuntimeNodesAreAbsent()
    }

    private func processExists(_ pid: pid_t) -> Bool {
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno != ESRCH
    }

    private func ownedRuntimeNodesAreAbsent() -> Bool {
        guard let socket = try? RuntimeSocketPath.current(for: target).path else {
            return false
        }
        return !FileManager.default.fileExists(atPath: socket)
            && !FileManager.default.fileExists(
                atPath: hostPaths.helperStatePath(for: target)
            )
    }

    private func rejectParallelGUIHost() throws {
        let path = try hostPaths.guiHostSocketPath(for: appPath)
        if try ProductionGUIHostSocketActivityProbe.isActive(path: path) {
            throw ProviderError.invalid
        }
    }

    private func loadManifest(
        expectedRuntimePID: pid_t,
        expectedRuntimeEpoch: UInt64
    ) throws -> Manifest {
        let path = hostPaths.helperStatePath(for: target)
        let descriptor = Darwin.open(
            path,
            O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        )
        guard descriptor >= 0 else { throw ProviderError.invalid }
        defer { _ = Darwin.close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0,
              before.st_uid == geteuid(),
              before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_mode & mode_t(0o777) == mode_t(0o600),
              before.st_size > 0,
              before.st_size <= 256 * 1_024
        else { throw ProviderError.invalid }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= 256 * 1_024 else { throw ProviderError.invalid }
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            throw ProviderError.invalid
        }
        var after = stat()
        guard lstat(path, &after) == 0,
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino
        else { throw ProviderError.invalid }
        let document = try RepositoryCanonicalJSON.validateCanonicalDocument(
            [UInt8](data),
            maximumByteCount: 256 * 1_024
        )
        guard document.root.members.map(\.key) == [
            "canonicalUDIDHash", "helpers", "ownerUID", "runtimeEpoch",
            "runtimePID", "runtimeProcessStartIdentity", "schemaVersion",
        ],
        document.root["runtimeProcessStartIdentity"]?.objectValue?.members
            .map(\.key) == ["microseconds", "seconds"],
        let helperValues = document.root["helpers"]?.arrayValue
        else { throw ProviderError.invalid }
        for value in helperValues {
            guard value.objectValue?.members.map(\.key) == [
                "executablePath", "executorGeneration", "executorID",
                "helperID", "pid", "processGroupID", "processStartIdentity",
                "role",
            ],
            value.objectValue?["processStartIdentity"]?.objectValue?.members
                .map(\.key) == ["microseconds", "seconds"]
            else { throw ProviderError.invalid }
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.schemaVersion == 1,
              manifest.ownerUID == geteuid(),
              manifest.canonicalUDIDHash == target.domainSeparatedHash,
              manifest.runtimePID == expectedRuntimePID,
              manifest.runtimeEpoch == expectedRuntimeEpoch,
              manifest.helpers.count <= 64,
              manifest.helpers.map(\.helperID) == manifest.helpers.map(\.helperID).sorted(),
              Set(manifest.helpers.map(\.helperID)).count == manifest.helpers.count
        else { throw ProviderError.invalid }
        return manifest
    }

    private func processIdentity(
        pid: pid_t,
        expectedPath: String,
        expectedStart: StartIdentity? = nil
    ) throws -> ProductionProcessIdentity {
        guard pid > 0,
              let canonicalExpected = canonicalPath(expectedPath),
              currentExecutablePath(pid) == canonicalExpected
        else { throw ProviderError.invalid }
        var info = proc_bsdinfo()
        let size = MemoryLayout<proc_bsdinfo>.size
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, pointer, Int32(size))
        }
        guard result == Int32(size),
              info.pbi_pid == UInt32(pid),
              info.pbi_uid == geteuid(),
              info.pbi_start_tvusec < 1_000_000
        else { throw ProviderError.invalid }
        let identity = StartIdentity(
            seconds: info.pbi_start_tvsec,
            microseconds: info.pbi_start_tvusec
        )
        if let expectedStart, expectedStart != identity {
            throw ProviderError.invalid
        }
        return ProductionProcessIdentity(
            executablePath: canonicalExpected,
            pid: pid,
            startMicroseconds: identity.microseconds,
            startSeconds: identity.seconds
        )
    }

    private func resource(
        _ identity: ProductionProcessIdentity
    ) throws -> ProductionProcessResource {
        var info = proc_taskinfo()
        let size = MemoryLayout<proc_taskinfo>.size
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            proc_pidinfo(identity.pid, PROC_PIDTASKINFO, 0, pointer, Int32(size))
        }
        guard result == Int32(size) else { throw ProviderError.invalid }
        let total = info.pti_total_user.addingReportingOverflow(
            info.pti_total_system
        )
        guard !total.overflow else { throw ProviderError.invalid }
        return ProductionProcessResource(
            identity: identity,
            residentBytes: info.pti_resident_size,
            totalCPUNanoseconds: total.partialValue
        )
    }

    private func isDescendant(_ candidate: pid_t, of ancestor: pid_t) -> Bool {
        var current = candidate
        var visited = Set<pid_t>()
        for _ in 0..<64 {
            guard current > 1, visited.insert(current).inserted else { return false }
            var info = proc_bsdinfo()
            let size = MemoryLayout<proc_bsdinfo>.size
            let result = withUnsafeMutablePointer(to: &info) { pointer in
                proc_pidinfo(current, PROC_PIDTBSDINFO, 0, pointer, Int32(size))
            }
            guard result == Int32(size) else { return false }
            let parent = pid_t(info.pbi_ppid)
            if parent == ancestor { return true }
            current = parent
        }
        return false
    }

    private func currentExecutablePath(_ pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let count = buffer.withUnsafeMutableBufferPointer { pointer in
            proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
        }
        guard count > 0 else { return nil }
        let end = buffer.firstIndex(of: 0) ?? buffer.endIndex
        let bytes = buffer[..<end].map { UInt8(bitPattern: $0) }
        return canonicalPath(String(decoding: bytes, as: UTF8.self))
    }

    private func canonicalPath(_ path: String) -> String? {
        guard path.hasPrefix("/"), !path.utf8.contains(0),
              let resolved = realpath(path, nil)
        else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    private func successfulValue(
        _ result: RepositoryJSONObject
    ) throws -> RepositoryJSONObject {
        guard result["outcome"]?.stringValue == "succeeded",
              let value = result["value"]?.objectValue
        else { throw ProviderError.invalid }
        return value
    }

    private func pid(
        _ object: RepositoryJSONObject,
        key: String
    ) throws -> pid_t {
        let value = try uint(object, key: key)
        guard value > 0, value <= UInt64(Int32.max) else {
            throw ProviderError.invalid
        }
        return pid_t(value)
    }

    private func uint(
        _ object: RepositoryJSONObject,
        key: String
    ) throws -> UInt64 {
        guard let number = object[key]?.numberValue,
              let value = try? number.requireUInt64()
        else { throw ProviderError.invalid }
        return value
    }

    private func object(
        _ members: [(String, RepositoryJSONValue)]
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(members: members.map {
            RepositoryJSONMember(key: $0.0, value: $0.1)
        })
    }

    private struct StartIdentity: Codable, Equatable {
        let seconds: UInt64
        let microseconds: UInt64
    }

    private struct Helper: Codable {
        let role: String
        let executorID: String
        let executorGeneration: UInt64
        let helperID: String
        let pid: pid_t
        let processGroupID: pid_t
        let processStartIdentity: StartIdentity
        let executablePath: String
    }

    private struct Manifest: Codable {
        let schemaVersion: Int
        let runtimeEpoch: UInt64
        let canonicalUDIDHash: String
        let ownerUID: uid_t
        let runtimePID: pid_t
        let runtimeProcessStartIdentity: StartIdentity
        let helpers: [Helper]
    }

    private enum ProviderError: Error {
        case invalid
    }
}

enum ProductionGUIHostSocketActivityProbe {
    static func isActive(path: String) throws -> Bool {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            guard errno == ENOENT else { throw ProbeError.invalid }
            return false
        }
        guard metadata.st_uid == geteuid(),
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFSOCK)
        else { throw ProbeError.invalid }
        let descriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ProbeError.invalid }
        defer { _ = Darwin.close(descriptor) }
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
            throw ProbeError.invalid
        }
        var address = try socketAddress(path)
        let addressLength = socklen_t(address.sun_len)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(descriptor, $0, addressLength)
            }
        }
        if result == 0 { return true }
        guard errno == ECONNREFUSED || errno == ENOENT else {
            throw ProbeError.invalid
        }
        return false
    }

    static func socketAddress(_ path: String) throws -> sockaddr_un {
        let bytes = Array(path.utf8)
        let offset = MemoryLayout<sockaddr_un>.offset(of: \sockaddr_un.sun_path)!
        let length = offset + bytes.count + 1
        guard length <= MemoryLayout<sockaddr_un>.size,
              length <= Int(UInt8.max)
        else { throw ProbeError.invalid }
        var address = sockaddr_un()
        address.sun_len = UInt8(length)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    private enum ProbeError: Error {
        case invalid
    }
}
