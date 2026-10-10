import Foundation

// FloeCore — Canvas-owned design workspace binding.
//
// Office/presentation/CAD design workflows need a real document the EXISTING
// editors can address. The binding creates a per-canvas, app-owned workspace
// (`Application Support/FloeAgent/DesignWorkspaces/<canvasID>`), copies the
// node's source bytes into it through a path guard, and records the
// workspace-relative document identity on the design subdocument. Existing
// editor services (OfficeCommandCenter, CadDocumentCenter) address the bound
// document through their normal workspace access — no parallel editor,
// runtime or project system. The Canvas remains the owner; deleting the
// canvas prunes the workspace.

public enum DesignWorkspaceBindingError: Error, Equatable {
    case invalidRelativePath(String)
    case sourceUnavailable(String)
}

public struct DesignWorkspaceBinding: Sendable, Equatable, Codable {
    /// Workspace root for one canvas (absolute, app-owned).
    public let workspaceRootPath: String
    /// Document path relative to the workspace root.
    public let relativeDocumentPath: String
    /// Real content format of the bound document.
    public let format: String

    public init(workspaceRootPath: String, relativeDocumentPath: String, format: String) {
        self.workspaceRootPath = workspaceRootPath
        self.relativeDocumentPath = relativeDocumentPath
        self.format = format
    }

    public var documentAbsolutePath: String {
        URL(fileURLWithPath: workspaceRootPath, isDirectory: true)
            .appendingPathComponent(relativeDocumentPath).path
    }
}

public enum DesignWorkspace {
    public static func root(canvasID: UUID) -> URL? {
        FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent("DesignWorkspaces", isDirectory: true)
            .appendingPathComponent(canvasID.uuidString.lowercased(), isDirectory: true)
    }

    /// Containment-checked relative path builder: the relative document path
    /// may never escape the workspace root.
    public static func contained(relativePath: String, in root: URL) throws -> URL {
        let trimmed = relativePath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("/"),
              trimmed.split(separator: "/").allSatisfy({ $0 != ".." && $0 != "." && !$0.isEmpty }) else {
            throw DesignWorkspaceBindingError.invalidRelativePath(relativePath)
        }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let resolved = trimmed.split(separator: "/").reduce(base) { partial, component in
            partial.appendingPathComponent(String(component))
        }.standardizedFileURL.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(base.path + "/") else {
            throw DesignWorkspaceBindingError.invalidRelativePath(relativePath)
        }
        return resolved
    }

