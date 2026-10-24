// FloeWorkspace — process-local registry for security-scoped folder mounts.

import Foundation

/// Maps a workspace's virtual `Mounts/<name>` paths to user-selected folders.
/// Bookmark ownership and security-scope lifetimes remain in the app layer;
/// this registry only gives every guarded file service the same resolved map.
public final class WorkspaceMountRegistry: @unchecked Sendable {
    public static let shared = WorkspaceMountRegistry()

    private let lock = NSLock()
    private struct Entry {
        var mounts: [String: URL]
        var owners: Int
    }
    private var values: [String: Entry] = [:]

    private init() {}

    public func register(rootURL: URL, mounts: [String: URL]) {
        let key = Self.key(for: rootURL)
        let safe = Dictionary(uniqueKeysWithValues: mounts.map { name, url in
            (name, url.standardizedFileURL.resolvingSymlinksInPath())
        })
        lock.lock()
        let owners = (values[key]?.owners ?? 0) + 1
        values[key] = Entry(mounts: safe, owners: owners)
        lock.unlock()
    }

    public func unregister(rootURL: URL) {
        lock.lock()
        let key = Self.key(for: rootURL)
        if let entry = values[key], entry.owners > 1 {
            values[key] = Entry(mounts: entry.mounts, owners: entry.owners - 1)
        } else {
            values.removeValue(forKey: key)
        }
        lock.unlock()
    }

    public func mounts(for rootURL: URL) -> [String: URL] {
        lock.lock()
        let result = values[Self.key(for: rootURL)]?.mounts ?? [:]
        lock.unlock()
        return result
    }

    private static func key(for url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}
