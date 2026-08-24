import AVFoundation
import CoreMedia
import CoreMediaIO
import Foundation
import OSLog
import PulsePhoneSharedDefinitions

public enum AVFoundationVideoSourceError: Error, Equatable, Sendable {
    case authorizationUnavailable
    case captureConfigurationFailed
    case duplicateSourceID
    case invalidActiveFormat
    case inventoryCapacityExceeded
    case sourceEpochMismatch
    case sourceUnavailable
}

public struct AVFoundationVideoSourceObservation: Equatable, Sendable {
    public let activeFormatHeight: UInt64
    public let activeFormatWidth: UInt64
    public let classification: VideoSourceClassification
    public let displayName: String
    public let sourceID: String

    public init(
        sourceID: String,
        activeFormatWidth: UInt64,
        activeFormatHeight: UInt64,
        displayName: String = "Video Source",
        classification: VideoSourceClassification = .residual
    ) throws {
        guard !sourceID.isEmpty else {
            throw AVFoundationVideoSourceError.sourceUnavailable
        }
        guard (activeFormatWidth == 0) == (activeFormatHeight == 0) else {
            throw AVFoundationVideoSourceError.invalidActiveFormat
        }
        let displayNameBytes = Array(displayName.utf8)
        guard (1...256).contains(displayNameBytes.count),
              !displayName.unicodeScalars.contains(where: {
                  CharacterSet.controlCharacters.contains($0)
              })
        else {
            throw AVFoundationVideoSourceError.sourceUnavailable
        }
        self.sourceID = sourceID
        self.activeFormatWidth = activeFormatWidth
        self.activeFormatHeight = activeFormatHeight
        self.displayName = displayName
        self.classification = classification
    }
}

public struct AVFoundationVideoSourceInventoryTracker: Sendable {
    private struct CurrentSource: Equatable, Sendable {
        let observation: AVFoundationVideoSourceObservation
        let sourceEpoch: UInt64
    }

    private var currentBySourceID = [String: CurrentSource]()
    private var inventoryRevision: UInt64 = 0
    private var nextSourceEpoch: UInt64 = 1

    public init() {}

    public mutating func refresh(
        observations: [AVFoundationVideoSourceObservation]
    ) throws -> VideoSourceInventory {
        guard observations.count <= 64 else {
            throw AVFoundationVideoSourceError.inventoryCapacityExceeded
        }
        let sourceIDs = observations.map(\.sourceID)
        guard Set(sourceIDs).count == sourceIDs.count else {
            throw AVFoundationVideoSourceError.duplicateSourceID
        }
        guard inventoryRevision < UInt64.max else {
            throw AVFoundationVideoSourceError.sourceEpochMismatch
        }
        inventoryRevision += 1

        var next = [String: CurrentSource]()
        for observation in observations.sorted(by: Self.sourceOrder) {
            let sourceEpoch: UInt64
            if let current = currentBySourceID[observation.sourceID],
               current.observation == observation
            {
                sourceEpoch = current.sourceEpoch
            } else {
                guard nextSourceEpoch < UInt64.max else {
                    throw AVFoundationVideoSourceError.sourceEpochMismatch
                }
                sourceEpoch = nextSourceEpoch
                nextSourceEpoch += 1
            }
            next[observation.sourceID] = CurrentSource(
                observation: observation,
                sourceEpoch: sourceEpoch
            )
        }
        currentBySourceID = next
        return try VideoSourceInventory(
            inventoryRevision: inventoryRevision,
            sources: next.values.map { current in
                try VideoSourceDescriptor(
                    sourceID: current.observation.sourceID,
                    sourceEpoch: current.sourceEpoch,
                    activeFormatWidth: current.observation.activeFormatWidth,
                    activeFormatHeight: current.observation.activeFormatHeight,
                    displayName: current.observation.displayName,
                    classification: current.observation.classification
                )
            }
        )
    }

    public func currentEpoch(for sourceID: String) -> UInt64? {
        currentBySourceID[sourceID]?.sourceEpoch
    }

    private static func sourceOrder(
        _ lhs: AVFoundationVideoSourceObservation,
        _ rhs: AVFoundationVideoSourceObservation
    ) -> Bool {
        lhs.sourceID.utf8.lexicographicallyPrecedes(rhs.sourceID.utf8)
    }
}

