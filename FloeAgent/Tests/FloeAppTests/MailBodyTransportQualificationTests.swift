// FloeAppTests — mail-body pages through the REAL tool output types.
//
// This is the App-hosted qualification entry for the two production summary
// bounds that the module-level paging tests cannot prove: every page is built
// by `MailBodyPaging`, wrapped in the actual `ToolExecutionOutput`
// (`AgentTool.swift`, 4096-character default), then in the actual `ToolResult`
// (`ToolCall.swift`, 4096-character default), and finally encoded/decoded as
// the persisted `ToolResult`. No `String.prefix(4096)` copy is used here: if
// either real type changed the page, the preserved JSON/cursor assertions and
// the final byte-exact reassembly would fail.
//
// Offline only: no MailSettings, Keychain, credential, account, network or
// mailbox access. The run is an ordinary FloeAppTests case and needs no UI.

import Foundation
import Testing
import CryptoKit
import FloeExecution
import FloeModels
import FloeTools

@Suite("FloeApp.MailBodyTransportQualification")
struct MailBodyTransportQualificationTests {
    private let binding = MailBodyPaging.Binding(
        accountID: UUID(),
        folder: "INBOX",
        uid: "transport-42",
        snapshotSHA256: String(repeating: "a", count: 64)
    )

    private let budget = MailBodyPaging.defaultMaximumCharacters

    // MARK: - Real production transport

    /// Wrap one page in the exact production types, then persist and reload
    /// the `ToolResult` the runtime would hand to the model.
    private func transport(_ page: String) throws -> String {
        let output = ToolExecutionOutput(
            summary: page,
            fullOutputSHA256: sha256Hex(page)
        )
        #expect(
            output.summary == page,
            "ToolExecutionOutput's production summary bound altered the page"
        )

