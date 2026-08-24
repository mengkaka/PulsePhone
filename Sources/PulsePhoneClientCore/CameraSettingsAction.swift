import Foundation

public enum GUIAuthorizationState: String, Codable, Equatable, Sendable {
    case authorized
    case denied
    case notDetermined
    case restricted
}

public enum CameraSettingsDisposition: Equatable, Sendable {
    case noActionRequired
    case openSettings(URL)
    case requestAuthorization
}

public enum CameraSettingsAction {
    public static let privacySettingsURL = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera"
    )!

    public static func disposition(
        for authorization: GUIAuthorizationState
    ) -> CameraSettingsDisposition {
        switch authorization {
        case .authorized:
            .noActionRequired
        case .denied, .restricted:
            .openSettings(privacySettingsURL)
        case .notDetermined:
            .requestAuthorization
        }
    }
}
