// SPDX-License-Identifier: MPL-2.0
import Foundation

/// Minimal store-only ZIP writer for attack/edge fixtures. Produces byte-exact
/// archives with full control over entry names, duplicates, CRC correctness
/// and unix external attributes — no compression, no ZIP64.
enum GameTestZIPCraft {
    struct Entry {
        var name: String
        var data: Data
        var directory: Bool
        var executable: Bool
        var symlink: Bool
        var corruptCRC: Bool
        var omitFromCentralDirectory: Bool
        /// Legacy-encoding fixture support: raw name bytes with no UTF-8 flag
        /// (e.g. GBK/Shift-JIS), exactly as older ZIP tools wrote them.
        var rawNameBytes: [UInt8]?
        var utf8Flag: Bool

        static func entry(_ name: String, data: Data = Data(), directory: Bool = false,
                          executable: Bool = false, symlink: Bool = false,
                          corruptCRC: Bool = false) -> Entry {
            .init(name: name, data: data, directory: directory, executable: executable,
                  symlink: symlink, corruptCRC: corruptCRC, omitFromCentralDirectory: false,
                  rawNameBytes: nil, utf8Flag: true)
        }

        static func legacyEntry(rawNameBytes: [UInt8], data: Data) -> Entry {
            .init(name: "", data: data, directory: false, executable: false,
                  symlink: false, corruptCRC: false, omitFromCentralDirectory: false,
                  rawNameBytes: rawNameBytes, utf8Flag: false)
        }
    }

    static func entry(_ name: String, data: Data = Data(), directory: Bool = false,
                      executable: Bool = false, symlink: Bool = false,
                      corruptCRC: Bool = false) -> Entry {
        .entry(name, data: data, directory: directory, executable: executable,
               symlink: symlink, corruptCRC: corruptCRC)
    }

    static func makeZIP(_ entries: [Entry]) -> Data {
        var out = Data()
        var central = Data()
        var offset = 0
        for entry in entries {
            let nameBytes = entry.rawNameBytes ?? Array(entry.name.utf8)
            let crc = crc32(entry.data)
            let recordedCRC = entry.corruptCRC ? crc ^ 0xFFFF_FFFF : crc
            let flags: UInt16 = entry.utf8Flag ? 0x0800 : 0
            let method: UInt16 = 0
            let size = UInt32(entry.data.count)

            var local = Data()
            local.append(contentsOf: u32(0x04034b50)); local.append(contentsOf: u16(20)); local.append(contentsOf: u16(flags))
            local.append(contentsOf: u16(method)); local.append(contentsOf: u16(0)); local.append(contentsOf: u16(0))
            local.append(contentsOf: u32(recordedCRC)); local.append(contentsOf: u32(size)); local.append(contentsOf: u32(size))
            local.append(contentsOf: u16(UInt16(nameBytes.count))); local.append(contentsOf: u16(0))
            local.append(contentsOf: nameBytes)
            local.append(entry.data)

            var mode: UInt32 = 0o644
            if entry.directory { mode = 0o755 | 0o040000 }
            else if entry.symlink { mode = 0o777 | 0o120000 }
            else if entry.executable { mode = 0o755 }

            if !entry.omitFromCentralDirectory {
                var cd = Data()
                cd.append(contentsOf: u32(0x02014b50)); cd.append(contentsOf: u16(0x031E)); cd.append(contentsOf: u16(20))
                cd.append(contentsOf: u16(flags)); cd.append(contentsOf: u16(method)); cd.append(contentsOf: u16(0)); cd.append(contentsOf: u16(0))
                cd.append(contentsOf: u32(recordedCRC)); cd.append(contentsOf: u32(size)); cd.append(contentsOf: u32(size))
                cd.append(contentsOf: u16(UInt16(nameBytes.count))); cd.append(contentsOf: u16(0)); cd.append(contentsOf: u16(0))
                cd.append(contentsOf: u16(0)); cd.append(contentsOf: u16(0)); cd.append(contentsOf: u32(mode << 16))
                cd.append(contentsOf: u32(UInt32(offset))); cd.append(contentsOf: nameBytes)
                central.append(cd)
            }
            out.append(local)
            offset += local.count
        }
        let cdOffset = offset
        out.append(central)
        var eocd = Data()
        eocd.append(contentsOf: u32(0x06054b50)); eocd.append(contentsOf: u16(0)); eocd.append(contentsOf: u16(0))
        let count = UInt16(entries.filter { !$0.omitFromCentralDirectory }.count)
        eocd.append(contentsOf: u16(count)); eocd.append(contentsOf: u16(count))
        eocd.append(contentsOf: u32(UInt32(central.count))); eocd.append(contentsOf: u32(UInt32(cdOffset)))
        eocd.append(contentsOf: u16(0))
        out.append(eocd)
        return out
    }

    static func crc32(_ data: Data) -> UInt32 {
        var table: [UInt32] = []
        for byte in 0..<256 {
            var value = UInt32(byte)
            for _ in 0..<8 {
                value = value & 1 != 0 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
            }
            table.append(value)
        }
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[(Int(crc) ^ Int(byte)) & 0xFF] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    private static func u16(_ value: UInt16) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }

    private static func u32(_ value: UInt32) -> [UInt8] {
        withUnsafeBytes(of: value.littleEndian) { Array($0) }
    }
}
