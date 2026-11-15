// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit
import FloeGameCore

/// Machine-readable starter provenance written into a newly seeded project.
/// It is deterministic: no timestamps, random identifiers or absolute paths.
public struct GameStarterMetadata: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let engine: GameEngineID
    public let starter: String
    public let starterVersion: String
    public let title: String
    public let entry: String
    public let webEntry: String?
    public let sourceLicense: String
    public let engineLicense: String
    public let templateKind: GameStarterTemplateKind
    public let provider: String?
    public let runtimePackID: String?
    public let prerequisites: [GameStarterPrerequisite]
    public let generator: String

    public init(descriptor: GameStarterDescriptor, title: String) {
        self.schemaVersion = 1
        self.engine = descriptor.engine
        self.starter = "floe.glimmerfen"
        self.starterVersion = descriptor.starterVersion
        self.title = title
        self.entry = descriptor.entry.value
        self.webEntry = descriptor.webEntry?.value
        self.sourceLicense = descriptor.sourceLicense
        self.engineLicense = descriptor.engineLicense
        self.templateKind = descriptor.templateKind
        self.provider = descriptor.provider
        self.runtimePackID = descriptor.runtimePack?.id
        self.prerequisites = descriptor.prerequisites
        self.generator = "FloeGameStarterKit/1.0.0"
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }
}

public enum GameStarterTreeDigest {
    /// A stable digest over path, content hash and byte count, sorted by path.
    public static func sha256(files: [GameProjectFile]) -> String {
        var hasher = SHA256()
        for file in files.sorted(by: { $0.path.value < $1.path.value }) {
            hasher.update(data: Data(file.path.value.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(file.sha256.utf8))
            hasher.update(data: Data([0]))
            hasher.update(data: Data(String(file.bytes).utf8))
            hasher.update(data: Data([10]))
        }
        return hasher.finalize().hexString
    }
}

public enum GameStarterDeterminism {
    public static func uuid(_ text: String) -> UUID {
        let digest = Array(SHA256.hash(data: Data(text.utf8)).prefix(16))
        var bytes = digest
        bytes[6] = (bytes[6] & 0x0F) | 0x40
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3],
                           bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    public static func twineIFID(title: String) -> String {
        let digest = SHA256.hash(data: Data(("twine:" + title).utf8))
        return "FLOE-" + digest.hexString.uppercased()
    }
}

enum GameStarterFileSupport {
    static func read(_ url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size >= 0, size <= maximum else {
            throw GameStarterError.unsafePath(url.lastPathComponent)
        }
        return try Data(contentsOf: url)
    }

    static func write(_ data: Data, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    static func replaceFirstLineHeading(_ url: URL, from old: String, to new: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try read(url, maximum: 2 * 1_024 * 1_024)
        guard var text = String(data: data, encoding: .utf8) else { return }
        if text.hasPrefix("# " + old) {
            text = "# " + new + String(text.dropFirst(2 + old.count))
            try write(Data(text.utf8), to: url)
        }
    }

    static func replaceFirstOccurrence(in url: URL, from old: String, to new: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try read(url, maximum: 4 * 1_024 * 1_024)
        guard let text = String(data: data, encoding: .utf8) else { return }
        guard let range = text.range(of: old) else { return }
        let replaced = text.replacingCharacters(in: range, with: new)
        try write(Data(replaced.utf8), to: url)
    }

    static func replaceText(in url: URL, from old: String, to new: String) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try read(url, maximum: 16 * 1_024 * 1_024)
        guard let text = String(data: data, encoding: .utf8) else {
            throw GameStarterError.invalidTemplate("not UTF-8: \(url.lastPathComponent)")
        }
        guard text.contains(old) else { return }
        try write(Data(text.replacingOccurrences(of: old, with: new).utf8), to: url)
    }

    static func updateJSON(_ url: URL, mutate: (inout [String: Any]) throws -> Void) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GameStarterError.invalidTemplate("missing \(url.lastPathComponent)")
        }
        let data = try read(url, maximum: 16 * 1_024 * 1_024)
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GameStarterError.invalidTemplate("JSON object expected: \(url.lastPathComponent)")
        }
        try mutate(&object)
        let encoded = try JSONSerialization.data(withJSONObject: object,
                                                 options: [.sortedKeys, .prettyPrinted])
        try write(encoded + Data([10]), to: url)
    }

    static func rewriteTwineIFID(at root: URL, title: String) throws {
        let url = root.appendingPathComponent("story.twine.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try updateJSON(url) { object in
            object["ifid"] = GameStarterDeterminism.twineIFID(title: title)
            if var attributes = object["storyAttributes"] as? [String: Any] {
                attributes["ifid"] = GameStarterDeterminism.twineIFID(title: title)
                object["storyAttributes"] = attributes
            }
        }
    }
}
