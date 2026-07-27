#if os(macOS)
    import Foundation
    import LocalAuthentication
    import Security
    import VelaStorage
    import os

    enum KeychainKeyError: Error, LocalizedError {
        case randomGenerationFailed(OSStatus)
        case keyFileUnreadable(String)
        case keyFileUnwritable(String)
        case malformedStoredKey

        var errorDescription: String? {
            switch self {
            case .randomGenerationFailed(let status):
                "Could not generate a database key (status \(status))."
            case .keyFileUnreadable(let detail):
                "Could not read the database key: \(detail)."
            case .keyFileUnwritable(let detail):
                "Could not store the database key: \(detail)."
            case .malformedStoredKey:
                "The stored database key is malformed."
            }
        }
    }

    /// Holds the SQLCipher key for the local database.
    ///
    /// The key lives in a `0600` file inside the App Sandbox container rather
    /// than the Keychain. The legacy Keychain authorises by code signature, and
    /// an ad-hoc signed build gets a new signature on every rebuild, so macOS
    /// asked for the login password again each time. The data-protection
    /// keychain avoids that but needs a Team-ID-prefixed `keychain-access-groups`
    /// entitlement, which makes an ad-hoc build fail to launch outright.
    ///
    /// **This is weaker than the Keychain and the app says so in Settings.** The
    /// database is still encrypted at rest, so copying the `.sqlite` file alone
    /// yields nothing, but anyone who can read the container can read the key
    /// beside it. Signing with a Developer ID would allow moving back.
    struct KeychainDatabaseKeyProvider {
        private static let log = Logger(subsystem: "works.deadsignal.vela", category: "database-key")

        /// Kept for migration only: an existing Keychain key is adopted so the
        /// current database stays readable.
        private let legacyService = "works.deadsignal.vela.database"
        private let legacyAccount = "primary-database-key"

        private let keyURL: URL

        init(containerRoot: URL) {
            keyURL = containerRoot.appendingPathComponent("database/key.bin")
        }

        func loadOrCreate() throws -> DatabaseKey {
            if let existing = try loadFromFile() {
                return try DatabaseKey(bytes: existing)
            }

            // A database encrypted under the old Keychain key must keep working.
            if let migrated = legacyKeychainKey() {
                try writeToFile(migrated)
                Self.log.info("migrated the database key out of the Keychain")
                return try DatabaseKey(bytes: migrated)
            }

            var bytes = Data(count: 32)
            let status = bytes.withUnsafeMutableBytes { rawBuffer in
                SecRandomCopyBytes(kSecRandomDefault, rawBuffer.count, rawBuffer.baseAddress!)
            }
            guard status == errSecSuccess else {
                throw KeychainKeyError.randomGenerationFailed(status)
            }

            try writeToFile(bytes)
            Self.log.info("created a new database key")
            return try DatabaseKey(bytes: bytes)
        }

        private func loadFromFile() throws -> Data? {
            guard FileManager.default.fileExists(atPath: keyURL.path) else { return nil }
            do {
                let data = try Data(contentsOf: keyURL)
                guard data.count >= 32 else { throw KeychainKeyError.malformedStoredKey }
                return data
            } catch let error as KeychainKeyError {
                throw error
            } catch {
                throw KeychainKeyError.keyFileUnreadable(error.localizedDescription)
            }
        }

        private func writeToFile(_ data: Data) throws {
            do {
                try FileManager.default.createDirectory(
                    at: keyURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                // Not `.completeFileProtection`: that is an iOS data-protection
                // class and the write fails outright on macOS. POSIX 0600 below
                // is what actually restricts access here.
                try data.write(to: keyURL, options: [.atomic])
                // Owner-only. `.atomic` writes via a temporary file, so the mode
                // has to be set after the replace rather than before.
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: keyURL.path
                )
            } catch {
                throw KeychainKeyError.keyFileUnwritable(error.localizedDescription)
            }
        }

        /// Reads the pre-migration Keychain item, if the user still has one.
        /// Failure is not an error: it usually just means there is nothing there.
        private func legacyKeychainKey() -> Data? {
            let context = LAContext()
            // The legacy lookup is a best-effort migration. It must never put a
            // password or Touch ID prompt in front of app launch.
            context.interactionNotAllowed = true
            let query: [String: Any] = [
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: legacyService,
                kSecAttrAccount as String: legacyAccount,
                kSecReturnData as String: true,
                kSecMatchLimit as String: kSecMatchLimitOne,
                // Replaces deprecated `kSecUseAuthenticationUIFail` while
                // retaining the no-prompt migration guarantee.
                kSecUseAuthenticationContext as String: context,
            ]

            var result: CFTypeRef?
            guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
                let data = result as? Data,
                data.count >= 32
            else { return nil }
            return data
        }
    }
#endif
