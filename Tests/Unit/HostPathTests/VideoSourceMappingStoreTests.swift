import Darwin
import Foundation
import XCTest
@testable import PulsePhoneHostPaths
@testable import PulsePhoneSharedDefinitions

final class VideoSourceMappingStoreTests: XCTestCase {
    private let firstSourceID = String(repeating: "a", count: 64)
    private let secondSourceID = String(repeating: "b", count: 64)

    func testRecordAndPathUseFrozenDomainsAndExcludeTransientIdentity() throws {
        let target = try canonicalTarget("00008110-001A7D523E90401E")
        let record = try VideoSourceMappingRecordV2(
            target: target,
            sourceID: firstSourceID,
            proofKind: .singleConnectedTargetSource
        )

        XCTAssertEqual(
            VideoSourceMappingPathV1.targetDomainID,
            "pulsephone.video-mapping-target.v1"
        )
        XCTAssertEqual(
            VideoSourceMappingPathV1.targetPathKey(for: target),
            "a9414cb0b2bd597385b34800d27ad34bcf5ef06fe255c4830ac6b89d9fc369f9"
        )
        XCTAssertEqual(
            VideoSourceMappingPathV1.fileName(for: target),
            "a9414cb0b2bd597385b34800d27ad34bcf5ef06fe255c4830ac6b89d9fc369f9.v1.json"
        )
        XCTAssertEqual(
            VideoSourceMappingPathV2.fileName(for: target),
            "a9414cb0b2bd597385b34800d27ad34bcf5ef06fe255c4830ac6b89d9fc369f9.v2.json"
        )
        XCTAssertEqual(
            String(decoding: record.canonicalBytes, as: UTF8.self),
            "{\"proofKind\":\"singleConnectedTargetSource.v1\",\"schemaVersion\":2,"
                + "\"sourceID\":\"\(firstSourceID)\","
                + "\"sourceIdentityDomain\":\"pulsephone.av-source.v1\","
                + "\"targetPathKey\":\"\(record.targetPathKey)\"}"
        )

        let text = String(decoding: record.canonicalBytes, as: UTF8.self)
        XCTAssertFalse(text.contains(target.rawValue))
        for forbidden in [
            "canonicalUDID", "uniqueID", "mappingProof", "sourceEpoch",
            "inventoryRevision", "connectionEpoch", "geometryRevision",
            "format", "width", "height", "orientation", "name", "index",
        ] {
            XCTAssertFalse(text.contains(forbidden), forbidden)
        }
    }

