import Darwin
import Foundation
import PulsePhoneSharedDefinitions

public enum VideoSourceMappingPathV1 {
    public static let targetDomainID = "pulsephone.video-mapping-target.v1"

    public static func targetPathKey(for target: CanonicalUDID) -> String {
        do {
            return try StableBytes.domainSeparatedSHA256Hex(
                domainID: targetDomainID,
                payload: target.rawValue.utf8
            )
        } catch {
            preconditionFailure("video mapping target domain must remain ASCII")
        }
    }

    public static func fileName(for target: CanonicalUDID) -> String {
        "\(targetPathKey(for: target)).v1.json"
    }
}

public enum VideoSourceMappingPathV2 {
    public static func fileName(for target: CanonicalUDID) -> String {
        "\(VideoSourceMappingPathV1.targetPathKey(for: target)).v2.json"
    }
}

public enum VideoSourceMappingProofKind: String, Equatable, Sendable {
    case operatorConfirmedPreview = "operatorConfirmedPreview.v1"
    case singleConnectedTargetSource = "singleConnectedTargetSource.v1"
}

public enum VideoSourceMappingRecordError: Error, Equatable, Sendable {
    case invalidCanonicalDocument
    case invalidInitialCanvasDimensions
    case invalidProofKind
    case invalidSchemaVersion
    case invalidSourceID
    case invalidSourceIdentityDomain
    case invalidTargetPathKey
    case unexpectedFieldSet
}

public struct VideoSourceMappingRecordV1: Equatable, Sendable {
    public static let maximumByteCount = 4_096
    public static let proofKind = "operatorConfirmedPreview.v1"
    public static let schemaVersion: UInt64 = 1
    public static let sourceIdentityDomain = "pulsephone.av-source.v1"

    public let sourceID: String
    public let targetPathKey: String

    public init(target: CanonicalUDID, sourceID: String) throws {
        let targetPathKey = VideoSourceMappingPathV1.targetPathKey(for: target)
        guard Self.isLowercaseHex(targetPathKey, count: 64) else {
            throw VideoSourceMappingRecordError.invalidTargetPathKey
        }
        guard Self.isLowercaseHex(sourceID, count: 64) else {
            throw VideoSourceMappingRecordError.invalidSourceID
        }
        self.sourceID = sourceID
        self.targetPathKey = targetPathKey
    }

    public var canonicalBytes: [UInt8] {
        let object = try! RepositoryJSONObject(members: [
            RepositoryJSONMember(
                key: "proofKind",
                value: .string(Self.proofKind)
            ),
            RepositoryJSONMember(
                key: "schemaVersion",
                value: .number(.uint64(Self.schemaVersion))
            ),
            RepositoryJSONMember(
                key: "sourceID",
                value: .string(sourceID)
            ),
            RepositoryJSONMember(
                key: "sourceIdentityDomain",
                value: .string(Self.sourceIdentityDomain)
            ),
            RepositoryJSONMember(
                key: "targetPathKey",
                value: .string(targetPathKey)
            ),
        ])
        return RepositoryCanonicalJSON.encodeDocument(object)
    }

    public static func decode(
        _ bytes: [UInt8],
        target: CanonicalUDID
    ) throws -> Self {
        let document: RepositoryCanonicalJSONDocument
        do {
            document = try RepositoryCanonicalJSON.validateCanonicalDocument(
                bytes,
                maximumByteCount: maximumByteCount
            )
        } catch {
            throw VideoSourceMappingRecordError.invalidCanonicalDocument
        }
        let required = Set([
            "proofKind", "schemaVersion", "sourceID",
            "sourceIdentityDomain", "targetPathKey",
        ])
        guard document.root.members.count == required.count,
              Set(document.root.members.map(\.key)) == required
        else {
            throw VideoSourceMappingRecordError.unexpectedFieldSet
        }
        guard let version = try? document.root["schemaVersion"]?
            .numberValue?.requireUInt64(),
              version == schemaVersion
        else {
            throw VideoSourceMappingRecordError.invalidSchemaVersion
        }
        guard document.root["proofKind"]?.stringValue == proofKind else {
            throw VideoSourceMappingRecordError.invalidProofKind
        }
        guard document.root["sourceIdentityDomain"]?.stringValue
                == sourceIdentityDomain
        else {
            throw VideoSourceMappingRecordError.invalidSourceIdentityDomain
        }
        guard document.root["targetPathKey"]?.stringValue
                == VideoSourceMappingPathV1.targetPathKey(for: target)
        else {
            throw VideoSourceMappingRecordError.invalidTargetPathKey
        }
        guard let sourceID = document.root["sourceID"]?.stringValue else {
            throw VideoSourceMappingRecordError.invalidSourceID
        }
        return try Self(target: target, sourceID: sourceID)
    }

