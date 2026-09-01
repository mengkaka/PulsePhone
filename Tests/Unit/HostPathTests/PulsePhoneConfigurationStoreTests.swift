import Foundation
import XCTest
@testable import PulsePhoneHostPaths

final class PulsePhoneConfigurationStoreTests: XCTestCase {
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
