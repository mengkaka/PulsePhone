import Foundation
import PulsePhoneSharedDefinitions

public enum PerformanceContractError: Error, Equatable, Sendable {
    case duplicateIdentifier(String)
    case integerOverflow
    case invalidApplicability
    case invalidCanonicalDocument
    case invalidContractIdentity
    case invalidDataQuality
    case invalidMetric(String)
    case invalidRule(String)
    case invalidStatistic(String)
    case missingSamples(String)
    case samplesNotAllowed(String)
    case unsortedIdentifiers
}

public enum PerformanceComparatorV1: String, Equatable, Sendable {
    case greaterThanOrEqual
    case lessThanOrEqual
}

public enum PerformanceApplicabilityV1: String, Equatable, Sendable {
    case applicable
    case notApplicable
}

public enum PerformanceDataQualityV1: String, Equatable, Sendable {
    case complete
    case gap
    case notRecovered
}

public struct PerformanceContractIdentityV1: Equatable, Sendable {
    public static let domainID = "pulsephone.performance-contract-artifact-set.v1"
    public static let setID = "performanceContract"

    public let revision: String
    public let sha256: String

    public init(revision: String, sha256: String) throws {
        guard !revision.isEmpty,
              revision.utf8.count <= 128,
              StableBytes.isLowercaseHex(sha256, byteCount: 32)
        else {
            throw PerformanceContractError.invalidContractIdentity
        }
        self.revision = revision
        self.sha256 = sha256
    }
}

public struct PerformanceMetricDescriptorV1: Equatable, Sendable {
    public let metricID: String
    public let allowedStatisticIDs: [String]
    public let requiredRuleIDs: [String]
    public let comparator: PerformanceComparatorV1
    public let canonicalUnitID: String
    public let applicabilityRuleID: String
    public let collectorContractVersion: String
    public let evaluatorContractVersion: String

    public func statisticID(for ruleID: String) throws -> String {
        let prefix = metricID + "."
        guard ruleID.hasPrefix(prefix) else {
            throw PerformanceContractError.invalidRule(ruleID)
        }
        let statisticID = String(ruleID.dropFirst(prefix.count))
        guard allowedStatisticIDs.contains(statisticID) else {
            throw PerformanceContractError.invalidStatistic(statisticID)
        }
        return statisticID
    }
}

public struct PerformanceMetricRegistryV1: Equatable, Sendable {
    public static let relativePath = "Registries/performance-metrics.v1.json"
    public static let revision = "performance-metrics.v1-20260720"
    public static let artifactPaths = [
        "Registries/performance-metrics.v1.json",
        "Schemas/evidence/performance-evaluation.v1.schema.json",
        "Schemas/evidence/performance-measurement-profile.v1.schema.json",
        "Schemas/evidence/performance-threshold-approval.v1.schema.json",
        "Schemas/evidence/performance-threshold-decision.v1.schema.json",
        "Schemas/evidence/performance-threshold-profile.v1.schema.json",
        "Schemas/evidence/pulsephone.metrics.v1.schema.json",
    ]

    public let revision: String
    public let metrics: [PerformanceMetricDescriptorV1]

    public static func load(repositoryRoot: URL) throws -> Self {
        let data = try Data(
            contentsOf: repositoryRoot.appendingPathComponent(relativePath)
        )
        let document = try RepositoryCanonicalJSON.validateCanonicalDocument(
            [UInt8](data),
            maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
        )
        return try decode(document.root)
    }

    public static func identity(repositoryRoot: URL) throws -> PerformanceContractIdentityV1 {
        let registry = try load(repositoryRoot: repositoryRoot)
        let artifactSet = try RepositoryContractResolver.resolve(
            repositoryRoot: repositoryRoot,
            setID: PerformanceContractIdentityV1.setID,
            revision: registry.revision,
            relativePaths: artifactPaths
        )
        return try PerformanceContractIdentityV1(
            revision: registry.revision,
            sha256: artifactSet.domainSeparatedHash(
                domainID: PerformanceContractIdentityV1.domainID
            )
        )
    }

    public func descriptor(metricID: String) -> PerformanceMetricDescriptorV1? {
        metrics.first { $0.metricID == metricID }
    }

    public func rule(ruleID: String) -> (PerformanceMetricDescriptorV1, String)? {
        for metric in metrics where metric.requiredRuleIDs.contains(ruleID) {
            guard let statisticID = try? metric.statisticID(for: ruleID) else {
                return nil
            }
            return (metric, statisticID)
        }
        return nil
    }

    public var requiredRuleIDs: [String] {
        metrics.flatMap(\.requiredRuleIDs).sorted(by: Self.asciiLessThan)
    }

