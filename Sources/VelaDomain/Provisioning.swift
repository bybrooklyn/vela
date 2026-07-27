import Foundation

public struct ProvisioningSession: Identifiable, Hashable, Codable, Sendable {
    public var id: ProvisioningSessionID
    public var linkingURI: URL
    public var expiresAt: Date
    public var verificationCode: String?

    public init(id: ProvisioningSessionID, linkingURI: URL, expiresAt: Date, verificationCode: String? = nil) {
        self.id = id
        self.linkingURI = linkingURI
        self.expiresAt = expiresAt
        self.verificationCode = verificationCode
    }
}

public struct ProvisioningPayload: Hashable, Codable, Sendable {
    public var accountID: AccountID
    public var localRecipientID: RecipientID
    public var deviceID: DeviceID
    public var serviceIdentifier: ServiceIdentifier
    public var identityHandle: String
    public var capabilities: Set<ClientCapability>

    public init(
        accountID: AccountID,
        localRecipientID: RecipientID,
        deviceID: DeviceID,
        serviceIdentifier: ServiceIdentifier,
        identityHandle: String,
        capabilities: Set<ClientCapability>
    ) {
        self.accountID = accountID
        self.localRecipientID = localRecipientID
        self.deviceID = deviceID
        self.serviceIdentifier = serviceIdentifier
        self.identityHandle = identityHandle
        self.capabilities = capabilities
    }
}

public enum ProvisioningEvent: Hashable, Codable, Sendable {
    case awaitingScan
    case phoneConnected
    case transferringCredentials
    case completed(ProvisioningPayload)
    case failed(category: String)
    case cancelled
}
