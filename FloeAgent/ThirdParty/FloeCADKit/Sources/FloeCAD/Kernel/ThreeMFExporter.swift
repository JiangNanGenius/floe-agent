//
//  ThreeMFExporter.swift
//  openshape3d
//
//  Minimal valid 3MF: an OPC zip with [Content_Types].xml, _rels/.rels and
//  3D/3dmodel.model. No zip library is available on this target, so the file
//  also carries a minimal STORED-entry zip writer (no compression, CRC32 +
//  central directory). Transforms are baked; unit is millimeter per the
//  1 unit = 1 mm convention.
//

import Foundation
import simd

nonisolated enum ThreeMFExporter {

    static func threeMF(bodies: [Body]) -> Data {
        var zip = MinimalZipWriter()
        zip.addFile(path: "[Content_Types].xml", data: Data(contentTypesXML.utf8))
        zip.addFile(path: "_rels/.rels", data: Data(relsXML.utf8))
        zip.addFile(path: "3D/3dmodel.model", data: Data(modelXML(bodies: bodies).utf8))
        return zip.finish()
    }

    private static let contentTypesXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
    <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
    <Default Extension="model" ContentType="application/vnd.ms-package.3dmanufacturing-3dmodel+xml"/>
    </Types>
    """

    private static let relsXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
    <Relationship Id="rel0" Target="/3D/3dmodel.model" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
    </Relationships>
    """

    static func modelXML(bodies: [Body]) -> String {
        var out = """
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xml:lang="en-US" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
        <resources>
        """
        out += "\n"
        for (index, body) in bodies.enumerated() {
            let objectID = index + 1
            out += "<object id=\"\(objectID)\" type=\"model\">\n<mesh>\n<vertices>\n"
            let transform = body.transform
            for p in body.render.positions {
                let w = transform.applying(to: SIMD3<Double>(p))
                out += String(format: "<vertex x=\"%.6f\" y=\"%.6f\" z=\"%.6f\"/>\n", w.x, w.y, w.z)
            }
            out += "</vertices>\n<triangles>\n"
            let indices = body.render.indices
            var i = 0
            while i + 2 < indices.count {
                out += "<triangle v1=\"\(indices[i])\" v2=\"\(indices[i + 1])\" v3=\"\(indices[i + 2])\"/>\n"
                i += 3
            }
            out += "</triangles>\n</mesh>\n</object>\n"
        }
        out += "</resources>\n<build>\n"
        for index in bodies.indices {
            out += "<item objectid=\"\(index + 1)\"/>\n"
        }
        out += "</build>\n</model>\n"
        return out
    }
}

/// Minimal zip writer emitting STORED (uncompressed) entries with correct
/// CRC32 values and a central directory. Sufficient for OPC consumers.
nonisolated struct MinimalZipWriter {

    private struct Entry {
        let name: [UInt8]
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    private var data = Data()
    private var entries = [Entry]()

    mutating func addFile(path: String, data fileData: Data) {
        let name = Array(path.utf8)
        let crc = Self.crc32(fileData)
        let size = UInt32(fileData.count)
        let entry = Entry(name: name, crc: crc, size: size, offset: UInt32(data.count))
        entries.append(entry)

        appendU32(0x0403_4B50)        // local file header signature
        appendU16(20)                 // version needed
        appendU16(0)                  // flags
        appendU16(0)                  // method: STORED
        appendU16(0)                  // mod time
        appendU16(0x21)               // mod date (1980-01-01)
        appendU32(crc)
        appendU32(size)               // compressed size == size (stored)
        appendU32(size)
        appendU16(UInt16(name.count))
        appendU16(0)                  // extra length
        data.append(contentsOf: name)
        data.append(fileData)
    }

    mutating func finish() -> Data {
        let centralOffset = UInt32(data.count)
        for entry in entries {
            appendU32(0x0201_4B50)    // central directory header signature
            appendU16(20)             // version made by
            appendU16(20)             // version needed
            appendU16(0)              // flags
            appendU16(0)              // method
            appendU16(0)              // mod time
            appendU16(0x21)           // mod date
            appendU32(entry.crc)
            appendU32(entry.size)
            appendU32(entry.size)
            appendU16(UInt16(entry.name.count))
            appendU16(0)              // extra length
            appendU16(0)              // comment length
            appendU16(0)              // disk number
            appendU16(0)              // internal attributes
            appendU32(0)              // external attributes
            appendU32(entry.offset)
            data.append(contentsOf: entry.name)
        }
        let centralSize = UInt32(data.count) - centralOffset
        appendU32(0x0605_4B50)        // end of central directory signature
        appendU16(0)                  // disk number
        appendU16(0)                  // central directory disk
        appendU16(UInt16(entries.count))
        appendU16(UInt16(entries.count))
        appendU32(centralSize)
        appendU32(centralOffset)
        appendU16(0)                  // comment length
        return data
    }

    private mutating func appendU16(_ value: UInt16) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private mutating func appendU32(_ value: UInt32) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    /// Standard CRC-32 (IEEE 802.3, reflected, poly 0xEDB88320).
    static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1)))
            }
        }
        return ~crc
    }
}

