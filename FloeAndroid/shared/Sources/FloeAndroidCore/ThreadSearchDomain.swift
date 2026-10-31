// SPDX-License-Identifier: MPL-2.0
//
// Current-thread visible-text search for the Android conversation surface.
//
// Authority split:
//  * this file owns the QUERY normalizer, the VISIBLE projection and the SQL
//    predicate used by the native `conversation.messageSearch` command;
//  * the durable message bodies stay in the ORIGINAL `messages` table, the
//    live temporary session stays in its ORIGINAL RAM store, and the App
//    never opens a second database or keeps a second transcript;
//  * a hit names the ACTUAL message id. The App then asks for a bounded
//    window around it through `conversation.messageWindow` and highlights the
//    SAME visible string whose offsets were returned here.
//
// Visible projection rules mirror the frozen iOS `ConversationSearchText`:
// assistant content is Markdown SOURCE, so syntax is flattened before
// matching; link text is kept and the hidden target is dropped; fenced code
// content is kept without fence markers/language; user content is verbatim.
// Reasoning, tool output, hidden context and internal template bytes are
// never part of a message body and therefore never become hits.
import Foundation
import GRDB
import FloeCore
import FloeModels
import FloePersistence

/// Parsed, bounded `conversation.messageSearch` payload.
public struct ThreadSearchRequest: Sendable, Equatable {
    public var raw: String
    public var limit: Int

    public static let maximumQueryCharacters = 512
    public static let maximumResults = 200
    public static let defaultResults = 200

    public init(raw: String, limit: Int = ThreadSearchRequest.defaultResults) {
        self.raw = String(raw.prefix(Self.maximumQueryCharacters))
        self.limit = min(Self.maximumResults, max(1, limit))
    }

    public static func parse(_ payload: SettingsDomainV1.JSONValue?) throws
        -> ThreadSearchRequest
    {
        guard let payload else {
            throw ConversationDomainError.invalidEnvelope("missingPayload")
        }
        guard case .object(let root) = payload else {
            throw ConversationDomainError.invalidEnvelope("invalidPayload")
        }
        guard root.keys.allSatisfy({ ["query", "limit"].contains($0) }) else {
            throw ConversationDomainError.invalidEnvelope("unknownMessageSearchField")
        }
        guard case .string(let raw)? = root["query"] else {
            throw ConversationDomainError.invalidEnvelope("missingPayloadField:query")
        }
        guard !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              raw.count <= maximumQueryCharacters else {
            throw ConversationDomainError.invalidEnvelope("invalidPayloadField:query")
        }
        var limit = defaultResults
        if let value = root["limit"] {
            guard case .integer(let number) = value,
                  number >= 1, number <= Int64(maximumResults) else {
                throw ConversationDomainError.invalidEnvelope("invalidPayloadField:limit")
            }
            limit = Int(number)
        }
        return ThreadSearchRequest(raw: raw, limit: limit)
    }
}

/// One normalizer for both the native SQL predicate and the App's local
/// highlight math. Semantics: whitespace-AND, double-quoted phrase, case/
/// diacritic/width insensitive, bounded terms.
public struct ThreadSearchQuery: Sendable, Equatable {
    public enum Term: Sendable, Equatable, Hashable {
        case word(String)
        case phrase(String)

        public var text: String {
            switch self {
            case .word(let value), .phrase(let value): value
            }
        }
    }

    public static let maximumTerms = 8
    public static let maximumWordCharacters = 64
    public static let maximumPhraseCharacters = 128

    public let raw: String
    public let terms: [Term]

    public init(raw: String) {
        self.raw = raw
        var parsed: [Term] = []
        var buffer = ""
        var inPhrase = false

        func emit(_ value: String, phrase: Bool) {
            let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            let bounded = String(
                text.prefix(phrase ? Self.maximumPhraseCharacters : Self.maximumWordCharacters))
            let normalized = bounded.lowercased()
            guard !parsed.contains(where: { $0.text.lowercased() == normalized }) else { return }
            parsed.append(phrase ? .phrase(bounded) : .word(bounded))
        }

        for character in raw {
            if character == "\"" || character == "\u{201c}" || character == "\u{201d}" {
                if inPhrase {
                    emit(buffer, phrase: true)
                    buffer = ""
                    inPhrase = false
                } else {
                    emit(buffer, phrase: false)
                    buffer = ""
                    inPhrase = true
                }
                continue
            }
            if !inPhrase, character.isWhitespace {
                emit(buffer, phrase: false)
                buffer = ""
            } else {
                buffer.append(character)
            }
        }
        emit(buffer, phrase: inPhrase)
        self.terms = Array(parsed.prefix(Self.maximumTerms))
    }

