import CoreGraphics
import Darwin
import Foundation
import ImageIO
@testable import PulsePhoneElement
import PulsePhoneHostPaths
import PulsePhoneMedia
import PulsePhoneSharedDefinitions
import XCTest

final class ElementAnalyzerTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.handler = nil
        super.tearDown()
    }

    func testEndpointConfigurationIsDisabledUntilConfigured() throws {
        XCTAssertNil(try OmniParserEndpointConfiguration.resolve(
            environment: [:],
            managedEndpoint: nil
        ))

        let override = try XCTUnwrap(OmniParserEndpointConfiguration.resolve(
            environment: [
            OmniParserEndpointConfiguration.environmentKey:
                "https://omni.example.test:8443/v3/parse/",
            ],
            managedEndpoint: "http://ignored.example.test/parse/"
        ))
        XCTAssertEqual(override.endpoint.absoluteString, "https://omni.example.test:8443/v3/parse/")
        XCTAssertEqual(override.redactedHost, "omni.example.test:8443")
        XCTAssertEqual(override.source, .environment)
        XCTAssertEqual(override.networkScope, .configured)
        XCTAssertTrue(override.usesTLS)

        let managed = try XCTUnwrap(OmniParserEndpointConfiguration.resolve(
            environment: [:],
            managedEndpoint: "http://192.168.1.143:8000/parse/"
        ))
        XCTAssertEqual(managed.source, .managedConfiguration)
        XCTAssertEqual(managed.networkScope, .configured)

        let ipv6 = try OmniParserEndpointConfiguration(
            endpointString: "http://[::1]:8000/parse/",
            source: .environment
        )
        XCTAssertEqual(ipv6.redactedHost, "[::1]:8000")
        XCTAssertEqual(ipv6.networkScope, .loopback)

        XCTAssertNoThrow(try OmniParserEndpointConfiguration(
            endpointString: "http://omni.example.test/parse/",
            source: .environment
        ))

        for invalid in [
            "",
            " ftp://example.test/parse/",
            "ftp://example.test/parse/",
            "https://user:secret@example.test/parse/",
            "https://example.test/parse/?token=secret",
            "https://example.test/parse/#fragment",
        ] {
            XCTAssertThrowsError(try OmniParserEndpointConfiguration(
                endpointString: invalid,
                source: .environment
            )) { error in
                XCTAssertEqual(error as? ElementAnalyzerError, .invalidEndpoint)
            }
        }
    }

    func testManagedEndpointRequiresAStringConfigurationValue() {
        let snapshot = PulsePhoneConfigurationSnapshot(values: [
            PulsePhoneConfigurationKey.omniParserEndpoint.rawValue: .boolean(true),
        ])

        XCTAssertThrowsError(
            try PulsePhoneConfigurationRegistry.omniParserEndpoint(in: snapshot)
        ) { error in
            XCTAssertEqual(
                error as? PulsePhoneConfigurationRegistryError,
                .invalidValue
            )
        }
    }

    func testOmniProductionSessionDoesNotRetainProxyCookieOrCredentials() {
        let configuration = OmniParserAnalyzer.productionSessionConfiguration()

        XCTAssertEqual(configuration.connectionProxyDictionary?.count, 0)
        XCTAssertEqual(configuration.httpCookieAcceptPolicy, .never)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertFalse(configuration.httpShouldSetCookies)
        XCTAssertNil(configuration.urlCache)
        XCTAssertNil(configuration.urlCredentialStorage)
        XCTAssertEqual(configuration.httpMaximumConnectionsPerHost, 1)
        XCTAssertEqual(
            configuration.requestCachePolicy,
            .reloadIgnoringLocalCacheData
        )
    }

    func testOmniProductionSessionRejectsRedirectAndCredentialChallenge()
        throws
    {
        let delegate = OmniParserSessionDelegate()
        let session = URLSession(configuration: .ephemeral)
        let originalURL = try XCTUnwrap(URL(string: "https://omni.example.test/parse/"))
        let task = session.dataTask(with: originalURL)
        let response = try XCTUnwrap(HTTPURLResponse(
            url: originalURL,
            statusCode: 307,
            httpVersion: "HTTP/1.1",
            headerFields: ["Location": "https://other.example.test/parse/"]
        ))
        var redirectedRequest: URLRequest? = URLRequest(
            url: try XCTUnwrap(URL(string: "https://other.example.test/parse/"))
        )
        delegate.urlSession(
            session,
            task: task,
            willPerformHTTPRedirection: response,
            newRequest: try XCTUnwrap(redirectedRequest)
        ) { redirectedRequest = $0 }
        XCTAssertNil(redirectedRequest)

        let protectionSpace = URLProtectionSpace(
            host: "omni.example.test",
            port: 443,
            protocol: "https",
            realm: "test",
            authenticationMethod: NSURLAuthenticationMethodHTTPBasic
        )
        let challenge = URLAuthenticationChallenge(
            protectionSpace: protectionSpace,
            proposedCredential: URLCredential(
                user: "user",
                password: "secret",
                persistence: .none
            ),
            previousFailureCount: 0,
            failureResponse: nil,
            error: nil,
            sender: TestAuthenticationChallengeSender()
        )
        var disposition: URLSession.AuthChallengeDisposition?
        delegate.urlSession(
            session,
            task: task,
            didReceive: challenge
        ) { value, _ in disposition = value }
        XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
        session.invalidateAndCancel()
    }

    func testOmniClientGenerationReusesRetiresAndRedactsConfiguration()
        async throws
    {
        let endpoint = LockedOmniEndpoint(
            "https://first.omni.example.test/parse/"
        )
        let requests = RequestRecorder()
        StubURLProtocol.handler = { request in
            requests.record(request, body: try requestBody(request))
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!,
                try omniCurrentResponseData()
            )
        }
        let manager = OmniParserClientGenerationManager(
            configurationProvider: {
                try OmniParserEndpointConfiguration(
                    endpointString: endpoint.value,
                    source: .environment
                )
            },
            analyzerFactory: { configuration in
                let sessionConfiguration = URLSessionConfiguration.ephemeral
                sessionConfiguration.protocolClasses = [StubURLProtocol.self]
                return OmniParserAnalyzer(
                    configuration: configuration,
                    renderer: ElementImageRenderer(),
                    session: URLSession(configuration: sessionConfiguration)
                )
            }
        )
        let frame = try makeFrame(image: makeBlankImage(width: 32, height: 64))

        let first = await manager.analyze(frame)
        let second = await manager.analyze(frame)
        XCTAssertEqual(first.status, .succeeded)
        XCTAssertEqual(second.status, .succeeded)
        var snapshot = await manager.snapshot()
        XCTAssertEqual(snapshot.generation, 1)
        XCTAssertEqual(snapshot.initializationCount, 1)
        XCTAssertEqual(snapshot.retirementCount, 0)
        XCTAssertEqual(snapshot.redactedHost, "first.omni.example.test")
        XCTAssertEqual(snapshot.networkScope, .configured)
        XCTAssertEqual(snapshot.configurationSource, .environment)

        endpoint.value = "https://second.omni.example.test/v3/parse/"
        let replaced = await manager.analyze(frame)
        XCTAssertEqual(replaced.status, .succeeded)
        snapshot = await manager.snapshot()
        XCTAssertEqual(snapshot.generation, 2)
        XCTAssertEqual(snapshot.initializationCount, 2)
        XCTAssertEqual(snapshot.retirementCount, 1)
        XCTAssertEqual(snapshot.redactedHost, "second.omni.example.test")

        endpoint.value = "https://user:secret@omni.example.test/parse/"
        let invalid = await manager.analyze(frame)
        XCTAssertEqual(invalid.status, .unavailable)
        snapshot = await manager.snapshot()
        XCTAssertEqual(snapshot.configurationFailureCount, 1)
        XCTAssertEqual(snapshot.generation, 2)
        XCTAssertEqual(snapshot.retirementCount, 2)
        XCTAssertNil(snapshot.redactedHost)
        XCTAssertEqual(
            requests.hosts,
            [
                "first.omni.example.test",
                "first.omni.example.test",
                "second.omni.example.test",
            ]
        )

        await manager.shutdown()
        let stopped = await manager.analyze(frame)
        XCTAssertEqual(stopped.status, .unavailable)
    }

    func testOmniEndpointHasNoBuiltInNetworkDefault() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let literal = "192.168." + "1.142:8000"
        var matches = [String]()
        for directory in ["Sources", "Tests"] {
            let directoryURL = root.appendingPathComponent(directory)
            let enumerator = try XCTUnwrap(
                FileManager.default.enumerator(
                    at: directoryURL,
                    includingPropertiesForKeys: [.isRegularFileKey]
                )
            )
            for case let file as URL in enumerator {
                guard ["swift", "py"].contains(file.pathExtension),
                      let contents = try? String(contentsOf: file, encoding: .utf8),
                      contents.contains(literal)
                else { continue }
                matches.append(file.path.replacingOccurrences(
                    of: root.path + "/",
                    with: ""
                ))
            }
        }
        XCTAssertTrue(matches.isEmpty)
    }

    func testOmniResponseMapsPixelInputBoxBackToSourcePixels() throws {
        let source = try SnapshotImageDimensions(width: 1_179, height: 2_556)
        let geometry = try ElementAnalyzerProfiles.omniparser.geometry(
            sourceDimensions: source
        )
        let expected = try SnapshotPixelRect(
            x: 117.9,
            y: 511.2,
            width: 353.7,
            height: 766.8
        )
        let input = try XCTUnwrap(geometry.mapSourceRectToInput(expected))
        let capability = try OmniParserServiceCapability.decodeProbe(
            omniProbeData()
        )
        let response = try capability.decodeResponse(
            omniDetectorResponseData(
                requestID: "request-1",
                snapshotID: "snapshot-1",
                width: geometry.inputDimensions.width,
                height: geometry.inputDimensions.height,
                profileID: ElementAnalyzerProfiles.omniparser.profileID,
                detections: [(input, 0.81)]
            ),
            requestID: "request-1",
            snapshotID: "snapshot-1",
            geometry: geometry,
            profileID: ElementAnalyzerProfiles.omniparser.profileID
        )
        let detection = try XCTUnwrap(response.detections.first)
        let mapped = try XCTUnwrap(
            geometry.mapInputRectToSource(detection.inputFrame)
        )
        XCTAssertEqual(response.detections.count, 1)
        XCTAssertEqual(detection.confidence, 0.81)
        XCTAssertEqual(mapped.x, expected.x, accuracy: 0.001)
        XCTAssertEqual(mapped.y, expected.y, accuracy: 0.001)
        XCTAssertEqual(mapped.width, expected.width, accuracy: 0.001)
        XCTAssertEqual(mapped.height, expected.height, accuracy: 0.001)
    }

    func testOmniResponseRejectsErrorAndOversizedDocuments() throws {
        let dimensions = try SnapshotImageDimensions(width: 100, height: 200)
        let geometry = try ElementAnalyzerProfiles.omniparser.geometry(
            sourceDimensions: dimensions
        )
        let capability = try OmniParserServiceCapability.decodeProbe(
            omniProbeData()
        )
        let invalid = try JSONSerialization.data(withJSONObject: [
            "detail": "model unavailable",
        ])
        XCTAssertThrowsError(try capability.decodeResponse(
            invalid,
            requestID: "request-1",
            snapshotID: "snapshot-1",
            geometry: geometry,
            profileID: ElementAnalyzerProfiles.omniparser.profileID
        ))

        let oversized = Data(
            repeating: 0x20,
            count: OmniParserAnalyzer.maximumResponseBytes + 1
        )
        XCTAssertThrowsError(try capability.decodeResponse(
            oversized,
            requestID: "request-1",
            snapshotID: "snapshot-1",
            geometry: geometry,
            profileID: ElementAnalyzerProfiles.omniparser.profileID
        )) { error in
            XCTAssertEqual(error as? ElementAnalyzerError, .invalidResponse)
        }
    }

    func testOmniCurrentProtocolRejectsMalformedRowsAndUnorderedBoxes() throws {
        let geometry = try ElementAnalyzerProfiles.omniparser.geometry(
            sourceDimensions: try SnapshotImageDimensions(width: 100, height: 200)
        )
        let capability = OmniParserServiceCapability.currentParse()
        for bbox: [Any] in [
            [0.2, 0.1, 0.2, 0.3],
            [0.1, 0.3, 0.2, 0.2],
            [0.1, 0.2, 0.3],
        ] {
            let data = try JSONSerialization.data(withJSONObject: [
                "latency": 0.1,
                "parsed_content_list": [[
                    "bbox": bbox,
                    "content": "icon",
                    "interactivity": true,
                    "source": "box_yolo_content_yolo",
                    "type": "icon",
                ]],
            ])
            XCTAssertThrowsError(try capability.decodeResponse(
                data,
                requestID: "ignored",
                snapshotID: "ignored",
                geometry: geometry,
                profileID: ElementAnalyzerProfiles.omniparser.profileID
            ))
        }
    }

    func testOmniCurrentProtocolClipsIntersectingBoxesAndDropsOutsideRows()
        throws
    {
        let geometry = try ElementAnalyzerProfiles.omniparser.geometry(
            sourceDimensions: try SnapshotImageDimensions(width: 100, height: 200)
        )
        let capability = OmniParserServiceCapability.currentParse()
        let boxes: [[Double]] = [
            [-0.25, 0.125, 0.25, 0.25],
            [0.75, 0.875, 1.25, 1.25],
            [-2, 0.1, -1, 0.2],
            [2, 0.1, 3, 0.2],
            [0.1, -1, 0.2, 0],
        ]
        let rows = boxes.map { bbox in
            [
                "bbox": bbox,
                "content": "icon",
                "interactivity": true,
                "source": "box_yolo_content_yolo",
                "type": "icon",
            ] as [String: Any]
        }
        let data = try JSONSerialization.data(withJSONObject: [
            "latency": 0.1,
            "parsed_content_list": rows,
        ])

        let response = try capability.decodeResponse(
            data,
            requestID: "ignored",
            snapshotID: "ignored",
            geometry: geometry,
            profileID: ElementAnalyzerProfiles.omniparser.profileID
        )

        XCTAssertEqual(response.detections.map(\.inputFrame), [
            try SnapshotPixelRect(x: 0, y: 25, width: 25, height: 25),
            try SnapshotPixelRect(x: 75, y: 175, width: 25, height: 25),
        ])
    }

    func testOmniProtocolRejectsMismatchedVersionBoundsAndTiming() throws {
        let dimensions = try SnapshotImageDimensions(width: 100, height: 200)
        let geometry = try ElementAnalyzerProfiles.omniparser.geometry(
            sourceDimensions: dimensions
        )
        let capability = try OmniParserServiceCapability.decodeProbe(
            omniProbeData()
        )
        let base = try omniDetectorResponseData(
            requestID: "request-1",
            snapshotID: "snapshot-1",
            width: geometry.inputDimensions.width,
            height: geometry.inputDimensions.height,
            profileID: ElementAnalyzerProfiles.omniparser.profileID
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: base) as? [String: Any]
        )
        var invalidDocuments = [Data]()

        var wrongVersion = object
        var model = try XCTUnwrap(wrongVersion["model"] as? [String: Any])
        model["version"] = "4.0.0"
        wrongVersion["model"] = model
        invalidDocuments.append(try JSONSerialization.data(
            withJSONObject: wrongVersion
        ))

        invalidDocuments.append(try omniDetectorResponseData(
            requestID: "request-1",
            snapshotID: "snapshot-1",
            width: geometry.inputDimensions.width,
            height: geometry.inputDimensions.height,
            profileID: ElementAnalyzerProfiles.omniparser.profileID,
            detections: [(try SnapshotPixelRect(
                x: 99,
                y: 0,
                width: 2,
                height: 1
            ), 0.5)]
        ))

        var impossibleTiming = object
        impossibleTiming["timings"] = [
            "inferenceMilliseconds": 2,
            "queueWaitMilliseconds": 2,
            "totalMilliseconds": 3,
        ]
        invalidDocuments.append(try JSONSerialization.data(
            withJSONObject: impossibleTiming
        ))

        var extraField = object
        extraField["legacy"] = true
        invalidDocuments.append(try JSONSerialization.data(
            withJSONObject: extraField
        ))

        for invalid in invalidDocuments {
            XCTAssertThrowsError(try capability.decodeResponse(
                invalid,
                requestID: "request-1",
                snapshotID: "snapshot-1",
                geometry: geometry,
                profileID: ElementAnalyzerProfiles.omniparser.profileID
            ))
        }
    }

    func testRendererPreservesPixelOrientationAndDimensions() throws {
        let sourceImage = try makeQuadrantImage(width: 16, height: 24)
        let sourcePixels = try rgbaPixels(sourceImage)
        let lease = try SnapshotSourceImageLease(cgImage: sourceImage)
        let profile = try SnapshotDerivedImageProfile(
            profileID: "renderer-orientation.v1",
            resize: .longestEdge(12),
            colorSpace: .sRGB,
            encoding: .png
        )
        let geometry = try profile.geometry(sourceDimensions: lease.dimensions)
        let payload = try ElementImageRenderer().renderPNG(
            source: lease,
            geometry: geometry
        )
        XCTAssertEqual(payload.dimensions.width, 8)
        XCTAssertEqual(payload.dimensions.height, 12)
        let decoded = try decodeCGImage(payload.bytes)
        let outputPixels = try rgbaPixels(decoded)

        XCTAssertEqual(quadrantColor(sourcePixels, width: 16, height: 24, x: 4, y: 6),
                       quadrantColor(outputPixels, width: 8, height: 12, x: 2, y: 3))
        XCTAssertEqual(quadrantColor(sourcePixels, width: 16, height: 24, x: 12, y: 6),
                       quadrantColor(outputPixels, width: 8, height: 12, x: 6, y: 3))
        XCTAssertEqual(quadrantColor(sourcePixels, width: 16, height: 24, x: 4, y: 18),
                       quadrantColor(outputPixels, width: 8, height: 12, x: 2, y: 9))
        XCTAssertEqual(quadrantColor(sourcePixels, width: 16, height: 24, x: 12, y: 18),
                       quadrantColor(outputPixels, width: 8, height: 12, x: 6, y: 9))
    }

    func testRendererDecodeFailureDoesNotPoisonDerivedImageRetry() async throws {
        let valid = try makeFrame(image: makeBlankImage(width: 16, height: 24))
        let frame = try SnapshotFrame(
            authority: valid.authority,
            metadata: valid.metadata,
            sourceImage: SnapshotSourceImageLease(
                encodedBytes: [0x00, 0x01, 0x02],
                contentType: "image/png",
                dimensions: valid.metadata.pixelDimensions
            )
        )
        let profile = try SnapshotDerivedImageProfile(
            profileID: "renderer-failure-retry.v1",
            resize: .source,
            colorSpace: .sRGB,
            encoding: .png
        )
        do {
            _ = try await frame.derivedImage(
                for: profile,
                materialize: ElementImageRenderer().pngMaterializer()
            )
            XCTFail("invalid encoded input must fail")
        } catch {
            XCTAssertEqual(error as? ElementAnalyzerError, .imageDecodeFailed)
        }

        let recovered = try await frame.derivedImage(for: profile) { _, geometry in
            try SnapshotDerivedImagePayload(
                bytes: [9],
                contentType: "image/png",
                dimensions: geometry.inputDimensions
            )
        }
        XCTAssertEqual(recovered.payload.bytes, [9])
    }

    func testOmniAnalyzerReusesSessionAndReturnsMappedCandidates() async throws {
        let requests = RequestRecorder()
        StubURLProtocol.handler = { request in
            requests.record(request, body: try requestBody(request))
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = request.httpMethod == "GET"
                ? try omniProbeData()
                : try omniDetectorResponseData(
                    for: request,
                    detections: [
                        (try SnapshotPixelRect(
                            x: 3,
                            y: 6,
                            width: 4,
                            height: 7
                        ), 0.92),
                    ]
                )
            return (response, data)
        }
        let analyzer = OmniParserAnalyzer(
            configuration: try OmniParserEndpointConfiguration(
                endpointString: "https://omni.example.test/parse/",
                source: .environment
            ),
            renderer: ElementImageRenderer(),
            session: stubSession(),
            protocolMode: .detectorProbe
        )
        let frame = try makeFrame(image: makeQuadrantImage(width: 32, height: 64))
        let first = await analyzer.analyze(frame)
        let second = await analyzer.analyze(frame)

        XCTAssertEqual(first.status, .succeeded)
        XCTAssertEqual(first.candidates.count, 1)
        XCTAssertEqual(first.backend, "mps")
        XCTAssertEqual(first.version, "3.0.0-test")
        XCTAssertEqual(first.inferenceMilliseconds, 2)
        XCTAssertNotNil(first.queueWaitMilliseconds)
        XCTAssertNotNil(first.stageTimings.resizeAndColorSpaceMicroseconds)
        XCTAssertNotNil(first.stageTimings.inputEncodeMicroseconds)
        XCTAssertNotNil(first.stageTimings.requestEncodeMicroseconds)
        XCTAssertNotNil(first.stageTimings.responseDecodeMicroseconds)
        XCTAssertNotNil(first.stageTimings.transportRoundTripMicroseconds)
        XCTAssertLessThanOrEqual(
            first.stageTimings.transportOverheadMicroseconds ?? .max,
            first.stageTimings.transportRoundTripMicroseconds ?? 0
        )
        XCTAssertEqual(second.status, .succeeded)
        XCTAssertEqual(requests.count, 3)
        XCTAssertEqual(requests.methods, ["GET", "POST", "POST"])
        let snapshot = await analyzer.snapshot()
        XCTAssertEqual(snapshot.probeCount, 1)
        XCTAssertEqual(snapshot.requestCount, 2)
        let body = try XCTUnwrap(requests.lastBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(
            json["schema"] as? String,
            "pulsephone.omniparser.detector-request.v1"
        )
        XCTAssertEqual(
            json["protocol"] as? String,
            OmniParserServiceCapability.detectorProtocol
        )
        let input = try XCTUnwrap(json["input"] as? [String: Any])
        XCTAssertNotNil(input["base64"] as? String)
        XCTAssertEqual(
            input["profileID"] as? String,
            ElementAnalyzerProfiles.omniparser.profileID
        )
        let options = try XCTUnwrap(json["options"] as? [String: Any])
        XCTAssertEqual(options["detectorOnly"] as? Bool, true)
        XCTAssertEqual(options["includeOCR"] as? Bool, false)
        XCTAssertEqual(options["includeCaption"] as? Bool, false)
    }

    func testOmniCurrentParseProtocolUploadsAndMapsOnlyControlRows() async throws {
        let requests = RequestRecorder()
        StubURLProtocol.handler = { request in
            requests.record(request, body: try requestBody(request))
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (
                response,
                try omniCurrentResponseData()
            )
        }
        let frame = try makeFrame(image: makeQuadrantImage(width: 32, height: 64))
        let analyzer = makeOmniAnalyzer()
        let result = await analyzer.analyze(frame)

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.backend, "http")
        XCTAssertNil(result.version)
        XCTAssertEqual(result.inferenceMilliseconds, 250)
        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertTrue(result.candidates.allSatisfy {
            $0.type == .controlCandidate && $0.confidence == nil
        })
        XCTAssertEqual(requests.methods, ["POST"])
        let snapshot = await analyzer.snapshot()
        XCTAssertEqual(snapshot.probeCount, 0)
        let body = try XCTUnwrap(requests.lastBody)
        let json = try XCTUnwrap(
            JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(Set(json.keys), Set([
            "base64_image", "box_threshold", "iou_threshold", "response_mode",
        ]))
        XCTAssertNotNil(json["base64_image"] as? String)
        XCTAssertEqual(json["response_mode"] as? String, "json")
        XCTAssertEqual(json["box_threshold"] as? String, "0.05")
        XCTAssertEqual(json["iou_threshold"] as? String, "0.7")
    }

    func testOmniReportsCPUFallbackFromVersionedResponse() async throws {
        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            if request.httpMethod == "GET" {
                return (response, try omniProbeData())
            }
            return (response, try omniDetectorResponseData(
                for: request,
                backend: "cpu"
            ))
        }
        let frame = try makeFrame(image: makeBlankImage(width: 32, height: 64))
        let result = await makeOmniAnalyzer(
            protocolMode: .detectorProbe
        ).analyze(frame)

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertEqual(result.backend, "cpu")
        XCTAssertEqual(result.version, "3.0.0-test")
    }

    func testOmniSerializesRequestsAndSharesCapabilityProbe() async throws {
        let concurrency = ConcurrentRequestProbe()
        let requests = RequestRecorder()
        StubURLProtocol.handler = { request in
            requests.record(request, body: try requestBody(request))
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            if request.httpMethod == "GET" {
                return (response, try omniProbeData())
            }
            concurrency.begin()
            defer { concurrency.end() }
            Thread.sleep(forTimeInterval: 0.03)
            return (response, try omniDetectorResponseData(for: request))
        }
        let analyzer = makeOmniAnalyzer(protocolMode: .detectorProbe)
        let frame = try makeFrame(image: makeBlankImage(width: 32, height: 64))
        async let first = analyzer.analyze(frame)
        async let second = analyzer.analyze(frame)
        let results = await [first, second]

        XCTAssertTrue(results.allSatisfy { $0.status == .succeeded })
        XCTAssertTrue(results.allSatisfy { $0.inferenceMilliseconds == 2 })
        XCTAssertGreaterThanOrEqual(
            results.compactMap(\.queueWaitMilliseconds).max() ?? 0,
            20
        )
        XCTAssertEqual(requests.methods, ["GET", "POST", "POST"])
        XCTAssertEqual(concurrency.maximum, 1)
        let snapshot = await analyzer.snapshot()
        XCTAssertEqual(snapshot.probeCount, 1)
        XCTAssertEqual(snapshot.requestCount, 2)
    }

    func testOmniCircuitOpensWithoutUploadingAndRecoversWithProbe() async throws {
        let healthy = LockedBool(false)
        let requests = RequestRecorder()
        StubURLProtocol.handler = { request in
            requests.record(request, body: try requestBody(request))
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            if request.httpMethod == "GET" {
                let data = healthy.value
                    ? try omniProbeData()
                    : try JSONSerialization.data(withJSONObject: [
                        "message": "Omniparser API ready",
                    ])
                return (response, data)
            }
            return (response, try omniDetectorResponseData(for: request))
        }
        let analyzer = OmniParserAnalyzer(
            configuration: try OmniParserEndpointConfiguration(
                endpointString: "https://omni.example.test/parse/",
                source: .environment
            ),
            circuitPolicy: OmniParserCircuitPolicy(
                failureThreshold: 2,
                openDuration: .milliseconds(20)
            ),
            renderer: ElementImageRenderer(),
            session: stubSession(),
            protocolMode: .detectorProbe
        )
        let frame = try makeFrame(image: makeBlankImage(width: 32, height: 64))

        let first = await analyzer.analyze(frame)
        let second = await analyzer.analyze(frame)
        let open = await analyzer.analyze(frame)
        XCTAssertEqual(first.status, .unavailable)
        XCTAssertEqual(second.status, .unavailable)
        XCTAssertEqual(open.status, .circuitOpen)
        XCTAssertEqual(requests.methods, ["GET", "GET"])

        healthy.value = true
        try await Task.sleep(for: .milliseconds(30))
        let recovered = await analyzer.analyze(frame)
        XCTAssertEqual(recovered.status, .succeeded)
        XCTAssertEqual(requests.methods, ["GET", "GET", "GET", "POST"])
        let snapshot = await analyzer.snapshot()
        XCTAssertFalse(snapshot.circuitOpen)
        XCTAssertEqual(snapshot.consecutiveFailures, 0)
    }

    func testOmniQueuedRequestObservesCircuitOpenedByPredecessor() async throws {
        let requests = RequestRecorder()
        StubURLProtocol.handler = { request in
            requests.record(request, body: try requestBody(request))
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "application/json"]
                )!,
                try JSONSerialization.data(withJSONObject: [
                    "message": "Omniparser API ready",
                ])
            )
        }
        let analyzer = OmniParserAnalyzer(
            configuration: try OmniParserEndpointConfiguration(
                endpointString: "https://omni.example.test/parse/",
                source: .environment
            ),
            circuitPolicy: OmniParserCircuitPolicy(
                failureThreshold: 1,
                openDuration: .seconds(1)
            ),
            renderer: ElementImageRenderer(),
            session: stubSession(),
            protocolMode: .detectorProbe
        )
        let frame = try makeFrame(image: makeBlankImage(width: 32, height: 64))
        async let first = analyzer.analyze(frame)
        async let second = analyzer.analyze(frame)
        let results = await [first, second]

        XCTAssertEqual(
            results.map(\.status).sorted { $0.rawValue < $1.rawValue },
            [ElementAnalyzerStatus.circuitOpen, .unavailable]
                .sorted { $0.rawValue < $1.rawValue }
        )
        XCTAssertEqual(requests.methods, ["GET"])
    }

    func testOmniAnalyzerClassifiesTimeoutAndResponseCap() async throws {
        let frame = try makeFrame(image: makeQuadrantImage(width: 32, height: 64))
        StubURLProtocol.handler = { _ in
            throw URLError(.timedOut)
        }
        let timedOut = await makeOmniAnalyzer().analyze(frame)
        XCTAssertEqual(timedOut.status, .timedOut)

        StubURLProtocol.handler = { request in
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: nil,
                headerFields: nil
            )!
            if request.httpMethod == "GET" {
                return (response, try omniProbeData())
            }
            return (response, Data(
                repeating: 0x20,
                count: OmniParserAnalyzer.maximumResponseBytes + 1
            ))
        }
        let oversized = await makeOmniAnalyzer().analyze(frame)
        XCTAssertEqual(oversized.status, .failed)
    }

    func testOmniReconnectsWithFreshProbeAfterTransportDisconnect()
        async throws
    {
        let requests = RequestRecorder()
        StubURLProtocol.handler = { request in
            requests.record(request, body: try requestBody(request))
            if request.httpMethod == "POST",
               requests.methods.filter({ $0 == "POST" }).count == 1
            {
                throw URLError(.networkConnectionLost)
            }
            let response = HTTPURLResponse(
                url: try XCTUnwrap(request.url),
                statusCode: 200,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let data = request.httpMethod == "GET"
                ? try omniProbeData()
                : try omniDetectorResponseData(for: request)
            return (response, data)
        }
        let analyzer = makeOmniAnalyzer(protocolMode: .detectorProbe)
        let frame = try makeFrame(image: makeBlankImage(width: 32, height: 64))

        let disconnected = await analyzer.analyze(frame)
        let recovered = await analyzer.analyze(frame)

        XCTAssertEqual(disconnected.status, .failed)
        XCTAssertEqual(recovered.status, .succeeded)
        XCTAssertEqual(
            requests.methods,
            ["GET", "POST", "GET", "POST"]
        )
        let snapshot = await analyzer.snapshot()
        XCTAssertEqual(snapshot.probeCount, 2)
        XCTAssertEqual(snapshot.requestCount, 2)
        XCTAssertEqual(snapshot.consecutiveFailures, 0)
    }

    func testVisionAnalyzerIsRuntimeReusableAndConsumesOriginalImage() async throws {
        let analyzer = VisionTextAnalyzer()
        let frame = try makeFrame(image: makeBlankImage(width: 128, height: 256))
        let first = await analyzer.analyze(frame)
        let second = await analyzer.analyze(frame)
        let snapshot = await analyzer.snapshot()

        XCTAssertEqual(first.status, .succeeded)
        XCTAssertEqual(second.status, .succeeded)
        XCTAssertEqual(first.inputDimensions, frame.metadata.pixelDimensions)
        XCTAssertEqual(first.version, "VNRecognizeTextRequest.revision3")
        XCTAssertEqual(first.backend, "Vision.framework")
        XCTAssertNotNil(first.inferenceMilliseconds)
        XCTAssertNotNil(first.queueWaitMilliseconds)
        XCTAssertEqual(first.stageTimings.resizeAndColorSpaceMicroseconds, 0)
        XCTAssertEqual(first.stageTimings.inputEncodeMicroseconds, 0)
        XCTAssertEqual(first.stageTimings.requestEncodeMicroseconds, 0)
        XCTAssertEqual(first.stageTimings.transportRoundTripMicroseconds, 0)
        XCTAssertEqual(first.stageTimings.transportOverheadMicroseconds, 0)
        XCTAssertNotNil(first.stageTimings.responseDecodeMicroseconds)
        XCTAssertEqual(snapshot.initializationAttemptCount, 1)
        XCTAssertEqual(snapshot.initializationCount, 1)
        XCTAssertEqual(snapshot.initializationFailureCount, 0)
        XCTAssertEqual(snapshot.queryCount, 2)
        XCTAssertEqual(snapshot.requestRevision, 3)
        XCTAssertEqual(snapshot.recognitionLanguages, ["zh-Hans", "en-US"])
        XCTAssertEqual(snapshot.minimumTextHeight, 0)
        XCTAssertTrue(snapshot.usesLanguageCorrection)
        XCTAssertFalse(snapshot.automaticallyDetectsLanguage)
        XCTAssertFalse(snapshot.stopped)
    }

    func testVisionSerializesInferenceAndReportsQueueWait() async throws {
        let analyzer = VisionTextAnalyzer()
        let prewarmed = await analyzer.prewarm()
        XCTAssertTrue(prewarmed)
        let frame = try makeFrame(image: makeBlankImage(width: 512, height: 1_024))

        async let first = analyzer.analyze(frame)
        async let second = analyzer.analyze(frame)
        let results = await [first, second]

        XCTAssertTrue(results.allSatisfy { $0.status == .succeeded })
        XCTAssertTrue(results.allSatisfy { $0.inferenceMilliseconds != nil })
        XCTAssertGreaterThan(
            results.compactMap(\.queueWaitMilliseconds).max() ?? 0,
            0
        )
        await analyzer.shutdown()
    }

    func testVisionConcurrentPrewarmIsSingleFlightAndShutdownIsTerminal()
        async throws
    {
        let analyzer = VisionTextAnalyzer()
        async let first = analyzer.prewarm()
        async let second = analyzer.prewarm()
        async let third = analyzer.prewarm()
        let prewarmed = await [first, second, third]
        XCTAssertEqual(prewarmed, [true, true, true])
        var snapshot = await analyzer.snapshot()
        XCTAssertEqual(snapshot.initializationAttemptCount, 1)
        XCTAssertEqual(snapshot.initializationCount, 1)
        XCTAssertEqual(snapshot.initializationFailureCount, 0)
        XCTAssertEqual(snapshot.queryCount, 0)

        let frame = try makeFrame(image: makeBlankImage(width: 128, height: 256))
        let cancelled = Task { await analyzer.analyze(frame) }
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        XCTAssertEqual(cancelledResult.status, .timedOut)

        await analyzer.shutdown()
        let unavailable = await analyzer.analyze(frame)
        XCTAssertEqual(unavailable.status, .unavailable)
        snapshot = await analyzer.snapshot()
        XCTAssertTrue(snapshot.stopped)
        XCTAssertEqual(snapshot.initializationCount, 1)
    }

    func testVisionCancelledPrewarmWaiterDoesNotCancelSharedInitialization()
        async throws
    {
        let controlled = ControlledVisionPrewarm()
        let analyzer = VisionTextAnalyzer { _ in
            try await controlled.run()
        }
        let first = Task { await analyzer.prewarm() }
        await controlled.waitUntilStarted()
        let second = Task { await analyzer.prewarm() }
        first.cancel()

        let cancelled = await first.value
        XCTAssertFalse(cancelled)
        var snapshot = await analyzer.snapshot()
        XCTAssertEqual(snapshot.initializationAttemptCount, 1)
        XCTAssertEqual(snapshot.initializationCount, 0)

        await controlled.release()
        let completed = await second.value
        XCTAssertTrue(completed)
        snapshot = await analyzer.snapshot()
        XCTAssertEqual(snapshot.initializationAttemptCount, 1)
        XCTAssertEqual(snapshot.initializationCount, 1)
        XCTAssertEqual(snapshot.initializationFailureCount, 0)
    }

    func testAppleWorkerCodecRoundTripsBinaryImageAndRejectsInvalidFrames() throws {
        let request = AppleRegionWorkerMessage.detect(
            requestID: 7,
            inputWidth: 117,
            inputHeight: 253,
            imageData: Data([0, 1, 2, 3, 255])
        )
        let encoded = try AppleRegionWorkerCodec.encode(request)
        let decoded = try AppleRegionWorkerCodec.decode(
            encoded,
            maximumBytes: AppleRegionWorkerMessage.maximumRequestFrameBytes
        )
        XCTAssertEqual(decoded, request)

        let malformed = try PropertyListSerialization.data(
            fromPropertyList: [
                "protocolVersion": 2,
                "type": "shutdown",
            ],
            format: .binary,
            options: 0
        )
        XCTAssertThrowsError(try AppleRegionWorkerCodec.decode(
            malformed,
            maximumBytes: malformed.count
        )) { error in
            XCTAssertEqual(error as? AppleRegionWorkerError, .invalidMessage)
        }
    }

    func testAppleAnalyzerReusesWorkerAndMapsBottomLeftCoordinates() async throws {
        let transport = MockAppleRegionTransport(regions: [
            AppleRegionWorkerRegion(
                x: 10,
                y: 20,
                width: 30,
                height: 40,
                detectionType: 0
            ),
        ])
        let analyzer = AppleRegionAnalyzer(transportFactory: { transport })
        let frame = try makeFrame(image: makeBlankImage(width: 117, height: 253))
        let first = await analyzer.analyze(frame)
        let second = await analyzer.analyze(frame)
        let analyzerSnapshot = await analyzer.snapshot()
        let transportSnapshot = await transport.snapshot()
        await analyzer.shutdown()

        XCTAssertEqual(first.status, .succeeded)
        XCTAssertEqual(second.status, .succeeded)
        XCTAssertEqual(first.inputDimensions, frame.metadata.pixelDimensions)
        XCTAssertEqual(first.inferenceMilliseconds, 1)
        XCTAssertNotNil(first.queueWaitMilliseconds)
        XCTAssertNotNil(first.stageTimings.resizeAndColorSpaceMicroseconds)
        XCTAssertNotNil(first.stageTimings.inputEncodeMicroseconds)
        XCTAssertNil(first.stageTimings.requestEncodeMicroseconds)
        XCTAssertNotNil(first.stageTimings.responseDecodeMicroseconds)
        XCTAssertNotNil(first.stageTimings.transportRoundTripMicroseconds)
        XCTAssertLessThanOrEqual(
            first.stageTimings.transportOverheadMicroseconds ?? .max,
            first.stageTimings.transportRoundTripMicroseconds ?? 0
        )
        let candidate = try XCTUnwrap(first.candidates.first)
        XCTAssertEqual(candidate.frame.x, 10, accuracy: 0.001)
        XCTAssertEqual(candidate.frame.y, 193, accuracy: 0.001)
        XCTAssertEqual(candidate.frame.width, 30, accuracy: 0.001)
        XCTAssertEqual(candidate.frame.height, 40, accuracy: 0.001)
        XCTAssertEqual(candidate.source, .appleRegion)
        XCTAssertEqual(analyzerSnapshot.initializationCount, 1)
        XCTAssertEqual(analyzerSnapshot.initializationAttemptCount, 1)
        XCTAssertEqual(analyzerSnapshot.initializationFailureCount, 0)
        XCTAssertEqual(analyzerSnapshot.restartCount, 0)
        XCTAssertEqual(analyzerSnapshot.queryCount, 2)
        XCTAssertEqual(transportSnapshot.starts, 1)
        XCTAssertEqual(transportSnapshot.detects, 2)

        let stopped = await analyzer.analyze(frame)
        XCTAssertEqual(stopped.status, .unavailable)
    }

    func testAppleAnalyzerSerializesDetectionAndReportsWorkerTiming() async throws {
        let transport = MockAppleRegionTransport(
            detectionDelay: .milliseconds(30),
            inferenceMilliseconds: 7
        )
        let analyzer = AppleRegionAnalyzer(transportFactory: { transport })
        let frame = try makeFrame(image: makeBlankImage(width: 32, height: 64))

        async let first = analyzer.analyze(frame)
        async let second = analyzer.analyze(frame)
        let results = await [first, second]

        XCTAssertTrue(results.allSatisfy { $0.status == .succeeded })
        XCTAssertTrue(results.allSatisfy { $0.inferenceMilliseconds == 7 })
        XCTAssertGreaterThanOrEqual(
            results.compactMap(\.queueWaitMilliseconds).max() ?? 0,
            20
        )
        let transportSnapshot = await transport.snapshot()
        XCTAssertEqual(transportSnapshot.starts, 1)
        XCTAssertEqual(transportSnapshot.detects, 2)
        await analyzer.shutdown()
    }

    func testAppleQueuedRequestUsesReplacementAfterWorkerFailure() async throws {
        let factory = QueuedAppleTransportFactory()
        let analyzer = AppleRegionAnalyzer(
            transportFactory: { factory.make() }
        )
        let frame = try makeFrame(image: makeBlankImage(width: 32, height: 64))
        let first = Task { await analyzer.analyze(frame) }
        await factory.failing.waitUntilDetectionStarted()
        let second = Task { await analyzer.analyze(frame) }
        try await Task.sleep(for: .milliseconds(10))

        await factory.failing.releaseDetection()
        let results = await [first.value, second.value]
        let snapshot = await analyzer.snapshot()

        XCTAssertEqual(results.filter { $0.status == .failed }.count, 1)
        XCTAssertEqual(results.filter { $0.status == .succeeded }.count, 1)
        XCTAssertEqual(factory.count, 2)
        XCTAssertEqual(snapshot.initializationCount, 2)
        XCTAssertEqual(snapshot.restartCount, 1)
        XCTAssertEqual(snapshot.consecutiveFailures, 0)
        await analyzer.shutdown()
    }

    func testAppleAnalyzerTreatsZeroRegionsAsSuccessfulEmptyResult()
        async throws
    {
        let transport = MockAppleRegionTransport()
        let analyzer = AppleRegionAnalyzer(transportFactory: { transport })
        let frame = try makeFrame(image: makeBlankImage(width: 32, height: 64))
        let result = await analyzer.analyze(frame)

        XCTAssertEqual(result.status, .succeeded)
        XCTAssertTrue(result.candidates.isEmpty)
        XCTAssertEqual(result.backend, AppleRegionWorkerMessage.expectedBackend)
        XCTAssertEqual(result.version, AppleRegionWorkerMessage.expectedVersion)
    }

    func testAppleCancelledStartupWaiterDoesNotRetireSharedWorker()
        async throws
    {
        let transport = ControlledAppleRegionTransport()
        let analyzer = AppleRegionAnalyzer(transportFactory: { transport })
        let frame = try makeFrame(image: makeBlankImage(width: 32, height: 64))
        let first = Task { await analyzer.analyze(frame) }
        await transport.waitUntilStarted()
        let second = Task { await analyzer.analyze(frame) }
        first.cancel()
        let cancelled = await first.value
        XCTAssertEqual(cancelled.status, .timedOut)

        await transport.releaseStartup()
        let completed = await second.value
        let analyzerSnapshot = await analyzer.snapshot()
        let transportSnapshot = await transport.snapshot()
        XCTAssertEqual(completed.status, .succeeded)
        XCTAssertEqual(analyzerSnapshot.initializationAttemptCount, 1)
        XCTAssertEqual(analyzerSnapshot.initializationCount, 1)
        XCTAssertEqual(analyzerSnapshot.initializationFailureCount, 0)
        XCTAssertEqual(transportSnapshot.starts, 1)
        XCTAssertEqual(transportSnapshot.detects, 1)
        XCTAssertEqual(transportSnapshot.shutdowns, 0)
    }

    func testAppleAnalyzerRejectsVersionDriftAndOutOfBoundsRegions()
        async throws
    {
        let frame = try makeFrame(image: makeBlankImage(width: 32, height: 64))
        let driftedTransport = MockAppleRegionTransport(
            version: "apple-region-worker.v2"
        )
        let drifted = AppleRegionAnalyzer(
            transportFactory: { driftedTransport }
        )
        let driftedResult = await drifted.analyze(frame)
        let driftedSnapshot = await drifted.snapshot()
        let driftedTransportSnapshot = await driftedTransport.snapshot()
        XCTAssertEqual(driftedResult.status, .failed)
        XCTAssertEqual(driftedSnapshot.initializationCount, 0)
        XCTAssertEqual(driftedSnapshot.initializationFailureCount, 1)
        XCTAssertEqual(driftedSnapshot.consecutiveFailures, 1)
        XCTAssertEqual(driftedTransportSnapshot.detects, 0)
        XCTAssertEqual(driftedTransportSnapshot.shutdowns, 1)

        let invalidTransport = MockAppleRegionTransport(regions: [
            AppleRegionWorkerRegion(
                x: 31,
                y: 0,
                width: 2,
                height: 1,
                detectionType: 0
            ),
        ])
        let invalid = AppleRegionAnalyzer(
            transportFactory: { invalidTransport }
        )
        let invalidResult = await invalid.analyze(frame)
        let invalidSnapshot = await invalid.snapshot()
        let invalidTransportSnapshot = await invalidTransport.snapshot()
        XCTAssertEqual(invalidResult.status, .failed)
        XCTAssertEqual(invalidSnapshot.consecutiveFailures, 1)
        XCTAssertEqual(invalidTransportSnapshot.shutdowns, 1)
    }

    func testAppleAnalyzerReportsUnavailableWithoutRespawning() async throws {
        let transport = MockAppleRegionTransport(available: false)
        let analyzer = AppleRegionAnalyzer(transportFactory: { transport })
        let frame = try makeFrame(image: makeBlankImage(width: 32, height: 64))
        let first = await analyzer.analyze(frame)
        let second = await analyzer.analyze(frame)
        let analyzerSnapshot = await analyzer.snapshot()
        let transportSnapshot = await transport.snapshot()
        await analyzer.shutdown()

        XCTAssertEqual(first.status, .unavailable)
        XCTAssertEqual(second.status, .unavailable)
        XCTAssertEqual(analyzerSnapshot.initializationCount, 1)
        XCTAssertEqual(transportSnapshot.starts, 1)
        XCTAssertEqual(transportSnapshot.detects, 0)
    }

    func testAppleAnalyzerRestartsThenOpensIsolatedCircuit() async throws {
        let factory = AppleTransportFactoryRecorder(failDetection: true)
        let analyzer = AppleRegionAnalyzer(
            circuitPolicy: AppleRegionCircuitPolicy(
                failureThreshold: 2,
                openDuration: .seconds(60)
            ),
            transportFactory: { factory.make() }
        )
        let frame = try makeFrame(image: makeBlankImage(width: 32, height: 64))
        let first = await analyzer.analyze(frame)
        let second = await analyzer.analyze(frame)
        let third = await analyzer.analyze(frame)
        let snapshot = await analyzer.snapshot()
        await analyzer.shutdown()

        XCTAssertEqual(first.status, .failed)
        XCTAssertEqual(second.status, .failed)
        XCTAssertEqual(third.status, .circuitOpen)
        XCTAssertTrue(snapshot.circuitOpen)
        XCTAssertEqual(snapshot.consecutiveFailures, 2)
        XCTAssertEqual(snapshot.initializationCount, 2)
        XCTAssertEqual(snapshot.restartCount, 1)
        XCTAssertEqual(factory.count, 2)
    }

    func testAppleAnalyzerCircuitHalfOpenRestartsAndRecovers() async throws {
        let factory = RecoveringAppleTransportFactory()
        let analyzer = AppleRegionAnalyzer(
            circuitPolicy: AppleRegionCircuitPolicy(
                failureThreshold: 1,
                openDuration: .milliseconds(20)
            ),
            transportFactory: { factory.make() }
        )
        let frame = try makeFrame(image: makeBlankImage(width: 32, height: 64))
        let failed = await analyzer.analyze(frame)
        let open = await analyzer.analyze(frame)
        XCTAssertEqual(failed.status, .failed)
        XCTAssertEqual(open.status, .circuitOpen)
        XCTAssertEqual(factory.count, 1)

        try await Task.sleep(for: .milliseconds(30))
        let recovered = await analyzer.analyze(frame)
        let snapshot = await analyzer.snapshot()
        XCTAssertEqual(recovered.status, .succeeded)
        XCTAssertEqual(factory.count, 2)
        XCTAssertEqual(snapshot.initializationCount, 2)
        XCTAssertEqual(snapshot.restartCount, 1)
        XCTAssertEqual(snapshot.consecutiveFailures, 0)
        XCTAssertFalse(snapshot.circuitOpen)
    }

    func testAppleSubprocessTransportRejectsAbsentExecutable() async {
        let transport = AppleRegionSubprocessTransport(
            executablePath: "/private/tmp/pulsephone-absent-apple-worker"
        )
        do {
            _ = try await transport.start()
            XCTFail("absent worker unexpectedly started")
        } catch {
            XCTAssertEqual(error as? AppleRegionWorkerError, .invalidExecutable)
        }
    }

    func testAppleSubprocessTransportBoundsStartupAndReapsHungWorker() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhoneAppleWorkerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("hung-worker")
        try Data("#!/bin/sh\nsleep 10\n".utf8).write(to: executable)
        XCTAssertEqual(chmod(executable.path, 0o700), 0)
        let transport = AppleRegionSubprocessTransport(
            executablePath: executable.path,
            startupTimeout: .milliseconds(50),
            requestTimeout: .milliseconds(50)
        )
        let started = ContinuousClock.now
        do {
            _ = try await transport.start()
            XCTFail("hung worker unexpectedly started")
        } catch {
            XCTAssertEqual(error as? AppleRegionWorkerError, .timedOut)
        }
        await transport.shutdown()
        XCTAssertLessThan(
            started.duration(to: .now),
            Duration.seconds(1)
        )
    }

    func testAppleSubprocessTransportContainsWorkerExit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "PulsePhoneAppleWorkerTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("exiting-worker")
        let payload = try AppleRegionWorkerCodec.encode(.hello(
            outcome: .succeeded,
            backend: "mock-crash-worker",
            version: "mock-v1"
        ))
        let length = UInt32(payload.count)
        var frame = Data([
            UInt8((length >> 24) & 0xff), UInt8((length >> 16) & 0xff),
            UInt8((length >> 8) & 0xff), UInt8(length & 0xff),
        ])
        frame.append(payload)
        let escapedFrame = frame.map { String(format: "\\%03o", $0) }.joined()
        let script = "#!/bin/sh\nprintf '\(escapedFrame)'\n"
        try Data(script.utf8).write(to: executable)
        XCTAssertEqual(chmod(executable.path, 0o700), 0)
        let transport = AppleRegionSubprocessTransport(
            executablePath: executable.path,
            startupTimeout: .seconds(3),
            requestTimeout: .milliseconds(250)
        )
        let hello = try await transport.start()
        XCTAssertEqual(hello.outcome, .succeeded)
        do {
            _ = try await transport.detect(.detect(
                requestID: 1,
                inputWidth: 1,
                inputHeight: 1,
                imageData: Data([1])
            ))
            XCTFail("exited worker unexpectedly replied")
        } catch {
            XCTAssertNotNil(error as? AppleRegionWorkerError)
        }
        await transport.shutdown()
    }

    func testAnalyzerCoordinatorRunsAllBranchesAndReturnsCanonicalDegradation() async throws {
        let frame = try makeFrame(image: makeBlankImage(width: 64, height: 128))
        let coordinator = ElementAnalyzerCoordinator(
            deadlines: ElementAnalyzerDeadlinePolicy(
                omniparser: .seconds(1),
                vision: .seconds(1),
                appleRegion: .seconds(1),
                whole: .seconds(1)
            ),
            operations: ElementAnalyzerOperations(
                omniparser: { _ in
                    try? await Task.sleep(for: .milliseconds(100))
                    return analyzerResult(source: .omniparser, status: .succeeded)
                },
                vision: { _ in
                    try? await Task.sleep(for: .milliseconds(100))
                    return analyzerResult(source: .vision, status: .succeeded)
                },
                appleRegion: { _ in
                    try? await Task.sleep(for: .milliseconds(100))
                    return analyzerResult(source: .appleRegion, status: .unavailable)
                }
            )
        )
        let started = ContinuousClock.now
        let batch = try await coordinator.analyze(frame)

        XCTAssertTrue(batch.degraded)
        XCTAssertEqual(batch.results.map(\.source), [
            .omniparser, .vision, .appleRegion,
        ])
        XCTAssertEqual(batch.results.map(\.status), [
            .succeeded, .succeeded, .unavailable,
        ])
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(220))
    }

    func testAnalyzerSelectionCanonicalizesAndRejectsInvalidValues() throws {
        XCTAssertEqual(
            try XCTUnwrap(ElementAnalyzerSelection(
                canonicalString: "apple,omni,omni"
            )).canonicalString,
            "omni,apple"
        )
        XCTAssertEqual(
            ElementAnalyzerSelection.all.canonicalString,
            "omni,vision,apple"
        )
        for invalid in ["", "omni,", "localGeometry", "OMNI", "vision apple"] {
            XCTAssertNil(ElementAnalyzerSelection(canonicalString: invalid), invalid)
        }
    }

    func testAnalyzerCoordinatorDoesNotPrepareOrRunDisabledBranches() async throws {
        let frame = try makeFrame(image: makeBlankImage(width: 64, height: 128))
        let omniCalls = AsyncCallCounter()
        let visionCalls = AsyncCallCounter()
        let appleCalls = AsyncCallCounter()
        let omniPrepareCalls = AsyncCallCounter()
        let visionPrepareCalls = AsyncCallCounter()
        let applePrepareCalls = AsyncCallCounter()
        let coordinator = ElementAnalyzerCoordinator(
            operations: ElementAnalyzerOperations(
                omniparser: { _ in
                    await omniCalls.increment()
                    return analyzerResult(source: .omniparser, status: .succeeded)
                },
                vision: { _ in
                    await visionCalls.increment()
                    return analyzerResult(source: .vision, status: .succeeded)
                },
                appleRegion: { _ in
                    await appleCalls.increment()
                    return analyzerResult(source: .appleRegion, status: .succeeded)
                },
                prepareOmniparser: {
                    await omniPrepareCalls.increment()
                    return nil
                },
                prepareVision: {
                    await visionPrepareCalls.increment()
                    return nil
                },
                prepareAppleRegion: {
                    await applePrepareCalls.increment()
                    return nil
                }
            )
        )
        let selection = try XCTUnwrap(ElementAnalyzerSelection(
            canonicalString: "vision"
        ))
        let batch = try await coordinator.analyze(frame, selection: selection)

        let callCounts = await (
            omniCalls.value,
            visionCalls.value,
            appleCalls.value,
            omniPrepareCalls.value,
            visionPrepareCalls.value,
            applePrepareCalls.value
        )
        XCTAssertEqual(callCounts.0, 0)
        XCTAssertEqual(callCounts.1, 1)
        XCTAssertEqual(callCounts.2, 0)
        XCTAssertEqual(callCounts.3, 0)
        XCTAssertEqual(callCounts.4, 1)
        XCTAssertEqual(callCounts.5, 0)
        XCTAssertEqual(batch.results.map(\.status), [
            .unavailable, .succeeded, .unavailable,
        ])
        XCTAssertTrue(batch.degraded)
    }

    func testAnalyzerCoordinatorRunsPrewarmInParallelOutsideBranchBudget()
        async throws
    {
        let frame = try makeFrame(image: makeBlankImage(width: 64, height: 128))
        let prepare: ElementAnalyzerOperations.Preparation = {
            try? await Task.sleep(for: .milliseconds(50))
            return nil
        }
        let coordinator = ElementAnalyzerCoordinator(
            operations: ElementAnalyzerOperations(
                omniparser: { _ in
                    analyzerResult(source: .omniparser, status: .succeeded)
                },
                vision: { _ in
                    analyzerResult(source: .vision, status: .succeeded)
                },
                appleRegion: { _ in
                    analyzerResult(source: .appleRegion, status: .succeeded)
                },
                prepareOmniparser: prepare,
                prepareVision: prepare,
                prepareAppleRegion: prepare
            )
        )
        let started = ContinuousClock.now
        let batch = try await coordinator.analyze(frame)
        let wall = started.duration(to: .now)

        XCTAssertGreaterThanOrEqual(wall, .milliseconds(45))
        XCTAssertLessThan(wall, .milliseconds(130))
        XCTAssertLessThan(batch.elapsedMilliseconds, 30)
    }

    func testAnalyzerCoordinatorUsesPreparationFailureWithoutRetryingBranch()
        async throws
    {
        let frame = try makeFrame(image: makeBlankImage(width: 64, height: 128))
        let visionCalls = AsyncCallCounter()
        let preparedFailure = analyzerResult(
            source: .vision,
            status: .unavailable,
            elapsedMilliseconds: 0,
            inferenceMilliseconds: nil,
            queueWaitMilliseconds: 0
        )
        let batch = try await ElementAnalyzerCoordinator(
            operations: ElementAnalyzerOperations(
                omniparser: { _ in
                    analyzerResult(source: .omniparser, status: .succeeded)
                },
                vision: { _ in
                    await visionCalls.increment()
                    return analyzerResult(source: .vision, status: .succeeded)
                },
                appleRegion: { _ in
                    analyzerResult(source: .appleRegion, status: .succeeded)
                },
                prepareVision: { preparedFailure }
            )
        ).analyze(frame)

        let callCount = await visionCalls.value
        XCTAssertEqual(callCount, 0)
        XCTAssertEqual(
            batch.results.first { $0.source == .vision }?.status,
            .unavailable
        )
        XCTAssertTrue(batch.degraded)
    }

    func testAnalyzerCoordinatorReturnsBranchTimeoutWithoutWaitingForLateResult() async throws {
        let frame = try makeFrame(image: makeBlankImage(width: 64, height: 128))
        let coordinator = ElementAnalyzerCoordinator(
            deadlines: ElementAnalyzerDeadlinePolicy(
                omniparser: .milliseconds(100),
                vision: .milliseconds(20),
                appleRegion: .milliseconds(100),
                whole: .milliseconds(150)
            ),
            operations: ElementAnalyzerOperations(
                omniparser: { _ in
                    analyzerResult(source: .omniparser, status: .succeeded)
                },
                vision: { _ in
                    try? await Task.sleep(for: .seconds(5))
                    return analyzerResult(source: .vision, status: .succeeded)
                },
                appleRegion: { _ in
                    analyzerResult(source: .appleRegion, status: .succeeded)
                }
            )
        )
        let started = ContinuousClock.now
        let batch = try await coordinator.analyze(frame)
        let vision = try XCTUnwrap(batch.results.first { $0.source == .vision })

        XCTAssertEqual(vision.status, .timedOut)
        XCTAssertTrue(batch.degraded)
        XCTAssertEqual(batch.lateResultCount, 1)
        XCTAssertLessThan(started.duration(to: .now), .milliseconds(100))
    }

    func testAnalyzerCoordinatorFailsOnlyWhenAllBranchesFail() async throws {
        let frame = try makeFrame(image: makeBlankImage(width: 64, height: 128))
        let coordinator = ElementAnalyzerCoordinator(
            operations: ElementAnalyzerOperations(
                omniparser: { _ in
                    analyzerResult(source: .omniparser, status: .failed)
                },
                vision: { _ in
                    analyzerResult(source: .vision, status: .timedOut)
                },
                appleRegion: { _ in
                    analyzerResult(source: .appleRegion, status: .circuitOpen)
                }
            )
        )
        do {
            _ = try await coordinator.analyze(frame)
            XCTFail("all-failed analyzer batch unexpectedly succeeded")
        } catch let ElementSnapshotAnalysisError.allAnalyzersFailed(results) {
            XCTAssertEqual(results.map(\.source), [
                .omniparser, .vision, .appleRegion,
            ])
        }
    }

    func testAnalyzerCoordinatorAcceptsEveryNonemptySuccessCombination()
        async throws
    {
        let frame = try makeFrame(image: makeBlankImage(width: 64, height: 128))
        let sources: [ElementAnalyzerSource] = [
            .omniparser, .vision, .appleRegion,
        ]
        let combinations = (1..<(1 << sources.count)).map { mask in
            Set(sources.enumerated().compactMap { index, source in
                mask & (1 << index) == 0 ? nil : source
            })
        }

        for succeeded in combinations {
            let result: @Sendable (ElementAnalyzerSource) -> ElementAnalyzerResult = {
                source in
                analyzerResult(
                    source: source,
                    status: succeeded.contains(source) ? .succeeded : .unavailable
                )
            }
            let batch = try await ElementAnalyzerCoordinator(
                operations: ElementAnalyzerOperations(
                    omniparser: { _ in result(.omniparser) },
                    vision: { _ in result(.vision) },
                    appleRegion: { _ in result(.appleRegion) }
                )
            ).analyze(frame)

            XCTAssertEqual(
                Set(batch.results.filter { $0.status == .succeeded }.map(\.source)),
                succeeded
            )
            XCTAssertEqual(batch.degraded, succeeded.count != sources.count)
            XCTAssertEqual(batch.results.map(\.source), sources)
        }
    }

    func testAnalyzerCoordinatorWaitsForEveryCompletionOrder() async throws {
        let frame = try makeFrame(image: makeBlankImage(width: 64, height: 128))
        let canonical: [ElementAnalyzerSource] = [
            .omniparser, .vision, .appleRegion,
        ]
        for firstSource in canonical {
            let delay: @Sendable (ElementAnalyzerSource) -> Duration = { source in
                source == firstSource ? .milliseconds(5) :
                    (source == .vision ? .milliseconds(15) : .milliseconds(25))
            }
            let operation: @Sendable (
                ElementAnalyzerSource
            ) async -> ElementAnalyzerResult = { source in
                try? await Task.sleep(for: delay(source))
                return analyzerResult(source: source, status: .succeeded)
            }
            let started = ContinuousClock.now
            let batch = try await ElementAnalyzerCoordinator(
                deadlines: ElementAnalyzerDeadlinePolicy(
                    omniparser: .milliseconds(100),
                    vision: .milliseconds(100),
                    appleRegion: .milliseconds(100),
                    whole: .milliseconds(150)
                ),
                operations: ElementAnalyzerOperations(
                    omniparser: { _ in await operation(.omniparser) },
                    vision: { _ in await operation(.vision) },
                    appleRegion: { _ in await operation(.appleRegion) }
                )
            ).analyze(frame)

            XCTAssertEqual(batch.results.map(\.source), canonical)
            XCTAssertTrue(batch.results.allSatisfy { $0.status == .succeeded })
            XCTAssertGreaterThanOrEqual(
                started.duration(to: .now),
                .milliseconds(20)
            )
        }
    }

    func testAnalyzerCoordinatorCancellationCancelsWholeBarrier() async throws {
        let frame = try makeFrame(image: makeBlankImage(width: 64, height: 128))
        let operation: ElementAnalyzerOperations.Operation = { _ in
            try? await Task.sleep(for: .seconds(1))
            return analyzerResult(source: .omniparser, status: .succeeded)
        }
        let coordinator = ElementAnalyzerCoordinator(
            deadlines: ElementAnalyzerDeadlinePolicy(
                omniparser: .seconds(1),
                vision: .seconds(1),
                appleRegion: .seconds(1),
                whole: .seconds(1)
            ),
            operations: ElementAnalyzerOperations(
                omniparser: operation,
                vision: { frame in
                    var result = await operation(frame)
                    result = analyzerResult(source: .vision, status: result.status)
                    return result
                },
                appleRegion: { frame in
                    var result = await operation(frame)
                    result = analyzerResult(source: .appleRegion, status: result.status)
                    return result
                }
            )
        )
        let started = ContinuousClock.now
        let task = Task { try await coordinator.analyze(frame) }
        try await Task.sleep(for: .milliseconds(20))
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled barrier unexpectedly succeeded")
        } catch is CancellationError {
            XCTAssertLessThan(started.duration(to: .now), .milliseconds(150))
        }
    }

    func testIndependentRuntimeCoordinatorsDoNotSerializeAnalyzerWork()
        async throws
    {
        let frame = try makeFrame(image: makeBlankImage(width: 64, height: 128))
        let concurrency = ConcurrentRequestProbe()
        let makeCoordinator: @Sendable () -> ElementAnalyzerCoordinator = {
            ElementAnalyzerCoordinator(
                operations: ElementAnalyzerOperations(
                    omniparser: { _ in
                        concurrency.begin()
                        defer { concurrency.end() }
                        try? await Task.sleep(for: .milliseconds(50))
                        return analyzerResult(
                            source: .omniparser,
                            status: .succeeded
                        )
                    },
                    vision: { _ in
                        analyzerResult(source: .vision, status: .succeeded)
                    },
                    appleRegion: { _ in
                        analyzerResult(source: .appleRegion, status: .succeeded)
                    }
                )
            )
        }
        let first = makeCoordinator()
        let second = makeCoordinator()

        async let firstBatch = first.analyze(frame)
        async let secondBatch = second.analyze(frame)
        let batches = try await [firstBatch, secondBatch]

        XCTAssertEqual(batches.count, 2)
        XCTAssertTrue(batches.allSatisfy { !$0.degraded })
        XCTAssertEqual(concurrency.maximum, 2)
    }

    func testFusionIsOrderIndependentMergesEvidenceAndSuppressesOCRGroup() throws {
        let dimensions = try SnapshotImageDimensions(width: 200, height: 400)
        let omni = analyzerResult(
            source: .omniparser,
            status: .succeeded,
            candidates: [
                try candidate(
                    source: .omniparser,
                    type: .controlCandidate,
                    x: 10, y: 10, width: 40, height: 40,
                    confidence: 0.8
                ),
                try candidate(
                    source: .omniparser,
                    type: .controlCandidate,
                    x: 60, y: 10, width: 40, height: 40,
                    confidence: 0.7
                ),
            ]
        )
        let vision = analyzerResult(
            source: .vision,
            status: .succeeded,
            candidates: [
                try candidate(
                    source: .vision,
                    type: .text,
                    x: 5, y: 5, width: 100, height: 50,
                    confidence: 0.9,
                    label: "group"
                ),
                try candidate(
                    source: .vision,
                    type: .text,
                    x: 12, y: 12, width: 35, height: 20,
                    confidence: 0.95,
                    label: "first"
                ),
            ]
        )
        let apple = analyzerResult(
            source: .appleRegion,
            status: .succeeded,
            candidates: [
                try candidate(
                    source: .appleRegion,
                    type: .text,
                    x: 10, y: 10, width: 40, height: 40
                ),
            ]
        )
        let engine = ElementFusionEngine()
        let first = try engine.fuse(
            batch(results: [vision, apple, omni]),
            dimensions: dimensions
        )
        let second = try engine.fuse(
            batch(results: [omni, vision, apple]),
            dimensions: dimensions
        )

        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 2)
        XCTAssertEqual(first[0].frame, omni.candidates[0].frame)
        XCTAssertEqual(first[0].sources, [.omniparser, .vision, .appleRegion])
        XCTAssertEqual(first[0].label, "first")
        XCTAssertEqual(first[0].labelSource, .vision)
        XCTAssertEqual(first[0].confidence, 0.95)
        XCTAssertFalse(first.contains { $0.label == "group" })
    }

    func testFusionSuppressesMultiControlOCRAndAssignsOrderedLabels() throws {
        let dimensions = try SnapshotImageDimensions(width: 200, height: 400)
        let omni = analyzerResult(
            source: .omniparser,
            status: .succeeded,
            candidates: [
                try candidate(
                    source: .omniparser,
                    type: .controlCandidate,
                    x: 10, y: 10, width: 40, height: 40
                ),
                try candidate(
                    source: .omniparser,
                    type: .controlCandidate,
                    x: 60, y: 10, width: 40, height: 40
                ),
            ]
        )
        let vision = analyzerResult(
            source: .vision,
            status: .succeeded,
            candidates: [try candidate(
                source: .vision,
                type: .text,
                x: 5, y: 5, width: 100, height: 50,
                confidence: 0.9,
                label: "Home Market"
            )]
        )

        let fused = try ElementFusionEngine().fuse(
            batch(results: [vision, omni]),
            dimensions: dimensions
        )

        XCTAssertEqual(fused.count, 2)
        XCTAssertEqual(fused.map(\.label), ["Home", "Market"])
        XCTAssertTrue(fused.allSatisfy {
            $0.type == .controlCandidate
                && $0.sources == [.omniparser, .vision]
        })
    }

    func testFusionRetainsOCRAcrossNestedContainerAndChildControl() throws {
        let dimensions = try SnapshotImageDimensions(width: 200, height: 400)
        let omni = analyzerResult(
            source: .omniparser,
            status: .succeeded,
            candidates: [
                try candidate(
                    source: .omniparser,
                    type: .controlCandidate,
                    x: 10, y: 10, width: 100, height: 80
                ),
                try candidate(
                    source: .omniparser,
                    type: .controlCandidate,
                    x: 20, y: 20, width: 40, height: 30
                ),
            ]
        )
        let vision = analyzerResult(
            source: .vision,
            status: .succeeded,
            candidates: [try candidate(
                source: .vision,
                type: .text,
                x: 15, y: 15, width: 75, height: 40,
                confidence: 0.9,
                label: "Card title"
            )]
        )

        let fused = try ElementFusionEngine().fuse(
            batch(results: [vision, omni]),
            dimensions: dimensions
        )

        XCTAssertEqual(fused.filter { $0.type == .controlCandidate }.count, 2)
        XCTAssertTrue(fused.contains { $0.label == "Card title" })
    }

    func testFusionUsesAppleBridgeToMergeIconAndNumericCounter() throws {
        let dimensions = try SnapshotImageDimensions(width: 200, height: 400)
        let omni = analyzerResult(
            source: .omniparser,
            status: .succeeded,
            candidates: [
                try candidate(
                    source: .omniparser,
                    type: .controlCandidate,
                    x: 10, y: 10, width: 20, height: 20
                ),
                try candidate(
                    source: .omniparser,
                    type: .controlCandidate,
                    x: 34, y: 10, width: 30, height: 20
                ),
            ]
        )
        let vision = analyzerResult(
            source: .vision,
            status: .succeeded,
            candidates: [try candidate(
                source: .vision,
                type: .text,
                x: 36, y: 12, width: 26, height: 16,
                confidence: 0.9,
                label: "226"
            )]
        )
        let apple = analyzerResult(
            source: .appleRegion,
            status: .succeeded,
            candidates: [try candidate(
                source: .appleRegion,
                type: .text,
                x: 8, y: 8, width: 58, height: 24
            )]
        )

        let fused = try ElementFusionEngine().fuse(
            batch(results: [apple, vision, omni]),
            dimensions: dimensions
        )

        let result = try XCTUnwrap(fused.first)
        XCTAssertEqual(fused.count, 1)
        XCTAssertEqual(result.frame, apple.candidates[0].frame)
        XCTAssertEqual(result.label, "226")
        XCTAssertEqual(result.type, .controlCandidate)
        XCTAssertEqual(result.sources, [.omniparser, .vision, .appleRegion])
    }

    func testFusionDoesNotBridgeNestedControlAndNumericChild() throws {
        let dimensions = try SnapshotImageDimensions(width: 200, height: 400)
        let omni = analyzerResult(
            source: .omniparser,
            status: .succeeded,
            candidates: [
                try candidate(
                    source: .omniparser,
                    type: .controlCandidate,
                    x: 10, y: 10, width: 80, height: 60
                ),
                try candidate(
                    source: .omniparser,
                    type: .controlCandidate,
                    x: 20, y: 20, width: 30, height: 20
                ),
            ]
        )
        let vision = analyzerResult(
            source: .vision,
            status: .succeeded,
            candidates: [try candidate(
                source: .vision,
                type: .text,
                x: 22, y: 22, width: 26, height: 16,
                confidence: 0.9,
                label: "2"
            )]
        )
        let apple = analyzerResult(
            source: .appleRegion,
            status: .succeeded,
            candidates: [try candidate(
                source: .appleRegion,
                type: .text,
                x: 8, y: 8, width: 84, height: 64
            )]
        )

        let fused = try ElementFusionEngine().fuse(
            batch(results: [apple, vision, omni]),
            dimensions: dimensions
        )

        XCTAssertEqual(fused.count, 2)
        XCTAssertEqual(fused.filter { $0.type == .controlCandidate }.count, 2)
        XCTAssertTrue(fused.contains { $0.label == "2" })
    }

    func testFusionRetainsNestedDetectorBoxesAndClipsViewport() throws {
        let dimensions = try SnapshotImageDimensions(width: 200, height: 400)
        let omni = analyzerResult(
            source: .omniparser,
            status: .succeeded,
            candidates: [
                try candidate(
                    source: .omniparser,
                    type: .controlCandidate,
                    x: -10, y: -10, width: 110, height: 110,
                    confidence: 0.8
                ),
                try candidate(
                    source: .omniparser,
                    type: .controlCandidate,
                    x: 20, y: 20, width: 40, height: 40,
                    confidence: 0.9
                ),
            ]
        )
        let fused = try ElementFusionEngine().fuse(
            batch(results: [omni]),
            dimensions: dimensions
        )

        XCTAssertEqual(fused.count, 2)
        XCTAssertEqual(fused[0].frame.x, 0)
        XCTAssertEqual(fused[0].frame.y, 0)
        XCTAssertEqual(fused[0].frame.width, 100)
        XCTAssertEqual(fused[0].frame.height, 100)
        XCTAssertEqual(fused[1].frame.width, 40)
        XCTAssertEqual(fused[1].frame.height, 40)
    }

    func testFusionAcceptsCurrentProtocolOmniCandidateWithoutConfidence() throws {
        let dimensions = try SnapshotImageDimensions(width: 200, height: 400)
        let candidate = try candidate(
            source: .omniparser,
            type: .controlCandidate,
            x: 20,
            y: 30,
            width: 80,
            height: 90,
            confidence: nil
        )
        let fused = try ElementFusionEngine().fuse(
            batch(results: [analyzerResult(
                source: .omniparser,
                status: .succeeded,
                candidates: [candidate]
            )]),
            dimensions: dimensions
        )

        XCTAssertEqual(fused.count, 1)
        XCTAssertEqual(fused[0].frame, candidate.frame)
        XCTAssertEqual(fused[0].type, .controlCandidate)
        XCTAssertNil(fused[0].confidence)
    }

    func testLocalGeometryCorrectionRequiresSafetyPredicateAndUsesTopLeftPixels() async throws {
        let image = try makeTopLeftImage(
            width: 300,
            height: 200,
            luminanceRects: [
                (try SnapshotPixelRect(x: 40, y: 55, width: 30, height: 30), 0),
                (try SnapshotPixelRect(x: 200, y: 100, width: 30, height: 25), 0),
            ]
        )
        let frame = try makeFrame(image: image)
        let parent = FusedElementCandidate(
            frame: try SnapshotPixelRect(x: 10, y: 50, width: 280, height: 80),
            sources: [.vision],
            type: .text,
            confidence: 0.7,
            label: nil,
            labelSource: nil
        )
        let child = FusedElementCandidate(
            frame: try SnapshotPixelRect(x: 40, y: 55, width: 30, height: 30),
            sources: [.omniparser],
            type: .controlCandidate,
            confidence: 0.9,
            label: nil,
            labelSource: nil
        )
        let corrector = ElementLocalGeometryCorrector()
        let unsafe = await corrector.correct(frame: frame, candidates: [parent])
        let corrected = await corrector.correct(
            frame: frame,
            candidates: [parent, child]
        )

        XCTAssertEqual(unsafe.appliedParentCount, 0)
        XCTAssertEqual(unsafe.candidates, [parent])
        XCTAssertEqual(corrected.appliedParentCount, 1)
        XCTAssertEqual(corrected.componentCount, 2)
        XCTAssertFalse(corrected.candidates.contains(parent))
        let correctedChild = try XCTUnwrap(corrected.candidates.first {
            $0.frame == child.frame
        })
        XCTAssertTrue(
            correctedChild.sources.contains(.localGeometry),
            "corrected candidates: \(corrected.candidates)"
        )
        XCTAssertEqual(
            corrected.candidates.filter { $0.sources.contains(.localGeometry) }.count,
            2
        )
    }

    func testLocalGeometryRefinesNonOmniSeedWithoutPromotingItsType() async throws {
        let iconFrame = try SnapshotPixelRect(
            x: 70,
            y: 70,
            width: 100,
            height: 100
        )
        let image = try makeTopLeftImage(
            width: 240,
            height: 240,
            background: 244,
            luminanceRects: [(iconFrame, 20)]
        )
        let frame = try makeFrame(image: image)
        let seed = FusedElementCandidate(
            frame: try SnapshotPixelRect(
                x: 105,
                y: 105,
                width: 30,
                height: 30
            ),
            sources: [.appleRegion],
            type: .unknown,
            confidence: nil,
            label: nil,
            labelSource: nil
        )
        let trusted = FusedElementCandidate(
            frame: iconFrame,
            sources: [.omniparser],
            type: .controlCandidate,
            confidence: nil,
            label: nil,
            labelSource: nil
        )
        let corrector = ElementLocalGeometryCorrector()

        let refined = await corrector.correct(
            frame: frame,
            candidates: [seed]
        )
        let refinedCandidate = try XCTUnwrap(refined.candidates.first)
        XCTAssertNotEqual(refinedCandidate.frame, seed.frame)
        XCTAssertEqual(
            refinedCandidate.frame.intersection(seed.frame),
            seed.frame
        )
        XCTAssertGreaterThan(refinedCandidate.frame.width, 90)
        XCTAssertGreaterThan(refinedCandidate.frame.height, 90)
        XCTAssertEqual(refinedCandidate.type, .unknown)
        XCTAssertEqual(refinedCandidate.sources, [.appleRegion, .localGeometry])

        let preserved = await corrector.correct(
            frame: frame,
            candidates: [trusted]
        )
        XCTAssertEqual(preserved.candidates, [trusted])
    }

    func testLocalGeometryRasterBudgetPreservesUnprocessedSeeds() async throws {
        let firstIcon = try SnapshotPixelRect(x: 20, y: 40, width: 60, height: 60)
        let secondIcon = try SnapshotPixelRect(x: 200, y: 40, width: 60, height: 60)
        let image = try makeTopLeftImage(
            width: 300,
            height: 140,
            background: 244,
            luminanceRects: [(firstIcon, 20), (secondIcon, 20)]
        )
        let firstSeed = FusedElementCandidate(
            frame: try SnapshotPixelRect(x: 40, y: 60, width: 20, height: 20),
            sources: [.appleRegion],
            type: .unknown,
            confidence: nil,
            label: nil,
            labelSource: nil
        )
        let secondSeed = FusedElementCandidate(
            frame: try SnapshotPixelRect(x: 220, y: 60, width: 20, height: 20),
            sources: [.appleRegion],
            type: .unknown,
            confidence: nil,
            label: nil,
            labelSource: nil
        )
        let corrector = ElementLocalGeometryCorrector(policy: .init(
            maximumElapsedMilliseconds: 10_000,
            maximumRasterizedPixels: 6_400
        ))

        let result = await corrector.correct(
            frame: try makeFrame(image: image),
            candidates: [firstSeed, secondSeed]
        )

        XCTAssertEqual(result.candidates.count, 2)
        XCTAssertEqual(result.candidates[0].sources, [.appleRegion, .localGeometry])
        XCTAssertGreaterThan(result.candidates[0].frame.width, firstSeed.frame.width)
        XCTAssertEqual(result.candidates[1], secondSeed)
    }

    func testLocalGeometryCorrectionHandlesToolbarShadowAndDarkLandscapeKeyboard() async throws {
        let lightParent = FusedElementCandidate(
            frame: try SnapshotPixelRect(x: 10, y: 50, width: 280, height: 80),
            sources: [.vision],
            type: .text,
            confidence: 0.7,
            label: nil,
            labelSource: nil
        )
        let lightChild = FusedElementCandidate(
            frame: try SnapshotPixelRect(x: 40, y: 55, width: 30, height: 30),
            sources: [.omniparser],
            type: .controlCandidate,
            confidence: 0.9,
            label: nil,
            labelSource: nil
        )
        let lightImage = try makeTopLeftImage(
            width: 300,
            height: 200,
            background: 248,
            luminanceRects: [
                (try SnapshotPixelRect(x: 35, y: 50, width: 40, height: 40), 164),
                (lightChild.frame, 0),
                (try SnapshotPixelRect(x: 200, y: 100, width: 30, height: 25), 0),
            ]
        )
        let light = await ElementLocalGeometryCorrector().correct(
            frame: try makeFrame(image: lightImage),
            candidates: [lightParent, lightChild]
        )

        XCTAssertEqual(light.appliedParentCount, 1)
        XCTAssertEqual(light.componentCount, 2)
        XCTAssertFalse(light.candidates.contains(lightParent))

        let darkParent = FusedElementCandidate(
            frame: try SnapshotPixelRect(x: 20, y: 50, width: 360, height: 80),
            sources: [.vision],
            type: .text,
            confidence: 0.7,
            label: nil,
            labelSource: nil
        )
        let darkChild = FusedElementCandidate(
            frame: try SnapshotPixelRect(x: 50, y: 55, width: 30, height: 30),
            sources: [.omniparser],
            type: .controlCandidate,
            confidence: 0.9,
            label: nil,
            labelSource: nil
        )
        let darkImage = try makeTopLeftImage(
            width: 400,
            height: 200,
            background: 24,
            luminanceRects: [
                (darkChild.frame, 244),
                (try SnapshotPixelRect(x: 300, y: 100, width: 30, height: 25), 244),
            ]
        )
        let dark = await ElementLocalGeometryCorrector().correct(
            frame: try makeFrame(image: darkImage, orientation: .landscapeLeft),
            candidates: [darkParent, darkChild]
        )

        XCTAssertEqual(dark.appliedParentCount, 1)
        XCTAssertEqual(dark.componentCount, 2)
        XCTAssertFalse(dark.candidates.contains(darkParent))
        XCTAssertTrue(dark.candidates.contains {
            $0.frame == darkChild.frame && $0.sources.contains(.localGeometry)
        })
    }

    func testLocalGeometryCorrectionFallsBackOnTexturedImageBackground() async throws {
        let image = try makeTexturedTopLeftImage(width: 300, height: 200)
        let frame = try makeFrame(image: image)
        let parent = FusedElementCandidate(
            frame: try SnapshotPixelRect(x: 10, y: 50, width: 280, height: 80),
            sources: [.vision],
            type: .text,
            confidence: 0.7,
            label: nil,
            labelSource: nil
        )
        let child = FusedElementCandidate(
            frame: try SnapshotPixelRect(x: 40, y: 55, width: 30, height: 30),
            sources: [.omniparser],
            type: .controlCandidate,
            confidence: 0.9,
            label: nil,
            labelSource: nil
        )

        let result = await ElementLocalGeometryCorrector().correct(
            frame: frame,
            candidates: [parent, child]
        )

        XCTAssertEqual(result.appliedParentCount, 0)
        XCTAssertEqual(result.componentCount, 0)
        XCTAssertEqual(result.candidates, [parent, child])
    }

    private func makeOmniAnalyzer(
        protocolMode: OmniParserProtocolMode = .currentParse
    ) -> OmniParserAnalyzer {
        OmniParserAnalyzer(
            configuration: try! OmniParserEndpointConfiguration(
                endpointString: "https://omni.example.test/parse/",
                source: .environment
            ),
            renderer: ElementImageRenderer(),
            session: stubSession(),
            protocolMode: protocolMode
        )
    }

    private func batch(
        results: [ElementAnalyzerResult]
    ) -> ElementAnalyzerBatch {
        ElementAnalyzerBatch(
            degraded: results.contains { $0.status != .succeeded },
            elapsedMilliseconds: 1,
            results: results
        )
    }

    private func candidate(
        source: ElementAnalyzerSource,
        type: ElementCandidateType,
        x: Double,
        y: Double,
        width: Double,
        height: Double,
        confidence: Double? = nil,
        label: String? = nil
    ) throws -> ElementAnalyzerCandidate {
        ElementAnalyzerCandidate(
            frame: try SnapshotPixelRect(
                x: x,
                y: y,
                width: width,
                height: height
            ),
            source: source,
            type: type,
            confidence: confidence,
            label: label
        )
    }

    private func stubSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func makeFrame(
        image: CGImage,
        orientation: DisplayOrientationDTO = .portrait
    ) throws -> SnapshotFrame {
        let dimensions = try SnapshotImageDimensions(
            width: UInt64(image.width),
            height: UInt64(image.height)
        )
        let geometry = try DisplayGeometryDTO(
            connectionEpoch: 7,
            geometryRevision: 11,
            logicalHeight: UInt64(image.height / 2),
            logicalWidth: UInt64(image.width / 2),
            orientation: orientation
        )
        let fence = try SnapshotFreshnessFence(
            queryStartedAtNanoseconds: 1_000,
            baselineFrameSequence: 40,
            maximumFrameAgeNanoseconds: 200,
            validatedAtNanoseconds: 1_150
        )
        let metadata = try SnapshotFrameMetadata(
            canonicalUDID: udid(),
            connectionEpoch: geometry.connectionEpoch,
            sourceEpoch: nil,
            sourceID: nil,
            geometry: geometry,
            captureGeneration: 5,
            frameSequence: 41,
            capturedAtNanoseconds: 1_100,
            freshnessFence: fence,
            pixelDimensions: dimensions,
            provider: .coreDevice,
            settleReason: .queryFenceSatisfied
        )
        return try SnapshotFrame(
            authority: SnapshotFrameAuthority(
                canonicalUDID: metadata.canonicalUDID,
                geometry: geometry,
                sourceEpoch: nil,
                sourceID: nil,
                captureGeneration: metadata.captureGeneration
            ),
            metadata: metadata,
            sourceImage: SnapshotSourceImageLease(cgImage: image)
        )
    }

    private func makeBlankImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func makeQuadrantImage(width: Int, height: Int) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        let halfWidth = CGFloat(width) / 2
        let halfHeight = CGFloat(height) / 2
        for (rect, color) in [
            (CGRect(x: 0, y: 0, width: halfWidth, height: halfHeight), CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
            (CGRect(x: halfWidth, y: 0, width: halfWidth, height: halfHeight), CGColor(red: 0, green: 1, blue: 0, alpha: 1)),
            (CGRect(x: 0, y: halfHeight, width: halfWidth, height: halfHeight), CGColor(red: 0, green: 0, blue: 1, alpha: 1)),
            (CGRect(x: halfWidth, y: halfHeight, width: halfWidth, height: halfHeight), CGColor(red: 1, green: 1, blue: 1, alpha: 1)),
        ] {
            context.setFillColor(color)
            context.fill(rect)
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func makeTopLeftImage(
        width: Int,
        height: Int,
        background: UInt8 = 255,
        luminanceRects: [(SnapshotPixelRect, UInt8)]
    ) throws -> CGImage {
        var pixels = [UInt8](repeating: background, count: width * height * 4)
        for offset in stride(from: 3, to: pixels.count, by: 4) {
            pixels[offset] = 255
        }
        for (rect, luminance) in luminanceRects {
            let minX = max(0, Int(rect.x.rounded(.down)))
            let minY = max(0, Int(rect.y.rounded(.down)))
            let maxX = min(width, Int(rect.maxX.rounded(.up)))
            let maxY = min(height, Int(rect.maxY.rounded(.up)))
            for y in minY..<maxY {
                for x in minX..<maxX {
                    let offset = (y * width + x) * 4
                    pixels[offset] = luminance
                    pixels[offset + 1] = luminance
                    pixels[offset + 2] = luminance
                    pixels[offset + 3] = 255
                }
            }
        }
        return try makeTopLeftImage(width: width, height: height, pixels: pixels)
    }

    private func makeTexturedTopLeftImage(width: Int, height: Int) throws -> CGImage {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let luminance: UInt8 = ((x / 8) + (y / 8)).isMultiple(of: 2)
                    ? 72 : 192
                let offset = (y * width + x) * 4
                pixels[offset] = luminance
                pixels[offset + 1] = luminance
                pixels[offset + 2] = luminance
                pixels[offset + 3] = 255
            }
        }
        for rect in [
            try SnapshotPixelRect(x: 40, y: 55, width: 30, height: 30),
            try SnapshotPixelRect(x: 200, y: 100, width: 30, height: 25),
        ] {
            for y in Int(rect.y)..<Int(rect.maxY) {
                for x in Int(rect.x)..<Int(rect.maxX) {
                    let offset = (y * width + x) * 4
                    pixels[offset] = 0
                    pixels[offset + 1] = 0
                    pixels[offset + 2] = 0
                }
            }
        }
        return try makeTopLeftImage(width: width, height: height, pixels: pixels)
    }

    private func makeTopLeftImage(
        width: Int,
        height: Int,
        pixels: [UInt8]
    ) throws -> CGImage {
        let data = Data(pixels) as CFData
        let provider = try XCTUnwrap(CGDataProvider(data: data))
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func decodeCGImage(_ bytes: [UInt8]) throws -> CGImage {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(Data(bytes) as CFData, nil))
        return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try pixels.withUnsafeMutableBytes { buffer in
            try XCTUnwrap(CGContext(
                data: buffer.baseAddress,
                width: image.width,
                height: image.height,
                bitsPerComponent: 8,
                bytesPerRow: image.width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ))
        }
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(
            x: 0,
            y: 0,
            width: image.width,
            height: image.height
        ))
        return pixels
    }

    private func quadrantColor(
        _ pixels: [UInt8],
        width: Int,
        height: Int,
        x: Int,
        y: Int
    ) -> [UInt8] {
        precondition((0..<width).contains(x) && (0..<height).contains(y))
        let offset = (y * width + x) * 4
        return Array(pixels[offset..<(offset + 4)])
    }

    private func udid() throws -> CanonicalUDID {
        try CanonicalUDID(canonicalString: "00008020-001C2D123456002E")
    }
}

