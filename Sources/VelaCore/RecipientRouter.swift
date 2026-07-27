import VelaDomain

public protocol RecipientRouter: Sendable {
    func destination(for conversation: ConversationSeed) async throws -> DeviceAddress
}

/// Development-only route resolver. A real linked-device client must ask the
/// upstream Signal recipient/device stores for every destination device.
public struct DevelopmentRecipientRouter: RecipientRouter {
    public init() {}

    public func destination(for conversation: ConversationSeed) async throws -> DeviceAddress {
        switch conversation.kind {
        case .direct(let recipientID):
            return DeviceAddress(recipientID: recipientID, deviceID: DeviceID("development-primary-device"))
        case .group(_, let memberIDs):
            guard let recipientID = memberIDs.first else { throw VelaError.conversationMissing }
            return DeviceAddress(recipientID: recipientID, deviceID: DeviceID("development-group-route"))
        case .noteToSelf:
            return DeviceAddress(recipientID: RecipientID("self"), deviceID: DeviceID("development-self-device"))
        }
    }
}

public struct UnavailableRecipientRouter: RecipientRouter {
    public init() {}

    public func destination(for conversation: ConversationSeed) async throws -> DeviceAddress {
        throw VelaError.productionIntegrationRequired("Signal recipient and linked-device resolution")
    }
}
