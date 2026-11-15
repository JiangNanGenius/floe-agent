// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// Portable-path and size checks applied to the generated staging tree before
/// the repository imports it. The repository has its own descriptor-relative
/// import; this policy adds case-insensitive collision and portable-name checks.
public enum GameStarterTreePolicy {
    public struct Report: Sendable {
        public let fileCount: Int
        public let byteCount: Int
        public let entryCount: Int
    }

    public static func validate(root: URL, limits: GameStarterLimits) throws -> Report {
        guard root.isFileURL else { throw GameStarterError.unsafePath("stage") }
        let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey,
                                      .isSymbolicLinkKey, .fileSizeKey]
        guard let enumerator = FileManager.default.enumerator(
            at: canonical, includingPropertiesForKeys: keys,
            options: [.skipsPackageDescendants], errorHandler: { _, _ in false }) else {
            throw GameStarterError.io("stage enumeration")
        }
        var folded = Set<String>()
        var fileCount = 0
        var byteCount = 0
        var entryCount = 0
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            entryCount += 1
            guard entryCount <= limits.maximumEntries else {
                throw GameStarterError.limitExceeded("stageEntries")
            }
            let values = try url.resourceValues(forKeys: Set(keys))
            if values.isSymbolicLink == true {
                throw GameStarterError.unsafePath(relative(url, root: canonical))
            }
            if values.isDirectory == true {
                let path = try GameRelativePath(relative(url, root: canonical))
                try validateName(path)
                continue
            }
            guard values.isRegularFile == true else {
                throw GameStarterError.unsafePath(relative(url, root: canonical))
            }
            let path = try GameRelativePath(relative(url, root: canonical))
            guard path.value.utf8.count <= limits.maximumPathBytes else {
                throw GameStarterError.limitExceeded("stagePath")
            }
            try registerFilePath(path, folded: &folded)
            guard let size = values.fileSize, size >= 0 else {
                throw GameStarterError.io("stage file size")
            }
            guard size <= limits.maximumFileBytes else {
                throw GameStarterError.limitExceeded(path.value)
            }
            fileCount += 1
            guard fileCount <= limits.maximumFiles else {
                throw GameStarterError.limitExceeded("stageFiles")
            }
            guard byteCount <= limits.maximumTotalBytes - size else {
                throw GameStarterError.limitExceeded("stageBytes")
            }
            byteCount += size
        }
        return .init(fileCount: fileCount, byteCount: byteCount, entryCount: entryCount)
    }

    private static func relative(_ url: URL, root: URL) -> String {
        let prefix = root.path + "/"
        return url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
    }

    /// Shared by enumeration and path-set validation. Kept independent of the
    /// filesystem so collisions can be tested on case-insensitive APFS too.
    static func registerFilePath(_ path: GameRelativePath, folded: inout Set<String>) throws {
        try validateName(path)
        let key = path.value.precomposedStringWithCanonicalMapping.lowercased()
        guard folded.insert(key).inserted else {
            throw GameStarterError.unsafePath("case-collision: \(path.value)")
        }
    }

    private static func validateName(_ path: GameRelativePath) throws {
        let components = path.value.split(separator: "/").map(String.init)
        guard !components.isEmpty else { throw GameStarterError.unsafePath(path.value) }
        let reserved: Set<String> = ["con", "prn", "aux", "nul",
                                     "com1", "com2", "com3", "com4", "com5", "com6", "com7", "com8", "com9",
                                     "lpt1", "lpt2", "lpt3", "lpt4", "lpt5", "lpt6", "lpt7", "lpt8", "lpt9"]
        for component in components {
            guard !component.isEmpty, component != ".", component != "..",
                  !component.hasPrefix("."), !component.hasSuffix("."),
                  !component.hasSuffix(" "), !component.contains("\\"),
                  !component.contains(":") else {
                throw GameStarterError.unsafePath(path.value)
            }
            let stem = component.split(separator: ".", maxSplits: 1,
                                       omittingEmptySubsequences: false).first.map(String.init) ?? component
            guard !reserved.contains(stem.lowercased()) else {
                throw GameStarterError.unsafePath(path.value)
            }
            guard !component.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw GameStarterError.unsafePath(path.value)
            }
        }
    }
}
