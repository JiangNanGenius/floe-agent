// SPDX-License-Identifier: MPL-2.0
//
// Bounded plain-text extraction for PDF and Word document attachment bytes.
// This is an internal helper for the Mac self-core composition: the host
// stages picked attachment bytes (already size-capped by the caller) and this
// helper returns bounded, non-empty readable text or throws. It never grants
// tools, never persists, never leaves the process, and never invents text for
// scanned, encrypted, malformed or oversized input.
//
// Constraints followed from the existing repository:
// * PDF work is serialized through the shared public `FloeCore.PDFKitGate`
//   (PDFKit is not thread-safe) and is read-only; locked, non-copying,
//   page-count-out-of-range or text-less documents fail closed instead of
//   being OCR-guessed or truncated silently.
// * DOCX is read as a bounded ZIP package: the central directory is parsed
//   with entry-count, member-size, total-expansion and ratio caps before any
//   allocation; only `word/document.xml` is decoded (stored or raw-DEFLATE
//   through the bundled system zlib, with CRC-32 verification); the XML is
//   parsed with Foundation's pull parser, external entities disabled, DTD and
//   entity declarations refused, mirroring the bounded OOXML reader.
// * No new dependency is added; only Foundation, PDFKit (through the shared
//   gate) and the OS-bundled zlib module are used.

import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import FloeCore
#if canImport(PDFKit)
import PDFKit
#endif
#if canImport(zlib)
import zlib
#endif

/// Wordprocessingml main namespace; real Word parts carry this URI on every
/// `w:p`/`w:t` element once namespace processing is enabled.
private let documentWordNamespace =
    "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
/// Element and depth ceilings for the bounded XML pull parse, mirroring the
/// repository's bounded OOXML reader.
private let maximumDocumentXMLElementCount = 200_000
private let maximumDocumentXMLDepth = 128

/// Fail-closed rejection reasons for bounded document text extraction.
/// `code` is a stable machine label for redacted host diagnostics.
public enum FloeMacDocumentTextError: String, Error, Sendable, Hashable {
    /// The caller supplied a non-positive character budget.
    case invalidLimit
    /// The bytes are not the requested format, are truncated, corrupt,
    /// refuse decoding, or carry an unsafe package member or XML prolog.
    case malformedDocument
    /// The document is well-formed but carries no readable text layer
    /// (scanned/raster pages, encrypted without an empty user password,
    /// or a Word body without text runs).
    case noReadableText
    /// A member or the package exceeds the bounded expansion caps.
    case oversizedDocument
    /// Extracted text exceeds the caller's character budget.
    case limitExceeded

    public var code: String { rawValue }
}

extension FloeMacDocumentTextError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidLimit:
            return "The text extraction budget must be positive."
        case .malformedDocument:
            return "The document bytes are malformed or use an unsafe package feature."
        case .noReadableText:
            return "The document has no readable text layer."
        case .oversizedDocument:
            return "The document expands beyond the bounded extraction limits."
        case .limitExceeded:
            return "The extracted text exceeds the requested character budget."
        }
    }
}

/// Bounded text extraction for one verified attachment.
public enum FloeMacDocumentText {
    public enum Kind: String, Sendable, Hashable {
        case pdf
        case docx
    }

    /// Returns the trimmed, non-empty text of `bytes`, never exceeding
    /// `limit` characters. The caller has already capped the input size;
    /// this helper additionally bounds archive expansion, parsing work and
    /// output. Throws `FloeMacDocumentTextError` on every failure path.
    public static func extract(_ bytes: Data, type: Kind, limit: Int) throws -> String {
        guard limit > 0 else { throw FloeMacDocumentTextError.invalidLimit }
        let text: String
        switch type {
        case .pdf:
            text = try extractPDFText(bytes, limit: limit)
        case .docx:
            text = try extractDOCXText(bytes, limit: limit)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FloeMacDocumentTextError.noReadableText }
        return trimmed
    }