public struct AVFoundationMediaFormatIdentity: Equatable, Sendable {
    public let mediaSubtype: UInt32
    public let mediaType: UInt32

    public init(mediaType: UInt32, mediaSubtype: UInt32) {
        self.mediaType = mediaType
        self.mediaSubtype = mediaSubtype
    }
}

public struct AVFoundationVideoSourceClassificationFacts: Equatable, Sendable {
    public let activeFormat: AVFoundationMediaFormatIdentity
    public let availableFormats: [AVFoundationMediaFormatIdentity]
    public let deviceType: String
    public let hasMuxedMedia: Bool
    public let manufacturer: String?

    public init(
        deviceType: String,
        hasMuxedMedia: Bool,
        manufacturer: String?,
        activeFormat: AVFoundationMediaFormatIdentity,
        availableFormats: [AVFoundationMediaFormatIdentity]
    ) {
        self.deviceType = deviceType
        self.hasMuxedMedia = hasMuxedMedia
        self.manufacturer = manufacturer
        self.activeFormat = activeFormat
        self.availableFormats = availableFormats
    }
}

public enum AVFoundationVideoSourceClassifier {
    public static let embeddedScreenRecordingMediaSubtype = UInt32(
        kCMMuxedStreamType_EmbeddedDeviceScreenRecording
    )
    public static let muxedMediaType = UInt32(kCMMediaType_Muxed)

    public static func classify(
        _ facts: AVFoundationVideoSourceClassificationFacts
    ) -> VideoSourceClassification {
        let knownNonPhoneTypes = Set([
            AVCaptureDevice.DeviceType.builtInWideAngleCamera.rawValue,
            AVCaptureDevice.DeviceType.continuityCamera.rawValue,
            AVCaptureDevice.DeviceType.deskViewCamera.rawValue,
        ])
        if knownNonPhoneTypes.contains(facts.deviceType) {
            return .knownNonPhone
        }
        let embeddedScreen = AVFoundationMediaFormatIdentity(
            mediaType: muxedMediaType,
            mediaSubtype: embeddedScreenRecordingMediaSubtype
        )
        guard facts.deviceType == AVCaptureDevice.DeviceType.external.rawValue,
              facts.hasMuxedMedia,
              facts.manufacturer == "Apple Inc.",
              facts.activeFormat == embeddedScreen,
              facts.availableFormats.contains(embeddedScreen)
        else {
            return .residual
        }
        return .qualifiedPhoneScreen
    }
}

public final class AVFoundationVideoFrameSample: @unchecked Sendable {
    public let delegateMonotonicNanoseconds: UInt64
    public let frameSequence: UInt64
    public let presentationHeight: UInt64
    public let presentationWidth: UInt64
    public let sampleBuffer: CMSampleBuffer
    public let sourceEpoch: UInt64
    public let sourceID: String

    public var activeFormatHeight: UInt64 { presentationHeight }
    public var activeFormatWidth: UInt64 { presentationWidth }

    init(
        sourceID: String,
        sourceEpoch: UInt64,
        frameSequence: UInt64,
        delegateMonotonicNanoseconds: UInt64,
        presentationWidth: UInt64,
        presentationHeight: UInt64,
        sampleBuffer: CMSampleBuffer
    ) {
        self.sourceID = sourceID
        self.sourceEpoch = sourceEpoch
        self.frameSequence = frameSequence
        self.delegateMonotonicNanoseconds = delegateMonotonicNanoseconds
        self.presentationWidth = presentationWidth
        self.presentationHeight = presentationHeight
        self.sampleBuffer = sampleBuffer
    }
}

enum AVFoundationVideoPresentationDimensions {
    static func resolve(
        _ description: CMVideoFormatDescription
    ) -> (width: UInt64, height: UInt64)? {
        let presentation = CMVideoFormatDescriptionGetPresentationDimensions(
            description,
            usePixelAspectRatio: true,
            useCleanAperture: true
        )
        if let width = positiveInteger(presentation.width),
           let height = positiveInteger(presentation.height)
        {
            return (width, height)
        }

        let encoded = CMVideoFormatDescriptionGetDimensions(description)
        guard encoded.width > 0, encoded.height > 0 else { return nil }
        return (UInt64(encoded.width), UInt64(encoded.height))
    }