    private static func decode(_ root: RepositoryJSONObject) throws -> Self {
        guard root.members.map(\.key).sorted(by: asciiLessThan) == [
            "metrics", "revision", "schemaVersion",
        ],
        try integer(root, "schemaVersion") == 1,
        let revision = root["revision"]?.stringValue,
        revision == Self.revision,
        let rows = root["metrics"]?.arrayValue
        else {
            throw PerformanceContractError.invalidCanonicalDocument
        }

        var metrics = [PerformanceMetricDescriptorV1]()
        for value in rows {
            guard let row = value.objectValue,
                  row.members.map(\.key).sorted(by: asciiLessThan) == [
                    "allowedStatisticIDs",
                    "applicabilityRuleID",
                    "canonicalUnitID",
                    "collectorContractVersion",
                    "comparator",
                    "evaluatorContractVersion",
                    "metricID",
                    "requiredRuleIDs",
                  ],
                  let metricID = row["metricID"]?.stringValue,
                  let comparatorValue = row["comparator"]?.stringValue,
                  let comparator = PerformanceComparatorV1(rawValue: comparatorValue),
                  let canonicalUnitID = row["canonicalUnitID"]?.stringValue,
                  let applicabilityRuleID = row["applicabilityRuleID"]?.stringValue,
                  let collectorContractVersion = row["collectorContractVersion"]?.stringValue,
                  let evaluatorContractVersion = row["evaluatorContractVersion"]?.stringValue
            else {
                throw PerformanceContractError.invalidCanonicalDocument
            }
            let statisticIDs = try strings(row, "allowedStatisticIDs")
            let ruleIDs = try strings(row, "requiredRuleIDs")
            guard isSortedUnique(statisticIDs), isSortedUnique(ruleIDs),
                  !statisticIDs.isEmpty, !ruleIDs.isEmpty,
                  (ruleIDs.allSatisfy { ruleID in
                    let prefix = metricID + "."
                    return ruleID.hasPrefix(prefix)
                        && statisticIDs.contains(String(ruleID.dropFirst(prefix.count)))
                  })
            else {
                throw PerformanceContractError.unsortedIdentifiers
            }
            metrics.append(PerformanceMetricDescriptorV1(
                metricID: metricID,
                allowedStatisticIDs: statisticIDs,
                requiredRuleIDs: ruleIDs,
                comparator: comparator,
                canonicalUnitID: canonicalUnitID,
                applicabilityRuleID: applicabilityRuleID,
                collectorContractVersion: collectorContractVersion,
                evaluatorContractVersion: evaluatorContractVersion
            ))
        }
        let metricIDs = metrics.map(\.metricID)
        guard isSortedUnique(metricIDs),
              Set(metrics.flatMap(\.requiredRuleIDs)).count
                == metrics.flatMap(\.requiredRuleIDs).count
        else {
            throw PerformanceContractError.duplicateIdentifier("metric or rule")
        }
        return Self(revision: revision, metrics: metrics)
    }

    private static func strings(
        _ object: RepositoryJSONObject,
        _ key: String
    ) throws -> [String] {
        guard let values = object[key]?.arrayValue else {
            throw PerformanceContractError.invalidCanonicalDocument
        }
        return try values.map { value in
            guard let string = value.stringValue else {
                throw PerformanceContractError.invalidCanonicalDocument
            }
            return string
        }
    }

    private static func integer(
        _ object: RepositoryJSONObject,
        _ key: String
    ) throws -> UInt64 {
        guard let number = object[key]?.numberValue else {
            throw PerformanceContractError.invalidCanonicalDocument
        }
        return try number.requireUInt64()
    }

    private static func isSortedUnique(_ values: [String]) -> Bool {
        values == values.sorted(by: asciiLessThan) && Set(values).count == values.count
    }

    static func asciiLessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}

public struct PerformanceObservationSeriesV1: Equatable, Sendable {
    public let metricID: String
    public let applicability: PerformanceApplicabilityV1
    public let dataQuality: PerformanceDataQualityV1
    public let samples: [Int64]
    public let notApplicableReasonCode: String?
    public let unknownReasonCode: String?

    public init(
        metricID: String,
        applicability: PerformanceApplicabilityV1,
        dataQuality: PerformanceDataQualityV1,
        samples: [Int64],
        notApplicableReasonCode: String? = nil,
        unknownReasonCode: String? = nil
    ) throws {
        switch (applicability, dataQuality) {
        case (.applicable, .complete):
            guard !samples.isEmpty,
                  notApplicableReasonCode == nil,
                  unknownReasonCode == nil
            else {
                throw PerformanceContractError.missingSamples(metricID)
            }
        case (.applicable, .gap), (.applicable, .notRecovered):
            guard samples.isEmpty,
                  notApplicableReasonCode == nil,
                  unknownReasonCode?.isEmpty == false
            else {
                throw PerformanceContractError.invalidDataQuality
            }
        case (.notApplicable, .complete):
            guard samples.isEmpty,
                  notApplicableReasonCode?.isEmpty == false,
                  unknownReasonCode == nil
            else {
                throw PerformanceContractError.invalidApplicability
            }
        case (.notApplicable, .gap), (.notApplicable, .notRecovered):
            throw PerformanceContractError.invalidApplicability
        }
        self.metricID = metricID
        self.applicability = applicability
        self.dataQuality = dataQuality
        self.samples = samples
        self.notApplicableReasonCode = notApplicableReasonCode
        self.unknownReasonCode = unknownReasonCode
    }
}

