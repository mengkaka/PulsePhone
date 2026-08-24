import Foundation
import PulsePhoneBackendAdapters
import PulsePhoneCLI
import PulsePhoneClientCore
import PulsePhoneSharedDefinitions
import XCTest

final class AppLaunchTests: XCTestCase {
    func testCanonicalFixtureFreezesOSDisjointRoutes() throws {
        for fixture in try loadFixtures() {
            let route = try AppLaunchRoute.resolve(osMajor: fixture.osMajor)
            XCTAssertEqual(route.rawValue, fixture.expectedRouteID)
            XCTAssertEqual(route.preparationGroupID, fixture.expectedGroupID)
        }
        XCTAssertThrowsError(try AppLaunchRoute.resolve(osMajor: 13)) {
            XCTAssertEqual(
                $0 as? AppLaunchActionError,
                .unsupportedOSMajor(13)
            )
        }
    }

    func testModernAndLegacyCallOnlyTheirOwnBackend() throws {
        let modern = RecordingAppLaunchTransport(complete: true)
        let modernResult = try AppLaunchAction(transport: modern).execute(
            bundleID: "com.example.App",
            osMajor: 26,
            preparation: ready("prep.coredevice.v2")
        )
        XCTAssertEqual(modernResult.route, .modernCoreDevice)
        XCTAssertEqual(modern.modernCount, 1)
        XCTAssertEqual(modern.legacyCount, 0)

        let legacy = RecordingAppLaunchTransport(complete: true)
        let legacyResult = try AppLaunchAction(transport: legacy).execute(
            bundleID: "com.example.App",
            osMajor: 16,
            preparation: ready("prep.legacy.developer.v2")
        )
        XCTAssertEqual(legacyResult.route, .legacyDVT)
        XCTAssertEqual(legacy.modernCount, 0)
        XCTAssertEqual(legacy.legacyCount, 1)
    }

    func testPreparationMustMatchSelectedRouteBeforeBackend() {
        let transport = RecordingAppLaunchTransport(complete: true)
        XCTAssertThrowsError(try AppLaunchAction(transport: transport).execute(
            bundleID: "com.example.App",
            osMajor: 26,
            preparation: ready("prep.legacy.developer.v2")
        )) { error in
            XCTAssertEqual(
                error as? AppLaunchActionError,
                .preparationGroupMismatch(
                    expected: "prep.coredevice.v2",
                    actual: "prep.legacy.developer.v2"
                )
            )
        }
        XCTAssertEqual(transport.totalLaunchCount, 0)
    }

    func testDeveloperSupportFailureIsPreservedExactly() {
        let transport = RecordingAppLaunchTransport(complete: true)
        XCTAssertThrowsError(try AppLaunchAction(transport: transport).execute(
            bundleID: "com.example.App",
            osMajor: 16,
            preparation: AppLaunchPreparation(
                preparationGroupID: "prep.legacy.developer.v2",
                state: .failed(code: "developerImageMountFailed")
            )
        )) { error in
            XCTAssertEqual(
                error as? AppLaunchActionError,
                .developerSupportFailure("developerImageMountFailed")
            )
        }
        XCTAssertEqual(transport.totalLaunchCount, 0)
    }

    func testBackendFailureDoesNotCrossFallback() {
        let modern = RecordingAppLaunchTransport(complete: false)
        XCTAssertThrowsError(try AppLaunchAction(transport: modern).execute(
            bundleID: "com.example.App",
            osMajor: 26,
            preparation: ready("prep.coredevice.v2")
        )) { error in
            XCTAssertEqual(
                error as? AppLaunchActionError,
                .backendDidNotComplete
            )
        }
        XCTAssertEqual(modern.modernCount, 1)
        XCTAssertEqual(modern.legacyCount, 0)
        XCTAssertEqual(modern.waitCount, 1)
    }

    func testCLIProjectsLaunchRequestedAndUnknownOutcome() throws {
        let target = try CanonicalUDID(canonicalString: "AAAA")
        let success = try AppLaunchCommand(submitter: CommandSubmitter(runtime:
            AppLaunchRuntime(outcome: .succeeded)
        )).run(
            bundleID: "com.example.App",
            requestID: uuid(1),
            actionID: uuid(2),
            canonicalUDID: target,
            outputMode: .json
        )
        XCTAssertTrue(success.chunk.stdout[0].contains("launchRequested"))

        let unknown = try AppLaunchCommand(submitter: CommandSubmitter(runtime:
            AppLaunchRuntime(outcome: .outcomeUnknown)
        )).run(
            bundleID: "com.example.App",
            requestID: uuid(3),
            actionID: uuid(4),
            canonicalUDID: target,
            outputMode: .json
        )
        XCTAssertEqual(unknown.exitCode, 7)
    }

    private func ready(_ groupID: String) -> AppLaunchPreparation {
        AppLaunchPreparation(preparationGroupID: groupID, state: .ready)
    }

    private func loadFixtures() throws -> [AppLaunchFixture] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/product-actions/app-launch-route/cases.v1.json")
        let bytes = [UInt8](try Data(contentsOf: url))
        _ = try RepositoryCanonicalJSON.parseDocument(
            bytes,
            maximumByteCount: 64 * 1_024
        )
        return try JSONDecoder().decode(
            AppLaunchFixtureDocument.self,
            from: Data(bytes)
        ).cases
    }

    private func uuid(_ value: Int) throws -> CanonicalUUID {
        try CanonicalUUID(
            String(format: "00000000-0000-0000-0000-%012x", value)
        )
    }
}

private struct AppLaunchFixtureDocument: Decodable {
    let cases: [AppLaunchFixture]
}

private struct AppLaunchFixture: Decodable {
    let expectedGroupID: String
    let expectedRouteID: String
    let osMajor: UInt64
}

private final class RecordingAppLaunchTransport: AppLaunchTransport,
    @unchecked Sendable
{
    private let complete: Bool
    private(set) var legacyCount = 0
    private(set) var modernCount = 0
    private(set) var waitCount = 0

    init(complete: Bool) {
        self.complete = complete
    }

    var totalLaunchCount: Int { legacyCount + modernCount }

    func launchCoreDevice(bundleID: String) throws {
        XCTAssertEqual(bundleID, "com.example.App")
        modernCount += 1
    }

    func launchLegacyDVT(bundleID: String) throws {
        XCTAssertEqual(bundleID, "com.example.App")
        legacyCount += 1
    }

    func waitForLaunchComplete(
        route: AppLaunchRoute,
        timeoutMilliseconds: UInt64
    ) throws -> Bool {
        XCTAssertEqual(timeoutMilliseconds, 60_000)
        waitCount += 1
        return complete
    }
}

private struct AppLaunchRuntime: CommandSubmissionRuntime {
    let outcome: StandardOutcome

    func submit(
        _ intent: CommandSubmissionIntent
    ) throws -> [CommandSubmissionEvent] {
        XCTAssertEqual(intent.commandID, "app.launch")
        XCTAssertEqual(intent.rawArguments, ["bundleID": "com.example.App"])
        let terminal = try CommandSubmissionTerminal(
            outcome: outcome,
            commitState: outcome == .succeeded ? .committed : .unknown,
            routeID: outcome == .succeeded ? "coredevice.appLaunch" : nil,
            errorCode: outcome == .succeeded ? nil : "outcomeUnknown"
        )
        return [
            .accepted,
            .authoritativePlan(
                routeID: "coredevice.appLaunch",
                sourceRevision: 1,
                resumedAfterPreparation: false
            ),
            .queued,
            .started(routeID: "coredevice.appLaunch"),
            .terminal(terminal),
        ]
    }
}