    private static func positiveInteger(_ value: CGFloat) -> UInt64? {
        let value = Double(value)
        guard value.isFinite, value > 0, value <= Double(UInt64.max) else {
            return nil
        }
        let rounded = value.rounded(.toNearestOrAwayFromZero)
        guard rounded > 0, rounded <= Double(UInt64.max) else { return nil }
        return UInt64(rounded)
    }
}

public final class ProductionAVFoundationVideoSourceCatalog: @unchecked Sendable {
    public typealias FrameHandler = @Sendable (
        AVFoundationVideoFrameSample
    ) -> Void
    public typealias AudioHandler = @Sendable (CMSampleBuffer) -> Void
    public typealias InventoryHandler = @Sendable (VideoSourceInventory) -> Void

    private static let sourceIdentityDomain = "pulsephone.av-source.v1"
    private static let audioDeviceLogger = Logger(
        subsystem: "com.pulsephone.PulsePhone",
        category: "audio-device"
    )
    private let lock = NSLock()
    private var cmioListener: CMIOObjectPropertyListenerBlock?
    private var devicesBySourceID = [String: AVCaptureDevice]()
    private var inventoryHandler: InventoryHandler?
    private var monitorGeneration: UInt64 = 0
    private var monitorNotificationTokens = [NSObjectProtocol]()
    private let monitorQueue = DispatchQueue(
        label: "dev.pulsephone.video.inventory",
        qos: .userInitiated
    )
    private let monitorQueueKey = DispatchSpecificKey<UInt8>()
    private var monitorRefreshScheduled = false
    private var monitorTimer: DispatchSourceTimer?
    private var tracker = AVFoundationVideoSourceInventoryTracker()

    public init() {
        monitorQueue.setSpecific(key: monitorQueueKey, value: 1)
    }

    public func refresh() throws -> VideoSourceInventory {
        Self.enableScreenCaptureDevices()
        return try refreshCurrentSnapshot()
    }

    public func makeCapture(
        sourceID: String,
        sourceEpoch: UInt64,
        frameHandler: @escaping FrameHandler,
        audioHandler: AudioHandler? = nil
    ) throws -> ProductionAVFoundationVideoCapture {
        lock.lock()
        defer { lock.unlock() }
        guard tracker.currentEpoch(for: sourceID) == sourceEpoch else {
            throw AVFoundationVideoSourceError.sourceEpochMismatch
        }
        guard let device = devicesBySourceID[sourceID] else {
            throw AVFoundationVideoSourceError.sourceUnavailable
        }
        let audioDevice = Self.audioDevice(for: device)
        Self.audioDeviceLogger.notice(
            "video=\(device.localizedName, privacy: .public) videoID=\(device.uniqueID, privacy: .public) audio=\(audioDevice?.localizedName ?? "none", privacy: .public) audioID=\(audioDevice?.uniqueID ?? "none", privacy: .public)"
        )
        return ProductionAVFoundationVideoCapture(
            device: device,
            audioDevice: audioDevice,
            sourceID: sourceID,
            sourceEpoch: sourceEpoch,
            frameHandler: frameHandler,
            audioHandler: audioHandler
        )
    }

