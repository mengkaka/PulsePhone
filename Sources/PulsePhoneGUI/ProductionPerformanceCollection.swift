import Darwin
import Foundation
import PulsePhoneMedia
import PulsePhoneSharedDefinitions

public enum ProductionPerformanceCollectionEntrypoint {
    public static let roleArgument = "--performance-collect-v1"

    private static let performanceContractRevision =
        "performance-metrics.v1-20260720"
    private static let performanceContractSHA256 =
        "26e473c469fa5526912c124c43856280ef40be808c741230dcd0f24de9711480"
    private static let measurementDomain =
        "pulsephone.performance-measurement-profile.v1"
    private static let thresholdDomain =
        "pulsephone.performance-threshold-profile.v1"

    private struct Request {
        let target: CanonicalUDID
        let minimumDurationMilliseconds: UInt64
        let requiredReconnectCount: Int
        let evaluationMode: String
        let measurementProfileID: String
        let environmentProfileID: String
        let environmentProfileHash: String
        let reconnectProfileID: String
        let reconnectProfileHash: String
        let thresholdProfile: ThresholdProfile?
        let measurementDescriptor: Int32
        let metricsDescriptor: Int32
        let receiptDescriptor: Int32
        let sessionNonce: String
        let candidateInputHash: String
        let videoMapping: VideoMapping?
    }

    private struct VideoMapping {
        let deviceOSBuild: String
        let deviceProductType: String
        let displayRefreshRateMilliHz: UInt64
        let sourceMapping: ProductionVideoSourceMapping
        let windowHeightPixels: UInt64
        let windowWidthPixels: UInt64
    }

    private struct ThresholdProfile {
        let profileID: String
        let profileHash: String
        let thresholdSetID: String
    }

    private struct OutputDescriptor {
        let descriptor: Int32
        let device: UInt64
        let inode: UInt64
    }

    public static func handles(_ arguments: [String]) -> Bool {
        arguments.first == roleArgument
    }

    public static func run(arguments: [String]) -> Int32 {
        do {
            let request = try parse(arguments)
            let descriptors = try validateOutputDescriptors(request)
            let startedAt = Date()
            let startedMonotonic = SystemMonotonicClock().now().nanoseconds
            let videoLifecycle = request.videoMapping.map {
                ProductionPerformanceVideoLifecycle(
                    target: request.target,
                    mapping: $0.sourceMapping
                )
            }
            videoLifecycle?.start()
            defer { videoLifecycle?.stop() }
            let telemetry = ProductionPerformanceTelemetrySession.bundled(
                target: request.target,
                requiredReconnectCount: request.requiredReconnectCount
            )
            telemetry.begin(
                atMonotonicNanoseconds: startedMonotonic,
                video: videoLifecycle?.snapshot()
            )
            try waitUntilDurationElapsed(
                startedMonotonicNanoseconds: startedMonotonic,
                minimumDurationMilliseconds: request.minimumDurationMilliseconds
            ) { now in
                telemetry.observe(
                    atMonotonicNanoseconds: now,
                    video: videoLifecycle?.snapshot()
                )
            }
            videoLifecycle?.stop()
            let endedMonotonic = SystemMonotonicClock().now().nanoseconds
            telemetry.observe(
                atMonotonicNanoseconds: endedMonotonic,
                video: videoLifecycle?.snapshot()
            )
            let telemetrySnapshot = telemetry.finish()
            let duration = max(
                request.minimumDurationMilliseconds,
                (endedMonotonic - startedMonotonic) / 1_000_000
            )
            let video = videoLifecycle?.snapshot()
            let measurement = try makeMeasurement(
                request: request,
                video: video,
                startedMonotonicNanoseconds: startedMonotonic
            )
            let measurementHash = try StableBytes.domainSeparatedSHA256Hex(
                domainID: measurementDomain,
                payload: measurement
            )
            let metrics = try makeMetrics(
                request: request,
                measurementHash: measurementHash,
                durationMilliseconds: duration,
                startedMonotonicNanoseconds: startedMonotonic,
                telemetry: telemetrySnapshot,
                video: video,
                startedAt: startedAt,
                endedAt: Date()
            )
            let receipt = try canonicalJSON([
                "candidateInputHash": request.candidateInputHash,
                "measurementSHA256": StableBytes.sha256Hex(measurement),
                "metricsSHA256": StableBytes.sha256Hex(metrics),
                "schemaVersion": 1,
                "sessionNonce": request.sessionNonce,
            ])
            try writeAll(measurement, to: descriptors[0].descriptor)
            try writeAll(metrics, to: descriptors[1].descriptor)
            try writeAll(receipt, to: descriptors[2].descriptor)
            return 0
        } catch {
            return 64
        }
    }

