import Foundation
import Testing

@testable import VelaCrypto
@testable import VelaSignalBridge

@Suite struct LibSignalRecordPersistenceTests {
    @Test func recordKeysKeepComponentsTypedAndUnambiguous() throws {
        let split = try LibSignalRecordKey(
            accountID: "account",
            namespace: .session,
            components: [Data("a".utf8), Data("b:c".utf8)]
        )
        let joined = try LibSignalRecordKey(
            accountID: "account",
            namespace: .session,
            components: [Data("a:b".utf8), Data("c".utf8)]
        )

        #expect(split != joined)
    }

    @Test func recordKeysArePartitionedByAccountAndNamespace() throws {
        let component = Data([0, 0, 0, 7])
        let firstAccount = try LibSignalRecordKey(
            accountID: "first",
            namespace: .preKey,
            components: [component]
        )
        let secondAccount = try LibSignalRecordKey(
            accountID: "second",
            namespace: .preKey,
            components: [component]
        )
        let firstSession = try LibSignalRecordKey(
            accountID: "first",
            namespace: .session,
            components: [component]
        )

        #expect(firstAccount != secondAccount)
        #expect(firstAccount != firstSession)
    }

    @Test func accountIdentifierMustNotBeBlank() {
        #expect(throws: LibSignalRecordStoreError.self) {
            try LibSignalRecordKey(accountID: " \n ", namespace: .identityKeyPair)
        }
    }

    @Test func registrationIdentifierEncodingIsStableBigEndian() throws {
        let encoded = LibSignalRecordKey.uint32Component(0x0102_A0FF)
        #expect(encoded == Data([0x01, 0x02, 0xA0, 0xFF]))
        #expect(try LibSignalRecordKey.decodeUInt32(encoded, record: "registration") == 0x0102_A0FF)
        #expect(throws: LibSignalRecordStoreError.self) {
            try LibSignalRecordKey.decodeUInt32(Data([0x01]), record: "registration")
        }
    }
}
