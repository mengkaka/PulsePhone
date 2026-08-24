import Darwin

public struct MonotonicDuration: Hashable, Comparable, Sendable {
    public let nanoseconds: UInt64

    public init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    public init(milliseconds: UInt64) throws {
        let (nanoseconds, overflow) = milliseconds.multipliedReportingOverflow(
            by: 1_000_000
        )
        guard !overflow else {
            throw SharedPrimitiveError.integerOverflow
        }
        self.nanoseconds = nanoseconds
    }

    public var wholeMilliseconds: UInt64 {
        nanoseconds / 1_000_000
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }
}

public struct MonotonicInstant: Hashable, Comparable, Sendable {
    public let nanoseconds: UInt64

    public init(nanoseconds: UInt64) {
        self.nanoseconds = nanoseconds
    }

    public static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.nanoseconds < rhs.nanoseconds
    }

    public func advanced(by duration: MonotonicDuration) throws -> Self {
        let (result, overflow) = nanoseconds.addingReportingOverflow(
            duration.nanoseconds
        )
        guard !overflow else {
            throw SharedPrimitiveError.integerOverflow
        }
        return Self(nanoseconds: result)
    }

    public func duration(since earlier: Self) throws -> MonotonicDuration {
        guard nanoseconds >= earlier.nanoseconds else {
            throw SharedPrimitiveError.nonMonotonicOrder
        }
        return MonotonicDuration(nanoseconds: nanoseconds - earlier.nanoseconds)
    }
}

public protocol MonotonicClock: Sendable {
    func now() -> MonotonicInstant
}

public struct SystemMonotonicClock: MonotonicClock, Sendable {
    private let numerator: UInt64
    private let denominator: UInt64

    public init() {
        var timebase = mach_timebase_info_data_t()
        let result = mach_timebase_info(&timebase)
        precondition(result == KERN_SUCCESS && timebase.denom != 0)
        self.numerator = UInt64(timebase.numer)
        self.denominator = UInt64(timebase.denom)
    }

    public func now() -> MonotonicInstant {
        do {
            return MonotonicInstant(
                nanoseconds: try Self.convertToNanoseconds(
                    ticks: mach_continuous_time(),
                    numerator: numerator,
                    denominator: denominator
                )
            )
        } catch {
            preconditionFailure("mach_continuous_time conversion overflow")
        }
    }

    static func convertToNanoseconds(
        ticks: UInt64,
        numerator: UInt64,
        denominator: UInt64
    ) throws -> UInt64 {
        guard numerator != 0, denominator != 0 else {
            throw SharedPrimitiveError.invalidTimebase
        }

        let wholeTicks = ticks / denominator
        let remainderTicks = ticks % denominator
        let (wholeNanoseconds, wholeOverflow) = wholeTicks
            .multipliedReportingOverflow(by: numerator)
        let (remainderProduct, remainderOverflow) = remainderTicks
            .multipliedReportingOverflow(by: numerator)
        guard !wholeOverflow, !remainderOverflow else {
            throw SharedPrimitiveError.integerOverflow
        }

        let fractionalNanoseconds = remainderProduct / denominator
        let (result, additionOverflow) = wholeNanoseconds
            .addingReportingOverflow(fractionalNanoseconds)
        guard !additionOverflow else {
            throw SharedPrimitiveError.integerOverflow
        }
        return result
    }
}