    private static func parse(_ arguments: [String]) throws -> Request {
        guard arguments.first == roleArgument else { throw ParseError.invalid }
        let pairs = Array(arguments.dropFirst())
        guard pairs.count.isMultiple(of: 2) else { throw ParseError.invalid }
        var values = [String: String]()
        var index = 0
        while index < pairs.count {
            let key = pairs[index]
            guard allowedArguments.contains(key), values[key] == nil else {
                throw ParseError.invalid
            }
            values[key] = pairs[index + 1]
            index += 2
        }
        let required = Set(allowedArguments).subtracting(
            ["--threshold-profile", "--threshold-set"] + videoArgumentNames
        )
        guard required.isSubset(of: values.keys) else { throw ParseError.invalid }

        let evaluationMode = try value("--evaluation-mode", in: values)
        let thresholdProfile: ThresholdProfile?
        switch evaluationMode {
        case "baseline":
            guard values["--threshold-profile"] == nil,
                  values["--threshold-set"] == nil
            else { throw ParseError.invalid }
            thresholdProfile = nil
        case "threshold":
            let path = try value("--threshold-profile", in: values)
            let setID = try identifier(
                value("--threshold-set", in: values),
                maximumBytes: 128
            )
            thresholdProfile = try loadThresholdProfile(path: path, setID: setID)
        default:
            throw ParseError.invalid
        }

        let duration = try unsigned(value("--minimum-duration-ms", in: values))
        guard (1_000...43_200_000).contains(duration) else {
            throw ParseError.invalid
        }
        let reconnects = try unsigned(
            value("--required-reconnect-count", in: values)
        )
        guard reconnects <= 1_000 else { throw ParseError.invalid }
        let videoMapping = try parseVideoMapping(values)
        return Request(
            target: try CanonicalUDID(
                canonicalString: value("--target-udid", in: values)
            ),
            minimumDurationMilliseconds: duration,
            requiredReconnectCount: Int(reconnects),
            evaluationMode: evaluationMode,
            measurementProfileID: try identifier(
                value("--measurement-profile-id", in: values),
                maximumBytes: 128
            ),
            environmentProfileID: try identifier(
                value("--evidence-environment-profile-id", in: values),
                maximumBytes: 128
            ),
            environmentProfileHash: try hash(
                value("--evidence-environment-profile-hash", in: values)
            ),
            reconnectProfileID: try identifier(
                value("--reconnect-readiness-profile-id", in: values),
                maximumBytes: 128
            ),
            reconnectProfileHash: try hash(
                value("--reconnect-readiness-profile-hash", in: values)
            ),
            thresholdProfile: thresholdProfile,
            measurementDescriptor: try descriptor(
                value("--performance-measurement-fd", in: values)
            ),
            metricsDescriptor: try descriptor(
                value("--performance-metrics-fd", in: values)
            ),
            receiptDescriptor: try descriptor(
                value("--performance-receipt-fd", in: values)
            ),
            sessionNonce: try lowercaseHex(
                value("--performance-session-nonce", in: values),
                byteCount: 16
            ),
            candidateInputHash: try hash(
                value("--performance-candidate-input-hash", in: values)
            ),
            videoMapping: videoMapping
        )
    }

    private static func parseVideoMapping(
        _ values: [String: String]
    ) throws -> VideoMapping? {
        let provided = videoArgumentNames.filter { values[$0] != nil }
        guard !provided.isEmpty else { return nil }
        guard provided.count == videoArgumentNames.count else {
            throw ParseError.invalid
        }
        let connectionEpoch = try positiveUnsigned(
            value("--video-connection-epoch", in: values)
        )
        let geometryRevision = try positiveUnsigned(
            value("--video-geometry-revision", in: values)
        )
        let logicalWidth = try positiveUnsigned(
            value("--video-logical-width", in: values)
        )
        let logicalHeight = try positiveUnsigned(
            value("--video-logical-height", in: values)
        )
        guard let orientation = DisplayOrientationDTO(
            rawValue: try value("--video-orientation", in: values)
        ) else { throw ParseError.invalid }
        return VideoMapping(
            deviceOSBuild: try identifier(
                value("--video-device-os-build", in: values),
                maximumBytes: 64
            ),
            deviceProductType: try identifier(
                value("--video-device-product-type", in: values),
                maximumBytes: 64
            ),
            displayRefreshRateMilliHz: try positiveUnsigned(
                value("--video-display-refresh-rate-millihz", in: values)
            ),
            sourceMapping: ProductionVideoSourceMapping(
                connectionEpoch: connectionEpoch,
                geometry: try DisplayGeometryDTO(
                    connectionEpoch: connectionEpoch,
                    geometryRevision: geometryRevision,
                    logicalHeight: logicalHeight,
                    logicalWidth: logicalWidth,
                    orientation: orientation
                ),
                mappingProofID: try identifier(
                    value("--video-mapping-proof-id", in: values),
                    maximumBytes: 128
                ),
                sourceEpoch: try positiveUnsigned(
                    value("--video-source-epoch", in: values)
                ),
                sourceID: try lowercaseHex(
                    value("--video-source-id", in: values),
                    byteCount: 32
                )
            ),
            windowHeightPixels: try positiveUnsigned(
                value("--video-window-height-pixels", in: values)
            ),
            windowWidthPixels: try positiveUnsigned(
                value("--video-window-width-pixels", in: values)
            )
        )
    }