    public var isEmpty: Bool { terms.isEmpty }

    private static let compareOptions: String.CompareOptions = [
        .caseInsensitive, .diacriticInsensitive, .widthInsensitive,
    ]

    public func matches(_ text: String) -> Bool {
        terms.allSatisfy { term in
            !term.text.isEmpty
                && text.range(of: term.text, options: Self.compareOptions) != nil
        }
    }

    /// Character offsets (into [text]) of every term occurrence, merged and
    /// sorted. The caller must pass the SAME visible string it renders.
    public func ranges(in text: String) -> [Range<Int>] {
        guard !text.isEmpty else { return [] }
        var found: [Range<Int>] = []
        for term in terms {
            var searchStart = text.startIndex
            var count = 0
            while searchStart < text.endIndex,
                  let range = text.range(
                    of: term.text, options: Self.compareOptions,
                    range: searchStart..<text.endIndex) {
                let lower = text.distance(from: text.startIndex, to: range.lowerBound)
                let upper = text.distance(from: text.startIndex, to: range.upperBound)
                if upper > lower { found.append(lower..<upper) }
                searchStart = range.upperBound
                count += 1
                if count >= 512 { break }
            }
        }
        found.sort { lhs, rhs in
            lhs.lowerBound != rhs.lowerBound
                ? lhs.lowerBound < rhs.lowerBound
                : lhs.upperBound < rhs.upperBound
        }
        var merged: [Range<Int>] = []
        for range in found {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// SQLite connection-local predicate implementing `matches(_:)` over the
    /// visible projection. The query text is an argument, never SQL text.
    public static let visibleMatchFunction = DatabaseFunction(
        "floe_thread_search_match",
        argumentCount: 3,
        pure: true
    ) { values in
        guard let role = String.fromDatabaseValue(values[0]),
              let content = String.fromDatabaseValue(values[1]),
              let rawQuery = String.fromDatabaseValue(values[2]) else { return 0 }
        let query = ThreadSearchQuery(raw: rawQuery)
        guard !query.isEmpty else { return 0 }
        let visible = ThreadSearchText.visibleText(role: role, content: content)
        return query.matches(visible) ? 1 : 0
    }
}

/// Visible projection shared by the native search, the App highlight math and
/// the tests. It is intentionally line-oriented and deterministic; no UI
/// framework or regular-expression engine is required on Android.
public enum ThreadSearchText {
    public static let maximumSnippetCharacters = 160

    public static func visibleText(role: String, content: String) -> String {
        role.lowercased() == "assistant" ? visibleText(markdown: content) : content
    }

    public static func visibleText(markdown source: String) -> String {
        var output: [String] = []
        var inFence = false
        for rawLine in source.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                inFence.toggle()
                continue
            }
            if inFence {
                output.append(rawLine)
                continue
            }
            if isTableSeparator(trimmed) { continue }
            if isThematicBreak(trimmed) { continue }
            if isReferenceDefinition(trimmed) { continue }
            var line = stripBlockMarkers(rawLine)
            line = flattenInline(line)
            let cleaned = line.trimmingCharacters(in: .whitespaces)
            if cleaned.isEmpty {
                if output.last?.isEmpty == false { output.append("") }
            } else {
                output.append(cleaned)
            }
        }
        return output.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One readable line around the first match, bounded to
    /// [maximumCharacters]. Never includes hidden link targets because the
    /// input is already the visible projection.
    public static func snippet(
        in text: String,
        query: ThreadSearchQuery,
        maximumCharacters: Int = 160
    ) -> String {
        let limit = max(24, maximumCharacters)
        guard let first = query.ranges(in: text).first,
              first.lowerBound < text.count else {
            let firstLine = text.split(separator: "\n", omittingEmptySubsequences: true)
                .first.map(String.init) ?? text
            return String(firstLine.prefix(limit))
        }
        let matchStart = text.index(text.startIndex, offsetBy: first.lowerBound)
        var lineStart = matchStart
        while lineStart > text.startIndex {
            let previous = text.index(before: lineStart)
            if text[previous] == "\n" { break }
            lineStart = previous
        }
        var lineEnd = matchStart
        while lineEnd < text.endIndex, text[lineEnd] != "\n" {
            lineEnd = text.index(after: lineEnd)
        }
        let line = String(text[lineStart..<lineEnd])
        let matchOffset = text.distance(from: lineStart, to: matchStart)
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.count <= limit { return trimmed }
        let windowStart = max(0, min(matchOffset - limit / 3, max(0, line.count - limit)))
        let startIndex = line.index(line.startIndex, offsetBy: windowStart)
        let endIndex = line.index(
            startIndex,
            offsetBy: min(limit, line.distance(from: startIndex, to: line.endIndex)))
        var window = String(line[startIndex..<endIndex])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if windowStart > 0 { window = "\u{2026}" + window }
        if endIndex < line.endIndex { window += "\u{2026}" }
        return window
    }

    // MARK: - Line-level syntax removal

    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.hasPrefix("|") || line.contains("|") else { return false }
        let cells = line.split(separator: "|", omittingEmptySubsequences: false)
        guard cells.count > 1 else { return false }
        return cells.allSatisfy { cell in
            let value = String(cell).trimmingCharacters(in: .whitespaces)
            return !value.isEmpty && value.allSatisfy { $0 == "-" || $0 == ":" }
        }
    }

