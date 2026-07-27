import Foundation
import Testing

@testable import VelaDomain

/// Pure presentation contracts shared by sidebar previews, message bubbles,
/// notifications, accessibility descriptions, and diagnostics.
@Suite struct PresentationPrivacyTests {
    @Test func redactionUsesByteCountWithoutReturningMessageContent() {
        let secret = "launch code: 👩🏾‍💻 8249"
        let redacted = Redaction.messageBody(secret)

        #expect(redacted == "<redacted:\(secret.utf8.count)-bytes>")
        #expect(!redacted.contains(secret))
        #expect(!redacted.contains("8249"))
    }

    @Test func redactionHandlesAbsentAndEmptyBodiesWithoutAmbiguity() {
        #expect(Redaction.messageBody(nil) == "<none>")
        #expect(Redaction.messageBody("") == "<redacted:0-bytes>")
    }

    @Test func identifierRedactionKeepsOnlyUsefulEdges() {
        let secret = "recipient-sensitive-identifier"
        let redacted = Redaction.identifier(secret)

        #expect(redacted == "reci…fier")
        #expect(!redacted.contains("sensitive"))
        #expect(Redaction.identifier("short") == "<redacted>")
    }

    @Test func fileNameRedactionNeverReturnsPathOrName() {
        let secret = "/tmp/test-fixtures/private-document.pdf"

        #expect(Redaction.fileName(secret) == "<redacted-filename>")
        #expect(!Redaction.fileName(secret).contains("private-document"))
        #expect(Redaction.fileName(nil) == "<none>")
    }

    @Test func nonSensitivePreviewVariantsStayConcise() {
        #expect(MessageContent.text("Hello").previewText == "Hello")
        #expect(MessageContent.deleted(deletedBy: nil).previewText == "Message deleted")
        #expect(
            MessageContent.unsupported(requiredVersion: 2, description: "future").previewText
                == "Unsupported message"
        )
        #expect(MessageContent.system("Safety number changed").previewText == "Safety number changed")
    }

    @Test func spoilerPreviewConcealsHiddenTextButKeepsContext() throws {
        let text = "Meet at the station at 8"
        let hidden = (text as NSString).range(of: "station at 8")
        let content = MessageContent.styledText(
            text,
            [try #require(TextStyleRange(nsRange: hidden, style: .spoiler))]
        )

        #expect(content.containsSpoiler)
        #expect(content.privacySafePreviewText == "Meet at the Spoiler")
        #expect(!content.privacySafePreviewText.contains("station"))
        #expect(!content.privacySafePreviewText.contains("8"))
    }

    @Test func spoilerPreviewHandlesMultipleUTF16RangesWithoutOffsetDrift() throws {
        let text = "Code 🧪-red then 🔐-blue"
        let first = (text as NSString).range(of: "🧪-red")
        let second = (text as NSString).range(of: "🔐-blue")
        let content = MessageContent.styledText(
            text,
            [
                try #require(TextStyleRange(nsRange: first, style: .spoiler)),
                try #require(TextStyleRange(nsRange: second, style: .spoiler)),
            ]
        )

        #expect(content.privacySafePreviewText == "Code Spoiler then Spoiler")
        #expect(!content.privacySafePreviewText.contains("red"))
        #expect(!content.privacySafePreviewText.contains("blue"))
    }

    @Test func ordinaryFormattingDoesNotChangePrivacySafePreview() {
        let content = MessageContent.styledText(
            "formatted text",
            [TextStyleRange(start: 0, length: 9, style: .bold)]
        )

        #expect(!content.containsSpoiler)
        #expect(content.privacySafePreviewText == "formatted text")
    }

    @Test func absoluteTimestampCutoverBeginsAtSevenDays() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let justInsideWeek = now.addingTimeInterval(-(7 * 24 * 60 * 60 - 1))
        let oneWeek = now.addingTimeInterval(-(7 * 24 * 60 * 60))

        #expect(RelativeTime.short(for: justInsideWeek, reference: now) == "6d")
        let absolute = RelativeTime.short(for: oneWeek, reference: now)
        #expect(absolute != "7d")
        #expect(!absolute.isEmpty)
    }
}
