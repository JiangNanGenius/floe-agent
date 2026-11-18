#if os(macOS)
import Foundation
import FloeMacBridgeProtocol
import Darwin

/// Fresh, separate namespace for a future explicit re-pair flow. Merely
/// constructing this value does not access or migrate the legacy Bridge.
/// The port is a proposed distinct endpoint, not a reservation of it.
struct BridgeIsolatedProfile: Sendable {
    static let identityService = "org.floeagent.mac.bridge-isolated.server.v1"
    static let endpointPort: UInt16 = 43872
    let home: URL
    let root: URL
    let caches: URL
    let logs: URL
    let endpoint: URL

    init(home: URL) throws {
        guard home.isFileURL else { throw BridgeFailure.unsafePath }
        let home = home.resolvingSymlinksInPath().standardizedFileURL
        guard home.path != "/" else { throw BridgeFailure.unsafePath }
        self.home = home
        root = home.appendingPathComponent("Library/Application Support/Floe Mac/Isolated Bridge/v1", isDirectory: true)
        caches = home.appendingPathComponent("Library/Caches/Floe Mac/Isolated Bridge/v1", isDirectory: true)
        logs = home.appendingPathComponent("Library/Logs/Floe Mac/Isolated Bridge/v1", isDirectory: true)
        endpoint = URL(string: "http://127.0.0.1:\(Self.endpointPort)/rpc")!
    }
}

struct BridgePaths: Sendable {
    enum Namespace: Sendable { case legacy, isolated }
    let root: URL
    let caches: URL
    let logs: URL
    let namespace: Namespace
    init(home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        namespace = .legacy
        root = home.appendingPathComponent("Library/Application Support/Floe Bridge", isDirectory: true)
        caches = home.appendingPathComponent("Library/Caches/Floe Bridge", isDirectory: true)
        logs = home.appendingPathComponent("Library/Logs/Floe Bridge", isDirectory: true)
        for url in [root, caches, logs] + ["State", "Workspaces", "Tasks", "Skills", "Environments"].map({ root.appendingPathComponent($0) }) {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else { throw BridgeFailure.unsafePath }
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                   attributes: [.posixPermissions: 0o700])
        }
    }

    /// Creates only the isolated profile paths by walking from the selected
    /// home without following links. This is preparation, not a lifetime
    /// storage lease: future production integration must also protect against
    /// later path replacement and retain a real lock before opening a store.
    init(isolated profile: BridgeIsolatedProfile) throws {
        let groups: [[String]] = [
            ["Library", "Application Support", "Floe Mac", "Isolated Bridge", "v1"],
            ["Library", "Caches", "Floe Mac", "Isolated Bridge", "v1"],
            ["Library", "Logs", "Floe Mac", "Isolated Bridge", "v1"]
        ]
        for components in groups { try Self.createIsolatedDirectory(home: profile.home, components: components) }
        for category in ["State", "Workspaces", "Tasks", "Skills", "Environments"] {
            try Self.createIsolatedDirectory(home: profile.home, components: groups[0] + [category])
        }
        namespace = .isolated
        root = profile.root; caches = profile.caches; logs = profile.logs
    }

    private static func createIsolatedDirectory(home: URL, components: [String]) throws {
        var fd = open(home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw BridgeFailure.unsafePath }
        defer { close(fd) }
        for (index, component) in components.enumerated() {
            guard !component.isEmpty, component != ".", component != "..", !component.contains("/") else {
                throw BridgeFailure.unsafePath
            }
            if mkdirat(fd, component, mode_t(0o700)) != 0 && errno != EEXIST { throw BridgeFailure.unsafePath }
            let next = openat(fd, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw BridgeFailure.unsafePath }
            var info = stat()
            guard fstat(next, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == geteuid(),
                  // Reject an already-existing isolated namespace readable or
                  // writable by other users; do not silently chmod it.
                  (index < 3 || (info.st_mode & 0o077) == 0) else {
                close(next); throw BridgeFailure.unsafePath
            }
            close(fd); fd = next
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
        var readError: Error?
        guard let entries = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            errorHandler: { _, error in readError = error; return false }) else {
            throw BridgeFailure.remote("The Mac workspace could not be listed.")
        }
        var result: [[String: BridgeValue]] = []
        for case let file as URL in entries {
            // The enumerator can return /private/var for a /var root. Its
            // directory depth identifies the child's relative path in both.
            guard entries.level > 0 else { throw BridgeFailure.unsafePath }
            let relative = file.pathComponents.suffix(entries.level).joined(separator: "/")
            if BridgeWorkspaceTransferPolicy.excludes(relative) { entries.skipDescendants(); continue }
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { entries.skipDescendants(); continue }
            guard values.isRegularFile == true else { continue }
            guard result.count < BridgeResponseValidation.maximumListedFiles else {
                throw BridgeFailure.remote("The workspace has too many files to synchronize.")
            }
            // Hash incrementally; large artifacts never enter one Data allocation.
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 256 * 1_024), !chunk.isEmpty { hasher.update(data: chunk) }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            result.append(["path": .string(relative), "size": .integer(Int64(values.fileSize ?? 0)), "sha256": .string(digest)])
        }
        if let readError { throw readError }
        return result.sorted { ($0["path"]?.string ?? "") < ($1["path"]?.string ?? "") }
    }
}
import CryptoKit
#endif
