import AppKit
import AVFoundation
import Darwin
import Foundation
import PulsePhoneMedia
import PulsePhoneSharedDefinitions

public enum ProductionVideoSourceHandoffEntrypoint {
    public static let inventoryRoleArgument = "--video-source-inventory-v1"
    public static let probeRoleArgument = "--video-source-probe-v1"

    private static let maximumSources = 64

    public static func handles(_ arguments: [String]) -> Bool {
        arguments.first == inventoryRoleArgument
            || arguments.first == probeRoleArgument
    }

    public static func run(arguments: [String]) -> Int32 {
        if arguments.first == inventoryRoleArgument {
            guard Thread.isMainThread else { return 70 }
            return MainActor.assumeIsolated {
                let application = NSApplication.shared
                application.setActivationPolicy(.accessory)
                application.finishLaunching()
                return runInventory(
                    arguments: arguments,
                    inventoryProvider: {
                        try ProductionAVFoundationVideoSourceCatalog().refresh()
                    },
                    authorizationStatusProvider: {
                        AVCaptureDevice.authorizationStatus(for: .video)
                    }
                )
            }
        }
        guard arguments.first == probeRoleArgument else { return 64 }
        do {
            let request = try parseProbe(arguments)
            guard Thread.isMainThread else { return 70 }
            return try MainActor.assumeIsolated {
                try runProbe(request)
            }
        } catch {
            return 64
        }
    }

    static func runInventory(
        arguments: [String],
        inventoryProvider: () throws -> VideoSourceInventory,
        authorizationStatusProvider: () -> AVAuthorizationStatus = { .authorized }
    ) -> Int32 {
        do {
            let request = try parseInventory(arguments)
            let output = try validateOutputDescriptor(request.outputDescriptor)
            let inventory = try inventoryProvider()
            guard inventory.sources.count <= maximumSources else {
                throw HandoffError.invalid
            }
            let sources: [[String: Any]] = try inventory.sources.map { source in
                guard validHash(source.sourceID) else {
                    throw HandoffError.invalid
                }
                return [
                    "activeFormatHeight": source.activeFormatHeight,
                    "activeFormatWidth": source.activeFormatWidth,
                    "sourceEpoch": source.sourceEpoch,
                    "sourceID": source.sourceID,
                ]
            }
            let bytes = try canonicalJSON([
                "candidateInputHash": request.candidateInputHash,
                "inventoryRevision": inventory.inventoryRevision,
                "schemaVersion": 1,
                "sessionNonce": request.sessionNonce,
                "sources": sources,
                "videoAuthorizationStatus": authorizationStatus(
                    authorizationStatusProvider()
                ),
            ])
            try writeAll(bytes, to: output.descriptor)
            return 0
        } catch {
            return 64
        }
    }

    private struct InventoryRequest {
        let candidateInputHash: String
        let outputDescriptor: Int32
        let sessionNonce: String
    }

    private struct ProbeRequest {
        let sourceEpoch: UInt64
        let sourceID: String
        let timeoutMilliseconds: UInt64
    }

    private struct OutputDescriptor {
        let descriptor: Int32
    }

    private enum HandoffError: Error {
        case invalid
    }

    private static func parseInventory(_ arguments: [String]) throws -> InventoryRequest {
        let values = try parsePairs(
            arguments,
            role: inventoryRoleArgument,
            allowed: [
                "--video-source-inventory-candidate-input-hash",
                "--video-source-inventory-fd",
                "--video-source-inventory-session-nonce",
            ]
        )
        guard values.count == 3,
              let candidateInputHash = values[
                "--video-source-inventory-candidate-input-hash"
              ],
              let descriptorValue = values["--video-source-inventory-fd"],
              let sessionNonce = values[
                "--video-source-inventory-session-nonce"
              ],
              validHash(candidateInputHash),
              validLowercaseHex(sessionNonce, byteCount: 16),
              let descriptor = Int32(descriptorValue),
              descriptor >= 3
        else { throw HandoffError.invalid }
        return InventoryRequest(
            candidateInputHash: candidateInputHash,
            outputDescriptor: descriptor,
            sessionNonce: sessionNonce
        )
    }

    private static func parseProbe(_ arguments: [String]) throws -> ProbeRequest {
        let values = try parsePairs(
            arguments,
            role: probeRoleArgument,
            allowed: [
                "--video-source-epoch",
                "--video-source-id",
                "--video-source-probe-timeout-ms",
            ]
        )
        guard values.count == 3,
              let sourceID = values["--video-source-id"],
              validHash(sourceID),
              let sourceEpochValue = values["--video-source-epoch"],
              let sourceEpoch = UInt64(sourceEpochValue),
              sourceEpoch > 0,
              let timeoutValue = values["--video-source-probe-timeout-ms"],
              let timeout = UInt64(timeoutValue),
              (1_000...120_000).contains(timeout)
        else { throw HandoffError.invalid }
        return ProbeRequest(
            sourceEpoch: sourceEpoch,
            sourceID: sourceID,
            timeoutMilliseconds: timeout
        )
    }

    private static func parsePairs(
        _ arguments: [String],
        role: String,
        allowed: Set<String>
    ) throws -> [String: String] {
        guard arguments.first == role else { throw HandoffError.invalid }
        let pairs = Array(arguments.dropFirst())
        guard pairs.count.isMultiple(of: 2) else { throw HandoffError.invalid }
        var values = [String: String]()
        var index = 0
        while index < pairs.count {
            let key = pairs[index]
            guard allowed.contains(key), values[key] == nil else {
                throw HandoffError.invalid
            }
            values[key] = pairs[index + 1]
            index += 2
        }
        return values
    }

