import Foundation

public protocol VelaClock: Sendable {
    var now: Date { get }
}

public struct SystemVelaClock: VelaClock {
    public init() {}
    public var now: Date { Date() }
}

public struct FixedVelaClock: VelaClock {
    public let now: Date
    public init(now: Date) { self.now = now }
}
