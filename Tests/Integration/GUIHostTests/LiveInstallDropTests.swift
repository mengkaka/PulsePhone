import AppKit
import Foundation
@testable import PulsePhoneGUI
import XCTest

final class LiveInstallDropTests: XCTestCase {
    @MainActor
    func testWholeWindowHoverAndSingleSubmissionForIPAAndApp() throws {
        let fixture = try InstallDropFixture()
        defer { fixture.remove() }
        let window = makeWindow()
        defer { window.close() }
        window.toolbar = NSToolbar(identifier: "install-drop-test")
        var accepted = [ToolbarInstallParameter]()
        window.acceptedDrop = { accepted.append($0) }
        let drag = InstallDropDraggingInfo(window: window, urls: [fixture.ipa], sequence: 1)
        XCTAssertEqual(window.draggingEntered(drag), .copy)
        XCTAssertTrue(window.isInstallDropHighlighted)
        XCTAssertTrue(accepted.isEmpty)

        let frameView = try XCTUnwrap(window.contentView?.superview)
        let border = try XCTUnwrap(frameView.subviews.compactMap {
            $0 as? ProductionInstallDropBorderView
        }.first)
        XCTAssertEqual(border.frame, frameView.bounds)
        XCTAssertNil(border.hitTest(NSPoint(x: 2, y: 2)))
        // Bottom controls, video, and native toolbar remain one window destination.
        for point in [NSPoint(x: 10, y: 10), NSPoint(x: 100, y: 100),
                      NSPoint(x: 20, y: frameView.bounds.maxY - 5)] {
            drag.draggingLocation = point
            XCTAssertEqual(window.draggingUpdated(drag), .copy)
            XCTAssertTrue(window.isInstallDropHighlighted)
            XCTAssertTrue(accepted.isEmpty)
            XCTAssertTrue(frameView.subviews.last === border)
        }
        window.setContentSize(NSSize(width: 440, height: 660))
        XCTAssertEqual(border.frame, frameView.bounds)
        XCTAssertTrue(window.prepareForDragOperation(drag))
        XCTAssertTrue(window.performDragOperation(drag))
        XCTAssertFalse(window.isInstallDropHighlighted)
        XCTAssertEqual(accepted.map(\.absoluteIPAPath), [fixture.ipa.path])
        XCTAssertFalse(window.performDragOperation(drag))
        XCTAssertEqual(window.draggingEntered(drag), [])
        XCTAssertEqual(accepted.count, 1)

        let appDrag = InstallDropDraggingInfo(window: window, urls: [fixture.app], sequence: 2)
        XCTAssertEqual(window.draggingEntered(appDrag), .copy)
        XCTAssertTrue(window.performDragOperation(appDrag))
        XCTAssertEqual(accepted.map(\.absoluteIPAPath), [fixture.ipa.path, fixture.app.path])
        window.concludeDragOperation(appDrag)
        XCTAssertFalse(window.isInstallDropHighlighted)
    }

    @MainActor
    func testInvalidMultipleAndChangedCandidatesNeverSubmit() throws {
        let fixture = try InstallDropFixture()
        defer { fixture.remove() }
        let window = makeWindow()
        defer { window.close() }
        var submissions = 0
        window.acceptedDrop = { _ in submissions += 1 }
        let invalidFile = fixture.directory.appendingPathComponent("Other.txt")
        try Data([1]).write(to: invalidFile)
        let wrongType = fixture.directory.appendingPathComponent("Directory.ipa")
        try FileManager.default.createDirectory(at: wrongType, withIntermediateDirectories: false)
        for (index, urls) in [[], [invalidFile], [wrongType], [fixture.ipa, fixture.app],
                              [fixture.directory.appendingPathComponent("Missing.app")]].enumerated() {
            let drag = InstallDropDraggingInfo(window: window, urls: urls, sequence: index)
            XCTAssertEqual(window.draggingEntered(drag), [])
            XCTAssertFalse(window.isInstallDropHighlighted)
            XCTAssertFalse(window.prepareForDragOperation(drag))
            XCTAssertFalse(window.performDragOperation(drag))
        }
        let drag = InstallDropDraggingInfo(window: window, urls: [fixture.ipa], sequence: 10)
        drag.draggingSourceOperationMask = .link
        XCTAssertEqual(window.draggingEntered(drag), [])
        drag.draggingSourceOperationMask = .copy
        XCTAssertEqual(window.draggingEntered(drag), .copy)
        // Recheck node facts on release, even after an accepted hover.
        try FileManager.default.removeItem(at: fixture.ipa)
        XCTAssertFalse(window.performDragOperation(drag))
        XCTAssertFalse(window.isInstallDropHighlighted)
        XCTAssertEqual(submissions, 0)
    }

