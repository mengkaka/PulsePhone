import Foundation
import PulsePhoneBackendAdapters
import PulsePhoneCLI
import PulsePhoneClientCore
import PulsePhoneSharedDefinitions
import XCTest

final class AppInstallationTests: XCTestCase {
    func testAFCUploadUsesAtMostOneMiBChunks() throws {
        let transport = RecordingInstallTransport(
            sourceByteCount: 2 * 1_024 * 1_024 + 17,
            installBundleID: "com.example.App"
        )
        let upload = try AFCUploadAction(transport: transport).execute()
        XCTAssertEqual(upload.bytesUploaded, 2 * 1_024 * 1_024 + 17)
        XCTAssertEqual(upload.chunkCount, 3)
        XCTAssertEqual(
            transport.readMaximums,
            [1_048_576, 1_048_576, 1_048_576, 1_048_576]
        )
        XCTAssertEqual(transport.writtenSizes, [1_048_576, 1_048_576, 17])
    }

    func testOversizedSourceChunkFailsBeforeDeviceWrite() {
        let transport = RecordingInstallTransport(
            sourceByteCount: 1,
            installBundleID: "com.example.App",
            forceOversizedChunk: true
        )
        XCTAssertThrowsError(try AFCUploadAction(transport: transport).execute()) {
            XCTAssertEqual(
                $0 as? AFCUploadError,
                .invalidSourceChunk(actualBytes: 1_048_577)
            )
        }
        XCTAssertTrue(transport.writtenSizes.isEmpty)
    }

    func testInstallSucceedsOnlyAfterBackendComplete() throws {
        let transport = RecordingInstallTransport(
            sourceByteCount: 12,
            installBundleID: "com.example.App"
        )
        let execution = try InstallAction(transport: transport).execute()
        XCTAssertEqual(execution.result, AppOperationActionResult(
            bundleID: "com.example.App",
            disposition: "installed"
        ))
        XCTAssertEqual(transport.finishCount, 1)
        XCTAssertEqual(transport.installWaitCount, 1)
    }

    func testMissingInstallCompleteFailsWithoutRollbackOrRetry() {
        let transport = RecordingInstallTransport(
            sourceByteCount: 12,
            installBundleID: nil
        )
        XCTAssertThrowsError(try InstallAction(transport: transport).execute()) {
            XCTAssertEqual(
                $0 as? AppInstallationActionError,
                .backendDidNotComplete
            )
        }
        XCTAssertEqual(transport.finishCount, 1)
        XCTAssertEqual(transport.installWaitCount, 1)
    }

    func testUninstallRequiresBackendComplete() throws {
        let success = RecordingUninstallTransport(complete: true)
        XCTAssertEqual(
            try UninstallAction(transport: success).execute(
                bundleID: "com.example.App"
            ).disposition,
            "uninstalled"
        )
        let failure = RecordingUninstallTransport(complete: false)
        XCTAssertThrowsError(try UninstallAction(transport: failure).execute(
            bundleID: "com.example.App"
        ))
        XCTAssertEqual(failure.requestCount, 1)
        XCTAssertEqual(failure.waitCount, 1)
    }

    func testCLIValidatesPathAndBundleAndProjectsResults() throws {
        let target = try CanonicalUDID(canonicalString: "AAAA")
        let install = try InstallCommand(submitter: submitter(
            commandID: "app.install",
            routeID: "direct.installationProxy.install",
            arguments: ["ipaPath": "/tmp/App.ipa"]
        )).run(
            ipaPath: "/tmp/App.ipa",
            installedBundleID: "com.example.App",
            requestID: uuid(1),
            actionID: uuid(2),
            canonicalUDID: target,
            outputMode: .json
        )
        XCTAssertTrue(install.chunk.stdout[0].contains("com.example.App"))

        let uninstall = try UninstallCommand(submitter: submitter(
            commandID: "app.uninstall",
            routeID: "direct.installationProxy.uninstall",
            arguments: ["bundleID": "com.example.App"]
        )).run(
            bundleID: "com.example.App",
            requestID: uuid(3),
            actionID: uuid(4),
            canonicalUDID: target,
            outputMode: .human
        )
        XCTAssertEqual(uninstall.chunk.stdout, ["Uninstalled com.example.App"])

        XCTAssertThrowsError(try InstallCommand(submitter: submitter(
            commandID: "app.install",
            routeID: "direct.installationProxy.install",
            arguments: [:]
        )).run(
            ipaPath: "relative.ipa",
            installedBundleID: "unused",
            requestID: uuid(5),
            actionID: uuid(6),
            canonicalUDID: target,
            outputMode: .human
        ))
    }

