import Foundation
import PulsePhoneSharedDefinitions

enum DeterministicClockError: Error, Equatable {
    case integerOverflow
    case nonMonotonicAdvance
}

final class DeterministicClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: MonotonicInstant

    init(start: MonotonicInstant = MonotonicInstant(nanoseconds: 0)) {
        current = start
    }

    func now() -> MonotonicInstant {
        lock.withLock { current }
    }

    @discardableResult
    func advance(by duration: MonotonicDuration) throws -> MonotonicInstant {
        try lock.withLock {
            let (next, overflow) = current.nanoseconds.addingReportingOverflow(
                duration.nanoseconds
            )
            guard !overflow else {
                throw DeterministicClockError.integerOverflow
            }
            current = MonotonicInstant(nanoseconds: next)
            return current
        }
    }

    func advance(to instant: MonotonicInstant) throws {
        try lock.withLock {
            guard instant >= current else {
                throw DeterministicClockError.nonMonotonicAdvance
            }
            current = instant
        }
    }
}

private extension NSLock {
    func withLock<Value>(_ body: () throws -> Value) rethrows -> Value {
        lock()
        defer { unlock() }
        return try body()
    }
}
