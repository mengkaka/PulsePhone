import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
@testable import PulsePhoneGUI
import PulsePhoneHostPaths
@testable import PulsePhoneMedia
import PulsePhoneSharedDefinitions
import XCTest

final class ProductionLiveSourceResolverTests: XCTestCase {
    func testPreviewAuthorityRequiresOwnerSourceEpochAndFreshFrame() {
        let owner = UUID()
        let authority = ProductionSourcePreviewAuthority(
            ownerToken: owner,
            sourceEpoch: 7,
            sourceID: "source-a"
        )
        let maximumAge: UInt64 = 1_000_000_000

        XCTAssertTrue(authority.accepts(sourceID: "source-a", sourceEpoch: 7))
        XCTAssertFalse(authority.accepts(sourceID: "source-b", sourceEpoch: 7))
        XCTAssertFalse(authority.accepts(sourceID: "source-a", sourceEpoch: 8))
        XCTAssertTrue(authority.frameIsFresh(
            ownerToken: owner,
            capturedAtNanoseconds: 10,
            nowNanoseconds: 10 + maximumAge,
            maximumAgeNanoseconds: maximumAge
        ))
        XCTAssertFalse(authority.frameIsFresh(
            ownerToken: owner,
            capturedAtNanoseconds: 10,
            nowNanoseconds: 11 + maximumAge,
            maximumAgeNanoseconds: maximumAge
        ))
        XCTAssertFalse(authority.frameIsFresh(
            ownerToken: UUID(),
            capturedAtNanoseconds: 10,
            nowNanoseconds: 10,
            maximumAgeNanoseconds: maximumAge
        ))
        XCTAssertFalse(authority.frameIsFresh(
            ownerToken: owner,
            capturedAtNanoseconds: 11,
            nowNanoseconds: 10,
            maximumAgeNanoseconds: maximumAge
        ))
    }

    @MainActor
    func testCachedExactMappingHandsOffBeforeStableGateAndAfterCaptureStops() async throws {
        let fixture = try ResolverFixture(mapping: .cached)
        fixture.capture.emitOnStart = true
        let handedOff = expectation(description: "cached source handed off")
        let started = ContinuousClock.now
        let resolver = fixture.makeResolver(firstHandoff: { _, _, handoff in
            XCTAssertEqual(
                handoff.targetFacts.canonicalUDID,
                fixture.target
            )
            XCTAssertEqual(fixture.capture.activeCount, 0)
            handedOff.fulfill()
        })
        resolver.apply(fixture.inventory)
        resolver.openFirstOwner(
            target: fixture.target,
            ownerID: fixture.ownerID,
            policy: .automatic
        )

        await fulfillment(of: [handedOff], timeout: 1)
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
        XCTAssertEqual(fixture.capture.startCount, 1)
        XCTAssertEqual(fixture.capture.stopCount, 1)
        XCTAssertEqual(fixture.capture.maximumActiveCount, 1)
    }

    @MainActor
    func testTargetFactsAndClaimsFailuresNeverRestoreCachedMapping() async throws {
        let factsFailure = try ResolverFixture(mapping: .cached)
        let factsProvider = ResolverSnapshotProviderBox(
            snapshot: factsFailure.snapshot,
            failuresBeforeSuccess: .max
        )
        let factsResolver = factsFailure.makeResolver(
            snapshotProvider: factsProvider.load
        )
        factsResolver.apply(factsFailure.inventory)
        factsResolver.openFirstOwner(
            target: factsFailure.target,
            ownerID: factsFailure.ownerID,
            policy: .automatic
        )
        await assertEventually {
            self.chooser(ownerID: factsFailure.ownerID) != nil
        }
        XCTAssertEqual(factsFailure.capture.startCount, 2)
        XCTAssertEqual(
            statusText(in: try XCTUnwrap(chooser(ownerID: factsFailure.ownerID))),
            "无法读取设备信息，请刷新后重试"
        )
        XCTAssertEqual(factsProvider.attemptCount, 4)
        chooser(ownerID: factsFailure.ownerID)?.close()

        let claimsFailure = try ResolverFixture(mapping: .cached)
        claimsFailure.store.forcedFailures[claimsFailure.target] = .ioFailure
        let claimsResolver = claimsFailure.makeResolver()
        claimsResolver.apply(claimsFailure.inventory)
        claimsResolver.openFirstOwner(
            target: claimsFailure.target,
            ownerID: claimsFailure.ownerID,
            policy: .automatic
        )
        await assertEventually {
            self.statusText(in: self.chooser(ownerID: claimsFailure.ownerID))
                == "无法验证视频源缓存，请刷新后重试"
        }
        XCTAssertEqual(claimsFailure.capture.startCount, 2)
        XCTAssertEqual(claimsFailure.store.loadCount, 4)
        chooser(ownerID: claimsFailure.ownerID)?.close()
    }

    @MainActor
    func testTargetFactsRetryRecoversAndEnablesFreshDefaultPreview() async throws {
        let fixture = try ResolverFixture(mapping: .missing)
        fixture.capture.emitOnStart = true
        let provider = ResolverSnapshotProviderBox(
            snapshot: fixture.snapshot,
            failuresBeforeSuccess: 2
        )
        let resolver = fixture.makeResolver(snapshotProvider: provider.load)
        resolver.apply(fixture.inventory)
        resolver.openFirstOwner(
            target: fixture.target,
            ownerID: fixture.ownerID,
            policy: .forceChooser
        )

        await assertEventually {
            self.confirmButton(in: self.chooser(ownerID: fixture.ownerID))?.isEnabled
                == true
        }
        XCTAssertTrue((3...4).contains(provider.attemptCount))
        XCTAssertEqual(fixture.store.load(target: fixture.target), .missing)
        XCTAssertEqual(
            candidateButton(in: chooser(ownerID: fixture.ownerID))?.state,
            .on
        )
        chooser(ownerID: fixture.ownerID)?.close()
    }

    @MainActor
    func testClaimsWaitForTwoMatchingConnectedTargetSnapshots() async throws {
        let fixture = try ResolverFixture(
            mapping: .cached,
            includeOtherTarget: true
        )
        _ = try fixture.store.replace(
            target: fixture.otherTarget,
            sourceID: fixture.source.sourceID,
            proofKind: .operatorConfirmedPreview
        )
        let target = ProductionLiveSourceTargetFacts(
            canonicalUDID: fixture.target,
            name: "iPhone",
            osVersion: "26.5"
        )
        let other = ProductionLiveSourceTargetFacts(
            canonicalUDID: fixture.otherTarget,
            name: "iPhone",
            osVersion: "16.3"
        )
        let provider = ResolverSnapshotSequenceProviderBox(snapshots: [
            ProductionLiveSourceTargetSnapshot(
                connectedTargets: [target],
                target: target
            ),
            ProductionLiveSourceTargetSnapshot(
                connectedTargets: [target, other],
                target: target
            ),
            ProductionLiveSourceTargetSnapshot(
                connectedTargets: [target, other],
                target: target
            ),
        ])
        let resolver = fixture.makeResolver(snapshotProvider: provider.load)
        resolver.apply(fixture.inventory)
        resolver.openFirstOwner(
            target: fixture.target,
            ownerID: fixture.ownerID,
            policy: .forceChooser
        )

        await assertEventually {
            self.candidateText(in: self.chooser(ownerID: fixture.ownerID))
                .contains(fixture.otherTarget.rawValue)
        }
        XCTAssertGreaterThanOrEqual(provider.attemptCount, 3)
        chooser(ownerID: fixture.ownerID)?.close()
    }

    @MainActor
    func testTargetSnapshotRecoverySerializesProviderCalls() async throws {
        let fixture = try ResolverFixture(
            mapping: .cached,
            includeOtherTarget: true
        )
        let provider = ResolverSerializedSnapshotProviderBox(
            snapshot: fixture.snapshot
        )
        let resolver = fixture.makeResolver(snapshotProvider: provider.load)
        resolver.apply(fixture.inventory)
        resolver.openFirstOwner(
            target: fixture.target,
            ownerID: fixture.ownerID,
            policy: .forceChooser
        )

        await assertEventually { provider.firstAttemptStarted }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertEqual(provider.maximumConcurrentAttempts, 1)

        provider.releaseFirstAttempt()
        await assertEventually {
            self.candidateText(in: self.chooser(ownerID: fixture.ownerID))
                .contains(fixture.target.rawValue)
        }
        XCTAssertGreaterThanOrEqual(provider.attemptCount, 2)
        XCTAssertEqual(provider.maximumConcurrentAttempts, 1)
        chooser(ownerID: fixture.ownerID)?.close()
    }

