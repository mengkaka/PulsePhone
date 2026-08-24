import Foundation
import PulsePhoneSharedDefinitions

public struct PerformanceMeasurementProfileIdentityV1: Equatable, Sendable {
    public static let domainID = "pulsephone.performance-measurement-profile.v1"

    public let profileID: String
    public let profileHash: String

    public init(profileID: String, profileHash: String) throws {
        guard !profileID.isEmpty,
              profileID.utf8.count <= 128,
              StableBytes.isLowercaseHex(profileHash, byteCount: 32)
        else {
            throw PerformanceContractError.invalidContractIdentity
        }
        self.profileID = profileID
        self.profileHash = profileHash
    }
}

public struct PerformanceMetricsBindingsV1: Equatable, Sendable {
    public let performanceContract: PerformanceContractIdentityV1
    public let evaluationMode: String
    public let measurementProfile: PerformanceMeasurementProfileIdentityV1
    public let thresholdProfileID: String?
    public let thresholdProfileHash: String?
    public let thresholdSetID: String?
    public let targetUDIDHash: String
    public let gateValues: [PerformanceGateValueV1]
}

public enum PerformanceMetricsExportV1 {
    public static let measurementProfileMaximumBytes = 64 * 1024 * 1024

    public static func measurementProfileIdentity(
        canonicalBytes: [UInt8]
    ) throws -> PerformanceMeasurementProfileIdentityV1 {
        let document = try RepositoryCanonicalJSON.validateCanonicalDocument(
            canonicalBytes,
            maximumByteCount: measurementProfileMaximumBytes
        )
        guard document.root["schemaVersion"]?.numberValue.flatMap({
            try? $0.requireUInt64()
        }) == 1,
        let profileID = document.root["profileID"]?.stringValue
        else {
            throw PerformanceContractError.invalidCanonicalDocument
        }
        return try PerformanceMeasurementProfileIdentityV1(
            profileID: profileID,
            profileHash: document.domainSeparatedSHA256Hex(
                domainID: PerformanceMeasurementProfileIdentityV1.domainID
            )
        )
    }

    public static func targetUDIDHash(_ canonicalUDID: CanonicalUDID) -> String {
        canonicalUDID.domainSeparatedHash
    }

    public static func validateCanonicalMetrics(
        _ bytes: [UInt8],
        registry: PerformanceMetricRegistryV1,
        expectedContract: PerformanceContractIdentityV1,
        expectedMeasurementProfile: PerformanceMeasurementProfileIdentityV1
    ) throws -> PerformanceMetricsBindingsV1 {
        let document = try RepositoryCanonicalJSON.validateCanonicalDocument(
            bytes,
            maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
        )
        let root = document.root
        try rejectPrivateKeys(root)
        guard try uint(root, "schemaVersion") == 1,
              let mode = root["evaluationMode"]?.stringValue,
              mode == "baseline" || mode == "threshold",
              let targetUDIDHash = root["targetUDIDHash"]?.stringValue,
              StableBytes.isLowercaseHex(targetUDIDHash, byteCount: 32),
              try bool(root, "metricsEnabled"),
              let contractObject = root["performanceContract"]?.objectValue,
              let contractRevision = contractObject["revision"]?.stringValue,
              let contractHash = contractObject["sha256"]?.stringValue,
              contractRevision == expectedContract.revision,
              contractHash == expectedContract.sha256,
              root["measurementProfileID"]?.stringValue
                == expectedMeasurementProfile.profileID,
              root["measurementProfileHash"]?.stringValue
                == expectedMeasurementProfile.profileHash
        else {
            throw PerformanceContractError.invalidContractIdentity
        }

        let thresholdProfileID = root["thresholdProfileID"]?.stringValue
        let thresholdProfileHash = root["thresholdProfileHash"]?.stringValue
        let thresholdSetID = root["thresholdSetID"]?.stringValue
        if mode == "baseline" {
            guard thresholdProfileID == nil,
                  thresholdProfileHash == nil,
                  thresholdSetID == nil
            else {
                throw PerformanceContractError.invalidContractIdentity
            }
        } else {
            guard thresholdProfileID?.isEmpty == false,
                  thresholdSetID?.isEmpty == false,
                  let thresholdProfileHash,
                  StableBytes.isLowercaseHex(thresholdProfileHash, byteCount: 32)
            else {
                throw PerformanceContractError.invalidContractIdentity
            }
        }

        guard let rows = root["gateValues"]?.arrayValue else {
            throw PerformanceContractError.invalidCanonicalDocument
        }
        let gateValues = try rows.map(parseGateValue)
        guard gateValues.map(\.ruleID) == registry.requiredRuleIDs else {
            throw PerformanceContractError.unsortedIdentifiers
        }
        for gateValue in gateValues {
            guard let (metric, statisticID) = registry.rule(ruleID: gateValue.ruleID),
                  gateValue.metricID == metric.metricID,
                  gateValue.statisticID == statisticID,
                  gateValue.canonicalUnitID == metric.canonicalUnitID
            else {
                throw PerformanceContractError.invalidRule(gateValue.ruleID)
            }
        }
        return PerformanceMetricsBindingsV1(
            performanceContract: expectedContract,
            evaluationMode: mode,
            measurementProfile: expectedMeasurementProfile,
            thresholdProfileID: thresholdProfileID,
            thresholdProfileHash: thresholdProfileHash,
            thresholdSetID: thresholdSetID,
            targetUDIDHash: targetUDIDHash,
            gateValues: gateValues
        )
    }