    private static let videoArgumentNames = [
        "--video-connection-epoch",
        "--video-device-os-build",
        "--video-device-product-type",
        "--video-display-refresh-rate-millihz",
        "--video-geometry-revision",
        "--video-logical-height",
        "--video-logical-width",
        "--video-mapping-proof-id",
        "--video-orientation",
        "--video-source-epoch",
        "--video-source-id",
        "--video-window-height-pixels",
        "--video-window-width-pixels",
    ]

    private static let allowedArguments = [
        "--target-udid",
        "--minimum-duration-ms",
        "--required-reconnect-count",
        "--evaluation-mode",
        "--measurement-profile-id",
        "--evidence-environment-profile-id",
        "--evidence-environment-profile-hash",
        "--reconnect-readiness-profile-id",
        "--reconnect-readiness-profile-hash",
        "--threshold-profile",
        "--threshold-set",
        "--performance-measurement-fd",
        "--performance-metrics-fd",
        "--performance-receipt-fd",
        "--performance-session-nonce",
        "--performance-candidate-input-hash",
    ] + videoArgumentNames

    private static func validateOutputDescriptors(
        _ request: Request
    ) throws -> [OutputDescriptor] {
        let raw = [
            request.measurementDescriptor,
            request.metricsDescriptor,
            request.receiptDescriptor,
        ]
        guard Set(raw).count == raw.count else { throw ParseError.invalid }
        let descriptors = try raw.map(validateOutputDescriptor)
        let identities = descriptors.map { "\($0.device):\($0.inode)" }
        guard Set(identities).count == identities.count else {
            throw ParseError.invalid
        }
        return descriptors
    }

    private static func validateOutputDescriptor(
        _ descriptor: Int32
    ) throws -> OutputDescriptor {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_size == 0,
              metadata.st_mode & mode_t(0o777) == mode_t(0o600),
              lseek(descriptor, 0, SEEK_CUR) == 0
        else { throw ParseError.invalid }
        let status = fcntl(descriptor, F_GETFL)
        guard status >= 0,
              status & O_ACCMODE == O_WRONLY,
              status & (O_APPEND | O_NONBLOCK) == 0
        else { throw ParseError.invalid }
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        guard descriptorFlags >= 0,
              fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0
        else { throw ParseError.invalid }
        return OutputDescriptor(
            descriptor: descriptor,
            device: UInt64(metadata.st_dev),
            inode: UInt64(metadata.st_ino)
        )
    }

    private static func waitUntilDurationElapsed(
        startedMonotonicNanoseconds: UInt64,
        minimumDurationMilliseconds: UInt64,
        observe: (UInt64) -> Void
    ) throws {
        let delta = minimumDurationMilliseconds.multipliedReportingOverflow(
            by: 1_000_000
        )
        guard !delta.overflow,
              startedMonotonicNanoseconds <= UInt64.max - delta.partialValue
        else { throw ParseError.invalid }
        let deadline = startedMonotonicNanoseconds + delta.partialValue
        var nextObservation = min(
            deadline,
            startedMonotonicNanoseconds + 1_000_000_000
        )
        while true {
            let now = SystemMonotonicClock().now().nanoseconds
            if now >= deadline { return }
            if now >= nextObservation {
                observe(now)
                let advanced = nextObservation.addingReportingOverflow(
                    1_000_000_000
                )
                nextObservation = advanced.overflow
                    ? deadline
                    : min(deadline, advanced.partialValue)
                continue
            }
            let remaining = min(deadline, nextObservation) - now
            if Thread.isMainThread {
                let quantum = min(remaining, 50_000_000)
                RunLoop.current.run(
                    until: Date(timeIntervalSinceNow: TimeInterval(quantum) / 1e9)
                )
                continue
            }
            var requestedSleep = timespec(
                tv_sec: Int(remaining / 1_000_000_000),
                tv_nsec: Int(remaining % 1_000_000_000)
            )
            while true {
                var unslept = timespec()
                if nanosleep(&requestedSleep, &unslept) == 0 { break }
                guard errno == EINTR else { throw ParseError.invalid }
                requestedSleep = unslept
            }
        }
    }

