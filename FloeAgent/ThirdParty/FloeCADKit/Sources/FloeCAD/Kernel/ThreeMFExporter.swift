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
