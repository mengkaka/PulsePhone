enum FakeDeviceError: Error, Equatable {
    case alreadyDetached
    case invalidInitialEpoch
    case epochOverflow
}

struct FakeDevice: Equatable, Sendable {
    private(set) var connectionEpoch: UInt64
    private(set) var isAttached = true

    init(connectionEpoch: UInt64) throws {
        guard connectionEpoch > 0 else {
            throw FakeDeviceError.invalidInitialEpoch
        }
        self.connectionEpoch = connectionEpoch
    }

    @discardableResult
    mutating func detach() throws -> (previous: UInt64, current: UInt64) {
        guard isAttached else { throw FakeDeviceError.alreadyDetached }
        let previous = connectionEpoch
        let (current, overflow) = connectionEpoch.addingReportingOverflow(1)
        guard !overflow else { throw FakeDeviceError.epochOverflow }
        connectionEpoch = current
        isAttached = false
        return (previous, current)
    }
}