    private static func makeMeasurement(
        request: Request,
        video: ProductionVideoSnapshot?,
        startedMonotonicNanoseconds: UInt64
    ) throws -> [UInt8] {
        let mapping = video == nil ? nil : request.videoMapping
        let captureWidth = video?.activeFormatWidth ?? 1
        let captureHeight = video?.activeFormatHeight ?? 1
        let preview = previewSummary(
            video: video,
            startedMonotonicNanoseconds: startedMonotonicNanoseconds,
            durationMilliseconds: request.minimumDurationMilliseconds
        )
        return try canonicalJSON([
            "buildConfiguration": "release",
            "capture": [
                "audioMute": true,
                "heightPixels": captureHeight,
                "nominalFPSMilli": max(1, preview.p50),
                "widthPixels": captureWidth,
                "windowHeightPixels": mapping?.windowHeightPixels ?? 1,
                "windowWidthPixels": mapping?.windowWidthPixels ?? 1,
            ],
            "device": [
                "deviceClass": "iPhone",
                "osBuild": mapping?.deviceOSBuild ?? "unknown",
                "productType": mapping?.deviceProductType ?? "unknown",
            ],
            "evidenceEnvironmentProfileHash": request.environmentProfileHash,
            "evidenceEnvironmentProfileID": request.environmentProfileID,
            "host": [
                "architecture": "arm64",
                "displayRefreshRateMilliHz":
                    mapping?.displayRefreshRateMilliHz ?? 1,
                "logicalCPUCount": max(1, ProcessInfo.processInfo.processorCount),
                "macModel": sysctlString("hw.model") ?? "unknown",
                "macOSBuild": sysctlString("kern.osversion") ?? "unknown",
            ],
            "processSetProfileID": "single-live.v1",
            "profileID": request.measurementProfileID,
            "reconnectReadinessProfileHash": request.reconnectProfileHash,
            "reconnectReadinessProfileID": request.reconnectProfileID,
            "schemaVersion": 1,
        ])
    }

    private static func makeMetrics(
        request: Request,
        measurementHash: String,
        durationMilliseconds: UInt64,
        startedMonotonicNanoseconds: UInt64,
        telemetry: ProductionPerformanceTelemetrySnapshot,
        video: ProductionVideoSnapshot?,
        startedAt: Date,
        endedAt: Date
    ) throws -> [UInt8] {
        let mapping = video == nil ? nil : request.videoMapping
        let preview = previewSummary(
            video: video,
            startedMonotonicNanoseconds: startedMonotonicNanoseconds,
            durationMilliseconds: durationMilliseconds
        )
        let latency = latencySummary(
            video: video,
            startedMonotonicNanoseconds: startedMonotonicNanoseconds
        )
        let gates = gateValues(
            reconnectsRequired: request.requiredReconnectCount,
            preview: preview,
            latency: latency,
            telemetry: telemetry
        )
        let gapCount = gates.reduce(0) { count, gate in
            guard gate["applicability"] as? String != "notApplicable" else {
                return count
            }
            return count + ((gate["dataQuality"] as? String) == "complete" ? 0 : 1)
        }
        var failureReasons = [String]()
        if !telemetry.process.hasCompleteSteadySamples {
            failureReasons.append("processSetUnavailable")
        }
        if request.requiredReconnectCount > 0,
           telemetry.reconnects.contains(where: {
               if case .recovered = $0.control { return false }
               return true
           })
        {
            failureReasons.append("reconnectObservationUnavailable")
        }
        if preview.bucketCount == 0 || latency.count == 0 {
            failureReasons.append("performanceSourceUnavailable")
        }
        if telemetry.pointer.dropped > 0 {
            failureReasons.append("pointerTelemetrySaturated")
        }
        if !telemetry.runtimeCleanupComplete {
            failureReasons.append("runtimeCleanupUnavailable")
        }
        failureReasons = Array(Set(failureReasons)).sorted()
        let connectionEpochs = Set(
            telemetry.connectionEpochs + (video?.connectionEpochs ?? [])
        ).sorted()
        var root: [String: Any] = [
            "appBuild": Bundle.main.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String ?? "unknown",
            "architecture": "arm64",
            "audioMute": true,
            "bucketMs": 1_000,
            "buildConfiguration": "release",
            "captureHeightPixels": video?.activeFormatHeight ?? 1,
            "captureWidthPixels": video?.activeFormatWidth ?? 1,
            "connectionEpochs": connectionEpochs,
            "cpuTotalPercent": cpuSummary(telemetry.process),
            "deviceClass": "iPhone",
            "displayRefreshRateMilliHz":
                mapping?.displayRefreshRateMilliHz ?? 1,
            "endedAtUTC": utc(endedAt),
            "evaluationMode": request.evaluationMode,
            "excludedSegments": excludedSegments(
                durationMilliseconds: durationMilliseconds,
                videoBound: video != nil
            ),
            "gateValues": gates,
            "hostVideoPipelineLatencyMs": latency.dictionary,
            "iOSBuild": mapping?.deviceOSBuild ?? "unknown",
            "logicalCPUCount": max(1, ProcessInfo.processInfo.processorCount),
            "macModel": sysctlString("hw.model") ?? "unknown",
            "macOSBuild": sysctlString("kern.osversion") ?? "unknown",
            "measurementProfileHash": measurementHash,
            "measurementProfileID": request.measurementProfileID,
            "metricsEnabled": true,
            "metricsSessionID": "metrics.\(StableBytes.sha256Hex(request.sessionNonce.utf8).prefix(32))",
            "monotonicDurationMs": durationMilliseconds,
            "nominalCaptureFPSMilli": max(1, preview.p50),
            "performanceContract": [
                "revision": performanceContractRevision,
                "sha256": performanceContractSHA256,
            ],
            "previewFPS": preview.dictionary,
            "productType": mapping?.deviceProductType ?? "unknown",
            "reconnectReadinessProfileHash": request.reconnectProfileHash,
            "reconnectReadinessProfileID": request.reconnectProfileID,
            "reconnects": telemetry.reconnects.map(\.dictionary),
            "rssTotalMiB": rssSummary(telemetry.process),
            "runtimeEpochs": telemetry.process.runtimeEpochs,
            "schemaVersion": 1,
            "sourceEpochs": video?.sourceEpochs ?? [],
            "stability": [
                "counters": [
                    "crash": 0,
                    "duplicateGeneration": 0,
                    "duplicateTerminal": 0,
                    "foreignSignal": 0,
                    "frameGap": 0,
                    "lockLeak": 0,
                    "metricsGap": gapCount,
                    "outcomeUnknown": gapCount,
                    "runtimeFatal": 0,
                    "wrongTargetFrame": 0,
                ],
                "durationMs": durationMilliseconds,
                "failureReasons": failureReasons,
                "passed": failureReasons.isEmpty && gapCount == 0,
            ],
            "startedAtUTC": utc(startedAt),
            "targetUDIDHash": PerformanceMetricsExportV1.targetUDIDHash(
                request.target
            ),
            "touchDeliveryLatencyMs": telemetry.pointer.dictionary,
            "warmupMs": 10_000,
            "windowHeightPixels": mapping?.windowHeightPixels ?? 1,
            "windowWidthPixels": mapping?.windowWidthPixels ?? 1,
        ]
        if let threshold = request.thresholdProfile {
            root["thresholdProfileHash"] = threshold.profileHash
            root["thresholdProfileID"] = threshold.profileID
            root["thresholdSetID"] = threshold.thresholdSetID
        }
        return try canonicalJSON(root)
    }