    private static func isThematicBreak(_ line: String) -> Bool {
        guard line.count >= 3 else { return false }
        let allowed: Set<Character> = ["-", "*", "_", " "]
        guard line.allSatisfy({ allowed.contains($0) }),
              line.contains("-") || line.contains("*") || line.contains("_") else {
            return false
        }
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count >= 3
    }

    /// `[label]: url` reference definitions are not rendered text.
    private static func isReferenceDefinition(_ line: String) -> Bool {
        guard line.hasPrefix("[") else { return false }
        guard let close = line.firstIndex(of: "]") else { return false }
        let remainder = line[line.index(after: close)...]
        return remainder.hasPrefix(":")
    }

    private static func stripBlockMarkers(_ rawLine: String) -> String {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("|") && line.hasSuffix("|") && line.count > 1 {
            let cells = line.split(separator: "|", omittingEmptySubsequences: false)
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return cells.joined(separator: " ")
        }
        var leading = Substring(line)
        while leading.hasPrefix(">") {
            leading = leading.dropFirst()
            leading = leading.drop(while: { $0 == " " || $0 == "\t" })
        }
        line = String(leading)
        // ATX heading marker.
        var hashes = 0
        for character in line {
            if character == "#" { hashes += 1 } else { break }
        }
        if hashes > 0, hashes <= 6 {
            let rest = line.dropFirst(hashes)
            if rest.first == " " || rest.isEmpty {
                line = String(rest).trimmingCharacters(in: .whitespaces)
            }
        }
        // Bullet / ordered list marker.
        if let first = line.first, "-*+".contains(first) {
            let rest = line.dropFirst()
            if rest.first == " " || rest.isEmpty {
                line = String(rest).trimmingCharacters(in: .whitespaces)
            }
        } else {
            var digits = 0
            for character in line {
                if character.isNumber { digits += 1 } else { break }
            }
            if digits > 0, digits <= 9 {
                var index = line.index(line.startIndex, offsetBy: digits)
                if index < line.endIndex, line[index] == "." || line[index] == ")" {
                    index = line.index(after: index)
                    if index < line.endIndex, line[index] == " " {
                        line = String(line[index...]).trimmingCharacters(in: .whitespaces)
                    }
                }
            }
        }
        return line
    }

    // MARK: - Inline syntax removal

