import CoreFoundation
import Foundation
import PulsePhoneMedia

struct OmniParserServiceModel: Equatable, Sendable {
    let backend: String
    let imageSize: UInt64
    let name: String
    let version: String
}

struct OmniParserServiceCapability: Equatable, Sendable {
    enum WireProtocol: Equatable, Sendable {
        case currentParse
        case detectorV1
    }

    static let detectorName = "omniparser-v3-yolov9-e"
    static let detectorProtocol = "pulsephone.omniparser.detector.v1"
    static let probeSchema = "pulsephone.omniparser.probe.v1"
    static let responseSchema = "pulsephone.omniparser.detector-response.v1"
    static let currentBoxThreshold = 0.05
    static let currentIOUThreshold = 0.7

    let backends: Set<String>
    let currentBackend: String?
    let maximumDetections: UInt64
    let maximumRequestBytes: UInt64
    let maximumResponseBytes: UInt64
    let model: OmniParserServiceModel?
    let wireProtocol: WireProtocol

    static func currentParse(
        backend: String = "http"
    ) -> Self {
        Self(
            backends: [],
            currentBackend: backend,
            maximumDetections: 2_048,
            maximumRequestBytes: UInt64(
                OmniParserAnalyzer.maximumRequestBodyBytes
            ),
            maximumResponseBytes: UInt64(
                OmniParserAnalyzer.maximumResponseBytes
            ),
            model: nil,
            wireProtocol: .currentParse
        )
    }

    static func decodeProbe(_ data: Data) throws -> Self {
        guard data.count <= OmniParserAnalyzer.maximumProbeBytes,
              let root = try JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else {
            throw ElementAnalyzerError.invalidResponse
        }
        guard Set(root.keys) == Set([
            "capabilities", "limits", "model", "protocol", "schema",
            "status",
        ]),
              root["schema"] as? String == probeSchema,
              root["protocol"] as? String == detectorProtocol,
              root["status"] as? String == "ready",
              let capabilities = root["capabilities"] as? [String: Any],
              Set(capabilities.keys) == Set([
                "caption", "detectorOnly", "ocr",
              ]),
              capabilities["detectorOnly"] as? Bool == true,
              capabilities["ocr"] as? Bool == false,
              capabilities["caption"] as? Bool == false,
              let limits = root["limits"] as? [String: Any],
              Set(limits.keys) == Set([
                "maximumDetections", "maximumRequestBytes",
                "maximumResponseBytes",
              ]),
              let maximumDetections = uint(limits["maximumDetections"]),
              (1...2_048).contains(maximumDetections),
              let maximumRequestBytes = uint(limits["maximumRequestBytes"]),
              (1...UInt64(OmniParserAnalyzer.maximumRequestBodyBytes))
                .contains(maximumRequestBytes),
              let maximumResponseBytes = uint(limits["maximumResponseBytes"]),
              (1...UInt64(OmniParserAnalyzer.maximumResponseBytes))
                .contains(maximumResponseBytes),
              let modelObject = root["model"] as? [String: Any],
              let (model, backends) = decodeProbeModel(modelObject)
        else {
            throw ElementAnalyzerError.invalidResponse
        }
        return Self(
            backends: backends,
            currentBackend: nil,
            maximumDetections: maximumDetections,
            maximumRequestBytes: maximumRequestBytes,
            maximumResponseBytes: maximumResponseBytes,
            model: model,
            wireProtocol: .detectorV1
        )
    }

    func decodeResponse(
        _ data: Data,
        requestID: String,
        snapshotID: String,
        geometry: SnapshotDerivedImageGeometry,
        profileID: String
    ) throws -> OmniParserDetectorResponse {
        switch wireProtocol {
        case .currentParse:
            return try decodeCurrentResponse(data, geometry: geometry)
        case .detectorV1:
            return try decodeDetectorResponse(
                data,
                requestID: requestID,
                snapshotID: snapshotID,
                geometry: geometry,
                profileID: profileID
            )
        }
    }

