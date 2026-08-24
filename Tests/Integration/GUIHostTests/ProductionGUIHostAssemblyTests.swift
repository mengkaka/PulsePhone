import AppKit
import Darwin
import Dispatch
import Foundation
@testable import PulsePhoneGUI
import PulsePhoneClientCore
import PulsePhoneHostPaths
import PulsePhoneMedia
import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions
import XCTest

final class ProductionGUIHostAssemblyTests: XCTestCase {
    @MainActor private static var retainedHeadlessWindows = [NSWindow]()

    func testWindowCloseLifecycleWaitsForOwnedCleanup() {
        var lifecycle = ProductionGUIHostWindowCloseLifecycle()
        XCTAssertTrue(lifecycle.acceptsWork)
        XCTAssertTrue(lifecycle.requestClose())
        XCTAssertEqual(lifecycle.phase, .stoppingOwnedResources)
        XCTAssertFalse(lifecycle.acceptsWork)
        XCTAssertFalse(lifecycle.requestClose())
        XCTAssertTrue(lifecycle.ownedResourcesStopped())
        XCTAssertEqual(lifecycle.phase, .readyToClose)
        lifecycle.windowClosed()
        XCTAssertEqual(lifecycle.phase, .closed)
    }

    func testProductionScreenshotRootLoggerEmitsBeginAndTerminal() throws {
        let target = try CanonicalUDID(canonicalString: "M2031-GUI-SCREENSHOT")
        let actionID = CanonicalUUID(value: UUID())
        let clientID = CanonicalUUID(value: UUID())
        let bodies = LockedJSONObjectStore()
        let logger = ProductionGUIScreenshotRootLogger(
            clientInstanceID: clientID,
            submit: { bodies.append($0) }
        )

        logger.recordBestEffort(.begin(
            actionID: actionID,
            canonicalUDID: target
        ))
        logger.recordBestEffort(.terminal(
            actionID: actionID,
            canonicalUDID: target,
            outcome: .succeeded
        ))

        XCTAssertEqual(bodies.values.count, 2)
        XCTAssertEqual(bodies.values[0]["eventKind"]?.stringValue, "action.begin")
        XCTAssertEqual(bodies.values[1]["eventKind"]?.stringValue, "action.terminal")
        XCTAssertEqual(
            bodies.values[1]["payload"]?.objectValue?["outcome"]?.stringValue,
            "succeeded"
        )
        XCTAssertEqual(
            bodies.values[0]["sourceClientInstanceID"]?.stringValue,
            clientID.canonicalString
        )
        XCTAssertEqual(bodies.values[0]["sourceRole"]?.stringValue, "gui")
    }