    // MARK: - PDF

    /// Same page ceiling the existing conversion/export paths accept.
    private static let maximumPDFPages = 500

    private static func extractPDFText(_ bytes: Data, limit: Int) throws -> String {
        guard bytes.starts(with: Data("%PDF-".utf8)) else {
            throw FloeMacDocumentTextError.malformedDocument
        }
        #if canImport(PDFKit)
        // Every PDFKit object stays inside the shared serialized gate; only
        // plain value text leaves it. Extraction is read-only: no mutation,
        // no serialization, no OCR fallback for text-less pages. Password
        // protection, copying refusal and malformed input fail closed.
        return try PDFKitGate.run {
            guard let pdf = PDFDocument(data: bytes) else {
                throw FloeMacDocumentTextError.malformedDocument
            }
            if pdf.isEncrypted {
                // Only a document openable with the empty user password is
                // readable here; password-protected input stays unreadable.
                guard pdf.unlock(withPassword: "") else {
                    throw FloeMacDocumentTextError.noReadableText
                }
            }
            guard !pdf.isLocked, pdf.allowsCopying,
                  pdf.pageCount > 0, pdf.pageCount <= maximumPDFPages else {
                throw FloeMacDocumentTextError.noReadableText
            }
            var parts: [String] = []
            var characters = 0
            for index in 0..<pdf.pageCount {
                guard let page = pdf.page(at: index) else { continue }
                let text = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { continue }
                characters += text.count + (parts.isEmpty ? 0 : 1)
                guard characters <= limit else {
                    throw FloeMacDocumentTextError.limitExceeded
                }
                parts.append(text)
            }
            return parts.joined(separator: "\n")
        }
        #else
        throw FloeMacDocumentTextError.noReadableText
        #endif
    }

    // MARK: - DOCX (ZIP container + wordprocessingml text)

    private static let wantedMember = "word/document.xml"
    private static let maximumArchiveEntries = 256
    private static let maximumMemberBytes = 16 * 1_024 * 1_024
    private static let maximumTotalExpandedBytes = 32 * 1_024 * 1_024
    /// Refuse members whose declared expansion is more than ~1032x the
    /// stored bytes plus slack; the same family of ratio the archive codecs
    /// use against gzip bombs. Stored members must match exactly.
    private static let maximumMemberExpansionRatio: UInt64 = 1_032
    private static let endOfCentralDirectoryLength = 22
    private static let endOfCentralDirectorySearchWindow = 65_536 + 22

    // General-purpose flag bits (PKWARE APPNOTE 4.4.4).
    private static let zipFlagEncrypted: UInt16 = 0x0001
    private static let zipFlagDataDescriptor: UInt16 = 0x0008
    private static let zipFlagStrongEncryption: UInt16 = 0x0040

    private static func extractDOCXText(_ bytes: Data, limit: Int) throws -> String {
        guard bytes.count >= endOfCentralDirectoryLength,
              bytes.starts(with: [0x50, 0x4b]) else {
            throw FloeMacDocumentTextError.malformedDocument
        }
        let member = try zipMember(named: wantedMember, in: [UInt8](bytes))
        guard let xml = String(data: member, encoding: .utf8) else {
            throw FloeMacDocumentTextError.malformedDocument
        }
        return try wordText(fromXML: xml, limit: limit)
    }

    // MARK: ZIP reader

    private struct ZipCentralDirectory {
        let offset: Int
        let entries: Int
    }

    private struct ZipCursor {
        let bytes: [UInt8]
        var offset: Int

        mutating func readUInt16() throws -> UInt16 {
            guard offset + 2 <= bytes.count else {
                throw FloeMacDocumentTextError.malformedDocument
            }
            let value = UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
            offset += 2
            return value
        }

