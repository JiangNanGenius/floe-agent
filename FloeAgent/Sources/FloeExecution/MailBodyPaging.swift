import Foundation

/// Bounded, valid-JSON paging for mail bodies.
///
/// The tool boundary truncates every summary twice at 4096 characters — once
/// in `ToolExecutionOutput` (`AgentTool.swift`, default 4096) and once in
/// `ToolResult` (`ToolCall.swift` / `AgentRuntime`, default 4096 for
/// `mail.read`) — without any JSON awareness. A page therefore must stay
/// strictly below both caps *after* JSON escaping, or the model receives a
/// fragment that cannot be parsed and loses its continuation cursor. Every
/// page here is serialized and measured, and only then emitted, so the
/// 4096-character `prefix` is a no-op on it.
///
/// Content is never cached or written anywhere: a continuation re-fetches the
/// message and verifies the raw-bytes digest recorded in the cursor. Cursors
/// are opaque, self-contained values bound to the account, folder, message
/// UID, raw content digest, body format (text/html) and an offset in
/// **Unicode scalar values** (`offsetUnit`), under token format version 2.
///
/// Grapheme clusters are deliberately not the offset unit. A legal extended
/// grapheme cluster can exceed a whole page — for example a base letter
/// followed by thousands of combining marks — so a grapheme-count cursor
/// could never advance inside it (or would have to fail the read entirely).
/// Splitting only at Unicode scalar boundaries keeps every page valid
/// UTF-8/JSON, guarantees at least one scalar of progress per continuation,
/// and makes concatenating the pages reproduce the original UTF-8 bytes
/// exactly. A huge grapheme therefore spans consecutive pages instead of
/// being dropped or replaced; no combining mark is lost.
///
/// The previous `mbp1.` grapheme cursor was never delivered to the App, so it
/// is intentionally not migrated: only `mbp2.` tokens with
/// `offsetUnit == unicodeScalar` decode.
public enum MailBodyPaging {
    public enum Format: String, Codable, Sendable, Equatable {
        case text
        case html
    }

    /// Unit of `offsetStart`/`chars`/`total` in continuation pages and of the
    /// cursor's `offset`. Serialized in every page and cursor so a stored
    /// token can never be reinterpreted under a different counting rule.
    public enum OffsetUnit: String, Codable, Sendable, Equatable {
        /// `String.unicodeScalars`: a boundary that is always valid UTF-8 and
        /// can split a grapheme cluster without changing the scalar sequence.
        case unicodeScalar
    }

    /// Cursor/page contract version. Bumping it retires old offset units.
    public static let formatVersion = 2
    public static let offsetUnit: OffsetUnit = .unicodeScalar

    /// How a page is tied to one exact message revision. `snapshotSHA256` is
    /// the digest of the raw message bytes (the same value `mail.read`
    /// reports as `sha256`), so any content drift rejects the cursor instead
    /// of silently mixing two revisions.
    public struct Binding: Sendable, Equatable {
        public var accountID: UUID
        public var folder: String
        public var uid: String
        public var snapshotSHA256: String

        public init(accountID: UUID, folder: String, uid: String, snapshotSHA256: String) {
            self.accountID = accountID
            self.folder = folder
            self.uid = uid
            self.snapshotSHA256 = snapshotSHA256
        }
    }

    /// Attachment metadata included on the first page. The rows compete for
    /// the same page budget as the body; when they do not all fit, the page
    /// states how many were withheld instead of overflowing the cap.
    public struct Attachment: Sendable, Equatable {
        public var index: Int
        public var filename: String
        public var byteCount: Int
        public var sha256: String

        public init(index: Int, filename: String, byteCount: Int, sha256: String) {
            self.index = index
            self.filename = filename
            self.byteCount = byteCount
            self.sha256 = sha256
        }
    }

    /// Recommended page budget. Stays below the production 4096-character
    /// cap even after JSON escaping; callers may lower it, never raise it
    /// above 4096.
    public static let defaultMaximumCharacters = 4_000
    public static let hardMaximumCharacters = 4_096