private func analyzerResult(
    source: ElementAnalyzerSource,
    status: ElementAnalyzerStatus,
    candidates: [ElementAnalyzerCandidate] = [],
    elapsedMilliseconds: UInt64? = 1,
    inferenceMilliseconds: UInt64? = 1,
    queueWaitMilliseconds: UInt64? = 0
) -> ElementAnalyzerResult {
    let profileID: String
    switch source {
    case .omniparser:
        profileID = ElementAnalyzerProfiles.omniparser.profileID
    case .vision:
        profileID = ElementAnalyzerProfiles.visionProfileID
    case .appleRegion:
        profileID = ElementAnalyzerProfiles.appleRegion.profileID
    case .localGeometry:
        profileID = "local-geometry-components.v1"
    }
    return ElementAnalyzerResult(
        source: source,
        status: status,
        profileID: profileID,
        candidates: candidates,
        elapsedMilliseconds: elapsedMilliseconds,
        inferenceMilliseconds: inferenceMilliseconds,
        queueWaitMilliseconds: queueWaitMilliseconds
    )
}

private actor AsyncCallCounter {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private actor MockAppleRegionTransport: AppleRegionWorkerTransport {
    struct Snapshot: Equatable, Sendable {
        let detects: Int
        let shutdowns: Int
        let starts: Int
    }

    private let available: Bool
    private let detectionDelay: Duration
    private var detects = 0
    private let failDetection: Bool
    private let inferenceMilliseconds: UInt64
    private let regions: [AppleRegionWorkerRegion]
    private var shutdowns = 0
    private var starts = 0
    private let version: String

    init(
        available: Bool = true,
        detectionDelay: Duration = .zero,
        failDetection: Bool = false,
        inferenceMilliseconds: UInt64 = 1,
        regions: [AppleRegionWorkerRegion] = [],
        version: String = AppleRegionWorkerMessage.expectedVersion
    ) {
        self.available = available
        self.detectionDelay = detectionDelay
        self.failDetection = failDetection
        self.inferenceMilliseconds = inferenceMilliseconds
        self.regions = regions
        self.version = version
    }

    func start() async throws -> AppleRegionWorkerMessage {
        starts += 1
        return .hello(
            outcome: available ? .succeeded : .unavailable,
            backend: AppleRegionWorkerMessage.expectedBackend,
            version: version,
            errorCode: available ? nil : "capabilityUnavailable"
        )
    }

    func detect(
        _ request: AppleRegionWorkerMessage
    ) async throws -> AppleRegionWorkerMessage {
        detects += 1
        if failDetection { throw AppleRegionWorkerError.processExited }
        if detectionDelay > .zero {
            try await Task.sleep(for: detectionDelay)
        }
        return .result(
            requestID: try XCTUnwrap(request.requestID),
            outcome: .succeeded,
            elapsedMilliseconds: inferenceMilliseconds,
            regions: regions
        )
    }

    func shutdown() async {
        shutdowns += 1
    }

    func snapshot() -> Snapshot {
        Snapshot(detects: detects, shutdowns: shutdowns, starts: starts)
    }
}

private actor ControlledAppleRegionTransport: AppleRegionWorkerTransport {
    struct Snapshot: Equatable, Sendable {
        let detects: Int
        let shutdowns: Int
        let starts: Int
    }

    private var detects = 0
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var shutdowns = 0
    private var started = false
    private var startWaiters = [CheckedContinuation<Void, Never>]()
    private var starts = 0

    func start() async throws -> AppleRegionWorkerMessage {
        starts += 1
        started = true
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            releaseContinuation = continuation
        }
        return .hello(
            outcome: .succeeded,
            backend: AppleRegionWorkerMessage.expectedBackend,
            version: AppleRegionWorkerMessage.expectedVersion
        )
    }

    func detect(
        _ request: AppleRegionWorkerMessage
    ) async throws -> AppleRegionWorkerMessage {
        detects += 1
        return .result(
            requestID: try XCTUnwrap(request.requestID),
            outcome: .succeeded,
            elapsedMilliseconds: 1,
            regions: []
        )
    }

    func shutdown() async {
        shutdowns += 1
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            startWaiters.append(continuation)
        }
    }

    func releaseStartup() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func snapshot() -> Snapshot {
        Snapshot(detects: detects, shutdowns: shutdowns, starts: starts)
    }
}