        mutating func readUInt32() throws -> UInt32 {
            guard offset + 4 <= bytes.count else {
                throw FloeMacDocumentTextError.malformedDocument
            }
            let value = UInt32(bytes[offset])
                | (UInt32(bytes[offset + 1]) << 8)
                | (UInt32(bytes[offset + 2]) << 16)
                | (UInt32(bytes[offset + 3]) << 24)
            offset += 4
            return value
        }

        mutating func skip(_ count: Int) throws {
            guard count >= 0, offset + count <= bytes.count else {
                throw FloeMacDocumentTextError.malformedDocument
            }
            offset += count
        }

        mutating func readBytes(_ count: Int) throws -> ArraySlice<UInt8> {
            guard count >= 0, offset + count <= bytes.count else {
                throw FloeMacDocumentTextError.malformedDocument
            }
            defer { offset += count }
            return bytes[offset..<(offset + count)]
        }
    }

    /// Locates the single-spool end-of-central-directory record. Multi-disk
    /// archives and archives with a spanned signature are refused.
    private static func centralDirectory(in bytes: [UInt8]) throws -> ZipCentralDirectory {
        guard bytes.count >= endOfCentralDirectoryLength else {
            throw FloeMacDocumentTextError.malformedDocument
        }
        let searchStart = max(0, bytes.count - endOfCentralDirectorySearchWindow)
        var position = bytes.count - endOfCentralDirectoryLength
        while position >= searchStart {
            if bytes[position] == 0x50, bytes[position + 1] == 0x4b,
               bytes[position + 2] == 0x05, bytes[position + 3] == 0x06 {
                do {
                    var cursor = ZipCursor(bytes: bytes, offset: position + 4)
                    let disk = try cursor.readUInt16()
                    let directoryDisk = try cursor.readUInt16()
                    let entriesOnDisk = try cursor.readUInt16()
                    let totalEntries = try cursor.readUInt16()
                    let directorySize = try cursor.readUInt32()
                    let directoryOffset = try cursor.readUInt32()
                    let commentLength = Int(try cursor.readUInt16())
                    guard disk == 0, directoryDisk == 0, entriesOnDisk == totalEntries,
                          totalEntries > 0, totalEntries <= maximumArchiveEntries,
                          position + endOfCentralDirectoryLength + commentLength <= bytes.count else {
                        position -= 1
                        continue
                    }
                    let directoryEnd = UInt64(directoryOffset) + UInt64(directorySize)
                    guard directoryEnd <= UInt64(bytes.count) else {
                        position -= 1
                        continue
                    }
                    return ZipCentralDirectory(
                        offset: Int(directoryOffset),
                        entries: Int(totalEntries)
                    )
                } catch {
                    position -= 1
                    continue
                }
            }
            position -= 1
        }
        throw FloeMacDocumentTextError.malformedDocument
    }

    /// Member names must be relative, single-link safe strings: no absolute
    /// paths, no backslashes, no parent traversal, no NULs.
    private static func validateMemberName(_ name: String) throws {
        guard !name.isEmpty,
              !name.hasPrefix("/"),
              !name.contains("\\"),
              !name.utf8.contains(0),
              !name.split(separator: "/").contains("..") else {
            throw FloeMacDocumentTextError.malformedDocument
        }
    }