/// Streaming counterpart to `MinimalZipWriter` for a produced file that must
/// not be accumulated in memory (a real PNG frame-sequence bundle). It emits
/// the SAME STORED entries and central directory, reuses the canonical CRC-32,
/// and keeps only one file's bytes resident at a time. The caller still owns
/// the output byte bound and verification.
nonisolated final class MinimalZipFileWriter {
    private struct Entry {
        let name: [UInt8]
        let crc: UInt32
        let size: UInt32
        let offset: UInt32
    }

    private let handle: FileHandle
    private var entries: [Entry] = []
    private var offset: UInt64 = 0
    private var isClosed = false

    init(url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        handle = try FileHandle(forWritingTo: url)
    }

    deinit {
        if !isClosed { try? handle.close() }
    }

    /// Add one STORED entry from bytes the caller already holds.
    func addFile(path: String, data fileData: Data) throws {
        guard entries.count < Int(UInt16.max) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard offset <= UInt64(UInt32.max),
              UInt64(fileData.count) <= UInt64(UInt32.max) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let name = Array(path.utf8)
        guard name.count <= Int(UInt16.max) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let crc = MinimalZipWriter.crc32(fileData)
        let size = UInt32(fileData.count)
        let entry = Entry(name: name, crc: crc, size: size,
                          offset: UInt32(offset))
        var header = Data()
        appendU32(0x0403_4B50, to: &header)  // local file header signature
        appendU16(20, to: &header)           // version needed
        appendU16(0, to: &header)            // flags
        appendU16(0, to: &header)            // method: STORED
        appendU16(0, to: &header)            // mod time
        appendU16(0x21, to: &header)         // mod date (1980-01-01)
        appendU32(crc, to: &header)
        appendU32(size, to: &header)         // compressed size
        appendU32(size, to: &header)         // uncompressed size
        appendU16(UInt16(name.count), to: &header)
        appendU16(0, to: &header)            // extra length
        header.append(contentsOf: name)
        try write(header)
        try write(fileData)
        entries.append(entry)
    }

    /// Add one entry directly from a staged file. Only this one file is read
    /// into memory at a time.
    func addFile(path: String, contentsOf url: URL) throws {
        try addFile(path: path, data: try Data(contentsOf: url))
    }

    /// Add one entry directly from a staged file in BOUNDED chunks, verifying
    /// the declared size/CRC against the exact bytes written. The caller's
    /// `onChunk` runs before each write, which is where an off-main finalizer
    /// checks cancellation and, when needed, re-computes the file digest. A
    /// throw abandons the archive (the caller removes staging); this method is
    /// never used to publish a partial entry.
    func addFile(
        path: String,
        expectedSize: UInt32,
        expectedCRC: UInt32,
        contentsOf url: URL,
        chunkSize: Int = 64 * 1024,
        onChunk: (Data) throws -> Void = { _ in }
    ) throws {
        guard chunkSize > 0 else { throw CocoaError(.fileReadUnknown) }
        guard entries.count < Int(UInt16.max) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let name = Array(path.utf8)
        guard name.count <= Int(UInt16.max) else {
            throw CocoaError(.fileWriteUnknown)
        }
        // The central directory stores 32-bit offsets: refuse to begin an entry
        // that could overflow the format instead of trapping in finish().
        guard offset <= UInt64(UInt32.max),
              UInt64(expectedSize) <= UInt64(UInt32.max),
              offset + UInt64(expectedSize) <= UInt64(UInt32.max) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let entry = Entry(name: name, crc: expectedCRC, size: expectedSize,
                          offset: UInt32(offset))
        var header = Data()
        appendU32(0x0403_4B50, to: &header)  // local file header signature
        appendU16(20, to: &header)           // version needed
        appendU16(0, to: &header)            // flags
        appendU16(0, to: &header)            // method: STORED
        appendU16(0, to: &header)            // mod time
        appendU16(0x21, to: &header)         // mod date (1980-01-01)
        appendU32(expectedCRC, to: &header)
        appendU32(expectedSize, to: &header) // compressed size
        appendU32(expectedSize, to: &header) // uncompressed size
        appendU16(UInt16(name.count), to: &header)
        appendU16(0, to: &header)            // extra length
        header.append(contentsOf: name)
        try write(header)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var crc = MinimalZipCRC32()
        var written: UInt64 = 0
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            written += UInt64(chunk.count)
            guard written <= UInt64(expectedSize) else {
                throw CocoaError(.fileReadCorruptFile)
            }
            try onChunk(chunk)
            crc.update(chunk)
            try write(chunk)
        }
        guard written == UInt64(expectedSize),
              crc.checksum == expectedCRC else {
            throw CocoaError(.fileReadCorruptFile)
        }
        entries.append(entry)
    }

    /// Close the underlying file WITHOUT writing a directory. Used when an
    /// off-main finalizer abandons a partially written bundle; the caller then
    /// removes staging. Safe after `finish()` (idempotent).
    func close() {
        guard !isClosed else { return }
        isClosed = true
        try? handle.close()
    }

    /// Write the central directory + EOCD, close the file and return its exact
    /// byte count. The archive is usable only after this returns.
    @discardableResult
    func finish() throws -> Int64 {
        let centralOffset = UInt32(offset)
        var central = Data()
        for entry in entries {
            appendU32(0x0201_4B50, to: &central) // central header signature
            appendU16(20, to: &central)          // version made by
            appendU16(20, to: &central)          // version needed
            appendU16(0, to: &central)           // flags
            appendU16(0, to: &central)           // method
            appendU16(0, to: &central)           // mod time
            appendU16(0x21, to: &central)        // mod date
            appendU32(entry.crc, to: &central)
            appendU32(entry.size, to: &central)
            appendU32(entry.size, to: &central)
            appendU16(UInt16(entry.name.count), to: &central)
            appendU16(0, to: &central)           // extra length
            appendU16(0, to: &central)           // comment length
            appendU16(0, to: &central)           // disk number
            appendU16(0, to: &central)           // internal attributes
            appendU32(0, to: &central)           // external attributes
            appendU32(entry.offset, to: &central)
            central.append(contentsOf: entry.name)
        }
        let centralSize = UInt32(central.count)
        try write(central)
        var eocd = Data()
        appendU32(0x0605_4B50, to: &eocd)       // end of central directory
        appendU16(0, to: &eocd)                 // disk number
        appendU16(0, to: &eocd)                 // central directory disk
        appendU16(UInt16(entries.count), to: &eocd)
        appendU16(UInt16(entries.count), to: &eocd)
        appendU32(centralSize, to: &eocd)
        appendU32(centralOffset, to: &eocd)
        appendU16(0, to: &eocd)                 // comment length
        try write(eocd)
        try handle.close()
        isClosed = true
        return Int64(offset)
    }

    private func write(_ data: Data) throws {
        try handle.write(contentsOf: data)
        offset += UInt64(data.count)
    }

    private func appendU16(_ value: UInt16, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private func appendU32(_ value: UInt32, to data: inout Data) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
}

/// Incremental CRC-32 for streamed ZIP entries. It uses the SAME reflected
/// polynomial and final inversion as `MinimalZipWriter.crc32`, so a chunked
/// entry and a buffered entry produce the identical directory value; the state
/// starts at the canonical 0xFFFF_FFFF seed. The 256-entry table is just a
/// faster form of the same bytewise recurrence (identical results), which
/// matters because the frame bundle is CRC-checked again while it is written.
nonisolated struct MinimalZipCRC32 {
    private static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for index in 0..<256 {
            var crc = UInt32(index)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1)))
            }
            table[index] = crc
        }
        return table
    }()

    private var value: UInt32 = 0xFFFF_FFFF

    mutating func update(_ data: Data) {
        var crc = value
        let table = Self.table
        for byte in data {
            crc = (crc >> 8) ^ table[Int((crc ^ UInt32(byte)) & 0xFF)]
        }
        value = crc
    }

    var checksum: UInt32 { ~value }

    /// Canonical value for one buffer; equals `MinimalZipWriter.crc32(_:)`.
    static func checksum(of data: Data) -> UInt32 {
        var crc = MinimalZipCRC32()
        crc.update(data)
        return crc.checksum
    }
}
