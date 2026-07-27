import Foundation

public struct LinkedAccount: Hashable, Codable, Sendable {
    public var id: AccountID
    public var localRecipientID: RecipientID
    public var deviceID: DeviceID
    public var deviceName: String
    public var serviceIdentifier: ServiceIdentifier
    public var identityHandle: String
    public var linkedAt: Date
    public var lastConnectedAt: Date?
    public var capabilities: Set<ClientCapability>

    public init(
        id: AccountID,
        localRecipientID: RecipientID,
        deviceID: DeviceID,
        deviceName: String,
        serviceIdentifier: ServiceIdentifier,
        identityHandle: String,
        linkedAt: Date,
        lastConnectedAt: Date? = nil,
        capabilities: Set<ClientCapability> = []
    ) {
        self.id = id
        self.localRecipientID = localRecipientID
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.serviceIdentifier = serviceIdentifier
        self.identityHandle = identityHandle
        self.linkedAt = linkedAt
        self.lastConnectedAt = lastConnectedAt
        self.capabilities = capabilities
    }
}

public enum ClientCapability: String, Hashable, Codable, Sendable, CaseIterable {
    case textMessages
    case attachments
    case reactions
    case edits
    case deletes
    case disappearingMessages
    case historyTransfer
    case calls
    case stories
}
