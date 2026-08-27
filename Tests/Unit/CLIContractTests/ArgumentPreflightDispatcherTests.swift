import Foundation
import PulsePhoneCLI
@testable import PulsePhoneClientCore
import PulsePhoneDeveloperImageAssets
import PulsePhoneLogging
import PulsePhoneSharedDefinitions
import PulsePhoneWire
import XCTest

final class ArgumentPreflightDispatcherTests: XCTestCase {
    func testFactsProbeTimeoutUsesRetryablePublicError() throws {
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeProductVersion: Self.productVersion,
            makeQueries: { throw LocalDeviceFactsProbeError.workTimeout },
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            runtimeRequest: { _, _, _, _, _ in
                XCTFail("Runtime must not be contacted after probe timeout")
                return try Self.failedRuntimeResult(code: "runtimeFailed")
            }
        )

        let output = process.run(arguments: [
            "device", "prepare", "--udid", "AAAA", "--json",
        ])

        XCTAssertEqual(output.exitCode, 6)
        let envelope = try XCTUnwrap(try json(output.chunk.stdout[0]))
        XCTAssertEqual(envelope["commandID"] as? String, "device.prepare")
        XCTAssertEqual(
            envelope["target"] as? [String: String],
            ["requestedUDID": "AAAA", "scope": "unresolved"]
        )
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "probeUnavailable")
        XCTAssertEqual(error["message"] as? String, "Probe Unavailable")
        XCTAssertEqual(
            (error["details"] as? [String: String])?["reason"],
            "timeout"
        )
    }

    func testExistingProductionVariantsReachOwnedProductionRoute() throws {
        let recorder = RuntimeRequestRecorder()
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeProductVersion: Self.productVersion,
            selfInstall: {
                SelfInstallResult(
                    applicationPath: "/Users/test/Applications/PulsePhone.app",
                    build: "1",
                    disposition: .alreadyCurrent,
                    launcherChanged: false,
                    launcherPath: "/Users/test/.local/bin/PulsePhone",
                    terminatedProcessCount: 0,
                    version: "0.1.0"
                )
            },
            makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
            makeDeveloperImageDiagnostics: {
                throw CLIProductionBackendError.standard(
                    code: "developerImageCatalogUnavailable"
                )
            },
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            runtimeRequest: { operation, _, body, _, _ in
                recorder.record(operation: operation.rawValue, body: body)
                return try Self.failedRuntimeResult(code: "runtimeFailed")
            },
            liveOpen: { target, _, _ in
                CLILiveOpenResult(
                    disposition: "opened",
                    liveOwnerID: "test-live-owner-\(target.rawValue)"
                )
            }
        )
        let target = ["--udid", "AAAA"]
        let variants: [(String, [String])] = [
            ("app.install", ["install", "--path", "/tmp/Test.ipa"] + target),
            ("app.list", ["apps"] + target),
            ("app.launch", ["launch", "--bundle-id", "com.example.app"] + target),
            ("app.uninstall", ["uninstall", "--bundle-id", "com.example.app"] + target),
            ("button.appSwitcher", ["button", "app-switcher"] + target),
            ("button.home", ["button", "home"] + target),
            ("button.lock", ["button", "lock"] + target),
            ("button.mute", ["button", "mute"] + target),
            ("button.volumeDown", ["button", "volume-down"] + target),
            ("button.volumeUp", ["button", "volume-up"] + target),
            ("catalog.commands", ["commands"]),
            ("developerImage.list", ["developer-image", "list"]),
            ("developerImage.check", ["developer-image", "check"] + target),
            ("device.info", ["device", "info"] + target),
            ("device.list", ["devices"]),
            ("device.prepare", ["device", "prepare"] + target),
            ("device.rotate", ["rotate", "--direction", "left"] + target),
            ("device.status", ["status"] + target),
            ("diagnostics.start", ["diagnostics", "start"] + target),
            ("diagnostics.stop", ["diagnostics", "stop"] + target),
            ("element.snapshot", ["element", "snapshot"] + target),
            ("live.launch", ["live"] + target),
            ("logs.clear.all", ["logs", "clear", "--all"]),
            ("logs.clear.device", ["logs", "clear"] + target),
            ("logs.prune", ["logs", "prune"]),
            ("product.version", ["version"]),
            ("runtime.status.device", ["runtime", "status"] + target),
            ("runtime.status.global", ["runtime", "status"]),
            ("runtime.stop", ["stop"] + target),
            ("screenshot.cli", ["screenshot", "--output", "/tmp/a.png"] + target),
            ("self.install", ["self", "install"]),
            ("skill.install", ["skill", "install", "--agent", "codex"]),
            ("skill.status", ["skill", "status"]),
            ("skill.uninstall", ["skill", "uninstall", "--agent", "codex"]),
            ("text.clear", ["text", "clear"] + target),
            ("text.cursor", [
                "text", "cursor", "--move", "word-left", "--count", "2", "--select",
            ] + target),
            ("text.inputSource.next", ["text", "input-source", "next"] + target),
            ("text.key", [
                "text", "key", "--key", "a", "--command", "--repeat", "2",
            ] + target),
            ("text.type", ["type", "--text", "hello"] + target),
            ("touch.drag", [
                "drag", "--from", "0,0", "--to", "1,1", "--duration", "100",
            ] + target),
            ("touch.swipe", [
                "swipe", "--from", "0,0", "--to", "1,1", "--duration", "100",
            ] + target),
            ("touch.tap", ["tap", "--x", "0.25", "--y", "0.75"] + target),
            ("trace.start", ["trace", "start"] + target),
            ("trace.stop", ["trace", "stop"] + target),
        ]

        XCTAssertEqual(variants.count, 44)
        for (expectedCommandID, arguments) in variants {
            let output = process.run(arguments: arguments + ["--json"])
            XCTAssertEqual(output.chunk.stdout.count, 1, expectedCommandID)
            XCTAssertTrue(output.chunk.stderr.isEmpty, expectedCommandID)
            let envelope = try XCTUnwrap(try json(output.chunk.stdout[0]))
            XCTAssertEqual(envelope["commandID"] as? String, expectedCommandID)
            let error = envelope["error"] as? [String: Any]
            XCTAssertNotEqual(error?["code"] as? String, "commandNotImplemented")
            if arguments.contains("--udid") {
                let target = envelope["target"] as? [String: Any]
                XCTAssertEqual(target?["scope"] as? String, "device", expectedCommandID)
                XCTAssertEqual(target?["udid"] as? String, "AAAA", expectedCommandID)
            }
        }

        XCTAssertTrue(recorder.operations.contains("command.submit"))
        XCTAssertTrue(recorder.operations.contains("runtime.prepareCapabilities"))
        XCTAssertTrue(recorder.operations.contains("runtime.runtimeStatus"))
        XCTAssertTrue(recorder.operations.contains("runtime.stopIfIdle"))
    }

    func testDeveloperImageDiagnosticsAreReadOnlyAndUseExistingRuntimeOnly() throws {
        let fixture = try DeveloperImageDiagnosticsFixture()
        defer { fixture.remove() }
        let runtime = RuntimeActivationRecorder()
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeProductVersion: Self.productVersion,
            makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
            makeDeveloperImageDiagnostics: { fixture.diagnostics },
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            runtimeRequest: { operation, _, _, activation, _ in
                runtime.record(operation: operation.rawValue, activation: activation)
                return try Self.failedRuntimeResult(code: "runtimeNotRunning")
            }
        )

        let human = process.run(arguments: ["developer-image", "list"])
        XCTAssertEqual(human.exitCode, 0)
        XCTAssertEqual(human.chunk.stderr, [])
        XCTAssertTrue(human.chunk.stdout.joined(separator: "\n").contains(
            "Catalog 2026-08-22.1"
        ))
        XCTAssertTrue(runtime.calls.isEmpty)

        let list = process.run(arguments: [
            "developer-image", "list", "--refresh", "--json",
        ])
        XCTAssertEqual(list.exitCode, 0)
        let listEnvelope = try XCTUnwrap(try json(list.chunk.stdout[0]))
        XCTAssertEqual(listEnvelope["commandID"] as? String, "developerImage.list")
        XCTAssertEqual(
            (listEnvelope["target"] as? [String: String])?["scope"],
            "global"
        )
        XCTAssertEqual(
            ((listEnvelope["result"] as? [String: Any])?["records"] as? [[String: Any]])?
                .count,
            1
        )
        XCTAssertTrue(runtime.calls.isEmpty)

        let check = process.run(arguments: [
            "developer-image", "check", "--udid", "AAAA", "--refresh", "--json",
        ])
        XCTAssertEqual(check.exitCode, 0)
        let checkEnvelope = try XCTUnwrap(try json(check.chunk.stdout[0]))
        XCTAssertEqual(checkEnvelope["commandID"] as? String, "developerImage.check")
        XCTAssertEqual(
            checkEnvelope["target"] as? [String: String],
            ["scope": "device", "udid": "AAAA"]
        )
        let result = try XCTUnwrap(checkEnvelope["result"] as? [String: Any])
        XCTAssertEqual(result["status"] as? String, "verifiedAvailable")
        XCTAssertEqual(result["selectedAssetID"] as? String, "base.17.test")
        XCTAssertEqual(
            runtime.calls,
            [RuntimeActivationRecorder.Call(
                operation: "runtime.getAvailabilitySnapshot",
                activation: "existingOnly"
            )]
        )
        XCTAssertEqual(fixture.archiveFetchCount, 0)
    }

    func testVersionHumanAndJSONUseInjectedBundleMetadataWithoutSideEffects() throws {
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeProductVersion: Self.productVersion,
            makeQueries: {
                throw CLIProductionBackendError.standard(code: "probeUnavailable")
            },
            makeActionLogMaintenance: {
                throw CLIProductionBackendError.standard(code: "unsafeHostPath")
            },
            runtimeRequest: { _, _, _, _, _ in
                throw CLIProductionBackendError.standard(code: "runtimeFailed")
            },
            liveOpen: { _, _, _ in
                throw CLIProductionBackendError.standard(code: "guiHostUnavailable")
            }
        )

        let human = process.run(arguments: ["version"])
        XCTAssertEqual(human.exitCode, 0)
        XCTAssertEqual(human.chunk.stdout, ["PulsePhone 0.1.0 (1)"])
        XCTAssertTrue(human.chunk.stderr.isEmpty)

        let machine = process.run(arguments: ["version", "--json"])
        XCTAssertEqual(machine.exitCode, 0)
        XCTAssertTrue(machine.chunk.stderr.isEmpty)
        let envelope = try XCTUnwrap(try json(machine.chunk.stdout[0]))
        XCTAssertEqual(envelope["commandID"] as? String, "product.version")
        XCTAssertEqual(
            envelope["target"] as? [String: String],
            ["scope": "global"]
        )
        XCTAssertEqual(
            envelope["result"] as? [String: String],
            ["build": "1", "version": "0.1.0"]
        )
    }

    func testDuplicateUnknownAndMissingOptionsFailBeforeRuntime() throws {
        let recorder = RuntimeRequestRecorder()
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            runtimeRequest: { operation, _, body, _, _ in
                recorder.record(operation: operation.rawValue, body: body)
                return try Self.failedRuntimeResult(code: "runtimeFailed")
            }
        )
        let invalid = [
            ["tap", "--x", "0", "--x", "1", "--y", "0", "--json"],
            ["tap", "--x", "0", "--y", "0", "--bogus", "x", "--json"],
            ["tap", "--x", "0", "--json"],
            ["logs", "clear", "--all", "--udid", "AAAA", "--json"],
            ["text", "key", "--repeat", "1", "--json"],
            ["text", "key", "--key", "A", "--json"],
            ["text", "key", "--key", "a", "--repeat", "101", "--json"],
            ["text", "cursor", "--move", "character-left", "--json"],
            ["text", "cursor", "--move", "left", "--count", "0", "--json"],
            ["text", "clear", "--select", "--json"],
            ["text", "input-source", "next", "--repeat", "2", "--json"],
        ]
        for arguments in invalid {
            let output = process.run(arguments: arguments)
            XCTAssertEqual(output.exitCode, 2)
            let envelope = try XCTUnwrap(try json(output.chunk.stdout[0]))
            XCTAssertEqual(
                (envelope["error"] as? [String: Any])?["code"] as? String,
                "invalidArgument"
            )
        }
        XCTAssertTrue(recorder.operations.isEmpty)
    }

    func testTrailingZeroCoordinatesAreAcceptedAndCanonicalized() throws {
        let recorder = RuntimeRequestRecorder()
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            runtimeRequest: { operation, _, body, _, _ in
                recorder.record(operation: operation.rawValue, body: body)
                return try Self.failedRuntimeResult(code: "runtimeFailed")
            }
        )

        let output = process.run(arguments: [
            "tap", "--x", "0.40", "--y", "1.0", "--udid", "AAAA", "--json",
        ])

        XCTAssertEqual(output.exitCode, 4)
        XCTAssertEqual(recorder.lastNormalizedArguments?["point"], "0.4,1")
    }

    func testInvalidCoordinateReturnsTypedReasonAndSuggestion() throws {
        let recorder = RuntimeRequestRecorder()
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            runtimeRequest: { operation, _, body, _, _ in
                recorder.record(operation: operation.rawValue, body: body)
                return try Self.failedRuntimeResult(code: "runtimeFailed")
            }
        )

        let output = process.run(arguments: [
            "tap", "--x", "0.25", "--y", "1.20", "--udid", "AAAA", "--json",
        ])

        XCTAssertEqual(output.exitCode, 2)
        let envelope = try XCTUnwrap(try json(output.chunk.stdout[0]))
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "invalidCoordinate")
        XCTAssertTrue((error["message"] as? String)?.contains("0.40") == true)
        XCTAssertEqual(
            (error["details"] as? [String: String])?["argumentName"],
            "--y"
        )
        XCTAssertTrue(recorder.operations.isEmpty)
    }

    func testUnsupportedOSVersionPreservesTypedDetailsAndExitThree() throws {
        let reason = "tap requires iOS 17 or later; target device is running iOS 16.0."
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            runtimeRequest: { _, _, _, _, _ in
                try Self.failedRuntimeResult(
                    code: "unsupportedOSVersion",
                    details: [
                        "deviceClass": "iPhone",
                        "osVersion": "16.0",
                        "reason": reason,
                    ]
                )
            }
        )

        let jsonOutput = process.run(arguments: [
            "tap", "--x", "0.5", "--y", "0.5", "--udid", "AAAA", "--json",
        ])
        XCTAssertEqual(jsonOutput.exitCode, 3)
        let envelope = try XCTUnwrap(try json(jsonOutput.chunk.stdout[0]))
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "unsupportedOSVersion")
        let details = try XCTUnwrap(error["details"] as? [String: String])
        XCTAssertEqual(details["deviceClass"], "iPhone")
        XCTAssertEqual(details["osVersion"], "16.0")
        XCTAssertEqual(details["reason"], reason)

        let humanOutput = process.run(arguments: [
            "tap", "--x", "0.5", "--y", "0.5", "--udid", "AAAA",
        ])
        XCTAssertEqual(humanOutput.exitCode, 3)
        XCTAssertEqual(
            humanOutput.chunk.stderr,
            ["unsupportedOSVersion: \(reason)"]
        )
    }

    func testPublicRotateDirectionRemainsRelativeThroughSubmission() throws {
        let recorder = RuntimeRequestRecorder()
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            runtimeRequest: { operation, _, body, _, _ in
                recorder.record(operation: operation.rawValue, body: body)
                return try Self.failedRuntimeResult(code: "runtimeFailed")
            }
        )
        _ = process.run(arguments: [
            "rotate", "--direction", "right", "--udid", "AAAA", "--json",
        ])
        XCTAssertEqual(recorder.lastCommandID, "device.rotate")
        XCTAssertEqual(recorder.lastNormalizedArguments?["direction"], "right")
    }

    func testTextKeyboardOptionsNormalizeThroughProductionSubmission() throws {
        let recorder = RuntimeRequestRecorder()
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            runtimeRequest: { operation, _, body, _, _ in
                recorder.record(operation: operation.rawValue, body: body)
                return try Self.failedRuntimeResult(code: "runtimeFailed")
            }
        )

        _ = process.run(arguments: [
            "text", "key", "--key", "a", "--control", "--option",
            "--repeat", "100", "--udid", "AAAA", "--json",
        ])
        XCTAssertEqual(recorder.lastCommandID, "text.key")
        XCTAssertEqual(recorder.lastNormalizedArguments, [
            "command": "false", "control": "true", "key": "a",
            "option": "true", "repeat": "100", "shift": "false",
        ])

        _ = process.run(arguments: [
            "text", "cursor", "--move", "document-end", "--select",
            "--udid", "AAAA", "--json",
        ])
        XCTAssertEqual(recorder.lastCommandID, "text.cursor")
        XCTAssertEqual(recorder.lastNormalizedArguments, [
            "count": "1", "move": "document-end", "select": "true",
        ])
    }

    func testTextKeyboardHumanAndJSONSuccessUseDispatchLanguage() throws {
        let cases: [(arguments: [String], commandID: String, disposition: String, human: String)] = [
            (["text", "key", "--key", "a"], "text.key", "keyDispatched", "Key macro dispatched"),
            (["text", "cursor", "--move", "left"], "text.cursor", "cursorMoveDispatched", "Cursor macro dispatched"),
            (["text", "clear"], "text.clear", "clearDispatched", "Clear macro dispatched"),
            (["text", "input-source", "next"], "text.inputSource.next", "inputSourceCycleDispatched", "Input-source cycle dispatched"),
        ]
        for fixture in cases {
            let process = PulsePhoneCLIProcess(
                makeStaticSurface: Self.staticSurface,
                makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
                makeActionLogMaintenance: Self.missingActionLogMaintenance,
                runtimeRequest: { _, _, _, _, _ in
                    try Self.succeededRuntimeResult(value: [
                        ("disposition", .string(fixture.disposition)),
                    ])
                }
            )
            let human = process.run(arguments: fixture.arguments + ["--udid", "AAAA"])
            XCTAssertEqual(human.exitCode, 0, fixture.commandID)
            XCTAssertEqual(human.chunk.stdout, [fixture.human], fixture.commandID)
            let jsonOutput = process.run(
                arguments: fixture.arguments + ["--udid", "AAAA", "--json"]
            )
            let envelope = try XCTUnwrap(try json(jsonOutput.chunk.stdout[0]))
            XCTAssertEqual(envelope["commandID"] as? String, fixture.commandID)
            XCTAssertEqual(
                (envelope["result"] as? [String: Any])?["disposition"] as? String,
                fixture.disposition
            )
        }
    }

    func testRuntimeFixedDecimalResultIsEmittedAsPlainJSONNumber() throws {
        let decimal = try RepositoryJSONDecimal("0.000000001")
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            runtimeRequest: { _, _, _, _, _ in
                try Self.succeededRuntimeResult(value: [
                    ("confidence", .number(.decimal(decimal))),
                    ("disposition", .string("keyDispatched")),
                ])
            }
        )

        let output = process.run(arguments: [
            "text", "key", "--key", "a", "--udid", "AAAA", "--json",
        ])

        XCTAssertEqual(output.exitCode, 0)
        XCTAssertTrue(output.chunk.stderr.isEmpty)
        let line = try XCTUnwrap(output.chunk.stdout.first)
        XCTAssertTrue(line.contains("\"confidence\":0.000000001"), line)
        XCTAssertFalse(line.contains("\"confidence\":\""), line)
        XCTAssertFalse(line.lowercased().contains("1e-"), line)
    }

    func testRotateHumanSuccessNamesConfirmedCurrentDirection() throws {
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            runtimeRequest: { _, _, _, _, _ in
                try Self.succeededRuntimeResult(value: [
                    ("currentDisplayOrientation", .string("landscapeLeft")),
                    ("direction", .string("left")),
                    ("displayOrientationChanged", .bool(true)),
                    ("geometryRevision", .number(.uint64(4))),
                    ("logicalHeight", .number(.uint64(1_179))),
                    ("logicalWidth", .number(.uint64(2_556))),
                    ("orientation", .string("landscapeLeft")),
                    ("outcomeKnown", .bool(true)),
                    ("previousDisplayOrientation", .string("portrait")),
                    ("requestedDirection", .string("left")),
                    ("rotateResponseOrientation", .string("landscapeLeft")),
                    ("visibleOrientationConfirmed", .bool(true)),
                ])
            }
        )

        let output = process.run(arguments: [
            "rotate", "--direction", "left", "--udid", "AAAA",
        ])
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(output.chunk.stdout, ["Rotated to Landscape Left"])
        XCTAssertTrue(output.chunk.stderr.isEmpty)
    }

    func testRotateHumanSuccessNamesUnchangedCurrentDirection() throws {
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            runtimeRequest: { _, _, _, _, _ in
                try Self.succeededRuntimeResult(value: [
                    ("currentDisplayOrientation", .string("landscapeRight")),
                    ("direction", .string("right")),
                    ("displayOrientationChanged", .bool(false)),
                    ("geometryRevision", .number(.uint64(5))),
                    ("logicalHeight", .number(.uint64(1_179))),
                    ("logicalWidth", .number(.uint64(2_556))),
                    ("orientation", .string("landscapeRight")),
                    ("outcomeKnown", .bool(false)),
                    ("previousDisplayOrientation", .string("landscapeRight")),
                    ("requestedDirection", .string("right")),
                    ("rotateResponseOrientation", .string("portraitUpsideDown")),
                    ("visibleOrientationConfirmed", .bool(false)),
                ])
            }
        )

        let output = process.run(arguments: [
            "rotate", "--direction", "right", "--udid", "AAAA",
        ])
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(
            output.chunk.stdout,
            ["No visible rotation; current direction is Landscape Right"]
        )
        XCTAssertTrue(output.chunk.stderr.isEmpty)
    }

    func testScreenshotUsesArtifactBackendAndAtomicOutput() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-CLIScreenshot-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let outputPath = root.appendingPathComponent("capture.png").path
        let png: [UInt8] = [
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3,
        ]
        let recorder = ScreenshotRequestRecorder(bytes: png)
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            screenshotRequest: recorder.request
        )

        let first = process.run(arguments: [
            "screenshot", "--output", outputPath,
            "--udid", "AAAA", "--json",
        ])
        XCTAssertEqual(first.exitCode, 0)
        XCTAssertEqual(recorder.paths, [outputPath])
        XCTAssertEqual(
            try [UInt8](Data(contentsOf: URL(fileURLWithPath: outputPath))),
            png
        )
        let firstEnvelope = try XCTUnwrap(try json(first.chunk.stdout[0]))
        XCTAssertEqual(firstEnvelope["commandID"] as? String, "screenshot.cli")

        let existing = process.run(arguments: [
            "screenshot", "--output", outputPath,
            "--udid", "AAAA", "--json",
        ])
        XCTAssertEqual(existing.exitCode, 6)
        XCTAssertEqual(recorder.paths, [outputPath])
        XCTAssertEqual(
            (existingEnvelope(existing)["error"] as? [String: Any])?["code"]
                as? String,
            "outputExists"
        )

        let replaced = process.run(arguments: [
            "screenshot", "--output", outputPath, "--force",
            "--udid", "AAAA", "--json",
        ])
        XCTAssertEqual(replaced.exitCode, 0)
        XCTAssertEqual(recorder.paths, [outputPath, outputPath])
    }

    func testScreenshotPreservesPreparationRemediationDetailsWithoutArtifact() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-CLIScreenshotPreparation-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let outputPath = root.appendingPathComponent("capture.png").path
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            screenshotRequest: { _, _, _, _ in
                throw CLIProductionBackendError.standard(
                    code: "capabilityPreparing",
                    details: [
                        "remediation": "runDevicePrepare",
                        "state": "preparingDevice",
                    ]
                )
            }
        )

        let human = process.run(arguments: [
            "screenshot", "--output", outputPath, "--udid", "AAAA",
        ])
        XCTAssertEqual(human.exitCode, 5)
        XCTAssertEqual(
            human.chunk.stderr,
            ["capabilityPreparing: Developer support preparation is in progress. Run PulsePhone device prepare to follow progress."]
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputPath))

        let machine = process.run(arguments: [
            "screenshot", "--output", outputPath, "--udid", "AAAA", "--json",
        ])
        XCTAssertEqual(machine.exitCode, 5)
        let error = try XCTUnwrap(existingEnvelope(machine)["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "capabilityPreparing")
        XCTAssertEqual(
            (error["details"] as? [String: String])?["remediation"],
            "runDevicePrepare"
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputPath))
    }

    func testElementSnapshotDefaultsToJSONAndKeepsOutputPathClientLocal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-CLIElement-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let outputPath = root.appendingPathComponent("elements.png").path
        let recorder = ElementSnapshotRequestRecorder()
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            elementSnapshotRequest: recorder.request
        )

        let jsonOnly = process.run(arguments: [
            "element", "snapshot", "--udid", "AAAA",
        ])
        XCTAssertEqual(jsonOnly.exitCode, 0)
        XCTAssertEqual(jsonOnly.chunk.stdout.count, 1)
        XCTAssertTrue(jsonOnly.chunk.stderr.isEmpty)
        XCTAssertEqual(recorder.formats, ["json"])
        let jsonEnvelope = try XCTUnwrap(try json(jsonOnly.chunk.stdout[0]))
        XCTAssertEqual(jsonEnvelope["commandID"] as? String, "element.snapshot")

        let both = process.run(arguments: [
            "element", "snapshot", "--format", "both",
            "--output", outputPath, "--udid", "AAAA",
        ])
        XCTAssertEqual(both.exitCode, 0)
        XCTAssertEqual(both.chunk.stdout.count, 1)
        XCTAssertEqual(recorder.formats, ["json", "both"])
        XCTAssertEqual(
            try [UInt8](Data(contentsOf: URL(fileURLWithPath: outputPath))),
            ElementSnapshotRequestRecorder.png
        )
        let bothEnvelope = try XCTUnwrap(try json(both.chunk.stdout[0]))
        let result = bothEnvelope["result"] as? [String: Any]
        let annotation = result?["annotation"] as? [String: Any]
        XCTAssertEqual(annotation?["outputPath"] as? String, outputPath)

        let annotatedPath = root.appendingPathComponent("only.png").path
        let annotated = process.run(arguments: [
            "element", "snapshot", "--format", "annotated",
            "--output", annotatedPath, "--udid", "AAAA",
        ])
        XCTAssertEqual(annotated.exitCode, 0)
        XCTAssertTrue(annotated.chunk.stdout.isEmpty)
        XCTAssertTrue(annotated.chunk.stderr.isEmpty)
        XCTAssertEqual(recorder.formats, ["json", "both", "annotated"])
    }

    func testElementSnapshotRejectsUnsupportedVerbsAndInvalidFormatMatrix()
        throws
    {
        let recorder = ElementSnapshotRequestRecorder()
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            elementSnapshotRequest: recorder.request
        )
        let invalid = [
            ["element", "find", "--json"],
            ["element", "get", "--json"],
            ["element", "click", "--json"],
            ["element", "snapshot", "--format", "invalid", "--json"],
            [
                "element", "snapshot", "--format", "annotated",
                "--output", "/tmp/elements.png", "--json",
            ],
            ["element", "snapshot", "--format", "both", "--json"],
            ["element", "snapshot", "--output", "/tmp/elements.png", "--json"],
            ["element", "snapshot", "--force", "--json"],
        ]

        for arguments in invalid {
            let output = process.run(arguments: arguments)
            XCTAssertEqual(output.exitCode, 2, arguments.joined(separator: " "))
            let envelope = try XCTUnwrap(try json(output.chunk.stdout[0]))
            XCTAssertEqual(
                (envelope["error"] as? [String: Any])?["code"] as? String,
                "invalidArgument",
                arguments.joined(separator: " ")
            )
        }
        XCTAssertTrue(recorder.formats.isEmpty)
    }

    func testElementSnapshotAcceptsStrictHiddenAnalyzerSelectionWithoutHelpExposure()
        throws
    {
        let recorder = ElementSnapshotRequestRecorder()
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            elementSnapshotRequest: recorder.request
        )

        let selected = process.run(arguments: [
            "element", "snapshot",
            "--internal-analyzers", "apple,omni,omni",
            "--udid", "AAAA",
        ])
        XCTAssertEqual(selected.exitCode, 0)
        XCTAssertEqual(recorder.formats, ["json"])
        XCTAssertEqual(recorder.analyzerSelections, ["omni,apple"])

        let globalJSON = process.run(arguments: [
            "--json", "element", "snapshot",
            "--internal-analyzers", "vision",
            "--udid", "AAAA",
        ])
        XCTAssertEqual(globalJSON.exitCode, 0)
        XCTAssertEqual(recorder.analyzerSelections, ["omni,apple", "vision"])

        let invalidValues = [
            "", "omni,", "localGeometry", "OMNI", "vision apple",
        ]
        for value in invalidValues {
            let invalid = process.run(arguments: [
                "element", "snapshot",
                "--internal-analyzers", value,
                "--udid", "AAAA",
            ])
            XCTAssertEqual(invalid.exitCode, 2, value)
        }
        let duplicate = process.run(arguments: [
            "element", "snapshot",
            "--internal-analyzers", "omni",
            "--internal-analyzers", "vision",
            "--udid", "AAAA",
        ])
        XCTAssertEqual(duplicate.exitCode, 2)
        let otherCommand = process.run(arguments: [
            "devices", "--internal-analyzers", "omni",
        ])
        XCTAssertEqual(otherCommand.exitCode, 2)

        let help = process.run(arguments: [
            "element", "snapshot", "--help",
        ])
        XCTAssertEqual(help.exitCode, 0)
        XCTAssertFalse(help.chunk.stdout.joined().contains("internal-analyzers"))
        XCTAssertEqual(recorder.analyzerSelections, ["omni,apple", "vision"])
    }

    func testElementSnapshotEnforcesNoClobberForceAndAtomicWriteFailure()
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-CLIElementOutput-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let existing = root.appendingPathComponent("existing.png")
        try Data([1, 2, 3]).write(to: existing)
        let recorder = ElementSnapshotRequestRecorder()
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            elementSnapshotRequest: recorder.request
        )

        let refused = process.run(arguments: [
            "element", "snapshot", "--format", "both",
            "--output", existing.path, "--udid", "AAAA",
        ])
        XCTAssertEqual(refused.exitCode, 6)
        XCTAssertTrue(recorder.formats.isEmpty)
        XCTAssertEqual(
            (existingEnvelope(refused)["error"] as? [String: Any])?["code"]
                as? String,
            "outputExists"
        )

        let replaced = process.run(arguments: [
            "element", "snapshot", "--format", "both",
            "--output", existing.path, "--force", "--udid", "AAAA",
        ])
        XCTAssertEqual(replaced.exitCode, 0)
        XCTAssertEqual(
            try [UInt8](Data(contentsOf: existing)),
            ElementSnapshotRequestRecorder.png
        )

        let unavailableParent = root
            .appendingPathComponent("missing", isDirectory: true)
            .appendingPathComponent("elements.png")
        let writeFailure = process.run(arguments: [
            "element", "snapshot", "--format", "both",
            "--output", unavailableParent.path, "--udid", "AAAA",
        ])
        XCTAssertEqual(writeFailure.exitCode, 6)
        XCTAssertEqual(
            (existingEnvelope(writeFailure)["error"] as? [String: Any])?["code"]
                as? String,
            "localWriteFailed"
        )
        XCTAssertEqual(recorder.formats, ["both", "both"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: unavailableParent.path))
    }

    func testElementSnapshotDegradedSuccessAndWholeFailureExitSemantics() throws {
        let degradedRecorder = ElementSnapshotRequestRecorder(degraded: true)
        let degradedProcess = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            elementSnapshotRequest: degradedRecorder.request
        )
        let degraded = degradedProcess.run(arguments: [
            "element", "snapshot", "--udid", "AAAA",
        ])
        XCTAssertEqual(degraded.exitCode, 0)
        let degradedEnvelope = try XCTUnwrap(try json(degraded.chunk.stdout[0]))
        XCTAssertEqual(
            (degradedEnvelope["result"] as? [String: Any])?["degraded"] as? Bool,
            true
        )

        let failedProcess = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            elementSnapshotRequest: { _, _, _, _, _ in
                throw CLIProductionBackendError.standard(code: "partialFailure")
            }
        )
        let failed = failedProcess.run(arguments: [
            "element", "snapshot", "--udid", "AAAA",
        ])
        XCTAssertNotEqual(failed.exitCode, 0)
        XCTAssertEqual(
            (existingEnvelope(failed)["error"] as? [String: Any])?["code"]
                as? String,
            "partialFailure"
        )
    }

    func testElementSnapshotInterruptionProjectsStableCodeAndExit() throws {
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            elementSnapshotRequest: { _, _, _, _, _ in
                throw RuntimeClientError.interrupted
            }
        )
        let output = process.run(arguments: [
            "element", "snapshot", "--udid", "AAAA", "--json",
        ])
        XCTAssertEqual(output.exitCode, 130)
        let envelope = try XCTUnwrap(try json(output.chunk.stdout[0]))
        XCTAssertEqual(
            (envelope["error"] as? [String: Any])?["code"] as? String,
            "interrupted"
        )
    }

    func testConnectedOnlyAndDisconnectedExplicitTargetsStayDisjoint() throws {
        let recorder = RuntimeRequestRecorder()
        let liveRecorder = LiveOpenRecorder()
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            runtimeRequest: { operation, _, body, _, _ in
                recorder.record(operation: operation.rawValue, body: body)
                throw RuntimeClientError.socketUnavailable(errno: ENOENT)
            },
            liveOpen: { target, _, _ in
                liveRecorder.record(target)
                return CLILiveOpenResult(
                    disposition: "opened",
                    liveOwnerID: "unexpected"
                )
            }
        )
        let missing = ["--udid", "BBBB", "--json"]
        let connectedOnly = [
            ["tap", "--x", "0", "--y", "0"] + missing,
            ["device", "prepare"] + missing,
            ["live"] + missing,
            ["trace", "start"] + missing,
            ["diagnostics", "start"] + missing,
        ]
        for arguments in connectedOnly {
            let output = process.run(arguments: arguments)
            XCTAssertEqual(output.exitCode, 3)
            let envelope = try XCTUnwrap(try json(output.chunk.stdout[0]))
            XCTAssertEqual(
                (envelope["error"] as? [String: Any])?["code"] as? String,
                "deviceNotFound"
            )
        }
        XCTAssertTrue(recorder.operations.isEmpty)
        XCTAssertTrue(liveRecorder.targets.isEmpty)

        let disconnectedControl = [
            ["stop"] + missing,
            ["trace", "stop"] + missing,
            ["diagnostics", "stop"] + missing,
            ["logs", "clear"] + missing,
        ]
        for arguments in disconnectedControl {
            let output = process.run(arguments: arguments)
            XCTAssertNotEqual(output.exitCode, 3)
            let envelope = try XCTUnwrap(try json(output.chunk.stdout[0]))
            let target = try XCTUnwrap(envelope["target"] as? [String: Any])
            XCTAssertEqual(target["scope"] as? String, "device")
            XCTAssertEqual(target["udid"] as? String, "BBBB")
        }
        XCTAssertEqual(recorder.operations, [
            "runtime.stopIfIdle",
            "runtime.stopReplayTrace",
            "runtime.stopDiagnostics",
            "runtime.clearActionLogs",
        ])
    }

    func testLiveSelectSourceReachesGUIOnlyForLive() throws {
        let recorder = LiveOpenRecorder()
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            runtimeRequest: { operation, _, body, _, _ in
                XCTAssertEqual(operation, .runtimePrepareCapabilities)
                XCTAssertEqual(body["mode"]?.stringValue, "startOnly")
                return try Self.succeededRuntimeResult(value: [
                    ("disposition", .string("alreadyReady")),
                ])
            },
            liveOpen: { target, _, selectSource in
                recorder.record(target, selectSource: selectSource)
                return CLILiveOpenResult(
                    disposition: selectSource
                        ? "sourceSelectionOpened"
                        : "opened",
                    liveOwnerID: "owner-a"
                )
            }
        )

        let selected = process.run(arguments: [
            "live", "--select-source", "--udid", "AAAA", "--json",
        ])
        XCTAssertEqual(selected.exitCode, 0)
        XCTAssertEqual(recorder.targets.map(\.rawValue), ["AAAA"])
        XCTAssertEqual(recorder.selectSourceValues, [true])
        let envelope = try XCTUnwrap(try json(selected.chunk.stdout[0]))
        XCTAssertEqual(
            (envelope["result"] as? [String: Any])?["disposition"] as? String,
            "sourceSelectionOpened"
        )

        let unrelated = process.run(arguments: [
            "tap", "--x", "0", "--y", "0", "--select-source", "--json",
        ])
        XCTAssertEqual(unrelated.exitCode, 2)
        XCTAssertEqual(recorder.targets.count, 1)
    }

    func testLiveDoesNotCreateGUIWhilePreparationIsRequired() throws {
        let recorder = LiveOpenRecorder()
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            runtimeRequest: { operation, _, body, _, _ in
                XCTAssertEqual(operation, .runtimePrepareCapabilities)
                XCTAssertEqual(body["mode"]?.stringValue, "startOnly")
                return try Self.failedRuntimeResult(
                    code: "capabilityPreparing",
                    details: [
                        "remediation": "runDevicePrepare",
                        "state": "preparingDevice",
                    ]
                )
            },
            liveOpen: { target, _, selectSource in
                recorder.record(target, selectSource: selectSource)
                return CLILiveOpenResult(disposition: "opened", liveOwnerID: "x")
            }
        )

        let human = process.run(arguments: ["live", "--udid", "AAAA"])
        XCTAssertEqual(human.exitCode, 5)
        XCTAssertEqual(
            human.chunk.stderr,
            ["capabilityPreparing: Developer support preparation is in progress. Run PulsePhone device prepare to follow progress."]
        )
        XCTAssertTrue(recorder.targets.isEmpty)

        let json = process.run(arguments: ["live", "--udid", "AAAA", "--json"])
        XCTAssertEqual(json.exitCode, 5)
        let envelope = try XCTUnwrap(try self.json(json.chunk.stdout[0]))
        let error = try XCTUnwrap(envelope["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? String, "capabilityPreparing")
        XCTAssertEqual(
            (error["details"] as? [String: String])?["remediation"],
            "runDevicePrepare"
        )
        XCTAssertTrue(recorder.targets.isEmpty)
    }

    func testStopRetriesTransientDeviceNotFoundBeforeRunningLifecycle() throws {
        let queries = SequencedStopQueryFactory(snapshot: try Self.snapshot())
        let stops = RuntimeStopInvocationRecorder()
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeQueries: queries.make,
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            runtimeStop: { target, mode in
                try stops.run(target: target, outputMode: mode)
            }
        )

        let output = process.run(arguments: ["stop", "--json"])
        XCTAssertEqual(output.exitCode, 0)
        XCTAssertEqual(queries.attemptCount, 2)
        XCTAssertEqual(stops.targets.map(\.rawValue), ["AAAA"])
        let envelope = try XCTUnwrap(try json(output.chunk.stdout[0]))
        XCTAssertEqual(envelope["commandID"] as? String, "runtime.stop")
        XCTAssertEqual(
            (envelope["target"] as? [String: Any])?["udid"] as? String,
            "AAAA"
        )
    }

    func testLocalLogMaintenanceRoutesAndErrorsUseInjectedBackend() throws {
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            runtimeRequest: { _, _, _, _, _ in
                throw RuntimeClientError.socketUnavailable(errno: ENOENT)
            }
        )
        for (commandID, arguments) in [
            ("logs.prune", ["logs", "prune", "--json"]),
            ("logs.clear.all", ["logs", "clear", "--all", "--json"]),
        ] {
            let output = process.run(arguments: arguments)
            XCTAssertEqual(output.exitCode, 0)
            let envelope = try XCTUnwrap(try json(output.chunk.stdout[0]))
            XCTAssertEqual(envelope["commandID"] as? String, commandID)
        }

        for (error, expectedCode, expectedExit) in [
            (ProductionActionLogMaintenanceError.unsafeHostPath, "unsafeHostPath", 4),
            (ProductionActionLogMaintenanceError.maintenanceBusy, "resourceBusy", 5),
            (ProductionActionLogMaintenanceError.systemCall(
                operation: "test",
                errno: EIO
            ), "localWriteFailed", 6),
        ] {
            let failing = PulsePhoneCLIProcess(
                makeStaticSurface: Self.staticSurface,
                makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
                makeActionLogMaintenance: { throw error }
            )
            let output = failing.run(arguments: ["logs", "prune", "--json"])
            XCTAssertEqual(output.exitCode, Int32(expectedExit))
            let envelope = try XCTUnwrap(try json(output.chunk.stdout[0]))
            XCTAssertEqual(
                (envelope["error"] as? [String: Any])?["code"] as? String,
                expectedCode
            )
        }
    }

    func testDeviceLogClearFallsBackLocallyOnlyWhenRuntimeSocketIsAbsent() throws {
        let recorder = RuntimeRequestRecorder()
        let process = PulsePhoneCLIProcess(
            makeStaticSurface: Self.staticSurface,
            makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
            makeActionLogMaintenance: Self.missingActionLogMaintenance,
            runtimeRequest: { operation, _, body, _, _ in
                recorder.record(operation: operation.rawValue, body: body)
                throw RuntimeClientError.socketUnavailable(errno: ENOENT)
            }
        )
        let output = process.run(arguments: [
            "logs", "clear", "--udid", "AAAA", "--json",
        ])
        XCTAssertEqual(output.exitCode, 0)
        let envelope = try XCTUnwrap(try json(output.chunk.stdout[0]))
        XCTAssertEqual(envelope["commandID"] as? String, "logs.clear.device")
        let target = try XCTUnwrap(envelope["target"] as? [String: Any])
        XCTAssertEqual(target["udid"] as? String, "AAAA")
        XCTAssertEqual(recorder.operations, ["runtime.clearActionLogs"])
    }

    func testClearAllAggregatesRuntimeFailureAndUnknownBeforeLocalResult() throws {
        for (outcome, code, expectedExit) in [
            ("failed", "runtimeFailed", 6),
            ("outcomeUnknown", "outcomeUnknown", 7),
        ] {
            let process = PulsePhoneCLIProcess(
                makeStaticSurface: Self.staticSurface,
                makeQueries: { LocalDeviceQueries(snapshot: try Self.snapshot()) },
                makeActionLogMaintenance: Self.missingActionLogMaintenance,
                runtimeRequest: { _, _, _, _, _ in
                    if outcome == "outcomeUnknown" {
                        return try Self.outcomeUnknownRuntimeResult()
                    }
                    return try Self.failedRuntimeResult(code: code)
                }
            )
            let output = process.run(arguments: [
                "logs", "clear", "--all", "--json",
            ])
            XCTAssertEqual(output.exitCode, Int32(expectedExit))
            let envelope = try XCTUnwrap(try json(output.chunk.stdout[0]))
            XCTAssertEqual(
                (envelope["error"] as? [String: Any])?["code"] as? String,
                outcome == "outcomeUnknown" ? "outcomeUnknown" : "partialFailure"
            )
        }
    }

    private func json(_ value: String) throws -> [String: Any]? {
        try JSONSerialization.jsonObject(with: Data(value.utf8)) as? [String: Any]
    }

    private func existingEnvelope(
        _ output: CLITerminalOutput
    ) -> [String: Any] {
        (try? json(output.chunk.stdout[0])) ?? [:]
    }

    private static func snapshot() throws -> USBDiscoverySnapshot {
        USBDiscoverySnapshot(
            observedAtMonotonicNanoseconds: 1,
            devices: [USBDiscoveredDevice(
                deviceID: 1,
                rawTransportUDID: "AAAA",
                canonicalUDID: try CanonicalUDID(canonicalString: "AAAA"),
                facts: LocalDeviceFacts(
                    buildVersion: "21A000",
                    deviceClass: "iPhone",
                    deviceName: "Test Phone",
                    productType: "iPhone15,2",
                    productVersion: "17.0",
                    uniqueDeviceID: "AAAA"
                ),
                condition: LocalDeviceCondition(
                    connected: true,
                    locked: false,
                    trusted: true
                )
            )]
        )
    }

    private static func staticSurface() throws -> CLIStaticSurface {
        try CLIStaticSurface.loading(
            repositoryRoot: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        )
    }

    private static func missingActionLogMaintenance() -> ProductionActionLogMaintenance {
        ProductionActionLogMaintenance(
            rootPath: FileManager.default.temporaryDirectory
                .appendingPathComponent("pulsephone-missing-actionlogs")
                .appendingPathComponent(UUID().uuidString)
                .path
        )
    }

    private static func failedRuntimeResult(
        code: String,
        details: [String: String] = [:]
    ) throws -> RepositoryJSONObject {
        try object([
            ("commitState", .string("notCommitted")),
            ("error", .object(try object([
                ("code", .string(code)),
                ("details", .object(try object(details.map {
                    ($0.key, .string($0.value))
                }))),
            ]))),
            ("outcome", .string("failed")),
        ])
    }

    private static func succeededRuntimeResult(
        value: [(String, RepositoryJSONValue)]
    ) throws -> RepositoryJSONObject {
        try object([
            ("commitState", .string("committed")),
            ("outcome", .string("succeeded")),
            ("value", .object(try object(value))),
        ])
    }

    private static func outcomeUnknownRuntimeResult() throws -> RepositoryJSONObject {
        try object([
            ("commitState", .string("unknown")),
            ("error", .object(try object([
                ("code", .string("outcomeUnknown")),
                ("details", .object(try object([]))),
            ]))),
            ("outcome", .string("outcomeUnknown")),
        ])
    }

    private static func object(
        _ members: [(String, RepositoryJSONValue)]
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(members: members.map {
            RepositoryJSONMember(key: $0.0, value: $0.1)
        })
    }

    private static func productVersion() throws -> PulsePhoneProductVersion {
        try XCTUnwrap(PulsePhoneProductVersion(version: "0.1.0", build: "1"))
    }
}

