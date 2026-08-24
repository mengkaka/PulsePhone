import Foundation
import PulsePhoneSharedDefinitions

public enum IdentityPlaceholderError: Error, Equatable, Sendable {
    case deviceNameEmpty
    case deviceNameTooLong(actualByteCount: Int)
    case deviceNameContainsControl
}

public struct IdentityPlaceholder: Equatable, Sendable {
    public static let maximumDeviceNameByteCount = 256

    public let canonicalUDID: CanonicalUDID
    public let deviceName: String

    public init(
        deviceName: String,
        canonicalUDID: CanonicalUDID
    ) throws {
        let normalized = deviceName.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !normalized.isEmpty else {
            throw IdentityPlaceholderError.deviceNameEmpty
        }
        let byteCount = normalized.utf8.count
        guard byteCount <= Self.maximumDeviceNameByteCount else {
            throw IdentityPlaceholderError.deviceNameTooLong(
                actualByteCount: byteCount
            )
        }
        guard !normalized.unicodeScalars.contains(where: {
            CharacterSet.controlCharacters.contains($0)
        }) else {
            throw IdentityPlaceholderError.deviceNameContainsControl
        }
        self.deviceName = normalized
        self.canonicalUDID = canonicalUDID
    }

    public var primaryText: String { deviceName }
    public var secondaryText: String { canonicalUDID.rawValue }
    public var accessibilityLabel: String {
        "\(deviceName), \(canonicalUDID.rawValue)"
    }
}