    private struct PreviewSummary {
        let bucketCount: UInt64
        let dropped: UInt64
        let enqueued: UInt64
        let maxInterFrameGapMilliseconds: UInt64
        let minimum: UInt64
        let p05: UInt64
        let p50: UInt64
        let p95: UInt64
        let received: UInt64

        var dictionary: [String: Any] {
            [
                "bucketCount": bucketCount,
                "dropped": dropped,
                "enqueued": enqueued,
                "maxInterFrameGapMs": maxInterFrameGapMilliseconds,
                "min": minimum,
                "p05": p05,
                "p50": p50,
                "p95": p95,
                "received": received,
            ]
        }
    }

    private struct LatencySummary {
        let count: UInt64
        let maximum: UInt64
        let p50: UInt64
        let p95: UInt64
        let p99: UInt64

        var dictionary: [String: Any] {
            [
                "count": count,
                "max": maximum,
                "p50": p50,
                "p95": p95,
                "p99": p99,
            ]
        }
    }

    private static func previewSummary(
        video: ProductionVideoSnapshot?,
        startedMonotonicNanoseconds: UInt64,
        durationMilliseconds: UInt64
    ) -> PreviewSummary {
        guard let video else { return zeroPreviewSummary() }
        let warmupMilliseconds: UInt64 = 10_000
        let fullBucketCount = durationMilliseconds > warmupMilliseconds
            ? (durationMilliseconds - warmupMilliseconds) / 1_000
            : 0
        let warmupNanoseconds = warmupMilliseconds * 1_000_000
        guard startedMonotonicNanoseconds <= UInt64.max - warmupNanoseconds else {
            return zeroPreviewSummary(video: video)
        }
        let steadyStart = startedMonotonicNanoseconds + warmupNanoseconds
        var bucketValues = [UInt64](
            repeating: 0,
            count: Int(fullBucketCount)
        )
        if fullBucketCount > 0 {
            for timestamp in video.enqueueMonotonicNanoseconds
                where timestamp >= steadyStart
            {
                let index = (timestamp - steadyStart) / 1_000_000_000
                guard index < fullBucketCount else { continue }
                bucketValues[Int(index)] += 1_000
            }
        }
        let sortedBuckets = bucketValues.sorted()
        let gaps = zip(
            video.enqueueMonotonicNanoseconds,
            video.enqueueMonotonicNanoseconds.dropFirst()
        ).map { first, second in
            second >= first ? (second - first) / 1_000_000 : 0
        }
        return PreviewSummary(
            bucketCount: fullBucketCount,
            dropped: video.droppedFrameCount,
            enqueued: video.enqueuedFrameCount,
            maxInterFrameGapMilliseconds: gaps.max() ?? 0,
            minimum: sortedBuckets.first ?? 0,
            p05: percentile(sorted: sortedBuckets, percent: 5),
            p50: percentile(sorted: sortedBuckets, percent: 50),
            p95: percentile(sorted: sortedBuckets, percent: 95),
            received: video.receivedFrameCount
        )
    }

