import Foundation
import VelaDomain

/// Mirrors the primary device's contact list into Vela's local cache.
///
/// Signal holds the authoritative copy; this is presentation data so the UI can
/// show names and avatars instead of raw phone numbers. Avatars are written into
/// the application container as files rather than kept in the database, so the
/// cache stays small and can be cleared independently.
public actor SignalCLIContactSync {
    private let client: JSONRPCClient
    private let avatarDirectory: URL?

    public init(client: JSONRPCClient, avatarDirectory: URL? = nil) {
        self.client = client
        self.avatarDirectory = avatarDirectory
    }

    /// Asks the primary device to resend contacts, groups, configuration and the
    /// blocked list.
    ///
    /// Without this, `fetchContacts` only ever re-reads signal-cli's local copy,
    /// so a rename or a new group made on the phone stays invisible. The reply
    /// arrives asynchronously as sync messages, which is why callers should
    /// request first and read after.
    ///
    /// Best-effort: a failure here just means the list is as fresh as it already
    /// was, which is not worth surfacing as an error.
    public func requestSyncFromPrimary() async {
        _ = try? await client.call("sendSyncRequest", params: .object([:]))
    }

    /// Fetches the contact list. Avatars are fetched separately and lazily,
    /// because each one is a round trip and most conversations need only a few.
    public func fetchContacts(now: Date = Date()) async throws -> [Contact] {
        let result = try await client.call(
            "listContacts",
            params: .object(["detailed": .bool(true)])
        )
        // An empty array is an authoritative empty snapshot. A non-array is a
        // malformed response and must not be mistaken for one, or a transient
        // backend/schema problem would erase the last good contact cache.
        guard let entries = result.arrayValue else {
            throw JSONRPCClientError.malformedResponse("list-contacts-result")
        }
        return entries.compactMap { Self.contact(from: $0, now: now) }
    }

    /// Downloads and caches a contact's avatar, returning its relative path.
    /// Returns nil when the contact has no avatar, which is common.
    public func fetchAvatar(for recipientID: RecipientID) async -> String? {
        guard let avatarDirectory else { return nil }

        // The profile avatar is the one the contact publishes; the contact
        // avatar is a local address-book photo. Prefer the profile.
        for key in ["profile", "contact"] {
            guard
                let result = try? await client.call(
                    "getAvatar",
                    params: .object([key: .string(recipientID.rawValue)])
                ),
                let base64 = result["avatar"]?.stringValue ?? result.stringValue,
                let data = Data(base64Encoded: base64),
                !data.isEmpty
            else { continue }

            let name = Self.avatarFileName(for: recipientID)
            let destination = avatarDirectory.appendingPathComponent(name)
            do {
                try FileManager.default.createDirectory(
                    at: avatarDirectory,
                    withIntermediateDirectories: true
                )
                try data.write(to: destination, options: .atomic)
                return name
            } catch {
                return nil
            }
        }
        return nil
    }

    /// Stable, filesystem-safe name derived from the identifier, so an E.164
    /// number or a UUID both produce a valid filename.
    static func avatarFileName(for recipientID: RecipientID) -> String {
        let allowed = CharacterSet.alphanumerics
        let sanitized = recipientID.rawValue.unicodeScalars
            .map { allowed.contains($0) ? Character($0) : "_" }
            .reduce(into: "") { $0.append($1) }
        return "avatar-\(sanitized).bin"
    }

    static func contact(from value: JSONValue, now: Date) -> Contact? {
        // signal-cli reports the account under `number`, and newer builds also
        // carry `uuid`. Either identifies the recipient for later sends.
        let number = value["number"]?.stringValue
        let uuid = value["uuid"]?.stringValue ?? value["aci"]?.stringValue
        // The ACI is the stable identity, so it is the recipient key when known.
        // Numbers change hands and can be withheld by phone-number privacy.
        guard let identifier = uuid ?? number, !identifier.isEmpty else { return nil }

        let profile = value["profile"]
        let profileName =
            profile?["givenName"]?.stringValue.map { given -> String in
                let family = profile?["familyName"]?.stringValue ?? ""
                return family.isEmpty ? given : "\(given) \(family)"
            } ?? profile?["displayName"]?.stringValue

        return Contact(
            recipientID: RecipientID(identifier),
            givenName: value["givenName"]?.stringValue ?? value["name"]?.stringValue,
            familyName: value["familyName"]?.stringValue,
            profileName: profileName,
            username: value["username"]?.stringValue,
            phoneNumber: number,
            aci: uuid,
            avatarRelativePath: nil,
            isBlocked: value["isBlocked"]?.boolValue ?? value["blocked"]?.boolValue ?? false,
            isRegistered: value["isRegistered"]?.boolValue ?? true,
            updatedAt: now
        )
    }
}
