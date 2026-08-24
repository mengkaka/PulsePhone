import PulsePhoneClientCore

public struct MediaPermissionSnapshot: Equatable, Sendable {
    public let camera: GUIAuthorizationState
    public let microphone: GUIAuthorizationState
    public let revision: UInt64

    public init(
        camera: GUIAuthorizationState,
        microphone: GUIAuthorizationState,
        revision: UInt64
    ) {
        self.camera = camera
        self.microphone = microphone
        self.revision = revision
    }
}

public enum PermissionCoordinatorError: Error, Equatable, Sendable {
    case staleRevision
}

public struct PermissionCoordinator: Equatable, Sendable {
    public private(set) var snapshot: MediaPermissionSnapshot

    public init(
        camera: GUIAuthorizationState = .notDetermined,
        microphone: GUIAuthorizationState = .notDetermined
    ) {
        self.snapshot = MediaPermissionSnapshot(
            camera: camera,
            microphone: microphone,
            revision: 0
        )
    }

    public var audioPreviewAuthorized: Bool {
        snapshot.microphone == .authorized
    }

    public var videoPreviewAuthorized: Bool {
        snapshot.camera == .authorized
    }

    public var runtimeControlAffected: Bool { false }

    public mutating func refreshOnForeground(
        camera: GUIAuthorizationState,
        microphone: GUIAuthorizationState,
        revision: UInt64
    ) throws {
        guard revision > snapshot.revision else {
            throw PermissionCoordinatorError.staleRevision
        }
        snapshot = MediaPermissionSnapshot(
            camera: camera,
            microphone: microphone,
            revision: revision
        )
    }

    public mutating func updateCamera(
        _ camera: GUIAuthorizationState,
        revision: UInt64
    ) throws {
        try refreshOnForeground(
            camera: camera,
            microphone: snapshot.microphone,
            revision: revision
        )
    }

    public mutating func updateMicrophone(
        _ microphone: GUIAuthorizationState,
        revision: UInt64
    ) throws {
        try refreshOnForeground(
            camera: snapshot.camera,
            microphone: microphone,
            revision: revision
        )
    }
}
