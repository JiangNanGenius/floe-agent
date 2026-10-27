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
//
// ANDROID MIRROR DELTA (FloeAndroid/shared, D04 producer batch,
// job-3135f83ef97c4a21): ported byte-for-byte from iOS main 8f185ac blob
// c85a3b0c074b27d71ff3762e08e66f7c7dafd778 except two narrow platform
// adaptations:
//   1. `UniformTypeIdentifiers`/`UTType` is Apple-only. On Apple platforms
//      MIME/UTI detection is unchanged; elsewhere a bounded extension→MIME
//      table (documented below, `application/octet-stream` fallback, no UTI)
//      fills the same commit fields. The core store re-validates every
//      bounded field either way.
//   2. `artifactRootProvider`: on Android the run-output store lives under
//      the trusted runtime composition's owned persistent root (there is no
//      implicit Application Support authority, and the Foundation default
//      can resolve below `$HOME`). The provider supplied by
//      `RuntimeFacadeRunOutput` registration is passed to the core store;
//      when the binding is absent the store fails closed. Apple default
//      (`nil` → `FloeArtifactStore.root()`) is unchanged.
//   3. D04 lifetime fix (coordinator review 2026-10-27): `operationGate`
//      holds a generation-bound publication lease across the whole store
//      call (cleanup probes consult it — no race with an active publisher)
//      and refuses to advertise a receipt whose generation was retired or
//      rebound during publication (committed bytes preserved);
//      `registerWorkspacePublishOutputTool` additionally wires the ACTUAL
//      `isAvailable` discovery gate used by the existing
//      `ToolRunnerRegistry`/`CatalogToolExecutor` contract (a retired
//      binding removes the executable surface through the gate, not
//      pretend catalog deletion).
// The public tool name, schema, slot, `writesFiles` risk label, host-scope
// refusal, path authorization, guard re-verification and typed path-free
// failures are exactly the upstream contract — no new alias, no parallel
// receipt format.

import Foundation
#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif
#if canImport(Darwin)
import Darwin
#elseif canImport(Android)
import Android
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
    /// ANDROID delta: supplies the trusted artifact-store root for the core
    /// snapshot publication (see file header). `nil` keeps the upstream
    /// default-root behavior on Apple platforms; on Android a `nil` result
    /// fails closed inside the store — never a HOME or temporary fallback.
    private let artifactRootProvider: (@Sendable () -> URL?)?
    /// ANDROID delta (D04 lifetime fix): the generation-bound operation
    /// gate. When configured, every publication holds a lease for the
    /// whole store call (so cleanup never races an active publisher) and
    /// REVALIDATES the ticket at the completion boundary: a publication
    /// whose generation was retired or rebound mid-flight preserves its
    /// committed bytes but never advertises the stale receipt. `nil`
    /// (host-focused fixtures) keeps the upstream single-call semantics.
    private let operationGate: (any RunOutputOperationGate)?

    public init(
        environment: WorkspaceToolEnvironment,
        artifactRootProvider: (@Sendable () -> URL?)? = nil,
        operationGate: (any RunOutputOperationGate)? = nil
    ) {
        self.environment = environment
        self.artifactRootProvider = artifactRootProvider
        self.operationGate = operationGate
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
        // validates the bounded fields again). Apple platforms use UTType
        // exactly as upstream; the Android fallback table below is consulted
        // only where UniformTypeIdentifiers cannot be imported.
        let detected = Self.detectContentIdentity(pathExtension: resolved.pathExtension)
        let mimeType = detected.mimeType
        let uti = detected.uniformTypeIdentifier

        // Streamed stat+digest of the real local bytes (1 MiB chunks, never a
        // whole-file load; cancellation aborts before the core copy begins).
        let sha256 = try FloeDigest.sha256Hex(
            ofFileAt: resolved,
            isCancelled: { context.cancellation.isCancelled }
        )
        try context.cancellation.throwIfCancelled()

        // D04 lifetime fix (ANDROID delta): hold the generation-bound
        // operation lease for the WHOLE publication so a concurrent
        // conversation cleanup can never race an active publisher (the
        // cleanup probes consult this lease), and revalidate the ticket at
        // the completion boundary: bytes committed under a generation that
        // was retired or rebound mid-flight are preserved but the receipt
        // is refused — never advertised as usable ownership.
        let ticket: RunOutputPublicationTicket?
        if let operationGate {
            guard let begun = operationGate.beginPublication(runID: context.runID) else {
                throw FloeError.validationFailed(
                    "run output publication failed (no current trusted generation binding)")
            }
            ticket = begun
        } else {
            ticket = nil
        }
        defer { if let ticket { operationGate?.endPublication(ticket) } }
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
                using: context,
                // The root comes from the SAME atomic ticket capture when
                // a gate is configured (never a separately re-read value
                // that a retire/rebind could split from the lease); a
                // gate-less fixture keeps the injected provider/default.
                artifactRoot: ticket?.artifactRoot ?? artifactRootProvider?()
            )
            if let ticket, operationGate?.isPublicationCurrent(ticket) == false {
                throw FloeError.validationFailed(
                    "run output publication failed (generation retired during publication; committed bytes preserved)")
            }
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

    /// ANDROID delta (see file header): content identity for the commit
    /// fields. Where `UniformTypeIdentifiers` is available this is exactly
    /// the upstream UTType path (identifier + preferred MIME type).
    /// Elsewhere a bounded lowercase extension→MIME table answers with the
    /// SAME values UTType reports for the document/media types Floe
    /// publishes, and unknown extensions fall back to
    /// `application/octet-stream` with no UTI. Nothing here widens the
    /// publication contract: the core store re-validates both bounded
    /// fields, and no receipt ever depends on this mapping for identity
    /// (outputID derives from run/call/slot only).
    static func detectContentIdentity(
        pathExtension: String
    ) -> (mimeType: String, uniformTypeIdentifier: String?) {
        #if canImport(UniformTypeIdentifiers)
        let detected = UTType(filenameExtension: pathExtension)
        return (
            detected?.preferredMIMEType ?? "application/octet-stream",
            detected?.identifier
        )
        #else
        let ext = pathExtension.lowercased()
        if ext.isEmpty { return ("application/octet-stream", nil) }
        if let mime = fallbackMIMEByExtension[ext] { return (mime, nil) }
        return ("application/octet-stream", nil)
        #endif
    }

    /// Bounded fallback table (ANDROID delta): keys are lowercase
    /// extensions, values are the same MIME strings `UTType` reports for
    /// these common producers on Apple platforms.
    #if !canImport(UniformTypeIdentifiers)
    static let fallbackMIMEByExtension: [String: String] = [
        "txt": "text/plain",
        "md": "text/markdown",
        "csv": "text/csv",
        "json": "application/json",
        "html": "text/html",
        "htm": "text/html",
        "xml": "text/xml",
        "pdf": "application/pdf",
        "doc": "application/msword",
        "docx": "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls": "application/vnd.ms-excel",
        "xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt": "application/vnd.ms-powerpoint",
        "pptx": "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        "odt": "application/vnd.oasis.opendocument.text",
        "ods": "application/vnd.oasis.opendocument.spreadsheet",
        "odp": "application/vnd.oasis.opendocument.presentation",
        "rtf": "application/rtf",
        "zip": "application/zip",
        "gz": "application/gzip",
        "tar": "application/x-tar",
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
        "heic": "image/heic",
        "svg": "image/svg+xml",
        "tif": "image/tiff",
        "tiff": "image/tiff",
        "mp3": "audio/mpeg",
        "m4a": "audio/x-m4a",
        "wav": "audio/wav",
        "aac": "audio/aac",
        "flac": "audio/flac",
        "mp4": "video/mp4",
        "mov": "video/quicktime",
        "m4v": "video/x-m4v",
    ]
    #endif
}

