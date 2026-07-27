import Foundation
import Testing

@testable import VelaDomain

@Suite struct DomainTests {
    @Test func typedIdentifierCodableRoundTrip() throws {
        let original = ConversationID("conversation-123")
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ConversationID.self, from: encoded)
        #expect(decoded == original)
    }

    @Test func messageDraftEmptySemantics() {
        #expect(MessageDraft(text: "  \n ").isEmpty)
        #expect(!(MessageDraft(text: "hello").isEmpty))
        #expect(
            !MessageDraft(
                text: "",
                attachments: [AttachmentReference(mimeType: "image/png", byteCount: 1)]
            ).isEmpty)
    }

    @Test func redactionNeverReturnsMessageContent() {
        let secret = "this is extremely private"
        let redacted = Redaction.messageBody(secret)
        #expect(!(redacted.contains("private")))
        #expect(redacted.contains("bytes"))
    }
}