private actor ControlledFailingAppleRegionTransport: AppleRegionWorkerTransport {
    private var detectionRelease: CheckedContinuation<Void, Never>?
    private var detectionStarted = false
    private var detectionWaiters = [CheckedContinuation<Void, Never>]()

    func start() async throws -> AppleRegionWorkerMessage {
        .hello(
            outcome: .succeeded,
            backend: AppleRegionWorkerMessage.expectedBackend,
            version: AppleRegionWorkerMessage.expectedVersion
        )
    }

    func detect(
        _ request: AppleRegionWorkerMessage
    ) async throws -> AppleRegionWorkerMessage {
        detectionStarted = true
        let waiters = detectionWaiters
        detectionWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            detectionRelease = continuation
        }
        throw AppleRegionWorkerError.processExited
    }

    func shutdown() async {
        detectionRelease?.resume()
        detectionRelease = nil
    }

    func waitUntilDetectionStarted() async {
        if detectionStarted { return }
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            detectionWaiters.append(continuation)
        }
    }

    func releaseDetection() {
        detectionRelease?.resume()
        detectionRelease = nil
    }
}

private final class QueuedAppleTransportFactory: @unchecked Sendable {
    let failing = ControlledFailingAppleRegionTransport()
    private let lock = NSLock()
    private var makeCount = 0

