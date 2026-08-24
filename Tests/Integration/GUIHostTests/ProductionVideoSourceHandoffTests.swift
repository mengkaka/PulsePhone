import Darwin
import Foundation
@testable import PulsePhoneGUI
import PulsePhoneMedia
import PulsePhoneSharedDefinitions
import XCTest

final class ProductionVideoSourceHandoffTests: XCTestCase {
    func testInventoryWritesBoundedCanonicalOpaqueDocument() throws {
        let output = try OutputFile()
        defer { output.closeAndRemove() }
        let inventory = try VideoSourceInventory(
            inventoryRevision: 7,
            sources: [
                try VideoSourceDescriptor(
                    sourceID: String(repeating: "b", count: 64),
                    sourceEpoch: 3,
                    activeFormatWidth: 1_920,
                    activeFormatHeight: 1_080
                ),
                try VideoSourceDescriptor(
                    sourceID: String(repeating: "a", count: 64),
                    sourceEpoch: 2,
                    activeFormatWidth: 1_179,
                    activeFormatHeight: 2_556
                ),
                try VideoSourceDescriptor(
                    sourceID: String(repeating: "c", count: 64),
                    sourceEpoch: 4,
                    activeFormatWidth: 0,
                    activeFormatHeight: 0
                ),
            ]
        )
        XCTAssertEqual(ProductionVideoSourceHandoffEntrypoint.runInventory(
            arguments: inventoryArguments(descriptor: output.descriptor),
            inventoryProvider: { inventory }
        ), 0)
        output.close()
        let bytes = try Data(contentsOf: output.url)
        _ = try RepositoryCanonicalJSON.validateCanonicalDocument(
            [UInt8](bytes),
            maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: bytes) as? [String: Any]
        )
        XCTAssertEqual(object["schemaVersion"] as? Int, 1)
        XCTAssertEqual(object["inventoryRevision"] as? Int, 7)
        XCTAssertEqual(
            object["candidateInputHash"] as? String,
            String(repeating: "c", count: 64)
        )
        XCTAssertEqual(
            object["sessionNonce"] as? String,
            String(repeating: "d", count: 32)
        )
        XCTAssertEqual(object["videoAuthorizationStatus"] as? String, "authorized")
        let sources = try XCTUnwrap(object["sources"] as? [[String: Any]])
        XCTAssertEqual(sources.compactMap { $0["sourceID"] as? String }, [
            String(repeating: "a", count: 64),
            String(repeating: "b", count: 64),
            String(repeating: "c", count: 64),
        ])
        XCTAssertEqual(sources.last?["activeFormatWidth"] as? Int, 0)
        XCTAssertEqual(sources.last?["activeFormatHeight"] as? Int, 0)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("uniqueID"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("localizedName"))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("UDID"))
    }

    func testInventoryRejectsInvalidArgumentsDescriptorAndSourceIdentity() throws {
        let output = try OutputFile()
        defer { output.closeAndRemove() }
        let valid = try VideoSourceInventory(inventoryRevision: 1, sources: [])
        XCTAssertEqual(ProductionVideoSourceHandoffEntrypoint.runInventory(
            arguments: inventoryArguments(descriptor: output.descriptor) + [
                "--video-source-inventory-fd", String(output.descriptor),
            ],
            inventoryProvider: { valid }
        ), 64)
        XCTAssertEqual(ProductionVideoSourceHandoffEntrypoint.runInventory(
            arguments: inventoryArguments(descriptor: STDOUT_FILENO),
            inventoryProvider: { valid }
        ), 64)

        let invalid = try VideoSourceInventory(
            inventoryRevision: 1,
            sources: [try VideoSourceDescriptor(
                sourceID: "not-opaque",
                sourceEpoch: 1,
                activeFormatWidth: 1,
                activeFormatHeight: 1
            )]
        )
        XCTAssertEqual(ProductionVideoSourceHandoffEntrypoint.runInventory(
            arguments: inventoryArguments(descriptor: output.descriptor),
            inventoryProvider: { invalid }
        ), 64)
    }

    func testInventoryRejectsMoreThanSixtyFourSources() throws {
        let output = try OutputFile()
        defer { output.closeAndRemove() }
        let inventory = try VideoSourceInventory(
            inventoryRevision: 1,
            sources: try (0..<65).map { index in
                try VideoSourceDescriptor(
                    sourceID: String(format: "%064x", index),
                    sourceEpoch: UInt64(index + 1),
                    activeFormatWidth: 1,
                    activeFormatHeight: 1
                )
            }
        )
        XCTAssertEqual(ProductionVideoSourceHandoffEntrypoint.runInventory(
            arguments: inventoryArguments(descriptor: output.descriptor),
            inventoryProvider: { inventory }
        ), 64)
    }

    func testProcessEntrypointOwnsBothPrivateHandoffRoles() {
        XCTAssertTrue(GUIHostProcessEntrypoint.handles([
            ProductionVideoSourceHandoffEntrypoint.inventoryRoleArgument,
        ]))
        XCTAssertTrue(GUIHostProcessEntrypoint.handles([
            ProductionVideoSourceHandoffEntrypoint.probeRoleArgument,
        ]))
        XCTAssertEqual(GUIHostProcessEntrypoint.run(arguments: [
            ProductionVideoSourceHandoffEntrypoint.inventoryRoleArgument,
        ]), 64)
        XCTAssertEqual(GUIHostProcessEntrypoint.run(arguments: [
            ProductionVideoSourceHandoffEntrypoint.probeRoleArgument,
        ]), 64)
    }

    private func inventoryArguments(descriptor: Int32) -> [String] {
        [
            ProductionVideoSourceHandoffEntrypoint.inventoryRoleArgument,
            "--video-source-inventory-candidate-input-hash",
            String(repeating: "c", count: 64),
            "--video-source-inventory-fd", String(descriptor),
            "--video-source-inventory-session-nonce",
            String(repeating: "d", count: 32),
        ]
    }
}

private final class OutputFile {
    let descriptor: Int32
    let root: URL
    let url: URL
    private var closed = false

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-video-handoff-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        url = root.appendingPathComponent("inventory.json")
        descriptor = Darwin.open(
            url.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC,
            0o600
        )
        guard descriptor >= 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        _ = Darwin.close(descriptor)
    }

    func closeAndRemove() {
        close()
        try? FileManager.default.removeItem(at: root)
    }
}
