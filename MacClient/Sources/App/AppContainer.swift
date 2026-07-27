#if os(macOS)
    import Foundation
    import UserNotifications
    import VelaCore
    import VelaCrypto
    import VelaDomain
    import VelaSignalBridge
    import VelaSignalCLI
    import VelaStorage
    import VelaTransport

    @MainActor
    final class AppContainer {
        let client: VelaClient
        let store: SQLiteStore
        let notificationSink: MacNotificationSink
        let isDevelopmentMode: Bool

        let developmentCrypto: DevelopmentPlaintextCryptoEngine?
        let developmentServiceTransport: LoopbackTransport?
        let developmentProvisioningTransport: DevelopmentProvisioningTransport?

        /// Non-nil when this build runs against the embedded signal-cli backend.
        let daemon: SignalCLIDaemon?
        let messageIndex: SignalCLIMessageIndex?
        let recipientRouter: SignalCLIRecipientRouter?
        let contactSync: SignalCLIContactSync?
        let groupSync: SignalCLIGroupSync?
        /// Retained so the inbound identity directory can be refreshed as
        /// contacts change.
        let serviceTransport: SignalCLIServiceTransport?
        /// Where cached contact avatars live, so views can resolve relative paths.
        let avatarDirectory: URL?
        private let supportRoot: URL

        /// Builds the live stack when the backend is embedded, and falls back to
        /// the local development stack otherwise, so a build without a vendored
        /// backend still runs.
        static func makeDefault() throws -> AppContainer {
            if SignalCLIBackend.layout() != nil {
                return try AppContainer(useSignalCLIBackend: true)
            }
            return try AppContainer(useSignalCLIBackend: false)
        }

        private convenience init(useSignalCLIBackend: Bool) throws {
            if useSignalCLIBackend {
                try self.init(signalCLI: ())
            } else {
                try self.init()
            }
        }

        /// The live stack. Storage is SQLCipher-encrypted with a key held in an
        /// owner-only file inside the app container, so copying the database file
        /// alone does not reveal message history. See Settings for its limits.
        private init(signalCLI: Void) throws {
            let supportRoot = try Self.applicationSupportRoot()
            self.supportRoot = supportRoot
            let databaseURL = supportRoot.appendingPathComponent("database/vela.sqlite")
            notificationSink = MacNotificationSink()
            isDevelopmentMode = false
            developmentCrypto = nil
            developmentServiceTransport = nil
            developmentProvisioningTransport = nil

            let daemon = SignalCLIDaemon()
            let index = SignalCLIMessageIndex(
                url: supportRoot.appendingPathComponent("signal-cli/message-index.json")
            )
            let router = SignalCLIRecipientRouter()
            let avatars = supportRoot.appendingPathComponent("avatars", isDirectory: true)
            self.daemon = daemon
            self.messageIndex = index
            self.recipientRouter = router
            self.avatarDirectory = avatars
            self.contactSync = SignalCLIContactSync(client: daemon.rpc, avatarDirectory: avatars)
            self.groupSync = SignalCLIGroupSync(client: daemon.rpc)

            let transport = SignalCLIServiceTransport(client: daemon.rpc, index: index)
            self.serviceTransport = transport

            let databaseKey = try KeychainDatabaseKeyProvider(containerRoot: supportRoot).loadOrCreate()
            store = try SQLiteStore(url: databaseURL, security: .sqlCipher(key: databaseKey))
            client = VelaClient(
                dependencies: VelaClientDependencies(
                    store: store,
                    crypto: SignalCLICryptoEngine(),
                    serviceTransport: transport,
                    provisioningTransport: SignalCLIProvisioningTransport(client: daemon.rpc),
                    recipientRouter: router,
                    notificationSink: notificationSink
                )
            )
        }

        init() throws {
            let supportRoot = try Self.applicationSupportRoot()
            self.supportRoot = supportRoot
            let databaseURL = supportRoot.appendingPathComponent("database/vela.sqlite")
            notificationSink = MacNotificationSink()
            daemon = nil
            messageIndex = nil
            recipientRouter = nil
            contactSync = nil
            groupSync = nil
            avatarDirectory = nil
            serviceTransport = nil

            #if VELA_DEVELOPMENT_MODE
                isDevelopmentMode = true
                let crypto = DevelopmentPlaintextCryptoEngine(explicitlyAllowInsecurePlaintext: true)
                let service = LoopbackTransport()
                let provisioning = DevelopmentProvisioningTransport()
                store = try SQLiteStore(url: databaseURL, security: .plaintextDevelopmentOnly)
                developmentCrypto = crypto
                developmentServiceTransport = service
                developmentProvisioningTransport = provisioning
                client = VelaClient(
                    dependencies: VelaClientDependencies(
                        store: store,
                        crypto: crypto,
                        serviceTransport: service,
                        provisioningTransport: provisioning,
                        recipientRouter: DevelopmentRecipientRouter(),
                        notificationSink: notificationSink
                    )
                )
            #else
                isDevelopmentMode = false
                let databaseKey = try KeychainDatabaseKeyProvider(containerRoot: supportRoot).loadOrCreate()
                store = try SQLiteStore(url: databaseURL, security: .sqlCipher(key: databaseKey))
                let bridge = UnavailableSignalUpstreamBridge()
                let crypto = LibSignalCryptoEngine(adapter: bridge)
                developmentCrypto = nil
                developmentServiceTransport = nil
                developmentProvisioningTransport = nil
                client = VelaClient(
                    dependencies: VelaClientDependencies(
                        store: store,
                        crypto: crypto,
                        serviceTransport: bridge,
                        provisioningTransport: bridge,
                        recipientRouter: UnavailableRecipientRouter(),
                        notificationSink: notificationSink
                    )
                )
            #endif
        }

        /// Clears account-derived files that live outside the SQLCipher store.
        /// Caller must stop the daemon and clear the store first.
        func eraseAccountArtifacts() async throws {
            await messageIndex?.removeAll()
            let notificationCenter = UNUserNotificationCenter.current()
            notificationCenter.removeAllDeliveredNotifications()
            notificationCenter.removeAllPendingNotificationRequests()
            try SignalCLIBackend.eraseAccountData(
                layout: SignalCLIBackend.layout(),
                applicationSupportRoot: supportRoot
            )
        }

        private static func applicationSupportRoot() throws -> URL {
            let base = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            let root = base.appendingPathComponent("Vela", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("database", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("attachments", isDirectory: true),
                withIntermediateDirectories: true
            )
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("diagnostics", isDirectory: true),
                withIntermediateDirectories: true
            )
            return root
        }
    }
#endif
