import Darwin
import Foundation
import XCTest
@testable import PulsePhoneHostPaths

final class BundledHelperExecutableSetTests: XCTestCase {
    private func canonicalPath(_ path: String) -> String {
        guard let pointer = realpath(path, nil) else { return path }
        defer { free(pointer) }
        return String(cString: pointer)
    }

    func testResourcesRootResolvesSiblingHelpersDirectory() {
        let set = BundledHelperExecutableSet(
            resourcesURL: URL(fileURLWithPath: "/Applications/PulsePhone.app/Contents/Resources")
        )
        XCTAssertEqual(
            set.directExecutableURL.path,
            "/Applications/PulsePhone.app/Contents/Helpers/PulsePhoneDirectHelper"
        )
        XCTAssertEqual(
            set.coreDeviceExecutableURL.path,
            "/Applications/PulsePhone.app/Contents/Helpers/PulsePhoneCoreDeviceHelper"
        )
    }

    func testContentsAndAppRootsResolveTheSameHelpersDirectory() {
        let fromContents = BundledHelperExecutableSet(
            resourcesURL: URL(fileURLWithPath: "/tmp/PulsePhone.app/Contents")
        )
        let fromApp = BundledHelperExecutableSet(
            resourcesURL: URL(fileURLWithPath: "/tmp/PulsePhone.app")
        )
        XCTAssertEqual(fromContents, fromApp)
    }

    func testSymlinkedTemporaryPrefixResolvesBeforeExecutableValidation() {
        let input = URL(
            fileURLWithPath: "/tmp/PulsePhone.app/Contents/Resources"
        )
        let canonical = URL(
            fileURLWithPath: canonicalPath("/tmp")
        ).appendingPathComponent("PulsePhone.app/Contents/Resources")
        let set = BundledHelperExecutableSet(resourcesURL: input)

        XCTAssertEqual(
            set.directExecutableURL.path,
            canonical
                .deletingLastPathComponent()
                .appendingPathComponent("Helpers/PulsePhoneDirectHelper")
                .path
        )
    }

    func testSourceTreeRootResolvesGoDebugProducts() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pulsephone-source-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("GoHelpers"),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Registries"),
            withIntermediateDirectories: true
        )
        try Data().write(to: root.appendingPathComponent("Package.swift"))
        try Data().write(to: root.appendingPathComponent("GoHelpers/go.mod"))

        let set = BundledHelperExecutableSet(resourcesURL: root)
        let canonicalRoot = URL(fileURLWithPath: canonicalPath(root.path))
        XCTAssertEqual(
            set.directExecutableURL,
            canonicalRoot.appendingPathComponent(
                "build/go/debug/PulsePhoneDirectHelper"
            )
        )
        XCTAssertEqual(
            set.coreDeviceExecutableURL,
            canonicalRoot.appendingPathComponent(
                "build/go/debug/PulsePhoneCoreDeviceHelper"
            )
        )
    }
}
