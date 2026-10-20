import Foundation
import XCTest
@testable import FloeAndroidCore

/// Unit tests for the settings-domain P0 vocabulary.
///
/// These are authored source tests only: they do not open a database, call a
/// model, read credentials, register a handler or claim any runtime result.
/// They exercise the pure validation, digest and chunking helpers that the
/// later P1..P8 adapters must use.
final class SettingsDomainV1Tests: XCTestCase {
    private func decode(_ value: String) -> SettingsDomainV1.JSONValue {
        SettingsDomainV1.JSONValue.decode(Data(value.utf8))!
    }

    private func validate(_ command: String, _ label: String,
                          createIntent: Bool = false,
                          revisionPresent: Bool = false,
                          payload: String? = nil) -> SettingsDomainV1.ValidationFailure? {
        SettingsDomainV1.validate(
            payload: payload.map(decode),
            command: command,
            label: label,
            createIntent: createIntent,
            revisionPresent: revisionPresent
        )
    }

    // MARK: - Canonical digest

    func testCanonicalDigestDistinguishesNullTextDelimitersAndTypes() {
        let domain = "floe.test-domain.v1"
        let nullToken = SettingsDomainV1.CanonicalDigest.token(
            domain: domain, records: [[.null]])
        let textNull = SettingsDomainV1.CanonicalDigest.token(
            domain: domain, records: [[.text("NULL")]])
        let textAngleNull = SettingsDomainV1.CanonicalDigest.token(
            domain: domain, records: [[.text("<null>")]])
        let emptyText = SettingsDomainV1.CanonicalDigest.token(
            domain: domain, records: [[.text("")]])
        XCTAssertEqual(Set([nullToken, textNull, textAngleNull, emptyText]).count, 4)

        let embeddedSeparator = SettingsDomainV1.CanonicalDigest.token(
            domain: domain, records: [[.text("a\u{1F}b")]])
        let twoFields = SettingsDomainV1.CanonicalDigest.token(
            domain: domain, records: [[.text("a"), .text("b")]])
        let pipeText = SettingsDomainV1.CanonicalDigest.token(
            domain: domain, records: [[.text("a|b")]])
        XCTAssertEqual(Set([embeddedSeparator, twoFields, pipeText]).count, 3)

        let integer = SettingsDomainV1.CanonicalDigest.token(
            domain: domain, records: [[.integer(1)]])
        let real = SettingsDomainV1.CanonicalDigest.token(
            domain: domain, records: [[.real(1.0)]])
        let text = SettingsDomainV1.CanonicalDigest.token(
            domain: domain, records: [[.text("1")]])
        XCTAssertEqual(Set([integer, real, text]).count, 3)

        let negativeZero = SettingsDomainV1.CanonicalDigest.token(
            domain: domain, records: [[.real(-0.0)]])
        let positiveZero = SettingsDomainV1.CanonicalDigest.token(
            domain: domain, records: [[.real(0.0)]])
        XCTAssertNotEqual(negativeZero, positiveZero)

        let emptySet = SettingsDomainV1.CanonicalDigest.token(domain: domain, records: [])
        let oneEmptyRecord = SettingsDomainV1.CanonicalDigest.token(
            domain: domain, records: [[.text("")]])
        XCTAssertNotEqual(emptySet, oneEmptyRecord)
    }

    func testCanonicalDigestStreamOrderingAndFixedOrderRows() {
        let domain = "floe.test-stream.v1"
        let records: [[SettingsDomainV1.CanonicalDigest.Field]] = [
            [.text("a"), .text("1")], [.text("b"), .text("2")],
        ]
        // The encoder writes the caller's records in order. Identity streams
        // are sorted by the caller (SQL ORDER BY); any construction order of
        // the same sorted stream must then produce the same digest, while an
        // unsorted stream must not.
        func byRawID(_ lhs: [SettingsDomainV1.CanonicalDigest.Field],
                     _ rhs: [SettingsDomainV1.CanonicalDigest.Field]) -> Bool {
            guard case .text(let left) = lhs[0],
                  case .text(let right) = rhs[0] else { return false }
            return left.utf8.lexicographicallyPrecedes(right.utf8)
        }
        let forward = SettingsDomainV1.CanonicalDigest.token(
            domain: domain, records: records.sorted(by: byRawID))
        let reverse = SettingsDomainV1.CanonicalDigest.token(
            domain: domain, records: records.reversed().sorted(by: byRawID))
        XCTAssertEqual(forward, reverse, "sorted streams are permutation-invariant")
        XCTAssertNotEqual(
            SettingsDomainV1.CanonicalDigest.token(domain: domain, records: records),
            SettingsDomainV1.CanonicalDigest.token(domain: domain,
                                                   records: records.reversed()),
            "the encoder preserves caller order; identity streams must be sorted")

        let rowA = SettingsDomainV1.CanonicalDigest.rowToken(
            domain: domain, fields: [.text("a"), .text("b")])
        let rowB = SettingsDomainV1.CanonicalDigest.rowToken(
            domain: domain, fields: [.text("b"), .text("a")])
        XCTAssertNotEqual(rowA, rowB, "fixed-order rows are order-sensitive")
        XCTAssertTrue(forward.hasPrefix("sha256:"))
        XCTAssertEqual(forward.count, 71)
    }

