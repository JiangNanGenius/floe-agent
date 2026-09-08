import Foundation
import FloePersistence

/// A model's citation is data, not permission to attach an arbitrary message.
public struct DreamEvidenceQuote: Codable, Sendable {
    public var messageID: UUID
    public var excerpt: String

    public init(messageID: UUID, excerpt: String) {
        self.messageID = messageID
        self.excerpt = excerpt
    }
}

/// Bounded auxiliary context only. Never use this to trim an active user's task.
public enum DreamPromptInput {
    public struct MessageExcerpt: Codable, Sendable {
        public var messageID: UUID
        public var role: String
        public var excerpts: [String]
        public var truncated: Bool
    }

    public static func messages(_ messages: [PersistedMessage]) -> [MessageExcerpt] {
        messages.filter { $0.role == "user" || $0.role == "assistant" }.suffix(16).map { message in
            let scalars = message.content.unicodeScalars
            let truncated = scalars.count > 1_024
            let excerpts = truncated ? [
                String(String.UnicodeScalarView(scalars.prefix(512))),
                String(String.UnicodeScalarView(scalars.suffix(512)))
            ] : [message.content]
            return MessageExcerpt(messageID: message.id, role: message.role,
                                  excerpts: excerpts, truncated: truncated)
        }
    }

    public static func transcript(_ messages: [PersistedMessage]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        // This value contains only strings, UUIDs and booleans.
        guard let data = try? encoder.encode(Self.messages(messages)) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    /// Accept only exact, nonempty quotes from a visible USER excerpt. Assistant
    /// claims, hidden middle sections and fabricated IDs cannot become evidence.
    public static func validatedEvidence(
        _ quotes: [DreamEvidenceQuote], messages: [PersistedMessage]
    ) -> [MemoryEvidenceReference] {
        let visible = Self.messages(messages).filter { $0.role == "user" }
        var seen = Set<UUID>()
        return quotes.prefix(12).compactMap { quote in
            guard !quote.excerpt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  quote.excerpt.unicodeScalars.count <= 512,
                  !seen.contains(quote.messageID),
                  let source = visible.first(where: { $0.messageID == quote.messageID }),
                  source.excerpts.contains(where: { $0.contains(quote.excerpt) }) else { return nil }
            seen.insert(quote.messageID)
            return MemoryEvidenceReference(messageID: quote.messageID, excerpt: quote.excerpt)
        }
    }
}
