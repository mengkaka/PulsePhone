import Foundation
import PulsePhoneMedia

public struct OmniParserClientGenerationSnapshot: Equatable, Sendable {
    public let configurationFailureCount: UInt64
    public let configurationSource: OmniParserEndpointSource?
    public let generation: UInt64?
    public let initializationCount: UInt64
    public let networkScope: OmniParserEndpointNetworkScope?
    public let redactedHost: String?
    public let retirementCount: UInt64

    public init(
        configurationFailureCount: UInt64,
        configurationSource: OmniParserEndpointSource?,
        generation: UInt64?,
        initializationCount: UInt64,
        networkScope: OmniParserEndpointNetworkScope?,
        redactedHost: String?,
        retirementCount: UInt64
    ) {
        self.configurationFailureCount = configurationFailureCount
        self.configurationSource = configurationSource
        self.generation = generation
        self.initializationCount = initializationCount
        self.networkScope = networkScope
        self.redactedHost = redactedHost
        self.retirementCount = retirementCount
    }
}

public actor OmniParserClientGenerationManager {
    typealias AnalyzerFactory = @Sendable (
        OmniParserEndpointConfiguration
    ) -> OmniParserAnalyzer
    typealias ConfigurationProvider = @Sendable () throws ->
        OmniParserEndpointConfiguration

    private let analyzerFactory: AnalyzerFactory
    private var configuration: OmniParserEndpointConfiguration?
    private var configurationFailureCount: UInt64 = 0
    private let configurationProvider: ConfigurationProvider
    private var generation: UInt64?
    private var initializationCount: UInt64 = 0
    private var analyzer: OmniParserAnalyzer?
    private var retirementCount: UInt64 = 0
    private var stopped = false

    public init(configuration: OmniParserEndpointConfiguration) {
        self.analyzerFactory = { OmniParserAnalyzer(configuration: $0) }
        self.configurationProvider = { configuration }
    }

    init(
        configurationProvider: @escaping ConfigurationProvider,
        analyzerFactory: @escaping AnalyzerFactory
    ) {
        self.analyzerFactory = analyzerFactory
        self.configurationProvider = configurationProvider
    }

    public func analyze(_ frame: SnapshotFrame) async -> ElementAnalyzerResult {
        guard !stopped else { return Self.unavailable() }
        let nextConfiguration: OmniParserEndpointConfiguration
        do {
            nextConfiguration = try configurationProvider()
        } catch {
            configurationFailureCount = Self.increment(configurationFailureCount)
            await retireCurrentClient()
            return Self.unavailable()
        }

        if configuration != nextConfiguration || analyzer == nil {
            await retireCurrentClient()
            guard generation != UInt64.max else { return Self.unavailable() }
            generation = (generation ?? 0) + 1
            initializationCount = Self.increment(initializationCount)
            configuration = nextConfiguration
            analyzer = analyzerFactory(nextConfiguration)
        }
        guard let analyzer else { return Self.unavailable() }
        return await analyzer.analyze(frame)
    }

    public func shutdown() async {
        guard !stopped else { return }
        stopped = true
        await retireCurrentClient()
    }

    public func snapshot() -> OmniParserClientGenerationSnapshot {
        OmniParserClientGenerationSnapshot(
            configurationFailureCount: configurationFailureCount,
            configurationSource: configuration?.source,
            generation: generation,
            initializationCount: initializationCount,
            networkScope: configuration?.networkScope,
            redactedHost: configuration?.redactedHost,
            retirementCount: retirementCount
        )
    }

    private func retireCurrentClient() async {
        guard let analyzer else {
            configuration = nil
            return
        }
        self.analyzer = nil
        configuration = nil
        retirementCount = Self.increment(retirementCount)
        await analyzer.shutdown()
    }

    private static func increment(_ value: UInt64) -> UInt64 {
        value == UInt64.max ? UInt64.max : value + 1
    }

    private static func unavailable() -> ElementAnalyzerResult {
        ElementAnalyzerResult(
            source: .omniparser,
            status: .unavailable,
            profileID: ElementAnalyzerProfiles.omniparser.profileID
        )
    }
}
