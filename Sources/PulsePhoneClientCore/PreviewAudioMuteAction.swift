public enum PreviewAudioMuteActionError: Error, Equatable, Sendable {
    case invalidWindowID
    case windowMismatch
}

public struct PreviewAudioMuteState: Equatable, Sendable {
    public let isMuted: Bool
    public let windowID: String

    public init(windowID: String, isMuted: Bool = false) throws {
        guard Self.validWindowID(windowID) else {
            throw PreviewAudioMuteActionError.invalidWindowID
        }
        self.windowID = windowID
        self.isMuted = isMuted
    }

    fileprivate static func validWindowID(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (1...128).contains(bytes.count)
            && bytes.allSatisfy { (0x21...0x7e).contains($0) }
    }
}

public enum PreviewAudioMuteAction {
    public static func toggle(
        _ state: PreviewAudioMuteState,
        forWindowID windowID: String
    ) throws -> PreviewAudioMuteState {
        guard PreviewAudioMuteState.validWindowID(windowID) else {
            throw PreviewAudioMuteActionError.invalidWindowID
        }
        guard windowID == state.windowID else {
            throw PreviewAudioMuteActionError.windowMismatch
        }
        return try PreviewAudioMuteState(
            windowID: state.windowID,
            isMuted: !state.isMuted
        )
    }
}