    func hasExternalOrMuxedDevice() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return devicesBySourceID.values.contains { device in
            device.hasMediaType(.muxed) || device.deviceType == .external
        }
    }

    public func startMonitoring(
        inventoryHandler: @escaping InventoryHandler
    ) {
        monitorQueue.async { [weak self] in
            guard let self else { return }
            stopMonitoringOnQueue()
            self.inventoryHandler = inventoryHandler
            Self.enableScreenCaptureDevices()
            installCMIOListenerOnQueue()
            installAVFoundationObserversOnQueue()
            installFallbackTimerOnQueue()
            scheduleInventoryRefreshOnQueue()
        }
    }

    public func stopMonitoring() {
        if DispatchQueue.getSpecific(key: monitorQueueKey) != nil {
            stopMonitoringOnQueue()
        } else {
            monitorQueue.sync { [self] in
                stopMonitoringOnQueue()
            }
        }
    }

    private func scheduleInventoryRefreshOnQueue() {
        guard !monitorRefreshScheduled,
              let handler = inventoryHandler
        else { return }
        monitorRefreshScheduled = true
        let generation = monitorGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let inventory = try? self.refreshCurrentSnapshot()
            self.monitorQueue.async { [weak self] in
                guard let self,
                      monitorGeneration == generation
                else { return }
                monitorRefreshScheduled = false
                guard inventoryHandler != nil, let inventory else { return }
                handler(inventory)
            }
        }
    }

    private func installCMIOListenerOnQueue() {
        var address = Self.cmioDevicesPropertyAddress()
        let listener: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleInventoryRefreshOnQueue()
        }
        guard CMIOObjectAddPropertyListenerBlock(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            monitorQueue,
            listener
        ) == noErr else { return }
        cmioListener = listener
    }

    private func installAVFoundationObserversOnQueue() {
        let center = NotificationCenter.default
        monitorNotificationTokens = [
            AVCaptureDevice.wasConnectedNotification,
            AVCaptureDevice.wasDisconnectedNotification,
        ].map { name in
            center.addObserver(
                forName: name,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.monitorQueue.async { [weak self] in
                    self?.scheduleInventoryRefreshOnQueue()
                }
            }
        }
    }

    private func installFallbackTimerOnQueue() {
        let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
        timer.schedule(
            deadline: .now() + .seconds(2),
            repeating: .seconds(2),
            leeway: .milliseconds(250)
        )
        timer.setEventHandler { [weak self] in
            self?.scheduleInventoryRefreshOnQueue()
        }
        monitorTimer = timer
        timer.activate()
    }

    private func stopMonitoringOnQueue() {
        monitorGeneration = monitorGeneration == UInt64.max
            ? 1
            : monitorGeneration + 1
        monitorRefreshScheduled = false
        monitorTimer?.cancel()
        monitorTimer = nil
        let center = NotificationCenter.default
        for token in monitorNotificationTokens {
            center.removeObserver(token)
        }
        monitorNotificationTokens.removeAll()
        if let listener = cmioListener {
            var address = Self.cmioDevicesPropertyAddress()
            _ = CMIOObjectRemovePropertyListenerBlock(
                CMIOObjectID(kCMIOObjectSystemObject),
                &address,
                monitorQueue,
                listener
            )
            cmioListener = nil
        }
        inventoryHandler = nil
    }

    deinit {
        stopMonitoring()
    }

    private static func sourceID(for uniqueID: String) throws -> String {
        try StableBytes.domainSeparatedSHA256Hex(
            domainID: sourceIdentityDomain,
            payload: Array(uniqueID.utf8)
        )
    }

    private static func enableScreenCaptureDevices() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(
                kCMIOHardwarePropertyAllowScreenCaptureDevices
            ),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var allow: UInt32 = 1
        _ = CMIOObjectSetPropertyData(
            CMIOObjectID(kCMIOObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<UInt32>.size),
            &allow
        )
    }

    private static func cmioDevicesPropertyAddress(
    ) -> CMIOObjectPropertyAddress {
        CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
    }

    static func discoverDevices() -> [AVCaptureDevice] {
        enableScreenCaptureDevices()
        return discoverDeviceSnapshot()
    }

    private func refreshCurrentSnapshot() throws -> VideoSourceInventory {
        let devices = Self.discoverDeviceSnapshot()
        var observations = [AVFoundationVideoSourceObservation]()
        var refreshedDevices = [String: AVCaptureDevice]()
        for device in devices {
            let dimensions = CMVideoFormatDescriptionGetDimensions(
                device.activeFormat.formatDescription
            )
            guard dimensions.width >= 0, dimensions.height >= 0 else {
                continue
            }
            let sourceID = try Self.sourceID(for: device.uniqueID)
            guard refreshedDevices[sourceID] == nil else { continue }
            observations.append(try AVFoundationVideoSourceObservation(
                sourceID: sourceID,
                activeFormatWidth: UInt64(dimensions.width),
                activeFormatHeight: UInt64(dimensions.height),
                displayName: device.localizedName,
                classification: Self.classification(for: device)
            ))
            refreshedDevices[sourceID] = device
        }
        lock.lock()
        defer { lock.unlock() }
        let inventory = try tracker.refresh(observations: observations)
        devicesBySourceID = refreshedDevices
        return inventory
    }

    private static func classification(
        for device: AVCaptureDevice
    ) -> VideoSourceClassification {
        let active = device.activeFormat.formatDescription
        return AVFoundationVideoSourceClassifier.classify(
            AVFoundationVideoSourceClassificationFacts(
                deviceType: device.deviceType.rawValue,
                hasMuxedMedia: device.hasMediaType(.muxed),
                manufacturer: device.manufacturer,
                activeFormat: AVFoundationMediaFormatIdentity(
                    mediaType: UInt32(CMFormatDescriptionGetMediaType(active)),
                    mediaSubtype: UInt32(CMFormatDescriptionGetMediaSubType(active))
                ),
                availableFormats: device.formats.map { format in
                    let description = format.formatDescription
                    return AVFoundationMediaFormatIdentity(
                        mediaType: UInt32(CMFormatDescriptionGetMediaType(description)),
                        mediaSubtype: UInt32(CMFormatDescriptionGetMediaSubType(description))
                    )
                }
            )
        )
    }

    private static func audioDevice(
        for videoDevice: AVCaptureDevice
    ) -> AVCaptureDevice? {
        let discovered = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        ).devices
        let legacy = AVCaptureDevice.devices(for: .audio)
        var devices = [AVCaptureDevice]()
        var seen = Set<String>()
        for device in discovered + legacy {
            guard seen.insert(device.uniqueID).inserted else { continue }
            devices.append(device)
        }

        let videoFamily = deviceFamilyKey(videoDevice)
        if let match = devices.first(where: { device in
            deviceFamilyKey(device) == videoFamily
        }) {
            return match
        }
        if let match = devices.first(where: { device in
            normalizedDeviceName(device.localizedName)
                == normalizedDeviceName(videoDevice.localizedName)
        }) {
            return match
        }
        let externalMicrophones = devices.filter { device in
            !device.uniqueID.hasPrefix("BuiltIn")
        }
        return externalMicrophones.count == 1 ? externalMicrophones[0] : nil
    }

    private static func deviceFamilyKey(_ device: AVCaptureDevice) -> String {
        let identifier = device.uniqueID
        guard identifier.count > 2 else { return identifier }
        return String(identifier.dropLast(2))
    }

    private static func normalizedDeviceName(_ name: String) -> String {
        var value = name.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: .current
        )
        for token in [
            "camera", "microphone", "相机", "麦克风", "摄像头"
        ] {
            value = value.replacingOccurrences(of: token, with: "")
        }
        return value
            .replacingOccurrences(of: "的", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func discoverDeviceSnapshot() -> [AVCaptureDevice] {
        let discovered = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .external,
                .continuityCamera,
                .deskViewCamera,
                .builtInWideAngleCamera,
            ],
            mediaType: nil,
            position: .unspecified
        ).devices
        let direct = directCMIODeviceUniqueIDs().compactMap {
            AVCaptureDevice(uniqueID: $0)
        }

        // On current macOS, list APIs can omit an iOS screen device that remains
        // present in the public CMIO graph and resolvable by its device UID.
        return mergeDiscoveredDevices(
            discovered: discovered,
            legacy: AVCaptureDevice.devices(),
            direct: direct,
            uniqueID: \.uniqueID
        ) { device in
            device.hasMediaType(.video)
                || device.hasMediaType(.muxed)
                || device.deviceType == .external
        }
    }

    static func mergeDiscoveredDevices<Device>(
        discovered: [Device],
        legacy: [Device],
        direct: [Device] = [],
        uniqueID: KeyPath<Device, String>,
        isEligible: (Device) -> Bool
    ) -> [Device] {
        var seen = Set<String>()
        return (discovered + legacy + direct).filter { device in
            guard isEligible(device) else { return false }
            return seen.insert(device[keyPath: uniqueID]).inserted
        }
    }

    private static func directCMIODeviceUniqueIDs() -> [String] {
        var devicesAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var dataSize: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(
            CMIOObjectID(kCMIOObjectSystemObject),
            &devicesAddress,
            0,
            nil,
            &dataSize
        ) == noErr,
        dataSize.isMultiple(of: UInt32(MemoryLayout<CMIODeviceID>.size))
        else { return [] }
        let count = Int(dataSize) / MemoryLayout<CMIODeviceID>.size
        guard count <= 64 else { return [] }
        var devices = [CMIODeviceID](repeating: 0, count: count)
        var dataUsed: UInt32 = 0
        let deviceStatus = devices.withUnsafeMutableBytes { buffer in
            CMIOObjectGetPropertyData(
                CMIOObjectID(kCMIOObjectSystemObject),
                &devicesAddress,
                0,
                nil,
                dataSize,
                &dataUsed,
                buffer.baseAddress
            )
        }
        guard deviceStatus == noErr, dataUsed == dataSize else { return [] }

        return devices.compactMap { deviceID in
            var uidAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(
                    kCMIODevicePropertyDeviceUID
                ),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(
                    kCMIOObjectPropertyElementMain
                )
            )
            var value: CFString?
            var used: UInt32 = 0
            let status = withUnsafeMutablePointer(to: &value) { pointer in
                CMIOObjectGetPropertyData(
                    deviceID,
                    &uidAddress,
                    0,
                    nil,
                    UInt32(MemoryLayout<CFString?>.size),
                    &used,
                    pointer
                )
            }
            guard status == noErr,
                  used == UInt32(MemoryLayout<CFString?>.size),
                  let value
            else { return nil }
            return value as String
        }.sorted { lhs, rhs in
            lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
        }
    }
}

