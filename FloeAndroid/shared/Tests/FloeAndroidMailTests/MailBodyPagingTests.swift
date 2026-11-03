// SPDX-License-Identifier: MPL-2.0
//
// C06 body paging tests. Authored source; NOT RUN by the source lane.

import Foundation
import Testing
import FloeCore
@testable import FloeAndroidMail

private func object(_ json: String) throws -> [String: Any] {
    let data = Data(json.utf8)
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw MailFailure.invalidMessage
    }
    return value
}

@Suite("FloeAndroidMail body paging")
struct MailBodyPagingTests {
    private let binding = MailBodyPaging.Binding(
        accountID: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        folder: "INBOX",
        uid: "42",
        snapshotSHA256: String(repeating: "a", count: 64)
    )

    @Test("Initial and continuation pages reproduce the exact scalar sequence")
    func pagesReproduceBody() throws {
        let text = String(repeating: "Hello 世界 ", count: 400)
        let first = try MailBodyPaging.initialPageJSON(
            binding: binding,
            subject: "Subject",
            from: "a@example.com",
            to: "b@example.com",
            date: "today",
            text: text,
            html: "",
            attachments: [],
            maximumCharacters: 600
        )
        let firstObject = try object(first)
        #expect(firstObject["contentTrust"] as? String == "untrustedEmail")
        #expect(firstObject["formatVersion"] as? Int == 2)
        #expect(firstObject["offsetUnit"] as? String == "unicodeScalar")
        let cursor = try #require(firstObject["nextTextCursor"] as? String)
        #expect(!cursor.isEmpty)
        let firstText = try #require(firstObject["text"] as? String)
        let firstChars = try #require(firstObject["textChars"] as? Int)
        #expect(firstText.unicodeScalars.count == firstChars)

        let continuation = try MailBodyPaging.continuationPageJSON(
            cursorToken: cursor,
            binding: binding,
            text: text,
            html: "",
            maximumCharacters: 600
        )
        let next = try object(continuation)
        let piece = try #require(next["text"] as? String)
        let expected = String(text.unicodeScalars.prefix(firstChars))
        #expect(firstText + piece == expected)
    }

    @Test("Cursor is bound to account, folder, message and content digest")
    func cursorMismatchFailsClosed() throws {
        let text = String(repeating: "x", count: 2_000)
        let first = try object(try MailBodyPaging.initialPageJSON(
            binding: binding,
            subject: "", from: "", to: "", date: "",
            text: text, html: "", attachments: [],
            maximumCharacters: 512
        ))
        let cursor = try #require(first["nextTextCursor"] as? String)
        let wrongAccount = MailBodyPaging.Binding(
            accountID: UUID(),
            folder: binding.folder,
            uid: binding.uid,
            snapshotSHA256: binding.snapshotSHA256
        )
        #expect(throws: MailFailure.cursorMismatch) {
            try MailBodyPaging.continuationPageJSON(
                cursorToken: cursor, binding: wrongAccount, text: text, html: "",
                maximumCharacters: 512
            )
        }
        let wrongDigest = MailBodyPaging.Binding(
            accountID: binding.accountID,
            folder: binding.folder,
            uid: binding.uid,
            snapshotSHA256: String(repeating: "b", count: 64)
        )
        #expect(throws: MailFailure.cursorMismatch) {
            try MailBodyPaging.continuationPageJSON(
                cursorToken: cursor, binding: wrongDigest, text: text, html: "",
                maximumCharacters: 512
            )
        }
    }

    @Test("A single oversized grapheme spans pages without losing scalars")
    func oversizedGraphemeMakesProgress() throws {
        let text = "a" + String(repeating: "\u{0301}", count: 1_500) + "z"
        let first = try object(try MailBodyPaging.initialPageJSON(
            binding: binding,
            subject: "", from: "", to: "", date: "",
            text: text, html: "", attachments: [],
            maximumCharacters: 512
        ))
        let cursor = try #require(first["nextTextCursor"] as? String)
        let second = try object(try MailBodyPaging.continuationPageJSON(
            cursorToken: cursor, binding: binding, text: text, html: "",
            maximumCharacters: 512
        ))
        let combined = (first["text"] as? String ?? "") + (second["text"] as? String ?? "")
        #expect(combined.unicodeScalars.count > 512)
        #expect(Array(text.unicodeScalars).prefix(combined.unicodeScalars.count)
            == Array(combined.unicodeScalars))
    }

    @Test("Attachments are withheld, not allowed to overflow the page budget")
    func attachmentsDeferredUnderBudget() throws {
        let attachments = (0..<10).map {
            MailBodyPaging.Attachment(
                index: $0,
                filename: "attachment-with-a-long-name-\($0).bin",
                byteCount: 1_000,
                sha256: String(repeating: "c", count: 64)
            )
        }
        let page = try object(try MailBodyPaging.initialPageJSON(
            binding: binding,
            subject: "Subject",
            from: "a@example.com",
            to: "b@example.com",
            date: "today",
            text: String(repeating: "body", count: 500),
            html: "",
            attachments: attachments,
            maximumCharacters: 700
        ))
        #expect((page["attachmentsDeferred"] as? Int ?? 0) > 0)
        #expect((page["attachments"] as? [[String: Any]])?.count ?? 0 < attachments.count)
    }

    @Test("Continuation rejects a cursor from the retired grapheme format")
    func legacyCursorRejected() {
        #expect(throws: MailFailure.invalidConfiguration) {
            try MailBodyPaging.continuationPageJSON(
                cursorToken: "mbp1.eyJ2IjoxfQ",
                binding: binding,
                text: "text",
                html: "",
                maximumCharacters: 512
            )
        }
    }
}