    @MainActor
    func testConflictedCacheAndNoFrameProbeFallBackToChooser() async throws {
        let conflicted = try ResolverFixture(mapping: .cached, includeOtherTarget: true)
        _ = try conflicted.store.replace(
            target: conflicted.otherTarget,
            sourceID: conflicted.source.sourceID,
            proofKind: .operatorConfirmedPreview
        )
        let conflictResolver = conflicted.makeResolver()
        conflictResolver.apply(conflicted.inventory)
        conflictResolver.openFirstOwner(
            target: conflicted.target,
            ownerID: conflicted.ownerID,
            policy: .automatic
        )
        await assertEventually {
            self.candidateText(in: self.chooser(ownerID: conflicted.ownerID))
                .contains(conflicted.otherTarget.rawValue)
        }
        XCTAssertGreaterThanOrEqual(conflicted.capture.startCount, 1)
        chooser(ownerID: conflicted.ownerID)?.close()

        let noFrame = try ResolverFixture(mapping: .cached)
        let noFrameResolver = noFrame.makeResolver(probeTimeout: .milliseconds(30))
        noFrameResolver.apply(noFrame.inventory)
        noFrameResolver.openFirstOwner(
            target: noFrame.target,
            ownerID: noFrame.ownerID,
            policy: .automatic
        )
        await assertEventually {
            self.chooser(ownerID: noFrame.ownerID) != nil
                && noFrame.capture.stopCount == 1
        }
        XCTAssertEqual(noFrame.capture.startCount, 3)
        XCTAssertEqual(noFrame.capture.activeCount, 2)
        chooser(ownerID: noFrame.ownerID)?.close()
    }

    @MainActor
    func testStableSingleTargetAutoBindingWritesDistinctProof() async throws {
        let fixture = try ResolverFixture(mapping: .missing)
        fixture.capture.emitOnStart = true
        let handedOff = expectation(description: "automatic source handed off")
        let started = ContinuousClock.now
        let resolver = fixture.makeResolver(firstHandoff: { _, _, _ in
            handedOff.fulfill()
        })
        resolver.apply(fixture.inventory)
        resolver.openFirstOwner(
            target: fixture.target,
            ownerID: fixture.ownerID,
            policy: .automatic
        )

        await fulfillment(of: [handedOff], timeout: 3)
        XCTAssertGreaterThanOrEqual(started.duration(to: .now), .seconds(1.4))
        guard case .mapped(let record) = fixture.store.load(target: fixture.target)
        else { return XCTFail("automatic mapping was not saved") }
        XCTAssertEqual(record.proofKind, .singleConnectedTargetSource)
        XCTAssertEqual(record.sourceID, fixture.source.sourceID)
        XCTAssertEqual(record.initialCanvasDimensions?.width, 16)
        XCTAssertEqual(record.initialCanvasDimensions?.height, 32)
    }

    @MainActor
    func testUserSelectionCancelsPendingAutomaticBinding() async throws {
        let fixture = try ResolverFixture(mapping: .missing)
        fixture.capture.emitOnStart = true
        let unexpectedHandoff = expectation(description: "no automatic handoff")
        unexpectedHandoff.isInverted = true
        let cancelled = expectation(description: "first owner released")
        let resolver = fixture.makeResolver(
            firstHandoff: { _, _, _ in unexpectedHandoff.fulfill() },
            ownerCancelled: { _, _ in cancelled.fulfill() }
        )
        resolver.apply(fixture.inventory)
        resolver.openFirstOwner(
            target: fixture.target,
            ownerID: fixture.ownerID,
            policy: .automatic
        )
        await assertEventually {
            self.candidateButton(in: self.chooser(ownerID: fixture.ownerID)) != nil
        }
        candidateButton(in: chooser(ownerID: fixture.ownerID))?.performClick(nil)
        await assertEventually {
            self.confirmButton(in: self.chooser(ownerID: fixture.ownerID))?.isEnabled
                == true
        }

        await fulfillment(of: [unexpectedHandoff], timeout: 1.8)
        XCTAssertEqual(fixture.store.load(target: fixture.target), .missing)
        chooser(ownerID: fixture.ownerID)?.close()
        await fulfillment(of: [cancelled], timeout: 1)
    }

    @MainActor
    func testManualPreviewConfirmationSavesOperatorProofAndHandsOff() async throws {
        let fixture = try ResolverFixture(mapping: .missing)
        fixture.capture.emitOnStart = true
        let handedOff = expectation(description: "manual source handed off")
        let resolver = fixture.makeResolver(firstHandoff: { _, _, handoff in
            XCTAssertEqual(handoff.targetFacts.canonicalUDID, fixture.target)
            XCTAssertEqual(fixture.capture.activeCount, 0)
            handedOff.fulfill()
        })
        resolver.apply(fixture.inventory)
        resolver.openFirstOwner(
            target: fixture.target,
            ownerID: fixture.ownerID,
            policy: .forceChooser
        )
        await assertEventually {
            self.candidateButton(in: self.chooser(ownerID: fixture.ownerID)) != nil
        }
        candidateButton(in: chooser(ownerID: fixture.ownerID))?.performClick(nil)
        await assertEventually {
            self.confirmButton(in: self.chooser(ownerID: fixture.ownerID))?.isEnabled
                == true
        }
        confirmButton(in: chooser(ownerID: fixture.ownerID))?.performClick(nil)

        await fulfillment(of: [handedOff], timeout: 1)
        guard case .mapped(let record) = fixture.store.load(target: fixture.target)
        else { return XCTFail("manual mapping was not saved") }
        XCTAssertEqual(record.proofKind, .operatorConfirmedPreview)
        XCTAssertEqual(record.initialCanvasDimensions?.width, 16)
        XCTAssertEqual(record.initialCanvasDimensions?.height, 32)
    }

    @MainActor
    func testExistingLiveConfirmationUsesExistingHandoffWithoutReleasingOwner() async throws {
        let fixture = try ResolverFixture(mapping: .missing)
        fixture.capture.emitOnStart = true
        let handedOff = expectation(description: "existing live source handed off")
        let unexpectedRelease = expectation(description: "existing owner retained")
        unexpectedRelease.isInverted = true
        let resolver = fixture.makeResolver(
            existingHandoff: { target, ownerID, handoff in
                XCTAssertEqual(target, fixture.target)
                XCTAssertEqual(ownerID, fixture.ownerID)
                XCTAssertEqual(handoff.targetFacts.canonicalUDID, fixture.target)
                XCTAssertEqual(fixture.capture.activeCount, 0)
                handedOff.fulfill()
            },
            ownerCancelled: { _, _ in unexpectedRelease.fulfill() }
        )
        resolver.apply(fixture.inventory)
        resolver.openForExistingLive(
            target: fixture.target,
            ownerID: fixture.ownerID
        )
        await assertEventually {
            self.candidateButton(in: self.chooser(ownerID: fixture.ownerID)) != nil
        }
        candidateButton(in: chooser(ownerID: fixture.ownerID))?.performClick(nil)
        await assertEventually {
            self.confirmButton(in: self.chooser(ownerID: fixture.ownerID))?.isEnabled
                == true
        }
        confirmButton(in: chooser(ownerID: fixture.ownerID))?.performClick(nil)

        await fulfillment(of: [handedOff], timeout: 1)
        await fulfillment(of: [unexpectedRelease], timeout: 0.1)
    }

