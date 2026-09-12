import Foundation
import FloeCore

/// Minimal `ar` archive reader/writer with GNU long-name and BSD `#1/<len>`
/// support, sufficient for `.deb` packages.
public enum ArArchive {
    public struct Member: Sendable, Equatable {
        public var name: String
        public var data: Data
        public var modificationTime: Date?

        public init(name: String, data: Data, modificationTime: Date? = nil) {
            self.name = name
            self.data = data
            self.modificationTime = modificationTime
        }
    }

    public static let magic = Data("!<arch>\n".utf8)

    public static func isAr(_ data: Data) -> Bool { data.starts(with: magic) }

    public static func read(_ data: Data) throws -> [Member] {
        guard isAr(data) else {
            throw FloeError.validationFailed("not an ar archive")
        }
        var members: [Member] = []
        var longNames: String?
        var offset = magic.count
        while offset + 60 <= data.count {
            let header = data.subdata(in: offset..<(offset + 60))
            offset += 60
            guard let headerString = String(data: header, encoding: .utf8), headerString.hasSuffix("`\n") else {
                throw FloeError.validationFailed("corrupt ar header")
            }
            let rawName = String(headerString.prefix(16)).trimmingCharacters(in: .whitespaces)
            let timestamp = Int(String(headerString.dropFirst(16).prefix(12)).trimmingCharacters(in: .whitespaces)) ?? 0
            guard let size = Int(String(headerString.dropFirst(48).prefix(10)).trimmingCharacters(in: .whitespaces)),
                  size >= 0, offset + size <= data.count else {
                throw FloeError.validationFailed("corrupt ar member size")
            }
            let payload = data.subdata(in: offset..<(offset + size))
            offset += size
            if offset % 2 == 1 { offset += 1 }

            if rawName == "//" {
                longNames = String(data: payload, encoding: .utf8)
                continue
            }
            if rawName == "/" || rawName.isEmpty { continue }

            var name = rawName
            var memberData = payload
            if rawName.hasPrefix("/"), let table = longNames {
                let index = Int(rawName.dropFirst()) ?? -1
                if index >= 0 {
                    let scalars = Array(table.unicodeScalars)
                    if index < scalars.count {
                        var end = index
                        while end < scalars.count, scalars[end] != "\n", scalars[end] != "/" { end += 1 }
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
            members.append(Member(
                name: name.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                data: memberData,
                modificationTime: timestamp > 0 ? Date(timeIntervalSince1970: TimeInterval(timestamp)) : nil
            ))
        }
        return members
    }

    public static func write(_ members: [Member]) -> Data {
        var output = magic
        for member in members {
            let name: String
            if member.name.count <= 15 {
                name = member.name
            } else {
                name = member.name
            }
            var header = name.padding(toLength: 16, withPad: " ", startingAt: 0)
            header += String(Int(member.modificationTime?.timeIntervalSince1970 ?? 0)).padding(toLength: 12, withPad: " ", startingAt: 0)
            header += "0".padding(toLength: 6, withPad: " ", startingAt: 0)
            header += "0".padding(toLength: 6, withPad: " ", startingAt: 0)
            header += "100644".padding(toLength: 8, withPad: " ", startingAt: 0)
            header += String(member.data.count).padding(toLength: 10, withPad: " ", startingAt: 0)
            header += "`\n"
            output.append(Data(header.utf8))
            output.append(member.data)
            if member.data.count % 2 == 1 { output.append(0x0A) }
        }
        return output
    }

    /// True when the member stream contains an ELF or Mach-O payload.
    public static func containsNativeExecutable(_ data: Data) -> Bool {
        let magics: [ [UInt8] ] = [
            [0x7F, 0x45, 0x4C, 0x46],
            [0xCF, 0xFA, 0xED, 0xFE],
            [0xCE, 0xFA, 0xED, 0xFE],
            [0xCA, 0xFE, 0xBA, 0xBE],
            [0xFE, 0xED, 0xFA, 0xCE],
            [0xFE, 0xED, 0xFA, 0xCF]
        ]
        return magics.contains { data.starts(with: Data($0)) }
    }
}