    func testProductionAtomicScreenshotOutputWritesAndReplacesPNG() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-GUIScreenshot-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("screen.png")
        let writer = AtomicGUIScreenshotOutputWriter(
            fileSystem: ProductionAtomicOutputFileSystem()
        )
        let first = try GUIScreenshotPNGArtifact(bytes: [
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1,
        ])
        try writer.write(
            first,
            toAbsolutePath: output.path,
            replaceExisting: false,
            tempID: CanonicalUUID(value: UUID())
        )
        XCTAssertEqual(try Data(contentsOf: output), Data(first.bytes))
        let mode = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: output.path)[.posixPermissions]
                as? NSNumber
        )
        XCTAssertEqual(mode.uint16Value, 0o600)

        let second = try GUIScreenshotPNGArtifact(bytes: [
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 2,
        ])
        try writer.write(
            second,
            toAbsolutePath: output.path,
            replaceExisting: true,
            tempID: CanonicalUUID(value: UUID())
        )
        XCTAssertEqual(try Data(contentsOf: output), Data(second.bytes))
        XCTAssertTrue(
            try FileManager.default.contentsOfDirectory(atPath: directory.path)
                .allSatisfy { !$0.hasPrefix(".pulsephone-") }
        )
    }

    func testProductionToolbarProjectionBuildsTwelveFrozenSlots() throws {
        let commands = [
            "button.home", "button.appSwitcher", "button.lock",
            "button.volumeUp", "button.volumeDown", "button.mute",
            "device.rotate", "screenshot.gui", "gui.keyboardCapture.toggle",
            "gui.softwareKeyboard.toggle", "gui.previewAudioMute.toggle",
            "app.install",
        ]
        let availability = try Self.object([
            ("commands", .array(try commands.map { commandID in
                .object(try Self.object([
                    ("commandID", .string(commandID)),
                    ("state", .string("enabled")),
                ]))
            })),
        ])
        let toolbar = try ProductionGUIHostToolbarProjection.make(
            availability: availability,
            repositoryRoot: repositoryRoot()
        )
        XCTAssertEqual(toolbar.slots.count, 12)
        XCTAssertEqual(toolbar.commandIDs.first, "button.home")
        XCTAssertEqual(toolbar.commandIDs.last, "app.install")
        XCTAssertTrue(toolbar.slots.allSatisfy { $0.presentation == .enabled })
    }

    @MainActor
    func testInstallPickerProjectsCancelInvalidSubmitAndMissingSession() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-GUIInstall-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let ipa = directory.appendingPathComponent("Fixture.ipa")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: ipa.path,
            contents: Data([1])
        ))
        let target = try CanonicalUDID(canonicalString: "M2031-GUI-INSTALL")
        let attached = expectation(description: "runtime attached")
        let closed = expectation(description: "runtime closed")
        let session = try MockGUIHostRuntimeSession(
            target: target,
            attached: attached,
            closed: closed,
            successfulSubmissions: true
        )
        let sessions = MockGUIHostRuntimeSessionFactory(sessions: [session])
        var selections: [String?] = [
            nil,
            directory.appendingPathComponent("Invalid.txt").path,
            ipa.path,
            ipa.path,
        ]
        let controller = ProductionGUIHostWindowController(
            catalog: ProductionAVFoundationVideoSourceCatalog(),
            mappingCoordinator: ProductionVideoSourceMappingCoordinator(
                store: InMemoryVideoSourceMappingStore()
            ),
            ipaSelectionPresenter: { _, completion in
                completion(selections.removeFirst())
            },
            runtimeSessionFactory: { _ in try sessions.next() },
            runtimeRetryDelaysNanoseconds: [60_000_000_000],
            toolbarRepositoryRoot: repositoryRoot(),
            presentsWindows: false
        )
        let identifier = try XCTUnwrap(controller.createWindow(for: target))
        await fulfillment(of: [attached], timeout: 3)
        let window = try XCTUnwrap(NSApplication.shared.windows.first {
            $0.identifier?.rawValue == identifier
        })
        Self.retainedHeadlessWindows.append(window)
        let toolbar = try await expandedToolbar(in: window)
        let item = try XCTUnwrap(controller.toolbar(
            toolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier(
                "\(identifier)::app.install"
            ),
            willBeInsertedIntoToolbar: true
        ))
        let button = try XCTUnwrap(item.view as? NSButton)
        XCTAssertTrue(button is ProductionIPAInstallButton)
        XCTAssertTrue(button.registeredDraggedTypes.contains(.fileURL))
        let sourceControls = try XCTUnwrap(descendant(
            in: try XCTUnwrap(window.contentView),
            identifier: ProductionGUIHostViewIdentifier.sourceControls
        ))
        let stack = try XCTUnwrap(sourceControls.subviews.first as? NSStackView)
        let status = try XCTUnwrap(stack.arrangedSubviews.first {
            $0 is NSTextField
                && $0.identifier != ProductionGUIHostViewIdentifier.sourceSummary
        } as? NSTextField)

        button.performClick(nil)
        XCTAssertEqual(status.stringValue, "Install cancelled")
        button.performClick(nil)
        XCTAssertEqual(status.stringValue, "invalidIPAPath")
        button.performClick(nil)
        XCTAssertEqual(status.stringValue, "Running Install App")
        try await waitUntil {
            session.submissions.contains { $0.commandID == "app.install" }
                && status.stringValue == "Installed com.example.Fixture"
        }
        XCTAssertEqual(
            session.submissions.last?.arguments,
            ["ipaPath": ipa.path]
        )

        session.simulateTransportFailure()
        await fulfillment(of: [closed], timeout: 3)
        try await waitUntil { status.stringValue.hasPrefix("Reconnecting controls") }
        button.performClick(nil)
        XCTAssertEqual(status.stringValue, "runtimeNotRunning")

        XCTAssertFalse(controller.windowShouldClose(window))
        controller.stopMonitoring()
    }

    @MainActor
    func testScreenshotPickerSurvivesRuntimeLossAndProjectsFallbackErrors() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-GUIScreenshot-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let saved = directory.appendingPathComponent("saved.png").path
        let runtimeFailure = directory.appendingPathComponent("runtime.png").path
        let writeFailure = directory.appendingPathComponent("write.png").path
        var selections: [String?] = [
            nil,
            "relative.png",
            saved,
            runtimeFailure,
            writeFailure,
        ]
        let backend = MockGUIScreenshotDeviceBackend()
        let writer = MockGUIScreenshotOutputWriter()
        let target = try CanonicalUDID(canonicalString: "M2031-GUI-SCREENSHOT")
        let attached = expectation(description: "runtime attached")
        let closed = expectation(description: "runtime closed")
        let session = try MockGUIHostRuntimeSession(
            target: target,
            attached: attached,
            closed: closed
        )
        let sessions = MockGUIHostRuntimeSessionFactory(sessions: [session])
        let controller = ProductionGUIHostWindowController(
            catalog: ProductionAVFoundationVideoSourceCatalog(),
            mappingCoordinator: ProductionVideoSourceMappingCoordinator(
                store: InMemoryVideoSourceMappingStore()
            ),
            runtimeSessionFactory: { _ in try sessions.next() },
            screenshotDeviceBackend: backend,
            screenshotOutputWriter: writer,
            screenshotSavePresenter: { _, completion in
                completion(selections.removeFirst())
            },
            runtimeRetryDelaysNanoseconds: [60_000_000_000],
            toolbarRepositoryRoot: repositoryRoot(),
            presentsWindows: false
        )
        let identifier = try XCTUnwrap(controller.createWindow(for: target))
        await fulfillment(of: [attached], timeout: 3)
        let window = try XCTUnwrap(NSApplication.shared.windows.first {
            $0.identifier?.rawValue == identifier
        })
        Self.retainedHeadlessWindows.append(window)
        let toolbar = try await expandedToolbar(in: window)
        let item = try XCTUnwrap(controller.toolbar(
            toolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier(
                "\(identifier)::screenshot.gui"
            ),
            willBeInsertedIntoToolbar: true
        ))
        let button = try XCTUnwrap(item.view as? NSButton)
        let sourceControls = try XCTUnwrap(descendant(
            in: try XCTUnwrap(window.contentView),
            identifier: ProductionGUIHostViewIdentifier.sourceControls
        ))
        let stack = try XCTUnwrap(sourceControls.subviews.first as? NSStackView)
        let status = try XCTUnwrap(stack.arrangedSubviews.first {
            $0 is NSTextField
                && $0.identifier != ProductionGUIHostViewIdentifier.sourceSummary
        } as? NSTextField)

        session.simulateTransportFailure()
        await fulfillment(of: [closed], timeout: 3)
        try await waitUntil { status.stringValue.hasPrefix("Reconnecting controls") }
        let localActionCount = session.events.filter { $0 == "recordLocalAction" }.count

        button.performClick(nil)
        XCTAssertEqual(status.stringValue, "Screenshot cancelled")
        XCTAssertTrue(backend.requests.isEmpty)

        button.performClick(nil)
        try await waitUntil { status.stringValue == "invalidOutputPath" }
        XCTAssertTrue(backend.requests.isEmpty)

        button.performClick(nil)
        try await waitUntil { status.stringValue == "Screenshot saved" }
        XCTAssertEqual(backend.requests.count, 1)
        XCTAssertEqual(writer.writes.map(\.absolutePath), [saved])
        XCTAssertNotEqual(
            backend.requests[0].rootActionID,
            backend.requests[0].childActionID
        )

        backend.failNext(RuntimeClientError.socketUnavailable(errno: ENOENT))
        button.performClick(nil)
        try await waitUntil { status.stringValue == "runtimeNotRunning" }
        XCTAssertEqual(backend.requests.count, 2)
        XCTAssertEqual(writer.writes.count, 1)

        writer.failNextWrite()
        button.performClick(nil)
        try await waitUntil { status.stringValue == "localWriteFailed" }
        XCTAssertEqual(backend.requests.count, 3)
        XCTAssertEqual(writer.writes.count, 1)
        XCTAssertEqual(
            session.events.filter { $0 == "recordLocalAction" }.count,
            localActionCount
        )

        XCTAssertFalse(controller.windowShouldClose(window))
        controller.stopMonitoring()
    }

    @MainActor
    func testRuntimeAvailabilityRefreshUpdatesOverflowToolbarItem() async throws {
        let target = try CanonicalUDID(canonicalString: "M2031-TOOLBAR-REFRESH")
        let attached = expectation(description: "runtime attached")
        let closed = expectation(description: "runtime closed")
        let session = try MockGUIHostRuntimeSession(
            target: target,
            attached: attached,
            closed: closed,
            availabilityStartsWithGeometryUnavailable: true,
            successfulSubmissions: true
        )
        let controller = ProductionGUIHostWindowController(
            catalog: ProductionAVFoundationVideoSourceCatalog(),
            mappingCoordinator: ProductionVideoSourceMappingCoordinator(
                store: InMemoryVideoSourceMappingStore()
            ),
            runtimeSessionFactory: { _ in session },
            toolbarRepositoryRoot: repositoryRoot(),
            presentsWindows: false
        )
        let identifier = try XCTUnwrap(controller.createWindow(for: target))
        await fulfillment(of: [attached], timeout: 3)

        let window = try XCTUnwrap(NSApplication.shared.windows.first {
            $0.identifier?.rawValue == identifier
        })
        Self.retainedHeadlessWindows.append(window)
        let toolbar = try await expandedToolbar(in: window)
        let rotateItem = try XCTUnwrap(controller.toolbar(
            toolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier(
                "\(identifier)::device.rotate"
            ),
            willBeInsertedIntoToolbar: true
        ))
        let lockItem = try XCTUnwrap(controller.toolbar(
            toolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier(
                "\(identifier)::button.lock"
            ),
            willBeInsertedIntoToolbar: true
        ))
        XCTAssertFalse(rotateItem.isEnabled)
        XCTAssertEqual(rotateItem.toolTip, "Rotate: displayGeometryUnavailable")

        let lockButton = try XCTUnwrap(lockItem.view as? NSButton)
        lockButton.performClick(nil)
        try await waitUntil {
            session.availabilityCallCount >= 2
                && rotateItem.isEnabled
                && rotateItem.toolTip == "Rotate"
                && (rotateItem.view as? NSButton)?.isEnabled == true
        }

        let refreshedSizingDelegate = window.delegate
        window.delegate = nil
        window.setFrame(
            NSRect(x: window.frame.minX, y: window.frame.minY, width: 800,
                   height: window.frame.height),
            display: false
        )
        window.delegate = refreshedSizingDelegate
        let refreshedRotateItem = try XCTUnwrap(controller.toolbar(
            toolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier(
                "\(identifier)::device.rotate"
            ),
            willBeInsertedIntoToolbar: true
        ))
        XCTAssertGreaterThanOrEqual(session.availabilityCallCount, 2)
        XCTAssertTrue(refreshedRotateItem.isEnabled)
        XCTAssertEqual(refreshedRotateItem.toolTip, "Rotate")
        XCTAssertTrue((refreshedRotateItem.view as? NSButton)?.isEnabled == true)
        XCTAssertEqual((refreshedRotateItem.view as? NSButton)?.toolTip, "Rotate")

        XCTAssertFalse(controller.windowShouldClose(window))
        await fulfillment(of: [closed], timeout: 3)
        controller.stopMonitoring()
    }

    @MainActor
    func testSuccessfulHomePresentsWithoutRefreshingAvailability() async throws {
        let target = try CanonicalUDID(canonicalString: "M2031-TOOLBAR-HOME")
        let attached = expectation(description: "runtime attached")
        let closed = expectation(description: "runtime closed")
        let session = try MockGUIHostRuntimeSession(
            target: target,
            attached: attached,
            closed: closed,
            successfulSubmissions: true
        )
        let controller = ProductionGUIHostWindowController(
            catalog: ProductionAVFoundationVideoSourceCatalog(),
            mappingCoordinator: ProductionVideoSourceMappingCoordinator(
                store: InMemoryVideoSourceMappingStore()
            ),
            runtimeSessionFactory: { _ in session },
            toolbarRepositoryRoot: repositoryRoot(),
            presentsWindows: false
        )
        let identifier = try XCTUnwrap(controller.createWindow(for: target))
        await fulfillment(of: [attached], timeout: 3)

        let window = try XCTUnwrap(NSApplication.shared.windows.first {
            $0.identifier?.rawValue == identifier
        })
        Self.retainedHeadlessWindows.append(window)
        for _ in 0..<100 where window.toolbar == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let toolbar = try XCTUnwrap(window.toolbar)
        let homeItem = try XCTUnwrap(controller.toolbar(
            toolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier(
                "\(identifier)::button.home"
            ),
            willBeInsertedIntoToolbar: true
        ))
        let initialAvailabilityCalls = session.availabilityCallCount

        let homeButton = try XCTUnwrap(homeItem.view as? NSButton)
        homeButton.performClick(nil)
        try await waitUntil {
            session.events.contains("submit.button.home") && homeButton.isEnabled
        }

        XCTAssertEqual(session.availabilityCallCount, initialAvailabilityCalls)
        XCTAssertFalse(controller.windowShouldClose(window))
        await fulfillment(of: [closed], timeout: 3)
        controller.stopMonitoring()
    }

    @MainActor
    func testSoftwareKeyboardToolbarButtonSubmitsMomentaryWindowCommand() async throws {
        let target = try CanonicalUDID(canonicalString: "M2031-SOFTWARE-KEYBOARD")
        let attached = expectation(description: "runtime attached")
        let closed = expectation(description: "runtime closed")
        let session = try MockGUIHostRuntimeSession(
            target: target,
            attached: attached,
            closed: closed,
            successfulSubmissions: true
        )
        let controller = ProductionGUIHostWindowController(
            catalog: ProductionAVFoundationVideoSourceCatalog(),
            mappingCoordinator: ProductionVideoSourceMappingCoordinator(
                store: InMemoryVideoSourceMappingStore()
            ),
            runtimeSessionFactory: { _ in session },
            toolbarRepositoryRoot: repositoryRoot(),
            presentsWindows: false
        )
        let identifier = try XCTUnwrap(controller.createWindow(for: target))
        await fulfillment(of: [attached], timeout: 3)
        let window = try XCTUnwrap(NSApplication.shared.windows.first {
            $0.identifier?.rawValue == identifier
        })
        Self.retainedHeadlessWindows.append(window)
        for _ in 0..<100 where window.toolbar == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        _ = try XCTUnwrap(window.toolbar)
        let button = NSButton()
        button.identifier = NSUserInterfaceItemIdentifier(
            "\(identifier)::gui.softwareKeyboard.toggle"
        )
        button.setButtonType(.momentaryPushIn)
        button.target = controller
        let action = NSSelectorFromString("toolbarAction:")
        button.action = action

        XCTAssertEqual(button.state, .off)
        XCTAssertTrue(controller.responds(to: action))
        button.state = .on
        _ = controller.perform(action, with: button)
        try await waitUntil {
            session.submissions.contains {
                $0.commandID == "gui.softwareKeyboard.toggle"
            }
        }

        XCTAssertEqual(button.state, .off)
        XCTAssertEqual(
            session.submissions.last?.arguments,
            ["windowID": identifier]
        )
        XCTAssertFalse(session.events.contains("submit.gui.keyboard.interaction"))
        XCTAssertFalse(controller.windowShouldClose(window))
        await fulfillment(of: [closed], timeout: 3)
        controller.stopMonitoring()
    }

    func testProductionPointerPayloadCarriesFrozenGeometryAuthority() throws {
        let geometry = try DisplayGeometryDTO(
            connectionEpoch: 8,
            geometryRevision: 3,
            logicalHeight: 2532,
            logicalWidth: 1170,
            orientation: .portrait
        )
        var controller = PointerInteractionController()
        let frame = try controller.begin(
            at: PointerViewPoint(x: 50, y: 75),
            visibleImageRect: PointerVisibleImageRect(
                x: 0, y: 0, width: 100, height: 100
            ),
            geometry: geometry
        )
        let payload = try ProductionGUIHostFramePayload.pointer(frame)
        XCTAssertEqual(payload["x"]?.stringValue, "0.5")
        XCTAssertEqual(payload["y"]?.stringValue, "0.75")
        XCTAssertEqual(
            try payload["expectedConnectionEpoch"]?.numberValue?.requireUInt64(),
            8
        )
        XCTAssertEqual(
            try payload["expectedGeometryRevision"]?.numberValue?.requireUInt64(),
            3
        )
    }

    func testProductionKeyboardEventTapUsesPhysicalHIDMapping() {
        XCTAssertEqual(
            ProductionKeyboardHIDUsage.key(forKeyCode: 0),
            KeyboardCapturedKey(usagePage: 0x07, usage: 0x04)
        )
        XCTAssertEqual(
            ProductionKeyboardHIDUsage.key(forKeyCode: 55),
            KeyboardCapturedKey(usagePage: 0x07, usage: 0xE3)
        )
        XCTAssertNil(ProductionKeyboardHIDUsage.key(forKeyCode: 255))
        XCTAssertTrue(ProductionKeyboardHIDUsage.modifierIsPressed(
            keyCode: 55,
            flags: [.maskCommand, .maskShift]
        ))
        XCTAssertFalse(ProductionKeyboardHIDUsage.modifierIsPressed(
            keyCode: 55,
            flags: [.maskShift]
        ))
    }

    func testPointerStreamTerminalDispositionClosesEachInteraction() throws {
        let geometry = try DisplayGeometryDTO(
            connectionEpoch: 8,
            geometryRevision: 3,
            logicalHeight: 2_532,
            logicalWidth: 1_170,
            orientation: .portrait
        )
        let rect = PointerVisibleImageRect(
            x: 0, y: 0, width: 117, height: 253.2
        )
        var controller = PointerInteractionController()
        let firstBegin = try controller.begin(
            at: PointerViewPoint(x: 58.5, y: 126.6),
            visibleImageRect: rect,
            geometry: geometry
        )
        let firstEnd = try controller.end(
            at: PointerViewPoint(x: 58.5, y: 126.6),
            visibleImageRect: rect
        )
        let secondBegin = try controller.begin(
            at: PointerViewPoint(x: 30, y: 80),
            visibleImageRect: rect,
            geometry: geometry
        )
        let secondEnd = try controller.end(
            at: PointerViewPoint(x: 80, y: 120),
            visibleImageRect: rect
        )

        XCTAssertEqual(firstBegin.sequence, 0)
        XCTAssertEqual(firstEnd.sequence, 1)
        XCTAssertEqual(secondBegin.sequence, 0)
        XCTAssertEqual(secondEnd.sequence, 1)
        XCTAssertEqual(
            ProductionPointerStreamTerminalDisposition.resolve([
                (firstBegin, firstBegin.sequence),
                (firstEnd, firstEnd.sequence),
            ]),
            .close(expectedLastSequence: 1)
        )
        XCTAssertEqual(
            ProductionPointerStreamTerminalDisposition.resolve([
                (secondBegin, secondBegin.sequence),
            ]),
            .keepOpen
        )
        var cancelling = PointerInteractionController()
        let cancelBegin = try cancelling.begin(
            at: PointerViewPoint(x: 20, y: 20),
            visibleImageRect: rect,
            geometry: geometry
        )
        let cancel = try cancelling.cancel()
        XCTAssertEqual(
            ProductionPointerStreamTerminalDisposition.resolve([
                (cancelBegin, cancelBegin.sequence),
                (cancel, cancel.sequence),
            ]),
            .cancel
        )
    }

    @MainActor
    func testInteractionViewAspectFitsPortraitGeometryWithoutStretching() throws {
        let view = ProductionGUIHostInteractionView(
            frame: NSRect(x: 0, y: 0, width: 300, height: 600)
        )
        XCTAssertTrue(view.isFlipped)
        view.geometry = try DisplayGeometryDTO(
            connectionEpoch: 1,
            geometryRevision: 1,
            logicalHeight: 2532,
            logicalWidth: 1170,
            orientation: .portrait
        )
        let visible = view.visibleImageRect()
        XCTAssertEqual(visible.height, 600, accuracy: 0.001)
        XCTAssertEqual(visible.width / visible.height, 1170.0 / 2532.0,
                       accuracy: 0.000_001)
        XCTAssertEqual(visible.x, (300 - visible.width) / 2, accuracy: 0.001)
    }

    @MainActor
    func testInteractionViewOnlyShowsOptimisticOverlayForAcceptedPointerEvent() throws {
        let view = ProductionGUIHostInteractionView(
            frame: NSRect(x: 0, y: 0, width: 100, height: 100)
        )
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: NSPoint(x: 50, y: 50),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        view.pointerBegan = { _, _ in false }
        view.mouseDown(with: event)
        XCTAssertFalse(view.hasPointerOverlay)

        view.pointerBegan = { _, _ in true }
        view.mouseDown(with: event)
        XCTAssertTrue(view.hasPointerOverlay)
        view.clearPointerOverlay()
        XCTAssertFalse(view.hasPointerOverlay)
    }

    @MainActor
    func testPointerQueuesRapidGestureWhilePreviousStreamCloses() async throws {
        let harness = try await makePointerHarness(
            targetID: "M2031-POINTER-RAPID",
            configure: { $0.blockNextPointerClose() }
        )
        let point = PointerViewPoint(x: 50, y: 50)
        let rect = harness.interaction.visibleImageRect()

        XCTAssertTrue(harness.interaction.pointerBegan?(point, rect) == true)
        XCTAssertTrue(harness.interaction.pointerEnded?(point, rect) == true)
        try await waitUntil {
            harness.session.events.contains("pointer.close.blocked")
        }

        XCTAssertTrue(harness.interaction.pointerBegan?(point, rect) == true)
        XCTAssertTrue(harness.interaction.pointerEnded?(point, rect) == true)
        harness.session.releaseBlockedPointerClose()
        try await waitUntil {
            harness.session.events.filter { $0 == "pointer.close.1" }.count == 2
        }

        XCTAssertEqual(
            harness.session.events.filter { $0 == "pointer.open" }.count,
            2
        )
        XCTAssertEqual(
            harness.session.events.filter { $0 == "pointer.frame.0.begin" }.count,
            2
        )
        XCTAssertEqual(harness.session.ownedStreamCount, 0)
        try await closePointerHarness(harness)
    }

    @MainActor
    func testPointerOpenFailureAllowsNextGesture() async throws {
        let harness = try await makePointerHarness(
            targetID: "M2031-POINTER-OPEN-RECOVERY",
            configure: { $0.failNextPointerOpen() }
        )
        let point = PointerViewPoint(x: 50, y: 50)
        let rect = harness.interaction.visibleImageRect()

        XCTAssertTrue(harness.interaction.pointerBegan?(point, rect) == true)
        XCTAssertTrue(harness.interaction.pointerEnded?(point, rect) == true)
        try await waitUntil {
            harness.session.events.contains("pointer.open.failure")
        }
        XCTAssertTrue(harness.interaction.pointerBegan?(point, rect) == true)
        XCTAssertTrue(harness.interaction.pointerEnded?(point, rect) == true)
        try await waitUntil {
            harness.session.events.contains("pointer.close.1")
        }

        XCTAssertEqual(
            harness.session.events.filter { $0 == "pointer.open" }.count,
            1
        )
        XCTAssertEqual(harness.session.ownedStreamCount, 0)
        try await closePointerHarness(harness)
    }

    @MainActor
    func testPointerAdoptsRuntimeAcceptedRevisionBeforeFirstFrame() async throws {
        let accepted = try DisplayGeometryDTO(
            connectionEpoch: 7,
            geometryRevision: 3,
            logicalHeight: 100,
            logicalWidth: 100,
            orientation: .portrait
        )
        let harness = try await makePointerHarness(
            targetID: "M2031-POINTER-REVISION-ADOPTION",
            configure: { $0.acceptNextPointerGeometry(accepted) }
        )
        let point = PointerViewPoint(x: 50, y: 50)
        let rect = harness.interaction.visibleImageRect()

        XCTAssertTrue(harness.interaction.pointerBegan?(point, rect) == true)
        XCTAssertTrue(harness.interaction.pointerEnded?(point, rect) == true)
        try await waitUntil {
            harness.session.events.contains("pointer.close.1")
        }

        XCTAssertEqual(
            harness.session.events.filter { $0.hasPrefix("pointer.geometry.") },
            ["pointer.geometry.3", "pointer.geometry.3"]
        )
        XCTAssertEqual(harness.session.ownedStreamCount, 0)
        try await closePointerHarness(harness)
    }

    @MainActor
    func testPointerAdoptsRuntimeAcceptedRevisionForAllQueuedGestures()
        async throws
    {
        let accepted = try DisplayGeometryDTO(
            connectionEpoch: 7,
            geometryRevision: 3,
            logicalHeight: 100,
            logicalWidth: 100,
            orientation: .portrait
        )
        let harness = try await makePointerHarness(
            targetID: "M2031-POINTER-QUEUED-REVISION-ADOPTION",
            configure: {
                $0.acceptNextPointerGeometry(accepted)
                $0.blockNextPointerOpen()
            }
        )
        let point = PointerViewPoint(x: 50, y: 50)
        let rect = harness.interaction.visibleImageRect()

        XCTAssertTrue(harness.interaction.pointerBegan?(point, rect) == true)
        XCTAssertTrue(harness.interaction.pointerEnded?(point, rect) == true)
        try await waitUntil {
            harness.session.events.contains("pointer.open.blocked")
        }
        XCTAssertTrue(harness.interaction.pointerBegan?(point, rect) == true)
        XCTAssertTrue(harness.interaction.pointerEnded?(point, rect) == true)
        harness.session.releaseBlockedPointerOpen()
        try await waitUntil {
            harness.session.events.filter { $0 == "pointer.close.1" }.count == 2
        }

        XCTAssertEqual(
            harness.session.events.filter { $0 == "pointer.open" }.count,
            2
        )
        XCTAssertEqual(
            harness.session.events.filter { $0.hasPrefix("pointer.geometry.") },
            [
                "pointer.geometry.3", "pointer.geometry.3",
                "pointer.geometry.3", "pointer.geometry.3",
            ]
        )
        XCTAssertEqual(harness.session.ownedStreamCount, 0)
        try await closePointerHarness(harness)
    }

    @MainActor
    func testPointerCloseFailureCancelsAndAdvancesNextGesture() async throws {
        let harness = try await makePointerHarness(
            targetID: "M2031-POINTER-CLOSE-RECOVERY",
            configure: { $0.failNextPointerClose() }
        )
        let point = PointerViewPoint(x: 50, y: 50)
        let rect = harness.interaction.visibleImageRect()

        XCTAssertTrue(harness.interaction.pointerBegan?(point, rect) == true)
        XCTAssertTrue(harness.interaction.pointerEnded?(point, rect) == true)
        try await waitUntil {
            harness.session.events.contains("pointer.cancel.ownerLost")
        }
        XCTAssertTrue(harness.interaction.pointerBegan?(point, rect) == true)
        XCTAssertTrue(harness.interaction.pointerEnded?(point, rect) == true)
        try await waitUntil {
            harness.session.events.contains("pointer.close.1")
        }

        XCTAssertEqual(harness.session.ownedStreamCount, 0)
        try await closePointerHarness(harness)
    }

    @MainActor
    func testPointerFrameFailureCancelsAndAllowsNextGesture() async throws {
        let harness = try await makePointerHarness(
            targetID: "M2031-POINTER-FRAME-RECOVERY",
            configure: { $0.failNextPointerFrame() }
        )
        let point = PointerViewPoint(x: 50, y: 50)
        let rect = harness.interaction.visibleImageRect()

        XCTAssertTrue(harness.interaction.pointerBegan?(point, rect) == true)
        XCTAssertTrue(harness.interaction.pointerEnded?(point, rect) == true)
        try await waitUntil {
            harness.session.events.contains("pointer.cancel.clientInterrupted")
        }
        XCTAssertTrue(harness.interaction.pointerBegan?(point, rect) == true)
        XCTAssertTrue(harness.interaction.pointerEnded?(point, rect) == true)
        try await waitUntil {
            harness.session.events.contains("pointer.close.1")
        }

        XCTAssertEqual(harness.session.ownedStreamCount, 0)
        try await closePointerHarness(harness)
    }

    @MainActor
    func testRuntimeReconnectPreservesLiveIdentityWithoutSecondAttach()
        async throws
    {
        let harness = try await makePointerHarness(
            targetID: "M2031-RUNTIME-RECONNECT"
        )
        let original = try XCTUnwrap(harness.session.currentAttachment)
        let point = PointerViewPoint(x: 50, y: 50)
        let rect = harness.interaction.visibleImageRect()
        let toolbarButtons = harness.window.toolbar?.items.compactMap {
            $0.view as? NSButton
        } ?? []
        XCTAssertFalse(toolbarButtons.isEmpty)
        let availabilityOverlay = try XCTUnwrap(descendant(
            in: try XCTUnwrap(harness.window.contentView),
            identifier: ProductionGUIHostViewIdentifier.availabilityOverlay
        ) as? ProductionGUIHostAvailabilityOverlayView)
        XCTAssertEqual(
            availabilityOverlay.presentation?.videoMessage,
            "Video preparing"
        )
        XCTAssertNil(availabilityOverlay.presentation?.pointerMessage)

        let mouseDown = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDown,
            location: harness.interaction.convert(
                NSPoint(x: point.x, y: point.y),
                to: nil
            ),
            modifierFlags: [],
            timestamp: 0,
            windowNumber: harness.window.windowNumber,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        ))
        harness.interaction.mouseDown(with: mouseDown)
        XCTAssertTrue(harness.interaction.hasPointerOverlay)
        try harness.session.simulateDeviceDisconnected()
        try await waitUntil {
            harness.interaction.geometry == nil
                && !harness.interaction.hasPointerOverlay
                && toolbarButtons.allSatisfy { !$0.isEnabled }
                && availabilityOverlay.presentation?.videoMessage
                    == "Video disconnected"
                && availabilityOverlay.presentation?.pointerMessage
                    == "Touch unavailable"
        }
        XCTAssertNil(harness.session.currentAttachment)
        XCTAssertTrue(harness.interaction.pointerBegan?(point, rect) == false)

        let replacement = try harness.session.simulateDeviceReattached()
        try await waitUntil {
            harness.session.availabilityCallCount >= 2
                && toolbarButtons.allSatisfy(\.isEnabled)
                && availabilityOverlay.presentation?.pointerMessage
                    == "Touch preparing"
        }
        XCTAssertEqual(replacement.connectionEpoch, original.connectionEpoch + 1)
        XCTAssertEqual(replacement.liveOwnerID, original.liveOwnerID)
        XCTAssertEqual(replacement.subscriptionID, original.subscriptionID)
        XCTAssertEqual(
            harness.session.events.filter { $0 == "attach" }.count,
            1
        )

        try harness.controller.applyRuntimeGeometry(
            DisplayGeometryDTO(
                connectionEpoch: replacement.connectionEpoch,
                geometryRevision: 1,
                logicalHeight: 100,
                logicalWidth: 100,
                orientation: .portrait
            ),
            toWindow: harness.window.identifier!.rawValue
        )
        let replacementRect = harness.interaction.visibleImageRect()
        XCTAssertNil(availabilityOverlay.presentation?.pointerMessage)
        XCTAssertEqual(
            availabilityOverlay.presentation?.videoMessage,
            "Video disconnected"
        )
        XCTAssertTrue(
            harness.interaction.pointerBegan?(point, replacementRect) == true
        )
        XCTAssertTrue(
            harness.interaction.pointerEnded?(point, replacementRect) == true
        )
        try await waitUntil {
            harness.session.events.contains("pointer.close.1")
        }
        try harness.session.simulateRuntimePointerObservation(
            frameKind: .begin,
            x: "0.5",
            y: "0.5"
        )
        try await waitUntil {
            harness.interaction.hasPointerOverlay
        }

        try await closePointerHarness(harness)
        XCTAssertEqual(harness.session.detachedAttachment, replacement)
    }

    @MainActor
    func testQueuedPointerGeometryMismatchFailsClosedAndNextGestureRecovers()
        async throws
    {
        let harness = try await makePointerHarness(
            targetID: "M2031-POINTER-GEOMETRY-RECOVERY",
            configure: { $0.blockNextPointerClose() }
        )
        let point = PointerViewPoint(x: 50, y: 50)
        let rect = harness.interaction.visibleImageRect()

        XCTAssertTrue(harness.interaction.pointerBegan?(point, rect) == true)
        XCTAssertTrue(harness.interaction.pointerEnded?(point, rect) == true)
        try await waitUntil {
            harness.session.events.contains("pointer.close.blocked")
        }
        XCTAssertTrue(harness.interaction.pointerBegan?(point, rect) == true)
        XCTAssertTrue(harness.interaction.pointerEnded?(point, rect) == true)
        try harness.controller.applyRuntimeGeometry(
            DisplayGeometryDTO(
                connectionEpoch: 7,
                geometryRevision: 2,
                logicalHeight: 100,
                logicalWidth: 100,
                orientation: .portrait
            ),
            toWindow: harness.window.identifier!.rawValue
        )
        harness.session.releaseBlockedPointerClose()
        try await waitUntil {
            harness.session.events.contains("pointer.close.1")
                && harness.session.ownedStreamCount == 0
        }

        let currentRect = harness.interaction.visibleImageRect()
        XCTAssertTrue(harness.interaction.pointerBegan?(point, currentRect) == true)
        XCTAssertTrue(harness.interaction.pointerEnded?(point, currentRect) == true)
        try await waitUntil {
            harness.session.events.filter { $0 == "pointer.close.1" }.count == 2
        }
        XCTAssertEqual(
            harness.session.events.filter { $0 == "pointer.open" }.count,
            2,
            "stale queued gesture is rejected before StreamOpen"
        )
        try await closePointerHarness(harness)
    }

    @MainActor
    func testPointerCloseAndCancelFailureReconnectsRuntimeSession() async throws {
        let target = try CanonicalUDID(canonicalString: "M2031-POINTER-RECONNECT")
        let firstAttached = expectation(description: "first pointer runtime attached")
        let firstClosed = expectation(description: "failed pointer runtime closed")
        let secondAttached = expectation(description: "replacement pointer runtime attached")
        let secondClosed = expectation(description: "replacement pointer runtime closed")
        let first = try MockGUIHostRuntimeSession(
            target: target,
            attached: firstAttached,
            closed: firstClosed,
            supportsPointerStreams: true
        )
        first.failNextPointerClose()
        first.failNextPointerCancel()
        let second = try MockGUIHostRuntimeSession(
            target: target,
            attached: secondAttached,
            closed: secondClosed,
            supportsPointerStreams: true
        )
        let sessions = MockGUIHostRuntimeSessionFactory(sessions: [first, second])
        let controller = ProductionGUIHostWindowController(
            catalog: ProductionAVFoundationVideoSourceCatalog(),
            mappingCoordinator: ProductionVideoSourceMappingCoordinator(
                store: InMemoryVideoSourceMappingStore()
            ),
            runtimeSessionFactory: { _ in try sessions.next() },
            toolbarRepositoryRoot: repositoryRoot(),
            presentsWindows: false
        )
        let identifier = try XCTUnwrap(controller.createWindow(for: target))
        await fulfillment(of: [firstAttached], timeout: 3)
        try await waitUntil { first.events.contains("availability") }
        await Task.yield()
        try controller.applyRuntimeGeometry(pointerGeometry(), toWindow: identifier)
        let window = try XCTUnwrap(NSApplication.shared.windows.first {
            $0.identifier?.rawValue == identifier
        })
        Self.retainedHeadlessWindows.append(window)
        let interaction = try XCTUnwrap(descendant(
            in: try XCTUnwrap(window.contentView),
            identifier: ProductionGUIHostViewIdentifier.interactionCanvas
        ) as? ProductionGUIHostInteractionView)
        let point = PointerViewPoint(x: 50, y: 50)
        let rect = interaction.visibleImageRect()

        // Availability precedes pointer readiness by one asynchronous handoff. A false
        // begin has not accepted or dispatched an interaction, so retry boundedly.
        try await waitUntil {
            interaction.pointerBegan?(point, rect) == true
        }
        XCTAssertTrue(interaction.pointerEnded?(point, rect) == true)
        await fulfillment(of: [firstClosed, secondAttached], timeout: 3)
        try await waitUntil { second.events.contains("availability") }
        XCTAssertTrue(first.events.contains("pointer.cancel.failure"))
        try await waitUntil {
            interaction.pointerBegan?(point, rect) == true
        }
        XCTAssertTrue(interaction.pointerEnded?(point, rect) == true)
        try await waitUntil { second.events.contains("pointer.close.1") }

        XCTAssertFalse(controller.windowShouldClose(window))
        await fulfillment(of: [secondClosed], timeout: 3)
        controller.stopMonitoring()
    }

    func testLiveWindowSizingReservesControlsAndBoundsCanvasAspect() {
        let content = ProductionLiveWindowSizing.constrainedContentSize(
            proposedContentSize: NSSize(width: 700, height: 900),
            currentContentSize: NSSize(width: 405, height: 772),
            canvasAspectRatio: 9.0 / 16.0,
            sourceControlsHeight: 52,
            maximumFrameSize: NSSize(width: 1_200, height: 900),
            frameChromeHeight: 52
        )
        let canvasHeight = content.height - 52
        XCTAssertLessThanOrEqual(
            abs(content.width - canvasHeight * (9.0 / 16.0)),
            0.5
        )
        XCTAssertLessThanOrEqual(content.height + 52, 900.000_001)
    }

    func testLiveResizeDriverFreezesEdgeAndCornerClassification() {
        let reference = NSSize(width: 700, height: 1_600)
        let controls: CGFloat = 52
        let chrome: CGFloat = 40
        XCTAssertEqual(
            ProductionLiveWindowSizing.liveResizeDriver(
                proposedFrameSize: NSSize(width: 740, height: 1_600),
                referenceFrameSize: reference,
                sourceControlsHeight: controls,
                frameChromeHeight: chrome
            ),
            .widthEdge
        )
        XCTAssertEqual(
            ProductionLiveWindowSizing.liveResizeDriver(
                proposedFrameSize: NSSize(width: 700, height: 1_640),
                referenceFrameSize: reference,
                sourceControlsHeight: controls,
                frameChromeHeight: chrome
            ),
            .heightEdge
        )
        XCTAssertEqual(
            ProductionLiveWindowSizing.liveResizeDriver(
                proposedFrameSize: NSSize(width: 740, height: 1_640),
                referenceFrameSize: reference,
                sourceControlsHeight: controls,
                frameChromeHeight: chrome
            ),
            .corner
        )
    }

    func testFrozenLiveResizeDriversRemainMonotonicAcrossContinuousCallbacks() {
        let ratio: CGFloat = 1_170.0 / 2_532.0
        let controls: CGFloat = 52
        let initial = NSSize(width: 700, height: 700 / ratio + controls)
        for driver in [
            ProductionLiveResizeDriver.widthEdge,
            .heightEdge,
            .corner,
        ] {
            for direction: CGFloat in [-1, 1] {
                var previousPrimary: CGFloat?
                for step in 1...100 {
                    let delta = direction * CGFloat(step)
                    let proposed: NSSize
                    switch driver {
                    case .widthEdge:
                        proposed = NSSize(
                            width: initial.width + delta,
                            height: initial.height
                        )
                    case .heightEdge:
                        proposed = NSSize(
                            width: initial.width,
                            height: initial.height + delta / ratio
                        )
                    case .corner:
                        proposed = NSSize(
                            width: initial.width + delta,
                            height: initial.height + delta / ratio
                        )
                    }
                    let content = ProductionLiveWindowSizing.constrainedContentSize(
                        proposedContentSize: proposed,
                        currentContentSize: initial,
                        canvasAspectRatio: ratio,
                        sourceControlsHeight: controls,
                        maximumFrameSize: NSSize(width: 2_000, height: 2_000),
                        frameChromeHeight: 0,
                        resizeDriver: driver
                    )
                    let canvasHeight = content.height - controls
                    XCTAssertLessThanOrEqual(
                        abs(content.width - canvasHeight * ratio),
                        0.5,
                        "driver=\(driver) direction=\(direction) step=\(step)"
                    )
                    let primary = driver == .heightEdge
                        ? canvasHeight
                        : content.width
                    if let previousPrimary {
                        if direction > 0 {
                            XCTAssertGreaterThanOrEqual(
                                primary + 0.001,
                                previousPrimary
                            )
                        } else {
                            XCTAssertLessThanOrEqual(
                                primary - 0.001,
                                previousPrimary
                            )
                        }
                    }
                    previousPrimary = primary
                }
            }
        }
    }

    func testAdoptableSizingTracksNearestPrimaryWithoutCoarseSteps() {
        let sourceControlsHeight: CGFloat = 92
        for ratio: CGFloat in [1_170.0 / 2_532.0, 2_532.0 / 1_170.0] {
            var previousPrimary: CGFloat?
            for tick in (320 * 4)...(500 * 4) {
                let preferredPrimary = CGFloat(tick) / 4
                let preferredCanvasSize = ratio >= 1
                    ? NSSize(
                        width: preferredPrimary * ratio,
                        height: preferredPrimary
                    )
                    : NSSize(
                        width: preferredPrimary,
                        height: preferredPrimary / ratio
                    )
                let contentSize = ProductionLiveWindowSizing.adoptableContentSize(
                    preferredCanvasSize: preferredCanvasSize,
                    canvasAspectRatio: ratio,
                    sourceControlsHeight: sourceControlsHeight,
                    maximumCanvasSize: NSSize(width: 1_200, height: 1_200),
                    minimumContentWidth: 1
                )
                let canvasHeight = contentSize.height - sourceControlsHeight
                let adoptedPrimary = ratio >= 1 ? canvasHeight : contentSize.width
                XCTAssertLessThanOrEqual(
                    abs(adoptedPrimary - preferredPrimary),
                    0.5,
                    "ratio=\(ratio) preferred=\(preferredPrimary) adopted=\(adoptedPrimary)"
                )
                XCTAssertLessThanOrEqual(
                    abs(contentSize.width - canvasHeight * ratio),
                    0.5,
                    "ratio=\(ratio) content=\(contentSize)"
                )
                if let previousPrimary {
                    XCTAssertGreaterThanOrEqual(adoptedPrimary, previousPrimary)
                    XCTAssertLessThanOrEqual(adoptedPrimary - previousPrimary, 1)
                }
                previousPrimary = adoptedPrimary
            }
        }
    }

    func testProgrammaticLiveWindowSizingDoesNotExpandPreferredPrimaryForRatioQuantization() {
        for ratio in [1_170.0 / 2_532.0, 2_532.0 / 1_170.0] {
            let preferredCanvas = ratio < 1
                ? NSSize(width: 375, height: 375 / ratio)
                : NSSize(width: 375 * ratio, height: 375)
            let content = ProductionLiveWindowSizing.adoptableContentSize(
                preferredCanvasSize: preferredCanvas,
                canvasAspectRatio: ratio,
                sourceControlsHeight: 52,
                maximumCanvasSize: NSSize(width: 2_000, height: 2_000),
                minimumContentWidth: 65,
                preferredPrimaryConstraint: .notExceedingPreferred
            )
            let canvasHeight = content.height - 52
            let primary = ratio < 1 ? content.width : canvasHeight
            XCTAssertLessThanOrEqual(primary, 375.000_001)
            XCTAssertLessThanOrEqual(
                abs(content.width - canvasHeight * ratio),
                0.5
            )
        }
    }

    func testLiveResizeSizingTracksPreferredPrimaryBeforeRatioTieBreak() {
        let ratio = 1_170.0 / 2_532.0
        let content = ProductionLiveWindowSizing.adoptableContentSize(
            preferredCanvasSize: NSSize(width: 375, height: 375 / ratio),
            canvasAspectRatio: ratio,
            sourceControlsHeight: 52,
            maximumCanvasSize: NSSize(width: 2_000, height: 2_000),
            minimumContentWidth: 65,
            preferredPrimaryConstraint: .unrestricted
        )
        let canvasHeight = content.height - 52

        XCTAssertEqual(content.width, 375, accuracy: 0.5)
        XCTAssertLessThanOrEqual(
            abs(content.width - canvasHeight * ratio),
            0.5
        )
    }

    func testLiveResizeSizingEnforcesProductMinimumAcrossOrientation() {
        for ratio in [1_170.0 / 2_532.0, 2_532.0 / 1_170.0] {
            let content = ProductionLiveWindowSizing.constrainedContentSize(
                proposedContentSize: NSSize(width: 120, height: 180),
                currentContentSize: NSSize(width: 375, height: 864),
                canvasAspectRatio: ratio,
                sourceControlsHeight: 52,
                maximumFrameSize: NSSize(width: 2_000, height: 1_600),
                frameChromeHeight: 52,
                minimumContentWidth: 65
            )
            let canvas = NSSize(width: content.width, height: content.height - 52)
            XCTAssertGreaterThanOrEqual(
                min(canvas.width, canvas.height),
                LiveWindowReservation.minimumCanvasShortEdge - 0.5
            )
            XCTAssertLessThanOrEqual(
                abs(canvas.width - canvas.height * ratio),
                0.5
            )
        }
    }

    func testLiveResizeProductMinimumYieldsToScreenBound() {
        let ratio = 1_170.0 / 2_532.0
        let content = ProductionLiveWindowSizing.constrainedContentSize(
            proposedContentSize: NSSize(width: 120, height: 180),
            currentContentSize: NSSize(width: 375, height: 864),
            canvasAspectRatio: ratio,
            sourceControlsHeight: 52,
            maximumFrameSize: NSSize(width: 300, height: 500),
            frameChromeHeight: 52,
            minimumContentWidth: 65
        )
        let canvas = NSSize(width: content.width, height: content.height - 52)
        XCTAssertLessThan(
            min(canvas.width, canvas.height),
            LiveWindowReservation.minimumCanvasShortEdge
        )
        XCTAssertLessThanOrEqual(content.height + 52, 500.000_001)
        XCTAssertLessThanOrEqual(
            abs(canvas.width - canvas.height * ratio),
            0.5
        )
    }

    func testSourceControlsMinimumWidthExcludesCompressibleDisplayText() {
        XCTAssertEqual(
            ProductionSourceControlsSizing.minimumContentWidth(
                horizontalInset: 6,
                spacing: 3,
                arrangedSubviewCount: 4,
                noncompressibleWidths: [28, 16]
            ),
            65,
            accuracy: 0.001
        )
    }

    func testLiveWindowSizingClampsMinimumWidthToExactFeasibleRatio() {
        let content = ProductionLiveWindowSizing.constrainedContentSize(
            proposedContentSize: NSSize(width: 300, height: 600),
            currentContentSize: NSSize(width: 405, height: 772),
            canvasAspectRatio: 1_170.0 / 2_532.0,
            sourceControlsHeight: 52,
            maximumFrameSize: NSSize(width: 1_200, height: 900),
            frameChromeHeight: 52,
            minimumContentWidth: 430
        )
        let visibleCanvasHeight = content.height - 52
        XCTAssertLessThan(content.width, 430)
        XCTAssertLessThanOrEqual(
            abs(content.width - visibleCanvasHeight * (1_170.0 / 2_532.0)),
            0.5
        )
    }

    func testLiveWindowSizingReconcilesPartialAxisAdoption() {
        let reference = NSRect(x: 100, y: 100, width: 400, height: 700)
        let expected = NSSize(width: 360, height: 800)
        let visible = NSRect(x: 0, y: 0, width: 2_000, height: 2_000)

        let rightEdge = ProductionLiveWindowSizing.reconciledLiveResizeFrame(
            referenceFrame: reference,
            adoptedFrame: NSRect(x: 100, y: 100, width: 360, height: 700),
            expectedFrameSize: expected,
            visibleFrame: visible
        )
        XCTAssertEqual(rightEdge, NSRect(x: 100, y: 50, width: 360, height: 800))

        let leftEdge = ProductionLiveWindowSizing.reconciledLiveResizeFrame(
            referenceFrame: reference,
            adoptedFrame: NSRect(x: 140, y: 100, width: 360, height: 700),
            expectedFrameSize: expected,
            visibleFrame: visible
        )
        XCTAssertEqual(leftEdge, NSRect(x: 140, y: 50, width: 360, height: 800))

        let topEdge = ProductionLiveWindowSizing.reconciledLiveResizeFrame(
            referenceFrame: reference,
            adoptedFrame: NSRect(x: 100, y: 100, width: 400, height: 800),
            expectedFrameSize: expected,
            visibleFrame: visible
        )
        XCTAssertEqual(topEdge, NSRect(x: 120, y: 100, width: 360, height: 800))

        let bottomEdge = ProductionLiveWindowSizing.reconciledLiveResizeFrame(
            referenceFrame: reference,
            adoptedFrame: NSRect(x: 100, y: 0, width: 400, height: 800),
            expectedFrameSize: expected,
            visibleFrame: visible
        )
        XCTAssertEqual(bottomEdge, NSRect(x: 120, y: 0, width: 360, height: 800))
    }

    func testProgrammaticReservationRetriesTransientAdoptedWidth() {
        XCTAssertTrue(ProductionLiveWindowSizing.shouldRetryProgrammaticReservation(
            adoptedContentWidth: 377,
            desiredContentWidth: 366,
            minimumContentWidthChanged: false
        ))
        XCTAssertTrue(ProductionLiveWindowSizing.shouldRetryProgrammaticReservation(
            adoptedContentWidth: 366,
            desiredContentWidth: 366,
            minimumContentWidthChanged: true
        ))
        XCTAssertFalse(ProductionLiveWindowSizing.shouldRetryProgrammaticReservation(
            adoptedContentWidth: 366,
            desiredContentWidth: 366,
            minimumContentWidthChanged: false
        ))
    }

    func testRotateResultProjectsNewGeometryOnCurrentConnectionOnly() throws {
        let current = try DisplayGeometryDTO(
            connectionEpoch: 7,
            geometryRevision: 3,
            logicalHeight: 2_532,
            logicalWidth: 1_170,
            orientation: .portrait
        )
        let result = try RepositoryJSONObject(members: [
            RepositoryJSONMember(key: "outcome", value: .string("succeeded")),
            RepositoryJSONMember(
                key: "value",
                value: .object(try RepositoryJSONObject(members: [
                    RepositoryJSONMember(
                        key: "currentDisplayOrientation",
                        value: .string("landscapeLeft")
                    ),
                    RepositoryJSONMember(
                        key: "direction",
                        value: .string("right")
                    ),
                    RepositoryJSONMember(
                        key: "displayOrientationChanged",
                        value: .bool(true)
                    ),
                    RepositoryJSONMember(
                        key: "geometryRevision",
                        value: .number(.uint64(4))
                    ),
                    RepositoryJSONMember(
                        key: "logicalHeight",
                        value: .number(.uint64(1_170))
                    ),
                    RepositoryJSONMember(
                        key: "logicalWidth",
                        value: .number(.uint64(2_532))
                    ),
                    RepositoryJSONMember(
                        key: "orientation",
                        value: .string("landscapeLeft")
                    ),
                    RepositoryJSONMember(
                        key: "outcomeKnown",
                        value: .bool(true)
                    ),
                    RepositoryJSONMember(
                        key: "previousDisplayOrientation",
                        value: .string("portrait")
                    ),
                    RepositoryJSONMember(
                        key: "requestedDirection",
                        value: .string("right")
                    ),
                    RepositoryJSONMember(
                        key: "rotateResponseOrientation",
                        value: .string("landscapeLeft")
                    ),
                    RepositoryJSONMember(
                        key: "visibleOrientationConfirmed",
                        value: .bool(true)
                    ),
                ]))
            ),
        ])

        let rotated = try XCTUnwrap(
            ProductionLiveGeometryProjection.rotatedGeometry(
                result: result,
                current: current,
                expectedConnectionEpoch: 7
            )
        )
        XCTAssertEqual(rotated.geometryRevision, 4)
        XCTAssertEqual(rotated.logicalWidth, 2_532)
        XCTAssertEqual(rotated.logicalHeight, 1_170)
        XCTAssertEqual(rotated.orientation, .landscapeLeft)
        XCTAssertNil(ProductionLiveGeometryProjection.rotatedGeometry(
            result: result,
            current: current,
            expectedConnectionEpoch: 8
        ))
        let unconfirmed = try RepositoryJSONObject(members: [
            RepositoryJSONMember(key: "outcome", value: .string("succeeded")),
            RepositoryJSONMember(
                key: "value",
                value: .object(try RepositoryJSONObject(members: [
                    RepositoryJSONMember(
                        key: "currentDisplayOrientation",
                        value: .string("portrait")
                    ),
                    RepositoryJSONMember(
                        key: "direction",
                        value: .string("right")
                    ),
                    RepositoryJSONMember(
                        key: "displayOrientationChanged",
                        value: .bool(false)
                    ),
                    RepositoryJSONMember(
                        key: "geometryRevision",
                        value: .number(.uint64(5))
                    ),
                    RepositoryJSONMember(
                        key: "logicalHeight",
                        value: .number(.uint64(2_532))
                    ),
                    RepositoryJSONMember(
                        key: "logicalWidth",
                        value: .number(.uint64(1_170))
                    ),
                    RepositoryJSONMember(
                        key: "orientation",
                        value: .string("portrait")
                    ),
                    RepositoryJSONMember(
                        key: "outcomeKnown",
                        value: .bool(false)
                    ),
                    RepositoryJSONMember(
                        key: "previousDisplayOrientation",
                        value: .string("portrait")
                    ),
                    RepositoryJSONMember(
                        key: "requestedDirection",
                        value: .string("right")
                    ),
                    RepositoryJSONMember(
                        key: "rotateResponseOrientation",
                        value: .string("portraitUpsideDown")
                    ),
                    RepositoryJSONMember(
                        key: "visibleOrientationConfirmed",
                        value: .bool(false)
                    ),
                ]))
            ),
        ])
        XCTAssertNil(ProductionLiveGeometryProjection.rotatedGeometry(
            result: unconfirmed,
            current: current,
            expectedConnectionEpoch: 7
        ))
    }

    func testRotateResultStatusNamesUnconfirmedCurrentDirection() throws {
        XCTAssertNil(ProductionGUIHostWindowController.resultStatus(
            try Self.rotateResult(
                current: "landscapeLeft",
                previous: "portrait",
                response: "landscapeLeft",
                changed: true,
                confirmed: true
            )
        ))
        XCTAssertEqual(
            ProductionGUIHostWindowController.resultStatus(
                try Self.rotateResult(
                    current: "landscapeRight",
                    previous: "landscapeRight",
                    response: "portraitUpsideDown",
                    changed: false,
                    confirmed: false
                )
            ),
            "No visible rotation; current direction is Landscape Right"
        )
        XCTAssertEqual(
            ProductionGUIHostWindowController.resultStatus(
                try Self.rotateResult(
                    current: "portrait",
                    previous: "landscapeRight",
                    response: "portraitUpsideDown",
                    changed: true,
                    confirmed: false
                )
            ),
            "Visible direction is Portrait"
        )
    }

    func testPendingRotateDefersGenericPresentationUntilActualGeometry() throws {
        let portrait = try DisplayGeometryDTO(
            connectionEpoch: 7,
            geometryRevision: 1,
            logicalHeight: 2_532,
            logicalWidth: 1_170,
            orientation: .portrait
        )
        let landscape = try LiveSamplePresentationFormat(
            sourceEpoch: 5,
            width: 2_532,
            height: 1_170,
            formatRevision: 2
        )
        XCTAssertEqual(
            ProductionLiveGeometryProjection.presentationGeometry(
                format: landscape,
                current: portrait
            ),
            .deferred
        )

        let actual = try DisplayGeometryDTO(
            connectionEpoch: 7,
            geometryRevision: 2,
            logicalHeight: 1_170,
            logicalWidth: 2_532,
            orientation: .landscapeLeft
        )
        XCTAssertEqual(
            ProductionLiveGeometryProjection.presentationGeometry(
                format: landscape,
                current: actual
            ),
            .current(actual)
        )
    }

    func testCoordinateAdmissionRequiresVideoConvergenceOnlyWhileVideoIsLive()
        throws
    {
        let target = try CanonicalUDID(
            canonicalString: "M2031-COORDINATE-CONVERGENCE"
        )
        var model = try LiveWindowModel(
            identityPlaceholder: IdentityPlaceholder(
                deviceName: "iPhone",
                canonicalUDID: target
            ),
            screenVisibleFrame: LiveWindowRect(
                x: 0,
                y: 0,
                width: 1_440,
                height: 900
            )
        )
        try model.setControlAvailable(connectionEpoch: 7)
        let geometry = try DisplayGeometryDTO(
            connectionEpoch: 7,
            geometryRevision: 4,
            logicalHeight: 2_532,
            logicalWidth: 1_170,
            orientation: .portrait
        )
        _ = try model.updateRuntimeGeometry(geometry)
        let binding = VideoBindingIdentity(
            canonicalUDID: target,
            connectionEpoch: 7,
            sourceID: String(repeating: "a", count: 64),
            sourceEpoch: 5,
            geometryRevision: 4
        )
        XCTAssertEqual(
            ProductionLiveGeometryProjection.coordinateAdmissionGeometry(
                liveModel: model,
                videoBinding: binding,
                videoBindingInFlight: true
            ),
            geometry,
            "video-unavailable pointer uses current Runtime authority independently"
        )

        _ = try model.updateSamplePresentation(LiveSamplePresentationFormat(
            sourceEpoch: 4,
            width: 1_170,
            height: 2_532
        ))
        XCTAssertNil(ProductionLiveGeometryProjection.coordinateAdmissionGeometry(
            liveModel: model,
            videoBinding: binding,
            videoBindingInFlight: false
        ))

        _ = try model.updateSamplePresentation(LiveSamplePresentationFormat(
            sourceEpoch: 5,
            width: 2_532,
            height: 1_170
        ))
        XCTAssertNil(ProductionLiveGeometryProjection.coordinateAdmissionGeometry(
            liveModel: model,
            videoBinding: binding,
            videoBindingInFlight: false
        ))

        _ = try model.updateSamplePresentation(LiveSamplePresentationFormat(
            sourceEpoch: 5,
            width: 1_170,
            height: 2_532,
            formatRevision: 2
        ))
        XCTAssertNil(ProductionLiveGeometryProjection.coordinateAdmissionGeometry(
            liveModel: model,
            videoBinding: VideoBindingIdentity(
                canonicalUDID: target,
                connectionEpoch: 7,
                sourceID: binding.sourceID,
                sourceEpoch: 5,
                geometryRevision: 3
            ),
            videoBindingInFlight: false
        ))
        XCTAssertNil(ProductionLiveGeometryProjection.coordinateAdmissionGeometry(
            liveModel: model,
            videoBinding: binding,
            videoBindingInFlight: true
        ))
        XCTAssertEqual(
            ProductionLiveGeometryProjection.coordinateAdmissionGeometry(
                liveModel: model,
                videoBinding: binding,
                videoBindingInFlight: false
            ),
            geometry
        )

        XCTAssertTrue(model.freezeVideo(unavailableReason: .deviceDetached))
        XCTAssertEqual(
            ProductionLiveGeometryProjection.coordinateAdmissionGeometry(
                liveModel: model,
                videoBinding: nil,
                videoBindingInFlight: true
            ),
            geometry,
            "frozen video never becomes coordinate authority"
        )
    }

    @MainActor
    func testAvailabilityOverlayPresentsIndependentStatesWithoutHitTesting() {
        let overlay = ProductionGUIHostAvailabilityOverlayView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 640)
        )
        overlay.update(ProductionLiveAvailabilityOverlayPresentation(
            videoAvailability: .frozen(sourceEpoch: 4, formatRevision: 2),
            pointerAvailability: .available(
                connectionEpoch: 8,
                geometryRevision: 3
            )
        ))
        XCTAssertEqual(overlay.presentation?.videoMessage, "Video disconnected")
        XCTAssertNil(overlay.presentation?.pointerMessage)
        XCTAssertFalse(overlay.presentation?.videoIsPreparing == true)
        XCTAssertEqual(overlay.presentation?.videoSymbolName, "video.slash.fill")
        XCTAssertFalse(overlay.isHidden)
        XCTAssertNil(overlay.hitTest(NSPoint(x: 100, y: 100)))
        overlay.layoutSubtreeIfNeeded()
        XCTAssertEqual(
            overlay.videoScrimOpacity,
            ProductionGUIHostAvailabilityOverlayView.videoScrimAlpha
        )
        XCTAssertEqual(overlay.videoStatusFrame.midX, overlay.bounds.midX, accuracy: 1)
        XCTAssertEqual(overlay.videoStatusFrame.midY, overlay.bounds.midY, accuracy: 1)
        XCTAssertTrue(overlay.videoUsesSymbol)
        XCTAssertFalse(overlay.videoUsesProgressIndicator)

        overlay.update(ProductionLiveAvailabilityOverlayPresentation(
            videoAvailability: .live(sourceEpoch: 5, formatRevision: 1),
            pointerAvailability: .preparing(reason: "awaitingGeometry")
        ))
        XCTAssertNil(overlay.presentation?.videoMessage)
        XCTAssertEqual(overlay.presentation?.pointerMessage, "Touch preparing")
        XCTAssertTrue(overlay.presentation?.pointerIsPreparing == true)
        XCTAssertNil(overlay.presentation?.pointerSymbolName)
        overlay.layoutSubtreeIfNeeded()
        XCTAssertEqual(overlay.videoScrimOpacity, 0)
        XCTAssertLessThan(overlay.pointerStatusFrame.midY, overlay.bounds.midY)
        XCTAssertTrue(overlay.pointerUsesProgressIndicator)
        XCTAssertFalse(overlay.pointerUsesSymbol)
        XCTAssertEqual(
            overlay.pointerStatusFrame.minY,
            overlay.bounds.minY + 18,
            accuracy: 1
        )

        overlay.update(ProductionLiveAvailabilityOverlayPresentation(
            videoAvailability: .frozen(sourceEpoch: 5, formatRevision: 1),
            pointerAvailability: .unavailable(reason: "deviceDisconnected")
        ))
        XCTAssertEqual(overlay.presentation?.videoMessage, "Video disconnected")
        XCTAssertEqual(overlay.presentation?.pointerMessage, "Touch unavailable")
        XCTAssertEqual(
            overlay.presentation?.pointerSymbolName,
            "hand.raised.slash.fill"
        )
        overlay.layoutSubtreeIfNeeded()
        XCTAssertTrue(overlay.pointerUsesSymbol)
        XCTAssertFalse(overlay.pointerUsesProgressIndicator)
        XCTAssertLessThan(
            overlay.pointerStatusFrame.maxY,
            overlay.videoStatusFrame.minY
        )
        XCTAssertGreaterThanOrEqual(
            overlay.pointerStatusFrame.minX,
            overlay.bounds.minX + 18
        )
        XCTAssertLessThanOrEqual(
            overlay.pointerStatusFrame.maxX,
            overlay.bounds.maxX - 18
        )

        overlay.update(ProductionLiveAvailabilityOverlayPresentation(
            videoAvailability: .live(sourceEpoch: 5, formatRevision: 1),
            pointerAvailability: .available(
                connectionEpoch: 8,
                geometryRevision: 4
            )
        ))
        XCTAssertTrue(overlay.isHidden)
    }

    @MainActor
    func testAvailabilityOverlayOwnsIdentityAndHighContrastVideoStatus() {
        let overlay = ProductionGUIHostAvailabilityOverlayView(
            frame: NSRect(x: 0, y: 0, width: 320, height: 640)
        )
        overlay.update(
            ProductionLiveAvailabilityOverlayPresentation(
                videoAvailability: .unavailable(reason: .awaitingBinding),
                pointerAvailability: .unavailable(reason: "deviceDisconnected")
            ),
            identityMessage: "Test iPhone\nTARGET-UDID"
        )
        overlay.layoutSubtreeIfNeeded()

        XCTAssertTrue(overlay.videoStatusText.contains("Test iPhone\nTARGET-UDID"))
        XCTAssertEqual(
            overlay.videoStatusText.components(separatedBy: "Video preparing").count - 1,
            1
        )
        XCTAssertGreaterThanOrEqual(overlay.videoStatusSurfaceOpacity, 0.76)
        XCTAssertTrue(overlay.statusForegroundsUseHighContrastTint)
        XCTAssertTrue(overlay.videoUsesProgressIndicator)
        XCTAssertLessThan(
            overlay.pointerStatusFrame.maxY,
            overlay.videoStatusFrame.minY
        )
        XCTAssertNil(overlay.hitTest(NSPoint(x: 160, y: 320)))
        XCTAssertEqual(
            ProductionGUIHostAvailabilityOverlayView.statusSurfaceAlpha(
                reduceTransparency: true,
                increaseContrast: false
            ),
            0.92
        )
        XCTAssertEqual(
            ProductionGUIHostAvailabilityOverlayView.statusSurfaceAlpha(
                reduceTransparency: false,
                increaseContrast: true
            ),
            0.92
        )

        overlay.frame = NSRect(x: 0, y: 0, width: 220, height: 300)
        overlay.update(
            ProductionLiveAvailabilityOverlayPresentation(
                videoAvailability: .unavailable(reason: .sourceUnavailable),
                pointerAvailability: .unavailable(reason: "deviceDisconnected")
            ),
            identityMessage: "A Very Long iPhone Device Name\nTARGET-UDID-WITH-LONG-SUFFIX"
        )
        overlay.layoutSubtreeIfNeeded()
        XCTAssertTrue(overlay.videoStatusText.contains("Video unavailable"))
        XCTAssertGreaterThanOrEqual(overlay.videoStatusFrame.minX, 24)
        XCTAssertLessThanOrEqual(overlay.videoStatusFrame.maxX, overlay.bounds.maxX - 24)
        XCTAssertGreaterThanOrEqual(overlay.pointerStatusFrame.minX, 18)
        XCTAssertLessThanOrEqual(
            overlay.pointerStatusFrame.maxX,
            overlay.bounds.maxX - 18
        )
        XCTAssertLessThan(
            overlay.pointerStatusFrame.maxY,
            overlay.videoStatusFrame.minY
        )
        XCTAssertTrue(overlay.statusForegroundsUseHighContrastTint)
        XCTAssertNil(overlay.hitTest(NSPoint(x: 110, y: 150)))
    }

    func testPresentationWithoutPendingRotateDefersToActualGeometryRefresh()
        throws
    {
        let portrait = try DisplayGeometryDTO(
            connectionEpoch: 7,
            geometryRevision: 4,
            logicalHeight: 2_532,
            logicalWidth: 1_170,
            orientation: .portrait
        )
        let landscape = try LiveSamplePresentationFormat(
            sourceEpoch: 5,
            width: 2_532,
            height: 1_170,
            formatRevision: 2
        )
        XCTAssertEqual(
            ProductionLiveGeometryProjection.presentationGeometry(
                format: landscape,
                current: portrait
            ),
            .deferred
        )
    }

    func testInitialVideoGeometryKeepsActualHandednessOrIsProvisional()
        throws
    {
        let actual = try DisplayGeometryDTO(
            connectionEpoch: 7,
            geometryRevision: 9,
            logicalHeight: 1_170,
            logicalWidth: 2_532,
            orientation: .landscapeLeft
        )
        XCTAssertEqual(
            try ProductionLiveGeometryProjection.initialVideoGeometry(
                width: 2_532,
                height: 1_170,
                current: actual,
                expectedConnectionEpoch: 7
            ),
            .init(geometry: actual, isAuthoritative: true)
        )

        let provisional = try ProductionLiveGeometryProjection
            .initialVideoGeometry(
                width: 2_532,
                height: 1_170,
                current: nil,
                expectedConnectionEpoch: 7
            )
        XCTAssertFalse(provisional.isAuthoritative)
        XCTAssertEqual(provisional.geometry.geometryRevision, 0)
        XCTAssertEqual(provisional.geometry.logicalWidth, 2_532)
        XCTAssertEqual(provisional.geometry.logicalHeight, 1_170)

        let upsideDown = try DisplayGeometryDTO(
            connectionEpoch: 7,
            geometryRevision: 10,
            logicalHeight: 2_532,
            logicalWidth: 1_170,
            orientation: .portraitUpsideDown
        )
        XCTAssertTrue(try ProductionLiveGeometryProjection.initialVideoGeometry(
            width: 1_170,
            height: 2_532,
            current: upsideDown,
            expectedConnectionEpoch: 7
        ).isAuthoritative)
    }

    func testCaptureReadyReceiptRebindsProvisionalVideoAndEnablesPointer()
        throws
    {
        let target = try CanonicalUDID(
            canonicalString: "M2031-CAPTURE-RECEIPT-ADOPTION"
        )
        var liveModel = try LiveWindowModel(
            identityPlaceholder: IdentityPlaceholder(
                deviceName: "iPhone",
                canonicalUDID: target
            ),
            screenVisibleFrame: LiveWindowRect(
                x: 0,
                y: 0,
                width: 1_440,
                height: 900
            )
        )
        try liveModel.updateCaptureActiveFormat(LiveCaptureActiveFormat(
            sourceEpoch: 11,
            width: 2_532,
            height: 1_170
        ))
        let binding = VideoBindingIdentity(
            canonicalUDID: target,
            connectionEpoch: 7,
            sourceID: String(repeating: "a", count: 64),
            sourceEpoch: 11,
            geometryRevision: 0
        )
        let collector = ProductionVideoObservationCollector(
            binding: binding,
            sourceWidth: 2_532,
            sourceHeight: 1_170
        )
        let actual = try DisplayGeometryDTO(
            connectionEpoch: 7,
            geometryRevision: 1,
            logicalHeight: 1_170,
            logicalWidth: 2_532,
            orientation: .landscapeLeft
        )

        let adoption = try XCTUnwrap(
            ProductionCaptureReadyGeometryAdoption.prepare(
                geometry: actual,
                attachmentConnectionEpoch: 7,
                captureReadyConnectionEpoch: 7,
                videoBinding: collector.bindingIdentity,
                liveModel: liveModel,
                pointerController: PointerInteractionController(),
                rebindVideo: { collector.rebindGeometry($0) }
            )
        )
        XCTAssertEqual(adoption.liveModel.runtimeGeometry, actual)
        XCTAssertEqual(collector.bindingIdentity.geometryRevision, 1)

        var pointer = adoption.pointerController
        let frame = try pointer.begin(
            at: PointerViewPoint(x: 50, y: 50),
            visibleImageRect: PointerVisibleImageRect(
                x: 0,
                y: 0,
                width: 100,
                height: 100
            ),
            geometry: try XCTUnwrap(adoption.liveModel.runtimeGeometry)
        )
        XCTAssertEqual(frame.expectedGeometry.expectedConnectionEpoch, 7)
        XCTAssertEqual(frame.expectedGeometry.expectedGeometryRevision, 1)
        XCTAssertEqual(
            adoption.liveModel.runtimeGeometry?.orientation,
            .landscapeLeft
        )
    }

    func testCaptureReadyRecoveryRequiresOriginalConnectionEpoch() throws {
        let target = try CanonicalUDID(canonicalString: "M2031-CAPTURE-RECOVERY")
        let attachment = try LiveAttachment(
            canonicalUDID: target,
            liveOwnerID: CanonicalUUID(value: UUID()),
            subscriptionID: CanonicalUUID(value: UUID()),
            connectionEpoch: 7,
            stateRevision: 1
        )

        XCTAssertTrue(ProductionGUIHostWindowController
            .captureReadyActivationCanResume(
                activationConnectionEpoch: 7,
                attachment: attachment
            ))
        XCTAssertFalse(ProductionGUIHostWindowController
            .captureReadyActivationCanResume(
                activationConnectionEpoch: 8,
                attachment: attachment
            ))
        XCTAssertFalse(ProductionGUIHostWindowController
            .captureReadyActivationCanResume(
                activationConnectionEpoch: nil,
                attachment: attachment
            ))
    }

    func testCaptureReadyActivationReusesSameEpochAndRotatesForNewEpoch() {
        let existing = CanonicalUUID(value: UUID())
        let replacement = CanonicalUUID(value: UUID())

        XCTAssertEqual(
            ProductionGUIHostWindowController.captureReadyActivationID(
                existing: existing,
                activationConnectionEpoch: 7,
                bindingConnectionEpoch: 7,
                create: { replacement }
            ),
            existing
        )
        XCTAssertEqual(
            ProductionGUIHostWindowController.captureReadyActivationID(
                existing: existing,
                activationConnectionEpoch: 7,
                bindingConnectionEpoch: 8,
                create: { replacement }
            ),
            replacement
        )
    }

    func testCaptureReadyFailureStatusPreservesCurrentPointerAuthority() {
        XCTAssertNil(ProductionGUIHostWindowController
            .captureReadyFailureStatus(pointerAvailability: .available(
                connectionEpoch: 7,
                geometryRevision: 3
            )))
        XCTAssertEqual(
            ProductionGUIHostWindowController.captureReadyFailureStatus(
                pointerAvailability: .preparing(reason: "awaitingGeometry")
            ),
            "Controls awaiting geometry"
        )
        XCTAssertEqual(
            ProductionGUIHostWindowController.captureReadyFailureStatus(
                pointerAvailability: .unavailable(reason: "runtimeUnavailable")
            ),
            "Controls unavailable"
        )
    }

    func testBoundVideoStartErrorsUseStableNonIdentityDiagnosticCodes() {
        XCTAssertEqual(
            ProductionGUIHostWindowController.boundVideoStartErrorCode(
                SnapshotFrameError.geometryRevisionMismatch
            ),
            "snapshotFrameInvalid"
        )
        XCTAssertEqual(
            ProductionGUIHostWindowController.boundVideoStartErrorCode(
                VideoBindingError.sourceUnavailable
            ),
            "videoBindingInvalid"
        )
        XCTAssertEqual(
            ProductionGUIHostWindowController.boundVideoStartErrorCode(
                AVFoundationVideoSourceError.sourceUnavailable
            ),
            "captureSourceUnavailable"
        )
        XCTAssertEqual(
            ProductionGUIHostWindowController.boundVideoStartErrorCode(
                NSError(domain: "test", code: 1)
            ),
            "boundSessionStartFailed"
        )
    }

    func testVideoCallbackTokenRejectsReplacedBoundSession() {
        let inFlight = UUID()
        let bound = UUID()
        let stale = UUID()

        XCTAssertTrue(ProductionGUIHostWindowController
            .videoCallbackTokenIsCurrent(
                inFlight,
                inFlightToken: inFlight,
                boundToken: nil
            ))
        XCTAssertTrue(ProductionGUIHostWindowController
            .videoCallbackTokenIsCurrent(
                bound,
                inFlightToken: nil,
                boundToken: bound
            ))
        XCTAssertFalse(ProductionGUIHostWindowController
            .videoCallbackTokenIsCurrent(
                stale,
                inFlightToken: nil,
                boundToken: bound
            ))
    }

    @MainActor
    func testWindowUsesInjectedPersistentRuntimeSessionAndClosesIt() async throws {
        let target = try CanonicalUDID(canonicalString: "M2031-GUI-RUNTIME")
        let attached = expectation(description: "runtime attached")
        let closed = expectation(description: "runtime closed")
        let windowClosed = expectation(description: "window reservation released")
        let session = try MockGUIHostRuntimeSession(
            target: target,
            attached: attached,
            closed: closed
        )
        let controller = ProductionGUIHostWindowController(
            catalog: ProductionAVFoundationVideoSourceCatalog(),
            mappingCoordinator: ProductionVideoSourceMappingCoordinator(
                store: InMemoryVideoSourceMappingStore()
            ),
            runtimeSessionFactory: { requested in
                XCTAssertEqual(requested, target)
                return session
            },
            toolbarRepositoryRoot: repositoryRoot(),
            presentsWindows: false
        )
        controller.setWindowClosedHandler { requested, _ in
            XCTAssertEqual(requested, target)
            windowClosed.fulfill()
        }
        let identifier = try XCTUnwrap(controller.createWindow(for: target))
        await fulfillment(of: [attached], timeout: 3)

        let window = try XCTUnwrap(NSApplication.shared.windows.first {
            $0.identifier?.rawValue == identifier
        })
        Self.retainedHeadlessWindows.append(window)
        for _ in 0..<100 where window.toolbar == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        window.contentView?.layoutSubtreeIfNeeded()
        let content = try XCTUnwrap(window.contentView)
        let canvasHost = try XCTUnwrap(descendant(
            in: content,
            identifier: ProductionGUIHostViewIdentifier.canvasHost
        ))
        let videoCanvas = try XCTUnwrap(descendant(
            in: content,
            identifier: ProductionGUIHostViewIdentifier.videoCanvas
        ))
        let interactionCanvas = try XCTUnwrap(descendant(
            in: content,
            identifier: ProductionGUIHostViewIdentifier.interactionCanvas
        ))
        let availabilityOverlay = try XCTUnwrap(descendant(
            in: content,
            identifier: ProductionGUIHostViewIdentifier.availabilityOverlay
        ))
        let sourceControls = try XCTUnwrap(descendant(
            in: content,
            identifier: ProductionGUIHostViewIdentifier.sourceControls
        ))
        let changeSourceButton = try XCTUnwrap(
            sourceControls.subviews.compactMap { $0 as? NSStackView }
                .flatMap(\.arrangedSubviews)
                .compactMap { $0 as? NSButton }
                .first { $0.toolTip == "更换视频源" }
        )
        XCTAssertNotNil(window.toolbar)
        XCTAssertEqual(changeSourceButton.toolTip, "更换视频源")
        XCTAssertEqual(window.titleVisibility, .hidden)
        XCTAssertEqual(videoCanvas.frame, interactionCanvas.frame)
        XCTAssertEqual(videoCanvas.frame, availabilityOverlay.frame)
        XCTAssertEqual(sourceControls.frame.minY, content.bounds.minY,
                       accuracy: 0.001)
        XCTAssertEqual(canvasHost.frame.minY, sourceControls.frame.maxY,
                       accuracy: 0.001)
        XCTAssertEqual(canvasHost.frame.maxY, content.bounds.maxY,
                       accuracy: 0.001)
        XCTAssertTrue(canvasHost.bounds.contains(videoCanvas.frame))
        XCTAssertEqual(
            canvasHost.layer?.backgroundColor,
            NSColor.black.cgColor
        )
        XCTAssertEqual(sourceControls.frame.height, 52, accuracy: 0.001)
        XCTAssertEqual(
            videoCanvas.frame.width / videoCanvas.frame.height,
            9.0 / 16.0,
            accuracy: 0.001,
            "content=\(content.bounds) video=\(videoCanvas.frame) controls=\(sourceControls.frame)"
        )
        XCTAssertEqual(window.animationBehavior, .none)
        XCTAssertFalse(window.isReleasedWhenClosed)
        XCTAssertFalse(controller.windowShouldClose(window))
        await fulfillment(of: [closed, windowClosed], timeout: 3)
        controller.stopMonitoring()

        XCTAssertNil(window.delegate)
        XCTAssertEqual(
            session.events,
            ["prepare", "attach", "availability", "detach", "close"]
        )
        XCTAssertNil(session.currentAttachment)
    }

    @MainActor
    func testRuntimePreparationOccursBeforeLiveAttachment() async throws {
        let target = try CanonicalUDID(canonicalString: "M2031-GUI-PREPARE-FIRST")
        let attached = expectation(description: "prepared runtime attached")
        let closed = expectation(description: "prepared runtime closed")
        let session = try MockGUIHostRuntimeSession(
            target: target,
            attached: attached,
            closed: closed
        )
        let controller = ProductionGUIHostWindowController(
            catalog: ProductionAVFoundationVideoSourceCatalog(),
            mappingCoordinator: ProductionVideoSourceMappingCoordinator(
                store: InMemoryVideoSourceMappingStore()
            ),
            runtimeSessionFactory: { _ in session },
            toolbarRepositoryRoot: repositoryRoot(),
            presentsWindows: false
        )
        let identifier = try XCTUnwrap(controller.createWindow(for: target))
        await fulfillment(of: [attached], timeout: 3)
        XCTAssertEqual(Array(session.events.prefix(2)), ["prepare", "attach"])

        let window = try XCTUnwrap(NSApplication.shared.windows.first {
            $0.identifier?.rawValue == identifier
        })
        Self.retainedHeadlessWindows.append(window)
        XCTAssertFalse(controller.windowShouldClose(window))
        await fulfillment(of: [closed], timeout: 3)
        controller.stopMonitoring()
    }

    @MainActor
    func testPresentedWindowUsesFixedMoreToolbarAndAdoptedContentWidth() async throws {
        let target = try CanonicalUDID(canonicalString: "M2031-GUI-NATIVE-WIDTH")
        let attached = expectation(description: "runtime attached")
        let closed = expectation(description: "runtime closed")
        let session = try MockGUIHostRuntimeSession(
            target: target,
            attached: attached,
            closed: closed
        )
        let controller = ProductionGUIHostWindowController(
            catalog: ProductionAVFoundationVideoSourceCatalog(),
            mappingCoordinator: ProductionVideoSourceMappingCoordinator(
                store: InMemoryVideoSourceMappingStore()
            ),
            productVersion: try XCTUnwrap(PulsePhoneProductVersion(
                version: "0.1.0",
                build: "1"
            )),
            runtimeSessionFactory: { _ in session },
            toolbarRepositoryRoot: repositoryRoot(),
            presentsWindows: true
        )
        XCTAssertTrue(controller.responds(to: NSSelectorFromString(
            "windowWillResize:toSize:"
        )))
        let identifier = try XCTUnwrap(controller.createWindow(for: target))
        await fulfillment(of: [attached], timeout: 3)
        let window = try XCTUnwrap(NSApplication.shared.windows.first {
            $0.identifier?.rawValue == identifier
        })
        Self.retainedHeadlessWindows.append(window)
        for _ in 0..<100 where window.toolbar == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertTrue(window.isVisible)
        XCTAssertEqual(window.titleVisibility, .hidden)
        let toolbar = try XCTUnwrap(window.toolbar)
        let toolbarIdentifiers = controller.toolbarDefaultItemIdentifiers(toolbar)
        let expectedCommandOrder = [
            "button.home", "button.appSwitcher", "button.lock",
            "button.volumeUp", "button.volumeDown", "button.mute",
            "device.rotate", "screenshot.gui", "gui.keyboardCapture.toggle",
            "gui.softwareKeyboard.toggle", "gui.previewAudioMute.toggle",
            "app.install",
        ]
        let visibleCommandIDs = try toolbarIdentifiers.dropLast(2).map {
            try XCTUnwrap($0.rawValue.split(separator: "::").last).description
        }
        XCTAssertGreaterThanOrEqual(visibleCommandIDs.count, 3)
        XCTAssertLessThanOrEqual(visibleCommandIDs.count, expectedCommandOrder.count)
        XCTAssertEqual(
            visibleCommandIDs,
            Array(expectedCommandOrder.prefix(visibleCommandIDs.count))
        )
        XCTAssertEqual(
            toolbarIdentifiers.suffix(2).map(\.rawValue),
            [
                NSToolbarItem.Identifier.flexibleSpace.rawValue,
                "\(identifier)::gui.more",
            ]
        )
        let primary = try XCTUnwrap(controller.toolbar(
            toolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier(
                "\(identifier)::button.home"
            ),
            willBeInsertedIntoToolbar: true
        ))
        let more = try XCTUnwrap(controller.toolbar(
            toolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier(
                "\(identifier)::gui.more"
            ),
            willBeInsertedIntoToolbar: true
        ))
        XCTAssertEqual(primary.visibilityPriority, .high)
        XCTAssertEqual(more.visibilityPriority, .high)
        let versionLabel = ProductionGUIHostWindowController
            .morePopoverVersionLabel(try XCTUnwrap(PulsePhoneProductVersion(
                version: "0.1.0",
                build: "1"
            )))
        XCTAssertEqual(
            versionLabel.identifier?.rawValue,
            "pulsephone.product-version"
        )
        XCTAssertEqual(versionLabel.stringValue, "PulsePhone 0.1.0 (1)")
        let adoptedWidth = try XCTUnwrap(window.contentView).bounds.width
        XCTAssertGreaterThan(adoptedWidth, 0)
        XCTAssertLessThanOrEqual(adoptedWidth, window.screen?.visibleFrame.width ?? 10_000)

        let content = try XCTUnwrap(window.contentView)
        let canvasHost = try XCTUnwrap(descendant(
            in: content,
            identifier: ProductionGUIHostViewIdentifier.canvasHost
        ))
        let videoCanvas = try XCTUnwrap(descendant(
            in: content,
            identifier: ProductionGUIHostViewIdentifier.videoCanvas
        ))
        let interactionCanvas = try XCTUnwrap(descendant(
            in: content,
            identifier: ProductionGUIHostViewIdentifier.interactionCanvas
        ))
        let availabilityOverlay = try XCTUnwrap(descendant(
            in: content,
            identifier: ProductionGUIHostViewIdentifier.availabilityOverlay
        ))
        let sourceControls = try XCTUnwrap(descendant(
            in: content,
            identifier: ProductionGUIHostViewIdentifier.sourceControls
        ))
        let sourceControlsStack = try XCTUnwrap(
            sourceControls.subviews.first as? NSStackView
        )
        let sourceSummary = try XCTUnwrap(
            sourceControlsStack.arrangedSubviews.first {
                $0.identifier == ProductionGUIHostViewIdentifier.sourceSummary
            } as? NSTextField
        )
        let statusLabel = try XCTUnwrap(
            sourceControlsStack.arrangedSubviews.first {
                $0 is NSTextField
                    && $0.identifier != ProductionGUIHostViewIdentifier.sourceSummary
            } as? NSTextField
        )
        sourceSummary.stringValue = String(repeating: "source-", count: 12)
        statusLabel.stringValue = String(repeating: "status-", count: 12)
        statusLabel.isHidden = false

        try controller.applyRuntimeGeometry(
            DisplayGeometryDTO(
                connectionEpoch: 7,
                geometryRevision: 1,
                logicalHeight: 2_532,
                logicalWidth: 1_170,
                orientation: .portrait
            ),
            toWindow: identifier
        )
        try await waitForExactCanvas(
            canvasHost: canvasHost,
            videoCanvas: videoCanvas,
            interactionCanvas: interactionCanvas,
            ratio: 1_170.0 / 2_532.0
        )
        XCTAssertGreaterThanOrEqual(
            window.contentMinSize.width,
            LiveWindowReservation.minimumCanvasShortEdge - 0.5
        )
        XCTAssertEqual(availabilityOverlay.frame, videoCanvas.frame)
        try await waitUntil {
            window.contentView?.layoutSubtreeIfNeeded()
            return (window.contentView?.bounds.width ?? .greatestFiniteMagnitude)
                <= LiveWindowReservation.preferredCanvasShortEdge + 0.5
        }
        XCTAssertLessThan(window.contentView?.bounds.width ?? .greatestFiniteMagnitude, 396)
        let compactDiagnostic = compactWindowDiagnostic(
            window: window,
            canvasHost: canvasHost,
            toolbar: toolbar
        )
        XCTAssertLessThanOrEqual(
            window.contentView?.bounds.width ?? .greatestFiniteMagnitude,
            LiveWindowReservation.preferredCanvasShortEdge + 0.5,
            compactDiagnostic
        )
        XCTAssertNotEqual(statusLabel.stringValue, "Window geometry unavailable")
        try await exerciseWindowResizeCallbacks(
            controller: controller,
            window: window,
            sourceControlsHeight: sourceControls.bounds.height,
            ratio: 1_170.0 / 2_532.0,
            canvasHost: canvasHost,
            videoCanvas: videoCanvas,
            interactionCanvas: interactionCanvas
        )
        XCTAssertEqual(availabilityOverlay.frame, videoCanvas.frame)

        try controller.applyRuntimeGeometry(
            DisplayGeometryDTO(
                connectionEpoch: 7,
                geometryRevision: 2,
                logicalHeight: 1_170,
                logicalWidth: 2_532,
                orientation: .landscapeRight
            ),
            toWindow: identifier
        )
        try await waitForExactCanvas(
            canvasHost: canvasHost,
            videoCanvas: videoCanvas,
            interactionCanvas: interactionCanvas,
            ratio: 2_532.0 / 1_170.0
        )
        XCTAssertGreaterThanOrEqual(
            window.contentMinSize.height - sourceControls.bounds.height,
            LiveWindowReservation.minimumCanvasShortEdge - 0.5
        )
        try await exerciseWindowResizeCallbacks(
            controller: controller,
            window: window,
            sourceControlsHeight: sourceControls.bounds.height,
            ratio: 2_532.0 / 1_170.0,
            canvasHost: canvasHost,
            videoCanvas: videoCanvas,
            interactionCanvas: interactionCanvas
        )

        try controller.applyRuntimeGeometry(
            DisplayGeometryDTO(
                connectionEpoch: 7,
                geometryRevision: 3,
                logicalHeight: 2_532,
                logicalWidth: 1_170,
                orientation: .portrait
            ),
            toWindow: identifier
        )
        try await waitForExactCanvas(
            canvasHost: canvasHost,
            videoCanvas: videoCanvas,
            interactionCanvas: interactionCanvas,
            ratio: 1_170.0 / 2_532.0
        )
        XCTAssertLessThan(
            window.contentView?.bounds.width ?? .greatestFiniteMagnitude,
            396
        )
        XCTAssertNotEqual(statusLabel.stringValue, "Window geometry unavailable")

        XCTAssertFalse(controller.windowShouldClose(window))
        await fulfillment(of: [closed], timeout: 3)
        controller.stopMonitoring()
    }

    @MainActor
    func testCanvasHostAspectFitsPortraitAndLandscapeInWideContainer() {
        let bounds = NSRect(x: 0, y: 0, width: 600, height: 720)
        let portrait = ProductionGUIHostCanvasHost.aspectFitRect(
            aspectRatio: 1_170.0 / 2_532.0,
            in: bounds
        )
        XCTAssertEqual(portrait.height, bounds.height, accuracy: 0.001)
        XCTAssertEqual(
            portrait.width / portrait.height,
            1_170.0 / 2_532.0,
            accuracy: 0.001
        )
        XCTAssertEqual(portrait.midX, bounds.midX, accuracy: 0.001)

        let landscape = ProductionGUIHostCanvasHost.aspectFitRect(
            aspectRatio: 2_532.0 / 1_170.0,
            in: bounds
        )
        XCTAssertEqual(landscape.width, bounds.width, accuracy: 0.001)
        XCTAssertEqual(
            landscape.width / landscape.height,
            2_532.0 / 1_170.0,
            accuracy: 0.001
        )
        XCTAssertEqual(landscape.midY, bounds.midY, accuracy: 0.001)
    }

    @MainActor
    func testWindowRetriesTransientRuntimeAvailabilityFailure() async throws {
        let target = try CanonicalUDID(canonicalString: "M2031-GUI-RETRY")
        let firstAttached = expectation(description: "first runtime attached")
        let firstClosed = expectation(description: "failed runtime closed")
        let secondAttached = expectation(description: "retry runtime attached")
        let secondClosed = expectation(description: "retry runtime closed")
        let windowClosed = expectation(description: "retry window released")
        let first = try MockGUIHostRuntimeSession(
            target: target,
            attached: firstAttached,
            closed: firstClosed,
            failsAvailability: true
        )
        let second = try MockGUIHostRuntimeSession(
            target: target,
            attached: secondAttached,
            closed: secondClosed
        )
        let sessions = MockGUIHostRuntimeSessionFactory(sessions: [first, second])
        let controller = ProductionGUIHostWindowController(
            catalog: ProductionAVFoundationVideoSourceCatalog(),
            mappingCoordinator: ProductionVideoSourceMappingCoordinator(
                store: InMemoryVideoSourceMappingStore()
            ),
            runtimeSessionFactory: { requested in
                XCTAssertEqual(requested, target)
                return try sessions.next()
            },
            runtimeRetryDelaysNanoseconds: [1_000_000],
            presentsWindows: false
        )
        controller.setWindowClosedHandler { requested, _ in
            XCTAssertEqual(requested, target)
            windowClosed.fulfill()
        }
        let identifier = try XCTUnwrap(controller.createWindow(for: target))
        await fulfillment(
            of: [firstAttached, firstClosed, secondAttached],
            timeout: 3
        )

        XCTAssertEqual(
            first.events,
            ["prepare", "attach", "availability", "detach", "close"]
        )
        XCTAssertEqual(second.events, ["prepare", "attach", "availability"])
        let window = try XCTUnwrap(NSApplication.shared.windows.first {
            $0.identifier?.rawValue == identifier
        })
        Self.retainedHeadlessWindows.append(window)
        XCTAssertFalse(controller.windowShouldClose(window))
        await fulfillment(of: [secondClosed, windowClosed], timeout: 3)
        controller.stopMonitoring()

        XCTAssertNil(window.delegate)
        XCTAssertEqual(
            second.events,
            ["prepare", "attach", "availability", "detach", "close"]
        )
        XCTAssertNil(second.currentAttachment)
    }

    @MainActor
    func testRealSocketHelloAndOpenLive() throws {
        let target = try CanonicalUDID(canonicalString: "M2031-GUI")
        let system = POSIXHostPathSystem()
        let appPath = try CanonicalAppPath(
            canonicalBundlePath: "/Applications/PulsePhone.app"
        )
        let hostPaths = try system.makeHostPathLayout()
        let endpoint = try GUIHostEndpoint(
            canonicalAppPath: appPath,
            hostPaths: hostPaths
        )
        let server = try ProductionGUIHostServer(
            canonicalAppPath: appPath,
            hostPaths: hostPaths,
            windowCreator: { target in "test-appkit-\(target.rawValue)" }
        )
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            defer { stopped.signal() }
            try? server.run()
        }
        defer {
            server.requestStop()
            XCTAssertEqual(stopped.wait(timeout: .now() + 3), .success)
        }
        try waitForNode(endpoint.socketPath)
        XCTAssertThrowsError(try ProductionGUIHostServer(
            canonicalAppPath: appPath,
            hostPaths: hostPaths
        ).run())
        let launcher = try LiveLauncher(
            canonicalAppPath: appPath,
            hostPaths: hostPaths,
            launcherBuildID: "launcher.test",
            launcherInstanceID: CanonicalUUID(value: UUID()),
            transport: ProductionGUIHostTransport(canonicalAppPath: appPath)
        )
        let result = try launcher.openLive(
            canonicalUDID: target,
            requestID: CanonicalUUID(value: UUID()),
            startedAtNanoseconds: SystemMonotonicClock().now().nanoseconds
        )
        XCTAssertEqual(result.disposition, .opened)
        XCTAssertEqual(result.canonicalUDID, target)
        XCTAssertEqual(result.windowID, "test-appkit-\(target.rawValue)")
    }

    @MainActor
    func testVideoSourceMappingCoordinatorLoadsReplacesAndClearsPerTarget() async throws {
        let store = InMemoryVideoSourceMappingStore()
        let coordinator = ProductionVideoSourceMappingCoordinator(store: store)
        let first = try CanonicalUDID(canonicalString: "M2031-MAPPING-A")
        let second = try CanonicalUDID(canonicalString: "M2031-MAPPING-B")
        let firstSource = String(repeating: "a", count: 64)
        let secondSource = String(repeating: "b", count: 64)

        let savedFirst = expectation(description: "saved first mapping")
        coordinator.replace(target: first, sourceID: firstSource) { result in
            guard case .saved(let record) = result else {
                return XCTFail("expected saved mapping")
            }
            XCTAssertEqual(record.sourceID, firstSource)
            savedFirst.fulfill()
        }
        await fulfillment(of: [savedFirst], timeout: 2)

        let loadedTargets = expectation(description: "loaded isolated targets")
        loadedTargets.expectedFulfillmentCount = 2
        coordinator.load(target: first) { result in
            guard case .mapped(let record) = result else {
                return XCTFail("expected first mapping")
            }
            XCTAssertEqual(record.sourceID, firstSource)
            loadedTargets.fulfill()
        }
        coordinator.load(target: second) { result in
            XCTAssertEqual(result, .missing)
            loadedTargets.fulfill()
        }
        await fulfillment(of: [loadedTargets], timeout: 2)

        let savedSecond = expectation(description: "saved second mapping")
        coordinator.replace(target: second, sourceID: secondSource) { result in
            guard case .saved(let record) = result else {
                return XCTFail("expected second mapping")
            }
            XCTAssertEqual(record.sourceID, secondSource)
            savedSecond.fulfill()
        }
        await fulfillment(of: [savedSecond], timeout: 2)

        let cleared = expectation(description: "cleared first mapping")
        coordinator.clear(target: first) { result in
            XCTAssertEqual(result, .cleared(true))
            cleared.fulfill()
        }
        await fulfillment(of: [cleared], timeout: 2)
        XCTAssertEqual(store.load(target: first), .missing)
        guard case .mapped(let retained) = store.load(target: second) else {
            return XCTFail("second target mapping must remain")
        }
        XCTAssertEqual(retained.sourceID, secondSource)
    }

    @MainActor
    func testVideoSourceReassignmentChecksConflictsBeforeFenceAndMutation() async throws {
        let store = InMemoryVideoSourceMappingStore()
        let coordinator = ProductionVideoSourceMappingCoordinator(store: store)
        let current = try CanonicalUDID(canonicalString: "M2031-REASSIGN-A")
        let other = try CanonicalUDID(canonicalString: "M2031-REASSIGN-B")
        let sourceID = String(repeating: "c", count: 64)
        _ = try store.replace(target: other, sourceID: sourceID)

        let saved = expectation(description: "reassigned source")
        var fenced = [CanonicalUDID]()
        coordinator.reassign(
            target: current,
            sourceID: sourceID,
            proofKind: .operatorConfirmedPreview,
            connectedTargets: [current, other],
            expectedConflictingTargets: [other],
            fence: { targets in fenced = targets }
        ) { result in
            guard case .saved(let record) = result else {
                return XCTFail("expected reassignment")
            }
            XCTAssertEqual(record.sourceID, sourceID)
            saved.fulfill()
        }
        await fulfillment(of: [saved], timeout: 2)
        XCTAssertEqual(fenced, [other])
        XCTAssertEqual(store.load(target: other), .missing)
        guard case .mapped(let reassigned) = store.load(target: current) else {
            return XCTFail("current target must own source")
        }
        XCTAssertEqual(reassigned.sourceID, sourceID)

        _ = try store.replace(target: other, sourceID: sourceID)
        let changed = expectation(description: "conflict changed")
        var unexpectedFence = false
        coordinator.reassign(
            target: current,
            sourceID: sourceID,
            proofKind: .operatorConfirmedPreview,
            connectedTargets: [current, other],
            expectedConflictingTargets: [],
            fence: { _ in unexpectedFence = true }
        ) { result in
            XCTAssertEqual(result, .conflictChanged)
            changed.fulfill()
        }
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertFalse(unexpectedFence)
    }

    @MainActor
    func testForceChooserDoesNotStartRuntimeBeforeHandoff() async throws {
        let target = try CanonicalUDID(canonicalString: "M2031-CHOOSER-NO-RUNTIME")
        let counter = LockedCallCounter()
        let facts = ProductionLiveSourceTargetFacts(
            canonicalUDID: target,
            name: "Test iPhone",
            osVersion: "26.5"
        )
        let controller = ProductionGUIHostWindowController(
            catalog: ProductionAVFoundationVideoSourceCatalog(),
            mappingCoordinator: ProductionVideoSourceMappingCoordinator(
                store: InMemoryVideoSourceMappingStore()
            ),
            productVersion: try XCTUnwrap(PulsePhoneProductVersion(
                version: "0.1.0",
                build: "1"
            )),
            runtimeSessionFactory: { _ in
                counter.increment()
                throw GUIHostTransportError.invalidFrame
            },
            sourceTargetSnapshotProvider: { _ in
                ProductionLiveSourceTargetSnapshot(
                    connectedTargets: [facts],
                    target: facts
                )
            },
            presentsWindows: false
        )
        let released = expectation(description: "chooser reservation released")
        controller.setWindowClosedHandler { closedTarget, _ in
            XCTAssertEqual(closedTarget, target)
            released.fulfill()
        }
        let ownerID = try XCTUnwrap(controller.openOwner(
            for: target,
            policy: .forceChooser
        ))
        let chooser = try XCTUnwrap(NSApplication.shared.windows.first {
            $0.identifier?.rawValue == ownerID
        })
        XCTAssertEqual(chooser.title, "选择视频源")
        XCTAssertEqual(chooser.subtitle, "PulsePhone 0.1.0 (1)")
        XCTAssertEqual(counter.value, 0)
        chooser.close()
        await fulfillment(of: [released], timeout: 2)
        XCTAssertEqual(counter.value, 0)
        controller.stopMonitoring()
    }

    func testSpawnedGUIHostEntrypointServesOpenAndClosesTransportOnExit() throws {
        let appPath = try makeTemporaryApp()
        defer { try? FileManager.default.removeItem(atPath: appPath.bundlePath) }
        let executable = appPath.bundlePath + "/Contents/MacOS/PulsePhone"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = [GUIHostProcessEntrypoint.roleArgument]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        let hostPaths = try POSIXHostPathSystem().makeHostPathLayout()
        let endpoint = try GUIHostEndpoint(
            canonicalAppPath: appPath,
            hostPaths: hostPaths
        )
        defer {
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
            _ = unlink(endpoint.socketPath)
            _ = unlink(endpoint.socketPath + ".lock")
        }
        try waitForNode(endpoint.socketPath)
        let transport = ProductionGUIHostTransport(canonicalAppPath: appPath)
        let launcher = try LiveLauncher(
            canonicalAppPath: appPath,
            hostPaths: hostPaths,
            launcherBuildID: "launcher.process-test",
            launcherInstanceID: CanonicalUUID(value: UUID()),
            transport: transport
        )
        let target = try CanonicalUDID(canonicalString: "M2031-GUI-PROCESS")
        let opened = try launcher.openLive(
            canonicalUDID: target,
            requestID: CanonicalUUID(value: UUID()),
            startedAtNanoseconds: SystemMonotonicClock().now().nanoseconds
        )
        XCTAssertEqual(opened.disposition, .opened)
        XCTAssertEqual(opened.canonicalUDID, target)
        XCTAssertTrue(opened.windowID?.hasPrefix("appkit-") == true)
        XCTAssertFalse(opened.windowID?.hasPrefix("window-") == true)

        _ = Darwin.kill(process.processIdentifier, SIGTERM)
        process.waitUntilExit()
        XCTAssertThrowsError(try transport.openLive(GUIHostOpenLiveRequest(
            requestID: CanonicalUUID(value: UUID()),
            canonicalUDID: try CanonicalUDID(canonicalString: "M2031-GUI-EOF")
        )))
    }

    @MainActor
    func testProductionKeyboardCaptureUsesEventTapAndClosesShortInteractions()
        async throws
    {
        let target = try CanonicalUDID(canonicalString: "M2031-GUI-KEYBOARD")
        let attached = expectation(description: "keyboard runtime attached")
        let closed = expectation(description: "keyboard runtime closed")
        let session = try MockGUIHostRuntimeSession(
            target: target,
            attached: attached,
            closed: closed,
            supportsKeyboardStreams: true
        )
        let eventTap = MockKeyboardEventTap(status: .authorized)
        let focus = MockWindowFocus(isKey: true)
        let controller = ProductionGUIHostWindowController(
            catalog: ProductionAVFoundationVideoSourceCatalog(),
            keyboardEventTap: eventTap,
            mappingCoordinator: ProductionVideoSourceMappingCoordinator(
                store: InMemoryVideoSourceMappingStore()
            ),
            runtimeSessionFactory: { _ in session },
            toolbarRepositoryRoot: repositoryRoot(),
            presentsWindows: false,
            applicationIsActive: { true },
            windowIsKey: { _ in focus.isKey }
        )
        let identifier = try XCTUnwrap(controller.createWindow(for: target))
        await fulfillment(of: [attached], timeout: 3)
        let window = try XCTUnwrap(NSApplication.shared.windows.first {
            $0.identifier?.rawValue == identifier
        })
        Self.retainedHeadlessWindows.append(window)
        window.makeKey()
        let interaction = try XCTUnwrap(descendant(
            in: try XCTUnwrap(window.contentView),
            identifier: ProductionGUIHostViewIdentifier.interactionCanvas
        ))
        XCTAssertTrue(window.makeFirstResponder(interaction))
        let button = try await keyboardButton(
            controller: controller,
            window: window,
            identifier: identifier
        )
        button.performClick(nil)
        XCTAssertTrue(window.makeFirstResponder(button))
        try await waitUntil {
            window.firstResponder === interaction && eventTap.isCaptureActive
        }
        XCTAssertEqual(button.state, .on)
        XCTAssertEqual(button.toolTip, "Keyboard Capture active")

        eventTap.emit(.event(capturedKey(.keyDown, usage: 4, pressed: true)))
        eventTap.emit(.event(capturedKey(.keyUp, usage: 4, pressed: false)))
        try await waitUntil {
            session.events.contains("keyboard.close.1")
        }
        XCTAssertTrue(session.events.contains("keyboard.frame.0.1"))
        XCTAssertTrue(session.events.contains("keyboard.frame.1.0"))
        XCTAssertEqual(session.ownedStreamCount, 0)
        XCTAssertTrue(eventTap.isCaptureActive)
        XCTAssertEqual(button.state, .on, "enabled preference survives short close")

        eventTap.emit(.event(capturedKey(.keyDown, usage: 5, pressed: true)))
        eventTap.emit(.event(capturedKey(.keyUp, usage: 5, pressed: false)))
        try await waitUntil {
            session.events.filter { $0 == "keyboard.close.1" }.count == 2
        }
        XCTAssertEqual(
            session.events.filter { $0 == "keyboard.frame.0.1" }.count,
            2,
            "each short interaction restarts sequence at zero"
        )

        eventTap.emit(.event(capturedKey(.keyDown, usage: 6, pressed: true)))
        try await waitUntil {
            session.events.filter { $0 == "keyboard.open" }.count == 3
        }
        focus.setKey(false)
        controller.windowDidResignKey(Notification(
            name: NSWindow.didResignKeyNotification,
            object: window
        ))
        try await waitUntil {
            session.events.contains("keyboard.cancel.focusLost")
        }
        XCTAssertFalse(eventTap.isCaptureActive)
        XCTAssertEqual(button.state, .on)
        XCTAssertEqual(button.contentTintColor, .systemOrange)

        focus.setKey(true)
        XCTAssertTrue(window.makeFirstResponder(interaction))
        controller.windowDidBecomeKey(Notification(
            name: NSWindow.didBecomeKeyNotification,
            object: window
        ))
        try await waitUntil { eventTap.isCaptureActive }
        eventTap.emit(.event(capturedKey(.keyDown, usage: 7, pressed: true)))
        try await waitUntil {
            session.events.filter { $0 == "keyboard.open" }.count == 4
        }
        eventTap.emit(.disabled)
        try await waitUntil {
            session.events.contains("keyboard.cancel.eventTapDisabled")
        }
        XCTAssertFalse(eventTap.isCaptureActive)
        XCTAssertEqual(
            button.toolTip,
            "Keyboard Capture unavailable: Event Tap disabled"
        )

        button.performClick(nil)
        button.performClick(nil)
        try await waitUntil { eventTap.isCaptureActive }
        session.failNextKeyboardFrame()
        eventTap.emit(.event(capturedKey(.keyDown, usage: 8, pressed: true)))
        try await waitUntil {
            session.events.contains("keyboard.frame.failure")
                && session.events.contains("keyboard.cancel.transportFailure")
        }
        try await waitUntil { eventTap.isCaptureActive }
        XCTAssertEqual(session.ownedStreamCount, 0)

        XCTAssertFalse(controller.windowShouldClose(window))
        await fulfillment(of: [closed], timeout: 3)
        controller.stopMonitoring()
    }

    @MainActor
    func testKeyboardCaptureIsDisabledWhenRuntimeKeyboardCapabilityIsUnavailable()
        async throws
    {
        let target = try CanonicalUDID(canonicalString: "M2031-GUI-KEYBOARD-UNAVAILABLE")
        let attached = expectation(description: "keyboard-unavailable runtime attached")
        let closed = expectation(description: "keyboard-unavailable runtime closed")
        let session = try MockGUIHostRuntimeSession(
            target: target,
            attached: attached,
            closed: closed,
            keyboardCapabilityAvailable: false
        )
        let controller = ProductionGUIHostWindowController(
            catalog: ProductionAVFoundationVideoSourceCatalog(),
            mappingCoordinator: ProductionVideoSourceMappingCoordinator(
                store: InMemoryVideoSourceMappingStore()
            ),
            runtimeSessionFactory: { _ in session },
            toolbarRepositoryRoot: repositoryRoot(),
            presentsWindows: false
        )
        let identifier = try XCTUnwrap(controller.createWindow(for: target))
        await fulfillment(of: [attached], timeout: 3)
        let window = try XCTUnwrap(NSApplication.shared.windows.first {
            $0.identifier?.rawValue == identifier
        })
        Self.retainedHeadlessWindows.append(window)
        let toolbar = try await expandedToolbar(in: window)

        func button(_ commandID: String) throws -> NSButton {
            let item = try XCTUnwrap(controller.toolbar(
                toolbar,
                itemForItemIdentifier: NSToolbarItem.Identifier(
                    "\(identifier)::\(commandID)"
                ),
                willBeInsertedIntoToolbar: true
            ))
            return try XCTUnwrap(item.view as? NSButton)
        }

        let keyboard = try button("gui.keyboardCapture.toggle")
        XCTAssertFalse(keyboard.isEnabled)
        XCTAssertEqual(
            keyboard.toolTip,
            "Keyboard Capture unavailable: device keyboard not ready"
        )
        XCTAssertFalse(
            controller.toolbar(
                toolbar,
                itemForItemIdentifier: NSToolbarItem.Identifier(
                    "\(identifier)::gui.keyboardCapture.toggle"
                ),
                willBeInsertedIntoToolbar: true
            )?.menuFormRepresentation?.isEnabled ?? true
        )
        XCTAssertTrue(try button("screenshot.gui").isEnabled)
        XCTAssertTrue(try button("gui.previewAudioMute.toggle").isEnabled)
        XCTAssertTrue(try button("app.install").isEnabled)

        XCTAssertFalse(controller.windowShouldClose(window))
        await fulfillment(of: [closed], timeout: 3)
        controller.stopMonitoring()
    }

    @MainActor
    func testProductionKeyboardCaptureProjectsInputMonitoringStates() async throws {
        let target = try CanonicalUDID(canonicalString: "M2031-GUI-KEYBOARD-TCC")
        let attached = expectation(description: "TCC runtime attached")
        let closed = expectation(description: "TCC runtime closed")
        let session = try MockGUIHostRuntimeSession(
            target: target,
            attached: attached,
            closed: closed,
            supportsKeyboardStreams: true
        )
        let eventTap = MockKeyboardEventTap(status: .notDetermined)
        let focus = MockWindowFocus(isKey: true)
        let controller = ProductionGUIHostWindowController(
            catalog: ProductionAVFoundationVideoSourceCatalog(),
            keyboardEventTap: eventTap,
            mappingCoordinator: ProductionVideoSourceMappingCoordinator(
                store: InMemoryVideoSourceMappingStore()
            ),
            runtimeSessionFactory: { _ in session },
            toolbarRepositoryRoot: repositoryRoot(),
            presentsWindows: false,
            applicationIsActive: { true },
            windowIsKey: { _ in focus.isKey }
        )
        let identifier = try XCTUnwrap(controller.createWindow(for: target))
        await fulfillment(of: [attached], timeout: 3)
        let window = try XCTUnwrap(NSApplication.shared.windows.first {
            $0.identifier?.rawValue == identifier
        })
        Self.retainedHeadlessWindows.append(window)
        window.makeKey()
        let interaction = try XCTUnwrap(descendant(
            in: try XCTUnwrap(window.contentView),
            identifier: ProductionGUIHostViewIdentifier.interactionCanvas
        ))
        XCTAssertTrue(window.makeFirstResponder(interaction))
        let button = try await keyboardButton(
            controller: controller,
            window: window,
            identifier: identifier
        )
        button.performClick(nil)
        XCTAssertEqual(button.state, .on)
        XCTAssertEqual(button.contentTintColor, .systemOrange)
        XCTAssertEqual(
            button.toolTip,
            "Keyboard Capture unavailable: Input Monitoring required"
        )
        XCTAssertFalse(eventTap.isCaptureActive)

        eventTap.setAuthorizationStatus(.restricted)
        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification,
            object: NSApplication.shared
        )
        try await waitUntil {
            button.toolTip ==
                "Keyboard Capture unavailable: Input Monitoring restricted"
        }
        eventTap.setAuthorizationStatus(.denied)
        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification,
            object: NSApplication.shared
        )
        try await waitUntil {
            button.toolTip ==
                "Keyboard Capture unavailable: Input Monitoring denied"
        }
        eventTap.setAuthorizationStatus(.authorized)
        NotificationCenter.default.post(
            name: NSApplication.didBecomeActiveNotification,
            object: NSApplication.shared
        )
        try await waitUntil { eventTap.isCaptureActive }
        XCTAssertEqual(button.contentTintColor, .controlAccentColor)
        XCTAssertEqual(button.toolTip, "Keyboard Capture active")

        XCTAssertFalse(controller.windowShouldClose(window))
        await fulfillment(of: [closed], timeout: 3)
        controller.stopMonitoring()
    }

    @MainActor
    private func keyboardButton(
        controller: ProductionGUIHostWindowController,
        window: NSWindow,
        identifier: String
    ) async throws -> NSButton {
        let toolbar = try await expandedToolbar(in: window)
        let item = try XCTUnwrap(controller.toolbar(
            toolbar,
            itemForItemIdentifier: NSToolbarItem.Identifier(
                "\(identifier)::gui.keyboardCapture.toggle"
            ),
            willBeInsertedIntoToolbar: true
        ))
        return try XCTUnwrap(item.view as? NSButton)
    }

    @MainActor
    private func expandedToolbar(in window: NSWindow) async throws -> NSToolbar {
        for _ in 0..<100 where window.toolbar == nil {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let toolbar = try XCTUnwrap(window.toolbar)
        var frame = window.frame
        frame.size.width = max(frame.width, 720)
        window.setFrame(frame, display: false)
        return toolbar
    }

    private func capturedKey(
        _ kind: KeyboardCaptureEventKind,
        usage: UInt16,
        pressed: Bool
    ) -> ProductionKeyboardCapturedEvent {
        ProductionKeyboardCapturedEvent(
            isPressed: pressed,
            key: KeyboardCapturedKey(usagePage: 0x07, usage: usage),
            kind: kind
        )
    }

    @MainActor
    private func waitUntil(
        timeoutIterations: Int = 300,
        condition: @escaping () -> Bool
    ) async throws {
        for _ in 0..<timeoutIterations {
            if condition() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("condition did not become true")
    }

    @MainActor
    private func compactWindowDiagnostic(
        window: NSWindow,
        canvasHost: NSView,
        toolbar: NSToolbar
    ) -> String {
        let visibleItems = toolbar.visibleItems?.map(\.itemIdentifier.rawValue)
            .joined(separator: ",") ?? "none"
        return "screen=\(window.screen?.visibleFrame ?? .zero) "
            + "main=\(NSScreen.main?.visibleFrame ?? .zero) "
            + "frame=\(window.frame) "
            + "content=\(window.contentView?.bounds ?? .zero) "
            + "contentLayout=\(window.contentLayoutRect) "
            + "canvas=\(canvasHost.bounds) "
            + "contentMin=\(window.contentMinSize) "
            + "visibleToolbarItems=\(visibleItems)"
    }

    private func waitForNode(_ path: String) throws {
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: path) { return }
            usleep(10_000)
        }
        throw POSIXError(.ETIMEDOUT)
    }

    @MainActor
    private func waitForExactCanvas(
        canvasHost: NSView,
        videoCanvas: NSView,
        interactionCanvas: NSView,
        ratio: CGFloat
    ) async throws {
        try await waitUntil {
            canvasHost.window?.contentView?.layoutSubtreeIfNeeded()
            canvasHost.layoutSubtreeIfNeeded()
            return self.canvasIsExact(
                canvasHost: canvasHost,
                videoCanvas: videoCanvas,
                interactionCanvas: interactionCanvas,
                ratio: ratio
            )
        }
    }

    @MainActor
    private func exerciseWindowResizeCallbacks(
        controller: ProductionGUIHostWindowController,
        window: NSWindow,
        sourceControlsHeight: CGFloat,
        ratio: CGFloat,
        canvasHost: NSView,
        videoCanvas: NSView,
        interactionCanvas: NSView
    ) async throws {
        let base = window.frame.size
        let candidates = [
            NSSize(width: base.width + 120, height: base.height),
            NSSize(width: max(240, base.width - 80), height: base.height),
            NSSize(width: base.width, height: base.height + 120),
            NSSize(width: base.width, height: max(240, base.height - 80)),
            NSSize(width: base.width + 100, height: base.height + 60),
            NSSize(width: max(240, base.width - 60), height: base.height + 100),
            NSSize(width: base.width + 80, height: max(240, base.height - 60)),
            NSSize(width: max(240, base.width - 80), height: max(240, base.height - 80)),
        ]
        for (index, candidate) in candidates.enumerated() {
            let referenceFrame = window.frame
            let constrained = controller.windowWillResize(window, to: candidate)
            let contentSize = window.contentRect(forFrameRect: NSRect(
                origin: .zero,
                size: constrained
            )).size
            let canvasHeight = contentSize.height - sourceControlsHeight
            XCTAssertGreaterThan(canvasHeight, 0)
            XCTAssertGreaterThanOrEqual(
                min(contentSize.width, canvasHeight),
                LiveWindowReservation.minimumCanvasShortEdge - 0.5
            )
            XCTAssertLessThanOrEqual(
                abs(contentSize.width - canvasHeight * ratio),
                0.5
            )
            let adoptsWidth = index.isMultiple(of: 2)
            var partialFrame = referenceFrame
            if adoptsWidth {
                partialFrame.size.width = constrained.width
                if index.isMultiple(of: 4) == false {
                    partialFrame.origin.x = referenceFrame.maxX - constrained.width
                }
            } else {
                partialFrame.size.height = constrained.height
                if index.isMultiple(of: 4) == false {
                    partialFrame.origin.y = referenceFrame.maxY - constrained.height
                }
            }
            window.delegate = nil
            window.setFrame(
                NSRect(origin: referenceFrame.origin, size: constrained),
                display: false
            )
            window.delegate = controller
            controller.windowDidResize(Notification(
                name: NSWindow.didResizeNotification,
                object: window
            ))
            window.delegate = nil
            window.setFrame(partialFrame, display: false)
            window.delegate = controller
            controller.windowDidResize(Notification(
                name: NSWindow.didResizeNotification,
                object: window
            ))
            window.contentView?.layoutSubtreeIfNeeded()
            canvasHost.layoutSubtreeIfNeeded()
            XCTAssertEqual(window.frame.width, constrained.width, accuracy: 0.5)
            XCTAssertEqual(window.frame.height, constrained.height, accuracy: 0.5)
            XCTAssertTrue(canvasIsExact(
                canvasHost: canvasHost,
                videoCanvas: videoCanvas,
                interactionCanvas: interactionCanvas,
                ratio: ratio
            ))
            try await waitUntil {
                window.contentView?.layoutSubtreeIfNeeded()
                canvasHost.layoutSubtreeIfNeeded()
                return abs(window.frame.width - constrained.width) <= 0.5
                    && abs(window.frame.height - constrained.height) <= 0.5
                    && self.canvasIsExact(
                        canvasHost: canvasHost,
                        videoCanvas: videoCanvas,
                        interactionCanvas: interactionCanvas,
                        ratio: ratio
                    )
            }
            let diagnostic = "candidate=\(candidate) constrained=\(constrained) "
                + "partial=\(partialFrame) "
                + "frame=\(window.frame.size) "
                + "content=\(window.contentView?.bounds.size ?? .zero) "
                + "canvas=\(canvasHost.bounds) video=\(videoCanvas.frame) "
                + "interaction=\(interactionCanvas.frame) ratio=\(ratio)"
            XCTAssertEqual(window.frame.width, constrained.width, accuracy: 0.5, diagnostic)
            XCTAssertEqual(window.frame.height, constrained.height, accuracy: 0.5, diagnostic)
            XCTAssertTrue(canvasIsExact(
                canvasHost: canvasHost,
                videoCanvas: videoCanvas,
                interactionCanvas: interactionCanvas,
                ratio: ratio
            ), diagnostic)
        }
        try await exerciseLateLiveResizeEndSettlement(
            controller: controller,
            window: window,
            ratio: ratio,
            canvasHost: canvasHost,
            videoCanvas: videoCanvas,
            interactionCanvas: interactionCanvas
        )
        try await exerciseMissingResizeCallbackSettlement(
            controller: controller,
            window: window,
            ratio: ratio,
            canvasHost: canvasHost,
            videoCanvas: videoCanvas,
            interactionCanvas: interactionCanvas
        )
    }

    @MainActor
    private func exerciseLateLiveResizeEndSettlement(
        controller: ProductionGUIHostWindowController,
        window: NSWindow,
        ratio: CGFloat,
        canvasHost: NSView,
        videoCanvas: NSView,
        interactionCanvas: NSView
    ) async throws {
        let referenceFrame = window.frame
        let candidate = NSSize(
            width: referenceFrame.width + 44,
            height: referenceFrame.height
        )
        controller.windowWillStartLiveResize(Notification(
            name: NSWindow.willStartLiveResizeNotification,
            object: window
        ))
        let constrained = controller.windowWillResize(
            window,
            to: candidate
        )
        window.delegate = nil
        window.setFrame(
            NSRect(origin: referenceFrame.origin, size: constrained),
            display: false
        )
        window.delegate = controller
        controller.windowDidResize(Notification(
            name: NSWindow.didResizeNotification,
            object: window
        ))
        controller.windowDidEndLiveResize(Notification(
            name: NSWindow.didEndLiveResizeNotification,
            object: window
        ))

        let partialFrame = NSRect(
            origin: referenceFrame.origin,
            size: NSSize(
                width: constrained.width,
                height: referenceFrame.height
            )
        )
        try await Task.sleep(nanoseconds: 80_000_000)
        window.delegate = nil
        window.setFrame(partialFrame, display: false)
        window.delegate = controller
        try await Task.sleep(nanoseconds: 620_000_000)
        window.contentView?.layoutSubtreeIfNeeded()
        canvasHost.layoutSubtreeIfNeeded()
        let diagnostic = "late-partial=\(partialFrame) constrained=\(constrained) "
            + "frame=\(window.frame) canvas=\(canvasHost.bounds)"
        XCTAssertEqual(window.frame.width, constrained.width, accuracy: 0.5, diagnostic)
        XCTAssertEqual(window.frame.height, constrained.height, accuracy: 0.5, diagnostic)
        XCTAssertTrue(canvasIsExact(
            canvasHost: canvasHost,
            videoCanvas: videoCanvas,
            interactionCanvas: interactionCanvas,
            ratio: ratio
        ), diagnostic)
    }

    @MainActor
    private func exerciseMissingResizeCallbackSettlement(
        controller: ProductionGUIHostWindowController,
        window: NSWindow,
        ratio: CGFloat,
        canvasHost: NSView,
        videoCanvas: NSView,
        interactionCanvas: NSView
    ) async throws {
        let referenceFrame = window.frame
        let partialFrame = NSRect(
            origin: referenceFrame.origin,
            size: NSSize(
                width: referenceFrame.width + 36,
                height: referenceFrame.height
            )
        )
        controller.windowWillStartLiveResize(Notification(
            name: NSWindow.willStartLiveResizeNotification,
            object: window
        ))
        window.delegate = nil
        window.setFrame(partialFrame, display: false)
        window.delegate = controller
        controller.windowDidResize(Notification(
            name: NSWindow.didResizeNotification,
            object: window
        ))
        window.contentView?.layoutSubtreeIfNeeded()
        canvasHost.layoutSubtreeIfNeeded()
        let firstCorrectedFrame = window.frame
        let firstDiagnostic = "missing-callback partial=\(partialFrame) "
            + "frame=\(firstCorrectedFrame) canvas=\(canvasHost.bounds)"
        XCTAssertTrue(
            abs(firstCorrectedFrame.width - partialFrame.width) > 0.5
                || abs(firstCorrectedFrame.height - partialFrame.height) > 0.5,
            firstDiagnostic
        )
        XCTAssertTrue(canvasIsExact(
            canvasHost: canvasHost,
            videoCanvas: videoCanvas,
            interactionCanvas: interactionCanvas,
            ratio: ratio
        ), firstDiagnostic)

        var continuedPartialFrame = firstCorrectedFrame
        continuedPartialFrame.size.width -= 36
        window.delegate = nil
        window.setFrame(continuedPartialFrame, display: false)
        let adoptedContinuedFrame = window.frame
        window.delegate = controller
        controller.windowDidResize(Notification(
            name: NSWindow.didResizeNotification,
            object: window
        ))
        window.contentView?.layoutSubtreeIfNeeded()
        canvasHost.layoutSubtreeIfNeeded()
        let continuedDiagnostic = "continued-missing-callback partial="
            + "\(continuedPartialFrame) adopted=\(adoptedContinuedFrame) "
            + "frame=\(window.frame) "
            + "canvas=\(canvasHost.bounds)"
        XCTAssertLessThan(
            window.frame.width,
            firstCorrectedFrame.width - 0.5,
            firstDiagnostic + " " + continuedDiagnostic
        )
        XCTAssertTrue(canvasIsExact(
            canvasHost: canvasHost,
            videoCanvas: videoCanvas,
            interactionCanvas: interactionCanvas,
            ratio: ratio
        ), continuedDiagnostic)

        controller.windowDidEndLiveResize(Notification(
            name: NSWindow.didEndLiveResizeNotification,
            object: window
        ))
        try await Task.sleep(nanoseconds: 700_000_000)
        window.contentView?.layoutSubtreeIfNeeded()
        canvasHost.layoutSubtreeIfNeeded()
        let diagnostic = "missing-callback partial=\(continuedPartialFrame) "
            + "frame=\(window.frame) canvas=\(canvasHost.bounds)"
        XCTAssertTrue(
            abs(window.frame.width - continuedPartialFrame.width) > 0.5
                || abs(window.frame.height - continuedPartialFrame.height) > 0.5,
            diagnostic
        )
        XCTAssertTrue(canvasIsExact(
            canvasHost: canvasHost,
            videoCanvas: videoCanvas,
            interactionCanvas: interactionCanvas,
            ratio: ratio
        ), diagnostic)
    }

    @MainActor
    private func canvasIsExact(
        canvasHost: NSView,
        videoCanvas: NSView,
        interactionCanvas: NSView,
        ratio: CGFloat
    ) -> Bool {
        let bounds = canvasHost.bounds
        guard bounds.height > 0 else { return false }
        return abs(bounds.width - bounds.height * ratio) <= 0.5
            && abs(bounds.minX - videoCanvas.frame.minX) <= 0.5
            && abs(bounds.minY - videoCanvas.frame.minY) <= 0.5
            && abs(bounds.width - videoCanvas.frame.width) <= 0.5
            && abs(bounds.height - videoCanvas.frame.height) <= 0.5
            && abs(bounds.minX - interactionCanvas.frame.minX) <= 0.5
            && abs(bounds.minY - interactionCanvas.frame.minY) <= 0.5
            && abs(bounds.width - interactionCanvas.frame.width) <= 0.5
            && abs(bounds.height - interactionCanvas.frame.height) <= 0.5
    }

    @MainActor
    private func makePointerHarness(
        targetID: String,
        configure: (MockGUIHostRuntimeSession) -> Void = { _ in }
    ) async throws -> PointerHarness {
        let target = try CanonicalUDID(canonicalString: targetID)
        let attached = expectation(description: "pointer runtime attached")
        let closed = expectation(description: "pointer runtime closed")
        let session = try MockGUIHostRuntimeSession(
            target: target,
            attached: attached,
            closed: closed,
            supportsPointerStreams: true
        )
        configure(session)
        let controller = ProductionGUIHostWindowController(
            catalog: ProductionAVFoundationVideoSourceCatalog(),
            mappingCoordinator: ProductionVideoSourceMappingCoordinator(
                store: InMemoryVideoSourceMappingStore()
            ),
            runtimeSessionFactory: { _ in session },
            toolbarRepositoryRoot: repositoryRoot(),
            presentsWindows: false
        )
        let identifier = try XCTUnwrap(controller.createWindow(for: target))
        await fulfillment(of: [attached], timeout: 3)
        try await waitUntil { session.events.contains("availability") }
        await Task.yield()
        try controller.applyRuntimeGeometry(pointerGeometry(), toWindow: identifier)
        let window = try XCTUnwrap(NSApplication.shared.windows.first {
            $0.identifier?.rawValue == identifier
        })
        Self.retainedHeadlessWindows.append(window)
        let interaction = try XCTUnwrap(descendant(
            in: try XCTUnwrap(window.contentView),
            identifier: ProductionGUIHostViewIdentifier.interactionCanvas
        ) as? ProductionGUIHostInteractionView)
        return PointerHarness(
            closed: closed,
            controller: controller,
            interaction: interaction,
            session: session,
            window: window
        )
    }

    @MainActor
    private func closePointerHarness(_ harness: PointerHarness) async throws {
        XCTAssertFalse(harness.controller.windowShouldClose(harness.window))
        await fulfillment(of: [harness.closed], timeout: 3)
        harness.controller.stopMonitoring()
    }

    private func pointerGeometry() throws -> DisplayGeometryDTO {
        try DisplayGeometryDTO(
            connectionEpoch: 7,
            geometryRevision: 1,
            logicalHeight: 100,
            logicalWidth: 100,
            orientation: .portrait
        )
    }

    @MainActor
    private func descendant(
        in view: NSView,
        identifier: NSUserInterfaceItemIdentifier
    ) -> NSView? {
        if view.identifier == identifier { return view }
        for subview in view.subviews {
            if let match = descendant(in: subview, identifier: identifier) {
                return match
            }
        }
        return nil
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private static func object(
        _ members: [(String, RepositoryJSONValue)]
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(members: members.map {
            RepositoryJSONMember(key: $0.0, value: $0.1)
        })
    }

    private static func rotateResult(
        current: String,
        previous: String,
        response: String,
        changed: Bool,
        confirmed: Bool
    ) throws -> RepositoryJSONObject {
        try object([
            ("outcome", .string("succeeded")),
            ("value", .object(try object([
                ("currentDisplayOrientation", .string(current)),
                ("direction", .string("right")),
                ("displayOrientationChanged", .bool(changed)),
                ("geometryRevision", .number(.uint64(4))),
                ("logicalHeight", .number(.uint64(1_170))),
                ("logicalWidth", .number(.uint64(2_532))),
                ("orientation", .string(current)),
                ("outcomeKnown", .bool(confirmed)),
                ("previousDisplayOrientation", .string(previous)),
                ("requestedDirection", .string("right")),
                ("rotateResponseOrientation", .string(response)),
                ("visibleOrientationConfirmed", .bool(confirmed)),
            ]))),
        ])
    }

    private func makeTemporaryApp() throws -> CanonicalAppPath {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-M2031-\(UUID().uuidString)",
            isDirectory: true
        )
        let app = root.appendingPathComponent("PulsePhone.app", isDirectory: true)
        let macOS = app.appendingPathComponent("Contents/MacOS", isDirectory: true)
        try FileManager.default.createDirectory(
            at: macOS,
            withIntermediateDirectories: true
        )
        let source = repositoryRoot().appendingPathComponent(".build/debug/PulsePhone")
        let destination = macOS.appendingPathComponent("PulsePhone")
        try FileManager.default.copyItem(at: source, to: destination)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: destination.path
        )
        guard let resolved = realpath(app.path, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(resolved) }
        return try CanonicalAppPath(canonicalBundlePath: String(cString: resolved))
    }
}

