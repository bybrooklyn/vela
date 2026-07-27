import Foundation

/// Stable namespaces for serialized records owned by libsignal.
///
/// Values are intentionally independent of libsignal's Swift type names so an
/// upstream source update cannot silently move or orphan persisted key material.
public enum LibSignalRecordNamespace: String, CaseIterable, Codable, Sendable {
    case identityKeyPair = "identity-key-pair"
    case localRegistrationID = "local-registration-id"
    case remoteIdentity = "remote-identity"
    case preKey = "pre-key"
    case signedPreKey = "signed-pre-key"
    case kyberPreKey = "kyber-pre-key"
    case kyberPreKeyUse = "kyber-pre-key-use"
    case session = "session"
    case senderKey = "sender-key"
}

/// Typed lookup key passed to the SQLCipher-owned persistence implementation.
/// Components remain separate blobs; callers must not join them with a delimiter.
public struct LibSignalRecordKey: Hashable, Sendable {
    public let accountID: String
    public let namespace: LibSignalRecordNamespace
    public let components: [Data]

    public init(
        accountID: String,
        namespace: LibSignalRecordNamespace,
        components: [Data] = []
    ) throws {
        guard !accountID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibSignalRecordStoreError.invalidAccountID
        }
        self.accountID = accountID
        self.namespace = namespace
        self.components = components
    }
}

/// Synchronous persistence seam required by libsignal's synchronous store callbacks.
///
/// Production implementations must execute these operations on a private serial
/// executor and in the same SQLCipher database as the linked account. `replace`
/// and `insertIfAbsent` must each be one atomic database operation.
public protocol LibSignalRecordPersistence: AnyObject, Sendable {
    func load(_ key: LibSignalRecordKey) throws -> Data?

    /// Atomically stores `value` and returns the prior value, if one existed.
    @discardableResult
    func replace(_ value: Data, for key: LibSignalRecordKey) throws -> Data?

    func remove(_ key: LibSignalRecordKey) throws

    /// Atomically inserts only when no row exists.
    /// - Returns: `true` when inserted, `false` when the key already existed.
    @discardableResult
    func insertIfAbsent(_ value: Data, for key: LibSignalRecordKey) throws -> Bool
}

public enum LibSignalRecordStoreError: Error, Sendable, LocalizedError {
    case invalidAccountID
    case missingRequiredRecord(String)
    case corruptRecord(String)

    public var errorDescription: String? {
        switch self {
        case .invalidAccountID:
            "A non-empty account identifier is required for libsignal storage."
        case .missingRequiredRecord(let record):
            "A required libsignal record is missing: \(record)."
        case .corruptRecord(let record):
            "A persisted libsignal record is corrupt: \(record)."
        }
    }
}

extension LibSignalRecordKey {
    package static func uint32Component(_ value: UInt32) -> Data {
        Data([
            UInt8(truncatingIfNeeded: value >> 24),
            UInt8(truncatingIfNeeded: value >> 16),
            UInt8(truncatingIfNeeded: value >> 8),
            UInt8(truncatingIfNeeded: value),
        ])
    }

    package static func decodeUInt32(_ data: Data, record: String) throws -> UInt32 {
        guard data.count == 4 else {
            throw LibSignalRecordStoreError.corruptRecord(record)
        }
        return data.reduce(UInt32.zero) { ($0 << 8) | UInt32($1) }
    }
}
