import AVFoundation
import Foundation

final class AudioPreviewPCMPlayer {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let playbackFormat: AVAudioFormat
    private var converter: AVAudioConverter?
    private var converterInputFormat: AVAudioFormat?

    init() throws {
        guard let playbackFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 2,
            interleaved: false
        ) else { throw AudioPreviewPlaybackError.invalidFormat }
        self.playbackFormat = playbackFormat
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        engine.prepare()
        do {
            try engine.start()
        } catch {
            throw AudioPreviewPlaybackError.engineStartFailed
        }
        player.play()
    }

    func stop() {
        player.stop()
        engine.stop()
        converter = nil
        converterInputFormat = nil
    }

    func enqueue(sampleBuffer: CMSampleBuffer) {
        guard let formatDescription = CMSampleBufferGetFormatDescription(
            sampleBuffer
        ),
              let streamDescription =
                CMAudioFormatDescriptionGetStreamBasicDescription(
                    formatDescription
                ),
              let format = AVAudioFormat(
                  streamDescription: streamDescription
              )
        else { return }
        let frameCount = AVAudioFrameCount(CMSampleBufferGetNumSamples(sampleBuffer))
        guard frameCount > 0,
              let buffer = AVAudioPCMBuffer(
                  pcmFormat: format,
                  frameCapacity: frameCount
              )
        else { return }
        buffer.frameLength = frameCount
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            sampleBuffer,
            at: 0,
            frameCount: Int32(frameCount),
            into: buffer.mutableAudioBufferList
        )
        guard status == noErr else { return }

        let inputDescription = format.streamDescription.pointee
        let previousDescription = converterInputFormat?.streamDescription.pointee
        let inputFormatChanged = previousDescription?.mSampleRate != inputDescription.mSampleRate
            || previousDescription?.mChannelsPerFrame != inputDescription.mChannelsPerFrame
            || previousDescription?.mFormatID != inputDescription.mFormatID
            || previousDescription?.mFormatFlags != inputDescription.mFormatFlags
            || previousDescription?.mBytesPerFrame != inputDescription.mBytesPerFrame
            || previousDescription?.mBytesPerPacket != inputDescription.mBytesPerPacket
            || previousDescription?.mBitsPerChannel != inputDescription.mBitsPerChannel
        if converter == nil || inputFormatChanged {
            converter = AVAudioConverter(from: format, to: playbackFormat)
            converterInputFormat = format
        }
        guard let converter else { return }

        let outputCapacity = AVAudioFrameCount(
            ceil(Double(frameCount) * playbackFormat.sampleRate / format.sampleRate)
        ) + 32
        guard let playbackBuffer = AVAudioPCMBuffer(
            pcmFormat: playbackFormat,
            frameCapacity: outputCapacity
        ) else { return }

        var supplied = false
        var conversionError: NSError?
        let conversionStatus = converter.convert(
            to: playbackBuffer,
            error: &conversionError
        ) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard conversionError == nil,
              conversionStatus == .haveData || conversionStatus == .inputRanDry,
              playbackBuffer.frameLength > 0
        else { return }
        player.scheduleBuffer(playbackBuffer)
    }
}

private enum AudioPreviewPlaybackError: Error {
    case engineStartFailed
    case invalidFormat
}

private final class AudioPreviewCaptureDelegate:
    NSObject,
    AVCaptureAudioDataOutputSampleBufferDelegate
{
    private let player: AudioPreviewPCMPlayer

    init(player: AudioPreviewPCMPlayer) {
        self.player = player
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        player.enqueue(sampleBuffer: sampleBuffer)
    }
}

public enum AudioPreviewHelperProcessEntrypoint {
    public static let roleArgument = "--audio-preview-helper"

    public static func handles(_ arguments: [String]) -> Bool {
        arguments.first == roleArgument
    }

    public static func run(arguments: [String]) -> Int32 {
        guard arguments.count == 2,
              let device = AVCaptureDevice(uniqueID: arguments[1]),
              let input = try? AVCaptureDeviceInput(device: device)
        else { return 64 }

        let captureSession = AVCaptureSession()
        let audioOutput = AVCaptureAudioDataOutput()
        guard let player = try? AudioPreviewPCMPlayer() else { return 70 }
        let delegate = AudioPreviewCaptureDelegate(player: player)
        let audioQueue = DispatchQueue(
            label: "dev.pulsephone.audio.preview.helper",
            qos: .userInteractive
        )

        captureSession.beginConfiguration()
        guard captureSession.canAddInput(input),
              captureSession.canAddOutput(audioOutput)
        else { return 70 }
        captureSession.addInput(input)
        audioOutput.setSampleBufferDelegate(delegate, queue: audioQueue)
        captureSession.addOutput(audioOutput)
        captureSession.commitConfiguration()

        captureSession.startRunning()
        guard captureSession.isRunning else { return 70 }

        // Keep the helper alive while AVCapture delivers buffers on its queue.
        // A bare RunLoop has no input source here and can return immediately.
        dispatchMain()
    }
}
