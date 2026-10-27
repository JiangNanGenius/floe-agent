// SPDX-License-Identifier: MPL-2.0
//
// G05-R2 Office AI (job-1db1a7a8d5da457a) — bounded OOXML package-structure
// verification performed INDEPENDENTLY by the Swift runtime (it never trusts
// a host claim of "it is a real package"). A ZIP central directory parse only:
// no inflate, no allocation growth beyond bounded reads, no symlink or
// traversal semantics (this validates the FILE, then the store owns the copy).
//
// Honest scope: this proves container structure (magic, entry presence,
// recorded sizes/CRCs, no encrypted entries, sane entry count/names). It does
// NOT claim content correctness — the owned semantic facts come from the host
// OOXML inspection over the ACTUAL saved bytes. Both layers must pass before
// any tool success.

import Foundation

public struct OfficeAIZipEntry: Sendable, Equatable {
    public let name: String
    public let method: UInt16
    public let crc32: UInt32
    public let uncompressedSize: Int64
    public let compressedSize: Int64
    public let flags: UInt16
}

public enum OfficeAIPackageStructure {

    public enum Failure: Error, Equatable, Sendable {
        case unreadable
        case notRegularFile
        case tooSmall
        case tooLarge
        case missingEndOfCentralDirectory
        case centralDirectoryOutOfRange
        case entryLimitExceeded
        case malformedEntry
        case encryptedEntries
        case unsupportedCompression
    }

    /// Local file header magic `PK\u{03}\u{04}` (OOXML/ODF ZIP container).
    static let localMagic: [UInt8] = [0x50, 0x4B, 0x03, 0x04]

    /// Read the whole file with a hard cap (OOXML documents here are bounded
    /// by the engine export caps; a bigger file is an honest refusal).
    public static let maximumPackageBytes: Int64 = 256 * 1_024 * 1_024
    static let maximumEntries = 4096
    static let maximumNameBytes = 1024
    /// EOCD signature 0x06054b50 (LE bytes: 50 4B 05 06).
    static let eocd: [UInt8] = [0x50, 0x4B, 0x05, 0x06]

