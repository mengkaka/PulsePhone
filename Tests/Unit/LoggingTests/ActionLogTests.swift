import Foundation
import PulsePhoneLogging
import PulsePhoneSharedDefinitions
import XCTest

final class ActionLogTests: XCTestCase {
    func testIdentityAndSingleWriterFailClosed() throws {
        let target = try CanonicalUDID(canonicalString: "A")
        XCTAssertNoThrow(try ActionLogIdentity(
            canonicalUDID: target,
            canonicalUDIDHash: target.domainSeparatedHash,
            createdAtUTC: "2026-07-20T00:00:00Z"
        ))
        XCTAssertThrowsError(try ActionLogIdentity(
            canonicalUDID: target,
            canonicalUDIDHash: String(repeating: "0", count: 64),
            createdAtUTC: "2026-07-20T00:00:00Z"
        )) { error in
            XCTAssertEqual(error as? ActionLogError, .identityHashMismatch)
        }

        let first = ActionLogWriterClaim(
            canonicalUDID: target,
            runtimeEpoch: 7,
            writerID: try uuid(70)
        )
        let second = ActionLogWriterClaim(
            canonicalUDID: target,
            runtimeEpoch: 8,
            writerID: try uuid(71)
        )
        var registry = ActionLogSingleWriterRegistry()
        XCTAssertEqual(registry.acquire(first), .acquired)
        XCTAssertEqual(registry.acquire(first), .alreadyOwned)
        XCTAssertEqual(
            registry.acquire(second),
            .busy(existingWriterID: first.writerID)
        )
        XCTAssertThrowsError(try registry.release(second))
        try registry.release(first)
        XCTAssertEqual(registry.acquire(second), .acquired)
    }

    func testAppendOnceAllowsBeginOnlyAndTerminalOnly() throws {
        var writer = try ActionLogWriter(firstFileID: uuid(1))
        let begin = try beginEvent(action: 10)
        let terminal = try terminalEvent(action: 11)
        XCTAssertEqual(
            try writer.append(begin, nextFileID: { try self.uuid(2) }),
            .appended(fileID: try uuid(1), recordSequence: 0)
        )
        XCTAssertEqual(
            try writer.append(begin, nextFileID: { try self.uuid(2) }),
            .duplicateIgnored
        )
        XCTAssertEqual(
            try writer.append(terminal, nextFileID: { try self.uuid(2) }),
            .appended(fileID: try uuid(1), recordSequence: 1)
        )
        XCTAssertEqual(writer.files[0].records.count, 2)
    }

    func testRotationResetsOnlyPerFileSequence() throws {
        let sampleBytes = try ActionLogRecord(
            recordSequence: 0,
            event: beginEvent(action: 20, padding: 80)
        ).canonicalLineBytes().count
        var writer = try ActionLogWriter(
            firstFileID: uuid(3),
            maximumFileBytes: sampleBytes + 10
        )
        _ = try writer.append(beginEvent(action: 20, padding: 80)) {
            try self.uuid(4)
        }
        let second = try writer.append(terminalEvent(action: 20)) {
            try self.uuid(4)
        }
        XCTAssertEqual(second, .appended(fileID: try uuid(4), recordSequence: 0))
        XCTAssertTrue(writer.files[0].closed)
        XCTAssertEqual(writer.files.map { $0.records.map(\.recordSequence) }, [[0], [0]])
        XCTAssertEqual(ActionLogRotation.maximumFileBytes, 10 * 1_024 * 1_024)
    }

    func testRecoveryDropsTornTailAndRebuildsAppendOnceKeys() throws {
        let record = ActionLogRecord(
            recordSequence: 0,
            event: try beginEvent(action: 30)
        )
        let file = try ActionLogFile(
            fileID: uuid(5),
            records: [record],
            trailingTornByteCount: 17
        )
        var recovered = try ActionLogWriter(
            recovering: [file],
            nextFileOrdinal: 1
        )
        XCTAssertEqual(recovered.files[0].trailingTornByteCount, 0)
        XCTAssertEqual(
            try recovered.append(record.event, nextFileID: { try self.uuid(6) }),
            .duplicateIgnored
        )
        XCTAssertEqual(
            try recovered.append(try terminalEvent(action: 30)) {
                try self.uuid(6)
            },
            .appended(fileID: try uuid(5), recordSequence: 1)
        )
    }

    func testBestEffortFailureDoesNotReserveAppendKey() throws {
        let event = try beginEvent(action: 40)
        var writer = try ActionLogWriter(firstFileID: uuid(7))
        XCTAssertEqual(writer.appendBestEffort(
            event,
            sinkAvailable: false,
            nextFileID: { try self.uuid(8) }
        ), .droppedBestEffort)
        XCTAssertEqual(
            try writer.append(event, nextFileID: { try self.uuid(8) }),
            .appended(fileID: try uuid(7), recordSequence: 0)
        )
    }