    private static func zipMember(named wanted: String, in bytes: [UInt8]) throws -> Data {
        let directory = try centralDirectory(in: bytes)
        var chosen: (
            name: String, flags: UInt16, method: UInt16, crc: UInt32,
            compressedSize: UInt32, uncompressedSize: UInt32,
            localOffset: UInt32
        )?
        var totalExpanded: UInt64 = 0
        var cursor = ZipCursor(bytes: bytes, offset: directory.offset)
        for _ in 0..<directory.entries {
            guard try cursor.readUInt32() == 0x0201_4b50 else {
                throw FloeMacDocumentTextError.malformedDocument
            }
            _ = try cursor.readUInt16() // version made by
            _ = try cursor.readUInt16() // version needed
            let flags = try cursor.readUInt16()
            let method = try cursor.readUInt16()
            _ = try cursor.readUInt16() // modification time
            _ = try cursor.readUInt16() // modification date
            let crc = try cursor.readUInt32()
            let compressedSize = try cursor.readUInt32()
            let uncompressedSize = try cursor.readUInt32()
            let nameLength = Int(try cursor.readUInt16())
            let extraLength = Int(try cursor.readUInt16())
            let commentLength = Int(try cursor.readUInt16())
            _ = try cursor.readUInt16() // disk number
            _ = try cursor.readUInt16() // internal attributes
            _ = try cursor.readUInt32() // external attributes
            let localOffset = try cursor.readUInt32()
            let name = String(decoding: try cursor.readBytes(nameLength), as: UTF8.self)
            try cursor.skip(extraLength + commentLength)
            try validateMemberName(name)
            // Traditional and strong encryption, and patched-in compression
            // methods, are never decoded; the whole package fails closed.
            guard flags & zipFlagEncrypted == 0,
                  flags & zipFlagStrongEncryption == 0,
                  method == 0 || method == 8 else {
                throw FloeMacDocumentTextError.malformedDocument
            }

            let expanded = UInt64(uncompressedSize)
            totalExpanded += expanded
            guard expanded <= UInt64(maximumMemberBytes),
                  totalExpanded <= UInt64(maximumTotalExpandedBytes) else {
                throw FloeMacDocumentTextError.oversizedDocument
            }
            if method == 8 {
                // Bound work before allocating: a member that claims to
                // expand more than the ratio cap over its stored bytes is a
                // zip bomb and is refused before any inflate happens.
                guard expanded <= UInt64(compressedSize) * maximumMemberExpansionRatio + 1_024 else {
                    throw FloeMacDocumentTextError.oversizedDocument
                }
            }
            if name == wanted {
                guard chosen == nil else {
                    throw FloeMacDocumentTextError.malformedDocument
                }
                chosen = (name, flags, method, crc, compressedSize, uncompressedSize, localOffset)
            }
        }
        guard let entry = chosen else {
            throw FloeMacDocumentTextError.malformedDocument
        }
        // Slice the payload from the local file header. The local header's
        // name/extra lengths are authoritative for the stored byte range; its
        // method, flags, filename and local offset must agree with the
        // central entry. With the data-descriptor flag (bit 3) — the form
        // streaming writers, including real Word savers, emit — the local
        // CRC and sizes are zero and the central directory values are used;
        // the descriptor itself is never read.
        var local = ZipCursor(bytes: bytes, offset: Int(entry.localOffset))
        guard try local.readUInt32() == 0x0403_4b50 else {
            throw FloeMacDocumentTextError.malformedDocument
        }
        _ = try local.readUInt16() // version needed
        let localFlags = try local.readUInt16()
        let localMethod = try local.readUInt16()
        _ = try local.readUInt16() // modification time
        _ = try local.readUInt16() // modification date
        let localCRC = try local.readUInt32()
        let localCompressedSize = try local.readUInt32()
        let localUncompressedSize = try local.readUInt32()
        let localNameLength = Int(try local.readUInt16())
        let localExtraLength = Int(try local.readUInt16())
        let localName = String(decoding: try local.readBytes(localNameLength), as: UTF8.self)
        guard localName == entry.name,
              localMethod == entry.method,
              localFlags == entry.flags,
              localFlags & zipFlagEncrypted == 0 else {
            throw FloeMacDocumentTextError.malformedDocument
        }
        if entry.flags & zipFlagDataDescriptor == 0 {
            guard localCRC == entry.crc,
                  localCompressedSize == entry.compressedSize,
                  localUncompressedSize == entry.uncompressedSize else {
                throw FloeMacDocumentTextError.malformedDocument
            }
        }
        try local.skip(localExtraLength)
        let payload = try local.readBytes(Int(entry.compressedSize))

        switch entry.method {
        case 0:
            guard entry.uncompressedSize == payload.count,
                  zipCRC32(payload) == entry.crc else {
                throw FloeMacDocumentTextError.malformedDocument
            }
            return Data(payload)
        case 8:
            return try inflateRawDeflate(
                payload,
                expectedSize: Int(entry.uncompressedSize),
                crc: entry.crc
            )
        default:
            throw FloeMacDocumentTextError.malformedDocument
        }
    }

