import PulsePhoneHostPaths
import PulsePhoneSharedDefinitions

public enum ScreenshotRoute: String, Equatable, Sendable {
    case legacyScreenshotR = "legacy.screenshotr"
    case modernCoreDevice = "coredevice.screenshot"

    public var preparationGroupID: String {
        switch self {
        case .legacyScreenshotR: "prep.legacy.developer.v2"
        case .modernCoreDevice: "prep.coredevice.v2"
        }
    }

    public static func resolve(osMajor: UInt64) throws -> ScreenshotRoute {
        switch osMajor {
        case 14..<17: .legacyScreenshotR
        case 17...: .modernCoreDevice
        default: throw ScreenshotArtifactError.unsupportedOSMajor(osMajor)
        }
    }
}

public enum ScreenshotPreparationState: Equatable, Sendable {
    case failed(code: String)
    case ready
    case unavailable
}

public struct ScreenshotPreparation: Equatable, Sendable {
    public let preparationGroupID: String
    public let state: ScreenshotPreparationState

    public init(
        preparationGroupID: String,
        state: ScreenshotPreparationState
    ) {
        self.preparationGroupID = preparationGroupID
        self.state = state
    }
}

public enum ScreenshotArtifactError: Error, Equatable, Sendable {
    case artifactTooLarge
    case artifactValidationFailed
    case backendFormatConversionFailed
    case developerSupportFailure(String)
    case preparationGroupMismatch(expected: String, actual: String)
    case preparationNotReady(String)
    case protocolViolation
    case unsafeHostPath
    case unsupportedOSMajor(UInt64)
    case unsupportedScreenshotFormat
}

public enum ScreenshotBackendFormat: String, Equatable, Sendable {
    case jpeg
    case png
    case tiff
    case unknown
}

public struct ScreenshotReservationNode: Equatable, Sendable {
    public let identity: HostNodeIdentity
    public let kind: HostNodeKind
    public let mode: UInt16
    public let owner: UInt32

    public init(
        identity: HostNodeIdentity,
        owner: UInt32,
        kind: HostNodeKind,
        mode: UInt16
    ) {
        self.identity = identity
        self.owner = owner
        self.kind = kind
        self.mode = mode
    }
}

public struct ScreenshotReservation: Equatable, Sendable {
    public let artifactID: CanonicalUUID
    public let basename: String
    public let internalPath: String
    public let node: ScreenshotReservationNode

    public init(
        artifactID: CanonicalUUID,
        directoryPath: String,
        node: ScreenshotReservationNode
    ) throws {
        guard directoryPath.utf8.first == 0x2f,
              !directoryPath.utf8.contains(0),
              node.kind == .regularFile,
              node.mode == 0o600
        else {
            throw ScreenshotArtifactError.unsafeHostPath
        }
        self.artifactID = artifactID
        self.basename = "\(artifactID).png"
        self.internalPath = "\(directoryPath)/\(artifactID).png"
        self.node = node
    }
}

public struct ScreenshotHelperCompletion: Equatable, Sendable {
    public let artifactID: CanonicalUUID
    public let byteCount: UInt64
    public let format: ScreenshotBackendFormat
    public let returnedPath: String?

    public init(
        artifactID: CanonicalUUID,
        byteCount: UInt64,
        format: ScreenshotBackendFormat,
        returnedPath: String? = nil
    ) {
        self.artifactID = artifactID
        self.byteCount = byteCount
        self.format = format
        self.returnedPath = returnedPath
    }
}

public struct ValidatedScreenshotArtifact: Equatable, Sendable {
    public let artifactID: CanonicalUUID
    public let byteCount: UInt64
    public let bytes: [UInt8]
    public let contentType: String
    public let nodeIdentity: HostNodeIdentity
    public let readOnly: Bool
    public let reservationUnlinked: Bool
}

public enum ScreenshotReservationFailureCleanup: Equatable, Sendable {
    case preserveNode
    case unlinkOwnedReservation
}

public enum ScreenshotReservationValidator {
    public static let maximumArtifactBytes: UInt64 = 64 * 1_024 * 1_024
    public static let pngSignature: [UInt8] = [
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
    ]

    public static func validatePreparation(
        osMajor: UInt64,
        preparation: ScreenshotPreparation
    ) throws -> ScreenshotRoute {
        let route = try ScreenshotRoute.resolve(osMajor: osMajor)
        guard preparation.preparationGroupID == route.preparationGroupID else {
            throw ScreenshotArtifactError.preparationGroupMismatch(
                expected: route.preparationGroupID,
                actual: preparation.preparationGroupID
            )
        }
        switch preparation.state {
        case .ready:
            return route
        case .failed(let code):
            throw ScreenshotArtifactError.developerSupportFailure(code)
        case .unavailable:
            throw ScreenshotArtifactError.preparationNotReady(
                preparation.preparationGroupID
            )
        }
    }

    public static func validate(
        reservation: ScreenshotReservation,
        completion: ScreenshotHelperCompletion,
        reopenedNode: ScreenshotReservationNode,
        bytes: [UInt8]
    ) throws -> ValidatedScreenshotArtifact {
        guard completion.artifactID == reservation.artifactID,
              completion.returnedPath == nil
        else {
            throw ScreenshotArtifactError.protocolViolation
        }
        guard reopenedNode.owner == reservation.node.owner,
              reopenedNode.kind == .regularFile,
              reopenedNode.mode == 0o600,
              reopenedNode.identity == reservation.node.identity
        else {
            throw ScreenshotArtifactError.unsafeHostPath
        }
        guard completion.byteCount <= maximumArtifactBytes else {
            throw ScreenshotArtifactError.artifactTooLarge
        }
        guard completion.format == .png else {
            throw ScreenshotArtifactError.unsupportedScreenshotFormat
        }
        guard completion.byteCount == UInt64(bytes.count),
              bytes.starts(with: pngSignature)
        else {
            throw ScreenshotArtifactError.artifactValidationFailed
        }
        return ValidatedScreenshotArtifact(
            artifactID: reservation.artifactID,
            byteCount: completion.byteCount,
            bytes: bytes,
            contentType: "image/png",
            nodeIdentity: reopenedNode.identity,
            readOnly: true,
            reservationUnlinked: true
        )
    }

    public static func failureCleanup(
        for error: ScreenshotArtifactError
    ) -> ScreenshotReservationFailureCleanup {
        switch error {
        case .unsafeHostPath, .protocolViolation:
            .preserveNode
        default:
            .unlinkOwnedReservation
        }
    }
}

public enum ScreenshotHelperFormatNormalizer {
    public static func normalizeToPNG(
        sourceFormat: ScreenshotBackendFormat,
        sourceBytes: [UInt8],
        convertedPNG: [UInt8]? = nil
    ) throws -> [UInt8] {
        switch sourceFormat {
        case .png:
            guard sourceBytes.starts(
                with: ScreenshotReservationValidator.pngSignature
            ) else {
                throw ScreenshotArtifactError.artifactValidationFailed
            }
            return sourceBytes
        case .jpeg, .tiff:
            guard let convertedPNG,
                  convertedPNG.starts(
                      with: ScreenshotReservationValidator.pngSignature
                  )
            else {
                throw ScreenshotArtifactError.backendFormatConversionFailed
            }
            return convertedPNG
        case .unknown:
            throw ScreenshotArtifactError.unsupportedScreenshotFormat
        }
    }
}