    private static func flattenInline(_ source: String) -> String {
        var output = ""
        var index = source.startIndex
        func peek(_ offset: Int) -> Character? {
            guard let target = source.index(index, offsetBy: offset, limitedBy: source.endIndex),
                  target < source.endIndex else { return nil }
            return source[target]
        }
        while index < source.endIndex {
            let character = source[index]
            if character == "\\" {
                let next = source.index(after: index)
                if next < source.endIndex {
                    output.append(source[next])
                    index = source.index(after: next)
                } else {
                    index = next
                }
                continue
            }
            if character == "!" , peek(1) == "[" {
                if let (text, next) = parseLink(source, from: source.index(index, offsetBy: 2)) {
                    output += text
                    index = next
                    continue
                }
            }
            if character == "[" {
                if let (text, next) = parseLink(source, from: source.index(after: index)) {
                    output += text
                    index = next
                    continue
                }
            }
            if character == "<" {
                // HTML comment: drop the whole comment; other tags are kept
                // literally because the renderer does not execute markup.
                if source[index...].hasPrefix("<!--"),
                   let end = source.range(of: "-->", range: index..<source.endIndex) {
                    index = end.upperBound
                    continue
                }
            }
            if character == "`" {
                var fence = 0
                var cursor = index
                while cursor < source.endIndex, source[cursor] == "`" {
                    fence += 1
                    cursor = source.index(after: cursor)
                }
                let marker = String(repeating: "`", count: fence)
                if let end = source.range(of: marker, range: cursor..<source.endIndex) {
                    output += String(source[cursor..<end.lowerBound])
                    index = end.upperBound
                    continue
                }
            }
            if character == "*" || character == "_" || character == "~" {
                let next = source.index(after: index)
                if character == "_" {
                    // CommonMark does not use intraword underscore runs as
                    // emphasis delimiters. Keep the entire run before the
                    // strong/emphasis cases below: ALPHA19_NOTE_OK and a__b
                    // are visible identifiers, including inside emphasis.
                    var runEnd = next
                    while runEnd < source.endIndex, source[runEnd] == "_" {
                        runEnd = source.index(after: runEnd)
                    }
                    let beforeIsWord = index > source.startIndex
                        && source[source.index(before: index)] != "_"
                        && isWordCharacter(source[source.index(before: index)])
                    let afterIsWord = runEnd < source.endIndex
                        && isWordCharacter(source[runEnd])
                    if beforeIsWord && afterIsWord {
                        output += String(source[index..<runEnd])
                        index = runEnd
                        continue
                    }
                }
                if next < source.endIndex, source[next] == character {
                    // Strong/strikethrough delimiter: drop both markers.
                    index = source.index(after: next)
                    continue
                }
                // Emphasis delimiter: drop one marker when it is adjacent to
                // word content (the common case rendered by the UI).
                let previousIsWord = index > source.startIndex
                    && isWordCharacter(source[source.index(before: index)])
                let nextIsWord = next < source.endIndex && isWordCharacter(source[next])
                if previousIsWord || nextIsWord {
                    index = next
                    continue
                }
            }
            output.append(character)
            index = source.index(after: index)
        }
        return output
    }

    private static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    /// Parses a Markdown link starting just after `[`. Returns the visible
    /// label and the index after the closing `)`. Reference links are
    /// flattened to their label as well. On malformed input returns nil and
    /// the caller keeps the literal bracket (content is never dropped).
    private static func parseLink(
        _ source: String,
        from start: String.Index
    ) -> (String, String.Index)? {
        guard let close = source.range(of: "]", range: start..<source.endIndex) else {
            return nil
        }
        let label = String(source[start..<close.lowerBound])
        let after = close.upperBound
        guard after < source.endIndex else { return nil }
        if source[after] == "(" {
            var depth = 1
            var cursor = source.index(after: after)
            var escaped = false
            while cursor < source.endIndex {
                let character = source[cursor]
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "(" {
                    depth += 1
                } else if character == ")" {
                    depth -= 1
                    if depth == 0 {
                        return (label, source.index(after: cursor))
                    }
                }
                cursor = source.index(after: cursor)
            }
            return nil
        }
        if source[after] == "[" {
            if let refClose = source.range(of: "]", range: source.index(after: after)..<source.endIndex) {
                return (label, refClose.upperBound)
            }
        }
        return (label, after)
    }
}

/// Search execution over already-loaded message records (used by the live
/// temporary session and by tests). Durable search runs the same projection
/// inside SQLite through `ThreadSearchQuery.visibleMatchFunction`.
public enum ThreadSearchDomain {
    public struct Hit: Sendable, Equatable {
        public var messageID: UUID
        public var role: String
        public var snippet: String
        public var createdAt: Date