    var count: Int { lock.withLock { makeCount } }

    func make() -> any AppleRegionWorkerTransport {
        lock.withLock {
            makeCount += 1
            if makeCount == 1 { return failing }
            return MockAppleRegionTransport()
        }
    }
}

private final class AppleTransportFactoryRecorder: @unchecked Sendable {
    private let failDetection: Bool
    private let lock = NSLock()
    private var transports = [MockAppleRegionTransport]()

    init(failDetection: Bool) {
        self.failDetection = failDetection
    }

    var count: Int { lock.withLock { transports.count } }

    func make() -> MockAppleRegionTransport {
        lock.withLock {
            let transport = MockAppleRegionTransport(
                failDetection: failDetection
            )
            transports.append(transport)
            return transport
        }
    }
}

private final class RecoveringAppleTransportFactory: @unchecked Sendable {
    private let lock = NSLock()
    private var transports = [MockAppleRegionTransport]()

    var count: Int { lock.withLock { transports.count } }

    func make() -> MockAppleRegionTransport {
        lock.withLock {
            let transport = MockAppleRegionTransport(
                failDetection: transports.isEmpty
            )
            transports.append(transport)
            return transport
        }
    }
}

private final class RequestRecorder: @unchecked Sendable {
    private var requests = [(request: URLRequest, body: Data)]()
    private let lock = NSLock()

