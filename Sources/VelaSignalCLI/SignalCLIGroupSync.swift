import Foundation
import VelaDomain

/// Mirrors the groups the primary device knows about.
///
/// Like contacts, this is a cache: Signal holds the authoritative membership, and
/// Vela keeps enough to name a thread and show who is in it.
public actor SignalCLIGroupSync {
    private let client: JSONRPCClient

    public init(client: JSONRPCClient) {
        self.client = client
    }

    /// Groups as conversation seeds, ready to be persisted.
    ///
    /// Only groups still containing this account are returned: left and blocked
    /// groups should not reappear in the sidebar.
    public func fetchGroups(
        account: LinkedAccount,
        directory: RecipientDirectory = RecipientDirectory()
    ) async throws -> [ConversationSeed] {
        let result = try await client.call(
            "listGroups",
            params: .object(["account": .string(account.localRecipientID.rawValue)])
        )
        guard let entries = result.arrayValue else { return [] }
        return entries.compactMap { Self.seed(from: $0, directory: directory) }
    }

    static func seed(from value: JSONValue, directory: RecipientDirectory) -> ConversationSeed? {
        guard let groupID = value["id"]?.stringValue ?? value["groupId"]?.stringValue,
            !groupID.isEmpty
        else { return nil }

        // A group we have left still appears in the listing.
        if value["isMember"]?.boolValue == false { return nil }
        if value["isBlocked"]?.boolValue == true { return nil }

        let members = (value["members"]?.arrayValue ?? []).compactMap { member -> RecipientID? in
            // Members arrive either as bare strings or as objects.
            if let text = member.stringValue { return directory.canonical(for: text) }
            return directory.canonical(
                aci: member["uuid"]?.stringValue,
                number: member["number"]?.stringValue
            )
        }

        let kind = ConversationKind.group(groupID: groupID, memberIDs: members)
        return ConversationSeed(
            id: .of(kind),
            kind: kind,
            title: value["name"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
                .nilWhenEmpty ?? "Group"
        )
    }
}

extension String {
    fileprivate var nilWhenEmpty: String? { isEmpty ? nil : self }
}