    @MainActor
    func testCurrentActiveSourceConfirmationIsStrictNoOp() async throws {
        let fixture = try ResolverFixture(mapping: .cached)
        fixture.capture.emitOnStart = true
        let retained = expectation(description: "current source retained")
        let unexpectedHandoff = expectation(description: "no source handoff")
        unexpectedHandoff.isInverted = true
        let initialReplaceCount = fixture.store.replaceCount
        let resolver = fixture.makeResolver(
            activeBindingsProvider: {
                [ProductionLiveSourceActiveBinding(
                    descriptor: fixture.source,
                    target: fixture.target
                )]
            },
            existingHandoff: { _, _, _ in unexpectedHandoff.fulfill() },
            existingSourceRetained: { target, ownerID in
                XCTAssertEqual(target, fixture.target)
                XCTAssertEqual(ownerID, fixture.ownerID)
                retained.fulfill()
            }
        )
        resolver.apply(fixture.inventory)
        resolver.openForExistingLive(
            target: fixture.target,
            ownerID: fixture.ownerID
        )

        await assertEventually {
            guard let window = self.chooser(ownerID: fixture.ownerID) else { return false }
            let candidateText = self.candidateText(in: window)
            let hasCurrentStatus = self.descendants(of: window.contentView)
                .compactMap { $0 as? NSTextField }
                .contains { $0.stringValue == "当前 Live 正在使用此视频源" }
            return candidateText.contains(
                "已映射到：Test iPhone / \(fixture.target.rawValue)"
            ) && candidateText.contains("当前正在使用") && hasCurrentStatus
        }
        XCTAssertTrue(candidateText(in: chooser(ownerID: fixture.ownerID))
            .contains("已映射到：Test iPhone / \(fixture.target.rawValue)"))
        XCTAssertTrue(candidateText(in: chooser(ownerID: fixture.ownerID))
            .contains("当前正在使用"))
        XCTAssertTrue(descendants(of: chooser(ownerID: fixture.ownerID)?.contentView)
            .compactMap { $0 as? NSTextField }
            .contains { $0.stringValue == "当前 Live 正在使用此视频源" })
        weak var closedWindow: NSWindow?
        do {
            let window = try XCTUnwrap(chooser(ownerID: fixture.ownerID))
            closedWindow = window
            window.contentView?.layoutSubtreeIfNeeded()
            let contentView = try XCTUnwrap(window.contentView)
            let warning = try XCTUnwrap(
                descendants(of: contentView).compactMap { $0 as? NSTextField }
                    .first { $0.stringValue == "当前 Live 正在使用此视频源" }
            )
            let statusArea = try XCTUnwrap(warning.superview as? NSStackView)
            let status = NSTextField(labelWithString: "视频正在准备")
            statusArea.addArrangedSubview(status)
            window.setContentSize(window.contentMinSize)
            contentView.layoutSubtreeIfNeeded()
            let confirm = try XCTUnwrap(confirmButton(in: window))
            let refresh = try XCTUnwrap(refreshButton(in: window))
            let statusAreaFrame = statusArea.convert(statusArea.bounds, to: contentView)
            let refreshFrame = refresh.convert(refresh.bounds, to: contentView)
            XCTAssertEqual(
                statusAreaFrame.minX - refreshFrame.maxX,
                10,
                accuracy: 0.5
            )
            XCTAssertEqual(
                contentView.bounds.maxX
                    - confirm.convert(confirm.bounds, to: contentView).maxX,
                14,
                accuracy: 0.5
            )
        }
        confirmButton(in: chooser(ownerID: fixture.ownerID))?.performClick(nil)

        await fulfillment(of: [retained], timeout: 1)
        await fulfillment(of: [unexpectedHandoff], timeout: 0.1)
        XCTAssertNil(closedWindow)
        XCTAssertEqual(fixture.store.replaceCount, initialReplaceCount)
        XCTAssertEqual(fixture.store.clearCount, 0)
        XCTAssertEqual(fixture.capture.activeCount, 0)
    }