    func testCanonicalDigestKnownVectors() {
        // Fixed vectors also encoded by the Kotlin mirror. Any change to the
        // type tags, lengths, domain separator or terminator breaks these.
        XCTAssertEqual(
            SettingsDomainV1.CanonicalDigest.token(
                domain: "floe.test-domain.v1", records: [[.null]]),
            "sha256:8e266dda37a34717f46567b34e7d01235be575ae642e5cace0c20d42d79ed040"
        )
        XCTAssertEqual(
            SettingsDomainV1.CanonicalDigest.token(
                domain: "floe.test-domain.v1", records: [[.text("a\u{1F}b")]]),
            "sha256:c1cc1e8fc89341e28d2a3392b7f6c5d8122d5bab7c4949c458a2fa1001a3e14e"
        )
        XCTAssertEqual(
            SettingsDomainV1.CanonicalDigest.token(
                domain: "floe.test-domain.v1",
                records: [[.text("a"), .integer(1), .real(1.0)]]),
            "sha256:e82f2c03d0f48dd66637930c25c0e34e33e55b38c362b24b64e00e0e50c11463"
        )
    }

    func testCanonicalDigestFinalContractVectors() {
        let domain = "floe.test-domain.v1"
        func token(_ records: [[SettingsDomainV1.CanonicalDigest.Field]]) -> String {
            SettingsDomainV1.CanonicalDigest.token(domain: domain, records: records)
        }
        // NULL and the literal spellings must all differ.
        XCTAssertEqual(token([[.text("NULL")]]),
                       "sha256:aed0060f828b6acf31240bc2b95a550a1ef217db9a858a4729bbc0984483dbda")
        XCTAssertEqual(token([[.text("<null>")]]),
                       "sha256:5f037464bb245e468c7125156403b38992101d256b67969e7e402ad31583b6cd")
        XCTAssertEqual(token([[.text("")]]),
                       "sha256:d04a8ffdfeb150415c05a449cac3dae28715c483eb5d014c6f464a47b2400454")
        XCTAssertEqual(token([[.text("a|b")]]),
                       "sha256:ff873c5ad7ae6cf5f697bbe64a67d2fe88da84c756739173ee2c92474c6ebda5")
        // INTEGER 1, REAL 1.0 and TEXT "1" are distinct.
        XCTAssertEqual(token([[.integer(1)]]),
                       "sha256:2d76a1d92b3c479128fb1b652f1411826aad7b14fb0b49a3d59697661f32d1c4")
        XCTAssertEqual(token([[.real(1.0)]]),
                       "sha256:e407fd63c4efd9d63f718765355be2de2b692fa2190912aa39a7697329f387a9")
        XCTAssertEqual(token([[.text("1")]]),
                       "sha256:678e97b738f918c00420f5e34c1e320fb5fb7a67aa6f8649a5ed06cd95bf9218")
        // Unicode is hashed as exact UTF-8 bytes, including emoji and NUL.
        XCTAssertEqual(token([[.text("记忆 🧪")]]),
                       "sha256:77557c230f4072b4493eaedee41e45f411ca04c7f8fa8b8f8b88e34a997b1760")
        XCTAssertEqual(token([[.text("a\u{0}b")]]),
                       "sha256:1358515378e0289f3ae51bebeb3832f644636dc6fc2ea7288810012d477ab43d")
        // Int64 bounds and signed real zero use the exact bit pattern.
        XCTAssertEqual(token([[.integer(.min)]]),
                       "sha256:0833a1f65a014f8ec3eb42b9d2151d6c13a0b472a4fccbb81dad063e7ac35d59")
        XCTAssertEqual(token([[.integer(.max)]]),
                       "sha256:72207d1c815db4361ead204b47c3969062ae0ce73344c2c3fcf50f93dae8a814")
        XCTAssertEqual(token([[.real(-0.0)]]),
                       "sha256:abc5fa1dd093f66909da2503c0045cab7bd059ce9dcccff2d8151b22969973f1")
        XCTAssertEqual(token([[.real(0.0)]]),
                       "sha256:8e1dac2bf944541404eed91460e7d00b02cb08593424fc8e1231149fa0615391")
        // Empty set vs a single empty-text record.
        XCTAssertEqual(token([]),
                       "sha256:e9b33f8eb6a88ed572780774f83f58bcbcd5a88f89b5a7354453df08ec96eef3")
        XCTAssertNotEqual(token([]), token([[.text("")]]))
    }

    // MARK: - Content budget

    func testContentChunkUsesScalarBoundariesAndActualBudget() throws {
        let content = "A😀B中文C"
        let bytes = Array(content.utf8)
        let first = try SettingsDomainV1.ContentBudget.chunk(
            content, offsetBytes: 0, maxBytes: 1).get()
        XCTAssertEqual(first.chunk, "A")
        XCTAssertEqual(first.nextOffset, 1)
        XCTAssertFalse(first.done)

        // A partial multi-byte scalar is never emitted as a replacement char.
        XCTAssertThrowsError(try SettingsDomainV1.ContentBudget.chunk(
            content, offsetBytes: 1, maxBytes: 3).get())
        let emoji = try SettingsDomainV1.ContentBudget.chunk(
            content, offsetBytes: 1, maxBytes: 4).get()
        XCTAssertEqual(emoji.chunk, "😀")
        XCTAssertEqual(emoji.nextOffset, 5)
        // An offset inside a scalar is rejected.
        XCTAssertThrowsError(try SettingsDomainV1.ContentBudget.chunk(
            content, offsetBytes: 2, maxBytes: 4).get())
        XCTAssertEqual(Array(emoji.chunk.utf8), Array(bytes[1..<5]))

        // Walk the complete content and reassemble byte-exactly.
        var offset = 0
        var rebuilt = Data()
        var pages = 0
        while true {
            let chunk = try SettingsDomainV1.ContentBudget.chunk(
                content, offsetBytes: offset, maxBytes: 4).get()
            rebuilt.append(Data(chunk.chunk.utf8))
            XCTAssertTrue(SettingsDomainV1.ContentBudget.fitsPageBudget(chunk))
            pages += 1
            guard let next = chunk.nextOffset else { break }
            offset = next
        }
        XCTAssertEqual(rebuilt, Data(bytes))
        XCTAssertGreaterThan(pages, 1)

        // The actual page budget wins over the requested maxBytes.
        let cjk = String(repeating: "中", count: 100)
        let tight = try SettingsDomainV1.ContentBudget.chunk(
            cjk, offsetBytes: 0, maxBytes: 32_768, pageBudget: 160).get()
        XCTAssertLessThan(tight.chunk.utf8.count, 300)
        XCTAssertTrue(SettingsDomainV1.ContentBudget.fitsPageBudget(
            tight, pageBudget: 160))
    }