    @MainActor
    func testExitCancellationCloseAndIndependentWindows() throws {
        let fixture = try InstallDropFixture()
        defer { fixture.remove() }
        let first = makeWindow()
        let second = makeWindow()
        defer { first.close(); second.close() }
        var firstCount = 0
        var secondCount = 0
        first.acceptedDrop = { _ in firstCount += 1 }
        second.acceptedDrop = { _ in secondCount += 1 }
        let drag = InstallDropDraggingInfo(window: first, urls: [fixture.app], sequence: 20)
        XCTAssertEqual(first.draggingEntered(drag), .copy)
        XCTAssertFalse(second.isInstallDropHighlighted)
        first.draggingExited(drag)
        XCTAssertFalse(first.isInstallDropHighlighted)
        XCTAssertEqual(first.draggingEntered(drag), .copy)
        first.draggingEnded(drag)
        XCTAssertFalse(first.isInstallDropHighlighted)
        XCTAssertEqual(firstCount, 0)

        drag.draggingDestinationWindow = second
        XCTAssertEqual(second.draggingEntered(drag), .copy)
        XCTAssertTrue(second.performDragOperation(drag))
        XCTAssertEqual(secondCount, 1)
        XCTAssertEqual(firstCount, 0)
        XCTAssertFalse(first.performDragOperation(drag))
        drag.draggingDestinationWindow = first
        XCTAssertEqual(first.draggingEntered(drag), .copy)
        first.acceptsInstallDrop = { false }
        XCTAssertEqual(first.draggingUpdated(drag), [])
        XCTAssertFalse(first.performDragOperation(drag))
        XCTAssertFalse(first.isInstallDropHighlighted)
        first.acceptsInstallDrop = { true }
        XCTAssertEqual(first.draggingEntered(drag), .copy)
        first.close()
        XCTAssertFalse(first.isInstallDropHighlighted)
    }

    @MainActor
    private func makeWindow() -> ProductionLiveInstallWindow {
        _ = NSApplication.shared
        let window = ProductionLiveInstallWindow(
            contentRect: NSRect(x: 0, y: 0, width: 375, height: 500),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.acceptsInstallDrop = { true }
        return window
    }
}

private struct InstallDropFixture {
    let directory: URL
    let ipa: URL
    let app: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        ipa = directory.appendingPathComponent("Fixture.ipa")
        app = directory.appendingPathComponent("Fixture.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try Data([1]).write(to: ipa)
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}

/// Real AppKit pasteboard passed through the production NSDraggingDestination methods.
@MainActor
final class InstallDropDraggingInfo: NSObject, NSDraggingInfo {
    var draggingDestinationWindow: NSWindow?
    var draggingSourceOperationMask: NSDragOperation = .copy
    var draggingLocation: NSPoint = .zero
    var draggedImageLocation: NSPoint { draggingLocation }
    nonisolated var draggedImage: NSImage? { nil }
    let draggingPasteboard: NSPasteboard
    var draggingSource: Any? { nil }
    let draggingSequenceNumber: Int
    var draggingFormation: NSDraggingFormation = .none
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    init(window: NSWindow, urls: [URL], sequence: Int) {
        draggingDestinationWindow = window
        draggingSequenceNumber = sequence
        draggingPasteboard = NSPasteboard.withUniqueName()
        super.init()
        draggingPasteboard.writeObjects(urls.map { $0 as NSURL })
    }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    nonisolated override func namesOfPromisedFilesDropped(atDestination dropDestination: URL) -> [String]? { nil }
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options enumOpts: NSDraggingItemEnumerationOptions,
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
