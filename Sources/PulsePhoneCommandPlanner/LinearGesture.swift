import Foundation
import PulsePhoneSharedDefinitions

public enum LinearGesturePlannerError: Error, Equatable, Sendable {
    case invalidCommandID
    case invalidArguments
    case planTooLarge(maximumFrames: Int, actualFrames: Int)
    case payloadTooLarge(maximumBytes: Int, actualBytes: Int)
}

public enum LinearGestureFrameKind: String, Equatable, Sendable {
    case begin
    case end
    case move
}

public struct LinearGestureFrame: Equatable, Sendable {
    public let elapsedMilliseconds: UInt64
    public let kind: LinearGestureFrameKind
    public let point: NormalizedPointV1
    public let sequence: UInt64

    public init(
        elapsedMilliseconds: UInt64,
        kind: LinearGestureFrameKind,
        point: NormalizedPointV1,
        sequence: UInt64
    ) {
        self.elapsedMilliseconds = elapsedMilliseconds
        self.kind = kind
        self.point = point
        self.sequence = sequence
    }
}

public struct LinearGesturePlan: Equatable, Sendable {
    public let commandID: String
    public let durationMilliseconds: UInt64
    public let encodedPayload: [UInt8]
    public let frames: [LinearGestureFrame]

    public init(
        commandID: String,
        durationMilliseconds: UInt64,
        encodedPayload: [UInt8],
        frames: [LinearGestureFrame]
    ) {
        self.commandID = commandID
        self.durationMilliseconds = durationMilliseconds
        self.encodedPayload = encodedPayload
        self.frames = frames
    }
}

public struct LinearGestureLimits: Equatable, Sendable {
    public let frameIntervalMilliseconds: UInt64
    public let maximumFrames: Int
    public let maximumPayloadBytes: Int

    public init(
        frameIntervalMilliseconds: UInt64 = 16,
        maximumFrames: Int = 4_096,
        maximumPayloadBytes: Int = 512 * 1_024
    ) {
        self.frameIntervalMilliseconds = frameIntervalMilliseconds
        self.maximumFrames = maximumFrames
        self.maximumPayloadBytes = maximumPayloadBytes
    }
}

public struct LinearGesturePlanner: Sendable {
    public static let contractID = "gesture.linear.v1"
    public static let productionLimits = LinearGestureLimits()

    private let limits: LinearGestureLimits

    public init(limits: LinearGestureLimits = Self.productionLimits) {
        self.limits = limits
    }

    public func plan(
        commandID: String,
        rawArguments: [String: String]
    ) throws -> LinearGesturePlan {
        guard commandID == "touch.drag" || commandID == "touch.swipe" else {
            throw LinearGesturePlannerError.invalidCommandID
        }
        guard limits.frameIntervalMilliseconds > 0,
              limits.maximumFrames >= 2,
              limits.maximumPayloadBytes > 0
        else {
            throw LinearGesturePlannerError.invalidArguments
        }

        let arguments: NormalizedArgumentsV1
        do {
            arguments = try ArgumentNormalizer.normalize(
                schemaID: "linearGesture.v1",
                raw: rawArguments
            )
        } catch {
            throw LinearGesturePlannerError.invalidArguments
        }
        guard case .uint64(let duration)? = arguments.values["durationMs"],
              case .point(let from)? = arguments.values["from"],
              case .point(let to)? = arguments.values["to"]
        else {
            throw LinearGesturePlannerError.invalidArguments
        }

        let intervalCount = (duration - 1) / limits.frameIntervalMilliseconds + 1
        let frameCountValue = intervalCount + 1
        guard let frameCount = Int(exactly: frameCountValue) else {
            throw LinearGesturePlannerError.planTooLarge(
                maximumFrames: limits.maximumFrames,
                actualFrames: Int.max
            )
        }
        guard frameCount <= limits.maximumFrames else {
            throw LinearGesturePlannerError.planTooLarge(
                maximumFrames: limits.maximumFrames,
                actualFrames: frameCount
            )
        }

        var frames = [LinearGestureFrame]()
        frames.reserveCapacity(frameCount)
        for index in 0..<frameCount {
            let isLast = index == frameCount - 1
            let elapsed = isLast
                ? duration
                : UInt64(index) * limits.frameIntervalMilliseconds
            let kind: LinearGestureFrameKind
            if index == 0 {
                kind = .begin
            } else if isLast {
                kind = .end
            } else {
                kind = .move
            }
            frames.append(LinearGestureFrame(
                elapsedMilliseconds: elapsed,
                kind: kind,
                point: NormalizedPointV1(
                    x: interpolate(
                        from: from.x,
                        to: to.x,
                        elapsed: elapsed,
                        duration: duration
                    ),
                    y: interpolate(
                        from: from.y,
                        to: to.y,
                        elapsed: elapsed,
                        duration: duration
                    )
                ),
                sequence: UInt64(index)
            ))
        }

        let payload = try encodePayload(
            commandID: commandID,
            duration: duration,
            frames: frames
        )
        guard payload.count <= limits.maximumPayloadBytes else {
            throw LinearGesturePlannerError.payloadTooLarge(
                maximumBytes: limits.maximumPayloadBytes,
                actualBytes: payload.count
            )
        }
        return LinearGesturePlan(
            commandID: commandID,
            durationMilliseconds: duration,
            encodedPayload: payload,
            frames: frames
        )
    }

    private func interpolate(
        from: String,
        to: String,
        elapsed: UInt64,
        duration: UInt64
    ) -> String {
        if elapsed == 0 { return from }
        if elapsed == duration { return to }
        let locale = Locale(identifier: "en_US_POSIX")
        let start = Decimal(string: from, locale: locale)!
        let end = Decimal(string: to, locale: locale)!
        let ratio = Decimal(elapsed) / Decimal(duration)
        var value = start + (end - start) * ratio
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, 18, .plain)
        let string = NSDecimalNumber(decimal: rounded).stringValue
        return string == "-0" ? "0" : string
    }

    private func encodePayload(
        commandID: String,
        duration: UInt64,
        frames: [LinearGestureFrame]
    ) throws -> [UInt8] {
        let frameValues = try frames.map { frame in
            RepositoryJSONValue.object(try RepositoryJSONObject(members: [
                RepositoryJSONMember(
                    key: "elapsedMs",
                    value: .number(.uint64(frame.elapsedMilliseconds))
                ),
                RepositoryJSONMember(
                    key: "kind",
                    value: .string(frame.kind.rawValue)
                ),
                RepositoryJSONMember(
                    key: "point",
                    value: .object(try RepositoryJSONObject(members: [
                        RepositoryJSONMember(
                            key: "x",
                            value: .string(frame.point.x)
                        ),
                        RepositoryJSONMember(
                            key: "y",
                            value: .string(frame.point.y)
                        ),
                    ]))
                ),
                RepositoryJSONMember(
                    key: "seq",
                    value: .number(.uint64(frame.sequence))
                ),
            ]))
        }
        let root = try RepositoryJSONObject(members: [
            RepositoryJSONMember(key: "commandID", value: .string(commandID)),
            RepositoryJSONMember(
                key: "durationMs",
                value: .number(.uint64(duration))
            ),
            RepositoryJSONMember(key: "frames", value: .array(frameValues)),
            RepositoryJSONMember(key: "schemaID", value: .string(Self.contractID)),
        ])
        return RepositoryCanonicalJSON.encodeDocument(root)
    }
}
