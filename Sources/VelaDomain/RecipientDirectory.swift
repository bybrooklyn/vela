import Foundation

/// Resolves the several identifiers Signal uses for one person down to a single
/// canonical `RecipientID`.
///
/// A person can arrive as an E.164 number, an ACI UUID, or a username, and
/// signal-cli reports different ones depending on the call: `listContacts`
/// returns both a number and a UUID, while an incoming envelope may carry only
/// `sourceUuid` if the sender hides their phone number. Keying conversations by
/// whichever string happened to arrive is what caused a reply to open a second
/// thread instead of joining the existing one.
///
/// The ACI UUID is canonical because it is stable: phone numbers change hands
/// and can be withheld, and usernames can be reassigned.
public struct RecipientDirectory: Hashable, Sendable {
    private var canonicalByAlias: [String: RecipientID]

    public init() {
        canonicalByAlias = [:]
    }

    public init(contacts: [Contact]) {
        canonicalByAlias = [:]
        for contact in contacts {
            register(contact)
        }
    }

    /// Indexes every identifier a contact is known by against its canonical ID.
    public mutating func register(_ contact: Contact) {
        let canonical = Self.canonicalIdentifier(
            aci: contact.aci,
            fallback: contact.recipientID.rawValue
        )
        for alias in [contact.aci, contact.phoneNumber, contact.username, contact.recipientID.rawValue] {
            guard let alias, !alias.isEmpty else { continue }
            canonicalByAlias[Self.normalize(alias)] = canonical
        }
    }

    /// Records that these identifiers all refer to the same person. Used for
    /// identifiers seen on the wire before a contact sync has caught up.
    public mutating func associate(aci: String?, number: String?, username: String? = nil) {
        let canonical = Self.canonicalIdentifier(aci: aci, fallback: number ?? username)
        guard let canonical else { return }
        for alias in [aci, number, username] {
            guard let alias, !alias.isEmpty else { continue }
            canonicalByAlias[Self.normalize(alias)] = canonical
        }
    }

    /// The canonical identity for a raw identifier, falling back to the
    /// identifier itself when nothing is known about it yet. Never returns nil,
    /// so an unknown sender still lands in a stable conversation.
    public func canonical(for raw: String) -> RecipientID {
        canonicalByAlias[Self.normalize(raw)] ?? RecipientID(raw)
    }

    public func canonical(for recipientID: RecipientID) -> RecipientID {
        canonical(for: recipientID.rawValue)
    }

    /// Resolves from the identifier set an envelope or contact carries.
    public func canonical(aci: String?, number: String?, username: String? = nil) -> RecipientID? {
        for candidate in [aci, number, username] {
            guard let candidate, !candidate.isEmpty else { continue }
            if let known = canonicalByAlias[Self.normalize(candidate)] { return known }
        }
        guard let fallback = Self.canonicalIdentifier(aci: aci, fallback: number ?? username) else {
            return nil
        }
        return fallback
    }

    public var isEmpty: Bool { canonicalByAlias.isEmpty }

    private static func canonicalIdentifier(aci: String?, fallback: String?) -> RecipientID? {
        if let aci, !aci.isEmpty { return RecipientID(normalize(aci)) }
        guard let fallback, !fallback.isEmpty else { return nil }
        return RecipientID(normalize(fallback))
    }

    /// Case-folds so a UUID reported in either case matches, and strips the
    /// formatting humans put in phone numbers. E.164 digits are left intact.
    private static func normalize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("+") {
            return "+" + trimmed.dropFirst().filter(\.isNumber)
        }
        return trimmed.lowercased()
    }
}

extension ConversationID {
    /// Conversation identity is derived from the counterpart rather than being
    /// random, so a message Vela sends and a reply that comes back resolve to the
    /// same thread. Both the outbound and inbound paths must use these.
    public static func direct(with recipientID: RecipientID) -> ConversationID {
        ConversationID("direct:\(recipientID.rawValue)")
    }

    public static func group(with groupID: String) -> ConversationID {
        ConversationID("group:\(groupID)")
    }

    public static let noteToSelf = ConversationID("note-to-self")

    /// The conversation a kind belongs to. One place decides, so the two paths
    /// cannot drift apart again.
    public static func of(_ kind: ConversationKind) -> ConversationID {
        switch kind {
        case .direct(let recipientID): .direct(with: recipientID)
        case .group(let groupID, _): .group(with: groupID)
        case .noteToSelf: .noteToSelf
        }
    }
}
