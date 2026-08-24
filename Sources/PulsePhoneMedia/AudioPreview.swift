import PulsePhoneClientCore
import PulsePhoneSharedDefinitions

public struct AudioPreviewRoute: Equatable, Sendable {
    public let canonicalUDID: CanonicalUDID
    public let sourceEpoch: UInt64
    public let sourceID: String

    public init(resolvedSource: VideoResolvedSource) {
        self.canonicalUDID = resolvedSource.canonicalUDID
        self.sourceID = resolvedSource.descriptor.sourceID
        self.sourceEpoch = resolvedSource.descriptor.sourceEpoch
    }
}

public enum AudioPreviewState: Equatable, Sendable {
    case failed(reason: String)
    case playing(route: AudioPreviewRoute)
    case stopped
}

public enum AudioPreviewError: Error, Equatable, Sendable {
    case ambiguousSource
    case microphoneUnauthorized
    case sourceUnavailable
}

public struct AudioPreview: Equatable, Sendable {
    public let canonicalUDID: CanonicalUDID
    public private(set) var muteState: PreviewAudioMuteState
    public private(set) var state: AudioPreviewState

    public init(windowID: String, canonicalUDID: CanonicalUDID) throws {
        self.canonicalUDID = canonicalUDID
        self.muteState = try PreviewAudioMuteState(windowID: windowID, isMuted: true)
        self.state = .stopped
    }

    public var isMuted: Bool { muteState.isMuted }
    public var isMacOutputEnabled: Bool { !muteState.isMuted }
    public var isPlaying: Bool {
        if case .playing = state { return true }
        return false
    }

    public mutating func start(
        resolution: VideoSourceResolution,
        microphoneAuthorization: GUIAuthorizationState
    ) throws {
        guard microphoneAuthorization == .authorized else {
            state = .stopped
            throw AudioPreviewError.microphoneUnauthorized
        }
        let resolved: VideoResolvedSource
        switch resolution {
        case .ambiguous:
            state = .stopped
            throw AudioPreviewError.ambiguousSource
        case .mapped(let value):
            resolved = value
        case .unavailable:
            state = .stopped
            throw AudioPreviewError.sourceUnavailable
        }
        guard resolved.canonicalUDID == canonicalUDID else {
            state = .stopped
            throw AudioPreviewError.sourceUnavailable
        }
        state = .playing(route: AudioPreviewRoute(
            resolvedSource: resolved
        ))
    }

    public mutating func toggleMute() throws {
        muteState = try PreviewAudioMuteAction.toggle(
            muteState,
            forWindowID: muteState.windowID
        )
    }

    public mutating func toggleMacOutput() throws {
        try toggleMute()
    }

    @discardableResult
    public mutating func sourceChanged(
        _ resolution: VideoSourceResolution
    ) -> Bool {
        guard case .playing(let current) = state else { return false }
        guard case .mapped(let resolved) = resolution else {
            state = .stopped
            return true
        }
        let next = AudioPreviewRoute(resolvedSource: resolved)
        guard next == current else {
            state = .stopped
            return true
        }
        return false
    }

    @discardableResult
    public mutating func deviceDetached(
        canonicalUDID: CanonicalUDID
    ) -> Bool {
        guard canonicalUDID == self.canonicalUDID, isPlaying else {
            return false
        }
        state = .stopped
        return true
    }

    public mutating func fail(reason: String) {
        state = .failed(reason: reason)
    }
}