@MainActor
private struct PointerHarness {
    let closed: XCTestExpectation
    let controller: ProductionGUIHostWindowController
    let interaction: ProductionGUIHostInteractionView
    let session: MockGUIHostRuntimeSession
    let window: NSWindow
}

private final class LockedJSONObjectStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = [RepositoryJSONObject]()

    var values: [RepositoryJSONObject] {
        lock.withLock { storage }
    }

    func append(_ value: RepositoryJSONObject) {
        lock.withLock { storage.append(value) }
    }
}

private final class MockGUIHostRuntimeSession:
    ProductionGUIHostRuntimeSession,
    @unchecked Sendable
{
    let clientInstanceID = CanonicalUUID(value: UUID())

    private let attachedExpectation: XCTestExpectation
    private let closedExpectation: XCTestExpectation
    private let failsAvailability: Bool
    private let availabilityStartsWithGeometryUnavailable: Bool
    private let keyboardCapabilityAvailable: Bool
    private let lock = NSLock()
    private let successfulSubmissions: Bool
    private let supportsKeyboardStreams: Bool
    private let supportsPointerStreams: Bool
    private let target: CanonicalUDID
    private var attachment: LiveAttachment?
    private var availabilityCalls = 0
    private var failNextKeyboardSend = false
    private var failPointerCancel = false
    private var failPointerClose = false
    private var failPointerFrame = false
    private var failPointerOpen = false
    private var lastDetachedAttachment: LiveAttachment?
    private var liveOwnershipAttachment: LiveAttachment?
    private var ownedStreams = [CanonicalUUID: ProductionRuntimeLiveStream]()
    private var nextPointerAcceptedGeometry: DisplayGeometryDTO?
    private var observationHandler: (@Sendable (RuntimeObservation) -> Void)?
    private var observationResetHandler:
        (@Sendable (ObservationStreamReset) -> Void)?
    private var pointerCloseGate: DispatchSemaphore?
    private var pointerOpenGate: DispatchSemaphore?
    private var recordedEvents = [String]()
    private var recordedSubmissions = [(
        commandID: String,
        arguments: [String: String]
    )]()
    private var runtimeEventHandler: (@Sendable (RepositoryJSONObject) -> Void)?
    private var streamCommands = [CanonicalUUID: String]()
    private var transportFailureHandler: (@Sendable (RuntimeClientError) -> Void)?

    init(
        target: CanonicalUDID,
        attached: XCTestExpectation,
        closed: XCTestExpectation,
        failsAvailability: Bool = false,
        availabilityStartsWithGeometryUnavailable: Bool = false,
        keyboardCapabilityAvailable: Bool = true,
        successfulSubmissions: Bool = false,
        supportsKeyboardStreams: Bool = false,
        supportsPointerStreams: Bool = false
    ) throws {
        self.target = target
        self.attachedExpectation = attached
        self.closedExpectation = closed
        self.failsAvailability = failsAvailability
        self.availabilityStartsWithGeometryUnavailable =
            availabilityStartsWithGeometryUnavailable
        self.keyboardCapabilityAvailable = keyboardCapabilityAvailable
        self.successfulSubmissions = successfulSubmissions
        self.supportsKeyboardStreams = supportsKeyboardStreams
        self.supportsPointerStreams = supportsPointerStreams
        let attachment = try LiveAttachment(
            canonicalUDID: target,
            liveOwnerID: CanonicalUUID(value: UUID()),
            subscriptionID: CanonicalUUID(value: UUID()),
            connectionEpoch: 7,
            stateRevision: 1
        )
        self.attachment = attachment
        self.liveOwnershipAttachment = attachment
    }

    var currentAttachment: LiveAttachment? {
        lock.withLock { attachment }
    }

    var ownedStreamCount: Int { lock.withLock { ownedStreams.count } }

    var events: [String] {
        lock.withLock { recordedEvents }
    }

    var submissions: [(commandID: String, arguments: [String: String])] {
        lock.withLock { recordedSubmissions }
    }

    var availabilityCallCount: Int {
        lock.withLock { availabilityCalls }
    }

    var detachedAttachment: LiveAttachment? {
        lock.withLock { lastDetachedAttachment }
    }

    func setRuntimeEventHandler(
        _ handler: (@Sendable (RepositoryJSONObject) -> Void)?
    ) {
        lock.withLock { runtimeEventHandler = handler }
    }

    func setRuntimeObservationHandler(
        _ handler: (@Sendable (RuntimeObservation) -> Void)?
    ) {
        lock.withLock { observationHandler = handler }
    }

    func setObservationResetHandler(
        _ handler: (@Sendable (ObservationStreamReset) -> Void)?
    ) {
        lock.withLock { observationResetHandler = handler }
    }

    func setTransportFailureHandler(
        _ handler: (@Sendable (RuntimeClientError) -> Void)?
    ) {
        lock.withLock { transportFailureHandler = handler }
    }

    func simulateTransportFailure() {
        let handler = lock.withLock { transportFailureHandler }
        handler?(.transportFailure(errno: EPIPE))
    }

    func simulateDeviceDisconnected() throws {
        let delivery = try lock.withLock {
            () throws -> ((@Sendable (RepositoryJSONObject) -> Void)?, RepositoryJSONObject) in
            let current = try XCTUnwrap(attachment)
            attachment = nil
            ownedStreams.removeAll()
            streamCommands.removeAll()
            let event = try RepositoryJSONObject(members: [
                RepositoryJSONMember(
                    key: "connectionEpoch",
                    value: .number(.uint64(current.connectionEpoch))
                ),
                RepositoryJSONMember(
                    key: "eventKind",
                    value: .string("deviceDisconnected")
                ),
            ])
            return (runtimeEventHandler, event)
        }
        delivery.0?(delivery.1)
    }

    func simulateDeviceReattached() throws -> LiveAttachment {
        let delivery = try lock.withLock {
            () throws -> (
                (@Sendable (RepositoryJSONObject) -> Void)?,
                RepositoryJSONObject,
                LiveAttachment
            ) in
            let current = try XCTUnwrap(liveOwnershipAttachment)
            guard attachment == nil else { throw RuntimeClientError.invalidResponse }
            let replacement = try LiveAttachment(
                canonicalUDID: current.canonicalUDID,
                liveOwnerID: current.liveOwnerID,
                subscriptionID: current.subscriptionID,
                connectionEpoch: current.connectionEpoch + 1,
                stateRevision: current.stateRevision + 1
            )
            attachment = replacement
            liveOwnershipAttachment = replacement
            let event = try RepositoryJSONObject(members: [
                RepositoryJSONMember(
                    key: "connectionEpoch",
                    value: .number(.uint64(replacement.connectionEpoch))
                ),
                RepositoryJSONMember(
                    key: "eventKind",
                    value: .string("availabilityInvalidated")
                ),
            ])
            return (runtimeEventHandler, event, replacement)
        }
        delivery.0?(delivery.1)
        return delivery.2
    }

    func simulateRuntimePointerObservation(
        frameKind: RuntimePointerFrameKind,
        x: String,
        y: String
    ) throws {
        let delivery = try lock.withLock {
            () throws -> (
                (@Sendable (RuntimeObservation) -> Void)?,
                RuntimeObservation
            ) in
            let current = try XCTUnwrap(attachment)
            let observation = RuntimeObservation(
                subscriptionID: current.subscriptionID,
                clientInstanceID: CanonicalUUID(value: UUID()),
                interactionID: CanonicalUUID(value: UUID()),
                observationSequence: 0,
                presentationPayload: RuntimePointerProjection(
                    edge: "none",
                    frameKind: frameKind,
                    x: x,
                    y: y
                )
            )
            return (observationHandler, observation)
        }
        delivery.0?(delivery.1)
    }

    func failNextKeyboardFrame() {
        lock.withLock { failNextKeyboardSend = true }
    }

    func blockNextPointerClose() {
        lock.withLock { pointerCloseGate = DispatchSemaphore(value: 0) }
    }

    func releaseBlockedPointerClose() {
        let gate = lock.withLock { () -> DispatchSemaphore? in
            defer { pointerCloseGate = nil }
            return pointerCloseGate
        }
        gate?.signal()
    }

    func blockNextPointerOpen() {
        lock.withLock { pointerOpenGate = DispatchSemaphore(value: 0) }
    }

    func releaseBlockedPointerOpen() {
        let gate = lock.withLock { () -> DispatchSemaphore? in
            defer { pointerOpenGate = nil }
            return pointerOpenGate
        }
        gate?.signal()
    }

    func failNextPointerOpen() {
        lock.withLock { failPointerOpen = true }
    }

    func acceptNextPointerGeometry(_ geometry: DisplayGeometryDTO) {
        lock.withLock { nextPointerAcceptedGeometry = geometry }
    }

    func failNextPointerFrame() {
        lock.withLock { failPointerFrame = true }
    }

    func failNextPointerClose() {
        lock.withLock { failPointerClose = true }
    }

    func failNextPointerCancel() {
        lock.withLock { failPointerCancel = true }
    }

    func attach(observationTopics: [String]) throws -> LiveAttachment {
        let value = try lock.withLock { () throws -> LiveAttachment in
            recordedEvents.append("attach")
            return try XCTUnwrap(attachment)
        }
        attachedExpectation.fulfill()
        return value
    }

    func prepareCapabilities() throws -> RepositoryJSONObject {
        lock.withLock { recordedEvents.append("prepare") }
        return try RepositoryJSONObject(members: [])
    }

    func availability() throws -> RepositoryJSONObject {
        let (geometryUnavailable, shouldFail) = lock.withLock { () -> (Bool, Bool) in
            recordedEvents.append("availability")
            availabilityCalls += 1
            return (
                availabilityStartsWithGeometryUnavailable
                    && availabilityCalls == 1,
                failsAvailability
            )
        }
        if shouldFail {
            throw RuntimeClientError.transportFailure(errno: EAGAIN)
        }
        var commandIDs = [
            "button.home", "button.appSwitcher", "button.lock",
            "button.volumeUp", "button.volumeDown", "button.mute",
            "device.rotate", "screenshot.gui", "gui.keyboardCapture.toggle",
            "gui.keyboard.interaction", "gui.softwareKeyboard.toggle",
            "gui.previewAudioMute.toggle",
            "app.install",
        ]
        if supportsPointerStreams {
            commandIDs.append("gui.pointer.interaction")
        }
        return try RepositoryJSONObject(members: [
            RepositoryJSONMember(
                key: "commands",
                value: .array(try commandIDs.map { commandID in
                    var members = [
                        RepositoryJSONMember(
                            key: "commandID",
                            value: .string(commandID)
                        ),
                        RepositoryJSONMember(
                        key: "state",
                        value: .string(
                            geometryUnavailable && commandID == "device.rotate"
                                || !keyboardCapabilityAvailable
                                    && commandID == "gui.keyboard.interaction"
                                ? "disabled"
                                : "enabled"
                        )
                    ),
                ]
                if geometryUnavailable && commandID == "device.rotate" {
                    members.append(RepositoryJSONMember(
                        key: "reasonCode",
                        value: .string("displayGeometryUnavailable")
                    ))
                } else if !keyboardCapabilityAvailable
                    && commandID == "gui.keyboard.interaction"
                {
                    members.append(RepositoryJSONMember(
                        key: "reasonCode",
                        value: .string("deviceKeyboardUnavailable")
                    ))
                }
                    return .object(try RepositoryJSONObject(members: members))
                })
            ),
        ])
    }

    func markLiveCaptureReady(
        captureActivationID: CanonicalUUID
    ) throws -> ProductionRuntimeCaptureReadyTransition {
        let epoch = try lock.withLock { () throws -> UInt64 in
            recordedEvents.append("capture.ready")
            return try XCTUnwrap(attachment).connectionEpoch
        }
        let value = try RepositoryJSONObject(members: [
            RepositoryJSONMember(
                key: "captureProvenance",
                value: .string("postCapture")
            ),
            RepositoryJSONMember(
                key: "connectionEpoch",
                value: .number(.uint64(epoch))
            ),
            RepositoryJSONMember(
                key: "disposition",
                value: .string("ready")
            ),
        ])
        return try ProductionRuntimeCaptureReadyTransition(
            value: value,
            expectedConnectionEpoch: epoch
        )
    }

    func submit(
        commandID: String,
        rawArguments: [String: String],
        actionID: CanonicalUUID
    ) throws -> RepositoryJSONObject {
        lock.withLock {
            recordedEvents.append("submit.\(commandID)")
            recordedSubmissions.append((commandID, rawArguments))
        }
        if successfulSubmissions {
            let value: RepositoryJSONObject
            if commandID == "app.install" {
                value = try RepositoryJSONObject(members: [
                    RepositoryJSONMember(
                        key: "bundleID",
                        value: .string("com.example.Fixture")
                    ),
                    RepositoryJSONMember(
                        key: "disposition",
                        value: .string("installed")
                    ),
                ])
            } else {
                value = try RepositoryJSONObject(members: [
                    RepositoryJSONMember(
                        key: "disposition",
                        value: .string("acknowledged")
                    ),
                ])
            }
            return try RepositoryJSONObject(members: [
                RepositoryJSONMember(key: "outcome", value: .string("succeeded")),
                RepositoryJSONMember(
                    key: "value",
                    value: .object(value)
                ),
            ])
        }
        throw RuntimeClientError.invalidResponse
    }

    func recordLocalAction(_ body: RepositoryJSONObject) throws {
        lock.withLock { recordedEvents.append("recordLocalAction") }
    }

    func openStream(
        commandID: String,
        rawArguments: [String: String],
        actionID: CanonicalUUID,
        interactionID: CanonicalUUID
    ) throws -> ProductionRuntimeLiveStream {
        let supported = commandID == "gui.keyboard.interaction"
            ? supportsKeyboardStreams
            : supportsPointerStreams && commandID == "gui.pointer.interaction"
        guard supported else { throw RuntimeClientError.invalidResponse }
        if commandID == "gui.pointer.interaction" {
            let shouldFail = lock.withLock { () -> Bool in
                guard failPointerOpen else { return false }
                failPointerOpen = false
                recordedEvents.append("pointer.open.failure")
                return true
            }
            if shouldFail {
                throw RuntimeClientError.transportFailure(errno: EIO)
            }
            let openGate = lock.withLock { () -> DispatchSemaphore? in
                guard let pointerOpenGate else { return nil }
                recordedEvents.append("pointer.open.blocked")
                return pointerOpenGate
            }
            openGate?.wait()
        }
        let acceptedGeometry = lock.withLock { () -> DisplayGeometryDTO? in
            guard commandID == "gui.pointer.interaction" else { return nil }
            defer { nextPointerAcceptedGeometry = nil }
            return nextPointerAcceptedGeometry
        }
        let stream = ProductionRuntimeLiveStream(
            acceptedGeometry: acceptedGeometry,
            actionID: actionID,
            executorGeneration: 1,
            interactionID: interactionID,
            sessionID: CanonicalUUID(value: UUID())
        )
        lock.withLock {
            ownedStreams[stream.sessionID] = stream
            streamCommands[stream.sessionID] = commandID
            recordedEvents.append(commandID == "gui.pointer.interaction"
                ? "pointer.open"
                : "keyboard.open")
        }
        return stream
    }

    func sendFrame(
        stream: ProductionRuntimeLiveStream,
        sequence: UInt64,
        frameKind: String,
        payload: RepositoryJSONObject,
        clientSubmittedMonotonicNanoseconds: UInt64?
    ) throws {
        try lock.withLock {
            guard ownedStreams[stream.sessionID] == stream else {
                throw RuntimeClientError.invalidResponse
            }
            let commandID = streamCommands[stream.sessionID]
            if commandID == "gui.pointer.interaction", failPointerFrame {
                failPointerFrame = false
                recordedEvents.append("pointer.frame.failure")
                throw RuntimeClientError.transportFailure(errno: EIO)
            }
            if commandID == "gui.keyboard.interaction", failNextKeyboardSend {
                failNextKeyboardSend = false
                recordedEvents.append("keyboard.frame.failure")
                throw RuntimeClientError.transportFailure(errno: EIO)
            }
            if commandID == "gui.pointer.interaction" {
                if let revision = payload["expectedGeometryRevision"]?.numberValue
                    .flatMap({ try? $0.requireUInt64() })
                {
                    recordedEvents.append("pointer.geometry.\(revision)")
                }
                recordedEvents.append("pointer.frame.\(sequence).\(frameKind)")
            } else {
                let usageCount = payload["usages"]?.arrayValue?.count ?? -1
                recordedEvents.append("keyboard.frame.\(sequence).\(usageCount)")
            }
        }
    }

    func closeStream(
        _ stream: ProductionRuntimeLiveStream,
        expectedLastSequence: UInt64?,
        reason: String
    ) throws -> RepositoryJSONObject {
        let gate = try lock.withLock { () throws -> DispatchSemaphore? in
            guard ownedStreams[stream.sessionID] != nil else {
                throw RuntimeClientError.invalidResponse
            }
            let commandID = streamCommands[stream.sessionID]
            if commandID == "gui.pointer.interaction", failPointerClose {
                failPointerClose = false
                recordedEvents.append("pointer.close.failure")
                throw RuntimeClientError.transportFailure(errno: EIO)
            }
            if commandID == "gui.pointer.interaction", let gate = pointerCloseGate {
                recordedEvents.append("pointer.close.blocked")
                return gate
            }
            return nil
        }
        gate?.wait()
        try lock.withLock {
            guard ownedStreams.removeValue(forKey: stream.sessionID) != nil else {
                throw RuntimeClientError.invalidResponse
            }
            let commandID = streamCommands.removeValue(forKey: stream.sessionID)
            let prefix = commandID == "gui.pointer.interaction" ? "pointer" : "keyboard"
            recordedEvents.append(
                "\(prefix).close.\(expectedLastSequence.map(String.init) ?? "nil")"
            )
        }
        return try RepositoryJSONObject(members: [])
    }

    func cancelStream(
        _ stream: ProductionRuntimeLiveStream,
        reason: String
    ) throws -> RepositoryJSONObject {
        try lock.withLock {
            let commandID = streamCommands[stream.sessionID]
            if commandID == "gui.pointer.interaction", failPointerCancel {
                failPointerCancel = false
                recordedEvents.append("pointer.cancel.failure")
                throw RuntimeClientError.transportFailure(errno: EIO)
            }
            ownedStreams.removeValue(forKey: stream.sessionID)
            streamCommands.removeValue(forKey: stream.sessionID)
            let prefix = commandID == "gui.pointer.interaction" ? "pointer" : "keyboard"
            recordedEvents.append("\(prefix).cancel.\(reason)")
        }
        return try RepositoryJSONObject(members: [])
    }

    func detach() throws -> LiveDetachResult {
        lock.withLock {
            recordedEvents.append("detach")
            lastDetachedAttachment = liveOwnershipAttachment
            attachment = nil
            liveOwnershipAttachment = nil
        }
        return LiveDetachResult(detached: true)
    }

    func close() throws {
        lock.withLock {
            if liveOwnershipAttachment != nil {
                recordedEvents.append("detach")
                lastDetachedAttachment = liveOwnershipAttachment
                attachment = nil
                liveOwnershipAttachment = nil
            }
            recordedEvents.append("close")
        }
        closedExpectation.fulfill()
    }
}

private final class MockGUIHostRuntimeSessionFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var sessions: [MockGUIHostRuntimeSession]

    init(sessions: [MockGUIHostRuntimeSession]) {
        self.sessions = sessions
    }

    func next() throws -> MockGUIHostRuntimeSession {
        try lock.withLock {
            guard !sessions.isEmpty else {
                throw RuntimeClientError.closedBeforeResponse
            }
            return sessions.removeFirst()
        }
    }
}

private struct AssemblyScreenshotRequest: Equatable {
    let canonicalUDID: CanonicalUDID
    let childActionID: CanonicalUUID
    let rootActionID: CanonicalUUID
}

private final class MockGUIScreenshotDeviceBackend:
    GUIScreenshotDeviceBackend,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var nextError: RuntimeClientError?
    private var recordedRequests = [AssemblyScreenshotRequest]()

    var requests: [AssemblyScreenshotRequest] {
        lock.withLock { recordedRequests }
    }

    func failNext(_ error: RuntimeClientError) {
        lock.withLock { nextError = error }
    }

    func requestDeviceScreenshot(
        rootActionID: CanonicalUUID,
        childActionID: CanonicalUUID,
        canonicalUDID: CanonicalUDID
    ) throws -> GUIScreenshotPNGArtifact {
        let error = lock.withLock { () -> RuntimeClientError? in
            recordedRequests.append(AssemblyScreenshotRequest(
                canonicalUDID: canonicalUDID,
                childActionID: childActionID,
                rootActionID: rootActionID
            ))
            defer { nextError = nil }
            return nextError
        }
        if let error { throw error }
        return try GUIScreenshotPNGArtifact(bytes: [
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1,
        ])
    }
}

