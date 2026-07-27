import Foundation
import Testing

@testable import VelaSignalCLI

@Suite(.serialized) struct JSONRPCClientTests {
    @Test func requestReceivesMatchingResult() async throws {
        let peer = try FakeSignalCLIPeer { method, _ in
            method == "version"
                ? .success(.object(["version": .string("0.14.6")]))
                : .failure(JSONRPCError(code: -32601, message: "method not found"))
        }
        defer { peer.stop() }

        let client = JSONRPCClient()
        try await client.connect(socketPath: peer.socketPath)
        defer { Task { await client.disconnect() } }

        let result = try await client.call("version")
        #expect(result["version"]?.stringValue == "0.14.6")
    }

    @Test func errorResponseSurfacesCodeAndMessage() async throws {
        let peer = try FakeSignalCLIPeer { _, _ in
            .failure(JSONRPCError(code: -32602, message: "invalid params"))
        }
        defer { peer.stop() }

        let client = JSONRPCClient()
        try await client.connect(socketPath: peer.socketPath)
        defer { Task { await client.disconnect() } }

        await #expect(throws: JSONRPCError(code: -32602, message: "invalid params")) {
            try await client.call("send")
        }
    }

    @Test func concurrentRequestsResolveToTheirOwnResponses() async throws {
        // Each response echoes its request, so a mismatched id shows up as a
        // wrong value rather than a hang.
        let peer = try FakeSignalCLIPeer { _, params in
            .success(.object(["echo": params["value"] ?? .null]))
        }
        defer { peer.stop() }

        let client = JSONRPCClient()
        try await client.connect(socketPath: peer.socketPath)
        defer { Task { await client.disconnect() } }

        let results = try await withThrowingTaskGroup(of: (Int64, Int64?).self) { group in
            for index in 1...25 {
                group.addTask {
                    let value = Int64(index)
                    let response = try await client.call(
                        "echo",
                        params: .object(["value": .integer(value)])
                    )
                    return (value, response["echo"]?.intValue)
                }
            }
            var collected: [(Int64, Int64?)] = []
            for try await pair in group { collected.append(pair) }
            return collected
        }

        #expect(results.count == 25)
        for (sent, received) in results {
            #expect(sent == received)
        }
    }

    @Test func notificationsArePublished() async throws {
        let peer = try FakeSignalCLIPeer { _, _ in .success(.null) }
        defer { peer.stop() }

        let client = JSONRPCClient()
        try await client.connect(socketPath: peer.socketPath)
        defer { Task { await client.disconnect() } }

        let stream = await client.notifications()

        // A round trip first, so the client is definitely reading before the
        // notification is pushed.
        _ = try await client.call("ping")
        peer.send(
            notification: "receive",
            params: .object(["envelope": .object(["timestamp": .integer(1_700_000_000_000)])])
        )

        var iterator = stream.makeAsyncIterator()
        let notification = await iterator.next()
        #expect(notification?.method == "receive")
        #expect(notification?.params["envelope"]?["timestamp"]?.intValue == 1_700_000_000_000)
    }

    @Test func millisecondTimestampsSurviveRoundTrip() throws {
        // Signal identifies messages by millisecond timestamp; losing precision
        // here would break edits, reactions and deletes.
        let original: Int64 = 1_763_925_123_456
        let encoded = try JSONEncoder().encode(JSONValue.integer(original))
        let decoded = try JSONDecoder().decode(JSONValue.self, from: encoded)
        #expect(decoded.intValue == original)

        let date = JSONValue.integer(original).millisecondDate
        #expect(JSONValue.milliseconds(from: try #require(date)).intValue == original)
    }

    @Test func pendingRequestsFailWhenThePeerDisappears() async throws {
        let peer = try FakeSignalCLIPeer { _, _ in .success(.null) }
        let client = JSONRPCClient()
        try await client.connect(socketPath: peer.socketPath)
        defer { Task { await client.disconnect() } }

        _ = try await client.call("ping")
        peer.stop()

        await #expect(throws: (any Error).self) {
            // The daemon dying must surface as an error, not a permanent hang.
            try await client.call("send")
        }
    }
}
