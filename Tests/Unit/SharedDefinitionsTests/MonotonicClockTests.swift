import XCTest
@testable import PulsePhoneSharedDefinitions

final class MonotonicClockTests: XCTestCase {
    private struct FixedClock: MonotonicClock {
        let instant: MonotonicInstant

        func now() -> MonotonicInstant {
            instant
        }
    }

    func testInjectedClockDoesNotSleep() {
        let expected = MonotonicInstant(nanoseconds: 42)
        let clock = FixedClock(instant: expected)

        XCTAssertEqual(clock.now(), expected)
        XCTAssertEqual(clock.now(), expected)
    }

    func testDurationAndAdvanceUseCheckedNanoseconds() throws {
        let start = MonotonicInstant(nanoseconds: 2_000_000)
        let duration = try MonotonicDuration(milliseconds: 3)
        let end = try start.advanced(by: duration)

        XCTAssertEqual(end.nanoseconds, 5_000_000)
        XCTAssertEqual(try end.duration(since: start), duration)
        XCTAssertEqual(duration.wholeMilliseconds, 3)
        XCTAssertEqual(
            MonotonicDuration(nanoseconds: 3_999_999).wholeMilliseconds,
            3
        )
    }

    func testInvalidOrderAndIntegerOverflowAreRejected() {
        XCTAssertThrowsError(
            try MonotonicInstant(nanoseconds: 1)
                .duration(since: MonotonicInstant(nanoseconds: 2))
        ) { error in
            XCTAssertEqual(error as? SharedPrimitiveError, .nonMonotonicOrder)
        }

        XCTAssertThrowsError(
            try MonotonicInstant(nanoseconds: .max)
                .advanced(by: MonotonicDuration(nanoseconds: 1))
        ) { error in
            XCTAssertEqual(error as? SharedPrimitiveError, .integerOverflow)
        }

        XCTAssertThrowsError(try MonotonicDuration(milliseconds: .max)) { error in
            XCTAssertEqual(error as? SharedPrimitiveError, .integerOverflow)
        }
    }

    func testMachTimebaseConversionAndBoundaries() throws {
        XCTAssertEqual(
            try SystemMonotonicClock.convertToNanoseconds(
                ticks: 9,
                numerator: 2,
                denominator: 3
            ),
            6
        )
        XCTAssertThrowsError(
            try SystemMonotonicClock.convertToNanoseconds(
                ticks: 1,
                numerator: 1,
                denominator: 0
            )
        ) { error in
            XCTAssertEqual(error as? SharedPrimitiveError, .invalidTimebase)
        }
        XCTAssertThrowsError(
            try SystemMonotonicClock.convertToNanoseconds(
                ticks: 1,
                numerator: 0,
                denominator: 1
            )
        ) { error in
            XCTAssertEqual(error as? SharedPrimitiveError, .invalidTimebase)
        }
        XCTAssertThrowsError(
            try SystemMonotonicClock.convertToNanoseconds(
                ticks: .max,
                numerator: 2,
                denominator: 1
            )
        ) { error in
            XCTAssertEqual(error as? SharedPrimitiveError, .integerOverflow)
        }
    }

    func testSystemClockIsNondecreasing() {
        let clock = SystemMonotonicClock()
        let first = clock.now()
        let second = clock.now()

        XCTAssertGreaterThanOrEqual(second, first)
    }
}