    @MainActor
    func testMappingClaimAndOtherActiveLiveAreProjectedIndependently() async throws {
        let fixture = try ResolverFixture(mapping: .cached, includeOtherTarget: true)
        fixture.capture.emitOnStart = true
        let resolver = fixture.makeResolver(activeBindingsProvider: {
            [ProductionLiveSourceActiveBinding(
                descriptor: fixture.source,
                target: fixture.otherTarget
            )]
        })
        resolver.apply(fixture.inventory)
        resolver.openForExistingLive(
            target: fixture.target,
            ownerID: fixture.ownerID
        )

        await assertEventually {
            let candidateText = self.candidateText(
                in: self.chooser(ownerID: fixture.ownerID)
            )
            return candidateText.contains(
                "已映射到：Test iPhone / \(fixture.target.rawValue)"
            ) && candidateText.contains(
                "正在 Live 中：Other iPhone / \(fixture.otherTarget.rawValue)"
            )
        }
        XCTAssertFalse(candidateText(in: chooser(ownerID: fixture.ownerID))
            .contains("当前正在使用"))
        XCTAssertTrue(descendants(of: chooser(ownerID: fixture.ownerID)?.contentView)
            .compactMap { $0 as? NSTextField }
            .contains { $0.stringValue.hasPrefix("确认后将重新分配此视频源") })
        let window = try XCTUnwrap(chooser(ownerID: fixture.ownerID))
        let contentView = try XCTUnwrap(window.contentView)
        let warning = try XCTUnwrap(
            descendants(of: contentView)
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue.hasPrefix("确认后将重新分配此视频源") }
        )
        contentView.layoutSubtreeIfNeeded()
        let originalWidth = window.frame.width
        warning.stringValue = String(repeating: "很长的重新分配提示 ", count: 80)
        contentView.layoutSubtreeIfNeeded()
        XCTAssertEqual(window.frame.width, originalWidth, accuracy: 0.5)
        XCTAssertEqual(warning.maximumNumberOfLines, 1)
        XCTAssertEqual(warning.lineBreakMode, .byTruncatingTail)
        XCTAssertGreaterThan(warning.intrinsicContentSize.width, warning.bounds.width)
        chooser(ownerID: fixture.ownerID)?.close()
    }

    @MainActor
    func testChooserUsesDualColumnLayoutAndLargeNineBySixteenPreview() throws {
        let fixture = try ResolverFixture(
            mapping: .missing,
            includeSecondSource: true
        )
        let resolver = fixture.makeResolver(
            productVersion: try XCTUnwrap(PulsePhoneProductVersion(
                version: "0.1.0",
                build: "1"
            ))
        )
        resolver.apply(fixture.inventory)
        resolver.openFirstOwner(
            target: fixture.target,
            ownerID: fixture.ownerID,
            policy: .forceChooser
        )
        let window = try XCTUnwrap(chooser(ownerID: fixture.ownerID))
        window.contentView?.layoutSubtreeIfNeeded()
        let preview = try XCTUnwrap(
            descendants(of: window.contentView).first {
                $0.identifier?.rawValue == "live-source-preview"
            }
        )
        XCTAssertEqual(
            preview.frame.width,
            preview.frame.height * 9.0 / 16.0,
            accuracy: 1
        )
        XCTAssertEqual(window.title, "选择视频源")
        XCTAssertEqual(window.subtitle, "PulsePhone 0.1.0 (1)")
        XCTAssertTrue(window.styleMask.contains(.resizable))
        XCTAssertEqual(window.contentMinSize, NSSize(width: 760, height: 500))
        XCTAssertEqual(window.contentView?.bounds.size, NSSize(width: 920, height: 600))
        XCTAssertGreaterThan(preview.frame.height, 300)
        let candidates = sourceCandidateButtons(in: window)
        XCTAssertEqual(candidates.count, 2)
        XCTAssertTrue(candidates.allSatisfy { $0.frame.height == 104 })
        XCTAssertEqual(candidates[0].frame.minX, candidates[1].frame.minX, accuracy: 1)
        XCTAssertEqual(candidates[0].frame.width, candidates[1].frame.width, accuracy: 1)
        let scroll = try XCTUnwrap(
            descendants(of: window.contentView).first { $0 is NSScrollView }
                as? NSScrollView
        )
        XCTAssertEqual(scroll.documentView?.isFlipped, true)
        let documentView = try XCTUnwrap(scroll.documentView)
        XCTAssertEqual(candidates[0].frame.minX, 18, accuracy: 1)
        XCTAssertEqual(
            candidates[0].frame.maxX,
            documentView.bounds.maxX - 18,
            accuracy: 1
        )
        let thumbnailMinXs = candidates.compactMap { candidate in
            descendants(of: candidate).compactMap { $0 as? NSImageView }.first
                .map { $0.convert($0.bounds, to: documentView).minX }
        }
        XCTAssertEqual(thumbnailMinXs.count, 2)
        XCTAssertEqual(thumbnailMinXs[0], thumbnailMinXs[1], accuracy: 1)
        let contentView = try XCTUnwrap(window.contentView)
        let confirm = try XCTUnwrap(confirmButton(in: window))
        let cancel = try XCTUnwrap(
            buttons(in: window).first { $0.title == "取消" }
        )
        let confirmFrame = confirm.convert(confirm.bounds, to: contentView)
        let cancelFrame = cancel.convert(cancel.bounds, to: contentView)
        XCTAssertEqual(
            contentView.bounds.maxX - confirmFrame.maxX,
            14,
            accuracy: 1
        )
        XCTAssertEqual(confirmFrame.midY, cancelFrame.midY, accuracy: 1)
        XCTAssertTrue(
            descendants(of: preview).compactMap { $0 as? NSTextField }
                .contains { $0.stringValue.contains(fixture.target.rawValue) }
        )
        window.close()
    }

    @MainActor
    func testLongFooterStatusDoesNotExpandChooserWidth() async throws {
        let fixture = try ResolverFixture(mapping: .cached)
        let provider = ResolverSnapshotProviderBox(
            snapshot: fixture.snapshot,
            failuresBeforeSuccess: .max
        )
        let resolver = fixture.makeResolver(snapshotProvider: provider.load)
        resolver.apply(fixture.inventory)
        resolver.openFirstOwner(
            target: fixture.target,
            ownerID: fixture.ownerID,
            policy: .automatic
        )
        await assertEventually {
            self.statusText(in: self.chooser(ownerID: fixture.ownerID))
                == "无法读取设备信息，请刷新后重试"
        }

        let window = try XCTUnwrap(chooser(ownerID: fixture.ownerID))
        let contentView = try XCTUnwrap(window.contentView)
        contentView.layoutSubtreeIfNeeded()
        let status = try XCTUnwrap(
            descendants(of: contentView)
                .compactMap { $0 as? NSTextField }
                .first { $0.stringValue.hasPrefix("无法读取设备信息") }
        )
        for contentWidth in [760.0, 920.0, 1_100.0] {
            window.setContentSize(NSSize(width: contentWidth, height: 600))
            status.stringValue = "短状态"
            contentView.layoutSubtreeIfNeeded()
            let originalWidth = window.frame.width
            status.stringValue = String(repeating: "很长的状态信息 ", count: 80)
            contentView.layoutSubtreeIfNeeded()

            let cancel = try XCTUnwrap(
                buttons(in: window).first { $0.title == "取消" }
            )
            let statusFrame = status.convert(status.bounds, to: contentView)
            let cancelFrame = cancel.convert(cancel.bounds, to: contentView)
            XCTAssertEqual(window.frame.width, originalWidth, accuracy: 0.5)
            XCTAssertGreaterThan(status.intrinsicContentSize.width, status.bounds.width)
            XCTAssertLessThanOrEqual(statusFrame.maxX, cancelFrame.minX - 8)
        }
        XCTAssertEqual(status.maximumNumberOfLines, 1)
        XCTAssertEqual(status.lineBreakMode, .byTruncatingTail)
        XCTAssertEqual(
            status.contentCompressionResistancePriority(for: .horizontal),
            .defaultLow
        )
        XCTAssertTrue(window.styleMask.contains(.resizable))
        window.close()
    }

    @MainActor
    func testDefaultSelectionSurvivesSameEpochInventoryMetadataUpdate() async throws {
        let fixture = try ResolverFixture(mapping: .missing)
        fixture.capture.emitOnStart = true
        let resolver = fixture.makeResolver()
        resolver.apply(fixture.inventory)
        resolver.openFirstOwner(
            target: fixture.target,
            ownerID: fixture.ownerID,
            policy: .forceChooser
        )
        await assertEventually {
            self.confirmButton(in: self.chooser(ownerID: fixture.ownerID))?.isEnabled
                == true
        }
        let captureStarts = fixture.capture.startCount
        let updated = try VideoSourceDescriptor(
            sourceID: fixture.source.sourceID,
            sourceEpoch: fixture.source.sourceEpoch,
            activeFormatWidth: 1_180,
            activeFormatHeight: 2_556,
            displayName: fixture.source.displayName,
            classification: fixture.source.classification
        )
        resolver.apply(try VideoSourceInventory(
            inventoryRevision: fixture.inventory.inventoryRevision + 1,
            sources: [updated]
        ))
        try await Task.sleep(for: .milliseconds(30))

        XCTAssertEqual(candidateButton(in: chooser(ownerID: fixture.ownerID))?.state, .on)
        XCTAssertEqual(fixture.capture.startCount, captureStarts)
        XCTAssertEqual(fixture.store.load(target: fixture.target), .missing)
        chooser(ownerID: fixture.ownerID)?.close()
    }

    @MainActor
    func testDisappearingSourceStopsPreviewAndRejectsLateFrame() async throws {
        let fixture = try ResolverFixture(mapping: .missing)
        let unexpectedHandoff = expectation(description: "stale frame rejected")
        unexpectedHandoff.isInverted = true
        let resolver = fixture.makeResolver(
            firstHandoff: { _, _, _ in unexpectedHandoff.fulfill() }
        )
        resolver.apply(fixture.inventory)
        resolver.openFirstOwner(
            target: fixture.target,
            ownerID: fixture.ownerID,
            policy: .forceChooser
        )
        await assertEventually {
            self.candidateButton(in: self.chooser(ownerID: fixture.ownerID)) != nil
        }
        candidateButton(in: chooser(ownerID: fixture.ownerID))?.performClick(nil)
        await assertEventually { fixture.capture.startCount == 2 }
        let empty = try VideoSourceInventory(inventoryRevision: 2, sources: [])
        resolver.apply(empty)
        await assertEventually {
            fixture.capture.stopCount == 2 && fixture.capture.activeCount == 0
        }
        fixture.capture.emit(at: 1)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(confirmButton(in: chooser(ownerID: fixture.ownerID))?.isEnabled ?? true)
        await fulfillment(of: [unexpectedHandoff], timeout: 0.1)
        chooser(ownerID: fixture.ownerID)?.close()
    }

    @MainActor
    func testThumbnailTimeoutRejectsLateFrameAndRefreshRetriesOnce() async throws {
        let fixture = try ResolverFixture(mapping: .missing)
        let bridge = ResolverRefreshBridge()
        let resolver = fixture.makeResolver(
            inventoryRefresh: { inventory in bridge.resolver?.apply(inventory) },
            inventoryRefreshProvider: { fixture.inventory },
            thumbnailTimeout: .milliseconds(30),
            videoAuthorizationStatus: { .authorized }
        )
        bridge.resolver = resolver
        resolver.apply(fixture.inventory)
        resolver.openFirstOwner(
            target: fixture.target,
            ownerID: fixture.ownerID,
            policy: .forceChooser
        )
        await assertEventually { fixture.capture.stopCount == 1 }
        fixture.capture.emit(at: 0)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(fixture.capture.startCount, 2)
        refreshButton(in: chooser(ownerID: fixture.ownerID))?.performClick(nil)
        await assertEventually { fixture.capture.startCount == 4 }
        chooser(ownerID: fixture.ownerID)?.close()
    }

    @MainActor
    func testRefreshImmediatelyFencesStaleTargetSnapshotCallback() async throws {
        let fixture = try ResolverFixture(mapping: .missing)
        fixture.capture.stopDelayNanoseconds = 150_000_000
        let staleFacts = ProductionLiveSourceTargetFacts(
            canonicalUDID: fixture.target,
            name: "Stale iPhone",
            osVersion: "26.4"
        )
        let freshFacts = ProductionLiveSourceTargetFacts(
            canonicalUDID: fixture.target,
            name: "Fresh iPhone",
            osVersion: "26.5"
        )
        let provider = ResolverRefreshSnapshotProviderBox(
            stale: ProductionLiveSourceTargetSnapshot(
                connectedTargets: [staleFacts],
                target: staleFacts
            ),
            fresh: ProductionLiveSourceTargetSnapshot(
                connectedTargets: [freshFacts],
                target: freshFacts
            )
        )
        let resolver = fixture.makeResolver(snapshotProvider: provider.load)
        resolver.apply(fixture.inventory)
        resolver.openFirstOwner(
            target: fixture.target,
            ownerID: fixture.ownerID,
            policy: .forceChooser
        )
        await assertEventually { provider.firstAttemptStarted }

        refreshButton(in: chooser(ownerID: fixture.ownerID))?.performClick(nil)
        provider.releaseFirstAttempt()
        await assertEventually { provider.firstAttemptReturned }
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(textValues(in: chooser(ownerID: fixture.ownerID))
            .contains { $0.contains("Stale iPhone") })

        await assertEventually(attempts: 100) {
            self.textValues(in: self.chooser(ownerID: fixture.ownerID))
                .contains { $0.contains("正在为 Fresh iPhone 选择视频源") }
        }
        chooser(ownerID: fixture.ownerID)?.close()
    }

    @MainActor
    func testThumbnailFirstFramePublishesFormatlessCandidateDimensions() async throws {
        let fixture = try ResolverFixture(
            mapping: .missing,
            sourceHasActiveFormat: false
        )
        fixture.capture.emitOnStart = true
        let resolver = fixture.makeResolver(
            thumbnailTimeout: .seconds(2),
            videoAuthorizationStatus: { .authorized }
        )
        resolver.apply(fixture.inventory)
        resolver.openFirstOwner(
            target: fixture.target,
            ownerID: fixture.ownerID,
            policy: .forceChooser
        )

        await assertEventually(attempts: 300) {
            self.candidateText(in: self.chooser(ownerID: fixture.ownerID))
                .contains("16x32")
        }
        XCTAssertFalse(
            candidateText(in: chooser(ownerID: fixture.ownerID))
                .contains("等待画面")
        )
        XCTAssertEqual(
            candidateImageView(in: chooser(ownerID: fixture.ownerID))?.imageScaling,
            .scaleProportionallyDown
        )

        fixture.capture.emitOnStart = false
        let replacement = try VideoSourceDescriptor(
            sourceID: fixture.source.sourceID,
            sourceEpoch: fixture.source.sourceEpoch + 1,
            activeFormatWidth: 0,
            activeFormatHeight: 0,
            displayName: fixture.source.displayName,
            classification: fixture.source.classification
        )
        resolver.apply(try VideoSourceInventory(
            inventoryRevision: fixture.inventory.inventoryRevision + 1,
            sources: [replacement]
        ))
        await assertEventually {
            self.candidateText(in: self.chooser(ownerID: fixture.ownerID))
                .contains("等待画面")
        }
        XCTAssertFalse(
            candidateText(in: chooser(ownerID: fixture.ownerID))
                .contains("16x32")
        )
        chooser(ownerID: fixture.ownerID)?.close()
    }

    @MainActor
    func testDeniedVideoAuthorizationShowsStatusWithoutStartingCapture() async throws {
        let fixture = try ResolverFixture(mapping: .missing)
        var settingsOpened = false
        let resolver = fixture.makeResolver(
            openCameraSettings: { settingsOpened = true },
            videoAuthorizationStatus: { .denied }
        )
        resolver.apply(fixture.inventory)
        resolver.openFirstOwner(
            target: fixture.target,
            ownerID: fixture.ownerID,
            policy: .forceChooser
        )

        await assertEventually {
            self.statusText(in: self.chooser(ownerID: fixture.ownerID))
                == "无法预览视频源：摄像头权限不可用"
        }
        XCTAssertEqual(fixture.capture.startCount, 0)
        cameraAuthorizationButton(in: chooser(ownerID: fixture.ownerID))?
            .performClick(nil)
        XCTAssertTrue(settingsOpened)
        chooser(ownerID: fixture.ownerID)?.close()
    }

    @MainActor
    func testNotDeterminedAuthorizationRequestsAccessAndStartsThumbnail() async throws {
        let fixture = try ResolverFixture(mapping: .missing)
        let authorization = ResolverAuthorizationBox(.notDetermined)
        let resolver = fixture.makeResolver(
            videoAuthorizationStatus: { authorization.status },
            videoAuthorizationRequest: { completion in
                authorization.status = .authorized
                authorization.requestCount += 1
                completion(true)
            }
        )
        resolver.apply(fixture.inventory)
        resolver.openFirstOwner(
            target: fixture.target,
            ownerID: fixture.ownerID,
            policy: .forceChooser
        )
        await assertEventually {
            self.cameraAuthorizationButton(
                in: self.chooser(ownerID: fixture.ownerID)
            )?.toolTip == "允许摄像头访问"
        }
        cameraAuthorizationButton(in: chooser(ownerID: fixture.ownerID))?
            .performClick(nil)

        await assertEventually { fixture.capture.startCount == 2 }
        XCTAssertEqual(authorization.requestCount, 1)
        chooser(ownerID: fixture.ownerID)?.close()
    }

    @MainActor
    func testFirstChooserCanContinueWithoutVideoAndWithoutWritingMapping() async throws {
        let fixture = try ResolverFixture(mapping: .missing)
        let handedOff = expectation(description: "blind live handed off")
        let resolver = fixture.makeResolver(
            videoAuthorizationStatus: { .denied },
            firstBlindHandoff: { target, ownerID, facts in
                XCTAssertEqual(target, fixture.target)
                XCTAssertEqual(ownerID, fixture.ownerID)
                XCTAssertEqual(facts.canonicalUDID, fixture.target)
                handedOff.fulfill()
            }
        )
        resolver.apply(fixture.inventory)
        resolver.openFirstOwner(
            target: fixture.target,
            ownerID: fixture.ownerID,
            policy: .forceChooser
        )
        await assertEventually {
            self.continueWithoutVideoButton(
                in: self.chooser(ownerID: fixture.ownerID)
            )?.isEnabled == true
        }
        continueWithoutVideoButton(in: chooser(ownerID: fixture.ownerID))?
            .performClick(nil)

        await fulfillment(of: [handedOff], timeout: 1)
        XCTAssertEqual(fixture.store.load(target: fixture.target), .missing)
        XCTAssertEqual(fixture.capture.startCount, 0)
    }

    @MainActor
    func testCancellingFirstChooserReleasesOwnerButExistingChooserKeepsLive() async throws {
        let first = try ResolverFixture(mapping: .missing)
        let released = expectation(description: "first owner released")
        let firstResolver = first.makeResolver(
            ownerCancelled: { target, ownerID in
                XCTAssertEqual(target, first.target)
                XCTAssertEqual(ownerID, first.ownerID)
                released.fulfill()
            }
        )
        firstResolver.openFirstOwner(
            target: first.target,
            ownerID: first.ownerID,
            policy: .forceChooser
        )
        chooser(ownerID: first.ownerID)?.close()
        await fulfillment(of: [released], timeout: 1)

        let existing = try ResolverFixture(mapping: .missing)
        let unexpectedRelease = expectation(description: "existing owner retained")
        unexpectedRelease.isInverted = true
        let existingResolver = existing.makeResolver(
            ownerCancelled: { _, _ in unexpectedRelease.fulfill() }
        )
        existingResolver.openForExistingLive(
            target: existing.target,
            ownerID: existing.ownerID
        )
        chooser(ownerID: existing.ownerID)?.close()
        await fulfillment(of: [unexpectedRelease], timeout: 0.1)
    }

    @MainActor
    func testWakeDeviceShowsForIOS17WithoutVideoSelectionAndReportsSuccess() async throws {
        let fixture = try ResolverFixture(mapping: .missing)
        let actions = ResolverWakeActionBox(
            homeResults: [.sent],
            prepareResults: []
        )
        let resolver = fixture.makeResolver(
            targetHomeAction: actions.submitHome,
            targetPrepareAction: actions.prepare,
            videoAuthorizationStatus: { .denied }
        )
        resolver.apply(fixture.inventory)
        resolver.openFirstOwner(
            target: fixture.target,
            ownerID: fixture.ownerID,
            policy: .forceChooser
        )

        await assertEventually {
            guard let button = self.wakeDeviceButton(
                in: self.chooser(ownerID: fixture.ownerID)
            ) else { return false }
            return !button.isHidden && button.isEnabled
        }
        XCTAssertEqual(
            candidateButton(in: chooser(ownerID: fixture.ownerID))?.state,
            .off
        )
        wakeDeviceButton(in: chooser(ownerID: fixture.ownerID))?.performClick(nil)

        await assertEventually {
            self.wakeResultText(in: self.chooser(ownerID: fixture.ownerID))
                == "已发送 Home"
        }
        let window = try XCTUnwrap(chooser(ownerID: fixture.ownerID))
        let content = try XCTUnwrap(window.contentView)
        content.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(wakeDeviceButton(in: window))
        let result = try XCTUnwrap(wakeResultLabel(in: window))
        XCTAssertEqual(result.alignment, .right)
        XCTAssertEqual(
            result.convert(result.bounds, to: content).maxX,
            button.convert(button.bounds, to: content).maxX,
            accuracy: 2.5
        )
        XCTAssertEqual(actions.homeCount, 1)
        XCTAssertEqual(actions.prepareCount, 0)
        chooser(ownerID: fixture.ownerID)?.close()
    }

    @MainActor
    func testWakeDevicePreparesOnceThenRetriesHome() async throws {
        let fixture = try ResolverFixture(mapping: .missing)
        let actions = ResolverWakeActionBox(
            homeResults: [.requiresPreparation, .sent],
            prepareResults: [.prepared]
        )
        let resolver = fixture.makeResolver(
            targetHomeAction: actions.submitHome,
            targetPrepareAction: actions.prepare
        )
        resolver.apply(fixture.inventory)
        resolver.openFirstOwner(
            target: fixture.target,
            ownerID: fixture.ownerID,
            policy: .forceChooser
        )

        await assertEventually {
            self.wakeDeviceButton(in: self.chooser(ownerID: fixture.ownerID))?
                .isEnabled == true
        }
        wakeDeviceButton(in: chooser(ownerID: fixture.ownerID))?.performClick(nil)

        await assertEventually {
            self.wakeResultText(in: self.chooser(ownerID: fixture.ownerID))
                == "已发送 Home"
        }
        XCTAssertEqual(actions.homeCount, 2)
        XCTAssertEqual(actions.prepareCount, 1)
        chooser(ownerID: fixture.ownerID)?.close()
    }

    @MainActor
    func testWakeDeviceCachesPrepareFailureForCurrentChooser() async throws {
        let fixture = try ResolverFixture(mapping: .missing)
        let actions = ResolverWakeActionBox(
            homeResults: [.requiresPreparation],
            prepareResults: [.failed(code: "serviceWarmupFailed")]
        )
        let resolver = fixture.makeResolver(
            targetHomeAction: actions.submitHome,
            targetPrepareAction: actions.prepare
        )
        resolver.apply(fixture.inventory)
        resolver.openFirstOwner(
            target: fixture.target,
            ownerID: fixture.ownerID,
            policy: .forceChooser
        )

        await assertEventually {
            self.wakeDeviceButton(in: self.chooser(ownerID: fixture.ownerID))?
                .isEnabled == true
        }
        wakeDeviceButton(in: chooser(ownerID: fixture.ownerID))?.performClick(nil)
        let expected = "Developer Support 准备失败：serviceWarmupFailed"
        await assertEventually {
            self.wakeResultText(in: self.chooser(ownerID: fixture.ownerID))
                == expected
        }
        wakeDeviceButton(in: chooser(ownerID: fixture.ownerID))?.performClick(nil)
        XCTAssertEqual(
            wakeResultText(in: chooser(ownerID: fixture.ownerID)),
            "Developer Support 准备此前失败：serviceWarmupFailed"
        )
        XCTAssertEqual(actions.homeCount, 1)
        XCTAssertEqual(actions.prepareCount, 1)
        chooser(ownerID: fixture.ownerID)?.close()
    }

    @MainActor
    private func chooser(ownerID: String) -> NSWindow? {
        NSApplication.shared.windows.first { $0.identifier?.rawValue == ownerID }
    }

    @MainActor
    private func candidateButton(in window: NSWindow?) -> NSButton? {
        buttons(in: window).first {
            $0.accessibilityLabel()?.contains("Test iPhone") == true
        }
    }

    @MainActor
    private func sourceCandidateButtons(in window: NSWindow?) -> [NSButton] {
        buttons(in: window).filter {
            $0.title.isEmpty
                && $0.accessibilityLabel()?.contains("iPhone") == true
        }
    }

    @MainActor
    private func candidateText(in window: NSWindow?) -> String {
        descendants(of: candidateButton(in: window))
            .compactMap { $0 as? NSTextField }
            .map(\.stringValue)
            .joined(separator: "\n")
    }

    @MainActor
    private func candidateImageView(in window: NSWindow?) -> NSImageView? {
        descendants(of: candidateButton(in: window))
            .compactMap { $0 as? NSImageView }
            .first
    }

    @MainActor
    private func confirmButton(in window: NSWindow?) -> NSButton? {
        buttons(in: window).first { $0.title == "使用此源" }
    }

    @MainActor
    private func refreshButton(in window: NSWindow?) -> NSButton? {
        buttons(in: window).first { $0.toolTip == "刷新视频源" }
    }

    @MainActor
    private func cameraAuthorizationButton(in window: NSWindow?) -> NSButton? {
        buttons(in: window).first {
            $0.toolTip == "允许摄像头访问"
                || $0.toolTip == "打开摄像头隐私设置"
        }
    }

    @MainActor
    private func continueWithoutVideoButton(in window: NSWindow?) -> NSButton? {
        buttons(in: window).first { $0.title == "继续，不显示画面" }
    }

    @MainActor
    private func wakeDeviceButton(in window: NSWindow?) -> NSButton? {
        buttons(in: window).first { $0.title == "唤醒设备" }
    }

    @MainActor
    private func wakeResultText(in window: NSWindow?) -> String? {
        wakeResultLabel(in: window)?.stringValue
    }

    @MainActor
    private func wakeResultLabel(in window: NSWindow?) -> NSTextField? {
        descendants(of: window?.contentView)
            .compactMap { $0 as? NSTextField }
            .first {
                $0.stringValue == "已发送 Home"
                    || $0.stringValue.hasPrefix("Developer Support 准备")
                    || $0.stringValue.hasPrefix("未发送 Home：")
            }
    }

    @MainActor
    private func buttons(in window: NSWindow?) -> [NSButton] {
        descendants(of: window?.contentView).compactMap { $0 as? NSButton }
    }

    @MainActor
    private func statusText(in window: NSWindow?) -> String? {
        textValues(in: window)
            .first { $0.hasPrefix("无法") }
    }

    @MainActor
    private func textValues(in window: NSWindow?) -> [String] {
        descendants(of: window?.contentView)
            .compactMap { $0 as? NSTextField }
            .map(\.stringValue)
    }

    @MainActor
    private func descendants(of root: NSView?) -> [NSView] {
        guard let root else { return [] }
        return [root] + root.subviews.flatMap { descendants(of: $0) }
    }

    @MainActor
    private func assertEventually(
        attempts: Int = 100,
        file: StaticString = #filePath,
        line: UInt = #line,
        _ predicate: @escaping @MainActor () -> Bool
    ) async {
        let result = await waitUntil(attempts: attempts, predicate)
        XCTAssertTrue(result, file: file, line: line)
    }

    @MainActor
    private func waitUntil(
        attempts: Int = 100,
        _ predicate: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<attempts {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return predicate()
    }
}