    private static func validateOutputDescriptor(
        _ descriptor: Int32
    ) throws -> OutputDescriptor {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_uid == geteuid(),
              metadata.st_nlink == 1,
              metadata.st_size == 0,
              metadata.st_mode & mode_t(0o777) == mode_t(0o600),
              lseek(descriptor, 0, SEEK_CUR) == 0
        else { throw HandoffError.invalid }
        let status = fcntl(descriptor, F_GETFL)
        guard status >= 0,
              status & O_ACCMODE == O_WRONLY,
              status & (O_APPEND | O_NONBLOCK) == 0
        else { throw HandoffError.invalid }
        let flags = fcntl(descriptor, F_GETFD)
        guard flags >= 0,
              fcntl(descriptor, F_SETFD, flags | FD_CLOEXEC) == 0
        else { throw HandoffError.invalid }
        return OutputDescriptor(descriptor: descriptor)
    }

    private static func canonicalJSON(_ object: [String: Any]) throws -> [UInt8] {
        guard JSONSerialization.isValidJSONObject(object) else {
            throw HandoffError.invalid
        }
        let bytes = [UInt8](try JSONSerialization.data(
            withJSONObject: object,
            options: [.sortedKeys, .withoutEscapingSlashes]
        ))
        _ = try RepositoryCanonicalJSON.validateCanonicalDocument(
            bytes,
            maximumByteCount: EvidenceContractHardCaps.otherCanonicalDocumentBytes
        )
        return bytes
    }

    private static func writeAll(_ bytes: [UInt8], to descriptor: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { buffer in
                Darwin.write(
                    descriptor,
                    buffer.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
            }
            if count > 0 {
                offset += count
                continue
            }
            if count < 0, errno == EINTR { continue }
            throw HandoffError.invalid
        }
        guard fsync(descriptor) == 0 else { throw HandoffError.invalid }
    }

    private static func validHash(_ value: String) -> Bool {
        validLowercaseHex(value, byteCount: 32)
    }

    private static func authorizationStatus(
        _ status: AVAuthorizationStatus
    ) -> String {
        switch status {
        case .authorized: "authorized"
        case .denied: "denied"
        case .notDetermined: "notDetermined"
        case .restricted: "restricted"
        @unknown default: "unknown"
        }
    }

    private static func validLowercaseHex(
        _ value: String,
        byteCount: Int
    ) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == byteCount * 2 && bytes.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    @MainActor
    private static func runProbe(_ request: ProbeRequest) throws -> Int32 {
        let catalog = ProductionAVFoundationVideoSourceCatalog()
        let inventory = try catalog.refresh()
        guard inventory.sources.contains(where: {
            $0.sourceID == request.sourceID
                && $0.sourceEpoch == request.sourceEpoch
        }) else { throw HandoffError.invalid }

        let sink = ProductionVideoSourceProbeSink()
        let capture = try catalog.makeCapture(
            sourceID: request.sourceID,
            sourceEpoch: request.sourceEpoch,
            frameHandler: sink.receive
        )
        let controller = ProductionVideoSourceProbeWindowController(
            sourceID: request.sourceID,
            displayLayer: sink.displayLayer
        )
        let application = NSApplication.shared
        application.setActivationPolicy(.regular)
        application.finishLaunching()
        controller.showWindow(nil)
        try capture.start()
        DispatchQueue.main.asyncAfter(
            deadline: .now() + .milliseconds(Int(request.timeoutMilliseconds))
        ) {
            application.terminate(nil)
        }
        application.run()
        capture.stop()
        return sink.frameCount > 0 ? 0 : 69
    }
}

private final class ProductionVideoSourceProbeSink: @unchecked Sendable {
    let displayLayer = AVSampleBufferDisplayLayer()

    private var frames: UInt64 = 0
    private let lock = NSLock()

    var frameCount: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return frames
    }

    init() {
        displayLayer.videoGravity = .resizeAspect
    }

    func receive(_ sample: AVFoundationVideoFrameSample) {
        lock.lock()
        if frames < UInt64.max { frames += 1 }
        lock.unlock()
        DispatchQueue.main.async { [self] in
            ProductionSampleBufferDisplay.enqueue(
                sample.sampleBuffer,
                on: displayLayer
            )
        }
    }
}

@MainActor
private final class ProductionVideoSourceProbeWindowController:
    NSWindowController,
    NSWindowDelegate
{
    init(sourceID: String, displayLayer: AVSampleBufferDisplayLayer) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 430, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PulsePhone Video Source Probe"
        let content = NSView(frame: window.contentView?.bounds ?? .zero)
        let video = NSView(frame: content.bounds)
        video.translatesAutoresizingMaskIntoConstraints = false
        video.wantsLayer = true
        video.layer = displayLayer
        let label = NSTextField(labelWithString: "Opaque source: \(sourceID)")
        label.alignment = .center
        label.lineBreakMode = .byTruncatingMiddle
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textColor = .secondaryLabelColor
        content.addSubview(video)
        content.addSubview(label)
        NSLayoutConstraint.activate([
            video.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            video.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            video.topAnchor.constraint(equalTo: content.topAnchor),
            video.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            label.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            label.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])
        window.contentView = content
        window.center()
        super.init(window: window)
        window.delegate = self
    }

    required init?(coder: NSCoder) {
        nil
    }

    func windowWillClose(_ notification: Notification) {
        NSApplication.shared.terminate(nil)
    }
}