    func testTerminalEmptyPageHonorsTheActualBudget() throws {
        let terminal = try SettingsDomainV1.ContentBudget.chunk(
            "abc", offsetBytes: 3, maxBytes: 1).get()
        XCTAssertEqual(terminal.chunk, "")
        XCTAssertNil(terminal.nextOffset)
        XCTAssertTrue(terminal.done)
        XCTAssertEqual(terminal.totalBytes, 3)
        XCTAssertTrue(SettingsDomainV1.ContentBudget.fitsPageBudget(terminal))

        // The empty terminal page still has a real encoded size. A tiny
        // budget must be a typed failure, never an oversized success.
        XCTAssertThrowsError(try SettingsDomainV1.ContentBudget.chunk(
            "abc", offsetBytes: 3, maxBytes: 1, pageBudget: 8).get()) { error in
            XCTAssertEqual(error as? SettingsDomainV1.ValidationFailure,
                           .invalid("invalidChunkRange"))
        }
        // A tiny budget that cannot hold any non-empty page fails typed too.
        XCTAssertThrowsError(try SettingsDomainV1.ContentBudget.chunk(
            "abc", offsetBytes: 0, maxBytes: 1, pageBudget: 8).get())
    }

    /// MAIN_TERMINAL_METADATA_BUDGET_FOLLOWUP_20261019 executed regression
    /// (RB1 integration): the TERMINAL candidate (nextOffset null + done true)
    /// encodes SMALLER than the penultimate non-terminal prefix, so a pure
    /// monotone binary search left a fitting final page unselected. The
    /// witness is 10001 ASCII bytes at the exact terminal-tight budget:
    /// terminal-first selection must return ALL 10001 bytes on one page.
    func testTerminalMetadataShrinkSelectsFullFinalPage() throws {
        let content = String(repeating: "A", count: 10_001)
        func encodedPrefix(_ byteCount: Int, terminal: Bool) -> Int {
            SettingsDomainV1.ContentBudget.encodedChunkResponseBytes(
                SettingsDomainV1.ContentChunk(
                    chunk: String(repeating: "A", count: byteCount),
                    nextOffset: terminal ? nil : byteCount,
                    totalBytes: 10_001,
                    done: terminal))
        }
        let terminalBytes = encodedPrefix(10_001, terminal: true)
        let penultimateBytes = encodedPrefix(10_000, terminal: false)
        // The shrink is real: the 10000-byte NON-terminal prefix oversizes
        // the exact terminal budget even though it carries LESS content.
        XCTAssertGreaterThan(penultimateBytes, terminalBytes)

        let page = try SettingsDomainV1.ContentBudget.chunk(
            content, offsetBytes: 0, maxBytes: 20_000,
            pageBudget: terminalBytes).get()
        XCTAssertEqual(page.chunk.utf8.count, 10_001)
        XCTAssertTrue(page.done)
        XCTAssertNil(page.nextOffset)
        XCTAssertTrue(SettingsDomainV1.ContentBudget.fitsPageBudget(
            page, pageBudget: terminalBytes))

        // Tight-budget control: one byte below the terminal response the
        // final page cannot fit; the selection stays inside the strictly
        // monotone non-terminal range and never marks data lost.
        let below = try SettingsDomainV1.ContentBudget.chunk(
            content, offsetBytes: 0, maxBytes: 20_000,
            pageBudget: terminalBytes - 1).get()
        XCTAssertFalse(below.done)
        XCTAssertNotNil(below.nextOffset)
        XCTAssertTrue(SettingsDomainV1.ContentBudget.fitsPageBudget(
            below, pageBudget: terminalBytes - 1))
        // The selected prefix is exactly the largest NON-terminal candidate
        // that fits (the 9999-byte witness selection; nothing bigger fits).
        XCTAssertFalse(SettingsDomainV1.ContentBudget.fitsPageBudget(
            SettingsDomainV1.ContentChunk(
                chunk: String(repeating: "A", count: below.chunk.utf8.count + 1),
                nextOffset: below.chunk.utf8.count + 1,
                totalBytes: 10_001, done: false),
            pageBudget: terminalBytes - 1))

        // Non-terminal window control: when the request window cannot reach
        // EOF there is no terminal candidate and behavior is unchanged.
        let mid = try SettingsDomainV1.ContentBudget.chunk(
            content, offsetBytes: 0, maxBytes: 5_000,
            pageBudget: terminalBytes).get()
        XCTAssertEqual(mid.chunk.utf8.count, 5_000)
        XCTAssertFalse(mid.done)
        XCTAssertEqual(mid.nextOffset, 5_000)

        // Unicode + escaping controls: multibyte content and heavy escapes
        // near the final boundary select the FULL page at their exact
        // terminal budget and stay inside budget one byte below.
        for sample in [String(repeating: "中", count: 4_000),
                       String(repeating: "\\\"\n", count: 3_000),
                       String(repeating: "😀", count: 3_000)] {
            let total = sample.utf8.count
            func encodedTerminal(_ byteCount: Int) -> Int {
                SettingsDomainV1.ContentBudget.encodedChunkResponseBytes(
                    SettingsDomainV1.ContentChunk(
                        chunk: String(bytes: Array(sample.utf8.prefix(byteCount)),
                                     encoding: .utf8)!,
                        nextOffset: nil, totalBytes: total, done: true))
            }
            let budget = encodedTerminal(total)
            let full = try SettingsDomainV1.ContentBudget.chunk(
                sample, offsetBytes: 0, maxBytes: total,
                pageBudget: budget).get()
            XCTAssertEqual(full.chunk, sample)
            XCTAssertTrue(full.done)
            let tight = try SettingsDomainV1.ContentBudget.chunk(
                sample, offsetBytes: 0, maxBytes: total,
                pageBudget: budget - 1).get()
            XCTAssertFalse(tight.done)
            XCTAssertTrue(SettingsDomainV1.ContentBudget.fitsPageBudget(
                tight, pageBudget: budget - 1))
        }
    }