    /// Binds a source file into the canvas workspace: copies the bytes,
    /// returns the binding. Idempotent per node document name.
    public static func bind(
        canvasID: UUID,
        nodeID: UUID,
        sourceFile: URL,
        format: String
    ) throws -> DesignWorkspaceBinding {
        guard let root = root(canvasID: canvasID) else {
            throw DesignWorkspaceBindingError.sourceUnavailable("workspace root unavailable")
        }
        let data = try Data(contentsOf: sourceFile, options: [.mappedIfSafe])
        guard !data.isEmpty else {
            throw DesignWorkspaceBindingError.sourceUnavailable("source file is empty")
        }
        let relative = "docs/\(nodeID.uuidString.lowercased()).\(format)"
        let target = try contained(relativePath: relative, in: root)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: target, options: .atomic)
        return DesignWorkspaceBinding(
            workspaceRootPath: root.standardizedFileURL.path,
            relativeDocumentPath: relative,
            format: format
        )
    }

    /// The ONLY write authority: the root is always re-derived from the
    /// canvas identity; a persisted absolute path is never trusted (imported
    /// JSON cannot grant write access), and the relative path is re-validated
    /// for containment and node ownership on every write.
    public static func documentURL(
        canvasID: UUID,
        relativePath: String,
        nodeID: UUID
    ) throws -> URL {
        guard let root = root(canvasID: canvasID) else {
            throw DesignWorkspaceBindingError.sourceUnavailable("workspace root unavailable")
        }
        // Node ownership: docs/<nodeID>.<ext> or docs/<nodeID>/… or
        // docs/<nodeID>.revisions/<sha>.<ext>.
        let prefix = "docs/\(nodeID.uuidString.lowercased())"
        guard relativePath.hasPrefix(prefix + ".") || relativePath.hasPrefix(prefix + "/") else {
            throw DesignWorkspaceBindingError.invalidRelativePath(relativePath)
        }
        return try contained(relativePath: relativePath, in: root)
    }

    /// The single binding authority for READ and WRITE: re-derives the root
    /// from the canvas identity, validates node ownership, containment and
    /// format against the DERIVED root, and returns a canonical binding.
    /// A workspaceRootPath recorded in imported/persisted metadata is never
    /// trusted — it cannot redirect reads or exports at another directory.
    public static func canonicalBinding(
        _ recorded: DesignWorkspaceBinding?,
        canvasID: UUID,
        nodeID: UUID
    ) throws -> DesignWorkspaceBinding? {
        guard let recorded else { return nil }
        guard let root = root(canvasID: canvasID) else {
            throw DesignWorkspaceBindingError.sourceUnavailable("workspace root unavailable")
        }
        // Validates ownership + containment under the derived root; throws
        // on traversal or foreign-node paths.
        let url = try documentURL(canvasID: canvasID, relativePath: recorded.relativeDocumentPath, nodeID: nodeID)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw DesignWorkspaceBindingError.sourceUnavailable("bound document is missing on disk")
        }
        let ext = (recorded.relativeDocumentPath as NSString).pathExtension.lowercased()
        guard ext == recorded.format.lowercased() else {
            throw DesignWorkspaceBindingError.invalidRelativePath("format does not match the bound path")
        }
        return DesignWorkspaceBinding(
            workspaceRootPath: root.standardizedFileURL.path,
            relativeDocumentPath: recorded.relativeDocumentPath,
            format: recorded.format
        )
    }

    /// Immutable, content-addressed revision file: adopted bytes land at
    /// `docs/<nodeID>.revisions/<sha256>.<format>` and are hash-verified on
    /// disk BEFORE any CAS references them. A crash after the CAS therefore
    /// leaves the binding pointing at fully-written bytes; a failed CAS
    /// leaves only a recyclable orphan.
    public struct RevisionFile: Sendable {
        public let relativePath: String
        public let contentSHA256: String
        public let byteCount: Int
    }

    public static func writeRevisionFile(
        bytes: Data,
        canvasID: UUID,
        nodeID: UUID,
        format: String
    ) throws -> RevisionFile {
        let sha = FloeDigest.sha256Hex(bytes)
        let relative = "docs/\(nodeID.uuidString.lowercased()).revisions/\(sha).\(format)"
        let target = try documentURL(canvasID: canvasID, relativePath: relative, nodeID: nodeID)
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory),
           !isDirectory.boolValue {
            // Immutable: identical bytes replay as the same revision file.
            let onDisk = try FloeDigest.sha256Hex(ofFileAt: target)
            guard onDisk == sha else {
                throw DesignWorkspaceBindingError.invalidRelativePath("revision file hash mismatch")
            }
            return RevisionFile(relativePath: relative, contentSHA256: sha, byteCount: bytes.count)
        }
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try bytes.write(to: target, options: .atomic)
        // Verify the full bytes landed before anyone references them.
        let written = try FloeDigest.sha256Hex(ofFileAt: target)
        guard written == sha else {
            try? FileManager.default.removeItem(at: target)
            throw DesignWorkspaceBindingError.sourceUnavailable("revision file failed verification")
        }
        return RevisionFile(relativePath: relative, contentSHA256: sha, byteCount: bytes.count)
    }

    /// Publishes a content-addressed revision as the STABLE editor alias
    /// (`docs/<nodeID>.<format>`) so existing editors reopen the latest
    /// content at their familiar path. This second write is explicitly NOT
    /// atomic with the CAS: it is protected by a recoverable journal and
    /// before/after hash checks; the revision file remains the authority and
    /// any mismatch is restored from it.
    public static func publishStableAlias(
        canvasID: UUID,
        nodeID: UUID,
        revision: RevisionFile,
        format: String
    ) throws {
        let aliasRelative = "docs/\(nodeID.uuidString.lowercased()).\(format)"
        let alias = try documentURL(canvasID: canvasID, relativePath: aliasRelative, nodeID: nodeID)
        let source = try documentURL(canvasID: canvasID, relativePath: revision.relativePath, nodeID: nodeID)
        try FileManager.default.createDirectory(
            at: alias.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        // Journal: expected alias hash after publish + the authoritative
        // revision, so an interrupted run can be repaired.
        let journalURL = alias.appendingPathExtension("alias-journal.json")
        let before = try? FloeDigest.sha256Hex(ofFileAt: alias)
        let journal: [String: String] = [
            "revision": revision.relativePath,
            "expectedAliasSHA256": revision.contentSHA256,
            "previousAliasSHA256": before ?? ""
        ]
        try JSONSerialization.data(withJSONObject: journal, options: [.sortedKeys])
            .write(to: journalURL, options: .atomic)
        // COPY (never move): the content-addressed revision file remains the
        // authority and survives the alias publish.
        do {
            let bytes = try Data(contentsOf: source, options: [.mappedIfSafe])
            try bytes.write(to: alias, options: .atomic)
            let after = try FloeDigest.sha256Hex(ofFileAt: alias)
            guard after == revision.contentSHA256 else {
                throw DesignWorkspaceBindingError.sourceUnavailable("alias publish failed verification")
            }
            try? FileManager.default.removeItem(at: journalURL)
        } catch {
            // Restore the alias from the authoritative revision bytes.
            try? Data(contentsOf: source, options: [.mappedIfSafe]).write(to: alias, options: .atomic)
            let restored = try? FloeDigest.sha256Hex(ofFileAt: alias)
            if restored != revision.contentSHA256 {
                // Leave the journal for recovery; the revision file is intact.
                throw DesignWorkspaceBindingError.sourceUnavailable(
                    "alias publish failed and auto-restore could not complete; journal retained"
                )
            }
            try? FileManager.default.removeItem(at: journalURL)
        }
    }

    /// Recovers an interrupted alias publish from its journal (launch-time
    /// reconcile hook). Returns true when a journal existed.
    @discardableResult
    public static func recoverPendingAlias(
        canvasID: UUID,
        nodeID: UUID
    ) throws -> Bool {
        let aliasRelative = "docs/\(nodeID.uuidString.lowercased())"
        guard let root = root(canvasID: canvasID) else { return false }
        let directory = try contained(relativePath: "docs", in: root)
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return false }
        var recovered = false
        for entry in entries where entry.hasSuffix(".alias-journal.json") {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(entry)),
                  let journal = try? JSONSerialization.jsonObject(with: data) as? [String: String],
                  let revisionRelative = journal["revision"] else { continue }
            let format = (revisionRelative as NSString).pathExtension
            // Node ownership + containment are validated by documentURL;
            // foreign revisions are skipped.
            guard let source = try? documentURL(
                canvasID: canvasID, relativePath: revisionRelative, nodeID: nodeID
            ) else { continue }
            let alias = try documentURL(
                canvasID: canvasID,
                relativePath: "docs/\(nodeID.uuidString.lowercased()).\(format)",
                nodeID: nodeID
            )
            try? FileManager.default.removeItem(at: alias)
            try? FileManager.default.copyItem(at: source, to: alias)
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(entry))
            recovered = true
        }
        return recovered
    }

}
