#if os(macOS)
import Foundation
import FloeMacBridgeProtocol

struct BridgePaths: Sendable {
    let root: URL
    let caches: URL
    let logs: URL
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        root = home.appendingPathComponent("Library/Application Support/Floe Bridge", isDirectory: true)
        caches = home.appendingPathComponent("Library/Caches/Floe Bridge", isDirectory: true)
        logs = home.appendingPathComponent("Library/Logs/Floe Bridge", isDirectory: true)
        for url in [root, caches, logs] + ["State", "Workspaces", "Tasks", "Skills", "Environments"].map({ root.appendingPathComponent($0) }) {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw BridgeFailure.unsafePath }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
    }
    func managed(_ category: String, id: String) throws -> URL {
        guard ["Workspaces", "Tasks", "Skills", "Environments"].contains(category), BridgeWire.validID(id) else { throw BridgeFailure.unsafePath }
        return try Self.safe(category + "/" + id, under: root)
    }
    static func safe(_ relative: String, under root: URL) throws -> URL {
        guard !relative.hasPrefix("/"), !relative.contains("\0"),
              relative.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && $0 != ".." && $0 != "." }) else { throw BridgeFailure.unsafePath }
        let base = root.resolvingSymlinksInPath().standardizedFileURL
        let url = base.appendingPathComponent(relative).standardizedFileURL
        guard url.path.hasPrefix(base.path + "/") else { throw BridgeFailure.unsafePath }
        var cursor = base
        for part in relative.split(separator: "/") {
            cursor.appendPathComponent(String(part))
            if (try? cursor.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true { throw BridgeFailure.unsafePath }
        }
        return url
    }
    static func files(in root: URL) throws -> [[String: BridgeValue]] {
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return [] }
        var result: [[String: BridgeValue]] = []
        for case let file as URL in entries {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            if BridgeWorkspaceTransferPolicy.excludes(relative) { entries.skipDescendants(); continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { entries.skipDescendants(); continue }
            guard values.isRegularFile == true else { continue }
            let path = String(file.path.dropFirst(root.path.count + 1))
            // Hash incrementally; large artifacts never enter one Data allocation.
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 256 * 1_024), !chunk.isEmpty { hasher.update(data: chunk) }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            result.append(["path": .string(path), "size": .integer(Int64(values.fileSize ?? 0)), "sha256": .string(digest)])
        }
        return result.sorted { ($0["path"]?.string ?? "") < ($1["path"]?.string ?? "") }
    }
}
import CryptoKit
#endif
