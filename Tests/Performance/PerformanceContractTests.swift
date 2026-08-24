import Foundation
import XCTest
@testable import PulsePhoneMedia
import PulsePhoneSharedDefinitions

final class PerformanceContractTests: XCTestCase {
    func testMetricsSchemaMeasurementAndRecomputeFixture() throws {
        let expected = try object(
            "Fixtures/requirements/T-018/metrics-schema-measurement-recompute-l3/expected.v1.json"
        )
        let input = try object(
            "Fixtures/requirements/T-018/metrics-schema-measurement-recompute-l3/input/input.v1.json"
        )
        let registry = try PerformanceMetricRegistryV1.load(repositoryRoot: repositoryRoot)
        let identity = try PerformanceMetricRegistryV1.identity(
            repositoryRoot: repositoryRoot
        )
        XCTAssertEqual(registry.metrics.count, try integer(input, "expectedMetricCount"))
        XCTAssertEqual(registry.metrics.count, try integer(expected, "metricCount"))
        XCTAssertEqual(identity.revision, try string(expected, "performanceContractRevision"))
        XCTAssertEqual(identity.sha256, try string(expected, "performanceContractSHA256"))
        XCTAssertEqual(
            registry.requiredRuleIDs,
            try strings(input, "expectedRuleIDs")
        )

        let profileData = try data(
            "Fixtures/performance/measurement-profile/profile.v1.json"
        )
        let measurement = try PerformanceMetricsExportV1.measurementProfileIdentity(
            canonicalBytes: [UInt8](profileData)
        )
        XCTAssertEqual(
            measurement.profileHash,
            try string(expected, "measurementProfileHash")
        )
        let metrics = try PerformanceMetricsExportV1.validateCanonicalMetrics(
            [UInt8](try data("Fixtures/performance/metrics-contract/threshold.metrics.v1.json")),
            registry: registry,
            expectedContract: identity,
            expectedMeasurementProfile: measurement
        )
        XCTAssertEqual(metrics.gateValues.count, registry.requiredRuleIDs.count)

        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pulsephone-evaluation-\(UUID().uuidString).json"
        )
        defer { try? FileManager.default.removeItem(at: output) }
        let result = try runTool([
            "evaluate",
            "--metrics", "Fixtures/performance/metrics-contract/threshold.metrics.v1.json",
            "--threshold-profile", "Fixtures/performance/threshold-profile/profile.v1.json",
            "--threshold-set", "threshold.synthetic.iphone.v1",
            "--evaluation-id", "evaluation.synthetic.performance.v1",
            "--output", output.path,
        ])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(
            try Data(contentsOf: output),
            try data("Fixtures/performance/evaluation/evaluation.v1.json")
        )
        let evaluation = try JSONSerialization.jsonObject(
            with: Data(contentsOf: output)
        ) as? [String: Any]
        XCTAssertEqual(
            evaluation?["overallOutcome"] as? String,
            try string(expected, "evaluationOutcome")
        )
        XCTAssertEqual(try integer(input, "schemaCount"), try integer(expected, "schemaCount"))
    }

    func testMetricsPrivacyApplicabilityAndGapFixture() throws {
        let input = try object(
            "Fixtures/requirements/T-018/metrics-privacy-applicability-gap-l5/input/input.v1.json"
        )
        let expected = try object(
            "Fixtures/requirements/T-018/metrics-privacy-applicability-gap-l5/expected.v1.json"
        )
        let canonicalUDID = try CanonicalUDID(
            canonicalString: try string(input, "canonicalUDID")
        )
        XCTAssertEqual(
            PerformanceMetricsExportV1.targetUDIDHash(canonicalUDID),
            try string(expected, "targetUDIDHash")
        )

        let denied = try JSONSerialization.data(
            withJSONObject: ["canonicalUDID": canonicalUDID.rawValue],
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let registry = try PerformanceMetricRegistryV1.load(repositoryRoot: repositoryRoot)
        let identity = try PerformanceMetricRegistryV1.identity(repositoryRoot: repositoryRoot)
        let measurement = try PerformanceMetricsExportV1.measurementProfileIdentity(
            canonicalBytes: [UInt8](try data(
                "Fixtures/performance/measurement-profile/profile.v1.json"
            ))
        )
        XCTAssertThrowsError(
            try PerformanceMetricsExportV1.validateCanonicalMetrics(
                [UInt8](denied),
                registry: registry,
                expectedContract: identity,
                expectedMeasurementProfile: measurement
            )
        )

        let observations = try registry.metrics.map { metric -> PerformanceObservationSeriesV1 in
            if metric.metricID == "touchDeliveryLatencyMs" {
                return try PerformanceObservationSeriesV1(
                    metricID: metric.metricID,
                    applicability: .notApplicable,
                    dataQuality: .complete,
                    samples: [],
                    notApplicableReasonCode: "noAcceptedTouchSamples"
                )
            }
            if metric.metricID == "videoReconnectMs" {
                return try PerformanceObservationSeriesV1(
                    metricID: metric.metricID,
                    applicability: .applicable,
                    dataQuality: .notRecovered,
                    samples: [],
                    unknownReasonCode: "videoNotRecovered"
                )
            }
            return try PerformanceObservationSeriesV1(
                metricID: metric.metricID,
                applicability: .applicable,
                dataQuality: .complete,
                samples: metric.comparator == .greaterThanOrEqual
                    ? [60_000]
                    : [metric.requiredRuleIDs[0].hasSuffix(".value") ? 1 : 10]
            )
        }
        let gates = try PerformanceMetricCollectorV1.collectGateValues(
            registry: registry,
            observations: observations
        )
        let thresholds = try thresholdRules(
            registry: registry,
            notApplicableRuleID: try string(input, "notApplicableRuleID")
        )
        let evaluation = try PerformanceEvaluatorV1.evaluate(
            registry: registry,
            gateValues: gates,
            thresholdRules: thresholds
        )
        let notApplicableRuleID = try string(input, "notApplicableRuleID")
        XCTAssertEqual(evaluation.overallOutcome.rawValue, try string(expected, "gapOutcome"))
        XCTAssertEqual(
            evaluation.ruleResults.first {
                $0.ruleID == notApplicableRuleID
            }?.outcome.rawValue,
            try string(expected, "notApplicableOutcome")
        )
        XCTAssertEqual(try bool(expected, "privacyDenied"), true)
    }

    func testCollectorUsesNearestRankIntegerScalingAndMonotonicTimestamps() throws {
        XCTAssertEqual(
            PerformanceMetricCollectorV1.nearestRank(
                percent: 5,
                samples: Array(1...20).map(Int64.init)
            ),
            1
        )
        XCTAssertEqual(
            PerformanceMetricCollectorV1.nearestRank(
                percent: 95,
                samples: Array(1...20).map(Int64.init)
            ),
            19
        )
        XCTAssertEqual(
            try PerformanceMetricCollectorV1.rssGrowthKiBPerHour(
                firstFiveMinuteSamplesKiB: [1000, 1000, 1000],
                lastFiveMinuteSamplesKiB: [2024, 2024, 2024],
                monotonicDurationMs: 3_600_000
            ),
            1024
        )
        XCTAssertEqual(
            try PerformanceTimestampIntervalV1(
                startedMonotonicNs: 1_000,
                endedMonotonicNs: 12_345
            ).microseconds,
            11
        )
        XCTAssertThrowsError(
            try PerformanceTimestampIntervalV1(
                startedMonotonicNs: 2,
                endedMonotonicNs: 1
            )
        )
    }

    func testThresholdEvaluationRecomputesPassFailAndUnknownWithoutTrustingExport() throws {
        let registry = try PerformanceMetricRegistryV1.load(repositoryRoot: repositoryRoot)
        let identity = try PerformanceMetricRegistryV1.identity(repositoryRoot: repositoryRoot)
        let measurement = try PerformanceMetricsExportV1.measurementProfileIdentity(
            canonicalBytes: [UInt8](try data(
                "Fixtures/performance/measurement-profile/profile.v1.json"
            ))
        )
        let bindings = try PerformanceMetricsExportV1.validateCanonicalMetrics(
            [UInt8](try data("Fixtures/performance/metrics-contract/threshold.metrics.v1.json")),
            registry: registry,
            expectedContract: identity,
            expectedMeasurementProfile: measurement
        )
        let thresholds = try thresholdRules(registry: registry)
        XCTAssertEqual(
            try PerformanceEvaluatorV1.evaluate(
                registry: registry,
                gateValues: bindings.gateValues,
                thresholdRules: thresholds
            ).overallOutcome,
            .passed
        )

        let failed = bindings.gateValues.map { gate in
            gate.ruleID == "previewFPS.p05"
                ? replacing(gate, observedScaledValue: 54_000)
                : gate
        }
        XCTAssertEqual(
            try PerformanceEvaluatorV1.evaluate(
                registry: registry,
                gateValues: failed,
                thresholdRules: thresholds
            ).overallOutcome,
            .failed
        )

        let unknown = bindings.gateValues.map { gate in
            gate.ruleID == "videoReconnectMs.p95"
                ? PerformanceGateValueV1(
                    ruleID: gate.ruleID,
                    metricID: gate.metricID,
                    statisticID: gate.statisticID,
                    canonicalUnitID: gate.canonicalUnitID,
                    applicability: .applicable,
                    dataQuality: .gap,
                    observedScaledValue: nil,
                    sampleCount: 0,
                    notApplicableReasonCode: nil,
                    unknownReasonCode: "metricsGap"
                )
                : gate
        }
        XCTAssertEqual(
            try PerformanceEvaluatorV1.evaluate(
                registry: registry,
                gateValues: unknown,
                thresholdRules: thresholds
            ).overallOutcome,
            .unknown
        )
    }

    func testThresholdFreezeFixtureBindsDecisionProfileApprovalAndThreeBaselines() throws {
        let input = try object(
            "Fixtures/requirements/T-018/performance-threshold-freeze-l5/input/input.v1.json"
        )
        let expected = try object(
            "Fixtures/requirements/T-018/performance-threshold-freeze-l5/expected.v1.json"
        )
        let decisionData = try data(try string(input, "decisionPath"))
        let profileData = try data(try string(input, "profilePath"))
        let approval = try object(try string(input, "approvalPath"))
        XCTAssertEqual(
            try StableBytes.domainSeparatedSHA256Hex(
                domainID: "pulsephone.performance-threshold-decision.v1",
                payload: decisionData
            ),
            try string(expected, "decisionHash")
        )
        XCTAssertEqual(
            try StableBytes.domainSeparatedSHA256Hex(
                domainID: "pulsephone.performance-threshold-profile.v1",
                payload: profileData
            ),
            try string(expected, "profileHash")
        )
        XCTAssertEqual(
            approval["thresholdDecisionHash"] as? String,
            try string(expected, "decisionHash")
        )
        XCTAssertEqual(
            approval["thresholdProfileHash"] as? String,
            try string(expected, "profileHash")
        )
        XCTAssertEqual(
            approval["baselineEvidenceRunIDs"] as? [String],
            try strings(expected, "baselineEvidenceRunIDs")
        )
        let profile = try JSONSerialization.jsonObject(with: profileData) as? [String: Any]
        let sets = profile?["thresholdSets"] as? [[String: Any]]
        XCTAssertEqual(sets?.count, try integer(expected, "thresholdSetCount"))
        XCTAssertEqual(
            (sets?.first?["baselineRuns"] as? [[String: Any]])?.count,
            try integer(input, "minimumBaselineRuns")
        )
        XCTAssertTrue(try bool(expected, "replaceWholeBaselineSetOnRunnerChange"))
    }

    func testPerformanceEvidenceSelfTestClosesRegistryAndSchemaSet() throws {
        let result = try runTool(["self-test"])
        XCTAssertEqual(result.status, 0, result.output)
        let value = try JSONSerialization.jsonObject(
            with: Data(result.output.dropLast().utf8)
        ) as? [String: Any]
        XCTAssertEqual(value?["outcome"] as? String, "passed")
        XCTAssertEqual(value?["tests"] as? Int, 13)
    }

    func testPackagedCandidateCollectionPublishesAuditableUnknown() throws {
        let package = try runProcess(
            executable: "Scripts/package-app",
            arguments: ["--objects-root", "build/evidence/objects"]
        )
        XCTAssertEqual(package.status, 0, package.error)
        let packageResult = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(package.output.utf8))
                as? [String: Any]
        )
        let candidateInput = try string(packageResult, "path")
        let target = "00008110-001A7D523E90401E"
        let collection = try runTool([
            "collect",
            "--candidate-input", candidateInput,
            "--target-udid", target,
            "--minimum-duration-ms", "1000",
            "--required-reconnect-count", "0",
            "--evaluation-mode", "baseline",
            "--measurement-profile-id", "measurement.packaged-smoke.v1",
            "--evidence-environment-profile-id", "environment.packaged-smoke.v1",
            "--evidence-environment-profile-hash", String(repeating: "a", count: 64),
            "--reconnect-profile-id", "reconnect.packaged-smoke.v1",
            "--reconnect-profile-hash", String(repeating: "b", count: 64),
            "--objects-root", "build/evidence/objects",
        ])
        XCTAssertEqual(collection.status, 0, collection.output)
        let result = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(collection.output.utf8))
                as? [String: Any]
        )
        XCTAssertEqual(result["schemaVersion"] as? Int, 1)
        XCTAssertEqual(
            result["candidateInputHash"] as? String,
            packageResult["releaseCandidateInputHash"] as? String
        )
        let artifacts = try XCTUnwrap(result["artifacts"] as? [[String: Any]])
        XCTAssertEqual(
            artifacts.compactMap { $0["artifactDomain"] as? String },
            ["performanceMeasurementProfile", "performanceMetrics"]
        )
        let metricsArtifact = try XCTUnwrap(artifacts.last)
        let metricsPath = repositoryRoot.appendingPathComponent(
            try string(metricsArtifact, "path")
        )
        let metricsData = try Data(contentsOf: metricsPath)
        let metrics = try XCTUnwrap(
            JSONSerialization.jsonObject(with: metricsData) as? [String: Any]
        )
        let stability = try XCTUnwrap(metrics["stability"] as? [String: Any])
        XCTAssertEqual(stability["passed"] as? Bool, false)
        let gates = try XCTUnwrap(metrics["gateValues"] as? [[String: Any]])
        XCTAssertTrue(gates.contains { $0["dataQuality"] as? String == "gap" })
        XCTAssertFalse(String(decoding: metricsData, as: UTF8.self).contains(target))

        let mappedCollection = try runTool([
            "collect",
            "--candidate-input", candidateInput,
            "--target-udid", target,
            "--minimum-duration-ms", "1000",
            "--required-reconnect-count", "0",
            "--evaluation-mode", "baseline",
            "--measurement-profile-id", "measurement.packaged-video.v1",
            "--evidence-environment-profile-id", "environment.packaged-video.v1",
            "--evidence-environment-profile-hash", String(repeating: "c", count: 64),
            "--reconnect-profile-id", "reconnect.packaged-video.v1",
            "--reconnect-profile-hash", String(repeating: "d", count: 64),
            "--video-connection-epoch", "7",
            "--video-device-os-build", "23F84",
            "--video-device-product-type", "iPhone14,7",
            "--video-display-refresh-rate-millihz", "60000",
            "--video-geometry-revision", "9",
            "--video-logical-height", "2532",
            "--video-logical-width", "1170",
            "--video-mapping-proof-id", "proof.packaged-video",
            "--video-orientation", "portrait",
            "--video-source-epoch", "11",
            "--video-source-id", String(repeating: "e", count: 64),
            "--video-window-height-pixels", "780",
            "--video-window-width-pixels", "430",
            "--objects-root", "build/evidence/objects",
        ])
        XCTAssertEqual(mappedCollection.status, 0, mappedCollection.output)
        let mappedResult = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(mappedCollection.output.utf8))
                as? [String: Any]
        )
        let mappedArtifacts = try XCTUnwrap(
            mappedResult["artifacts"] as? [[String: Any]]
        )
        let mappedMetricsPath = repositoryRoot.appendingPathComponent(
            try string(try XCTUnwrap(mappedArtifacts.last), "path")
        )
        let mappedMetrics = try XCTUnwrap(
            JSONSerialization.jsonObject(
                with: Data(contentsOf: mappedMetricsPath)
            ) as? [String: Any]
        )
        let connectionEpochs = try XCTUnwrap(
            mappedMetrics["connectionEpochs"] as? [Int]
        )
        XCTAssertEqual(connectionEpochs, connectionEpochs.sorted())
        XCTAssertEqual(Set(connectionEpochs).count, connectionEpochs.count)
        XCTAssertTrue(connectionEpochs.allSatisfy { $0 > 0 })
        XCTAssertEqual((mappedMetrics["sourceEpochs"] as? [Any])?.count, 0)
        XCTAssertEqual(mappedMetrics["iOSBuild"] as? String, "unknown")
        XCTAssertEqual(mappedMetrics["productType"] as? String, "unknown")
        let excluded = try XCTUnwrap(
            mappedMetrics["excludedSegments"] as? [[String: Any]]
        )
        XCTAssertEqual(excluded.first?["reasonCode"] as? String, "sourceUnbound")
    }

    func testPerformanceEvidenceRejectsPartialVideoMappingBeforeCandidateAccess() throws {
        let collection = try runTool([
            "collect",
            "--candidate-input", "/does/not/exist",
            "--target-udid", "M3012-PARTIAL-VIDEO",
            "--minimum-duration-ms", "1000",
            "--required-reconnect-count", "0",
            "--evaluation-mode", "baseline",
            "--measurement-profile-id", "measurement.partial-video.v1",
            "--evidence-environment-profile-id", "environment.partial-video.v1",
            "--evidence-environment-profile-hash", String(repeating: "a", count: 64),
            "--reconnect-profile-id", "reconnect.partial-video.v1",
            "--reconnect-profile-hash", String(repeating: "b", count: 64),
            "--video-source-id", String(repeating: "c", count: 64),
            "--objects-root", "build/evidence/objects",
        ])
        XCTAssertEqual(collection.status, 2)
        XCTAssertTrue(collection.output.contains("video mapping arguments"))
        XCTAssertFalse(collection.output.contains("No such file"))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func data(_ relativePath: String) throws -> Data {
        try Data(contentsOf: repositoryRoot.appendingPathComponent(relativePath))
    }

    private func object(_ relativePath: String) throws -> [String: Any] {
        try XCTUnwrap(
            JSONSerialization.jsonObject(with: data(relativePath)) as? [String: Any]
        )
    }

    private func string(_ object: [String: Any], _ key: String) throws -> String {
        try XCTUnwrap(object[key] as? String, key)
    }

    private func integer(_ object: [String: Any], _ key: String) throws -> Int {
        try XCTUnwrap(object[key] as? Int, key)
    }

    private func bool(_ object: [String: Any], _ key: String) throws -> Bool {
        try XCTUnwrap(object[key] as? Bool, key)
    }

    private func strings(_ object: [String: Any], _ key: String) throws -> [String] {
        try XCTUnwrap(object[key] as? [String], key)
    }

    private func runTool(_ arguments: [String]) throws -> (status: Int32, output: String) {
        let result = try runProcess(
            executable: "Scripts/performance-evidence",
            arguments: arguments
        )
        return (result.status, result.output + result.error)
    }

    private func runProcess(
        executable: String,
        arguments: [String]
    ) throws -> (status: Int32, output: String, error: String) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-performance-process-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let outputURL = root.appendingPathComponent("stdout")
        let errorURL = root.appendingPathComponent("stderr")
        XCTAssertTrue(FileManager.default.createFile(atPath: outputURL.path, contents: nil))
        XCTAssertTrue(FileManager.default.createFile(atPath: errorURL.path, contents: nil))
        let output = try FileHandle(forWritingTo: outputURL)
        let error = try FileHandle(forWritingTo: errorURL)
        let process = Process()
        process.currentDirectoryURL = repositoryRoot
        process.executableURL = repositoryRoot.appendingPathComponent(executable)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        try output.close()
        try error.close()
        return (
            process.terminationStatus,
            String(decoding: try Data(contentsOf: outputURL), as: UTF8.self),
            String(decoding: try Data(contentsOf: errorURL), as: UTF8.self)
        )
    }

    private func thresholdRules(
        registry: PerformanceMetricRegistryV1,
        notApplicableRuleID: String? = nil
    ) throws -> [PerformanceThresholdRuleV1] {
        let limits: [String: Int64] = [
            "controlReconnectMs.p95": 1_000_000,
            "cpuTotalPercent.p95": 50_000,
            "hostVideoPipelineLatencyMs.p95": 20_000,
            "previewFPS.p05": 55_000,
            "rssGrowthMiBPerHour.value": 4_096,
            "rssTotalMiB.p95": 524_288,
            "touchDeliveryLatencyMs.p95": 30_000,
            "videoReconnectMs.p95": 1_500_000,
        ]
        return try registry.requiredRuleIDs.map { ruleID in
            let (metric, statisticID) = try XCTUnwrap(registry.rule(ruleID: ruleID))
            if ruleID == notApplicableRuleID {
                return try PerformanceThresholdRuleV1(
                    ruleID: ruleID,
                    requirementID: "T-018/performance-threshold-evaluation-l5",
                    metricID: metric.metricID,
                    statisticID: statisticID,
                    applicability: .notApplicable,
                    notApplicableReasonCode: "noAcceptedTouchSamples"
                )
            }
            return try PerformanceThresholdRuleV1(
                ruleID: ruleID,
                requirementID: "T-018/performance-threshold-evaluation-l5",
                metricID: metric.metricID,
                statisticID: statisticID,
                applicability: .applicable,
                comparator: metric.comparator,
                canonicalUnitID: metric.canonicalUnitID,
                limitScaledValue: try XCTUnwrap(limits[ruleID])
            )
        }
    }

    private func replacing(
        _ gate: PerformanceGateValueV1,
        observedScaledValue: Int64
    ) -> PerformanceGateValueV1 {
        PerformanceGateValueV1(
            ruleID: gate.ruleID,
            metricID: gate.metricID,
            statisticID: gate.statisticID,
            canonicalUnitID: gate.canonicalUnitID,
            applicability: gate.applicability,
            dataQuality: gate.dataQuality,
            observedScaledValue: observedScaledValue,
            sampleCount: gate.sampleCount,
            notApplicableReasonCode: gate.notApplicableReasonCode,
            unknownReasonCode: gate.unknownReasonCode
        )
    }
}