private enum ResolverTestError: Error {
    case factsUnavailable
}

private final class ResolverWakeActionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var homeResults: [ProductionLiveSourceWakeActionResult]
    private var prepareResults: [ProductionLiveSourcePrepareResult]
    private var storedHomeCount = 0
    private var storedPrepareCount = 0

    init(
        homeResults: [ProductionLiveSourceWakeActionResult],
        prepareResults: [ProductionLiveSourcePrepareResult]
    ) {
        self.homeResults = homeResults
        self.prepareResults = prepareResults
    }

    var homeCount: Int { lock.withLock { storedHomeCount } }
    var prepareCount: Int { lock.withLock { storedPrepareCount } }

    func submitHome(
        _ target: CanonicalUDID
    ) -> ProductionLiveSourceWakeActionResult {
        lock.withLock {
            storedHomeCount += 1
            return homeResults.isEmpty
                ? .failed(code: "internalFailure")
                : homeResults.removeFirst()
        }
    }

    func prepare(
        _ target: CanonicalUDID
    ) -> ProductionLiveSourcePrepareResult {
        lock.withLock {
            storedPrepareCount += 1
            return prepareResults.isEmpty
                ? .failed(code: "internalFailure")
                : prepareResults.removeFirst()
        }
    }
}

@MainActor
private final class ResolverRefreshBridge {
    weak var resolver: ProductionLiveSourceResolver?
}

