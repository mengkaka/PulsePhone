import Darwin
import Foundation
import PulsePhoneClientCore
import PulsePhoneHostPaths
import PulsePhoneLogging
import PulsePhoneRuntimeState
import PulsePhoneSharedDefinitions

enum ProductionRuntimeRecordingError: Error, Equatable {
    case diagnosticsAlreadyActive
    case diagnosticWriteFailed
    case noActiveDiagnostics
    case noActiveTrace
    case traceAlreadyActive
    case traceWriteFailed
    case unsafeHostPath
}

enum ProductionRuntimeRecordingKind: Equatable, Sendable {
    case diagnostics
    case trace
}

enum ProductionRuntimeRecordingWriteStage: Equatable, Sendable {
    case finalize
    case header
    case record
}

struct ProductionRuntimeRecordingSnapshot: Equatable, Sendable {
    let activeDiagnosticsPath: String?
    let activeDiagnosticsSessionID: CanonicalUUID?
    let activeTraceID: CanonicalUUID?
    let activeTracePath: String?
    let revision: UInt64

    var hasActiveTrace: Bool { activeTraceID != nil }
}

final class ProductionRuntimeRecordingStore: @unchecked Sendable {
    typealias WriteAvailability = @Sendable (
        ProductionRuntimeRecordingKind,
        ProductionRuntimeRecordingWriteStage
    ) -> Bool

    private struct ActiveDiagnostics {
        let file: AnchoredRegularFile
        var persistedByteCount: Int
        var writer: DiagnosticLogWriter
    }

    private struct ActiveTrace {
        let file: AnchoredRegularFile
        var persistedByteCount: Int
        var writer: ReplayTraceWriter
    }

    private let diagnosticsDirectory: AnchoredDirectory
    private let fileSystem: AnchoredFileSystem
    private let lock = NSLock()
    private let owner: uid_t
    private let traceDirectory: AnchoredDirectory
    private let writeAvailability: WriteAvailability
    private var diagnostics: ActiveDiagnostics?
    private var revision: UInt64 = 0
    private var trace: ActiveTrace?
    private var lifecycle: RuntimeLifecycleController?
    private var traceToken: ShutdownInhibitorToken?

    func bindLifecycle(_ controller: RuntimeLifecycleController) {
        lock.withLock { lifecycle = controller }
    }

    init(
        traceDirectory: AnchoredDirectory,
        diagnosticsDirectory: AnchoredDirectory,
        owner: uid_t,
        fileSystem: AnchoredFileSystem,
        writeAvailability: @escaping WriteAvailability = { _, _ in true }
    ) {
        self.diagnosticsDirectory = diagnosticsDirectory
        self.fileSystem = fileSystem
        self.owner = owner
        self.traceDirectory = traceDirectory
        self.writeAvailability = writeAvailability
    }

    static func bundled(
        canonicalUDID: CanonicalUDID,
        system: POSIXHostPathSystem = POSIXHostPathSystem()
    ) throws -> ProductionRuntimeRecordingStore {
        let fileSystem = AnchoredFileSystem(system: system)
        do {
            let temporary = try system.openTemporaryBaseAnchor(
                fileSystem: fileSystem
            )
            let artifacts = try fileSystem.ensureDirectory(
                named: "artifacts",
                relativeTo: temporary,
                owner: system.effectiveUserID
            )
            let target = try fileSystem.ensureDirectory(
                named: canonicalUDID.domainSeparatedHash,
                relativeTo: artifacts,
                owner: system.effectiveUserID
            )
            let traces = try fileSystem.ensureDirectory(
                named: "traces",
                relativeTo: target,
                owner: system.effectiveUserID
            )
            let diagnostics = try fileSystem.ensureDirectory(
                named: "diagnostics",
                relativeTo: target,
                owner: system.effectiveUserID
            )
            return ProductionRuntimeRecordingStore(
                traceDirectory: traces,
                diagnosticsDirectory: diagnostics,
                owner: system.effectiveUserID,
                fileSystem: fileSystem
            )
        } catch is AnchoredFileSystemError {
            throw ProductionRuntimeRecordingError.unsafeHostPath
        }
    }

