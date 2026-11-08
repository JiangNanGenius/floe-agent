// FloeWorkspace — Path safety layer.
// See docs/ARCHITECTURE_AGENT_WORKSPACE.md §3: `WorkspacePathGuard` is the
// single choke point for every file access performed by workspace tools and
// the file inspector. It rejects empty/absolute paths, expands "." / "..",
// resolves symlinks, enforces root containment, excludes secret files, and
// caps read/write sizes.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Android)
import Android
#endif

/// Guards every file-system access against a fixed workspace root.
///
/// All workspace tools and the file inspector must resolve paths through
/// this guard; the view layer never concatenates URLs directly.
public struct WorkspacePathGuard: Sendable {

    /// The workspace root. Access is confined beneath this URL.
    public let rootURL: URL
    /// Maximum bytes a single read operation may touch (default 10 MiB).
    public let maxReadBytes: Int
    /// Maximum bytes a single write operation may touch (default 4 MiB).
    public let maxWriteBytes: Int

    /// Standardized root path used for containment prefix checks.
    private let rootPath: String
    /// User-selected folders exposed under virtual `Mounts/<name>` paths.
    private let mounts: [String: URL]

    public init(
        rootURL: URL,
        maxReadBytes: Int = 10 * 1024 * 1024,
        maxWriteBytes: Int = 4 * 1024 * 1024,
        mounts: [String: URL] = [:]
    ) {
        let standardized = (try? Self.resolveComponents(rootURL.standardizedFileURL))
            ?? rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.rootURL = standardized
        self.rootPath = standardized.path
        self.maxReadBytes = maxReadBytes
        self.maxWriteBytes = maxWriteBytes
        self.mounts = Dictionary(uniqueKeysWithValues: mounts.map { name, url in
            (name, (try? Self.resolveComponents(url.standardizedFileURL))
                ?? url.standardizedFileURL.resolvingSymlinksInPath())
        })
    }

    /// Basename denylist: exact matches and prefixes (case-insensitive).
    private static let secretExactNames: Set<String> = [
        ".netrc", ".npmrc", ".pypirc", ".git-credentials", ".htpasswd"
    ]
    private static let secretPrefixes: [String] = [
        ".env", "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519", ".pgpass"
    ]
    private static let secretExtensions: Set<String> = [
        "pem", "key", "keystore", "p12", "pfx", "jks"
    ]
    /// Any path component equal to one of these marks the path as secret.
    private static let secretDirectories: Set<String> = [".ssh", ".aws", ".gnupg"]

    /// Resolves a workspace-relative path to a safe, fully-resolved URL.
    ///
    /// 1. Rejects empty paths and absolute paths ("/" / "~" prefixed).
    /// 2. Expands "." / ".." via `NSString.standardizingPath`.
    /// 3. Joins the root and resolves symlinks.
    /// 4. The result must still be prefixed by the standardized root path,
    ///    otherwise throws `.escapesRoot`.
    /// 5. Paths hitting the secret exclusion list throw `.secretFile`.
    ///
    /// Size caps are enforced by `assertReadableSize` / `assertWritableSize`
    /// because they require the concrete payload/existing file size.
    public func resolve(_ path: String) throws -> URL {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw WorkspaceToolError.invalidArguments("path must not be empty")
        }
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else {
            throw WorkspaceToolError.invalidArguments("path must be relative to the workspace root: \(path)")
        }

        // Expand "." / ".." before joining so ".." cannot smuggle a segment
        // past the root prefix check below.
        let normalized = (trimmed as NSString).standardizingPath
        let pathComponents = normalized.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        let joined: URL
        let allowedRootPath: String
        if pathComponents.count >= 2,
           pathComponents[0] == "Mounts",
           let mountRoot = mounts[pathComponents[1]] {
            joined = pathComponents.dropFirst(2).reduce(mountRoot) { partial, component in
                partial.appendingPathComponent(component)
            }
            allowedRootPath = mountRoot.path
        } else {
            joined = rootURL.appendingPathComponent(normalized)
            allowedRootPath = rootPath
        }
        let resolved = try Self.resolveComponents(joined)

