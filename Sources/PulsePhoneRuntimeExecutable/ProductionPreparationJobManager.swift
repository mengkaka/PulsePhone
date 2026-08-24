import Dispatch
import Foundation
import PulsePhoneSharedDefinitions
import PulsePhoneWire

/// Runtime-owned preparation attempts. A request connection is only an
/// observer; the attempt survives observer disconnects and is keyed by the
/// current device connection generation and Runtime-derived group.
final class ProductionPreparationJobManager: @unchecked Sendable {
    enum RequestMode: String {
        case startOnly
        case waitForTerminal
    }

    struct Key: Hashable {
        let connectionEpoch: UInt64
        let preparationGroupID: String
    }

    typealias ProgressHandler = @Sendable (PreparationProgressV1) -> Void
    typealias Work = @Sendable (
        CanonicalUUID,
        @escaping ProgressHandler
    ) throws -> ProductionRuntimeBackendDisposition

    private final class Observer {
        let progress: ProgressHandler?
        let terminal = DispatchSemaphore(value: 0)
        var result: ProductionRuntimeBackendDisposition?

        init(progress: ProgressHandler?) {
            self.progress = progress
        }
    }

    /// All mutable job state is accessed while the manager lock is held.
    private final class Job: @unchecked Sendable {
        let attemptID: CanonicalUUID
        let key: Key
        var latestProgress: PreparationProgressV1?
        var observers = [CanonicalUUID: Observer]()
        var terminal: ProductionRuntimeBackendDisposition?

        init(attemptID: CanonicalUUID, key: Key) {
            self.attemptID = attemptID
            self.key = key
        }
    }

    private let lock = NSLock()
    private var jobs = [Key: Job]()

    /// `startOnly` returns immediately after starting or joining a job. An
    /// explicit observer blocks only on the shared Runtime terminal.
    func submit(
        key: Key,
        mode: RequestMode,
        observerID: CanonicalUUID,
        progress: ProgressHandler?,
        work: @escaping Work
    ) -> ProductionRuntimeBackendDisposition? {
        let observer: Observer?
        let progressReplay: PreparationProgressV1?
        let shouldStart: Bool

        lock.lock()
        let current: Job
        if let existing = jobs[key], existing.terminal == nil {
            current = existing
            shouldStart = false
        } else if mode == .waitForTerminal {
            let created = Job(attemptID: CanonicalUUID(value: UUID()), key: key)
            jobs[key] = created
            current = created
            shouldStart = true
        } else if let existing = jobs[key] {
            // A failed start-only attempt is intentionally not retried by a
            // later ordinary command. An explicit prepare creates the retry.
            current = existing
            shouldStart = false
        } else {
            let created = Job(attemptID: CanonicalUUID(value: UUID()), key: key)
            jobs[key] = created
            current = created
            shouldStart = true
        }

        if mode == .waitForTerminal {
            let createdObserver = Observer(progress: progress)
            current.observers[observerID] = createdObserver
            observer = createdObserver
            progressReplay = current.latestProgress
        } else {
            observer = nil
            progressReplay = nil
        }
        let completed = current.terminal
        lock.unlock()

        if let observer, let progressReplay {
            observer.progress?(progressReplay)
        }
        if shouldStart {
            start(job: current, work: work)
        }
        guard let observer else { return nil }
        if let completed { return completed }
        observer.terminal.wait()
        return observer.result
    }

    private func start(job: Job, work: @escaping Work) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self, weak job] in
            guard let self, let job else { return }
            let result: ProductionRuntimeBackendDisposition
            do {
                result = try work(job.attemptID) { [weak self, job] progress in
                    self?.publish(progress, for: job)
                }
            } catch {
                result = .outcomeUnknown(code: "runtimeFailed")
            }
            self.complete(result, for: job)
        }
    }

    private func publish(_ progress: PreparationProgressV1, for job: Job) {
        let observers: [Observer] = lock.withLock {
            guard jobs[job.key] === job, job.terminal == nil else { return [] }
            job.latestProgress = progress
            return Array(job.observers.values)
        }
        observers.forEach { $0.progress?(progress) }
    }

    private func complete(
        _ result: ProductionRuntimeBackendDisposition,
        for job: Job
    ) {
        let observers: [Observer] = lock.withLock {
            guard jobs[job.key] === job, job.terminal == nil else { return [] }
            job.terminal = result
            return Array(job.observers.values)
        }
        for observer in observers {
            observer.result = result
            observer.terminal.signal()
        }
    }
}
