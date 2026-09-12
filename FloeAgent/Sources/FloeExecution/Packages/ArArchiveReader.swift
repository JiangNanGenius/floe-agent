// FloeExecution — Minimal `ar` archive reader (Debian .deb payloads).
// Supports the common member layout used by .deb files: System V headers,
// GNU `//` long-name tables and BSD `#1/<len>` names.

import Foundation
import FloeCore

public enum ArArchiveReader {
    public struct Member: Sendable, Equatable {
        public var name: String
        public var data: Data
    }

    public static let magic = Data("!<arch>\n".utf8)

    public static func isArArchive(_ data: Data) -> Bool {
        data.starts(with: magic)
    }

    public static func read(_ data: Data) throws -> [Member] {
        guard isArArchive(data) else {
            throw FloeError.validationFailed("Not an ar archive (missing !<arch> magic)")
        }
        var members: [Member] = []
        var longNames: String?
        var offset = magic.count
        while offset + 60 <= data.count {
            let header = data.subdata(in: offset..<(offset + 60))
            offset += 60
            guard let headerString = String(data: header, encoding: .utf8),
                  headerString.hasSuffix("`\n") else {
                throw FloeError.validationFailed("Corrupt ar member header at byte \(offset - 60)")
            }
            let rawName = String(headerString.prefix(16)).trimmingCharacters(in: .whitespaces)
            guard let sizeField = Int(String(headerString.dropFirst(48).prefix(10)).trimmingCharacters(in: .whitespaces)) else {
                throw FloeError.validationFailed("Corrupt ar member size at byte \(offset - 60)")
            }
            guard sizeField >= 0, sizeField <= data.count - offset else {
                throw FloeError.validationFailed("ar member exceeds archive bounds")
            }
            let payload = data.subdata(in: offset..<(offset + sizeField))
            offset += sizeField
            if offset % 2 == 1 { offset += 1 }

            var name = rawName
            var memberData = payload
            if rawName == "//" {
                longNames = String(data: payload, encoding: .utf8)
                continue
            }
            if rawName == "/" || rawName.isEmpty { continue }
            if rawName.hasPrefix("/"), let table = longNames {
                let index = Int(rawName.dropFirst()) ?? -1
                if index >= 0 {
                    let scalars = Array(table.unicodeScalars)
                    if index < scalars.count {
                        var end = index
                        while end < scalars.count, scalars[end] != "\n" { end += 1 }
                        name = String(String.UnicodeScalarView(scalars[index..<end]))
                    }
                }
            } else if rawName.hasPrefix("#1/") {
                let length = Int(rawName.dropFirst(3)) ?? 0
                if length >= 0, length <= payload.count {
                    name = String(data: payload.prefix(length), encoding: .utf8)?
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\0")) ?? name
                    memberData = payload.dropFirst(length)
                }
            }
            members.append(Member(name: name.trimmingCharacters(in: CharacterSet(charactersIn: "/")), data: memberData))
        }
        guard offset == data.count else {
            throw FloeError.validationFailed("Truncated ar header or padding")
        }
        return members
    }

    /// Rejects payloads that contain native executables. iOS cannot execute
    /// ELF or Mach-O code, and Floe never ships an emulator that could.
    public static func containsNativeExecutable(_ members: [Member]) -> Bool {
        let magics: [Data] = [
            Data([0x7F, 0x45, 0x4C, 0x46]),             // ELF
            Data([0xCF, 0xFA, 0xED, 0xFE]),             // Mach-O 64 LE
            Data([0xCE, 0xFA, 0xED, 0xFE]),             // Mach-O 32 LE
            Data([0xCA, 0xFE, 0xBA, 0xBE]),             // Mach-O fat
            Data([0xFE, 0xED, 0xFA, 0xCE]),             // Mach-O 32 BE
            Data([0xFE, 0xED, 0xFA, 0xCF])              // Mach-O 64 BE
        ]
        for member in members {
            for magic in magics where member.data.count >= magic.count && member.data.prefix(magic.count) == magic {
                return true
            }
        }
        return false
    }
}