private final class ResolverFixture: @unchecked Sendable {
    enum InitialMapping: Equatable {
        case cached
        case missing
    }

    let capture: ResolverCaptureHarness
    let inventory: VideoSourceInventory
    let otherTarget: CanonicalUDID
    let ownerID: String
    let snapshot: ProductionLiveSourceTargetSnapshot
    let source: VideoSourceDescriptor
    let store: ResolverMappingStore
    let target: CanonicalUDID

    init(
        mapping: InitialMapping,
        includeOtherTarget: Bool = false,
        includeSecondSource: Bool = false,
        sourceHasActiveFormat: Bool = true
    ) throws {
        target = try CanonicalUDID(canonicalString: "RESOLVER-TARGET-A")
        otherTarget = try CanonicalUDID(canonicalString: "RESOLVER-TARGET-B")
        ownerID = "resolver-\(UUID().uuidString.lowercased())"
        source = try VideoSourceDescriptor(
            sourceID: String(repeating: "a", count: 64),
            sourceEpoch: 7,
            activeFormatWidth: sourceHasActiveFormat ? 1_170 : 0,
            activeFormatHeight: sourceHasActiveFormat ? 2_532 : 0,
            displayName: "Test iPhone",
            classification: .qualifiedPhoneScreen
        )
        let secondSource = try VideoSourceDescriptor(
            sourceID: String(repeating: "b", count: 64),
            sourceEpoch: 8,
            activeFormatWidth: 1_170,
            activeFormatHeight: 2_532,
            displayName: "A Much Longer Secondary iPhone Video Source Name",
            classification: .qualifiedPhoneScreen
        )
        inventory = try VideoSourceInventory(
            inventoryRevision: 1,
            sources: includeSecondSource ? [source, secondSource] : [source]
        )
        store = ResolverMappingStore()
        if mapping == .cached {
            _ = try store.replace(
                target: target,
                sourceID: source.sourceID,
                proofKind: .operatorConfirmedPreview
            )
        }
        let current = ProductionLiveSourceTargetFacts(
            canonicalUDID: target,
            name: source.displayName,
            osVersion: "26.5"
        )
        let other = ProductionLiveSourceTargetFacts(
            canonicalUDID: otherTarget,
            name: "Other iPhone",
            osVersion: "26.5"
        )
        snapshot = ProductionLiveSourceTargetSnapshot(
            connectedTargets: includeOtherTarget ? [current, other] : [current],
            target: current
        )
        capture = try ResolverCaptureHarness()
    }

