import Foundation
import VelaDomain

public struct HistoryTransferProgress: Hashable, Codable, Sendable {
    public var completedUnits: Int64
    public var totalUnits: Int64?
    public var phase: String

    public init(completedUnits: Int64, totalUnits: Int64?, phase: String) {
        self.completedUnits = completedUnits
        self.totalUnits = totalUnits
        self.phase = phase
    }

    public var fractionCompleted: Double? {
        guard let totalUnits, totalUnits > 0 else { return nil }
        return min(1, max(0, Double(completedUnits) / Double(totalUnits)))
    }
}

public protocol HistoryTransferService: Sendable {
    func importInitialHistory(account: LinkedAccount) async throws -> AsyncStream<HistoryTransferProgress>
    func cancel() async
}

public struct UnavailableHistoryTransferService: HistoryTransferService {
    public init() {}

    public func importInitialHistory(account: LinkedAccount) async throws -> AsyncStream<HistoryTransferProgress> {
        throw VelaError.productionIntegrationRequired("Signal link-and-sync history transfer")
    }

    public func cancel() async {}
}