        public init(messageID: UUID, role: String, snippet: String, createdAt: Date) {
            self.messageID = messageID
            self.role = role
            self.snippet = snippet
            self.createdAt = createdAt
        }
    }

    public static func search(
        messages: [PersistedMessage],
        conversationID: UUID,
        query: ThreadSearchRequest
    ) -> [Hit] {
        let parsed = ThreadSearchQuery(raw: query.raw)
        guard !parsed.isEmpty else { return [] }
        var hits: [Hit] = []
        for message in messages where hits.count < query.limit {
            guard message.conversationID == conversationID,
                  message.role.lowercased() == "user" || message.role.lowercased() == "assistant" else {
                continue
            }
            let visible = ThreadSearchText.visibleText(
                role: message.role, content: message.content)
            guard parsed.matches(visible) else { continue }
            hits.append(Hit(
                messageID: message.id,
                role: message.role.lowercased(),
                snippet: ThreadSearchText.snippet(in: visible, query: parsed),
                createdAt: message.createdAt))
        }
        return hits.sorted {
            $0.createdAt != $1.createdAt
                ? $0.createdAt < $1.createdAt
                : $0.messageID.uuidString < $1.messageID.uuidString
        }
    }

    public static func reply(
        conversationID: UUID,
        query: ThreadSearchRequest,
        hits: [Hit],
        isTemporary: Bool
    ) -> ThreadSearchReply {
        ThreadSearchReply(
            conversationID: conversationID,
            query: query.raw,
            isTemporary: isTemporary,
            hits: Array(hits.prefix(query.limit)),
            hasMore: hits.count > query.limit)
    }

    /// Sendable reply for the actor boundary. `wireObject()` is a pure
    /// nonisolated projection used by the command handler after the actor
    /// call returns.
    public struct ThreadSearchReply: Sendable {
        public let conversationID: UUID
        public let query: String
        public let isTemporary: Bool
        public let hits: [Hit]
        public let hasMore: Bool

        public func wireObject() -> [String: Any] {
            [
                "schema": "floe.threadsearch.v1",
                "conversationID": conversationID.uuidString,
                "query": query,
                "isTemporary": isTemporary,
                "rows": hits.map { hit in
                    [
                        "messageID": hit.messageID.uuidString,
                        "role": hit.role,
                        "snippet": hit.snippet,
                        "createdAt": ConversationWireDate.encode(hit.createdAt),
                    ] as [String: Any]
                },
                "hasMore": hasMore,
            ]
        }
    }
}

/// Bounded `conversation.messageWindow` payload.
public struct ThreadMessageWindowRequest: Sendable, Equatable {
    public var messageID: UUID
    public var before: Int
    public var after: Int

    public static let defaultBefore = 40
    public static let defaultAfter = 4
    public static let maximumBefore = 200
    public static let maximumAfter = 20

    public static func parse(_ payload: SettingsDomainV1.JSONValue?) throws
        -> ThreadMessageWindowRequest
    {
        guard let payload, case .object(let root) = payload else {
            throw ConversationDomainError.invalidEnvelope("missingPayload")
        }
        guard root.keys.allSatisfy({ ["messageID", "before", "after"].contains($0) }) else {
            throw ConversationDomainError.invalidEnvelope("unknownMessageWindowField")
        }
        guard case .string(let raw)? = root["messageID"],
              let messageID = UUID(uuidString: raw) else {
            throw ConversationDomainError.invalidEnvelope("invalidPayloadField:messageID")
        }
        var before = defaultBefore
        if let value = root["before"] {
            guard case .integer(let number) = value,
                  number >= 1, number <= Int64(maximumBefore) else {
                throw ConversationDomainError.invalidEnvelope("invalidPayloadField:before")
            }
            before = Int(number)
        }
        var after = defaultAfter
        if let value = root["after"] {
            guard case .integer(let number) = value,
                  number >= 0, number <= Int64(maximumAfter) else {
                throw ConversationDomainError.invalidEnvelope("invalidPayloadField:after")
            }
            after = Int(number)
        }
        return ThreadMessageWindowRequest(
            messageID: messageID, before: before, after: after)
    }
}
