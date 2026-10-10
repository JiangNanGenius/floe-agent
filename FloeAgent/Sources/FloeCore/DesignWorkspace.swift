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

    /// Writes adopted/restored bytes back to the bound document (the existing
    /// editor reopens the file). Containment is re-validated.
    public static func write(bytes: Data, to binding: DesignWorkspaceBinding) throws {
        guard let root = URL(string: "file://\(binding.workspaceRootPath)") else {
            throw DesignWorkspaceBindingError.invalidRelativePath(binding.workspaceRootPath)
        }
        let target = try contained(relativePath: binding.relativeDocumentPath, in: root)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try bytes.write(to: target, options: .atomic)
    }
}
