import Foundation
import VelaDomain

public struct WireCodec: Sendable {
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        self.decoder = decoder
    }

    public func encode(_ message: WireMessage) throws -> Data {
        try encoder.encode(message)
    }

    public func decode(_ data: Data) throws -> WireMessage {
        try decoder.decode(WireMessage.self, from: data)
    }
}
