public struct StandardErrorV1<Details: Sendable>: Sendable {
    public let code: String
    public let details: Details?

    public init(code: String, details: Details? = nil) {
        self.code = code
        self.details = details
    }
}

extension StandardErrorV1: Equatable where Details: Equatable {}

extension StandardErrorV1: Hashable where Details: Hashable {}