    fileprivate static func isLowercaseHex(_ value: String, count: Int) -> Bool {
        let bytes = Array(value.utf8)
        return bytes.count == count && bytes.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }
}

public struct VideoSourceMappingRecordV2: Equatable, Sendable {
    public static let maximumInitialCanvasDimension: UInt64 = 65_535
    public static let maximumByteCount = 4_096
    public static let schemaVersion: UInt64 = 2
    public static let sourceIdentityDomain = "pulsephone.av-source.v1"

    public let proofKind: VideoSourceMappingProofKind
    public let initialCanvasHeight: UInt64?
    public let initialCanvasWidth: UInt64?
    public let sourceID: String
    public let targetPathKey: String

    public init(
        target: CanonicalUDID,
        sourceID: String,
        proofKind: VideoSourceMappingProofKind,
        initialCanvasWidth: UInt64? = nil,
        initialCanvasHeight: UInt64? = nil
    ) throws {
        let targetPathKey = VideoSourceMappingPathV1.targetPathKey(for: target)
        guard VideoSourceMappingRecordV1.isLowercaseHex(
            targetPathKey,
            count: 64
        ) else {
            throw VideoSourceMappingRecordError.invalidTargetPathKey
        }
        guard VideoSourceMappingRecordV1.isLowercaseHex(sourceID, count: 64) else {
            throw VideoSourceMappingRecordError.invalidSourceID
        }
        guard Self.validInitialCanvasDimensions(
            width: initialCanvasWidth,
            height: initialCanvasHeight
        ) else {
            throw VideoSourceMappingRecordError.invalidInitialCanvasDimensions
        }
        self.proofKind = proofKind
        self.initialCanvasHeight = initialCanvasHeight
        self.initialCanvasWidth = initialCanvasWidth
        self.sourceID = sourceID
        self.targetPathKey = targetPathKey
    }

    public var canonicalBytes: [UInt8] {
        var members = [
            RepositoryJSONMember(
                key: "proofKind",
                value: .string(proofKind.rawValue)
            ),
            RepositoryJSONMember(
                key: "schemaVersion",
                value: .number(.uint64(Self.schemaVersion))
            ),
            RepositoryJSONMember(key: "sourceID", value: .string(sourceID)),
            RepositoryJSONMember(
                key: "sourceIdentityDomain",
                value: .string(Self.sourceIdentityDomain)
            ),
            RepositoryJSONMember(
                key: "targetPathKey",
                value: .string(targetPathKey)
            ),
        ]
        if let initialCanvasWidth, let initialCanvasHeight {
            members.append(RepositoryJSONMember(
                key: "initialCanvasWidth",
                value: .number(.uint64(initialCanvasWidth))
            ))
            members.append(RepositoryJSONMember(
                key: "initialCanvasHeight",
                value: .number(.uint64(initialCanvasHeight))
            ))
        }
        let object = try! RepositoryJSONObject(members: members)
        return RepositoryCanonicalJSON.encodeDocument(object)
    }