    static func testing(
        temporaryBasePath: String,
        canonicalUDID: CanonicalUDID,
        writeAvailability: @escaping WriteAvailability = { _, _ in true }
    ) throws -> ProductionRuntimeRecordingStore {
        let system = POSIXHostPathSystem()
        let fileSystem = AnchoredFileSystem(system: system)
        let owner = system.effectiveUserID
        let root = try fileSystem.openDirectory(
            atPath: temporaryBasePath,
            expecting: HostNodeExpectation(
                owner: owner,
                kind: .directory,
                mode: 0o700
            )
        )
        let artifacts = try fileSystem.ensureDirectory(
            named: "artifacts",
            relativeTo: root,
            owner: owner
        )
        let target = try fileSystem.ensureDirectory(
            named: canonicalUDID.domainSeparatedHash,
            relativeTo: artifacts,
            owner: owner
        )
        let traces = try fileSystem.ensureDirectory(
            named: "traces",
            relativeTo: target,
            owner: owner
        )
        let diagnostics = try fileSystem.ensureDirectory(
            named: "diagnostics",
            relativeTo: target,
            owner: owner
        )
        return ProductionRuntimeRecordingStore(
            traceDirectory: traces,
            diagnosticsDirectory: diagnostics,
            owner: owner,
            fileSystem: fileSystem,
            writeAvailability: writeAvailability
        )
    }

    var snapshot: ProductionRuntimeRecordingSnapshot {
        lock.withLock {
            ProductionRuntimeRecordingSnapshot(
                activeDiagnosticsPath: diagnostics?.writer.absolutePath,
                activeDiagnosticsSessionID: diagnostics?.writer.sessionID,
                activeTraceID: trace?.writer.traceID,
                activeTracePath: trace?.writer.absolutePath,
                revision: revision
            )
        }
    }

    func startTrace(
        maximumFileBytes: Int = ReplayTraceWriter.maximumFileBytes,
        footerReserveBytes: Int = ReplayTraceWriter.footerReserveBytes
    ) throws -> ReplayTraceStartResult {
        try lock.withLock {
            guard trace == nil else {
                throw ProductionRuntimeRecordingError.traceAlreadyActive
            }
            traceToken = try lifecycle?.acquire(kind: .activeTrace, commandID: "trace.start")
            defer { releaseTraceTokenIfInactive() }
            let traceID = CanonicalUUID(value: UUID())
            let file: AnchoredRegularFile
            do {
                file = try fileSystem.createExclusiveRegularFile(
                    named: "trace-\(traceID.canonicalString).jsonl",
                    relativeTo: traceDirectory,
                    owner: owner
                )
            } catch let error as AnchoredFileSystemError {
                throw mapPathError(error, writeFailure: .traceWriteFailed)
            }
            let writer: ReplayTraceWriter
            do {
                writer = try ReplayTraceWriter(
                    traceID: traceID,
                    absolutePath: file.logicalPath,
                    maximumFileBytes: maximumFileBytes,
                    footerReserveBytes: footerReserveBytes
                )
                let count = try persist(
                    writer.bytes,
                    from: 0,
                    to: file,
                    kind: .trace,
                    stage: .header,
                    synchronize: true
                )
                trace = ActiveTrace(
                    file: file,
                    persistedByteCount: count,
                    writer: writer
                )
            } catch let error as ProductionRuntimeRecordingError {
                rollback(file, to: 0)
                throw error
            } catch {
                rollback(file, to: 0)
                throw ProductionRuntimeRecordingError.traceWriteFailed
            }
            advanceRevision()
            return ReplayTraceStartResult(
                absolutePath: writer.absolutePath,
                traceID: writer.traceID
            )
        }
    }

    func stopTrace() throws -> ReplayTraceFinalization {
        try lock.withLock {
            guard let active = trace else {
                throw ProductionRuntimeRecordingError.noActiveTrace
            }
            var completed = active.writer
            let finalization = try completed.stop()
            do {
                _ = try persist(
                    completed.bytes,
                    from: active.persistedByteCount,
                    to: active.file,
                    kind: .trace,
                    stage: .finalize,
                    synchronize: true
                )
                trace = nil
                advanceRevision()
                return finalization
            } catch {
                rollback(active.file, to: active.persistedByteCount)
                var partial = active.writer
                let fallback = try partial.stop(
                    completeFooterWriteAvailable: false,
                    incompleteFooterWriteAvailable: true
                )
                persistBestEffort(
                    partial.bytes,
                    from: active.persistedByteCount,
                    to: active.file,
                    kind: .trace,
                    stage: .finalize,
                    synchronize: true
                )
                trace = nil
                advanceRevision()
                return fallback
            }
        }
    }