public final class ProductionAVFoundationVideoCapture:
    NSObject,
    AVCaptureAudioDataOutputSampleBufferDelegate,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    @unchecked Sendable
{
    private static let audioLogger = Logger(
        subsystem: "com.pulsephone.PulsePhone",
        category: "audio-preview"
    )
    static let preferredDecodedPixelFormats: [OSType] = [
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_32BGRA,
    ]

    private let audioHandler: ProductionAVFoundationVideoSourceCatalog.AudioHandler?
    private let audioOutput = AVCaptureAudioDataOutput()
    private var audioOutputConfigured = false
    private let audioQueue = DispatchQueue(
        label: "dev.pulsephone.audio.frames",
        qos: .userInteractive
    )
    private let audioQueueKey = DispatchSpecificKey<UInt8>()
    private let audioDevice: AVCaptureDevice?
    private let deviceUniqueID: String
    private let frameHandler: ProductionAVFoundationVideoSourceCatalog.FrameHandler
    private let frameQueue = DispatchQueue(
        label: "dev.pulsephone.video.frames",
        qos: .userInteractive
    )
    private let frameQueueKey = DispatchSpecificKey<UInt8>()
    private var frameSequence: UInt64 = 0
    private var audioSampleCount: UInt64 = 0
    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(
        label: "dev.pulsephone.video.session",
        qos: .userInitiated
    )
    private let sourceEpoch: UInt64
    private let sourceID: String
    private let videoOutput = AVCaptureVideoDataOutput()

    fileprivate init(
        device: AVCaptureDevice,
        audioDevice: AVCaptureDevice?,
        sourceID: String,
        sourceEpoch: UInt64,
        frameHandler: @escaping ProductionAVFoundationVideoSourceCatalog.FrameHandler,
        audioHandler: ProductionAVFoundationVideoSourceCatalog.AudioHandler?
    ) {
        self.deviceUniqueID = device.uniqueID
        self.audioDevice = audioDevice
        self.sourceID = sourceID
        self.sourceEpoch = sourceEpoch
        self.frameHandler = frameHandler
        self.audioHandler = audioHandler
        super.init()
        audioQueue.setSpecific(key: audioQueueKey, value: 1)
        frameQueue.setSpecific(key: frameQueueKey, value: 1)
    }

    public var hasAudioOutput: Bool {
        sessionQueue.sync {
            audioHandler != nil
                && (audioDevice != nil || audioOutputConfigured)
                && AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        }
    }

    public var audioDeviceUniqueID: String? {
        audioDevice?.uniqueID
    }

    public var isRunning: Bool {
        sessionQueue.sync { session.isRunning }
    }

    public func start() throws {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw AVFoundationVideoSourceError.authorizationUnavailable
        }
        try sessionQueue.sync {
            try configureSessionLocked()
            session.startRunning()
            guard session.isRunning else {
                throw AVFoundationVideoSourceError.captureConfigurationFailed
            }
        }
    }

    public func reconfigure(
        shouldRestart: @escaping @Sendable () -> Bool
    ) throws -> Bool {
        guard AVCaptureDevice.authorizationStatus(for: .video) == .authorized else {
            throw AVFoundationVideoSourceError.authorizationUnavailable
        }
        return try sessionQueue.sync {
            if session.isRunning { session.stopRunning() }
            videoOutput.setSampleBufferDelegate(nil, queue: nil)
            audioOutput.setSampleBufferDelegate(nil, queue: nil)
            frameQueue.sync {}
            audioQueue.sync {}
            try configureSessionLocked()
            guard shouldRestart() else { return false }
            session.startRunning()
            guard session.isRunning else {
                throw AVFoundationVideoSourceError.captureConfigurationFailed
            }
            return true
        }
    }

    public func stop() {
        sessionQueue.sync {
            if session.isRunning { session.stopRunning() }
            videoOutput.setSampleBufferDelegate(nil, queue: nil)
            audioOutput.setSampleBufferDelegate(nil, queue: nil)
            audioOutputConfigured = false
        }
        if DispatchQueue.getSpecific(key: frameQueueKey) == nil {
            frameQueue.sync {}
        }
        if DispatchQueue.getSpecific(key: audioQueueKey) == nil {
            audioQueue.sync {}
        }
    }

    private func configureSessionLocked() throws {
        guard let device = AVCaptureDevice(uniqueID: deviceUniqueID) else {
            throw AVFoundationVideoSourceError.sourceUnavailable
        }
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        for input in session.inputs { session.removeInput(input) }
        for output in session.outputs { session.removeOutput(output) }
        audioOutputConfigured = false
        session.sessionPreset = .high

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw AVFoundationVideoSourceError.captureConfigurationFailed
        }
        guard session.canAddInput(input) else {
            throw AVFoundationVideoSourceError.captureConfigurationFailed
        }
        session.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.setSampleBufferDelegate(self, queue: frameQueue)
        guard session.canAddOutput(videoOutput) else {
            throw AVFoundationVideoSourceError.captureConfigurationFailed
        }
        session.addOutput(videoOutput)
        guard let pixelFormat = Self.preferredDecodedPixelFormat(
            available: videoOutput.availableVideoPixelFormatTypes
        ) else {
            throw AVFoundationVideoSourceError.captureConfigurationFailed
        }
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: pixelFormat,
        ]
        if audioDevice == nil,
           audioHandler != nil,
           AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
           session.canAddOutput(audioOutput)
        {
            audioOutput.setSampleBufferDelegate(self, queue: audioQueue)
            session.addOutput(audioOutput)
            audioOutputConfigured = true
        }
        let audioMode = audioDevice == nil
            ? "muxed-session"
            : "external-device"
        let audioOutputIsConfigured = audioOutputConfigured
        Self.audioLogger.notice(
            "stage=capture-config audioMode=\(audioMode, privacy: .public) audioOutputConfigured=\(audioOutputIsConfigured, privacy: .public)"
        )
    }

    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        if output === audioOutput {
            guard CMSampleBufferIsValid(sampleBuffer) else { return }
            audioSampleCount += 1
            if audioSampleCount == 1 {
                Self.audioLogger.notice(
                    "stage=capture-sample outcome=received samples=\(CMSampleBufferGetNumSamples(sampleBuffer), privacy: .public)"
                )
            }
            audioHandler?(sampleBuffer)
            return
        }
        guard CMSampleBufferIsValid(sampleBuffer), frameSequence < UInt64.max,
              let description = CMSampleBufferGetFormatDescription(sampleBuffer)
        else { return }
        guard let dimensions = AVFoundationVideoPresentationDimensions.resolve(
            description
        ) else { return }
        let sequence = frameSequence
        frameSequence += 1
        frameHandler(AVFoundationVideoFrameSample(
            sourceID: sourceID,
            sourceEpoch: sourceEpoch,
            frameSequence: sequence,
            delegateMonotonicNanoseconds: SystemMonotonicClock().now().nanoseconds,
            presentationWidth: dimensions.width,
            presentationHeight: dimensions.height,
            sampleBuffer: sampleBuffer
        ))
    }

    static func preferredDecodedPixelFormat(
        available: [OSType]
    ) -> OSType? {
        for preferred in preferredDecodedPixelFormats
        where available.contains(preferred) {
            return preferred
        }
        return available.first
    }

    deinit {
        stop()
    }
}
