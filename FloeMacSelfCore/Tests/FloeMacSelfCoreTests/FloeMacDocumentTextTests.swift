// SPDX-License-Identifier: MPL-2.0
//
// Synthetic bounded-extraction regression tests for PDF and DOCX attachment
// text. PDF fixtures are rendered by Core Graphics/CoreText, DOCX fixtures
// are hand-built ZIP packages (stored, deflated and data-descriptor forms);
// every test is in-memory or under a fresh 0700 temporary directory. No user
// database, Keychain, provider, network, App, simulator or shared build
// resource is touched. The coordinator runs the canonical SwiftPM target.

import Foundation
import CoreGraphics
import CoreText
import Testing
#if canImport(zlib)
import zlib
#endif
@testable import FloeMacSelfCore

// MARK: - Fixture roots

private func makeDocumentTextRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
        "floe-mac-document-text-\(UUID().uuidString)",
        isDirectory: true
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700]
    )
    return root
}

// MARK: - PDF fixtures (Core Graphics + CoreText, no AppKit)

private func renderPDF(
    at url: URL,
    lines: [String],
    password: String? = nil
) throws {
    var mediaBox = CGRect(x: 0, y: 0, width: 612, height: 792)
    var auxiliaryInfo: [CFString: Any] = [:]
    if let password {
        auxiliaryInfo[kCGPDFContextUserPassword] = password
        auxiliaryInfo[kCGPDFContextOwnerPassword] = password
    }
    guard let context = CGContext(
        url as CFURL,
        mediaBox: &mediaBox,
        auxiliaryInfo as CFDictionary
    ) else {
        throw CocoaError(.fileWriteUnsupportedScheme)
    }
    context.beginPDFPage(nil)
    if !lines.isEmpty {
        let font = CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        var y: CGFloat = 740
        for line in lines {
            let attributed = NSAttributedString(
                string: line,
                attributes: [.font: font]
            )
            let textLine = CTLineCreateWithAttributedString(attributed)
            context.textPosition = CGPoint(x: 50, y: y)
            CTLineDraw(textLine, context)
            y -= 28
        }
    } else {
        // A drawn-but-text-less page: a "scanned" page with no text layer.
        context.setFillColor(gray: 0.2, alpha: 1)
        context.fill(CGRect(x: 40, y: 40, width: 532, height: 712))
    }
    context.endPDFPage()
    context.closePDF()
}

// MARK: - DOCX fixtures (hand-built bounded ZIP)

private struct ZipEntrySpec {
    var name: String
    var data: [UInt8]
    var method: UInt16
    /// Emit the standard data-descriptor form: bit 3 set, zero local CRC and
    /// sizes, and a signatured descriptor after the payload.
    var usesDataDescriptor = false
    /// Override the declared uncompressed size in both headers (zip-bomb).
    var declaredSize: Int?
    /// Override the recorded CRC (corruption tests).
    var crcOverride: UInt32?
    /// Force general-purpose flag bits (encryption-refusal tests).
    var flagsOverride: UInt16?
}

private let fixtureCRCTable: [UInt32] = (0..<256).map { value -> UInt32 in
    var crc = UInt32(value)
    for _ in 0..<8 {
        crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1
    }
    return crc
}

private func fixtureCRC32(_ bytes: [UInt8]) -> UInt32 {
    var crc: UInt32 = 0xffff_ffff
    for byte in bytes {
        crc = (crc >> 8) ^ fixtureCRCTable[Int((crc ^ UInt32(byte)) & 0xff)]
    }
    return crc ^ 0xffff_ffff
}