    // MARK: Inflate

    /// Raw-DEFLATE (RFC 1951, window bits -15) decode through the bundled
    /// system zlib. The output buffer is capped at the member's declared
    /// (already ratio- and size-bounded) size, the stream must end exactly
    /// after that many bytes, and the CRC-32 must match the directory entry.
    #if canImport(zlib)
    private static func inflateRawDeflate(
        _ bytes: ArraySlice<UInt8>,
        expectedSize: Int,
        crc: UInt32
    ) throws -> Data {
        guard expectedSize >= 0, expectedSize <= maximumMemberBytes else {
            throw FloeMacDocumentTextError.oversizedDocument
        }
        var stream = z_stream()
        guard inflateInit2_(&stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            throw FloeMacDocumentTextError.malformedDocument
        }
        // One byte of slack distinguishes "stream ended exactly" from
        // "stream still producing"; both are checked explicitly below.
        var output = [UInt8](repeating: 0, count: expectedSize + 1)
        let capacity = output.count
        let status: Int32 = bytes.withUnsafeBytes { source in
            output.withUnsafeMutableBytes { destination in
                guard let sourceAddress = source.baseAddress,
                      let destinationAddress = destination.baseAddress else { return Z_STREAM_ERROR }
                stream.next_in = UnsafeMutablePointer<Bytef>(
                    mutating: sourceAddress.assumingMemoryBound(to: Bytef.self))
                stream.avail_in = uInt(bytes.count)
                stream.next_out = destinationAddress.assumingMemoryBound(to: Bytef.self)
                stream.avail_out = uInt(capacity)
                return inflate(&stream, Z_FINISH)
            }
        }
        let produced = Int(stream.total_out)
        inflateEnd(&stream)
        guard status == Z_STREAM_END, produced == expectedSize else {
            throw FloeMacDocumentTextError.malformedDocument
        }
        let inflated = Array(output.prefix(produced))
        guard zipCRC32(inflated) == crc else {
            throw FloeMacDocumentTextError.malformedDocument
        }
        return Data(inflated)
    }
    #else
    private static func inflateRawDeflate(
        _ bytes: ArraySlice<UInt8>,
        expectedSize: Int,
        crc: UInt32
    ) throws -> Data {
        throw FloeMacDocumentTextError.malformedDocument
    }
    #endif

    // MARK: CRC-32 (ISO 3309, same polynomial the ZIP format uses)

    private static let crcTable: [UInt32] = (0..<256).map { value -> UInt32 in
        var crc = UInt32(value)
        for _ in 0..<8 {
            crc = (crc & 1) == 1 ? (crc >> 1) ^ 0xedb8_8320 : crc >> 1
        }
        return crc
    }

    private static func zipCRC32<S: Sequence>(_ bytes: S) -> UInt32 where S.Element == UInt8 {
        var crc: UInt32 = 0xffff_ffff
        for byte in bytes {
            crc = (crc >> 8) ^ crcTable[Int((crc ^ UInt32(byte)) & 0xff)]
        }
        return crc ^ 0xffff_ffff
    }

    // MARK: - WordprocessingML text

