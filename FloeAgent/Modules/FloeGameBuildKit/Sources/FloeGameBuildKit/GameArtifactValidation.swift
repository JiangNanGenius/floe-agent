// SPDX-License-Identifier: MPL-2.0
import Foundation

/// What a downloaded/sealed artifact actually is. A zip of an Xcode project is
/// not an IPA, and a Cocos native project is not an APK. The validator checks
/// bytes, not names, before the coordinator reports success.
public enum GameArtifactValidationKind: String, Codable, Equatable, Sendable {
    case webBundle = "web"
    case nativeZip = "zip"
    case apk
    case executablePE = "pe"
    case executableMachO = "macho"
    case executableELF = "elf"
    case xcodeProject = "xcodeproj"
    case nativeProject

    /// The initial v1 catalog emitted these two Swift case names, while
    /// receipts use the stable short wire values. Decode both published forms;
    /// continue encoding only the canonical wire value.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(String.self)
        switch value {
        case "webBundle": self = .webBundle
        case "nativeZip": self = .nativeZip
        default:
            guard let known = Self(rawValue: value) else {
                throw DecodingError.dataCorruptedError(in: container,
                    debugDescription: "Unknown artifact validation kind: \(value)")
            }
            self = known
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public struct GameArtifactValidationRule: Codable, Equatable, Sendable {
    public let kind: GameArtifactValidationKind?
    public let entry: String?
    public let member: String?

    public init(kind: GameArtifactValidationKind? = nil, entry: String? = nil, member: String? = nil) {
        self.kind = kind
        self.entry = entry
        self.member = member
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decodeIfPresent(GameArtifactValidationKind.self, forKey: .kind)
        entry = try values.decodeIfPresent(String.self, forKey: .entry)
        member = try values.decodeIfPresent(String.self, forKey: .member)
    }

    private enum CodingKeys: String, CodingKey { case kind, entry, member }
}

public enum GameArtifactValidationError: Error, Equatable, Sendable {
    case empty
    case unknownRule
    case notZip
    case missingEntry(String)
    case missingMember(String)
    case wrongMagic(String)
    case malformedZip
    case unsupportedZip64
}

/// Minimal central-directory reader. It never extracts or executes entries; it
/// only names them for validation. Zip64 is refused rather than misread.
enum GameZIPEntryReader {
    static func entryNames(in data: Data) throws -> [String] {
        guard data.count >= 22 else { throw GameArtifactValidationError.notZip }
        let searchStart = max(0, data.count - 65_557)
        var eocd: Int?
        var cursor = data.count - 22
        while cursor >= searchStart {
            if data[cursor] == 0x50, data[cursor + 1] == 0x4b,
               data[cursor + 2] == 0x05, data[cursor + 3] == 0x06 {
                eocd = cursor
                break
            }
            cursor -= 1
        }
        guard let end = eocd else { throw GameArtifactValidationError.notZip }
        let entryCount = Int(readUInt16(data, end + 10))
        let directorySize = Int(readUInt32(data, end + 12))
        let directoryOffset = Int(readUInt32(data, end + 16))
        guard entryCount != 0xFFFF, directorySize != 0xFFFF_FFFF, directoryOffset != 0xFFFF_FFFF else {
            throw GameArtifactValidationError.unsupportedZip64
        }
        guard directoryOffset >= 0, directorySize >= 0,
              directoryOffset + directorySize <= data.count else {
            throw GameArtifactValidationError.malformedZip
        }
        var names: [String] = []
        var offset = directoryOffset
        for _ in 0..<entryCount {
            guard offset + 46 <= data.count,
                  readUInt32(data, offset) == 0x0201_4b50 else {
                throw GameArtifactValidationError.malformedZip
            }
            let nameLength = Int(readUInt16(data, offset + 28))
            let extraLength = Int(readUInt16(data, offset + 30))
            let commentLength = Int(readUInt16(data, offset + 32))
            guard offset + 46 + nameLength <= data.count else {
                throw GameArtifactValidationError.malformedZip
            }
            let nameData = data.subdata(in: (offset + 46)..<(offset + 46 + nameLength))
            guard let name = String(data: nameData, encoding: .utf8) else {
                throw GameArtifactValidationError.malformedZip
            }
            names.append(name)
            offset += 46 + nameLength + extraLength + commentLength
        }
        return names
    }

    private static func readUInt16(_ data: Data, _ offset: Int) -> UInt16 {
        UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        UInt32(data[offset]) | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16) | (UInt32(data[offset + 3]) << 24)
    }
}

public enum GameArtifactValidator {
    public static func validate(data: Data, name: String,
                                rule: GameArtifactValidationRule) throws {
        guard !data.isEmpty else { throw GameArtifactValidationError.empty }
        guard let kind = rule.kind else { throw GameArtifactValidationError.unknownRule }
        switch kind {
        case .webBundle:
            let entry = rule.entry ?? "index.html"
            if data.starts(with: [0x50, 0x4b]) {
                let names = try GameZIPEntryReader.entryNames(in: data)
                guard names.contains(where: { $0 == entry || $0.hasSuffix("/" + entry) }) else {
                    throw GameArtifactValidationError.missingEntry(entry)
                }
            } else {
                throw GameArtifactValidationError.missingEntry(entry)
            }
        case .nativeZip, .nativeProject:
            let names = try GameZIPEntryReader.entryNames(in: data)
            guard !names.isEmpty else { throw GameArtifactValidationError.empty }
            if kind == .nativeProject {
                let markers = ["build.gradle", "project.pbxproj", "CMakeLists.txt", "settings.gradle"]
                guard names.contains(where: { name in markers.contains(where: { name.hasSuffix($0) }) }) else {
                    throw GameArtifactValidationError.missingMember("native project marker")
                }
            }
            if let member = rule.member, !member.isEmpty {
                guard names.contains(where: { glob(member, matches: $0) }) else {
                    throw GameArtifactValidationError.missingMember(member)
                }
            }
        case .apk:
            let names = try GameZIPEntryReader.entryNames(in: data)
            guard names.contains("AndroidManifest.xml") else {
                throw GameArtifactValidationError.missingEntry("AndroidManifest.xml")
            }
            guard names.contains(where: { $0.hasPrefix("classes") && $0.hasSuffix(".dex") }) else {
                throw GameArtifactValidationError.missingMember("classes*.dex")
            }
        case .xcodeProject:
            let names = try GameZIPEntryReader.entryNames(in: data)
            guard names.contains(where: { $0.hasSuffix("project.pbxproj") }) else {
                throw GameArtifactValidationError.missingMember("project.pbxproj")
            }
        case .executablePE:
            guard data.starts(with: [0x4d, 0x5a]) else { throw GameArtifactValidationError.wrongMagic("PE") }
        case .executableMachO:
            let magic = Array(data.prefix(4))
            let allowed: [[UInt8]] = [[0xfe, 0xed, 0xfa, 0xce], [0xce, 0xfa, 0xed, 0xfe],
                                      [0xfe, 0xed, 0xfa, 0xcf], [0xcf, 0xfa, 0xed, 0xfe],
                                      [0xca, 0xfe, 0xba, 0xbe]]
            guard allowed.contains(magic) else { throw GameArtifactValidationError.wrongMagic("Mach-O") }
        case .executableELF:
            guard data.starts(with: [0x7f, 0x45, 0x4c, 0x46]) else { throw GameArtifactValidationError.wrongMagic("ELF") }
        }
    }

    /// A tiny glob for the only form used by the plans (`*.exe`,
    /// `*.app/Contents/Info.plist`, `classes*.dex`). It is not a general regex.
    static func glob(_ pattern: String, matches value: String) -> Bool {
        let parts = pattern.split(separator: "*", omittingEmptySubsequences: false).map(String.init)
        if parts.count == 1 { return pattern == value }
        var index = value.startIndex
        for (offset, part) in parts.enumerated() {
            if part.isEmpty { continue }
            if offset == 0 {
                guard value.hasPrefix(part) else { return false }
                index = value.index(value.startIndex, offsetBy: part.count)
            } else if offset == parts.count - 1 {
                guard value.hasSuffix(part) else { return false }
                let suffixStart = value.index(value.endIndex, offsetBy: -part.count)
                guard suffixStart >= index else { return false }
            } else {
                guard let range = value.range(of: part, range: index..<value.endIndex) else { return false }
                index = range.upperBound
            }
        }
        return true
    }
}