    var bodies: [Data] { lock.withLock { requests.map(\.body) } }
    var count: Int { lock.withLock { requests.count } }
    var hosts: [String] {
        lock.withLock { requests.compactMap { $0.request.url?.host } }
    }
    var methods: [String] {
        lock.withLock { requests.compactMap { $0.request.httpMethod } }
    }
    var lastBody: Data? { lock.withLock { requests.last?.body } }

    func record(_ request: URLRequest, body: Data) {
        lock.withLock { requests.append((request, body)) }
    }
}

private final class LockedOmniEndpoint: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: String

    init(_ value: String) {
        self.storedValue = value
    }

    var value: String {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

private final class LockedBool: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: Bool

    init(_ value: Bool) {
        self.storedValue = value
    }

    var value: Bool {
        get { lock.withLock { storedValue } }
        set { lock.withLock { storedValue = newValue } }
    }
}

private final class ConcurrentRequestProbe: @unchecked Sendable {
    private var active = 0
    private let lock = NSLock()
    private var storedMaximum = 0

    var maximum: Int { lock.withLock { storedMaximum } }

    func begin() {
        lock.withLock {
            active += 1
            storedMaximum = max(storedMaximum, active)
        }
    }

    func end() {
        lock.withLock { active -= 1 }
    }
}