    /// Verify the magic bytes at the start of the file (streamed, tiny).
    public static func hasZipMagic(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 4), head.count == 4 else { return false }
        return [UInt8](head) == localMagic
    }

    /// Parse the central directory of one saved package.
    public static func readCentralDirectory(of url: URL,
                                            isCancelled: (() -> Bool)? = nil) throws
        -> [OfficeAIZipEntry] {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else { throw Failure.notRegularFile }
        let size = Int64(values.fileSize ?? 0)
        guard size > 22 else { throw Failure.tooSmall }
        guard size <= maximumPackageBytes else { throw Failure.tooLarge }
        guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            throw Failure.unreadable
        }
        let bytes = [UInt8](data)
        guard bytes.count == Int(size) else { throw Failure.unreadable }

        // Locate EOCD within the final bounded window (comment may be up to
        // 64 KiB - 1).
        let scanStart = max(0, bytes.count - (22 + 65_535))
        var eocdAt = -1
        var index = bytes.count - 22
        if index >= scanStart {
            while index >= scanStart {
                if bytes[index] == eocd[0], bytes[index + 1] == eocd[1],
                   bytes[index + 2] == eocd[2], bytes[index + 3] == eocd[3] {
                    // Validate the comment length matches the file end so a
                    // random byte sequence cannot pose as the directory.
                    let commentLen = Int(le16(bytes, index + 20))
                    if index + 22 + commentLen == bytes.count { eocdAt = index; break }
                }
                index -= 1
            }
        }
        guard eocdAt >= 0 else { throw Failure.missingEndOfCentralDirectory }
        let entryCount = Int(le16(bytes, eocdAt + 10))
        guard entryCount <= maximumEntries, entryCount >= 1 else {
            throw Failure.entryLimitExceeded
        }
        let cdOffset = Int(le32(bytes, eocdAt + 16))
        guard cdOffset >= 0, cdOffset + 46 <= bytes.count else {
            throw Failure.centralDirectoryOutOfRange
        }

        var entries: [OfficeAIZipEntry] = []
        entries.reserveCapacity(min(entryCount, 256))
        var cursor = cdOffset
        for _ in 0 ..< entryCount {
            try isCancelled.check()
            guard cursor + 46 <= bytes.count,
                  bytes[cursor] == 0x50, bytes[cursor + 1] == 0x4B,
                  bytes[cursor + 2] == 0x01, bytes[cursor + 3] == 0x02 else {
                throw Failure.malformedEntry
            }
            let flags = le16(bytes, cursor + 8)
            let method = le16(bytes, cursor + 10)
            let crc = le32(bytes, cursor + 16)
            let compressed = Int64(le32(bytes, cursor + 20))
            let uncompressed = Int64(le32(bytes, cursor + 24))
            let nameLen = Int(le16(bytes, cursor + 28))
            let extraLen = Int(le16(bytes, cursor + 30))
            let commentLen = Int(le16(bytes, cursor + 32))
            guard nameLen <= maximumNameBytes, nameLen >= 0,
                  cursor + 46 + nameLen <= bytes.count else {
                throw Failure.malformedEntry
            }
            let nameBytes = Array(bytes[(cursor + 46) ..< (cursor + 46 + nameLen)])
            guard let name = String(bytes: nameBytes, encoding: .utf8) else {
                throw Failure.malformedEntry
            }
            entries.append(OfficeAIZipEntry(name: name, method: method, crc32: crc,
                                            uncompressedSize: uncompressed,
                                            compressedSize: compressed, flags: flags))
            cursor += 46 + nameLen + extraLen + commentLen
            guard cursor <= bytes.count else { throw Failure.malformedEntry }
        }
        // Encrypted entries can never be verified as our saved content.
        if entries.contains(where: { $0.flags & 0x1 != 0 }) { throw Failure.encryptedEntries }
        // OOXML parts are deflate or stored only in practice.
        if entries.contains(where: { $0.method != 0 && $0.method != 8 }) {
            throw Failure.unsupportedCompression
        }
        return entries
    }

    /// Required parts per family (raw family token: "docx"|"xlsx"|"pptx" —
    /// deliberately a STRING so this file never depends on the JobTools
    /// contract types and stays testable inside FloeAndroidCoreTests): an
    /// OOXML package MUST carry these, plus `[Content_Types].xml` at root.
    public static func expectedParts(for family: String) -> [String]? {
        switch family.lowercased() {
        case "docx": return ["[Content_Types].xml", "_rels/.rels", "word/document.xml"]
        case "xlsx": return ["[Content_Types].xml", "_rels/.rels", "xl/workbook.xml"]
        case "pptx": return ["[Content_Types].xml", "_rels/.rels", "ppt/presentation.xml"]
        default: return nil
        }
    }

    /// Verify a saved export is structurally the expected family. Returns the
    /// entry list on success.
    public static func verifyPackage(url: URL, family: String,
                                     isCancelled: (() -> Bool)? = nil) throws
        -> [OfficeAIZipEntry] {
        guard let requiredParts = expectedParts(for: family) else { throw Failure.malformedEntry }
        guard hasZipMagic(url) else { throw Failure.missingEndOfCentralDirectory }
        let entries = try readCentralDirectory(of: url, isCancelled: isCancelled)
        let names = Set(entries.map(\.name))
        for required in requiredParts where !names.contains(required) {
            throw Failure.malformedEntry
        }
        // The family's payload parts must exist beyond the package skeleton.
        let payloadPrefix: String
        switch family.lowercased() {
        case "docx": payloadPrefix = "word/document.xml"
        case "xlsx": payloadPrefix = "xl/worksheets/"
        case "pptx": payloadPrefix = "ppt/slides/slide"
        default: throw Failure.malformedEntry
        }
        guard entries.contains(where: { $0.name.hasPrefix(payloadPrefix) }) else {
            throw Failure.malformedEntry
        }
        return entries
    }

    // MARK: little-endian scanners

    private static func le16(_ bytes: [UInt8], _ at: Int) -> UInt16 {
        UInt16(bytes[at]) | (UInt16(bytes[at + 1]) << 8)
    }

    private static func le32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        UInt32(bytes[at]) | (UInt32(bytes[at + 1]) << 8)
            | (UInt32(bytes[at + 2]) << 16) | (UInt32(bytes[at + 3]) << 24)
    }
}

private extension (() -> Bool)? {
    func check() throws {
        if self?() == true { throw OfficeAIPackageStructure.Failure.unreadable }
    }
}
