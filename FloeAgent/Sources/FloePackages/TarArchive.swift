import Foundation
import FloeCore

/// Minimal POSIX ustar reader/writer used for `.deb` control/data payloads.
/// Only regular files and directories are represented; links and devices are
/// reported as skipped entries so callers can enforce policy.
public enum TarArchive {
    public struct Entry: Sendable, Equatable {
        public enum Kind: String, Sendable {
            case file
            case directory
            case symlink
            case hardlink
            case other
        }

        public var path: String
        public var kind: Kind
        public var mode: Int
        public var byteCount: Int
        public var linkTarget: String?
        public var data: Data

        public init(path: String, kind: Kind, mode: Int = 0o644, byteCount: Int = 0, linkTarget: String? = nil, data: Data = Data()) {
            self.path = path
            self.kind = kind
            self.mode = mode
            self.byteCount = byteCount
            self.linkTarget = linkTarget
            self.data = data
        }
    }

    public static func read(_ data: Data) throws -> [Entry] {
        var entries: [Entry] = []
        var offset = 0
        var longName: String?
        while offset + 512 <= data.count {
            let header = data.subdata(in: offset..<(offset + 512))
            offset += 512
            if header.allSatisfy({ $0 == 0 }) { break }
            guard let name = cString(header, 0, 100) else { break }
            let mode = Int(cString(header, 100, 8) ?? "644", radix: 8) ?? 0o644
            let size = Int(cString(header, 124, 12) ?? "0", radix: 8) ?? 0
            let typeFlag = header[156]
            let linkName = cString(header, 157, 100) ?? ""
            let prefix = cString(header, 345, 155)
            var fullPath = prefix.map { "\($0)/\(name)" } ?? name
            if typeFlag == Character("L").asciiValue ?? 0 || typeFlag == Character("K").asciiValue ?? 0 {
                let payload = data.subdata(in: offset..<(offset + size))
                longName = String(data: payload, encoding: .utf8)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
                offset += size
                if offset % 512 != 0 { offset += 512 - (offset % 512) }
                continue
            }
            if let longName {
                fullPath = longName
                longName = nil
            }
            let payloadStart = offset
            let payloadEnd = min(offset + size, data.count)
            let payload = data.subdata(in: payloadStart..<payloadEnd)
            offset += size
            if offset % 512 != 0 { offset += 512 - (offset % 512) }

            let kind: Entry.Kind
            switch typeFlag {
            case Character("0").asciiValue, 0:
                kind = .file
            case Character("5").asciiValue:
                kind = .directory
            case Character("2").asciiValue:
                kind = .symlink
            case Character("1").asciiValue:
                kind = .hardlink
            default:
                kind = .other
            }
            entries.append(Entry(
                path: fullPath,
                kind: kind,
                mode: mode,
                byteCount: size,
                linkTarget: linkName.isEmpty ? nil : linkName,
                data: kind == .file ? payload : Data()
            ))
        }
        return entries
    }

    public static func write(_ entries: [Entry]) -> Data {
        var output = Data()
        for entry in entries {
            var header = [UInt8](repeating: 0, count: 512)
            writeString(entry.path, into: &header, offset: 0, length: 100)
            writeOctal(entry.mode, into: &header, offset: 100, length: 8)
            writeOctal(0, into: &header, offset: 108, length: 8)
            writeOctal(0, into: &header, offset: 116, length: 8)
            writeOctal(entry.kind == .file ? entry.data.count : 0, into: &header, offset: 124, length: 12)
            writeOctal(0, into: &header, offset: 136, length: 12)
            header[156] = entry.kind == .directory ? Character("5").asciiValue! : Character("0").asciiValue!
            if let linkTarget = entry.linkTarget {
                writeString(linkTarget, into: &header, offset: 157, length: 100)
                header[156] = entry.kind == .symlink ? Character("2").asciiValue! : Character("1").asciiValue!
            }
            writeString("ustar", into: &header, offset: 257, length: 6)
            header[263] = Character("0").asciiValue!
            header[264] = Character("0").asciiValue!
            // Checksum: spaces while computing.
            for index in 148..<156 { header[index] = 0x20 }
            let checksum = header.reduce(0) { $0 + Int($1) }
            writeOctal(checksum, into: &header, offset: 148, length: 7)
            header[155] = 0x20
            output.append(contentsOf: header)
            if entry.kind == .file {
                output.append(entry.data)
                let remainder = entry.data.count % 512
                if remainder != 0 {
                    output.append(contentsOf: [UInt8](repeating: 0, count: 512 - remainder))
                }
            }
        }
        output.append(contentsOf: [UInt8](repeating: 0, count: 1024))
        return output
    }

    private static func cString(_ data: Data, _ offset: Int, _ length: Int) -> String? {
        guard offset + length <= data.count else { return nil }
        let slice = data.subdata(in: offset..<(offset + length))
        let scalars = slice.prefix { $0 != 0 }
        let value = String(decoding: scalars, as: UTF8.self).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    private static func writeString(_ value: String, into header: inout [UInt8], offset: Int, length: Int) {
        let bytes = Array(value.utf8.prefix(length - 1))
        for (index, byte) in bytes.enumerated() {
            header[offset + index] = byte
        }
    }

    private static func writeOctal(_ value: Int, into header: inout [UInt8], offset: Int, length: Int) {
        let string = String(value, radix: 8)
        let padded = String(repeating: "0", count: max(0, length - 1 - string.count)) + string
        let bytes = Array(padded.utf8.prefix(length - 1))
        for (index, byte) in bytes.enumerated() {
            header[offset + index] = byte
        }
        header[offset + length - 1] = 0
    }
}
