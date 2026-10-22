// SPDX-License-Identifier: MPL-2.0
//
// G03-R2 — trusted engine-private root policy for the Linux authority.
//
// The ORIGINAL FloeEnvironments layer remains the only filesystem authority;
// this file just decides, fail-closed, WHICH three roots a trusted
// `configure` may hand to it. Rules (Main decisions 2026-10-22):
// - explicit normalized absolute paths only — nothing is defaulted, never a
//   temporary location, never the process home root itself;
// - each root is canonicalized with POSIX realpath (symlinked ANCESTORS are
//   accepted and normalized — e.g. Android's /data/user equivalence — but a
//   leaf symlink that would escape the expected location is caught by the
//   containment checks below and at workspace creation);
// - the three roots must be pairwise disjoint and no root may contain
//   another, so workspace enumeration can never reach the registry store or
//   the base slices;
// - world-accessible/system partitions and the process temp directory are
//   refused outright.

import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// One validated root: what was declared, its canonical realpath, and the
/// file URL the original authority is constructed with.
public struct LinuxAuthorityResolvedRoot: Sendable, Equatable {
    public let declaredPath: String
    public let canonicalPath: String
    public let url: URL

    init(declaredPath: String, canonicalPath: String) {
        self.declaredPath = declaredPath
        self.canonicalPath = canonicalPath
        self.url = URL(fileURLWithPath: canonicalPath, isDirectory: true)
    }
}

enum LinuxAuthorityRootPolicy {
    /// Exact paths that may never be a root.
    private static let forbiddenExactPaths: Set<String> = [
        "/", "/tmp", "/private/tmp", "/data", "/data/local", "/storage", "/sdcard",
        "/mnt", "/apex", "/system", "/vendor", "/product", "/system_ext", "/odm",
        "/dev", "/proc", "/sys", "/home", "/Users", "/var", "/private", "/usr",
        "/Volumes", "/System",
    ]

    /// Paths whose descendants are never an acceptable engine-private root
    /// (world-writable staging, external storage, system partitions, mount
    /// tables and virtual filesystems).
    private static let forbiddenAncestorPaths: [String] = [
        "/tmp", "/private/tmp", "/data/local", "/storage", "/sdcard", "/mnt",
        "/apex", "/system", "/vendor", "/product", "/system_ext", "/odm",
        "/dev", "/proc", "/sys", "/Volumes",
    ]

    /// Validates shape, creates the leaf when its parent exists, resolves
    /// symlinks and applies the location + containment gates. Throws
    /// `LinuxAuthorityError` with the documented codes.
    static func validate(path: String, role: String) throws -> LinuxAuthorityResolvedRoot {
        guard validateShape(path) else {
            throw LinuxAuthorityError(code: .invalidRoot, message: "\(role) must be an absolute, normalized path without control characters")
        }
        // Cheap string-level rejection FIRST so a forbidden location never
        // reaches the filesystem (no leaf creation inside /tmp-style roots).
        try rejectForbiddenLocation(path, role: role, includeTempRealpath: false)
        let fileManager = FileManager.default
        var createdLeaf = false
        if !fileManager.fileExists(atPath: path) {
            let parent = (path as NSString).deletingLastPathComponent
            guard !parent.isEmpty, fileManager.fileExists(atPath: parent, isDirectory: nil) else {
                throw LinuxAuthorityError(code: .rootParentMissing, message: "\(role) parent directory does not exist: \(parent)")
            }
            // A symlinked/temp parent is forbidden before anything is created.
            if let parentCanonical = posixRealpath(parent) {
                try rejectForbiddenLocation(parentCanonical, role: role, includeTempRealpath: true)
            }
            do {
                try fileManager.createDirectory(atPath: path, withIntermediateDirectories: false)
                createdLeaf = true
            } catch {
                throw LinuxAuthorityError(code: .invalidRoot, message: "\(role) could not be created: \(LinuxAuthorityWire.boundedMessage(error.localizedDescription))")
            }
        } else if !fileManager.fileExists(atPath: path, isDirectory: nil) {
            throw LinuxAuthorityError(code: .invalidRoot, message: "\(role) is not a directory")
        }
        guard let canonical = posixRealpath(path) else {
            cleanupCreatedLeaf(createdLeaf, path: path)
            throw LinuxAuthorityError(code: .rootNotResolvable, message: "\(role) could not be canonicalized (broken symlink or vanished path)")
        }
        do {
            try rejectForbiddenLocation(canonical, role: role, includeTempRealpath: true)
        } catch {
            cleanupCreatedLeaf(createdLeaf, path: path)
            throw error
        }
        return LinuxAuthorityResolvedRoot(declaredPath: path, canonicalPath: canonical)
    }