    public static func decode(
        _ bytes: [UInt8],
        target: CanonicalUDID
    ) throws -> Self {
        let document: RepositoryCanonicalJSONDocument
        do {
            document = try RepositoryCanonicalJSON.validateCanonicalDocument(
                bytes,
                maximumByteCount: maximumByteCount
            )
        } catch {
            throw VideoSourceMappingRecordError.invalidCanonicalDocument
        }
        let required = Set([
            "proofKind", "schemaVersion", "sourceID",
            "sourceIdentityDomain", "targetPathKey",
        ])
        let initialCanvasFields = Set([
            "initialCanvasWidth", "initialCanvasHeight",
        ])
        let actual = Set(document.root.members.map(\.key))
        guard actual == required || actual == required.union(initialCanvasFields)
        else {
            throw VideoSourceMappingRecordError.unexpectedFieldSet
        }
        guard let version = try? document.root["schemaVersion"]?
            .numberValue?.requireUInt64(),
              version == schemaVersion
        else {
            throw VideoSourceMappingRecordError.invalidSchemaVersion
        }
        guard let proofValue = document.root["proofKind"]?.stringValue,
              let proofKind = VideoSourceMappingProofKind(rawValue: proofValue)
        else {
            throw VideoSourceMappingRecordError.invalidProofKind
        }
        guard document.root["sourceIdentityDomain"]?.stringValue
                == sourceIdentityDomain
        else {
            throw VideoSourceMappingRecordError.invalidSourceIdentityDomain
        }
        guard document.root["targetPathKey"]?.stringValue
                == VideoSourceMappingPathV1.targetPathKey(for: target)
        else {
            throw VideoSourceMappingRecordError.invalidTargetPathKey
        }
        guard let sourceID = document.root["sourceID"]?.stringValue else {
            throw VideoSourceMappingRecordError.invalidSourceID
        }
        let initialCanvasWidth: UInt64?
        let initialCanvasHeight: UInt64?
        if actual == required {
            initialCanvasWidth = nil
            initialCanvasHeight = nil
        } else {
            guard let width = try? document.root["initialCanvasWidth"]?
                .numberValue?.requireUInt64(),
                  let height = try? document.root["initialCanvasHeight"]?
                    .numberValue?.requireUInt64()
            else {
                throw VideoSourceMappingRecordError.invalidInitialCanvasDimensions
            }
            initialCanvasWidth = width
            initialCanvasHeight = height
        }
        return try Self(
            target: target,
            sourceID: sourceID,
            proofKind: proofKind,
            initialCanvasWidth: initialCanvasWidth,
            initialCanvasHeight: initialCanvasHeight
        )
    }

    private static func validInitialCanvasDimensions(
        width: UInt64?,
        height: UInt64?
    ) -> Bool {
        switch (width, height) {
        case (nil, nil):
            true
        case (.some(let width), .some(let height)):
            width > 0 && height > 0
                && width <= maximumInitialCanvasDimension
                && height <= maximumInitialCanvasDimension
                && width <= height
        default:
            false
        }
    }
}

public enum VideoSourceMappingRecord: Equatable, Sendable {
    case legacyV1(VideoSourceMappingRecordV1)
    case currentV2(VideoSourceMappingRecordV2)

    public var proofKind: VideoSourceMappingProofKind {
        switch self {
        case .legacyV1:
            .operatorConfirmedPreview
        case .currentV2(let record):
            record.proofKind
        }
    }

    public var sourceID: String {
        switch self {
        case .legacyV1(let record): record.sourceID
        case .currentV2(let record): record.sourceID
        }
    }

    public var initialCanvasDimensions: (width: UInt64, height: UInt64)? {
        guard case .currentV2(let record) = self,
              let width = record.initialCanvasWidth,
              let height = record.initialCanvasHeight
        else { return nil }
        return (width, height)
    }

    public var targetPathKey: String {
        switch self {
        case .legacyV1(let record): record.targetPathKey
        case .currentV2(let record): record.targetPathKey
        }
    }
}

public enum VideoSourceMappingStoreFailure: String, Error, Equatable, Sendable {
    case capacityExceeded
    case corruptRecord
    case ioFailure
    case unsafeHostState
}

public enum VideoSourceMappingLoadResult: Equatable, Sendable {
    case mapped(VideoSourceMappingRecord)
    case missing
    case unavailable(VideoSourceMappingStoreFailure)
}

public protocol VideoSourceMappingStoring: AnyObject, Sendable {
    func load(target: CanonicalUDID) -> VideoSourceMappingLoadResult
    @discardableResult
    func replace(
        target: CanonicalUDID,
        sourceID: String,
        proofKind: VideoSourceMappingProofKind,
        initialCanvasWidth: UInt64?,
        initialCanvasHeight: UInt64?
    ) throws -> VideoSourceMappingRecordV2
    @discardableResult
    func clear(target: CanonicalUDID) throws -> Bool
}

