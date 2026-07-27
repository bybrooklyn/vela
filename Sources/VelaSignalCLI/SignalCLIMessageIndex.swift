import Foundation
import VelaDomain

/// Maps Vela's `MessageID`s to the Signal send timestamps that identify the same
/// message on the wire.
///
/// Signal has no message IDs: a message is identified by the millisecond
/// timestamp it was sent at, plus its author. Every edit, reaction and remote
/// delete refers to its target that way, so without this mapping those
/// operations cannot be expressed at all.
///
/// Incoming messages get their `MessageID` derived from the timestamp, so they
/// need no lookup; outgoing messages are assigned an ID before `send` returns a
/// timestamp, so the pairing has to be remembered.
public actor SignalCLIMessageIndex {
    private struct Entry: Codable {
        var timestamp: Int64
        var author: String
    }

    private let url: URL?
    private var entries: [String: Entry] = [:]
    private var isDirty = false

    /// - Parameter url: where to persist. Passing nil keeps the index in memory,
    ///   which is what the tests use.
    public init(url: URL? = nil) {
        self.url = url
        if let url, let data = try? Data(contentsOf: url),
            let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        {
            entries = decoded
        }
    }

    /// Derives the stable `MessageID` for an incoming Signal message, so that a
    /// later reaction naming the same timestamp resolves to the same row.
    public nonisolated static func messageID(forSignalTimestamp timestamp: Int64) -> MessageID {
        MessageID(String(timestamp))
    }

    public func record(messageID: MessageID, signalTimestamp: Int64, author: RecipientID) {
        entries[messageID.rawValue] = Entry(timestamp: signalTimestamp, author: author.rawValue)
        isDirty = true
        persist()
    }

    public func signalTimestamp(for messageID: MessageID) -> Int64? {
        if let entry = entries[messageID.rawValue] { return entry.timestamp }
        // Incoming IDs are the timestamp itself.
        return Int64(messageID.rawValue)
    }

    public func signalTimestamps(for messageIDs: [MessageID]) -> [Int64] {
        messageIDs.compactMap { signalTimestamp(for: $0) }
    }

    public func author(for messageID: MessageID) -> RecipientID? {
        entries[messageID.rawValue].map { RecipientID($0.author) }
    }

    public func removeAll() {
        entries.removeAll()
        isDirty = true
        persist()
    }

    private func persist() {
        guard isDirty, let url else { return }
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: url, options: .atomic)
        isDirty = false
    }
}
