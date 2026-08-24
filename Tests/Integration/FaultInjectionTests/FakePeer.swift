import PulsePhoneSharedDefinitions

enum FakePeerError: Error, Equatable {
    case closed
    case invalidDrainLimit
}

struct FakePeer: Equatable, Sendable {
    private(set) var isOpen = true
    private(set) var malformedPayloads = [[UInt8]]()
    private(set) var maximumBytesPerDrain: Int?
    private(set) var stalledUntil: MonotonicInstant?

    mutating func injectEOF() throws {
        guard isOpen else { throw FakePeerError.closed }
        isOpen = false
    }

    mutating func injectMalformed(_ bytes: [UInt8]) throws {
        guard isOpen else { throw FakePeerError.closed }
        malformedPayloads.append(bytes)
    }

    mutating func configureSlowPeer(
        maximumBytesPerDrain: Int,
        stallNanoseconds: UInt64,
        now: MonotonicInstant
    ) throws {
        guard isOpen else { throw FakePeerError.closed }
        guard maximumBytesPerDrain > 0 else {
            throw FakePeerError.invalidDrainLimit
        }
        self.maximumBytesPerDrain = maximumBytesPerDrain
        stalledUntil = try now.advanced(
            by: MonotonicDuration(nanoseconds: stallNanoseconds)
        )
    }

    func drainCount(requestedBytes: Int, now: MonotonicInstant) throws -> Int {
        guard isOpen else { throw FakePeerError.closed }
        guard requestedBytes >= 0 else { throw FakePeerError.invalidDrainLimit }
        if let stalledUntil, now < stalledUntil { return 0 }
        return min(requestedBytes, maximumBytesPerDrain ?? requestedBytes)
    }
}
