import Foundation

public struct PulsePhoneProductVersion: Codable, Equatable, Sendable {
    public let build: String
    public let version: String

    public init?(version: String, build: String) {
        guard Self.isValidComponent(version), Self.isValidComponent(build) else {
            return nil
        }
        self.build = build
        self.version = version
    }

    public init?(bundle: Bundle) {
        guard let version = bundle.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String,
              let build = bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
              ) as? String
        else {
            return nil
        }
        self.init(version: version, build: build)
    }

    public var displayText: String {
        "PulsePhone \(version) (\(build))"
    }

    private static func isValidComponent(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 128
            && value.unicodeScalars.allSatisfy { scalar in
                scalar.value >= 0x21 && scalar.value <= 0x7e
            }
    }
}