// MARK: - Registration entry (ANDROID mirror of WorkspaceToolRegistration)

/// Registers the run-output publisher into the EXISTING configured
/// tool registry: the compile-time `ToolCatalog` descriptor plus a concrete
/// runner in the supplied `ToolRunnerRegistry` — the same two-sided
/// requirement as iOS `registerWorkspaceTools`
/// (FloeAgent/Sources/FloeWorkspace/WorkspaceToolRegistration.swift),
/// scoped on Android to exactly this tool because the other workspace file
/// tools have their own lane. `ToolRunnerRegistry.register` replaces by
/// name, so a generation rebind re-registers with the fresh providers
/// atomically.
///
/// D04 lifetime fix: `isAvailable` is the ACTUAL discovery filter —
/// `ToolRunnerRegistry.runner(named:)` and `allDescriptors` (the
/// `CatalogToolExecutor` executable surface) already evaluate it, so after
/// a retirement the runner stops being reachable/advertised without any
/// removal dance. The compile-time `ToolCatalog` descriptor remains exactly
/// what the existing contract says it is ("A static catalog entry is
/// documentation, not an executable tool" — CatalogToolExecutor.allDescriptors
/// comes from runners only); this mirrors every other compiled tool and is
/// NOT presented as removal-based discovery filtering.
@discardableResult
public func registerWorkspacePublishOutputTool(
    artifactRootProvider: @escaping @Sendable () -> URL?,
    operationGate: (any RunOutputOperationGate)? = nil,
    isAvailable: (@Sendable () -> Bool)? = nil,
    rootProvider: @escaping @Sendable () -> URL? = { nil },
    registry: ToolRunnerRegistry = .shared
) -> WorkspaceToolEnvironment {
    let environment = WorkspaceToolEnvironment(rootProvider: rootProvider)
    ToolCatalog.register(WorkspacePublishOutputTool.self)
    var runner = AnyAgentTool(WorkspacePublishOutputTool(
        environment: environment,
        artifactRootProvider: artifactRootProvider,
        operationGate: operationGate
    ))
    if let isAvailable {
        runner.isAvailable = isAvailable
    }
    registry.register(runner)
    return environment
}
