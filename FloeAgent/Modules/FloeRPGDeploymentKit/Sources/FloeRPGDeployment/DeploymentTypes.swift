// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public enum RPGDeploymentError: Error, Equatable, Sendable {
    case invalidArchive(String)
    case unsupportedVersion(Int)
    case unsafePath(String)
    case conflictingPath(String)
    case limitExceeded(String)
    case sourceChanged
    case destinationExists
    case missingMediaKey
    case invalidMediaKey
    case invalidMediaHeader
    case invalidSelection
    case preparationNotFound
    case operationInProgress
    case io(String)
}

public struct RPGDeploymentLimits: Sendable {
    public let maximumFiles: Int
    public let maximumEntryBytes: UInt64
    public let maximumTotalBytes: UInt64
    public let maximumArchiveBytes: UInt64
    public let maximumNameBytes: Int
    public init(maximumFiles: Int = 50_000, maximumEntryBytes: UInt64 = 512 * 1_024 * 1_024,
                maximumTotalBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024,
                maximumArchiveBytes: UInt64 = 8 * 1_024 * 1_024 * 1_024,
                maximumNameBytes: Int = 4_096) throws {
        guard maximumFiles > 0, maximumFiles <= 1_000_000, maximumEntryBytes > 0,
              maximumTotalBytes >= maximumEntryBytes, maximumArchiveBytes > 0,
              (1...32_768).contains(maximumNameBytes) else { throw RPGDeploymentError.limitExceeded("limits") }
        self.maximumFiles = maximumFiles; self.maximumEntryBytes = maximumEntryBytes
        self.maximumTotalBytes = maximumTotalBytes; self.maximumArchiveBytes = maximumArchiveBytes
        self.maximumNameBytes = maximumNameBytes
    }
    public static var standard: Self { try! .init() }
}

public struct RPGDeploymentEntry: Sendable, Equatable {
    public let path: GameRelativePath
    public let originalNameBytes: Data
    public let byteCount: UInt64
    let offset: UInt64
    let fileKey: UInt32
}

public struct RPGDeploymentFile: Codable, Equatable, Sendable {
    public let path: String
    public let byteCount: UInt64
    public let sha256: String
}

public struct RPGDeploymentExtraction: Sendable {
    public let archiveVersion: Int
    public let output: URL
    public let files: [RPGDeploymentFile]
    /// The source archive is only opened read-only and is never rewritten.
    public let originalArchivePreserved: Bool
}

enum DeploymentPath {
    static func decode(_ bytes: Data) throws -> GameRelativePath {
        guard let text = String(data: bytes, encoding: .utf8)
            ?? String(data: bytes, encoding: .shiftJIS) else {
            throw RPGDeploymentError.unsafePath("undecodable file name")
        }
        return try validate(text)
    }
    static func validate(_ original: String) throws -> GameRelativePath {
        let text = original.replacingOccurrences(of: "\\", with: "/")
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        guard !text.hasPrefix("/"), !text.contains(":"), !text.isEmpty,
              parts.count <= 64,
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasSuffix(" ") && !$0.hasSuffix(".") }) else {
            throw RPGDeploymentError.unsafePath(original)
        }
        guard let path = try? GameRelativePath(text) else { throw RPGDeploymentError.unsafePath(original) }
        return path
    }
    static func collisionKey(_ path: GameRelativePath) -> String {
        path.value.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
    static func validateSet(_ entries: [RPGDeploymentEntry]) throws {
        var paths = Set<String>()
        for entry in entries {
            guard paths.insert(collisionKey(entry.path)).inserted else { throw RPGDeploymentError.conflictingPath(entry.path.value) }
        }
        for entry in entries {
            var prefix = ""
            for part in entry.path.value.split(separator: "/").dropLast() {
                prefix = prefix.isEmpty ? String(part) : prefix + "/" + String(part)
                if paths.contains(collisionKey(try GameRelativePath(prefix))) { throw RPGDeploymentError.conflictingPath(entry.path.value) }
            }
        }
    }
}