    @MainActor
    func makeResolver(
        productVersion: PulsePhoneProductVersion? = nil,
        snapshotProvider: ProductionLiveSourceResolver.TargetSnapshotProvider? = nil,
        activeBindingsProvider: @escaping ProductionLiveSourceResolver.ActiveBindingsProvider = {
            []
        },
        targetHomeAction: ProductionLiveSourceResolver.TargetHomeAction? = nil,
        targetPrepareAction: ProductionLiveSourceResolver.TargetPrepareAction? = nil,
        inventoryRefresh: @escaping ProductionLiveSourceResolver.InventoryRefresh = { _ in },
        inventoryRefreshProvider: (@Sendable () throws -> VideoSourceInventory)? = nil,
        probeTimeout: DispatchTimeInterval = .milliseconds(100),
        thumbnailTimeout: DispatchTimeInterval = .milliseconds(100),
        openCameraSettings: @escaping ProductionLiveSourceResolver.OpenCameraSettings = {},
        videoAuthorizationStatus: @escaping @Sendable () -> AVAuthorizationStatus = {
            .authorized
        },
        videoAuthorizationRequest: @escaping ProductionLiveSourceResolver.VideoAuthorizationRequest = {
            completion in completion(false)
        },
        firstHandoff: @escaping ProductionLiveSourceResolver.FirstHandoff = {
            _, _, _ in
        },
        firstBlindHandoff: @escaping ProductionLiveSourceResolver.FirstBlindHandoff = {
            _, _, _ in
        },
        existingHandoff: @escaping ProductionLiveSourceResolver.ExistingHandoff = {
            _, _, _ in
        },
        existingSourceRetained: @escaping ProductionLiveSourceResolver.ExistingSourceRetained = {
            _, _ in
        },
        ownerCancelled: @escaping ProductionLiveSourceResolver.OwnerCancelled = {
            _, _ in
        }
    ) -> ProductionLiveSourceResolver {
        ProductionLiveSourceResolver(
            catalog: ProductionAVFoundationVideoSourceCatalog(),
            mappingCoordinator: ProductionVideoSourceMappingCoordinator(store: store),
            productVersion: productVersion,
            presentsWindows: false,
            targetSnapshotProvider: snapshotProvider ?? { [snapshot] _ in snapshot },
            inventoryRefresh: inventoryRefresh,
            firstHandoff: firstHandoff,
            firstBlindHandoff: firstBlindHandoff,
            existingHandoff: existingHandoff,
            existingSourceRetained: existingSourceRetained,
            ownerCancelled: ownerCancelled,
            fenceTargets: { _ in },
            activeBindingsProvider: activeBindingsProvider,
            targetHomeAction: targetHomeAction,
            targetPrepareAction: targetPrepareAction,
            captureFactory: capture.factory,
            inventoryRefreshProvider: inventoryRefreshProvider ?? { [inventory] in
                inventory
            },
            probeTimeout: probeTimeout,
            thumbnailTimeout: thumbnailTimeout,
            targetSnapshotRetryDelaysNanoseconds: [
                5_000_000,
                5_000_000,
                5_000_000,
            ],
            openCameraSettings: openCameraSettings,
            videoAuthorizationStatus: videoAuthorizationStatus,
            videoAuthorizationRequest: videoAuthorizationRequest
        )
    }
}

private final class ResolverAuthorizationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequestCount = 0
    private var storedStatus: AVAuthorizationStatus

    init(_ status: AVAuthorizationStatus) {
        storedStatus = status
    }

    var requestCount: Int {
        get { lock.withLock { storedRequestCount } }
        set { lock.withLock { storedRequestCount = newValue } }
    }

    var status: AVAuthorizationStatus {
        get { lock.withLock { storedStatus } }
        set { lock.withLock { storedStatus = newValue } }
    }
}

private final class ResolverSnapshotProviderBox: @unchecked Sendable {
    private let lock = NSLock()
    private let snapshot: ProductionLiveSourceTargetSnapshot
    private var remainingFailures: Int
    private var storedAttemptCount = 0

    init(
        snapshot: ProductionLiveSourceTargetSnapshot,
        failuresBeforeSuccess: Int
    ) {
        self.snapshot = snapshot
        remainingFailures = failuresBeforeSuccess
    }

    var attemptCount: Int { lock.withLock { storedAttemptCount } }

    func load(_ target: CanonicalUDID) throws -> ProductionLiveSourceTargetSnapshot {
        try lock.withLock {
            storedAttemptCount += 1
            guard remainingFailures == 0 else {
                remainingFailures -= 1
                throw ResolverTestError.factsUnavailable
            }
            guard snapshot.target.canonicalUDID == target else {
                throw ResolverTestError.factsUnavailable
            }
            return snapshot
        }
    }
}

private final class ResolverSnapshotSequenceProviderBox: @unchecked Sendable {
    private let lock = NSLock()
    private let snapshots: [ProductionLiveSourceTargetSnapshot]
    private var storedAttemptCount = 0

    init(snapshots: [ProductionLiveSourceTargetSnapshot]) {
        precondition(!snapshots.isEmpty)
        self.snapshots = snapshots
    }

    var attemptCount: Int { lock.withLock { storedAttemptCount } }

