import Foundation
import Testing
@testable import hermes_deck

struct MentionTextViewTests {
    @Test
    func detectsCompletedMentionToken() {
        #expect(
            MentionTextView.mentionRanges(in: "hi @codex there", sortedAliases: ["claude", "codex"])
                == [NSRange(location: 3, length: 6)]
        )
    }

    @Test
    func detectsTokenAtStringEnd() {
        #expect(
            MentionTextView.mentionRanges(in: "@codex", sortedAliases: ["codex"])
                == [NSRange(location: 0, length: 6)]
        )
    }

    @Test
    func ignoresPartialOrUnboundedMentions() {
        // Still being typed (no trailing boundary yet).
        #expect(MentionTextView.mentionRanges(in: "@cod", sortedAliases: ["codex"]).isEmpty)
        // Alias immediately followed by more letters is not a clean token.
        #expect(MentionTextView.mentionRanges(in: "@codexx", sortedAliases: ["codex"]).isEmpty)
        // Not preceded by whitespace → part of another word.
        #expect(MentionTextView.mentionRanges(in: "a@codex ", sortedAliases: ["codex"]).isEmpty)
    }

    @Test
    func detectsMultipleTokens() {
        #expect(
            MentionTextView.mentionRanges(in: "@claude and @codex", sortedAliases: ["claude", "codex"])
                == [NSRange(location: 0, length: 7), NSRange(location: 12, length: 6)]
        )
    }
}