    func testDenseEscapedContentChunksWithBoundedWork() throws {
        // 32KiB of the most expensive ASCII escapes. The previous
        // remove-one-scalar-and-reserialize loop would re-encode the whole
        // prefix once per candidate byte here.
        let dense = String(repeating: "\"\\\u{01}\n", count: 8_192)
        let bytes = Array(dense.utf8)
        XCTAssertEqual(bytes.count, 32_768)
        var offset = 0
        var rebuilt = Data()
        var pages = 0
        var firstBytes = 0
        while true {
            let chunk = try SettingsDomainV1.ContentBudget.chunk(
                dense, offsetBytes: offset, maxBytes: 32_768).get()
            if pages == 0 { firstBytes = chunk.chunk.utf8.count }
            rebuilt.append(Data(chunk.chunk.utf8))
            XCTAssertTrue(SettingsDomainV1.ContentBudget.fitsPageBudget(chunk))
            XCTAssertFalse(chunk.chunk.isEmpty)
            pages += 1
            guard let next = chunk.nextOffset else { break }
            XCTAssertGreaterThan(next, offset)
            offset = next
        }
        XCTAssertEqual(rebuilt, Data(bytes))
        // Each 4-byte group encodes to 12 bytes, so a 48KiB page carries
        // roughly 16KiB of content. Two pages are expected; the upper bound
        // detects a chunker that silently shrinks pages to dodge the work.
        XCTAssertEqual(pages, 3)
        XCTAssertGreaterThan(firstBytes, 16_000)
    }

    func testInlineReplacementMathFailsClosed() {
        XCTAssertEqual(SettingsDomainV1.ContentBudget.encodedInlineResponseBytes(
            metadataEncodedBytesWithEmptyContent: 1, content: "x"), Int.max)
        XCTAssertEqual(SettingsDomainV1.ContentBudget.encodedInlineResponseBytes(
            metadataEncodedBytesWithEmptyContent: Int.max, content: "x"), Int.max)
        XCTAssertEqual(SettingsDomainV1.ContentBudget.encodedInlineResponseBytes(
            metadataEncodedBytesWithEmptyContent: 64, content: "x"), 65)
    }

    func testEncodedJsonStringBytesCountsRealEscaping() {
        XCTAssertEqual(SettingsDomainV1.ContentBudget.encodedJSONStringBytes("a"), 3)
        XCTAssertEqual(SettingsDomainV1.ContentBudget.encodedJSONStringBytes("\""), 4)
        XCTAssertEqual(SettingsDomainV1.ContentBudget.encodedJSONStringBytes("\\"), 4)
        XCTAssertEqual(SettingsDomainV1.ContentBudget.encodedJSONStringBytes("/"), 4)
        XCTAssertEqual(SettingsDomainV1.ContentBudget.encodedJSONStringBytes("\n"), 4)
        XCTAssertEqual(SettingsDomainV1.ContentBudget.encodedJSONStringBytes("\r"), 4)
        XCTAssertEqual(SettingsDomainV1.ContentBudget.encodedJSONStringBytes("\t"), 4)
        XCTAssertEqual(SettingsDomainV1.ContentBudget.encodedJSONStringBytes("\u{1F}"), 8)
        XCTAssertEqual(SettingsDomainV1.ContentBudget.encodedJSONStringBytes("\u{7F}"), 3)
        XCTAssertEqual(SettingsDomainV1.ContentBudget.encodedJSONStringBytes("中"), 5)
        XCTAssertEqual(SettingsDomainV1.ContentBudget.encodedJSONStringBytes("😀"), 6)
        XCTAssertEqual(SettingsDomainV1.ContentBudget.encodedJSONStringBytes("a\u{0}b"), 10)
    }

