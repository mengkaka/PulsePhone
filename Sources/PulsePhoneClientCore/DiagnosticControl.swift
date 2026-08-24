import PulsePhoneLogging
import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions

public enum DiagnosticControlError: Error, Equatable, Sendable {
    case controlMutationFailure
    case diagnosticsAlreadyActive
    case noActiveDiagnostics
}

public struct DiagnosticStartResult: Equatable, Sendable {
    public let absolutePath: String
    public let sessionID: CanonicalUUID

    public init(absolutePath: String, sessionID: CanonicalUUID) {
        self.absolutePath = absolutePath
        self.sessionID = sessionID
    }
}

public enum DiagnosticRecordDisposition: Equatable, Sendable {
    case autoFinalized(DiagnosticLogFinalization)
    case noActive
    case recorded
}

public struct DiagnosticRecordResult: Equatable, Sendable {
    public let commandMayContinue: Bool
    public let disposition: DiagnosticRecordDisposition
}

public struct DiagnosticControlSnapshot: Equatable, Sendable {
    public let activeSessionID: CanonicalUUID?
    public let activeSessionPath: String?
    public let controlMutationTokenCount: Int
    public let lastAutomaticReceiptExists: Bool
}

public struct DiagnosticController: Sendable {
    public static let shutdownFinalizeDeadlineNanoseconds: UInt64 = 5_000_000_000

    private var active: DiagnosticLogWriter?
    private var controlMutations = ShutdownInhibitorRegistry()

    public init() {}

    public var snapshot: DiagnosticControlSnapshot {
        DiagnosticControlSnapshot(
            activeSessionID: active?.sessionID,
            activeSessionPath: active?.absolutePath,
            controlMutationTokenCount: controlMutations.snapshot.tokenCount,
            lastAutomaticReceiptExists: false
        )
    }

    public mutating func start(
        sessionID: CanonicalUUID,
        controlTokenID: CanonicalUUID,
        absolutePath: String,
        maximumFileBytes: Int = DiagnosticLogWriter.maximumFileBytes,
        footerReserveBytes: Int = DiagnosticLogWriter.footerReserveBytes
    ) throws -> DiagnosticStartResult {
        guard active == nil else {
            throw DiagnosticControlError.diagnosticsAlreadyActive
        }
        let token = try acquireControlMutation(
            tokenID: controlTokenID,
            state: "diagnosticsStarting"
        )
        do {
            let writer = try DiagnosticLogWriter(
                sessionID: sessionID,
                absolutePath: absolutePath,
                maximumFileBytes: maximumFileBytes,
                footerReserveBytes: footerReserveBytes
            )
            try releaseControlMutation(token)
            active = writer
            return DiagnosticStartResult(
                absolutePath: writer.absolutePath,
                sessionID: writer.sessionID
            )
        } catch {
            _ = try? controlMutations.release(token)
            throw error
        }
    }

    public mutating func recordBestEffort(
        _ event: DiagnosticLogEvent,
        writeAvailable: Bool = true,
        footerWriteAvailable: Bool = true
    ) throws -> DiagnosticRecordResult {
        guard var writer = active else {
            return DiagnosticRecordResult(
                commandMayContinue: true,
                disposition: .noActive
            )
        }
        let writerDisposition = try writer.append(
            event,
            writeAvailable: writeAvailable,
            footerWriteAvailable: footerWriteAvailable
        )
        let disposition: DiagnosticRecordDisposition
        switch writerDisposition {
        case .appended:
            active = writer
            disposition = .recorded
        case .autoFinalized(let finalization):
            active = nil
            disposition = .autoFinalized(finalization)
        }
        return DiagnosticRecordResult(
            commandMayContinue: true,
            disposition: disposition
        )
    }

    public mutating func stop(
        controlTokenID: CanonicalUUID,
        footerWriteAvailable: Bool = true
    ) throws -> DiagnosticLogFinalization {
        guard var writer = active else {
            throw DiagnosticControlError.noActiveDiagnostics
        }
        let token = try acquireControlMutation(
            tokenID: controlTokenID,
            state: "diagnosticsStopping"
        )
        do {
            let result = try writer.stop(
                footerWriteAvailable: footerWriteAvailable
            )
            try releaseControlMutation(token)
            active = nil
            return result
        } catch {
            _ = try? controlMutations.release(token)
            throw error
        }
    }

    public mutating func finalizeForShutdown(
        elapsedNanoseconds: UInt64,
        footerWriteAvailable: Bool = true
    ) throws -> DiagnosticLogFinalization? {
        guard var writer = active else { return nil }
        let result: DiagnosticLogFinalization
        if elapsedNanoseconds > Self.shutdownFinalizeDeadlineNanoseconds {
            result = try writer.forceIncomplete(
                reason: .shutdownTimeout,
                footerWriteAvailable: false
            )
        } else {
            result = try writer.stop(
                reason: .shutdown,
                footerWriteAvailable: footerWriteAvailable
            )
        }
        active = nil
        return result
    }

    private mutating func acquireControlMutation(
        tokenID: CanonicalUUID,
        state: String
    ) throws -> ShutdownInhibitorToken {
        do {
            return try controlMutations.acquire(
                tokenID: tokenID,
                metadata: ShutdownInhibitorMetadata(
                    kind: .controlMutation,
                    retryWhen: .controlFinished,
                    commandID: "diagnostics.control",
                    state: state
                )
            )
        } catch {
            throw DiagnosticControlError.controlMutationFailure
        }
    }

    private mutating func releaseControlMutation(
        _ token: ShutdownInhibitorToken
    ) throws {
        do {
            _ = try controlMutations.release(token)
        } catch {
            throw DiagnosticControlError.controlMutationFailure
        }
    }
}