private final class RuntimeActivationRecorder: @unchecked Sendable {
    struct Call: Equatable {
        let operation: String
        let activation: String
    }

    private let lock = NSLock()
    private var recordedCalls = [Call]()

    var calls: [Call] {
        lock.withLock { recordedCalls }
    }

    func record(operation: String, activation: RuntimeClientActivation) {
        let activationName: String
        switch activation {
        case .ensureRunning:
            activationName = "ensureRunning"
        case .existingOnly:
            activationName = "existingOnly"
        }
        lock.withLock {
            recordedCalls.append(Call(operation: operation, activation: activationName))
        }
    }
}

private final class DeveloperImageDiagnosticsFixture: @unchecked Sendable {
    let diagnostics: DynamicDeveloperImageDiagnostics
    private let archiveFetches: LockedCounter
    private let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-DeveloperImageDiagnostics-\(UUID().uuidString)",
            isDirectory: true
        )
        let configuration = DynamicDeveloperImageCatalogStoreConfiguration(
            catalogURL: "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/catalog-test.json",
            archiveURLPrefix: "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/archives/"
        )
        let archiveFetches = LockedCounter()
        self.archiveFetches = archiveFetches
        let data = try Self.catalogData()
        let store = try DynamicDeveloperImageCatalogStore(
            rootURL: root,
            configuration: configuration,
            fetch: { _, _ in
                DynamicDeveloperImageCatalogHTTPResponse(
                    data: data,
                    etag: "\"test\"",
                    statusCode: 200
                )
            },
            now: { Date(timeIntervalSince1970: 1_785_000_000) }
        )
        let cache = try DynamicDeveloperImageAssetCache(
            rootURL: root,
            configuration: configuration,
            fetch: { _, _ in
                archiveFetches.increment()
                return Data()
            }
        )
        diagnostics = DynamicDeveloperImageDiagnostics(
            catalogStore: store,
            assetCache: cache,
            xcodeMatcher: { _ in false }
        )
    }

    var archiveFetchCount: Int {
        archiveFetches.value
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func catalogData() throws -> Data {
        let archivePrefix = "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/archives/"
        let catalog: [String: Any] = [
            "baseAssets": [[
                "archiveSHA256": String(repeating: "a", count: 64),
                "archiveSize": 10,
                "baseAssetID": "base.17.test",
                "contentManifestSHA256": String(repeating: "b", count: 64),
                "sourceURL": archivePrefix + "baseAssets/base.17.test.tar",
            ]],
            "catalogEntry": [[
                "baseAssetID": "base.17.test",
                "buildID": "21A000",
                "iosVersion": "17.0",
            ]],
            "catalogRevision": "2026-08-22.1",
            "defaultCandidateBaseAssetID": "base.17.test",
            "developerDiskImages": [],
            "schemaVersion": 1,
        ]
        return try JSONSerialization.data(
            withJSONObject: catalog,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private final class LiveOpenRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedTargets = [CanonicalUDID]()
    private var recordedSelectSourceValues = [Bool]()

    var targets: [CanonicalUDID] {
        lock.withLock { recordedTargets }
    }

    var selectSourceValues: [Bool] {
        lock.withLock { recordedSelectSourceValues }
    }

    func record(_ target: CanonicalUDID, selectSource: Bool = false) {
        lock.withLock {
            recordedTargets.append(target)
            recordedSelectSourceValues.append(selectSource)
        }
    }
}

private final class RuntimeRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedOperations = [String]()
    private var commandID: String?
    private var normalizedArguments: [String: String]?

    var operations: [String] {
        lock.withLock { recordedOperations }
    }

    var lastCommandID: String? {
        lock.withLock { commandID }
    }

    var lastNormalizedArguments: [String: String]? {
        lock.withLock { normalizedArguments }
    }

    func record(operation: String, body: RepositoryJSONObject) {
        lock.withLock {
            recordedOperations.append(operation)
            commandID = body["commandID"]?.stringValue ?? commandID
            if let object = body["normalizedArguments"]?.objectValue {
                normalizedArguments = Dictionary(uniqueKeysWithValues:
                    object.members.compactMap { member in
                        member.value.stringValue.map { (member.key, $0) }
                    }
                )
            }
        }
    }
}

private final class ScreenshotRequestRecorder: @unchecked Sendable {
    private let bytes: [UInt8]
    private let lock = NSLock()
    private var recordedPaths = [String]()

    init(bytes: [UInt8]) {
        self.bytes = bytes
    }

    var paths: [String] {
        lock.withLock { recordedPaths }
    }

    func request(
        requestID: CanonicalUUID,
        actionID: CanonicalUUID,
        canonicalUDID: CanonicalUDID,
        outputPath: String
    ) throws -> ScreenshotReceivedArtifact {
        lock.withLock { recordedPaths.append(outputPath) }
        return try ScreenshotReceivedArtifact(
            bytes: bytes,
            contentType: "image/png",
            readOnly: true
        )
    }
}

private final class ElementSnapshotRequestRecorder: @unchecked Sendable {
    static let png: [UInt8] = [
        0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3,
    ]

    private let degraded: Bool
    private let lock = NSLock()
    private var recordedAnalyzerSelections = [String?]()
    private var recordedFormats = [String]()

    init(degraded: Bool = false) {
        self.degraded = degraded
    }

    var formats: [String] {
        lock.withLock { recordedFormats }
    }

    var analyzerSelections: [String?] {
        lock.withLock { recordedAnalyzerSelections }
    }

    func request(
        requestID: CanonicalUUID,
        actionID: CanonicalUUID,
        canonicalUDID: CanonicalUDID,
        format: String,
        internalAnalyzers: String?
    ) throws -> RuntimeClientElementSnapshotResponse {
        lock.withLock {
            recordedFormats.append(format)
            recordedAnalyzerSelections.append(internalAnalyzers)
        }
        let captureSHA = String(repeating: "a", count: 64)
        let artifactID = try CanonicalUUID(
            "00000000-0000-0000-0000-000000000011"
        )
        let annotation: RuntimeClientElementAnnotationArtifact?
        var valueMembers: [(String, RepositoryJSONValue)] = [
            ("capture", .object(try Self.object([
                ("pixelHeight", .number(.uint64(2))),
                ("pixelWidth", .number(.uint64(3))),
                ("sha256", .string(captureSHA)),
            ]))),
            ("degraded", .bool(degraded)),
            ("elements", .array([])),
            ("snapshotGeneration", .number(.uint64(1))),
        ]
        if format == "json" {
            annotation = nil
        } else {
            let artifact = try ScreenshotReceivedArtifact(
                bytes: Self.png,
                contentType: "image/png",
                readOnly: true
            )
            annotation = RuntimeClientElementAnnotationArtifact(
                artifact: artifact,
                artifactID: artifactID,
                captureSHA256: captureSHA,
                pixelHeight: 2,
                pixelWidth: 3,
                snapshotGeneration: 1
            )
            valueMembers.append(("annotation", .object(try Self.object([
                ("artifactID", .string(artifactID.canonicalString)),
                ("byteLength", .number(.uint64(UInt64(Self.png.count)))),
                ("captureSHA256", .string(captureSHA)),
                ("contentType", .string("image/png")),
                ("sha256", .string(StableBytes.sha256Hex(Self.png))),
                ("snapshotGeneration", .number(.uint64(1))),
            ]))))
        }
        let compatibility = try RuntimeCompatibilityIdentity(
            runtimeCompatibilityID: ProductionRuntimeContractIdentity
                .runtimeCompatibilityID,
            executionCatalogHash: ProductionRuntimeContractIdentity
                .executionCatalogHash
        )
        return RuntimeClientElementSnapshotResponse(
            acknowledgement: try RuntimeHelloAck(
                runtimeBuildID: "test.runtime",
                compatibility: compatibility,
                connectionID: try CanonicalUUID(
                    "00000000-0000-0000-0000-000000000012"
                ),
                canonicalUDID: canonicalUDID,
                runtimeEpoch: 1,
                connectionEpoch: 1,
                quiescing: false
            ),
            annotation: annotation,
            result: try Self.object([
                ("commitState", .string("committed")),
                ("outcome", .string("succeeded")),
                ("value", .object(try Self.object(valueMembers))),
            ])
        )
    }

    private static func object(
        _ members: [(String, RepositoryJSONValue)]
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(members: members.map {
            RepositoryJSONMember(key: $0.0, value: $0.1)
        })
    }
}

private final class SequencedStopQueryFactory: @unchecked Sendable {
    private let lock = NSLock()
    private let snapshot: USBDiscoverySnapshot
    private var attempts = 0

    init(snapshot: USBDiscoverySnapshot) {
        self.snapshot = snapshot
    }

    var attemptCount: Int {
        lock.withLock { attempts }
    }

    func make() -> LocalDeviceQueries {
        let attempt = lock.withLock { () -> Int in
            attempts += 1
            return attempts
        }
        if attempt == 1 {
            return LocalDeviceQueries(discovery: TransientDeviceNotFoundDiscovery())
        }
        return LocalDeviceQueries(snapshot: snapshot)
    }
}

private struct TransientDeviceNotFoundDiscovery: USBDeviceDiscovering {
    func discover() throws -> USBDiscoverySnapshot {
        throw LocalDeviceFactsProbeError.remoteFailure(code: "deviceNotFound")
    }
}

private final class RuntimeStopInvocationRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedTargets = [CanonicalUDID]()

    var targets: [CanonicalUDID] {
        lock.withLock { recordedTargets }
    }

    func run(
        target: CanonicalUDID,
        outputMode: CLIOutputMode
    ) throws -> CLITerminalOutput {
        lock.withLock { recordedTargets.append(target) }
        return try CLIOutputAdapter(mode: outputMode).success(
            commandID: "runtime.stop",
            target: .device(target),
            result: RuntimeStopCommandResult(
                disposition: "stopped",
                stoppedTargetCount: 1
            ),
            human: "Stopped"
        )
    }
}
