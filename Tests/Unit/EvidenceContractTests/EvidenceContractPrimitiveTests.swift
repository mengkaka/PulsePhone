import Darwin
import Foundation
import XCTest
@testable import PulsePhoneSharedDefinitions

final class EvidenceContractPrimitiveTests: XCTestCase {
    func testArtifactPathKeyIsDomainSeparatedAndOpaqueIDSafe() throws {
        let run = try ArtifactPathKeyV1(
            artifactDomain: .evidenceRunPackage,
            opaqueID: "same-id"
        )
        let record = try ArtifactPathKeyV1(
            artifactDomain: .evidenceStoreRecord,
            opaqueID: "same-id"
        )
        XCTAssertEqual(try run.pathKey.utf8.count, 64)
        XCTAssertNotEqual(try run.pathKey, try record.pathKey)
        XCTAssertThrowsError(
            try ArtifactPathKeyV1(
                artifactDomain: .evidenceRunPackage,
                opaqueID: "../escape"
            )
        )
        XCTAssertThrowsError(
            try ArtifactPathKeyV1(
                artifactDomain: .evidenceRunPackage,
                opaqueID: "https://example.invalid"
            )
        )
    }

    func testRepositoryArtifactSetCanonicalHashAndOrdering() throws {
        let entries = try [
            RepositoryContractArtifactSetV1.Entry(
                relativePath: "a.json",
                sha256: String(repeating: "0", count: 64)
            ),
            RepositoryContractArtifactSetV1.Entry(
                relativePath: "b.json",
                sha256: String(repeating: "1", count: 64)
            ),
        ]
        let set = try RepositoryContractArtifactSetV1(
            setID: "testSet",
            revision: "test.v1",
            entries: entries
        )
        XCTAssertEqual(set.schemaVersion, 1)
        XCTAssertEqual(set.sha256Hex.utf8.count, 64)
        XCTAssertEqual(
            try set.domainSeparatedHash(domainID: "pulsephone.test-set.v1").utf8.count,
            64
        )
        XCTAssertThrowsError(
            try RepositoryContractArtifactSetV1(
                setID: "testSet",
                revision: "test.v1",
                entries: Array(entries.reversed())
            )
        )
    }

    func testRepositoryContractResolverRejectsMissingSymlinkAndHardlink() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("a.json")
        let second = root.appendingPathComponent("b.json")
        try Data("{\"schemaVersion\":1}".utf8).write(to: first)
        try Data("{\"schemaVersion\":1}".utf8).write(to: second)

        let resolved = try RepositoryContractResolver.resolve(
            repositoryRoot: root,
            setID: "testSet",
            revision: "test.v1",
            relativePaths: ["a.json", "b.json"]
        )
        XCTAssertEqual(resolved.entries.count, 2)

        XCTAssertThrowsError(
            try RepositoryContractResolver.resolve(
                repositoryRoot: root,
                setID: "testSet",
                revision: "test.v1",
                relativePaths: ["missing.json"]
            )
        )

        let symlinkPath = root.appendingPathComponent("link.json")
        XCTAssertEqual(symlink(first.path, symlinkPath.path), 0)
        XCTAssertThrowsError(
            try RepositoryContractResolver.resolve(
                repositoryRoot: root,
                setID: "testSet",
                revision: "test.v1",
                relativePaths: ["link.json"]
            )
        )

        let hardlinkPath = root.appendingPathComponent("hard.json")
        XCTAssertEqual(link(first.path, hardlinkPath.path), 0)
        XCTAssertThrowsError(
            try RepositoryContractResolver.resolve(
                repositoryRoot: root,
                setID: "testSet",
                revision: "test.v1",
                relativePaths: ["a.json", "hard.json"]
            )
        )
    }

    func testAllHardCapBoundaries() {
        let maxima = [
            EvidenceContractHardCaps.normalizedRelativePathBytes,
            EvidenceContractHardCaps.sourcePoliciesPerGate,
            EvidenceContractHardCaps.identityFieldsPerGatePolicy,
            EvidenceContractHardCaps.inputSlotsPerGatePolicy,
            EvidenceContractHardCaps.checksPerGatePolicy,
            EvidenceContractHardCaps.allowedPathRulesPerGatePolicy,
            EvidenceContractHardCaps.sourceSnapshotEntries,
            EvidenceContractHardCaps.artifactsPerGateInputSlot,
            EvidenceContractHardCaps.reasonCodesPerGateResult,
            EvidenceContractHardCaps.appBundleEntries,
            EvidenceContractHardCaps.releaseGateRequirements,
            EvidenceContractHardCaps.evidenceSelectionScenarios,
            EvidenceContractHardCaps.lineageSelectedEvidenceRuns,
            EvidenceContractHardCaps.releaseHoldSetEntries,
            EvidenceContractHardCaps.appBundleContentManifestBytes,
            EvidenceContractHardCaps.otherCanonicalDocumentBytes,
        ]
        for maximum in maxima {
            XCTAssertTrue(
                EvidenceContractHardCaps.accepts(count: maximum - 1, maximum: maximum)
            )
            XCTAssertTrue(
                EvidenceContractHardCaps.accepts(count: maximum, maximum: maximum)
            )
            XCTAssertFalse(
                EvidenceContractHardCaps.accepts(count: maximum + 1, maximum: maximum)
            )
        }
        XCTAssertFalse(
            EvidenceContractHardCaps.acceptsExact(
                count: EvidenceContractHardCaps.implementationGateDefinitionCount - 1,
                expected: EvidenceContractHardCaps.implementationGateDefinitionCount
            )
        )
        XCTAssertTrue(
            EvidenceContractHardCaps.acceptsExact(
                count: EvidenceContractHardCaps.implementationGateDefinitionCount,
                expected: EvidenceContractHardCaps.implementationGateDefinitionCount
            )
        )
        XCTAssertFalse(
            EvidenceContractHardCaps.acceptsExact(
                count: EvidenceContractHardCaps.implementationGateDefinitionCount + 1,
                expected: EvidenceContractHardCaps.implementationGateDefinitionCount
            )
        )
    }

    func testOutcomeAndSourceSnapshotZeroWriteCombinations() throws {
        XCTAssertEqual(EvidenceOutcomeV1.aggregate([.passed, .passed]), .passed)
        XCTAssertEqual(EvidenceOutcomeV1.aggregate([.passed, .unknown]), .unknown)
        XCTAssertEqual(EvidenceOutcomeV1.aggregate([.unknown, .failed]), .failed)
        _ = try RepositorySourceSnapshotShapeV1(
            worktreeState: .clean,
            entryCount: 0
        )
        _ = try RepositorySourceSnapshotShapeV1(
            worktreeState: .taskOwnedDirty,
            entryCount: 1
        )
        XCTAssertThrowsError(
            try RepositorySourceSnapshotShapeV1(
                worktreeState: .clean,
                entryCount: 1
            )
        )
        XCTAssertThrowsError(
            try RepositorySourceSnapshotShapeV1(
                worktreeState: .taskOwnedDirty,
                entryCount: 0
            )
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        var template = Array("/private/tmp/pulsephone-contract.XXXXXX".utf8CString)
        guard let path = mkdtemp(&template) else {
            throw POSIXError(.EIO)
        }
        return URL(fileURLWithPath: String(cString: path), isDirectory: true)
    }
}