    func testEncodedSizesMatchTheActualWireEncoder() {
        // Parity is against the actual JSONSerialization wire path, not a
        // hand-written estimate. Values cover quotes, slash, backslashes,
        // short escapes, C0 controls, CJK, emoji and both string positions
        // (fragment and the complete chunk response object).
        let values = [
            "a", "\"", "\\", "/", "\n", "\r", "\t", "\u{08}", "\u{0C}",
            "\u{1F}", "\u{7F}", "中", "😀", "a\u{0}b", "a/b\\c\"d\ne\tf",
            "记忆 🧪", "\u{2028}\u{2029}",
        ]
        for value in values {
            let fragment = try? JSONSerialization.data(
                withJSONObject: value, options: [.fragmentsAllowed])
            XCTAssertEqual(SettingsDomainV1.ContentBudget.encodedJSONStringBytes(value),
                           fragment?.count, value)

            let chunk = SettingsDomainV1.ContentChunk(
                chunk: value, nextOffset: nil,
                totalBytes: value.utf8.count, done: true)
            var object: [String: Any] = [
                "chunk": value,
                "totalBytes": chunk.totalBytes,
                "done": chunk.done,
            ]
            object["nextOffset"] = NSNull()
            let response = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys])
            XCTAssertEqual(
                SettingsDomainV1.ContentBudget.encodedChunkResponseBytes(chunk),
                response?.count, value)
        }
        // Fixed complete-response size for the smallest terminal page.
        XCTAssertEqual(
            SettingsDomainV1.ContentBudget.encodedChunkResponseBytes(
                SettingsDomainV1.ContentChunk(chunk: "a", nextOffset: nil,
                                              totalBytes: 1, done: true)),
            58)
    }

    func testInlineDecisionUsesCompleteEncodedEnvelope() throws {
        func response(_ content: String, contentBytes: Int) -> [String: Any] {
            [
                "active": [
                    "id": "11111111-1111-1111-1111-111111111111",
                    "content": content,
                    "contentBytes": contentBytes,
                    "revision": 3,
                ],
                "latestRevision": 3,
                "revisionsMeta": [],
                "cursor": ["revision": "absent"],
            ]
        }
        func encoded(_ content: String, contentBytes: Int) -> Int {
            (try? JSONSerialization.data(
                withJSONObject: response(content, contentBytes: contentBytes),
                options: [.sortedKeys]))?.count ?? -1
        }
        let sample = "a\"b\n中文😀"
        // `contentBytes` is final metadata: a real producer knows the exact
        // byte count even in the empty-content metadata probe, so the only
        // replacement is the 2-byte empty JSON string.
        let metadata = encoded("", contentBytes: sample.utf8.count)
        XCTAssertEqual(metadata - 2 + SettingsDomainV1.ContentBudget.encodedJSONStringBytes(sample),
                       encoded(sample, contentBytes: sample.utf8.count))
        XCTAssertEqual(SettingsDomainV1.ContentBudget.encodedInlineResponseBytes(
            metadataEncodedBytesWithEmptyContent: metadata, content: sample),
                       encoded(sample, contentBytes: sample.utf8.count))
        XCTAssertTrue(SettingsDomainV1.ContentBudget.shouldInline(
            content: sample, metadataEncodedBytesWithEmptyContent: metadata,
            pageBudget: encoded(sample, contentBytes: sample.utf8.count)))
        XCTAssertFalse(SettingsDomainV1.ContentBudget.shouldInline(
            content: sample, metadataEncodedBytesWithEmptyContent: metadata,
            pageBudget: encoded(sample, contentBytes: sample.utf8.count) - 1))

        // There is no extra 16 KiB inline cap: a 20k ASCII document is inline
        // when the complete encoded response fits.
        let small = String(repeating: "a", count: 20_000)
        let smallBytes = small.utf8.count
        XCTAssertTrue(SettingsDomainV1.ContentBudget.shouldInline(
            content: small,
            metadataEncodedBytesWithEmptyContent: encoded("", contentBytes: smallBytes),
            pageBudget: encoded(small, contentBytes: smallBytes)))
        let large = String(repeating: "中", count: 20_000)
        let largeBytes = large.utf8.count
        XCTAssertFalse(SettingsDomainV1.ContentBudget.shouldInline(
            content: large,
            metadataEncodedBytesWithEmptyContent: encoded("", contentBytes: largeBytes)))
    }

    // MARK: - Closed payload validation

    func testClosedPayloadValidationAndEnums() {
        XCTAssertNil(validate("config.defaults.save", "settings.defaults",
                              revisionPresent: true,
                              payload: #"{"values":{"defaultAgentMode":"human"}}"#))
        XCTAssertEqual(validate("config.defaults.save", "settings.defaults",
                                revisionPresent: true,
                                payload: #"{"values":{"defaultAgentMode":"human","extra":1}}"#)?.reason,
                       "unknownDefaultsField")
        XCTAssertEqual(validate("config.defaults.save", "settings.defaults",
                                revisionPresent: true,
                                payload: #"{"values":{"defaultAgentMode":"god"}}"#)?.reason,
                       "invalidDefaultsValue:defaultAgentMode")
        XCTAssertEqual(validate("config.defaults.save", "settings.defaults",
                                revisionPresent: true,
                                payload: #"{"values":{"verifyFinalAnswer":1}}"#)?.reason,
                       "invalidDefaultsValue:verifyFinalAnswer")
        XCTAssertEqual(validate("config.defaults.save", "settings.defaults",
                                revisionPresent: true,
                                payload: #"{"values":{"verifyFinalAnswer":true,"extra":null}}"#)?.reason,
                       "unknownDefaultsField")

        // Absent field defaults are valid; explicit null is not a valid bool.
        XCTAssertNil(validate("memory.list", "memory", payload: "{}"))
        XCTAssertEqual(validate("memory.list", "memory",
                                payload: #"{"isPinned":null}"#)?.reason,
                       "invalidPayloadField:isPinned")
        XCTAssertEqual(validate("memory.list", "memory",
                                payload: #"{"isPinned":1}"#)?.reason,
                       "invalidPayloadField:isPinned")
        XCTAssertEqual(validate("memory.list", "memory",
                                payload: #"{"limit":0}"#)?.reason,
                       "payloadFieldOutOfRange:limit")
        XCTAssertEqual(validate("memory.list", "memory",
                                payload: #"{"limit":1.5}"#)?.reason,
                       "invalidPayloadField:limit")
        XCTAssertEqual(validate("memory.list", "memory",
                                payload: #"{"cursor":12}"#)?.reason,
                       "invalidCursor")

        // UUID and zero-UUID fences.
        XCTAssertEqual(validate("memory.get", "memory",
                                payload: #"{"id":"00000000-0000-0000-0000-000000000000"}"#)?.reason,
                       "invalidPayloadField:id")
        XCTAssertNil(validate("memory.get", "memory",
                              payload: #"{"id":"11111111-1111-1111-1111-111111111111"}"#))

        // Memory scope is closed and identity-complete.
        XCTAssertNil(validate("memory.add", "memory", createIntent: true,
                              payload: #"{"content":"hello","scope":{"kind":"user"}}"#))
        XCTAssertEqual(validate("memory.add", "memory", createIntent: true,
                                payload: #"{"content":"hello","scope":{"kind":"workspace"}}"#)?.reason,
                       "invalidPayloadField:scope")
        XCTAssertEqual(validate("memory.add", "memory", createIntent: true,
                                payload: #"{"content":"hello","scope":{"kind":"user","workspaceID":"11111111-1111-1111-1111-111111111111"}}"#)?.reason,
                       "invalidPayloadField:scope")

        // Oversize user-edited content is rejected, never clamped.
        let oversize = String(repeating: "x", count: 24_001)
        let failure = validate("personalization.save", "personalization",
                               revisionPresent: true,
                               payload: #"{"kind":"soul","content":"\#(oversize)"}"#)
        XCTAssertEqual(failure?.code, "payloadTooLarge")
        XCTAssertEqual(failure?.reason, "maxChars:24000")

        // Nullable change fields distinguish null from absence.
        XCTAssertNil(validate("memory.update", "memory", revisionPresent: true,
                              payload: #"{"id":"11111111-1111-1111-1111-111111111111","changes":{"expiresAt":null,"factIdentity":null}}"#))
        XCTAssertEqual(validate("memory.update", "memory", revisionPresent: true,
                                payload: #"{"id":"11111111-1111-1111-1111-111111111111","changes":{"expiresAt":null,"factIdentity":null,"content":null}}"#)?.reason,
                       "invalidPayloadField:content")
    }

    func testBulkAndContentChunkValidation() {
        let id = UUID().uuidString
        let digest = "sha256:" + String(repeating: "a", count: 64)
        let batch = #"{"batchID":"\#(UUID().uuidString)","entries":[{"id":"\#(id)","expectedDigest":"\#(digest)"}],"syncRevision":0}"#
        XCTAssertNil(validate("memory.delete.bulk", "memory", createIntent: true,
                              payload: batch))
        let duplicate = #"{"batchID":"\#(UUID().uuidString)","entries":[{"id":"\#(id)","expectedDigest":"\#(digest)"},{"id":"\#(id)","expectedDigest":"\#(digest)"}],"syncRevision":0}"#
        XCTAssertEqual(validate("memory.delete.bulk", "memory", createIntent: true,
                                payload: duplicate)?.reason, "duplicateBatchEntry")
        XCTAssertNil(validate("content.read", "personalization",
                              payload: #"{"handle":"h-1","offsetBytes":0,"maxBytes":32768}"#))
        XCTAssertEqual(validate("content.read", "personalization",
                                payload: #"{"handle":"h-1","offsetBytes":0,"maxBytes":0}"#)?.reason,
                       "invalidChunkRange")
        XCTAssertEqual(validate("content.read", "personalization",
                                payload: #"{"handle":"h-1","offsetBytes":-1,"maxBytes":1}"#)?.reason,
                       "invalidChunkRange")
        XCTAssertEqual(validate("content.read", "conversations",
                                payload: #"{"handle":"","offsetBytes":0,"maxBytes":1}"#)?.reason,
                       "unknownCommand",
                       "the existing conversations entry is outside this vocabulary")
    }

    func testUsageDimensionUsesFrozenUnknownDimensionReason() {
        // A present but invalid dimension (bad string, wrong type or null)
        // uses the frozen usage reason; an omitted dimension defaults total.
        for payload in [#"{"dimension":"everything"}"#,
                        #"{"dimension":7}"#,
                        #"{"dimension":1.5}"#,
                        #"{"dimension":true}"#,
                        #"{"dimension":null}"#,
                        #"{"dimension":[]}"#,
                        #"{"dimension":{}}"#] {
            let failure = validate("usage.statistics.get", "usage", payload: payload)
            XCTAssertEqual(failure?.code, "invalidEnvelope", payload)
            XCTAssertEqual(failure?.reason, "unknownDimension", payload)
        }
        XCTAssertNil(validate("usage.statistics.get", "usage", payload: "{}"))
        XCTAssertNil(validate("usage.statistics.get", "usage",
                              payload: #"{"dimension":"model","limit":10}"#))
        // Non-object payloads keep the generic shape rejection.
        XCTAssertEqual(validate("usage.statistics.get", "usage", payload: "[]")?.reason,
                       "invalidPayload")
        // Other domains keep the generic enum-field taxonomy.
        XCTAssertEqual(validate("memory.list", "memory",
                                payload: #"{"status":"bogus"}"#)?.reason,
                       "invalidPayloadField:status")
        XCTAssertEqual(validate("memory.update", "memory", revisionPresent: true,
                                payload: #"{"id":"11111111-1111-1111-1111-111111111111","changes":{"status":"bogus"}}"#)?.reason,
                       "invalidPayloadField:status")
    }

    func testCreateOnlyPolicyRequiresExplicitIntent() {
        XCTAssertEqual(validate("memory.add", "memory",
                                payload: #"{"content":"x","scope":{"kind":"user"}}"#)?.reason,
                       "createIntentRequired")
        XCTAssertEqual(validate("personalization.generate", "personalization",
                                payload: #"{"kind":"soul"}"#)?.reason,
                       "createIntentRequired")
        XCTAssertEqual(validate("memory.add", "memory", createIntent: true,
                                revisionPresent: true,
                                payload: #"{"content":"x","scope":{"kind":"user"}}"#)?.reason,
                       "revisionForNewIdentity")
        XCTAssertNil(validate("memory.organize.start", "memory", createIntent: true,
                              payload: #"{"mode":"reviewFirst","includeSemantic":false}"#))
    }

    // MARK: - Final contract DTO shapes

    func testFinalContractDTOShapesAreNestedAndFlatAsSpecified() throws {
        let id = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
        let scope = try SettingsDomainV1.MemoryScope(kind: .user)
        let ownership = SettingsDomainV1.Ownership(
            ownerDeletedAt: nil, retainedUntil: nil, originOwnerLabel: "owner",
            lastRecalledAt: nil, recallCount: 2)
        let entry = SettingsDomainV1.MemoryEntry(
            id: id, scope: scope, status: .active, content: "hello",
            confidence: 1, importance: 0.8, isPinned: true,
            sourceKind: .explicitUserRequest, originConversationID: nil,
            originWorkspaceID: nil, factIdentity: nil, ownership: ownership,
            expiresAt: nil, createdAt: "2026-10-19T00:00:00Z",
            updatedAt: "2026-10-19T00:00:00Z",
            revision: "sha256:" + String(repeating: "a", count: 64))
        let item = SettingsDomainV1.MemorySearchItem(
            id: id, relevance: 0.9, lexicalRank: 1, semanticRank: nil,
            semanticSimilarity: nil, current: entry, deleted: false)
        let reply = SettingsDomainV1.MemorySearchReply(
            items: [item], searchHandle: "h-1", nextCursor: nil, hasMore: false)
        let object = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(reply)) as! [String: Any]
        let items = object["items"] as! [[String: Any]]
        let current = items[0]["current"] as! [String: Any]
        XCTAssertNotNil(current["revision"], "current.revision is the CAS token")
        XCTAssertNil(current["entry"], "current is flat, not current.entry")
        let ownershipObject = current["ownership"] as! [String: Any]
        XCTAssertEqual(ownershipObject["recallCount"] as? Int, 2)
        XCTAssertNil(current["ownerDeletedAt"],
                     "ownership fields are nested, not flattened")

        let evidence = SettingsDomainV1.MemoryEvidenceReference(
            id: UUID(), messageID: UUID(),
            excerpt: "sha256:" + String(repeating: "b", count: 64))
        let candidate = SettingsDomainV1.MemoryCandidate(
            id: UUID(), scope: scope, content: "fact", confidence: 0.9,
            stability: 0.9, importance: 0.8, sensitivity: .none,
            origin: .explicitUserRequest, evidence: [evidence],
            conflictsWithEntryIDs: [], reviewReason: nil,
            sourceAttachmentID: nil, sourceMIMEType: nil, status: .pending,
            expiresAt: nil, createdAt: "2026-10-19T00:00:00Z",
            updatedAt: "2026-10-19T00:00:00Z",
            revision: "sha256:" + String(repeating: "c", count: 64))
        let candidateJSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(candidate)) as! [String: Any]
        let evidenceJSON = (candidateJSON["evidence"] as! [[String: Any]])[0]
        XCTAssertNotNil(evidenceJSON["messageID"])
        XCTAssertNil(candidateJSON["evidence"] as? [String],
                     "evidence is an object list, not bare strings")

        let document = try SettingsDomainV1.PersonalizationDocument(
            id: id, kind: .soul, workspaceID: nil, revision: 4,
            source: .oneClick, evidenceDigest: "sha256:" + String(repeating: "d", count: 64),
            isActive: true, createdAt: "2026-10-19T00:00:00Z",
            contentBytes: 3, contentDigest: "sha256:" + String(repeating: "e", count: 64),
            content: "abc", contentHandle: nil)
        let effect = SettingsDomainV1.PersonalizationGenerateEffect(
            outcome: .active,
            document: SettingsDomainV1.GeneratedPersonalizationDocument(
                id: id, revision: 4, isActive: true, contentBytes: 3,
                contentDigest: "sha256:" + String(repeating: "e", count: 64),
                createdAt: "2026-10-19T00:00:00Z"),
            revisionToken: "11111111-1111-1111-1111-111111111111.4",
            draftRevision: nil,
            route: .init(providerID: id, modelID: id),
            evidenceDigest: "sha256:" + String(repeating: "f", count: 64),
            sourceSnapshot: .init(memoryCount: 1,
                                  digest: "sha256:" + String(repeating: "1", count: 64)),
            cursor: .init(revision: "sha256:" + String(repeating: "2", count: 64),
                          countersPreserved: false))
        let effectJSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(effect)) as! [String: Any]
        XCTAssertNotNil((effectJSON["route"] as? [String: Any])?["providerID"])
        XCTAssertNotNil((effectJSON["sourceSnapshot"] as? [String: Any])?["memoryCount"])
        XCTAssertNotNil((effectJSON["cursor"] as? [String: Any])?["countersPreserved"])
        XCTAssertNil(effectJSON["routeProviderID"])
        XCTAssertNil(effectJSON["sourceMemoryCount"])
        XCTAssertNil(effectJSON["cursorRevision"])
        _ = document

        let historyReport = SettingsDomainV1.PrivacyHistoryClearReport(
            enumerated: .init(conversations: 1, runs: 2,
                              persistedGrants: 3, inMemoryGrants: 4),
            deleted: .init(conversations: 1, runs: 2,
                           grants: .init(persisted: 3, inMemory: 4)),
            failures: [.init(itemID: id, phase: .drain, reason: "typed")],
            partial: false,
            remaining: .init(conversationCount: 0, runCount: 0,
                             persistedGrantCount: 0, inMemoryGrantCount: 0))
        let historyJSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(historyReport)) as! [String: Any]
        XCTAssertNotNil((historyJSON["enumerated"] as? [String: Any])?["conversations"])
        XCTAssertNotNil((historyJSON["deleted"] as? [String: Any])?["grants"])
        XCTAssertNil(historyJSON["enumeratedConversations"])

        let modelReport = SettingsDomainV1.PrivacyModelConfigClearReport(
            enumerated: .init(providers: 1, models: 2, secretReferences: 1),
            deleted: .init(providers: 1, models: 2, secrets: 1),
            deletionFailures: [.init(providerID: id,
                                     phase: .secretReferenceChanged,
                                     reason: "typed")],
            preferencesReset: true, preferencesSyncRevision: 3,
            remaining: .init(providerCount: 0, modelCount: 0,
                             secretReferenceCount: 0), partial: false)
        let modelJSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(modelReport)) as! [String: Any]
        XCTAssertNotNil((modelJSON["enumerated"] as? [String: Any])?["providers"])
        XCTAssertNotNil((modelJSON["deleted"] as? [String: Any])?["secrets"])
        XCTAssertNil(modelJSON["enumeratedProviders"])

        let cancel = SettingsDomainV1.OperationCancelReply(
            status: .canceled, phase: .streaming)
        let cancelJSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(cancel)) as! [String: Any]
        XCTAssertEqual(cancelJSON["phase"] as? String, "streaming")

        let breakdown = SettingsDomainV1.UsageBreakdown(
            id: "m-1", label: "model", inputTokens: 1, outputTokens: 2,
            runs: 1, cacheReadTokens: nil, cacheWriteTokens: nil,
            reasoningTokens: nil, averageTokensPerSecond: nil,
            averageTimeToFirstTokenMs: nil, averageDurationMs: nil,
            totalTokens: 3)
        let breakdownJSON = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(breakdown)) as! [String: Any]
        XCTAssertEqual(breakdownJSON["inputTokens"] as? Int, 1)
        XCTAssertNil(breakdownJSON["metrics"])
    }

    // MARK: - Typed result semantics

    func testPersonalizationDocumentRequiresExactlyOneProjection() throws {
        let base = (
            id: UUID(), kind: SettingsDomainV1.PersonalizationKind.soul,
            revision: 1, source: SettingsDomainV1.PersonalizationSource.manual,
            isActive: true, createdAt: "2026-10-19T00:00:00Z",
            contentBytes: 3, contentDigest: "sha256:" + String(repeating: "d", count: 64)
        )
        let inline = try SettingsDomainV1.PersonalizationDocument(
            id: base.id, kind: base.kind, workspaceID: nil, revision: base.revision,
            source: base.source, evidenceDigest: "", isActive: base.isActive,
            createdAt: base.createdAt, contentBytes: base.contentBytes,
            contentDigest: base.contentDigest, content: "abc", contentHandle: nil)
        XCTAssertEqual(inline.content, "abc")
        XCTAssertNil(inline.contentHandle)

        let handle = try SettingsDomainV1.PersonalizationDocument(
            id: base.id, kind: base.kind, workspaceID: nil, revision: base.revision,
            source: base.source, evidenceDigest: "", isActive: base.isActive,
            createdAt: base.createdAt, contentBytes: base.contentBytes,
            contentDigest: base.contentDigest, content: nil,
            contentHandle: .init(handle: "h-1", bytes: 3))
        XCTAssertNil(handle.content)
        XCTAssertEqual(handle.contentHandle?.bytes, 3)

        XCTAssertThrowsError(try SettingsDomainV1.PersonalizationDocument(
            id: base.id, kind: base.kind, workspaceID: nil, revision: base.revision,
            source: base.source, evidenceDigest: "", isActive: base.isActive,
            createdAt: base.createdAt, contentBytes: base.contentBytes,
            contentDigest: base.contentDigest, content: "abc",
            contentHandle: .init(handle: "h-1", bytes: 3)))
        XCTAssertThrowsError(try SettingsDomainV1.PersonalizationDocument(
            id: base.id, kind: base.kind, workspaceID: nil, revision: base.revision,
            source: base.source, evidenceDigest: "", isActive: base.isActive,
            createdAt: base.createdAt, contentBytes: base.contentBytes,
            contentDigest: base.contentDigest, content: nil, contentHandle: nil))
    }

    func testGenerateOutcomeRoundTripsDraftReason() throws {
        let outcome = SettingsDomainV1.PersonalizationGenerateOutcome
            .storedAsDraft(reason: .sourceChanged)
        let data = try JSONEncoder().encode(outcome)
        let decoded = try JSONDecoder().decode(
            SettingsDomainV1.PersonalizationGenerateOutcome.self, from: data)
        XCTAssertEqual(decoded, outcome)
        let active = try JSONDecoder().decode(
            SettingsDomainV1.PersonalizationGenerateOutcome.self,
            from: JSONEncoder().encode(SettingsDomainV1.PersonalizationGenerateOutcome.active))
        XCTAssertEqual(active, .active)
    }

    func testMemoryScopeAndUsageNullSemantics() {
        XCTAssertNoThrow(try SettingsDomainV1.MemoryScope(kind: .user))
        XCTAssertThrowsError(try SettingsDomainV1.MemoryScope(kind: .workspace))
        XCTAssertThrowsError(try SettingsDomainV1.MemoryScope(
            kind: .task, workspaceID: UUID()))
        let metrics = SettingsDomainV1.UsageMetrics(
            inputTokens: 1, outputTokens: 2, totalTokens: 3, runs: 1)
        XCTAssertNil(metrics.cacheReadTokens)
        XCTAssertNil(metrics.averageDurationMs)
    }
}
