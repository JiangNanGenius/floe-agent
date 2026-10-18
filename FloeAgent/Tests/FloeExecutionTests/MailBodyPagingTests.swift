// FloeExecutionTests — bounded mail-body paging: every page is valid JSON
// that survives the two production 4096-character summary cuts, and the
// concatenation of all pages reproduces the original body exactly.
//
// No mail account is touched: bodies are plain strings here and the cursors
// are the production `MailBodyPaging` tokens. The App-hosted
// `MailBodyTransportQualificationTests` is the real
// `ToolExecutionOutput`/`ToolResult` proof; this file stays module-level.

import Foundation
import Testing
import CryptoKit
@testable import FloeExecution

@Suite("Mail body paging")
struct MailBodyPagingTests {
    private let binding = MailBodyPaging.Binding(
        accountID: UUID(),
        folder: "INBOX",
        uid: "42",
        snapshotSHA256: String(repeating: "a", count: 64)
    )

    // MARK: - Fixtures and helpers

    private func digest(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func parsed(_ page: String) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(page.utf8))
        return try #require(object as? [String: Any])
    }

    /// Module-level bound check. The real `ToolExecutionOutput` and
    /// `ToolResult` instances are exercised by the App-hosted
    /// `MailBodyTransportQualificationTests`; here we assert the equivalent
    /// invariants directly (UTF-8 budget plus a character count below both
    /// 4096 caps), without copying either production truncation expression.
    private func assertTransportSafe(_ page: String, budget: Int) throws {
        #expect(page.utf8.count <= budget)
        #expect(page.utf8.count <= 4_096)
        #expect(page.count <= 4_096, "a production 4096-character cut would alter the page")
        let object = try parsed(page)
        #expect(object["offsetUnit"] as? String == "unicodeScalar")
        #expect(object["formatVersion"] as? Int == MailBodyPaging.formatVersion)
    }

    private func longText(paragraphs: Int = 420) -> String {
        (0..<paragraphs).map { index in
            "第\(index)段：正文含引号\"反斜杠\\制表\t与控制字符，emoji 👨‍👩‍👧‍👦 以及 CJK 汉字。"
        }.joined(separator: "\n")
    }

    private func longHTML(paragraphs: Int = 300) -> String {
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

    /// Follows both continuation streams to their stated end, asserting the
    /// transport guarantees on every page and returning the concatenation.
    private func reassemble(
        text: String,
        html: String,
        firstPage: String,
        budget: Int
    ) throws -> Reassembly {
        let first = try parsed(firstPage)
        var outText = try #require(first["text"] as? String)
        var outHtml = try #require(first["html"] as? String)
        var textCursor = try #require(first["nextTextCursor"] as? String)
        var htmlCursor = try #require(first["nextHtmlCursor"] as? String)
        #expect((first["hasMoreText"] as? Bool) == !textCursor.isEmpty)
        #expect((first["hasMoreHtml"] as? Bool) == !htmlCursor.isEmpty)
        #expect(first["textTotal"] as? Int == text.unicodeScalars.count)
        #expect(first["htmlTotal"] as? Int == html.unicodeScalars.count)
        var textOffset = outText.unicodeScalars.count
        var htmlOffset = outHtml.unicodeScalars.count
        var pages = 1
        var textPages = (first["textChars"] as? Int ?? 0) > 0 ? 1 : 0
        var htmlPages = (first["htmlChars"] as? Int ?? 0) > 0 ? 1 : 0
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
            try assertTransportSafe(pageJSON, budget: budget)
            let page = try parsed(pageJSON)
            #expect(page["format"] as? String == "text")
            let offsetStart = try #require(page["offsetStart"] as? Int)
            let units = try #require(page["chars"] as? Int)
            #expect(offsetStart == textOffset, "text page did not start where the previous one ended")
            #expect(units > 0, "text pagination made no progress")
            #expect(offsetStart + units <= text.unicodeScalars.count)
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
            #expect(guardCount < 5_000, "html pagination did not terminate")
            let pageJSON = try MailBodyPaging.continuationPageJSON(
                cursorToken: htmlCursor,
                binding: binding,
                text: text,
                html: html,
                maximumCharacters: budget
            )
            try assertTransportSafe(pageJSON, budget: budget)
            let page = try parsed(pageJSON)
            #expect(page["format"] as? String == "html")
            let offsetStart = try #require(page["offsetStart"] as? Int)
            let units = try #require(page["chars"] as? Int)
            #expect(offsetStart == htmlOffset, "HTML page did not start where the previous one ended")
            #expect(units > 0, "HTML pagination made no progress")
            #expect(offsetStart + units <= html.unicodeScalars.count)
            outHtml += try #require(page["html"] as? String)
            htmlOffset += units
            let hasMore = try #require(page["hasMore"] as? Bool)
            htmlCursor = try #require(page["nextCursor"] as? String)
            #expect(hasMore == !htmlCursor.isEmpty)
            pages += 1
            htmlPages += 1
        }
        #expect(textOffset == text.unicodeScalars.count, "text pages stopped before the body ended")
        #expect(htmlOffset == html.unicodeScalars.count, "HTML pages stopped before the body ended")
        return Reassembly(text: outText, html: outHtml, pages: pages, textPages: textPages, htmlPages: htmlPages)
    }

    private func initialPage(
        text: String,
        html: String,
        subject: String = "Long message",
        from: String = "sender@example.test",
        to: String = "receiver@example.test",
        date: String = "Mon, 19 Oct 2026 10:00:00 +0000",
        attachments: [MailBodyPaging.Attachment] = [],
        budget: Int = MailBodyPaging.defaultMaximumCharacters
    ) throws -> String {
        try MailBodyPaging.initialPageJSON(
            binding: binding,
            subject: subject,
            from: from,
            to: to,
            date: date,
            text: text,
            html: html,
            attachments: attachments,
            maximumCharacters: budget
        )
    }

    // MARK: - Completeness

    @Test("Long text and HTML reassemble byte-identically through bounded pages")
    func longBodiesReassembleExactly() throws {
        let text = longText()
        let html = longHTML()
        let page = try initialPage(text: text, html: html)
        try assertTransportSafe(page, budget: MailBodyPaging.defaultMaximumCharacters)

        let result = try reassemble(
            text: text,
            html: html,
            firstPage: page,
            budget: MailBodyPaging.defaultMaximumCharacters
        )
        #expect(result.pages > 2, "expected a genuinely paged body, got \(result.pages) pages")
        #expect(digest(result.text) == digest(text), "text content changed while paging")
        #expect(digest(result.html) == digest(html), "HTML content changed while paging")
        #expect(result.text.count == text.count)
        #expect(result.html.count == html.count)
    }

    @Test("Escaped quotes, backslashes and multibyte graphemes never split or overflow")
    func escapedContentReassembles() throws {
        let unit = "\"\\\"\\\\ 🧑🏾‍💻 汉字 \t\n"
        let text = String(repeating: unit, count: 3_000)
        let html = String(repeating: "<b>\"\\</b>👨‍👩‍👧‍👦", count: 2_000)
        let page = try initialPage(text: text, html: html)
        let result = try reassemble(
            text: text,
            html: html,
            firstPage: page,
            budget: MailBodyPaging.defaultMaximumCharacters
        )
        #expect(digest(result.text) == digest(text))
        #expect(digest(result.html) == digest(html))
    }

    @Test("One legal grapheme larger than a page still pages to a byte-identical end")
    func oversizedGraphemePagesToCompletion() throws {
        // A single extended grapheme cluster: base letter + 5000 combining
        // acute accents. It is one `Character`, but >4096 UTF-8 bytes, so any
        // grapheme-count cursor either never advances or fails the read.
        let giantText = "a" + String(repeating: "\u{0301}", count: 5_000) + "tail 👨‍👩‍👧‍👦 汉字"
        let giantHTML = "<p>" + "e" + String(repeating: "\u{0301}", count: 5_000) + "tail</p><p>👩🏽‍🚀</p>"
        #expect(String(giantText.prefix(1)).utf8.count > 4_096)
        #expect(giantText.count < 20, "the body is only a handful of graphemes")
        #expect(giantText.unicodeScalars.count > 5_000)

        let firstJSON = try initialPage(text: giantText, html: giantHTML)
        let first = try parsed(firstJSON)
        #expect(first["textTotal"] as? Int == giantText.unicodeScalars.count)
        #expect(first["htmlTotal"] as? Int == giantHTML.unicodeScalars.count)
        #expect(first["textTotal"] as? Int != giantText.count)

        let result = try reassemble(
            text: giantText,
            html: giantHTML,
            firstPage: firstJSON,
            budget: MailBodyPaging.defaultMaximumCharacters
        )
        #expect(result.textPages > 1, "the oversized grapheme must span text pages")
        #expect(result.htmlPages > 1, "the oversized grapheme must span HTML pages")
        #expect(result.text == giantText)
        #expect(result.html == giantHTML)
        #expect(digest(result.text) == digest(giantText), "combining marks changed while paging")
        #expect(digest(result.html) == digest(giantHTML))
    }

    @Test("The oversized grapheme advances even at a tight page budget")
    func oversizedGraphemeTightBudget() throws {
        let budget = 1_200
        let giantText = "x" + String(repeating: "\u{0301}", count: 5_000) + "end"
        let giantHTML = "<b>" + "y" + String(repeating: "\u{0327}", count: 5_000) + "end</b>"
        let firstJSON = try initialPage(text: giantText, html: giantHTML, budget: budget)
        let result = try reassemble(
            text: giantText,
            html: giantHTML,
            firstPage: firstJSON,
            budget: budget
        )
        #expect(result.textPages > 1)
        #expect(result.htmlPages > 1)
        #expect(result.text == giantText)
        #expect(result.html == giantHTML)
        #expect(digest(result.text) == digest(giantText))
        #expect(digest(result.html) == digest(giantHTML))
    }

    @Test("A tight budget still terminates with complete, valid pages")
    func tightBudgetStillComplete() throws {
        let budget = 1_200
        let text = longText(paragraphs: 60)
        let html = longHTML(paragraphs: 40)
        let page = try initialPage(text: text, html: html, budget: budget)
        try assertTransportSafe(page, budget: budget)
        let result = try reassemble(text: text, html: html, firstPage: page, budget: budget)
        #expect(digest(result.text) == digest(text))
        #expect(digest(result.html) == digest(html))
    }

    // MARK: - Legacy first-page compatibility

    @Test("The first page keeps the legacy message fields and attachment metadata")
    func firstPageLegacyFields() throws {
        let attachments = (0..<3).map {
            MailBodyPaging.Attachment(
                index: $0,
                filename: "report-\($0).pdf",
                byteCount: 1_000 + $0,
                sha256: String(repeating: "b", count: 64)
            )
        }
        let page = try parsed(try initialPage(text: "short text", html: "<p>short</p>", attachments: attachments))
        #expect(page["contentTrust"] as? String == "untrustedEmail")
        #expect(page["sha256"] as? String == binding.snapshotSHA256)
        #expect(page["subject"] as? String == "Long message")
        #expect(page["text"] as? String == "short text")
        #expect(page["html"] as? String == "<p>short</p>")
        #expect(page["truncated"] as? Bool == false)
        #expect(page["nextTextCursor"] as? String == "")
        #expect(page["nextHtmlCursor"] as? String == "")
        let rows = try #require(page["attachments"] as? [[String: Any]])
        #expect(rows.count == 3)
        #expect(rows[1]["filename"] as? String == "report-1.pdf")
        #expect(rows[1]["sha256"] as? String == String(repeating: "b", count: 64))
        #expect(rows[1]["byteCount"] as? Int == 1_001)
    }

    @Test("Adversarial headers and attachments are budgeted, never overflow")
    func adversarialMetadataIsBudgeted() throws {
        let attachments = (0..<10).map {
            MailBodyPaging.Attachment(
                index: $0,
                filename: String(repeating: "n", count: 400) + "\($0).pdf",
                byteCount: 1_000,
                sha256: String(repeating: "c", count: 64)
            )
        }
        let page = try initialPage(
            text: longText(paragraphs: 20),
            html: longHTML(paragraphs: 20),
            subject: String(repeating: "s", count: 10_000),
            from: String(repeating: "f", count: 2_000),
            attachments: attachments
        )
        try assertTransportSafe(page, budget: MailBodyPaging.defaultMaximumCharacters)
        let parsed = try parsed(page)
        #expect((parsed["subject"] as? String)?.count == 300)
        #expect(parsed["subjectTruncated"] as? Bool == true)
        #expect((parsed["from"] as? String)?.count == 200)
        #expect(parsed["fromTruncated"] as? Bool == true)
        let rows = try #require(parsed["attachments"] as? [[String: Any]])
        #expect(rows.count <= 10)
        #expect(rows.allSatisfy { ($0["sha256"] as? String)?.count == 64 })
        if rows.count < attachments.count {
            #expect(parsed["attachmentsDeferred"] as? Int == attachments.count - rows.count)
        }
        #expect(parsed["attachmentNamesTruncated"] as? Bool == true)
    }

    @Test("Oversized-grapheme metadata is byte-bounded and never blocks a short body")
    func oversizedMetadataDoesNotBlockBody() throws {
        // One legal grapheme (base + 5000 combining marks) is a single
        // `Character` but thousands of UTF-8 bytes. A grapheme-count clip
        // would leave this metadata larger than the whole page even with all
        // attachments withheld.
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
        let json = try initialPage(
            text: text,
            html: html,
            subject: giant,
            from: giant,
            to: giant,
            date: giant,
            attachments: attachments
        )
        try assertTransportSafe(json, budget: MailBodyPaging.defaultMaximumCharacters)
        let page = try parsed(json)
        #expect(page["subjectTruncated"] as? Bool == true)
        #expect(page["fromTruncated"] as? Bool == true)
        #expect(page["toTruncated"] as? Bool == true)
        #expect(page["dateTruncated"] as? Bool == true)
        #expect(page["attachmentNamesTruncated"] as? Bool == true)
        #expect(page["text"] as? String == text)
        #expect(page["html"] as? String == html)
        #expect(page["nextTextCursor"] as? String == "")
        #expect(page["nextHtmlCursor"] as? String == "")
        #expect(page["hasMoreText"] as? Bool == false)
        #expect(page["truncated"] as? Bool == false, "metadata truncation is not body truncation")

        let subject = try #require(page["subject"] as? String)
        let from = try #require(page["from"] as? String)
        let to = try #require(page["to"] as? String)
        let date = try #require(page["date"] as? String)
        #expect(!subject.isEmpty && subject.utf8.count <= 300)
        #expect(!from.isEmpty && from.utf8.count <= 200)
        #expect(!to.isEmpty && to.utf8.count <= 200)
        #expect(!date.isEmpty && date.utf8.count <= 64)
        for field in [subject, from, to, date] {
            #expect(!field.contains("\u{FFFD}"), "metadata clipping inserted a replacement character")
        }
        let rows = try #require(page["attachments"] as? [[String: Any]])
        #expect(rows.count == 1)
        let filename = try #require(rows[0]["filename"] as? String)
        #expect(!filename.isEmpty && filename.utf8.count <= 120)
        #expect(!filename.contains("\u{FFFD}"))
    }

    // MARK: - Cursor integrity

    @Test("Cursors are bound to account, folder, UID and the exact content revision")
    func cursorBindingRejectsDrift() throws {
        let text = longText(paragraphs: 40)
        let page = try parsed(try initialPage(text: text, html: ""))
        let token = try #require(page["nextTextCursor"] as? String)
        #expect(!token.isEmpty)

        let otherAccount = MailBodyPaging.Binding(
            accountID: UUID(), folder: binding.folder, uid: binding.uid, snapshotSHA256: binding.snapshotSHA256)
        let otherFolder = MailBodyPaging.Binding(
            accountID: binding.accountID, folder: "Sent", uid: binding.uid, snapshotSHA256: binding.snapshotSHA256)
        let otherUID = MailBodyPaging.Binding(
            accountID: binding.accountID, folder: binding.folder, uid: "43", snapshotSHA256: binding.snapshotSHA256)
        let otherContent = MailBodyPaging.Binding(
            accountID: binding.accountID, folder: binding.folder, uid: binding.uid,
            snapshotSHA256: String(repeating: "d", count: 64))

        for mismatched in [otherAccount, otherFolder, otherUID, otherContent] {
            #expect(throws: MailFailure.cursorMismatch) {
                try MailBodyPaging.continuationPageJSON(
                    cursorToken: token, binding: mismatched, text: text, html: "")
            }
        }
        // The correct binding still works.
        let continued = try MailBodyPaging.continuationPageJSON(
            cursorToken: token, binding: binding, text: text, html: "")
        try assertTransportSafe(continued, budget: MailBodyPaging.defaultMaximumCharacters)
    }

    @Test("Cursors declare Unicode scalar offsets under format version 2")
    func cursorDeclaresScalarUnit() throws {
        let text = longText(paragraphs: 120)
        let page = try parsed(try initialPage(text: text, html: ""))
        #expect(page["textTotal"] as? Int == text.unicodeScalars.count)
        #expect(page["textTotal"] as? Int != text.count, "a grapheme count would lose scalars")
        #expect(page["offsetUnit"] as? String == "unicodeScalar")
        #expect(page["formatVersion"] as? Int == 2)

        let token = try #require(page["nextTextCursor"] as? String)
        #expect(!token.isEmpty)
        let cursor = try MailBodyPaging.decodeCursor(token)
        #expect(cursor.v == MailBodyPaging.formatVersion)
        #expect(cursor.offsetUnit == .unicodeScalar)
        #expect(cursor.offset == page["textChars"] as? Int)
    }

    @Test("Malformed, legacy, wrong-unit, foreign, stale and out-of-range cursors are rejected")
    func invalidCursorsAreRejected() throws {
        let text = longText(paragraphs: 120)
        let page = try parsed(try initialPage(text: text, html: ""))
        let token = try #require(page["nextTextCursor"] as? String)
        #expect(!token.isEmpty)

        #expect(throws: MailFailure.invalidConfiguration) {
            try MailBodyPaging.continuationPageJSON(cursorToken: "garbage", binding: binding, text: text, html: "")
        }
        #expect(throws: MailFailure.invalidConfiguration) {
            // A search cursor is not a body cursor.
            try MailBodyPaging.continuationPageJSON(cursorToken: "msc1.AAAA", binding: binding, text: text, html: "")
        }
        #expect(throws: MailFailure.invalidConfiguration) {
            // The old grapheme-offset token must never be read as scalars.
            try MailBodyPaging.continuationPageJSON(cursorToken: "mbp1.!!!", binding: binding, text: text, html: "")
        }

        func cursorToken(version: Int = MailBodyPaging.formatVersion, offset: Int) -> String {
            let cursor = MailBodyPaging.Cursor(
                v: version,
                offsetUnit: .unicodeScalar,
                accountID: binding.accountID,
                folderSHA256: MailBodyPaging.folderFingerprint(binding.folder),
                uid: binding.uid,
                snapshotSHA256: binding.snapshotSHA256,
                format: .text,
                offset: offset
            )
            return MailBodyPaging.encodeCursor(cursor)
        }
        #expect(throws: MailFailure.invalidConfiguration) {
            try MailBodyPaging.continuationPageJSON(
                cursorToken: cursorToken(version: MailBodyPaging.formatVersion + 1, offset: 0),
                binding: binding, text: text, html: "")
        }
        #expect(throws: MailFailure.invalidConfiguration) {
            try MailBodyPaging.continuationPageJSON(cursorToken: cursorToken(offset: -1), binding: binding, text: text, html: "")
        }

        // A syntactically valid mbp2 token (short Cursor keys) whose declared
        // unit is not unicodeScalar must not be silently reinterpreted.
        let wrongUnitJSON = """
        {"v":2,"u":"grapheme","a":"\(binding.accountID.uuidString)",\
        "f":"\(MailBodyPaging.folderFingerprint(binding.folder))",\
        "i":"\(binding.uid)","s":"\(binding.snapshotSHA256)",\
        "t":"text","o":0}
        """
        let wrongUnitToken = "mbp2." + Data(wrongUnitJSON.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        #expect(throws: MailFailure.invalidConfiguration) {
            try MailBodyPaging.continuationPageJSON(
                cursorToken: wrongUnitToken, binding: binding, text: text, html: "")
        }

        #expect(throws: MailFailure.cursorMismatch) {
            // A valid shape but past the end of the stream (e.g. a cursor
            // from a different revision of the same length is not reusable).
            try MailBodyPaging.continuationPageJSON(
                cursorToken: cursorToken(offset: text.unicodeScalars.count),
                binding: binding, text: text, html: "")
        }
        // A text cursor is fine, but an HTML stream cursor cannot be used
        // when the HTML body is empty (nothing to continue).
        #expect(throws: MailFailure.cursorMismatch) {
            let htmlCursor = MailBodyPaging.encodeCursor(MailBodyPaging.Cursor(
                v: MailBodyPaging.formatVersion,
                offsetUnit: .unicodeScalar,
                accountID: binding.accountID,
                folderSHA256: MailBodyPaging.folderFingerprint(binding.folder),
                uid: binding.uid,
                snapshotSHA256: binding.snapshotSHA256,
                format: .html,
                offset: 0
            ))
            _ = try MailBodyPaging.continuationPageJSON(cursorToken: htmlCursor, binding: binding, text: text, html: "")
        }
        // The real cursor is untouched by the rejections above.
        _ = try MailBodyPaging.continuationPageJSON(cursorToken: token, binding: binding, text: text, html: "")
    }

    // MARK: - End states

    @Test("Empty, single-character and exact-boundary bodies terminate cleanly")
    func emptyAndBoundaryBodies() throws {
        let empty = try parsed(try initialPage(text: "", html: ""))
        #expect(empty["truncated"] as? Bool == false)
        #expect(empty["textChars"] as? Int == 0)
        #expect(empty["nextTextCursor"] as? String == "")
        #expect(empty["text"] as? String == "")

        let single = try parsed(try initialPage(text: "x", html: "<i>x</i>"))
        #expect(single["text"] as? String == "x")
        #expect(single["nextTextCursor"] as? String == "")
        #expect(single["truncated"] as? Bool == false)

        // Boundary: a body that ends exactly on a page boundary still
        // terminates with an empty cursor, never an empty continuation page.
        let boundary = String(repeating: "a", count: 3_900)
        let first = try initialPage(text: boundary, html: "")
        let result = try reassemble(
            text: boundary,
            html: "",
            firstPage: first,
            budget: MailBodyPaging.defaultMaximumCharacters
        )
        #expect(result.text == boundary)
        #expect(digest(result.text) == digest(boundary))
    }

    @Test("The final page states completion with hasMore=false and an empty cursor")
    func finalPageStatesCompletion() throws {
        let text = longText(paragraphs: 30)
        var page = try parsed(try initialPage(text: text, html: ""))
        var cursor = try #require(page["nextTextCursor"] as? String)
        var collected = try #require(page["text"] as? String)
        var lastPage: [String: Any] = page
        while !cursor.isEmpty {
            let pageJSON = try MailBodyPaging.continuationPageJSON(
                cursorToken: cursor, binding: binding, text: text, html: "")
            page = try parsed(pageJSON)
            collected += try #require(page["text"] as? String)
            cursor = try #require(page["nextCursor"] as? String)
            lastPage = page
        }
        #expect(lastPage["hasMore"] as? Bool == false)
        #expect(lastPage["nextCursor"] as? String == "")
        #expect(
            (lastPage["offsetStart"] as? Int ?? 0) + (lastPage["chars"] as? Int ?? 0)
                == text.unicodeScalars.count
        )
        #expect(collected == text)
    }
}