        let result = ToolResult(
            callID: "call-mail-body",
            status: .ok,
            outputSummary: output.summary,
            outputDigest: output.fullOutputSHA256,
            exitStatus: output.exitStatus,
            artifacts: output.artifacts
        )
        #expect(
            result.outputSummary == page,
            "ToolResult's production summary bound altered the page"
        )

        let encoded = try JSONEncoder().encode(result)
        let decoded = try JSONDecoder().decode(ToolResult.self, from: encoded)
        #expect(decoded == result, "ToolResult did not survive its own Codable round-trip")
        #expect(decoded.outputSummary == page, "the persisted ToolResult lost the page")
        #expect(decoded.status == .ok)
        #expect(decoded.outputDigest == output.fullOutputSHA256)
        return decoded.outputSummary
    }

    private func parsed(_ page: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(page.utf8))
        return try #require(object as? [String: Any])
    }

    /// Transport bound plus the scalar-unit contract that both page kinds
    /// carry. Returns the page object after the real-type round-trip.
    @discardableResult
    private func transportedPage(_ page: String) throws -> [String: Any] {
        let transported = try transport(page)
        #expect(transported.utf8.count <= budget)
        #expect(transported.count <= 4_096)
        let object = try parsed(transported)
        #expect(object["offsetUnit"] as? String == "unicodeScalar")
        #expect(object["formatVersion"] as? Int == MailBodyPaging.formatVersion)
        #expect(object["sha256"] as? String == binding.snapshotSHA256)
        return object
    }

    private func digest(_ value: String) -> String { sha256Hex(value) }

    private func sha256Hex(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Fixtures

    private func normalText(paragraphs: Int = 180) -> String {
        (0..<paragraphs).map { index in
            "第\(index)段：引号\"反斜杠\\制表\t与控制字符，emoji 👨‍👩‍👧‍👦，CJK 汉字。"
        }.joined(separator: "\n")
    }

    private func normalHTML(paragraphs: Int = 140) -> String {
        (0..<paragraphs).map { index in
            "<p data-index=\"\(index)\">第\(index)段 &amp; <strong>粗体</strong> 👩🏽‍🚀 \"quoted\" \\ slash</p>"
        }.joined(separator: "\n")
    }

    private struct Reassembly {
        var text: String
        var html: String
        var pages: Int
        var textPages: Int
        var htmlPages: Int
    }

    /// Follow both continuation streams through the real output types and
    /// assert exact progress, JSON validity and byte-identical reassembly.
    private func reassemble(
        text: String,
        html: String,
        firstPageJSON: String
    ) throws -> Reassembly {
        let first = try transportedPage(firstPageJSON)
        #expect(first["contentTrust"] as? String == "untrustedEmail")
        #expect(first["subject"] as? String != nil)
        #expect(first["from"] as? String != nil)
        #expect(first["date"] as? String != nil)
        #expect(first["textTotal"] as? Int == text.unicodeScalars.count)
        #expect(first["htmlTotal"] as? Int == html.unicodeScalars.count)
        #expect(first["attachments"] as? [[String: Any]] != nil)

        var outText = try #require(first["text"] as? String)
        var outHtml = try #require(first["html"] as? String)
        var textCursor = try #require(first["nextTextCursor"] as? String)
        var htmlCursor = try #require(first["nextHtmlCursor"] as? String)
        #expect((first["hasMoreText"] as? Bool) == !textCursor.isEmpty)
        #expect((first["hasMoreHtml"] as? Bool) == !htmlCursor.isEmpty)
        #expect((first["truncated"] as? Bool) == (!textCursor.isEmpty || !htmlCursor.isEmpty))

        var textOffset = outText.unicodeScalars.count
        var htmlOffset = outHtml.unicodeScalars.count
        var textPages = (first["textChars"] as? Int ?? 0) > 0 ? 1 : 0
        var htmlPages = (first["htmlChars"] as? Int ?? 0) > 0 ? 1 : 0
        var pages = 1
        var guardCount = 0

        while !textCursor.isEmpty {
            guardCount += 1
            #expect(guardCount < 5_000, "text pagination did not terminate")
            let pageJSON = try MailBodyPaging.continuationPageJSON(
                cursorToken: textCursor,
                binding: binding,
                text: text,
                html: html,
                maximumCharacters: budget
            )
            let page = try transportedPage(pageJSON)
            #expect(page["format"] as? String == "text")
            let offsetStart = try #require(page["offsetStart"] as? Int)
            let units = try #require(page["chars"] as? Int)
            #expect(offsetStart == textOffset, "text page did not start where the previous one ended")
            #expect(units > 0, "text pagination made no progress")
            #expect(offsetStart + units <= text.unicodeScalars.count)
            #expect(page["total"] as? Int == text.unicodeScalars.count)
            outText += try #require(page["text"] as? String)
            textOffset += units
            let hasMore = try #require(page["hasMore"] as? Bool)
            textCursor = try #require(page["nextCursor"] as? String)
            #expect(hasMore == !textCursor.isEmpty)
            pages += 1
            textPages += 1
        }

        while !htmlCursor.isEmpty {
            guardCount += 1
            #expect(guardCount < 5_000, "HTML pagination did not terminate")
            let pageJSON = try MailBodyPaging.continuationPageJSON(
                cursorToken: htmlCursor,
                binding: binding,
                text: text,
                html: html,
                maximumCharacters: budget
            )
            let page = try transportedPage(pageJSON)
            #expect(page["format"] as? String == "html")
            let offsetStart = try #require(page["offsetStart"] as? Int)
            let units = try #require(page["chars"] as? Int)
            #expect(offsetStart == htmlOffset, "HTML page did not start where the previous one ended")
            #expect(units > 0, "HTML pagination made no progress")
            #expect(offsetStart + units <= html.unicodeScalars.count)
            #expect(page["total"] as? Int == html.unicodeScalars.count)
            outHtml += try #require(page["html"] as? String)
            htmlOffset += units
            let hasMore = try #require(page["hasMore"] as? Bool)
            htmlCursor = try #require(page["nextCursor"] as? String)
            #expect(hasMore == !htmlCursor.isEmpty)
            pages += 1
            htmlPages += 1
        }

        #expect(textOffset == text.unicodeScalars.count, "text pages stopped early")
        #expect(htmlOffset == html.unicodeScalars.count, "HTML pages stopped early")
        return Reassembly(
            text: outText,
            html: outHtml,
            pages: pages,
            textPages: textPages,
            htmlPages: htmlPages
        )
    }

    // MARK: - Real-type acceptance

    @Test("Long text and HTML keep JSON and cursors through ToolExecutionOutput and ToolResult")
    func longBodiesThroughRealToolTypes() throws {
        let text = normalText()
        let html = normalHTML()
        let first = try MailBodyPaging.initialPageJSON(
            binding: binding,
            subject: "Long message",
            from: "sender@example.test",
            to: "receiver@example.test",
            date: "Mon, 19 Oct 2026 10:00:00 +0000",
            text: text,
            html: html,
            attachments: [],
            maximumCharacters: budget
        )
        let result = try reassemble(text: text, html: html, firstPageJSON: first)
        #expect(result.pages > 2, "expected a genuinely paged body")
        #expect(result.text == text)
        #expect(result.html == html)
        #expect(digest(result.text) == digest(text))
        #expect(digest(result.html) == digest(html))
    }

    @Test("An oversized combining grapheme survives both real caps and ToolResult Codable")
    func oversizedGraphemeThroughRealToolTypes() throws {
        // One extended grapheme cluster (base + 5000 combining acute
        // accents) is a single `Character` but far beyond 4096 UTF-8 bytes.
        let text = "a" + String(repeating: "\u{0301}", count: 5_000) + "tail 👨‍👩‍👧‍👦 汉字"
        let html = "<p>" + "e" + String(repeating: "\u{0301}", count: 5_000) + "tail</p><p>👩🏽‍🚀</p>"
        #expect(String(text.prefix(1)).utf8.count > 4_096)
        #expect(text.count < 20)
        #expect(text.unicodeScalars.count > 5_000)

        let first = try MailBodyPaging.initialPageJSON(
            binding: binding,
            subject: "Oversized grapheme",
            from: "sender@example.test",
            to: "receiver@example.test",
            date: "Mon, 19 Oct 2026 10:00:00 +0000",
            text: text,
            html: html,
            attachments: [],
            maximumCharacters: budget
        )
        let firstPage = try transportedPage(first)
        #expect(firstPage["textTotal"] as? Int == text.unicodeScalars.count)
        #expect(firstPage["htmlTotal"] as? Int == html.unicodeScalars.count)
        #expect(firstPage["textTotal"] as? Int != text.count)

        let result = try reassemble(text: text, html: html, firstPageJSON: first)
        #expect(result.textPages > 1, "the oversized grapheme must span text pages")
        #expect(result.htmlPages > 1, "the oversized grapheme must span HTML pages")
        #expect(result.text == text)
        #expect(result.html == html)
        #expect(digest(result.text) == digest(text), "no combining mark may be dropped or replaced")
        #expect(digest(result.html) == digest(html))
    }

    @Test("Oversized-grapheme metadata is bounded and a short body survives the real types")
    func oversizedMetadataThroughRealToolTypes() throws {
        let giant = "m" + String(repeating: "\u{0301}", count: 5_000)
        #expect(String(giant.prefix(1)).utf8.count > 4_096)
        let attachments = [
            MailBodyPaging.Attachment(
                index: 0,
                filename: giant + ".pdf",
                byteCount: 1,
                sha256: String(repeating: "e", count: 64)
            )
        ]
        let text = "short body"
        let html = "<p>short body</p>"
        let first = try MailBodyPaging.initialPageJSON(
            binding: binding,
            subject: giant,
            from: giant,
            to: giant,
            date: giant,
            text: text,
            html: html,
            attachments: attachments,
            maximumCharacters: budget
        )
        let page = try transportedPage(first)
        #expect(page["subjectTruncated"] as? Bool == true)
        #expect(page["fromTruncated"] as? Bool == true)
        #expect(page["toTruncated"] as? Bool == true)
        #expect(page["dateTruncated"] as? Bool == true)
        #expect(page["attachmentNamesTruncated"] as? Bool == true)
        #expect(page["text"] as? String == text)
        #expect(page["html"] as? String == html)
        #expect(page["nextTextCursor"] as? String == "")
        #expect(page["nextHtmlCursor"] as? String == "")
        #expect(page["truncated"] as? Bool == false)

        let subject = try #require(page["subject"] as? String)
        let from = try #require(page["from"] as? String)
        let to = try #require(page["to"] as? String)
        let date = try #require(page["date"] as? String)
        #expect(!subject.isEmpty && subject.utf8.count <= 300)
        #expect(!from.isEmpty && from.utf8.count <= 200)
        #expect(!to.isEmpty && to.utf8.count <= 200)
        #expect(!date.isEmpty && date.utf8.count <= 64)
        for field in [subject, from, to, date] {
            #expect(!field.contains("\u{FFFD}"))
        }
        let rows = try #require(page["attachments"] as? [[String: Any]])
        #expect(rows.count == 1)
        let filename = try #require(rows[0]["filename"] as? String)
        #expect(!filename.isEmpty && filename.utf8.count <= 120)
        #expect(!filename.contains("\u{FFFD}"))
    }

    @Test("Every page keeps its cursor and terminal end fields after a ToolResult round-trip")
    func cursorAndEndFieldsSurviveRealTypes() throws {
        let text = normalText(paragraphs: 40)
        let first = try MailBodyPaging.initialPageJSON(
            binding: binding,
            subject: "Cursor retention",
            from: "sender@example.test",
            to: "receiver@example.test",
            date: "Mon, 19 Oct 2026 10:00:00 +0000",
            text: text,
            html: "",
            attachments: [],
            maximumCharacters: budget
        )
        var page = try transportedPage(first)
        var cursor = try #require(page["nextTextCursor"] as? String)
        #expect(!cursor.isEmpty)
        var continuationCount = 0
        while !cursor.isEmpty {
            continuationCount += 1
            #expect(continuationCount < 5_000)
            let pageJSON = try MailBodyPaging.continuationPageJSON(
                cursorToken: cursor,
                binding: binding,
                text: text,
                html: "",
                maximumCharacters: budget
            )
            page = try transportedPage(pageJSON)
            #expect(page["format"] as? String == "text")
            #expect(page["offsetUnit"] as? String == "unicodeScalar")
            #expect(page["formatVersion"] as? Int == 2)
            cursor = try #require(page["nextCursor"] as? String)
        }
        #expect(page["hasMore"] as? Bool == false)
        #expect(page["nextCursor"] as? String == "")
        #expect(
            (page["offsetStart"] as? Int ?? -1) + (page["chars"] as? Int ?? 0)
                == text.unicodeScalars.count
        )
    }
}