    private static func wordText(fromXML xml: String, limit: Int) throws -> String {
        guard xml.utf8.count <= maximumMemberBytes,
              !xml.contains("<!DOCTYPE"), !xml.contains("<!ENTITY") else {
            throw FloeMacDocumentTextError.malformedDocument
        }
        let reader = WordXMLReader(limit: limit)
        let parser = XMLParser(data: Data(xml.utf8))
        // Namespace-aware parsing with no DTD/entity resolution: real Word
        // parts carry the wordprocessingml namespace URI on every element,
        // and no external resource is ever loaded.
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = reader
        guard parser.parse(), !reader.invalid else {
            if reader.limitExceeded {
                throw FloeMacDocumentTextError.limitExceeded
            }
            throw FloeMacDocumentTextError.malformedDocument
        }
        var text = ""
        for paragraph in reader.paragraphs {
            let addition = paragraph.count + (text.isEmpty ? 0 : 1)
            guard addition <= limit - text.count else {
                throw FloeMacDocumentTextError.limitExceeded
            }
            if !text.isEmpty { text.append("\n") }
            text.append(paragraph)
        }
        return text
    }

    /// Pull-parser reader that keeps only `w:t` characters inside `w:p`
    /// paragraphs of the wordprocessingml namespace. Element count and depth
    /// are bounded exactly like the repository's bounded OOXML reader; text
    /// capture stops as soon as the caller's budget is exceeded.
    private final class WordXMLReader: NSObject, XMLParserDelegate {
        let limit: Int
        private(set) var paragraphs: [String] = []
        private(set) var invalid = false
        private(set) var limitExceeded = false
        private var elementCount = 0
        private var depth = 0
        private var paragraphDepth = 0
        private var capturingText = false
        private var paragraph = ""

        init(limit: Int) {
            self.limit = limit
        }

        func parser(
            _ parser: XMLParser,
            didStartElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?,
            attributes: [String: String]
        ) {
            elementCount += 1
            depth += 1
            guard elementCount <= maximumDocumentXMLElementCount,
                  depth <= maximumDocumentXMLDepth else {
                invalid = true
                parser.abortParsing()
                return
            }
            let local = localName(elementName, qName)
            guard matchesWordNamespace(namespaceURI, qName) else { return }
            switch local {
            case "p":
                paragraphDepth += 1
                paragraph = ""
            case "t":
                if paragraphDepth > 0 { capturingText = true }
            default:
                break
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard capturingText, !invalid else { return }
            append(string)
            if paragraph.count > limit {
                limitExceeded = true
                invalid = true
                parser.abortParsing()
            }
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard capturingText, !invalid else { return }
            guard let string = String(data: CDATABlock, encoding: .utf8) else {
                invalid = true
                parser.abortParsing()
                return
            }
            append(string)
            if paragraph.count > limit {
                limitExceeded = true
                invalid = true
                parser.abortParsing()
            }
        }

        private func append(_ string: String) {
            paragraph.append(string)
        }

        func parser(
            _ parser: XMLParser,
            didEndElement elementName: String,
            namespaceURI: String?,
            qualifiedName qName: String?
        ) {
            let local = localName(elementName, qName)
            if matchesWordNamespace(namespaceURI, qName) {
                switch local {
                case "t":
                    capturingText = false
                case "p":
                    paragraphDepth = max(0, paragraphDepth - 1)
                    if paragraphDepth == 0, !paragraph.isEmpty {
                        paragraphs.append(paragraph)
                        paragraph = ""
                    }
                default:
                    break
                }
            }
            depth -= 1
        }

        private func localName(_ elementName: String, _ qName: String?) -> String {
            // With shouldProcessNamespaces the parser reports the local name
            // in elementName (qName is nil); an unbound prefix arrives whole,
            // e.g. "w:t", so the split stays harmless in both modes.
            let qualified = qName ?? elementName
            let parts = qualified.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2 else { return qualified }
            return String(parts[1])
        }

        /// Word documents always declare the wordprocessingml namespace; an
        /// absent namespace URI only happens for hand-built fragments, where
        /// the local name alone is accepted leniently.
        private func matchesWordNamespace(_ namespaceURI: String?, _ qName: String?) -> Bool {
            if namespaceURI == documentWordNamespace { return true }
            return namespaceURI == nil
        }
    }
}
