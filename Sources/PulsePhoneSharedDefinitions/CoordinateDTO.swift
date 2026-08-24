public struct HIDCoordinateDTO: Codable, Equatable, Sendable {
    public let x: UInt16
    public let y: UInt16

    public init(x: UInt16, y: UInt16) {
        self.x = x
        self.y = y
    }
}