    func encodeRequest(
        image: SnapshotDerivedImage,
        requestID: String,
        snapshotID: String
    ) throws -> Data {
        guard image.payload.contentType == "image/png",
              image.payload.bytes.count <= OmniParserAnalyzer.maximumRequestImageBytes,
              image.geometry.inputDimensions == image.payload.dimensions
        else {
            throw ElementAnalyzerError.requestTooLarge
        }
        let object: [String: Any]
        switch wireProtocol {
        case .currentParse:
            object = [
                "base64_image": Data(image.payload.bytes).base64EncodedString(),
                "box_threshold": "0.05",
                "iou_threshold": "0.7",
                "response_mode": "json",
            ]
        case .detectorV1:
            guard let model else {
                throw ElementAnalyzerError.invalidResponse
            }
            object = [
                "input": [
                    "base64": Data(image.payload.bytes).base64EncodedString(),
                    "contentType": image.payload.contentType,
                    "height": image.geometry.inputDimensions.height,
                    "profileID": image.profile.profileID,
                    "width": image.geometry.inputDimensions.width,
                ],
                "model": [
                    "imageSize": model.imageSize,
                    "name": model.name,
                    "version": model.version,
                ],
                "options": [
                    "detectorOnly": true,
                    "includeCaption": false,
                    "includeOCR": false,
                    "maximumDetections": maximumDetections,
                ],
                "protocol": Self.detectorProtocol,
                "requestID": requestID,
                "schema": "pulsephone.omniparser.detector-request.v1",
                "snapshotID": snapshotID,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        guard data.count <= min(
            Int(maximumRequestBytes),
            OmniParserAnalyzer.maximumRequestBodyBytes
        ) else {
            throw ElementAnalyzerError.requestTooLarge
        }
        return data
    }

    private func decodeCurrentResponse(
        _ data: Data,
        geometry: SnapshotDerivedImageGeometry
    ) throws -> OmniParserDetectorResponse {
        guard data.count <= min(
            Int(maximumResponseBytes),
            OmniParserAnalyzer.maximumResponseBytes
        ),
              let root = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              Set(root.keys) == Set(["latency", "parsed_content_list"]),
              let latencySeconds = Self.double(root["latency"]),
              (0...60).contains(latencySeconds),
              let rows = root["parsed_content_list"] as? [Any],
              rows.count <= min(Int(maximumDetections), 2_048)
        else {
            throw ElementAnalyzerError.invalidResponse
        }
        let width = Double(geometry.inputDimensions.width)
        let height = Double(geometry.inputDimensions.height)
        var detections = [OmniParserDetectorResponse.Detection]()
        detections.reserveCapacity(rows.count)
        for row in rows {
            guard let object = row as? [String: Any],
                  Set(object.keys) == Set([
                    "bbox", "content", "interactivity", "source", "type",
                  ]),
                  let content = object["content"] as? String,
                  content.utf8.count <= 4_096,
                  let source = Self.boundedString(
                    object["source"],
                    maximumBytes: 128
                  ),
                  !source.isEmpty,
                  let type = Self.boundedString(
                    object["type"],
                    maximumBytes: 32
                  ),
                  ["icon", "text"].contains(type),
                  let interactive = object["interactivity"] as? Bool,
                  let bbox = object["bbox"] as? [Any],
                  bbox.count == 4,
                  let x1 = Self.double(bbox[0]),
                  let y1 = Self.double(bbox[1]),
                  let x2 = Self.double(bbox[2]),
                  let y2 = Self.double(bbox[3]),
                  x1 < x2,
                  y1 < y2
            else {
                throw ElementAnalyzerError.invalidResponse
            }
            let clippedX1 = max(0, x1)
            let clippedY1 = max(0, y1)
            let clippedX2 = min(1, x2)
            let clippedY2 = min(1, y2)
            guard clippedX1 < clippedX2, clippedY1 < clippedY2 else {
                continue
            }
            guard let inputFrame = try? SnapshotPixelRect(
                x: clippedX1 * width,
                y: clippedY1 * height,
                width: (clippedX2 - clippedX1) * width,
                height: (clippedY2 - clippedY1) * height
            ) else {
                throw ElementAnalyzerError.invalidResponse
            }
            guard type == "icon" || interactive else { continue }
            detections.append(.init(
                confidence: nil,
                inputFrame: inputFrame
            ))
        }
        let elapsed = UInt64((latencySeconds * 1_000).rounded())
        return OmniParserDetectorResponse(
            backend: currentBackend,
            detections: detections,
            timings: .init(
                inferenceMilliseconds: elapsed,
                queueWaitMilliseconds: 0,
                totalMilliseconds: elapsed
            ),
            version: nil
        )
    }

    private func decodeDetectorResponse(
        _ data: Data,
        requestID: String,
        snapshotID: String,
        geometry: SnapshotDerivedImageGeometry,
        profileID: String
    ) throws -> OmniParserDetectorResponse {
        guard let model,
              data.count <= min(
                Int(maximumResponseBytes),
                OmniParserAnalyzer.maximumResponseBytes
              ),
              let root = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
              Set(root.keys) == Set([
                "detections", "input", "model", "outcome", "preprocess",
                "requestID", "schema", "snapshotID", "timings",
              ]),
              root["schema"] as? String == Self.responseSchema,
              root["outcome"] as? String == "succeeded",
              root["requestID"] as? String == requestID,
              root["snapshotID"] as? String == snapshotID,
              let input = root["input"] as? [String: Any],
              Set(input.keys) == Set(["height", "profileID", "width"]),
              Self.uint(input["width"]) == geometry.inputDimensions.width,
              Self.uint(input["height"]) == geometry.inputDimensions.height,
              input["profileID"] as? String == profileID,
              let responseModelObject = root["model"] as? [String: Any],
              let responseModel = decodeResponseModel(responseModelObject),
              responseModel.name == model.name,
              responseModel.version == model.version,
              responseModel.imageSize == model.imageSize,
              backends.contains(responseModel.backend),
              let preprocess = root["preprocess"] as? [String: Any],
              validPreprocess(
                preprocess,
                inputDimensions: geometry.inputDimensions,
                modelImageSize: responseModel.imageSize
              ),
              let timingsObject = root["timings"] as? [String: Any],
              let timings = decodeTimings(timingsObject),
              let rawDetections = root["detections"] as? [Any],
              rawDetections.count <= min(Int(maximumDetections), 2_048)
        else {
            throw ElementAnalyzerError.invalidResponse
        }

        let inputBounds = try SnapshotPixelRect(
            x: 0,
            y: 0,
            width: Double(geometry.inputDimensions.width),
            height: Double(geometry.inputDimensions.height)
        )
        var detections = [OmniParserDetectorResponse.Detection]()
        detections.reserveCapacity(rawDetections.count)
        for raw in rawDetections {
            guard let object = raw as? [String: Any],
                  Set(object.keys) == Set(["box", "confidence"]),
                  let confidence = Self.double(object["confidence"]),
                  (0...1).contains(confidence),
                  let box = object["box"] as? [String: Any],
                  Set(box.keys) == Set(["height", "width", "x", "y"]),
                  let x = Self.double(box["x"]),
                  let y = Self.double(box["y"]),
                  let width = Self.double(box["width"]),
                  let height = Self.double(box["height"]),
                  let rect = try? SnapshotPixelRect(
                    x: x,
                    y: y,
                    width: width,
                    height: height
                  ),
                  rect.intersection(inputBounds) == rect
            else {
                throw ElementAnalyzerError.invalidResponse
            }
            detections.append(.init(
                confidence: confidence,
                inputFrame: rect
            ))
        }
        return OmniParserDetectorResponse(
            backend: responseModel.backend,
            detections: detections,
            timings: timings,
            version: responseModel.version
        )
    }

    private static func decodeProbeModel(
        _ object: [String: Any]
    ) -> (OmniParserServiceModel, Set<String>)? {
        guard Set(object.keys) == Set([
            "backends", "imageSize", "name", "version",
        ]),
              object["name"] as? String == detectorName,
              let version = token(object["version"]),
              let imageSize = uint(object["imageSize"]),
              (64...4_096).contains(imageSize),
              let rawBackends = object["backends"] as? [Any],
              !rawBackends.isEmpty,
              rawBackends.count <= 2
        else { return nil }
        let backends = Set(rawBackends.compactMap { $0 as? String })
        guard backends.count == rawBackends.count,
              backends.isSubset(of: ["cpu", "mps"])
        else { return nil }
        let preferred = backends.contains("mps") ? "mps" : "cpu"
        return (
            OmniParserServiceModel(
                backend: preferred,
                imageSize: imageSize,
                name: detectorName,
                version: version
            ),
            backends
        )
    }

    private func decodeResponseModel(
        _ object: [String: Any]
    ) -> OmniParserServiceModel? {
        guard Set(object.keys) == Set([
            "backend", "imageSize", "name", "version",
        ]),
              object["name"] as? String == Self.detectorName,
              let version = Self.token(object["version"]),
              let backend = object["backend"] as? String,
              ["cpu", "mps"].contains(backend),
              let imageSize = Self.uint(object["imageSize"]),
              (64...4_096).contains(imageSize)
        else { return nil }
        return OmniParserServiceModel(
            backend: backend,
            imageSize: imageSize,
            name: Self.detectorName,
            version: version
        )
    }

    private func validPreprocess(
        _ object: [String: Any],
        inputDimensions: SnapshotImageDimensions,
        modelImageSize: UInt64
    ) -> Bool {
        guard Set(object.keys) == Set([
            "inputHeight", "inputWidth", "modelHeight", "modelWidth",
            "scaleX", "scaleY", "translateX", "translateY",
        ]),
              Self.uint(object["inputWidth"]) == inputDimensions.width,
              Self.uint(object["inputHeight"]) == inputDimensions.height,
              let modelWidth = Self.uint(object["modelWidth"]),
              let modelHeight = Self.uint(object["modelHeight"]),
              modelWidth > 0,
              modelHeight > 0,
              modelWidth <= modelImageSize,
              modelHeight <= modelImageSize,
              let scaleX = Self.double(object["scaleX"]),
              let scaleY = Self.double(object["scaleY"]),
              scaleX > 0,
              scaleY > 0,
              let translateX = Self.double(object["translateX"]),
              let translateY = Self.double(object["translateY"]),
              translateX >= 0,
              translateY >= 0,
              Double(inputDimensions.width) * scaleX + translateX
                <= Double(modelWidth) + 0.001,
              Double(inputDimensions.height) * scaleY + translateY
                <= Double(modelHeight) + 0.001
        else { return false }
        return true
    }

    private func decodeTimings(
        _ object: [String: Any]
    ) -> OmniParserDetectorResponse.Timings? {
        guard Set(object.keys) == Set([
            "inferenceMilliseconds", "queueWaitMilliseconds",
            "totalMilliseconds",
        ]),
              let queue = Self.uint(object["queueWaitMilliseconds"]),
              let inference = Self.uint(object["inferenceMilliseconds"]),
              let total = Self.uint(object["totalMilliseconds"]),
              queue <= 60_000,
              inference <= 60_000,
              total <= 60_000,
              queue <= total,
              inference <= total - queue
        else { return nil }
        return .init(
            inferenceMilliseconds: inference,
            queueWaitMilliseconds: queue,
            totalMilliseconds: total
        )
    }

    private static func uint(_ value: Any?) -> UInt64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID()
        else { return nil }
        let double = number.doubleValue
        guard double.isFinite,
              double >= 0,
              double.rounded(.towardZero) == double,
              double <= Double(UInt64.max)
        else { return nil }
        return UInt64(double)
    }

    private static func double(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite
        else { return nil }
        return number.doubleValue
    }

    private static func boundedString(
        _ value: Any?,
        maximumBytes: Int
    ) -> String? {
        guard let value = value as? String,
              value.utf8.count <= maximumBytes
        else { return nil }
        return value
    }

    private static func token(_ value: Any?) -> String? {
        guard let value = value as? String,
              !value.isEmpty,
              value.utf8.count <= 128,
              value.unicodeScalars.allSatisfy({
                $0.isASCII && ($0.value == 45 || $0.value == 46
                    || $0.value == 95 || (48...57).contains($0.value)
                    || (65...90).contains($0.value)
                    || (97...122).contains($0.value))
              })
        else { return nil }
        return value
    }
}

struct OmniParserDetectorResponse: Equatable, Sendable {
    struct Detection: Equatable, Sendable {
        let confidence: Double?
        let inputFrame: SnapshotPixelRect
    }

    struct Timings: Equatable, Sendable {
        let inferenceMilliseconds: UInt64
        let queueWaitMilliseconds: UInt64
        let totalMilliseconds: UInt64
    }

    let backend: String?
    let detections: [Detection]
    let timings: Timings
    let version: String?
}