    private static func parseGateValue(
        _ value: RepositoryJSONValue
    ) throws -> PerformanceGateValueV1 {
        guard let row = value.objectValue,
              let ruleID = row["ruleID"]?.stringValue,
              let metricID = row["metricID"]?.stringValue,
              let statisticID = row["statisticID"]?.stringValue,
              let canonicalUnitID = row["canonicalUnitID"]?.stringValue,
              let applicabilityValue = row["applicability"]?.stringValue,
              let applicability = PerformanceApplicabilityV1(
                rawValue: applicabilityValue
              ),
              let qualityValue = row["dataQuality"]?.stringValue,
              let dataQuality = PerformanceDataQualityV1(rawValue: qualityValue)
        else {
            throw PerformanceContractError.invalidCanonicalDocument
        }
        let observed = try optionalInt(row, "observedScaledValue")
        let sampleCount = try uint(row, "sampleCount")
        let notApplicableReason = row["notApplicableReasonCode"]?.stringValue
        let unknownReason = row["unknownReasonCode"]?.stringValue
        switch (applicability, dataQuality) {
        case (.applicable, .complete):
            guard observed != nil,
                  notApplicableReason == nil,
                  unknownReason == nil,
                  sampleCount > 0
            else {
                throw PerformanceContractError.invalidDataQuality
            }
        case (.applicable, .gap), (.applicable, .notRecovered):
            guard observed == nil,
                  sampleCount == 0,
                  notApplicableReason == nil,
                  unknownReason?.isEmpty == false
            else {
                throw PerformanceContractError.invalidDataQuality
            }
        case (.notApplicable, .complete):
            guard observed == nil,
                  sampleCount == 0,
                  notApplicableReason?.isEmpty == false,
                  unknownReason == nil
            else {
                throw PerformanceContractError.invalidApplicability
            }
        case (.notApplicable, .gap), (.notApplicable, .notRecovered):
            throw PerformanceContractError.invalidApplicability
        }
        return PerformanceGateValueV1(
            ruleID: ruleID,
            metricID: metricID,
            statisticID: statisticID,
            canonicalUnitID: canonicalUnitID,
            applicability: applicability,
            dataQuality: dataQuality,
            observedScaledValue: observed,
            sampleCount: sampleCount,
            notApplicableReasonCode: notApplicableReason,
            unknownReasonCode: unknownReason
        )
    }

    private static func rejectPrivateKeys(_ object: RepositoryJSONObject) throws {
        let denied = Set([
            "canonicalUDID", "coordinates", "deviceName", "ecid", "hidUsage",
            "keyboardFrame", "pairingRecord", "pressedSet", "rawUDID", "serial",
            "text", "userText",
        ])
        for member in object.members {
            guard !denied.contains(member.key) else {
                throw PerformanceContractError.invalidCanonicalDocument
            }
            try rejectPrivateValue(member.value)
        }
    }

    private static func rejectPrivateValue(_ value: RepositoryJSONValue) throws {
        switch value {
        case .object(let object):
            try rejectPrivateKeys(object)
        case .array(let values):
            for child in values {
                try rejectPrivateValue(child)
            }
        default:
            break
        }
    }

    private static func uint(
        _ object: RepositoryJSONObject,
        _ key: String
    ) throws -> UInt64 {
        guard let number = object[key]?.numberValue else {
            throw PerformanceContractError.invalidCanonicalDocument
        }
        return try number.requireUInt64()
    }

    private static func bool(
        _ object: RepositoryJSONObject,
        _ key: String
    ) throws -> Bool {
        guard case .bool(let value)? = object[key] else {
            throw PerformanceContractError.invalidCanonicalDocument
        }
        return value
    }

    private static func optionalInt(
        _ object: RepositoryJSONObject,
        _ key: String
    ) throws -> Int64? {
        guard let value = object[key] else { return nil }
        guard let number = value.numberValue else {
            throw PerformanceContractError.invalidCanonicalDocument
        }
        return try number.requireInt64()
    }
}