    private static func latencySummary(
        video: ProductionVideoSnapshot?,
        startedMonotonicNanoseconds: UInt64
    ) -> LatencySummary {
        guard let video else { return zeroLatencySummary() }
        let warmupNanoseconds: UInt64 = 10_000_000_000
        guard startedMonotonicNanoseconds <= UInt64.max - warmupNanoseconds else {
            return zeroLatencySummary()
        }
        let steadyStart = startedMonotonicNanoseconds + warmupNanoseconds
        let samples = zip(
            video.enqueueMonotonicNanoseconds,
            video.latencyMicroseconds
        ).compactMap { timestamp, latency in
            timestamp >= steadyStart ? latency : nil
        }.sorted()
        return LatencySummary(
            count: UInt64(samples.count),
            maximum: samples.last ?? 0,
            p50: percentile(sorted: samples, percent: 50),
            p95: percentile(sorted: samples, percent: 95),
            p99: percentile(sorted: samples, percent: 99)
        )
    }

    private static func gateValues(
        reconnectsRequired: Int,
        preview: PreviewSummary,
        latency: LatencySummary,
        telemetry: ProductionPerformanceTelemetrySnapshot
    ) -> [[String: Any]] {
        var values = unknownGateValues(reconnectsRequired: reconnectsRequired)
        let controlReconnects = telemetry.reconnects.compactMap { attempt -> UInt64? in
            if case .recovered(let milliseconds) = attempt.control {
                return milliseconds * 1_000
            }
            return nil
        }.sorted()
        if reconnectsRequired > 0,
           controlReconnects.count == reconnectsRequired
        {
            values[0] = completeGate(
                rule: "controlReconnectMs.p95",
                metric: "controlReconnectMs",
                statistic: "p95",
                unit: "microseconds",
                observed: percentile(sorted: controlReconnects, percent: 95),
                sampleCount: UInt64(controlReconnects.count)
            )
        }
        if telemetry.process.hasCompleteSteadySamples {
            values[1] = completeGate(
                rule: "cpuTotalPercent.p95",
                metric: "cpuTotalPercent",
                statistic: "p95",
                unit: "milliPercent",
                observed: percentile(
                    sorted: telemetry.process.cpuMilliPercent,
                    percent: 95
                ),
                sampleCount: UInt64(telemetry.process.cpuMilliPercent.count)
            )
            values[5] = completeGate(
                rule: "rssTotalMiB.p95",
                metric: "rssTotalMiB",
                statistic: "p95",
                unit: "kibibytes",
                observed: percentile(
                    sorted: telemetry.process.rssKibibytes,
                    percent: 95
                ),
                sampleCount: UInt64(telemetry.process.rssKibibytes.count)
            )
            if telemetry.process.rssKibibytes.count >= 600 {
                values[4] = completeGate(
                    rule: "rssGrowthMiBPerHour.value",
                    metric: "rssGrowthMiBPerHour",
                    statistic: "value",
                    unit: "kibibytesPerHour",
                    observed: telemetry.process.rssGrowthKibibytesPerHour,
                    sampleCount: 1
                )
            }
        }
        if latency.count > 0 {
            values[2] = completeGate(
                rule: "hostVideoPipelineLatencyMs.p95",
                metric: "hostVideoPipelineLatencyMs",
                statistic: "p95",
                unit: "microseconds",
                observed: latency.p95,
                sampleCount: latency.count
            )
        }
        if preview.bucketCount > 0 {
            values[3] = completeGate(
                rule: "previewFPS.p05",
                metric: "previewFPS",
                statistic: "p05",
                unit: "milliFramesPerSecond",
                observed: preview.p05,
                sampleCount: preview.bucketCount
            )
        }
        if telemetry.pointer.count > 0, telemetry.pointer.dropped == 0 {
            values[6] = completeGate(
                rule: "touchDeliveryLatencyMs.p95",
                metric: "touchDeliveryLatencyMs",
                statistic: "p95",
                unit: "microseconds",
                observed: telemetry.pointer.p95Microseconds,
                sampleCount: telemetry.pointer.count
            )
        } else if telemetry.pointer.unconfirmed > 0
                    || telemetry.pointer.dropped > 0
        {
            values[6] = unknownGate(
                rule: "touchDeliveryLatencyMs.p95",
                metric: "touchDeliveryLatencyMs",
                statistic: "p95",
                unit: "microseconds",
                quality: "gap",
                reason: telemetry.pointer.dropped > 0
                    ? "pointerTelemetrySaturated"
                    : "acceptedTouchTimestampUnavailable"
            )
        }
        let videoReconnects = telemetry.reconnects.compactMap { attempt -> UInt64? in
            if case .recovered(let milliseconds) = attempt.video {
                return milliseconds * 1_000
            }
            return nil
        }.sorted()
        if reconnectsRequired > 0,
           videoReconnects.count == reconnectsRequired
        {
            values[7] = completeGate(
                rule: "videoReconnectMs.p95",
                metric: "videoReconnectMs",
                statistic: "p95",
                unit: "microseconds",
                observed: percentile(sorted: videoReconnects, percent: 95),
                sampleCount: UInt64(videoReconnects.count)
            )
        }
        return values
    }