    /// Token prefix for format version 2. `mbp1.` used grapheme offsets and is
    /// rejected rather than silently mixed with scalar offsets.
    private static let cursorPrefix = "mbp2."
    /// UTF-8 byte ceilings for bounded metadata. Bytes, not `Character`
    /// counts: one legal grapheme can exceed the whole page budget, so a
    /// grapheme-count clip could not fit even an otherwise empty page.
    private static let subjectLimit = 300
    private static let addressLimit = 200
    private static let dateLimit = 64
    private static let attachmentNameLimit = 120

    struct Cursor: Codable, Equatable {
        var v: Int
        /// Declares the meaning of `offset`; decoding rejects any other unit.
        var offsetUnit: OffsetUnit
        var accountID: UUID
        /// SHA-256 of the UTF-8 folder name (keeps the token small even for
        /// long folder names while still binding the cursor to the folder).
        var folderSHA256: String
        var uid: String
        var snapshotSHA256: String
        var format: Format
        /// Counted in `offsetUnit`, never in `Character`/grapheme clusters.
        var offset: Int

        /// Short keys keep the opaque base64 token small enough that two
        /// cursors plus the first-page metadata still fit a 1200-byte page.
        /// The values (including `u = unicodeScalar`) stay explicit.
        enum CodingKeys: String, CodingKey {
            case v
            case offsetUnit = "u"
            case accountID = "a"
            case folderSHA256 = "f"
            case uid = "i"
            case snapshotSHA256 = "s"
            case format = "t"
            case offset = "o"
        }
    }

    // MARK: - Public page builders

    /// First page for one message. Keeps the legacy `mail.read` field names
    /// (`contentTrust`, `sha256`, `subject`, `from`, `to`, `date`, `text`,
    /// `html`, `truncated`, `attachments`) and adds the continuation state:
    /// `nextTextCursor`/`hasMoreText` and `nextHtmlCursor`/`hasMoreHtml`.
    /// `truncated` keeps its legacy meaning, now honestly derived from
    /// "continuation exists".
    public static func initialPageJSON(
        binding: Binding,
        subject: String,
        from: String,
        to: String,
        date: String,
        text: String,
        html: String,
        attachments: [Attachment],
        maximumCharacters: Int = defaultMaximumCharacters
    ) throws -> String {
        let budget = resolvedBudget(maximumCharacters)
        let clippedSubject = clippedUTF8(subject, subjectLimit)
        let clippedFrom = clippedUTF8(from, addressLimit)
        let clippedTo = clippedUTF8(to, addressLimit)
        let clippedDate = clippedUTF8(date, dateLimit)
        // Totals are Unicode scalar counts, matching the cursor offset unit.
        // `textChars`/`htmlChars` below are counts in that same unit.
        let textTotal = text.unicodeScalars.count
        let htmlTotal = html.unicodeScalars.count

        func page(attachmentLimit: Int, textLimit: Int, htmlLimit: Int) -> [String: Any] {
            let textPage = scalarSlice(text, offset: 0, length: textLimit)
            let htmlPage = scalarSlice(html, offset: 0, length: htmlLimit)
            let hasMoreText = textLimit < textTotal
            let hasMoreHtml = htmlLimit < htmlTotal
            var page: [String: Any] = [
                "contentTrust": "untrustedEmail",
                "sha256": binding.snapshotSHA256,
                "subject": clippedSubject.value,
                "from": clippedFrom.value,
                "to": clippedTo.value,
                "date": clippedDate.value,
                "text": textPage,
                "html": htmlPage,
                "truncated": hasMoreText || hasMoreHtml,
                "textChars": textLimit,
                "textTotal": textTotal,
                "htmlChars": htmlLimit,
                "htmlTotal": htmlTotal,
                "offsetUnit": offsetUnit.rawValue,
                "formatVersion": formatVersion,
                "hasMoreText": hasMoreText,
                "hasMoreHtml": hasMoreHtml,
                "nextTextCursor": hasMoreText
                    ? encodeCursor(makeCursor(binding, format: .text, offset: textLimit))
                    : "",
                "nextHtmlCursor": hasMoreHtml
                    ? encodeCursor(makeCursor(binding, format: .html, offset: htmlLimit))
                    : "",
                "attachments": attachments.prefix(attachmentLimit).map { row($0) }
            ]
            if clippedSubject.clipped { page["subjectTruncated"] = true }
            if clippedFrom.clipped { page["fromTruncated"] = true }
            if clippedTo.clipped { page["toTruncated"] = true }
            if clippedDate.clipped { page["dateTruncated"] = true }
            if attachmentLimit < attachments.count {
                page["attachmentsDeferred"] = attachments.count - attachmentLimit
            }
            if attachments.prefix(attachmentLimit).contains(where: { $0.filename.utf8.count > attachmentNameLimit }) {
                page["attachmentNamesTruncated"] = true
            }
            return page
        }

        // Escaping makes per-character cost non-uniform, so grow the shared
        // body length with a monotone binary search instead of subtracting an
        // overshoot (which could collapse the page to a single character).
        let upper = min(max(textTotal, htmlTotal), budget)
        var attachmentLimit = attachments.count
        while true {
            if let length = largestFittingLength(lowerBound: 0, upperBound: upper, budget: budget, build: { length in
                serialize(page(
                    attachmentLimit: attachmentLimit,
                    textLimit: min(textTotal, length),
                    htmlLimit: min(htmlTotal, length)
                ))
            }) {
                return serialize(page(
                    attachmentLimit: attachmentLimit,
                    textLimit: min(textTotal, length),
                    htmlLimit: min(htmlTotal, length)
                ))
            }
            // Even an empty body does not fit next to the metadata: withhold
            // attachment rows (stated via `attachmentsDeferred`) before
            // failing outright.
            guard attachmentLimit > 0 else { throw MailFailure.responseTooLarge }
            attachmentLimit -= 1
        }
    }