public struct PerformanceGateValueV1: Equatable, Sendable {
    public let ruleID: String
    public let metricID: String
    public let statisticID: String
    public let canonicalUnitID: String
    public let applicability: PerformanceApplicabilityV1
    public let dataQuality: PerformanceDataQualityV1
    public let observedScaledValue: Int64?
    public let sampleCount: UInt64
    public let notApplicableReasonCode: String?
    public let unknownReasonCode: String?
}

public struct PerformanceTimestampIntervalV1: Equatable, Sendable {
    public let startedMonotonicNs: UInt64
    public let endedMonotonicNs: UInt64

    public init(startedMonotonicNs: UInt64, endedMonotonicNs: UInt64) throws {
        guard endedMonotonicNs >= startedMonotonicNs else {
            throw PerformanceContractError.invalidDataQuality
        }
        self.startedMonotonicNs = startedMonotonicNs
        self.endedMonotonicNs = endedMonotonicNs
    }

    public var microseconds: Int64 {
        Int64((endedMonotonicNs - startedMonotonicNs) / 1_000)
    }
}

public enum PerformanceMetricCollectorV1 {
    public static func collectGateValues(
        registry: PerformanceMetricRegistryV1,
        observations: [PerformanceObservationSeriesV1]
    ) throws -> [PerformanceGateValueV1] {
        let observationIDs = observations.map(\.metricID)
        guard Set(observationIDs).count == observationIDs.count else {
            throw PerformanceContractError.duplicateIdentifier("observation")
        }
        let byMetric = Dictionary(uniqueKeysWithValues: observations.map { ($0.metricID, $0) })
        var values = [PerformanceGateValueV1]()
        for ruleID in registry.requiredRuleIDs {
            guard let (metric, statisticID) = registry.rule(ruleID: ruleID) else {
                throw PerformanceContractError.invalidRule(ruleID)
            }
            guard let observation = byMetric[metric.metricID] else {
                throw PerformanceContractError.invalidMetric(metric.metricID)
            }
            let observed: Int64?
            if observation.applicability == .applicable,
               observation.dataQuality == .complete
            {
                observed = try statistic(statisticID, samples: observation.samples)
            } else {
                observed = nil
            }
            values.append(PerformanceGateValueV1(
                ruleID: ruleID,
                metricID: metric.metricID,
                statisticID: statisticID,
                canonicalUnitID: metric.canonicalUnitID,
                applicability: observation.applicability,
                dataQuality: observation.dataQuality,
                observedScaledValue: observed,
                sampleCount: UInt64(observation.samples.count),
                notApplicableReasonCode: observation.notApplicableReasonCode,
                unknownReasonCode: observation.unknownReasonCode
            ))
        }
        return values
    }

    public static func statistic(
        _ statisticID: String,
        samples: [Int64]
    ) throws -> Int64 {
        guard !samples.isEmpty else {
            throw PerformanceContractError.missingSamples(statisticID)
        }
        switch statisticID {
        case "max", "wholeRunMax":
            return samples.max()!
        case "min":
            return samples.min()!
        case "p05":
            return nearestRank(percent: 5, samples: samples)
        case "p50":
            return nearestRank(percent: 50, samples: samples)
        case "p95":
            return nearestRank(percent: 95, samples: samples)
        case "p99":
            return nearestRank(percent: 99, samples: samples)
        case "value":
            guard samples.count == 1 else {
                throw PerformanceContractError.invalidStatistic(statisticID)
            }
            return samples[0]
        default:
            throw PerformanceContractError.invalidStatistic(statisticID)
        }
    }

    public static func nearestRank(
        percent: Int,
        samples: [Int64]
    ) -> Int64 {
        precondition((1...100).contains(percent) && !samples.isEmpty)
        let sorted = samples.sorted()
        let numerator = percent * sorted.count
        let rank = max(1, (numerator + 99) / 100)
        return sorted[rank - 1]
    }

    public static func rssGrowthKiBPerHour(
        firstFiveMinuteSamplesKiB: [Int64],
        lastFiveMinuteSamplesKiB: [Int64],
        monotonicDurationMs: UInt64
    ) throws -> Int64 {
        guard monotonicDurationMs >= 600_000,
              !firstFiveMinuteSamplesKiB.isEmpty,
              !lastFiveMinuteSamplesKiB.isEmpty,
              monotonicDurationMs <= UInt64(Int64.max)
        else {
            throw PerformanceContractError.invalidDataQuality
        }
        let first = try statistic("p50", samples: firstFiveMinuteSamplesKiB)
        let last = try statistic("p50", samples: lastFiveMinuteSamplesKiB)
        let (delta, subtractionOverflow) = last.subtractingReportingOverflow(first)
        guard !subtractionOverflow else {
            throw PerformanceContractError.integerOverflow
        }
        let (deltaProduct, overflow) = delta.multipliedReportingOverflow(
            by: 3_600_000
        )
        guard !overflow else {
            throw PerformanceContractError.integerOverflow
        }
        return deltaProduct / Int64(monotonicDurationMs)
    }
}
