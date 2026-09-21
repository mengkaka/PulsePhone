import Darwin
import Dispatch
import Foundation
import PulsePhoneCLI
import PulsePhoneClientCore
import PulsePhoneCommandCatalog
import PulsePhoneDeveloperImageAssets
import PulsePhoneDeveloperSupportDefinitions
import PulsePhoneHostPaths
import PulsePhoneLogging
import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions
import PulsePhoneWire
import XCTest

@testable import PulsePhoneElement
@testable import PulsePhoneMedia
@testable import PulsePhoneRuntimeExecutable
@testable import PulsePhoneRuntimeKernel

final class ProductionRuntimeAssemblyTests: XCTestCase {
    func testDynamicPreparationMarksRuntimeCapabilitiesReady() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        context.setModernDeveloperSupportMounted(true)
        let target = try CanonicalUDID(
            canonicalString: context.device.facts.uniqueDeviceID
        )
        let catalog = try ExecutionProfileCatalog.load(
            repositoryRoot: repositoryRoot()
        )
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: catalog,
            discovery: { context.device }
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-DynamicPreparationReadiness-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = DynamicDeveloperImageCatalogStoreConfiguration(
            catalogURL: "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/catalog-test.json",
            archiveURLPrefix: "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/archives/"
        )
        let dynamicStore = try DynamicDeveloperImageCatalogStore(
            rootURL: root,
            configuration: configuration,
            fetch: { _, _ in
                XCTFail("mounted dynamic preparation must not fetch catalog")
                return DynamicDeveloperImageCatalogHTTPResponse(
                    etag: nil,
                    statusCode: 500
                )
            },
            now: Date.init
        )
        let dynamicCache = try DynamicDeveloperImageAssetCache(
            rootURL: root,
            configuration: configuration,
            fetch: { _, _ in
                XCTFail("mounted dynamic preparation must not fetch archive")
                return Data()
            }
        )

        let result = try ProductionRuntimeOperationBackend.executePreparation(
            RuntimeRequestEnvelope(
                requestID: CanonicalUUID(value: UUID()),
                operation: .runtimePrepareCapabilities,
                body: try Self.object([
                    ("canonicalUDID", .string(target.rawValue)),
                ])
            ),
            coordinator: coordinator,
            helperExecutor: context.executor,
            dynamicDeveloperImageCatalogStore: dynamicStore,
            dynamicDeveloperImageAssetCache: dynamicCache
        )
        guard case .succeeded = result else {
            return XCTFail("expected mounted dynamic preparation to succeed")
        }

        let preparedSnapshot = try coordinator.commandAdmissionSnapshot()
        XCTAssertTrue(
            coordinator.isPreparationReady(
                groupID: "prep.coredevice.v2",
                snapshot: preparedSnapshot
            )
        )
        let attachedSnapshot = try coordinator.setLiveAttached(true)
        _ = try coordinator.updateGeometry(
            connectionEpoch: attachedSnapshot.connectionEpoch,
            geometryRevision: 1,
            logicalWidth: 1_170,
            logicalHeight: 2_532,
            orientation: .portrait
        )
        let availability = try coordinator.availabilityValue()
        let pointerState = availability["commands"]?.arrayValue?.first { value in
            value.objectValue?["commandID"]?.stringValue
                == "gui.pointer.interaction"
        }?.objectValue?["state"]?.stringValue
        XCTAssertEqual(pointerState, "enabled")
    }

    func testProductionPreparationDerivesLegacyAndModernOSBoundaries() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        let target = try CanonicalUDID(
            canonicalString: context.device.facts.uniqueDeviceID
        )
        let request = RuntimeRequestEnvelope(
            requestID: CanonicalUUID(value: UUID()),
            operation: .runtimePrepareCapabilities,
            body: try Self.object([
        ("canonicalUDID", .string(target.rawValue))
            ])
        )
        let catalog = try ExecutionProfileCatalog.load(
            repositoryRoot: repositoryRoot()
        )
        for version in ["14.0", "15.7", "16.6"] {
            let coordinator = ProductionRuntimeDeviceCoordinator(
                canonicalUDID: target,
                catalog: catalog,
                discovery: {
                    Self.deviceObservation(
                        target: target,
                        buildVersion: "legacy-\(version)",
                        productVersion: version
                    )
                }
            )
            let result = try ProductionRuntimeOperationBackend.executePreparation(
                request,
                coordinator: coordinator,
                helperExecutor: context.executor,
                directHelperExecutor: context.directExecutor
            )
            guard case .failedWithDetails(let code, let details) = result else {
                return XCTFail("expected typed legacy catalog failure for iOS \(version)")
            }
            XCTAssertEqual(code, "developerImageCatalogMismatch")
            XCTAssertEqual(
                details["preparationGroupID"]?.stringValue,
                "prep.legacy.developer.v2"
            )
            XCTAssertNil(
                context.executor.diagnosticSnapshot().activeExecutorGeneration,
                "legacy preparation must not start CoreDevice on iOS \(version)"
            )
        }

        let modern = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: catalog,
            discovery: {
                Self.deviceObservation(
                    target: target,
                    buildVersion: "21A000",
                    productVersion: "17.0"
                )
            }
        )
        let modernCatalog = try Self.personalizedDeveloperImageCatalog(
            buildVersion: "21A000"
        )
        let modernStoreRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PulsePhone-ModernPreparation-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: modernStoreRoot) }
        let modernStore = try DeveloperImageAssetStore(rootURL: modernStoreRoot)
        let modernResult = try ProductionRuntimeOperationBackend.executePreparation(
            request,
            coordinator: modern,
            helperExecutor: context.executor,
            developerImageCatalog: modernCatalog,
            developerImageStore: modernStore
        )
        guard case .succeeded(let value) = modernResult else {
            return XCTFail("expected iOS 17 CoreDevice preparation")
        }
        XCTAssertEqual(
            value["preparationGroupID"]?.stringValue,
            "prep.coredevice.v2"
        )
        XCTAssertNotNil(
            context.executor.diagnosticSnapshot().activeExecutorGeneration
        )
    }

    func testProductionLegacyPreparationUsesVerifiedCachedExactBuild() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        let target = try CanonicalUDID(
            canonicalString: context.device.facts.uniqueDeviceID
        )
        let image = Data("legacy-developer-image".utf8)
        let signature = Data("legacy-developer-signature".utf8)
        let catalog = try Self.legacyDeveloperImageCatalog(
            buildVersion: "18D70",
            image: image,
            signature: signature
        )
        let storeRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PulsePhone-LegacyPreparation-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: storeRoot) }
        let store = try DeveloperImageAssetStore(rootURL: storeRoot)
        _ = try store.publish(
            catalog: catalog,
            entryID: "legacy.18d70",
            archiveEntries: [
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
        )
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(
                repositoryRoot: repositoryRoot()
            ),
            discovery: {
                Self.deviceObservation(
                    target: target,
                    buildVersion: "18D70",
                    productVersion: "14.4.2"
                )
            }
        )
        let result = try ProductionRuntimeOperationBackend.executePreparation(
            RuntimeRequestEnvelope(
                requestID: CanonicalUUID(value: UUID()),
                operation: .runtimePrepareCapabilities,
                body: try Self.object([
          ("canonicalUDID", .string(target.rawValue))
                ])
            ),
            coordinator: coordinator,
            helperExecutor: context.executor,
            directHelperExecutor: context.directExecutor,
            developerImageCatalog: catalog,
            developerImageStore: store
        )

        guard case .succeeded(let value) = result else {
            return XCTFail("expected cached exact-build legacy preparation")
        }
        XCTAssertEqual(
            value["preparationGroupID"]?.stringValue,
            "prep.legacy.developer.v2"
        )
        XCTAssertEqual(value["assetDisposition"]?.stringValue, "cacheHit")
        XCTAssertEqual(value["mountDisposition"]?.stringValue, "mounted")
        XCTAssertEqual(value["serviceDisposition"]?.stringValue, "ready")
        XCTAssertNil(
            context.executor.diagnosticSnapshot().activeExecutorGeneration,
            "legacy preparation must not start CoreDevice"
        )
        XCTAssertTrue(
            try context.manifest().helpers.isEmpty,
            "legacy DirectHelper one-shots must clean up after terminal delivery"
        )

        let repeated = try ProductionRuntimeOperationBackend.executePreparation(
            RuntimeRequestEnvelope(
                requestID: CanonicalUUID(value: UUID()),
                operation: .runtimePrepareCapabilities,
                body: try Self.object([
          ("canonicalUDID", .string(target.rawValue))
                ])
            ),
            coordinator: coordinator,
            helperExecutor: context.executor,
            directHelperExecutor: context.directExecutor,
            developerImageCatalog: catalog,
            developerImageStore: store
        )
        guard case .succeeded(let repeatedValue) = repeated else {
            return XCTFail("expected idempotent legacy preparation")
        }
        XCTAssertEqual(repeatedValue["disposition"]?.stringValue, "alreadyReady")
        XCTAssertEqual(
            repeatedValue["assetDisposition"]?.stringValue,
            "mountedOnly"
        )
        XCTAssertEqual(
            repeatedValue["mountDisposition"]?.stringValue,
            "alreadyMounted"
        )
        XCTAssertNil(repeatedValue["preparationAttemptID"])
    }

    func testProductionLegacyPreparationPublishesSelectedXcodeExactRoles() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        let target = try CanonicalUDID(
            canonicalString: context.device.facts.uniqueDeviceID
        )
        let image = Data("selected-xcode-developer-image".utf8)
        let signature = Data("selected-xcode-developer-signature".utf8)
        let catalog = try Self.legacyDeveloperImageCatalog(
            buildVersion: "18D70",
            image: image,
            signature: signature
        )
        let entry = try XCTUnwrap(catalog.entries.first)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PulsePhone-SelectedXcode-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Xcode.app", isDirectory: true)
        let developer = app.appendingPathComponent(
            "Contents/Developer",
            isDirectory: true
        )
        let support = developer.appendingPathComponent(
            "Platforms/iPhoneOS.platform/DeviceSupport/\(entry.ddiVersion)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: support,
            withIntermediateDirectories: true
        )
        let imageURL = support.appendingPathComponent("DeveloperDiskImage.dmg")
        let signatureURL = support.appendingPathComponent(
            "DeveloperDiskImage.dmg.signature"
        )
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
      pairs: [
        SelectedXcodePair(
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
        )
      ],
            signatureValid: true
        )
        let store = try DeveloperImageAssetStore(
            rootURL: root.appendingPathComponent(
                "DeveloperImages",
                isDirectory: true
            )
        )
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(
                repositoryRoot: repositoryRoot()
            ),
            discovery: {
                Self.deviceObservation(
                    target: target,
                    buildVersion: "18D70",
                    productVersion: "14.4.2"
                )
            }
        )

        let result = try ProductionRuntimeOperationBackend.executePreparation(
            RuntimeRequestEnvelope(
                requestID: CanonicalUUID(value: UUID()),
                operation: .runtimePrepareCapabilities,
                body: try Self.object([
          ("canonicalUDID", .string(target.rawValue))
                ])
            ),
            coordinator: coordinator,
            helperExecutor: context.executor,
            directHelperExecutor: context.directExecutor,
            developerImageCatalog: catalog,
            developerImageStore: store,
            selectedXcodeSnapshotProvider: { _ in snapshot }
        )

        guard case .succeeded(let value) = result else {
            return XCTFail("expected selected Xcode legacy preparation")
        }
        XCTAssertEqual(value["assetDisposition"]?.stringValue, "xcodeHit")
        XCTAssertEqual(value["mountDisposition"]?.stringValue, "mounted")
    XCTAssertNotNil(
      try store.openVerifiedAsset(
            catalog: catalog,
            entryID: entry.entryID
        ))
    }

    func testProductionSelectedXcodeSnapshotHashesExactCatalogRoles() throws {
        let image = Data("snapshot-image".utf8)
        let signature = Data("snapshot-signature".utf8)
        let catalog = try Self.legacyDeveloperImageCatalog(
            buildVersion: "18D70",
            image: image,
            signature: signature
        )
        let entry = try XCTUnwrap(catalog.entries.first)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PulsePhone-XcodeSnapshot-\(UUID().uuidString)",
                isDirectory: true
            )
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Xcode.app", isDirectory: true)
        let developer = app.appendingPathComponent(
            "Contents/Developer",
            isDirectory: true
        )
        let support = developer.appendingPathComponent(
            "Platforms/iPhoneOS.platform/DeviceSupport/\(entry.ddiVersion)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: support,
            withIntermediateDirectories: true
        )
        try PropertyListSerialization.data(
            fromPropertyList: [
                "CFBundleIdentifier": "com.apple.dt.Xcode",
                "CFBundleShortVersionString": "26.5",
                "DTXcodeBuild": "17F41",
            ],
            format: .xml,
            options: 0
        ).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try image.write(to: support.appendingPathComponent("DeveloperDiskImage.dmg"))
    try signature.write(
      to: support.appendingPathComponent(
            "DeveloperDiskImage.dmg.signature"
        ))
        let runner: ProductionSelectedXcodeSnapshot.CommandRunner = {
            executable, _ in
            if executable == "/usr/bin/xcode-select" {
                return ProductionSelectedXcodeSnapshot.CommandResult(
                    exitCode: 0,
                    stdout: Data((developer.path + "\n").utf8)
                )
            }
            return ProductionSelectedXcodeSnapshot.CommandResult(
                exitCode: 0,
                stdout: Data()
            )
        }

    let snapshot = try XCTUnwrap(
      ProductionSelectedXcodeSnapshot.capture(
            entry: entry,
            commandRunner: runner
        ))
        XCTAssertTrue(snapshot.signatureValid)
        XCTAssertTrue(snapshot.gatekeeperAccepted)
        let pair = try XCTUnwrap(snapshot.pairs.first)
        XCTAssertEqual(pair.buildID, "18D70")
        XCTAssertEqual(pair.ddiVersion, "14.4")
        XCTAssertEqual(
            pair.roleFiles["classic.image"]?.sha256,
            StableBytes.sha256Hex(image)
        )
        XCTAssertEqual(
            try DeveloperImageSourceResolver.resolve(
                entry: entry,
                alreadyMounted: false,
                verifiedCacheAvailable: false,
                selectedXcode: snapshot,
                networkAvailable: false
            ).kind,
            .selectedReleaseXcode
        )

        for rejectedExecutable in ["/usr/bin/codesign", "/usr/sbin/spctl"] {
      XCTAssertNil(
        ProductionSelectedXcodeSnapshot.capture(
                entry: entry,
                commandRunner: { executable, _ in
                    if executable == "/usr/bin/xcode-select" {
                        return ProductionSelectedXcodeSnapshot.CommandResult(
                            exitCode: 0,
                            stdout: Data((developer.path + "\n").utf8)
                        )
                    }
                    return ProductionSelectedXcodeSnapshot.CommandResult(
                        exitCode: executable == rejectedExecutable ? 1 : 0,
                        stdout: Data()
                    )
                }
            ))
        }
    }

  func testProductionSelectedXcodeSnapshotReadsValidatedHostDDI() throws {
    let files = [
      ("BuildManifest.plist", Data("host-manifest".utf8)),
      ("Image.dmg", Data("host-image".utf8)),
      ("Image.dmg.trustcache", Data("host-trust".utf8)),
    ]
    let contentFiles = files.map {
      DynamicDeveloperImageContentFile(
        path: $0.0,
        sha256: StableBytes.sha256Hex($0.1),
        size: UInt64($0.1.count)
      )
    }.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    let reference = DynamicDeveloperImageAssetReference(
      archiveSHA256: String(repeating: "a", count: 64),
      archiveSize: 7,
      assetID: "base.xcode-host-test",
      contentManifestSHA256:
        try DynamicDeveloperImageContentManifest
        .sha256(contentFiles),
      ddiVersion: nil,
      kind: .baseImage,
      sourceURL:
        "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/archives/baseAssets/base.xcode-host-test.tar"
    )
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PulsePhone-XcodeHostDDI-\(UUID().uuidString)",
        isDirectory: true
      )
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Xcode.app", isDirectory: true)
    let developer = app.appendingPathComponent(
      "Contents/Developer",
      isDirectory: true
    )
    let hostDDI = root.appendingPathComponent("HostDDI/Restore", isDirectory: true)
    try FileManager.default.createDirectory(
      at: developer,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: hostDDI,
      withIntermediateDirectories: true
    )
    try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundleIdentifier": "com.apple.dt.Xcode",
        "CFBundleShortVersionString": "26.5",
        "DTXcodeBuild": "17F41",
      ],
      format: .xml,
      options: 0
    ).write(to: app.appendingPathComponent("Contents/Info.plist"))
    for (path, data) in files {
      try data.write(to: hostDDI.appendingPathComponent(path))
    }
    let runner: ProductionSelectedXcodeSnapshot.CommandRunner = {
      executable, _ in
      if executable == "/usr/bin/xcode-select" {
        return ProductionSelectedXcodeSnapshot.CommandResult(
          exitCode: 0,
          stdout: Data((developer.path + "\n").utf8)
        )
      }
      return ProductionSelectedXcodeSnapshot.CommandResult(
        exitCode: 0,
        stdout: Data()
      )
    }

    XCTAssertEqual(
      ProductionSelectedXcodeSnapshot.captureDynamicAssetFiles(
        for: reference,
        hostDDIRestorePath: hostDDI.path,
        commandRunner: runner
      ),
      Dictionary(uniqueKeysWithValues: files)
    )
    XCTAssertNil(
      ProductionSelectedXcodeSnapshot.captureDynamicAssetFiles(
        for: reference,
        hostDDIRestorePath: hostDDI.path,
        commandRunner: { executable, _ in
          if executable == "/usr/bin/xcode-select" {
            return ProductionSelectedXcodeSnapshot.CommandResult(
              exitCode: 0,
              stdout: Data((developer.path + "\n").utf8)
            )
          }
          return ProductionSelectedXcodeSnapshot.CommandResult(
            exitCode: executable == "/usr/bin/codesign" ? 1 : 0,
            stdout: Data()
          )
        }
      )
    )
  }

  func testProductionSelectedXcodeSnapshotFindsClassicDDIByContentManifest() throws {
    let image = Data("classic-image".utf8)
    let signature = Data("classic-signature".utf8)
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PulsePhone-XcodeClassicDDI-\(UUID().uuidString)",
        isDirectory: true
      )
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Xcode.app", isDirectory: true)
    let developer = app.appendingPathComponent(
      "Contents/Developer",
      isDirectory: true
    )
    let support = developer.appendingPathComponent(
      "Platforms/iPhoneOS.platform/DeviceSupport",
      isDirectory: true
    )
    let unrelated = support.appendingPathComponent("00-unrelated", isDirectory: true)
    let matching = support.appendingPathComponent("Xcode-18-support", isDirectory: true)
    try FileManager.default.createDirectory(
      at: unrelated,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: matching,
      withIntermediateDirectories: true
    )
    try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundleIdentifier": "com.apple.dt.Xcode",
        "CFBundleShortVersionString": "26.5",
        "DTXcodeBuild": "17F41",
      ],
      format: .xml,
      options: 0
    ).write(to: app.appendingPathComponent("Contents/Info.plist"))
    try Data("other-image".utf8).write(
      to: unrelated.appendingPathComponent("DeveloperDiskImage.dmg")
    )
    try Data("other-signature".utf8).write(
      to: unrelated.appendingPathComponent("DeveloperDiskImage.dmg.signature")
    )
    try image.write(to: matching.appendingPathComponent("DeveloperDiskImage.dmg"))
    try signature.write(to: matching.appendingPathComponent("DeveloperDiskImage.dmg.signature"))
    let expected = [
      "DeveloperDiskImage.dmg": image,
      "DeveloperDiskImage.dmg.signature": signature,
    ]
    let contentFiles = expected.map { path, bytes in
      DynamicDeveloperImageContentFile(
        path: path,
        sha256: StableBytes.sha256Hex(bytes),
        size: UInt64(bytes.count)
      )
    }.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    let reference = DynamicDeveloperImageAssetReference(
      archiveSHA256: String(repeating: "a", count: 64),
      archiveSize: 7,
      assetID: "16.3",
      contentManifestSHA256: try DynamicDeveloperImageContentManifest.sha256(contentFiles),
      ddiVersion: "16.3",
      kind: .developerDiskImage,
      sourceURL:
        "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/archives/DDI/16.3-test.tar"
    )
    let runner: ProductionSelectedXcodeSnapshot.CommandRunner = { executable, _ in
      if executable == "/usr/bin/xcode-select" {
        return ProductionSelectedXcodeSnapshot.CommandResult(
          exitCode: 0,
          stdout: Data((developer.path + "\n").utf8)
        )
      }
      return ProductionSelectedXcodeSnapshot.CommandResult(exitCode: 0, stdout: Data())
    }

    XCTAssertEqual(
      ProductionSelectedXcodeSnapshot.captureDynamicAssetFiles(
        for: reference,
        commandRunner: runner
      ),
      expected
    )
  }

  func testProductionSelectedXcodeSnapshotReadsManifestNamedHostDDI() throws {
    let image = Data("manifest-named-host-image".utf8)
    let trustCache = Data("manifest-named-host-trustcache".utf8)
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "PulsePhone-XcodeManifestHostDDI-\(UUID().uuidString)",
        isDirectory: true
      )
    defer { try? FileManager.default.removeItem(at: root) }
    let app = root.appendingPathComponent("Xcode.app", isDirectory: true)
    let developer = app.appendingPathComponent(
      "Contents/Developer",
      isDirectory: true
    )
    let hostDDI = root.appendingPathComponent("HostDDI/Restore", isDirectory: true)
    let firmware = hostDDI.appendingPathComponent("Firmware", isDirectory: true)
    try FileManager.default.createDirectory(
      at: developer,
      withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
      at: firmware,
      withIntermediateDirectories: true
    )
    try PropertyListSerialization.data(
      fromPropertyList: [
        "CFBundleIdentifier": "com.apple.dt.Xcode",
        "CFBundleShortVersionString": "26.5",
        "DTXcodeBuild": "17F41",
      ],
      format: .xml,
      options: 0
    ).write(to: app.appendingPathComponent("Contents/Info.plist"))
    let buildManifest = try PropertyListSerialization.data(
      fromPropertyList: [
        "BuildIdentities": [
          [
            "Manifest": [
              "PersonalizedDMG": [
                "Info": ["Path": "022-22070-062.dmg"],
              ],
              "LoadableTrustCache": [
                "Info": ["Path": "Firmware/022-22070-062.dmg.trustcache"],
              ],
            ],
          ],
        ],
      ],
      format: .binary,
      options: 0
    )
    try buildManifest.write(to: hostDDI.appendingPathComponent("BuildManifest.plist"))
    try image.write(to: hostDDI.appendingPathComponent("022-22070-062.dmg"))
    try trustCache.write(
      to: firmware.appendingPathComponent("022-22070-062.dmg.trustcache")
    )
    let expected = [
      "BuildManifest.plist": buildManifest,
      "Image.dmg": image,
      "Image.dmg.trustcache": trustCache,
    ]
    let contentFiles = expected.map { path, bytes in
      DynamicDeveloperImageContentFile(
        path: path,
        sha256: StableBytes.sha256Hex(bytes),
        size: UInt64(bytes.count)
      )
    }.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    let reference = DynamicDeveloperImageAssetReference(
      archiveSHA256: String(repeating: "a", count: 64),
      archiveSize: 7,
      assetID: "base.xcode-manifest-host-test",
      contentManifestSHA256: try DynamicDeveloperImageContentManifest.sha256(contentFiles),
      ddiVersion: nil,
      kind: .baseImage,
      sourceURL:
        "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/archives/baseAssets/base.xcode-manifest-host-test.tar"
    )
    let runner: ProductionSelectedXcodeSnapshot.CommandRunner = {
      executable, _ in
      if executable == "/usr/bin/xcode-select" {
        return ProductionSelectedXcodeSnapshot.CommandResult(
          exitCode: 0,
          stdout: Data((developer.path + "\n").utf8)
        )
      }
      return ProductionSelectedXcodeSnapshot.CommandResult(
        exitCode: 0,
        stdout: Data()
      )
    }

    XCTAssertEqual(
      ProductionSelectedXcodeSnapshot.captureDynamicAssetFiles(
        for: reference,
        hostDDIRestorePath: hostDDI.path,
        commandRunner: runner
      ),
      expected
    )
  }

    func testProductionInstallationPayloadPreflightAndDeadlines() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PulsePhone-Install-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let ipa = directory.appendingPathComponent("Fixture.ipa")
    XCTAssertTrue(
      FileManager.default.createFile(
            atPath: ipa.path,
            contents: Data([1])
        ))
        let target = try CanonicalUDID(canonicalString: "M2031-INSTALL-PAYLOAD")
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(repositoryRoot: repositoryRoot()),
            discovery: {
                ProductionRuntimeDeviceObservation(
                    rawTransportUDID: target.rawValue,
                    facts: ProductionRuntimeDeviceFacts(
                        buildVersion: "23F84",
                        deviceClass: "iPhone",
                        deviceName: "Test iPhone",
                        productType: "iPhone14,7",
                        productVersion: "26.5.2",
                        uniqueDeviceID: target.rawValue
                    ),
                    condition: ProductionRuntimeDeviceCondition(
                        connected: true,
                        locked: false,
                        trusted: true
                    )
                )
            }
        )
        let snapshot = try coordinator.refresh()
        let payload = try XCTUnwrap(
            ProductionRuntimeOperationBackend.helperBackendPayload(
                commandID: "app.install",
                arguments: ["ipaPath": ipa.path],
                snapshot: snapshot
            )
        )
        XCTAssertEqual(payload["operation"], .string("install"))
        XCTAssertEqual(payload["ipaPath"], .string(ipa.path))
        let uninstallPayload = try XCTUnwrap(
            ProductionRuntimeOperationBackend.helperBackendPayload(
                commandID: "app.uninstall",
                arguments: ["bundleID": "com.example.UninstallFixture"],
                snapshot: snapshot
            )
        )
    XCTAssertEqual(
      uninstallPayload,
      [
            "bundleID": .string("com.example.UninstallFixture"),
            "operation": .string("uninstall"),
        ])
    XCTAssertTrue(
      ProductionRuntimeOperationBackend.validIPAPathForExecution(
            ipa.path
        ))
    XCTAssertFalse(
      ProductionRuntimeOperationBackend.validIPAPathForExecution(
            directory.appendingPathComponent("Missing.ipa").path
        ))
        let empty = directory.appendingPathComponent("Empty.ipa")
        XCTAssertTrue(FileManager.default.createFile(atPath: empty.path, contents: Data()))
    XCTAssertFalse(
      ProductionRuntimeOperationBackend.validIPAPathForExecution(
            empty.path
        ))
        let link = directory.appendingPathComponent("Link.ipa")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: ipa)
    XCTAssertFalse(
      ProductionRuntimeOperationBackend.validIPAPathForExecution(
            link.path
        ))
    XCTAssertFalse(
      ProductionRuntimeOperationBackend.validIPAPathForExecution(
            directory.path + "//Fixture.ipa"
        ))
    XCTAssertFalse(
      ProductionRuntimeOperationBackend.validIPAPathForExecution(
            directory.path + "/../" + directory.lastPathComponent + "/Fixture.ipa"
        ))
        XCTAssertEqual(
            RuntimeClient.commandRequestTimeoutSeconds("app.install"),
            30 * 60 + 10
        )
        XCTAssertGreaterThan(
            RuntimeClient.commandRequestTimeoutSeconds("app.install"),
            Int(ProductionCoreDeviceHelperExecutor.installDeadlineMilliseconds) / 1_000
        )
        XCTAssertEqual(
            RuntimeClient.commandRequestTimeoutSeconds("app.uninstall"),
            5 * 60 + 10
        )
        XCTAssertGreaterThan(
            RuntimeClient.commandRequestTimeoutSeconds("app.uninstall"),
            Int(ProductionCoreDeviceHelperExecutor.uninstallDeadlineMilliseconds)
                / 1_000
        )
        XCTAssertEqual(
            RuntimeClient.commandRequestTimeoutSeconds("button.home"),
            RuntimeClient.requestTimeoutSeconds
        )
        XCTAssertEqual(
            ProductionCoreDeviceHelperExecutor.oneShotDeadlineNanoseconds(
                routeID: "direct.installationProxy.install",
                startedAt: 10
            ),
            10 + UInt64(30 * 60 * 1_000) * 1_000_000
        )
        XCTAssertEqual(
            ProductionCoreDeviceHelperExecutor.oneShotDeadlineNanoseconds(
                routeID: "direct.installationProxy.uninstall",
                startedAt: 10
            ),
            10 + UInt64(5 * 60 * 1_000) * 1_000_000
        )
        XCTAssertNil(
            ProductionCoreDeviceHelperExecutor.oneShotDeadlineNanoseconds(
                routeID: "coredevice.button.home",
                startedAt: 10
            )
        )
        XCTAssertEqual(
            ProductionCoreDeviceHelperExecutor.oneShotDeadlineNanoseconds(
                routeID: "legacy.developerSupport.queryMounted",
                startedAt: 10
            ),
            10 + UInt64(
                ProductionCoreDeviceHelperExecutor
                    .legacyDeveloperSupportQueryDeadlineMilliseconds
            ) * 1_000_000
        )
        XCTAssertEqual(
            ProductionCoreDeviceHelperExecutor.oneShotDeadlineNanoseconds(
                routeID: "legacy.developerSupport.probeServices",
                startedAt: 10
            ),
            10 + UInt64(
                ProductionCoreDeviceHelperExecutor
                    .legacyDeveloperSupportProbeDeadlineMilliseconds
            ) * 1_000_000
        )
        XCTAssertEqual(
            ProductionCoreDeviceHelperExecutor.oneShotDeadlineNanoseconds(
                routeID: "legacy.developerSupport.mount",
                startedAt: 10
            ),
            10 + UInt64(
                ProductionCoreDeviceHelperExecutor
                    .legacyDeveloperSupportMountDeadlineMilliseconds
            ) * 1_000_000
        )
        XCTAssertEqual(
            ProductionCoreDeviceHelperExecutor.oneShotDeadlineNanoseconds(
                routeID: "coredevice.developerSupport.mount",
                startedAt: 10
            ),
            10 + UInt64(
                ProductionCoreDeviceHelperExecutor
                    .coreDeviceDeveloperSupportMountDeadlineMilliseconds
            ) * 1_000_000
        )
        XCTAssertEqual(
            ProductionCoreDeviceHelperExecutor.oneShotDeadlineNanoseconds(
                routeID: "coredevice.developerSupport.requestTSS",
                startedAt: 10
            ),
            10 + UInt64(
                ProductionCoreDeviceHelperExecutor
                    .coreDeviceDeveloperSupportPersonalizationDeadlineMilliseconds
            ) * 1_000_000
        )
        for routeID in ["coredevice.screenshot", "legacy.screenshotr"] {
            XCTAssertEqual(
                ProductionCoreDeviceHelperExecutor.oneShotDeadlineNanoseconds(
                    routeID: routeID,
                    startedAt: 10
                ),
                10 + UInt64(
                    ProductionCoreDeviceHelperExecutor
                        .screenshotDeadlineMilliseconds
                ) * 1_000_000
            )
        }
    XCTAssertTrue(
      ProductionRuntimeOperationBackend.usesDirectHelper(
            routeID: "direct.installationProxy.install"
        ))
    XCTAssertTrue(
      ProductionRuntimeOperationBackend.usesDirectHelper(
            routeID: "direct.installationProxy.uninstall"
        ))
    XCTAssertFalse(
      ProductionRuntimeOperationBackend.usesDirectHelper(
            routeID: "coredevice.app.launch"
        ))
    let invalidPath =
      try ProductionRuntimeOperationBackend
            .invalidIPAPathDetails()
        XCTAssertEqual(invalidPath["argumentName"]?.stringValue, "ipaPath")
        XCTAssertEqual(
            invalidPath["reason"]?.stringValue,
            "notCanonicalRegularIPA"
        )
    let unknown =
      try ProductionRuntimeOperationBackend
            .installOutcomeUnknownResult()
        XCTAssertEqual(unknown["outcome"]?.stringValue, "outcomeUnknown")
        XCTAssertEqual(unknown["commitState"]?.stringValue, "unknown")
        XCTAssertEqual(
            unknown["error"]?.objectValue?["code"]?.stringValue,
            "outcomeUnknown"
        )
        XCTAssertEqual(
            unknown["error"]?.objectValue?["details"]?
                .objectValue?["reason"]?.stringValue,
            "commitStateUnknown"
        )
    let precommit =
      try ProductionRuntimeOperationBackend
            .installFailedNotCommittedResult(stage: "helperStartup")
        XCTAssertEqual(precommit["outcome"]?.stringValue, "failed")
        XCTAssertEqual(precommit["commitState"]?.stringValue, "notCommitted")
        XCTAssertEqual(
            precommit["error"]?.objectValue?["code"]?.stringValue,
            "installFailed"
        )
        XCTAssertEqual(
            precommit["error"]?.objectValue?["details"]?
                .objectValue?["commitState"]?.stringValue,
            "notCommitted"
        )
        XCTAssertEqual(
            precommit["error"]?.objectValue?["details"]?
                .objectValue?["stage"]?.stringValue,
            "helperStartup"
        )
    let uninstallUnknown =
      try ProductionRuntimeOperationBackend
            .uninstallOutcomeUnknownResult()
        XCTAssertEqual(uninstallUnknown["outcome"]?.stringValue, "outcomeUnknown")
        XCTAssertEqual(uninstallUnknown["commitState"]?.stringValue, "unknown")
    let uninstallPrecommit =
      try ProductionRuntimeOperationBackend
            .uninstallFailedNotCommittedResult(stage: "helperStartup")
        XCTAssertEqual(uninstallPrecommit["outcome"]?.stringValue, "failed")
        XCTAssertEqual(
            uninstallPrecommit["error"]?.objectValue?["code"]?.stringValue,
            "uninstallFailed"
        )
        XCTAssertEqual(
            uninstallPrecommit["error"]?.objectValue?["details"]?
                .objectValue?["stage"]?.stringValue,
            "helperStartup"
        )
    }

    func testScreenshotResultRetirementMarkerIsRouteAndOutcomeBound() throws {
        let retiring = try Self.object([
            ("outcome", .string("succeeded")),
      (
        "value",
        .object(
          try Self.object([
            ("generationDisposition", .string("retiringAfterResult"))
          ]))
      ),
        ])
    XCTAssertTrue(
      try ProductionCoreDeviceHelperExecutor
            .resultRetiresGeneration(
                routeID: "coredevice.screenshot",
                result: retiring
            ))
    XCTAssertFalse(
      try ProductionCoreDeviceHelperExecutor
            .resultRetiresGeneration(
                routeID: "coredevice.screenshot",
                result: try Self.object([
                    ("outcome", .string("succeeded")),
                    ("value", .object(try Self.object([]))),
                ])
            ))
    XCTAssertThrowsError(
      try ProductionCoreDeviceHelperExecutor
            .resultRetiresGeneration(
                routeID: "coredevice.button.home",
                result: retiring
        )
    ) {
            XCTAssertEqual(
                $0 as? ProductionCoreDeviceHelperExecutorError,
                .invalidHelperMessage
            )
        }
    XCTAssertThrowsError(
      try ProductionCoreDeviceHelperExecutor
            .resultRetiresGeneration(
                routeID: "coredevice.screenshot",
                result: try Self.object([
                    ("outcome", .string("failed")),
            (
              "value",
              .object(
                try Self.object([
                        (
                            "generationDisposition",
                            .string("retiringAfterResult")
                  )
                ]))
                        ),
                ])
        )
    ) {
            XCTAssertEqual(
                $0 as? ProductionCoreDeviceHelperExecutorError,
                .invalidHelperMessage
            )
        }
    }

    func testElementCaptureMetadataStrictlyValidatesAttemptTrace() throws {
        func timings(
            total: UInt64 = 5,
            extraKey: Bool = false
        ) throws -> RepositoryJSONObject {
            var members: [(String, RepositoryJSONValue)] = [
                ("captureMicroseconds", .number(.uint64(2))),
                ("queueWaitMicroseconds", .number(.uint64(1))),
                ("serviceCloseMicroseconds", .number(.uint64(0))),
                ("serviceOpenMicroseconds", .number(.uint64(2))),
                ("totalMicroseconds", .number(.uint64(total))),
            ]
            if extraKey { members.append(("unexpected", .number(.uint64(0)))) }
            return try Self.object(members)
        }
        func attempt(
            provider: String,
            status: String,
            errorCode: RepositoryJSONValue,
            stage: RepositoryJSONValue,
            total: UInt64 = 5,
            extraTimingKey: Bool = false
        ) throws -> RepositoryJSONValue {
      .object(
        try Self.object([
                ("errorCode", errorCode),
                ("provider", .string(provider)),
                ("stage", stage),
                ("status", .string(status)),
          (
            "timings",
            .object(
              try timings(
                    total: total,
                    extraKey: extraTimingKey
              ))
          ),
            ]))
        }
        let failedCore = try attempt(
            provider: "coreDevice",
            status: "failed",
            errorCode: .string("developerServicesUnavailable"),
            stage: .string("screenshotServiceOpen")
        )
        let succeededCore = try attempt(
            provider: "coreDevice",
            status: "succeeded",
            errorCode: .null,
            stage: .null
        )
        let succeededDVT = try attempt(
            provider: "dvt",
            status: "succeeded",
            errorCode: .null,
            stage: .null
        )
        let failedDVT = try attempt(
            provider: "dvt",
            status: "failed",
            errorCode: .string("developerServicesUnavailable"),
            stage: .string("dvtScreenshotCaptureOrValidate")
        )
        let succeededAXAudit = try attempt(
            provider: "axAudit",
            status: "succeeded",
            errorCode: .null,
            stage: .null
        )
        func value(
            provider: String = "coreDevice",
            attempts: [RepositoryJSONValue],
            generationDisposition: RepositoryJSONValue? = .string(
                "retiringAfterResult"
            )
        ) throws -> RepositoryJSONObject {
            var members: [(String, RepositoryJSONValue)] = [
                ("_pulsephoneCaptureAttempts", .array(attempts)),
                ("captureProvider", .string(provider)),
            ]
            if let generationDisposition {
                members.append(("generationDisposition", generationDisposition))
            }
            return try Self.object(members)
        }

        let valid = try XCTUnwrap(
            ProductionRuntimeOperationBackend.elementCaptureMetadata(
                route: .modernCoreDevice,
                value: try value(attempts: [failedDVT, succeededCore])
            )
        )
        XCTAssertEqual(valid.provider, .coreDevice)
        XCTAssertEqual(valid.attempts?.map(\.provider), [.dvt, .coreDevice])
        XCTAssertEqual(valid.attempts?.first?.failureStage, .captureOrValidate)

        let validPrimary = try XCTUnwrap(
            ProductionRuntimeOperationBackend.elementCaptureMetadata(
                route: .modernCoreDevice,
                value: try value(
                    provider: "dvt",
                    attempts: [succeededDVT],
                    generationDisposition: nil
                )
            )
        )
        XCTAssertEqual(validPrimary.provider, .dvt)
        XCTAssertEqual(validPrimary.attempts?.map(\.provider), [.dvt])

        let validAXAudit = try XCTUnwrap(
            ProductionRuntimeOperationBackend.elementCaptureMetadata(
                route: .modernCoreDevice,
                value: try value(
                    provider: "axAudit",
                    attempts: [failedDVT, failedCore, succeededAXAudit]
                )
            )
        )
        XCTAssertEqual(validAXAudit.provider, .axAudit)
        XCTAssertEqual(
            validAXAudit.attempts?.map(\.provider),
            [.dvt, .coreDevice, .axAudit]
        )
        XCTAssertEqual(
            validAXAudit.attempts?[1].failureStage,
            .serviceOpen
        )

        let malformedTraces: [RepositoryJSONObject] = [
            try value(attempts: []),
            try value(attempts: [succeededCore, failedDVT]),
            try value(attempts: [failedDVT]),
            try value(attempts: [
                failedDVT,
                try attempt(
                    provider: "coreDevice",
                    status: "failed",
                    errorCode: .string("developerServicesUnavailable"),
                    stage: .string("screenshotServiceOpen")
                ),
            ]),
            try value(attempts: [
                try attempt(
                    provider: "dvt",
                    status: "failed",
                    errorCode: .string("developerServicesUnavailable"),
                    stage: .string("screenshotServiceOpen")
                ),
                succeededCore,
            ]),
            try value(attempts: [
                failedDVT,
                try attempt(
                    provider: "coreDevice",
                    status: "succeeded",
                    errorCode: .null,
                    stage: .null,
                    total: 30_000_001
                ),
            ]),
            try value(attempts: [
                failedDVT,
                try attempt(
                    provider: "coreDevice",
                    status: "succeeded",
                    errorCode: .null,
                    stage: .null,
                    extraTimingKey: true
                ),
            ]),
            try value(
                provider: "axAudit",
                attempts: [
                    failedDVT,
                    failedCore,
                    try attempt(
                        provider: "axAudit",
                        status: "succeeded",
                        errorCode: .null,
                        stage: .string("axAuditScreenshotServiceOpen")
                    ),
                ]
            ),
        ]
        for malformed in malformedTraces {
            XCTAssertNil(
                ProductionRuntimeOperationBackend.elementCaptureMetadata(
                    route: .modernCoreDevice,
                    value: malformed
                )
            )
        }
    XCTAssertNil(
      ProductionRuntimeOperationBackend.elementCaptureMetadata(
            route: .modernCoreDevice,
            value: try value(
                provider: "dvt",
                attempts: [succeededCore],
                generationDisposition: nil
            )
        ))
    XCTAssertNil(
      ProductionRuntimeOperationBackend.elementCaptureMetadata(
            route: .modernCoreDevice,
            value: try value(
                provider: "dvt",
                attempts: [succeededDVT]
            )
        ))
    XCTAssertNil(
      ProductionRuntimeOperationBackend.elementCaptureMetadata(
            route: .modernCoreDevice,
            value: try value(
                attempts: [failedDVT, succeededCore],
                generationDisposition: nil
            )
        ))
    }

    func testElementCaptureMetadataAcceptsPreparedCoreDeviceFallbackPlan()
        throws
    {
        let timings = try Self.object([
            ("captureMicroseconds", .number(.uint64(1))),
            ("queueWaitMicroseconds", .number(.uint64(0))),
            ("serviceCloseMicroseconds", .number(.uint64(0))),
            ("serviceOpenMicroseconds", .number(.uint64(1))),
            ("totalMicroseconds", .number(.uint64(2))),
        ])
        let failedCore = try Self.object([
            ("errorCode", .string("developerServicesUnavailable")),
            ("provider", .string("coreDevice")),
            ("stage", .string("screenshotServiceOpen")),
            ("status", .string("failed")),
            ("timings", .object(timings)),
        ])
        let succeededAXAudit = try Self.object([
            ("errorCode", .null),
            ("provider", .string("axAudit")),
            ("stage", .null),
            ("status", .string("succeeded")),
            ("timings", .object(timings)),
        ])
        let value = try Self.object([
            (
                "_pulsephoneCaptureAttempts",
                .array([.object(failedCore), .object(succeededAXAudit)])
            ),
            ("captureProvider", .string("axAudit")),
            ("generationDisposition", .string("retiringAfterResult")),
        ])

        let metadata = try XCTUnwrap(
            ProductionRuntimeOperationBackend.elementCaptureMetadata(
                route: .modernCoreDevice,
                value: value,
                providerOrder: ["coreDevice", "axAudit"]
            )
        )
        XCTAssertEqual(metadata.provider, .axAudit)
        XCTAssertEqual(metadata.attempts?.map(\.provider), [.coreDevice, .axAudit])
    }

    func testScreenshotProviderPlanClearsAcrossConnectionEpoch() throws {
        let target = try CanonicalUDID(canonicalString: "M2031-SCREENSHOT-PLAN-EPOCH")
        let catalog = try ExecutionProfileCatalog.load(repositoryRoot: repositoryRoot())
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: catalog,
            discovery: { Self.deviceObservation(target: target) }
        )
        let initial = try coordinator.refresh()
        let plan = try XCTUnwrap(
            ProductionScreenshotProviderPlan(
                preferredProvider: "coreDevice",
                attemptOrder: ["coreDevice", "axAudit"]
            )
        )
        try coordinator.recordScreenshotProviderPlan(
            plan,
            connectionEpoch: initial.connectionEpoch
        )
        XCTAssertEqual(
            coordinator.screenshotProviderPlan(
                connectionEpoch: initial.connectionEpoch
            ),
            plan
        )

        _ = try coordinator.confirmDisconnected()
        XCTAssertNil(
            coordinator.screenshotProviderPlan(
                connectionEpoch: initial.connectionEpoch
            )
        )
        let replacement = try coordinator.refresh()
        XCTAssertGreaterThan(replacement.connectionEpoch, initial.connectionEpoch)
        XCTAssertNil(
            coordinator.screenshotProviderPlan(
                connectionEpoch: replacement.connectionEpoch
            )
        )
    }

    func testOptionalCapabilityAvailabilitySurfacesAfterPreparationProbe() throws {
        let target = try CanonicalUDID(canonicalString: "M2031-OPTIONAL-CAPABILITY")
        let catalog = try ExecutionProfileCatalog.load(repositoryRoot: repositoryRoot())
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: catalog,
            discovery: { Self.deviceObservation(target: target) }
        )
        let snapshot = try coordinator.refresh()
        try coordinator.recordOptionalCapabilityAvailability(
            [
                "coredevice.screenshot": .unavailable(
                    reason: "allProvidersUnavailable"
                ),
            ],
            connectionEpoch: snapshot.connectionEpoch
        )

        let updated = try coordinator.commandAdmissionSnapshot()
        XCTAssertEqual(
            updated.planningContext.capabilities["coredevice.screenshot"],
            .unavailable(reason: "allProvidersUnavailable")
        )
    }

    func testProductionRecordingStorePersistsStableTraceAndDiagnostics()
        throws
    {
        let root = try recordingRoot("stable")
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try CanonicalUDID(
            canonicalString: "M2031-RECORDING-STABLE"
        )
        let store = try ProductionRuntimeRecordingStore.testing(
            temporaryBasePath: root.path,
            canonicalUDID: target
        )

        let trace = try store.startTrace()
        XCTAssertThrowsError(try store.startTrace()) { error in
            XCTAssertEqual(
                error as? ProductionRuntimeRecordingError,
                .traceAlreadyActive
            )
        }
        let actionID = CanonicalUUID(value: UUID())
    store.recordTrace(
      try ReplayTraceSemanticEvent(
            actionID: actionID,
            commandID: "button.home",
            eventKind: .invocation,
            payloadByteCount: 42
        ))
    store.recordTrace(
      try ReplayTraceSemanticEvent(
            actionID: actionID,
            commandID: "button.home",
            eventKind: .result,
            outcome: .succeeded
        ))
        XCTAssertEqual(store.snapshot.activeTraceID, trace.traceID)
        let traceStop = try store.stopTrace()
        XCTAssertEqual(traceStop.absolutePath, trace.absolutePath)
        XCTAssertEqual(traceStop.traceID, trace.traceID)
        XCTAssertEqual(traceStop.completeness, .complete)
        XCTAssertNil(store.snapshot.activeTraceID)

        let traceLines = try recordingLines(at: trace.absolutePath)
    XCTAssertEqual(
      traceLines.map { $0["kind"]?.stringValue },
      [
            "trace.header", "trace.semantic", "trace.semantic", "trace.footer",
        ])
        XCTAssertEqual(traceLines[1]["eventKind"]?.stringValue, "invocation")
        XCTAssertEqual(traceLines[2]["eventKind"]?.stringValue, "result")
        XCTAssertEqual(traceLines[3]["completeness"]?.stringValue, "complete")
        try assertRecordingFileMode(trace.absolutePath)

        let diagnostics = try store.startDiagnostics()
        XCTAssertThrowsError(try store.startDiagnostics()) { error in
            XCTAssertEqual(
                error as? ProductionRuntimeRecordingError,
                .diagnosticsAlreadyActive
            )
        }
    store.recordDiagnostic(
      try DiagnosticLogEvent(
            category: .backend,
            code: "runtime.commandSubmit.succeeded"
        ))
        XCTAssertEqual(
            store.snapshot.activeDiagnosticsSessionID,
            diagnostics.sessionID
        )
        let diagnosticStop = try store.stopDiagnostics()
        XCTAssertEqual(diagnosticStop.absolutePath, diagnostics.absolutePath)
        XCTAssertEqual(diagnosticStop.sessionID, diagnostics.sessionID)
        XCTAssertEqual(diagnosticStop.completeness, .complete)
        XCTAssertNil(store.snapshot.activeDiagnosticsSessionID)

        let diagnosticLines = try recordingLines(at: diagnostics.absolutePath)
    XCTAssertEqual(
      diagnosticLines.map { $0["kind"]?.stringValue },
      [
            "diagnostic.header", "diagnostic.event", "diagnostic.footer",
        ])
        XCTAssertEqual(
            diagnosticLines[2]["completeness"]?.stringValue,
            "complete"
        )
        try assertRecordingFileMode(diagnostics.absolutePath)
    }

    func testProductionRecordingStoreAutoFinalizesWriteFailureAndCap()
        throws
    {
        let root = try recordingRoot("failure")
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = RecordingWriteGate()
        let store = try ProductionRuntimeRecordingStore.testing(
            temporaryBasePath: root.path,
            canonicalUDID: try CanonicalUDID(
                canonicalString: "M2031-RECORDING-FAILURE"
            ),
            writeAvailability: { kind, stage in
                gate.allows(kind: kind, stage: stage)
            }
        )

        let trace = try store.startTrace()
        gate.failNextTraceRecord()
    store.recordTrace(
      try ReplayTraceSemanticEvent(
            actionID: CanonicalUUID(value: UUID()),
            commandID: "device.rotate",
            eventKind: .invocation
        ))
        XCTAssertNil(store.snapshot.activeTraceID)
        XCTAssertThrowsError(try store.stopTrace()) { error in
            XCTAssertEqual(
                error as? ProductionRuntimeRecordingError,
                .noActiveTrace
            )
        }
        let failedTraceLines = try recordingLines(at: trace.absolutePath)
    XCTAssertEqual(
      failedTraceLines.map { $0["kind"]?.stringValue },
      [
            "trace.header", "trace.footer",
        ])
        XCTAssertEqual(
            failedTraceLines.last?["completeness"]?.stringValue,
            "incomplete"
        )
        XCTAssertEqual(
            failedTraceLines.last?["reason"]?.stringValue,
            "writeFailure"
        )

        let noFooterTrace = try store.startTrace()
        gate.failNextTraceRecord()
        gate.failNextTraceFinalize()
    store.recordTrace(
      try ReplayTraceSemanticEvent(
            actionID: CanonicalUUID(value: UUID()),
            commandID: "button.home",
            eventKind: .invocation
        ))
        XCTAssertNil(store.snapshot.activeTraceID)
        XCTAssertEqual(
            try recordingLines(at: noFooterTrace.absolutePath).map {
                $0["kind"]?.stringValue
            },
            ["trace.header"]
        )

        let diagnostics = try store.startDiagnostics(
            maximumFileBytes: 768,
            footerReserveBytes: 384
        )
        for index in 0..<32 where store.snapshot.activeDiagnosticsSessionID != nil {
      store.recordDiagnostic(
        try DiagnosticLogEvent(
                category: .lifecycle,
                code: "operation.\(index)"
            ))
        }
        XCTAssertNil(store.snapshot.activeDiagnosticsSessionID)
        XCTAssertThrowsError(try store.stopDiagnostics()) { error in
            XCTAssertEqual(
                error as? ProductionRuntimeRecordingError,
                .noActiveDiagnostics
            )
        }
        let cappedLines = try recordingLines(at: diagnostics.absolutePath)
        XCTAssertEqual(cappedLines.first?["kind"]?.stringValue, "diagnostic.header")
        XCTAssertEqual(cappedLines.last?["kind"]?.stringValue, "diagnostic.footer")
        XCTAssertEqual(cappedLines.last?["completeness"]?.stringValue, "incomplete")
        XCTAssertEqual(cappedLines.last?["reason"]?.stringValue, "sizeCap")
        XCTAssertLessThanOrEqual(
            try Data(contentsOf: URL(fileURLWithPath: diagnostics.absolutePath)).count,
            768
        )
    }

    func testProductionScreenshotStoreReturnsReadOnlyUnlinkedPNG() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-ScreenshotStore-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try CanonicalUDID(canonicalString: "M2031-SCREENSHOT-STORE")
        var store: ProductionScreenshotArtifactStore? = try .testing(
            temporaryBasePath: root.path,
            canonicalUDID: target,
            runtimeEpoch: 9
        )
        let artifactID = CanonicalUUID(value: UUID())
        let reservation = try XCTUnwrap(store).reserve(artifactID: artifactID)
        let png: [UInt8] = [
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 9, 8, 7,
        ]
        let writer = open(
            reservation.internalPath,
            O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW
        )
        XCTAssertGreaterThanOrEqual(writer, 0)
    XCTAssertEqual(
      png.withUnsafeBytes {
            Darwin.write(writer, $0.baseAddress, $0.count)
        }, png.count)
        XCTAssertEqual(fsync(writer), 0)
        XCTAssertEqual(Darwin.close(writer), 0)

        let delivery = try XCTUnwrap(store).complete(
            reservation,
            byteCount: UInt64(png.count),
            format: .png
        )
        defer { _ = Darwin.close(delivery.descriptor) }
        XCTAssertEqual(delivery.artifactID, artifactID)
        XCTAssertEqual(delivery.byteCount, UInt64(png.count))
        XCTAssertEqual(fcntl(delivery.descriptor, F_GETFL) & O_ACCMODE, O_RDONLY)
        var status = stat()
        XCTAssertEqual(fstat(delivery.descriptor, &status), 0)
        XCTAssertEqual(status.st_nlink, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: reservation.internalPath))
        var received = [UInt8](repeating: 0, count: png.count)
    XCTAssertEqual(
      received.withUnsafeMutableBytes {
            Darwin.read(delivery.descriptor, $0.baseAddress, $0.count)
        }, png.count)
        XCTAssertEqual(received, png)

        store = nil
    XCTAssertFalse(
      FileManager.default.fileExists(
            atPath: root.appendingPathComponent("scratch").path
        ))
    }

    func testProductionHelperIdentifiersBindGenerationAndSession() throws {
        XCTAssertEqual(
            ProductionCoreDeviceHelperExecutor.helperIdentifier(generation: 42),
            "coredevice-42"
        )
        let sessionID = try CanonicalUUID(
            "01234567-89ab-cdef-8123-456789abcdef"
        )
        XCTAssertEqual(
            ProductionCoreDeviceHelperExecutor.streamDeliveryAttemptID(
                sessionID: sessionID
            ),
            "stream.01234567-89ab-cdef-8123-456789abcdef"
        )
    }

    func testProductionHelperTracesButtonAndRotateOneShotRequests() {
    XCTAssertTrue(
      ProductionCoreDeviceHelperExecutor.tracesOneShotRequest(
            routeID: "coredevice.button.home"
        ))
    XCTAssertTrue(
      ProductionCoreDeviceHelperExecutor.tracesOneShotRequest(
            routeID: "coredevice.orientation.rotate"
        ))
    XCTAssertFalse(
      ProductionCoreDeviceHelperExecutor.tracesOneShotRequest(
            routeID: "coredevice.displayGeometry.query"
        ))
    XCTAssertFalse(
      ProductionCoreDeviceHelperExecutor.tracesOneShotRequest(
            routeID: "coredevice.normalTouch"
        ))
    }

    func testRuntimeCoordinateProjectionCoversOrientationsRoundingAndEdges() throws {
        let cases: [(DisplayOrientationDTO, UInt16, UInt16, [String])] = [
      (
        .portrait, 13_107, 45_875,
        ["top", "right", "bottom", "left"]
      ),
      (
        .landscapeRight, 45_875, 52_428,
        ["left", "top", "right", "bottom"]
      ),
      (
        .portraitUpsideDown, 52_428, 19_661,
        ["bottom", "left", "top", "right"]
      ),
      (
        .landscapeLeft, 19_661, 13_107,
        ["right", "bottom", "left", "top"]
      ),
        ]
        let visualEdges = ["top", "right", "bottom", "left"]
        for (orientation, expectedX, expectedY, expectedEdges) in cases {
            let geometry = try DisplayGeometryDTO(
                connectionEpoch: 3,
                geometryRevision: 5,
                logicalHeight: orientation.rawValue.hasPrefix("landscape")
                    ? 1170 : 2532,
                logicalWidth: orientation.rawValue.hasPrefix("landscape")
                    ? 2532 : 1170,
                orientation: orientation
            )
            let projection = ProductionRuntimeCoordinateProjection(
                geometry: geometry
            )
            let point = try projection.project(x: "0.2", y: "0.7", edge: "none")
            XCTAssertEqual(point.x, expectedX, orientation.rawValue)
            XCTAssertEqual(point.y, expectedY, orientation.rawValue)
            XCTAssertEqual(point.edge, "none", orientation.rawValue)
            for (visualEdge, expectedEdge) in zip(visualEdges, expectedEdges) {
                XCTAssertEqual(
                    try projection.project(
                        x: "0.5",
                        y: "0.5",
                        edge: visualEdge
                    ).edge,
                    expectedEdge,
                    "\(orientation.rawValue) \(visualEdge)"
                )
            }
            let midpoint = try projection.project(
                x: "0.5",
                y: "0.5",
                edge: "none"
            )
            XCTAssertEqual(midpoint.x, 32_768, orientation.rawValue)
            XCTAssertEqual(midpoint.y, 32_768, orientation.rawValue)
        }
        let portrait = ProductionRuntimeCoordinateProjection(
            geometry: try DisplayGeometryDTO(
                connectionEpoch: 1,
                geometryRevision: 1,
                logicalHeight: 2532,
                logicalWidth: 1170,
                orientation: .portrait
            )
        )
        let minimum = try portrait.project(x: "0", y: "0", edge: "none")
        XCTAssertEqual(minimum.x, 0)
        XCTAssertEqual(minimum.y, 0)
        let maximum = try portrait.project(x: "1", y: "1", edge: "none")
        XCTAssertEqual(maximum.x, UInt16.max)
        XCTAssertEqual(maximum.y, UInt16.max)
        let landscapeEndpoint = try ProductionRuntimeCoordinateProjection(
            geometry: try DisplayGeometryDTO(
                connectionEpoch: 1,
                geometryRevision: 1,
                logicalHeight: 1170,
                logicalWidth: 2532,
                orientation: .landscapeRight
            )
        ).project(x: "0", y: "1", edge: "none")
        XCTAssertEqual(landscapeEndpoint.x, UInt16.max)
        XCTAssertEqual(landscapeEndpoint.y, UInt16.max)
        XCTAssertThrowsError(try portrait.project(x: "0.50", y: "0.5", edge: "none"))
        XCTAssertThrowsError(try portrait.project(x: "0.5", y: "0.5", edge: "center"))
    }

    func testRuntimeCoordinateProjectionStoreFencesGeometryAndPreservesKeyboard() throws {
        let store = ProductionRuntimeCoordinateProjectionStore()
        let pointerSession = CanonicalUUID(value: UUID())
        let pointerInteraction = CanonicalUUID(value: UUID())
        let geometry = try DisplayGeometryDTO(
            connectionEpoch: 3,
            geometryRevision: 5,
            logicalHeight: 1170,
            logicalWidth: 2532,
            orientation: .landscapeRight
        )
        store.registerPointer(
            sessionID: pointerSession,
            interactionID: pointerInteraction,
            geometry: geometry
        )
        func pointerFrame(
            sessionID: CanonicalUUID = pointerSession,
            interactionID: CanonicalUUID = pointerInteraction,
            connectionEpoch: UInt64 = 3,
            geometryRevision: UInt64 = 5
        ) throws -> RuntimeStreamFrameEnvelope {
            RuntimeStreamFrameEnvelope(
                sessionID: sessionID,
                interactionID: interactionID,
                sequence: 0,
                frameKind: "begin",
                payload: try Self.object([
                    ("edge", .string("top")),
                    ("expectedConnectionEpoch", .number(.uint64(connectionEpoch))),
                    ("expectedGeometryRevision", .number(.uint64(geometryRevision))),
                    ("x", .string("0.2")),
                    ("y", .string("0.7")),
                ]),
                clientSubmittedMonotonicNanoseconds: 1
            )
        }
        let projected = try store.payload(
            for: pointerFrame(),
            currentGeometry: geometry
        )
        XCTAssertEqual(
            try projected["x"]?.numberValue?.requireUInt64(),
            45_875
        )
        XCTAssertEqual(
            try projected["y"]?.numberValue?.requireUInt64(),
            52_428
        )
        XCTAssertEqual(projected["edge"]?.stringValue, "left")
        let rotatedGeometry = try DisplayGeometryDTO(
            connectionEpoch: 3,
            geometryRevision: 6,
            logicalHeight: 2532,
            logicalWidth: 1170,
            orientation: .portrait
        )
    XCTAssertThrowsError(
      try store.payload(
            for: pointerFrame(),
            currentGeometry: rotatedGeometry
      )
    ) {
            XCTAssertEqual(
                $0 as? ProductionRuntimeCoordinateProjectionError,
                .staleGeometry
            )
        }
    XCTAssertThrowsError(
      try store.payload(
            for: pointerFrame(connectionEpoch: 4),
            currentGeometry: geometry
      )
    ) {
            XCTAssertEqual(
                $0 as? ProductionRuntimeCoordinateProjectionError,
                .staleGeometry
            )
        }
    XCTAssertThrowsError(
      try store.payload(
            for: pointerFrame(geometryRevision: 6),
            currentGeometry: geometry
      )
    ) {
            XCTAssertEqual(
                $0 as? ProductionRuntimeCoordinateProjectionError,
                .staleGeometry
            )
        }
    XCTAssertThrowsError(
      try store.payload(
            for: pointerFrame(sessionID: CanonicalUUID(value: UUID())),
            currentGeometry: geometry
      )
    ) {
            XCTAssertEqual(
                $0 as? ProductionRuntimeCoordinateProjectionError,
                .unknownStream
            )
        }
    XCTAssertThrowsError(
      try store.payload(
            for: pointerFrame(interactionID: CanonicalUUID(value: UUID())),
            currentGeometry: geometry
      )
    ) {
            XCTAssertEqual(
                $0 as? ProductionRuntimeCoordinateProjectionError,
                .unknownStream
            )
        }

        let keyboardSession = CanonicalUUID(value: UUID())
        let keyboardInteraction = CanonicalUUID(value: UUID())
        store.registerKeyboard(
            sessionID: keyboardSession,
            interactionID: keyboardInteraction
        )
        let keyboardPayload = try Self.object([
      ("usages", .array([.number(.uint64(4)), .number(.uint64(225))]))
        ])
        let keyboardFrame = RuntimeStreamFrameEnvelope(
            sessionID: keyboardSession,
            interactionID: keyboardInteraction,
            sequence: 0,
            frameKind: "pressedSet",
            payload: keyboardPayload,
            clientSubmittedMonotonicNanoseconds: 2
        )
        XCTAssertEqual(
            try store.payload(
                for: keyboardFrame,
                currentGeometry: nil
            )["usages"]?.arrayValue?.count,
            2
        )
        XCTAssertEqual(
            try store.payload(
                for: keyboardFrame,
                currentGeometry: nil
            )["usages"]?.arrayValue?.first?.numberValue?.requireUInt64(),
            4
        )
        store.invalidateAll()
    XCTAssertThrowsError(
      try store.payload(
            for: pointerFrame(),
            currentGeometry: geometry
      )
    ) {
            XCTAssertEqual(
                $0 as? ProductionRuntimeCoordinateProjectionError,
                .unknownStream
            )
        }
    XCTAssertThrowsError(
      try store.payload(
            for: keyboardFrame,
            currentGeometry: nil
      )
    ) {
            XCTAssertEqual(
                $0 as? ProductionRuntimeCoordinateProjectionError,
                .unknownStream
            )
        }
        store.registerKeyboard(
            sessionID: keyboardSession,
            interactionID: keyboardInteraction
        )
        store.remove(
            sessionID: keyboardSession,
            interactionID: keyboardInteraction
        )
    XCTAssertThrowsError(
      try store.payload(
            for: keyboardFrame,
            currentGeometry: nil
      )
    ) {
            XCTAssertEqual(
                $0 as? ProductionRuntimeCoordinateProjectionError,
                .unknownStream
            )
        }
    }

    func testRuntimeCoordinateProjectionMatchesCommandAndPointerPaths() throws {
        let target = try CanonicalUDID(canonicalString: "M2031-PROJECTION-PARITY")
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(repositoryRoot: repositoryRoot()),
            discovery: {
                ProductionRuntimeDeviceObservation(
                    rawTransportUDID: target.rawValue,
                    facts: ProductionRuntimeDeviceFacts(
                        buildVersion: "23F84",
                        deviceClass: "iPhone",
                        deviceName: "Test iPhone",
                        productType: "iPhone14,7",
                        productVersion: "26.5.2",
                        uniqueDeviceID: target.rawValue
                    ),
                    condition: ProductionRuntimeDeviceCondition(
                        connected: true,
                        locked: false,
                        trusted: true
                    )
                )
            }
        )
        _ = try coordinator.refresh()
        let snapshot = try coordinator.updateGeometry(
            connectionEpoch: 1,
            geometryRevision: 7,
            logicalWidth: 2532,
            logicalHeight: 1170,
            orientation: .landscapeRight
        )
        let commandPayload = try XCTUnwrap(
            ProductionRuntimeOperationBackend.helperBackendPayload(
                commandID: "touch.tap",
                arguments: ["point": "0.2,0.7"],
                snapshot: snapshot
            )
        )
        guard case .array(let commandFrames) = commandPayload["frames"],
              case .object(let commandBegin) = commandFrames.first
        else {
            return XCTFail("expected projected touch frames")
        }

        let store = ProductionRuntimeCoordinateProjectionStore()
        let sessionID = CanonicalUUID(value: UUID())
        let interactionID = CanonicalUUID(value: UUID())
        store.registerPointer(
            sessionID: sessionID,
            interactionID: interactionID,
            geometry: try XCTUnwrap(snapshot.geometry)
        )
        let pointer = try store.payload(
            for: RuntimeStreamFrameEnvelope(
                sessionID: sessionID,
                interactionID: interactionID,
                sequence: 0,
                frameKind: "begin",
                payload: try Self.object([
                    ("edge", .string("none")),
                    ("expectedConnectionEpoch", .number(.uint64(1))),
                    ("expectedGeometryRevision", .number(.uint64(7))),
                    ("x", .string("0.2")),
                    ("y", .string("0.7")),
                ]),
                clientSubmittedMonotonicNanoseconds: 1
            ),
            currentGeometry: snapshot.geometry
        )
        XCTAssertEqual(
            commandBegin["x"]?.uintValue,
            try pointer["x"]?.numberValue?.requireUInt64()
        )
        XCTAssertEqual(
            commandBegin["y"]?.uintValue,
            try pointer["y"]?.numberValue?.requireUInt64()
        )
    }

    func testCaptureGenerationStateRecordsReadyAndReplacesOnlyOnce() throws {
        var noGeneration = ProductionCoreDeviceCaptureState()
        XCTAssertEqual(
            noGeneration.provenanceForSpawn(connectionEpoch: 7),
            .preCapture
        )
        XCTAssertEqual(
            noGeneration.noteCaptureReady(
                connectionEpoch: 7,
                activeProvenance: nil,
                activeExecutorGeneration: nil,
                hasActiveWork: false
            ),
            .ready
        )
        XCTAssertEqual(
            noGeneration.provenanceForSpawn(connectionEpoch: 7),
            .postCapture
        )

        var idlePreCapture = ProductionCoreDeviceCaptureState()
        XCTAssertEqual(
            idlePreCapture.noteCaptureReady(
                connectionEpoch: 9,
                activeProvenance: .preCapture,
                activeExecutorGeneration: 3,
                hasActiveWork: false
            ),
            .replace(oldExecutorGeneration: 3)
        )
        idlePreCapture.replacementFinished(connectionEpoch: 9)
    XCTAssertNil(
      idlePreCapture.pendingDecision(
            connectionEpoch: 9,
            activeProvenance: .postCapture,
            activeExecutorGeneration: 4,
            hasActiveWork: false
        ))
        XCTAssertEqual(
            idlePreCapture.noteCaptureReady(
                connectionEpoch: 9,
                activeProvenance: .postCapture,
                activeExecutorGeneration: 4,
                hasActiveWork: false
            ),
            .alreadyReady
        )
        XCTAssertEqual(
            idlePreCapture.provenanceForSpawn(connectionEpoch: 10),
            .preCapture
        )
    }

    func testCaptureGenerationStateDefersAcrossActiveStreamBarrier() throws {
        var state = ProductionCoreDeviceCaptureState()
        XCTAssertEqual(
            state.noteCaptureReady(
                connectionEpoch: 11,
                activeProvenance: .preCapture,
                activeExecutorGeneration: 5,
                hasActiveWork: true
            ),
            .deferred
        )
        XCTAssertTrue(state.replacementPending)
        XCTAssertEqual(
            state.pendingDecision(
                connectionEpoch: 11,
                activeProvenance: .preCapture,
                activeExecutorGeneration: 5,
                hasActiveWork: false
            ),
            .replace(oldExecutorGeneration: 5)
        )

        state.resetAfterDetach(connectionEpoch: 11)
        XCTAssertNil(state.connectionEpoch)
        XCTAssertFalse(state.captureReady)
        XCTAssertFalse(state.replacementPending)
        XCTAssertEqual(
            state.provenanceForSpawn(connectionEpoch: 11),
            .preCapture
        )
    }

    func testProductionExecutorReusesPostCaptureGenerationAcrossShortStreams() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }

        let ready = try context.executor.markLiveCaptureReady(
            device: context.device,
            connectionEpoch: 1
        )
        XCTAssertEqual(ready.disposition, .ready)

        for route in [
            "coredevice.pointerStream",
            "coredevice.keyboardStream",
            "coredevice.pointerStream",
        ] {
            let stream = try context.openStream(route: route, connectionEpoch: 1)
            XCTAssertEqual(stream.executorGeneration, 1)
            try context.sendFrame(stream, sequence: 0)
            try context.closeStream(stream)
        }

        var snapshot = context.executor.diagnosticSnapshot()
        XCTAssertEqual(snapshot.activeExecutorGeneration, 1)
        XCTAssertEqual(snapshot.activeProvenance, .postCapture)
        XCTAssertEqual(snapshot.activeStreamCount, 0)
        XCTAssertFalse(snapshot.captureReplacementPending)
        XCTAssertEqual(try context.manifest().helpers.map(\.executorGeneration), [1])

        let newEpochStream = try context.openStream(
            route: "coredevice.pointerStream",
            connectionEpoch: 2
        )
        XCTAssertEqual(newEpochStream.executorGeneration, 2)
        try context.closeStream(newEpochStream)
        let replaced = try context.executor.markLiveCaptureReady(
            device: context.device,
            connectionEpoch: 2
        )
        XCTAssertEqual(replaced.disposition, .replaced)
        XCTAssertEqual(replaced.oldExecutorGeneration, 2)
        XCTAssertEqual(replaced.newExecutorGeneration, 3)
        snapshot = context.executor.diagnosticSnapshot()
        XCTAssertEqual(snapshot.activeExecutorGeneration, 3)
        XCTAssertEqual(snapshot.activeProvenance, .postCapture)
    }

    func testSoftwareKeyboardToggleUsesCompletionBarrier() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }

        _ = try context.executor.executeOneShot(
            requestID: CanonicalUUID(value: UUID()),
            actionID: CanonicalUUID(value: UUID()),
            parentActionID: nil,
            routeID: "coredevice.softwareKeyboardToggle",
            backendPayload: ["commandID": .string("gui.softwareKeyboard.toggle")],
            device: context.device,
            connectionEpoch: 1,
            completionBarrierTimeoutMilliseconds: 500
        )

        XCTAssertTrue(context.completionBarrierObserved())
    }

    func testSoftwareKeyboardToggleBarrierTimeoutReleasesKeyboardResource() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        context.dropCompletionBarrier()

    XCTAssertThrowsError(
      try context.executor.executeOneShot(
            requestID: CanonicalUUID(value: UUID()),
            actionID: CanonicalUUID(value: UUID()),
            parentActionID: nil,
            routeID: "coredevice.softwareKeyboardToggle",
            backendPayload: ["commandID": .string("gui.softwareKeyboard.toggle")],
            device: context.device,
            connectionEpoch: 1,
            completionBarrierTimeoutMilliseconds: 20
      )
    ) {
            XCTAssertEqual(
                $0 as? ProductionCoreDeviceHelperExecutorError,
                .timedOut
            )
        }
        XCTAssertNil(context.executor.diagnosticSnapshot().activeExecutorGeneration)

        context.allowCompletionBarrier()
    XCTAssertNoThrow(
      try context.executor.executeOneShot(
            requestID: CanonicalUUID(value: UUID()),
            actionID: CanonicalUUID(value: UUID()),
            parentActionID: nil,
            routeID: "coredevice.softwareKeyboardToggle",
            backendPayload: ["commandID": .string("gui.softwareKeyboard.toggle")],
            device: context.device,
            connectionEpoch: 1,
            completionBarrierTimeoutMilliseconds: 500
        ))
    }

    func testKeyboardOneShotFailsFastWhileKeyboardStreamIsOpen() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        let stream = try context.openStream(
            route: "coredevice.keyboardStream",
            connectionEpoch: 1
        )

    XCTAssertThrowsError(
      try context.executor.executeOneShot(
            requestID: CanonicalUUID(value: UUID()),
            actionID: CanonicalUUID(value: UUID()),
            parentActionID: nil,
            routeID: "coredevice.keyboardMacro",
            backendPayload: ["commandID": .string("text.clear")],
            device: context.device,
            connectionEpoch: 1
      )
    ) {
            XCTAssertEqual(
                $0 as? ProductionCoreDeviceHelperExecutorError,
                .resourceBusy
            )
        }

        try context.closeStream(stream)
    XCTAssertNoThrow(
      try context.executor.executeOneShot(
            requestID: CanonicalUUID(value: UUID()),
            actionID: CanonicalUUID(value: UUID()),
            parentActionID: nil,
            routeID: "coredevice.keyboardMacro",
            backendPayload: ["commandID": .string("text.clear")],
            device: context.device,
            connectionEpoch: 1
        ))
    }

    func testConcurrentKeyboardOneShotsFailFast() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        let finished = expectation(description: "keyboard one-shot terminal")
        let errors = LockedErrorStore()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { finished.fulfill() }
            do {
                _ = try context.executor.executeOneShot(
                    requestID: CanonicalUUID(value: UUID()),
                    actionID: CanonicalUUID(value: UUID()),
                    parentActionID: nil,
                    routeID: "coredevice.pasteboardSetAndPaste",
                    backendPayload: ["fixture": .string("test.block")],
                    device: context.device,
                    connectionEpoch: 1
                )
            } catch {
                errors.store(error)
            }
        }
        try context.waitForBlockedOneShot()

    XCTAssertThrowsError(
      try context.executor.executeOneShot(
            requestID: CanonicalUUID(value: UUID()),
            actionID: CanonicalUUID(value: UUID()),
            parentActionID: nil,
            routeID: "coredevice.keyboardMacro",
            backendPayload: ["commandID": .string("text.clear")],
            device: context.device,
            connectionEpoch: 1
      )
    ) {
            XCTAssertEqual(
                $0 as? ProductionCoreDeviceHelperExecutorError,
                .resourceBusy
            )
        }

        context.releaseBlockedOneShot()
        wait(for: [finished], timeout: 2)
        XCTAssertNil(errors.error)
    }

    func testDirectOneShotSharesManifestWithoutRetiringCoreDeviceStream() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        defer { context.releaseBlockedDirectOneShot() }
        let stream = try context.openStream(
            route: "coredevice.pointerStream",
            connectionEpoch: 1
        )
        let errors = LockedErrorStore()
        let finished = expectation(description: "direct one-shot terminal")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { finished.fulfill() }
            do {
                _ = try context.directExecutor.executeOneShot(
                    requestID: CanonicalUUID(value: UUID()),
                    actionID: CanonicalUUID(value: UUID()),
                    parentActionID: nil,
                    routeID: "direct.installationProxy.install",
                    backendPayload: ["fixture": .string("test.block")],
                    device: context.device,
                    connectionEpoch: 1
                )
            } catch {
                errors.store(error)
            }
        }
        try context.waitForBlockedDirectOneShot()
        XCTAssertEqual(
            try context.manifest().helpers.map(\.helperID),
            ["coredevice-1", "direct-1"]
        )
        XCTAssertEqual(
            context.executor.diagnosticSnapshot().activeStreamCount,
            1
        )
        context.releaseBlockedDirectOneShot()
        wait(for: [finished], timeout: 3)
        XCTAssertNil(errors.error)
        XCTAssertEqual(
            try context.manifest().helpers.map(\.helperID),
            ["coredevice-1"]
        )
        try context.sendFrame(stream, sequence: 0)
        try context.closeStream(stream)
    }

    func testHelperStreamRejectsCanonicalDecimalWithoutRetiringStream() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        let stream = try context.openStream(
            route: "coredevice.pointerStream",
            connectionEpoch: 1
        )
        let payload = try RepositoryJSONObject(members: [
            RepositoryJSONMember(
                key: "x",
                value: .number(.decimal(try RepositoryJSONDecimal("0.5")))
      )
        ])

    XCTAssertThrowsError(
      try context.executor.sendStreamFrame(
            RuntimeStreamFrameEnvelope(
                sessionID: stream.sessionID,
                interactionID: stream.interactionID,
                sequence: 0,
                frameKind: "begin",
                payload: payload,
                clientSubmittedMonotonicNanoseconds: 1
            )
      )
    ) { error in
            XCTAssertEqual(
                error as? ProductionCoreDeviceHelperExecutorError,
                .invalidRequest
            )
        }
        XCTAssertEqual(
            context.executor.diagnosticSnapshot().activeStreamCount,
            1
        )
        try context.sendFrame(stream, sequence: 0)
        try context.closeStream(stream)
    }

    func testDirectHelperStartupFailureIsKnownPrecommit() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        try context.removeDirectImplementation()
        XCTAssertThrowsError(
            try context.directExecutor.executeOneShot(
                requestID: CanonicalUUID(value: UUID()),
                actionID: CanonicalUUID(value: UUID()),
                parentActionID: nil,
                routeID: "direct.installationProxy.install",
                backendPayload: ["operation": .string("install")],
                device: context.device,
                connectionEpoch: 1
            )
        ) { error in
            XCTAssertEqual(
                error as? ProductionCoreDeviceHelperExecutorError,
                .helperUnavailableBeforeRequest
            )
        }
        XCTAssertNil(
            context.directExecutor.diagnosticSnapshot().activeExecutorGeneration
        )
    }

    func testProductionExecutorQueriesCurrentDisplayGeometryOverHelperWire() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }

        let result = try context.executor.executeOneShot(
            requestID: CanonicalUUID(value: UUID()),
            actionID: CanonicalUUID(value: UUID()),
            parentActionID: nil,
            routeID: "coredevice.displayGeometry.query",
            backendPayload: [
        "commandID": .string("runtime.displayGeometry.query")
            ],
            device: context.device,
            connectionEpoch: 1
        )
        XCTAssertEqual(result["outcome"]?.stringValue, "succeeded")
        let value = try XCTUnwrap(result["value"]?.objectValue)
        XCTAssertEqual(
            value["resolvedRouteID"]?.stringValue,
            "coredevice.displayGeometry.query"
        )
        XCTAssertEqual(
            try value["logicalWidth"]?.numberValue?.requireUInt64(),
            2532
        )
        XCTAssertEqual(
            try value["logicalHeight"]?.numberValue?.requireUInt64(),
            1170
        )
        XCTAssertEqual(value["orientation"]?.stringValue, "landscapeRight")
    }

    func testProductionExecutorNotifiesAcceptedOnceBeforeOneShotTerminal() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        defer { context.releaseBlockedOneShot() }
        let accepted = LockedCallCounter()
        let acceptedNotification = expectation(description: "one-shot accepted")
        let errors = LockedErrorStore()
        let finished = expectation(description: "one-shot terminal")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { finished.fulfill() }
            do {
                _ = try context.executor.executeOneShot(
                    requestID: CanonicalUUID(value: UUID()),
                    actionID: CanonicalUUID(value: UUID()),
                    parentActionID: nil,
                    routeID: "test.block",
                    backendPayload: [:],
                    device: context.device,
                    connectionEpoch: 1,
                    onAccepted: {
                        accepted.increment()
                        acceptedNotification.fulfill()
                    }
                )
            } catch {
                errors.store(error)
            }
        }
        try context.waitForBlockedOneShot()
        wait(for: [acceptedNotification], timeout: 1)
        XCTAssertEqual(accepted.value, 1)
        context.releaseBlockedOneShot()
        wait(for: [finished], timeout: 3)
        XCTAssertEqual(accepted.value, 1)
        XCTAssertNil(errors.error)
    }

    func testProductionExecutorCancellationInterruptsBlockedCaptureAndRetiresHelper()
        throws
    {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        defer { context.releaseBlockedOneShot() }
        let cancellation = ProductionElementSnapshotCancellation()
        let errors = LockedErrorStore()
        let finished = expectation(description: "cancelled one-shot terminal")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { finished.fulfill() }
            do {
                _ = try context.executor.executeOneShot(
                    requestID: CanonicalUUID(value: UUID()),
                    actionID: CanonicalUUID(value: UUID()),
                    parentActionID: nil,
                    routeID: "test.block",
                    backendPayload: [:],
                    device: context.device,
                    connectionEpoch: 1,
                    cancellation: cancellation
                )
            } catch {
                errors.store(error)
            }
        }
        try context.waitForBlockedOneShot()
        cancellation.cancel(cause: .authorityChanged)
        wait(for: [finished], timeout: 2)
        XCTAssertTrue(errors.error is CancellationError)
        let diagnostic = context.executor.diagnosticSnapshot()
        XCTAssertNil(
            diagnostic.activeExecutorGeneration,
            "a cancelled capture must not reuse its helper generation"
        )
        XCTAssertNil(diagnostic.lastErrorCode)
    }

    func testProductionExecutorDefersReplacementAcrossOneShotAndStreamBarriers() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        let stream = try context.openStream(
            route: "coredevice.pointerStream",
            connectionEpoch: 1
        )
        XCTAssertEqual(stream.executorGeneration, 1)

        let finished = expectation(description: "blocked one-shot completed")
        let errors = LockedErrorStore()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { finished.fulfill() }
            do {
                _ = try context.executor.executeOneShot(
                    requestID: CanonicalUUID(value: UUID()),
                    actionID: CanonicalUUID(value: UUID()),
                    parentActionID: nil,
                    routeID: "test.block",
                    backendPayload: [:],
                    device: context.device,
                    connectionEpoch: 1
                )
            } catch {
                errors.store(error)
            }
        }
        try context.waitForBlockedOneShot()

        let deferred = try context.executor.markLiveCaptureReady(
            device: context.device,
            connectionEpoch: 1
        )
        XCTAssertEqual(deferred.disposition, .deferred)
        context.releaseBlockedOneShot()
        wait(for: [finished], timeout: 3)
        XCTAssertNil(errors.error)

        var snapshot = context.executor.diagnosticSnapshot()
        XCTAssertEqual(snapshot.activeExecutorGeneration, 1)
        XCTAssertEqual(snapshot.activeProvenance, .preCapture)
        XCTAssertEqual(snapshot.activeStreamCount, 1)
        XCTAssertTrue(snapshot.captureReplacementPending)

        try context.closeStream(stream)
        snapshot = context.executor.diagnosticSnapshot()
        XCTAssertEqual(snapshot.activeExecutorGeneration, 2)
        XCTAssertEqual(snapshot.activeProvenance, .postCapture)
        XCTAssertEqual(snapshot.activeStreamCount, 0)
        XCTAssertFalse(snapshot.captureReplacementPending)

        let keyboard = try context.openStream(
            route: "coredevice.keyboardStream",
            connectionEpoch: 1
        )
        XCTAssertEqual(keyboard.executorGeneration, 2)
        try context.closeStream(keyboard)
        XCTAssertEqual(
            context.executor.diagnosticSnapshot().activeExecutorGeneration,
            2
        )
    }

    func testProductionExecutorAppliesDeferredReplacementAfterOneShotTerminal() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        let finished = expectation(description: "one-shot terminal replacement")
        let errors = LockedErrorStore()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { finished.fulfill() }
            do {
                _ = try context.executor.executeOneShot(
                    requestID: CanonicalUUID(value: UUID()),
                    actionID: CanonicalUUID(value: UUID()),
                    parentActionID: nil,
                    routeID: "test.block",
                    backendPayload: [:],
                    device: context.device,
                    connectionEpoch: 1
                )
            } catch {
                errors.store(error)
            }
        }
        try context.waitForBlockedOneShot()
        let deferred = try context.executor.markLiveCaptureReady(
            device: context.device,
            connectionEpoch: 1
        )
        XCTAssertEqual(deferred.disposition, .deferred)
        context.releaseBlockedOneShot()
        wait(for: [finished], timeout: 3)
        XCTAssertNil(errors.error)
        let snapshot = context.executor.diagnosticSnapshot()
        XCTAssertEqual(snapshot.activeExecutorGeneration, 2)
        XCTAssertEqual(snapshot.activeProvenance, .postCapture)
        XCTAssertFalse(snapshot.captureReplacementPending)
        XCTAssertEqual(try context.manifest().helpers.map(\.executorGeneration), [2])
    }

    func testProductionExecutorWarmsReplacementBeforePublishingCaptureReady() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        let stream = try context.openStream(
            route: "coredevice.pointerStream",
            connectionEpoch: 1
        )
        try context.closeStream(stream)
        context.blockWarmGeneration()

        let finished = expectation(description: "capture-ready replacement completed")
        let errors = LockedErrorStore()
        let results = LockedCaptureReadyResultStore()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { finished.fulfill() }
            do {
        results.store(
          try context.executor.markLiveCaptureReady(
                    device: context.device,
                    connectionEpoch: 1
                ))
            } catch {
                errors.store(error)
            }
        }

        try context.waitForBlockedOneShot()
        XCTAssertNil(results.result)
        context.releaseBlockedOneShot()
        wait(for: [finished], timeout: 3)

        XCTAssertNil(errors.error)
        XCTAssertEqual(results.result?.disposition, .replaced)
        XCTAssertEqual(results.result?.oldExecutorGeneration, 1)
        XCTAssertEqual(results.result?.newExecutorGeneration, 2)
        XCTAssertEqual(
            context.executor.diagnosticSnapshot().activeProvenance,
            .postCapture
        )
    }

    func testProductionExecutorWarmFailureRetiresReplacementAndRecovers() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        let stream = try context.openStream(
            route: "coredevice.pointerStream",
            connectionEpoch: 1
        )
        try context.closeStream(stream)
        context.failWarmGeneration()

    XCTAssertThrowsError(
      try context.executor.markLiveCaptureReady(
            device: context.device,
            connectionEpoch: 1
      )
    ) {
            XCTAssertEqual(
                $0 as? ProductionCoreDeviceHelperExecutorError,
                .helperRejected(
                    code: "developerServicesUnavailable",
                    phase: "startingDeviceServices"
                )
            )
        }
        var snapshot = context.executor.diagnosticSnapshot()
        XCTAssertNil(snapshot.activeExecutorGeneration)
        XCTAssertFalse(snapshot.captureReplacementPending)
        XCTAssertEqual(snapshot.lastFailureOperation, .generationReplacement)
        XCTAssertEqual(snapshot.lastFailureStage, .tunnelOrRSD)
        XCTAssertTrue(try context.manifest().helpers.isEmpty)

        context.allowWarmGeneration()
        let recovered = try context.openStream(
            route: "coredevice.keyboardStream",
            connectionEpoch: 1
        )
        XCTAssertEqual(recovered.executorGeneration, 3)
        snapshot = context.executor.diagnosticSnapshot()
        XCTAssertEqual(snapshot.activeProvenance, .postCapture)
        try context.closeStream(recovered)
    }

    func testProductionExecutorFaultsRetireHelperAndProjectFailureStage() throws {
        try assertExecutorFault(
            route: "test.serviceFailure",
            expectedError: .helperRejected(
                code: "developerServicesUnavailable",
                phase: "openingInputService"
            ),
            expectedOperation: .streamOpen,
            expectedStage: .inputServiceOpen
        ) { context, _ in
            _ = try context.openStream(route: "test.serviceFailure", connectionEpoch: 1)
        }

        try assertExecutorFault(
            route: "test.frameTimeout",
            expectedError: .timedOut,
            expectedOperation: .frameAccepted,
            expectedStage: .frameAccepted
        ) { context, route in
            let stream = try context.openStream(route: route, connectionEpoch: 1)
            try context.sendFrame(stream, sequence: 0)
        }

        try assertExecutorFault(
            route: "test.frameExit",
            expectedError: .processExited,
            expectedOperation: .frameAccepted,
            expectedStage: .frameAccepted
        ) { context, route in
            let stream = try context.openStream(route: route, connectionEpoch: 1)
            try context.sendFrame(stream, sequence: 0)
        }

        try assertExecutorFault(
            route: "test.cleanupFailure",
            expectedError: .helperRejected(
                code: "developerServicesUnavailable",
                phase: "closingInputService"
            ),
            expectedOperation: .streamCleanup,
            expectedStage: .cleanup
        ) { context, route in
            let stream = try context.openStream(route: route, connectionEpoch: 1)
            try context.closeStream(stream)
        }
    }

    func testProductionExecutorDiagnosticsDoNotCrossConnectionEpochs() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }

        XCTAssertThrowsError(
            try context.openStream(route: "test.serviceFailure", connectionEpoch: 1)
        )
        var snapshot = context.executor.diagnosticSnapshot()
        XCTAssertEqual(snapshot.connectionEpoch, 1)
        XCTAssertEqual(snapshot.lastFailureOperation, .streamOpen)

        let ready = try context.executor.markLiveCaptureReady(
            device: context.device,
            connectionEpoch: 2
        )
        XCTAssertEqual(ready.disposition, .ready)
        snapshot = context.executor.diagnosticSnapshot()
        XCTAssertEqual(snapshot.connectionEpoch, 2)
        XCTAssertNil(snapshot.lastErrorCode)
        XCTAssertNil(snapshot.lastFailureOperation)
        XCTAssertNil(snapshot.lastFailureStage)
    }

    func testProductionExecutorReplacementFailureCleansManifestAndRecoversOnDemand() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        let stream = try context.openStream(
            route: "coredevice.pointerStream",
            connectionEpoch: 1
        )
        try context.closeStream(stream)
        try context.disableHelperExecutable()

    XCTAssertThrowsError(
      try context.executor.markLiveCaptureReady(
            device: context.device,
            connectionEpoch: 1
      )
    ) {
            XCTAssertEqual(
                $0 as? ProductionCoreDeviceHelperExecutorError,
                .invalidBundledResources
            )
        }
        var snapshot = context.executor.diagnosticSnapshot()
        XCTAssertNil(snapshot.activeExecutorGeneration)
        XCTAssertFalse(snapshot.captureReplacementPending)
        XCTAssertEqual(snapshot.lastFailureOperation, .generationReplacement)
        XCTAssertEqual(snapshot.lastFailureStage, .helperSpawn)
        XCTAssertEqual(snapshot.lastErrorCode, "capabilityPreparing")
        XCTAssertTrue(try context.manifest().helpers.isEmpty)

        try context.compileHelper()
        let recovered = try context.openStream(
            route: "coredevice.keyboardStream",
            connectionEpoch: 1
        )
        XCTAssertEqual(recovered.executorGeneration, 3)
        snapshot = context.executor.diagnosticSnapshot()
        XCTAssertEqual(snapshot.activeProvenance, .postCapture)
        try context.closeStream(recovered)
    }

    func testProductionExecutorDetachResetsCaptureProofAndRetiresGeneration() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        _ = try context.executor.markLiveCaptureReady(
            device: context.device,
            connectionEpoch: 1
        )
        let first = try context.openStream(
            route: "coredevice.pointerStream",
            connectionEpoch: 1
        )
        try context.closeStream(first)
        XCTAssertEqual(first.executorGeneration, 1)

        context.executor.retireForDetach(connectionEpoch: 1)
        var snapshot = context.executor.diagnosticSnapshot()
        XCTAssertNil(snapshot.activeExecutorGeneration)
        XCTAssertNil(snapshot.connectionEpoch)
        XCTAssertTrue(try context.manifest().helpers.isEmpty)

        let afterDetach = try context.openStream(
            route: "coredevice.pointerStream",
            connectionEpoch: 1
        )
        XCTAssertEqual(afterDetach.executorGeneration, 2)
        try context.closeStream(afterDetach)
        let replacement = try context.executor.markLiveCaptureReady(
            device: context.device,
            connectionEpoch: 1
        )
        XCTAssertEqual(replacement.oldExecutorGeneration, 2)
        XCTAssertEqual(replacement.newExecutorGeneration, 3)
        snapshot = context.executor.diagnosticSnapshot()
        XCTAssertEqual(snapshot.activeProvenance, .postCapture)
    }

    func testExecutorDiagnosticSnapshotUsesBoundedRuntimeStatusProjection() throws {
        let summary = try ProductionRuntimeOperationBackend.executorSummary(
            ProductionCoreDeviceHelperDiagnosticSnapshot(
                activeExecutorGeneration: 7,
                activeProvenance: .postCapture,
                activeStreamCount: 1,
                captureReplacementPending: true,
                connectionEpoch: 4,
                lastErrorCode: "transportFailure",
                lastFailureOperation: .frameAccepted,
                lastFailureStage: .frameAccepted
            )
        )
        XCTAssertEqual(
            summary["activeExecutorGeneration"]?.numberValue.flatMap {
                try? $0.requireUInt64()
            },
            7
        )
        XCTAssertEqual(summary["activeProvenance"]?.stringValue, "postCapture")
        XCTAssertEqual(summary["lastFailureOperation"]?.stringValue, "frameAccepted")
        XCTAssertEqual(summary["lastFailureStage"]?.stringValue, "frameAccepted")
        XCTAssertNil(summary["rawTransportUDID"])
        XCTAssertNil(summary["canonicalUDID"])
    }

    func testPeerLiveStateRejectsForeignStaleAndConflictingCaptureProof() throws {
        let target = try CanonicalUDID(
            canonicalString: "00008110-001A7D523E90401E"
        )
        let owner = CanonicalUUID(value: UUID())
        let subscription = CanonicalUUID(value: UUID())
        let activation = CanonicalUUID(value: UUID())
        var state = ProductionRuntimePeerLiveState()
    XCTAssertTrue(
      state.attach(
            canonicalUDID: target,
            connectionEpoch: 12,
            liveOwnerID: owner,
            subscriptionID: subscription
        ))
    XCTAssertEqual(
      try state.validateCaptureReady(
            canonicalUDID: target,
            connectionEpoch: 12,
            liveOwnerID: owner,
            subscriptionID: subscription,
            captureActivationID: activation
        ), .new)
        state.commitCaptureActivation(activation)
    XCTAssertEqual(
      try state.validateCaptureReady(
            canonicalUDID: target,
            connectionEpoch: 12,
            liveOwnerID: owner,
            subscriptionID: subscription,
            captureActivationID: activation
        ), .duplicate)

    XCTAssertThrowsError(
      try state.validateCaptureReady(
            canonicalUDID: target,
            connectionEpoch: 13,
            liveOwnerID: owner,
            subscriptionID: subscription,
            captureActivationID: activation
      )
    ) {
            XCTAssertEqual(
                $0 as? ProductionRuntimePeerLiveValidationError,
                .staleConnectionEpoch
            )
        }
    XCTAssertThrowsError(
      try state.validateCaptureReady(
            canonicalUDID: target,
            connectionEpoch: 12,
            liveOwnerID: CanonicalUUID(value: UUID()),
            subscriptionID: subscription,
            captureActivationID: activation
      )
    ) {
            XCTAssertEqual(
                $0 as? ProductionRuntimePeerLiveValidationError,
                .ownerConflict
            )
        }
    XCTAssertThrowsError(
      try state.validateCaptureReady(
            canonicalUDID: target,
            connectionEpoch: 12,
            liveOwnerID: owner,
            subscriptionID: subscription,
            captureActivationID: CanonicalUUID(value: UUID())
      )
    ) {
            XCTAssertEqual(
                $0 as? ProductionRuntimePeerLiveValidationError,
                .activationConflict
            )
        }

        try state.detach(
            canonicalUDID: target,
            liveOwnerID: owner,
            subscriptionID: subscription
        )
        XCTAssertFalse(state.isAttached)
        XCTAssertNil(state.captureActivationID)
    XCTAssertThrowsError(
      try state.validateCaptureReady(
            canonicalUDID: target,
            connectionEpoch: 12,
            liveOwnerID: owner,
            subscriptionID: subscription,
            captureActivationID: activation
      )
    ) {
            XCTAssertEqual(
                $0 as? ProductionRuntimePeerLiveValidationError,
                .notAttached
            )
        }
        let replacementOwner = CanonicalUUID(value: UUID())
        let replacementSubscription = CanonicalUUID(value: UUID())
    XCTAssertTrue(
      state.attach(
            canonicalUDID: target,
            connectionEpoch: 12,
            liveOwnerID: replacementOwner,
            subscriptionID: replacementSubscription
        ))
    XCTAssertEqual(
      try state.validateCaptureReady(
            canonicalUDID: target,
            connectionEpoch: 12,
            liveOwnerID: replacementOwner,
            subscriptionID: replacementSubscription,
            captureActivationID: activation
        ), .new)

        var disconnected = ProductionRuntimePeerLiveState()
    XCTAssertTrue(
      disconnected.attach(
            canonicalUDID: target,
            connectionEpoch: 0,
            liveOwnerID: CanonicalUUID(value: UUID()),
            subscriptionID: CanonicalUUID(value: UUID())
        ))

        var reconnecting = ProductionRuntimePeerLiveState()
    XCTAssertTrue(
      reconnecting.attach(
            canonicalUDID: target,
            connectionEpoch: 7,
            liveOwnerID: owner,
            subscriptionID: subscription
        ))
        reconnecting.commitCaptureActivation(activation)
        XCTAssertTrue(reconnecting.invalidateForDisconnect(connectionEpoch: 7))
        XCTAssertNil(reconnecting.captureActivationID)
        XCTAssertEqual(reconnecting.liveOwnerID, owner)
        XCTAssertEqual(reconnecting.subscriptionID, subscription)
        XCTAssertFalse(reconnecting.invalidateForDisconnect(connectionEpoch: 7))
        XCTAssertTrue(reconnecting.replaceConnectionEpoch(8))
        XCTAssertEqual(reconnecting.connectionEpoch, 8)
        XCTAssertEqual(reconnecting.liveOwnerID, owner)
        XCTAssertEqual(reconnecting.subscriptionID, subscription)
        XCTAssertFalse(reconnecting.replaceConnectionEpoch(8))
    }

    func testDeviceCoordinatorReconnectPreservesLiveDemandAndAdvancesEpochOnce()
        throws
    {
        let target = try CanonicalUDID(
            canonicalString: "M2031-RECONNECT-COORDINATOR"
        )
        let discovery = LockedDeviceDiscoveryState(
            device: Self.deviceObservation(target: target)
        )
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(repositoryRoot: repositoryRoot()),
            discovery: { discovery.device }
        )
        let initial = try coordinator.refreshConnectionTransition()
        XCTAssertEqual(initial.kind, .attached)
        XCTAssertEqual(initial.snapshot.connectionEpoch, 1)
        _ = try coordinator.setLiveAttached(true)
        _ = try coordinator.updateGeometry(
            connectionEpoch: 1,
            geometryRevision: 1,
            logicalWidth: 1_170,
            logicalHeight: 2_532,
            orientation: .portrait
        )

        discovery.device = nil
        let detached = try coordinator.confirmDisconnected()
        XCTAssertEqual(
            detached.kind,
            .detached(previousConnectionEpoch: 1)
        )
        XCTAssertEqual(detached.snapshot.connectionEpoch, 1)
        XCTAssertNil(detached.snapshot.device)
        XCTAssertNil(detached.snapshot.geometry)
        XCTAssertTrue(coordinator.hasPersistentLiveDemand)
        XCTAssertEqual(
            try coordinator.confirmDisconnected().kind,
            .unchanged
        )

        discovery.device = Self.deviceObservation(target: target)
        let reattached = try coordinator.refreshConnectionTransition()
        XCTAssertEqual(reattached.kind, .attached)
        XCTAssertEqual(reattached.snapshot.connectionEpoch, 2)
        XCTAssertTrue(coordinator.hasPersistentLiveDemand)
        XCTAssertEqual(
            try coordinator.refreshConnectionTransition().kind,
            .unchanged
        )
        XCTAssertEqual(try coordinator.refresh().connectionEpoch, 2)
    }

    func testLiveRefreshCannotConsumeTransientReconnectInventoryEdges() throws {
        let target = try CanonicalUDID(
            canonicalString: "M2031-LIVE-REFRESH-FENCE"
        )
        let observation = Self.deviceObservation(target: target)
        let discovery = LockedDeviceDiscoveryState(device: observation)
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(repositoryRoot: repositoryRoot()),
            discovery: { discovery.device }
        )

        let initial = try coordinator.refreshConnectionTransition()
        XCTAssertEqual(initial.kind, .attached)
        XCTAssertEqual(initial.snapshot.connectionEpoch, 1)
        _ = try coordinator.setLiveAttached(true)

        discovery.device = nil
        let detached = try coordinator.refreshConnectionTransition()
        XCTAssertEqual(
            detached.kind,
            .detached(previousConnectionEpoch: 1)
        )

        discovery.device = observation
        let reattached = try coordinator.refreshConnectionTransition()
        XCTAssertEqual(reattached.kind, .attached)
        XCTAssertEqual(reattached.snapshot.connectionEpoch, 2)

        discovery.device = nil
        let availability = try coordinator.availabilityValue()
        XCTAssertEqual(
            try availability["connectionEpoch"]?.numberValue?.requireUInt64(),
            2
        )
        XCTAssertNotNil(try coordinator.refresh().device)

        discovery.device = observation
        let stable = try coordinator.refreshConnectionTransition()
        XCTAssertEqual(stable.kind, .unchanged)
        XCTAssertEqual(stable.snapshot.connectionEpoch, 2)
    }

    func testAttachOnlyTransitionCannotDetachConnectedSnapshot() throws {
        let target = try CanonicalUDID(
            canonicalString: "M2031-ATTACH-ONLY-TRANSITION"
        )
        let observation = Self.deviceObservation(target: target)
        let discovery = LockedDeviceDiscoveryState(device: observation)
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(repositoryRoot: repositoryRoot()),
            discovery: { discovery.device }
        )

        let initial = try coordinator.refreshConnectionTransition()
        XCTAssertEqual(initial.kind, .attached)
        XCTAssertEqual(initial.snapshot.connectionEpoch, 1)

        discovery.device = nil
        let transient = try coordinator.refreshConnectionTransition(
            allowDetachment: false
        )
        XCTAssertEqual(transient.kind, .unchanged)
        XCTAssertEqual(transient.snapshot.connectionEpoch, 1)
        XCTAssertNotNil(transient.snapshot.device)
        XCTAssertTrue(coordinator.hasConnectedDevice)

        let detached = try coordinator.refreshConnectionTransition()
        XCTAssertEqual(
            detached.kind,
            .detached(previousConnectionEpoch: 1)
        )
        XCTAssertFalse(coordinator.hasConnectedDevice)
    }

    func testRefreshStartedBeforeLiveAttachCannotOverwriteCachedConnection() throws {
        let target = try CanonicalUDID(
            canonicalString: "M2031-LIVE-REFRESH-RACE"
        )
        let observation = Self.deviceObservation(target: target)
        let discovery = BlockingDeviceDiscoveryState(device: observation)
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(repositoryRoot: repositoryRoot()),
            discovery: { discovery.discover() }
        )

        let initial = try coordinator.refreshConnectionTransition()
        XCTAssertEqual(initial.kind, .attached)
        XCTAssertEqual(initial.snapshot.connectionEpoch, 1)

        discovery.device = nil
        discovery.blockNextDiscovery()
        let refreshFinished = expectation(description: "refresh finished")
        let result = LockedRuntimeDeviceSnapshotStore()
        DispatchQueue.global().async {
            do {
                result.store(try coordinator.refresh())
            } catch {
                result.store(error)
            }
            refreshFinished.fulfill()
        }

        XCTAssertEqual(discovery.waitUntilBlocked(), .success)
        let attached = try coordinator.setLiveAttached(true)
        XCTAssertEqual(attached.connectionEpoch, 1)
        XCTAssertNotNil(attached.device)
        discovery.resumeDiscovery()
        wait(for: [refreshFinished], timeout: 1)

        XCTAssertNil(result.error)
        XCTAssertEqual(result.snapshot?.connectionEpoch, 1)
        XCTAssertNotNil(result.snapshot?.device)

        let detached = try coordinator.refreshConnectionTransition()
        XCTAssertEqual(
            detached.kind,
            .detached(previousConnectionEpoch: 1)
        )
    }

    func testUSBMonitorParsesAndReducesExactTargetEventsIdempotently() throws {
        let target = try CanonicalUDID(
            canonicalString: "00008110-001A7D523E90401E"
        )
        let attachedPayload = try PropertyListSerialization.data(
            fromPropertyList: [
                "DeviceID": 17,
                "MessageType": "Attached",
                "Properties": [
                    "ConnectionType": "USB",
                    "SerialNumber": target.rawValue.lowercased(),
                ],
            ],
            format: .binary,
            options: 0
        )
        XCTAssertEqual(
            try ProductionUSBDeviceMonitor.decodeEventPayload(attachedPayload),
            .attached(
                deviceID: 17,
                rawTransportUDID: target.rawValue.lowercased(),
                usb: true
            )
        )
        let detachedPayload = try PropertyListSerialization.data(
            fromPropertyList: [
                "DeviceID": 17,
                "MessageType": "Detached",
            ],
            format: .xml,
            options: 0
        )
        XCTAssertEqual(
            try ProductionUSBDeviceMonitor.decodeEventPayload(detachedPayload),
            .detached(deviceID: 17)
        )

        var reducer = ProductionUSBDevicePresenceReducer(canonicalUDID: target)
    XCTAssertNil(
      reducer.consume(
        .attached(
            deviceID: 1,
            rawTransportUDID: "OTHER-DEVICE",
            usb: true
        )))
    XCTAssertNil(
      reducer.consume(
        .attached(
            deviceID: 2,
            rawTransportUDID: target.rawValue,
            usb: false
        )))
        XCTAssertEqual(
      reducer.consume(
        .attached(
                deviceID: 17,
                rawTransportUDID: target.rawValue.lowercased(),
                usb: true
            )),
            .attached(rawTransportUDID: target.rawValue.lowercased())
        )
    XCTAssertNil(
      reducer.consume(
        .attached(
            deviceID: 17,
            rawTransportUDID: target.rawValue.lowercased(),
            usb: true
        )))
    XCTAssertNil(
      reducer.consume(
        .attached(
            deviceID: 18,
            rawTransportUDID: target.rawValue,
            usb: true
        )))
        XCTAssertNil(reducer.consume(.detached(deviceID: 17)))
        XCTAssertEqual(reducer.consume(.detached(deviceID: 18)), .detached)
        XCTAssertNil(reducer.consume(.detached(deviceID: 18)))
        reducer.resetTransportSession()
        XCTAssertEqual(
      reducer.consume(
        .attached(
                deviceID: 19,
                rawTransportUDID: target.rawValue,
                usb: true
            )),
            .attached(rawTransportUDID: target.rawValue)
        )
    }

    func testCaptureReadyBackendFailureMapsToCapabilityPreparing() throws {
        let backend = ProductionRuntimeOperationBackend(
            handler: { _ in .failed(code: "invalidArgument") },
            captureReadyHandler: { _, _ in
                throw POSIXError(.EIO)
            }
        )
        let result = try backend.markLiveCaptureReady(
            connectionEpoch: 3,
            captureActivationID: CanonicalUUID(value: UUID())
        )
        guard case .failed(let code) = result else {
            return XCTFail("expected typed failure")
        }
        XCTAssertEqual(code, "capabilityPreparing")
    }

    func testDuplicateCaptureReadyReturnsCurrentGeometryWithoutNewGeneration()
        throws
    {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        let target = try CanonicalUDID(
            canonicalString: context.device.facts.uniqueDeviceID
        )
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(
                repositoryRoot: repositoryRoot()
            ),
            discovery: { context.device }
        )
        _ = try coordinator.refresh()
        _ = try coordinator.setLiveAttached(true)
        _ = try coordinator.refresh()
        let ready = try context.executor.markLiveCaptureReady(
            device: context.device,
            connectionEpoch: 1
        )
        XCTAssertEqual(ready.disposition, .ready)
        _ = try context.executor.executeOneShot(
            requestID: CanonicalUUID(value: UUID()),
            actionID: CanonicalUUID(value: UUID()),
            parentActionID: nil,
            routeID: "coredevice.displayGeometry.query",
            backendPayload: [
        "commandID": .string("runtime.displayGeometry.query")
            ],
            device: context.device,
            connectionEpoch: 1
        )
        let generation = context.executor.diagnosticSnapshot()
            .activeExecutorGeneration
        XCTAssertNotNil(generation)
        let screenshotRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PulsePhone-DuplicateCaptureReady-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: screenshotRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: screenshotRoot) }
        let screenshotStore = try ProductionScreenshotArtifactStore.testing(
            temporaryBasePath: screenshotRoot.path,
            canonicalUDID: target,
            runtimeEpoch: 41
        )
        let backend = ProductionRuntimeOperationBackend(
            deviceCoordinator: coordinator,
            helperExecutor: context.executor,
            recordingStore: nil,
            screenshotStore: screenshotStore,
            coordinateProjectionStore:
                ProductionRuntimeCoordinateProjectionStore(),
            pointerObservationSink:
                ProductionRuntimePointerObservationSink(),
            captureReadyHandler: { _, _ in
                .failed(code: "capabilityPreparing")
            },
            handler: { _, _, _, _ in .failed(code: "invalidArgument") }
        )

        let result = backend.refreshDuplicateCaptureReady(connectionEpoch: 1)
        guard case .succeeded(let value) = result else {
            return XCTFail("expected duplicate capture-ready success")
        }
        XCTAssertEqual(value["disposition"]?.stringValue, "alreadyReady")
        XCTAssertEqual(
            try value["geometryRevision"]?.numberValue?.requireUInt64(),
            1
        )
        XCTAssertEqual(
            try value["logicalWidth"]?.numberValue?.requireUInt64(),
            2_532
        )
        XCTAssertEqual(
            try value["logicalHeight"]?.numberValue?.requireUInt64(),
            1_170
        )
        XCTAssertEqual(value["orientation"]?.stringValue, "landscapeRight")
        XCTAssertEqual(
            context.executor.diagnosticSnapshot().activeExecutorGeneration,
            generation
        )
        XCTAssertEqual(try context.manifest().helpers.count, 1)
    }

    func testCaptureReadyCompatibilityGenerationRejectsOldRuntimeBeforeDispatch() throws {
        let target = try CanonicalUDID(
            canonicalString: "M2031-CAPTURE-COMPAT-\(UUID().uuidString)"
        )
        let dispatches = LockedCallCounter()
        let backend = ProductionRuntimeOperationBackend(
            handler: { _ in .failed(code: "protocolViolation") },
            captureReadyHandler: { _, _ in
                dispatches.increment()
                return .failed(code: "protocolViolation")
            }
        )
        let oldCompatibility = try RuntimeCompatibilityIdentity(
            runtimeCompatibilityID: "runtime.compat.v1",
            executionCatalogHash:
        ProductionRuntimeContractIdentity.executionCatalogHash
        )
        let server = ProductionRuntimeServer(
            canonicalUDID: target,
            compatibility: oldCompatibility,
            runtimeEpoch: 30,
            operationBackend: backend,
            connectionTimeoutSeconds: 1
        )
        let stopped = expectation(description: "old runtime stopped")
        let errors = LockedErrorStore()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { stopped.fulfill() }
      do { try server.run() } catch { errors.store(error) }
        }
        var waitedForStop = false
        defer {
            if !waitedForStop {
                server.requestStop()
                wait(for: [stopped], timeout: 3)
            }
        }
        try waitForNode(try RuntimeSocketPath.current(for: target).path)
        let client = RuntimeClient(
            canonicalAppPath: try CanonicalAppPath(
                canonicalBundlePath: "/Applications/PulsePhone.app"
            ),
            compatibility: try RuntimeCompatibilityIdentity(
                runtimeCompatibilityID:
                    ProductionRuntimeContractIdentity.runtimeCompatibilityID,
                executionCatalogHash:
          ProductionRuntimeContractIdentity.executionCatalogHash
            ),
            role: .gui
        )
        XCTAssertEqual(
            ProductionRuntimeContractIdentity.runtimeCompatibilityID,
            "runtime.compat.v4"
        )
    XCTAssertThrowsError(
      try client.request(
            operation: .runtimeMarkLiveCaptureReady,
            canonicalUDID: target,
            body: Self.object([
          ("canonicalUDID", .string(target.rawValue))
            ]),
            activation: .existingOnly
      )
    ) {
            XCTAssertEqual($0 as? RuntimeClientError, .incompatibleRuntime)
        }
        XCTAssertEqual(dispatches.value, 0)
        let retired = try RuntimeStopCommand(
            backend: ProductionRuntimeStopBackend(
                runtimeClient: client,
                runtimeExecutablePath:
                    "/Applications/PulsePhone.app/Contents/Helpers/PulsePhoneRuntime"
            )
        ).run(
            canonicalUDID: target,
            outputMode: .human
        )
        XCTAssertEqual(retired.chunk.stdout, ["Stopped"])
        wait(for: [stopped], timeout: 3)
        waitedForStop = true
        XCTAssertNil(errors.error)
    }

    func testProductionStopBackendRecoversVerifiedOrphanHelpersWithoutSpawn()
        throws
    {
        let target = try CanonicalUDID(
            canonicalString: "M2031-STOP-ORPHAN-\(UUID().uuidString)"
        )
        var runtimeLock: RuntimeLock? = try RuntimeLock.acquireForRuntimeStartup(
            for: target
        )
        let runtimeLockPath = try XCTUnwrap(runtimeLock).path
        let lockHolder = RuntimeLockHolder(try XCTUnwrap(runtimeLock))
        runtimeLock = nil
        let manifest = try HelperManifestStore(
            canonicalUDID: target,
            runtimeEpoch: 41,
            runtimePID: 12345,
            runtimeProcessStartIdentity: HelperProcessStartIdentity(
                seconds: 10,
                microseconds: 20
            )
        )
    try manifest.publish([
      HelperStateRecord(
            helperID: "helper-1",
            role: "coredevice",
            executorID: "executor.coredevice",
            executorGeneration: 2,
            processIdentity: HelperProcessIdentity(
                pid: 23456,
                processGroupID: 23456,
                processStartIdentity: HelperProcessStartIdentity(
                    seconds: 30,
                    microseconds: 40
                ),
                executablePath: "/usr/bin/true"
            )
      )
    ])
        defer {
            lockHolder.release()
            _ = unlink(manifest.path)
            _ = unlink(runtimeLockPath)
      _ = unlink(
        "/tmp/pulsephone-\(geteuid())/"
                + target.domainSeparatedHash + ".bootstrap.lock")
        }
        let catalogHash = String(repeating: "b", count: 64)
        let client = try RuntimeClient.testing(
            canonicalAppPath: CanonicalAppPath(
                canonicalBundlePath: "/Applications/PulsePhone.app"
            ),
            developerImageCatalogRevision: "catalog.test",
            developerImageCatalogHash: catalogHash
        )
        let processSystem = OrphanStopProcessSystem(lockHolder: lockHolder)
        let output = try RuntimeStopCommand(
            backend: ProductionRuntimeStopBackend(
                runtimeClient: client,
                runtimeExecutablePath:
                    "/Applications/PulsePhone.app/Contents/Helpers/PulsePhoneRuntime",
                processSystem: processSystem
            )
        ).run(
            canonicalUDID: target,
            outputMode: .human
        )

        XCTAssertEqual(output.chunk.stdout, ["Already stopped"])
        XCTAssertEqual(processSystem.signals, [SIGTERM])
        XCTAssertNil(lockHolder.runtimeLock)
    }

    func testPhysicalBundledCoordinatorDiscoversTargetAndPublishesAvailability() throws {
    guard
      let rawTarget = ProcessInfo.processInfo.environment[
            "PULSEPHONE_PHYSICAL_UDID"
      ]
    else {
            throw XCTSkip("set PULSEPHONE_PHYSICAL_UDID for the local device smoke")
        }
        let target = try CanonicalUDID(canonicalString: rawTarget)
        let server = try ProductionRuntimeServer.bundled(canonicalUDID: target)
        let stopped = expectation(description: "runtime stopped")
        let errors = LockedErrorStore()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { stopped.fulfill() }
            do {
                try server.run()
            } catch {
                errors.store(error)
            }
        }
        defer {
            server.requestStop()
            wait(for: [stopped], timeout: 3)
        }
        try waitForNode(try RuntimeSocketPath.current(for: target).path)
        let client = try RuntimeClient.testing(
            canonicalAppPath: CanonicalAppPath(
                canonicalBundlePath: "/Applications/PulsePhone.app"
      )
        )
        let response = try client.request(
            operation: .runtimeGetAvailabilitySnapshot,
            canonicalUDID: target,
            body: try Self.object([
        ("canonicalUDID", .string(target.rawValue))
            ]),
            activation: .existingOnly
        )
        let value = try XCTUnwrap(response.result["value"]?.objectValue)
        XCTAssertGreaterThan(
            try XCTUnwrap(value["connectionEpoch"]?.numberValue?.requireUInt64()),
            0
        )
    XCTAssertEqual(value["commands"]?.arrayValue?.count, 52)
        XCTAssertNil(errors.error)
    }

    func testPackagedRuntimeHealthUsesCandidateProcessWithoutDeviceControl() throws {
    guard
      let rawAppPath = ProcessInfo.processInfo.environment[
            "PULSEPHONE_PACKAGED_APP"
      ]
    else {
            throw XCTSkip(
                "set PULSEPHONE_PACKAGED_APP for the packaged Runtime health smoke"
            )
        }
        guard let resolvedAppPath = realpath(rawAppPath, nil) else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { free(resolvedAppPath) }
        let appPath = try CanonicalAppPath(
            canonicalBundlePath: String(cString: resolvedAppPath)
        )
        let appURL = appPath.bundleURL
        let target = try CanonicalUDID(
            canonicalString: "PACKAGED-RUNTIME-HEALTH-\(UUID().uuidString)"
        )
        let client = RuntimeClient(
            canonicalAppPath: appPath,
            compatibility: try ProductionRuntimeContractIdentity.load(
                resourcesURL: appPath.resourcesURL
            ),
            role: .cli
        )
        let launched: LaunchedRuntimeGeneration
        switch try RuntimeBootstrapCoordinator().ensureRunning(
            for: target,
            from: appPath
        ) {
        case .launched(let value):
            launched = value
        case .existing:
            return XCTFail("unique packaged Runtime target unexpectedly already exists")
        }
        var requiresStop = true
        defer {
            if requiresStop {
                _ = try? client.requestStopIfIdle(canonicalUDID: target)
            }
        }

    let expectedPath =
      appURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("Helpers", isDirectory: true)
            .appendingPathComponent("PulsePhoneRuntime", isDirectory: false)
            .path
        XCTAssertEqual(launched.executablePath, expectedPath)
        XCTAssertGreaterThan(launched.processStartIdentity.seconds, 0)
        var executablePath = [CChar](
            repeating: 0,
            count: 4 * Int(MAXPATHLEN)
        )
        let pathLength = executablePath.withUnsafeMutableBufferPointer { buffer in
            proc_pidpath(launched.pid, buffer.baseAddress, UInt32(buffer.count))
        }
        XCTAssertGreaterThan(pathLength, 0)
        let terminator = executablePath.firstIndex(of: 0) ?? executablePath.endIndex
        let observedPath = String(
            decoding: executablePath[..<terminator].map { UInt8(bitPattern: $0) },
            as: UTF8.self
        )
        XCTAssertEqual(observedPath, expectedPath)

        let health = try client.health(
            canonicalUDID: target,
            activation: .existingOnly
        )
        XCTAssertEqual(health.result["outcome"]?.stringValue, "succeeded")
        XCTAssertEqual(
            try health.result["value"]?.objectValue?["pid"]?.numberValue?
                .requireUInt64(),
            UInt64(launched.pid)
        )

        let stop = try client.requestStopIfIdle(canonicalUDID: target)
        XCTAssertTrue(stop.accepted)
        XCTAssertTrue(try stop.eofReceipt.waitForEOF())
        requiresStop = false
        try waitForProcessGone(launched.pid, timeoutMilliseconds: 3_000)
    XCTAssertFalse(
      FileManager.default.fileExists(
            atPath: try RuntimeSocketPath.current(for: target).path
        ))
    }

    func testPhysicalPackagedLiveSessionExecutesControlAndPointerStream() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let rawTarget = environment["PULSEPHONE_PHYSICAL_UDID"],
              let rawAppPath = environment["PULSEPHONE_PACKAGED_APP"]
        else {
            throw XCTSkip(
                "set PULSEPHONE_PHYSICAL_UDID and PULSEPHONE_PACKAGED_APP "
                    + "for the packaged live-session smoke"
            )
        }
        let target = try CanonicalUDID(canonicalString: rawTarget)
        let appURL = URL(fileURLWithPath: rawAppPath).resolvingSymlinksInPath()
        let client = RuntimeClient(
            canonicalAppPath: try CanonicalAppPath(
                canonicalBundlePath: appURL.path
            ),
            compatibility: try ProductionRuntimeContractIdentity.load(
        resourcesURL:
          appURL
                    .appendingPathComponent("Contents", isDirectory: true)
                    .appendingPathComponent("Resources", isDirectory: true)
            ),
            role: .gui
        )
        let live = try client.openLiveSession(
            canonicalUDID: target,
            activation: .ensureRunning
        )
        defer { try? live.close() }

        let attachment = try live.attach()
        _ = try live.prepareCapabilities()
        let control = try live.submit(commandID: "button.home")
        XCTAssertEqual(control["outcome"]?.stringValue, "succeeded")

        let stream = try live.openStream(
            commandID: "gui.pointer.interaction",
            rawArguments: [
                "geometryRevision": "1",
                "logicalHeight": "2532",
                "logicalWidth": "1170",
                "orientation": "portrait",
            ]
        )
        let framePayload = try Self.object([
            ("edge", .string("none")),
      (
        "expectedConnectionEpoch",
        .number(
          .uint64(
                attachment.connectionEpoch
          ))
      ),
            ("expectedGeometryRevision", .number(.uint64(1))),
            ("x", .string("0.5")),
            ("y", .string("0.5")),
        ])
        try live.sendFrame(
            stream: stream,
            sequence: 0,
            frameKind: "begin",
            payload: framePayload
        )
        try live.sendFrame(
            stream: stream,
            sequence: 1,
            frameKind: "end",
            payload: framePayload
        )
        _ = try live.closeStream(stream, expectedLastSequence: 1)
        XCTAssertTrue(try live.detach().detached)
    }

    func testProductionDeviceCoordinatorPublishesRealPlanningAvailability() throws {
        let target = try CanonicalUDID(canonicalString: "00008110-001A7D523E90401E")
        let observation = ProductionRuntimeDeviceObservation(
            rawTransportUDID: "00008110-001A7D523E90401E",
            facts: ProductionRuntimeDeviceFacts(
                buildVersion: "23F84",
                deviceClass: "iPhone",
                deviceName: "Test iPhone",
                productType: "iPhone14,7",
                productVersion: "26.5.2",
                uniqueDeviceID: "00008110-001A7D523E90401E"
            ),
            condition: ProductionRuntimeDeviceCondition(
                connected: true,
                locked: false,
                trusted: true
            )
        )
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(repositoryRoot: repositoryRoot()),
            discovery: { observation }
        )

        let first = try coordinator.refresh()
        let second = try coordinator.refresh()
        XCTAssertEqual(first.connectionEpoch, 1)
        XCTAssertEqual(second.connectionEpoch, 1)
        XCTAssertEqual(first.device, observation)

        let availability = try coordinator.availabilityValue()
        XCTAssertEqual(
            try availability["connectionEpoch"]?.numberValue?.requireUInt64(),
            1
        )
        let commands = try XCTUnwrap(availability["commands"]?.arrayValue)
    XCTAssertEqual(commands.count, 52)
        let commandObjects = commands.compactMap {
            $0.objectValue
        }
    let home = try XCTUnwrap(
      commandObjects.first {
            $0["commandID"]?.stringValue == "button.home"
        })
        XCTAssertEqual(home["state"]?.stringValue, "loading")
        XCTAssertEqual(home["reasonCode"]?.stringValue, "capabilityPreparing")
    let tap = try XCTUnwrap(
      commandObjects.first {
            $0["commandID"]?.stringValue == "touch.tap"
        })
        XCTAssertEqual(tap["state"]?.stringValue, "disabled")
        XCTAssertEqual(
            tap["reasonCode"]?.stringValue,
            "displayGeometryUnavailable"
        )
        XCTAssertEqual(
            ProductionRuntimeOperationBackend.publicPlanningFailureCode(
                try XCTUnwrap(tap["reasonCode"]?.stringValue)
            ),
            "capabilityUnavailable"
        )
        XCTAssertEqual(
            ProductionRuntimeOperationBackend.publicPlanningFailureCode(
                "deviceDisconnected"
            ),
            "deviceDisconnected"
        )

        let geometry = try coordinator.updateGeometry(
            connectionEpoch: 1,
            geometryRevision: 1,
            logicalWidth: 1170,
            logicalHeight: 2532,
            orientation: .portrait
        )
        XCTAssertEqual(geometry.geometryRevision, 1)
        let withGeometry = try coordinator.availabilityValue()
        let geometryCommands = try XCTUnwrap(withGeometry["commands"]?.arrayValue)
            .compactMap(\.objectValue)
        XCTAssertEqual(
            geometryCommands.first {
                $0["commandID"]?.stringValue == "touch.tap"
            }?["state"]?.stringValue,
            "loading"
        )
        let prepared = try coordinator.markPreparationReady(
            groupID: "prep.coredevice.v2",
            connectionEpoch: geometry.connectionEpoch
        )
        let readyCommands = try XCTUnwrap(
            coordinator.availabilityValue()["commands"]?.arrayValue
        ).compactMap(\.objectValue)
        XCTAssertEqual(
            readyCommands.first {
                $0["commandID"]?.stringValue == "button.home"
            }?["state"]?.stringValue,
            "enabled"
        )
        XCTAssertEqual(
            readyCommands.first {
                $0["commandID"]?.stringValue == "touch.tap"
            }?["state"]?.stringValue,
            "enabled"
        )

        let conflictingGeometry = try coordinator.updateGeometry(
            connectionEpoch: 1,
            geometryRevision: 1,
            logicalWidth: 2532,
            logicalHeight: 1170,
            orientation: .landscapeRight
        )
        XCTAssertEqual(conflictingGeometry.geometryRevision, 1)
        XCTAssertEqual(conflictingGeometry.stateRevision, prepared.stateRevision)
        XCTAssertEqual(
            conflictingGeometry.planningContext.geometry?.logicalWidth,
            1170
        )
        XCTAssertEqual(
            conflictingGeometry.planningContext.geometry?.logicalHeight,
            2532
        )

        let synchronizedSame = try coordinator.synchronizeGeometry(
            connectionEpoch: 1,
            logicalWidth: 1170,
            logicalHeight: 2532,
            orientation: .portrait
        )
        XCTAssertEqual(synchronizedSame.geometryRevision, 1)
        XCTAssertEqual(synchronizedSame.stateRevision, prepared.stateRevision)

        let synchronizedRotated = try coordinator.synchronizeGeometry(
            connectionEpoch: 1,
            logicalWidth: 2532,
            logicalHeight: 1170,
            orientation: .landscapeRight
        )
        XCTAssertEqual(synchronizedRotated.geometryRevision, 2)
        XCTAssertEqual(synchronizedRotated.geometry?.orientation, .landscapeRight)
        XCTAssertGreaterThan(
            synchronizedRotated.stateRevision,
            synchronizedSame.stateRevision
        )
        let repeatedRotated = try coordinator.synchronizeGeometry(
            connectionEpoch: 1,
            logicalWidth: 2532,
            logicalHeight: 1170,
            orientation: .landscapeRight
        )
        XCTAssertEqual(repeatedRotated.geometryRevision, 2)
        XCTAssertEqual(
            repeatedRotated.stateRevision,
            synchronizedRotated.stateRevision
        )
    }

    func testElementAuthorityObserversInvalidateOnGeometryAndDetachWithoutRace()
        throws
    {
        let target = try CanonicalUDID(canonicalString: "M2031-ELEMENT-AUTHORITY")
        let discovery = LockedDeviceDiscoveryState(
            device: Self.deviceObservation(target: target)
        )
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(repositoryRoot: repositoryRoot()),
            discovery: { try discovery.discover() }
        )
        let attached = try coordinator.refresh()
        let portrait = try coordinator.synchronizeGeometry(
            connectionEpoch: attached.connectionEpoch,
            logicalWidth: 390,
            logicalHeight: 844,
            orientation: .portrait
        )
        let portraitAuthority = try XCTUnwrap(
            ProductionRuntimeElementSnapshotAuthority(snapshot: portrait)
        )
        let rotated = DispatchSemaphore(value: 0)
        let rotationObserver = coordinator.observeElementSnapshotAuthority(
            portraitAuthority
        ) {
            rotated.signal()
        }
        _ = try coordinator.synchronizeGeometry(
            connectionEpoch: attached.connectionEpoch,
            logicalWidth: 390,
            logicalHeight: 844,
            orientation: .portrait
        )
        XCTAssertEqual(rotated.wait(timeout: .now() + 0.05), .timedOut)
        let landscape = try coordinator.synchronizeGeometry(
            connectionEpoch: attached.connectionEpoch,
            logicalWidth: 844,
            logicalHeight: 390,
            orientation: .landscapeRight
        )
        XCTAssertEqual(rotated.wait(timeout: .now() + 1), .success)
        coordinator.removeElementSnapshotAuthorityObserver(rotationObserver)

        let staleRegistration = DispatchSemaphore(value: 0)
        let staleObserver = coordinator.observeElementSnapshotAuthority(
            portraitAuthority
        ) {
            staleRegistration.signal()
        }
        XCTAssertEqual(staleRegistration.wait(timeout: .now() + 1), .success)
        coordinator.removeElementSnapshotAuthorityObserver(staleObserver)

        let landscapeAuthority = try XCTUnwrap(
            ProductionRuntimeElementSnapshotAuthority(snapshot: landscape)
        )
        let epochChanged = DispatchSemaphore(value: 0)
        let epochObserver = coordinator.observeElementSnapshotAuthority(
            landscapeAuthority
        ) {
            epochChanged.signal()
        }
        let priorDevice = try XCTUnwrap(discovery.device)
        discovery.device = ProductionRuntimeDeviceObservation(
            rawTransportUDID: priorDevice.rawTransportUDID + "-replacement",
            facts: priorDevice.facts,
            condition: priorDevice.condition
        )
        let replacement = try coordinator.refreshConnectionTransition()
        XCTAssertEqual(replacement.snapshot.connectionEpoch, 2)
        XCTAssertEqual(epochChanged.wait(timeout: .now() + 1), .success)
        coordinator.removeElementSnapshotAuthorityObserver(epochObserver)
        let replacementGeometry = try coordinator.synchronizeGeometry(
            connectionEpoch: replacement.snapshot.connectionEpoch,
            logicalWidth: 844,
            logicalHeight: 390,
            orientation: .landscapeRight
        )
        let replacementAuthority = try XCTUnwrap(
            ProductionRuntimeElementSnapshotAuthority(snapshot: replacementGeometry)
        )
        let detached = DispatchSemaphore(value: 0)
        let detachObserver = coordinator.observeElementSnapshotAuthority(
            replacementAuthority
        ) {
            detached.signal()
        }
        discovery.device = nil
        _ = try coordinator.confirmDisconnected()
        XCTAssertEqual(detached.wait(timeout: .now() + 1), .success)
        coordinator.removeElementSnapshotAuthorityObserver(detachObserver)
    }

    func testPointerGeometryAdmissionSkipsWarmQueryAndRefreshesMismatchOnce() throws {
        let target = try CanonicalUDID(canonicalString: "M2031-POINTER-GEOMETRY")
        let observation = ProductionRuntimeDeviceObservation(
            rawTransportUDID: "M2031-POINTER-GEOMETRY",
            facts: ProductionRuntimeDeviceFacts(
                buildVersion: "23F84",
                deviceClass: "iPhone",
                deviceName: "Test iPhone",
                productType: "iPhone14,7",
                productVersion: "26.5.2",
                uniqueDeviceID: "M2031-POINTER-GEOMETRY"
            ),
            condition: ProductionRuntimeDeviceCondition(
                connected: true,
                locked: false,
                trusted: true
            )
        )
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(repositoryRoot: repositoryRoot()),
            discovery: { observation }
        )
        _ = try coordinator.refresh()
        _ = try coordinator.setLiveAttached(true)
        let portrait = try DisplayGeometryDTO(
            connectionEpoch: 1,
            geometryRevision: 1,
            logicalHeight: 2_532,
            logicalWidth: 1_170,
            orientation: .portrait
        )
        let cached = try coordinator.updateGeometry(
            connectionEpoch: portrait.connectionEpoch,
            geometryRevision: portrait.geometryRevision,
            logicalWidth: portrait.logicalWidth,
            logicalHeight: portrait.logicalHeight,
            orientation: portrait.orientation
        )
        var queryCount = 0
        var updateCount = 0

        let warm = try ProductionRuntimeOperationBackend.admitPointerGeometry(
            requested: portrait,
            snapshot: cached,
            query: {
                queryCount += 1
                return portrait
            },
            update: { geometry in
                updateCount += 1
                return try coordinator.updateGeometry(
                    connectionEpoch: geometry.connectionEpoch,
                    geometryRevision: geometry.geometryRevision,
                    logicalWidth: geometry.logicalWidth,
                    logicalHeight: geometry.logicalHeight,
                    orientation: geometry.orientation
                )
            }
        )
        XCTAssertEqual(warm.geometry, portrait)
        XCTAssertEqual(queryCount, 0)
        XCTAssertEqual(updateCount, 0)

        let landscape = try DisplayGeometryDTO(
            connectionEpoch: 1,
            geometryRevision: 2,
            logicalHeight: 1_170,
            logicalWidth: 2_532,
            orientation: .landscapeRight
        )
        let refreshed = try ProductionRuntimeOperationBackend.admitPointerGeometry(
            requested: landscape,
            snapshot: warm,
            query: {
                queryCount += 1
                return landscape
            },
            update: { geometry in
                updateCount += 1
                return try coordinator.updateGeometry(
                    connectionEpoch: geometry.connectionEpoch,
                    geometryRevision: geometry.geometryRevision,
                    logicalWidth: geometry.logicalWidth,
                    logicalHeight: geometry.logicalHeight,
                    orientation: geometry.orientation
                )
            }
        )
        XCTAssertEqual(refreshed.geometry, landscape)
        XCTAssertEqual(queryCount, 1)
        XCTAssertEqual(updateCount, 1)

        let authoritative = try coordinator.updateGeometry(
            connectionEpoch: landscape.connectionEpoch,
            geometryRevision: 3,
            logicalWidth: landscape.logicalWidth,
            logicalHeight: landscape.logicalHeight,
            orientation: landscape.orientation
        )
        let adopted = try ProductionRuntimeOperationBackend.admitPointerGeometry(
            requested: landscape,
            snapshot: authoritative,
            query: {
                queryCount += 1
                return landscape
            },
            update: { geometry in
                updateCount += 1
                return try coordinator.updateGeometry(
                    connectionEpoch: geometry.connectionEpoch,
                    geometryRevision: geometry.geometryRevision,
                    logicalWidth: geometry.logicalWidth,
                    logicalHeight: geometry.logicalHeight,
                    orientation: geometry.orientation
                )
            }
        )
        XCTAssertEqual(adopted.geometry?.geometryRevision, 3)
        XCTAssertEqual(queryCount, 2)
        XCTAssertEqual(updateCount, 2)

        let ahead = try DisplayGeometryDTO(
            connectionEpoch: 1,
            geometryRevision: 5,
            logicalHeight: 1_170,
            logicalWidth: 2_532,
            orientation: .landscapeRight
        )
        let advanced = try ProductionRuntimeOperationBackend.admitPointerGeometry(
            requested: ahead,
            snapshot: adopted,
            query: {
                queryCount += 1
                return ahead
            },
            update: { geometry in
                updateCount += 1
                return try coordinator.updateGeometry(
                    connectionEpoch: geometry.connectionEpoch,
                    geometryRevision: geometry.geometryRevision,
                    logicalWidth: geometry.logicalWidth,
                    logicalHeight: geometry.logicalHeight,
                    orientation: geometry.orientation
                )
            }
        )
        XCTAssertEqual(advanced.geometry, ahead)
        XCTAssertEqual(queryCount, 3)
        XCTAssertEqual(updateCount, 3)

        let conflicting = try DisplayGeometryDTO(
            connectionEpoch: 1,
            geometryRevision: 6,
            logicalHeight: 2_532,
            logicalWidth: 1_170,
            orientation: .portrait
        )
    XCTAssertThrowsError(
      try ProductionRuntimeOperationBackend.admitPointerGeometry(
            requested: conflicting,
            snapshot: advanced,
            query: {
                queryCount += 1
                return landscape
            },
            update: { _ in
                updateCount += 1
                return advanced
            }
      )
    ) {
            XCTAssertEqual(
                $0 as? ProductionRuntimeCoordinateProjectionError,
                .staleGeometry
            )
        }
        XCTAssertEqual(queryCount, 4)
        XCTAssertEqual(updateCount, 3)
    }

    func testDetachedCommandPlanningPerformsOneFreshDiscovery() throws {
        let target = try CanonicalUDID(canonicalString: "M2031-SINGLE-REFRESH")
        let observation = ProductionRuntimeDeviceObservation(
            rawTransportUDID: "M2031-SINGLE-REFRESH",
            facts: ProductionRuntimeDeviceFacts(
                buildVersion: "23F84",
                deviceClass: "iPhone",
                deviceName: "Test iPhone",
                productType: "iPhone14,7",
                productVersion: "26.5.2",
                uniqueDeviceID: "M2031-SINGLE-REFRESH"
            ),
            condition: ProductionRuntimeDeviceCondition(
                connected: true,
                locked: false,
                trusted: true
            )
        )
        let discoveries = LockedCallCounter()
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(repositoryRoot: repositoryRoot()),
            discovery: {
                discoveries.increment()
                return observation
            }
        )

        let (_, planning) = try coordinator.plan(
            commandID: "button.home",
            rawArguments: [:]
        )

        guard case .awaitingPreparation(let waiting) = planning else {
            return XCTFail("expected button.home to await Developer Support")
        }
        XCTAssertEqual(waiting.preparationGroupIDs, ["prep.coredevice.v2"])
        XCTAssertEqual(discoveries.value, 1)
    }

    func testPreparationJobManagerSharesAttemptAndReplaysLatestProgress() throws {
        let manager = ProductionPreparationJobManager()
        let key = ProductionPreparationJobManager.Key(
            connectionEpoch: 7,
            preparationGroupID: "prep.coredevice.v2"
        )
        let progress = try PreparationProgressV1(
            phase: .resolvingDeveloperSupport,
            phaseSequence: 1,
            preparationAttemptID: CanonicalUUID(value: UUID()),
            preparationGroupID: "prep.coredevice.v2",
            stateRevision: 1
        )
        let invocationCount = LockedCallCounter()
        let firstProgress = LockedPreparationProgressStore()
        let lateProgress = LockedPreparationProgressStore()
        let firstResult = LockedPreparationResultStore()
        let lateResult = LockedPreparationResultStore()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let terminalValue = try Self.object([
      ("disposition", .string("ready"))
        ])

        DispatchQueue.global(qos: .userInitiated).async {
            let result = manager.submit(
                key: key,
                mode: .waitForTerminal,
                observerID: CanonicalUUID(value: UUID()),
                progress: { firstProgress.append($0) }
            ) { _, publish in
                invocationCount.increment()
                publish(progress)
                started.signal()
                release.wait()
                return .succeeded(value: terminalValue)
            }
            firstResult.store(result ?? .failed(code: "runtimeFailed"))
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)

        DispatchQueue.global(qos: .userInitiated).async {
            let result = manager.submit(
                key: key,
                mode: .waitForTerminal,
                observerID: CanonicalUUID(value: UUID()),
                progress: { lateProgress.append($0) }
            ) { _, _ in
                invocationCount.increment()
                return .failed(code: "unexpectedSecondAttempt")
            }
            lateResult.store(result ?? .failed(code: "runtimeFailed"))
        }
        try waitForCondition { lateProgress.values == [progress] }
        release.signal()
        try waitForCondition {
            firstResult.hasResult && lateResult.hasResult
        }

        XCTAssertEqual(invocationCount.value, 1)
        XCTAssertEqual(firstProgress.values, [progress])
        XCTAssertEqual(lateProgress.values, [progress])
        guard case .succeeded = try firstResult.requireResult(),
              case .succeeded = try lateResult.requireResult()
        else {
            return XCTFail("explicit observers must receive the shared terminal")
        }
    }

    func testPreparationJobManagerRetriesFailedAttemptOnlyForExplicitPrepare() throws {
        let manager = ProductionPreparationJobManager()
        let key = ProductionPreparationJobManager.Key(
            connectionEpoch: 8,
            preparationGroupID: "prep.coredevice.v2"
        )
        let invocationCount = LockedCallCounter()
        _ = manager.submit(
            key: key,
            mode: .startOnly,
            observerID: CanonicalUUID(value: UUID()),
            progress: nil
        ) { _, _ in
            invocationCount.increment()
            return .failed(code: "developerImageCatalogMismatch")
        }
        try waitForCondition { invocationCount.value == 1 }
        usleep(20_000)

        _ = manager.submit(
            key: key,
            mode: .startOnly,
            observerID: CanonicalUUID(value: UUID()),
            progress: nil
        ) { _, _ in
            invocationCount.increment()
            return .failed(code: "unexpectedOrdinaryRetry")
        }
        usleep(20_000)
        XCTAssertEqual(invocationCount.value, 1)

        let retry = manager.submit(
            key: key,
            mode: .waitForTerminal,
            observerID: CanonicalUUID(value: UUID()),
            progress: nil
        ) { _, _ in
            invocationCount.increment()
      return .succeeded(
        value: try Self.object([
          ("disposition", .string("ready"))
            ]))
        }
        XCTAssertEqual(invocationCount.value, 2)
        guard case .succeeded = retry else {
            return XCTFail("an explicit prepare must be allowed to retry")
        }
    }

    func testFiniteModernCommandStartsPreparationAndRequiresExplicitRetry() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        let target = try CanonicalUDID(
            canonicalString: context.device.facts.uniqueDeviceID
        )
        let catalog = try Self.personalizedDeveloperImageCatalog(
            buildVersion: context.device.facts.buildVersion
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-ImplicitModernPreparation-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DeveloperImageAssetStore(rootURL: root)
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(
                repositoryRoot: repositoryRoot()
            ),
            discovery: { context.device }
        )
        let screenshotStore = try ProductionScreenshotArtifactStore.testing(
            temporaryBasePath: root.path,
            canonicalUDID: target,
            runtimeEpoch: 41
        )
        let preparationJobs = ProductionPreparationJobManager()
        let request = RuntimeRequestEnvelope(
            requestID: CanonicalUUID(value: UUID()),
            operation: .commandSubmit,
            body: try Self.object([
        (
          "actionID",
          .string(
                    CanonicalUUID(value: UUID()).canonicalString
          )
        ),
                ("canonicalUDID", .string(target.rawValue)),
                ("commandID", .string("button.home")),
                ("normalizedArguments", .object(try Self.object([]))),
            ])
        )

        let result = try ProductionRuntimeOperationBackend.executeCommand(
            request,
            coordinator: coordinator,
            helperExecutor: context.executor,
            directHelperExecutor: context.directExecutor,
            screenshotStore: screenshotStore,
            clientInstanceID: nil,
            pointerObservationSink: ProductionRuntimePointerObservationSink(),
            developerImageCatalog: catalog,
            developerImageStore: store,
            preparationJobs: preparationJobs
        )
        guard case .standard(let value) = result else {
            return XCTFail("mounted and warm Developer Support should recover and execute: \(result)")
        }
        XCTAssertEqual(value["outcome"]?.stringValue, "succeeded")
        XCTAssertTrue(context.buttonHomeObserved())
    }

    func testModernPreparationRehydratesFreshCoordinatorForStartOnlyAndCommand()
        throws
    {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        let target = try CanonicalUDID(
            canonicalString: context.device.facts.uniqueDeviceID
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-RehydratePreparedModernSupport-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let developerImageStore = try DeveloperImageAssetStore(rootURL: root)
        let catalog = try ExecutionProfileCatalog.load(
            repositoryRoot: repositoryRoot()
        )
        let initialCoordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: catalog,
            discovery: { context.device }
        )
        let preparation = try ProductionRuntimeOperationBackend.executePreparation(
            RuntimeRequestEnvelope(
                requestID: CanonicalUUID(value: UUID()),
                operation: .runtimePrepareCapabilities,
                body: try Self.object([
          ("canonicalUDID", .string(target.rawValue))
                ])
            ),
            coordinator: initialCoordinator,
            helperExecutor: context.executor,
            directHelperExecutor: context.directExecutor,
            developerImageStore: developerImageStore
        )
        guard case .succeeded = preparation else {
            return XCTFail("initial modern preparation must succeed")
        }

        let startOnlyCoordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: catalog,
            discovery: { context.device }
        )
    let startOnly =
      try ProductionRuntimeOperationBackend
            .executePreparationRequest(
                RuntimeRequestEnvelope(
                    requestID: CanonicalUUID(value: UUID()),
                    operation: .runtimePrepareCapabilities,
                    body: try Self.object([
                        ("canonicalUDID", .string(target.rawValue)),
                        ("mode", .string("startOnly")),
                    ])
                ),
                coordinator: startOnlyCoordinator,
                helperExecutor: context.executor,
                directHelperExecutor: context.directExecutor,
                developerImageCatalog: nil,
                developerImageStore: developerImageStore,
                preparationJobs: ProductionPreparationJobManager(),
                preparationProgress: nil,
                selectedXcodeSnapshotProvider: { _ in nil }
            )
        guard case .succeeded(let startOnlyValue) = startOnly else {
            return XCTFail("fresh Live start-only preflight must rehydrate")
        }
        XCTAssertEqual(startOnlyValue["disposition"]?.stringValue, "alreadyReady")

        let commandCoordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: catalog,
            discovery: { context.device }
        )
        let screenshotStore = try ProductionScreenshotArtifactStore.testing(
            temporaryBasePath: root.path,
            canonicalUDID: target,
            runtimeEpoch: 41
        )
        let command = try ProductionRuntimeOperationBackend.executeCommand(
            RuntimeRequestEnvelope(
                requestID: CanonicalUUID(value: UUID()),
                operation: .commandSubmit,
                body: try Self.object([
          (
            "actionID",
            .string(
                        CanonicalUUID(value: UUID()).canonicalString
            )
          ),
                    ("canonicalUDID", .string(target.rawValue)),
                    ("commandID", .string("button.home")),
                    ("normalizedArguments", .object(try Self.object([]))),
                ])
            ),
            coordinator: commandCoordinator,
            helperExecutor: context.executor,
            directHelperExecutor: context.directExecutor,
            screenshotStore: screenshotStore,
            clientInstanceID: nil,
            pointerObservationSink: ProductionRuntimePointerObservationSink(),
            developerImageStore: developerImageStore,
            preparationJobs: ProductionPreparationJobManager()
        )
        guard case .standard(let commandValue) = command else {
            return XCTFail("fresh command coordinator must rehydrate: \(command)")
        }
        XCTAssertEqual(commandValue["outcome"]?.stringValue, "succeeded")
        XCTAssertTrue(context.buttonHomeObserved())
    }

    func testDynamicClassicPreparationRehydratesFreshCoordinatorForStartOnlyAndCommand()
        throws
    {
        let target = try CanonicalUDID(
            canonicalString: "M2031-CLASSIC-REHYDRATE-\(UUID().uuidString)"
        )
        let classicDevice = Self.deviceObservation(
            target: target,
            buildVersion: "18D70",
            productVersion: "14.4.2"
        )
        let context = try CoreDeviceExecutorTestContext(device: classicDevice)
        defer { context.cleanup() }
        context.setLegacyDeveloperSupportMounted(true)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-RehydratePreparedClassicSupport-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let developerImageStore = try DeveloperImageAssetStore(rootURL: root)
        let configuration = DynamicDeveloperImageCatalogStoreConfiguration(
            catalogURL: "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/catalog-test.json",
            archiveURLPrefix: "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/archives/"
        )
        let catalogData = try Self.dynamicClassicCatalogData()
        let dynamicStore = try DynamicDeveloperImageCatalogStore(
            rootURL: root,
            configuration: configuration,
            fetch: { _, _ in
                DynamicDeveloperImageCatalogHTTPResponse(
                    data: catalogData,
                    etag: "\"classic-v1\"",
                    statusCode: 200
                )
            },
            now: Date.init
        )
        let dynamicCache = try DynamicDeveloperImageAssetCache(
            rootURL: root,
            configuration: configuration,
            fetch: { _, _ in
                XCTFail("mounted classic preparation must not fetch archive")
                return Data()
            }
        )
        let catalog = try ExecutionProfileCatalog.load(
            repositoryRoot: repositoryRoot()
        )
        let initialCoordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: catalog,
            discovery: { classicDevice }
        )
        let preparation = try ProductionRuntimeOperationBackend.executePreparation(
            RuntimeRequestEnvelope(
                requestID: CanonicalUUID(value: UUID()),
                operation: .runtimePrepareCapabilities,
                body: try Self.object([
                    ("canonicalUDID", .string(target.rawValue)),
                ])
            ),
            coordinator: initialCoordinator,
            helperExecutor: context.executor,
            directHelperExecutor: context.directExecutor,
            developerImageStore: developerImageStore,
            dynamicDeveloperImageCatalogStore: dynamicStore,
            dynamicDeveloperImageAssetCache: dynamicCache
        )
        guard case .succeeded = preparation else {
            return XCTFail("initial dynamic classic preparation must succeed")
        }

        let startOnlyCoordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: catalog,
            discovery: { classicDevice }
        )
        let startOnly = try ProductionRuntimeOperationBackend
            .executePreparationRequest(
                RuntimeRequestEnvelope(
                    requestID: CanonicalUUID(value: UUID()),
                    operation: .runtimePrepareCapabilities,
                    body: try Self.object([
                        ("canonicalUDID", .string(target.rawValue)),
                        ("mode", .string("startOnly")),
                    ])
                ),
                coordinator: startOnlyCoordinator,
                helperExecutor: context.executor,
                directHelperExecutor: context.directExecutor,
                developerImageCatalog: nil,
                developerImageStore: developerImageStore,
                dynamicDeveloperImageCatalogStore: dynamicStore,
                dynamicDeveloperImageAssetCache: dynamicCache,
                preparationJobs: ProductionPreparationJobManager(),
                preparationProgress: nil,
                selectedXcodeSnapshotProvider: { _ in nil }
            )
        guard case .succeeded(let startOnlyValue) = startOnly else {
            return XCTFail("fresh classic start-only preflight must rehydrate")
        }
        XCTAssertEqual(startOnlyValue["disposition"]?.stringValue, "alreadyReady")

        let commandCoordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: catalog,
            discovery: { classicDevice }
        )
        let screenshotStore = try ProductionScreenshotArtifactStore.testing(
            temporaryBasePath: root.path,
            canonicalUDID: target,
            runtimeEpoch: 41
        )
        let command = try ProductionRuntimeOperationBackend.executeCommand(
            RuntimeRequestEnvelope(
                requestID: CanonicalUUID(value: UUID()),
                operation: .commandSubmit,
                body: try Self.object([
                    ("actionID", .string(CanonicalUUID(value: UUID()).canonicalString)),
                    ("canonicalUDID", .string(target.rawValue)),
                    ("commandID", .string("screenshot.cli")),
                    ("normalizedArguments", .object(try Self.object([
                        ("outputPath", .string("/tmp/capture.png")),
                    ]))),
                ])
            ),
            coordinator: commandCoordinator,
            helperExecutor: context.executor,
            directHelperExecutor: context.directExecutor,
            screenshotStore: screenshotStore,
            clientInstanceID: nil,
            pointerObservationSink: ProductionRuntimePointerObservationSink(),
            developerImageStore: developerImageStore,
            dynamicDeveloperImageCatalogStore: dynamicStore,
            dynamicDeveloperImageAssetCache: dynamicCache,
            preparationJobs: ProductionPreparationJobManager()
        )
        guard case .artifact(_, _, _, _, let commandValue) = command else {
            return XCTFail("fresh classic command coordinator must rehydrate: \(command)")
        }
        XCTAssertNotNil(commandValue["artifactID"]?.stringValue)
    }

    func testModernPreparationDoesNotRehydrateFreshCoordinatorWhenUnmounted()
        throws
    {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        let target = try CanonicalUDID(
            canonicalString: context.device.facts.uniqueDeviceID
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-RehydrateUnmountedModernSupport-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let developerImageStore = try DeveloperImageAssetStore(rootURL: root)
        let catalog = try ExecutionProfileCatalog.load(
            repositoryRoot: repositoryRoot()
        )
        let initialCoordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: catalog,
            discovery: { context.device }
        )
    guard
      case .succeeded =
        try ProductionRuntimeOperationBackend
            .executePreparation(
                RuntimeRequestEnvelope(
                    requestID: CanonicalUUID(value: UUID()),
                    operation: .runtimePrepareCapabilities,
                    body: try Self.object([
              ("canonicalUDID", .string(target.rawValue))
                    ])
                ),
                coordinator: initialCoordinator,
                helperExecutor: context.executor,
                directHelperExecutor: context.directExecutor,
                developerImageStore: developerImageStore
            )
        else {
            return XCTFail("initial modern preparation must record eligibility")
        }

        context.setModernDeveloperSupportMounted(false)
        let freshCoordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: catalog,
            discovery: { context.device }
        )
        let screenshotStore = try ProductionScreenshotArtifactStore.testing(
            temporaryBasePath: root.path,
            canonicalUDID: target,
            runtimeEpoch: 41
        )
        let result = try ProductionRuntimeOperationBackend.executeCommand(
            RuntimeRequestEnvelope(
                requestID: CanonicalUUID(value: UUID()),
                operation: .commandSubmit,
                body: try Self.object([
          (
            "actionID",
            .string(
                        CanonicalUUID(value: UUID()).canonicalString
            )
          ),
                    ("canonicalUDID", .string(target.rawValue)),
                    ("commandID", .string("button.home")),
                    ("normalizedArguments", .object(try Self.object([]))),
                ])
            ),
            coordinator: freshCoordinator,
            helperExecutor: context.executor,
            directHelperExecutor: context.directExecutor,
            screenshotStore: screenshotStore,
            clientInstanceID: nil,
            pointerObservationSink: ProductionRuntimePointerObservationSink(),
            developerImageStore: developerImageStore,
            preparationJobs: ProductionPreparationJobManager()
        )
        guard case .failedWithDetails(let code, let details) = result else {
            return XCTFail("unmounted support must retain remediation: \(result)")
        }
        XCTAssertEqual(code, "capabilityPreparing")
        XCTAssertEqual(details["remediation"]?.stringValue, "runDevicePrepare")
        XCTAssertEqual(
            details["reason"]?.stringValue,
            "developerSupportNotMounted"
        )
        XCTAssertFalse(context.buttonHomeObserved())
    }

    func testModernCaptureCommandsStartPreparationBeforeCaptureAndRequireRetry()
        throws
    {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        let target = try CanonicalUDID(
            canonicalString: context.device.facts.uniqueDeviceID
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-ImplicitCapturePreparation-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try Self.personalizedDeveloperImageCatalog(
            buildVersion: context.device.facts.buildVersion
        )
        let store = try DeveloperImageAssetStore(rootURL: root)
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(
                repositoryRoot: repositoryRoot()
            ),
            discovery: { context.device }
        )
        let screenshotStore = try ProductionScreenshotArtifactStore.testing(
            temporaryBasePath: root.path,
            canonicalUDID: target,
            runtimeEpoch: 41
        )
        let analyzerCalls = LockedCallCounter()
        let pipeline = ProductionElementSnapshotPipeline(
            canonicalUDID: target,
      analyzer: ElementAnalyzerCoordinator(
        operations: .init(
                omniparser: { _ in
                    analyzerCalls.increment()
                    fatalError("element analysis must not start while preparing")
                },
                vision: { _ in
                    analyzerCalls.increment()
                    fatalError("element analysis must not start while preparing")
                },
                appleRegion: { _ in
                    analyzerCalls.increment()
                    fatalError("element analysis must not start while preparing")
                }
            ))
        )
        let preparationJobs = ProductionPreparationJobManager()
        context.blockWarmGeneration()
        defer { context.releaseBlockedOneShot() }

        func execute(
            commandID: String,
            arguments: [(String, RepositoryJSONValue)]
        ) throws -> ProductionRuntimeBackendDisposition {
            try ProductionRuntimeOperationBackend.executeCommand(
                RuntimeRequestEnvelope(
                    requestID: CanonicalUUID(value: UUID()),
                    operation: .commandSubmit,
                    body: try Self.object([
            (
              "actionID",
              .string(
                            CanonicalUUID(value: UUID()).canonicalString
              )
            ),
                        ("canonicalUDID", .string(target.rawValue)),
                        ("commandID", .string(commandID)),
            (
              "normalizedArguments",
              .object(
                            try Self.object(arguments)
              )
            ),
                    ])
                ),
                coordinator: coordinator,
                helperExecutor: context.executor,
                directHelperExecutor: context.directExecutor,
                elementSnapshotPipeline: pipeline,
                screenshotStore: screenshotStore,
                clientInstanceID: nil,
                pointerObservationSink: ProductionRuntimePointerObservationSink(),
                developerImageCatalog: catalog,
                developerImageStore: store,
                preparationJobs: preparationJobs
            )
        }

        let screenshot = try execute(
            commandID: "screenshot.cli",
            arguments: [("outputPath", .string("/tmp/capture.png"))]
        )
    guard case .failedWithDetails(let screenshotCode, let screenshotDetails) = screenshot
        else {
            return XCTFail("expected screenshot preparation remediation: \(screenshot)")
        }
        XCTAssertEqual(screenshotCode, "capabilityPreparing")
        XCTAssertEqual(
            screenshotDetails["remediation"]?.stringValue,
            "runDevicePrepare"
        )
        XCTAssertEqual(
            screenshotDetails["reason"]?.stringValue,
            "serviceWarmupFailed"
        )
        XCTAssertEqual(analyzerCalls.value, 0)
    }

    func testModernTouchCommandStartsPreparationBeforeGeometryQuery() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        let target = try CanonicalUDID(
            canonicalString: context.device.facts.uniqueDeviceID
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-ImplicitTouchPreparation-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try Self.personalizedDeveloperImageCatalog(
            buildVersion: context.device.facts.buildVersion
        )
        let store = try DeveloperImageAssetStore(rootURL: root)
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(
                repositoryRoot: repositoryRoot()
            ),
            discovery: { context.device }
        )
        let screenshotStore = try ProductionScreenshotArtifactStore.testing(
            temporaryBasePath: root.path,
            canonicalUDID: target,
            runtimeEpoch: 41
        )
        let result = try ProductionRuntimeOperationBackend.executeCommand(
            RuntimeRequestEnvelope(
                requestID: CanonicalUUID(value: UUID()),
                operation: .commandSubmit,
                body: try Self.object([
          (
            "actionID",
            .string(
                        CanonicalUUID(value: UUID()).canonicalString
            )
          ),
                    ("canonicalUDID", .string(target.rawValue)),
                    ("commandID", .string("touch.tap")),
          (
            "normalizedArguments",
            .object(
              try Self.object([
                ("point", .string("0.5,0.5"))
              ]))
          ),
                ])
            ),
            coordinator: coordinator,
            helperExecutor: context.executor,
            directHelperExecutor: context.directExecutor,
            screenshotStore: screenshotStore,
            clientInstanceID: nil,
            pointerObservationSink: ProductionRuntimePointerObservationSink(),
            developerImageCatalog: catalog,
            developerImageStore: store,
            preparationJobs: ProductionPreparationJobManager()
        )
        guard case .standard(let value) = result else {
            return XCTFail(
                "mounted and warm Developer Support should execute touch command: \(result)"
            )
        }
        XCTAssertEqual(value["outcome"]?.stringValue, "succeeded")
    }

    func testModernPreparationReusesMountedSupportBeforeCatalogResolution() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        let target = try CanonicalUDID(
            canonicalString: context.device.facts.uniqueDeviceID
        )
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(
                repositoryRoot: repositoryRoot()
            ),
            discovery: { context.device }
        )
        let result = try ProductionRuntimeOperationBackend.executePreparation(
            RuntimeRequestEnvelope(
                requestID: CanonicalUUID(value: UUID()),
                operation: .runtimePrepareCapabilities,
                body: try Self.object([
          ("canonicalUDID", .string(target.rawValue))
                ])
            ),
            coordinator: coordinator,
            helperExecutor: context.executor,
            directHelperExecutor: context.directExecutor
        )
        guard case .succeeded(let value) = result else {
            return XCTFail("expected mounted support reuse without a catalog: \(result)")
        }
        XCTAssertEqual(value["assetDisposition"]?.stringValue, "mountedOnly")
        XCTAssertEqual(value["disposition"]?.stringValue, "alreadyReady")
        XCTAssertEqual(value["mountDisposition"]?.stringValue, "alreadyMounted")
        XCTAssertEqual(
            value["provenance"]?.stringValue,
            "mountedUnknownUnverified"
        )
        XCTAssertNotNil(context.executor.diagnosticSnapshot().activeExecutorGeneration)
    }

  func testDynamicAssetAcquisitionPrefersValidatedXcodeThenFallsBackToRemote() throws {
    let files = [
      ("BuildManifest.plist", Data("xcode-manifest".utf8)),
      ("Image.dmg", Data("xcode-image".utf8)),
      ("Image.dmg.trustcache", Data("xcode-trust".utf8)),
    ]
    let contentFiles = files.map {
      DynamicDeveloperImageContentFile(
        path: $0.0,
        sha256: StableBytes.sha256Hex($0.1),
        size: UInt64($0.1.count)
      )
    }.sorted { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
    let archive = Self.runtimeTestUSTAR(files)
    let reference = DynamicDeveloperImageAssetReference(
      archiveSHA256: StableBytes.sha256Hex(archive),
      archiveSize: UInt64(archive.count),
      assetID: "base.runtime-xcode-source",
      contentManifestSHA256:
        try DynamicDeveloperImageContentManifest
        .sha256(contentFiles),
      ddiVersion: nil,
      kind: .baseImage,
      sourceURL:
        "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/archives/baseAssets/base.runtime-xcode-source.tar"
    )
    let configuration = DynamicDeveloperImageCatalogStoreConfiguration(
      catalogURL:
        "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/catalog-test.json",
      archiveURLPrefix:
        "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/archives/"
    )
    let xcodeRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PulsePhone-DynamicXcode-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: xcodeRoot) }
    let xcodeCache = try DynamicDeveloperImageAssetCache(
      rootURL: xcodeRoot,
      configuration: configuration,
      fetch: { _, _ in
        XCTFail("catalog-matched Xcode files must precede remote acquisition")
        return archive
      }
    )
    let xcode =
      try ProductionRuntimeOperationBackend
      .acquireDynamicAssetForPreparation(
        reference,
        assetCache: xcodeCache,
        xcodeFilesProvider: { _ in Dictionary(uniqueKeysWithValues: files) }
      )
    XCTAssertEqual(xcode.disposition, .xcodeHit)
    XCTAssertEqual(
      xcode.lease.contentManifestSHA256,
      reference.contentManifestSHA256
    )

    let remoteRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
      "PulsePhone-DynamicRemoteFallback-\(UUID().uuidString)",
      isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: remoteRoot) }
    let remoteCache = try DynamicDeveloperImageAssetCache(
      rootURL: remoteRoot,
      configuration: configuration,
      fetch: { _, _ in archive }
    )
    let mismatched = Dictionary(uniqueKeysWithValues: files).merging([
      "Image.dmg": Data("not-the-catalog-image".utf8)
    ]) { _, replacement in replacement }
    let fallback =
      try ProductionRuntimeOperationBackend
      .acquireDynamicAssetForPreparation(
        reference,
        assetCache: remoteCache,
        xcodeFilesProvider: { _ in mismatched }
      )
    XCTAssertEqual(fallback.disposition, .downloaded)
    XCTAssertEqual(
      fallback.lease.contentManifestSHA256,
      reference.contentManifestSHA256
    )
  }

  func testDynamicCatalogFailureKeepsIntegrityAndAvailabilityDistinct() throws {
    let groupID = "prep.coredevice.v2"
    for (error, expected) in [
      (.catalogMismatch, "developerImageCatalogMismatch"),
      (.sourceRejected, "developerImageCatalogMismatch"),
      (.catalogUnavailable, "developerImageCatalogUnavailable"),
      (.networkUnavailable, "developerImageCatalogUnavailable"),
      (.candidateIncompatible, "developerImageCandidateIncompatible"),
    ] as [(DynamicDeveloperImageCatalogStoreError, String)] {
      guard
        case .failedWithDetails(let code, let details) =
          try ProductionRuntimeOperationBackend
          .dynamicCatalogFailure(error, groupID: groupID)
      else {
        return XCTFail("expected typed dynamic catalog failure")
      }
      XCTAssertEqual(code, expected)
      XCTAssertEqual(details["preparationGroupID"]?.stringValue, groupID)
    }
  }

  func testDynamicPersonalizationTimeoutProjectsTypedRetryableFailure() throws {
    let groupID = "prep.coredevice.v2"
    guard case .failedWithDetails(let code, let details) =
      try ProductionRuntimeOperationBackend.dynamicPersonalizationTimeoutFailure(
        groupID: groupID
      )
    else {
      return XCTFail("expected typed dynamic personalization timeout")
    }
    XCTAssertEqual(code, "preparationTimeout")
    XCTAssertEqual(details["preparationGroupID"]?.stringValue, groupID)
    XCTAssertEqual(details["phase"]?.stringValue, "personalizing")
    XCTAssertEqual(details["retryStage"]?.stringValue, "personalizationTSS")
  }

  func testDynamicClassicMountTimeoutProjectsTypedRetryableFailure() throws {
    let groupID = "prep.legacy.developer.v2"
    guard case .failedWithDetails(let code, let details) =
      try ProductionRuntimeOperationBackend.dynamicClassicMountTimeoutFailure(
        groupID: groupID
      )
    else {
      return XCTFail("expected typed dynamic classic mount timeout")
    }
    XCTAssertEqual(code, "preparationTimeout")
    XCTAssertEqual(details["preparationGroupID"]?.stringValue, groupID)
    XCTAssertEqual(details["phase"]?.stringValue, "mounting")
    XCTAssertEqual(details["retryStage"]?.stringValue, "classicMount")
  }

    func testModernPreparationDownloadsControlledRemoteExactCatalog() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        context.setModernDeveloperSupportMounted(false)
        let target = try CanonicalUDID(
            canonicalString: context.device.facts.uniqueDeviceID
        )
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(
                repositoryRoot: repositoryRoot()
            ),
            discovery: { context.device }
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-RemoteModernPreparation-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DeveloperImageAssetStore(rootURL: root)
        let fixture = try Self.remotePersonalizedCatalogFixture(
            buildVersion: context.device.facts.buildVersion
        )
        let remote = ControlledRemoteDeveloperImageCatalog(
            configuration: fixture.configuration,
            fetch: { url, _ in
                if url == fixture.catalogURL { return fixture.catalogBytes }
                if url == fixture.archiveURL { return fixture.archiveBytes }
                throw RemoteCatalogFixtureError.unexpectedURL
            }
        )
        let bundledCatalog = try Self.personalizedDeveloperImageCatalog(
            buildVersion: "unmatched-build"
        )
        let result = try ProductionRuntimeOperationBackend.executePreparation(
            RuntimeRequestEnvelope(
                requestID: CanonicalUUID(value: UUID()),
                operation: .runtimePrepareCapabilities,
                body: try Self.object([
          ("canonicalUDID", .string(target.rawValue))
                ])
            ),
            coordinator: coordinator,
            helperExecutor: context.executor,
            developerImageCatalog: bundledCatalog,
            developerImageStore: store,
            remoteDeveloperImageCatalog: remote
        )
        guard case .succeeded(let value) = result else {
            return XCTFail("expected remote exact-build preparation: \(result)")
        }
        XCTAssertEqual(value["assetDisposition"]?.stringValue, "downloaded")
        XCTAssertEqual(value["mountDisposition"]?.stringValue, "mounted")
    XCTAssertNotNil(
      try store.openVerifiedAsset(
            catalog: fixture.catalog,
            entryID: "personalized.ios26.23F1"
        ))
    }

    func testModernPreparationRetriesActualWarmAfterCommittedMount() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        context.setModernDeveloperSupportMounted(false)
        context.failWarmGeneration()
        defer { context.allowWarmGeneration() }

        let target = try CanonicalUDID(
            canonicalString: context.device.facts.uniqueDeviceID
        )
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(
                repositoryRoot: repositoryRoot()
            ),
            discovery: { context.device }
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-WarmAfterCommittedMount-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try DeveloperImageAssetStore(rootURL: root)
        let fixture = try Self.remotePersonalizedCatalogFixture(
            buildVersion: context.device.facts.buildVersion
        )
        let remote = ControlledRemoteDeveloperImageCatalog(
            configuration: fixture.configuration,
            fetch: { url, _ in
                if url == fixture.catalogURL { return fixture.catalogBytes }
                if url == fixture.archiveURL { return fixture.archiveBytes }
                throw RemoteCatalogFixtureError.unexpectedURL
            }
        )
        let bundledCatalog = try Self.personalizedDeveloperImageCatalog(
            buildVersion: "unmatched-build"
        )

        let finished = expectation(description: "preparation completed")
        let resultStore = LockedPreparationResultStore()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { finished.fulfill() }
            do {
        resultStore.store(
          try ProductionRuntimeOperationBackend.executePreparation(
                    RuntimeRequestEnvelope(
                        requestID: CanonicalUUID(value: UUID()),
                        operation: .runtimePrepareCapabilities,
                        body: try Self.object([
                ("canonicalUDID", .string(target.rawValue))
                        ])
                    ),
                    coordinator: coordinator,
                    helperExecutor: context.executor,
                    developerImageCatalog: bundledCatalog,
                    developerImageStore: store,
                    remoteDeveloperImageCatalog: remote
                ))
            } catch {
                resultStore.store(error)
            }
        }
        try context.waitForWarmGeneration()
        usleep(50_000)
        context.allowWarmGeneration()
        wait(for: [finished], timeout: 3)
        let result = try resultStore.requireResult()

        guard case .succeeded(let value) = result else {
            return XCTFail(
                "committed mount must wait for actual warm readiness: \(result)"
            )
        }
        XCTAssertEqual(value["mountDisposition"]?.stringValue, "mounted")
        XCTAssertNotNil(context.executor.diagnosticSnapshot().activeExecutorGeneration)
    }

    func testFiniteModernCommandDoesNotExecuteWhilePreparationFailureIsPending() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        let target = try CanonicalUDID(
            canonicalString: context.device.facts.uniqueDeviceID
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-ImplicitPreparationFailure-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(
                repositoryRoot: repositoryRoot()
            ),
            discovery: { context.device }
        )
        let screenshotStore = try ProductionScreenshotArtifactStore.testing(
            temporaryBasePath: root.path,
            canonicalUDID: target,
            runtimeEpoch: 41
        )
        context.setModernDeveloperSupportMounted(false)
        let preparationJobs = ProductionPreparationJobManager()
        let result = try ProductionRuntimeOperationBackend.executeCommand(
            RuntimeRequestEnvelope(
                requestID: CanonicalUUID(value: UUID()),
                operation: .commandSubmit,
                body: try Self.object([
          (
            "actionID",
            .string(
                        CanonicalUUID(value: UUID()).canonicalString
            )
          ),
                    ("canonicalUDID", .string(target.rawValue)),
                    ("commandID", .string("button.home")),
                    ("normalizedArguments", .object(try Self.object([]))),
                ])
            ),
            coordinator: coordinator,
            helperExecutor: context.executor,
            directHelperExecutor: context.directExecutor,
            screenshotStore: screenshotStore,
            clientInstanceID: nil,
            pointerObservationSink: ProductionRuntimePointerObservationSink(),
            preparationJobs: preparationJobs
        )
        guard case .failedWithDetails(let code, let details) = result else {
            return XCTFail("expected preparation remediation before button execution")
        }
        XCTAssertEqual(code, "capabilityPreparing")
        XCTAssertEqual(details["remediation"]?.stringValue, "runDevicePrepare")
        XCTAssertFalse(context.warmGenerationObserved())
        XCTAssertFalse(context.buttonHomeObserved())
    }

    func testModernKeyboardStreamStartsPreparationWithoutOpeningInputService() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        let target = try CanonicalUDID(
            canonicalString: context.device.facts.uniqueDeviceID
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-ImplicitStreamPreparation-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(
                repositoryRoot: repositoryRoot()
            ),
            discovery: { context.device }
        )
        _ = try coordinator.refresh()
        _ = try coordinator.setLiveAttached(true)
        let catalog = try Self.personalizedDeveloperImageCatalog(
            buildVersion: context.device.facts.buildVersion
        )
        let store = try DeveloperImageAssetStore(rootURL: root)
        let actionID = CanonicalUUID(value: UUID())
        let interactionID = CanonicalUUID(value: UUID())
        let request = RuntimeRequestEnvelope(
            requestID: CanonicalUUID(value: UUID()),
            operation: .streamOpen,
            body: try Self.object([
        (
          "intent",
          .object(
            try Self.object([
                    ("actionID", .string(actionID.canonicalString)),
                    ("commandID", .string("gui.keyboard.interaction")),
                    ("normalizedArguments", .object(try Self.object([]))),
            ]))
        ),
                ("interactionID", .string(interactionID.canonicalString)),
            ])
        )

        let result = try ProductionRuntimeOperationBackend.executeStreamOpen(
            request,
            coordinator: coordinator,
            helperExecutor: context.executor,
            coordinateProjectionStore:
                ProductionRuntimeCoordinateProjectionStore(),
            directHelperExecutor: context.directExecutor,
            developerImageCatalog: catalog,
            developerImageStore: store,
            preparationJobs: ProductionPreparationJobManager()
        )
        guard case .succeeded(let value) = result else {
            return XCTFail("mounted and warm Developer Support should open keyboard stream: \(result)")
        }
        XCTAssertNotNil(value["executorGeneration"])
    }

    func testModernPointerStreamStartsPreparationBeforeGeometryQuery() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        let target = try CanonicalUDID(
            canonicalString: context.device.facts.uniqueDeviceID
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-ImplicitPointerPreparation-\(UUID().uuidString)",
            isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(
                repositoryRoot: repositoryRoot()
            ),
            discovery: { context.device }
        )
        _ = try coordinator.refresh()
        _ = try coordinator.setLiveAttached(true)
        let catalog = try Self.personalizedDeveloperImageCatalog(
            buildVersion: context.device.facts.buildVersion
        )
        let store = try DeveloperImageAssetStore(rootURL: root)
        let interactionID = CanonicalUUID(value: UUID())
        let request = RuntimeRequestEnvelope(
            requestID: CanonicalUUID(value: UUID()),
            operation: .streamOpen,
            body: try Self.object([
        (
          "intent",
          .object(
            try Self.object([
              (
                "actionID",
                .string(
                        CanonicalUUID(value: UUID()).canonicalString
                )
              ),
                    ("commandID", .string("gui.pointer.interaction")),
              (
                "normalizedArguments",
                .object(
                  try Self.object([
                        ("geometryRevision", .string("1")),
                        ("logicalHeight", .string("1170")),
                        ("logicalWidth", .string("2532")),
                        ("orientation", .string("landscapeRight")),
                  ]))
              ),
            ]))
        ),
                ("interactionID", .string(interactionID.canonicalString)),
            ])
        )

        let result = try ProductionRuntimeOperationBackend.executeStreamOpen(
            request,
            coordinator: coordinator,
            helperExecutor: context.executor,
            coordinateProjectionStore:
                ProductionRuntimeCoordinateProjectionStore(),
            directHelperExecutor: context.directExecutor,
            developerImageCatalog: catalog,
            developerImageStore: store,
            preparationJobs: ProductionPreparationJobManager()
        )
        guard case .succeeded(let value) = result else {
            return XCTFail("mounted and warm Developer Support should open pointer stream: \(result)")
        }
        XCTAssertNotNil(value["executorGeneration"])
    }

    func testLiveCommandAdmissionReusesCurrentSnapshot() throws {
        let target = try CanonicalUDID(canonicalString: "M2031-LIVE-SNAPSHOT")
        let observation = ProductionRuntimeDeviceObservation(
            rawTransportUDID: target.rawValue,
            facts: ProductionRuntimeDeviceFacts(
                buildVersion: "23F84",
                deviceClass: "iPhone",
                deviceName: "Test iPhone",
                productType: "iPhone14,7",
                productVersion: "26.5.2",
                uniqueDeviceID: target.rawValue
            ),
            condition: ProductionRuntimeDeviceCondition(
                connected: true,
                locked: false,
                trusted: true
            )
        )
        let discoveries = LockedCallCounter()
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(repositoryRoot: repositoryRoot()),
            discovery: {
                discoveries.increment()
                return observation
            }
        )

        let refreshed = try coordinator.refresh()
        _ = try coordinator.setLiveAttached(true)
        let cached = try coordinator.commandAdmissionSnapshot()

        XCTAssertEqual(discoveries.value, 1)
        XCTAssertEqual(cached.connectionEpoch, refreshed.connectionEpoch)
        XCTAssertEqual(cached.device, observation)

        _ = try coordinator.confirmDisconnected()
        let disconnected = try coordinator.commandAdmissionSnapshot()
        XCTAssertNil(disconnected.device)
        XCTAssertEqual(disconnected.connectionEpoch, refreshed.connectionEpoch)
        XCTAssertEqual(discoveries.value, 1)

        _ = try coordinator.setLiveAttached(false)
        let rediscovered = try coordinator.commandAdmissionSnapshot()
        XCTAssertEqual(rediscovered.device, observation)
        XCTAssertEqual(discoveries.value, 2)
    }

    func testProductionDeviceCoordinatorBuildsTypedOSCompatibilityDetails() throws {
        let target = try CanonicalUDID(canonicalString: "M2031-OS-COMPATIBILITY")
        let observation = ProductionRuntimeDeviceObservation(
            rawTransportUDID: target.rawValue,
            facts: ProductionRuntimeDeviceFacts(
                buildVersion: "20A000",
                deviceClass: "iPhone",
                deviceName: "Test iPhone",
                productType: "iPhone14,7",
                productVersion: "16.0",
                uniqueDeviceID: target.rawValue
            ),
            condition: ProductionRuntimeDeviceCondition(
                connected: true,
                locked: false,
                trusted: true
            )
        )
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(repositoryRoot: repositoryRoot()),
            discovery: { observation }
        )

        let (snapshot, planning) = try coordinator.plan(
            commandID: "button.home",
            rawArguments: [:]
        )
        XCTAssertEqual(planning, .unavailable(reason: "unsupportedOSVersion"))
    let details = try XCTUnwrap(
      coordinator.targetFailureDetails(
            commandID: "button.home",
            code: "unsupportedOSVersion",
            snapshot: snapshot
        ))
        XCTAssertEqual(details["deviceClass"]?.stringValue, "iPhone")
        XCTAssertEqual(details["osVersion"]?.stringValue, "16.0")
        XCTAssertEqual(
            details["reason"]?.stringValue,
            "button home requires iOS 17 or later; target device is running iOS 16.0."
        )
        XCTAssertNil(details["canonicalUDID"])
    XCTAssertNil(
      try coordinator.targetFailureDetails(
            commandID: "button.home",
            code: "capabilityUnavailable",
            snapshot: snapshot
        ))
    }

    func testCoordinateCompatibilityFailurePrecedesGeometryHelperQuery() throws {
        let target = try CanonicalUDID(
            canonicalString: "M2031-COORDINATE-COMPATIBILITY"
        )
        let observation = ProductionRuntimeDeviceObservation(
            rawTransportUDID: target.rawValue,
            facts: ProductionRuntimeDeviceFacts(
                buildVersion: "20A000",
                deviceClass: "iPhone",
                deviceName: "Test iPhone",
                productType: "iPhone14,7",
                productVersion: "16.0",
                uniqueDeviceID: target.rawValue
            ),
            condition: ProductionRuntimeDeviceCondition(
                connected: true,
                locked: false,
                trusted: true
            )
        )
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(repositoryRoot: repositoryRoot()),
            discovery: { observation }
        )
        let snapshot = try coordinator.commandAdmissionSnapshot()
        let cases: [(String, [String: String])] = [
            ("touch.tap", ["point": "0.2,0.5"]),
      (
        "touch.drag",
        [
                "durationMs": "200",
                "from": "0.2,0.5",
                "to": "0.2,0.8",
        ]
      ),
      (
        "touch.swipe",
        [
                "durationMs": "200",
                "from": "0.2,0.5",
                "to": "0.2,0.8",
        ]
      ),
        ]
        for (commandID, arguments) in cases {
            var geometryQueryCount = 0
      let result =
        try ProductionRuntimeOperationBackend
                .planCommandForExecution(
                    commandID: commandID,
                    rawArguments: arguments,
                    coordinator: coordinator,
                    snapshot: snapshot,
                    refreshCoordinateGeometry: { current in
                        geometryQueryCount += 1
                        return current
                    }
                )
            XCTAssertEqual(
                result.planning,
                .unavailable(reason: "unsupportedOSVersion"),
                commandID
            )
            XCTAssertEqual(geometryQueryCount, 0, commandID)
      let details = try XCTUnwrap(
        coordinator.targetFailureDetails(
                commandID: commandID,
                code: "unsupportedOSVersion",
                snapshot: result.snapshot
            ))
            XCTAssertEqual(details["osVersion"]?.stringValue, "16.0")
            XCTAssertTrue(
                details["reason"]?.stringValue?.contains(
                    "requires iOS 17 or later"
                ) == true,
                commandID
            )
        }
    }

    func testCompatibleCoordinateCommandRefreshesGeometryBeforeFinalPlan() throws {
        let target = try CanonicalUDID(
            canonicalString: "M2031-COORDINATE-GEOMETRY"
        )
        let observation = ProductionRuntimeDeviceObservation(
            rawTransportUDID: target.rawValue,
            facts: ProductionRuntimeDeviceFacts(
                buildVersion: "23F84",
                deviceClass: "iPhone",
                deviceName: "Test iPhone",
                productType: "iPhone14,7",
                productVersion: "26.5.2",
                uniqueDeviceID: target.rawValue
            ),
            condition: ProductionRuntimeDeviceCondition(
                connected: true,
                locked: false,
                trusted: true
            )
        )
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(repositoryRoot: repositoryRoot()),
            discovery: { observation }
        )
        let unpreparedInitial = try coordinator.commandAdmissionSnapshot()
        XCTAssertNil(unpreparedInitial.geometry)
        let initial = try coordinator.markPreparationReady(
            groupID: "prep.coredevice.v2",
            connectionEpoch: unpreparedInitial.connectionEpoch
        )
        var geometryQueryCount = 0
    let result =
      try ProductionRuntimeOperationBackend
            .planCommandForExecution(
                commandID: "touch.tap",
                rawArguments: ["point": "0.2,0.5"],
                coordinator: coordinator,
                snapshot: initial,
                refreshCoordinateGeometry: { current in
                    geometryQueryCount += 1
                    return try coordinator.synchronizeGeometry(
                        connectionEpoch: current.connectionEpoch,
                        logicalWidth: 1_170,
                        logicalHeight: 2_532,
                        orientation: .portrait
                    )
                }
            )
        XCTAssertEqual(geometryQueryCount, 1)
        XCTAssertNotNil(result.snapshot.geometry)
        guard case .planned(let plan) = result.planning else {
            return XCTFail("expected planned coordinate command")
        }
        XCTAssertEqual(plan.commandID, "touch.tap")

    XCTAssertThrowsError(
      try ProductionRuntimeOperationBackend
            .planCommandForExecution(
                commandID: "touch.tap",
                rawArguments: ["point": "0.2,0.5"],
                coordinator: coordinator,
                snapshot: result.snapshot,
                refreshCoordinateGeometry: { _ in
                    throw ProductionRuntimeCommandPlanningError
                        .geometryUnavailable
                }
        )
    ) {
                XCTAssertEqual(
                    $0 as? ProductionRuntimeCommandPlanningError,
                    .geometryUnavailable
                )
            }
    }

    func testProductionDeviceCoordinatorPlansHybridScreenshotChildRoute() throws {
        let target = try CanonicalUDID(canonicalString: "M2031-SCREENSHOT-PLAN")
        let catalog = try ExecutionProfileCatalog.load(
            repositoryRoot: repositoryRoot()
        )
        for version in ["14.0", "15.7", "16.6"] {
            let coordinator = ProductionRuntimeDeviceCoordinator(
                canonicalUDID: target,
                catalog: catalog,
                discovery: {
                    Self.deviceObservation(
                        target: target,
                        buildVersion: "legacy-\(version)",
                        productVersion: version
                    )
                }
            )
            let (snapshot, routeID) = try coordinator.planScreenshot(
                commandID: "screenshot.cli",
                rawArguments: ["outputPath": "/tmp/capture.png"]
            )
            XCTAssertEqual(snapshot.connectionEpoch, 1)
            XCTAssertEqual(
                routeID,
                ScreenshotRoute.legacyScreenshotR.rawValue,
                version
            )
            let (_, elementRouteID) = try coordinator.planScreenshot(
                commandID: "element.snapshot",
                rawArguments: ["force": "false", "format": "json"]
            )
            XCTAssertEqual(
                elementRouteID,
                ScreenshotRoute.legacyScreenshotR.rawValue,
                version
            )
        }

        let modern = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: catalog,
            discovery: { Self.deviceObservation(target: target) }
        )
        let (_, modernRouteID) = try modern.planScreenshot(
            commandID: "screenshot.cli",
            rawArguments: ["outputPath": "/tmp/capture.png"]
        )
        XCTAssertEqual(
            modernRouteID,
            ScreenshotRoute.modernCoreDevice.rawValue
        )
        let (_, modernElementRouteID) = try modern.planScreenshot(
            commandID: "element.snapshot",
            rawArguments: ["force": "false", "format": "json"]
        )
        XCTAssertEqual(
            modernElementRouteID,
            ScreenshotRoute.modernCoreDevice.rawValue
        )
    }

    func testElementScreenshotPlanningReturnsStableDeviceStateFailures() throws {
        let target = try CanonicalUDID(
            canonicalString: "M2031-ELEMENT-DEVICE-STATE"
        )
        let catalog = try ExecutionProfileCatalog.load(
            repositoryRoot: repositoryRoot()
        )
        let cases: [(ProductionRuntimeDeviceCondition, String, String)] = [
            (
                ProductionRuntimeDeviceCondition(
                    connected: false,
                    locked: false,
                    trusted: true
                ),
                "26.5.2",
                "deviceDisconnected"
            ),
            (
                ProductionRuntimeDeviceCondition(
                    connected: true,
                    locked: false,
                    trusted: false
                ),
                "26.5.2",
                "deviceNotTrusted"
            ),
            (
                ProductionRuntimeDeviceCondition(
                    connected: true,
                    locked: true,
                    trusted: true
                ),
                "26.5.2",
                "deviceLocked"
            ),
            (
                ProductionRuntimeDeviceCondition(
                    connected: true,
                    locked: false,
                    trusted: true
                ),
                "13.7",
                "unsupportedOSVersion"
            ),
        ]
        for (condition, version, expected) in cases {
            let coordinator = ProductionRuntimeDeviceCoordinator(
                canonicalUDID: target,
                catalog: catalog,
                discovery: {
                    ProductionRuntimeDeviceObservation(
                        rawTransportUDID: target.rawValue,
                        facts: ProductionRuntimeDeviceFacts(
                            buildVersion: "test-build",
                            deviceClass: "iPhone",
                            deviceName: "Test iPhone",
                            productType: "iPhone14,7",
                            productVersion: version,
                            uniqueDeviceID: target.rawValue
                        ),
                        condition: condition
                    )
                }
            )
      XCTAssertThrowsError(
        try coordinator.planScreenshot(
                commandID: "element.snapshot",
                rawArguments: ["force": "false", "format": "json"]
        )
      ) { error in
                XCTAssertEqual(
                    error as? ProductionRuntimeDeviceCoordinatorError,
                    .screenshotUnavailable(expected),
                    version
                )
            }
        }
    }

    func testProductionLegacyScreenshotUsesDirectHelperAndArtifactStore() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        let target = try CanonicalUDID(
            canonicalString: context.device.facts.uniqueDeviceID
        )
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(
                repositoryRoot: repositoryRoot()
            ),
            discovery: {
                Self.deviceObservation(
                    target: target,
                    buildVersion: "18D70",
                    productVersion: "14.4.2"
                )
            }
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-LegacyScreenshot-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let developerImage = Data("legacy-screenshot-image".utf8)
        let developerImageSignature = Data(
            "legacy-screenshot-signature".utf8
        )
        let developerImageCatalog = try Self.legacyDeveloperImageCatalog(
            buildVersion: "18D70",
            image: developerImage,
            signature: developerImageSignature
        )
        let developerImageStore = try DeveloperImageAssetStore(
            rootURL: root.appendingPathComponent(
                "DeveloperImages",
                isDirectory: true
            )
        )
        _ = try developerImageStore.publish(
            catalog: developerImageCatalog,
            entryID: "legacy.18d70",
            archiveEntries: [
                DeveloperImageArchiveEntry(
                    path: "DeveloperDiskImage.dmg",
                    kind: .regularFile,
                    bytes: developerImage
                ),
                DeveloperImageArchiveEntry(
                    path: "DeveloperDiskImage.dmg.signature",
                    kind: .regularFile,
                    bytes: developerImageSignature
                ),
            ]
        )
        let store = try ProductionScreenshotArtifactStore.testing(
            temporaryBasePath: root.path,
            canonicalUDID: target,
            runtimeEpoch: 41
        )
        let failureRequest = RuntimeRequestEnvelope(
            requestID: CanonicalUUID(value: UUID()),
            operation: .commandSubmit,
            body: try Self.object([
        (
          "actionID",
          .string(
                    CanonicalUUID(value: UUID()).canonicalString
          )
        ),
                ("canonicalUDID", .string(target.rawValue)),
                ("commandID", .string("screenshot.gui")),
        ("normalizedArguments", .object(try Self.object([]))),
            ])
        )
        let preparationJobs = ProductionPreparationJobManager()
        let failure = try ProductionRuntimeOperationBackend.executeCommand(
            failureRequest,
            coordinator: coordinator,
            helperExecutor: context.executor,
            directHelperExecutor: context.directExecutor,
            screenshotStore: store,
            clientInstanceID: nil,
            pointerObservationSink:
                ProductionRuntimePointerObservationSink(),
            developerImageCatalog: developerImageCatalog,
            developerImageStore: developerImageStore,
            preparationJobs: preparationJobs
        )
        guard case .failedWithDetails(let failureCode, let failureDetails) = failure
        else {
            switch failure {
            case .artifact:
                return XCTFail("typed failure returned an artifact")
            case .failed(let code):
                return XCTFail("typed failure lost details: \(code)")
            case .failedWithDetails(let code, let details):
                return XCTFail("typed failure was reprojected: \(code) \(details)")
            case .outcomeUnknown(let code):
                return XCTFail("typed failure became unknown: \(code)")
            case .standard(let value):
                return XCTFail("typed failure payload was malformed: \(value)")
            case .succeeded(let value):
                return XCTFail("typed failure became success: \(value)")
            }
        }
        XCTAssertEqual(failureCode, "capabilityPreparing")
        XCTAssertEqual(failureDetails["remediation"]?.stringValue, "runDevicePrepare")
        XCTAssertEqual(
            failureDetails["preparationGroup"]?.stringValue,
            "prep.legacy.developer.v2"
        )

    let preparation =
      try ProductionRuntimeOperationBackend
            .executePreparationRequest(
                RuntimeRequestEnvelope(
                    requestID: CanonicalUUID(value: UUID()),
                    operation: .runtimePrepareCapabilities,
                    body: try Self.object([
                        ("canonicalUDID", .string(target.rawValue)),
                        ("mode", .string("waitForTerminal")),
                    ])
                ),
                coordinator: coordinator,
                helperExecutor: context.executor,
                directHelperExecutor: context.directExecutor,
                developerImageCatalog: developerImageCatalog,
                developerImageStore: developerImageStore,
                preparationJobs: preparationJobs,
                preparationProgress: nil,
                selectedXcodeSnapshotProvider: { _ in nil }
            )
        guard case .succeeded = preparation else {
            return XCTFail("explicit prepare must make legacy screenshot available")
        }

        let request = RuntimeRequestEnvelope(
            requestID: CanonicalUUID(value: UUID()),
            operation: .commandSubmit,
            body: try Self.object([
        (
          "actionID",
          .string(
                    CanonicalUUID(value: UUID()).canonicalString
          )
        ),
                ("canonicalUDID", .string(target.rawValue)),
                ("commandID", .string("screenshot.cli")),
        (
          "normalizedArguments",
          .object(
            try Self.object([
              ("outputPath", .string("/tmp/capture.png"))
            ]))
        ),
            ])
        )
        let result = try ProductionRuntimeOperationBackend.executeCommand(
            request,
            coordinator: coordinator,
            helperExecutor: context.executor,
            directHelperExecutor: context.directExecutor,
            screenshotStore: store,
            clientInstanceID: nil,
            pointerObservationSink:
                ProductionRuntimePointerObservationSink(),
            developerImageCatalog: developerImageCatalog,
            developerImageStore: developerImageStore,
            preparationJobs: preparationJobs
        )

    guard
      case .artifact(
            let descriptor,
            _,
            let sizeBytes,
            let binding,
            let value
      ) = result
    else {
            switch result {
            case .failed(let code):
                return XCTFail("expected artifact, got failed: \(code)")
            case .failedWithDetails(let code, let details):
                return XCTFail(
                    "expected artifact, got failed: \(code) \(details)"
                )
            case .outcomeUnknown(let code):
                return XCTFail("expected artifact, got unknown: \(code)")
            case .standard(let value):
                return XCTFail("expected artifact, got standard: \(value)")
            case .succeeded(let value):
                return XCTFail("expected artifact, got success: \(value)")
            case .artifact:
                return XCTFail("unreachable artifact pattern")
            }
        }
        defer { _ = Darwin.close(descriptor) }
        XCTAssertEqual(sizeBytes, 12)
        XCTAssertEqual(binding, .deviceScreenshot)
        XCTAssertEqual(value["format"]?.stringValue, "png")
        var bytes = [UInt8](repeating: 0, count: Int(sizeBytes))
    XCTAssertEqual(
      bytes.withUnsafeMutableBytes {
            Darwin.read(descriptor, $0.baseAddress, $0.count)
        }, Int(sizeBytes))
        XCTAssertEqual(
            Array(bytes.prefix(8)),
            ScreenshotReservationValidator.pngSignature
        )
        var status = stat()
        XCTAssertEqual(fstat(descriptor, &status), 0)
        XCTAssertEqual(status.st_nlink, 0)
        XCTAssertEqual(fcntl(descriptor, F_GETFL) & O_ACCMODE, O_RDONLY)
        XCTAssertNil(
            context.executor.diagnosticSnapshot().activeExecutorGeneration,
            "legacy screenshot must not start CoreDevice"
        )
        XCTAssertTrue(try context.manifest().helpers.isEmpty)
    XCTAssertTrue(
      ProductionRuntimeOperationBackend.usesDirectHelper(
            routeID: ScreenshotRoute.legacyScreenshotR.rawValue
        ))
    XCTAssertFalse(
      ProductionRuntimeOperationBackend.usesDirectHelper(
            routeID: ScreenshotRoute.modernCoreDevice.rawValue
        ))
    }

    func testProductionElementSnapshotUsesOneCapturePerAttemptAndRetriesOneDrift()
        throws
    {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        let target = try CanonicalUDID(
            canonicalString: context.device.facts.uniqueDeviceID
        )
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(
                repositoryRoot: repositoryRoot()
            ),
            discovery: { context.device }
        )
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-ElementRuntime-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: root) }
        let developerImageCatalog = try Self.personalizedDeveloperImageCatalog(
            buildVersion: context.device.facts.buildVersion
        )
        let developerImageStore = try DeveloperImageAssetStore(
            rootURL: root.appendingPathComponent(
                "DeveloperImages",
                isDirectory: true
            )
        )
        let store = try ProductionScreenshotArtifactStore.testing(
            temporaryBasePath: root.path,
            canonicalUDID: target,
            runtimeEpoch: 41
        )
    let empty:
      @Sendable (
            ElementAnalyzerSource,
            String,
            SnapshotFrame
        ) -> ElementAnalyzerResult = { source, profileID, frame in
            let stageTimings: ElementAnalyzerStageTimings
            switch source {
            case .omniparser:
                stageTimings = .init(
                    resizeAndColorSpaceMicroseconds: 0,
                    inputEncodeMicroseconds: 0,
                    requestEncodeMicroseconds: 0,
                    transportRoundTripMicroseconds: 0,
                    transportOverheadMicroseconds: 0,
                    responseDecodeMicroseconds: 0
                )
            case .vision:
                stageTimings = .noDerivedInputOrTransport
            case .appleRegion:
                stageTimings = .init(
                    resizeAndColorSpaceMicroseconds: 0,
                    inputEncodeMicroseconds: 0,
                    transportRoundTripMicroseconds: 0,
                    transportOverheadMicroseconds: 0,
                    responseDecodeMicroseconds: 0
                )
            case .localGeometry:
                stageTimings = .init()
            }
            return ElementAnalyzerResult(
                source: source,
                status: .succeeded,
                profileID: profileID,
                elapsedMilliseconds: 0,
                inputDimensions: frame.metadata.pixelDimensions,
                backend: "test",
                version: "1",
                stageTimings: stageTimings
            )
        }
        let analyzerCalls = LockedCallCounter()
        let preparationJobs = ProductionPreparationJobManager()
        let pipeline = ProductionElementSnapshotPipeline(
            canonicalUDID: target,
      analyzer: ElementAnalyzerCoordinator(
        operations: .init(
                omniparser: { frame in
                    analyzerCalls.increment()
                    let call = analyzerCalls.value
                    if [3, 5, 6].contains(call) {
                        _ = try? coordinator.synchronizeGeometry(
                            connectionEpoch: frame.metadata.connectionEpoch,
                            logicalWidth: UInt64(call),
                            logicalHeight: 1,
                            orientation: .portrait
                        )
                    }
                    return empty(
                        .omniparser,
                        ElementAnalyzerProfiles.omniparser.profileID,
                        frame
                    )
                },
                vision: { frame in
                    empty(.vision, ElementAnalyzerProfiles.visionProfileID, frame)
                },
                appleRegion: { frame in
                    empty(
                        .appleRegion,
                        ElementAnalyzerProfiles.appleRegion.profileID,
                        frame
                    )
                }
            ))
        )

        func execute(format: String) throws -> ProductionRuntimeBackendDisposition {
            try ProductionRuntimeOperationBackend.executeCommand(
                RuntimeRequestEnvelope(
                    requestID: CanonicalUUID(value: UUID()),
                    operation: .commandSubmit,
                    body: try Self.object([
            (
              "actionID",
              .string(
                            CanonicalUUID(value: UUID()).canonicalString
              )
            ),
                        ("canonicalUDID", .string(target.rawValue)),
                        ("commandID", .string("element.snapshot")),
            (
              "normalizedArguments",
              .object(
                try Self.object([
                  ("format", .string(format))
                ]))
            ),
                    ])
                ),
                coordinator: coordinator,
                helperExecutor: context.executor,
                directHelperExecutor: context.directExecutor,
                elementSnapshotPipeline: pipeline,
                screenshotStore: store,
                clientInstanceID: nil,
                pointerObservationSink: ProductionRuntimePointerObservationSink(),
                developerImageCatalog: developerImageCatalog,
                developerImageStore: developerImageStore,
                preparationJobs: preparationJobs
            )
        }

    let preparation =
      try ProductionRuntimeOperationBackend
            .executePreparationRequest(
                RuntimeRequestEnvelope(
                    requestID: CanonicalUUID(value: UUID()),
                    operation: .runtimePrepareCapabilities,
                    body: try Self.object([
                        ("canonicalUDID", .string(target.rawValue)),
                        ("mode", .string("waitForTerminal")),
                    ])
                ),
                coordinator: coordinator,
                helperExecutor: context.executor,
                directHelperExecutor: context.directExecutor,
                developerImageCatalog: developerImageCatalog,
                developerImageStore: developerImageStore,
                preparationJobs: preparationJobs,
                preparationProgress: nil,
                selectedXcodeSnapshotProvider: { _ in nil }
            )
        guard case .succeeded = preparation else {
            return XCTFail("explicit prepare must make element capture available")
        }

        guard case .succeeded(let json) = try execute(format: "json") else {
            return XCTFail("expected JSON element snapshot")
        }
        XCTAssertEqual(
            try json["snapshotGeneration"]?.numberValue?.requireUInt64(),
            1
        )
        let initialCapture = try XCTUnwrap(json["capture"]?.objectValue)
        XCTAssertEqual(initialCapture["provider"]?.stringValue, "dvt")
        XCTAssertEqual(
            initialCapture["attempts"]?.arrayValue?.count,
            1
        )
        XCTAssertNil(initialCapture["fallbackReason"]?.objectValue)
        XCTAssertNil(json["annotation"])

    guard
      case .artifact(
            let descriptor,
            _,
            let sizeBytes,
            let binding,
            let both
      ) = try execute(format: "both")
    else {
            return XCTFail("expected bound annotation artifact")
        }
        defer { _ = Darwin.close(descriptor) }
        XCTAssertGreaterThan(sizeBytes, 8)
        XCTAssertEqual(binding.elementAnnotation?.snapshotGeneration, 2)
        XCTAssertEqual(binding.elementAnnotation?.pixelWidth, 1)
        XCTAssertEqual(binding.elementAnnotation?.pixelHeight, 1)
        XCTAssertEqual(
            both["annotation"]?.objectValue?["snapshotGeneration"]?
                .numberValue.flatMap { try? $0.requireUInt64() },
            2
        )
        XCTAssertEqual(fcntl(descriptor, F_GETFL) & O_ACCMODE, O_RDONLY)
        var status = stat()
        XCTAssertEqual(fstat(descriptor, &status), 0)
        XCTAssertEqual(status.st_nlink, 0)

        guard case .succeeded(let retried) = try execute(format: "json") else {
            return XCTFail("one geometry drift must retry with fresh authority")
        }
        XCTAssertEqual(
            try retried["snapshotGeneration"]?.numberValue?.requireUInt64(),
            4
        )
        XCTAssertEqual(analyzerCalls.value, 4)

        guard case .failed(let code) = try execute(format: "json") else {
            return XCTFail("a second consecutive geometry drift must fail closed")
        }
        XCTAssertEqual(code, "capabilityUnavailable")
        XCTAssertEqual(analyzerCalls.value, 6)

        let buttonResult = try ProductionRuntimeOperationBackend.executeCommand(
            RuntimeRequestEnvelope(
                requestID: CanonicalUUID(value: UUID()),
                operation: .commandSubmit,
                body: try Self.object([
          (
            "actionID",
            .string(
                        CanonicalUUID(value: UUID()).canonicalString
            )
          ),
                    ("canonicalUDID", .string(target.rawValue)),
                    ("commandID", .string("button.home")),
                    ("normalizedArguments", .object(try Self.object([]))),
                ])
            ),
            coordinator: coordinator,
            helperExecutor: context.executor,
            directHelperExecutor: context.directExecutor,
            elementSnapshotPipeline: pipeline,
            screenshotStore: store,
            clientInstanceID: nil,
            pointerObservationSink: ProductionRuntimePointerObservationSink()
        )
        guard case .standard(let button) = buttonResult else {
            return XCTFail(
                "Element failure must not prevent a non-Element command"
            )
        }
        XCTAssertEqual(button["outcome"]?.stringValue, "succeeded")

        context.enableCoreDeviceScreenshotFallback()
        guard case .succeeded(let coreDevice) = try execute(format: "json") else {
            return XCTFail("CoreDevice fallback must publish the captured snapshot")
        }
        let coreCapture = try XCTUnwrap(coreDevice["capture"]?.objectValue)
        XCTAssertEqual(coreCapture["provider"]?.stringValue, "coreDevice")
        let coreAttempts = try XCTUnwrap(coreCapture["attempts"]?.arrayValue)
        XCTAssertEqual(coreAttempts.count, 2)
        XCTAssertEqual(
            coreAttempts.compactMap {
                $0.objectValue?["status"]?.stringValue
            },
            ["failed", "succeeded"]
        )
        let fallbackReason = try XCTUnwrap(
            coreCapture["fallbackReason"]?.objectValue
        )
        XCTAssertEqual(
            fallbackReason["failedProvider"]?.stringValue,
            "dvt"
        )
        XCTAssertEqual(
            fallbackReason["failureStage"]?.stringValue,
            "captureOrValidate"
        )
        XCTAssertEqual(
            try coreDevice["snapshotGeneration"]?.numberValue?.requireUInt64(),
            7
        )
        XCTAssertNil(
            context.executor.diagnosticSnapshot().activeExecutorGeneration,
            "fallback must retire the generation poisoned by DVT failure"
        )
        XCTAssertTrue(try context.manifest().helpers.isEmpty)

        context.enableAXAuditScreenshotFallback()
        guard case .succeeded(let axAudit) = try execute(format: "json") else {
            return XCTFail("AXAudit fallback must publish the captured snapshot")
        }
        let axAuditCapture = try XCTUnwrap(axAudit["capture"]?.objectValue)
        XCTAssertEqual(axAuditCapture["provider"]?.stringValue, "axAudit")
        let axAuditAttempts = try XCTUnwrap(
            axAuditCapture["attempts"]?.arrayValue
        )
        XCTAssertEqual(axAuditAttempts.count, 3)
        XCTAssertEqual(
            axAuditAttempts.compactMap {
                $0.objectValue?["provider"]?.stringValue
            },
            ["dvt", "coreDevice", "axAudit"]
        )
        XCTAssertEqual(
            axAuditAttempts.compactMap {
                $0.objectValue?["status"]?.stringValue
            },
            ["failed", "failed", "succeeded"]
        )
        let axAuditFallbackReason = try XCTUnwrap(
            axAuditCapture["fallbackReason"]?.objectValue
        )
        XCTAssertEqual(
            axAuditFallbackReason["failedProvider"]?.stringValue,
            "coreDevice"
        )
        XCTAssertEqual(
            try axAudit["snapshotGeneration"]?.numberValue?.requireUInt64(),
            8
        )
        XCTAssertNil(
            context.executor.diagnosticSnapshot().activeExecutorGeneration
        )
        XCTAssertTrue(try context.manifest().helpers.isEmpty)
    }

    func testTestOnlyInjectedGoHelpersSatisfyStartupContract() throws {
        let root = repositoryRoot()
        let outputRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-GoHelper-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: outputRoot) }
        let helpers: [(String, TestOnlyHelperLaunchOverride)] = [
            (
                "direct",
                TestOnlyHelperLaunchOverride(
                    executableURL: try buildTestOnlyGoHelper(
                        repositoryRoot: root,
                        outputRoot: outputRoot,
                        command: "pulsephone-direct-helper"
                    )
                )
            ),
            (
                "coreDevice",
                TestOnlyHelperLaunchOverride(
                    executableURL: try buildTestOnlyGoHelper(
                        repositoryRoot: root,
                        outputRoot: outputRoot,
                        command: "pulsephone-coredevice-helper"
                    )
                )
            ),
        ]

        for (kind, override) in helpers {
            let context = try CoreDeviceExecutorTestContext(
                coreDeviceHelperLaunchOverride: kind == "coreDevice" ? override : nil,
                directHelperLaunchOverride: kind == "direct" ? override : nil
            )
            defer { context.cleanup() }
      let executor =
        kind == "direct"
                ? context.directExecutor
                : context.executor
            do {
                try executor.testOnlyPerformStartupHandshake(
                    device: context.device,
                    connectionEpoch: 1
                )
            } catch {
                XCTFail("\(kind) startup handshake failed: \(error)")
                continue
            }
            let snapshot = executor.diagnosticSnapshot()
            XCTAssertEqual(snapshot.activeExecutorGeneration, 1, kind)
            XCTAssertEqual(snapshot.activeProvenance, .preCapture, kind)
            XCTAssertEqual(try context.manifest().helpers.count, 1, kind)
            executor.shutdown()
            XCTAssertTrue(try context.manifest().helpers.isEmpty, kind)
        }
    }

    func testRealDeviceProductionCoreDeviceExecutorTouchSequenceSmoke() throws {
    guard
      let rawTransportUDID = ProcessInfo.processInfo.environment[
            "PULSEPHONE_REAL_DEVICE_UDID"
      ],
      ProcessInfo.processInfo.environment[
            "PULSEPHONE_REAL_DEVICE_SWIFT_EXECUTOR_TOUCH_SMOKE"
      ] == "1"
    else {
            throw XCTSkip(
                "set PULSEPHONE_REAL_DEVICE_UDID and PULSEPHONE_REAL_DEVICE_SWIFT_EXECUTOR_TOUCH_SMOKE=1 to run the physical-device executor smoke"
            )
        }
        let target = try CanonicalUDID(canonicalString: rawTransportUDID)
        let device = ProductionRuntimeDeviceObservation(
            rawTransportUDID: rawTransportUDID,
            facts: ProductionRuntimeDeviceFacts(
                buildVersion: "23F84",
                deviceClass: "iPhone",
                deviceName: "iPhone",
                productType: "iPhone14,7",
                productVersion: "26.5.2",
                uniqueDeviceID: target.rawValue
            ),
            condition: ProductionRuntimeDeviceCondition(
                connected: true,
                locked: false,
                trusted: true
            )
        )
        let outputRoot = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-RealExecutorTouch-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: outputRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: outputRoot) }
        let helper = try buildTestOnlyGoHelper(
            repositoryRoot: repositoryRoot(),
            outputRoot: outputRoot,
            command: "pulsephone-coredevice-helper"
        )
        let context = try CoreDeviceExecutorTestContext(
            inputTimeoutMilliseconds: 15_000,
            coreDeviceHelperLaunchOverride: TestOnlyHelperLaunchOverride(
                executableURL: helper
            ),
            device: device
        )
        defer { context.cleanup() }

        func execute(
            route: String,
            payload: [String: HelperWireJSONValue]
        ) throws {
            let result = try context.executor.executeOneShot(
                requestID: CanonicalUUID(value: UUID()),
                actionID: CanonicalUUID(value: UUID()),
                parentActionID: nil,
                routeID: route,
                backendPayload: payload,
                device: device,
                connectionEpoch: 1
            )
            XCTAssertEqual(result["outcome"]?.stringValue, "succeeded", route)
        }
        func touchFrames(
            fromX: UInt16,
            fromY: UInt16,
            toX: UInt16,
            toY: UInt16,
            duration: UInt64
        ) -> [String: HelperWireJSONValue] {
            let intervalCount = (duration - 1) / 16 + 1
            let interpolate: (UInt16, UInt16, UInt64) -> UInt16 = { from, to, elapsed in
                guard elapsed > 0, from != to else { return from }
                guard elapsed < duration else { return to }
                let distance = UInt64(Swift.max(from, to) - Swift.min(from, to))
                let offset = (distance * elapsed + duration / 2) / duration
                if to > from {
                    return from + UInt16(offset)
                }
                return from - UInt16(offset)
            }
      return [
        "frames": .array(
          (0...intervalCount).map { index in
                let elapsed = index == intervalCount ? duration : index * 16
                let kind = index == 0 ? "begin" : index == intervalCount ? "end" : "move"
                return .object([
                    "elapsedMs": .unsignedInteger(elapsed),
                    "kind": .string(kind),
                    "x": .unsignedInteger(UInt64(interpolate(fromX, toX, elapsed))),
                    "y": .unsignedInteger(UInt64(interpolate(fromY, toY, elapsed))),
                ])
          })
      ]
        }

    try execute(
      route: "coredevice.warmGeneration",
      payload: [
            "operation": .string("warmGeneration"),
            "preparationAttemptID": .string(CanonicalUUID(value: UUID()).canonicalString),
            "preparationGroupID": .string("prep.coredevice.v2"),
        ])
        try execute(route: "coredevice.button.home", payload: ["commandID": .string("button.home")])
        for _ in 0..<3 {
            try execute(
                route: "coredevice.normalTouch",
                payload: touchFrames(
                    fromX: 9830, fromY: 32768, toX: 55705, toY: 32768, duration: 300
                )
            )
        }
        try execute(
            route: "coredevice.normalTouch",
            payload: touchFrames(
                fromX: 55705, fromY: 32768, toX: 9830, toY: 32768, duration: 300
            )
        )
        let artifactID = CanonicalUUID(value: UUID())
        let reservation = outputRoot.appendingPathComponent(artifactID.canonicalString + ".png")
    XCTAssertTrue(
      FileManager.default.createFile(
            atPath: reservation.path,
            contents: Data(),
            attributes: [.posixPermissions: 0o600]
        ))
    try execute(
      route: "coredevice.screenshot",
      payload: [
            "artifactID": .string(artifactID.canonicalString),
            "reservationPath": .string(reservation.path),
        ])
    XCTAssertGreaterThan(
      try XCTUnwrap(
        FileManager.default.attributesOfItem(
            atPath: reservation.path
        )[.size] as? NSNumber
      ).intValue, 0)
        try execute(
            route: "coredevice.normalTouch",
            payload: touchFrames(
                fromX: 32768, fromY: 32768, toX: 32768, toY: 32768, duration: 35
            )
        )
        try execute(
            route: "coredevice.normalTouch",
            payload: touchFrames(
                fromX: 22937, fromY: 39321, toX: 42598, toY: 39321, duration: 200
            )
        )
        try execute(
            route: "coredevice.normalTouch",
            payload: touchFrames(
                fromX: 32768, fromY: 49151, toX: 32768, toY: 22937, duration: 200
            )
        )
    }

    func testRealDeviceProductionRuntimeServerTouchSequenceSmoke() throws {
    guard
      let rawTransportUDID = ProcessInfo.processInfo.environment[
            "PULSEPHONE_REAL_DEVICE_UDID"
      ],
      ProcessInfo.processInfo.environment[
            "PULSEPHONE_REAL_DEVICE_RUNTIME_SERVER_TOUCH_SMOKE"
      ] == "1"
    else {
            throw XCTSkip(
                "set PULSEPHONE_REAL_DEVICE_UDID and PULSEPHONE_REAL_DEVICE_RUNTIME_SERVER_TOUCH_SMOKE=1 to run the physical-device Runtime server smoke"
            )
        }
        let target = try CanonicalUDID(canonicalString: rawTransportUDID)
        let server = try ProductionRuntimeServer.bundled(canonicalUDID: target)
        let stopped = expectation(description: "physical Runtime server stopped")
        let serverErrors = LockedErrorStore()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { stopped.fulfill() }
            do {
                try server.run()
            } catch {
                serverErrors.store(error)
            }
        }
        var stoppedServer = false
        defer {
            if !stoppedServer {
                server.requestStop()
                wait(for: [stopped], timeout: 5)
            }
        }
        try waitForNode(try RuntimeSocketPath.current(for: target).path)
        let client = try RuntimeClient.testing(
            canonicalAppPath: CanonicalAppPath(
                canonicalBundlePath: "/Applications/PulsePhone.app"
      )
        )
        var health: RuntimeClientResponse?
        var lastReadinessError: (any Error)?
    let readinessDeadline =
      DispatchTime.now().uptimeNanoseconds
            + 5_000_000_000
        var attempt = 0
        while DispatchTime.now().uptimeNanoseconds < readinessDeadline {
            attempt += 1
            print("runtime-server-touch step=health attempt=\(attempt)")
            do {
                health = try client.request(
                    operation: .runtimeHealth,
                    canonicalUDID: target,
                    body: try Self.object([
            ("canonicalUDID", .string(target.rawValue))
                    ]),
                    activation: .existingOnly,
                    timeoutSeconds: 1
                )
                print("runtime-server-touch step=health outcome=succeeded")
                break
            } catch let error as RuntimeClientError {
                switch error {
                case .socketUnavailable:
                    lastReadinessError = error
                    usleep(10_000)
                case .transportFailure(let code) where code == EAGAIN || code == EWOULDBLOCK:
                    lastReadinessError = error
                    usleep(10_000)
                default:
                    XCTFail(
                        "runtime-server-touch step=health attempt=\(attempt) error=\(error)"
                    )
                    throw error
                }
            } catch {
                XCTFail(
                    "runtime-server-touch step=health attempt=\(attempt) error=\(error)"
                )
                throw error
            }
        }
        guard let health else {
            XCTFail(
                "runtime-server-touch step=health deadlineExceeded lastError=\(String(describing: lastReadinessError))"
            )
            throw RuntimeClientError.transportFailure(errno: ETIMEDOUT)
        }
        XCTAssertEqual(health.result["outcome"]?.stringValue, "succeeded")

        func command(
            _ commandID: String,
            rawArguments: [String: String] = [:]
        ) throws {
            print(
                "runtime-server-touch step=command commandID=\(commandID) rawArguments=\(rawArguments)"
            )
      let arguments = try RepositoryJSONObject(
        members: rawArguments.map {
                RepositoryJSONMember(key: $0.key, value: .string($0.value))
            })
            let response: RuntimeClientResponse
            do {
                response = try client.request(
                    operation: .commandSubmit,
                    canonicalUDID: target,
                    body: try Self.object([
                        ("actionID", .string(CanonicalUUID(value: UUID()).canonicalString)),
                        ("canonicalUDID", .string(target.rawValue)),
                        ("commandID", .string(commandID)),
                        ("normalizedArguments", .object(arguments)),
                    ]),
                    activation: .existingOnly
                )
            } catch {
                XCTFail(
                    "runtime-server-touch step=command commandID=\(commandID) rawArguments=\(rawArguments) error=\(error)"
                )
                throw error
            }
            guard response.result["outcome"]?.stringValue == "succeeded" else {
                XCTFail(
                    "\(commandID) rawArguments=\(rawArguments) result=\(response.result)"
                )
                throw RuntimeClientError.invalidResponse
            }
        }

        try command("button.home")
        for _ in 0..<3 {
            try command(
                "touch.swipe",
                rawArguments: [
                    "durationMs": "300",
                    "from": "0.15,0.5",
                    "to": "0.85,0.5",
                ]
            )
        }
        try command(
            "touch.swipe",
            rawArguments: [
                "durationMs": "300",
                "from": "0.85,0.5",
                "to": "0.15,0.5",
            ]
        )
        print("runtime-server-touch step=screenshot")
        let screenshot: RuntimeClientScreenshotResponse
        do {
            screenshot = try client.requestScreenshot(
                canonicalUDID: target,
                body: try Self.object([
                    ("actionID", .string(CanonicalUUID(value: UUID()).canonicalString)),
                    ("canonicalUDID", .string(target.rawValue)),
                    ("commandID", .string("screenshot.cli")),
          (
            "normalizedArguments",
            .object(
              try Self.object([
                ("outputPath", .string("/tmp/pulsephone-runtime-server-touch.png"))
              ]))
          ),
                ]),
                activation: .existingOnly,
                requestID: CanonicalUUID(value: UUID())
            )
        } catch {
            XCTFail("runtime-server-touch step=screenshot error=\(error)")
            throw error
        }
        XCTAssertEqual(screenshot.result["outcome"]?.stringValue, "succeeded")
        XCTAssertGreaterThan(try XCTUnwrap(screenshot.artifact).bytes.count, 0)
        try command(
            "touch.tap",
            rawArguments: ["point": "0.5,0.5"]
        )
        try command(
            "touch.drag",
            rawArguments: [
                "durationMs": "200",
                "from": "0.35,0.6",
                "to": "0.65,0.6",
            ]
        )
        try command(
            "touch.swipe",
            rawArguments: [
                "durationMs": "200",
                "from": "0.5,0.75",
                "to": "0.5,0.35",
            ]
        )

        server.requestStop()
        wait(for: [stopped], timeout: 5)
        stoppedServer = true
        XCTAssertNil(serverErrors.error)
    }

    func testProductionElementAssemblyUsesFrozenDeadlinesAndStrictSelection() throws {
        XCTAssertEqual(
            ProductionRuntimeOperationBackend.elementOuterSafetyDeadlineSeconds(
                includeAnnotation: false
            ),
            ProductionElementSnapshotPipeline.jsonOuterSafetyDeadlineSeconds
        )
        XCTAssertEqual(
            ProductionRuntimeOperationBackend.elementOuterSafetyDeadlineSeconds(
                includeAnnotation: true
            ),
            ProductionElementSnapshotPipeline.annotationOuterSafetyDeadlineSeconds
        )
        XCTAssertEqual(
            ProductionRuntimeOperationBackend.elementAnalyzerSelection(rawValue: nil),
            .all
        )
        XCTAssertEqual(
            ProductionRuntimeOperationBackend.elementAnalyzerSelection(
                rawValue: "apple,omni,omni"
            )?.canonicalString,
            "omni,apple"
        )
    XCTAssertNil(
      ProductionRuntimeOperationBackend.elementAnalyzerSelection(
            rawValue: "omni,"
        ))
    }

    func testElementOwnedCancellationValidatesBodyAndReturnsNotFound() throws {
        let target = try CanonicalUDID(canonicalString: "AAAA")
        let targetRequestID = CanonicalUUID(value: UUID())
        let owner = CanonicalUUID(value: UUID())
        func request(
            canonicalUDID: String = "AAAA",
            reason: String = "ownerCancelled",
            includeExtra: Bool = false
        ) throws -> RuntimeRequestEnvelope {
            var members: [(String, RepositoryJSONValue)] = [
                ("canonicalUDID", .string(canonicalUDID)),
                ("reason", .string(reason)),
                (
                    "targetRequestID",
                    .string(targetRequestID.canonicalString)
                ),
            ]
            if includeExtra { members.append(("unexpected", .bool(true))) }
            return RuntimeRequestEnvelope(
                requestID: CanonicalUUID(value: UUID()),
                operation: .runtimeCancelOwnedPendingWork,
                body: try Self.object(members)
            )
        }

    guard
      case .succeeded(let value) =
        try ProductionRuntimeOperationBackend
            .executeCancelOwnedPendingWork(
                request(),
                canonicalUDID: target,
                clientInstanceID: owner,
                pipeline: nil
            )
        else {
            return XCTFail("expected a typed notFound disposition")
        }
        XCTAssertEqual(value["disposition"]?.stringValue, "notFound")
        XCTAssertEqual(
            value["targetRequestID"]?.stringValue,
            targetRequestID.canonicalString
        )
        XCTAssertNil(value["targetPhase"])

        for invalid in [
            try request(canonicalUDID: "BBBB"),
            try request(reason: "invalid"),
            try request(includeExtra: true),
        ] {
      guard
        case .failed(let code) =
          try ProductionRuntimeOperationBackend
                .executeCancelOwnedPendingWork(
                    invalid,
                    canonicalUDID: target,
                    clientInstanceID: owner,
                    pipeline: nil
                )
            else {
                return XCTFail("invalid cancellation body must fail")
            }
            XCTAssertEqual(code, "invalidArgument")
        }
    guard
      case .failed(let missingOwnerCode) =
        try ProductionRuntimeOperationBackend.executeCancelOwnedPendingWork(
                request(),
                canonicalUDID: target,
                clientInstanceID: nil,
                pipeline: nil
            )
        else {
            return XCTFail("missing owner must fail")
        }
        XCTAssertEqual(missingOwnerCode, "invalidArgument")
    }

    func testProductionUninstallUsesDirectHelperAcrossOSBoundary() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        let target = try CanonicalUDID(
            canonicalString: context.device.facts.uniqueDeviceID
        )
        let catalog = try ExecutionProfileCatalog.load(
            repositoryRoot: repositoryRoot()
        )
        let screenshotRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PulsePhone-Uninstall-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: screenshotRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: screenshotRoot) }
        let screenshotStore = try ProductionScreenshotArtifactStore.testing(
            temporaryBasePath: screenshotRoot.path,
            canonicalUDID: target,
            runtimeEpoch: 1
        )

        for (productVersion, buildVersion) in [
            ("14.4.2", "18D70"),
            ("16.3.1", "20D67"),
            ("17.0", "21A329"),
            ("26.5.2", "23F84"),
        ] {
            let coordinator = ProductionRuntimeDeviceCoordinator(
                canonicalUDID: target,
                catalog: catalog,
                discovery: {
                    Self.deviceObservation(
                        target: target,
                        buildVersion: buildVersion,
                        productVersion: productVersion
                    )
                }
            )
            let request = RuntimeRequestEnvelope(
                requestID: CanonicalUUID(value: UUID()),
                operation: .commandSubmit,
                body: try Self.object([
          (
            "actionID",
            .string(
                        CanonicalUUID(value: UUID()).canonicalString
            )
          ),
                    ("canonicalUDID", .string(target.rawValue)),
                    ("commandID", .string("app.uninstall")),
          (
            "normalizedArguments",
            .object(
              try Self.object([
                ("bundleID", .string("com.example.UninstallFixture"))
              ]))
          ),
                ])
            )
            let disposition = try ProductionRuntimeOperationBackend.executeCommand(
                request,
                coordinator: coordinator,
                helperExecutor: context.executor,
                directHelperExecutor: context.directExecutor,
                screenshotStore: screenshotStore,
                clientInstanceID: nil,
                pointerObservationSink: ProductionRuntimePointerObservationSink()
            )
            guard case .standard(let result) = disposition else {
                return XCTFail("expected uninstall result for iOS \(productVersion)")
            }
            XCTAssertEqual(result["outcome"]?.stringValue, "succeeded")
            XCTAssertEqual(result["commitState"]?.stringValue, "committed")
            XCTAssertEqual(
                result["value"]?.objectValue?["bundleID"]?.stringValue,
                "com.example.UninstallFixture"
            )
            XCTAssertEqual(
                result["value"]?.objectValue?["disposition"]?.stringValue,
                "uninstalled"
            )
            XCTAssertNil(context.executor.diagnosticSnapshot().activeExecutorGeneration)
            XCTAssertTrue(try context.manifest().helpers.isEmpty)
        }
    }

    func testProductionLegacyLaunchUsesDirectHelperAcrossOSBoundary() throws {
        let context = try CoreDeviceExecutorTestContext()
        defer { context.cleanup() }
        let target = try CanonicalUDID(
            canonicalString: context.device.facts.uniqueDeviceID
        )
        let catalog = try ExecutionProfileCatalog.load(
            repositoryRoot: repositoryRoot()
        )

        for (version, expectedRoute) in [
            ("14.0", "legacy.dvtLaunch"),
            ("15.7", "legacy.dvtLaunch"),
            ("16.6", "legacy.dvtLaunch"),
            ("17.0", "coredevice.appLaunch"),
        ] {
            let coordinator = ProductionRuntimeDeviceCoordinator(
                canonicalUDID: target,
                catalog: catalog,
                discovery: {
                    Self.deviceObservation(
                        target: target,
                        buildVersion: "build-\(version)",
                        productVersion: version
                    )
                }
            )
            let unpreparedSnapshot = try coordinator.commandAdmissionSnapshot()
            let snapshot = try coordinator.markPreparationReady(
                groupID: version.hasPrefix("17")
                    ? "prep.coredevice.v2"
                    : "prep.legacy.developer.v2",
                connectionEpoch: unpreparedSnapshot.connectionEpoch
            )
      let result =
        try ProductionRuntimeOperationBackend
                .planCommandForExecution(
                    commandID: "app.launch",
                    rawArguments: ["bundleID": "com.example.LegacyApp"],
                    coordinator: coordinator,
                    snapshot: snapshot,
                    refreshCoordinateGeometry: { $0 }
                )
            guard case .planned(let plan) = result.planning else {
                return XCTFail("expected app launch plan for iOS \(version)")
            }
            XCTAssertEqual(plan.candidates.map(\.routeID), [expectedRoute])
        }

        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: catalog,
            discovery: {
                Self.deviceObservation(
                    target: target,
                    buildVersion: "18D70",
                    productVersion: "14.4.2"
                )
            }
        )
        let readySnapshot = try coordinator.commandAdmissionSnapshot()
        _ = try coordinator.markPreparationReady(
            groupID: "prep.legacy.developer.v2",
            connectionEpoch: readySnapshot.connectionEpoch
        )
        let artifactRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "PulsePhone-LegacyLaunch-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: artifactRoot,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: artifactRoot) }
        let screenshotStore = try ProductionScreenshotArtifactStore.testing(
            temporaryBasePath: artifactRoot.path,
            canonicalUDID: target,
            runtimeEpoch: 41
        )
        let request = RuntimeRequestEnvelope(
            requestID: CanonicalUUID(value: UUID()),
            operation: .commandSubmit,
            body: try Self.object([
        (
          "actionID",
          .string(
                    CanonicalUUID(value: UUID()).canonicalString
          )
        ),
                ("canonicalUDID", .string(target.rawValue)),
                ("commandID", .string("app.launch")),
        (
          "normalizedArguments",
          .object(
            try Self.object([
              ("bundleID", .string("com.example.LegacyApp"))
            ]))
        ),
            ])
        )
        let result = try ProductionRuntimeOperationBackend.executeCommand(
            request,
            coordinator: coordinator,
            helperExecutor: context.executor,
            directHelperExecutor: context.directExecutor,
            screenshotStore: screenshotStore,
            clientInstanceID: nil,
            pointerObservationSink:
                ProductionRuntimePointerObservationSink()
        )
        guard case .standard(let value) = result else {
            return XCTFail("expected legacy launch result, got \(result)")
        }
        XCTAssertEqual(value["outcome"]?.stringValue, "succeeded")
        XCTAssertEqual(value["commitState"]?.stringValue, "committed")
        XCTAssertEqual(
            value["value"]?.objectValue?["bundleID"]?.stringValue,
            "com.example.LegacyApp"
        )
        XCTAssertEqual(
            value["value"]?.objectValue?["disposition"]?.stringValue,
            "launchRequested"
        )
        XCTAssertTrue(try context.manifest().helpers.isEmpty)
    }

    func testProductionLegacyLaunchPayloadSelectionAndDeadline() throws {
        let target = try CanonicalUDID(
            canonicalString: "M2031-LEGACY-LAUNCH-PAYLOAD"
        )
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(
                repositoryRoot: repositoryRoot()
            ),
            discovery: {
                Self.deviceObservation(
                    target: target,
                    buildVersion: "18D70",
                    productVersion: "14.4.2"
                )
            }
        )
        let snapshot = try coordinator.commandAdmissionSnapshot()
        let payload = try XCTUnwrap(
            ProductionRuntimeOperationBackend.helperBackendPayload(
                commandID: "app.launch",
                arguments: ["bundleID": "com.example.LegacyApp"],
                snapshot: snapshot
            )
        )
        XCTAssertEqual(payload["bundleID"], .string("com.example.LegacyApp"))
        XCTAssertEqual(payload["commandID"], .string("app.launch"))
        XCTAssertEqual(payload["operation"], .string("launch"))
    XCTAssertTrue(
      ProductionRuntimeOperationBackend.usesDirectHelper(
            routeID: "legacy.dvtLaunch"
        ))
    XCTAssertFalse(
      ProductionRuntimeOperationBackend.usesDirectHelper(
            routeID: "coredevice.appLaunch"
        ))
        XCTAssertEqual(
            ProductionCoreDeviceHelperExecutor.oneShotDeadlineNanoseconds(
                routeID: "legacy.dvtLaunch",
                startedAt: 10
            ),
            10 + UInt64(60 * 1_000) * 1_000_000
        )
    let startupFailure =
      try ProductionRuntimeOperationBackend
            .appLaunchFailedResult(stage: "helperStartup")
        XCTAssertEqual(
            startupFailure["error"]?.objectValue?["code"]?.stringValue,
            "appLaunchFailed"
        )
        XCTAssertEqual(
            startupFailure["error"]?.objectValue?["details"]?
                .objectValue?["stage"]?.stringValue,
            "helperStartup"
        )
    let unknown =
      try ProductionRuntimeOperationBackend
            .appLaunchOutcomeUnknownResult()
        XCTAssertEqual(unknown["outcome"]?.stringValue, "outcomeUnknown")
        XCTAssertEqual(unknown["commitState"]?.stringValue, "unknown")
        XCTAssertEqual(
            unknown["error"]?.objectValue?["details"]?
                .objectValue?["reason"]?.stringValue,
            "commitStateUnknown"
        )
    }

    func testProductionPayloadAndResultProjectionCoverModernCoreDeviceRoutes() throws {
        let target = try CanonicalUDID(canonicalString: "M2031-MODERN-ROUTES")
        let observation = ProductionRuntimeDeviceObservation(
            rawTransportUDID: target.rawValue,
            facts: ProductionRuntimeDeviceFacts(
                buildVersion: "23F84",
                deviceClass: "iPhone",
                deviceName: "Test iPhone",
                productType: "iPhone14,7",
                productVersion: "26.5.2",
                uniqueDeviceID: target.rawValue
            ),
            condition: ProductionRuntimeDeviceCondition(
                connected: true,
                locked: false,
                trusted: true
            )
        )
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(repositoryRoot: repositoryRoot()),
            discovery: { observation }
        )
        _ = try coordinator.refresh()
        _ = try coordinator.markPreparationReady(
            groupID: "prep.coredevice.v2",
            connectionEpoch: 1
        )
        let snapshot = try coordinator.updateGeometry(
            connectionEpoch: 1,
            geometryRevision: 7,
            logicalWidth: 1170,
            logicalHeight: 2532,
            orientation: .portrait
        )

        let rotatePayload = try XCTUnwrap(
            ProductionRuntimeOperationBackend.helperBackendPayload(
                commandID: "device.rotate",
                arguments: ["direction": "right"],
                snapshot: snapshot
            )
        )
        XCTAssertEqual(rotatePayload["connectionEpoch"]?.uintValue, 1)
        XCTAssertEqual(rotatePayload["geometryRevision"]?.uintValue, 7)
        XCTAssertEqual(rotatePayload["logicalWidth"]?.uintValue, 1170)
        XCTAssertEqual(rotatePayload["logicalHeight"]?.uintValue, 2532)
        XCTAssertEqual(rotatePayload["direction"]?.stringValue, "right")
        XCTAssertEqual(rotatePayload["orientation"]?.stringValue, "portrait")
        XCTAssertEqual(
            try ProductionRuntimeOperationBackend.helperBackendPayload(
                commandID: "gui.softwareKeyboard.toggle",
                arguments: ["windowID": "window-1"],
                snapshot: snapshot
            )?["commandID"],
            .string("gui.softwareKeyboard.toggle")
        )
        XCTAssertEqual(
            try ProductionRuntimeOperationBackend.helperBackendPayload(
                commandID: "text.type",
                arguments: ["text": "hello"],
                snapshot: snapshot
            )?["text"],
            .string("hello")
        )
        let keyPayload = try XCTUnwrap(
            ProductionRuntimeOperationBackend.helperBackendPayload(
                commandID: "text.key",
                arguments: [
                    "command": "true", "control": "false", "key": "a",
                    "option": "true", "repeat": "2", "shift": "false",
                ],
                snapshot: snapshot
            )
        )
        XCTAssertEqual(keyPayload["commandID"], .string("text.key"))
        XCTAssertEqual(keyPayload["key"], .string("a"))
        XCTAssertEqual(
            keyPayload["modifiers"],
            .array([.string("command"), .string("option")])
        )
        XCTAssertEqual(keyPayload["repeat"], .unsignedInteger(2))
        let cursorPayload = try XCTUnwrap(
            ProductionRuntimeOperationBackend.helperBackendPayload(
                commandID: "text.cursor",
                arguments: [
                    "count": "3", "move": "word-left", "select": "true",
                ],
                snapshot: snapshot
            )
        )
        XCTAssertEqual(cursorPayload["count"], .unsignedInteger(3))
        XCTAssertEqual(cursorPayload["move"], .string("word-left"))
        XCTAssertEqual(cursorPayload["select"], .bool(true))
        XCTAssertEqual(
            try ProductionRuntimeOperationBackend.helperBackendPayload(
                commandID: "text.clear", arguments: [:], snapshot: snapshot
            ),
            ["commandID": .string("text.clear")]
        )
        XCTAssertEqual(
            try ProductionRuntimeOperationBackend.helperBackendPayload(
                commandID: "text.inputSource.next", arguments: [:], snapshot: snapshot
            ),
            ["commandID": .string("text.inputSource.next")]
        )
        XCTAssertNil(
            try ProductionRuntimeOperationBackend.helperBackendPayload(
                commandID: "text.key",
                arguments: [
                    "command": "false", "control": "false", "key": "a",
                    "option": "false", "repeat": "101", "shift": "false",
                ],
                snapshot: snapshot
            )
        )
        XCTAssertEqual(
            try ProductionRuntimeOperationBackend.helperBackendPayload(
                commandID: "app.launch",
                arguments: ["bundleID": "com.example.App"],
                snapshot: snapshot
            )?["bundleID"],
            .string("com.example.App")
        )

        let toggleHelper = try Self.object([
            ("commitState", .string("committed")),
            ("outcome", .string("succeeded")),
      (
        "value",
        .object(
          try Self.object([
                ("disposition", .string("acknowledged")),
                ("stateUnknown", .bool(true)),
          ]))
      ),
        ])
        let toggle = try ProductionRuntimeOperationBackend.projectCommandResult(
            commandID: "gui.softwareKeyboard.toggle",
            arguments: ["windowID": "window-1"],
            helperResult: toggleHelper,
            coordinator: coordinator,
            connectionEpoch: 1
        )
        guard case .bool(true)? = toggle["value"]?.objectValue?["stateUnknown"] else {
            return XCTFail("expected software keyboard state to remain unknown")
        }

        let helper = try Self.object([
            ("commitState", .string("committed")),
            ("outcome", .string("succeeded")),
      (
        "value",
        .object(
          try Self.object([
                ("currentDisplayOrientation", .string("landscapeRight")),
                ("displayOrientationChanged", .bool(true)),
                ("geometryRevision", .number(.uint64(8))),
                ("logicalHeight", .number(.uint64(1170))),
                ("logicalWidth", .number(.uint64(2532))),
                ("orientation", .string("landscapeRight")),
                ("outcomeKnown", .bool(true)),
                ("previousDisplayOrientation", .string("portrait")),
                ("requestedDirection", .string("right")),
                ("rotateResponseOrientation", .string("landscapeRight")),
                ("visibleOrientationConfirmed", .bool(true)),
          ]))
      ),
        ])
        let rotate = try ProductionRuntimeOperationBackend.projectCommandResult(
            commandID: "device.rotate",
            arguments: ["direction": "right"],
            helperResult: helper,
            coordinator: coordinator,
            connectionEpoch: 1,
            previousGeometry: snapshot.geometry
        )
        XCTAssertEqual(
            rotate["value"]?.objectValue?["direction"]?.stringValue,
            "right"
        )
        XCTAssertEqual(
            try rotate["value"]?.objectValue?["geometryRevision"]?.numberValue?
                .requireUInt64(),
            8
        )
        XCTAssertEqual(
            rotate["value"]?.objectValue?["orientation"]?.stringValue,
            "landscapeRight"
        )
        XCTAssertEqual(
            try rotate["value"]?.objectValue?["logicalWidth"]?.numberValue?
                .requireUInt64(),
            2532
        )
        XCTAssertEqual(
            try coordinator.refresh().planningContext.geometry?.logicalWidth,
            2532
        )

        let rotatedGeometry = try XCTUnwrap(coordinator.refresh().geometry)
        let invalidated = try coordinator.invalidateGeometry(
            connectionEpoch: 1,
            geometryRevision: 8
        )
        XCTAssertNil(invalidated.geometry)
        XCTAssertEqual(invalidated.geometryRevision, 8)
        let unchangedHelper = try Self.object([
            ("commitState", .string("committed")),
            ("outcome", .string("succeeded")),
      (
        "value",
        .object(
          try Self.object([
                ("currentDisplayOrientation", .string("landscapeRight")),
                ("displayOrientationChanged", .bool(false)),
                ("geometryRevision", .number(.uint64(9))),
                ("logicalHeight", .number(.uint64(1170))),
                ("logicalWidth", .number(.uint64(2532))),
                ("orientation", .string("landscapeRight")),
                ("outcomeKnown", .bool(false)),
                ("previousDisplayOrientation", .string("landscapeRight")),
                ("requestedDirection", .string("right")),
                ("rotateResponseOrientation", .string("portraitUpsideDown")),
                ("visibleOrientationConfirmed", .bool(false)),
          ]))
      ),
        ])
        let unchanged = try ProductionRuntimeOperationBackend.projectCommandResult(
            commandID: "device.rotate",
            arguments: ["direction": "right"],
            helperResult: unchangedHelper,
            coordinator: coordinator,
            connectionEpoch: 1,
            previousGeometry: rotatedGeometry
        )
        XCTAssertEqual(unchanged["outcome"]?.stringValue, "succeeded")
        XCTAssertEqual(
            unchanged["value"]?.objectValue?["currentDisplayOrientation"]?.stringValue,
            "landscapeRight"
        )
    guard
      case .bool(false)? = unchanged["value"]?.objectValue?[
            "displayOrientationChanged"
      ]
    else {
            return XCTFail("expected unchanged display orientation")
        }
    guard
      case .bool(false)? = unchanged["value"]?.objectValue?[
            "visibleOrientationConfirmed"
      ]
    else {
            return XCTFail("expected unconfirmed visible orientation")
        }
        XCTAssertEqual(try coordinator.refresh().geometry?.orientation, .landscapeRight)

        let invalidatedForRecovery = try coordinator.invalidateGeometry(
            connectionEpoch: 1,
            geometryRevision: 9
        )
        XCTAssertNil(invalidatedForRecovery.geometry)
        XCTAssertEqual(invalidatedForRecovery.geometryRevision, 9)
        var recoveryQueries = [UInt64]()
    let recovered =
      try ProductionRuntimeOperationBackend
            .recoverInvalidatedRotateGeometry(
                coordinator: coordinator,
                connectionEpoch: 1,
                query: { requestedRevision in
                    recoveryQueries.append(requestedRevision)
                    return try DisplayGeometryDTO(
                        connectionEpoch: 1,
                        geometryRevision: requestedRevision,
                        logicalHeight: 1170,
                        logicalWidth: 2532,
                        orientation: .landscapeRight
                    )
                }
            )
        XCTAssertEqual(recoveryQueries, [9])
        XCTAssertEqual(recovered.geometryRevision, 10)
        XCTAssertEqual(recovered.geometry?.orientation, .landscapeRight)
        XCTAssertEqual(recovered.geometry?.logicalWidth, 2532)
        let recoveredPlanning = try coordinator.plan(
            commandID: "device.rotate",
            rawArguments: ["direction": "left"],
            snapshot: recovered
        )
        guard case .planned(let recoveredPlan) = recoveredPlanning else {
            return XCTFail("rotate did not recover after actual geometry resync")
        }
        XCTAssertEqual(
            recoveredPlan.candidates.first?.routeID,
            "coredevice.orientation.rotate"
        )

    let alreadyRecovered =
      try ProductionRuntimeOperationBackend
            .recoverInvalidatedRotateGeometry(
                coordinator: coordinator,
                connectionEpoch: 1,
                query: { _ in
                    XCTFail("recovery queried after geometry was restored")
                    throw ProductionRuntimeCoordinateProjectionError.staleGeometry
                }
            )
        XCTAssertEqual(alreadyRecovered.geometryRevision, 10)
        XCTAssertEqual(alreadyRecovered.geometry?.orientation, .landscapeRight)

        let previousForMismatch = try XCTUnwrap(alreadyRecovered.geometry)
        let invalidatedForMismatch = try coordinator.invalidateGeometry(
            connectionEpoch: 1,
            geometryRevision: 10
        )
        XCTAssertNil(invalidatedForMismatch.geometry)
        let mismatchHelper = try Self.object([
            ("commitState", .string("committed")),
            ("outcome", .string("succeeded")),
      (
        "value",
        .object(
          try Self.object([
                ("currentDisplayOrientation", .string("portrait")),
                ("displayOrientationChanged", .bool(true)),
                ("geometryRevision", .number(.uint64(11))),
                ("logicalHeight", .number(.uint64(2532))),
                ("logicalWidth", .number(.uint64(1170))),
                ("orientation", .string("portrait")),
                ("outcomeKnown", .bool(false)),
                ("previousDisplayOrientation", .string("landscapeRight")),
                ("requestedDirection", .string("right")),
                ("rotateResponseOrientation", .string("portraitUpsideDown")),
                ("visibleOrientationConfirmed", .bool(false)),
          ]))
      ),
        ])
        let mismatch = try ProductionRuntimeOperationBackend.projectCommandResult(
            commandID: "device.rotate",
            arguments: ["direction": "right"],
            helperResult: mismatchHelper,
            coordinator: coordinator,
            connectionEpoch: 1,
            previousGeometry: previousForMismatch
        )
        XCTAssertEqual(mismatch["outcome"]?.stringValue, "succeeded")
    guard
      case .bool(false)? = mismatch["value"]?.objectValue?[
            "outcomeKnown"
      ]
    else {
            return XCTFail("expected unknown visible outcome")
        }
    guard
      case .bool(true)? = mismatch["value"]?.objectValue?[
            "displayOrientationChanged"
      ]
    else {
            return XCTFail("expected changed actual display orientation")
        }
    guard
      case .bool(false)? = mismatch["value"]?.objectValue?[
            "visibleOrientationConfirmed"
      ]
    else {
            return XCTFail("expected unconfirmed visible orientation")
        }
        XCTAssertEqual(try coordinator.refresh().geometry?.orientation, .portrait)

        let genericHelper = try Self.object([
            ("commitState", .string("committed")),
            ("outcome", .string("succeeded")),
      (
        "value",
        .object(
          try Self.object([
            (
              "_pulsephoneInternalTiming",
              .object(
                try Self.object([
                    ("buttonSequenceMicroseconds", .number(.uint64(50_000))),
                    ("serviceCloseMicroseconds", .number(.uint64(500))),
                    ("serviceOpenMicroseconds", .number(.uint64(2_000))),
                    ("totalMicroseconds", .number(.uint64(52_500))),
                ]))
            ),
                ("disposition", .string("acknowledged")),
                ("resolvedRouteID", .string("internal")),
          ]))
      ),
        ])
        let button = try ProductionRuntimeOperationBackend.projectCommandResult(
            commandID: "button.home",
            arguments: [:],
            helperResult: genericHelper,
            coordinator: coordinator,
            connectionEpoch: 1
        )
        XCTAssertEqual(
            button["value"]?.objectValue?["disposition"]?.stringValue,
            "acknowledged"
        )
        XCTAssertNil(
            button["value"]?.objectValue?["_pulsephoneInternalTiming"]
        )
        let text = try ProductionRuntimeOperationBackend.projectCommandResult(
            commandID: "text.type",
            arguments: ["text": "你好"],
            helperResult: try Self.object([
                ("commitState", .string("committed")),
                ("outcome", .string("succeeded")),
        (
          "value",
          .object(
            try Self.object([
              ("disposition", .string("pasteDispatched"))
            ]))
        ),
            ]),
            coordinator: coordinator,
            connectionEpoch: 1
        )
        XCTAssertEqual(
            try text["value"]?.objectValue?["textByteCount"]?.numberValue?
                .requireUInt64(),
            6
        )
    guard
      case .bool(let textRedacted)? =
            text["value"]?.objectValue?["textRedacted"]
        else {
            return XCTFail("missing text redaction marker")
        }
        XCTAssertTrue(textRedacted)
        XCTAssertEqual(
            text["value"]?.objectValue?["disposition"]?.stringValue,
            "pasteDispatched"
        )
        func macroHelper(_ disposition: String) throws -> RepositoryJSONObject {
            try Self.object([
                ("commitState", .string("committed")),
                ("outcome", .string("succeeded")),
        (
          "value",
          .object(
            try Self.object([
                    ("disposition", .string(disposition)),
                    ("resolvedRouteID", .string("coredevice.keyboardMacro")),
            ]))
        ),
            ])
        }
        let keyResult = try ProductionRuntimeOperationBackend.projectCommandResult(
            commandID: "text.key",
            arguments: [
                "command": "true", "control": "false", "key": "a",
                "option": "true", "repeat": "2", "shift": "false",
            ],
            helperResult: macroHelper("keyDispatched"),
            coordinator: coordinator,
            connectionEpoch: 1
        )
        XCTAssertEqual(
            keyResult["value"]?.objectValue?["modifiers"]?.arrayValue?
                .compactMap(\.stringValue),
            ["command", "option"]
        )
        XCTAssertEqual(
            try keyResult["value"]?.objectValue?["repeatCount"]?.numberValue?
                .requireUInt64(),
            2
        )
        let cursorResult = try ProductionRuntimeOperationBackend.projectCommandResult(
            commandID: "text.cursor",
            arguments: ["count": "3", "move": "word-left", "select": "true"],
            helperResult: macroHelper("cursorMoveDispatched"),
            coordinator: coordinator,
            connectionEpoch: 1
        )
        XCTAssertEqual(
            cursorResult["value"]?.objectValue?["move"]?.stringValue,
            "word-left"
        )
        guard case .bool(true)? = cursorResult["value"]?.objectValue?["select"] else {
            return XCTFail("expected cursor selection projection")
        }
        let clearResult = try ProductionRuntimeOperationBackend.projectCommandResult(
            commandID: "text.clear",
            arguments: [:],
            helperResult: macroHelper("clearDispatched"),
            coordinator: coordinator,
            connectionEpoch: 1
        )
        XCTAssertEqual(
            clearResult["value"]?.objectValue?["disposition"]?.stringValue,
            "clearDispatched"
        )
        let inputSourceResult = try ProductionRuntimeOperationBackend.projectCommandResult(
            commandID: "text.inputSource.next",
            arguments: [:],
            helperResult: macroHelper("inputSourceCycleDispatched"),
            coordinator: coordinator,
            connectionEpoch: 1
        )
        XCTAssertEqual(
            inputSourceResult["value"]?.objectValue?["disposition"]?.stringValue,
            "inputSourceCycleDispatched"
        )
        let extraHelperField = try Self.object([
            ("commitState", .string("committed")),
            ("outcome", .string("succeeded")),
      (
        "value",
        .object(
          try Self.object([
                ("disposition", .string("clearDispatched")),
                ("extra", .string("not-allowed")),
                ("resolvedRouteID", .string("coredevice.keyboardMacro")),
          ]))
      ),
        ])
        let rejectedExtra = try ProductionRuntimeOperationBackend.projectCommandResult(
            commandID: "text.clear",
            arguments: [:],
            helperResult: extraHelperField,
            coordinator: coordinator,
            connectionEpoch: 1
        )
        XCTAssertEqual(rejectedExtra["outcome"]?.stringValue, "outcomeUnknown")
    let readBackFailure =
      try ProductionRuntimeOperationBackend
            .projectCommandResult(
                commandID: "text.type",
                arguments: ["text": "secret"],
                helperResult: try Self.object([
                    ("commitState", .string("committed")),
          (
            "error",
            .object(
              try Self.object([
                        ("code", .string("backendFailed")),
                (
                  "details",
                  .object(
                    try Self.object([
                            ("phase", .string("executingProductRoute")),
                            ("preparationGroupID", .string("prep.coredevice.v2")),
                            ("stage", .string("pasteboardReadBack")),
                    ]))
                ),
              ]))
          ),
                    ("outcome", .string("failed")),
                ]),
                coordinator: coordinator,
                connectionEpoch: 1
            )
        XCTAssertEqual(readBackFailure["outcome"]?.stringValue, "failed")
        XCTAssertEqual(
            readBackFailure["error"]?.objectValue?["code"]?.stringValue,
            "backendFailed"
        )
        XCTAssertEqual(
            readBackFailure["error"]?.objectValue?["details"]?
                .objectValue?["stage"]?.stringValue,
            "pasteboardReadBack"
        )
        XCTAssertNil(
            readBackFailure["error"]?.objectValue?["details"]?
                .objectValue?["phase"]
        )
        let launch = try ProductionRuntimeOperationBackend.projectCommandResult(
            commandID: "app.launch",
            arguments: ["bundleID": "com.example.App"],
            helperResult: genericHelper,
            coordinator: coordinator,
            connectionEpoch: 1
        )
        XCTAssertEqual(
            launch["value"]?.objectValue?["disposition"]?.stringValue,
            "launchRequested"
        )
        XCTAssertNil(launch["value"]?.objectValue?["resolvedRouteID"])
    }

    func testRealSocketHandshakeHealthAndCommandTerminal() throws {
        let target = try CanonicalUDID(canonicalString: "M2031-RUNTIME")
        let catalogHash = String(repeating: "b", count: 64)
        let server = try ProductionRuntimeServer.testing(
            canonicalUDID: target,
            developerImageCatalogRevision: "catalog.test",
            developerImageCatalogHash: catalogHash,
            runtimeEpoch: 31
        )
        let stopped = expectation(description: "runtime stopped")
        let errors = LockedErrorStore()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { stopped.fulfill() }
            do {
                try server.run()
            } catch {
                errors.store(error)
            }
        }
        let socketPath = try RuntimeSocketPath.current(for: target).path
        try waitForNode(socketPath)
        let client = try RuntimeClient.testing(
            canonicalAppPath: CanonicalAppPath(
                canonicalBundlePath: "/Applications/PulsePhone.app"
            ),
            developerImageCatalogRevision: "catalog.test",
            developerImageCatalogHash: catalogHash
        )
        let health = try client.health(
            canonicalUDID: target,
            activation: .existingOnly
        )
        XCTAssertEqual(health.result["outcome"]?.stringValue, "succeeded")
    let manifestPath =
      "/tmp/pulsephone-\(geteuid())/"
            + target.domainSeparatedHash + ".helpers.v1.json"
        try waitForNode(manifestPath)
        let manifest = try RepositoryCanonicalJSON.parseDocument(
            [UInt8](Data(contentsOf: URL(fileURLWithPath: manifestPath))),
            maximumByteCount: 256 * 1_024
        )
        let healthValue = try XCTUnwrap(
            health.result["value"]?.objectValue
        )
        XCTAssertEqual(
            try manifest["runtimePID"]?.numberValue?.requireUInt64(),
            UInt64(getpid())
        )
        XCTAssertEqual(
            try manifest["runtimeEpoch"]?.numberValue?.requireUInt64(),
            try healthValue["runtimeEpoch"]?.numberValue?.requireUInt64()
        )
        XCTAssertEqual(manifest["helpers"]?.arrayValue?.count, 0)
        XCTAssertEqual(
            health.result["value"]?.objectValue?["canonicalUDID"]?.stringValue,
            target.rawValue
        )

    let submitter = CommandSubmitter(
      runtime: ProductionCommandSubmissionRuntime(
            client: client,
            canonicalUDID: target
        ))
    let receipt = try submitter.submit(
      CommandSubmissionIntent(
            requestID: CanonicalUUID(value: UUID()),
            actionID: CanonicalUUID(value: UUID()),
            canonicalUDID: target,
            commandID: "touch.tap",
            rawArguments: ["x": "0.5", "y": "0.5"]
        ))
        XCTAssertEqual(receipt.terminal.outcome, .failed)
        XCTAssertEqual(receipt.terminal.errorCode, "deviceDisconnected")

        server.requestStop()
        wait(for: [stopped], timeout: 3)
        XCTAssertNil(errors.error)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestPath))
    }

    func testRealSocketDeliversPreparationProgressBeforeTerminal() throws {
        let target = try CanonicalUDID(
            canonicalString: "M2031-PROGRESS-\(UUID().uuidString)"
        )
        let catalogHash = String(repeating: "b", count: 64)
        let attemptID = CanonicalUUID(value: UUID())
        let expectedProgress = try PreparationProgressV1(
            completedBytes: 64,
            phase: .downloading,
            phaseSequence: 1,
            preparationAttemptID: attemptID,
            preparationGroupID: "prep.coredevice.v2",
            sourceKind: .approvedRemote,
            stateRevision: 1,
            totalBytes: 128
        )
        let backend = ProductionRuntimeOperationBackend(
            progressReportingHandler: { request, report in
                guard request.operation == .runtimePrepareCapabilities else {
                    return .failed(code: "protocolViolation")
                }
                report(expectedProgress)
                return .succeeded(value: try Self.object([]))
            }
        )
        let server = try ProductionRuntimeServer.testing(
            canonicalUDID: target,
            developerImageCatalogRevision: "catalog.test",
            developerImageCatalogHash: catalogHash,
            runtimeEpoch: 39,
            operationBackend: backend
        )
        let stopped = expectation(description: "runtime stopped")
        let errors = LockedErrorStore()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { stopped.fulfill() }
            do {
                try server.run()
            } catch {
                errors.store(error)
            }
        }
        defer {
            server.requestStop()
            wait(for: [stopped], timeout: 3)
        }
        try waitForNode(try RuntimeSocketPath.current(for: target).path)
        let client = try RuntimeClient.testing(
            canonicalAppPath: CanonicalAppPath(
                canonicalBundlePath: "/Applications/PulsePhone.app"
            ),
            developerImageCatalogRevision: "catalog.test",
            developerImageCatalogHash: catalogHash
        )
        let observed = LockedPreparationProgressStore()
        let response = try client.request(
            operation: .runtimePrepareCapabilities,
            canonicalUDID: target,
            body: try Self.object([
        ("canonicalUDID", .string(target.rawValue))
            ]),
            activation: .existingOnly,
            onPreparationProgress: { observed.append($0) }
        )
        XCTAssertEqual(response.result["outcome"]?.stringValue, "succeeded")
        XCTAssertEqual(observed.values, [expectedProgress])
        XCTAssertNil(errors.error)
    }

    func testSpawnedRuntimePublishesReadyServesRequestsAndClosesOnStop() throws {
        let target = try CanonicalUDID(canonicalString: "M2031-PROCESS")
        let child = try spawnRuntime(target: target)
        var childReaped = false
        defer {
            _ = Darwin.close(child.reader)
            if !childReaped {
                _ = Darwin.kill(child.pid, SIGKILL)
                var status: Int32 = 0
                while Darwin.waitpid(child.pid, &status, 0) == -1, errno == EINTR {}
            }
        }

        try waitForReadable(child.reader, timeoutMilliseconds: 5_000)
        let readiness = try RepositoryCanonicalJSON.parseDocument(
            readToEOF(child.reader),
            maximumByteCount: 4_096
        )
        XCTAssertEqual(readiness["state"]?.stringValue, "ready")
        XCTAssertEqual(
            try readiness["pid"]?.numberValue?.requireUInt64(),
            UInt64(child.pid)
        )

        let client = try RuntimeClient.testing(
            canonicalAppPath: CanonicalAppPath(
                canonicalBundlePath: "/Applications/PulsePhone.app"
      )
        )
        let health = try client.health(
            canonicalUDID: target,
            activation: .existingOnly
        )
        XCTAssertEqual(health.result["outcome"]?.stringValue, "succeeded")
    let manifestPath =
      "/tmp/pulsephone-\(geteuid())/"
            + target.domainSeparatedHash + ".helpers.v1.json"
        try waitForNode(manifestPath)
        let manifest = try RepositoryCanonicalJSON.parseDocument(
            [UInt8](Data(contentsOf: URL(fileURLWithPath: manifestPath))),
            maximumByteCount: 256 * 1_024
        )
        let healthValue = try XCTUnwrap(
            health.result["value"]?.objectValue
        )
        XCTAssertEqual(
            try manifest["runtimePID"]?.numberValue?.requireUInt64(),
            UInt64(child.pid)
        )
        XCTAssertEqual(
            try manifest["runtimeEpoch"]?.numberValue?.requireUInt64(),
            try healthValue["runtimeEpoch"]?.numberValue?.requireUInt64()
        )
        XCTAssertEqual(manifest["helpers"]?.arrayValue?.count, 0)

        let stop = try RuntimeStopCommand(
            backend: ProductionRuntimeStopBackend(
                runtimeClient: client,
                runtimeExecutablePath:
                    "/Applications/PulsePhone.app/Contents/Helpers/PulsePhoneRuntime"
            )
        ).run(
            canonicalUDID: target,
            outputMode: .human
        )
        XCTAssertEqual(stop.chunk.stdout, ["Stopped"])
        try waitForExit(child.pid, timeoutMilliseconds: 3_000)
        childReaped = true
    XCTAssertFalse(
      FileManager.default.fileExists(
            atPath: try RuntimeSocketPath.current(for: target).path
        ))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestPath))
    }

    func testProductionStopRecoversKilledRuntimeWithOwnedStaleNodes() throws {
        let target = try CanonicalUDID(
            canonicalString: "M2031-DEAD-GENERATION-\(UUID().uuidString)"
        )
        let socketPath = try RuntimeSocketPath.current(for: target).path
    let manifestPath =
      "/tmp/pulsephone-\(geteuid())/"
            + target.domainSeparatedHash + ".helpers.v1.json"
        defer {
            _ = unlink(socketPath)
            _ = unlink(manifestPath)
        }
        let child = try spawnRuntime(target: target)
        var childReaped = false
        defer {
            _ = Darwin.close(child.reader)
            if !childReaped {
                _ = Darwin.kill(child.pid, SIGKILL)
                var status: Int32 = 0
                while Darwin.waitpid(child.pid, &status, 0) == -1,
          errno == EINTR
        {}
            }
        }
        try waitForReadable(child.reader, timeoutMilliseconds: 5_000)
        _ = try RepositoryCanonicalJSON.parseDocument(
            readToEOF(child.reader),
            maximumByteCount: 4_096
        )
        try waitForNode(socketPath)
        try waitForNode(manifestPath)

        XCTAssertEqual(Darwin.kill(child.pid, SIGKILL), 0)
        var status: Int32 = 0
        while Darwin.waitpid(child.pid, &status, 0) == -1, errno == EINTR {}
        childReaped = true
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestPath))

        do {
            let bootstrap = try BootstrapLock.acquire(for: target)
            let runtimeLock = try RuntimeLock.probe(whileHolding: bootstrap)
            try runtimeLock.validateStablePathIdentity()
            let manifest = try HelperManifestStore.loadCurrent(
                canonicalUDID: target
            )
            let executable = repositoryRoot()
                .appendingPathComponent(".build/debug/PulsePhoneRuntime").path
            XCTAssertEqual(
                POSIXVerifiedRecoveryProcessSystem().observeRuntime(
                    RuntimeRecoveryIdentity(
                        executablePath: executable,
                        pid: manifest.runtimePID,
                        processStartIdentity:
                            manifest.runtimeProcessStartIdentity
                    )
                ),
                .gone
            )
            XCTAssertTrue(manifest.helpers.isEmpty)
            _ = try RuntimeSocketIdentity.capture(
                path: socketPath,
                expectedOwner: geteuid()
            )
        }

        let client = try RuntimeClient.testing(
            canonicalAppPath: CanonicalAppPath(
                canonicalBundlePath: "/Applications/PulsePhone.app"
      )
        )
        let executable = repositoryRoot()
            .appendingPathComponent(".build/debug/PulsePhoneRuntime").path
        let mismatched = RuntimeStopCommand(
            backend: ProductionRuntimeStopBackend(
                runtimeClient: client,
                runtimeExecutablePath: executable,
                processSystem: IdentityMismatchRecoveryProcessSystem()
            )
        )
    XCTAssertThrowsError(
      try mismatched.run(
            canonicalUDID: target,
            outputMode: .human
      )
    ) {
            XCTAssertEqual(
                $0 as? RuntimeStopCommandError,
                .generationBusy(.identityUnknown)
            )
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertTrue(FileManager.default.fileExists(atPath: manifestPath))

        let recovered = try RuntimeStopCommand(
            backend: ProductionRuntimeStopBackend(
                runtimeClient: client,
                runtimeExecutablePath: executable
            )
        ).run(
            canonicalUDID: target,
            outputMode: .human
        )
        XCTAssertEqual(recovered.chunk.stdout, ["Already stopped"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: socketPath))
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestPath))
    }

    func testSpawnedRuntimeServesRecordingCommandsAndTraceBlocksStop() throws {
        let target = try CanonicalUDID(
            canonicalString: "M2031-RECORDING-\(UUID().uuidString)"
        )
    let artifacts =
      "/tmp/pulsephone-\(geteuid())/artifacts/"
            + target.domainSeparatedHash
        defer { try? FileManager.default.removeItem(atPath: artifacts) }
        let child = try spawnRuntime(target: target)
        var childReaped = false
        defer {
            _ = Darwin.close(child.reader)
            if !childReaped {
                _ = Darwin.kill(child.pid, SIGKILL)
                var status: Int32 = 0
                while Darwin.waitpid(child.pid, &status, 0) == -1, errno == EINTR {}
            }
        }
        try waitForReadable(child.reader, timeoutMilliseconds: 5_000)
        _ = try RepositoryCanonicalJSON.parseDocument(
            readToEOF(child.reader),
            maximumByteCount: 4_096
        )
        let client = try RuntimeClient.testing(
            canonicalAppPath: CanonicalAppPath(
                canonicalBundlePath: "/Applications/PulsePhone.app"
      )
        )
        let targetBody = try Self.object([
      ("canonicalUDID", .string(target.rawValue))
        ])
        let traceStart = try client.request(
            operation: .runtimeStartReplayTrace,
            canonicalUDID: target,
            body: targetBody,
            activation: .existingOnly
        )
        let traceValue = try XCTUnwrap(traceStart.result["value"]?.objectValue)
        let tracePath = try XCTUnwrap(traceValue["absolutePath"]?.stringValue)
        let traceID = try XCTUnwrap(traceValue["traceID"]?.stringValue)
        XCTAssertEqual(traceStart.result["outcome"]?.stringValue, "succeeded")
        let duplicateTrace = try client.request(
            operation: .runtimeStartReplayTrace,
            canonicalUDID: target,
            body: targetBody,
            activation: .existingOnly
        )
        XCTAssertEqual(
            duplicateTrace.result["error"]?.objectValue?["code"]?.stringValue,
            "traceAlreadyActive"
        )

        let diagnosticsStart = try client.request(
            operation: .runtimeStartDiagnostics,
            canonicalUDID: target,
            body: targetBody,
            activation: .existingOnly
        )
        let diagnosticsValue = try XCTUnwrap(
            diagnosticsStart.result["value"]?.objectValue
        )
        let diagnosticsPath = try XCTUnwrap(
            diagnosticsValue["absolutePath"]?.stringValue
        )
        XCTAssertEqual(
            diagnosticsStart.result["outcome"]?.stringValue,
            "succeeded"
        )
        let duplicateDiagnostics = try client.request(
            operation: .runtimeStartDiagnostics,
            canonicalUDID: target,
            body: targetBody,
            activation: .existingOnly
        )
        XCTAssertEqual(
            duplicateDiagnostics.result["error"]?.objectValue?["code"]?
                .stringValue,
            "diagnosticsAlreadyActive"
        )

        let actionID = CanonicalUUID(value: UUID())
        let command = try client.request(
            operation: .commandSubmit,
            canonicalUDID: target,
            body: try Self.object([
                ("actionID", .string(actionID.canonicalString)),
                ("canonicalUDID", .string(target.rawValue)),
                ("commandID", .string("button.home")),
                ("normalizedArguments", .object(try Self.object([]))),
            ]),
            activation: .existingOnly
        )
        XCTAssertEqual(command.result["outcome"]?.stringValue, "failed")

        let status = try client.request(
            operation: .runtimeRuntimeStatus,
            canonicalUDID: target,
            body: targetBody,
            activation: .existingOnly
        )
        let statusValue = try XCTUnwrap(status.result["value"]?.objectValue)
    guard
      case .bool(true)? = statusValue["traceSummary"]?
            .objectValue?["active"]
        else { return XCTFail("trace summary was not active") }
    guard
      case .bool(true)? = statusValue["diagnosticsSummary"]?
            .objectValue?["active"]
        else { return XCTFail("diagnostics summary was not active") }
        XCTAssertEqual(statusValue["stopBlockers"]?.arrayValue?.count, 1)

        let blockedStop = try client.request(
            operation: .runtimeStopIfIdle,
            canonicalUDID: target,
            body: targetBody,
            activation: .existingOnly
        )
        XCTAssertEqual(blockedStop.result["outcome"]?.stringValue, "failed")
        XCTAssertEqual(
            blockedStop.result["error"]?.objectValue?["code"]?.stringValue,
            "controlBusy"
        )
        XCTAssertEqual(Darwin.kill(child.pid, 0), 0)

        let traceStop = try client.request(
            operation: .runtimeStopReplayTrace,
            canonicalUDID: target,
            body: targetBody,
            activation: .existingOnly
        )
        let traceStopValue = try XCTUnwrap(
            traceStop.result["value"]?.objectValue
        )
        XCTAssertEqual(traceStopValue["absolutePath"]?.stringValue, tracePath)
        XCTAssertEqual(traceStopValue["traceID"]?.stringValue, traceID)
        XCTAssertEqual(traceStopValue["completeness"]?.stringValue, "complete")
        let noTrace = try client.request(
            operation: .runtimeStopReplayTrace,
            canonicalUDID: target,
            body: targetBody,
            activation: .existingOnly
        )
        XCTAssertEqual(
            noTrace.result["error"]?.objectValue?["code"]?.stringValue,
            "noActiveTrace"
        )

        let stop = try client.request(
            operation: .runtimeStopIfIdle,
            canonicalUDID: target,
            body: targetBody,
            activation: .existingOnly
        )
        XCTAssertEqual(
            stop.result["value"]?.objectValue?["disposition"]?.stringValue,
            "stopping"
        )
        try waitForExit(child.pid, timeoutMilliseconds: 3_000)
        childReaped = true

        let traceLines = try recordingLines(at: tracePath)
        XCTAssertEqual(traceLines.first?["kind"]?.stringValue, "trace.header")
        XCTAssertEqual(traceLines.last?["kind"]?.stringValue, "trace.footer")
        XCTAssertEqual(traceLines.last?["completeness"]?.stringValue, "complete")
        XCTAssertEqual(
            traceLines.filter { $0["kind"]?.stringValue == "trace.semantic" }
                .map { $0["eventKind"]?.stringValue },
            ["invocation", "result"]
        )
        let diagnosticLines = try recordingLines(at: diagnosticsPath)
        XCTAssertEqual(
            diagnosticLines.first?["kind"]?.stringValue,
            "diagnostic.header"
        )
        XCTAssertEqual(
            diagnosticLines.last?["kind"]?.stringValue,
            "diagnostic.footer"
        )
        XCTAssertEqual(
            diagnosticLines.last?["reason"]?.stringValue,
            "shutdown"
        )
    }

    func testRealSocketTransfersScreenshotArtifactBeforeSuccessResponse() throws {
        let target = try CanonicalUDID(
            canonicalString: "M2031-ARTIFACT-\(UUID().uuidString)"
        )
        let artifactID = CanonicalUUID(value: UUID())
        let png: [UInt8] = [
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4,
        ]
        let backend = ProductionRuntimeOperationBackend { request in
            guard request.operation == .commandSubmit else {
                return .failed(code: "protocolViolation")
            }
            let descriptor = try Self.makeUnlinkedReadOnlyFile(bytes: png)
            return .artifact(
                descriptor: descriptor,
                artifactID: artifactID,
                sizeBytes: UInt64(png.count),
                binding: .deviceScreenshot,
                value: try Self.object([
          ("artifactID", .string(artifactID.canonicalString))
                ])
            )
        }
        let catalogHash = String(repeating: "b", count: 64)
        let server = try ProductionRuntimeServer.testing(
            canonicalUDID: target,
            developerImageCatalogRevision: "catalog.test",
            developerImageCatalogHash: catalogHash,
            runtimeEpoch: 32,
            operationBackend: backend
        )
        let stopped = expectation(description: "runtime stopped")
        let errors = LockedErrorStore()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { stopped.fulfill() }
            do {
                try server.run()
            } catch {
                errors.store(error)
            }
        }
        defer {
            server.requestStop()
            wait(for: [stopped], timeout: 3)
        }
        try waitForNode(try RuntimeSocketPath.current(for: target).path)
        let client = try RuntimeClient.testing(
            canonicalAppPath: CanonicalAppPath(
                canonicalBundlePath: "/Applications/PulsePhone.app"
            ),
            developerImageCatalogRevision: "catalog.test",
            developerImageCatalogHash: catalogHash
        )
        let requestID = CanonicalUUID(value: UUID())
        let response = try client.requestScreenshot(
            canonicalUDID: target,
            body: try Self.object([
                ("actionID", .string(CanonicalUUID(value: UUID()).canonicalString)),
                ("canonicalUDID", .string(target.rawValue)),
                ("commandID", .string("screenshot.cli")),
                ("normalizedArguments", .object(try Self.object([]))),
            ]),
            activation: .existingOnly,
            requestID: requestID
        )
        XCTAssertEqual(response.result["outcome"]?.stringValue, "succeeded")
        XCTAssertEqual(response.artifact?.bytes, png)
        XCTAssertEqual(response.artifact?.contentType, "image/png")
        XCTAssertNil(errors.error)
    }

    func testRealSocketBindsElementAnnotationToSnapshotResponse() throws {
        let target = try CanonicalUDID(
            canonicalString: "M2031-ELEMENT-ARTIFACT-\(UUID().uuidString)"
        )
        let artifactID = CanonicalUUID(value: UUID())
        let captureSHA256 = String(repeating: "a", count: 64)
        let png: [UInt8] = [
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 4, 3, 2, 1,
        ]
        let annotationSHA256 = StableBytes.sha256Hex(png)
        let binding = try ElementAnnotationArtifactBinding(
            snapshotGeneration: 7,
            captureSHA256: captureSHA256,
            pixelWidth: 3,
            pixelHeight: 2
        )
        let backend = ProductionRuntimeOperationBackend { request in
            guard request.operation == .commandSubmit else {
                return .failed(code: "protocolViolation")
            }
            return .artifact(
                descriptor: try Self.makeUnlinkedReadOnlyFile(bytes: png),
                artifactID: artifactID,
                sizeBytes: UInt64(png.count),
                binding: .elementAnnotation(binding),
                value: try Self.object([
          (
            "annotation",
            .object(
              try Self.object([
                        ("artifactID", .string(artifactID.canonicalString)),
                        ("byteLength", .number(.uint64(UInt64(png.count)))),
                        ("captureSHA256", .string(captureSHA256)),
                        ("contentType", .string("image/png")),
                        ("sha256", .string(annotationSHA256)),
                        ("snapshotGeneration", .number(.uint64(7))),
              ]))
          ),
          (
            "capture",
            .object(
              try Self.object([
                        ("pixelHeight", .number(.uint64(2))),
                        ("pixelWidth", .number(.uint64(3))),
                        ("sha256", .string(captureSHA256)),
              ]))
          ),
                    ("snapshotGeneration", .number(.uint64(7))),
                ])
            )
        }
        let catalogHash = String(repeating: "b", count: 64)
        let server = try ProductionRuntimeServer.testing(
            canonicalUDID: target,
            developerImageCatalogRevision: "catalog.test",
            developerImageCatalogHash: catalogHash,
            runtimeEpoch: 35,
            operationBackend: backend
        )
        let stopped = expectation(description: "runtime stopped")
        let errors = LockedErrorStore()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { stopped.fulfill() }
            do {
                try server.run()
            } catch {
                errors.store(error)
            }
        }
        defer {
            server.requestStop()
            wait(for: [stopped], timeout: 3)
        }
        try waitForNode(try RuntimeSocketPath.current(for: target).path)
        let client = try RuntimeClient.testing(
            canonicalAppPath: CanonicalAppPath(
                canonicalBundlePath: "/Applications/PulsePhone.app"
            ),
            developerImageCatalogRevision: "catalog.test",
            developerImageCatalogHash: catalogHash
        )
        let response = try client.requestElementSnapshot(
            canonicalUDID: target,
            body: try Self.object([
                ("actionID", .string(CanonicalUUID(value: UUID()).canonicalString)),
                ("canonicalUDID", .string(target.rawValue)),
                ("commandID", .string("element.snapshot")),
        (
          "normalizedArguments",
          .object(
            try Self.object([
              ("format", .string("both"))
            ]))
        ),
            ]),
            activation: .existingOnly,
            requestID: CanonicalUUID(value: UUID()),
            expectsAnnotation: true
        )
        XCTAssertEqual(response.result["outcome"]?.stringValue, "succeeded")
        XCTAssertEqual(response.annotation?.artifact.bytes, png)
        XCTAssertEqual(response.annotation?.snapshotGeneration, 7)
        XCTAssertEqual(response.annotation?.captureSHA256, captureSHA256)
        XCTAssertNil(errors.error)
    }

    func testElementClientTimeoutSendsOwnedCancellationOnSeparateConnection()
        throws
    {
        let target = try CanonicalUDID(
            canonicalString: "M2031-ELEMENT-CANCEL-\(UUID().uuidString)"
        )
        let recorder = ElementCancellationIdentityRecorder()
        let backend = ProductionRuntimeOperationBackend(
            pointerObservationSink: ProductionRuntimePointerObservationSink()
        ) { request, clientInstanceID, _, _ in
            switch request.operation {
            case .commandSubmit:
                recorder.recordCommand(
                    clientInstanceID: clientInstanceID,
                    requestID: request.requestID
                )
                _ = recorder.cancellationReceived.wait(timeout: .now() + 4)
                return .failed(code: "executionTimeout")
            case .runtimeCancelOwnedPendingWork:
                recorder.recordCancellation(
                    clientInstanceID: clientInstanceID,
                    targetRequestID: request.body["targetRequestID"]?.stringValue,
                    reason: request.body["reason"]?.stringValue
                )
                recorder.cancellationReceived.signal()
        return .succeeded(
          value: try Self.object([
                    ("disposition", .string("cancellationRequested")),
                    (
                        "targetRequestID",
                        request.body["targetRequestID"] ?? .null
                    ),
                ]))
            default:
                return .failed(code: "invalidArgument")
            }
        }
        let catalogHash = String(repeating: "b", count: 64)
        let server = try ProductionRuntimeServer.testing(
            canonicalUDID: target,
            developerImageCatalogRevision: "catalog.test",
            developerImageCatalogHash: catalogHash,
            runtimeEpoch: 36,
            operationBackend: backend
        )
        let stopped = expectation(description: "runtime stopped")
        let errors = LockedErrorStore()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { stopped.fulfill() }
            do {
                try server.run()
            } catch {
                errors.store(error)
            }
        }
        defer {
            server.requestStop()
            wait(for: [stopped], timeout: 3)
        }
        try waitForNode(try RuntimeSocketPath.current(for: target).path)
        let client = try RuntimeClient.testing(
            canonicalAppPath: CanonicalAppPath(
                canonicalBundlePath: "/Applications/PulsePhone.app"
            ),
            developerImageCatalogRevision: "catalog.test",
            developerImageCatalogHash: catalogHash
        )
        let requestID = CanonicalUUID(value: UUID())
    XCTAssertThrowsError(
      try client.requestElementSnapshot(
            canonicalUDID: target,
            body: try Self.object([
                ("actionID", .string(CanonicalUUID(value: UUID()).canonicalString)),
                ("canonicalUDID", .string(target.rawValue)),
                ("commandID", .string("element.snapshot")),
          (
            "normalizedArguments",
            .object(
              try Self.object([
                ("format", .string("json"))
              ]))
          ),
            ]),
            activation: .existingOnly,
            requestID: requestID,
            expectsAnnotation: false,
            timeoutSeconds: 1
      )
    ) { error in
            guard case RuntimeClientError.transportFailure(let code) = error else {
                return XCTFail("expected receive timeout, got \(error)")
            }
            XCTAssertTrue(code == EAGAIN || code == EWOULDBLOCK)
        }
        XCTAssertEqual(
            recorder.cancellationRecorded.wait(timeout: .now() + 2),
            .success
        )
        XCTAssertEqual(recorder.commandClientInstanceID, recorder.cancelClientInstanceID)
        XCTAssertEqual(recorder.commandRequestID, requestID)
        XCTAssertEqual(recorder.cancelTargetRequestID, requestID.canonicalString)
        XCTAssertEqual(recorder.cancelReason, "clientDeadlineExceeded")

        let health = try client.request(
            operation: .runtimeHealth,
            canonicalUDID: target,
            body: try Self.object([
        ("canonicalUDID", .string(target.rawValue))
            ]),
            activation: .existingOnly
        )
        XCTAssertEqual(health.result["outcome"]?.stringValue, "succeeded")
        XCTAssertNil(errors.error)
    }

    func testElementClientInterruptionSendsOwnedCancellationAndRejectsLateTerminal()
        throws
    {
        let target = try CanonicalUDID(
            canonicalString: "M2031-ELEMENT-INTERRUPT-\(UUID().uuidString)"
        )
        let recorder = ElementCancellationIdentityRecorder()
        let backend = ProductionRuntimeOperationBackend(
            pointerObservationSink: ProductionRuntimePointerObservationSink()
        ) { request, clientInstanceID, _, _ in
            switch request.operation {
            case .commandSubmit:
                recorder.recordCommand(
                    clientInstanceID: clientInstanceID,
                    requestID: request.requestID
                )
                _ = recorder.cancellationReceived.wait(timeout: .now() + 4)
                return .failed(code: "executionTimeout")
            case .runtimeCancelOwnedPendingWork:
                recorder.recordCancellation(
                    clientInstanceID: clientInstanceID,
                    targetRequestID: request.body["targetRequestID"]?.stringValue,
                    reason: request.body["reason"]?.stringValue
                )
                recorder.cancellationReceived.signal()
        return .succeeded(
          value: try Self.object([
                    ("disposition", .string("cancellationRequested")),
                    (
                        "targetRequestID",
                        request.body["targetRequestID"] ?? .null
                    ),
                ]))
            default:
                return .failed(code: "invalidArgument")
            }
        }
        let catalogHash = String(repeating: "b", count: 64)
        let server = try ProductionRuntimeServer.testing(
            canonicalUDID: target,
            developerImageCatalogRevision: "catalog.test",
            developerImageCatalogHash: catalogHash,
            runtimeEpoch: 37,
            operationBackend: backend
        )
        let stopped = expectation(description: "runtime stopped")
        let serverErrors = LockedErrorStore()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { stopped.fulfill() }
            do {
                try server.run()
            } catch {
                serverErrors.store(error)
            }
        }
        defer {
            server.requestStop()
            wait(for: [stopped], timeout: 3)
        }
        try waitForNode(try RuntimeSocketPath.current(for: target).path)
        let client = try RuntimeClient.testing(
            canonicalAppPath: CanonicalAppPath(
                canonicalBundlePath: "/Applications/PulsePhone.app"
            ),
            developerImageCatalogRevision: "catalog.test",
            developerImageCatalogHash: catalogHash
        )
        let interruption = RuntimeClientElementSnapshotInterruption()
        let requestID = CanonicalUUID(value: UUID())
        let clientErrors = LockedErrorStore()
        let requestFinished = expectation(description: "interrupted request finished")
        DispatchQueue.global(qos: .userInitiated).async {
            defer { requestFinished.fulfill() }
            do {
                _ = try client.requestElementSnapshot(
                    canonicalUDID: target,
                    body: try Self.object([
                        (
                            "actionID",
                            .string(CanonicalUUID(value: UUID()).canonicalString)
                        ),
                        ("canonicalUDID", .string(target.rawValue)),
                        ("commandID", .string("element.snapshot")),
            (
              "normalizedArguments",
              .object(
                try Self.object([
                  ("format", .string("json"))
                ]))
            ),
                    ]),
                    activation: .existingOnly,
                    requestID: requestID,
                    expectsAnnotation: false,
                    interruption: interruption
                )
            } catch {
                clientErrors.store(error)
            }
        }
        XCTAssertEqual(
            recorder.commandRecorded.wait(timeout: .now() + 2),
            .success
        )
        interruption.interrupt()
        XCTAssertEqual(
            recorder.cancellationRecorded.wait(timeout: .now() + 2),
            .success
        )
        wait(for: [requestFinished], timeout: 3)
        XCTAssertEqual(
            clientErrors.error as? RuntimeClientError,
            .interrupted
        )
        XCTAssertEqual(recorder.commandClientInstanceID, recorder.cancelClientInstanceID)
        XCTAssertEqual(recorder.commandRequestID, requestID)
        XCTAssertEqual(recorder.cancelTargetRequestID, requestID.canonicalString)
        XCTAssertEqual(recorder.cancelReason, "clientInterrupted")

        let health = try client.request(
            operation: .runtimeHealth,
            canonicalUDID: target,
            body: try Self.object([
        ("canonicalUDID", .string(target.rawValue))
            ]),
            activation: .existingOnly
        )
        XCTAssertEqual(health.result["outcome"]?.stringValue, "succeeded")
        XCTAssertNil(serverErrors.error)
    }

    func testRealSocketPreservesTypedFailureDetails() throws {
        let target = try CanonicalUDID(
            canonicalString: "M2031-DETAILS-\(UUID().uuidString)"
        )
        let details = try Self.object([
            ("deviceClass", .string("iPhone")),
            ("osVersion", .string("16.0")),
            (
                "reason",
                .string(
                    "tap requires iOS 17 or later; target device is running iOS 16.0."
                )
            ),
        ])
        let backend = ProductionRuntimeOperationBackend { _ in
            .failedWithDetails(code: "unsupportedOSVersion", details: details)
        }
        let catalogHash = String(repeating: "b", count: 64)
        let server = try ProductionRuntimeServer.testing(
            canonicalUDID: target,
            developerImageCatalogRevision: "catalog.test",
            developerImageCatalogHash: catalogHash,
            runtimeEpoch: 34,
            operationBackend: backend
        )
        let stopped = expectation(description: "runtime stopped")
        let errors = LockedErrorStore()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { stopped.fulfill() }
      do { try server.run() } catch { errors.store(error) }
        }
        defer {
            server.requestStop()
            wait(for: [stopped], timeout: 3)
        }
        try waitForNode(try RuntimeSocketPath.current(for: target).path)
        let client = try RuntimeClient.testing(
            canonicalAppPath: CanonicalAppPath(
                canonicalBundlePath: "/Applications/PulsePhone.app"
            ),
            developerImageCatalogRevision: "catalog.test",
            developerImageCatalogHash: catalogHash
        )
        let response = try client.requestScreenshot(
            canonicalUDID: target,
            body: try Self.object([
        ("canonicalUDID", .string(target.rawValue))
            ]),
            activation: .existingOnly,
            requestID: CanonicalUUID(value: UUID())
        )
        XCTAssertNil(response.artifact)
        let error = try XCTUnwrap(response.result["error"]?.objectValue)
        XCTAssertEqual(error["code"]?.stringValue, "unsupportedOSVersion")
        let receivedDetails = try XCTUnwrap(error["details"]?.objectValue)
        XCTAssertEqual(receivedDetails["deviceClass"]?.stringValue, "iPhone")
        XCTAssertEqual(receivedDetails["osVersion"]?.stringValue, "16.0")
        XCTAssertEqual(
            receivedDetails["reason"]?.stringValue,
            "tap requires iOS 17 or later; target device is running iOS 16.0."
        )
        XCTAssertNil(errors.error)
    }

    func testPersistentLiveSessionSurvivesIdleTimeoutThroughStreamCleanup() throws {
        let target = try CanonicalUDID(
            canonicalString: "M2031-LIVE-\(UUID().uuidString)"
        )
        let sessionID = CanonicalUUID(value: UUID())
        let frames = LockedFrameStore()
        let streamCancels = LockedCallCounter()
        let streamOpens = LockedCallCounter()
        let backend = ProductionRuntimeOperationBackend(
            handler: { request in
                switch request.operation {
                case .commandSubmit:
          return .succeeded(
            value: try Self.object([
              ("disposition", .string("acknowledged"))
                    ]))
                case .streamOpen:
                    let intent = try XCTUnwrap(request.body["intent"]?.objectValue)
                    streamOpens.increment()
                    var members: [(String, RepositoryJSONValue)] = [
                        ("actionID", try XCTUnwrap(intent["actionID"])),
                        ("executorGeneration", .number(.uint64(7))),
            (
              "interactionID",
              try XCTUnwrap(
                            request.body["interactionID"]
              )
            ),
                        ("openedAtMonotonicNs", .number(.uint64(1))),
                        ("sessionID", .string(sessionID.canonicalString)),
                    ]
                    if streamOpens.value > 1 {
                        members.append(contentsOf: [
                            ("connectionEpoch", .number(.uint64(1))),
                            ("geometryRevision", .number(.uint64(9))),
                            ("logicalHeight", .number(.uint64(2_532))),
                            ("logicalWidth", .number(.uint64(1_170))),
                            ("orientation", .string("portrait")),
                        ])
                    }
                    return .succeeded(value: try Self.object(members))
                case .streamClose, .streamCancel:
                    if request.operation == .streamCancel {
                        streamCancels.increment()
                    }
          return .succeeded(
            value: try Self.object([
                        ("cleanupDisposition", .string("acknowledged")),
                        ("disposition", .string("closed")),
              (
                "interactionID",
                try XCTUnwrap(
                            request.body["interactionID"]
                )
              ),
                        ("sessionID", try XCTUnwrap(request.body["sessionID"])),
                    ]))
                default:
                    return .failed(code: "invalidArgument")
                }
            },
            streamFrameHandler: { frames.append($0) },
            captureReadyHandler: { connectionEpoch, _ in
        .succeeded(
          value: try Self.object([
                    ("captureProvenance", .string("postCapture")),
                    ("connectionEpoch", .number(.uint64(connectionEpoch))),
                    ("disposition", .string("ready")),
                    ("geometryRevision", .number(.uint64(4))),
                    ("logicalHeight", .number(.uint64(1_170))),
                    ("logicalWidth", .number(.uint64(2_532))),
                    ("orientation", .string("landscapeLeft")),
                ]))
            }
        )
        let catalogHash = String(repeating: "b", count: 64)
        let server = try ProductionRuntimeServer.testing(
            canonicalUDID: target,
            developerImageCatalogRevision: "catalog.test",
            developerImageCatalogHash: catalogHash,
            runtimeEpoch: 33,
            operationBackend: backend,
            connectionTimeoutSeconds: 1
        )
        let stopped = expectation(description: "runtime stopped")
        let errors = LockedErrorStore()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { stopped.fulfill() }
      do { try server.run() } catch { errors.store(error) }
        }
        defer {
            server.requestStop()
            wait(for: [stopped], timeout: 3)
        }
        try waitForNode(try RuntimeSocketPath.current(for: target).path)
        let client = try RuntimeClient.testing(
            canonicalAppPath: CanonicalAppPath(
                canonicalBundlePath: "/Applications/PulsePhone.app"
            ),
            developerImageCatalogRevision: "catalog.test",
            developerImageCatalogHash: catalogHash
        )
        let live = try client.openLiveSession(
            canonicalUDID: target,
            activation: .existingOnly
        )
        let attachment = try live.attach()
        XCTAssertEqual(attachment.connectionEpoch, 1)
        let captureActivationID = CanonicalUUID(value: UUID())
        let captureReady = try live.markLiveCaptureReady(
            captureActivationID: captureActivationID
        )
        XCTAssertEqual(
            captureReady.value["disposition"]?.stringValue,
            "ready"
        )
        XCTAssertEqual(captureReady.geometry?.connectionEpoch, 1)
        XCTAssertEqual(captureReady.geometry?.geometryRevision, 4)
        XCTAssertEqual(captureReady.geometry?.logicalWidth, 2_532)
        XCTAssertEqual(captureReady.geometry?.logicalHeight, 1_170)
        XCTAssertEqual(captureReady.geometry?.orientation, .landscapeLeft)
        let duplicateCaptureReady = try live.markLiveCaptureReady(
            captureActivationID: captureActivationID
        )
        XCTAssertEqual(
            duplicateCaptureReady.value["disposition"]?.stringValue,
            "alreadyReady"
        )
        let control = try live.submit(commandID: "button.home")
        XCTAssertEqual(control["outcome"]?.stringValue, "succeeded")
        sleep(2)
    XCTAssertThrowsError(
      try live.openStream(
            commandID: "gui.pointer.interaction",
            rawArguments: [
                "geometryRevision": "1",
                "logicalHeight": "2532",
                "logicalWidth": "1170",
                "orientation": "portrait",
            ]
      )
    ) {
            XCTAssertEqual($0 as? RuntimeClientError, .invalidResponse)
        }
        XCTAssertEqual(streamCancels.value, 1)
        XCTAssertEqual(live.ownedStreamCount, 0)
        let stream = try live.openStream(
            commandID: "gui.pointer.interaction",
            rawArguments: [
                "geometryRevision": "1",
                "logicalHeight": "2532",
                "logicalWidth": "1170",
                "orientation": "portrait",
            ]
        )
        XCTAssertEqual(stream.sessionID, sessionID)
        XCTAssertEqual(stream.acceptedGeometry?.geometryRevision, 9)
        XCTAssertEqual(stream.acceptedGeometry?.orientation, .portrait)
        try live.sendFrame(
            stream: stream,
            sequence: 0,
            frameKind: "begin",
            payload: try Self.object([
                ("x", .string("0.5")),
                ("y", .string("0.5")),
            ]),
            clientSubmittedMonotonicNanoseconds: 42
        )
        for _ in 0..<100 where frames.values.isEmpty {
            usleep(10_000)
        }
        XCTAssertEqual(frames.values.count, 1)
        XCTAssertEqual(frames.values.first?.sessionID, stream.sessionID)
        XCTAssertEqual(frames.values.first?.sequence, 0)
        XCTAssertEqual(frames.values.first?.frameKind, "begin")
        _ = try live.closeStream(stream, expectedLastSequence: 0)
        XCTAssertEqual(live.ownedStreamCount, 0)
        XCTAssertTrue(try live.detach().detached)
        try live.close()
        XCTAssertNil(live.currentAttachment)
        XCTAssertNil(errors.error)
    }

    func testRuntimeAutomaticallyStopsAfterBlockerFreeIdleGrace() throws {
        let target = try CanonicalUDID(
            canonicalString: "M2031-IDLE-\(UUID().uuidString)"
        )
        let backend = ProductionRuntimeOperationBackend(
            handler: { _ in .failed(code: "invalidArgument") }
        )
        let server = try ProductionRuntimeServer.testing(
            canonicalUDID: target,
            runtimeEpoch: 44,
            operationBackend: backend,
            connectionTimeoutSeconds: 1,
            idleGraceNanoseconds: 50_000_000
        )
        let stopped = expectation(description: "runtime stopped")
        let errors = LockedErrorStore()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { stopped.fulfill() }
            do { try server.run() } catch { errors.store(error) }
        }

        try waitForNode(try RuntimeSocketPath.current(for: target).path)
        wait(for: [stopped], timeout: 3)
        XCTAssertNil(errors.error)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: try RuntimeSocketPath.current(for: target).path
        ))
    }

    func testRealSocketPublishesCrossClientPointerObservation() throws {
        let target = try CanonicalUDID(
            canonicalString: "M2031-OBSERVATION-\(UUID().uuidString)"
        )
        let sink = ProductionRuntimePointerObservationSink()
        let backend = ProductionRuntimeOperationBackend(
            pointerObservationSink: sink,
            handler: { request, clientInstanceID, _, _ in
                guard request.operation == .commandSubmit,
                      let clientInstanceID,
                      let actionText = request.body["actionID"]?.stringValue,
                      let interactionID = try? CanonicalUUID(actionText)
                else { return .failed(code: "invalidArgument") }
                sink.publishAccepted(
                    clientInstanceID: clientInstanceID,
                    interactionID: interactionID,
                    plan: ProductionRuntimePointerObservationPlan(
                        connectionEpoch: 1,
                        frames: [
                            .init(
                                delayMilliseconds: 0,
                                projection: .init(
                                    edge: "none",
                                    frameKind: .begin,
                                    x: "0.2",
                                    y: "0.5"
                                )
                            ),
                            .init(
                                delayMilliseconds: 16,
                                projection: .init(
                                    edge: "none",
                                    frameKind: .move,
                                    x: "0.35",
                                    y: "0.5"
                                )
                            ),
                            .init(
                                delayMilliseconds: 32,
                                projection: .init(
                                    edge: "none",
                                    frameKind: .end,
                                    x: "0.5",
                                    y: "0.5"
                                )
                            ),
                        ]
                    )
                )
        return .succeeded(
          value: try Self.object([
                    ("commandID", .string("touch.swipe")),
                    ("resultSchemaID", .string("emptyResult.v1")),
                ]))
            }
        )
        let catalogHash = String(repeating: "b", count: 64)
        let server = try ProductionRuntimeServer.testing(
            canonicalUDID: target,
            developerImageCatalogRevision: "catalog.test",
            developerImageCatalogHash: catalogHash,
            runtimeEpoch: 36,
            operationBackend: backend
        )
        let stopped = expectation(description: "runtime stopped")
        let errors = LockedErrorStore()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { stopped.fulfill() }
      do { try server.run() } catch { errors.store(error) }
        }
        defer {
            server.requestStop()
            wait(for: [stopped], timeout: 3)
        }
        try waitForNode(try RuntimeSocketPath.current(for: target).path)
        let client = try RuntimeClient.testing(
            canonicalAppPath: CanonicalAppPath(
                canonicalBundlePath: "/Applications/PulsePhone.app"
            ),
            developerImageCatalogRevision: "catalog.test",
            developerImageCatalogHash: catalogHash
        )
        let subscriber = try client.openLiveSession(
            canonicalUDID: target,
            activation: .existingOnly
        )
        let attachment = try subscriber.attach(observationTopics: [
            "availability", "pointerProjection",
        ])
        let observations = LockedRuntimeObservationStore()
        subscriber.setRuntimeObservationHandler { observations.append($0) }
        let origin = try client.openLiveSession(
            canonicalUDID: target,
            activation: .existingOnly
        )
        let interactionID = CanonicalUUID(value: UUID())
        _ = try origin.submit(
            commandID: "touch.swipe",
            actionID: interactionID
        )
        try waitForCondition { observations.values.count == 3 }
        XCTAssertEqual(
            observations.values.map(\.presentationPayload.frameKind),
            [.begin, .move, .end]
        )
        XCTAssertEqual(
            observations.values.map(\.observationSequence),
            [0, 1, 2]
        )
    XCTAssertTrue(
      observations.values.allSatisfy {
            $0.clientInstanceID == origin.clientInstanceID
                && $0.interactionID == interactionID
                && $0.subscriptionID == attachment.subscriptionID
        })
        try origin.close()
        XCTAssertTrue(try subscriber.detach().detached)
        try subscriber.close()
        XCTAssertEqual(server.observationSubscriberCountForTesting, 0)
        XCTAssertNil(errors.error)
    }

    func testLiveSessionSurvivesUSBReconnectWithSameOwnerAndSubscription() throws {
        let target = try CanonicalUDID(
            canonicalString: "M2031-USB-RECONNECT-\(UUID().uuidString)"
        )
        let discovery = LockedDeviceDiscoveryState(
            device: Self.deviceObservation(target: target)
        )
        let coordinator = ProductionRuntimeDeviceCoordinator(
            canonicalUDID: target,
            catalog: try ExecutionProfileCatalog.load(repositoryRoot: repositoryRoot()),
            discovery: { try discovery.discover() }
        )
        let captureReadyCalls = LockedCallCounter()
        let backend = ProductionRuntimeOperationBackend(
            deviceCoordinator: coordinator,
            captureReadyHandler: { connectionEpoch, _ in
                captureReadyCalls.increment()
        return .succeeded(
          value: try Self.object([
                    ("captureProvenance", .string("postCapture")),
                    ("connectionEpoch", .number(.uint64(connectionEpoch))),
                    ("disposition", .string("ready")),
                ]))
            },
            handler: { request in
                guard request.operation == .runtimeGetAvailabilitySnapshot else {
                    return .failed(code: "invalidArgument")
                }
                return .succeeded(value: try coordinator.availabilityValue())
            }
        )
        let monitor = FakeUSBDeviceMonitor()
        let catalogHash = String(repeating: "b", count: 64)
        let server = try ProductionRuntimeServer.testing(
            canonicalUDID: target,
            developerImageCatalogRevision: "catalog.test",
            developerImageCatalogHash: catalogHash,
            runtimeEpoch: 35,
            operationBackend: backend
        )
        server.installUSBMonitorForTesting(monitor)
        let stopped = expectation(description: "runtime stopped")
        let errors = LockedErrorStore()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { stopped.fulfill() }
      do { try server.run() } catch { errors.store(error) }
        }
        defer {
            server.requestStop()
            wait(for: [stopped], timeout: 3)
        }
        try waitForNode(try RuntimeSocketPath.current(for: target).path)
        let client = try RuntimeClient.testing(
            canonicalAppPath: CanonicalAppPath(
                canonicalBundlePath: "/Applications/PulsePhone.app"
            ),
            developerImageCatalogRevision: "catalog.test",
            developerImageCatalogHash: catalogHash
        )
        let live = try client.openLiveSession(
            canonicalUDID: target,
            activation: .existingOnly
        )
        let initial = try live.attach(observationTopics: [
            "availability", "pointerProjection",
        ])
        XCTAssertEqual(server.observationSubscriberCountForTesting, 1)
        let eventKinds = LockedStringStore()
        let resetCount = LockedCallCounter()
        live.setRuntimeEventHandler { event in
            if let kind = event["eventKind"]?.stringValue {
                eventKinds.append(kind)
            }
        }
        live.setObservationResetHandler { reset in
            if reset.reason == "projectionInvalidated" {
                resetCount.increment()
            }
        }
        let activation = CanonicalUUID(value: UUID())
        _ = try live.markLiveCaptureReady(captureActivationID: activation)

        monitor.emit(.detached)
        usleep(400_000)
        XCTAssertEqual(live.currentAttachment, initial)
        XCTAssertFalse(eventKinds.values.contains("deviceDisconnected"))
        XCTAssertEqual(resetCount.value, 0)

        discovery.device = nil
        monitor.emit(.detached)
        try waitForCondition {
            live.currentAttachment == nil
                && eventKinds.values.contains("deviceDisconnected")
                && resetCount.value == 1
        }
        XCTAssertTrue(coordinator.hasPersistentLiveDemand)

        discovery.device = Self.deviceObservation(target: target)
        try waitForCondition {
            live.currentAttachment?.connectionEpoch == 2
        }
        let replacement = try XCTUnwrap(live.currentAttachment)
        XCTAssertEqual(replacement.liveOwnerID, initial.liveOwnerID)
        XCTAssertEqual(replacement.subscriptionID, initial.subscriptionID)
        XCTAssertGreaterThan(replacement.stateRevision, initial.stateRevision)
        XCTAssertTrue(eventKinds.values.contains("availabilityInvalidated"))

        let disconnectedEventCount = eventKinds.values.filter {
            $0 == "deviceDisconnected"
        }.count

        discovery.device = nil
        monitor.emit(.detached)
        usleep(200_000)
        discovery.device = Self.deviceObservation(target: target)
        monitor.emit(.attached(rawTransportUDID: target.rawValue))
        usleep(400_000)
        XCTAssertEqual(live.currentAttachment?.connectionEpoch, 2)
        XCTAssertEqual(
            eventKinds.values.filter { $0 == "deviceDisconnected" }.count,
            disconnectedEventCount
        )
        XCTAssertEqual(resetCount.value, 1)

        discovery.failNextDiscovery()
        monitor.emit(.resynchronize)
        discovery.device = nil
        usleep(2_200_000)
        XCTAssertEqual(live.currentAttachment?.connectionEpoch, 2)
        XCTAssertEqual(
            eventKinds.values.filter { $0 == "deviceDisconnected" }.count,
            disconnectedEventCount
        )

        discovery.device = Self.deviceObservation(target: target)
        usleep(1_200_000)
        XCTAssertEqual(live.currentAttachment?.connectionEpoch, 2)
        XCTAssertEqual(
            eventKinds.values.filter { $0 == "deviceDisconnected" }.count,
            disconnectedEventCount
        )
        XCTAssertEqual(resetCount.value, 1)

        monitor.emit(.attached(rawTransportUDID: target.rawValue))
        usleep(100_000)
        XCTAssertEqual(live.currentAttachment?.connectionEpoch, 2)
        _ = try live.markLiveCaptureReady(captureActivationID: activation)
        XCTAssertEqual(captureReadyCalls.value, 2)

        discovery.device = nil
        monitor.emit(.resynchronize)
        try waitForCondition {
            live.currentAttachment == nil
                && eventKinds.values.filter { $0 == "deviceDisconnected" }.count
                    == disconnectedEventCount + 1
                && resetCount.value == 2
        }
        XCTAssertNil(live.currentAttachment)
        XCTAssertEqual(
            eventKinds.values.filter { $0 == "deviceDisconnected" }.count,
            disconnectedEventCount + 1
        )
        XCTAssertEqual(resetCount.value, 2)

        discovery.device = Self.deviceObservation(target: target)
        try waitForCondition {
            live.currentAttachment?.connectionEpoch == 3
        }
        let secondReplacement = try XCTUnwrap(live.currentAttachment)
        XCTAssertEqual(secondReplacement.liveOwnerID, initial.liveOwnerID)
        XCTAssertEqual(secondReplacement.subscriptionID, initial.subscriptionID)
        _ = try live.markLiveCaptureReady(captureActivationID: activation)
        XCTAssertEqual(captureReadyCalls.value, 3)
        XCTAssertTrue(try live.detach().detached)
        XCTAssertEqual(server.observationSubscriberCountForTesting, 0)
        try live.close()
        XCTAssertNil(errors.error)
    }

    func testFrozenProductionIdentityMatchesCurrentRepositoryProjection() throws {
        let root = repositoryRoot()
    let identityBytes = [UInt8](
      try Data(
        contentsOf: root.appendingPathComponent(
            "Fixtures/developer-support/routing/current-contract-identity.v1.json"
        )))
        let identity = try RepositoryCanonicalJSON.parseDocument(
            identityBytes,
            maximumByteCount: 64 * 1_024
        )
        XCTAssertEqual(
            identity["executionCatalogHash"]?.stringValue,
            ProductionRuntimeContractIdentity.executionCatalogHash
        )
        XCTAssertEqual(
            ProductionRuntimeServer.executionCatalogHash,
            ProductionRuntimeContractIdentity.executionCatalogHash
        )
        XCTAssertEqual(
            ProductionRuntimeServer.runtimeCompatibilityID,
            ProductionRuntimeContractIdentity.runtimeCompatibilityID
        )
    XCTAssertNoThrow(
      try ProductionRuntimeContractIdentity.load(
            resourcesURL: root
        ))
    }

    func testProductionOperationAssemblyIsExhaustiveWithoutGenericFallback() throws {
        let serverCore: Set<RuntimeOperationID> = [
            .runtimeAttachLive,
            .runtimeDetachLive,
            .runtimeHealth,
            .runtimeMarkLiveCaptureReady,
            .runtimeRecordLocalAction,
            .runtimeRuntimeStatus,
            .runtimeStopIfIdle,
        ]
        XCTAssertEqual(
            serverCore.union(ProductionRuntimeOperationBackend.routedOperations),
            Set(RuntimeOperationID.allCases)
        )
    let source = try String(
      decoding: Data(
        contentsOf: repositoryRoot()
            .appendingPathComponent(
                "Sources/PulsePhoneRuntimeExecutable/ProductionRuntimeServer.swift"
            )), as: UTF8.self)
        XCTAssertFalse(source.contains("failed(code: \"runtimeFailed\")"))
    }

    private func waitForNode(_ path: String) throws {
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: path) { return }
            usleep(10_000)
        }
        throw POSIXError(.ETIMEDOUT)
    }

    private func waitForCondition(
        _ condition: () -> Bool
    ) throws {
        for _ in 0..<300 {
            if condition() { return }
            usleep(10_000)
        }
        throw POSIXError(.ETIMEDOUT)
    }

    private static func deviceObservation(
        target: CanonicalUDID,
        buildVersion: String = "23F84",
        productVersion: String = "26.5.2"
    ) -> ProductionRuntimeDeviceObservation {
        ProductionRuntimeDeviceObservation(
            rawTransportUDID: target.rawValue,
            facts: ProductionRuntimeDeviceFacts(
                buildVersion: buildVersion,
                deviceClass: "iPhone",
                deviceName: "Test iPhone",
                productType: "iPhone14,7",
                productVersion: productVersion,
                uniqueDeviceID: target.rawValue
            ),
            condition: ProductionRuntimeDeviceCondition(
                connected: true,
                locked: false,
                trusted: true
            )
        )
    }

    private static func dynamicClassicCatalogData() throws -> Data {
        let prefix = "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/archives/"
        let object: [String: Any] = [
            "baseAssets": [[
                "archiveSHA256": String(repeating: "a", count: 64),
                "archiveSize": 10,
                "baseAssetID": "base.test",
                "contentManifestSHA256": String(repeating: "b", count: 64),
                "sourceURL": prefix + "baseAssets/base.test.tar",
            ]],
            "catalogEntry": [[
                "baseAssetID": "base.test",
                "buildID": "18D70",
                "iosVersion": "14.4.2",
            ]],
            "catalogRevision": "2026-08-22.1",
            "defaultCandidateBaseAssetID": "base.test",
            "developerDiskImages": [[
                "archiveSHA256": String(repeating: "c", count: 64),
                "archiveSize": 10,
                "contentManifestSHA256": String(repeating: "d", count: 64),
                "ddiVersion": "14.4",
                "sourceURL": prefix + "DDI/14.4-test.tar",
            ]],
            "schemaVersion": 1,
        ]
        return try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
    }

    private func assertExecutorFault(
        route: String,
        expectedError: ProductionCoreDeviceHelperExecutorError,
        expectedOperation: ProductionCoreDeviceHelperOperationStage,
        expectedStage: ProductionCoreDeviceHelperFailureStage,
        operation: (CoreDeviceExecutorTestContext, String) throws -> Void
    ) throws {
        let context = try CoreDeviceExecutorTestContext(
            frameAcknowledgementTimeoutMilliseconds: 100
        )
        defer { context.cleanup() }
        XCTAssertThrowsError(try operation(context, route)) {
            XCTAssertEqual(
                $0 as? ProductionCoreDeviceHelperExecutorError,
                expectedError
            )
        }
        let snapshot = context.executor.diagnosticSnapshot()
        XCTAssertNil(snapshot.activeExecutorGeneration)
        XCTAssertEqual(snapshot.activeStreamCount, 0)
        XCTAssertEqual(snapshot.lastFailureOperation, expectedOperation)
        XCTAssertEqual(snapshot.lastFailureStage, expectedStage)
        XCTAssertTrue(try context.manifest().helpers.isEmpty)
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func buildTestOnlyGoHelper(
        repositoryRoot: URL,
        outputRoot: URL,
        command: String
    ) throws -> URL {
        let output = outputRoot.appendingPathComponent(command)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "go", "build", "-trimpath", "-buildvcs=true", "-o", output.path,
            "./cmd/\(command)",
        ]
        process.currentDirectoryURL = repositoryRoot.appendingPathComponent("GoHelpers")
        var environment = ProcessInfo.processInfo.environment
        environment["CGO_ENABLED"] = "0"
        environment["GOENV"] = "off"
        environment["GOFLAGS"] = "-mod=vendor"
        environment["GOTOOLCHAIN"] = "local"
        environment["GOWORK"] = "off"
        environment["GOARCH"] = "arm64"
        environment["GOOS"] = "darwin"
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              FileManager.default.isExecutableFile(atPath: output.path)
        else {
            throw POSIXError(.ENOENT)
        }
        return output
    }

    private func spawnRuntime(
        target: CanonicalUDID
    ) throws -> (pid: pid_t, reader: Int32) {
        let executable = repositoryRoot()
            .appendingPathComponent(".build/debug/PulsePhoneRuntime").path
        guard FileManager.default.isExecutableFile(atPath: executable) else {
            throw POSIXError(.ENOENT)
        }
        var descriptors = [Int32](repeating: -1, count: 2)
        guard Darwin.pipe(&descriptors) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        let reader = descriptors[0]
        let writer = descriptors[1]
        var actions: posix_spawn_file_actions_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else {
            _ = Darwin.close(reader)
            _ = Darwin.close(writer)
            throw POSIXError(.EIO)
        }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawn_file_actions_addclose(&actions, reader) == 0,
              posix_spawn_file_actions_adddup2(&actions, writer, 3) == 0,
              writer == 3
                || posix_spawn_file_actions_addclose(&actions, writer) == 0
        else {
            _ = Darwin.close(reader)
            _ = Darwin.close(writer)
            throw POSIXError(.EIO)
        }
        let rawArguments = [
            executable, "--canonical-udid", target.rawValue,
        ]
        var arguments = rawArguments.map { strdup($0) } + [nil]
        defer { arguments.compactMap { $0 }.forEach { free($0) } }
        var pid: pid_t = 0
        let result = executable.withCString { path in
            arguments.withUnsafeMutableBufferPointer { buffer in
                posix_spawn(
                    &pid,
                    path,
                    &actions,
                    nil,
                    buffer.baseAddress!,
                    environ
                )
            }
        }
        _ = Darwin.close(writer)
        guard result == 0, pid > 0 else {
            _ = Darwin.close(reader)
            throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO)
        }
        return (pid, reader)
    }

    private func waitForReadable(
        _ descriptor: Int32,
        timeoutMilliseconds: Int32
    ) throws {
        var pollDescriptor = pollfd(
            fd: descriptor,
            events: Int16(POLLIN),
            revents: 0
        )
        let result = Darwin.poll(&pollDescriptor, 1, timeoutMilliseconds)
        guard result == 1,
              pollDescriptor.revents & Int16(POLLIN | POLLHUP) != 0
        else {
      throw POSIXError(
        result == 0
                ? .ETIMEDOUT
                : POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func readToEOF(_ descriptor: Int32) throws -> [UInt8] {
        var output = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 256)
        while true {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count > 0 {
                output.append(contentsOf: buffer.prefix(count))
            } else if count == 0 {
                return output
            } else if errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }
    }

    private func waitForExit(
        _ pid: pid_t,
        timeoutMilliseconds: Int
    ) throws {
        for _ in 0..<(timeoutMilliseconds / 10) {
            var status: Int32 = 0
            let result = Darwin.waitpid(pid, &status, WNOHANG)
            if result == pid { return }
            if result == -1, errno != EINTR {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
            usleep(10_000)
        }
        throw POSIXError(.ETIMEDOUT)
    }

    private func waitForProcessGone(
        _ pid: pid_t,
        timeoutMilliseconds: Int
    ) throws {
        for _ in 0..<(timeoutMilliseconds / 10) {
            if Darwin.kill(pid, 0) == -1 {
                if errno == ESRCH { return }
                if errno != EPERM {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
            usleep(10_000)
        }
        throw POSIXError(.ETIMEDOUT)
    }

    private func recordingRoot(_ suffix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-Recording-\(suffix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        return root
    }

    private func recordingLines(
        at path: String
    ) throws -> [RepositoryJSONObject] {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try data.split(separator: 0x0a).map { line in
            try RepositoryCanonicalJSON.parseDocument(
                [UInt8](line),
                maximumByteCount: 16 * 1_024
            )
        }
    }

    private func assertRecordingFileMode(_ path: String) throws {
        var status = stat()
        XCTAssertEqual(Darwin.lstat(path, &status), 0)
        XCTAssertEqual(status.st_mode & mode_t(S_IFMT), mode_t(S_IFREG))
        XCTAssertEqual(status.st_mode & mode_t(0o777), mode_t(0o600))
    }

    private static func object(
        _ members: [(String, RepositoryJSONValue)]
    ) throws -> RepositoryJSONObject {
    try RepositoryJSONObject(
      members: members.map {
            RepositoryJSONMember(key: $0.0, value: $0.1)
        })
    }

    private static func legacyDeveloperImageCatalog(
        buildVersion: String,
        image: Data,
        signature: Data
    ) throws -> DeveloperImageCatalogV1 {
        let extractedSize = image.count + signature.count
        let object: [String: Any] = [
            "catalogRevision": "legacy-preparation-test.v1",
      "entries": [
        [
                "archiveSHA256": StableBytes.sha256Hex(image + signature),
                "archiveSize": extractedSize,
                "buildID": buildVersion,
                "compatibilityRuleID":
                    "compat.preparation.legacy-developer.v2",
                "ddiVersion": "14.4",
                "deviceOSRange": [
                    "exactBuilds": [buildVersion],
                    "maximumMajorExclusive": 17,
                    "minimumMajor": 14,
                ],
                "entryID": "legacy.18d70",
                "evidenceState": "verified",
                "extractedUpperBound": extractedSize,
          "files": [
            [
                    "archiveRelativePath": "DeveloperDiskImage.dmg",
                    "fileRole": "classic.image",
                    "sha256": StableBytes.sha256Hex(image),
                    "size": image.count,
            ],
            [
                    "archiveRelativePath":
                        "DeveloperDiskImage.dmg.signature",
                    "fileRole": "classic.signature",
                    "sha256": StableBytes.sha256Hex(signature),
                    "size": signature.count,
            ],
          ],
                "imageKind": "classic",
                "requiredServices": ["com.apple.mobile.screenshotr"],
                "sourceURLs": [
            "https://approved.example.invalid/developer-image.zip"
          ],
        ]
                ],
            "schemaVersion": 1,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return try DeveloperImageCatalog.decodeCanonical([UInt8](data))
    }

    private static func personalizedDeveloperImageCatalog(
        buildVersion: String
    ) throws -> DeveloperImageCatalogV1 {
        let buildManifest = Data("personalized-build-manifest".utf8)
        let image = Data("personalized-developer-image".utf8)
        let trustCache = Data("personalized-trust-cache".utf8)
        let extractedSize = buildManifest.count + image.count + trustCache.count
        let object: [String: Any] = [
            "catalogRevision": "personalized-preparation-test.v1",
      "entries": [
        [
                "archiveSHA256": StableBytes.sha256Hex(
                    buildManifest + image + trustCache
                ),
                "archiveSize": extractedSize,
                "buildID": buildVersion,
                "compatibilityRuleID": "compat.preparation.coredevice.v2",
                "ddiVersion": "17.0",
                "deviceOSRange": [
                    "exactBuilds": [buildVersion],
                    "minimumMajor": 17,
                ],
                "entryID": "personalized.\(buildVersion)",
                "evidenceState": "verified",
                "extractedUpperBound": extractedSize,
          "files": [
            [
                    "archiveRelativePath": "BuildManifest.plist",
                    "fileRole": "personalized.buildManifest",
                    "sha256": StableBytes.sha256Hex(buildManifest),
                    "size": buildManifest.count,
            ],
            [
                    "archiveRelativePath": "DeveloperDiskImage.dmg",
                    "fileRole": "personalized.image",
                    "sha256": StableBytes.sha256Hex(image),
                    "size": image.count,
            ],
            [
                    "archiveRelativePath": "DeveloperDiskImage.dmg.trustcache",
                    "fileRole": "personalized.trustCache",
                    "sha256": StableBytes.sha256Hex(trustCache),
                    "size": trustCache.count,
            ],
          ],
                "imageKind": "personalized",
                "requiredServices": ["com.apple.coredevice.appservice"],
                "sourceURLs": [
            "https://approved.example.invalid/developer-image.tar"
          ],
        ]
                ],
            "schemaVersion": 1,
        ]
        let data = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return try DeveloperImageCatalog.decodeCanonical([UInt8](data))
    }

    private static func remotePersonalizedCatalogFixture(
        buildVersion: String
    ) throws -> RemotePersonalizedCatalogFixture {
        let files = [
            ("BuildManifest.plist", Data("remote-build-manifest".utf8)),
            ("Image.dmg", Data("remote-image".utf8)),
            ("Image.dmg.trustcache", Data("remote-trust-cache".utf8)),
        ]
        let archive = runtimeTestUSTAR(files)
    let catalogURL = URL(
      string:
            "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/runtime-test-catalog.json"
        )!
    let archiveURL = URL(
      string:
            "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/archives/runtime-test.tar"
        )!
        let fileObjects: [[String: Any]] = [
            ("BuildManifest.plist", "personalized.buildManifest"),
            ("Image.dmg", "personalized.image"),
            ("Image.dmg.trustcache", "personalized.trustCache"),
        ].map { path, role in
            let bytes = files.first(where: { $0.0 == path })!.1
            return [
                "archiveRelativePath": path,
                "fileRole": role,
                "sha256": StableBytes.sha256Hex(bytes),
                "size": bytes.count,
            ]
        }
        let object: [String: Any] = [
            "catalogRevision": "mengkaka-release-runtime-test.1",
      "entries": [
        [
                "archiveSHA256": StableBytes.sha256Hex(archive),
                "archiveSize": archive.count,
                "buildID": buildVersion,
                "compatibilityRuleID": "compat.preparation.coredevice.v2",
                "ddiVersion": "27A5218g",
                "deviceOSRange": [
                    "exactBuilds": [buildVersion],
                    "maximumMajorExclusive": 27,
                    "minimumMajor": 26,
                ],
                "entryID": "personalized.ios26.23F1",
                "evidenceState": "target",
                "extractedUpperBound": files.reduce(0) { $0 + $1.1.count },
                "files": fileObjects,
                "imageKind": "personalized",
                "requiredServices": [
                    "com.apple.coredevice.appservice",
                    "com.apple.coredevice.screencaptureservice",
                ],
                "sourceURLs": [archiveURL.absoluteString],
        ]
      ],
            "schemaVersion": 1,
        ]
        let catalogBytes = try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        let catalog = try DeveloperImageCatalog.decodeCanonical([UInt8](catalogBytes))
        return RemotePersonalizedCatalogFixture(
            archiveBytes: archive,
            archiveURL: archiveURL,
            catalog: catalog,
            catalogBytes: Data(try DeveloperImageCatalog.canonicalBytes(catalog)),
            catalogURL: catalogURL,
            configuration: ControlledRemoteDeveloperImageCatalogConfiguration(
                catalogURL: catalogURL.absoluteString,
                catalogRevisionPrefix: "mengkaka-release-",
                archiveURLPrefix:
                    "https://raw.githubusercontent.com/mengkaka/DeveloperDiskImage/release/PulsePhone/archives/"
            )
        )
    }

    private static func runtimeTestUSTAR(_ files: [(String, Data)]) -> Data {
        var archive = Data()
        for (name, bytes) in files {
            var header = [UInt8](repeating: 0, count: 512)
            header.replaceSubrange(0..<name.utf8.count, with: name.utf8)
            writeRuntimeTestOctal(0o644, to: &header, range: 100..<108)
            writeRuntimeTestOctal(0, to: &header, range: 108..<116)
            writeRuntimeTestOctal(0, to: &header, range: 116..<124)
            writeRuntimeTestOctal(UInt64(bytes.count), to: &header, range: 124..<136)
            writeRuntimeTestOctal(0, to: &header, range: 136..<148)
            header.replaceSubrange(148..<156, with: [UInt8](repeating: 32, count: 8))
            header.replaceSubrange(257..<263, with: Array("ustar\0".utf8))
            header.replaceSubrange(263..<265, with: Array("00".utf8))
            writeRuntimeTestOctal(
                header.reduce(UInt64(0)) { $0 + UInt64($1) },
                to: &header,
                range: 148..<156
            )
            archive.append(contentsOf: header)
            archive.append(bytes)
            archive.append(Data(repeating: 0, count: (512 - bytes.count % 512) % 512))
        }
        archive.append(Data(repeating: 0, count: 1_024))
        return archive
    }

    private static func writeRuntimeTestOctal(
        _ value: UInt64,
        to header: inout [UInt8],
        range: Range<Int>
    ) {
        let digits = Array(String(value, radix: 8).utf8)
        header.replaceSubrange(
            range,
            with: [UInt8](repeating: 48, count: range.count - digits.count - 1)
                + digits + [0]
        )
    }

    private static func makeUnlinkedReadOnlyFile(bytes: [UInt8]) throws -> Int32 {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("pulsephone-artifact-\(UUID().uuidString)").path
        let writer = Darwin.open(
            path,
            O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC,
            mode_t(0o600)
        )
        guard writer >= 0 else { throw POSIXError(.EIO) }
        do {
            var offset = 0
            while offset < bytes.count {
                let count = bytes.withUnsafeBytes { buffer in
                    Darwin.write(
                        writer,
                        buffer.baseAddress!.advanced(by: offset),
                        bytes.count - offset
                    )
                }
                guard count > 0 else { throw POSIXError(.EIO) }
                offset += count
            }
            guard fsync(writer) == 0 else { throw POSIXError(.EIO) }
        } catch {
            _ = Darwin.close(writer)
            _ = unlink(path)
            throw error
        }
        _ = Darwin.close(writer)
        let reader = Darwin.open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard reader >= 0, unlink(path) == 0 else {
            if reader >= 0 { _ = Darwin.close(reader) }
            _ = unlink(path)
            throw POSIXError(.EIO)
        }
        return reader
    }
}

private final class RecordingWriteGate: @unchecked Sendable {
    private let lock = NSLock()
    private var traceFinalizeFailuresRemaining = 0
    private var traceRecordFailuresRemaining = 0

    func failNextTraceRecord() {
        lock.withLock { traceRecordFailuresRemaining += 1 }
    }

    func failNextTraceFinalize() {
        lock.withLock { traceFinalizeFailuresRemaining += 1 }
    }

    func allows(
        kind: ProductionRuntimeRecordingKind,
        stage: ProductionRuntimeRecordingWriteStage
    ) -> Bool {
        lock.withLock {
            guard kind == .trace else { return true }
            if stage == .record, traceRecordFailuresRemaining > 0 {
                traceRecordFailuresRemaining -= 1
                return false
            }
            if stage == .finalize, traceFinalizeFailuresRemaining > 0 {
                traceFinalizeFailuresRemaining -= 1
                return false
            }
            return true
        }
    }
}

private struct RemotePersonalizedCatalogFixture: Sendable {
    let archiveBytes: Data
    let archiveURL: URL
    let catalog: DeveloperImageCatalogV1
    let catalogBytes: Data
    let catalogURL: URL
    let configuration: ControlledRemoteDeveloperImageCatalogConfiguration
}

private enum RemoteCatalogFixtureError: Error {
    case unexpectedURL
}

private final class CoreDeviceExecutorTestContext: @unchecked Sendable {
    private enum TestError: Error {
        case compileFailed
        case invalidRuntimeIdentity
        case timeout
    }

    let device: ProductionRuntimeDeviceObservation
    let directExecutor: ProductionCoreDeviceHelperExecutor
    let executor: ProductionCoreDeviceHelperExecutor

    private let directImplementationURL: URL
    private let implementationURL: URL
    private let manifestStore: HelperManifestStore
    private let root: URL
    private let sourceURL: URL
    private var runtimeLock: RuntimeLock?

    init(
        frameAcknowledgementTimeoutMilliseconds: Int32 = 500,
        inputTimeoutMilliseconds: Int32 = 5_000,
        helperHandshakeTimeoutMilliseconds: Int32 = 5_000,
        coreDeviceHelperLaunchOverride: TestOnlyHelperLaunchOverride? = nil,
        directHelperLaunchOverride: TestOnlyHelperLaunchOverride? = nil,
        device injectedDevice: ProductionRuntimeDeviceObservation? = nil
    ) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhone-CoreDeviceExecutor-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        let helpersDirectory = root.appendingPathComponent("Helpers", isDirectory: true)
        try FileManager.default.createDirectory(
            at: helpersDirectory,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700]
        )
        sourceURL = root.appendingPathComponent("fake_helper.c")
        implementationURL = helpersDirectory.appendingPathComponent(
            "PulsePhoneCoreDeviceHelper"
        )
        directImplementationURL = helpersDirectory.appendingPathComponent(
            "PulsePhoneDirectHelper"
        )

        if let injectedDevice {
            device = injectedDevice
        } else {
            let target = try CanonicalUDID(
                canonicalString: "M2031-EXECUTOR-\(UUID().uuidString)"
            )
            device = ProductionRuntimeDeviceObservation(
                rawTransportUDID: "test-raw-transport",
                facts: ProductionRuntimeDeviceFacts(
                    buildVersion: "23F1",
                    deviceClass: "iPhone",
                    deviceName: "Test iPhone",
                    productType: "iPhone15,2",
                    productVersion: "26.5.2",
                    uniqueDeviceID: target.rawValue
                ),
                condition: ProductionRuntimeDeviceCondition(
                    connected: true,
                    locked: false,
                    trusted: true
                )
            )
        }
        let target = try CanonicalUDID(canonicalString: device.facts.uniqueDeviceID)
        guard let runtimeExecutable = Bundle.main.executableURL?.path else {
            throw TestError.invalidRuntimeIdentity
        }
        let runtimeIdentity = try HelperProcessIdentity.capture(
            pid: getpid(),
            expectedExecutablePath: runtimeExecutable
        )
        runtimeLock = try RuntimeLock.acquireForRuntimeStartup(for: target)
        manifestStore = try HelperManifestStore(
            canonicalUDID: target,
            runtimeEpoch: 41,
            runtimePID: getpid(),
            runtimeProcessStartIdentity: runtimeIdentity.processStartIdentity,
            baseDirectoryPath: root.path
        )
        let supervisorRegistry = ProductionHelperSupervisorRegistry(runtimeEpoch: 41)
        executor = ProductionCoreDeviceHelperExecutor(
            runtimeEpoch: 41,
            resourcesURL: root,
            supervisorRegistry: supervisorRegistry,
            inputTimeoutMilliseconds: inputTimeoutMilliseconds,
            helperHandshakeTimeoutMilliseconds: helperHandshakeTimeoutMilliseconds,
            streamBarrierTimeoutMilliseconds: 2_000,
            frameAcknowledgementTimeoutMilliseconds:
                frameAcknowledgementTimeoutMilliseconds,
            testOnlyHelperLaunchOverride: coreDeviceHelperLaunchOverride
        )
        directExecutor = ProductionCoreDeviceHelperExecutor(
            runtimeEpoch: 41,
            resourcesURL: root,
            mode: .direct,
            supervisorRegistry: supervisorRegistry,
            inputTimeoutMilliseconds: inputTimeoutMilliseconds,
            helperHandshakeTimeoutMilliseconds: helperHandshakeTimeoutMilliseconds,
            streamBarrierTimeoutMilliseconds: 2_000,
            frameAcknowledgementTimeoutMilliseconds:
                frameAcknowledgementTimeoutMilliseconds,
            testOnlyHelperLaunchOverride: directHelperLaunchOverride
        )
        try compileHelper()
        executor.bind(
            runtimeLock: try requireRuntimeLock(),
            manifestStore: manifestStore
        )
        directExecutor.bind(
            runtimeLock: try requireRuntimeLock(),
            manifestStore: manifestStore
        )
    }

    func cleanup() {
        directExecutor.shutdown()
        executor.shutdown()
        let lockPath = runtimeLock?.path
        runtimeLock = nil
        if let lockPath { _ = unlink(lockPath) }
        try? FileManager.default.removeItem(at: root)
    }

    func openStream(
        route: String,
        connectionEpoch: UInt64
  ) throws -> (
    sessionID: CanonicalUUID, interactionID: CanonicalUUID,
    executorGeneration: UInt64
  ) {
        let interactionID = CanonicalUUID(value: UUID())
        let opened = try executor.openStream(
            requestID: CanonicalUUID(value: UUID()),
            actionID: CanonicalUUID(value: UUID()),
            interactionID: interactionID,
            parentActionID: nil,
            routeID: route,
            streamPayload: [:],
            device: device,
            connectionEpoch: connectionEpoch
        )
        return (opened.sessionID, interactionID, opened.executorGeneration)
    }

    func sendFrame(
    _ stream: (
      sessionID: CanonicalUUID, interactionID: CanonicalUUID,
      executorGeneration: UInt64
    ),
        sequence: UInt64
    ) throws {
    _ = try executor.sendStreamFrame(
      RuntimeStreamFrameEnvelope(
            sessionID: stream.sessionID,
            interactionID: stream.interactionID,
            sequence: sequence,
            frameKind: "begin",
            payload: try RepositoryJSONObject(members: [
                RepositoryJSONMember(key: "x", value: .string("0.5")),
                RepositoryJSONMember(key: "y", value: .string("0.5")),
            ]),
            clientSubmittedMonotonicNanoseconds: 1
        ))
    }

    func closeStream(
    _ stream: (
      sessionID: CanonicalUUID, interactionID: CanonicalUUID,
      executorGeneration: UInt64
    )
    ) throws {
        _ = try executor.closeStream(
            sessionID: stream.sessionID,
            interactionID: stream.interactionID,
            reason: "completed",
            cancel: false
        )
    }

    func manifest() throws -> HelperStateManifest {
        try manifestStore.load()
    }

    func waitForBlockedOneShot() throws {
        try waitForNode(controlURL(suffix: "started").path)
    }

    func waitForBlockedDirectOneShot() throws {
        try waitForNode(directControlURL(suffix: "started").path)
    }

    func completionBarrierObserved() -> Bool {
        FileManager.default.fileExists(
            atPath: controlURL(suffix: "barrier").path
        )
    }

    func dropCompletionBarrier() {
        FileManager.default.createFile(
            atPath: controlURL(suffix: "dropBarrier").path,
            contents: Data()
        )
    }

    func allowCompletionBarrier() {
        try? FileManager.default.removeItem(
            at: controlURL(suffix: "dropBarrier")
        )
    }

    func blockWarmGeneration() {
        FileManager.default.createFile(
            atPath: controlURL(suffix: "blockWarm").path,
            contents: Data()
        )
    }

    func failWarmGeneration() {
        FileManager.default.createFile(
            atPath: controlURL(suffix: "failWarm").path,
            contents: Data()
        )
    }

    func allowWarmGeneration() {
        try? FileManager.default.removeItem(at: controlURL(suffix: "failWarm"))
    }

    func setModernDeveloperSupportMounted(_ mounted: Bool) {
        let control = controlURL(suffix: "modernUnmounted")
        if mounted {
            try? FileManager.default.removeItem(at: control)
        } else {
            FileManager.default.createFile(atPath: control.path, contents: Data())
        }
    }

    func setLegacyDeveloperSupportMounted(_ mounted: Bool) {
        let control = directControlURL(suffix: "legacyMounted")
        if mounted {
            FileManager.default.createFile(atPath: control.path, contents: Data())
        } else {
            try? FileManager.default.removeItem(at: control)
        }
    }

    func warmGenerationObserved() -> Bool {
        FileManager.default.fileExists(
            atPath: controlURL(suffix: "warmObserved").path
        )
    }

    func waitForWarmGeneration() throws {
        try waitForNode(controlURL(suffix: "warmObserved").path)
    }

    func buttonHomeObserved() -> Bool {
        FileManager.default.fileExists(
            atPath: controlURL(suffix: "buttonHomeObserved").path
        )
    }

    func enableCoreDeviceScreenshotFallback() {
        FileManager.default.createFile(
            atPath: controlURL(suffix: "coreDeviceFallback").path,
            contents: Data()
        )
    }

    func enableAXAuditScreenshotFallback() {
        FileManager.default.createFile(
            atPath: controlURL(suffix: "axAuditFallback").path,
            contents: Data()
        )
    }

    func releaseBlockedOneShot() {
        FileManager.default.createFile(
            atPath: controlURL(suffix: "release").path,
            contents: Data()
        )
    }

    func releaseBlockedDirectOneShot() {
        FileManager.default.createFile(
            atPath: directControlURL(suffix: "release").path,
            contents: Data()
        )
    }

    func disableHelperExecutable() throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: helperExecutableURL.path
        )
    }

    func removeDirectImplementation() throws {
        try FileManager.default.removeItem(at: directImplementationURL)
    }

    func compileHelper() throws {
        if !FileManager.default.fileExists(atPath: sourceURL.path) {
            try Self.helperSource.write(
                to: sourceURL,
                atomically: true,
                encoding: .utf8
            )
        }
        let clang = try Self.runAndRead(
            executablePath: "/usr/bin/xcrun",
            arguments: ["--find", "clang"]
        )
        try Self.run(
            executablePath: clang,
            arguments: [sourceURL.path, "-o", implementationURL.path]
        )
        try Self.run(
            executablePath: clang,
            arguments: [sourceURL.path, "-o", directImplementationURL.path]
        )
    }

    private var helperExecutableURL: URL {
        implementationURL
    }

    private func controlURL(suffix: String) -> URL {
        URL(fileURLWithPath: implementationURL.path + "." + suffix)
    }

    private func directControlURL(suffix: String) -> URL {
        URL(fileURLWithPath: directImplementationURL.path + "." + suffix)
    }

    private func requireRuntimeLock() throws -> RuntimeLock {
        guard let runtimeLock else { throw TestError.invalidRuntimeIdentity }
        return runtimeLock
    }

    private func waitForNode(_ path: String) throws {
        // Keep the test observer aligned with the fake helper's 5 s
        // handshake/input budgets under a loaded full-suite process.
        for _ in 0..<2_500 {
            if FileManager.default.fileExists(atPath: path) { return }
            usleep(2_000)
        }
        throw TestError.timeout
    }

    private static func runAndRead(
        executablePath: String,
        arguments: [String]
    ) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TestError.compileFailed }
        let value = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("/") else { throw TestError.compileFailed }
        return value
    }

    private static func run(
        executablePath: String,
        arguments: [String]
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executablePath)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw TestError.compileFailed }
    }

    private static let helperSource = #"""
    #include <fcntl.h>
    #include <libproc.h>
    #include <limits.h>
    #include <stdio.h>
    #include <stdlib.h>
    #include <string.h>
    #include <sys/proc_info.h>
    #include <unistd.h>

    static unsigned long long message_counter = 1;
    static unsigned long long runtime_epoch = 0;
    static unsigned long long executor_generation = 0;
    static char implementation_path[PATH_MAX];
    static char pending_phase[64];
    static int frame_timeout = 0;
    static int frame_exit = 0;
    static int cleanup_failure = 0;

    static const char *argument_value(int argc, char **argv, const char *name) {
      for (int index = 1; index + 1 < argc; index++) {
        if (strcmp(argv[index], name) == 0) return argv[index + 1];
      }
      return NULL;
    }

    static void next_message_id(char *output, size_t size) {
      snprintf(output, size, "00000000-0000-0000-0000-%012llx", message_counter++);
    }

    static int extract_string(
      const char *line, const char *key, char *output, size_t output_size
    ) {
      char pattern[128];
      snprintf(pattern, sizeof(pattern), "\"%s\"", key);
      const char *cursor = strstr(line, pattern);
      if (cursor == NULL) return 0;
      cursor = strchr(cursor + strlen(pattern), ':');
      if (cursor == NULL) return 0;
      cursor++;
      while (*cursor == ' ' || *cursor == '\t') cursor++;
      if (*cursor != '\"') return 0;
      cursor++;
      const char *end = strchr(cursor, '\"');
      if (end == NULL || (size_t)(end - cursor) >= output_size) return 0;
      memcpy(output, cursor, (size_t)(end - cursor));
      output[end - cursor] = '\0';
      return 1;
    }

    static unsigned long long extract_unsigned(const char *line, const char *key) {
      char pattern[128];
      snprintf(pattern, sizeof(pattern), "\"%s\"", key);
      const char *cursor = strstr(line, pattern);
      if (cursor == NULL) return 0;
      cursor = strchr(cursor + strlen(pattern), ':');
      if (cursor == NULL) return 0;
      return strtoull(cursor + 1, NULL, 10);
    }

    static void send_associated(const char *type, const char *request_id) {
      char message_id[64];
      next_message_id(message_id, sizeof(message_id));
      printf(
        "{\"executorGeneration\":%llu,\"messageID\":\"%s\","
        "\"requestID\":\"%s\",\"runtimeEpoch\":%llu,"
        "\"schemaVersion\":1,\"type\":\"%s\"}\n",
        executor_generation, message_id, request_id, runtime_epoch, type
      );
    }

    static void send_result(
      const char *request_id,
      const char *phase,
      const char *request_line
    ) {
      char message_id[64];
      char legacy_mounted[PATH_MAX];
      char modern_unmounted[PATH_MAX];
      next_message_id(message_id, sizeof(message_id));
      snprintf(
        legacy_mounted, sizeof(legacy_mounted), "%s.legacyMounted",
        implementation_path
      );
      snprintf(
        modern_unmounted, sizeof(modern_unmounted), "%s.modernUnmounted",
        implementation_path
      );
      if (phase != NULL && phase[0] != '\0') {
        printf(
          "{\"executorGeneration\":%llu,\"messageID\":\"%s\","
          "\"payload\":{\"fallbackDisposition\":\"terminal\","
          "\"result\":{\"commitState\":\"notCommitted\",\"error\":{"
          "\"code\":\"developerServicesUnavailable\",\"details\":{"
          "\"phase\":\"%s\"}},\"outcome\":\"failed\"}},"
          "\"requestID\":\"%s\",\"runtimeEpoch\":%llu,"
          "\"schemaVersion\":1,\"type\":\"Result\"}\n",
          executor_generation, message_id, phase, request_id, runtime_epoch
        );
      } else if (strstr(request_line, "coredevice.developerSupport.queryMounted") != NULL) {
        const char *mounted = access(modern_unmounted, F_OK) == 0 ? "false" : "true";
        const char *provenance = strstr(request_line, "\"catalogRevision\"") != NULL
          ? "approved"
          : "mountedUnknownUnverified";
        printf(
          "{\"executorGeneration\":%llu,\"messageID\":\"%s\","
          "\"payload\":{\"fallbackDisposition\":\"terminal\","
          "\"result\":{\"commitState\":\"notCommitted\","
          "\"outcome\":\"succeeded\",\"value\":{\"mounted\":%s,"
          "\"provenance\":\"%s\"}}},"
          "\"requestID\":\"%s\",\"runtimeEpoch\":%llu,"
          "\"schemaVersion\":1,\"type\":\"Result\"}\n",
          executor_generation, message_id, mounted, provenance, request_id, runtime_epoch
        );
      } else if (strstr(request_line, "coredevice.developerSupport.probeServices") != NULL) {
        printf(
          "{\"executorGeneration\":%llu,\"messageID\":\"%s\","
          "\"payload\":{\"fallbackDisposition\":\"terminal\","
          "\"result\":{\"commitState\":\"notCommitted\","
          "\"outcome\":\"succeeded\",\"value\":{\"mounted\":true,"
          "\"provenance\":\"approved\",\"servicesReady\":true}}},"
          "\"requestID\":\"%s\",\"runtimeEpoch\":%llu,"
          "\"schemaVersion\":1,\"type\":\"Result\"}\n",
          executor_generation, message_id, request_id, runtime_epoch
        );
      } else if (strstr(request_line, "coredevice.developerSupport.mount") != NULL) {
        printf(
          "{\"executorGeneration\":%llu,\"messageID\":\"%s\","
          "\"payload\":{\"fallbackDisposition\":\"terminal\","
          "\"result\":{\"commitState\":\"committed\","
          "\"outcome\":\"succeeded\",\"value\":{\"mounted\":true,"
          "\"mountCommitted\":true,\"provenance\":\"approved\"}}},"
          "\"requestID\":\"%s\",\"runtimeEpoch\":%llu,"
          "\"schemaVersion\":1,\"type\":\"Result\"}\n",
          executor_generation, message_id, request_id, runtime_epoch
        );
      } else if (strstr(request_line, "legacy.developerSupport.queryMounted") != NULL) {
        const char *mounted = access(legacy_mounted, F_OK) == 0 ? "true" : "false";
        printf(
          "{\"executorGeneration\":%llu,\"messageID\":\"%s\","
          "\"payload\":{\"fallbackDisposition\":\"terminal\","
          "\"result\":{\"commitState\":\"notCommitted\","
          "\"outcome\":\"succeeded\",\"value\":{\"mounted\":%s,"
          "\"provenance\":\"approved\"}}},"
          "\"requestID\":\"%s\",\"runtimeEpoch\":%llu,"
          "\"schemaVersion\":1,\"type\":\"Result\"}\n",
          executor_generation, message_id, mounted, request_id, runtime_epoch
        );
      } else if (strstr(request_line, "legacy.developerSupport.mount") != NULL) {
        int descriptor = open(legacy_mounted, O_CREAT | O_WRONLY, 0600);
        if (descriptor >= 0) close(descriptor);
        printf(
          "{\"executorGeneration\":%llu,\"messageID\":\"%s\","
          "\"payload\":{\"fallbackDisposition\":\"terminal\","
          "\"result\":{\"commitState\":\"committed\","
          "\"outcome\":\"succeeded\",\"value\":{\"mounted\":true,"
          "\"provenance\":\"approved\",\"servicesReady\":true}}},"
          "\"requestID\":\"%s\",\"runtimeEpoch\":%llu,"
          "\"schemaVersion\":1,\"type\":\"Result\"}\n",
          executor_generation, message_id, request_id, runtime_epoch
        );
      } else if (strstr(request_line, "legacy.developerSupport.probeServices") != NULL) {
        printf(
          "{\"executorGeneration\":%llu,\"messageID\":\"%s\","
          "\"payload\":{\"fallbackDisposition\":\"terminal\","
          "\"result\":{\"commitState\":\"notCommitted\","
          "\"outcome\":\"succeeded\",\"value\":{\"mounted\":true,"
          "\"provenance\":\"approved\",\"servicesReady\":true}}},"
          "\"requestID\":\"%s\",\"runtimeEpoch\":%llu,"
          "\"schemaVersion\":1,\"type\":\"Result\"}\n",
          executor_generation, message_id, request_id, runtime_epoch
        );
      } else if (strstr(request_line, "direct.installationProxy.uninstall") != NULL) {
        if (strstr(implementation_path, "PulsePhoneDirectHelper") != NULL &&
            strstr(request_line, "\"operation\":\"uninstall\"") != NULL &&
            strstr(request_line, "\"bundleID\":\"com.example.UninstallFixture\"") != NULL) {
          printf(
            "{\"executorGeneration\":%llu,\"messageID\":\"%s\","
            "\"payload\":{\"fallbackDisposition\":\"terminal\","
            "\"result\":{\"commitState\":\"committed\","
            "\"outcome\":\"succeeded\",\"value\":{"
            "\"bundleID\":\"com.example.UninstallFixture\","
            "\"disposition\":\"uninstalled\"}}},"
            "\"requestID\":\"%s\",\"runtimeEpoch\":%llu,"
            "\"schemaVersion\":1,\"type\":\"Result\"}\n",
            executor_generation, message_id, request_id, runtime_epoch
          );
        } else {
          printf(
            "{\"executorGeneration\":%llu,\"messageID\":\"%s\","
            "\"payload\":{\"fallbackDisposition\":\"terminal\","
            "\"result\":{\"commitState\":\"notCommitted\","
            "\"error\":{\"code\":\"uninstallFailed\",\"details\":{"
            "\"commitState\":\"notCommitted\","
            "\"stage\":\"wrongExecutorOrPayload\"}},"
            "\"outcome\":\"failed\"}},\"requestID\":\"%s\","
            "\"runtimeEpoch\":%llu,\"schemaVersion\":1,"
            "\"type\":\"Result\"}\n",
            executor_generation, message_id, request_id, runtime_epoch
          );
        }
      } else if (strstr(request_line, "legacy.dvtLaunch") != NULL) {
        if (strstr(implementation_path, "PulsePhoneDirectHelper") != NULL &&
            strstr(request_line, "\"operation\":\"launch\"") != NULL) {
          printf(
            "{\"executorGeneration\":%llu,\"messageID\":\"%s\","
            "\"payload\":{\"fallbackDisposition\":\"terminal\","
            "\"result\":{\"commitState\":\"committed\","
            "\"outcome\":\"succeeded\",\"value\":{"
            "\"bundleID\":\"com.example.LegacyApp\","
            "\"disposition\":\"launchRequested\","
            "\"resolvedRouteID\":\"legacy.dvtLaunch\"}}},"
            "\"requestID\":\"%s\",\"runtimeEpoch\":%llu,"
            "\"schemaVersion\":1,\"type\":\"Result\"}\n",
            executor_generation, message_id, request_id, runtime_epoch
          );
        } else {
          printf(
            "{\"executorGeneration\":%llu,\"messageID\":\"%s\","
            "\"payload\":{\"fallbackDisposition\":\"terminal\","
            "\"result\":{\"commitState\":\"notCommitted\","
            "\"error\":{\"code\":\"appLaunchFailed\",\"details\":{"
            "\"commitState\":\"notCommitted\","
            "\"stage\":\"wrongExecutorOrPayload\"}},"
            "\"outcome\":\"failed\"}},\"requestID\":\"%s\","
            "\"runtimeEpoch\":%llu,\"schemaVersion\":1,"
            "\"type\":\"Result\"}\n",
            executor_generation, message_id, request_id, runtime_epoch
          );
        }
      } else if (strstr(request_line, "coredevice.screenshot") != NULL) {
        char artifact_id[64], reservation_path[PATH_MAX];
        char axaudit_fallback[PATH_MAX], coredevice_fallback[PATH_MAX];
        snprintf(
          axaudit_fallback, sizeof(axaudit_fallback), "%s.axAuditFallback",
          implementation_path
        );
        snprintf(
          coredevice_fallback, sizeof(coredevice_fallback), "%s.coreDeviceFallback",
          implementation_path
        );
        if (!extract_string(
              request_line, "artifactID", artifact_id, sizeof(artifact_id)
            ) || !extract_string(
              request_line, "reservationPath", reservation_path,
              sizeof(reservation_path)
            )) return;
        if (strstr(request_line, "\"commandID\":\"element.snapshot\"") != NULL &&
            strstr(
              request_line,
              "\"captureProviderOrder\":[\"dvt\",\"coreDevice\",\"axAudit\"]"
            ) == NULL) return;
        const unsigned char png[] = {
          0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00,
          0x0d, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
          0x00, 0x01, 0x08, 0x04, 0x00, 0x00, 0x00, 0xb5, 0x1c, 0x0c, 0x02,
          0x00, 0x00, 0x00, 0x0b, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63,
          0x64, 0xf8, 0x0f, 0x00, 0x01, 0x05, 0x01, 0x01, 0x27, 0x18, 0xe3,
          0x66, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42,
          0x60, 0x82
        };
        int descriptor = open(
          reservation_path, O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW
        );
        if (descriptor < 0 || write(descriptor, png, sizeof(png)) != sizeof(png) ||
            fsync(descriptor) != 0 || close(descriptor) != 0) return;
        if (access(axaudit_fallback, F_OK) == 0) {
          printf(
            "{\"executorGeneration\":%llu,\"messageID\":\"%s\","
            "\"payload\":{\"fallbackDisposition\":\"terminal\","
            "\"result\":{\"commitState\":\"notCommitted\","
            "\"outcome\":\"succeeded\",\"value\":{"
            "\"_pulsephoneCaptureAttempts\":["
            "{\"errorCode\":\"developerServicesUnavailable\","
            "\"provider\":\"dvt\","
            "\"stage\":\"dvtScreenshotCaptureOrValidate\","
            "\"status\":\"failed\",\"timings\":{"
            "\"captureMicroseconds\":11,\"queueWaitMicroseconds\":2,"
            "\"serviceCloseMicroseconds\":3,\"serviceOpenMicroseconds\":5,"
            "\"totalMicroseconds\":19}},"
            "{\"errorCode\":\"developerServicesUnavailable\","
            "\"provider\":\"coreDevice\","
            "\"stage\":\"screenshotCaptureOrValidate\","
            "\"status\":\"failed\",\"timings\":{"
            "\"captureMicroseconds\":13,\"queueWaitMicroseconds\":2,"
            "\"serviceCloseMicroseconds\":4,\"serviceOpenMicroseconds\":7,"
            "\"totalMicroseconds\":23}},"
            "{\"errorCode\":null,\"provider\":\"axAudit\","
            "\"stage\":null,\"status\":\"succeeded\",\"timings\":{"
            "\"captureMicroseconds\":17,\"queueWaitMicroseconds\":2,"
            "\"serviceCloseMicroseconds\":0,\"serviceOpenMicroseconds\":9,"
            "\"totalMicroseconds\":29}}],\"artifactID\":\"%s\","
            "\"byteCount\":%zu,\"captureProvider\":\"axAudit\","
            "\"format\":\"png\","
            "\"generationDisposition\":\"retiringAfterResult\"}}},"
            "\"requestID\":\"%s\",\"runtimeEpoch\":%llu,"
            "\"schemaVersion\":1,\"type\":\"Result\"}\n",
            executor_generation, message_id, artifact_id, sizeof(png),
            request_id, runtime_epoch
          );
        } else if (access(coredevice_fallback, F_OK) == 0) {
          printf(
            "{\"executorGeneration\":%llu,\"messageID\":\"%s\","
            "\"payload\":{\"fallbackDisposition\":\"terminal\","
            "\"result\":{\"commitState\":\"notCommitted\","
            "\"outcome\":\"succeeded\",\"value\":{"
            "\"_pulsephoneCaptureAttempts\":["
            "{\"errorCode\":\"developerServicesUnavailable\","
            "\"provider\":\"dvt\","
            "\"stage\":\"dvtScreenshotCaptureOrValidate\","
            "\"status\":\"failed\",\"timings\":{"
            "\"captureMicroseconds\":11,\"queueWaitMicroseconds\":2,"
            "\"serviceCloseMicroseconds\":3,\"serviceOpenMicroseconds\":5,"
            "\"totalMicroseconds\":19}},"
            "{\"errorCode\":null,\"provider\":\"coreDevice\",\"stage\":null,"
            "\"status\":\"succeeded\",\"timings\":{"
            "\"captureMicroseconds\":13,\"queueWaitMicroseconds\":2,"
            "\"serviceCloseMicroseconds\":0,\"serviceOpenMicroseconds\":7,"
            "\"totalMicroseconds\":23}}],\"artifactID\":\"%s\","
            "\"byteCount\":%zu,\"captureProvider\":\"coreDevice\","
            "\"format\":\"png\","
            "\"generationDisposition\":\"retiringAfterResult\"}}},"
            "\"requestID\":\"%s\",\"runtimeEpoch\":%llu,"
            "\"schemaVersion\":1,\"type\":\"Result\"}\n",
            executor_generation, message_id, artifact_id, sizeof(png),
            request_id, runtime_epoch
          );
        } else {
          printf(
            "{\"executorGeneration\":%llu,\"messageID\":\"%s\","
            "\"payload\":{\"fallbackDisposition\":\"terminal\","
            "\"result\":{\"commitState\":\"notCommitted\","
            "\"outcome\":\"succeeded\",\"value\":{"
            "\"_pulsephoneCaptureAttempts\":["
            "{\"errorCode\":null,\"provider\":\"dvt\","
            "\"stage\":null,\"status\":\"succeeded\",\"timings\":{"
            "\"captureMicroseconds\":11,\"queueWaitMicroseconds\":2,"
            "\"serviceCloseMicroseconds\":0,\"serviceOpenMicroseconds\":5,"
            "\"totalMicroseconds\":19}}],\"artifactID\":\"%s\","
            "\"byteCount\":%zu,\"captureProvider\":\"dvt\","
            "\"format\":\"png\"}}},"
            "\"requestID\":\"%s\",\"runtimeEpoch\":%llu,"
            "\"schemaVersion\":1,\"type\":\"Result\"}\n",
            executor_generation, message_id, artifact_id, sizeof(png),
            request_id, runtime_epoch
          );
        }
      } else if (strstr(request_line, "legacy.screenshotr") != NULL) {
        if (strstr(request_line, "\"commandID\":\"screenshot.gui\"") != NULL) {
          printf(
            "{\"executorGeneration\":%llu,\"messageID\":\"%s\","
            "\"payload\":{\"fallbackDisposition\":\"terminal\","
            "\"result\":{\"commitState\":\"notCommitted\","
            "\"error\":{\"code\":\"developerServicesUnavailable\","
            "\"details\":{\"phase\":\"startingDeviceServices\","
            "\"preparationGroupID\":\"prep.legacy.developer.v2\"}},"
            "\"outcome\":\"failed\"}},\"requestID\":\"%s\","
            "\"runtimeEpoch\":%llu,\"schemaVersion\":1,"
            "\"type\":\"Result\"}\n",
            executor_generation, message_id, request_id, runtime_epoch
          );
        } else {
          char artifact_id[64], reservation_path[PATH_MAX];
          if (!extract_string(
                request_line, "artifactID", artifact_id, sizeof(artifact_id)
              ) || !extract_string(
                request_line, "reservationPath", reservation_path,
                sizeof(reservation_path)
              )) return;
          const unsigned char png[] = {
            0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4
          };
          int descriptor = open(
            reservation_path, O_WRONLY | O_TRUNC | O_CLOEXEC | O_NOFOLLOW
          );
          if (descriptor < 0 || write(descriptor, png, sizeof(png)) != sizeof(png) ||
              fsync(descriptor) != 0 || close(descriptor) != 0) return;
          printf(
            "{\"executorGeneration\":%llu,\"messageID\":\"%s\","
            "\"payload\":{\"fallbackDisposition\":\"terminal\","
            "\"result\":{\"commitState\":\"notCommitted\","
            "\"outcome\":\"succeeded\",\"value\":{\"artifactID\":\"%s\","
            "\"byteCount\":%zu,\"format\":\"png\"}}},"
            "\"requestID\":\"%s\",\"runtimeEpoch\":%llu,"
            "\"schemaVersion\":1,\"type\":\"Result\"}\n",
            executor_generation, message_id, artifact_id, sizeof(png),
            request_id, runtime_epoch
          );
        }
      } else if (strstr(request_line, "coredevice.warmGeneration") != NULL) {
        printf(
          "{\"executorGeneration\":%llu,\"messageID\":\"%s\","
          "\"payload\":{\"fallbackDisposition\":\"terminal\","
          "\"result\":{\"commitState\":\"committed\","
          "\"outcome\":\"succeeded\",\"value\":{\"disposition\":\"ready\","
          "\"executorGeneration\":%llu}}},"
          "\"requestID\":\"%s\",\"runtimeEpoch\":%llu,"
          "\"schemaVersion\":1,\"type\":\"Result\"}\n",
          executor_generation, message_id, executor_generation, request_id,
          runtime_epoch
        );
      } else if (strstr(request_line, "coredevice.displayGeometry.query") != NULL) {
        printf(
          "{\"executorGeneration\":%llu,\"messageID\":\"%s\","
          "\"payload\":{\"fallbackDisposition\":\"terminal\","
          "\"result\":{\"commitState\":\"notCommitted\","
          "\"outcome\":\"succeeded\",\"value\":{"
          "\"logicalHeight\":1170,\"logicalWidth\":2532,"
          "\"orientation\":\"landscapeRight\","
          "\"resolvedRouteID\":\"coredevice.displayGeometry.query\"}}},"
          "\"requestID\":\"%s\",\"runtimeEpoch\":%llu,"
          "\"schemaVersion\":1,\"type\":\"Result\"}\n",
          executor_generation, message_id, request_id, runtime_epoch
        );
      } else {
        printf(
          "{\"executorGeneration\":%llu,\"messageID\":\"%s\","
          "\"payload\":{\"fallbackDisposition\":\"terminal\","
          "\"result\":{\"commitState\":\"notCommitted\","
          "\"outcome\":\"succeeded\",\"value\":{}}},"
          "\"requestID\":\"%s\",\"runtimeEpoch\":%llu,"
          "\"schemaVersion\":1,\"type\":\"Result\"}\n",
          executor_generation, message_id, request_id, runtime_epoch
        );
      }
      fflush(stdout);
    }

    static void send_frame_accepted(const char *line) {
      char delivery[160], interaction[64], session[64], message_id[64];
      if (!extract_string(line, "deliveryAttemptID", delivery, sizeof(delivery)) ||
          !extract_string(line, "interactionID", interaction, sizeof(interaction)) ||
          !extract_string(line, "sessionID", session, sizeof(session))) return;
      unsigned long long sequence = extract_unsigned(line, "seq");
      next_message_id(message_id, sizeof(message_id));
      printf(
        "{\"deliveryAttemptID\":\"%s\",\"executorGeneration\":%llu,"
        "\"messageID\":\"%s\",\"payload\":{"
        "\"acceptedMonotonicNs\":1,\"interactionID\":\"%s\","
        "\"seq\":%llu},\"runtimeEpoch\":%llu,\"schemaVersion\":1,"
        "\"sessionID\":\"%s\",\"type\":\"FrameAccepted\"}\n",
        delivery, executor_generation, message_id, interaction, sequence,
        runtime_epoch, session
      );
      fflush(stdout);
    }

    static void wait_for_release(void) {
      char started[PATH_MAX], release[PATH_MAX];
      snprintf(started, sizeof(started), "%s.started", implementation_path);
      snprintf(release, sizeof(release), "%s.release", implementation_path);
      int descriptor = open(started, O_CREAT | O_WRONLY, 0600);
      if (descriptor >= 0) close(descriptor);
      while (access(release, F_OK) != 0) usleep(1000);
      unlink(started);
      unlink(release);
    }

    static void record_barrier(void) {
      char barrier[PATH_MAX];
      snprintf(barrier, sizeof(barrier), "%s.barrier", implementation_path);
      int descriptor = open(barrier, O_CREAT | O_WRONLY, 0600);
      if (descriptor >= 0) close(descriptor);
    }

    static void record_request_marker(const char *suffix) {
      char marker[PATH_MAX];
      snprintf(marker, sizeof(marker), "%s.%s", implementation_path, suffix);
      int descriptor = open(marker, O_CREAT | O_WRONLY, 0600);
      if (descriptor >= 0) close(descriptor);
    }

    int main(int argc, char **argv) {
      setvbuf(stdout, NULL, _IONBF, 0);
      const char *runtime = argument_value(argc, argv, "--runtime-epoch");
      const char *generation = argument_value(argc, argv, "--executor-generation");
      const char *build = argument_value(argc, argv, "--helper-build-id");
      const char *manifest = argument_value(argc, argv, "--manifest-hash");
      const char *mode = argument_value(argc, argv, "--mode");
      if (runtime == NULL || generation == NULL || build == NULL || manifest == NULL || argc < 5) {
        return 2;
      }
      runtime_epoch = strtoull(runtime, NULL, 10);
      executor_generation = strtoull(generation, NULL, 10);
      if (proc_pidpath(getpid(), implementation_path, sizeof(implementation_path)) <= 0) {
        snprintf(implementation_path, sizeof(implementation_path), "%s", argv[0]);
      }

      struct proc_bsdinfo info;
      int size = proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, sizeof(info));
      if (size != sizeof(info)) return 2;
      char message_id[64];
      next_message_id(message_id, sizeof(message_id));
      printf(
        "{\"executorGeneration\":%llu,\"helperBuildID\":\"%s\","
        "\"helperKind\":\"%s\",\"manifestHash\":\"%s\","
        "\"messageID\":\"%s\",\"processStartIdentity\":\"%llu.%06llu\","
        "\"runtimeEpoch\":%llu,\"schemaVersion\":1,\"type\":\"Hello\"}\n",
        executor_generation, build, mode == NULL ? "coreDevice" : "direct",
        manifest, message_id,
        info.pbi_start_tvsec, info.pbi_start_tvusec, runtime_epoch
      );

      char *line = NULL;
      size_t capacity = 0;
      if (getline(&line, &capacity, stdin) < 0) return 2;
      next_message_id(message_id, sizeof(message_id));
      printf(
        "{\"executorGeneration\":%llu,\"messageID\":\"%s\","
        "\"payload\":{\"facets\":[]},\"runtimeEpoch\":%llu,"
        "\"schemaVersion\":1,\"type\":\"Ready\"}\n",
        executor_generation, message_id, runtime_epoch
      );

      while (getline(&line, &capacity, stdin) >= 0) {
        char type[64];
        if (!extract_string(line, "type", type, sizeof(type))) return 2;
        if (strcmp(type, "Shutdown") == 0) break;
        if (strcmp(type, "StreamOpen") == 0) {
          frame_timeout = strstr(line, "test.frameTimeout") != NULL;
          frame_exit = strstr(line, "test.frameExit") != NULL;
          cleanup_failure = strstr(line, "test.cleanupFailure") != NULL;
          if (strstr(line, "test.serviceFailure") != NULL) {
            snprintf(pending_phase, sizeof(pending_phase), "openingInputService");
          }
          continue;
        }
        if (strcmp(type, "Frame") == 0) {
          if (frame_exit) return 9;
          if (!frame_timeout) send_frame_accepted(line);
          continue;
        }
        if (strcmp(type, "Close") == 0 || strcmp(type, "Cancel") == 0) {
          if (cleanup_failure) {
            snprintf(pending_phase, sizeof(pending_phase), "closingInputService");
          }
          continue;
        }
        if (strcmp(type, "Request") == 0) {
          char request_id[64];
          if (!extract_string(line, "requestID", request_id, sizeof(request_id))) return 2;
          send_associated("Accepted", request_id);
          send_associated("Started", request_id);
          fflush(stdout);
          if (strstr(line, "test.exit") != NULL) return 9;
          if (mode != NULL &&
              strstr(line, "direct.installationProxy.install") != NULL) {
            char direct_started[PATH_MAX];
            snprintf(
              direct_started, sizeof(direct_started), "%s.started",
              implementation_path
            );
            int descriptor = open(direct_started, O_CREAT | O_WRONLY, 0600);
            if (descriptor >= 0) close(descriptor);
          }
          if (strstr(line, "test.block") != NULL) wait_for_release();
          if (strstr(line, "coredevice.warmGeneration") != NULL) {
            record_request_marker("warmObserved");
          }
          if (strstr(line, "coredevice.button.home") != NULL) {
            record_request_marker("buttonHomeObserved");
          }
          if (strstr(line, "coredevice.barrier") != NULL) {
            record_barrier();
            char drop_barrier[PATH_MAX];
            snprintf(drop_barrier, sizeof(drop_barrier), "%s.dropBarrier", implementation_path);
            if (access(drop_barrier, F_OK) == 0) continue;
          }
          char block_warm[PATH_MAX];
          snprintf(block_warm, sizeof(block_warm), "%s.blockWarm", implementation_path);
          if (strstr(line, "coredevice.warmGeneration") != NULL &&
              access(block_warm, F_OK) == 0) wait_for_release();
          char fail_warm[PATH_MAX];
          snprintf(fail_warm, sizeof(fail_warm), "%s.failWarm", implementation_path);
          if (strstr(line, "coredevice.warmGeneration") != NULL &&
              access(fail_warm, F_OK) == 0) {
            snprintf(pending_phase, sizeof(pending_phase), "startingDeviceServices");
          }
          send_result(request_id, pending_phase, line);
          pending_phase[0] = '\0';
          char axaudit_fallback[PATH_MAX], coredevice_fallback[PATH_MAX];
          snprintf(
            axaudit_fallback, sizeof(axaudit_fallback), "%s.axAuditFallback",
            implementation_path
          );
          snprintf(
            coredevice_fallback, sizeof(coredevice_fallback), "%s.coreDeviceFallback",
            implementation_path
          );
          if (strstr(line, "coredevice.screenshot") != NULL &&
              (access(coredevice_fallback, F_OK) == 0 ||
               access(axaudit_fallback, F_OK) == 0)) return 1;
          continue;
        }
        return 2;
      }
      free(line);
      return 0;
    }
    """#
}

private final class RuntimeLockHolder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: RuntimeLock?

    init(_ runtimeLock: RuntimeLock) {
        self.stored = runtimeLock
    }

    var runtimeLock: RuntimeLock? {
        lock.withLock { stored }
    }

    func release() {
        lock.withLock { stored = nil }
    }
}

private final class OrphanStopProcessSystem: VerifiedRecoveryProcessSystem,
    @unchecked Sendable
{
    private let lock = NSLock()
    private let lockHolder: RuntimeLockHolder
    private var helperAlive = true
    private var recordedSignals = [Int32]()

    init(lockHolder: RuntimeLockHolder) {
        self.lockHolder = lockHolder
    }

    var signals: [Int32] {
        lock.withLock { recordedSignals }
    }

    func observeRuntime(
        _ identity: RuntimeRecoveryIdentity
    ) -> RecoveryProcessObservation {
        .gone
    }

    func observeHelper(
        _ identity: HelperProcessIdentity
    ) -> RecoveryProcessObservation {
        lock.withLock { helperAlive ? .verified : .gone }
    }

    func signalHelperProcessGroup(
        _ identity: HelperProcessIdentity,
        signal: Int32
    ) throws {
        lock.withLock {
            recordedSignals.append(signal)
            helperAlive = false
        }
        lockHolder.release()
    }
}

private struct IdentityMismatchRecoveryProcessSystem:
    VerifiedRecoveryProcessSystem,
    Sendable
{
    func observeRuntime(
        _ identity: RuntimeRecoveryIdentity
    ) -> RecoveryProcessObservation {
        .identityMismatch
    }

    func observeHelper(
        _ identity: HelperProcessIdentity
    ) -> RecoveryProcessObservation {
        .identityMismatch
    }

    func signalHelperProcessGroup(
        _ identity: HelperProcessIdentity,
        signal: Int32
    ) throws {
        throw VerifiedProcessRecoveryError.identityMismatch
    }
}

private final class LockedErrorStore: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Error?

    var error: Error? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func store(_ error: Error) {
        lock.lock()
        stored = error
        lock.unlock()
    }
}

private final class LockedCaptureReadyResultStore: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ProductionCoreDeviceCaptureReadyResult?

    var result: ProductionCoreDeviceCaptureReadyResult? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func store(_ result: ProductionCoreDeviceCaptureReadyResult) {
        lock.lock()
        stored = result
        lock.unlock()
    }
}

private final class LockedPreparationResultStore: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<ProductionRuntimeBackendDisposition, Error>?

    var hasResult: Bool { lock.withLock { stored != nil } }

    func store(_ result: ProductionRuntimeBackendDisposition) {
        lock.withLock { stored = .success(result) }
    }

    func store(_ error: Error) {
        lock.withLock { stored = .failure(error) }
    }

    func requireResult() throws -> ProductionRuntimeBackendDisposition {
        let result = try XCTUnwrap(lock.withLock { stored })
        return try result.get()
    }
}

private final class LockedCallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() {
        lock.withLock { count += 1 }
    }
}

private final class ElementCancellationIdentityRecorder: @unchecked Sendable {
    let cancellationReceived = DispatchSemaphore(value: 0)
    let cancellationRecorded = DispatchSemaphore(value: 0)
    let commandRecorded = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var storedCancelClientInstanceID: CanonicalUUID?
    private var storedCancelReason: String?
    private var storedCancelTargetRequestID: String?
    private var storedCommandClientInstanceID: CanonicalUUID?
    private var storedCommandRequestID: CanonicalUUID?

    var cancelClientInstanceID: CanonicalUUID? {
        lock.withLock { storedCancelClientInstanceID }
    }

    var cancelReason: String? {
        lock.withLock { storedCancelReason }
    }

    var cancelTargetRequestID: String? {
        lock.withLock { storedCancelTargetRequestID }
    }

    var commandClientInstanceID: CanonicalUUID? {
        lock.withLock { storedCommandClientInstanceID }
    }

    var commandRequestID: CanonicalUUID? {
        lock.withLock { storedCommandRequestID }
    }

    func recordCommand(
        clientInstanceID: CanonicalUUID?,
        requestID: CanonicalUUID
    ) {
        lock.withLock {
            storedCommandClientInstanceID = clientInstanceID
            storedCommandRequestID = requestID
        }
        commandRecorded.signal()
    }

    func recordCancellation(
        clientInstanceID: CanonicalUUID?,
        targetRequestID: String?,
        reason: String?
    ) {
        lock.withLock {
            storedCancelClientInstanceID = clientInstanceID
            storedCancelTargetRequestID = targetRequestID
            storedCancelReason = reason
        }
        cancellationRecorded.signal()
    }
}

private final class LockedStringStore: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = [String]()

    var values: [String] { lock.withLock { stored } }

    func append(_ value: String) {
        lock.withLock { stored.append(value) }
    }
}

private final class LockedDeviceDiscoveryState: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ProductionRuntimeDeviceObservation?
    private var pendingFailure = false

    init(device: ProductionRuntimeDeviceObservation?) {
        stored = device
    }

    var device: ProductionRuntimeDeviceObservation? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func failNextDiscovery() {
        lock.withLock { pendingFailure = true }
    }

    func discover() throws -> ProductionRuntimeDeviceObservation? {
        try lock.withLock {
            if pendingFailure {
                pendingFailure = false
                throw TestDeviceDiscoveryError.transient
            }
            return stored
        }
    }
}

private enum TestDeviceDiscoveryError: Error {
    case transient
}

private final class BlockingDeviceDiscoveryState: @unchecked Sendable {
    private let lock = NSLock()
    private let blocked = DispatchSemaphore(value: 0)
    private let resumed = DispatchSemaphore(value: 0)
    private var stored: ProductionRuntimeDeviceObservation?
    private var shouldBlock = false

    init(device: ProductionRuntimeDeviceObservation?) {
        stored = device
    }

    var device: ProductionRuntimeDeviceObservation? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func blockNextDiscovery() {
        lock.withLock { shouldBlock = true }
    }

    func discover() -> ProductionRuntimeDeviceObservation? {
        let block = lock.withLock {
            defer { shouldBlock = false }
            return shouldBlock
        }
        if block {
            blocked.signal()
            resumed.wait()
        }
        return device
    }

    func waitUntilBlocked() -> DispatchTimeoutResult {
        blocked.wait(timeout: .now() + 1)
    }

    func resumeDiscovery() {
        resumed.signal()
    }
}

private final class LockedRuntimeDeviceSnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSnapshot: ProductionRuntimeDeviceSnapshot?
    private var storedError: Error?

    var snapshot: ProductionRuntimeDeviceSnapshot? {
        lock.withLock { storedSnapshot }
    }

    var error: Error? {
        lock.withLock { storedError }
    }

    func store(_ snapshot: ProductionRuntimeDeviceSnapshot) {
        lock.withLock { storedSnapshot = snapshot }
    }

    func store(_ error: Error) {
        lock.withLock { storedError = error }
    }
}

private final class FakeUSBDeviceMonitor: ProductionUSBDeviceMonitoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var handler: (@Sendable (ProductionUSBDeviceMonitorEvent) -> Void)?

    func start(
        _ handler: @escaping @Sendable (ProductionUSBDeviceMonitorEvent) -> Void
    ) {
        lock.withLock { self.handler = handler }
    }

    func stop() {
        lock.withLock { handler = nil }
    }

    func emit(_ event: ProductionUSBDeviceMonitorEvent) {
        lock.withLock { handler }?(event)
    }
}

private final class LockedFrameStore: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = [RuntimeStreamFrameEnvelope]()

    var values: [RuntimeStreamFrameEnvelope] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func append(_ frame: RuntimeStreamFrameEnvelope) {
        lock.lock()
        stored.append(frame)
        lock.unlock()
    }
}

private final class LockedRuntimeObservationStore: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = [RuntimeObservation]()

    var values: [RuntimeObservation] {
        lock.withLock { stored }
    }

    func append(_ observation: RuntimeObservation) {
        lock.withLock { stored.append(observation) }
    }
}

private final class LockedPreparationProgressStore: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = [PreparationProgressV1]()

    var values: [PreparationProgressV1] { lock.withLock { stored } }

    func append(_ progress: PreparationProgressV1) {
        lock.withLock { stored.append(progress) }
    }
}
