import Darwin
import Dispatch
import Foundation
import PulsePhoneClientCore
import PulsePhoneSharedDefinitions

public enum CLIWorkClass: Equatable, Sendable {
    case local
    case control
    case oneShot
    case hybrid
}

public enum CLIInterruptionAction: Equatable, Sendable {
    case stopLocalAndTerminateFactsProbe
    case cancelBeforeWriteOrWaitExistingTerminal
    case requestOwnedCancellation
    case stopLaunchingChildrenAndProjectActive
}

public enum CLISignalDisposition: Equatable, Sendable {
    case beginGrace(
        action: CLIInterruptionAction,
        deadline: MonotonicInstant
    )
    case immediateExit(Int32)
}

public enum CLISignalCoordinatorError: Error, Equatable, Sendable {
    case clockMovedBackwards
}

public struct CLISignalCoordinator: Sendable {
    public static let graceDuration = MonotonicDuration(
        nanoseconds: 1_000_000_000
    )

    public let workClass: CLIWorkClass
    private var firstSignalAt: MonotonicInstant?

    public init(workClass: CLIWorkClass) {
        self.workClass = workClass
    }

    public mutating func receiveSIGINT(
        at instant: MonotonicInstant
    ) throws -> CLISignalDisposition {
        if let firstSignalAt {
            guard instant >= firstSignalAt else {
                throw CLISignalCoordinatorError.clockMovedBackwards
            }
            return .immediateExit(ErrorFamily.interrupted.exitCode)
        }
        firstSignalAt = instant
        return .beginGrace(
            action: action,
            deadline: try instant.advanced(by: Self.graceDuration)
        )
    }

    public func exitCodeAfterInterruption() -> Int32 {
        ErrorFamily.interrupted.exitCode
    }

    private var action: CLIInterruptionAction {
        switch workClass {
        case .local:
            .stopLocalAndTerminateFactsProbe
        case .control:
            .cancelBeforeWriteOrWaitExistingTerminal
        case .oneShot:
            .requestOwnedCancellation
        case .hybrid:
            .stopLaunchingChildrenAndProjectActive
        }
    }
}

public final class ProductionElementSnapshotSIGINTMonitor: @unchecked Sendable {
    public typealias ImmediateExit = @Sendable (Int32) -> Void

    private let clock = SystemMonotonicClock()
    private var coordinator = CLISignalCoordinator(workClass: .oneShot)
    private let immediateExit: ImmediateExit
    private let interruption: RuntimeClientElementSnapshotInterruption
    private let lock = NSLock()
    private let previousSignalHandler: sig_t?
    private let queue = DispatchQueue(
        label: "com.pulsephone.cli.element-snapshot-sigint",
        qos: .userInitiated
    )
    private let source: DispatchSourceSignal
    private var stopped = false

    public init(
        interruption: RuntimeClientElementSnapshotInterruption,
        immediateExit: @escaping ImmediateExit = { Darwin._exit($0) }
    ) {
        self.immediateExit = immediateExit
        self.interruption = interruption
        previousSignalHandler = Darwin.signal(SIGINT, SIG_IGN)
        source = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
        source.setEventHandler { [weak self] in
            self?.receivePendingSignals()
        }
        source.resume()
    }

    deinit {
        stop()
    }

    public func stop() {
        let shouldStop = lock.withLock { () -> Bool in
            guard !stopped else { return false }
            stopped = true
            return true
        }
        guard shouldStop else { return }
        source.cancel()
        queue.sync {}
        if let previousSignalHandler {
            _ = Darwin.signal(SIGINT, previousSignalHandler)
        } else {
            _ = Darwin.signal(SIGINT, SIG_DFL)
        }
    }

    private func receivePendingSignals() {
        let signalCount = max(UInt(1), source.data)
        for _ in 0..<min(signalCount, UInt(2)) {
            let disposition = lock.withLock { () -> CLISignalDisposition? in
                guard !stopped else { return nil }
                return try? coordinator.receiveSIGINT(at: clock.now())
            }
            guard let disposition else { return }
            switch disposition {
            case .beginGrace(let action, _):
                guard action == .requestOwnedCancellation else {
                    immediateExit(ErrorFamily.interrupted.exitCode)
                    return
                }
                interruption.interrupt()
            case .immediateExit(let code):
                immediateExit(code)
                return
            }
        }
    }
}
