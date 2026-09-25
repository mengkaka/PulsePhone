@preconcurrency import AVFoundation
import CoreMedia
import Foundation

enum ProductionSampleBufferDisplay {
    static func presentationAgeMicroseconds(
        _ sampleBuffer: CMSampleBuffer,
        hostTime: CMTime = CMClockGetTime(CMClockGetHostTimeClock())
    ) -> UInt64? {
        let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard presentationTime.isValid,
              presentationTime.isNumeric,
              hostTime.isValid,
              hostTime.isNumeric
        else { return nil }
        let seconds = CMTimeGetSeconds(CMTimeSubtract(hostTime, presentationTime))
        guard seconds.isFinite, seconds >= 0,
              seconds <= Double(UInt64.max) / 1_000_000
        else { return nil }
        return UInt64(seconds * 1_000_000)
    }

    static func makeImmediateDisplayCopy(
        _ sampleBuffer: CMSampleBuffer
    ) -> CMSampleBuffer? {
        var displaySample: CMSampleBuffer?
        guard CMSampleBufferCreateCopy(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleBufferOut: &displaySample
        ) == noErr,
        let displaySample,
        prepareForImmediateDisplay(displaySample)
        else { return nil }
        return displaySample
    }

    @discardableResult
    private static func prepareForImmediateDisplay(
        _ sampleBuffer: CMSampleBuffer
    ) -> Bool {
        guard let rawAttachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer,
            createIfNecessary: true
        ) else { return false }
        let attachments = rawAttachments as NSArray
        guard attachments.count > 0 else { return false }
        let mutableAttachments = attachments.compactMap {
            $0 as? NSMutableDictionary
        }
        guard mutableAttachments.count == attachments.count else { return false }
        for attachment in mutableAttachments {
            attachment[kCMSampleAttachmentKey_DisplayImmediately] = kCFBooleanTrue
        }
        return true
    }

    static func enqueue(
        _ sampleBuffer: CMSampleBuffer,
        on displayLayer: AVSampleBufferDisplayLayer
    ) {
        guard let displaySample = makeImmediateDisplayCopy(sampleBuffer) else {
            return
        }
        if displayLayer.status == .failed {
            displayLayer.flushAndRemoveImage()
        }
        displayLayer.enqueue(displaySample)
    }
}
