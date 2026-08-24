import PulsePhoneSharedDefinitions

public enum VideoReconnectError: Error, Equatable, Sendable {
    case conflictingGeometry
    case staleConnectionEpoch
    case staleGeometry
    case staleSourceEpoch
}

public struct VideoReconnectCoordinator: Equatable, Sendable {
    public let canonicalUDID: CanonicalUDID
    public private(set) var binding: VideoBindingIdentity?
    public private(set) var connectionEpoch: UInt64?
    public private(set) var connectionEpochFloor: UInt64?
    public private(set) var geometry: DisplayGeometryDTO?
    public private(set) var sourceEpochFloor: UInt64?
    public private(set) var sourceResolution: VideoSourceResolution

    public init(canonicalUDID: CanonicalUDID) {
        self.canonicalUDID = canonicalUDID
        self.binding = nil
        self.connectionEpoch = nil
        self.connectionEpochFloor = nil
        self.geometry = nil
        self.sourceEpochFloor = nil
        self.sourceResolution = .unavailable
    }

    public var controlAvailable: Bool { connectionEpoch != nil }
    public var coordinateInputAvailable: Bool {
        guard let connectionEpoch, let geometry else { return false }
        return geometry.connectionEpoch == connectionEpoch
    }

    @discardableResult
    public mutating func runtimeReconnected(
        connectionEpoch: UInt64
    ) throws -> Bool {
        guard connectionEpoch > 0 else {
            throw VideoReconnectError.staleConnectionEpoch
        }
        if let floor = connectionEpochFloor {
            guard connectionEpoch >= floor else {
                throw VideoReconnectError.staleConnectionEpoch
            }
            if connectionEpoch == floor {
                guard self.connectionEpoch == connectionEpoch else {
                    throw VideoReconnectError.staleConnectionEpoch
                }
                return false
            }
        }
        self.connectionEpoch = connectionEpoch
        connectionEpochFloor = connectionEpoch
        geometry = nil
        return invalidateBinding()
    }

    @discardableResult
    public mutating func runtimeDetached(
        connectionEpoch: UInt64
    ) -> Bool {
        guard self.connectionEpoch == connectionEpoch else { return false }
        self.connectionEpoch = nil
        geometry = nil
        _ = invalidateBinding()
        return true
    }

    @discardableResult
    public mutating func updateGeometry(
        _ geometry: DisplayGeometryDTO
    ) throws -> Bool {
        if let currentConnectionEpoch = connectionEpoch {
            guard geometry.connectionEpoch >= currentConnectionEpoch else {
                throw VideoReconnectError.staleConnectionEpoch
            }
            if geometry.connectionEpoch > currentConnectionEpoch {
                _ = try runtimeReconnected(
                    connectionEpoch: geometry.connectionEpoch
                )
            }
        } else {
            _ = try runtimeReconnected(
                connectionEpoch: geometry.connectionEpoch
            )
        }
        if let current = self.geometry,
           current.connectionEpoch == geometry.connectionEpoch
        {
            guard geometry.geometryRevision >= current.geometryRevision else {
                throw VideoReconnectError.staleGeometry
            }
            if geometry.geometryRevision == current.geometryRevision,
               geometry != current
            {
                throw VideoReconnectError.conflictingGeometry
            }
        }
        let changed = self.geometry != geometry
        self.geometry = geometry
        if changed { _ = invalidateBinding() }
        return changed
    }

    @discardableResult
    public mutating func sourceChanged(
        _ resolution: VideoSourceResolution
    ) throws -> Bool {
        let nextEpoch = mappedSourceEpoch(resolution)
        if let floor = sourceEpochFloor,
           let nextEpoch,
           nextEpoch < floor
        {
            throw VideoReconnectError.staleSourceEpoch
        }
        if let nextEpoch {
            sourceEpochFloor = max(sourceEpochFloor ?? 0, nextEpoch)
        }
        let changed = sourceResolution != resolution
        sourceResolution = resolution
        if changed { _ = invalidateBinding() }
        return changed
    }

    @discardableResult
    public mutating func bindIfReady() throws -> VideoBindingIdentity? {
        guard let connectionEpoch, let geometry else { return nil }
        let candidate = try VideoBinding.make(
            target: canonicalUDID,
            connectionEpoch: connectionEpoch,
            geometry: geometry,
            resolution: sourceResolution
        )
        binding = candidate
        return candidate
    }

    public func receive(
        _ frame: VideoFrameIdentity
    ) -> VideoFrameDisposition {
        VideoBinding.validate(frame: frame, against: binding)
    }

    private mutating func invalidateBinding() -> Bool {
        let changed = binding != nil
        binding = nil
        return changed
    }

    private func mappedSourceEpoch(
        _ resolution: VideoSourceResolution
    ) -> UInt64? {
        guard case .mapped(let source) = resolution else { return nil }
        return source.descriptor.sourceEpoch
    }
}
