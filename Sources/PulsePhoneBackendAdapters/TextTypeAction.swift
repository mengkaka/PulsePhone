import PulsePhoneSharedDefinitions

public enum VirtualKeyboardModifier: String, CaseIterable, Sendable {
    case command
    case option
}

public protocol TextInputTransport: Sendable {
    func setPasteboard(_ text: String) throws
    func readPasteboard() throws -> String?
    func sendChord(
        modifiers: [VirtualKeyboardModifier],
        key: String
    ) throws
    func releaseAll() throws
    func waitForCleanupAcknowledgement(
        timeoutMilliseconds: UInt64
    ) throws
}

public struct TextInputFailure: Equatable, Sendable {
    public let code: String
    public let commitState: CommitState
    public let outcome: StandardOutcome
    public let stage: String?

    public init(
        code: String,
        commitState: CommitState,
        outcome: StandardOutcome,
        stage: String? = nil
    ) {
        self.code = code
        self.commitState = commitState
        self.outcome = outcome
        self.stage = stage
    }
}

public enum TextTypeActionError: Error, Equatable, Sendable {
    case failure(TextInputFailure)
}

public struct TextTypeActionResult: Codable, Equatable, Sendable {
    public let disposition: String

    public init(disposition: String = "pasteDispatched") {
        self.disposition = disposition
    }
}

public struct TextTypeSemanticLog: Equatable, Sendable {
    public let commandID: String
    public let inputReleased: Bool
    public let routeID: String
    public let textRedacted: Bool
    public let utf8ByteCount: Int
}

public struct TextTypeExecution: Equatable, Sendable {
    public let result: TextTypeActionResult
    public let semanticLog: TextTypeSemanticLog
}

public struct TextTypeAction: Sendable {
    public static let cleanupAcknowledgementMilliseconds: UInt64 = 2_000
    public static let commandID = "text.type"
    public static let maximumUTF8Bytes = 64 * 1_024
    public static let routeID = "coredevice.pasteboardSetAndPaste"

    private let transport: any TextInputTransport

    public init(transport: any TextInputTransport) {
        self.transport = transport
    }

    public func execute(text: String) throws -> TextTypeExecution {
        guard text.utf8.count <= Self.maximumUTF8Bytes else {
            throw TextTypeActionError.failure(TextInputFailure(
                code: "argumentTooLarge",
                commitState: .notCommitted,
                outcome: .failed
            ))
        }
        do {
            try transport.setPasteboard(text)
        } catch {
            throw TextTypeActionError.failure(TextInputFailure(
                code: "pasteboardSetFailed",
                commitState: .notCommitted,
                outcome: .failed
            ))
        }
        do {
            guard try transport.readPasteboard() == text else {
                throw TextTypeActionError.failure(TextInputFailure(
                    code: "backendFailed",
                    commitState: .committed,
                    outcome: .failed,
                    stage: "pasteboardReadBack"
                ))
            }
        } catch let error as TextTypeActionError {
            throw error
        } catch {
            throw TextTypeActionError.failure(TextInputFailure(
                code: "backendFailed",
                commitState: .committed,
                outcome: .failed,
                stage: "pasteboardReadBack"
            ))
        }

        do {
            try transport.sendChord(modifiers: [.command], key: "v")
        } catch {
            try settleAfterCommit()
            throw TextTypeActionError.failure(TextInputFailure(
                code: "pasteFailed",
                commitState: .committed,
                outcome: .failed
            ))
        }
        do {
            try transport.releaseAll()
        } catch {
            try cleanupOrUnknown()
            throw unknownReleaseFailure()
        }
        try cleanupOrUnknown()
        return TextTypeExecution(
            result: TextTypeActionResult(),
            semanticLog: TextTypeSemanticLog(
                commandID: Self.commandID,
                inputReleased: true,
                routeID: Self.routeID,
                textRedacted: true,
                utf8ByteCount: text.utf8.count
            )
        )
    }

    private func settleAfterCommit() throws {
        try? transport.releaseAll()
        try cleanupOrUnknown()
    }

    private func cleanupOrUnknown() throws {
        do {
            try transport.waitForCleanupAcknowledgement(
                timeoutMilliseconds: Self.cleanupAcknowledgementMilliseconds
            )
        } catch {
            throw unknownReleaseFailure()
        }
    }

    private func unknownReleaseFailure() -> TextTypeActionError {
        TextTypeActionError.failure(TextInputFailure(
            code: "outcomeUnknown",
            commitState: .committed,
            outcome: .outcomeUnknown
        ))
    }
}