        let resolvedPath = resolved.path
        guard resolvedPath == allowedRootPath || resolvedPath.hasPrefix(allowedRootPath + "/") else {
            throw WorkspaceToolError.escapesRoot(path)
        }
        if isSecretPath(resolved) {
            throw WorkspaceToolError.secretFile(path)
        }
        return resolved
    }

    /// Returns true when `url` matches the secret-file exclusion list.
    public func isSecretPath(_ url: URL) -> Bool {
        let components = url.pathComponents
        for component in components {
            if Self.secretDirectories.contains(component) {
                return true
            }
        }
        let name = url.lastPathComponent
        let lowered = name.lowercased()
        if Self.secretExactNames.contains(lowered) {
            return true
        }
        for prefix in Self.secretPrefixes where lowered.hasPrefix(prefix) {
            return true
        }
        let ext = url.pathExtension.lowercased()
        if !ext.isEmpty && Self.secretExtensions.contains(ext) {
            return true
        }
        // `.git/config` (and other VCS internals that commonly hold tokens).
        if components.count >= 2,
           let gitIndex = components.lastIndex(of: ".git"),
           gitIndex < components.count - 1 {
            let inside = components[(gitIndex + 1)...]
            if inside.first == "config" || inside.first == "credentials" {
                return true
            }
        }
        return false
    }

    /// Asserts the target of a write is inside the root and not secret.
    /// Unlike `resolve`, this does not require the file to exist.
    public func assertWritable(_ url: URL) throws {
        let resolved = try Self.resolveComponents(url.standardizedFileURL)
        let path = resolved.path
        let allowedPaths = [rootPath] + mounts.values.map(\.path)
        guard allowedPaths.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) else {
            throw WorkspaceToolError.escapesRoot(url.path)
        }
        if isSecretPath(resolved) {
            throw WorkspaceToolError.secretFile(url.lastPathComponent)
        }
    }

    /// Asserts an existing file does not exceed the read cap.
    public func assertReadableSize(_ url: URL) throws {
        guard let size = try fileSize(url) else { return }
        guard size <= maxReadBytes else {
            throw WorkspaceToolError.tooLarge(limit: maxReadBytes)
        }
    }

    /// Asserts a payload of `bytes` does not exceed the write cap.
    public func assertWritableSize(bytes: Int) throws {
        guard bytes <= maxWriteBytes else {
            throw WorkspaceToolError.tooLarge(limit: maxWriteBytes)
        }
    }

    /// Size of the file at `url`, or nil when the size cannot be determined
    /// (e.g. the file does not exist yet).
    private func fileSize(_ url: URL) throws -> Int? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.intValue
    }

    /// Foundation may leave an entire path unresolved when its final child
    /// does not exist yet. Resolve each existing component instead, including
    /// dangling links, before accepting a new output's namespace. No mkdir or
    /// write occurs here; internal links and explicit mount roots still work.
    private static func resolveComponents(_ url: URL) throws -> URL {
        var pending = url.standardizedFileURL.pathComponents.filter { $0 != "/" && !$0.isEmpty }
        var index = 0, links = 0
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        while index < pending.count {
            let name = pending[index]; index += 1
            if name == "." { continue }
            if name == ".." { if current.path != "/" { current.deleteLastPathComponent() }; continue }
            let next = current.appendingPathComponent(name)
            var info = stat()
            if lstat(next.path, &info) == 0 {
                if info.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                    links += 1
                    guard links <= 40 else { throw WorkspaceToolError.invalidArguments("path contains too many symbolic links") }
                    let target = try FileManager.default.destinationOfSymbolicLink(atPath: next.path)
                    guard !target.isEmpty else { throw WorkspaceToolError.invalidArguments("empty symbolic-link target") }
                    let tail = Array(pending[index...])
                    pending = target.split(separator: "/", omittingEmptySubsequences: true).map(String.init) + tail
                    index = 0
                    if target.hasPrefix("/") { current = URL(fileURLWithPath: "/", isDirectory: true) }
                    continue
                }
            } else if errno != ENOENT {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            current = next
        }
        // The walk already normalizes dot segments. Re-standardizing here
        // can rewrite an existing /private/var prefix to /var while leaving
        // a missing descendant unchanged, producing inconsistent identities.
        return current
    }
}

/// Access-specific policy applied on top of path resolution. The guard's
/// configured defaults previously shadowed larger tool limits (a 10 MiB
/// default made a tool's own 64 MiB check unreachable); callers now state the
/// cap they mean, once.
public enum WorkspacePathAccess: Sendable {
    case read(maxBytes: Int)
    case createNew
    case replace(consent: Bool)
}

public extension WorkspacePathGuard {
    func resolve(_ path: String, for access: WorkspacePathAccess) throws -> URL {
        let url = try resolve(path)
        switch access {
        case .read(let maxBytes):
            if let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
               values.isDirectory == true {
                throw WorkspaceToolError.isDirectory(path)
            }
            if let size = try fileSize(url), size > maxBytes {
                throw WorkspaceToolError.tooLarge(limit: maxBytes)
            }
        case .createNew:
            guard !FileManager.default.fileExists(atPath: url.path) else {
                throw WorkspaceToolError.alreadyExists(path)
            }
        case .replace(let consent):
            if !consent, FileManager.default.fileExists(atPath: url.path) {
                throw WorkspaceToolError.alreadyExistsOverwritable(path)
            }
        }
        return url
    }
}