    private static func completeGate(
        rule: String,
        metric: String,
        statistic: String,
        unit: String,
        observed: Any,
        sampleCount: UInt64
    ) -> [String: Any] {
        [
            "applicability": "applicable",
            "canonicalUnitID": unit,
            "dataQuality": "complete",
            "metricID": metric,
            "observedScaledValue": observed,
            "ruleID": rule,
            "sampleCount": sampleCount,
            "statisticID": statistic,
        ]
    }

    private static func excludedSegments(
        durationMilliseconds: UInt64,
        videoBound: Bool
    ) -> [[String: Any]] {
        if !videoBound {
            return [[
                "endedMonotonicMs": durationMilliseconds,
                "reasonCode": "sourceUnbound",
                "startedMonotonicMs": 0,
            ]]
        }
        return [[
            "endedMonotonicMs": min(durationMilliseconds, 10_000),
            "reasonCode": "initialWarmup",
            "startedMonotonicMs": 0,
        ]]
    }

    private static func percentile(
        sorted values: [UInt64],
        percent: Int
    ) -> UInt64 {
        guard !values.isEmpty, (1...100).contains(percent) else { return 0 }
        let rank = (values.count * percent + 99) / 100
        return values[max(0, rank - 1)]
    }

    private static func zeroPreviewSummary(
        video: ProductionVideoSnapshot? = nil
    ) -> PreviewSummary {
        PreviewSummary(
            bucketCount: 0,
            dropped: video?.droppedFrameCount ?? 0,
            enqueued: video?.enqueuedFrameCount ?? 0,
            maxInterFrameGapMilliseconds: 0,
            minimum: 0,
            p05: 0,
            p50: 0,
            p95: 0,
            received: video?.receivedFrameCount ?? 0
        )
    }

    private static func zeroLatencySummary() -> LatencySummary {
        LatencySummary(count: 0, maximum: 0, p50: 0, p95: 0, p99: 0)
    }

    private static func unknownGateValues(
        reconnectsRequired: Int
    ) -> [[String: Any]] {
        [
            unknownGate(
                rule: "controlReconnectMs.p95",
                metric: "controlReconnectMs",
                statistic: "p95",
                unit: "microseconds",
                quality: reconnectsRequired > 0 ? "notRecovered" : "gap",
                reason: reconnectsRequired > 0
                    ? "physicalReconnectNotObserved"
                    : "controlObservationUnavailable"
            ),
            unknownGate(
                rule: "cpuTotalPercent.p95",
                metric: "cpuTotalPercent",
                statistic: "p95",
                unit: "milliPercent",
                quality: "gap",
                reason: "processSetUnavailable"
            ),
            unknownGate(
                rule: "hostVideoPipelineLatencyMs.p95",
                metric: "hostVideoPipelineLatencyMs",
                statistic: "p95",
                unit: "microseconds",
                quality: "gap",
                reason: "videoSourceUnavailable"
            ),
            unknownGate(
                rule: "previewFPS.p05",
                metric: "previewFPS",
                statistic: "p05",
                unit: "milliFramesPerSecond",
                quality: "gap",
                reason: "videoSourceUnavailable"
            ),
            unknownGate(
                rule: "rssGrowthMiBPerHour.value",
                metric: "rssGrowthMiBPerHour",
                statistic: "value",
                unit: "kibibytesPerHour",
                quality: "gap",
                reason: "processSetUnavailable"
            ),
            unknownGate(
                rule: "rssTotalMiB.p95",
                metric: "rssTotalMiB",
                statistic: "p95",
                unit: "kibibytes",
                quality: "gap",
                reason: "processSetUnavailable"
            ),
            [
                "applicability": "notApplicable",
                "canonicalUnitID": "microseconds",
                "dataQuality": "complete",
                "metricID": "touchDeliveryLatencyMs",
                "notApplicableReasonCode": "noAcceptedTouchSamples",
                "ruleID": "touchDeliveryLatencyMs.p95",
                "sampleCount": 0,
                "statisticID": "p95",
            ],
            unknownGate(
                rule: "videoReconnectMs.p95",
                metric: "videoReconnectMs",
                statistic: "p95",
                unit: "microseconds",
                quality: reconnectsRequired > 0 ? "notRecovered" : "gap",
                reason: "videoSourceUnavailable"
            ),
        ]
    }

