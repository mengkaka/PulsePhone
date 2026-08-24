import Darwin
import Foundation
import PulsePhoneDeveloperImageAssets
import PulsePhoneDeveloperSupportDefinitions
import PulsePhoneSharedDefinitions
import XCTest

final class DeveloperImageAssetStoreTests: XCTestCase {
  func testPreparationRehydrationEligibilityRequiresExactCanonicalReceipt()
    throws
  {
    let store = try makeStore()
    let receipt = DeveloperSupportRehydrationEligibilityReceipt(
      buildVersion: "23F84",
      preparationGroupID: "prep.coredevice.v2",
      productType: "iPhone14,7",
      productVersion: "26.5.2",
      targetIdentityHash: String(repeating: "a", count: 64)
    )

    try store.recordPreparationRehydrationEligibility(receipt)
    XCTAssertTrue(try store.hasPreparationRehydrationEligibility(receipt))

    let mismatchedBuild = DeveloperSupportRehydrationEligibilityReceipt(
      buildVersion: "23F85",
      preparationGroupID: receipt.preparationGroupID,
      productType: receipt.productType,
      productVersion: receipt.productVersion,
      targetIdentityHash: receipt.targetIdentityHash
    )
    XCTAssertFalse(
      try store.hasPreparationRehydrationEligibility(mismatchedBuild)
    )

    let receiptPath = store.rootURL.appendingPathComponent(
      "state/preparation-rehydration/\(receipt.targetIdentityHash).v1.json"
    )
    try Data("not-canonical-json".utf8).write(to: receiptPath)
    XCTAssertFalse(try store.hasPreparationRehydrationEligibility(receipt))
  }

  func testPreparationRehydrationEligibilityRejectsInvalidReceipt() throws {
    let store = try makeStore()
    let receipt = DeveloperSupportRehydrationEligibilityReceipt(
      buildVersion: "23F84\n",
      preparationGroupID: "prep.coredevice.v2",
      productType: "iPhone14,7",
      productVersion: "26.5.2",
      targetIdentityHash: String(repeating: "a", count: 64)
    )

    XCTAssertThrowsError(
      try store.recordPreparationRehydrationEligibility(receipt)
    ) { error in
      XCTAssertEqual(
        error as? DeveloperImageAssetStoreError,
        .invalidPreparationRehydrationEligibility
      )
    }
  }

