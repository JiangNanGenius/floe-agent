// FloeWorkspace — Explicit run-output publication tool.
//
// Publishes ONE known workspace-relative file as this run's stable user
// output (S3-D). The file must already exist as a real regular file created
// by this task (exec.shell at the guest `/workspace` share, background jobs,
// native producers, or any other committed workspace write). Nothing is
// auto-scanned and nothing is inferred from assistant prose, tool namespace
// or directory enumeration: the model names the exact file, the guard
// re-verifies containment on the host side, and the core
// RunOutputSnapshotStore freezes the real bytes into the run-owned
// `RunOutputs/<runID>/` namespace with a streamed SHA-256 + stat identity.
// The returned receipt is the immutable per-run user-file reference consumed
// by the exact-run reader and the Get Run Files intent.

import Foundation
import UniformTypeIdentifiers
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import FloeCore
import FloeModels
import FloeTools

/// Publishes one existing workspace file as a durable run output.
public struct WorkspacePublishOutputTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        /// Single bounded workspace-relative path of the file to publish.
        public var path: String
        /// Optional stable display name override; defaults to the file's
        /// basename. Must remain a safe single filename component.
        public var displayName: String?
        public var scope: String?

        public init(path: String, displayName: String? = nil, scope: String? = nil) {
            self.path = path
            self.displayName = displayName
            self.scope = scope
        }
    }

    public static let name = "workspace.publishOutput"
    public static let toolDescription =
        "Publish one existing workspace file as this run's stable user output. The file must already exist (created by exec.shell, a background job or another committed write). The run's snapshot keeps the exact current bytes; later edits or deletion of the workspace original never change the published output."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative path of the existing file to publish"},
        "displayName": {"type": "string", "description": "Optional stable display name (defaults to the file basename)"}
      },
      "required": ["path"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true

    /// Stable logical slot: this tool publishes exactly one file per call.
    static let slot = "output"

    private let environment: WorkspaceToolEnvironment
    public init(environment: WorkspaceToolEnvironment) {
        self.environment = environment
    }

    public func validate(_ args: Arguments) throws {
        let trimmed = args.path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw WorkspaceToolError.invalidArguments("path must not be empty")
        }
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else {
            throw WorkspaceToolError.invalidArguments(
                "path must be relative to the workspace root")
        }
        if let displayName = args.displayName {
            guard RunOutputFile.isValidDisplayName(displayName) else {
                throw WorkspaceToolError.invalidArguments(
                    "displayName must be a safe single filename component")
            }
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try WorkspaceToolSupport.rejectHostScope(context.scope)
        if let scope = args.scope, scope != "local" {
            throw WorkspaceToolError.unsupportedScope(scope)
        }
        try context.authorizeWorkspacePath(args.path)

        // Host-side re-verification: traversal, symlink containment and the
        // secret denylist all run again here even though the guest saw the
        // same bytes through the workspace share (guest listings are never
        // trusted for publication).
        let root = try environment.rootURL(context: context)
        let guarder = WorkspacePathGuard(
            rootURL: root,
            maxReadBytes: RunOutputCaps.standard.perFileBytes,
            maxWriteBytes: environment.maxWriteBytes,
            mounts: WorkspaceMountRegistry.shared.mounts(for: root)
        )
        let resolved = try guarder.resolve(args.path)

        // The LEXICAL final component must be a real regular file: a symlink
        // (even one pointing inside the workspace) is refused, so the frozen
        // snapshot can never be mistaken for a live alias of mutable bytes.
        // Intermediate components are resolved through the guard (which
        // enforces containment and mount roots); the final component is then
        // inspected lexically under its resolved parent.
        let standardized = (args.path.trimmingCharacters(in: .whitespaces) as NSString).standardizingPath
        let parentRelative = (standardized as NSString).deletingLastPathComponent
        let finalComponent = (standardized as NSString).lastPathComponent
        guard !finalComponent.isEmpty else {
            throw WorkspaceToolError.invalidArguments("path must name a file")
        }
        let resolvedParent: URL
        if parentRelative.isEmpty || parentRelative == "." {
            resolvedParent = root.standardizedFileURL.resolvingSymlinksInPath()
        } else {
            resolvedParent = try guarder.resolve(parentRelative)
        }
        let lexicalURL = resolvedParent.appendingPathComponent(finalComponent)
        var lexicalInfo = stat()
        guard lstat(lexicalURL.path, &lexicalInfo) == 0 else {
            throw WorkspaceToolError.notFound(args.path)
        }
        switch lexicalInfo.st_mode & mode_t(S_IFMT) {
        case mode_t(S_IFREG):
            break
        case mode_t(S_IFLNK):
            throw WorkspaceToolError.invalidArguments(
                "path must be a real file, not a symlink")
        default:
            throw WorkspaceToolError.invalidArguments(
                "path must be a regular file")
        }
        let byteCount = Int(lexicalInfo.st_size)
        guard byteCount <= RunOutputCaps.standard.perFileBytes else {
            throw WorkspaceToolError.tooLarge(limit: RunOutputCaps.standard.perFileBytes)
        }

        // Display name: explicit argument wins, else the real basename.
        let displayName = args.displayName ?? resolved.lastPathComponent
        guard RunOutputFile.isValidDisplayName(displayName) else {
            throw WorkspaceToolError.invalidArguments(
                "display name is not a safe single filename component")
        }

        // MIME/UTI identity from the real extension (bounded; the core store
        // validates the bounded fields again).
        let detected = UTType(filenameExtension: resolved.pathExtension)
        let mimeType = detected?.preferredMIMEType ?? "application/octet-stream"
        let uti = detected?.identifier

        // Streamed stat+digest of the real local bytes (1 MiB chunks, never a
        // whole-file load; cancellation aborts before the core copy begins).
        let sha256 = try FloeDigest.sha256Hex(
            ofFileAt: resolved,
            isCancelled: { context.cancellation.isCancelled }
        )
        try context.cancellation.throwIfCancelled()

        do {
            let published = try RunOutputSnapshotStore.publish(
                RunOutputSnapshotRequest(
                    producerTool: Self.name,
                    slot: Self.slot,
                    commit: RunOutputCommit(
                        sourceURL: resolved,
                        sha256: sha256,
                        byteCount: byteCount,
                        displayName: displayName,
                        mimeType: mimeType,
                        uti: uti
                    )
                ),
                using: context
            )
            return ToolExecutionOutput(
                digesting: "published=\(displayName) bytes=\(byteCount) sha256=\(sha256) "
                    + "output=\(published.relativePath)",
                exitStatus: 0,
                outputFiles: [published]
            )
        } catch let error as RunOutputSnapshotError {
            throw Self.publicationFailure(error)
        }
    }

    /// Maps a typed publication failure into an observable, path-free tool
    /// error. The workspace original is never touched here; only the receipt
    /// outcome changes. Cancellation (`FloeError.cancelled`) propagates as-is.
    static func publicationFailure(_ error: RunOutputSnapshotError) -> FloeError {
        switch error {
        case .bindingMissing: return FloeError.validationFailed("run output publication failed (unbound)")
        case .policyRefused: return FloeError.validationFailed("run output publication refused by policy")
        case .identityInvalid: return FloeError.validationFailed("run output publication failed (invalid identity)")
        case .sourceUnavailable: return FloeError.validationFailed("run output publication failed (source unavailable)")
        case .commitIdentityStale: return FloeError.validationFailed("run output publication failed (stale commit identity)")
        case .conflict(let name): return FloeError.validationFailed("run output publication failed (conflict: \(name))")
        case .overCap: return FloeError.validationFailed("run output publication failed (over cap)")
        case .snapshotAliased: return FloeError.validationFailed("run output publication failed (aliased snapshot)")
        case .ioFailure: return FloeError.storageCorrupted("run output publication failed (storage)")
        }
    }
}
