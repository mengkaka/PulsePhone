import Foundation
import XCTest
@testable import PulsePhoneHostPaths

final class PulsePhoneConfigurationStoreTests: XCTestCase {
    func testExistingDirectoryPermissionsArePreservedWhenSavingConfiguration() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent(
            "pulsephone-configuration-reuse-\(UUID().uuidString)", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: base) }
        let product = base.appendingPathComponent("PulsePhone", isDirectory: true)
        let root = product.appendingPathComponent("Configuration", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o755]
        )
        let snapshot = PulsePhoneConfigurationSnapshot(values: ["example.bool": .boolean(true)])
        let store = PulsePhoneConfigurationStore(rootURL: root)
        try store.save(snapshot)
        XCTAssertEqual(try store.load(), snapshot)
        for directory in [product, root] {
            let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        }
    }

    func testStoreAtomicallyRoundTripsMultipleTypedValues() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhoneOmniParserStore-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = PulsePhoneConfigurationStore(rootURL: root)

        XCTAssertEqual(try store.load(), PulsePhoneConfigurationSnapshot())
        let expected = PulsePhoneConfigurationSnapshot(values: [
            "example.bool": .boolean(true),
            "example.count": .uint64(7),
            "omniparser.endpoint": .string("https://omni.example.test/parse/"),
        ])
        try store.save(expected)
        XCTAssertEqual(try store.load(), expected)
    }
}