public extension VideoSourceMappingStoring {
    @discardableResult
    func replace(
        target: CanonicalUDID,
        sourceID: String,
        proofKind: VideoSourceMappingProofKind
    ) throws -> VideoSourceMappingRecordV2 {
        try replace(
            target: target,
            sourceID: sourceID,
            proofKind: proofKind,
            initialCanvasWidth: nil,
            initialCanvasHeight: nil
        )
    }

    @discardableResult
    func replace(
        target: CanonicalUDID,
        sourceID: String
    ) throws -> VideoSourceMappingRecordV2 {
        try replace(
            target: target,
            sourceID: sourceID,
            proofKind: .operatorConfirmedPreview,
            initialCanvasWidth: nil,
            initialCanvasHeight: nil
        )
    }
}

public final class ProductionVideoSourceMappingStore:
    VideoSourceMappingStoring,
    @unchecked Sendable
{
    public static let maximumRecordCount = 256

    private let fileSystem: AnchoredFileSystem
    private let hostPaths: HostPathLayoutV1
    private let lock = NSLock()
    private let system: POSIXHostPathSystem

    public init(
        hostPaths: HostPathLayoutV1,
        system: POSIXHostPathSystem = POSIXHostPathSystem()
    ) {
        self.fileSystem = AnchoredFileSystem(system: system)
        self.hostPaths = hostPaths
        self.system = system
    }

    public func load(target: CanonicalUDID) -> VideoSourceMappingLoadResult {
        lock.withLock {
            do {
                let directory = try openStoreDirectory()
                let currentComponent = VideoSourceMappingPathV2.fileName(
                    for: target
                )
                if let metadata = try fileSystem.validateNodeIfPresent(
                    named: currentComponent,
                    relativeTo: directory,
                    expecting: recordExpectation
                ) {
                    try validateRecordMetadata(metadata)
                    let file = try fileSystem.openRegularFile(
                        named: currentComponent,
                        relativeTo: directory,
                        owner: hostPaths.effectiveUserID,
                        mode: 0o600,
                        access: .readOnly
                    )
                    let bytes = try readBounded(
                        file,
                        expectedByteCount: metadata.byteCount
                    )
                    return .mapped(.currentV2(
                        try VideoSourceMappingRecordV2.decode(
                            bytes,
                            target: target
                        )
                    ))
                }
                let legacyComponent = VideoSourceMappingPathV1.fileName(
                    for: target
                )
                guard let metadata = try fileSystem.validateNodeIfPresent(
                    named: legacyComponent,
                    relativeTo: directory,
                    expecting: recordExpectation
                ) else { return .missing }
                try validateRecordMetadata(metadata)
                let file = try fileSystem.openRegularFile(
                    named: legacyComponent,
                    relativeTo: directory,
                    owner: hostPaths.effectiveUserID,
                    mode: 0o600,
                    access: .readOnly
                )
                let bytes = try readBounded(file, expectedByteCount: metadata.byteCount)
                return .mapped(.legacyV1(
                    try VideoSourceMappingRecordV1.decode(bytes, target: target)
                ))
            } catch let error as VideoSourceMappingRecordError {
                _ = error
                return .unavailable(.corruptRecord)
            } catch let error as VideoSourceMappingStoreFailure {
                return .unavailable(error)
            } catch let error as AnchoredFileSystemError {
                return .unavailable(Self.map(error))
            } catch {
                return .unavailable(.ioFailure)
            }
        }
    }

    @discardableResult
    public func replace(
        target: CanonicalUDID,
        sourceID: String,
        proofKind: VideoSourceMappingProofKind,
        initialCanvasWidth: UInt64?,
        initialCanvasHeight: UInt64?
    ) throws -> VideoSourceMappingRecordV2 {
        do {
            return try lock.withLock {
                let record = try VideoSourceMappingRecordV2(
                    target: target,
                    sourceID: sourceID,
                    proofKind: proofKind,
                    initialCanvasWidth: initialCanvasWidth,
                    initialCanvasHeight: initialCanvasHeight
                )
                let bytes = record.canonicalBytes
                guard bytes.count <= VideoSourceMappingRecordV2.maximumByteCount else {
                    throw VideoSourceMappingStoreFailure.corruptRecord
                }
                let directory = try openStoreDirectory()
                let component = VideoSourceMappingPathV2.fileName(for: target)
                let existing = try trustedMetadataIfPresent(
                    component: component,
                    directory: directory
                )
                if existing == nil,
                   try directoryEntryCount(directory) >= Self.maximumRecordCount
                {
                    throw VideoSourceMappingStoreFailure.capacityExceeded
                }

                let tempComponent = ".video-source-mapping-\(UUID().uuidString.lowercased()).tmp"
                var renamed = false
                defer {
                    if !renamed {
                        _ = unlinkat(directory.fileDescriptor, tempComponent, 0)
                    }
                }
                let temp = try fileSystem.createExclusiveRegularFile(
                    named: tempComponent,
                    relativeTo: directory,
                    owner: hostPaths.effectiveUserID,
                    mode: 0o600
                )
                try temp.withUnsafeFileDescriptor { descriptor in
                    try Self.writeAll(bytes, descriptor: descriptor)
                    guard fsync(descriptor) == 0 else {
                        throw VideoSourceMappingStoreFailure.ioFailure
                    }
                }
                let current = try trustedMetadataIfPresent(
                    component: component,
                    directory: directory
                )
                guard current?.identity == existing?.identity else {
                    throw VideoSourceMappingStoreFailure.unsafeHostState
                }
                guard renameat(
                    directory.fileDescriptor,
                    tempComponent,
                    directory.fileDescriptor,
                    component
                ) == 0 else {
                    throw VideoSourceMappingStoreFailure.ioFailure
                }
                renamed = true
                let published = try fileSystem.validateNode(
                    named: component,
                    relativeTo: directory,
                    expecting: recordExpectation,
                    identity: temp.identity
                )
                try validateRecordMetadata(published)
                guard fsync(directory.fileDescriptor) == 0 else {
                    throw VideoSourceMappingStoreFailure.ioFailure
                }
                return record
            }
        } catch let error as AnchoredFileSystemError {
            throw Self.map(error)
        }
    }

    @discardableResult
    public func clear(target: CanonicalUDID) throws -> Bool {
        do {
            return try lock.withLock {
                let directory = try openStoreDirectory()
                let components = [
                    VideoSourceMappingPathV2.fileName(for: target),
                    VideoSourceMappingPathV1.fileName(for: target),
                ]
                var existing = [String: HostNodeMetadata]()
                for component in components {
                    if let metadata = try trustedMetadataIfPresent(
                        component: component,
                        directory: directory
                    ) {
                        existing[component] = metadata
                    }
                }
                guard !existing.isEmpty else { return false }
                for (component, metadata) in existing {
                    let current = try trustedMetadataIfPresent(
                        component: component,
                        directory: directory
                    )
                    guard current?.identity == metadata.identity else {
                        throw VideoSourceMappingStoreFailure.unsafeHostState
                    }
                }
                for component in existing.keys.sorted() {
                    guard unlinkat(
                        directory.fileDescriptor,
                        component,
                        0
                    ) == 0 else {
                        throw VideoSourceMappingStoreFailure.ioFailure
                    }
                }
                guard fsync(directory.fileDescriptor) == 0 else {
                    throw VideoSourceMappingStoreFailure.ioFailure
                }
                return true
            }
        } catch let error as AnchoredFileSystemError {
            throw Self.map(error)
        }
    }

    private var recordExpectation: HostNodeExpectation {
        HostNodeExpectation(
            owner: hostPaths.effectiveUserID,
            kind: .regularFile,
            mode: 0o600
        )
    }

    private func openStoreDirectory() throws -> AnchoredDirectory {
        let home = try fileSystem.openDirectory(
            atPath: hostPaths.homeDirectory,
            expecting: HostNodeExpectation(
                owner: hostPaths.effectiveUserID,
                kind: .directory
            )
        )
        let library = try fileSystem.openDirectory(
            named: "Library",
            relativeTo: home,
            expecting: HostNodeExpectation(
                owner: hostPaths.effectiveUserID,
                kind: .directory,
                mode: 0o700
            )
        )
        let applicationSupport = try fileSystem.openDirectory(
            named: "Application Support",
            relativeTo: library,
            expecting: HostNodeExpectation(
                owner: hostPaths.effectiveUserID,
                kind: .directory,
                mode: 0o700
            )
        )
        let pulsePhone = try fileSystem.ensureDirectory(
            named: "PulsePhone",
            relativeTo: applicationSupport,
            owner: hostPaths.effectiveUserID,
            mode: 0o700
        )
        let mappings = try fileSystem.ensureDirectory(
            named: "VideoSourceMappings",
            relativeTo: pulsePhone,
            owner: hostPaths.effectiveUserID,
            mode: 0o700
        )
        var url = URL(fileURLWithPath: mappings.logicalPath, isDirectory: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        _ = try fileSystem.validateNode(
            named: "VideoSourceMappings",
            relativeTo: pulsePhone,
            expecting: HostNodeExpectation(
                owner: hostPaths.effectiveUserID,
                kind: .directory,
                mode: 0o700
            ),
            identity: mappings.identity
        )
        return mappings
    }

    private func trustedMetadataIfPresent(
        component: String,
        directory: AnchoredDirectory
    ) throws -> HostNodeMetadata? {
        let metadata = try fileSystem.validateNodeIfPresent(
            named: component,
            relativeTo: directory,
            expecting: recordExpectation
        )
        if let metadata { try validateRecordMetadata(metadata) }
        return metadata
    }

    private func validateRecordMetadata(_ metadata: HostNodeMetadata) throws {
        guard metadata.linkCount == 1,
              metadata.byteCount <= VideoSourceMappingRecordV2.maximumByteCount
        else {
            throw VideoSourceMappingStoreFailure.unsafeHostState
        }
    }

    private func readBounded(
        _ file: AnchoredRegularFile,
        expectedByteCount: UInt64
    ) throws -> [UInt8] {
        guard expectedByteCount <= VideoSourceMappingRecordV2.maximumByteCount else {
            throw VideoSourceMappingStoreFailure.unsafeHostState
        }
        return try file.withUnsafeFileDescriptor { descriptor in
            var bytes = [UInt8]()
            bytes.reserveCapacity(Int(expectedByteCount))
            var buffer = [UInt8](repeating: 0, count: 1_024)
            while true {
                let count = buffer.withUnsafeMutableBytes { rawBuffer in
                    Darwin.read(
                        descriptor,
                        rawBuffer.baseAddress!,
                        rawBuffer.count
                    )
                }
                if count > 0 {
                    guard bytes.count + count
                            <= VideoSourceMappingRecordV2.maximumByteCount
                    else {
                        throw VideoSourceMappingStoreFailure.unsafeHostState
                    }
                    bytes.append(contentsOf: buffer.prefix(count))
                } else if count == 0 {
                    break
                } else if errno == EINTR {
                    continue
                } else {
                    throw VideoSourceMappingStoreFailure.ioFailure
                }
            }
            guard bytes.count == Int(expectedByteCount) else {
                throw VideoSourceMappingStoreFailure.unsafeHostState
            }
            return bytes
        }
    }

    private func directoryEntryCount(_ directory: AnchoredDirectory) throws -> Int {
        let duplicate = dup(directory.fileDescriptor)
        guard duplicate >= 0, let stream = fdopendir(duplicate) else {
            if duplicate >= 0 { _ = Darwin.close(duplicate) }
            throw VideoSourceMappingStoreFailure.ioFailure
        }
        defer { closedir(stream) }
        var count = 0
        while let entry = readdir(stream) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(cString: $0)
                }
            }
            if name == "." || name == ".." { continue }
            count += 1
            if count >= Self.maximumRecordCount { return count }
        }
        return count
    }

    private static func writeAll(_ bytes: [UInt8], descriptor: Int32) throws {
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { raw in
                Darwin.write(
                    descriptor,
                    raw.baseAddress!.advanced(by: offset),
                    bytes.count - offset
                )
            }
            if count > 0 {
                offset += count
            } else if count == -1, errno == EINTR {
                continue
            } else {
                throw VideoSourceMappingStoreFailure.ioFailure
            }
        }
    }

    private static func map(
        _ error: AnchoredFileSystemError
    ) -> VideoSourceMappingStoreFailure {
        switch error {
        case .unsafeNode:
            .unsafeHostState
        case .systemCall:
            .ioFailure
        }
    }
}
