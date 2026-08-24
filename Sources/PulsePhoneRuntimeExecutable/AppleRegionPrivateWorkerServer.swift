import Darwin
import Foundation
import PulsePhoneAppleRegionBridge
import PulsePhoneElement

enum AppleRegionPrivateWorkerServer {
    static func run() -> Int32 {
        signal(SIGPIPE, SIG_IGN)
        var bridgeStatus: Int32 = 0
        let bridge = PPAppleRegionBridgeCreate(&bridgeStatus)
        defer { PPAppleRegionBridgeDestroy(bridge) }
        let available = bridge != nil
            && bridgeStatus == PPAppleRegionBridgeStatusSucceeded
        do {
            try send(.hello(
                outcome: available ? .succeeded : .unavailable,
                backend: AppleRegionWorkerMessage.expectedBackend,
                version: AppleRegionWorkerMessage.expectedVersion,
                errorCode: available ? nil : errorCode(bridgeStatus)
            ))
            while let payload = try AppleRegionWorkerStream.readFrame(
                descriptor: STDIN_FILENO,
                maximumBytes: AppleRegionWorkerMessage.maximumRequestFrameBytes
            ) {
                let request = try AppleRegionWorkerCodec.decode(
                    payload,
                    maximumBytes: AppleRegionWorkerMessage.maximumRequestFrameBytes
                )
                if request.type == .shutdown { return EX_OK }
                guard request.type == .detect,
                      let requestID = request.requestID,
                      let imageData = request.imageData,
                      let inputWidth = request.inputWidth,
                      let inputHeight = request.inputHeight
                else { return EX_DATAERR }
                guard let bridge else {
                    try send(.result(
                        requestID: requestID,
                        outcome: .failed,
                        elapsedMilliseconds: 0,
                        errorCode: "capabilityUnavailable"
                    ))
                    continue
                }
                let started = ContinuousClock.now
                var rawRegions: UnsafeMutablePointer<PPAppleDetectedRegion>?
                var regionCount = 0
                let status = imageData.withUnsafeBytes { bytes in
                    PPAppleRegionBridgeDetect(
                        bridge,
                        bytes.bindMemory(to: UInt8.self).baseAddress,
                        bytes.count,
                        inputWidth,
                        inputHeight,
                        &rawRegions,
                        &regionCount
                    )
                }
                defer { PPAppleRegionBridgeFreeRegions(rawRegions) }
                guard status == PPAppleRegionBridgeStatusSucceeded,
                      regionCount <= AppleRegionWorkerMessage.maximumRegions
                else {
                    try send(.result(
                        requestID: requestID,
                        outcome: .failed,
                        elapsedMilliseconds: elapsedMilliseconds(since: started),
                        errorCode: errorCode(status)
                    ))
                    continue
                }
                var regions = [AppleRegionWorkerRegion]()
                regions.reserveCapacity(regionCount)
                if let rawRegions {
                    for index in 0..<regionCount {
                        let region = rawRegions[index]
                        regions.append(AppleRegionWorkerRegion(
                            x: region.x,
                            y: region.y,
                            width: region.width,
                            height: region.height,
                            detectionType: region.detectionType
                        ))
                    }
                }
                try send(.result(
                    requestID: requestID,
                    outcome: .succeeded,
                    elapsedMilliseconds: elapsedMilliseconds(since: started),
                    regions: regions
                ))
            }
            return EX_OK
        } catch {
            return EX_PROTOCOL
        }
    }

    private static func send(_ message: AppleRegionWorkerMessage) throws {
        try AppleRegionWorkerStream.writeFrame(
            descriptor: STDOUT_FILENO,
            payload: AppleRegionWorkerCodec.encode(message)
        )
    }

    private static func errorCode(_ status: Int32) -> String {
        switch Int(status) {
        case PPAppleRegionBridgeStatusFrameworkUnavailable:
            return "frameworkUnavailable"
        case PPAppleRegionBridgeStatusCapabilityUnavailable:
            return "capabilityUnavailable"
        case PPAppleRegionBridgeStatusInvalidImage:
            return "invalidImage"
        case PPAppleRegionBridgeStatusInvalidResult:
            return "invalidResult"
        case PPAppleRegionBridgeStatusException:
            return "privateException"
        case PPAppleRegionBridgeStatusAllocationFailed:
            return "allocationFailed"
        default:
            return "privateFailure"
        }
    }

    private static func elapsedMilliseconds(
        since started: ContinuousClock.Instant
    ) -> UInt64 {
        let duration = started.duration(to: .now)
        let seconds = max(0, duration.components.seconds)
        let milliseconds = max(0, duration.components.attoseconds)
            / 1_000_000_000_000_000
        let base = UInt64(seconds).multipliedReportingOverflow(by: 1_000)
        guard !base.overflow else { return 60_000 }
        return min(60_000, base.partialValue + UInt64(milliseconds))
    }
}