    private func submitter(
        commandID: String,
        routeID: String,
        arguments: [String: String]
    ) -> CommandSubmitter {
        CommandSubmitter(runtime: AppInstallationRuntime(
            arguments: arguments,
            commandID: commandID,
            routeID: routeID
        ))
    }

    private func uuid(_ value: Int) throws -> CanonicalUUID {
        try CanonicalUUID(
            String(format: "00000000-0000-0000-0000-%012x", value)
        )
    }
}

private final class RecordingInstallTransport: InstallTransport,
    @unchecked Sendable
{
    private let forceOversizedChunk: Bool
    private let installBundleID: String?
    private let sourceByteCount: Int
    private(set) var finishCount = 0
    private(set) var installWaitCount = 0
    private(set) var readMaximums = [Int]()
    private(set) var writtenSizes = [Int]()

    init(
        sourceByteCount: Int,
        installBundleID: String?,
        forceOversizedChunk: Bool = false
    ) {
        self.sourceByteCount = sourceByteCount
        self.installBundleID = installBundleID
        self.forceOversizedChunk = forceOversizedChunk
    }

    func readSourceChunk(
        offset: UInt64,
        maximumBytes: Int
    ) throws -> [UInt8] {
        readMaximums.append(maximumBytes)
        if forceOversizedChunk {
            return [UInt8](repeating: 0, count: maximumBytes + 1)
        }
        let remaining = max(0, sourceByteCount - Int(offset))
        return [UInt8](repeating: 0, count: min(remaining, maximumBytes))
    }

    func writeDeviceChunk(
        _ bytes: [UInt8],
        offset: UInt64
    ) throws {
        writtenSizes.append(bytes.count)
    }

    func finishAFCUpload() throws {
        finishCount += 1
    }

    func waitForInstallComplete(
        timeoutMilliseconds: UInt64
    ) throws -> String? {
        XCTAssertEqual(timeoutMilliseconds, 1_800_000)
        installWaitCount += 1
        return installBundleID
    }
}

private final class RecordingUninstallTransport: UninstallTransport,
    @unchecked Sendable
{
    private let complete: Bool
    private(set) var requestCount = 0
    private(set) var waitCount = 0

    init(complete: Bool) {
        self.complete = complete
    }

    func requestUninstall(bundleID: String) throws {
        XCTAssertEqual(bundleID, "com.example.App")
        requestCount += 1
    }

    func waitForUninstallComplete(
        bundleID: String,
        timeoutMilliseconds: UInt64
    ) throws -> Bool {
        XCTAssertEqual(bundleID, "com.example.App")
        XCTAssertEqual(timeoutMilliseconds, 300_000)
        waitCount += 1
        return complete
    }
}

private struct AppInstallationRuntime: CommandSubmissionRuntime {
    let arguments: [String: String]
    let commandID: String
    let routeID: String

    func submit(
        _ intent: CommandSubmissionIntent
    ) throws -> [CommandSubmissionEvent] {
        XCTAssertEqual(intent.commandID, commandID)
        XCTAssertEqual(intent.rawArguments, arguments)
        let terminal = try CommandSubmissionTerminal(
            outcome: .succeeded,
            commitState: .committed,
            routeID: routeID
        )
        return [
            .accepted,
            .authoritativePlan(
                routeID: routeID,
                sourceRevision: 1,
                resumedAfterPreparation: false
            ),
            .queued,
            .started(routeID: routeID),
            .terminal(terminal),
        ]
    }
}
