import Foundation
import VelaCore
import VelaCrypto
import VelaDomain
import VelaStorage
import VelaTransport

@main
struct VelaDemo {
    static func main() async {
        do {
            try await run()
        } catch {
            print("vela-demo failed: \(String(reflecting: type(of: error)))")
            Foundation.exit(1)
        }
    }

    private static func run() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("vela-demo-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SQLiteStore(
            url: root.appendingPathComponent("vela.sqlite"),
            security: .plaintextDevelopmentOnly
        )
        let crypto = DevelopmentPlaintextCryptoEngine(explicitlyAllowInsecurePlaintext: true)
        let serviceTransport = LoopbackTransport()
        let provisioningTransport = DevelopmentProvisioningTransport()
        let client = VelaClient(
            dependencies: VelaClientDependencies(
                store: store,
                crypto: crypto,
                serviceTransport: serviceTransport,
                provisioningTransport: provisioningTransport,
                recipientRouter: DevelopmentRecipientRouter(),
                backoffPolicy: BackoffPolicy(initialDelay: 0.05, maximumDelay: 0.2, maximumAttempts: 3)
            )
        )

        await client.bootstrap()
        let session = try await client.beginProvisioning(deviceName: "Vela Demo Mac")
        let identityHandle = try await crypto.generateIdentityHandle()
        _ = try await provisioningTransport.completeDevelopmentLink(
            sessionID: session.id,
            deviceName: "Vela Demo Mac",
            identityHandle: identityHandle
        )

        let account = try await waitForReady(client)
        let remoteRecipient = RecipientID("demo-remote-recipient")
        let conversation = ConversationSeed(
            id: ConversationID("demo-conversation"),
            kind: .direct(recipientID: remoteRecipient),
            title: "Local Loopback Demo"
        )

        let outgoingID = try await client.send(
            MessageDraft(text: "Hello from the native Swift client."),
            to: conversation
        )
        _ = try await client.editMessage(outgoingID, newText: "Hello from the native Swift macOS client.")
        _ = try await client.react(to: outgoingID, emoji: "✨")
        _ = await client.flushOutbox()

        let localAddress = DeviceAddress(recipientID: account.localRecipientID, deviceID: account.deviceID)
        let remoteAddress = DeviceAddress(recipientID: remoteRecipient, deviceID: DeviceID("demo-phone"))
        let reply = WireMessage(
            id: .random(),
            conversation: conversation,
            senderID: remoteRecipient,
            recipientID: account.localRecipientID,
            kind: .text,
            body: "Loopback reply received and persisted.",
            sentAt: Date()
        )
        let payload = try WireCodec().encode(reply)
        let incoming = try await crypto.seal(
            payload,
            envelopeID: .random(),
            source: remoteAddress,
            destination: localAddress,
            timestamp: Date(),
            contentType: .message
        )
        await serviceTransport.injectIncoming(incoming)

        try await Task.sleep(for: .milliseconds(150))
        let conversations = try await client.conversations()
        let messages = try await client.messages(in: conversation.id)
        let statistics = try await client.statistics()
        guard
            let mutated = messages.first(where: { $0.id == outgoingID }),
            mutated.content == .text("Hello from the native Swift macOS client."),
            mutated.revision == 1,
            mutated.reactions.map(\.emoji) == ["✨"]
        else {
            throw VelaError.storageFailure("development-mutation-verification")
        }

        print("Vela development pipeline verified")
        print("  state: ready")
        print("  conversations: \(conversations.count)")
        print("  messages: \(messages.count)")
        print("  pending outbox: \(statistics.pendingOutboxCount)")
        print("  seen envelopes: \(statistics.seenEnvelopeCount)")
        print("  mutations: edit + reaction")
        print("  outbound envelopes: \(await serviceTransport.sentEnvelopes().count)")

        await client.shutdown()
    }

    private static func waitForReady(_ client: VelaClient) async throws -> LinkedAccount {
        for _ in 0..<100 {
            let snapshot = await client.snapshot()
            if snapshot.state == .ready, let account = snapshot.linkedAccount {
                return account
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw VelaError.invalidState(expected: "ready", actual: "provisioning-timeout")
    }
}
