import Foundation
import Testing
@testable import FloeMarkdown

@Suite("FloeMarkdown.BoundedParseReuse")
@MainActor
struct MarkdownBlockParseCacheTests {
    @Test("Completed document redraws reuse the real AST without reparsing")
    func completedDocumentReuse() {
        let source = "# Heading\n\nText **bold** and [link](https://example.invalid/).\n\n| A | B |\n|---|---|\n| 1 | 2 |\n"
        var parsed: [String] = []
        let cache = MarkdownBlockParseCache { input in
            parsed.append(input)
            return MarkdownBlockParser.parse(input)
        }
        let expected = MarkdownBlockParser.parse(source)
        for _ in 0..<8 { #expect(cache.blocks(for: source) == expected) }
        #expect(parsed == [source])
    }

    @Test("Changing content evicts the old entry and preserves Markdown semantics")
    func sourceChangeAndSingleEntryEviction() {
        let a = "```swift\nlet x = 1\n```\n"
        let b = "> quote\n\n- bullet\n  - child\n\n---\n"
        var parsed: [String] = []
        let cache = MarkdownBlockParseCache { input in
            parsed.append(input)
            return MarkdownBlockParser.parse(input)
        }
        for source in [a, b, a] {
            #expect(cache.blocks(for: source) == MarkdownBlockParser.parse(source))
        }
        #expect(parsed == [a, b, a])
    }

    @Test("The unchanged streaming prefix is parsed once while the live tail keeps updating")
    func streamingPrefixReuse() {
        let prefix = "# Heading\n\nA completed paragraph.\n"
        let tails = ["a", "a **bo", "a **bold**", "[unfinished", "[link](https://example.invalid/)"]
        var parsed: [String] = []
        let cache = MarkdownBlockParseCache { input in
            parsed.append(input)
            return MarkdownBlockParser.parse(input)
        }
        for tail in tails {
            let actual = cache.streamingParts(for: prefix + tail)
            let expected = MarkdownBlockParser.parseStreaming(prefix + tail)
            #expect(actual.completed == expected.completed)
            #expect(actual.tail == expected.tail)
        }
        #expect(parsed.filter { $0 == prefix }.count == 1)
        #expect(parsed.count == tails.count + 1)
    }

    @Test("Streaming window, fences and the final document keep the original parser boundary")
    func streamingAndTerminalEquivalence() {
        let sources = ["", "partial **bold", "```swift\nlet x = 1\n", "> a\n> b\n", "| A |\n|---|\n| a |\n", String(repeating: "z", count: MarkdownBlockParser.maximumStreamingCharacters + 32)]
        let cache = MarkdownBlockParseCache()
        for source in sources {
            let actual = cache.streamingParts(for: source)
            let expected = MarkdownBlockParser.parseStreaming(source)
            #expect(actual.completed == expected.completed)
            #expect(actual.tail == expected.tail)
            #expect(cache.blocks(for: source) == MarkdownBlockParser.parse(source))
        }
    }

    @Test("The limit is UTF8 bytes; oversized content renders fully without being retained")
    func byteBudgetAndOversizedNonretention() {
        let limit = MarkdownBlockParseCache.maximumCachedSourceBytes
        let within = "```\n" + String(repeating: "é", count: (limit - 8) / 2) + "\n```"
        let oversized = within + "é"
        #expect(within.utf8.count == limit)
        #expect(oversized.count < limit)
        var parsed: [String] = []
        let cache = MarkdownBlockParseCache { input in
            parsed.append(input)
            return MarkdownBlockParser.parse(input)
        }
        let expectedWithin = MarkdownBlockParser.parse(within)
        let expectedOversized = MarkdownBlockParser.parse(oversized)
        for _ in 0..<2 { #expect(cache.blocks(for: within) == expectedWithin) }
        for _ in 0..<2 { #expect(cache.blocks(for: oversized) == expectedOversized) }
        #expect(cache.blocks(for: within) == expectedWithin)
        #expect(parsed.count == 4)
        #expect(parsed.filter { $0.utf8.elementsEqual(oversized.utf8) }.count == 2)
    }

    @Test("Canonical Unicode equality never substitutes different source bytes")
    func exactBytesRemainAuthoritative() throws {
        let composed = "```\ncafé\n```"
        let decomposed = "```\ncafe\u{301}\n```"
        #expect(composed == decomposed)
        #expect(!composed.utf8.elementsEqual(decomposed.utf8))
        var parses = 0
        let cache = MarkdownBlockParseCache { input in
            parses += 1
            return MarkdownBlockParser.parse(input)
        }
        _ = cache.blocks(for: composed)
        let result = cache.blocks(for: decomposed)
        let expected = MarkdownBlockParser.parse(decomposed)
        #expect(result == expected)
        guard case .codeBlock(_, let code) = try #require(result.first),
              case .codeBlock(_, let expectedCode) = try #require(expected.first) else {
            Issue.record("Real parser did not produce the fenced code block")
            return
        }
        #expect(code.utf8.elementsEqual(expectedCode.utf8))
        #expect(parses == 2)
    }

    @Test("Empty results are reusable and explicit clear releases the old parse")
    func emptyAndClear() {
        var parses = 0
        let cache = MarkdownBlockParseCache { input in
            parses += 1
            return MarkdownBlockParser.parse(input)
        }
        #expect(cache.blocks(for: "").isEmpty)
        #expect(cache.blocks(for: "").isEmpty)
        #expect(parses == 1)
        cache.clear()
        #expect(cache.blocks(for: "").isEmpty)
        #expect(parses == 2)
    }
}