    func recordTrace(_ event: ReplayTraceSemanticEvent) {
        lock.withLock {
            guard let active = trace else { return }
            var updated = active.writer
            guard let disposition = try? updated.append(event) else { return }
            do {
                let count = try persist(
                    updated.bytes,
                    from: active.persistedByteCount,
                    to: active.file,
                    kind: .trace,
                    stage: disposition.isFinal ? .finalize : .record,
                    synchronize: disposition.isFinal
                )
                if disposition.isFinal {
                    trace = nil
                    advanceRevision()
                } else {
                    trace = ActiveTrace(
                        file: active.file,
                        persistedByteCount: count,
                        writer: updated
                    )
                }
            } catch {
                rollback(active.file, to: active.persistedByteCount)
                var failed = active.writer
                _ = try? failed.append(
                    event,
                    semanticWriteAvailable: false,
                    incompleteFooterWriteAvailable: true
                )
                persistBestEffort(
                    failed.bytes,
                    from: active.persistedByteCount,
                    to: active.file,
                    kind: .trace,
                    stage: .finalize,
                    synchronize: true
                )
                trace = nil
                advanceRevision()
            }
        }
    }

    func startDiagnostics(
        maximumFileBytes: Int = DiagnosticLogWriter.maximumFileBytes,
        footerReserveBytes: Int = DiagnosticLogWriter.footerReserveBytes
    ) throws -> DiagnosticStartResult {
        try lock.withLock {
            guard diagnostics == nil else {
                throw ProductionRuntimeRecordingError.diagnosticsAlreadyActive
            }
            let sessionID = CanonicalUUID(value: UUID())
            let file: AnchoredRegularFile
            do {
                file = try fileSystem.createExclusiveRegularFile(
                    named: "diagnostics-\(sessionID.canonicalString).jsonl",
                    relativeTo: diagnosticsDirectory,
                    owner: owner
                )
            } catch let error as AnchoredFileSystemError {
                throw mapPathError(error, writeFailure: .diagnosticWriteFailed)
            }
            let writer: DiagnosticLogWriter
            do {
                writer = try DiagnosticLogWriter(
                    sessionID: sessionID,
                    absolutePath: file.logicalPath,
                    maximumFileBytes: maximumFileBytes,
                    footerReserveBytes: footerReserveBytes
                )
                let count = try persist(
                    writer.bytes,
                    from: 0,
                    to: file,
                    kind: .diagnostics,
                    stage: .header,
                    synchronize: true
                )
                diagnostics = ActiveDiagnostics(
                    file: file,
                    persistedByteCount: count,
                    writer: writer
                )
            } catch let error as ProductionRuntimeRecordingError {
                rollback(file, to: 0)
                throw error
            } catch {
                rollback(file, to: 0)
                throw ProductionRuntimeRecordingError.diagnosticWriteFailed
            }
            advanceRevision()
            return DiagnosticStartResult(
                absolutePath: writer.absolutePath,
                sessionID: writer.sessionID
            )
        }
    }

    func stopDiagnostics() throws -> DiagnosticLogFinalization {
        try lock.withLock {
            guard let active = diagnostics else {
                throw ProductionRuntimeRecordingError.noActiveDiagnostics
            }
            var completed = active.writer
            let finalization = try completed.stop()
            do {
                _ = try persist(
                    completed.bytes,
                    from: active.persistedByteCount,
                    to: active.file,
                    kind: .diagnostics,
                    stage: .finalize,
                    synchronize: true
                )
                diagnostics = nil
                advanceRevision()
                return finalization
            } catch {
                rollback(active.file, to: active.persistedByteCount)
                var partial = active.writer
                let fallback = try partial.stop(footerWriteAvailable: false)
                diagnostics = nil
                advanceRevision()
                return fallback
            }
        }
    }