private struct AssemblyScreenshotWrite: Equatable {
    let absolutePath: String
    let replaceExisting: Bool
}

private final class MockGUIScreenshotOutputWriter:
    GUIScreenshotOutputWriting,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var failWrite = false
    private var recordedWrites = [AssemblyScreenshotWrite]()

    var writes: [AssemblyScreenshotWrite] {
        lock.withLock { recordedWrites }
    }

    func failNextWrite() {
        lock.withLock { failWrite = true }
    }

    func write(
        _ artifact: GUIScreenshotPNGArtifact,
        toAbsolutePath absolutePath: String,
        replaceExisting: Bool,
        tempID: CanonicalUUID
    ) throws {
        let shouldFail = lock.withLock { () -> Bool in
            guard failWrite else { return false }
            failWrite = false
            return true
        }
        if shouldFail { throw AtomicOutputFileError.localWriteFailed }
        lock.withLock {
            recordedWrites.append(AssemblyScreenshotWrite(
                absolutePath: absolutePath,
                replaceExisting: replaceExisting
            ))
        }
    }
}

private final class MockKeyboardEventTap:
    ProductionKeyboardEventTapControlling,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var active = false
    private var handler: (@Sendable (ProductionKeyboardEventTapMessage) -> Void)?
    private var installed = false
    private var status: ProductionKeyboardInputMonitoringStatus
    private var requestedStatus: ProductionKeyboardInputMonitoringStatus

    init(
        status: ProductionKeyboardInputMonitoringStatus,
        requestedStatus: ProductionKeyboardInputMonitoringStatus? = nil
    ) {
        self.status = status
        self.requestedStatus = requestedStatus ?? status
    }

    var authorizationStatus: ProductionKeyboardInputMonitoringStatus {
        lock.withLock { status }
    }

    var isInstalled: Bool { lock.withLock { installed } }

    var isCaptureActive: Bool { lock.withLock { active } }

    func setAuthorizationStatus(
        _ status: ProductionKeyboardInputMonitoringStatus
    ) {
        lock.withLock { self.status = status }
    }

    func requestAuthorization() -> ProductionKeyboardInputMonitoringStatus {
        lock.withLock {
            status = requestedStatus
            return status
        }
    }

    func install(
        handler: @escaping @Sendable (ProductionKeyboardEventTapMessage) -> Void
    ) -> Bool {
        lock.withLock {
            guard status == .authorized else { return false }
            self.handler = handler
            installed = true
            return true
        }
    }

    func setCaptureActive(_ active: Bool) {
        lock.withLock { self.active = active }
    }

    func invalidate() {
        lock.withLock {
            active = false
            handler = nil
            installed = false
        }
    }

    func emit(_ message: ProductionKeyboardEventTapMessage) {
        let callback = lock.withLock {
            active || message == .disabled ? handler : nil
        }
        callback?(message)
    }
}

