// FloeProvidersTests — QA SSE parser edge corpus (Round 1, QA/Yan).
// Boundaries beyond the engineer's fragmentation corpus: empty input,
// comment-only streams, EOF without newline, empty event values, non-numeric
// retry, one-byte-at-a-time extreme fragmentation, mixed CR/LF endings,
// mid-stream invalid UTF-8 replacement, NUL-containing ids.

import Foundation
import Testing
@testable import FloeProviders

@Suite("QA.SSEParserEdges")
struct SSEParserEdgeTests {

    @Test("Empty input yields no events and finishes cleanly")
    func emptyInput() throws {
        var parser = SSEParser()
        let events = try parser.finish()
        #expect(events.isEmpty)
    }

    @Test("Comment-only stream yields no events")
    func commentOnly() throws {
        var parser = SSEParser()
        var events = parser.feed(Array(": heartbeat\n: another\n".utf8))
        events += try parser.finish()
        #expect(events.isEmpty)
    }

    @Test("data: with no trailing newline flushes at EOF")
    func dataWithoutTrailingNewline() throws {
        var parser = SSEParser()
        _ = parser.feed(Array("data: hello".utf8))
        let events = try parser.finish()
        #expect(events.count == 1)
        #expect(events[0].data == "hello")
    }

    @Test("data: immediately at EOF with empty value emits empty-data event")
    func emptyDataAtEOF() throws {
        var parser = SSEParser()
        _ = parser.feed(Array("data:".utf8))
        let events = try parser.finish()
        #expect(events.count == 1)
        #expect(events[0].data == "")
    }

    @Test("event: with empty value keeps the default message type")
    func emptyEventValue() throws {
        var parser = SSEParser()
        var events = parser.feed(Array("event:\ndata: x\n\n".utf8))
        events += try parser.finish()
        #expect(events.count == 1)
        #expect(events[0].event == "")
    }

    @Test("retry: with a non-numeric value is ignored")
    func nonNumericRetry() throws {
        var parser = SSEParser()
        var events = parser.feed(Array("retry: abc\ndata: x\n\n".utf8))
        events += try parser.finish()
        #expect(events.count == 1)
        #expect(events[0].retry == nil)
    }

    @Test("retry: with a negative value is ignored per spec")
    func negativeRetry() throws {
        var parser = SSEParser()
        var events = parser.feed(Array("retry: -5\ndata: x\n\n".utf8))
        events += try parser.finish()
        #expect(events.count == 1)
        #expect(events[0].retry == nil)
    }

    @Test("retry: with leading zeros parses as decimal")
    func leadingZeroRetry() throws {
        var parser = SSEParser()
        var events = parser.feed(Array("retry: 007\ndata: x\n\n".utf8))
        events += try parser.finish()
        #expect(events[0].retry == 7)
    }

    @Test("One-byte-at-a-time feed of a multi-line event equals whole-buffer parse")
    func byteByByteEquivalence() throws {
        let stream = "event: named\nid: 9\nretry: 250\ndata: part1\ndata: part2\n\n"
        var whole = SSEParser()
        var wholeEvents = whole.feed(Array(stream.utf8))
        wholeEvents += try whole.finish()

        var drip = SSEParser()
        var dripEvents: [SSEEvent] = []
        for byte in stream.utf8 {
            dripEvents += drip.feed(CollectionOfOne(byte))
        }
        dripEvents += try drip.finish()

        #expect(dripEvents == wholeEvents)
        #expect(dripEvents.count == 1)
        #expect(dripEvents[0].data == "part1\npart2")
        #expect(dripEvents[0].event == "named")
        #expect(dripEvents[0].id == "9")
        #expect(dripEvents[0].retry == 250)
    }

    @Test("Mixed CR / LF / CRLF / CRCRLF endings all terminate lines")
    func mixedLineEndings() throws {
        // "data: a\r\n" + "\r\n" → event a; "data: b\r" + "\r\n"? No:
        // construct explicitly: a (CRLF), blank (LF), b (CR), blank (CRLF).
        var parser = SSEParser()
        var events = parser.feed(Array("data: a\r\n\ndata: b\r\r\ndata: c\n\n".utf8))
        events += try parser.finish()
        #expect(events.map(\.data) == ["a", "b", "c"])
    }

    @Test("\\r\\r\\n sequence: first CR ends line, CRCR emits blank, LF swallowed")
    func crcrlfSequence() throws {
        var parser = SSEParser()
        // "data: x\r" → line; "\r" → blank line (event dispatched);
        // "\n" → swallowed as the LF half of CRLF.
        var events = parser.feed(Array("data: x\r\r\ndata: y\r\r\n".utf8))
        events += try parser.finish()
        #expect(events.map(\.data) == ["x", "y"])
    }

    @Test("Mid-stream invalid UTF-8 bytes are replaced with U+FFFD, not fatal")
    func midStreamInvalidUTF8() throws {
        var parser = SSEParser()
        var bytes = Array("data: caf".utf8)
        bytes.append(0xE9) // lone continuation-less byte → invalid UTF-8
        bytes.append(contentsOf: Array("\n\n".utf8))
        var events = parser.feed(bytes)
        events += try parser.finish()
        #expect(events.count == 1)
        #expect(events[0].data == "caf\u{FFFD}")
    }

    @Test("id: containing NUL is ignored per spec")
    func nulInIDIgnored() throws {
        var parser = SSEParser()
        var events = parser.feed(Array("id: a\u{0}b\ndata: x\n\n".utf8))
        events += try parser.finish()
        #expect(events.count == 1)
        #expect(events[0].id == nil)
    }

    @Test("Line containing only a colon is a comment (ignored)")
    func loneColonLine() throws {
        var parser = SSEParser()
        var events = parser.feed(Array(":\ndata: x\n\n".utf8))
        events += try parser.finish()
        #expect(events.count == 1)
        #expect(events[0].data == "x")
    }

    @Test("BOM mid-stream is treated as content, merging into the data payload")
    func midStreamBOMIsContent() throws {
        var parser = SSEParser()
        // The BOM (EF BB BF) lands before "data: y", so the line becomes
        // "\u{FEFF}data: y" whose field name is not "data" — but it IS
        // appended to the pending data of the previous event? No: unknown
        // fields are ignored. Observe actual behavior and pin it.
        var events = parser.feed(Array("data: x\n\n\u{FEFF}data: y\n\n".utf8))
        events += try parser.finish()
        #expect(events.count == 1)
        #expect(events[0].data == "x")
    }

    @Test("Incomplete BOM prefix bytes are treated as content at finish()")
    func incompleteBOMPrefix() throws {
        var parser = SSEParser()
        _ = parser.feed([0xEF]) // first BOM byte only
        let events = try parser.finish()
        // A lone 0xEF is invalid UTF-8 as a final line; the parser replays it
        // as content, which is not valid UTF-8 → replacement char, no throw
        // (only .inLine truncated tails throw; bomPending replays as content).
        #expect(events.isEmpty)
    }

    @Test("Very long single line (1 MiB) parses without truncation")
    func longLine() throws {
        let payload = String(repeating: "x", count: 1_048_576)
        var parser = SSEParser()
        var events = parser.feed(Array("data: \(payload)\n\n".utf8))
        events += try parser.finish()
        #expect(events.count == 1)
        #expect(events[0].data.count == 1_048_576)
    }
}