    private static func unknownGate(
        rule: String,
        metric: String,
        statistic: String,
        unit: String,
        quality: String,
        reason: String
    ) -> [String: Any] {
        [
            "applicability": "applicable",
            "canonicalUnitID": unit,
            "dataQuality": quality,
            "metricID": metric,
            "ruleID": rule,
            "sampleCount": 0,
            "statisticID": statistic,
            "unknownReasonCode": reason,
        ]
    }

    private static func cpuSummary(
        _ process: ProductionProcessTelemetrySummary
    ) -> [String: Any] {
        [
            "max": process.cpuMilliPercent.last ?? 0,
            "p50": percentile(sorted: process.cpuMilliPercent, percent: 50),
            "p95": percentile(sorted: process.cpuMilliPercent, percent: 95),
            "wholeRunMax": process.wholeRunCPUMaximumMilliPercent,
        ]
    }

    private static func rssSummary(
        _ process: ProductionProcessTelemetrySummary
    ) -> [String: Any] {
        [
            "growthMiBPerHour": process.rssGrowthKibibytesPerHour,
            "max": process.rssKibibytes.last ?? 0,
            "p50": percentile(sorted: process.rssKibibytes, percent: 50),
            "p95": percentile(sorted: process.rssKibibytes, percent: 95),
            "wholeRunMax": process.wholeRunRSSMaximumKibibytes,
        ]
    }

    private static func canonicalJSON(_ object: [String: Any]) throws -> [UInt8] {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw ParseError.invalid
        }
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let bytes = [UInt8](data)
        _ = try RepositoryCanonicalJSON.validateCanonicalDocument(
            bytes,
            maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
        )
        return bytes
    }

    private static func loadThresholdProfile(
        path: String,
        setID: String
    ) throws -> ThresholdProfile {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw ParseError.invalid
        }
        let descriptor = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw ParseError.invalid }
        defer { _ = Darwin.close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_uid == geteuid(),
              metadata.st_size > 0,
              metadata.st_size <= EvidenceContractHardCaps.otherCanonicalDocumentBytes
        else { throw ParseError.invalid }
        var bytes = [UInt8]()
        bytes.reserveCapacity(Int(metadata.st_size))
        var buffer = [UInt8](repeating: 0, count: 16 * 1_024)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                bytes.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 { break }
            if errno == EINTR { continue }
            throw ParseError.invalid
        }
        let document = try RepositoryCanonicalJSON.validateCanonicalDocument(
            bytes,
            maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
        )
        guard let profileID = document.root["profileID"]?.stringValue,
              let sets = document.root["thresholdSets"]?.arrayValue,
              sets.filter({ value in
                  value.objectValue?["thresholdSetID"]?.stringValue == setID
              }).count == 1
        else { throw ParseError.invalid }
        return ThresholdProfile(
            profileID: try identifier(profileID, maximumBytes: 128),
            profileHash: try StableBytes.domainSeparatedSHA256Hex(
                domainID: thresholdDomain,
                payload: bytes
            ),
            thresholdSetID: setID
        )
    }

    private static func writeAll(_ bytes: [UInt8], to descriptor: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer -> Int in
                Darwin.write(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
            }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EINTR { continue }
            throw ParseError.invalid
        }
        guard fsync(descriptor) == 0 else { throw ParseError.invalid }
    }

    private static func value(
        _ key: String,
        in values: [String: String]
    ) throws -> String {
        guard let value = values[key] else { throw ParseError.invalid }
        return value
    }

    private static func unsigned(_ value: String) throws -> UInt64 {
        guard !value.isEmpty,
              value.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
              let parsed = UInt64(value)
        else { throw ParseError.invalid }
        return parsed
    }

    private static func positiveUnsigned(_ value: String) throws -> UInt64 {
        let parsed = try unsigned(value)
        guard parsed > 0 else { throw ParseError.invalid }
        return parsed
    }

    private static func descriptor(_ value: String) throws -> Int32 {
        let parsed = try unsigned(value)
        guard (3...UInt64(Int32.max)).contains(parsed) else {
            throw ParseError.invalid
        }
        return Int32(parsed)
    }

    private static func identifier(
        _ value: String,
        maximumBytes: Int
    ) throws -> String {
        let bytes = Array(value.utf8)
        guard (1...maximumBytes).contains(bytes.count),
              !bytes.contains(0),
              !value.contains("/"),
              !value.contains("\\"),
              !value.contains("://"),
              bytes.allSatisfy({ (0x21...0x7e).contains($0) })
        else { throw ParseError.invalid }
        return value
    }

    private static func hash(_ value: String) throws -> String {
        try lowercaseHex(value, byteCount: 32)
    }

    private static func lowercaseHex(
        _ value: String,
        byteCount: Int
    ) throws -> String {
        guard value.utf8.count == byteCount * 2,
              value.utf8.allSatisfy({
                  (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
              })
        else { throw ParseError.invalid }
        return value
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else {
            return nil
        }
        var bytes = [UInt8](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return nil }
        if bytes.last == 0 { bytes.removeLast() }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func utc(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private enum ParseError: Error {
        case invalid
    }
}
