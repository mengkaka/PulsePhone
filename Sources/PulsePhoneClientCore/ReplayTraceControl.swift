import PulsePhoneLogging
import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions

public enum ReplayTraceControlError: Error, Equatable, Sendable {
    case inhibitorFailure
    case noActiveTrace
    case traceAlreadyActive
    case traceOpenFailed
}

public struct ReplayTraceStartResult: Equatable, Sendable {
    public let absolutePath: String
    public let traceID: CanonicalUUID

    public init(
        absolutePath: String,
        traceID: CanonicalUUID
    ) {
        self.absolutePath = absolutePath
        self.traceID = traceID
    }
}

public struct ReplayTraceControlSnapshot: Equatable, Sendable {
    public let activeTraceID: CanonicalUUID?
    public let activeTracePath: String?
    public let inhibitorSnapshot: ShutdownInhibitorRegistrySnapshot
    public let lastAutomaticReceiptExists: Bool
}

public struct ReplayTraceController: Sendable {
    private struct ActiveTrace: Sendable {
        var inhibitor: ShutdownInhibitorToken
        var writer: ReplayTraceWriter
    }

    private var active: ActiveTrace?
    private var inhibitors = ShutdownInhibitorRegistry()

    public init() {}

    public var snapshot: ReplayTraceControlSnapshot {
        ReplayTraceControlSnapshot(
            activeTraceID: active?.writer.traceID,
            activeTracePath: active?.writer.absolutePath,
            inhibitorSnapshot: inhibitors.snapshot,
            lastAutomaticReceiptExists: false
        )
    }

    public mutating func start(
        traceID: CanonicalUUID,
        inhibitorTokenID: CanonicalUUID,
        absolutePath: String,
        maximumFileBytes: Int = ReplayTraceWriter.maximumFileBytes,
        footerReserveBytes: Int = ReplayTraceWriter.footerReserveBytes,
        writerOpenAvailable: Bool = true,
        beforeWriterOpen: (ShutdownInhibitorRegistrySnapshot) -> Void = { _ in }
    ) throws -> ReplayTraceStartResult {
        guard active == nil else {
            throw ReplayTraceControlError.traceAlreadyActive
        }
        let starting: ShutdownInhibitorToken
        do {
            starting = try inhibitors.acquire(
                tokenID: inhibitorTokenID,
                metadata: ShutdownInhibitorMetadata(
                    kind: .activeTrace,
                    retryWhen: .traceStopped,
                    commandID: "trace.start",
                    state: "traceStarting"
                )
            )
        } catch {
            throw ReplayTraceControlError.inhibitorFailure
        }
        beforeWriterOpen(inhibitors.snapshot)
        guard writerOpenAvailable else {
            _ = try? inhibitors.release(starting)
            throw ReplayTraceControlError.traceOpenFailed
        }
        do {
            let writer = try ReplayTraceWriter(
                traceID: traceID,
                absolutePath: absolutePath,
                maximumFileBytes: maximumFileBytes,
                footerReserveBytes: footerReserveBytes
            )
            let activeToken = try inhibitors.handoff(
                starting,
                to: ShutdownInhibitorMetadata(
                    kind: .activeTrace,
                    retryWhen: .traceStopped,
                    commandID: "trace.start",
                    state: "active"
                )
            )
            active = ActiveTrace(inhibitor: activeToken, writer: writer)
            return ReplayTraceStartResult(
                absolutePath: writer.absolutePath,
                traceID: writer.traceID
            )
        } catch let error as ReplayTraceError {
            _ = try? inhibitors.release(starting)
            throw error
        } catch {
            _ = try? inhibitors.release(starting)
            throw ReplayTraceControlError.inhibitorFailure
        }
    }

    public mutating func append(
        _ event: ReplayTraceSemanticEvent,
        semanticWriteAvailable: Bool = true,
        incompleteFooterWriteAvailable: Bool = true
    ) throws -> ReplayTraceAppendDisposition {
        guard var current = active else {
            throw ReplayTraceControlError.noActiveTrace
        }
        let disposition = try current.writer.append(
            event,
            semanticWriteAvailable: semanticWriteAvailable,
            incompleteFooterWriteAvailable: incompleteFooterWriteAvailable
        )
        switch disposition {
        case .appended:
            active = current
        case .autoFinalized:
            do {
                _ = try inhibitors.release(current.inhibitor)
            } catch {
                throw ReplayTraceControlError.inhibitorFailure
            }
            active = nil
        }
        return disposition
    }

    public mutating func stop(
        completeFooterWriteAvailable: Bool = true,
        incompleteFooterWriteAvailable: Bool = true
    ) throws -> ReplayTraceFinalization {
        guard var current = active else {
            throw ReplayTraceControlError.noActiveTrace
        }
        let result = try current.writer.stop(
            completeFooterWriteAvailable: completeFooterWriteAvailable,
            incompleteFooterWriteAvailable: incompleteFooterWriteAvailable
        )
        do {
            _ = try inhibitors.release(current.inhibitor)
        } catch {
            throw ReplayTraceControlError.inhibitorFailure
        }
        active = nil
        return result
    }
}