    /// Continuation page for one body stream. The token must have been issued
    /// for exactly this account/folder/UID/content revision; anything else
    /// fails with `cursorMismatch` before any page is produced.
    public static func continuationPageJSON(
        cursorToken: String,
        binding: Binding,
        text: String,
        html: String,
        maximumCharacters: Int = defaultMaximumCharacters
    ) throws -> String {
        let budget = resolvedBudget(maximumCharacters)
        let cursor = try decodeCursor(cursorToken)
        guard cursor.accountID == binding.accountID,
              cursor.folderSHA256 == folderFingerprint(binding.folder),
              cursor.uid == binding.uid,
              cursor.snapshotSHA256 == binding.snapshotSHA256 else {
            throw MailFailure.cursorMismatch
        }
        let body = cursor.format == .text ? text : html
        // `total`, `offset` and `length` are Unicode scalar counts; every
        // continuation consumes at least one scalar, so even one oversized
        // grapheme cannot stall the cursor.
        let total = body.unicodeScalars.count
        guard cursor.offset >= 0, cursor.offset < total else {
            throw MailFailure.cursorMismatch
        }
        func page(length: Int) -> [String: Any] {
            let end = cursor.offset + length
            let hasMore = end < total
            var page: [String: Any] = [
                "contentTrust": "untrustedEmail",
                "sha256": binding.snapshotSHA256,
                "format": cursor.format.rawValue,
                "offsetStart": cursor.offset,
                "chars": length,
                "total": total,
                "offsetUnit": offsetUnit.rawValue,
                "formatVersion": formatVersion,
                "hasMore": hasMore,
                "nextCursor": hasMore
                    ? encodeCursor(makeCursor(binding, format: cursor.format, offset: end))
                    : ""
            ]
            page[cursor.format.rawValue] = scalarSlice(body, offset: cursor.offset, length: length)
            return page
        }

        guard let length = largestFittingLength(
            lowerBound: 1,
            upperBound: min(total - cursor.offset, budget),
            budget: budget,
            build: { serialize(page(length: $0)) }
        ) else {
            throw MailFailure.responseTooLarge
        }
        return serialize(page(length: length))
    }

    // MARK: - Cursor helpers