private actor ControlledVisionPrewarm {
    private var releaseContinuation: CheckedContinuation<Void, Never>?
    private var started = false
    private var startWaiters = [CheckedContinuation<Void, Never>]()

    func run() async throws {
        started = true
        let waiters = startWaiters
        startWaiters.removeAll(keepingCapacity: false)
        waiters.forEach { $0.resume() }
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            releaseContinuation = continuation
        }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation {
            (continuation: CheckedContinuation<Void, Never>) in
            startWaiters.append(continuation)
        }
    }

    func release() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }
}

private func requestBody(_ request: URLRequest) throws -> Data {
    if let body = request.httpBody { return body }
    guard let stream = request.httpBodyStream else { return Data() }
    stream.open()
    defer { stream.close() }
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while stream.hasBytesAvailable {
        let count = stream.read(&buffer, maxLength: buffer.count)
        guard count >= 0 else { throw try XCTUnwrap(stream.streamError) }
        if count == 0 { break }
        data.append(buffer, count: count)
    }
    return data
}

private func omniCurrentResponseData() throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "latency": 0.25,
        "parsed_content_list": [
            [
                "bbox": [0.1, 0.2, 0.3, 0.4],
                "content": "icon",
                "interactivity": true,
                "source": "box_yolo_content_yolo",
                "type": "icon",
            ],
            [
                "bbox": [0.4, 0.5, 0.6, 0.55],
                "content": "label",
                "interactivity": false,
                "source": "box_ocr_content_ocr",
                "type": "text",
            ],
            [
                "bbox": [0.6, 0.6, 0.8, 0.7],
                "content": "button text",
                "interactivity": true,
                "source": "box_yolo_content_ocr",
                "type": "text",
            ],
        ],
    ])
}