    func load(_ target: CanonicalUDID) throws -> ProductionLiveSourceTargetSnapshot {
        try lock.withLock {
            let index = min(storedAttemptCount, snapshots.count - 1)
            storedAttemptCount += 1
            let snapshot = snapshots[index]
            guard snapshot.target.canonicalUDID == target else {
                throw ResolverTestError.factsUnavailable
            }
            return snapshot
        }
    }
}

private final class ResolverSerializedSnapshotProviderBox: @unchecked Sendable {
    private let firstAttemptGate = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let snapshot: ProductionLiveSourceTargetSnapshot
    private var activeAttempts = 0
    private var storedAttemptCount = 0
    private var storedMaximumConcurrentAttempts = 0

    init(snapshot: ProductionLiveSourceTargetSnapshot) {
        self.snapshot = snapshot
    }

    var attemptCount: Int { lock.withLock { storedAttemptCount } }
    var firstAttemptStarted: Bool { attemptCount > 0 }
    var maximumConcurrentAttempts: Int {
        lock.withLock { storedMaximumConcurrentAttempts }
    }

    func releaseFirstAttempt() { firstAttemptGate.signal() }

    func load(_ target: CanonicalUDID) throws -> ProductionLiveSourceTargetSnapshot {
        let attempt = lock.withLock { () -> Int in
            storedAttemptCount += 1
            activeAttempts += 1
            storedMaximumConcurrentAttempts = max(
                storedMaximumConcurrentAttempts,
                activeAttempts
            )
            return storedAttemptCount
        }
        defer { lock.withLock { activeAttempts -= 1 } }
        if attempt == 1 { firstAttemptGate.wait() }
        guard snapshot.target.canonicalUDID == target else {
            throw ResolverTestError.factsUnavailable
        }
        return snapshot
    }
}

private final class ResolverRefreshSnapshotProviderBox: @unchecked Sendable {
    private let fresh: ProductionLiveSourceTargetSnapshot
    private let lock = NSLock()
    private let releaseFirst = DispatchSemaphore(value: 0)
    private let stale: ProductionLiveSourceTargetSnapshot
    private var storedAttemptCount = 0
    private var storedFirstAttemptReturned = false

    init(
        stale: ProductionLiveSourceTargetSnapshot,
        fresh: ProductionLiveSourceTargetSnapshot
    ) {
        self.stale = stale
        self.fresh = fresh
    }

    var firstAttemptStarted: Bool { lock.withLock { storedAttemptCount > 0 } }
    var firstAttemptReturned: Bool { lock.withLock { storedFirstAttemptReturned } }

    func releaseFirstAttempt() { releaseFirst.signal() }

    func load(_ target: CanonicalUDID) throws -> ProductionLiveSourceTargetSnapshot {
        let attempt = lock.withLock { () -> Int in
            storedAttemptCount += 1
            return storedAttemptCount
        }
        guard attempt == 1 else {
            guard fresh.target.canonicalUDID == target else {
                throw ResolverTestError.factsUnavailable
            }
            return fresh
        }
        releaseFirst.wait()
        lock.withLock { storedFirstAttemptReturned = true }
        guard stale.target.canonicalUDID == target else {
            throw ResolverTestError.factsUnavailable
        }
        return stale
    }
}

private final class ResolverMappingStore:
    VideoSourceMappingStoring,
    @unchecked Sendable
{
    private let lock = NSLock()
    private var records = [CanonicalUDID: VideoSourceMappingRecordV2]()
    private var storedClearCount = 0
    private var storedLoadCount = 0
    private var storedReplaceCount = 0
    var forcedFailures = [CanonicalUDID: VideoSourceMappingStoreFailure]()

    var clearCount: Int { lock.withLock { storedClearCount } }
    var loadCount: Int { lock.withLock { storedLoadCount } }
    var replaceCount: Int { lock.withLock { storedReplaceCount } }

    func load(target: CanonicalUDID) -> VideoSourceMappingLoadResult {
        lock.withLock {
            storedLoadCount += 1
            if let failure = forcedFailures[target] { return .unavailable(failure) }
            return records[target].map {
                .mapped(.currentV2($0))
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
        lock.withLock {
            records[target] = record
            storedReplaceCount += 1
        }
        return record
    }

    func clear(target: CanonicalUDID) throws -> Bool {
        lock.withLock {
            storedClearCount += 1
            return records.removeValue(forKey: target) != nil
        }
    }
}

private final class ResolverCaptureHarness: @unchecked Sendable {
    private struct Attempt {
        let frame: AVFoundationVideoFrameSample
        let handler: ProductionAVFoundationVideoSourceCatalog.FrameHandler
        var started = false
        var stopped = false
    }

    private let lock = NSLock()
    private var attempts = [Attempt]()
    private var active = 0
    private var maximumActive = 0
    private var sampleBuffer: CMSampleBuffer
    var emitOnStart = false
    var stopDelayNanoseconds: UInt64 = 0

    init() throws {
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            16,
            32,
            kCVPixelFormatType_32BGRA,
            nil,
            &pixelBuffer
        ) == kCVReturnSuccess,
        let pixelBuffer
        else { throw ResolverTestError.factsUnavailable }
        var description: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &description
        ) == noErr,
        let description
        else { throw ResolverTestError.factsUnavailable }
        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: .zero,
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: description,
            sampleTiming: &timing,
            sampleBufferOut: &sample
        ) == noErr,
        let sample
        else { throw ResolverTestError.factsUnavailable }
        sampleBuffer = sample
    }

    var factory: ProductionLiveSourceResolver.CaptureFactory {
        { [self] sourceID, sourceEpoch, handler in
            let index = lock.withLock { () -> Int in
                let frame = AVFoundationVideoFrameSample(
                    sourceID: sourceID,
                    sourceEpoch: sourceEpoch,
                    frameSequence: 0,
                    delegateMonotonicNanoseconds: 1,
                    presentationWidth: 16,
                    presentationHeight: 32,
                    sampleBuffer: sampleBuffer
                )
                attempts.append(Attempt(frame: frame, handler: handler))
                return attempts.count - 1
            }
            return ProductionLiveSourceCaptureHandle(
                start: { [self] in start(index) },
                stop: { [self] in stop(index) }
            )
        }
    }

    var activeCount: Int { lock.withLock { active } }
    var maximumActiveCount: Int { lock.withLock { maximumActive } }
    var startCount: Int { lock.withLock { attempts.filter(\.started).count } }
    var stopCount: Int { lock.withLock { attempts.filter(\.stopped).count } }

    func emit(at index: Int) {
        let value = lock.withLock { () -> (
            ProductionAVFoundationVideoSourceCatalog.FrameHandler,
            AVFoundationVideoFrameSample
        )? in
            guard attempts.indices.contains(index) else { return nil }
            return (attempts[index].handler, attempts[index].frame)
        }
        if let value { value.0(fresh(value.1)) }
    }

    private func start(_ index: Int) {
        let emission = lock.withLock { () -> (
            ProductionAVFoundationVideoSourceCatalog.FrameHandler,
            AVFoundationVideoFrameSample
        )? in
            guard attempts.indices.contains(index), !attempts[index].started else {
                return nil
            }
            attempts[index].started = true
            active += 1
            maximumActive = max(maximumActive, active)
            guard emitOnStart else { return nil }
            return (attempts[index].handler, attempts[index].frame)
        }
        if let emission { emission.0(fresh(emission.1)) }
    }

    private func stop(_ index: Int) {
        if stopDelayNanoseconds > 0 {
            Thread.sleep(forTimeInterval: Double(stopDelayNanoseconds) / 1_000_000_000)
        }
        lock.withLock {
            guard attempts.indices.contains(index), !attempts[index].stopped else {
                return
            }
            attempts[index].stopped = true
            if attempts[index].started { active -= 1 }
        }
    }

    private func fresh(
        _ sample: AVFoundationVideoFrameSample
    ) -> AVFoundationVideoFrameSample {
        AVFoundationVideoFrameSample(
            sourceID: sample.sourceID,
            sourceEpoch: sample.sourceEpoch,
            frameSequence: sample.frameSequence,
            delegateMonotonicNanoseconds: SystemMonotonicClock().now().nanoseconds,
            presentationWidth: sample.presentationWidth,
            presentationHeight: sample.presentationHeight,
            sampleBuffer: sample.sampleBuffer
        )
    }
}
