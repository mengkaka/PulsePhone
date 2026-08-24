import Darwin
import Foundation
import PulsePhoneCLI
import PulsePhoneLogging
import PulsePhoneSharedDefinitions
import XCTest

final class ActionLogMaintenanceTests: XCTestCase {
    func testPruneDeletesOnlyEligibleClosedActionFiles() throws {
        let target = try CanonicalUDID(canonicalString: "A")
        let result = ActionLogMaintenance.prune(
            targets: [ActionLogMaintenanceTarget(
                canonicalUDID: target,
                identityValid: true,
                files: [
                    file("identity.v1.json", kind: .identity, ageDays: 20),
                    file("writer.lock", kind: .writerLock, ageDays: 20),
                    file("actions-old.jsonl", ageDays: 8),
                    file("actions-busy.jsonl", ageDays: 8, lock: false),
                    file("actions-new.jsonl", ageDays: 1),
                ]
            )],
            nowEpochSeconds: now
        )
        XCTAssertEqual(result.deletedFileCount, 1)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertTrue(result.scanComplete)
    }

    func testCountAndPerTargetByteCapsDeleteOldestFirst() throws {
        let target = try CanonicalUDID(canonicalString: "A")
        let files = (0..<7).map { index in
            ActionLogMaintenanceFile(
                fileName: "actions-\(index).jsonl",
                nodeKind: .actionFile,
                byteCount: 10 * 1_024 * 1_024,
                closedAtEpochSeconds: UInt64(index + 1),
                writerLockAvailable: true
            )
        }
        let result = ActionLogMaintenance.prune(
            targets: [ActionLogMaintenanceTarget(
                canonicalUDID: target,
                identityValid: true,
                files: files
            )],
            nowEpochSeconds: 100
        )
        XCTAssertEqual(result.deletedFileCount, 2)
        XCTAssertEqual(result.deletedByteCount, 20 * 1_024 * 1_024)
        XCTAssertEqual(result.outcome, .succeeded)
    }

    func testGlobalCapUsesStableCrossTargetOrder() throws {
        let targets = try ["F", "E", "D", "C", "B", "A"].map { value in
            ActionLogMaintenanceTarget(
                canonicalUDID: try CanonicalUDID(canonicalString: value),
                identityValid: true,
                files: [ActionLogMaintenanceFile(
                    fileName: "actions-0.jsonl",
                    nodeKind: .actionFile,
                    byteCount: 50 * 1_024 * 1_024,
                    closedAtEpochSeconds: 1,
                    writerLockAvailable: true
                )]
            )
        }
        let result = ActionLogMaintenance.prune(
            targets: targets,
            nowEpochSeconds: 100
        )
        XCTAssertEqual(result.deletedFileCount, 1)
        XCTAssertEqual(result.deletedByteCount, 50 * 1_024 * 1_024)
    }

    func testByteAccountingSaturatesInsteadOfWrapping() throws {
        let target = try CanonicalUDID(canonicalString: "A")
        let result = ActionLogMaintenance.prune(
            targets: [ActionLogMaintenanceTarget(
                canonicalUDID: target,
                identityValid: true,
                files: [
                    ActionLogMaintenanceFile(
                        fileName: "actions-0.jsonl",
                        nodeKind: .actionFile,
                        byteCount: UInt64.max,
                        closedAtEpochSeconds: 1,
                        writerLockAvailable: true
                    ),
                    ActionLogMaintenanceFile(
                        fileName: "actions-1.jsonl",
                        nodeKind: .actionFile,
                        byteCount: 1,
                        closedAtEpochSeconds: 2,
                        writerLockAvailable: true
                    ),
                ]
            )],
            nowEpochSeconds: 100
        )
        XCTAssertEqual(result.deletedFileCount, 1)
        XCTAssertEqual(result.deletedByteCount, UInt64.max)
        XCTAssertEqual(result.outcome, .succeeded)
    }

