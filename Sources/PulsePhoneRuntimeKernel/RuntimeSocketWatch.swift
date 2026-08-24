import Darwin
import Dispatch
import Foundation

public enum RuntimeSocketWatchFailure: Equatable, Sendable {
    case socketMissing
    case socketReplaced
    case socketUnsafe
    case watcherInvalidated
}

public final class RuntimeSocketWatch: @unchecked Sendable {
    private let source: DispatchSourceFileSystemObject
    private let socketPath: String
    private let socketIdentity: RuntimeSocketIdentity
    private let expectedOwner: uid_t
    private let onFailure: @Sendable (RuntimeSocketWatchFailure) -> Void
    private let stateLock = NSLock()
    private var expectedRemoval = false
    private var failureDelivered = false

    init(
        baseDirectoryPath: String,
        socketPath: String,
        socketIdentity: RuntimeSocketIdentity,
        expectedOwner: uid_t,
        queue: DispatchQueue,
        onFailure: @escaping @Sendable (RuntimeSocketWatchFailure) -> Void
    ) throws {
        let descriptor = Darwin.open(
            baseDirectoryPath,
            O_EVTONLY | O_CLOEXEC | O_NOFOLLOW
        )
        guard descriptor >= 0 else {
            throw RuntimeListenerError.systemCall(
                operation: "open-runtime-base-watch",
                errno: errno
            )
        }
        guard socketIdentity.validation(
            path: socketPath,
            expectedOwner: expectedOwner
        ) == .valid else {
            _ = Darwin.close(descriptor)
            throw RuntimeListenerError.socketIdentityMismatch
        }
        self.socketPath = socketPath
        self.socketIdentity = socketIdentity
        self.expectedOwner = expectedOwner
        self.onFailure = onFailure
        self.source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke],
            queue: queue
        )
        source.setCancelHandler {
            _ = Darwin.close(descriptor)
        }
        source.setEventHandler { [weak self] in
            self?.handleEvent()
        }
        source.resume()
        guard socketIdentity.validation(
            path: socketPath,
            expectedOwner: expectedOwner
        ) == .valid else {
            source.cancel()
            throw RuntimeListenerError.socketIdentityMismatch
        }
    }

    public func beginExpectedRemoval() {
        stateLock.lock()
        expectedRemoval = true
        stateLock.unlock()
    }

    public func cancel() {
        source.cancel()
    }

    func simulateWatcherInvalidationForTesting() {
        deliver(.watcherInvalidated)
    }

    private func handleEvent() {
        let flags = source.data
        if !flags.intersection([.delete, .rename, .revoke]).isEmpty {
            deliver(.watcherInvalidated)
            return
        }
        switch socketIdentity.validation(
            path: socketPath,
            expectedOwner: expectedOwner
        ) {
        case .valid:
            return
        case .missing:
            deliver(.socketMissing)
        case .replaced:
            deliver(.socketReplaced)
        case .unsafe:
            deliver(.socketUnsafe)
        }
    }

    private func deliver(_ failure: RuntimeSocketWatchFailure) {
        stateLock.lock()
        guard !expectedRemoval, !failureDelivered else {
            stateLock.unlock()
            return
        }
        failureDelivered = true
        stateLock.unlock()
        onFailure(failure)
    }
}