    func testReplaceLoadClearAndTargetIsolation() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.remove() }
        let firstTarget = try canonicalTarget("TARGET-A")
        let secondTarget = try canonicalTarget("TARGET-B")

        XCTAssertEqual(fixture.store.load(target: firstTarget), .missing)
        let firstRecord = try fixture.store.replace(
            target: firstTarget,
            sourceID: firstSourceID
        )
        let secondRecord = try fixture.store.replace(
            target: secondTarget,
            sourceID: secondSourceID
        )

        XCTAssertEqual(
            fixture.store.load(target: firstTarget),
            .mapped(.currentV2(firstRecord))
        )
        XCTAssertEqual(
            fixture.store.load(target: secondTarget),
            .mapped(.currentV2(secondRecord))
        )
        XCTAssertNotEqual(firstRecord.targetPathKey, secondRecord.targetPathKey)
        XCTAssertEqual(permissions(at: fixture.path(for: firstTarget)), 0o600)
        XCTAssertEqual(permissions(at: fixture.path(for: secondTarget)), 0o600)
        XCTAssertTrue(try fixture.store.clear(target: firstTarget))
        XCTAssertFalse(try fixture.store.clear(target: firstTarget))
        XCTAssertEqual(fixture.store.load(target: firstTarget), .missing)
        XCTAssertEqual(
            fixture.store.load(target: secondTarget),
            .mapped(.currentV2(secondRecord))
        )
    }

    func testCurrentRecordRoundTripsOptionalPortraitCanvasDimensions() throws {
        let target = try canonicalTarget("TARGET-CANVAS")
        let record = try VideoSourceMappingRecordV2(
            target: target,
            sourceID: firstSourceID,
            proofKind: .operatorConfirmedPreview,
            initialCanvasWidth: 1_170,
            initialCanvasHeight: 2_532
        )

        XCTAssertEqual(record.initialCanvasWidth, 1_170)
        XCTAssertEqual(record.initialCanvasHeight, 2_532)
        XCTAssertEqual(
            try VideoSourceMappingRecordV2.decode(record.canonicalBytes, target: target),
            record
        )
        let text = String(decoding: record.canonicalBytes, as: UTF8.self)
        XCTAssertTrue(text.contains("\"initialCanvasHeight\":2532"))
        XCTAssertTrue(text.contains("\"initialCanvasWidth\":1170"))
    }

    func testCurrentRecordRejectsPartialOrInvalidCanvasDimensions() throws {
        let target = try canonicalTarget("TARGET-CANVAS-INVALID")
        for dimensions: (UInt64?, UInt64?) in [
            (1_170, nil),
            (nil, 2_532),
            (0, 2_532),
            (2_532, 1_170),
            (1_170, 65_536),
        ] {
            XCTAssertThrowsError(try VideoSourceMappingRecordV2(
                target: target,
                sourceID: firstSourceID,
                proofKind: .operatorConfirmedPreview,
                initialCanvasWidth: dimensions.0,
                initialCanvasHeight: dimensions.1
            )) { error in
                XCTAssertEqual(
                    error as? VideoSourceMappingRecordError,
                    .invalidInitialCanvasDimensions
                )
            }
        }

        let base = try VideoSourceMappingRecordV2(
            target: target,
            sourceID: firstSourceID,
            proofKind: .operatorConfirmedPreview
        )
        let text = "{\"initialCanvasWidth\":1170,"
            + String(decoding: base.canonicalBytes.dropFirst(), as: UTF8.self)
        XCTAssertThrowsError(try VideoSourceMappingRecordV2.decode(
            Array(text.utf8),
            target: target
        )) { error in
            XCTAssertEqual(
                error as? VideoSourceMappingRecordError,
                .unexpectedFieldSet
            )
        }
    }

    func testLegacyRecordLoadsOnlyWhenCurrentRecordIsMissing() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.remove() }
        let target = try canonicalTarget("TARGET-LEGACY")
        XCTAssertEqual(fixture.store.load(target: target), .missing)
        let legacy = try VideoSourceMappingRecordV1(
            target: target,
            sourceID: firstSourceID
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: fixture.legacyPath(for: target),
            contents: Data(legacy.canonicalBytes)
        ))
        XCTAssertEqual(chmod(fixture.legacyPath(for: target), 0o600), 0)
        XCTAssertEqual(
            fixture.store.load(target: target),
            .mapped(.legacyV1(legacy))
        )

        XCTAssertTrue(FileManager.default.createFile(
            atPath: fixture.path(for: target),
            contents: Data("{}".utf8)
        ))
        XCTAssertEqual(chmod(fixture.path(for: target), 0o600), 0)
        XCTAssertEqual(
            fixture.store.load(target: target),
            .unavailable(.corruptRecord)
        )
        XCTAssertTrue(try fixture.store.clear(target: target))
        XCTAssertEqual(fixture.store.load(target: target), .missing)
    }

    func testCorruptVersionDomainAndTargetMismatchFailClosedAndCanBeReplaced() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.remove() }
        let target = try canonicalTarget("TARGET-C")
        let otherTarget = try canonicalTarget("TARGET-D")
        let record = try fixture.store.replace(target: target, sourceID: firstSourceID)
        let path = fixture.path(for: target)

        try overwrite(path: path, bytes: Array("{}".utf8))
        XCTAssertEqual(fixture.store.load(target: target), .unavailable(.corruptRecord))

        var bytes = record.canonicalBytes
        bytes = replacing(
            bytes,
            from: "\"schemaVersion\":2",
            to: "\"schemaVersion\":3"
        )
        try overwrite(path: path, bytes: bytes)
        XCTAssertEqual(fixture.store.load(target: target), .unavailable(.corruptRecord))

        bytes = replacing(
            record.canonicalBytes,
            from: "pulsephone.av-source.v1",
            to: "pulsephone.av-source.v2"
        )
        try overwrite(path: path, bytes: bytes)
        XCTAssertEqual(fixture.store.load(target: target), .unavailable(.corruptRecord))

        let otherRecord = try VideoSourceMappingRecordV2(
            target: otherTarget,
            sourceID: firstSourceID,
            proofKind: .operatorConfirmedPreview
        )
        try overwrite(path: path, bytes: otherRecord.canonicalBytes)
        XCTAssertEqual(fixture.store.load(target: target), .unavailable(.corruptRecord))

        let replacement = try fixture.store.replace(
            target: target,
            sourceID: secondSourceID
        )
        XCTAssertEqual(
            fixture.store.load(target: target),
            .mapped(.currentV2(replacement))
        )
    }

    func testForeignModeHardLinkAndSymbolicLinkAreNeverRepaired() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.remove() }
        let target = try canonicalTarget("TARGET-E")
        let path = fixture.path(for: target)

        try fixture.store.replace(target: target, sourceID: firstSourceID)
        XCTAssertEqual(chmod(path, 0o644), 0)
        XCTAssertEqual(fixture.store.load(target: target), .unavailable(.unsafeHostState))
        XCTAssertThrowsError(
            try fixture.store.replace(target: target, sourceID: secondSourceID)
        ) { error in
            XCTAssertEqual(error as? VideoSourceMappingStoreFailure, .unsafeHostState)
        }
        XCTAssertEqual(permissions(at: path), 0o644)

        XCTAssertEqual(chmod(path, 0o600), 0)
        let hardLink = fixture.mappingsDirectory + "/foreign-hard-link"
        XCTAssertEqual(link(path, hardLink), 0)
        XCTAssertEqual(fixture.store.load(target: target), .unavailable(.unsafeHostState))
        XCTAssertThrowsError(try fixture.store.clear(target: target)) { error in
            XCTAssertEqual(error as? VideoSourceMappingStoreFailure, .unsafeHostState)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: hardLink))

        XCTAssertEqual(unlink(hardLink), 0)
        XCTAssertTrue(try fixture.store.clear(target: target))
        let foreignTarget = fixture.mappingsDirectory + "/foreign-target"
        XCTAssertTrue(FileManager.default.createFile(
            atPath: foreignTarget,
            contents: Data("foreign".utf8)
        ))
        XCTAssertEqual(chmod(foreignTarget, 0o600), 0)
        XCTAssertEqual(symlink(foreignTarget, path), 0)
        XCTAssertEqual(fixture.store.load(target: target), .unavailable(.unsafeHostState))
        XCTAssertThrowsError(
            try fixture.store.replace(target: target, sourceID: secondSourceID)
        ) { error in
            XCTAssertEqual(error as? VideoSourceMappingStoreFailure, .unsafeHostState)
        }
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: path), foreignTarget)
    }

    func testRecordCapacityIsBoundedAndExistingTargetCanStillBeReplaced() throws {
        let fixture = try makeStoreFixture()
        defer { fixture.remove() }

        for index in 0..<ProductionVideoSourceMappingStore.maximumRecordCount {
            let target = try canonicalTarget(String(format: "TARGET-%03d", index))
            let sourceID = String(format: "%064llx", UInt64(index + 1))
            try fixture.store.replace(target: target, sourceID: sourceID)
        }

        let overflow = try canonicalTarget("TARGET-OVERFLOW")
        XCTAssertThrowsError(
            try fixture.store.replace(target: overflow, sourceID: firstSourceID)
        ) { error in
            XCTAssertEqual(error as? VideoSourceMappingStoreFailure, .capacityExceeded)
        }

        let existing = try canonicalTarget("TARGET-000")
        let replacement = try fixture.store.replace(
            target: existing,
            sourceID: secondSourceID
        )
        XCTAssertEqual(
            fixture.store.load(target: existing),
            .mapped(.currentV2(replacement))
        )
    }

    private func canonicalTarget(_ value: String) throws -> CanonicalUDID {
        try CanonicalUDID(canonicalString: value)
    }

    private func replacing(
        _ bytes: [UInt8],
        from oldValue: String,
        to newValue: String
    ) -> [UInt8] {
        let text = String(decoding: bytes, as: UTF8.self)
        XCTAssertTrue(text.contains(oldValue))
        return Array(text.replacingOccurrences(of: oldValue, with: newValue).utf8)
    }

    private func overwrite(path: String, bytes: [UInt8]) throws {
        let descriptor = open(path, O_WRONLY | O_TRUNC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw POSIXError(.EIO) }
        defer { _ = close(descriptor) }
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { rawBuffer in
                write(
                    descriptor,
                    rawBuffer.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
            }
            if count > 0 {
                offset += count
            } else if count == -1, errno == EINTR {
                continue
            } else {
                throw POSIXError(.EIO)
            }
        }
        guard fsync(descriptor) == 0 else { throw POSIXError(.EIO) }
    }

    private func makeStoreFixture() throws -> StoreFixture {
        let template = "/private/tmp/pulsephone-video-mapping.XXXXXX"
        var bytes = Array(template.utf8CString)
        guard let result = mkdtemp(&bytes) else { throw POSIXError(.EIO) }
        let home = String(cString: result)
        XCTAssertEqual(chmod(home, 0o700), 0)
        XCTAssertEqual(mkdir(home + "/Library", 0o700), 0)
        XCTAssertEqual(mkdir(home + "/Library/Application Support", 0o700), 0)
        let layout = try HostPathLayoutV1(
            effectiveUserID: geteuid(),
            trustedHomeDirectory: home
        )
        return StoreFixture(
            home: home,
            layout: layout,
            store: ProductionVideoSourceMappingStore(hostPaths: layout)
        )
    }

    private func permissions(at path: String) -> mode_t {
        var status = stat()
        XCTAssertEqual(lstat(path, &status), 0)
        return status.st_mode & mode_t(0o7777)
    }
}

private struct StoreFixture {
    let home: String
    let layout: HostPathLayoutV1
    let store: ProductionVideoSourceMappingStore

    var mappingsDirectory: String { layout.videoSourceMappingsDirectory }

    func path(for target: CanonicalUDID) -> String {
        layout.videoSourceMappingPath(for: target)
    }

    func legacyPath(for target: CanonicalUDID) -> String {
        layout.legacyVideoSourceMappingPath(for: target)
    }

    func remove() {
        try? FileManager.default.removeItem(atPath: home)
    }
}
