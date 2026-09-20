import Foundation
import PulsePhoneSharedDefinitions

public enum PreparationProgressValidationError: Error, Equatable, Sendable {
    case invalidGroupID
    case invalidByteProgress
    case invalidFraction
    case invalidSourceKind
}

public enum PreparationWirePhase: String, CaseIterable, Equatable, Sendable {
    case checkingDevice
    case deviceClaimWait
    case downloading
    case extracting
    case mounting
    case personalizing
    case probingServices
    case queryingMountedImage
    case ready
    case resolvingDeveloperSupport
    case startingDeviceServices
    case uploading
    case validating
    case waitingForAcquisitionSlot
    case waitingForSharedAcquisition
}

public enum PreparationProgressSourceKind: String, CaseIterable, Equatable, Sendable {
    case approvedRemote
    case mountedUnknown
    case xcode
}

public struct PreparationProgressV1: Equatable, Sendable {
    public let completedBytes: UInt64?
    public let fraction: Double?
    public let phase: PreparationWirePhase
    public let phaseSequence: UInt64
    public let preparationAttemptID: CanonicalUUID
    public let preparationGroupID: String
    public let retryAfterMs: UInt64?
    public let sharedAcquisition: Bool?
    public let sourceKind: PreparationProgressSourceKind?
    public let stateRevision: UInt64
    public let totalBytes: UInt64?

    public init(
        completedBytes: UInt64? = nil,
        fraction: Double? = nil,
        phase: PreparationWirePhase,
        phaseSequence: UInt64,
        preparationAttemptID: CanonicalUUID,
        preparationGroupID: String,
        retryAfterMs: UInt64? = nil,
        sharedAcquisition: Bool? = nil,
        sourceKind: PreparationProgressSourceKind? = nil,
        stateRevision: UInt64,
        totalBytes: UInt64? = nil
    ) throws {
        guard PreparationWireValidation.validGroupID(preparationGroupID) else {
            throw PreparationProgressValidationError.invalidGroupID
        }
        guard completedBytes == nil || totalBytes == nil
                || completedBytes! <= totalBytes!
        else {
            throw PreparationProgressValidationError.invalidByteProgress
        }
        guard fraction == nil
                || (fraction!.isFinite && fraction! >= 0 && fraction! <= 1)
        else {
            throw PreparationProgressValidationError.invalidFraction
        }
        self.completedBytes = completedBytes
        self.fraction = fraction
        self.phase = phase
        self.phaseSequence = phaseSequence
        self.preparationAttemptID = preparationAttemptID
        self.preparationGroupID = preparationGroupID
        self.retryAfterMs = retryAfterMs
        self.sharedAcquisition = sharedAcquisition
        self.sourceKind = sourceKind
        self.stateRevision = stateRevision
        self.totalBytes = totalBytes
    }
}

enum PreparationWireValidation {
    static let groupIDs: Set<String> = [
        "prep.coredevice.v2",
        "prep.direct.lockdown.v1",
        "prep.legacy.developer.v2",
    ]

    static func validGroupID(_ value: String) -> Bool {
        groupIDs.contains(value)
    }

    static func validASCIISet(_ values: [String], maximumCount: Int) -> Bool {
        guard values.count <= maximumCount,
              Set(values).count == values.count,
              values == values.sorted(by: asciiLessThan)
        else {
            return false
        }
        return values.allSatisfy { value in
            let bytes = Array(value.utf8)
            return (1...128).contains(bytes.count)
                && bytes.allSatisfy { (0x21...0x7e).contains($0) }
        }
    }

    static func validCapabilityID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (1...128).contains(bytes.count)
            && bytes.allSatisfy { (0x21...0x7e).contains($0) }
    }

    static func validReason(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (1...128).contains(bytes.count)
            && bytes.allSatisfy { (0x21...0x7e).contains($0) }
    }

    private static func asciiLessThan(_ lhs: String, _ rhs: String) -> Bool {
        lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
    }
}
