import Darwin
import Foundation
import PulsePhoneClientCore
import PulsePhoneMedia
import PulsePhoneSharedDefinitions

enum ProductionGUIScreenshotDeviceError: Error, Equatable, Sendable {
    case terminal(errorCode: String)

    var errorCode: String {
        switch self {
        case .terminal(let errorCode): errorCode
        }
    }
}

final class ProductionGUIScreenshotRootLogger:
    GUIScreenshotRootLogging,
    @unchecked Sendable
{
    typealias Submit = @Sendable (RepositoryJSONObject) -> Void

    private let clientInstanceID: CanonicalUUID
    private let submit: Submit

    init(
        clientInstanceID: CanonicalUUID,
        submit: @escaping Submit
    ) {
        self.clientInstanceID = clientInstanceID
        self.submit = submit
    }

    func recordBestEffort(_ event: GUIScreenshotRootEvent) {
        guard let body = try? body(for: event) else { return }
        submit(body)
    }

    private func body(
        for event: GUIScreenshotRootEvent
    ) throws -> RepositoryJSONObject {
        let actionID: CanonicalUUID
        let target: CanonicalUDID
        let eventKind: String
        let payload: RepositoryJSONObject
        switch event {
        case .begin(let identifier, let canonicalUDID):
            actionID = identifier
            target = canonicalUDID
            eventKind = "action.begin"
            payload = try object([])
        case .terminal(let identifier, let canonicalUDID, let outcome):
            actionID = identifier
            target = canonicalUDID
            eventKind = "action.terminal"
            payload = try object([
                ("outcome", .string(outcome.rawValue)),
            ])
        }
        return try object([
            ("actionID", .string(actionID.canonicalString)),
            ("canonicalUDID", .string(target.rawValue)),
            ("commandID", .string(ScreenshotAction.commandID)),
            ("eventKind", .string(eventKind)),
            ("payload", .object(payload)),
            ("sourceClientInstanceID", .string(
                clientInstanceID.canonicalString
            )),
            ("sourceRole", .string("gui")),
            ("timestampMonotonicNs", .number(.uint64(
                SystemMonotonicClock().now().nanoseconds
            ))),
        ])
    }

    private func object(
        _ members: [(String, RepositoryJSONValue)]
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(members: members.map {
            RepositoryJSONMember(key: $0.0, value: $0.1)
        })
    }
}

final class ProductionGUIScreenshotFlowBox: @unchecked Sendable {
    private var flow: ScreenshotSaveFlow
    private let lock = NSLock()

    init(flow: ScreenshotSaveFlow) {
        self.flow = flow
    }

    func cancel() throws {
        try lock.withLock { try flow.cancel() }
    }

    func save(
        absoluteOutputPath: String,
        replaceExisting: Bool,
        selectedAtNanoseconds: UInt64,
        previewFrame: ScreenshotPreviewFrame?,
        currentBinding: VideoBindingIdentity?,
        childActionID: CanonicalUUID,
        tempID: CanonicalUUID
    ) throws -> ScreenshotSaveResult {
        try lock.withLock {
            try flow.save(
                absoluteOutputPath: absoluteOutputPath,
                replaceExisting: replaceExisting,
                selectedAtNanoseconds: selectedAtNanoseconds,
                previewFrame: previewFrame,
                currentBinding: currentBinding,
                childActionID: childActionID,
                tempID: tempID
            )
        }
    }
}

struct ProductionGUIScreenshotDeviceBackend: GUIScreenshotDeviceBackend {
    func requestDeviceScreenshot(
        rootActionID: CanonicalUUID,
        childActionID: CanonicalUUID,
        canonicalUDID: CanonicalUDID
    ) throws -> GUIScreenshotPNGArtifact {
        let response = try RuntimeClient.bundled(role: .gui).requestScreenshot(
            canonicalUDID: canonicalUDID,
            body: try object([
                ("actionID", .string(childActionID.canonicalString)),
                ("canonicalUDID", .string(canonicalUDID.rawValue)),
                ("commandID", .string(ScreenshotAction.commandID)),
                ("normalizedArguments", .object(try object([]))),
                ("parentActionID", .string(rootActionID.canonicalString)),
            ]),
            activation: .ensureRunning,
            requestID: CanonicalUUID(value: UUID())
        )
        guard response.result["outcome"]?.stringValue == "succeeded" else {
            throw ProductionGUIScreenshotDeviceError.terminal(
                errorCode: response.result["error"]?.objectValue?["code"]?.stringValue
                    ?? "internalFailure"
            )
        }
        guard let artifact = response.artifact else {
            throw RuntimeClientError.invalidResponse
        }
        return try GUIScreenshotPNGArtifact(bytes: artifact.bytes)
    }

    private func object(
        _ members: [(String, RepositoryJSONValue)]
    ) throws -> RepositoryJSONObject {
        try RepositoryJSONObject(members: members.map {
            RepositoryJSONMember(key: $0.0, value: $0.1)
        })
    }
}