private final class MockWindowFocus: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: Bool

    init(isKey: Bool) {
        storage = isKey
    }

    var isKey: Bool { lock.withLock { storage } }

    func setKey(_ isKey: Bool) {
        lock.withLock { storage = isKey }
    }
}

private final class InMemoryVideoSourceMappingStore:
    VideoSourceMappingStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var records = [CanonicalUDID: VideoSourceMappingRecordV2]()

    func load(target: CanonicalUDID) -> VideoSourceMappingLoadResult {
        lock.withLock {
            records[target].map {
                VideoSourceMappingLoadResult.mapped(.currentV2($0))
            } ?? .missing
        }
    }

    func replace(
        target: CanonicalUDID,
        sourceID: String,
        proofKind: VideoSourceMappingProofKind,
        initialCanvasWidth: UInt64?,
        initialCanvasHeight: UInt64?
    ) throws -> VideoSourceMappingRecordV2 {
        let record = try VideoSourceMappingRecordV2(
            target: target,
            sourceID: sourceID,
            proofKind: proofKind,
            initialCanvasWidth: initialCanvasWidth,
            initialCanvasHeight: initialCanvasHeight
        )
        lock.withLock { records[target] = record }
        return record
    }

    func clear(target: CanonicalUDID) throws -> Bool {
        lock.withLock { records.removeValue(forKey: target) != nil }
    }
}

private final class LockedCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = 0

    var value: Int { lock.withLock { storage } }

    func increment() {
        lock.withLock { storage += 1 }
    }
}