#if canImport(zlib)
/// Raw-DEFLATE (window bits -15) compression through the bundled zlib, the
/// exact store form ZIP method 8 uses.
private func fixtureDeflate(_ bytes: [UInt8]) -> [UInt8] {
    precondition(!bytes.isEmpty)
    var stream = z_stream()
    precondition(
        deflateInit2_(
            &stream, Z_DEFAULT_COMPRESSION, Z_DEFLATED, -15, 8,
            Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        ) == Z_OK
    )
    var output = [UInt8](repeating: 0, count: max(64, bytes.count + bytes.count / 2 + 64))
    let capacity = output.count
    let written: Int = output.withUnsafeMutableBytes { destination in
        bytes.withUnsafeBytes { source in
            stream.next_in = UnsafeMutablePointer<Bytef>(
                mutating: source.baseAddress!.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uInt(bytes.count)
            stream.next_out = destination.baseAddress!.assumingMemoryBound(to: Bytef.self)
            stream.avail_out = uInt(capacity)
            _ = deflate(&stream, Z_FINISH)
            return Int(stream.total_out)
        }
    }
    deflateEnd(&stream)
    precondition(written > 0)
    return Array(output.prefix(written))
}
#endif

private func fixtureZip(_ entries: [ZipEntrySpec]) -> Data {
    func appendUInt16(_ value: UInt16, to array: inout [UInt8]) {
        array.append(UInt8(value & 0xff))
        array.append(UInt8(value >> 8))
    }
    func appendUInt32(_ value: UInt32, to array: inout [UInt8]) {
        for shift in [0, 8, 16, 24] {
            array.append(UInt8((value >> shift) & 0xff))
        }
    }
    var output: [UInt8] = []
    var central: [UInt8] = []
    for entry in entries {
        let crc = entry.crcOverride ?? fixtureCRC32(entry.data)
        let stored: [UInt8]
        let method: UInt16
        if entry.method == 8 {
            stored = fixtureDeflate(entry.data)
            method = 8
        } else {
            stored = entry.data
            method = 0
        }
        let declared = UInt32(entry.declaredSize ?? entry.data.count)
        let flags = entry.flagsOverride ?? (entry.usesDataDescriptor ? 0x0008 : 0)
        let localOffset = UInt32(output.count)

        appendUInt32(0x0403_4b50, to: &output) // local file header
        appendUInt16(20, to: &output) // version needed
        appendUInt16(flags, to: &output)
        appendUInt16(method, to: &output)
        appendUInt16(0, to: &output) // modification time
        appendUInt16(0, to: &output) // modification date
        appendUInt32(entry.usesDataDescriptor ? 0 : crc, to: &output)
        appendUInt32(entry.usesDataDescriptor ? 0 : UInt32(stored.count), to: &output)
        appendUInt32(entry.usesDataDescriptor ? 0 : declared, to: &output)
        appendUInt16(UInt16(entry.name.utf8.count), to: &output)
        appendUInt16(0, to: &output) // extra length
        output.append(contentsOf: entry.name.utf8)
        output.append(contentsOf: stored)
        if entry.usesDataDescriptor {
            appendUInt32(0x0807_4b50, to: &output) // data descriptor signature
            appendUInt32(crc, to: &output)
            appendUInt32(UInt32(stored.count), to: &output)
            appendUInt32(declared, to: &output)
        }

        appendUInt32(0x0201_4b50, to: &central) // central directory entry
        appendUInt16(20, to: &central) // version made by
        appendUInt16(20, to: &central) // version needed
        appendUInt16(flags, to: &central)
        appendUInt16(method, to: &central)
        appendUInt16(0, to: &central) // modification time
        appendUInt16(0, to: &central) // modification date
        appendUInt32(crc, to: &central)
        appendUInt32(UInt32(stored.count), to: &central)
        appendUInt32(declared, to: &central)
        appendUInt16(UInt16(entry.name.utf8.count), to: &central)
        appendUInt16(0, to: &central) // extra length
        appendUInt16(0, to: &central) // comment length
        appendUInt16(0, to: &central) // disk number
        appendUInt16(0, to: &central) // internal attributes
        appendUInt32(0, to: &central) // external attributes
        appendUInt32(localOffset, to: &central)
        central.append(contentsOf: entry.name.utf8)
    }
    let directoryOffset = UInt32(output.count)
    output.append(contentsOf: central)
    appendUInt32(0x0605_4b50, to: &output) // end of central directory
    appendUInt16(0, to: &output) // disk number
    appendUInt16(0, to: &output) // central directory disk
    appendUInt16(UInt16(entries.count), to: &output)
    appendUInt16(UInt16(entries.count), to: &output)
    appendUInt32(UInt32(central.count), to: &output)
    appendUInt32(directoryOffset, to: &output)
    appendUInt16(0, to: &output) // comment length
    return Data(output)
}

private let fixtureWordNamespace =
    "http://schemas.openxmlformats.org/wordprocessingml/2006/main"

private func fixtureDocumentXML(paragraphs: [String]) -> String {
    let body = paragraphs
        .map { "<w:p><w:r><w:t xml:space=\"preserve\">\($0)</w:t></w:r></w:p>" }
        .joined()
    return #"<?xml version="1.0" encoding="UTF-8" standalone="yes"?>"#
        + "<w:document xmlns:w=\"\(fixtureWordNamespace)\">"
        + "<w:body>\(body)</w:body></w:document>"
}

private func makeDOCX(paragraphs: [String], method: UInt16) -> Data {
    fixtureZip([
        ZipEntrySpec(
            name: "[Content_Types].xml",
            data: Array("<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\"/>".utf8),
            method: 0
        ),
        ZipEntrySpec(
            name: "word/document.xml",
            data: Array(fixtureDocumentXML(paragraphs: paragraphs).utf8),
            method: method
        ),
    ])
}

// MARK: - Suite

@Suite("Bounded PDF and DOCX attachment text extraction")
struct FloeMacDocumentTextTests {

    // MARK: PDF

    @Test("Text-layer PDF yields its page text within the budget")
    func pdfTextLayerExtracts() throws {
        let root = try makeDocumentTextRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("text.pdf")
        try renderPDF(at: url, lines: ["Floe Mac PDF fixture", "second readable line"])
        let pdf = try Data(contentsOf: url)
        let text = try FloeMacDocumentText.extract(pdf, type: .pdf, limit: 10_000)
        #expect(text.contains("Floe Mac PDF fixture"))
        #expect(text.contains("second readable line"))
        #expect(text.count <= 10_000)
    }

    @Test("PDF extraction throws limitExceeded when the budget is smaller than the text")
    func pdfHonorsLimit() throws {
        let root = try makeDocumentTextRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("limited.pdf")
        try renderPDF(at: url, lines: ["A reasonably long PDF line for the limit test"])
        let pdf = try Data(contentsOf: url)
        #expect(throws: FloeMacDocumentTextError.limitExceeded) {
            _ = try FloeMacDocumentText.extract(pdf, type: .pdf, limit: 10)
        }
    }

    @Test("Scanned (text-less) PDF reports no readable text")
    func pdfScannedHasNoText() throws {
        let root = try makeDocumentTextRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("scanned.pdf")
        try renderPDF(at: url, lines: [])
        let pdf = try Data(contentsOf: url)
        #expect(throws: FloeMacDocumentTextError.noReadableText) {
            _ = try FloeMacDocumentText.extract(pdf, type: .pdf, limit: 10_000)
        }
    }

    @Test("Password-protected PDF reports no readable text")
    func pdfEncryptedHasNoText() throws {
        let root = try makeDocumentTextRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("encrypted.pdf")
        try renderPDF(
            at: url,
            lines: ["secret fixture line"],
            password: "fixture-password"
        )
        let pdf = try Data(contentsOf: url)
        #expect(throws: FloeMacDocumentTextError.noReadableText) {
            _ = try FloeMacDocumentText.extract(pdf, type: .pdf, limit: 10_000)
        }
    }

    @Test("Malformed and wrong-magic PDF bytes are malformed")
    func pdfMalformedThrows() throws {
        #expect(throws: FloeMacDocumentTextError.malformedDocument) {
            _ = try FloeMacDocumentText.extract(
                Data("%PDF-1.4\nnot a real cross-reference".utf8),
                type: .pdf,
                limit: 10_000
            )
        }
        #expect(throws: FloeMacDocumentTextError.malformedDocument) {
            _ = try FloeMacDocumentText.extract(
                Data("plain text, not a pdf".utf8),
                type: .pdf,
                limit: 10_000
            )
        }
    }

    // MARK: DOCX

    @Test("Stored DOCX extracts paragraph text in order")
    func docxStoredExtracts() throws {
        let docx = makeDOCX(paragraphs: ["First paragraph", "Second paragraph"], method: 0)
        let text = try FloeMacDocumentText.extract(docx, type: .docx, limit: 10_000)
        #expect(text == "First paragraph\nSecond paragraph")
    }

    @Test("Deflated DOCX extracts paragraph text including non-ASCII")
    func docxDeflatedExtracts() throws {
        let docx = makeDOCX(paragraphs: ["Floe 文档 fixture", "tail line"], method: 8)
        let text = try FloeMacDocumentText.extract(docx, type: .docx, limit: 10_000)
        #expect(text.contains("Floe 文档 fixture"))
        #expect(text.hasSuffix("tail line"))
    }

    @Test("Data-descriptor DOCX (streaming writer form) extracts")
    func docxDataDescriptorExtracts() throws {
        let xml = fixtureDocumentXML(paragraphs: ["streamed paragraph"])
        let docx = fixtureZip([
            ZipEntrySpec(
                name: "word/document.xml",
                data: Array(xml.utf8),
                method: 8,
                usesDataDescriptor: true
            ),
        ])
        let text = try FloeMacDocumentText.extract(docx, type: .docx, limit: 10_000)
        #expect(text == "streamed paragraph")
    }

    @Test("DOCX honors an exact character budget and rejects one less")
    func docxHonorsLimit() throws {
        let docx = makeDOCX(paragraphs: ["First", "Second"], method: 8)
        // Joined text is exactly "First\nSecond" (12 characters).
        let exact = try FloeMacDocumentText.extract(docx, type: .docx, limit: 12)
        #expect(exact == "First\nSecond")
        #expect(throws: FloeMacDocumentTextError.limitExceeded) {
            _ = try FloeMacDocumentText.extract(docx, type: .docx, limit: 11)
        }
    }

    @Test("DOCX without a word/document.xml member is malformed")
    func docxMissingMemberThrows() throws {
        let docx = fixtureZip([
            ZipEntrySpec(
                name: "[Content_Types].xml",
                data: Array("<Types/>".utf8),
                method: 0
            ),
        ])
        #expect(throws: FloeMacDocumentTextError.malformedDocument) {
            _ = try FloeMacDocumentText.extract(docx, type: .docx, limit: 10_000)
        }
    }

    @Test("DOCX with a DOCTYPE or entity declaration is refused")
    func docxExternalEntitiesRejected() throws {
        let xml = #"<?xml version="1.0"?>"#
            + "<w:document xmlns:w=\"\(fixtureWordNamespace)\"><w:body><w:p><w:r>"
            + "<w:t>&xxe;</w:t></w:r></w:p></w:body></w:document>"
        let docx = fixtureZip([
            ZipEntrySpec(name: "word/document.xml", data: Array(xml.utf8), method: 0),
        ])
        #expect(throws: FloeMacDocumentTextError.malformedDocument) {
            _ = try FloeMacDocumentText.extract(docx, type: .docx, limit: 10_000)
        }
    }

    @Test("DOCX whose declared member size breaks the expansion caps is oversized")
    func docxZipBombRejected() throws {
        let xml = fixtureDocumentXML(paragraphs: ["tiny real payload"])
        var spec = ZipEntrySpec(
            name: "word/document.xml",
            data: Array(xml.utf8),
            method: 8
        )
        spec.declaredSize = 512 * 1_024 * 1_024
        let docx = fixtureZip([spec])
        #expect(throws: FloeMacDocumentTextError.oversizedDocument) {
            _ = try FloeMacDocumentText.extract(docx, type: .docx, limit: 10_000)
        }
    }

    @Test("DOCX with duplicate word/document.xml members is malformed")
    func docxDuplicateMemberThrows() throws {
        let xml = fixtureDocumentXML(paragraphs: ["one"])
        let docx = fixtureZip([
            ZipEntrySpec(name: "word/document.xml", data: Array(xml.utf8), method: 0),
            ZipEntrySpec(name: "word/document.xml", data: Array(xml.utf8), method: 0),
        ])
        #expect(throws: FloeMacDocumentTextError.malformedDocument) {
            _ = try FloeMacDocumentText.extract(docx, type: .docx, limit: 10_000)
        }
    }

    @Test("DOCX with an encrypted member is refused")
    func docxEncryptedMemberRejected() throws {
        let xml = fixtureDocumentXML(paragraphs: ["one"])
        var spec = ZipEntrySpec(
            name: "word/document.xml",
            data: Array(xml.utf8),
            method: 0
        )
        spec.flagsOverride = 0x0001
        let docx = fixtureZip([spec])
        #expect(throws: FloeMacDocumentTextError.malformedDocument) {
            _ = try FloeMacDocumentText.extract(docx, type: .docx, limit: 10_000)
        }
    }

    @Test("DOCX with a traversal member name is refused")
    func docxTraversalMemberRejected() throws {
        let xml = fixtureDocumentXML(paragraphs: ["one"])
        let docx = fixtureZip([
            ZipEntrySpec(name: "../word/document.xml", data: Array(xml.utf8), method: 0),
        ])
        #expect(throws: FloeMacDocumentTextError.malformedDocument) {
            _ = try FloeMacDocumentText.extract(docx, type: .docx, limit: 10_000)
        }
    }

    @Test("DOCX with a CRC mismatch is malformed")
    func docxCRCMismatchRejected() throws {
        let xml = fixtureDocumentXML(paragraphs: ["corrupt me"])
        var spec = ZipEntrySpec(
            name: "word/document.xml",
            data: Array(xml.utf8),
            method: 0
        )
        spec.crcOverride = 0xdead_beef
        let docx = fixtureZip([spec])
        #expect(throws: FloeMacDocumentTextError.malformedDocument) {
            _ = try FloeMacDocumentText.extract(docx, type: .docx, limit: 10_000)
        }
    }

    @Test("DOCX whose body has no text runs reports no readable text")
    func docxEmptyBodyHasNoText() throws {
        let xml = "<w:document xmlns:w=\"\(fixtureWordNamespace)\"><w:body></w:body></w:document>"
        let docx = fixtureZip([
            ZipEntrySpec(name: "word/document.xml", data: Array(xml.utf8), method: 0),
        ])
        #expect(throws: FloeMacDocumentTextError.noReadableText) {
            _ = try FloeMacDocumentText.extract(docx, type: .docx, limit: 10_000)
        }
    }

    @Test("DOCX capturing CDATA text runs")
    func docxCapturesCDATA() throws {
        let xml = #"<?xml version="1.0"?>"#
            + "<w:document xmlns:w=\"\(fixtureWordNamespace)\"><w:body><w:p><w:r>"
            + "<w:t><![CDATA[cdata fixture text]]></w:t></w:r></w:p></w:body></w:document>"
        let docx = fixtureZip([
            ZipEntrySpec(name: "word/document.xml", data: Array(xml.utf8), method: 0),
        ])
        let text = try FloeMacDocumentText.extract(docx, type: .docx, limit: 10_000)
        #expect(text == "cdata fixture text")
    }

    @Test("Non-positive extraction budget is invalid for both kinds")
    func invalidLimitThrows() throws {
        #expect(throws: FloeMacDocumentTextError.invalidLimit) {
            _ = try FloeMacDocumentText.extract(Data("x".utf8), type: .docx, limit: 0)
        }
        #expect(throws: FloeMacDocumentTextError.invalidLimit) {
            _ = try FloeMacDocumentText.extract(Data("%PDF-".utf8), type: .pdf, limit: -1)
        }
    }

    @Test("Truncated DOCX bytes are malformed")
    func docxMalformedThrows() throws {
        let full = makeDOCX(paragraphs: ["hello"], method: 8)
        let truncated = full.prefix(24)
        #expect(throws: FloeMacDocumentTextError.malformedDocument) {
            _ = try FloeMacDocumentText.extract(Data(truncated), type: .docx, limit: 10_000)
        }
        #expect(throws: FloeMacDocumentTextError.malformedDocument) {
            _ = try FloeMacDocumentText.extract(
                Data([0x50, 0x4b, 0x03, 0x04, 0, 0, 0, 0]),
                type: .docx,
                limit: 10_000
            )
        }
    }
}