    func testDeadlineAndSamplesAreBounded() throws {
        let target = try CanonicalUDID(canonicalString: "A")
        let files = (0..<100).map { index in
            ActionLogMaintenanceFile(
                fileName: "actions-\(index).jsonl",
                nodeKind: .actionFile,
                byteCount: 1,
                closedAtEpochSeconds: 0,
                writerLockAvailable: false
            )
        }
        let result = ActionLogMaintenance.prune(
            targets: [ActionLogMaintenanceTarget(
                canonicalUDID: target,
                identityValid: true,
                files: files
            )],
            nowEpochSeconds: now,
            startedAtNanoseconds: 0,
            scanCostNanosecondsPerNode: 1_000_000_000
        )
        XCTAssertFalse(result.scanComplete)
        XCTAssertLessThanOrEqual(
            result.skippedSample.count,
            ActionLogMaintenance.maximumSampleCount
        )
        XCTAssertEqual(LogsPruneCommand.exitCode(for: result), 6)
    }

    func testInvalidIdentityFailsClosedWithoutGuessingFiles() throws {
        let result = ActionLogMaintenance.prune(
            targets: [ActionLogMaintenanceTarget(
                canonicalUDID: try CanonicalUDID(canonicalString: "A"),
                identityValid: false,
                files: [file("actions-old.jsonl", ageDays: 9)]
            )],
            nowEpochSeconds: now
        )
        XCTAssertEqual(result.deletedFileCount, 0)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.outcome, .partial)
    }

    func testClearRoutesActiveWriterThroughRuntime() {
        XCTAssertEqual(
            LogsClearCommand.route(runtimePresence: .compatible),
            .runtimeRotateCloseReopen
        )
        XCTAssertEqual(
            LogsClearCommand.route(runtimePresence: .absent),
            .localClosedFiles
        )
        XCTAssertEqual(
            LogsClearCommand.route(runtimePresence: .incompatible),
            .unavailable
        )
        XCTAssertFalse(LogsPruneCommand.runtimeActivationRequested)
    }

    func testClearAllUsesFixedUniqueBoundedSnapshotAndExitPriority() throws {
        XCTAssertEqual(
            try LogsClearCommand.fixedTargetSnapshot([
                CanonicalUDID(canonicalString: "B"),
                CanonicalUDID(canonicalString: "A"),
            ]).map(\.rawValue),
            ["A", "B"]
        )
        XCTAssertThrowsError(try LogsClearCommand.fixedTargetSnapshot([
            CanonicalUDID(canonicalString: "A"),
            CanonicalUDID(canonicalString: "A"),
        ]))
        XCTAssertEqual(LogsClearCommand.exitCode(completed: 1, failed: 1, unknown: 1), 7)
        XCTAssertEqual(LogsClearCommand.exitCode(completed: 1, failed: 1, unknown: 0), 6)
        XCTAssertEqual(LogsClearCommand.exitCode(completed: 1, failed: 0, unknown: 0), 0)
    }

    func testProductionMissingRootIsSuccessfulAndDoesNotCreateIt() throws {
        let root = temporaryRoot().appendingPathComponent("missing", isDirectory: true)
        let maintenance = ProductionActionLogMaintenance(rootPath: root.path)
        let prune = try maintenance.prune(nowEpochSeconds: now)
        let clear = try maintenance.clearAll()
        XCTAssertEqual(prune.outcome, .succeeded)
        XCTAssertEqual(clear.outcome, .succeeded)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testProductionPruneAndClearDeleteOnlyLockedClosedActionFiles() throws {
        let root = temporaryRoot().appendingPathComponent("ActionLogs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let targetA = try CanonicalUDID(canonicalString: "AAAA")
        let targetB = try CanonicalUDID(canonicalString: "BBBB")
        let old = "actions-20200101T000000Z-00000000-0000-0000-0000-000000000001.jsonl"
        let fresh = "actions-20260720T000000Z-00000000-0000-0000-0000-000000000002.jsonl"
        try makeTarget(root: root, target: targetA, files: [old, fresh])
        try makeTarget(root: root, target: targetB, files: [fresh])
        try setModificationDate(
            now - 8 * 24 * 60 * 60,
            for: root.appendingPathComponent(targetA.domainSeparatedHash)
                .appendingPathComponent(old)
        )
        for target in [targetA, targetB] {
            try setModificationDate(
                now - 24 * 60 * 60,
                for: root.appendingPathComponent(target.domainSeparatedHash)
                    .appendingPathComponent(fresh)
            )
        }

        let maintenance = ProductionActionLogMaintenance(rootPath: root.path)
        let prune = try maintenance.prune(nowEpochSeconds: now)
        XCTAssertEqual(prune.deletedFileCount, 1)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(targetA.domainSeparatedHash)
                .appendingPathComponent(old).path
        ))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(targetA.domainSeparatedHash)
                .appendingPathComponent(fresh).path
        ))

        let clear = try maintenance.clearAll()
        XCTAssertEqual(clear.deletedFileCount, 2)
        for target in [targetA, targetB] {
            let directory = root.appendingPathComponent(target.domainSeparatedHash)
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("identity.v1.json").path
            ))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("writer.lock").path
            ))
        }
    }

    func testProductionMaintenanceLockContentionFailsWithoutScanning() throws {
        let root = temporaryRoot().appendingPathComponent("ActionLogs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let lockPath = root.appendingPathComponent("actionlog-maintenance.lock").path
        let descriptor = Darwin.open(lockPath, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
        }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)

        XCTAssertThrowsError(
            try ProductionActionLogMaintenance(rootPath: root.path).prune(nowEpochSeconds: now)
        ) { error in
            XCTAssertEqual(
                error as? ProductionActionLogMaintenanceError,
                .maintenanceBusy
            )
        }
    }

    func testProductionWriterLockContentionSkipsFiles() throws {
        let root = temporaryRoot().appendingPathComponent("ActionLogs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let target = try CanonicalUDID(canonicalString: "AAAA")
        let file = "actions-20260720T000000Z-00000000-0000-0000-0000-000000000001.jsonl"
        try makeTarget(root: root, target: target, files: [file])
        let targetDirectory = root.appendingPathComponent(target.domainSeparatedHash)
        let descriptor = Darwin.open(
            targetDirectory.appendingPathComponent("writer.lock").path,
            O_RDWR | O_CLOEXEC
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
        }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)

        let result = try ProductionActionLogMaintenance(rootPath: root.path).clearAll()
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertEqual(result.deletedFileCount, 0)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: targetDirectory.appendingPathComponent(file).path
        ))
    }

    func testProductionIdentityMismatchFailsClosed() throws {
        let root = temporaryRoot().appendingPathComponent("ActionLogs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let directoryTarget = try CanonicalUDID(canonicalString: "AAAA")
        let identityTarget = try CanonicalUDID(canonicalString: "BBBB")
        let file = "actions-20260720T000000Z-00000000-0000-0000-0000-000000000001.jsonl"
        try makeTarget(root: root, target: directoryTarget, files: [file])
        try writeIdentity(
            identityTarget,
            to: root.appendingPathComponent(directoryTarget.domainSeparatedHash)
        )

        let result = try ProductionActionLogMaintenance(rootPath: root.path).clearAll()
        XCTAssertEqual(result.outcome, .partial)
        XCTAssertEqual(result.deletedFileCount, 0)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(directoryTarget.domainSeparatedHash)
                .appendingPathComponent(file).path
        ))
    }

    func testProductionCLIOutputPreservesTargetAndPartialFailure() throws {
        let root = temporaryRoot().appendingPathComponent("ActionLogs", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let target = try CanonicalUDID(canonicalString: "AAAA")
        let file = "actions-20260720T000000Z-00000000-0000-0000-0000-000000000001.jsonl"
        try makeTarget(root: root, target: target, files: [file])
        let descriptor = Darwin.open(
            root.appendingPathComponent(target.domainSeparatedHash)
                .appendingPathComponent("writer.lock").path,
            O_RDWR | O_CLOEXEC
        )
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer {
            _ = flock(descriptor, LOCK_UN)
            _ = Darwin.close(descriptor)
        }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)

        let output = try LogsClearCommand.runProductionDevice(
            canonicalUDID: target,
            maintenance: ProductionActionLogMaintenance(rootPath: root.path),
            outputMode: .json
        )
        XCTAssertEqual(output.exitCode, 6)
        let payload = try XCTUnwrap(output.chunk.stdout.first)
        XCTAssertTrue(payload.contains("\"commandID\":\"logs.clear.device\""))
        XCTAssertTrue(payload.contains("\"udid\":\"AAAA\""))
        XCTAssertTrue(payload.contains("\"code\":\"partialFailure\""))
    }

    func testProductionRejectsSymlinkRootWithoutTouchingTarget() throws {
        let base = temporaryRoot()
        let target = base.appendingPathComponent("target", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let sentinel = target.appendingPathComponent("sentinel")
        XCTAssertTrue(FileManager.default.createFile(atPath: sentinel.path, contents: Data()))
        let link = base.appendingPathComponent("ActionLogs")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertThrowsError(
            try ProductionActionLogMaintenance(rootPath: link.path).clearAll()
        ) { error in
            XCTAssertEqual(
                error as? ProductionActionLogMaintenanceError,
                .unsafeHostPath
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: sentinel.path))
    }

    private let now: UInt64 = 10 * 24 * 60 * 60

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pulsephone-log-maintenance-\(UUID().uuidString)",
            isDirectory: true
        )
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func makeTarget(
        root: URL,
        target: CanonicalUDID,
        files: [String]
    ) throws {
        let directory = root.appendingPathComponent(
            target.domainSeparatedHash,
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        try writeIdentity(target, to: directory)
        XCTAssertTrue(FileManager.default.createFile(
            atPath: directory.appendingPathComponent("writer.lock").path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        ))
        for file in files {
            XCTAssertTrue(FileManager.default.createFile(
                atPath: directory.appendingPathComponent(file).path,
                contents: Data("{}\n".utf8),
                attributes: [.posixPermissions: 0o600]
            ))
        }
        _ = chmod(directory.path, 0o700)
    }

    private func writeIdentity(
        _ target: CanonicalUDID,
        to directory: URL
    ) throws {
        let identity = try RepositoryJSONObject(members: [
            .init(key: "canonicalUDID", value: .string(target.rawValue)),
            .init(key: "canonicalUDIDHash", value: .string(target.domainSeparatedHash)),
            .init(key: "createdAtUTC", value: .string("2026-07-20T00:00:00Z")),
            .init(key: "schemaVersion", value: .number(.uint64(1))),
        ])
        try Data(RepositoryCanonicalJSON.encodeDocument(identity)).write(
            to: directory.appendingPathComponent("identity.v1.json")
        )
        _ = chmod(directory.appendingPathComponent("identity.v1.json").path, 0o600)
    }

    private func setModificationDate(_ epochSeconds: UInt64, for file: URL) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: TimeInterval(epochSeconds))],
            ofItemAtPath: file.path
        )
    }

    private func file(
        _ name: String,
        kind: ActionLogMaintenanceNodeKind = .actionFile,
        ageDays: UInt64,
        lock: Bool = true
    ) -> ActionLogMaintenanceFile {
        let ageSeconds = ageDays * 24 * 60 * 60
        return ActionLogMaintenanceFile(
            fileName: name,
            nodeKind: kind,
            byteCount: 1_024,
            closedAtEpochSeconds: ageSeconds >= now ? 0 : now - ageSeconds,
            writerLockAvailable: lock
        )
    }
}