  func testAssetContentIdentityAndCrossEntryDeduplication() throws {
    let fixture = try requirementFixture("T-019/asset-content-identity-matrix-l0")
    let expected = try fixture.decodeExpected(CommonExpected.self)
    XCTAssertEqual(expected.outcome, "passed")

    let image = Data("image-v1".utf8)
    let signature = Data("signature-v1".utf8)
    let first = EntrySpec(
      archiveSHA256: String(repeating: "a", count: 64),
      entryID: "classic.first",
      image: image,
      signature: signature
    )
    let second = EntrySpec(
      archiveSHA256: String(repeating: "b", count: 64),
      entryID: "classic.second",
      image: image,
      signature: signature,
      sourceURL: "https://approved.example.invalid/second.zip"
    )
    let catalog = try makeCatalog(revision: "asset-identity.v1", entries: [first, second])
    let store = try makeStore()

    let firstPublished = try store.publish(
      catalog: catalog,
      entryID: first.entryID,
      archiveEntries: first.archiveEntries
    )
    let secondPublished = try store.publish(
      catalog: catalog,
      entryID: second.entryID,
      archiveEntries: [
        DeveloperImageArchiveEntry(
          path: "DeveloperDiskImage.dmg",
          kind: .regularFile,
          bytes: Data("different archive bytes".utf8)
        )
      ]
    )

    XCTAssertEqual(firstPublished.assetKey, secondPublished.assetKey)
    XCTAssertEqual(
      firstPublished.roleRelativePaths["classic.image"],
      "assets/\(firstPublished.assetKey)/roles/classic.image"
    )
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        atPath: store.rootURL.appendingPathComponent("assets").path
      ).filter { !$0.hasPrefix(".") },
      [firstPublished.assetKey]
    )
    let lease = try XCTUnwrap(store.openVerifiedAsset(catalog: catalog, entryID: second.entryID))
    XCTAssertEqual(lease.roleFiles["classic.image"]?.size, UInt64(image.count))
    XCTAssertEqual(expected.expectedAssetCount, 1)
  }

  func testStoreRootSecurityAndAccounting() throws {
    let fixture = try requirementFixture("T-019/store-root-security-accounting-l2")
    let expected = try fixture.decodeExpected(CommonExpected.self)
    let image = Data("root-image".utf8)
    let signature = Data("root-signature".utf8)
    let entry = EntrySpec(entryID: "classic.root", image: image, signature: signature)
    let catalog = try makeCatalog(revision: "root-security.v1", entries: [entry])
    let rootParent = try temporaryDirectory()
    let storeRoot = rootParent.appendingPathComponent("DeveloperImages")
    let limits = DeveloperImageAssetStoreLimits(
      softTargetBytes: 1_000_000,
      hardCapBytes: 2_000_000,
      maximumCatalogBytes: 1_000_000,
      maximumCatalogCount: 1,
      maximumCatalogTotalBytes: 1_000_000
    )
    let store = try DeveloperImageAssetStore(rootURL: storeRoot, limits: limits)
    let published = try store.publish(
      catalog: catalog,
      entryID: entry.entryID,
      archiveEntries: entry.archiveEntries
    )
    let accounting = try store.accounting()
    XCTAssertGreaterThan(accounting.assetBytes, 0)
    XCTAssertGreaterThan(accounting.catalogBytes, 0)
    XCTAssertEqual(accounting.totalBytes,
      accounting.assetBytes + accounting.catalogBytes
        + accounting.downloadBytes + accounting.metadataBytes)
    XCTAssertEqual(try mode(of: storeRoot.path), 0o700)
    XCTAssertEqual(try mode(of: storeRoot.appendingPathComponent("locks/asset-store.lock").path), 0o600)
    XCTAssertEqual(
      try store.rootURL.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
      true
    )

    let firstEntered = DispatchSemaphore(value: 0)
    let releaseFirst = DispatchSemaphore(value: 0)
    let secondEntered = DispatchSemaphore(value: 0)
    let bothDone = DispatchGroup()
    let errors = LockedErrors()
    let secondStore = try DeveloperImageAssetStore(rootURL: storeRoot, limits: limits)
    bothDone.enter()
    DispatchQueue.global().async {
      defer { bothDone.leave() }
      do {
        try store.withAcquisitionOwnership(assetKey: published.assetKey) {
          firstEntered.signal()
          releaseFirst.wait()
        }
      } catch {
        errors.append(error)
      }
    }
    XCTAssertEqual(firstEntered.wait(timeout: .now() + 1), .success)
    bothDone.enter()
    DispatchQueue.global().async {
      defer { bothDone.leave() }
      do {
        _ = try secondStore.withAcquisitionOwnership(assetKey: published.assetKey) {
          secondEntered.signal()
        }
      } catch {
        errors.append(error)
      }
    }
    XCTAssertEqual(secondEntered.wait(timeout: .now() + 0.05), .timedOut)
    releaseFirst.signal()
    XCTAssertEqual(secondEntered.wait(timeout: .now() + 1), .success)
    XCTAssertEqual(bothDone.wait(timeout: .now() + 1), .success)
    XCTAssertTrue(errors.values.isEmpty)

    let rogueCatalog = storeRoot.appendingPathComponent("catalogs/rogue.json")
    try Data("{}".utf8).write(to: rogueCatalog)
    chmod(rogueCatalog.path, 0o600)
    XCTAssertThrowsError(
      try store.openVerifiedAsset(catalog: catalog, entryID: entry.entryID)
    ) { error in
      XCTAssertEqual(error as? DeveloperImageAssetStoreError, .capacityExceeded)
    }
    try FileManager.default.removeItem(at: rogueCatalog)

    let secondCatalog = try makeCatalog(revision: "root-security.v2", entries: [entry])
    XCTAssertThrowsError(
      try store.openVerifiedAsset(catalog: secondCatalog, entryID: entry.entryID)
    ) { error in
      XCTAssertEqual(error as? DeveloperImageAssetStoreError, .capacityExceeded)
    }

    let symlinkRoot = rootParent.appendingPathComponent("SymlinkStore")
    try FileManager.default.createSymbolicLink(at: symlinkRoot, withDestinationURL: storeRoot)
    XCTAssertThrowsError(try DeveloperImageAssetStore(rootURL: symlinkRoot))

    let external = rootParent.appendingPathComponent("external-index.json")
    try Data("external".utf8).write(to: external)
    chmod(external.path, 0o600)
    let index = storeRoot.appendingPathComponent("state/cache-index.v1.json")
    try FileManager.default.removeItem(at: index)
    try FileManager.default.createSymbolicLink(at: index, withDestinationURL: external)
    XCTAssertThrowsError(try store.rebuildIndex())
    XCTAssertEqual(try Data(contentsOf: external), Data("external".utf8))
    XCTAssertEqual(expected.rootDirectoryMode, "0700")
    XCTAssertEqual(expected.fileMode, "0600")
  }

  func testCapacityPruneBoundaryAndStableLRU() throws {
    let fixture = try requirementFixture("T-019/cache-capacity-prune-boundary-l2")
    let expected = try fixture.decodeExpected(CommonExpected.self)
    let entries = [
      EntrySpec(entryID: "classic.a", image: Data("asset-a".utf8), signature: Data("sig-a".utf8)),
      EntrySpec(entryID: "classic.b", image: Data("asset-b".utf8), signature: Data("sig-b".utf8)),
      EntrySpec(entryID: "classic.c", image: Data("asset-c".utf8), signature: Data("sig-c".utf8)),
    ]
    let catalog = try makeCatalog(revision: "prune.v1", entries: entries)
    let store = try makeStore()
    var keys: [String] = []
    for entry in entries {
      keys.append(try store.publish(
        catalog: catalog,
        entryID: entry.entryID,
        archiveEntries: entry.archiveEntries
      ).assetKey)
    }
    try store.setAccessRecency(assetKey: keys[0], monotonicNs: nil)
    try store.setAccessRecency(assetKey: keys[1], monotonicNs: 20)
    try store.setAccessRecency(assetKey: keys[2], monotonicNs: 10)

    let busyLease = try XCTUnwrap(store.openVerifiedAsset(catalog: catalog, entryID: entries[0].entryID))
    let removed = try store.prune(
      to: 0,
      activeAssetKeys: [],
      requiredAssetKeys: [keys[2]]
    )
    XCTAssertFalse(removed.contains(keys[0]), "shared-lock consumer must be skipped")
    XCTAssertTrue(removed.contains(keys[1]))
    XCTAssertFalse(removed.contains(keys[2]))
    XCTAssertNotNil(busyLease.roleFiles["classic.image"])

    let indexPath = store.rootURL.appendingPathComponent("state/cache-index.v1.json")
    try Data("{".utf8).write(to: indexPath)
    chmod(indexPath.path, 0o600)
    let rebuilt = try store.rebuildIndex()
    XCTAssertEqual(rebuilt.evictionOrder, [keys[0], keys[2]].sorted())
    XCTAssertEqual(expected.unknownRecencyFirst, true)
    XCTAssertEqual(expected.hardCapRejectsBeforePublish, true)
  }

  func testCanonicalRolePublishRejectsFaults() throws {
    let fixture = try requirementFixture("T-019/canonical-role-publish-fault-l2")
    let expected = try fixture.decodeExpected(CommonExpected.self)
    let entry = EntrySpec(
      entryID: "classic.role-fault",
      image: Data("role-image".utf8),
      signature: Data("role-signature".utf8)
    )
    let catalog = try makeCatalog(revision: "role-fault.v1", entries: [entry])
    let store = try makeStore()
    let assetKey = try catalog.entries[0].assetManifest.assetKey

    var wrong = entry.archiveEntries
    wrong[0] = DeveloperImageArchiveEntry(
      path: wrong[0].path,
      kind: .regularFile,
      bytes: Data("wrong".utf8)
    )
    XCTAssertThrowsError(try store.publish(
      catalog: catalog,
      entryID: entry.entryID,
      archiveEntries: wrong
    ))
    XCTAssertFalse(assetExists(store: store, assetKey: assetKey))

    let duplicate = entry.archiveEntries + [entry.archiveEntries[0]]
    XCTAssertThrowsError(try store.publish(
      catalog: catalog,
      entryID: entry.entryID,
      archiveEntries: duplicate
    ))
    XCTAssertFalse(assetExists(store: store, assetKey: assetKey))
    XCTAssertEqual(expected.canonicalRoleCount, 2)
    XCTAssertEqual(expected.partialPublishVisible, false)
  }

  func testSafeExtractionAndAtomicPublishFaults() throws {
    let fixture = try requirementFixture("T-019/safe-extraction-atomic-publish-fault-l2")
    let expected = try fixture.decodeExpected(CommonExpected.self)
    let retained = EntrySpec(
      entryID: "classic.retained",
      image: Data("retained-image".utf8),
      signature: Data("retained-signature".utf8)
    )
    let failing = EntrySpec(
      entryID: "classic.failing",
      image: Data("failing-image".utf8),
      signature: Data("failing-signature".utf8)
    )
    let catalog = try makeCatalog(revision: "extract-fault.v1", entries: [failing, retained])
    let store = try makeStore()
    let retainedAsset = try store.publish(
      catalog: catalog,
      entryID: retained.entryID,
      archiveEntries: retained.archiveEntries
    )
    let failingKey = try catalog.entries.first(where: { $0.entryID == failing.entryID })!.assetManifest.assetKey

    for kind in [
      DeveloperImageArchiveEntryKind.symbolicLink,
      .hardLink,
      .blockDevice,
      .characterDevice,
      .directory,
    ] {
      var unsafe = failing.archiveEntries
      unsafe[0] = DeveloperImageArchiveEntry(path: unsafe[0].path, kind: kind)
      XCTAssertThrowsError(try store.publish(
        catalog: catalog,
        entryID: failing.entryID,
        archiveEntries: unsafe
      ))
      XCTAssertFalse(assetExists(store: store, assetKey: failingKey))
    }
    for path in ["/absolute.dmg", "../escape.dmg", "nested/../escape.dmg"] {
      var unsafe = failing.archiveEntries
      unsafe[0] = DeveloperImageArchiveEntry(path: path, kind: .regularFile, bytes: failing.image)
      XCTAssertThrowsError(try store.publish(
        catalog: catalog,
        entryID: failing.entryID,
        archiveEntries: unsafe
      ))
    }
    for fault in [
      DeveloperImagePublishFault.afterFirstRoleFsync,
      .beforeAtomicRename,
    ] {
      XCTAssertThrowsError(try store.publish(
        catalog: catalog,
        entryID: failing.entryID,
        archiveEntries: failing.archiveEntries,
        fault: fault
      ))
      XCTAssertFalse(assetExists(store: store, assetKey: failingKey))
    }
    XCTAssertTrue(assetExists(store: store, assetKey: retainedAsset.assetKey))
    let tempNames = try FileManager.default.contentsOfDirectory(
      atPath: store.rootURL.appendingPathComponent("assets").path
    ).filter { $0.hasPrefix(".") }
    XCTAssertTrue(tempNames.isEmpty)
    XCTAssertEqual(expected.rejectedNodeKinds?.sorted(), [
      "blockDevice", "characterDevice", "directory", "hardLink", "symbolicLink",
    ])
  }

  func testPartialStateIsArchiveBoundAndRequiresStrongETag() throws {
    let image = Data("partial-image".utf8)
    let signature = Data("partial-signature".utf8)
    let entry = EntrySpec(entryID: "classic.partial-a", image: image, signature: signature)
    let second = EntrySpec(
      archiveSHA256: String(repeating: "f", count: 64),
      entryID: "classic.partial-b",
      image: image,
      signature: signature
    )
    let catalog = try makeCatalog(revision: "partial.v1", entries: [entry, second])
    let store = try makeStore()
    let catalogIdentity = try store.createOrValidateCatalog(catalog)
    let catalogEntry = catalog.entries[0]
    let assetKey = try catalogEntry.assetManifest.assetKey
    let partial = Data("partial".utf8)
    let state = try makePartialState(
      assetKey: assetKey,
      bytes: partial,
      catalogIdentity: catalogIdentity,
      entry: catalogEntry,
      strongETag: "\"etag-v1\""
    )
    try store.persistPartial(state: state, bytes: partial)
    XCTAssertEqual(
      try store.adoptPartial(catalog: catalog, entryID: entry.entryID, sourceIndex: 0),
      .adopted(state)
    )

    XCTAssertEqual(
      try store.adoptPartial(catalog: catalog, entryID: second.entryID, sourceIndex: 0),
      .discarded
    )

    var ledger = DeveloperImageRemoteAttemptLedger()
    let initial = try XCTUnwrap(ledger.nextRequest(entry: catalogEntry, resumableState: nil))
    XCTAssertEqual(initial.mode, .initial)
    let resume = try XCTUnwrap(ledger.nextRequest(entry: catalogEntry, resumableState: state))
    XCTAssertEqual(resume.mode, .resume)
    XCTAssertEqual(resume.offset, UInt64(partial.count))
    var validator = try DeveloperImageRemoteTransferValidator(
      archiveSize: UInt64(partial.count + 4),
      request: resume,
      response: DeveloperImageRemoteResponseHead(
        contentLength: 4,
        contentRangeStart: UInt64(partial.count),
        statusCode: 206,
        strongETag: "\"etag-v1\""
      )
    )
    try validator.acceptChunk(byteCount: 4)
    try validator.requireComplete()
    XCTAssertThrowsError(try validator.acceptChunk(byteCount: 1_048_577))
  }

  func testSourceResolutionOrderAndGuards() throws {
    let sourceFixture = try requirementFixture("T-021/source-resolution-matrix-l4")
    let sourceExpected = try sourceFixture.decodeExpected(SourceExpected.self)
    let noExtractionFixture = try requirementFixture("T-021/no-device-extraction-l4")
    let noExtractionExpected = try noExtractionFixture.decodeExpected(SourceExpected.self)
    let classicFixture = try requirementFixture("T-005/legacy-classic-source-cache-offline-matrix-l4")
    XCTAssertEqual(try classicFixture.decodeExpected(SourceExpected.self).outcome, "deferredPhysicalEvidence")

    let spec = EntrySpec(
      entryID: "classic.source",
      image: Data("source-image".utf8),
      signature: Data("source-signature".utf8)
    )
    let entry = try makeCatalog(revision: "source.v1", entries: [spec]).entries[0]
    let xcode = makeXcodeSnapshot(entry: entry)
    XCTAssertEqual(try resolve(entry, mounted: true, cache: true, xcode: xcode, online: true).kind,
      .alreadyMounted)
    XCTAssertEqual(try resolve(entry, mounted: false, cache: true, xcode: xcode, online: true).kind,
      .verifiedCache)
    XCTAssertEqual(try resolve(entry, mounted: false, cache: false, xcode: xcode, online: true).kind,
      .selectedReleaseXcode)
    XCTAssertEqual(try resolve(entry, mounted: false, cache: false, xcode: nil, online: true).kind,
      .approvedRemote)
    XCTAssertEqual(try resolve(entry, mounted: false, cache: false, xcode: nil, online: false).kind,
      .typedUnavailable)

    let beta = SelectedXcodeSnapshot(
      appPath: "/Applications/Xcode-beta.app",
      bundleIdentifier: "com.apple.dt.Xcode",
      developerPath: "/Applications/Xcode-beta.app/Contents/Developer",
      gatekeeperAccepted: true,
      licenseType: "Beta",
      pairs: xcode.pairs,
      signatureValid: true
    )
    XCTAssertEqual(try resolve(entry, mounted: false, cache: false, xcode: beta, online: false).kind,
      .typedUnavailable)
    XCTAssertEqual(sourceExpected.sourceOrder, PulsePhoneDeveloperImageAssetsModule.sourceOrder.map(\.rawValue))
    XCTAssertFalse(PulsePhoneDeveloperImageAssetsModule.permitsDeviceExtraction)
    XCTAssertEqual(noExtractionExpected.deviceExtractionPermitted, false)
  }

  func testSelectedXcodeRolesPublishAsVerifiedAsset() throws {
    let image = Data("selected-xcode-image".utf8)
    let signature = Data("selected-xcode-signature".utf8)
    let spec = EntrySpec(
      entryID: "classic.selected-xcode",
      image: image,
      signature: signature
    )
    let catalog = try makeCatalog(revision: "selected-xcode.v1", entries: [spec])
    let entry = try XCTUnwrap(catalog.entries.first)
    let root = try temporaryDirectory()
    let app = root.appendingPathComponent("Xcode.app", isDirectory: true)
    let developer = app.appendingPathComponent("Contents/Developer", isDirectory: true)
    let support = developer.appendingPathComponent(
      "Platforms/iPhoneOS.platform/DeviceSupport/\(entry.ddiVersion)",
      isDirectory: true
    )
    try FileManager.default.createDirectory(
      at: support,
      withIntermediateDirectories: true
    )
    let imageURL = support.appendingPathComponent("DeveloperDiskImage.dmg")
    let signatureURL = support.appendingPathComponent("DeveloperDiskImage.dmg.signature")
    try image.write(to: imageURL)
    try signature.write(to: signatureURL)
    chmod(imageURL.path, 0o644)
    chmod(signatureURL.path, 0o644)
    let snapshot = SelectedXcodeSnapshot(
      appPath: app.path,
      bundleIdentifier: "com.apple.dt.Xcode",
      developerPath: developer.path,
      gatekeeperAccepted: true,
      licenseType: "GM",
      pairs: [SelectedXcodePair(
        buildID: entry.buildID,
        ddiVersion: entry.ddiVersion,
        roleFiles: [
          "classic.image": SelectedXcodeRoleFile(
            path: imageURL.path,
            sha256: StableBytes.sha256Hex(image),
            size: UInt64(image.count)
          ),
          "classic.signature": SelectedXcodeRoleFile(
            path: signatureURL.path,
            sha256: StableBytes.sha256Hex(signature),
            size: UInt64(signature.count)
          ),
        ]
      )],
      signatureValid: true
    )
    let store = try DeveloperImageAssetStore(
      rootURL: root.appendingPathComponent("DeveloperImages", isDirectory: true)
    )

    let published = try XCTUnwrap(store.publishSelectedXcode(
      catalog: catalog,
      entryID: entry.entryID,
      snapshot: snapshot
    ))
    let lease = try XCTUnwrap(store.openVerifiedAsset(
      catalog: catalog,
      entryID: entry.entryID
    ))
    XCTAssertEqual(lease.assetKey, published.assetKey)
    XCTAssertEqual(lease.roleFiles["classic.image"]?.size, UInt64(image.count))

    let linkedImageURL = root.appendingPathComponent("linked-image")
    try image.write(to: linkedImageURL)
    try FileManager.default.removeItem(at: imageURL)
    XCTAssertEqual(link(linkedImageURL.path, imageURL.path), 0)
    XCTAssertThrowsError(try store.publishSelectedXcode(
      catalog: catalog,
      entryID: entry.entryID,
      snapshot: snapshot
    )) { error in
      XCTAssertEqual(
        error as? DeveloperImageAssetStoreError,
        .unsafeNode(imageURL.path)
      )
    }

    let rejected = SelectedXcodeSnapshot(
      appPath: app.path,
      bundleIdentifier: "com.apple.dt.Xcode",
      developerPath: developer.path,
      gatekeeperAccepted: false,
      licenseType: "GM",
      pairs: snapshot.pairs,
      signatureValid: true
    )
    XCTAssertNil(try store.publishSelectedXcode(
      catalog: catalog,
      entryID: entry.entryID,
      snapshot: rejected
    ))
  }

  private struct CommonExpected: Decodable {
    let canonicalRoleCount: Int?
    let expectedAssetCount: Int?
    let fileMode: String?
    let hardCapRejectsBeforePublish: Bool?
    let outcome: String
    let partialPublishVisible: Bool?
    let rejectedNodeKinds: [String]?
    let rootDirectoryMode: String?
    let unknownRecencyFirst: Bool?
  }

  private struct SourceExpected: Decodable {
    let deviceExtractionPermitted: Bool?
    let outcome: String
    let sourceOrder: [String]?
  }

  private struct EntrySpec {
    let archiveSHA256: String
    let entryID: String
    let image: Data
    let signature: Data
    let sourceURL: String

    init(
      archiveSHA256: String = String(repeating: "a", count: 64),
      entryID: String,
      image: Data,
      signature: Data,
      sourceURL: String = "https://approved.example.invalid/developer-image.zip"
    ) {
      self.archiveSHA256 = archiveSHA256
      self.entryID = entryID
      self.image = image
      self.signature = signature
      self.sourceURL = sourceURL
    }

    var archiveEntries: [DeveloperImageArchiveEntry] {
      [
        DeveloperImageArchiveEntry(
          path: "DeveloperDiskImage.dmg",
          kind: .regularFile,
          bytes: image
        ),
        DeveloperImageArchiveEntry(
          path: "DeveloperDiskImage.dmg.signature",
          kind: .regularFile,
          bytes: signature
        ),
      ]
    }
  }

  private func makeCatalog(
    revision: String,
    entries: [EntrySpec]
  ) throws -> DeveloperImageCatalogV1 {
    let entryObjects: [[String: Any]] = entries.sorted { $0.entryID < $1.entryID }.map { entry in
      [
        "archiveSHA256": entry.archiveSHA256,
        "archiveSize": entry.image.count + entry.signature.count,
        "buildID": "20H350",
        "compatibilityRuleID": "compat.preparation.legacy-developer.v2",
        "ddiVersion": "16.7",
        "deviceOSRange": [
          "exactBuilds": ["20H350"],
          "maximumMajorExclusive": 17,
          "minimumMajor": 16,
        ],
        "entryID": entry.entryID,
        "evidenceState": "target",
        "extractedUpperBound": entry.image.count + entry.signature.count,
        "files": [
          [
            "archiveRelativePath": "DeveloperDiskImage.dmg",
            "fileRole": "classic.image",
            "sha256": StableBytes.sha256Hex(entry.image),
            "size": entry.image.count,
          ],
          [
            "archiveRelativePath": "DeveloperDiskImage.dmg.signature",
            "fileRole": "classic.signature",
            "sha256": StableBytes.sha256Hex(entry.signature),
            "size": entry.signature.count,
          ],
        ],
        "imageKind": "classic",
        "requiredServices": ["com.apple.mobile.screenshotr"],
        "sourceURLs": [entry.sourceURL],
      ]
    }
    let object: [String: Any] = [
      "catalogRevision": revision,
      "entries": entryObjects,
      "schemaVersion": 1,
    ]
    let data = try canonicalJSONData(object)
    return try DeveloperImageCatalog.decodeCanonical([UInt8](data))
  }

  private func makePartialState(
    assetKey: String,
    bytes: Data,
    catalogIdentity: DeveloperImageCatalogIdentity,
    entry: DeveloperImageCatalogEntryV1,
    strongETag: String?
  ) throws -> PartialDownloadStateV1 {
    var object: [String: Any] = [
      "acquisitionAttemptID": "attempt.partial.v1",
      "archiveSHA256": entry.archiveSHA256,
      "archiveSize": entry.archiveSize,
      "assetKey": assetKey,
      "catalogEntryID": entry.entryID,
      "catalogRevision": catalogIdentity.revision,
      "developerImageCatalogHash": catalogIdentity.hash,
      "receivedBytes": bytes.count,
      "sourceIndex": 0,
      "sourceURLIdentityHash": try DeveloperImageSourcePolicy.sourceURLIdentityHash(entry.sourceURLs[0]),
    ]
    if let strongETag { object["strongETag"] = strongETag }
    let data = try canonicalJSONData(object)
    return try JSONDecoder().decode(PartialDownloadStateV1.self, from: data)
  }

  private func canonicalJSONData(_ object: Any) throws -> Data {
    let encoded = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
      .replacingOccurrences(of: "\\/", with: "/")
    return Data(text.utf8)
  }

  private func makeXcodeSnapshot(entry: DeveloperImageCatalogEntryV1) -> SelectedXcodeSnapshot {
    let app = "/Applications/Xcode.app"
    let developer = app + "/Contents/Developer"
    let base = developer + "/Platforms/iPhoneOS.platform/DeviceSupport/\(entry.ddiVersion)/"
    var roles: [String: SelectedXcodeRoleFile] = [:]
    for file in entry.files {
      let name = file.fileRole == "classic.image"
        ? "DeveloperDiskImage.dmg"
        : "DeveloperDiskImage.dmg.signature"
      roles[file.fileRole] = SelectedXcodeRoleFile(
        path: base + name,
        sha256: file.sha256,
        size: file.size
      )
    }
    return SelectedXcodeSnapshot(
      appPath: app,
      bundleIdentifier: "com.apple.dt.Xcode",
      developerPath: developer,
      gatekeeperAccepted: true,
      licenseType: "GM",
      pairs: [SelectedXcodePair(
        buildID: entry.buildID,
        ddiVersion: entry.ddiVersion,
        roleFiles: roles
      )],
      signatureValid: true
    )
  }

  private func resolve(
    _ entry: DeveloperImageCatalogEntryV1,
    mounted: Bool,
    cache: Bool,
    xcode: SelectedXcodeSnapshot?,
    online: Bool
  ) throws -> DeveloperImageSourceResolution {
    try DeveloperImageSourceResolver.resolve(
      entry: entry,
      alreadyMounted: mounted,
      verifiedCacheAvailable: cache,
      selectedXcode: xcode,
      networkAvailable: online
    )
  }

  private func requirementFixture(_ requirementID: String) throws -> FixtureCaseBundleV1 {
    try FixtureCaseLoaderV1.load(
      requirementID: requirementID,
      repositoryRoot: FixtureCaseLoaderV1.repositoryRoot(containing: #filePath)
    )
  }

  private func makeStore() throws -> DeveloperImageAssetStore {
    try DeveloperImageAssetStore(
      rootURL: try temporaryDirectory().appendingPathComponent("DeveloperImages")
    )
  }

  private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("pulsephone-asset-store-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    chmod(url.path, 0o700)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }

  private func assetExists(store: DeveloperImageAssetStore, assetKey: String) -> Bool {
    FileManager.default.fileExists(
      atPath: store.rootURL.appendingPathComponent("assets/\(assetKey)").path
    )
  }

  private func mode(of path: String) throws -> mode_t {
    var metadata = stat()
    guard lstat(path, &metadata) == 0 else {
      throw DeveloperImageAssetStoreError.systemCall(operation: "lstat-test", errno: errno)
    }
    return metadata.st_mode & 0o7777
  }
}

private final class LockedErrors: @unchecked Sendable {
  private let lock = NSLock()
  private var storage: [any Error] = []

  var values: [any Error] {
    lock.withLock { storage }
  }

  func append(_ error: any Error) {
    lock.withLock { storage.append(error) }
  }
}
