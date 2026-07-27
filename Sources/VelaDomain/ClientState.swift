import Foundation

public enum OfflineReason: String, Hashable, Codable, Sendable {
    case noNetwork
    case serviceUnavailable
    case authenticationRejected
    case userRequested
    case unknown
}

public enum RecoveryReason: String, Hashable, Codable, Sendable {
    case databaseCorrupt
    case migrationFailed
    case credentialsMissing
    case localStateInconsistent
}

public enum ClientState: Hashable, Codable, Sendable {
    case unlinked
    case openingDatabase
    case linking(sessionID: ProvisioningSessionID)
    case importingHistory(progress: Double)
    case startingServices
    case ready
    case offline(OfflineReason)
    case locked
    case relinkRequired
    case updateRequired(minimumVersion: String)
    case recoveryRequired(RecoveryReason)
    case deletingData
}

public enum TransportConnectionState: Hashable, Codable, Sendable {
    case disconnected
    case connecting
    case connected
    case backingOff(attempt: Int, retryAt: Date)
    case failed(category: String)
}

public struct ClientSnapshot: Hashable, Codable, Sendable {
    public var state: ClientState
    public var connection: TransportConnectionState
    public var linkedAccount: LinkedAccount?
    public var unreadCount: Int

    public init(
        state: ClientState,
        connection: TransportConnectionState,
        linkedAccount: LinkedAccount?,
        unreadCount: Int
    ) {
        self.state = state
        self.connection = connection
        self.linkedAccount = linkedAccount
        self.unreadCount = unreadCount
    }
}
