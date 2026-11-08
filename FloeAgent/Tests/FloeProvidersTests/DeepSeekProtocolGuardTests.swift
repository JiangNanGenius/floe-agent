// SPDX-License-Identifier: MPL-2.0
import Foundation
import Testing
@testable import FloeProviders

@Suite("DeepSeek assistant protocol isolation")
struct DeepSeekProtocolGuardTests {
    private let raw = "<｜DSML｜calls><｜DSML｜invoke name=\"document_office_edit\"><｜DSML｜parameter name=\"action\" string=\"true\">read</｜DSML｜parameter></｜DSML｜invoke></｜DSML｜calls>"

    @Test func everySplitHoldsMachinePrefixesAndRejectsExactlyOnce() {
        for marker in [raw, raw.replacingOccurrences(of: "｜", with: "|")] {
            let characters = Array("先读取文件。\n\n" + marker + "\n后续文字")
            for split in 0...characters.count {
                var guarder = DeepSeekAssistantProtocolGuard(enabled: true)
                let pieces = [String(characters[..<split]), String(characters[split...])]
                let output = pieces.map { guarder.consume($0) } + [guarder.finish(), guarder.consume(marker)]
                #expect(output.map(\.text).joined() == "先读取文件。\n\n")
                #expect(output.filter(\.rejected).count == 1)
            }
        }
    }

    @Test func characterAtATimeAndIncompleteEOFNeverPublishMachineIdentifiers() {
        for text in [raw, "<｜DSML", "</|DSML"] {
            var guarder = DeepSeekAssistantProtocolGuard(enabled: true)
            var emitted = "", errors = 0
            for character in text {
                let value = guarder.consume(String(character)); emitted += value.text
                if value.rejected { errors += 1 }
            }
            let tail = guarder.finish(); emitted += tail.text
            if tail.rejected { errors += 1 }
            #expect(emitted.isEmpty && errors == 1)
        }
        var ordinary = DeepSeekAssistantProtocolGuard(enabled: true)
        #expect(ordinary.consume("x < y <").text + ordinary.finish().text == "x < y <")
    }

    @Test func fencedInlineQuotedAndOrdinaryXMLRemainLiteralText() {
        let examples = [
            "源码示例：`" + raw + "`。这里不执行。",
            "```xml\n" + raw + "\n```\n普通说明。",
            "~~~xml\n" + raw + "\n~~~\n普通说明。",
            "> " + raw + "\n这是一条引用。",
            "    " + raw + "\n缩进源码。",
            "普通XML：<invoke name=\"sample\"><parameter>text</parameter></invoke>"
        ]
        for text in examples {
            var guarder = DeepSeekAssistantProtocolGuard(enabled: true)
            let output = text.map { guarder.consume(String($0)) } + [guarder.finish()]
            #expect(output.map(\.text).joined() == text)
            #expect(!output.contains { $0.rejected })
        }
    }

    @Test func aRealControlBlockAfterAFencedExampleStillRejects() {
        let quote = "```xml\n" + raw + "\n```\n\n"
        var guarder = DeepSeekAssistantProtocolGuard(enabled: true)
        let output = (quote + raw).map { guarder.consume(String($0)) } + [guarder.finish()]
        #expect(output.map(\.text).joined() == quote)
        #expect(output.filter(\.rejected).count == 1)
    }

    @Test func unknownFunctionsAndTagsNeverBecomeCommands() {
        for payload in [raw.replacingOccurrences(of: "document_office_edit", with: "untrusted_host_exec"),
                        "<｜DSML｜unknown operation=\"anything\">", "</|DSML|invoke>"] {
            var guarder = DeepSeekAssistantProtocolGuard(enabled: true)
            let output = guarder.consume(payload)
            #expect(output.text.isEmpty && output.rejected)
        }
    }

    @Test func anotherProviderIsUnaffectedAndEachResponseOwnsItsState() {
        var other = DeepSeekAssistantProtocolGuard(enabled: false)
        #expect(other.consume(raw).text == raw && !other.isRejected)
        var first = DeepSeekAssistantProtocolGuard(enabled: true)
        #expect(first.consume(raw).rejected)
        var next = DeepSeekAssistantProtocolGuard(enabled: true)
        #expect(next.consume("正常回复").text == "正常回复" && !next.isRejected)
    }
}
