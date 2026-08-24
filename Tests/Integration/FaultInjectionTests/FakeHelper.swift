enum FakeHelperError: Error, Equatable {
    case alreadyCrashed
    case invalidGeneration
    case zeroExitIsNotCrash
}

struct FakeHelper: Equatable, Sendable {
    let generation: UInt64
    private(set) var crashExitCode: Int32?

    init(generation: UInt64) throws {
        guard generation > 0 else { throw FakeHelperError.invalidGeneration }
        self.generation = generation
    }

    mutating func crash(exitCode: Int32) throws {
        guard exitCode != 0 else { throw FakeHelperError.zeroExitIsNotCrash }
        guard crashExitCode == nil else { throw FakeHelperError.alreadyCrashed }
        crashExitCode = exitCode
    }
}