private func omniProbeData(
    backends: [String] = ["mps", "cpu"],
    version: String = "3.0.0-test"
) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "capabilities": [
            "caption": false,
            "detectorOnly": true,
            "ocr": false,
        ],
        "limits": [
            "maximumDetections": 2_048,
            "maximumRequestBytes": 16 * 1_024 * 1_024,
            "maximumResponseBytes": 4 * 1_024 * 1_024,
        ],
        "model": [
            "backends": backends,
            "imageSize": 1_280,
            "name": OmniParserServiceCapability.detectorName,
            "version": version,
        ],
        "protocol": OmniParserServiceCapability.detectorProtocol,
        "schema": OmniParserServiceCapability.probeSchema,
        "status": "ready",
    ])
}

private func omniDetectorResponseData(
    for request: URLRequest,
    detections: [(SnapshotPixelRect, Double)] = [],
    backend: String = "mps",
    version: String = "3.0.0-test"
) throws -> Data {
    let root = try XCTUnwrap(
        JSONSerialization.jsonObject(with: requestBody(request))
            as? [String: Any]
    )
    let input = try XCTUnwrap(root["input"] as? [String: Any])
    return try omniDetectorResponseData(
        requestID: try XCTUnwrap(root["requestID"] as? String),
        snapshotID: try XCTUnwrap(root["snapshotID"] as? String),
        width: try XCTUnwrap((input["width"] as? NSNumber)?.uint64Value),
        height: try XCTUnwrap((input["height"] as? NSNumber)?.uint64Value),
        profileID: try XCTUnwrap(input["profileID"] as? String),
        detections: detections,
        backend: backend,
        version: version
    )
}