    static func encodeCursor(_ cursor: Cursor) -> String {
        guard let data = try? JSONEncoder().encode(cursor) else { return "" }
        return cursorPrefix + data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func decodeCursor(_ token: String) throws -> Cursor {
        guard token.hasPrefix(cursorPrefix) else { throw MailFailure.invalidConfiguration }
        var text = String(token.dropFirst(cursorPrefix.count))
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while text.count % 4 != 0 { text += "=" }
        guard let data = Data(base64Encoded: text),
              let cursor = try? JSONDecoder().decode(Cursor.self, from: data),
              cursor.v == formatVersion,
              cursor.offsetUnit == offsetUnit,
              cursor.offset >= 0 else {
            throw MailFailure.invalidConfiguration
        }
        return cursor
    }

    static func folderFingerprint(_ folder: String) -> String {
        MailMutationDigest.sha256Hex(Data(folder.utf8))
    }

    // MARK: - Internals

    private static func makeCursor(_ binding: Binding, format: Format, offset: Int) -> Cursor {
        Cursor(
            v: formatVersion,
            offsetUnit: offsetUnit,
            accountID: binding.accountID,
            folderSHA256: folderFingerprint(binding.folder),
            uid: binding.uid,
            snapshotSHA256: binding.snapshotSHA256,
            format: format,
            offset: offset
        )
    }

    private static func resolvedBudget(_ requested: Int) -> Int {
        min(max(requested, 512), hardMaximumCharacters)
    }

    /// Clip a metadata value to at most `limit` UTF-8 bytes without splitting
    /// a Unicode scalar. A grapheme cluster may be split, but the result is
    /// always valid UTF-8, never contains a replacement character and never
    /// exceeds the byte ceiling. `clipped` is true exactly when bytes were
    /// removed, so the page's `*Truncated` flags stay accurate.
    private static func clippedUTF8(_ value: String, _ limit: Int) -> (value: String, clipped: Bool) {
        let bytes = value.utf8
        guard bytes.count > limit else { return (value, false) }
        var cut = min(max(limit, 0), bytes.count)
        if cut > 0, cut < bytes.count {
            var index = bytes.index(bytes.startIndex, offsetBy: cut)
            // If the first excluded byte is a UTF-8 continuation byte, the
            // cut fell inside a scalar; move back to that scalar's lead byte.
            while index > bytes.startIndex, bytes[index] & 0xC0 == 0x80 {
                index = bytes.index(before: index)
            }
            cut = bytes.distance(from: bytes.startIndex, to: index)
        }
        return (String(decoding: bytes.prefix(cut), as: UTF8.self), true)
    }

    /// Slice exactly `length` Unicode scalar values starting at scalar
    /// `offset`. Callers guarantee `offset + length <=
    /// value.unicodeScalars.count`. The result is always valid UTF-8; the cut
    /// may fall inside a grapheme cluster, which is the point of the scalar
    /// offset unit.
    private static func scalarSlice(_ value: String, offset: Int, length: Int) -> String {
        guard length > 0 else { return "" }
        let scalars = value.unicodeScalars
        let start = scalars.index(scalars.startIndex, offsetBy: offset)
        let end = scalars.index(start, offsetBy: length)
        return String(scalars[start..<end])
    }

    private static func row(_ attachment: Attachment) -> [String: Any] {
        [
            "index": attachment.index,
            "filename": clippedUTF8(attachment.filename, attachmentNameLimit).value,
            "byteCount": attachment.byteCount,
            "sha256": attachment.sha256
        ]
    }

    /// Largest page length whose serialized form stays within `budget`.
    /// Page size is monotone in the emitted character count, so binary
    /// search is exact and makes far more progress per page than a fixed
    /// overshoot subtraction when JSON escaping expands multibyte content.
    private static func largestFittingLength(
        lowerBound: Int,
        upperBound: Int,
        budget: Int,
        build: (Int) -> String
    ) -> Int? {
        guard upperBound >= lowerBound else { return nil }
        var low = lowerBound
        var high = upperBound
        var best: Int?
        while low <= high {
            let mid = low + (high - low) / 2
            if build(mid).utf8.count <= budget {
                best = mid
                low = mid + 1
            } else {
                high = mid - 1
            }
        }
        return best
    }

    private static func serialize(_ value: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