    func testActionLogLifecycleRetentionRecoveryFixture() throws {
        let fixture = try loadFixture()
        let expected = try loadExpected()
        var writer = try ActionLogWriter(
            firstFileID: uuid(50),
            maximumFileBytes: fixture.maximumFileBytes
        )
        let begin = try beginEvent(
            action: fixture.actionID,
            padding: fixture.beginPaddingBytes
        )
        _ = try writer.append(begin) { try self.uuid(51) }
        XCTAssertEqual(
            try writer.append(begin) { try self.uuid(51) },
            .duplicateIgnored
        )
        _ = try writer.append(try terminalEvent(action: fixture.actionID)) {
            try self.uuid(51)
        }
        _ = try writer.append(try beginEvent(
            action: fixture.secondActionID,
            padding: fixture.secondBeginPaddingBytes
        )) { try self.uuid(51) }
        XCTAssertEqual(writer.files.count, expected.fileCountAfterRotation)
        XCTAssertEqual(
            writer.files.flatMap(\.records).count,
            expected.recordCount
        )

        var torn = writer.files
        torn[torn.count - 1] = try ActionLogFile(
            fileID: torn[torn.count - 1].fileID,
            records: torn[torn.count - 1].records,
            closed: torn[torn.count - 1].closed,
            trailingTornByteCount: fixture.trailingTornByteCount
        )
        let recovered = try ActionLogWriter(
            recovering: torn,
            nextFileOrdinal: UInt64(torn.count),
            maximumFileBytes: fixture.maximumFileBytes
        )
        XCTAssertEqual(
            recovered.files.last?.trailingTornByteCount,
            expected.trailingTornByteCountAfterRecovery
        )
        XCTAssertEqual(expected.closedFilesPrunedByWriter, 0)
    }

    func testCanonicalLineContainsNoUnredactedText() throws {
        let line = try ActionLogRecord(
            recordSequence: 0,
            event: beginEvent(action: 60)
        ).canonicalLineBytes()
        let text = String(decoding: line, as: UTF8.self)
        XCTAssertTrue(text.hasSuffix("\n"))
        XCTAssertTrue(text.contains("\"redactedArguments\""))
        XCTAssertFalse(text.contains("secret text"))
    }

    private func beginEvent(
        action: Int,
        padding: Int = 0
    ) throws -> ActionLogEvent {
        .begin(try ActionLogBegin(
            common: common(action: action),
            executionShape: "oneShot",
            redactedArguments: ["summary": String(repeating: "x", count: padding)],
            routeSummary: "direct"
        ))
    }

    private func terminalEvent(action: Int) throws -> ActionLogEvent {
        .terminal(try ActionLogTerminal(
            common: common(action: action),
            outcome: .succeeded,
            commitState: "committed",
            durationNanoseconds: 10,
            attemptSummary: "attempt-1",
            resultSummary: "completed",
            resultDelivery: .clientGone
        ))
    }

    private func common(action: Int) throws -> ActionLogCommon {
        try ActionLogCommon(
            actionID: uuid(action),
            canonicalUDID: CanonicalUDID(canonicalString: "A"),
            sourceRole: .runtime,
            commandID: "button.home",
            timestampUTC: "2026-07-20T00:00:00Z",
            runtimeEpoch: 7
        )
    }

    private func uuid(_ value: Int) throws -> CanonicalUUID {
        try CanonicalUUID(String(
            format: "00000000-0000-0000-0000-%012x",
            value
        ))
    }

    private func fixtureURL(_ relativePath: String) -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(
                "Fixtures/requirements/T-010/action-log-lifecycle-retention-recovery-l3/\(relativePath)"
            )
    }

    private func loadFixture() throws -> ActionLogFixture {
        try JSONDecoder().decode(
            ActionLogFixture.self,
            from: Data(contentsOf: fixtureURL("input/input.v1.json"))
        )
    }

    private func loadExpected() throws -> ActionLogExpected {
        try JSONDecoder().decode(
            ActionLogExpected.self,
            from: Data(contentsOf: fixtureURL("expected.v1.json"))
        )
    }
}

private struct ActionLogFixture: Decodable {
    let actionID: Int
    let beginPaddingBytes: Int
    let maximumFileBytes: Int
    let secondActionID: Int
    let secondBeginPaddingBytes: Int
    let trailingTornByteCount: Int
}

private struct ActionLogExpected: Decodable {
    let closedFilesPrunedByWriter: Int
    let fileCountAfterRotation: Int
    let recordCount: Int
    let trailingTornByteCountAfterRecovery: Int
}