private func omniDetectorResponseData(
    requestID: String,
    snapshotID: String,
    width: UInt64,
    height: UInt64,
    profileID: String,
    detections: [(SnapshotPixelRect, Double)] = [],
    backend: String = "mps",
    version: String = "3.0.0-test"
) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "detections": detections.map { detection in
            [
                "box": [
                    "height": detection.0.height,
                    "width": detection.0.width,
                    "x": detection.0.x,
                    "y": detection.0.y,
                ],
                "confidence": detection.1,
            ]
        },
        "input": [
            "height": height,
            "profileID": profileID,
            "width": width,
        ],
        "model": [
            "backend": backend,
            "imageSize": 1_280,
            "name": OmniParserServiceCapability.detectorName,
            "version": version,
        ],
        "outcome": "succeeded",
        "preprocess": [
            "inputHeight": height,
            "inputWidth": width,
            "modelHeight": height,
            "modelWidth": width,
            "scaleX": 1,
            "scaleY": 1,
            "translateX": 0,
            "translateY": 0,
        ],
        "requestID": requestID,
        "schema": OmniParserServiceCapability.responseSchema,
        "snapshotID": snapshotID,
        "timings": [
            "inferenceMilliseconds": 2,
            "queueWaitMilliseconds": 0,
            "totalMilliseconds": 3,
        ],
    ])
}

private final class TestAuthenticationChallengeSender: NSObject,
    URLAuthenticationChallengeSender
{
    func use(
        _ credential: URLCredential,
        for challenge: URLAuthenticationChallenge
    ) {}

    func continueWithoutCredential(
        for challenge: URLAuthenticationChallenge
    ) {}

    func cancel(_ challenge: URLAuthenticationChallenge) {}

    func performDefaultHandling(
        for challenge: URLAuthenticationChallenge
    ) {}

    func rejectProtectionSpaceAndContinue(
        with challenge: URLAuthenticationChallenge
    ) {}
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler:
        (@Sendable (URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        do {
            let handler = try XCTUnwrap(Self.handler)
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