    func recordDiagnostic(_ event: DiagnosticLogEvent) {
        lock.withLock {
            guard let active = diagnostics else { return }
            var updated = active.writer
            guard let disposition = try? updated.append(event) else { return }
            do {
                let count = try persist(
                    updated.bytes,
                    from: active.persistedByteCount,
                    to: active.file,
                    kind: .diagnostics,
                    stage: disposition.isFinal ? .finalize : .record,
                    synchronize: disposition.isFinal
                )
                if disposition.isFinal {
                    diagnostics = nil
                    advanceRevision()
                } else {
                    diagnostics = ActiveDiagnostics(
                        file: active.file,
                        persistedByteCount: count,
                        writer: updated
                    )
                }
            } catch {
                rollback(active.file, to: active.persistedByteCount)
                var failed = active.writer
                _ = try? failed.append(
                    event,
                    writeAvailable: false,
                    footerWriteAvailable: true
                )
                persistBestEffort(
                    failed.bytes,
                    from: active.persistedByteCount,
                    to: active.file,
                    kind: .diagnostics,
                    stage: .finalize,
                    synchronize: true
                )
                diagnostics = nil
                advanceRevision()
            }
        }
    }

    func shutdown() {
        lock.withLock {
            if let active = diagnostics {
                var writer = active.writer
                if let finalization = try? writer.stop(reason: .shutdown) {
                    persistBestEffort(
                        writer.bytes,
                        from: active.persistedByteCount,
                        to: active.file,
                        kind: .diagnostics,
                        stage: .finalize,
                        synchronize: true
                    )
                    _ = finalization
                }
                diagnostics = nil
                advanceRevision()
            }
            if trace != nil {
                trace = nil
                advanceRevision()
            }
        }
    }

    private func persist(
        _ bytes: [UInt8],
        from offset: Int,
        to file: AnchoredRegularFile,
        kind: ProductionRuntimeRecordingKind,
        stage: ProductionRuntimeRecordingWriteStage,
        synchronize: Bool
    ) throws -> Int {
        guard writeAvailability(kind, stage), offset <= bytes.count else {
            throw writeFailure(for: kind)
        }
        try file.withUnsafeFileDescriptor { descriptor in
            var position = offset
            while position < bytes.count {
                let written: Int = bytes.withUnsafeBytes { buffer in
                    guard let base = buffer.baseAddress else { return 0 }
                    return Darwin.pwrite(
                        descriptor,
                        base.advanced(by: position),
                        bytes.count - position,
                        off_t(position)
                    )
                }
                if written < 0 {
                    if errno == EINTR { continue }
                    throw writeFailure(for: kind)
                }
                guard written > 0 else {
                    throw writeFailure(for: kind)
                }
                position += written
            }
            if synchronize, Darwin.fsync(descriptor) != 0 {
                throw writeFailure(for: kind)
            }
        }
        return bytes.count
    }

    private func rollback(_ file: AnchoredRegularFile, to byteCount: Int) {
        _ = try? file.withUnsafeFileDescriptor { descriptor in
            guard Darwin.ftruncate(descriptor, off_t(byteCount)) == 0 else {
                throw ProductionRuntimeRecordingError.traceWriteFailed
            }
        }
    }

    private func persistBestEffort(
        _ bytes: [UInt8],
        from offset: Int,
        to file: AnchoredRegularFile,
        kind: ProductionRuntimeRecordingKind,
        stage: ProductionRuntimeRecordingWriteStage,
        synchronize: Bool
    ) {
        do {
            _ = try persist(
                bytes,
                from: offset,
                to: file,
                kind: kind,
                stage: stage,
                synchronize: synchronize
            )
        } catch {
            rollback(file, to: offset)
        }
    }

    private func mapPathError(
        _ error: AnchoredFileSystemError,
        writeFailure: ProductionRuntimeRecordingError
    ) -> ProductionRuntimeRecordingError {
        switch error {
        case .unsafeNode:
            return .unsafeHostPath
        case .systemCall:
            return writeFailure
        }
    }

    private func advanceRevision() {
        releaseTraceTokenIfInactive()
        revision = revision == UInt64.max ? UInt64.max : revision + 1
    }

    private func releaseTraceTokenIfInactive() {
        if trace == nil, let traceToken {
            try? lifecycle?.release(traceToken)
            self.traceToken = nil
        }
    }

    private func writeFailure(
        for kind: ProductionRuntimeRecordingKind
    ) -> ProductionRuntimeRecordingError {
        kind == .trace ? .traceWriteFailed : .diagnosticWriteFailed
    }
}

private extension ReplayTraceAppendDisposition {
    var isFinal: Bool {
        if case .autoFinalized = self { return true }
        return false
    }
}

private extension DiagnosticLogAppendDisposition {
    var isFinal: Bool {
        if case .autoFinalized = self { return true }
        return false
    }
}