    private static func cleanupCreatedLeaf(_ created: Bool, path: String) {
        guard created else { return }
        // Only ever removes the leaf THIS call just created, and only when
        // the validation immediately after creation failed.
        try? FileManager.default.removeItem(atPath: path)
    }

    /// The three configured roots must be distinct and mutually exclusive.
    static func validateDisjoint(_ roots: [LinuxAuthorityResolvedRoot]) throws {
        var paths = roots.map(\.canonicalPath)
        paths.sort()
        for index in roots.indices {
            for other in roots.indices where other != index {
                if pathsSetContainsAncestor(ancestor: roots[other].canonicalPath, descendant: roots[index].canonicalPath) {
                    throw LinuxAuthorityError(code: .rootContainmentViolation,
                                              message: "no configured root may contain or equal another root")
                }
            }
        }
    }

    /// Creates/resolves one explicit workspace `parentCanonical/<name>` under
    /// a validated parent. The result must be EXACTLY the expected child: a
    /// symlink (in the name or as a leaf) that redirects elsewhere fails
    /// closed, because the original coordinator will later key the workspace
    /// owner by this exact canonical path.
    static func workspace(parentCanonicalPath: String, name: String) throws -> LinuxAuthorityResolvedRoot {
        let expected = parentCanonicalPath + "/" + name
        guard validateNameComponent(name) else {
            throw LinuxAuthorityError(code: .workspaceUnavailable, message: "workspace name component is not a safe canonical identifier")
        }
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: expected) {
            do {
                try fileManager.createDirectory(atPath: expected, withIntermediateDirectories: false)
            } catch {
                throw LinuxAuthorityError(code: .workspaceUnavailable, message: "workspace could not be created under the configured workspaces root")
            }
        } else if !fileManager.fileExists(atPath: expected, isDirectory: nil) {
            throw LinuxAuthorityError(code: .workspaceUnavailable, message: "workspace path exists and is not a directory")
        }
        guard let canonical = posixRealpath(expected) else {
            throw LinuxAuthorityError(code: .workspaceUnavailable, message: "workspace could not be canonicalized")
        }
        guard canonical == expected else {
            throw LinuxAuthorityError(code: .workspaceUnavailable, message: "workspace symlinks outside its canonical location under the configured workspaces root")
        }
        try rejectForbiddenLocation(canonical, role: "workspace", includeTempRealpath: true)
        return LinuxAuthorityResolvedRoot(declaredPath: expected, canonicalPath: canonical)
    }

    /// Canonical realpath for helpers/tests; nil when unresolvable.
    static func posixRealpath(_ path: String) -> String? {
        guard !path.isEmpty else { return nil }
        return path.withCString { cPath in
            guard let resolved = realpath(cPath, nil) else { return nil }
            defer { free(resolved) }
            return String(cString: resolved)
        }
    }

    // MARK: - Internals

    private static func validateShape(_ path: String) -> Bool {
        guard !path.isEmpty, path.utf8.count <= LinuxAuthorityWire.maximumRootPathBytes else { return false }
        guard path.hasPrefix("/"), path != "/" else { return false }
        guard !path.hasSuffix("/") else { return false }
        guard !path.unicodeScalars.contains(where: { $0 == "\u{0}" || CharacterSet.controlCharacters.contains($0) }) else { return false }
        let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard standardized == path else { return false }
        return true
    }

    private static func validateNameComponent(_ name: String) -> Bool {
        guard !name.isEmpty, name.utf8.count <= 64 else { return false }
        guard !name.contains("/"), name != ".", name != ".." else { return false }
        return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "." }
    }

    private static func rejectForbiddenLocation(_ candidate: String, role: String, includeTempRealpath: Bool) throws {
        if forbiddenExactPaths.contains(candidate) {
            throw LinuxAuthorityError(code: .rootLocationForbidden, message: "\(role) may not be a shared/system root location")
        }
        for forbidden in forbiddenAncestorPaths where candidate == forbidden || candidate.hasPrefix(forbidden + "/") {
            throw LinuxAuthorityError(code: .rootLocationForbidden, message: "\(role) may not live under \(forbidden)")
        }
        guard includeTempRealpath else { return }
        let tempCanonical = posixRealpath(FileManager.default.temporaryDirectory.path)
            ?? FileManager.default.temporaryDirectory.standardizedFileURL.path
        if candidate == tempCanonical || candidate.hasPrefix(tempCanonical + "/") {
            throw LinuxAuthorityError(code: .rootLocationForbidden, message: "\(role) may not live in the process temporary directory")
        }
    }

    private static func pathsSetContainsAncestor(ancestor: String, descendant: String) -> Bool {
        ancestor == descendant || descendant.hasPrefix(ancestor + "/")
    }
}
