import Foundation

public protocol IdentifierTag: Sendable {}

public struct TypedID<Tag: IdentifierTag>: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible,
    ExpressibleByStringLiteral
{
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }

    public init(stringLiteral value: String) {
        self.rawValue = value
    }

    public static func random() -> Self {
        Self(UUID().uuidString.lowercased())
    }

    public var description: String { rawValue }
}

public enum AccountTag: IdentifierTag {}
public enum DeviceTag: IdentifierTag {}
public enum ConversationTag: IdentifierTag {}
public enum MessageTag: IdentifierTag {}
public enum AttachmentTag: IdentifierTag {}
public enum EnvelopeTag: IdentifierTag {}
public enum ProvisioningSessionTag: IdentifierTag {}
public enum RecipientTag: IdentifierTag {}
public enum ReactionTag: IdentifierTag {}

public typealias AccountID = TypedID<AccountTag>
public typealias DeviceID = TypedID<DeviceTag>
public typealias ConversationID = TypedID<ConversationTag>
public typealias MessageID = TypedID<MessageTag>
public typealias AttachmentID = TypedID<AttachmentTag>
public typealias EnvelopeID = TypedID<EnvelopeTag>
public typealias ProvisioningSessionID = TypedID<ProvisioningSessionTag>
public typealias RecipientID = TypedID<RecipientTag>
public typealias ReactionID = TypedID<ReactionTag>

public enum ServiceIdentifier: Hashable, Codable, Sendable, CustomStringConvertible {
    case aci(UUID)
    case pni(UUID)
    case opaque(String)

    public var description: String {
        switch self {
        case .aci(let value): "aci:\(value.uuidString.lowercased())"
        case .pni(let value): "pni:\(value.uuidString.lowercased())"
        case .opaque(let value): "opaque:\(value)"
        }
    }

    /// The bare ACI, when this identifier is one. Used to tie an account's
    /// stable identity to the other identifiers it is known by.
    public var aciString: String? {
        if case .aci(let value) = self { return value.uuidString.lowercased() }
        return nil
    }
}

public struct DeviceAddress: Hashable, Codable, Sendable {
    public var recipientID: RecipientID
    public var deviceID: DeviceID

    public init(recipientID: RecipientID, deviceID: DeviceID) {
        self.recipientID = recipientID
        self.deviceID = deviceID
    }
}
