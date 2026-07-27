import Foundation

/// A person known to the linked account.
///
/// Contacts are a cache of what the primary device already knows: Signal keeps
/// the authoritative copy, and Vela mirrors enough of it to show names and
/// avatars instead of raw phone numbers. Nothing here is authoritative, so it can
/// always be discarded and re-synced.
public struct Contact: Identifiable, Hashable, Codable, Sendable {
    public var id: RecipientID { recipientID }
    public var recipientID: RecipientID
    /// Name the user set locally for this contact, which wins over the profile.
    public var givenName: String?
    public var familyName: String?
    /// Name the contact publishes in their own Signal profile.
    public var profileName: String?
    public var username: String?
    public var phoneNumber: String?
    /// Signal's stable account identifier. Preferred over the phone number for
    /// identity, since numbers change and can be withheld.
    public var aci: String?
    /// Relative path of the cached avatar inside the application container.
    public var avatarRelativePath: String?
    public var isBlocked: Bool
    public var isRegistered: Bool
    public var updatedAt: Date

    public init(
        recipientID: RecipientID,
        givenName: String? = nil,
        familyName: String? = nil,
        profileName: String? = nil,
        username: String? = nil,
        phoneNumber: String? = nil,
        aci: String? = nil,
        avatarRelativePath: String? = nil,
        isBlocked: Bool = false,
        isRegistered: Bool = true,
        updatedAt: Date
    ) {
        self.recipientID = recipientID
        self.givenName = givenName
        self.familyName = familyName
        self.profileName = profileName
        self.username = username
        self.phoneNumber = phoneNumber
        self.aci = aci
        self.avatarRelativePath = avatarRelativePath
        self.isBlocked = isBlocked
        self.isRegistered = isRegistered
        self.updatedAt = updatedAt
    }

    /// Preferred display name, falling back through the same order Signal uses
    /// and ending at the raw identifier so this never renders empty.
    public var displayName: String {
        let local = [givenName, familyName]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        if !local.isEmpty { return local }

        if let profileName, !profileName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return profileName
        }
        if let username, !username.isEmpty { return username }
        if let phoneNumber, !phoneNumber.isEmpty { return phoneNumber }
        return recipientID.rawValue
    }

    /// Up to two initials for avatar placeholders.
    public var initials: String {
        let words =
            displayName
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first }
        if words.isEmpty { return "?" }
        return String(words).uppercased()
    }

    /// Whether the contact carries any name at all, used to decide if a synced
    /// record is worth showing above a raw identifier.
    public var hasResolvedName: Bool {
        displayName != recipientID.rawValue
    }
}
