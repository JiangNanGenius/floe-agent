// SPDX-License-Identifier: MPL-2.0
//
// MacAgentWorkspaceTools — focused, production native project-file tool
// capability for the unified Mac host ("Floe SelfCore" runtime).
//
// This file is the whole capability: a scoped ToolExecutor over the
// explicitly user-selected project workspace, plus the shared task approval
// policy composition, exposed as one binding factory for the host to hand
// to `FloeMacSelfRuntime.startSession(_:provider:tools:)`.
//
// Design constraints honored here:
// - Explicit known-safe catalog only: five reads
//   (workspace.listDirectory / workspace.readFile /
//   workspace.inspectFileMetadata / workspace.searchFiles /
//   workspace.readDocument) and the approved text-authoring lane
//   (workspace.createFile / workspace.replaceText / workspace.writeFile /
//   workspace.appendFile / workspace.applyPatch / workspace.createDirectory).
//   Tool and argument names intentionally match the existing public Floe
//   workspace contract so host prompts, provider schemas and approval
//   vocabulary stay aligned.
// - No uncontrolled shell, no code execution, no network, no credentials.
// - Descriptor-relative I/O: directories are pinned with
//   `openat(O_DIRECTORY | O_NOFOLLOW)` per component from the physical root
//   and verified by device/inode at every boundary; files are opened by
//   descriptor with `O_NOFOLLOW` and re-verified by `F_GETPATH` containment
//   after the open. A swapped ancestor or leaf can never redirect admission
//   after approval. This mirrors the production `MacWorkspaceFilesView`
//   openPinnedDirectory / publishExclusive pattern.
// - No symlink escape: `O_NOFOLLOW` on every component open plus `..`
//   component rejection (path standardization alone does not resolve
//   `a/../b`, and openat would walk it), plus post-open physical-path
//   containment checks.
// - No sensitive paths: the shared `BridgeAbsoluteFileRead.isSecretPath`
//   denylist is applied to the logical path before any filesystem call and
//   to the physical opened path of every read.
// - No ambiguous paths: relative paths containing control, format or
//   bidi-override scalars (invisible or direction-switching text) and
//   trailing-slash paths are rejected before touching the filesystem.
// - Strict no-overwrite: createFile publishes with
//   `renameatx_np(RENAME_EXCL)` (hard-link fallback), failing when the
//   target exists in any form (file, directory or dangling symlink).
// - No parent-directory creation: the destination's parent must already be
//   an existing directory inside the workspace, so a failed or approved
//   write can never leave new directory state behind.
// - Writes are bounded (4 MiB), reads are bounded (64 KiB pages, 10 MiB
//   ceiling). createFile stages and verifies bytes
//   through a held descriptor before exclusive publication.
// - The task approval policy and runtime gates govern every mutation.

import Foundation
import CryptoKit
import Darwin
import UniformTypeIdentifiers
import AppKit
import PDFKit
import Vision
import FloeAgentRuntime
import FloeCore
import FloeModels
import FloeTools
import FloeSecurity
import FloeMacSelfCore
import FloeMacBridgeProtocol

// MARK: - Errors

/// Failure surface of the Mac workspace tool capability. Everything the
/// model or host can trigger is one of these deterministic cases.
public enum MacAgentWorkspaceToolsError: Error, LocalizedError {
    /// `binding` was handed a workspace that is not an explicit user-selected
    /// project (for example a private-task workspace with an empty bookmark).
    case workspaceKindUnsupported(String)
    /// The stored security-scoped bookmark is missing, stale or unresolvable.
    case workspaceBookmarkUnavailable
    /// The resolved root is not an existing directory, or is the filesystem
    /// root / the user home directory, or its physical path is unavailable.
    case workspaceRootInvalid(String)
    /// Dispatch was attempted for a tool this executor does not own.
    case toolUnavailable(String)
    /// A tool argument failed validation.
    case invalidArguments(String)
    /// A relative path contained invisible characters (control/format/bidi
    /// overrides) or ended with a slash, making its displayed direction or
    /// identity ambiguous.
    case ambiguousPath(String)
    /// The resolved path escapes the workspace root (traversal or symlink),
    /// or a pinned descriptor no longer matches its verified path.
    case pathEscapesWorkspace(String)
    /// The resolved path hits the secret-file denylist.
    case secretPath(String)
    /// createFile target's parent directory does not exist; parents are never
    /// created implicitly.
    case parentDirectoryMissing(String)
    /// Strict no-overwrite: the createFile target already exists.
    case targetAlreadyExists(String)
    case revisionChanged
    case exactTextMismatch
    case replacementUnconfirmed(String)
    /// A directory was used where a regular file is required.
    case isDirectory(String)
    /// A required path does not exist.
    case notFound(String)
    /// readFile bytes are not UTF-8 plain text.
    case notTextFile(String)
    /// A formatted document (PDF/DOCX/RTF) could not be decoded or has no
    /// readable text layer.
    case documentTextUnavailable(String)
    /// Payload or file exceeds the bounded size cap.
    case tooLarge(limit: Int)
    /// A single-file unified diff was malformed, multi-file, or did not match
    /// the current revision (mapped from the shared text-mutation contract).
    case invalidPatch(String)

    public var errorDescription: String? {
        switch self {
        case .workspaceKindUnsupported(let kind):
            "workspace kind '\(kind)' is not an explicit user-selected project"
        case .workspaceBookmarkUnavailable:
            "the workspace root bookmark is missing, stale or unresolvable"
        case .workspaceRootInvalid(let reason):
            "the workspace root is not usable: \(reason)"
        case .toolUnavailable(let name):
            "the tool '\(name)' is not part of this Mac workspace capability"
        case .invalidArguments(let reason):
            "invalid arguments: \(reason)"
        case .ambiguousPath(let path):
            "the path '\(path)' contains invisible or direction-ambiguous characters"
        case .pathEscapesWorkspace(let path):
            "the path '\(path)' resolves outside the selected workspace"
        case .secretPath(let path):
            "the path '\(path)' matches the secret-file denylist"
        case .parentDirectoryMissing(let path):
            "the parent directory of '\(path)' does not exist; create it explicitly first"
        case .targetAlreadyExists(let path):
            "the file '\(path)' already exists; choose a new path"
        case .revisionChanged:
            "the file changed since it was inspected; inspect it again and ask for a new approval"
        case .exactTextMismatch:
            "the specified text must occur exactly once in this revision"
        case .replacementUnconfirmed(let recoveryName):
            "the edit could not be confirmed; inspect the file and the preserved previous entry '\(recoveryName)' before retrying"
        case .isDirectory(let path):
            "'\(path)' is a directory, not a regular file"
        case .notFound(let path):
            "'\(path)' does not exist"
        case .notTextFile(let path):
            "'\(path)' is not a UTF-8 plain-text file"
        case .documentTextUnavailable(let reason):
            "the document text is unavailable: \(reason)"
        case .tooLarge(let limit):
            "the payload exceeds the \(limit)-byte limit"
        case .invalidPatch(let reason):
            "Invalid patch: \(reason)"
        }
    }
}

// MARK: - Catalog names and binding factory

/// Public entry point of the Mac workspace file capability.
public enum MacAgentWorkspaceTools {
    // The explicit known-safe initial catalog. Names match the existing
    // public Floe workspace tool contract.
    public static let listDirectoryToolName = "workspace.listDirectory"
    public static let readFileToolName = "workspace.readFile"
    public static let inspectFileMetadataToolName = "workspace.inspectFileMetadata"
    public static let searchFilesToolName = "workspace.searchFiles"
    public static let readDocumentToolName = "workspace.readDocument"
    public static let createFileToolName = "workspace.createFile"
    public static let replaceTextToolName = "workspace.replaceText"
    public static let writeFileToolName = "workspace.writeFile"
    public static let appendFileToolName = "workspace.appendFile"
    public static let applyPatchToolName = "workspace.applyPatch"
    public static let createDirectoryToolName = "workspace.createDirectory"

    /// Read-only tools: allowed in both plan-style (`readOnly: true`) and
    /// agent/goal sessions. Plan sessions bind exactly this set, so every
    /// name here must also pass `ConversationToolAccess.plan` and the
    /// `PlanToolPolicy` (see `FloeMacSelfCapabilityResolver.validatePlanCeiling`).
    public static let readToolNames: Set<String> = [
        listDirectoryToolName,
        readFileToolName,
        inspectFileMetadataToolName,
        searchFilesToolName,
        readDocumentToolName,
    ]
    public static let writeToolNames: Set<String> = [
        createFileToolName, replaceTextToolName, writeFileToolName,
        appendFileToolName, applyPatchToolName, createDirectoryToolName,
        WorkspaceOutputPublication.name,
    ]

    /// Stable labels for the host gate (provenance, not secrets).
    public static let toolCorpusIdentifier = "floe.macunified.workspace-tools.v1"
    public static let issuer = "floe.macunified.mac-agent-workspace-tools"
    /// Local vision reads that stay offered in read-only benches (see the
    /// binding composition below).
    public static let readOnlyVisionToolNames: Set<String> = [
        "image.ocr", "image.barcode.scan"
    ]

    /// Bounded sizes shared by every tool in this catalog.
    public static let maxReadBytes = 10 * 1024 * 1024
    public static let maxWriteBytes = 4 * 1024 * 1024
    public static let readChunkBytes = 64 * 1024
    /// OCR/scan output is a full page of text with per-line boxes; keep the
    /// same generous envelope the long read tools use.
    public static let visionReadSummaryCharacters = 196_608
    public static let listPageSize = 200
    /// Search bounds, mirroring the existing public workspace search
    /// contract (`WorkspaceFileService`).
    public static let maxSearchHits = 100
    public static let maxHitContextCharacters = 200
    public static let maxSearchFiles = 10_000
    /// Directories pruned during search (VCS internals, build products),
    /// matching the existing workspace search skip list. Dot-prefixed
    /// entries are additionally skipped as hidden names.
    static let searchSkipDirectories: Set<String> = [
        ".git", ".svn", ".hg", "node_modules", ".build", "DerivedData", ".swiftpm"
    ]

    /// Composes the complete tool capability for one workspace — either an
    /// explicit user-selected project or the per-task private (personal)
    /// workspace of an ordinary conversation. Both kinds resolve through the
    /// exact same descriptor-relative executor and the same verified host
    /// gate; only the root resolution differs.
    ///
    /// - Parameters:
    ///   - workspace: A stored workspace record. `.project` rows carry a
    ///     security-scoped root bookmark; `.privateTask` rows carry an empty
    ///     bookmark and resolve as
    ///     `<privateTaskRootBase>/<internalRelativePath>` (the runtime
    ///     directory is the base; the row path is `PrivateTasks/<task id>`).
    ///     Any other shape fails closed.
    ///   - privateTaskRootBase: Host-configured lease base for personal task
    ///     roots (the owner-only runtime directory). Required exactly when
    ///     `workspace.kind == .privateTask`; ignored for projects.
    ///   - readOnly: When true (plan-style investigation) the binding
    ///     advertises and permits only the read tools. When false
    ///     (agent/goal) the task approval policy governs text writes.
    ///   - delegationRegistry: When non-nil (normal Agent/Goal runs
    ///     only; never chat/plan), the binding additionally advertises the
    ///     delegation tools (`delegate`, `delegate.wait`) as private
    ///     instances bound to that child-subagent registry, so the task can
    ///     hand independently authorized subtasks to owned foreground or background
    ///     children. No global registry/catalog entry is created or replaced.
    /// - Returns: A binding ready for `FloeMacSelfRuntime.startSession`.
    public static func binding(
        workspace: WorkspaceRecord,
        privateTaskRootBase: URL? = nil,
        runOutputArtifactRoot: URL? = nil,
        readOnly: Bool,
        chatOnly: Bool = false,
        taskPolicy: TaskPolicy? = nil,
        delegationRegistry: SubagentRunnerRegistry? = nil,
        search: MacSearchAccess? = nil,
        conversations: FloeMacConversationToolCapability? = nil,
        imageInspectionAvailable: Bool = false,
        imageTools: MacTaskImageTools? = nil, videoTools: [AnyAgentTool] = [],
        browserTools: ((URL) -> [AnyAgentTool])? = nil,
        computerUseBackend: MacComputerUseBackend = .kimi,
        extensionTools: [AnyAgentTool] = [],
        memoryTools: [AnyAgentTool] = [],
        observeShellOutput: (@Sendable (MacShellOutputUpdate) async -> Void)? = nil,
        approvalPolicy: ((URL, [String: String]) -> any ApprovalPolicy)? = nil
    ) throws -> FloeMacSelfToolBinding {
        let root: URL
        switch workspace.kind {
        case .project:
            root = try resolveProjectRoot(workspace)
        case .privateTask:
            root = try resolvePrivateTaskRoot(workspace, base: privateTaskRootBase)
        }
        // The executor pins descriptors against the physical root; it must
        // exist at composition time or every tool would fail identically.
        guard MacAgentWorkspacePinSupport.physicalPath(root.path) != nil else {
            throw MacAgentWorkspaceToolsError.workspaceRootInvalid(
                "the physical workspace path is unavailable"
            )
        }

        let baseExecutor = MacAgentWorkspaceToolExecutor(
            workspaceRootURL: root,
            runOutputArtifactRoot: runOutputArtifactRoot,
            readOnly: readOnly || chatOnly,
            search: search,
            conversations: chatOnly ? nil : conversations,
            imageInspectionAvailable: imageInspectionAvailable,
            imageTools: imageTools, videoTools: videoTools,
            browserTools: readOnly || chatOnly ? [] : browserTools?(root) ?? [],
            computerUseBackend: computerUseBackend,
            extensionTools: memoryTools + (chatOnly ? [] : extensionTools),
            observeShellOutput: observeShellOutput
        )
        let taskReadTools = Set(baseExecutor.allDescriptors.filter { ConversationToolAccess.plan.allows($0) }.map(\.name))
        var allowed = chatOnly ? taskReadTools.intersection(ConversationToolAccess.chatNames) : taskReadTools
        if readOnly, !chatOnly {
            // Local on-device vision reads need no staging, no provider and no
            // writable run: a read-only bench keeps them offered next to
            // workspace.readFile. The pinned-path admission and size bounds
            // still apply to every call.
            allowed.formUnion(Self.readOnlyVisionToolNames)
        }
        if !readOnly && !chatOnly { allowed.formUnion(baseExecutor.allDescriptors.map(\.name)) }
        if let taskPolicy {
            let permitted = baseExecutor.allDescriptors.filter { taskPolicy.allowsToolEffect($0) }.map(\.name)
            allowed.formIntersection(permitted)
            if !taskPolicy.filePaths.isEmpty || taskPolicy.networkAllowed == false {
                allowed.remove(MacNativeShellTool.name)
            }
        }
        let executor: any ToolExecutor
        if let delegationRegistry, !chatOnly {
            allowed.formUnion(FloeMacDelegatingProjectToolExecutor.defaultDelegatingNames)
            executor = FloeMacDelegatingProjectToolExecutor(
                project: baseExecutor,
                runners: delegationRegistry
            )
        } else {
            executor = baseExecutor
        }
        if let names = taskPolicy?.allowedToolNames { allowed.formIntersection(names) }
        for tool in extensionTools.reversed() where allowed.count > FloeMacSelfHostGate.maximumToolCount {
            allowed.remove(tool.descriptor.name)
        }
        let gate = bundledApprovalGate
            ?? CatastrophicActionGate.failClosed(reason: "Mac workspace tool gate corpus unavailable")
        let boundary = FloeMacSelfTaskBoundary(
            workspaceID: workspace.id,
            workspaceRootURL: root,
            allowedWorkspacePaths: taskPolicy?.filePaths ?? [],
            ownership: .nativeHost
        )
        let identities = Dictionary(uniqueKeysWithValues: baseExecutor.allDescriptors.map { ($0.name, $0.authorizationIdentity) })
        let policy = approvalPolicy?(root, identities) ?? HumanApprovalPolicy()
        let hostGate = FloeMacSelfHostGate(
            workspaceID: workspace.id,
            workspaceRootPath: root.resolvingSymlinksInPath().standardizedFileURL.path,
            approvalPolicySource: policy.policyName,
            toolCorpusIdentifier: toolCorpusIdentifier,
            approvedToolNames: allowed,
            issuer: issuer
        )
        return FloeMacSelfToolBinding(
            executor: executor,
            policy: policy,
            gate: gate,
            auditSink: nil,
            boundary: boundary,
            allowedToolNames: allowed,
            hostGate: hostGate
        )
    }

    private static let bundledApprovalGate = try? CatastrophicActionGate.withBundledPatterns()
    static var approvalGateAvailable: Bool { bundledApprovalGate != nil }

    /// Project roots resolve from the stored security-scoped bookmark; a
    /// stale or unresolvable bookmark, an empty bookmark, or a non-directory
    /// root fails closed.
    private static func resolveProjectRoot(_ workspace: WorkspaceRecord) throws -> URL {
        guard workspace.kind == .project else {
            throw MacAgentWorkspaceToolsError.workspaceKindUnsupported(workspace.kind.rawValue)
        }
        guard !workspace.rootBookmark.isEmpty else {
            throw MacAgentWorkspaceToolsError.workspaceBookmarkUnavailable
        }
        var stale = false
        guard let resolved = try? URL(
            resolvingBookmarkData: workspace.rootBookmark,
            options: [],
            relativeTo: nil,
            bookmarkDataIsStale: &stale
        ), !stale else {
            throw MacAgentWorkspaceToolsError.workspaceBookmarkUnavailable
        }
        let root = resolved.resolvingSymlinksInPath().standardizedFileURL
        try validateWorkspaceRoot(root)
        return root
    }

    /// Personal task roots resolve by the row's canonical
    /// `PrivateTasks/<task UUID>` relative path under the host-configured
    /// lease base (the owner-only runtime directory — the same base the
    /// self-core lease appends the relative path to, so the binding root and
    /// the verified lease root are identical). The leaf is materialized on
    /// demand by file surfaces and tool sessions. Anything but the
    /// exact two-component task-keyed shape fails closed — a personal
    /// workspace is never a shared parent and never falls back.
    static func resolvePrivateTaskRoot(_ workspace: WorkspaceRecord, base: URL?) throws -> URL {
        guard workspace.kind == .privateTask else {
            throw MacAgentWorkspaceToolsError.workspaceKindUnsupported(workspace.kind.rawValue)
        }
        guard let base else {
            throw MacAgentWorkspaceToolsError.workspaceRootInvalid(
                "a personal task workspace requires the host-configured lease base"
            )
        }
        guard let relative = workspace.internalRelativePath,
              workspace.isDisposableTaskWorkspace,
              MacAgentWorkspacePinSupport.canonicalPersonalLeaf(relative) != nil else {
            throw MacAgentWorkspaceToolsError.workspaceRootInvalid(
                "the personal task workspace path is not a canonical PrivateTasks/<task id> path"
            )
        }
        let root = try MacAgentWorkspacePinSupport.verifiedPersonalTaskRoot(
            relativePath: relative, leaseBase: base, createIfNeeded: true
        )
        try validateWorkspaceRoot(root)
        return root
    }

    /// The verified per-task personal root for one durable
    /// `PrivateTasks/<task UUID>` relative path under the host lease base.
    /// Shared by the tool binding and the host's file presentation:
    /// identical pinning, ownership and exact-physical-path checks, so the
    /// UI bookmark and the tool boundary always name the same leaf with the
    /// same spelling the durable row persists. Pass `createIfNeeded: false`
    /// for a pure lookup.
    public static func verifiedPersonalTaskRoot(
        relativePath: String,
        leaseBase: URL,
        createIfNeeded: Bool
    ) throws -> URL {
        try MacAgentWorkspacePinSupport.verifiedPersonalTaskRoot(
            relativePath: relativePath, leaseBase: leaseBase, createIfNeeded: createIfNeeded
        )
    }

    /// Extracts the stable task UUID from a canonical
    /// `PrivateTasks/<task UUID>` relative path.
    static func personalTaskID(relativePath: String) -> UUID? {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "PrivateTasks" else { return nil }
        return UUID(uuidString: String(parts[1]))
    }

    static func canRememberFile(_ path: String) -> Bool {
        path != "." && (try? MacAgentWorkspacePinSupport.standardizedRelativePath(path)) == path
    }

    /// Reveal the current regular file only while the original project
    /// bookmark (or, for a personal task row, the verified per-task root)
    /// and the verified descriptor are held.
    static func withWorkspaceFile(_ workspace: WorkspaceRecord, privateTaskRootBase: URL,
                                  path: String, artifact: ToolArtifactReference? = nil, use: (URL) -> Void) throws {
        let url: URL
        var scopedURL: URL?
        defer { scopedURL?.stopAccessingSecurityScopedResource() }
        switch workspace.kind {
        case .project:
            var stale = false
            let resolved = try URL(resolvingBookmarkData: workspace.rootBookmark, options: [.withoutUI],
                                   relativeTo: nil, bookmarkDataIsStale: &stale)
            guard !stale else { throw MacAgentWorkspaceToolsError.workspaceBookmarkUnavailable }
            if resolved.startAccessingSecurityScopedResource() { scopedURL = resolved }
            url = resolved.resolvingSymlinksInPath().standardizedFileURL
        case .privateTask:
            guard let relative = workspace.internalRelativePath else {
                throw MacAgentWorkspaceToolsError.workspaceBookmarkUnavailable
            }
            url = try verifiedPersonalTaskRoot(relativePath: relative, leaseBase: privateTaskRootBase,
                                               createIfNeeded: false)
        }
        try validateWorkspaceRoot(url)
        let root = MacAgentWorkspaceRoot(url)
        let (physical, relative) = try macWorkspacePinSetup(root: root, path: path)
        try MacAgentWorkspacePinSupport.withPinnedTarget(physicalRoot: physical, relative: relative, root: root) { pin in
            let descriptor = try MacAgentWorkspacePinSupport.openVerifiedRegularFile(pin, physicalRoot: physical, displayPath: path)
            defer { Darwin.close(descriptor) }
            if let artifact {
                guard artifact.relativePath == relative, artifact.byteCount > 0 else { throw MacAgentWorkspaceToolsError.revisionChanged }
                var before = stat()
                guard fstat(descriptor, &before) == 0, before.st_size == artifact.byteCount else {
                    throw MacAgentWorkspaceToolsError.revisionChanged
                }
                let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
                var digest = SHA256(), count = 0
                while let chunk = try file.read(upToCount: 262_144), !chunk.isEmpty {
                    try Task.checkCancellation()
                    guard chunk.count <= artifact.byteCount - count else { throw MacAgentWorkspaceToolsError.revisionChanged }
                    digest.update(data: chunk)
                    count += chunk.count
                }
                try Task.checkCancellation()
                var after = stat(), named = stat()
                guard count == artifact.byteCount, digest.finalize().map({ String(format: "%02x", $0) }).joined() == artifact.sha256,
                      fstat(descriptor, &after) == 0, after.st_size == before.st_size, after.st_nlink == 1,
                      after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
                      after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
                      fstatat(pin.parentFileDescriptor, pin.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                      named.st_dev == before.st_dev, named.st_ino == before.st_ino else {
                    throw MacAgentWorkspaceToolsError.revisionChanged
                }
            }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(descriptor, F_GETPATH, &buffer) == 0 else { throw MacAgentWorkspaceToolsError.notFound(path) }
            let fileURL = URL(fileURLWithFileSystemRepresentation: buffer, isDirectory: false, relativeTo: nil)
            if artifact != nil, fileURL.path != physical + "/" + relative { throw MacAgentWorkspaceToolsError.revisionChanged }
            use(fileURL)
        }
    }

    /// The same root checks the self-core composition applies at session
    /// start, surfaced here with this capability's own error cases so the
    /// host can fail before offering the run.
    private static func validateWorkspaceRoot(_ root: URL) throws {
        let path = root.path
        guard !path.isEmpty, path != "/" else {
            throw MacAgentWorkspaceToolsError.workspaceRootInvalid(
                "the filesystem root cannot be a workspace root"
            )
        }
        let home = FileManager.default.homeDirectoryForCurrentUser
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
        guard path != home else {
            throw MacAgentWorkspaceToolsError.workspaceRootInvalid(
                "the user home directory cannot be a workspace root"
            )
        }
        guard !BridgeAbsoluteFileRead.isSecretPath(path) else {
            throw MacAgentWorkspaceToolsError.secretPath(path)
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw MacAgentWorkspaceToolsError.workspaceRootInvalid(
                "the workspace root is not an existing directory"
            )
        }
    }
}

// MARK: - Pinned descriptor-relative I/O

/// Single choke point for filesystem access. Directories are pinned by
/// descriptor (`openat(O_DIRECTORY | O_NOFOLLOW)` per component from the
/// physical root, device/inode verified at every boundary, mirroring the
/// production `MacWorkspaceFilesView.openPinnedDirectory`); files are
/// opened by descriptor relative to the pinned parent and re-verified by
/// `F_GETPATH` containment. No path-based filesystem call is made for a
/// user-controlled path after admission.
enum MacAgentWorkspacePinSupport {
    private static let directoryOpenFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    /// Verified per-task personal workspace root, shared by the tool binding
    /// and the host's UI presentation record. Every path component is pinned
    /// with `openat(O_DIRECTORY | O_NOFOLLOW)` from the physical lease base
    /// and checked for euid ownership, so a symlinked leaf or a swapped
    /// ancestor can never redirect the root into a sibling task folder, the
    /// `PrivateTasks` parent, or the runtime database directory. When
    /// `createIfNeeded` is true, the `<task UUID>` leaf is materialized with
    /// `mkdirat(0700)` through the pinned parent descriptor (and the
    /// `PrivateTasks` parent likewise); nothing is created otherwise. The
    /// leaf name is used in exactly the spelling the durable row persists
    /// (`PrivateTasks/<id.uuidString>`), so the binding root and the lease
    /// root agree byte-for-byte on case-sensitive volumes. The returned path
    /// is the exact physical leaf — canonical string equality, never a
    /// prefix check.
    static func verifiedPersonalTaskRoot(
        relativePath: String,
        leaseBase: URL,
        createIfNeeded: Bool
    ) throws -> URL {
        guard let leafName = canonicalPersonalLeaf(relativePath) else {
            throw MacAgentWorkspaceToolsError.workspaceRootInvalid("invalid task id")
        }
        guard let basePath = physicalPath(leaseBase.path) else {
            throw MacAgentWorkspaceToolsError.workspaceRootInvalid(
                "the personal task lease base is unavailable"
            )
        }
        // Pin the physical base by descriptor with an identity check.
        let baseRoot = MacAgentWorkspaceRoot(URL(fileURLWithPath: basePath, isDirectory: true))
        guard baseRoot.physicalPath != nil else {
            throw MacAgentWorkspaceToolsError.workspaceRootInvalid(
                "the personal task lease base is not a directory"
            )
        }
        var descriptor = try openPinnedDirectory(physicalRoot: basePath, components: [], root: baseRoot)
        let tasksPath = basePath + "/PrivateTasks"
        do {
            let tasksFD = try verifiedChild(
                parent: descriptor, parentPath: basePath, name: "PrivateTasks",
                createIfNeeded: createIfNeeded
            )
            Darwin.close(descriptor)
            descriptor = tasksFD
            let leafFD = try verifiedChild(
                parent: descriptor, parentPath: tasksPath, name: leafName,
                createIfNeeded: createIfNeeded
            )
            Darwin.close(descriptor)
            descriptor = leafFD
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        defer { Darwin.close(descriptor) }
        // Exact physical identity: the pinned leaf must BE the canonical
        // path — a string-prefix check would admit a symlink into a sibling.
        let expected = tasksPath + "/" + leafName
        guard let physical = physicalPath(expected) else {
            throw MacAgentWorkspaceToolsError.workspaceRootInvalid(
                "the personal task workspace path does not resolve"
            )
        }
        guard physical == expected else {
            throw MacAgentWorkspaceToolsError.workspaceRootInvalid(
                "the personal task workspace resolved outside its canonical location"
            )
        }
        var pinned = stat(), actual = stat()
        guard fstat(descriptor, &pinned) == 0, lstat(expected, &actual) == 0,
              pinned.st_dev == actual.st_dev, pinned.st_ino == actual.st_ino,
              pinned.st_uid == geteuid(), actual.st_uid == geteuid() else {
            throw MacAgentWorkspaceToolsError.workspaceRootInvalid(
                "the personal task workspace identity could not be verified"
            )
        }
        return URL(fileURLWithPath: expected, isDirectory: true)
    }

    /// The exact `<task UUID>` leaf spelling of a canonical
    /// `PrivateTasks/<task UUID>` relative path, or nil for any other shape.
    static func canonicalPersonalLeaf(_ relativePath: String) -> String? {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0] == "PrivateTasks",
              UUID(uuidString: String(parts[1])) != nil else { return nil }
        return String(parts[1])
    }

    /// Opens `name` inside the pinned `parent` descriptor with
    /// `O_DIRECTORY | O_NOFOLLOW` (+`O_EXCL`-free `mkdirat(0700)` first when
    /// allowed and missing), verifies device/inode against the canonical
    /// child path and euid ownership, and returns the owned descriptor.
    private static func verifiedChild(
        parent: Int32,
        parentPath: String,
        name: String,
        createIfNeeded: Bool
    ) throws -> Int32 {
        var info = stat()
        let missing = fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) != 0 && errno == ENOENT
        if missing {
            guard createIfNeeded else {
                throw MacAgentWorkspaceToolsError.workspaceRootInvalid(
                    "the personal task workspace does not exist yet"
                )
            }
            guard mkdirat(parent, name, 0o700) == 0 || errno == EEXIST else {
                throw MacAgentWorkspaceToolsError.workspaceRootInvalid(
                    "the personal task workspace could not be created"
                )
            }
        }
        let child = openat(parent, name, directoryOpenFlags)
        guard child >= 0 else {
            throw MacAgentWorkspaceToolsError.workspaceRootInvalid(
                "the personal task workspace path could not be pinned"
            )
        }
        var expected = stat(), pinned = stat()
        let childPath = parentPath + "/" + name
        guard stat(childPath, &expected) == 0, fstat(child, &pinned) == 0,
              expected.st_dev == pinned.st_dev, expected.st_ino == pinned.st_ino,
              pinned.st_mode & S_IFMT == S_IFDIR, pinned.st_uid == geteuid() else {
            Darwin.close(child)
            throw MacAgentWorkspaceToolsError.workspaceRootInvalid(
                "the personal task workspace path failed its identity check"
            )
        }
        return child
    }

    /// realpath, or nil when the path does not resolve.
    static func physicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(validatingCString: resolved)
    }

    /// Validates the logical relative path and returns its standardized
    /// form: "." for the root, otherwise dot-free components joined by "/".
    /// Rejects empty/absolute/tilde/trailing-slash paths, ambiguous scalars,
    /// "." / ".." components (path standardization alone does NOT resolve
    /// `a/../b`, and openat would walk it), over-long paths, and the shared
    /// secret denylist — all before any filesystem call.
    static func standardizedRelativePath(_ path: String) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else {
            throw MacAgentWorkspaceToolsError.invalidArguments("path must not be empty")
        }
        // Reject invisible characters (control, format — including the
        // bidi embedding/override range) before the path is ever displayed
        // or resolved, so a model cannot make two different files look
        // identical to the reviewer.
        for scalar in trimmed.unicodeScalars where isAmbiguousScalar(scalar) {
            throw MacAgentWorkspaceToolsError.ambiguousPath(path)
        }
        guard !trimmed.hasPrefix("/"), !trimmed.hasPrefix("~") else {
            throw MacAgentWorkspaceToolsError.invalidArguments(
                "path must be relative to the workspace root: \(path)"
            )
        }
        guard !trimmed.hasSuffix("/") else {
            throw MacAgentWorkspaceToolsError.ambiguousPath(path)
        }
        if trimmed == "." { return "." }
        let standardized = (trimmed as NSString).standardizingPath
        var components: [String] = []
        for component in standardized.split(separator: "/", omittingEmptySubsequences: true) {
            let name = String(component)
            guard name != ".", name != ".." else {
                throw MacAgentWorkspaceToolsError.pathEscapesWorkspace(path)
            }
            components.append(name)
        }
        let relative = components.joined(separator: "/")
        guard relative.utf8.count <= BridgeAbsoluteFileRead.maximumPathBytes else {
            throw MacAgentWorkspaceToolsError.invalidArguments("path is too long")
        }
        // The shared denylist, applied to the logical path: covers secret
        // directory components anywhere, secret basenames/extensions, and
        // `.git/config` / `.git/credentials`.
        if BridgeAbsoluteFileRead.isSecretPath("/" + relative) {
            throw MacAgentWorkspaceToolsError.secretPath(path)
        }
        return relative.isEmpty ? "." : relative
    }

    /// True for scalars that make a displayed path ambiguous or invisible:
    /// control characters, format characters (this includes the bidi
    /// embedding/override range U+202A–U+202E and U+2066–U+2069), and
    /// illegal scalars.
    private static func isAmbiguousScalar(_ scalar: Unicode.Scalar) -> Bool {
        let category = scalar.properties.generalCategory
        if category == .control || category == .format { return true }
        if CharacterSet.illegalCharacters.contains(scalar) { return true }
        return false
    }

    /// A pinned target: the parent directory descriptor (owned by the pin
    /// scope), the final component name, and the parent physical path.
    /// `name` is empty exactly when `relative` was "." — the pinned
    /// descriptor then IS the target (the workspace root).
    struct Pin {
        var parentFileDescriptor: Int32
        var name: String
        var parentPhysicalPath: String
    }

    /// Pins the parent of `relative` under `physicalRoot` and runs `body`
    /// with the pinned descriptor; the descriptor is always closed after.
    static func withPinnedTarget<T>(
        physicalRoot: String,
        relative: String,
        root: MacAgentWorkspaceRoot,
        _ body: (Pin) throws -> T
    ) throws -> T {
        let components = relative == "." ? [] : relative.split(separator: "/").map(String.init)
        guard !components.isEmpty else {
            let descriptor = try openPinnedDirectory(physicalRoot: physicalRoot, components: [], root: root)
            defer { Darwin.close(descriptor) }
            return try body(Pin(
                parentFileDescriptor: descriptor,
                name: "",
                parentPhysicalPath: physicalRoot
            ))
        }
        let descriptor = try openPinnedDirectory(physicalRoot: physicalRoot, components: Array(components.dropLast()), root: root)
        defer { Darwin.close(descriptor) }
        return try body(Pin(
            parentFileDescriptor: descriptor,
            name: components[components.count - 1],
            parentPhysicalPath: physicalRoot + "/" + components.dropLast().joined(separator: "/")
        ))
    }

    /// Opens a directory by walking `physicalRoot` then `components`, each
    /// step with `O_NOFOLLOW` (symlinks are refused, never followed) and a
    /// device/inode check against the canonical path, so no component can be
    /// swapped for a link after verification. The caller owns the returned
    /// descriptor.
    private static func openPinnedDirectory(
        physicalRoot: String,
        components: [String],
        root: MacAgentWorkspaceRoot
    ) throws -> Int32 {
        func verify(_ descriptor: Int32, path: String) throws {
            var expected = stat(), pinned = stat()
            guard stat(path, &expected) == 0, fstat(descriptor, &pinned) == 0,
                  expected.st_dev == pinned.st_dev, expected.st_ino == pinned.st_ino else {
                Darwin.close(descriptor)
                throw MacAgentWorkspaceToolsError.pathEscapesWorkspace(path)
            }
        }
        var descriptor = Darwin.open("/", directoryOpenFlags)
        guard descriptor >= 0 else {
            throw MacAgentWorkspaceToolsError.pathEscapesWorkspace("/")
        }
        var currentPath = ""
        for component in physicalRoot.split(separator: "/") {
            let child = openat(descriptor, String(component), directoryOpenFlags)
            Darwin.close(descriptor)
            guard child >= 0 else {
                throw MacAgentWorkspaceToolsError.pathEscapesWorkspace(String(component))
            }
            descriptor = child
            currentPath += "/" + component
            try verify(descriptor, path: currentPath)
        }
        // Root boundary: the pinned descriptor must be the physical root.
        try verify(descriptor, path: physicalRoot)
        var rootInfo = stat()
        guard fstat(descriptor, &rootInfo) == 0, root.matches(rootInfo) else {
            Darwin.close(descriptor)
            throw MacAgentWorkspaceToolsError.pathEscapesWorkspace(physicalRoot)
        }
        for component in components {
            let child = openat(descriptor, component, directoryOpenFlags)
            Darwin.close(descriptor)
            guard child >= 0 else {
                throw MacAgentWorkspaceToolsError.notFound(component)
            }
            descriptor = child
            currentPath += "/" + component
            try verify(descriptor, path: currentPath)
        }
        return descriptor
    }

    /// Opens the leaf of a pin as a regular file by descriptor and verifies
    /// the opened identity: regular file, `F_GETPATH` containment inside the
    /// physical root, and the shared secret denylist on the physical path.
    /// The caller owns the returned descriptor.
    static func openVerifiedRegularFile(
        _ pin: Pin,
        physicalRoot: String,
        displayPath: String,
        writable: Bool = false
    ) throws -> Int32 {
        guard !pin.name.isEmpty else {
            throw MacAgentWorkspaceToolsError.isDirectory(displayPath)
        }
        let descriptor = openat(
            pin.parentFileDescriptor, pin.name,
            (writable ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw MacAgentWorkspaceToolsError.notFound(displayPath)
        }
        var info = stat()
        var pathBuffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_nlink == 1, fcntl(descriptor, F_GETPATH, &pathBuffer) == 0,
              let openedPath = pathBuffer.withUnsafeBufferPointer({ buffer in
                  buffer.baseAddress.flatMap { String(validatingCString: $0) }
              }),
              let physical = physicalPath(openedPath),
              isContained(physical, in: physicalRoot),
              !BridgeAbsoluteFileRead.isSecretPath(physical) else {
            Darwin.close(descriptor)
            throw MacAgentWorkspaceToolsError.pathEscapesWorkspace(displayPath)
        }
        return descriptor
    }

    /// True when `physicalPath` is the root itself or a descendant.
    static func isContained(_ path: String, in physicalRoot: String) -> Bool {
        guard path.hasPrefix(physicalRoot) else { return false }
        return path.count == physicalRoot.count || path.hasPrefix(physicalRoot + "/")
    }

    /// lstat through the pinned descriptor: facts for a leaf without
    /// following symlinks. Returns nil with `true` when the leaf does not
    /// exist (ENOENT), nil with `false` for other errors.
    static func leafStatus(
        _ pin: Pin
    ) -> (info: stat, exists: Bool, missing: Bool, symlink: Bool) {
        var info = stat()
        let result = fstatat(
            pin.parentFileDescriptor, pin.name, &info,
            AT_SYMLINK_NOFOLLOW
        )
        guard result == 0 else {
            return (info, false, errno == ENOENT, false)
        }
        return (info, true, false, (info.st_mode & S_IFMT) == S_IFLNK)
    }

    /// Creates `relative` (every missing component) under the pinned physical
    /// root, one `mkdirat(0700)` at a time through the pinned parent
    /// descriptor, verifying device/inode against the canonical path after
    /// every step — the same per-component pinning discipline as every other
    /// mutation, so a swapped or linked component can never redirect creation
    /// outside the workspace. Existing directory components are descended;
    /// an existing leaf directory, a symlink, or a file component fails
    /// closed and never leaves a partial chain behind for the approved leaf
    /// (a failure mid-chain only materializes directories that the approved
    /// path itself names).
    static func createDirectoryChain(
        physicalRoot: String,
        relative: String,
        root: MacAgentWorkspaceRoot
    ) throws {
        var descriptor = try openPinnedDirectory(physicalRoot: physicalRoot, components: [], root: root)
        var currentPath = physicalRoot
        do {
            let components = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
            for (index, component) in components.enumerated() {
                let isLeaf = index == components.count - 1
                var info = stat()
                let listed = fstatat(descriptor, component, &info, AT_SYMLINK_NOFOLLOW)
                if listed == 0 {
                    switch info.st_mode & S_IFMT {
                    case S_IFDIR:
                        guard !isLeaf else {
                            throw MacAgentWorkspaceToolsError.targetAlreadyExists(relative)
                        }
                    case S_IFLNK:
                        throw MacAgentWorkspaceToolsError.pathEscapesWorkspace(relative)
                    default:
                        throw MacAgentWorkspaceToolsError.invalidArguments(
                            "a file already exists at '\(relative)'"
                        )
                    }
                } else {
                    guard errno == ENOENT else {
                        throw MacAgentWorkspaceToolsError.invalidArguments(
                            "the directory '\(relative)' could not be inspected: errno \(errno)"
                        )
                    }
                    guard mkdirat(descriptor, component, 0o700) == 0 else {
                        throw MacAgentWorkspaceToolsError.invalidArguments(
                            "the directory '\(relative)' could not be created: errno \(errno)"
                        )
                    }
                }
                let child = openat(descriptor, component, directoryOpenFlags)
                guard child >= 0 else {
                    throw MacAgentWorkspaceToolsError.pathEscapesWorkspace(relative)
                }
                var expected = stat(), pinned = stat()
                currentPath += "/" + component
                guard stat(currentPath, &expected) == 0, fstat(child, &pinned) == 0,
                      expected.st_dev == pinned.st_dev, expected.st_ino == pinned.st_ino,
                      pinned.st_mode & S_IFMT == S_IFDIR else {
                    Darwin.close(child)
                    throw MacAgentWorkspaceToolsError.pathEscapesWorkspace(relative)
                }
                Darwin.close(descriptor)
                descriptor = child
            }
        } catch {
            Darwin.close(descriptor)
            throw error
        }
        Darwin.close(descriptor)
    }
}

// MARK: - Tool implementations

/// Shared executable surface so the executor can hold a homogeneous table.
/// `descriptor` is a static catalog fact; the constrained extension binds it
/// to the instance requirement.
protocol MacAgentWorkspaceExecutable: Sendable {
    var executionDescriptor: ToolCatalog.Descriptor { get }
    func run(argumentsJSON: Data, context: ToolContext) async throws -> ToolExecutionOutput
}

extension AnyAgentTool: MacAgentWorkspaceExecutable {
    var executionDescriptor: ToolCatalog.Descriptor { descriptor }

    func run(argumentsJSON: Data, context: ToolContext) async throws -> ToolExecutionOutput {
        try await run(argumentsJSON, context)
    }
}

extension MacAgentWorkspaceExecutable where Self: AgentTool {
    static var descriptor: ToolCatalog.Descriptor {
        .init(name: name, toolDescription: toolDescription, parametersJSON: parametersJSON,
              riskLabels: riskLabels, isSideEffecting: isSideEffecting, effect: toolEffect, requiresHostScope: requiresHostScope,
              prerequisites: prerequisites, executionBoundary: executionBoundary, supportsConcurrentBatchDispatch: supportsConcurrentBatchDispatch)
    }

    var executionDescriptor: ToolCatalog.Descriptor { Self.descriptor }

    func run(argumentsJSON: Data, context: ToolContext) async throws -> ToolExecutionOutput {
        let arguments = try Self.argumentsDecoder().decode(Arguments.self, from: argumentsJSON)
        try validate(arguments)
        return try await execute(arguments, context: context)
    }

    /// Fresh decoder per call: the approval preview uses the same Arguments
    /// shape and decoder configuration, so review stays exactly aligned with
    /// execution without sharing mutable decoder state across tasks.
    static func argumentsDecoder() -> JSONDecoder { JSONDecoder() }
}

/// Shared pre-dispatch checks mirrored from the production workspace tools:
/// local scope only, optional `scope` argument must be nil/"local", and the
/// runtime's persisted file ceiling is consulted before path resolution.
func macWorkspacePreflight(
    path: String?,
    context: ToolContext,
    scopeArgument: String?
) throws {
    try context.cancellation.throwIfCancelled()
    switch context.scope {
    case .local:
        break
    case .host(let id):
        throw MacAgentWorkspaceToolsError.invalidArguments(
            "host scope \(id.uuidString) is not supported by Mac workspace tools"
        )
    case .hostPath(let hostID, let path):
        throw MacAgentWorkspaceToolsError.invalidArguments(
            "host path scope \(hostID.uuidString):\(path) is not supported by Mac workspace tools"
        )
    }
    if let scopeArgument, scopeArgument != "local" {
        throw MacAgentWorkspaceToolsError.invalidArguments("scope must be local")
    }
    if let path {
        try context.authorizeWorkspacePath(path)
    }
}

struct MacAgentWorkspaceRoot: Sendable {
    let physicalPath: String?
    private let device: dev_t
    private let inode: ino_t

    init(_ url: URL) {
        var info = stat()
        if let path = MacAgentWorkspacePinSupport.physicalPath(url.path),
           lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR {
            physicalPath = path
        } else {
            physicalPath = nil
        }
        device = info.st_dev
        inode = info.st_ino
    }

    func matches(_ info: stat) -> Bool { info.st_dev == device && info.st_ino == inode }
}

func macWorkspacePinSetup(root: MacAgentWorkspaceRoot, path: String) throws -> (String, String) {
    guard let physicalRoot = root.physicalPath else {
        throw MacAgentWorkspaceToolsError.workspaceRootInvalid("the physical workspace path is unavailable")
    }
    return (physicalRoot, try MacAgentWorkspacePinSupport.standardizedRelativePath(path))
}

// MARK: workspace.listDirectory

/// Lists one page (≤200 entries) of a workspace directory.
public struct MacAgentWorkspaceListDirectoryTool: AgentTool, MacAgentWorkspaceExecutable {
    public struct Arguments: Decodable, Sendable {
        public var path: String
        public var pageToken: String?
        public var nameContains: String?
        public var kind: String?
        public var scope: String?

        public init(path: String, pageToken: String? = nil, nameContains: String? = nil,
                    kind: String? = nil, scope: String? = nil) {
            self.path = path
            self.pageToken = pageToken
            self.nameContains = nameContains
            self.kind = kind
            self.scope = scope
        }
    }

    public static let name = MacAgentWorkspaceTools.listDirectoryToolName
    public static let toolDescription =
        "List the contents of a directory inside the selected project workspace, one page (up to 200 entries) at a time. Pass nextPageToken back as pageToken to continue. Optional filters: nameContains (case-insensitive substring on names) and kind (\"file\" or \"dir\")."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative directory path (use \".\" for the root)"},
        "pageToken": {"type": "string", "description": "Opaque cursor from a previous call"},
        "nameContains": {"type": "string", "description": "Only entries whose names contain this substring (case-insensitive)"},
        "kind": {"type": "string", "enum": ["file", "dir"], "description": "Only files or only directories"}
      },
      "required": ["path"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false

    static let descriptor = ToolCatalog.Descriptor(
        name: name,
        toolDescription: toolDescription,
        parametersJSON: parametersJSON,
        riskLabels: riskLabels,
        isSideEffecting: isSideEffecting,
        requiresHostScope: false
    )

    private let root: MacAgentWorkspaceRoot
    public init(rootURL: URL) {
        self.root = MacAgentWorkspaceRoot(rootURL)
    }

    public func validate(_ args: Arguments) throws {
        if args.path.trimmingCharacters(in: .whitespaces).isEmpty {
            throw MacAgentWorkspaceToolsError.invalidArguments("path must not be empty")
        }
        if let kind = args.kind, kind != "file", kind != "dir" {
            throw MacAgentWorkspaceToolsError.invalidArguments("kind must be \"file\" or \"dir\"")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try macWorkspacePreflight(path: args.path, context: context, scopeArgument: args.scope)
        let (physicalRoot, relative) = try macWorkspacePinSetup(root: root, path: args.path)
        let includeDirectories = args.kind != "file"
        let includeFiles = args.kind != "dir"
        let needle = args.nameContains?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let offset = Int(args.pageToken ?? "0"), (0...5_000).contains(offset) else {
            throw MacAgentWorkspaceToolsError.invalidArguments("invalid directory page token")
        }

        let page = try MacAgentWorkspacePinSupport.withPinnedTarget(
            physicalRoot: physicalRoot, relative: relative, root: root
        ) { pin in
            // The pinned descriptor IS the directory when listing the root.
            let directoryDescriptor: Int32
            if pin.name.isEmpty {
                directoryDescriptor = pin.parentFileDescriptor
            } else {
                let opened = openat(
                    pin.parentFileDescriptor, pin.name,
                    O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
                )
                guard opened >= 0 else {
                    if errno == ENOTDIR {
                        throw MacAgentWorkspaceToolsError.isDirectory(args.path)
                    }
                    throw MacAgentWorkspaceToolsError.notFound(args.path)
                }
                // The child must be the same directory the canonical path names.
                var expected = stat(), pinned = stat()
                let childPath = pin.parentPhysicalPath + "/" + pin.name
                guard stat(childPath, &expected) == 0, fstat(opened, &pinned) == 0,
                      expected.st_dev == pinned.st_dev, expected.st_ino == pinned.st_ino else {
                    Darwin.close(opened)
                    throw MacAgentWorkspaceToolsError.pathEscapesWorkspace(args.path)
                }
                directoryDescriptor = opened
            }
            defer {
                if directoryDescriptor != pin.parentFileDescriptor {
                    Darwin.close(directoryDescriptor)
                }
            }
            let streamDescriptor = dup(directoryDescriptor)
            guard streamDescriptor >= 0 else {
                throw MacAgentWorkspaceToolsError.notFound(args.path)
            }
            guard let stream = fdopendir(streamDescriptor) else {
                Darwin.close(streamDescriptor)
                throw MacAgentWorkspaceToolsError.notFound(args.path)
            }
            defer { closedir(stream) }
            var lines: [(name: String, value: String)] = []
            var examined = 0
            let scanLimit = 5_000
            while examined < scanLimit, let entry = readdir(stream) {
                try context.cancellation.throwIfCancelled()
                examined += 1
                let name = withUnsafePointer(to: &entry.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                        String(validatingCString: $0)
                    }
                }
                guard let name, name != ".", name != ".." else { continue }
                let path = relative == "." ? name : relative + "/" + name
                guard (try? MacAgentWorkspacePinSupport.standardizedRelativePath(path)) == path else { continue }
                if let needle, !needle.isEmpty, name.range(of: needle, options: .caseInsensitive) == nil {
                    continue
                }
                var info = stat()
                guard fstatat(directoryDescriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                let kind = info.st_mode & S_IFMT
                let isDirectory = kind == S_IFDIR
                guard isDirectory ? includeDirectories : (kind == S_IFREG && includeFiles && info.st_nlink == 1) else {
                    continue
                }
                lines.append((name, "\(isDirectory ? "dir" : "file")\t\(isDirectory ? 0 : info.st_size)\t\(name)"))
            }
            return (lines: lines.sorted { $0.name < $1.name }, scanLimited: examined == scanLimit)
        }

        var records: [String] = []
        var outputBytes = 1_300
        for item in page.lines.dropFirst(offset).prefix(MacAgentWorkspaceTools.listPageSize) {
            outputBytes += item.value.utf8.count + 1
            if outputBytes > 4_000 { break }
            records.append(item.value)
        }
        var output = ["path=\(args.path) entries=\(records.count)"]
        output.append(contentsOf: records)
        if !records.isEmpty, offset + records.count < page.lines.count {
            output.append("nextPageToken=\(offset + records.count)")
        }
        if page.scanLimited { output.append("directoryScanLimited=true") }
        return ToolExecutionOutput(
            digesting: output.joined(separator: "\n"),
            maximumSummaryCharacters: 4096
        )
    }
}

// MARK: workspace.readFile

/// Reads one bounded UTF-8 page (≤64 KiB) of a workspace text file.
public struct MacAgentWorkspaceReadFileTool: AgentTool, MacAgentWorkspaceExecutable {
    public struct Arguments: Decodable, Sendable {
        public var path: String
        public var offset: Int?
        public var limit: Int?
        public var scope: String?

        public init(path: String, offset: Int? = nil, limit: Int? = nil, scope: String? = nil) {
            self.path = path
            self.offset = offset
            self.limit = limit
            self.scope = scope
        }
    }

    public static let name = MacAgentWorkspaceTools.readFileToolName
    public static let toolDescription =
        "Read up to 64 KiB of any UTF-8 plain-text file inside the selected project workspace: source code, scripts, Markdown, JSON/YAML/CSV, HTML/CSS/JS, LaTeX, TXT/logs or configuration. Binary or non-text bytes are refused. Returns one page with bytes, totalBytes, nextOffset and pageSHA256; pass nextOffset as offset until it is none."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative file path"},
        "offset": {"type": "integer", "description": "UTF-8 byte boundary (0-based); use the previous nextOffset"},
        "limit": {"type": "integer", "description": "Maximum bytes to read; clamped to 65536"}
      },
      "required": ["path"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false

    static let descriptor = ToolCatalog.Descriptor(
        name: name,
        toolDescription: toolDescription,
        parametersJSON: parametersJSON,
        riskLabels: riskLabels,
        isSideEffecting: isSideEffecting,
        requiresHostScope: false
    )

    private let root: MacAgentWorkspaceRoot
    public init(rootURL: URL) {
        self.root = MacAgentWorkspaceRoot(rootURL)
    }

    public func validate(_ args: Arguments) throws {
        if args.path.trimmingCharacters(in: .whitespaces).isEmpty {
            throw MacAgentWorkspaceToolsError.invalidArguments("path must not be empty")
        }
        if let offset = args.offset, offset < 0 {
            throw MacAgentWorkspaceToolsError.invalidArguments("offset must be >= 0")
        }
        if let limit = args.limit, limit <= 0 {
            throw MacAgentWorkspaceToolsError.invalidArguments("limit must be > 0")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try macWorkspacePreflight(path: args.path, context: context, scopeArgument: args.scope)
        let limit = min(args.limit ?? MacAgentWorkspaceTools.readChunkBytes,
                        MacAgentWorkspaceTools.readChunkBytes)
        let (physicalRoot, relative) = try macWorkspacePinSetup(root: root, path: args.path)
        let page = try MacAgentWorkspacePinSupport.withPinnedTarget(
            physicalRoot: physicalRoot, relative: relative, root: root
        ) { pin in
            let descriptor = try MacAgentWorkspacePinSupport.openVerifiedRegularFile(
                pin, physicalRoot: physicalRoot, displayPath: args.path
            )
            defer { Darwin.close(descriptor) }
            return try self.readPage(
                descriptor, displayPath: args.path,
                offset: args.offset ?? 0, limit: limit
            )
        }
        let next = page.nextOffset.map(String.init) ?? "none"
        let totalLines = page.text.split(separator: "\n", omittingEmptySubsequences: false).count
        let digest = FloeDigest.sha256Hex(Data(page.text.utf8))
        let summary = "path=\(args.path) offset=\(page.byteOffset) truncated=\(page.truncated) "
            + "totalLines=\(totalLines) bytes=\(page.bytesReturned) totalBytes=\(page.totalBytes) "
            + "nextOffset=\(next) pageSHA256=\(digest)\n\(page.text)"
        return ToolExecutionOutput(
            digesting: summary,
            maximumSummaryCharacters: 196_608
        )
    }

    struct Page: Sendable {
        var text: String
        var byteOffset: Int
        var bytesReturned: Int
        var totalBytes: Int
        var truncated: Bool
        var nextOffset: Int?
    }

    /// Reads exactly one page from the already-verified, no-follow
    /// descriptor. The page is decoded strictly as UTF-8 with its BOM
    /// preserved so a later write can reproduce the bytes exactly; a size
    /// change between fstat and read is treated as a conflict, never as
    /// partial output.
    private func readPage(
        _ descriptor: Int32,
        displayPath: String,
        offset: Int,
        limit: Int
    ) throws -> Page {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw MacAgentWorkspaceToolsError.notFound(displayPath)
        }
        let totalBytes = Int(info.st_size)
        guard totalBytes <= MacAgentWorkspaceTools.maxReadBytes else {
            throw MacAgentWorkspaceToolsError.tooLarge(limit: MacAgentWorkspaceTools.maxReadBytes)
        }
        guard offset <= totalBytes else {
            throw MacAgentWorkspaceToolsError.invalidArguments(
                "offset \(offset) is past the end of the file (\(totalBytes) bytes)"
            )
        }
        if offset == totalBytes {
            return Page(text: "", byteOffset: offset, bytesReturned: 0,
                        totalBytes: totalBytes, truncated: false, nextOffset: nil)
        }
        if offset > 0, lseek(descriptor, off_t(offset), SEEK_SET) == -1 {
            throw MacAgentWorkspaceToolsError.invalidArguments(
                "offset \(offset) could not be reached; use the previous nextOffset"
            )
        }
        let target = min(limit, totalBytes - offset)
        var data = Data()
        data.reserveCapacity(target)
        var buffer = [UInt8](repeating: 0, count: min(target, 64 * 1_024))
        var remaining = target
        while remaining > 0 {
            let want = min(remaining, buffer.count)
            let readCount = read(descriptor, &buffer, want)
            guard readCount > 0 else { break }
            data.append(contentsOf: buffer[0..<readCount])
            remaining -= readCount
        }
        guard data.count == target else {
            throw MacAgentWorkspaceToolsError.invalidArguments(
                "the file changed while it was being read; retry the read"
            )
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw MacAgentWorkspaceToolsError.notTextFile(displayPath)
        }
        let end = offset + data.count
        return Page(
            text: text,
            byteOffset: offset,
            bytesReturned: data.count,
            totalBytes: totalBytes,
            truncated: end < totalBytes,
            nextOffset: end < totalBytes ? end : nil
        )
    }
}

// MARK: workspace.searchFiles

/// Case-insensitive literal substring search over the workspace text files
/// or file names, mirroring the public `workspace.searchFiles` contract. The
/// tree walk is iterative (an explicit frame stack, never recursion, so deep
/// trees cannot exhaust a small concurrency stack) and every directory is
/// opened relative to its pinned parent descriptor with `O_NOFOLLOW` and
/// verified by device/inode against its canonical path, exactly like
/// `workspace.listDirectory`; files are opened by descriptor through the
/// shared verified-file admission. Hidden names, VCS/build directories and
/// the shared secret denylist are skipped before any filesystem call, per
/// file the read is size-bounded and best-effort (a file deleted or mutated
/// mid-scan is skipped, never fatal), and the whole scan is capped at
/// `maxSearchFiles` entries with at most `maxSearchHits` hits of at most
/// `maxHitContextCharacters` context characters.
public struct MacAgentWorkspaceSearchFilesTool: AgentTool, MacAgentWorkspaceExecutable {
    public struct Arguments: Decodable, Sendable {
        public var query: String
        public var path: String?
        public var maxResults: Int?
        /// "content" (default) searches file text; "filename" matches names.
        public var mode: String?
        public var scope: String?

        public init(query: String, path: String? = nil, maxResults: Int? = nil, mode: String? = nil, scope: String? = nil) {
            self.query = query
            self.path = path
            self.maxResults = maxResults
            self.mode = mode
            self.scope = scope
        }
    }

    public static let name = MacAgentWorkspaceTools.searchFilesToolName
    public static let toolDescription =
        "Search the selected project workspace with a case-insensitive substring. mode=\"content\" (default) searches UTF-8 text files and returns up to 100 hits as path:line: context. mode=\"filename\" matches file and directory names and returns up to 100 workspace-relative paths (directories end with /)."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "query": {"type": "string", "description": "Substring to search for (case-insensitive)"},
        "path": {"type": "string", "description": "Workspace-relative directory or file to search; defaults to the root"},
        "maxResults": {"type": "integer", "description": "Maximum hits; clamped to 100"},
        "mode": {"type": "string", "enum": ["content", "filename"], "description": "Search file contents (default) or file/directory names"}
      },
      "required": ["query"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false

    static let descriptor = ToolCatalog.Descriptor(
        name: name,
        toolDescription: toolDescription,
        parametersJSON: parametersJSON,
        riskLabels: riskLabels,
        isSideEffecting: isSideEffecting,
        requiresHostScope: false
    )

    private let root: MacAgentWorkspaceRoot
    public init(rootURL: URL) {
        self.root = MacAgentWorkspaceRoot(rootURL)
    }

    public func validate(_ args: Arguments) throws {
        if args.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MacAgentWorkspaceToolsError.invalidArguments("query must not be empty")
        }
        if let maxResults = args.maxResults, maxResults <= 0 {
            throw MacAgentWorkspaceToolsError.invalidArguments("maxResults must be > 0")
        }
        if let mode = args.mode, mode != "content", mode != "filename" {
            throw MacAgentWorkspaceToolsError.invalidArguments("mode must be \"content\" or \"filename\"")
        }
    }

    /// One open directory frame: the owned pinned descriptor, its verified
    /// canonical path and its workspace-relative display prefix.
    private struct Frame {
        var descriptor: Int32
        var physicalPath: String
        var relative: String
    }

    private struct SearchState {
        var visited = 0
        var remainingReadBytes = 16 * 1_024 * 1_024
        var truncated = false
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try macWorkspacePreflight(path: args.path ?? ".", context: context, scopeArgument: args.scope)
        let (physicalRoot, relative) = try macWorkspacePinSetup(root: root, path: args.path ?? ".")
        let needle = args.query.trimmingCharacters(in: .whitespacesAndNewlines)
        let hitLimit = max(1, min(args.maxResults ?? MacAgentWorkspaceTools.maxSearchHits,
                                MacAgentWorkspaceTools.maxSearchHits))
        let filenameOnly = args.mode == "filename"
        let directoryOpenFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

        var state = SearchState()
        let hits: [String] = try MacAgentWorkspacePinSupport.withPinnedTarget(
            physicalRoot: physicalRoot, relative: relative, root: root
        ) { pin in
            var hits: [String] = []
            if pin.name.isEmpty {
                // Root directory target: the pinned descriptor IS the root.
                let descriptor = dup(pin.parentFileDescriptor)
                guard descriptor >= 0 else {
                    throw MacAgentWorkspaceToolsError.notFound(args.path ?? ".")
                }
                try self.walk(
                    initial: Frame(descriptor: descriptor, physicalPath: physicalRoot, relative: "."),
                    physicalRoot: physicalRoot, needle: needle, hitLimit: hitLimit,
                    filenameOnly: filenameOnly, directoryOpenFlags: directoryOpenFlags,
                    context: context, state: &state, hits: &hits
                )
                return hits
            }
            let status = MacAgentWorkspacePinSupport.leafStatus(pin)
            guard status.exists, !status.symlink else {
                if status.symlink {
                    throw MacAgentWorkspaceToolsError.invalidArguments(
                        "symbolic links are not searchable: \(args.path ?? ".")"
                    )
                }
                throw MacAgentWorkspaceToolsError.notFound(args.path ?? ".")
            }
            if status.info.st_mode & S_IFMT == S_IFDIR {
                let descriptor = openat(pin.parentFileDescriptor, pin.name, directoryOpenFlags)
                guard descriptor >= 0 else {
                    throw MacAgentWorkspaceToolsError.notFound(args.path ?? ".")
                }
                // The child must be the same directory the canonical path names.
                var expected = stat(), pinned = stat()
                let childPhysical = pin.parentPhysicalPath + "/" + pin.name
                guard stat(childPhysical, &expected) == 0, fstat(descriptor, &pinned) == 0,
                      expected.st_dev == pinned.st_dev, expected.st_ino == pinned.st_ino else {
                    Darwin.close(descriptor)
                    throw MacAgentWorkspaceToolsError.pathEscapesWorkspace(args.path ?? ".")
                }
                try self.walk(
                    initial: Frame(descriptor: descriptor, physicalPath: childPhysical, relative: relative),
                    physicalRoot: physicalRoot, needle: needle, hitLimit: hitLimit,
                    filenameOnly: filenameOnly, directoryOpenFlags: directoryOpenFlags,
                    context: context, state: &state, hits: &hits
                )
                return hits
            }
            guard status.info.st_mode & S_IFMT == S_IFREG, status.info.st_nlink == 1 else {
                throw MacAgentWorkspaceToolsError.invalidArguments(
                    "'\(args.path ?? ".")' is neither a regular file nor a directory"
                )
            }
            state.visited = 1
            if filenameOnly {
                if pin.name.range(of: needle, options: .caseInsensitive) != nil {
                    hits.append(relative)
                }
            } else {
                self.searchFile(
                    pin, physicalRoot: physicalRoot, relative: relative,
                    size: Int(status.info.st_size), needle: needle,
                    hitLimit: hitLimit, context: context, state: &state, hits: &hits
                )
            }
            return hits
        }

        var lines = ["query=\(args.query) hits=\(hits.count) truncated=\(state.truncated || hits.count == hitLimit)"]
        if filenameOnly { lines[0] += " mode=filename" }
        lines.append(contentsOf: hits)
        return ToolExecutionOutput(
            digesting: lines.joined(separator: "\n"),
            maximumSummaryCharacters: 32_768
        )
    }

    /// Iterative pinned tree walk. Each frame descriptor is always closed:
    /// `scan` closes the frame it processes, and any frames left unprocessed
    /// after a hit-limit early exit are closed here.
    private func walk(
        initial: Frame,
        physicalRoot: String,
        needle: String,
        hitLimit: Int,
        filenameOnly: Bool,
        directoryOpenFlags: Int32,
        context: ToolContext,
        state: inout SearchState,
        hits: inout [String]
    ) throws {
        var pending: [Frame] = [initial]
        defer { for frame in pending { Darwin.close(frame.descriptor) } }
        while let frame = pending.popLast() {
            let reachedLimit = try scan(
                frame, physicalRoot: physicalRoot, needle: needle, hitLimit: hitLimit,
                filenameOnly: filenameOnly, directoryOpenFlags: directoryOpenFlags,
                context: context, state: &state, hits: &hits
            ) { child in
                guard pending.count < 64 else { return false }
                pending.append(child)
                return true
            }
            if reachedLimit { break }
        }
    }

    /// Scans one pinned directory frame, appending child directory frames
    /// through `push` and returning true once `hitLimit` hits are collected.
    /// The frame descriptor is always closed.
    private func scan(
        _ frame: Frame,
        physicalRoot: String,
        needle: String,
        hitLimit: Int,
        filenameOnly: Bool,
        directoryOpenFlags: Int32,
        context: ToolContext,
        state: inout SearchState,
        hits: inout [String],
        push: (Frame) -> Bool
    ) throws -> Bool {
        defer { Darwin.close(frame.descriptor) }
        let streamDescriptor = dup(frame.descriptor)
        guard streamDescriptor >= 0 else { return false }
        guard let stream = fdopendir(streamDescriptor) else {
            Darwin.close(streamDescriptor)
            return false
        }
        defer { closedir(stream) }
        while let entry = readdir(stream) {
            try context.cancellation.throwIfCancelled()
            guard hits.count < hitLimit else { return true }
            state.visited += 1
            if state.visited > MacAgentWorkspaceTools.maxSearchFiles {
                state.truncated = true
                return true
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) {
                    String(validatingCString: $0)
                }
            }
            guard let name, name != ".", name != ".." else { continue }
            // Mirror the existing workspace search: hidden names are skipped.
            guard !name.hasPrefix(".") else { continue }
            let childRelative = frame.relative == "." ? name : frame.relative + "/" + name
            // The shared admission checks (secret denylist, ambiguous scalars,
            // component validation) apply to every walked entry.
            guard (try? MacAgentWorkspacePinSupport.standardizedRelativePath(childRelative)) == childRelative,
                  (try? context.authorizeWorkspacePath(childRelative)) != nil else {
                continue
            }
            var info = stat()
            guard fstatat(frame.descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            if kind == S_IFDIR {
                guard !MacAgentWorkspaceTools.searchSkipDirectories.contains(name) else { continue }
                if filenameOnly, name.range(of: needle, options: .caseInsensitive) != nil {
                    hits.append(childRelative + "/")
                    if hits.count == hitLimit { return true }
                }
                let child = openat(frame.descriptor, name, directoryOpenFlags)
                guard child >= 0 else { continue }
                let childPhysical = frame.physicalPath + "/" + name
                var expected = stat(), pinned = stat()
                guard stat(childPhysical, &expected) == 0, fstat(child, &pinned) == 0,
                      expected.st_dev == pinned.st_dev, expected.st_ino == pinned.st_ino else {
                    Darwin.close(child)
                    throw MacAgentWorkspaceToolsError.pathEscapesWorkspace(childRelative)
                }
                if !push(Frame(descriptor: child, physicalPath: childPhysical, relative: childRelative)) {
                    Darwin.close(child)
                    state.truncated = true
                }
            } else if kind == S_IFREG, info.st_nlink == 1 {
                if filenameOnly {
                    if name.range(of: needle, options: .caseInsensitive) != nil {
                        hits.append(childRelative)
                    }
                } else {
                    let childPin = MacAgentWorkspacePinSupport.Pin(
                        parentFileDescriptor: frame.descriptor,
                        name: name,
                        parentPhysicalPath: frame.physicalPath
                    )
                    searchFile(
                        childPin, physicalRoot: physicalRoot, relative: childRelative,
                        size: Int(info.st_size), needle: needle, hitLimit: hitLimit,
                        context: context, state: &state, hits: &hits
                    )
                }
            }
            // Symbolic links and special files are never followed or searched.
        }
        return false
    }

    /// Best-effort content search of one already-admitted regular file: the
    /// file is re-opened by descriptor through the shared verified-file
    /// admission, read with an exact-size check, and scanned line by line.
    /// Concurrent deletion or mutation skips this file only.
    private func searchFile(
        _ pin: MacAgentWorkspacePinSupport.Pin,
        physicalRoot: String,
        relative: String,
        size: Int,
        needle: String,
        hitLimit: Int,
        context: ToolContext,
        state: inout SearchState,
        hits: inout [String]
    ) {
        guard size <= MacAgentWorkspaceTools.maxReadBytes, size <= state.remainingReadBytes else {
            state.truncated = true
            return
        }
        state.remainingReadBytes -= size
        guard let descriptor = try? MacAgentWorkspacePinSupport.openVerifiedRegularFile(
            pin, physicalRoot: physicalRoot, displayPath: relative
        ) else { return }
        defer { Darwin.close(descriptor) }
        guard let data = try? FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            .read(upToCount: size + 1), data.count == size else { return }
        guard !data.prefix(1024).contains(0) else { return }
        guard let text = String(data: data, encoding: .utf8) else { return }
        var lineNumber = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if context.cancellation.isCancelled || hits.count >= hitLimit { return }
            lineNumber += 1
            var contextLine = String(line)
            if contextLine.hasSuffix("\r") { contextLine.removeLast() }
            guard contextLine.range(of: needle, options: .caseInsensitive) != nil else { continue }
            hits.append("\(relative):\(lineNumber): \(contextLine.prefix(MacAgentWorkspaceTools.maxHitContextCharacters))")
        }
    }
}

// MARK: workspace.inspectFileMetadata

/// Reports size/mtime/UTI/sha256/symlink facts for one workspace path.
public struct MacAgentWorkspaceInspectMetadataTool: AgentTool, MacAgentWorkspaceExecutable {
    public struct Arguments: Decodable, Sendable {
        public var path: String
        public var scope: String?

        public init(path: String, scope: String? = nil) {
            self.path = path
            self.scope = scope
        }
    }

    public static let name = MacAgentWorkspaceTools.inspectFileMetadataToolName
    public static let toolDescription =
        "Inspect a file or directory inside the selected project workspace: size, modification time, UTI, sha256 and whether it is a symbolic link."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative path"}
      },
      "required": ["path"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false

    static let descriptor = ToolCatalog.Descriptor(
        name: name,
        toolDescription: toolDescription,
        parametersJSON: parametersJSON,
        riskLabels: riskLabels,
        isSideEffecting: isSideEffecting,
        requiresHostScope: false
    )

    private let root: MacAgentWorkspaceRoot
    public init(rootURL: URL) {
        self.root = MacAgentWorkspaceRoot(rootURL)
    }

    public func validate(_ args: Arguments) throws {
        if args.path.trimmingCharacters(in: .whitespaces).isEmpty {
            throw MacAgentWorkspaceToolsError.invalidArguments("path must not be empty")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try macWorkspacePreflight(path: args.path, context: context, scopeArgument: args.scope)
        let (physicalRoot, relative) = try macWorkspacePinSetup(root: root, path: args.path)
        let summary = try MacAgentWorkspacePinSupport.withPinnedTarget(
            physicalRoot: physicalRoot, relative: relative, root: root
        ) { pin in
            // Root target: the pinned descriptor is the directory itself.
            if pin.name.isEmpty {
                var info = stat()
                guard fstat(pin.parentFileDescriptor, &info) == 0 else {
                    throw MacAgentWorkspaceToolsError.notFound(args.path)
                }
                return Self.summary(
                    path: args.path,
                    isDirectory: true,
                    size: 0,
                    mtime: TimeInterval(info.st_mtimespec.tv_sec) + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000,
                    uti: "public.folder",
                    sha256: "",
                    isSymlink: false
                )
            }
            let status = MacAgentWorkspacePinSupport.leafStatus(pin)
            guard status.exists else {
                throw MacAgentWorkspaceToolsError.notFound(args.path)
            }
            if status.symlink {
                return Self.summary(
                    path: args.path,
                    isDirectory: false,
                    size: Int(status.info.st_size),
                    mtime: TimeInterval(status.info.st_mtimespec.tv_sec) + TimeInterval(status.info.st_mtimespec.tv_nsec) / 1_000_000_000,
                    uti: "public.symlink",
                    sha256: "",
                    isSymlink: true
                )
            }
            guard status.info.st_mode & S_IFMT == S_IFDIR
                    || status.info.st_mode & S_IFMT == S_IFREG else {
                throw MacAgentWorkspaceToolsError.invalidArguments(
                    "'\(args.path)' is neither a regular file nor a directory"
                )
            }
            let isDirectory = status.info.st_mode & S_IFMT == S_IFDIR
            let size = Int(status.info.st_size)
            // Open by descriptor for the hash so the bytes verified are the
            // bytes of the pinned leaf, not a swapped path.
            let sha256: String
            if isDirectory {
                sha256 = ""
            } else {
                let descriptor = try MacAgentWorkspacePinSupport.openVerifiedRegularFile(
                    pin, physicalRoot: physicalRoot, displayPath: args.path
                )
                defer { Darwin.close(descriptor) }
                guard size <= MacAgentWorkspaceTools.maxReadBytes else {
                    throw MacAgentWorkspaceToolsError.tooLarge(limit: MacAgentWorkspaceTools.maxReadBytes)
                }
                let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
                    .read(upToCount: MacAgentWorkspaceTools.maxReadBytes + 1) ?? Data()
                guard data.count == size else {
                    throw MacAgentWorkspaceToolsError.invalidArguments("file changed during inspection")
                }
                sha256 = FloeDigest.sha256Hex(data)
            }
            let uti = isDirectory
                ? "public.folder"
                : (UTType(filenameExtension: (pin.name as NSString).pathExtension)?.identifier ?? "public.data")
            return Self.summary(
                path: args.path,
                isDirectory: isDirectory,
                size: size,
                mtime: TimeInterval(status.info.st_mtimespec.tv_sec) + TimeInterval(status.info.st_mtimespec.tv_nsec) / 1_000_000_000,
                uti: uti,
                sha256: sha256,
                isSymlink: false
            )
        }
        return ToolExecutionOutput(digesting: summary, maximumSummaryCharacters: 4096)
    }

    private static func summary(
        path: String,
        isDirectory: Bool,
        size: Int,
        mtime: TimeInterval,
        uti: String,
        sha256: String,
        isSymlink: Bool
    ) -> String {
        """
        path=\(path)
        isDirectory=\(isDirectory)
        size=\(size)
        mtime=\(mtime)
        uti=\(uti)
        sha256=\(sha256)
        isSymlink=\(isSymlink)
        """
    }
}

// MARK: workspace.readDocument

public struct MacAgentWorkspaceReadDocumentTool: AgentTool, MacAgentWorkspaceExecutable {
    public struct Arguments: Decodable, Sendable {
        let path: String
        let limit: Int?
        let scope: String?
    }

    public static let name = MacAgentWorkspaceTools.readDocumentToolName
    public static let toolDescription =
        "Read the text layer of one PDF or Word DOCX document in the selected project. Use workspace.readFile for UTF-8 text. Documents that exceed the character budget return an error."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative PDF or DOCX file path"},
        "limit": {"type": "integer", "description": "Extraction limit in characters (default 65536, up to 131072)"}
      },
      "required": ["path"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.readsFiles]
    public static let isSideEffecting = false
    static let descriptor = ToolCatalog.Descriptor(
        name: name,
        toolDescription: toolDescription,
        parametersJSON: parametersJSON,
        riskLabels: riskLabels,
        isSideEffecting: isSideEffecting,
        requiresHostScope: false
    )

    private let root: MacAgentWorkspaceRoot

    public init(rootURL: URL) {
        self.root = MacAgentWorkspaceRoot(rootURL)
    }

    public func validate(_ args: Arguments) throws {
        guard !args.path.isEmpty, (args.limit ?? 1) > 0 else {
            throw MacAgentWorkspaceToolsError.invalidArguments("path and a positive extraction limit are required")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try macWorkspacePreflight(path: args.path, context: context, scopeArgument: args.scope)
        guard let kind = FloeMacDocumentText.Kind(rawValue: (args.path as NSString).pathExtension.lowercased()) else {
            throw MacAgentWorkspaceToolsError.invalidArguments("choose a PDF or DOCX document")
        }
        let (physicalRoot, relative) = try macWorkspacePinSetup(root: root, path: args.path)
        let bytes = try MacAgentWorkspacePinSupport.withPinnedTarget(
            physicalRoot: physicalRoot, relative: relative, root: root
        ) { pin in
            let descriptor = try MacAgentWorkspacePinSupport.openVerifiedRegularFile(
                pin, physicalRoot: physicalRoot, displayPath: args.path
            )
            defer { Darwin.close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0 else { throw MacAgentWorkspaceToolsError.notFound(args.path) }
            let maxBytes = MacAgentWorkspaceTools.maxReadBytes
            guard info.st_size <= maxBytes else { throw MacAgentWorkspaceToolsError.tooLarge(limit: maxBytes) }
            let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
                .read(upToCount: maxBytes + 1) ?? Data()
            guard data.count == info.st_size else { throw MacAgentWorkspaceToolsError.revisionChanged }
            return data
        }
        try context.cancellation.throwIfCancelled()
        let limit = min(args.limit ?? MacAgentWorkspaceTools.readChunkBytes, 131_072)
        do {
            let text = try FloeMacDocumentText.extract(bytes, type: kind, limit: limit)
            try context.cancellation.throwIfCancelled()
            return ToolExecutionOutput(
                digesting: "path=\(relative) format=\(kind.rawValue) characters=\(text.count)\n\(text)",
                maximumSummaryCharacters: 196_608
            )
        } catch FloeMacDocumentTextError.limitExceeded {
            throw MacAgentWorkspaceToolsError.documentTextUnavailable(
                "the extracted text exceeds \(limit) characters; try with a higher limit up to 131072"
            )
        } catch let error as FloeMacDocumentTextError {
            throw MacAgentWorkspaceToolsError.documentTextUnavailable(error.rawValue)
        }
    }
}

// MARK: - Native visual tools (OCR, barcode, PDF page evidence)

// MAC_VISION_CORE_BEGIN
/// Local, on-device visual processing shared by `image.ocr`,
/// `image.barcode.scan` and the `image.inspect` PDF page renderer. This is
/// the Mac port of the iPad `FloeExecution/Tools/VisionTools.swift` +
/// `RemoteImageInspectTool` page rendering: Apple Vision runs locally and
/// privately, no bytes leave the machine from this core, and every input is
/// bounded before decoding. Pure Foundation/Vision/PDFKit/AppKit by design —
/// no Floe types — so the exact production bodies can be exercised by the
/// standalone focused check without linking the app.
enum MacWorkspaceVisionSupport {
    /// iPad `image.ocr` / `image.barcode.scan` input ceiling.
    static let maximumInputBytes = 10 * 1_024 * 1_024
    /// iPad `image.inspect` source ceiling (raster or PDF).
    static let maximumSourceBytes = 20 * 1_024 * 1_024
    /// Rendered page-artifact ceiling; keep in lockstep with
    /// `VerifiedToolImageArtifact.maximumStoredImageBytes` (24 MiB).
    static let maximumRenderedBytes = 24 * 1_024 * 1_024
    /// Longest edge of a rendered PDF page, matching the iPad renderer.
    static let renderedPageMaxDimension: CGFloat = 2_048
    /// JPEG quality for rendered pages, matching the iPad renderer.
    static let renderedPageJPEGQuality = 0.86
    /// iPad OCR / Notes recognition language policy: Chinese first
    /// (simplified, then traditional), then English, with automatic
    /// per-line detection. Intersected with the languages this device
    /// reports so an absent model fails closed to what is supported.
    static let preferredRecognitionLanguages = ["zh-Hans", "zh-Hant", "en-US"]

    enum Failure: Error, LocalizedError {
        case emptyInput
        case notReadableImage
        case recognitionFailed(String)
        case pdfUnavailable
        case pdfPageOutOfRange(page: Int, pageCount: Int)
        case pdfPageRenderFailed(String)
        case renderedPageTooLarge(Int)

        var errorDescription: String? {
            switch self {
            case .emptyInput:
                "no visual input was supplied"
            case .notReadableImage:
                "the input is not a readable PNG/JPEG image"
            case .recognitionFailed(let message):
                "vision recognition failed: \(message)"
            case .pdfUnavailable:
                "the PDF could not be opened"
            case .pdfPageOutOfRange(let page, let pageCount):
                "PDF page must be between 1 and \(pageCount) (requested \(page))"
            case .pdfPageRenderFailed(let message):
                "the PDF page could not be rendered: \(message)"
            case .renderedPageTooLarge(let limit):
                "the rendered page exceeds the \(limit)-byte artifact limit"
            }
        }
    }

    /// True when the bytes (or the path extension) identify a PDF document.
    static nonisolated func isPDF(_ data: Data, path: String) -> Bool {
        data.starts(with: Data("%PDF".utf8))
            || URL(fileURLWithPath: path).pathExtension.lowercased() == "pdf"
    }

    /// True when the bytes carry one of the raster signatures Vision accepts
    /// for OCR/scan (PNG, JPEG, GIF, WebP). This is the readability gate that
    /// keeps undecodable input an ordinary tool error; encoded bytes are then
    /// handed straight to Vision.
    static nonisolated func hasRasterSignature(_ data: Data) -> Bool {
        if data.count >= 3, data.starts(with: [0xFF, 0xD8, 0xFF]) { return true }
        if data.count >= 8, data.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return true }
        if data.count >= 6, data.starts(with: Array("GIF8".utf8)) { return true }
        if data.count >= 12,
           data.prefix(4) == Data("RIFF".utf8),
           data.dropFirst(8).prefix(4) == Data("WEBP".utf8) { return true }
        return false
    }

    /// Runs Apple Vision text recognition and returns the iPad-format lines
    /// (`text [x,y wxh]`, percentages). Throws when the image is unreadable or
    /// recognition fails; an image with no text returns an empty array.
    ///
    /// The encoded bytes go straight into `VNImageRequestHandler(data:)`
    /// — the exact native path `MacComposerImageTextImport` proves in the App
    /// — so no AppKit `NSImage` lazy decode can stall a detached task or touch
    /// the UI actor.
    static nonisolated func recognizeText(from data: Data, language: String? = nil) throws -> [String] {
        guard !data.isEmpty else { throw Failure.emptyInput }
        #if canImport(Vision)
        guard hasRasterSignature(data) else { throw Failure.notReadableImage }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if let language, !language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            request.recognitionLanguages = [language]
        } else if let supported = try? request.supportedRecognitionLanguages() {
            let kept = preferredRecognitionLanguages.filter { supported.contains($0) }
            request.recognitionLanguages = kept.isEmpty ? preferredRecognitionLanguages : kept
        } else {
            request.recognitionLanguages = preferredRecognitionLanguages
        }
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(data: data, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw Failure.recognitionFailed(error.localizedDescription)
        }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let box = observation.boundingBox
            return "\(candidate.string) [\(Int(box.origin.x * 100)),\(Int(box.origin.y * 100)) \(Int(box.width * 100))x\(Int(box.height * 100))]"
        }
        #else
        throw Failure.recognitionFailed("Vision framework not available")
        #endif
    }

    /// Runs Apple Vision barcode/QR detection and returns the iPad-format
    /// lines (`- [symbology] payload`). An image with no codes returns an
    /// empty array. Uses the same encoded-byte handler as OCR.
    static nonisolated func scanBarcodes(from data: Data) throws -> [String] {
        guard !data.isEmpty else { throw Failure.emptyInput }
        #if canImport(Vision)
        guard hasRasterSignature(data) else { throw Failure.notReadableImage }
        let request = VNDetectBarcodesRequest()
        let handler = VNImageRequestHandler(data: data, options: [:])
        do {
            try handler.perform([request])
        } catch {
            throw Failure.recognitionFailed(error.localizedDescription)
        }
        return (request.results ?? []).map { observation in
            let content = observation.payloadStringValue ?? "cannot decode"
            return "- [\(observation.symbology.rawValue)] \(content)"
        }
        #else
        throw Failure.recognitionFailed("Vision framework not available")
        #endif
    }

    /// Renders one 1-based PDF page to a bounded JPEG, mirroring the iPad
    /// `RemoteImageInspectTool` renderer: white background, page drawn in its
    /// media box, longest edge capped at 2,048 points with scale at most 2.
    /// `PDFKitGate` serialization is applied by the caller.
    static nonisolated func renderPDFPage(
        from data: Data, page requestedPage: Int
    ) throws -> (data: Data, page: Int, pageCount: Int) {
        guard !data.isEmpty else { throw Failure.emptyInput }
        guard requestedPage >= 1 else {
            throw Failure.pdfPageOutOfRange(page: requestedPage, pageCount: 0)
        }
        #if canImport(PDFKit) && canImport(AppKit)
        guard let document = PDFDocument(data: data), document.pageCount > 0 else {
            throw Failure.pdfUnavailable
        }
        guard requestedPage <= document.pageCount,
              let page = document.page(at: requestedPage - 1) else {
            throw Failure.pdfPageOutOfRange(page: requestedPage, pageCount: document.pageCount)
        }
        let bounds = page.bounds(for: .mediaBox)
        guard bounds.width > 0, bounds.height > 0 else {
            throw Failure.pdfPageRenderFailed("the page has invalid bounds")
        }
        let scale = min(renderedPageMaxDimension / max(bounds.width, bounds.height), 2)
        let size = CGSize(
            width: max(1, floor(bounds.width * scale)),
            height: max(1, floor(bounds.height * scale))
        )
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: Int(size.width), height: Int(size.height),
            bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw Failure.pdfPageRenderFailed("a drawing context could not be created")
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
        // A raw CG bitmap context is already a y-up Quartz space, exactly the
        // PDF user space; only the uniform page scale is needed. (The iPad
        // renderer flips because UIGraphicsImageRenderer is a UIKit top-left
        // space — copying that flip here renders a blank white page.)
        context.saveGState()
        context.scaleBy(x: scale, y: scale)
        page.draw(with: .mediaBox, to: context)
        context.restoreGState()
        guard let cgImage = context.makeImage() else {
            throw Failure.pdfPageRenderFailed("the page produced no image")
        }
        let rep = NSBitmapImageRep(cgImage: cgImage)
        guard let jpeg = rep.representation(using: .jpeg, properties: [.compressionFactor: renderedPageJPEGQuality]) else {
            throw Failure.pdfPageRenderFailed("the rendered page could not be encoded as JPEG")
        }
        guard jpeg.count <= maximumRenderedBytes else {
            throw Failure.renderedPageTooLarge(maximumRenderedBytes)
        }
        return (jpeg, requestedPage, document.pageCount)
        #else
        throw Failure.pdfUnavailable
        #endif
    }
}
// MAC_VISION_CORE_END

/// Resolves the two supported vision tool inputs without exposing arbitrary
/// file URLs: a workspace-relative path is pinned and read through the shared
/// verified-file machinery; inline base64 is bounded before decoding. The
/// layout mirrors the iPad `WorkspaceVisionInput` helper.
enum MacWorkspaceVisionInput {
    static func load(base64: String?, path: String?, root: MacAgentWorkspaceRoot, context: ToolContext) throws -> Data {
        if let base64, !base64.isEmpty {
            guard let data = Data(base64Encoded: base64), !data.isEmpty else {
                throw MacAgentWorkspaceToolsError.invalidArguments("imageBase64 must be valid base64 image data")
            }
            guard data.count <= MacWorkspaceVisionSupport.maximumInputBytes else {
                throw MacAgentWorkspaceToolsError.tooLarge(limit: MacWorkspaceVisionSupport.maximumInputBytes)
            }
            return data
        }
        guard let path else {
            throw MacAgentWorkspaceToolsError.invalidArguments("No image input was supplied")
        }
        try macWorkspacePreflight(path: path, context: context, scopeArgument: nil)
        let (physical, relative) = try macWorkspacePinSetup(root: root, path: path)
        return try MacAgentWorkspacePinSupport.withPinnedTarget(physicalRoot: physical, relative: relative, root: root) { pin in
            let descriptor = try MacAgentWorkspacePinSupport.openVerifiedRegularFile(pin, physicalRoot: physical, displayPath: path)
            defer { Darwin.close(descriptor) }
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_size > 0, info.st_nlink == 1 else {
                throw MacAgentWorkspaceToolsError.notFound(path)
            }
            guard info.st_size <= MacWorkspaceVisionSupport.maximumInputBytes else {
                throw MacAgentWorkspaceToolsError.tooLarge(limit: MacWorkspaceVisionSupport.maximumInputBytes)
            }
            let data = try FileHandle(fileDescriptor: descriptor, closeOnDealloc: true).read(upToCount: MacWorkspaceVisionSupport.maximumInputBytes + 1) ?? Data()
            guard data.count == info.st_size else { throw MacAgentWorkspaceToolsError.revisionChanged }
            return data
        }
    }
}

/// OCR tool: recognizes text in a workspace image using on-device Apple
/// Vision. Mirrors the upstream iPad `image.ocr` name, schema and per-line
/// output format; recognition stays local and private.
struct MacAgentWorkspaceOCRTool: AgentTool, MacAgentWorkspaceExecutable {
    struct Arguments: Decodable, Sendable {
        var imageBase64: String?
        var path: String?
        var language: String?
    }

    static let name = "image.ocr"
    static let toolDescription =
        "Recognize text in a PNG/JPEG image using on-device Apple Vision OCR. Pass either a workspace-relative path (preferred for uploaded files) or base64 bytes. Returns recognized Chinese/English text with bounding boxes."
    static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative path to an uploaded PNG/JPEG image, for example Attachments/.../photo.jpg"},
        "imageBase64": {"type": "string", "description": "Base64-encoded PNG/JPEG bytes; omit when path is supplied"},
        "language": {"type": "string", "description": "Recognition language: zh-Hans, zh-Hant, en-US, etc. (default: auto-detect)"}
      },
      "required": [],
      "additionalProperties": false
    }
    """#
    static let riskLabels: Set<RiskLabel> = [.readsFiles]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly

    let root: MacAgentWorkspaceRoot

    func validate(_ args: Arguments) throws {
        let hasBase64 = !(args.imageBase64?.isEmpty ?? true)
        let hasPath = !(args.path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard hasBase64 != hasPath else {
            throw MacAgentWorkspaceToolsError.invalidArguments("Supply exactly one of path or imageBase64")
        }
        if let language = args.language, language.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw MacAgentWorkspaceToolsError.invalidArguments("language must not be empty when supplied")
        }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let imageData = try MacWorkspaceVisionInput.load(base64: args.imageBase64, path: args.path, root: root, context: context)
        let language = args.language
        let lines = try await Task.detached(priority: .userInitiated) {
            try MacWorkspaceVisionSupport.recognizeText(from: imageData, language: language)
        }.value
        try context.cancellation.throwIfCancelled()
        let body = lines.isEmpty
            ? "no text recognized"
            : "recognized \(lines.count) lines of text:\n" + lines.joined(separator: "\n")
        return .init(digesting: body, maximumSummaryCharacters: MacAgentWorkspaceTools.visionReadSummaryCharacters)
    }
}

/// Barcode/QR scanner tool: reads codes in a workspace image using on-device
/// Apple Vision. Mirrors the upstream iPad `image.barcode.scan` name, schema
/// and output format; decoding stays local and private.
struct MacAgentWorkspaceBarcodeScanTool: AgentTool, MacAgentWorkspaceExecutable {
    struct Arguments: Decodable, Sendable {
        var imageBase64: String?
        var path: String?
    }

    static let name = "image.barcode.scan"
    static let toolDescription =
        "Scan barcodes and QR codes in a PNG/JPEG image using on-device Apple Vision. Pass a workspace-relative path (preferred) or base64 bytes."
    static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative path to an uploaded PNG/JPEG image"},
        "imageBase64": {"type": "string", "description": "Base64-encoded PNG/JPEG bytes; omit when path is supplied"}
      },
      "required": [],
      "additionalProperties": false
    }
    """#
    static let riskLabels: Set<RiskLabel> = [.readsFiles]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly

    let root: MacAgentWorkspaceRoot

    func validate(_ args: Arguments) throws {
        let hasBase64 = !(args.imageBase64?.isEmpty ?? true)
        let hasPath = !(args.path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard hasBase64 != hasPath else {
            throw MacAgentWorkspaceToolsError.invalidArguments("Supply exactly one of path or imageBase64")
        }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        let imageData = try MacWorkspaceVisionInput.load(base64: args.imageBase64, path: args.path, root: root, context: context)
        let codes = try await Task.detached(priority: .userInitiated) {
            try MacWorkspaceVisionSupport.scanBarcodes(from: imageData)
        }.value
        try context.cancellation.throwIfCancelled()
        let body = codes.isEmpty
            ? "no barcode or QR code recognized"
            : "recognized \(codes.count) barcode/QR code(s):\n" + codes.joined(separator: "\n")
        return .init(digesting: body, maximumSummaryCharacters: MacAgentWorkspaceTools.visionReadSummaryCharacters)
    }
}

/// Bind an existing workspace image — or one rendered page of a workspace
/// PDF — to its bytes for the shared vision delivery route. The original file
/// remains in place; a rendered PDF page is retained as a tool-owned,
/// content-addressed derived JPEG under `InspectPages/` so the runtime's
/// verified-artifact evidence route can reload and digest-check it.
struct MacAgentWorkspaceInspectImageTool: AgentTool, MacAgentWorkspaceExecutable {
    struct Arguments: Decodable, Sendable {
        let path: String
        let question: String
        let page: Int?
        let sha256: String?
    }

    static let name = "image.inspect"
    static let toolDescription = "Inspect a PNG, JPEG, WebP, GIF or PDF page in the current workspace, including a window screenshot. Provide the workspace-relative path and a focused visual question. For a PDF, pass the 1-based page to inspect (defaults to page 1); the selected page is rendered locally and delivered as verified visual evidence. If the producing tool reported a SHA-256 digest, pass it to inspect that exact file. The next model request receives verified visual evidence for the question."
    static let parametersJSON = #"{"type":"object","properties":{"path":{"type":"string"},"question":{"type":"string"},"page":{"type":"integer","minimum":1,"description":"1-based PDF page; omit for ordinary images"},"sha256":{"type":"string"}},"required":["path","question"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.readsFiles, .sendsDataToProvider]
    static let isSideEffecting = false
    static let toolEffect: ToolEffect = .readOnly
    let root: MacAgentWorkspaceRoot

    func validate(_ args: Arguments) throws {
        let question = args.question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !args.path.isEmpty, !question.isEmpty, question.utf8.count <= 2_000,
              args.page.map({ $0 >= 1 }) != false,
              args.sha256.map({ $0.range(of: #"^[a-fA-F0-9]{64}$"#, options: .regularExpression) != nil }) != false else {
            throw MacAgentWorkspaceToolsError.invalidArguments("provide an image/PDF path, a focused question, an optional 1-based page and an optional SHA-256")
        }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try macWorkspacePreflight(path: args.path, context: context, scopeArgument: nil)
        let (physical, relative) = try macWorkspacePinSetup(root: root, path: args.path)
        let artifact = try MacAgentWorkspacePinSupport.withPinnedTarget(physicalRoot: physical, relative: relative, root: root) { pin in
            let descriptor = try MacAgentWorkspacePinSupport.openVerifiedRegularFile(pin, physicalRoot: physical, displayPath: args.path)
            let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            var info = stat()
            guard fstat(descriptor, &info) == 0, info.st_size > 0, info.st_nlink == 1 else {
                throw MacAgentWorkspaceToolsError.revisionChanged
            }
            let sourceLimit = MacWorkspaceVisionSupport.maximumSourceBytes
            guard info.st_size <= sourceLimit else { throw MacAgentWorkspaceToolsError.tooLarge(limit: sourceLimit) }
            let data = try file.read(upToCount: sourceLimit + 1) ?? Data()
            guard data.count == info.st_size else { throw MacAgentWorkspaceToolsError.revisionChanged }
            let hash = FloeDigest.sha256Hex(data)
            guard args.sha256.map({ $0.lowercased() == hash }) != false else {
                throw MacAgentWorkspaceToolsError.revisionChanged
            }
            if MacWorkspaceVisionSupport.isPDF(data, path: args.path) {
                let rendered = try PDFKitGate.run {
                    try MacWorkspaceVisionSupport.renderPDFPage(from: data, page: args.page ?? 1)
                }
                try context.cancellation.throwIfCancelled()
                return try retainRenderedPage(rendered, sourceDigest: hash, context: context)
            }
            guard args.page == nil else {
                throw MacAgentWorkspaceToolsError.invalidArguments("page is only valid for PDF inputs")
            }
            guard let mime = ProviderImageEvidencePolicy.sniffedMIME(data) else {
                throw MacAgentWorkspaceToolsError.invalidArguments("choose a valid PNG, JPEG, WebP or GIF, or a PDF")
            }
            let limit = VerifiedToolImageArtifact.maximumStoredImageBytes
            guard data.count <= limit else { throw MacAgentWorkspaceToolsError.tooLarge(limit: limit) }
            return ToolArtifactReference(id: UUID(), relativePath: relative, mimeType: mime, byteCount: data.count, sha256: hash)
        }
        try context.cancellation.throwIfCancelled()
        return .init(digesting: "Image verified for visual delivery: \(relative)\nVisual question: \(args.question)", artifacts: [artifact])
    }

    /// Publishes the rendered page through the shared verified media commit
    /// (pinned parent, staged write, fsync, digest-verified exclusive
    /// rename). Re-inspecting the same page reuses the retained derived file
    /// when its digest still matches; a changed source re-renders and
    /// republishes under the content-addressed source directory.
    private func retainRenderedPage(
        _ rendered: (data: Data, page: Int, pageCount: Int),
        sourceDigest: String,
        context: ToolContext
    ) throws -> ToolArtifactReference {
        let directory = "InspectPages/" + String(sourceDigest.prefix(24))
        let folder = try MacTaskMediaDirectory(
            root: root, relativeDirectory: directory, context: context
        )
        let name = "page-\(rendered.page).jpg"
        let digest = FloeDigest.sha256Hex(rendered.data)
        if let retained = try? folder.read(name: name, maximumBytes: MacWorkspaceVisionSupport.maximumRenderedBytes, context: context),
           FloeDigest.sha256Hex(retained) == digest {
            return ToolArtifactReference(
                id: UUID(), relativePath: directory + "/" + name,
                mimeType: "image/jpeg", byteCount: retained.count, sha256: digest
            )
        }
        return try folder.commit(
            name: name, mimeType: "image/jpeg", data: rendered.data, context: context
        )
    }
}

// MARK: workspace.createFile

/// Creates one new UTF-8 text file inside the selected project workspace.
/// Exclusive and strict: the target must not exist in any form (checked
/// through the pinned parent descriptor), the parent directory must already
/// exist (it is pinned per-component with O_NOFOLLOW; nothing is ever
/// created implicitly), and there is no overwrite mode. The write is staged
/// in the pinned directory, fsynced, published with
/// `renameatx_np(RENAME_EXCL)` (hard-link fallback) after staging and
/// verified byte-for-byte, so a failure or a swapped publish is detected
/// and leaves nothing behind.
public struct MacAgentWorkspaceCreateFileTool: AgentTool, MacAgentWorkspaceExecutable {
    public struct Arguments: Decodable, Sendable {
        public var path: String
        public var content: String
        public var scope: String?

        public init(path: String, content: String, scope: String? = nil) {
            self.path = path
            self.content = content
            self.scope = scope
        }
    }

    public static let name = MacAgentWorkspaceTools.createFileToolName
    public static let toolDescription =
        "Create one new plain-text file inside the selected project workspace: Markdown, source code, scripts, JSON/YAML/CSV, HTML/CSS/JS, LaTeX, TXT or configuration. The file must not already exist (no overwrite) and its parent directory must already exist. Content must be UTF-8 text up to 4 MiB."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative path for the new plain-text file"},
        "content": {"type": "string", "description": "Full UTF-8 text content"}
      },
      "required": ["path", "content"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true

    static let descriptor = ToolCatalog.Descriptor(
        name: name,
        toolDescription: toolDescription,
        parametersJSON: parametersJSON,
        riskLabels: riskLabels,
        isSideEffecting: isSideEffecting,
        requiresHostScope: false
    )

    private let root: MacAgentWorkspaceRoot
    public init(rootURL: URL) {
        self.root = MacAgentWorkspaceRoot(rootURL)
    }

    public func validate(_ args: Arguments) throws {
        if args.path.trimmingCharacters(in: .whitespaces).isEmpty {
            throw MacAgentWorkspaceToolsError.invalidArguments("path must not be empty")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try Task.checkCancellation()
        try macWorkspacePreflight(path: args.path, context: context, scopeArgument: args.scope)
        let (physicalRoot, relative) = try macWorkspacePinSetup(root: root, path: args.path)
        guard relative != "." else {
            throw MacAgentWorkspaceToolsError.invalidArguments(
                "path must name a new file, not the workspace root"
            )
        }
        let data = Data(args.content.utf8)
        guard data.count <= MacAgentWorkspaceTools.maxWriteBytes else {
            throw MacAgentWorkspaceToolsError.tooLarge(limit: MacAgentWorkspaceTools.maxWriteBytes)
        }
        let cancellation = context.cancellation

        let receipt = try MacAgentWorkspacePinSupport.withPinnedTarget(
            physicalRoot: physicalRoot, relative: relative, root: root
        ) { pin in
            // Strict absence through the pinned parent: covers existing
            // files, directories and dangling symlinks. A missing parent
            // already failed the per-component pin walk.
            let status = MacAgentWorkspacePinSupport.leafStatus(pin)
            guard !status.exists else {
                throw MacAgentWorkspaceToolsError.targetAlreadyExists(args.path)
            }
            guard status.missing else {
                throw MacAgentWorkspaceToolsError.invalidArguments(
                    "the target '\(args.path)' cannot be inspected: errno \(errno)"
                )
            }
            // Stage an exclusive temp file inside the pinned directory.
            let tempName = ".floe-agent-\(UUID().uuidString).tmp"
            let staged = openat(
                pin.parentFileDescriptor, tempName,
                O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600
            )
            guard staged >= 0 else {
                throw MacAgentWorkspaceToolsError.invalidArguments("the workspace directory is not writable")
            }
            defer {
                Darwin.close(staged)
                unlinkat(pin.parentFileDescriptor, tempName, 0)
            }

            let file = FileHandle(fileDescriptor: staged, closeOnDealloc: false)
            try file.write(contentsOf: data)
            try file.synchronize()
            try file.seek(toOffset: 0)
            let verified = try file.read(upToCount: data.count + 1) ?? Data()
            var held = stat(), named = stat()
            guard verified == data, fstat(staged, &held) == 0, held.st_nlink == 1,
                  fstatat(pin.parentFileDescriptor, tempName, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  held.st_dev == named.st_dev, held.st_ino == named.st_ino else {
                throw MacAgentWorkspaceToolsError.invalidArguments("the staged file changed before publication")
            }
            try cancellation.throwIfCancelled()

            var result = renameatx_np(
                pin.parentFileDescriptor, tempName, pin.parentFileDescriptor, pin.name,
                UInt32(RENAME_EXCL)
            )
            if result != 0, errno == ENOTSUP {
                result = linkat(pin.parentFileDescriptor, tempName, pin.parentFileDescriptor, pin.name, 0)
            }
            guard result == 0 else {
                if errno == EEXIST { throw MacAgentWorkspaceToolsError.targetAlreadyExists(args.path) }
                throw MacAgentWorkspaceToolsError.invalidArguments("the file could not be published")
            }

            let mtime = TimeInterval(held.st_mtimespec.tv_sec)
                + TimeInterval(held.st_mtimespec.tv_nsec) / 1_000_000_000
            return (byteCount: data.count, mtime: mtime, sha256: FloeDigest.sha256Hex(verified))
        }
        let summary = "created=\(args.path) bytes=\(receipt.byteCount) sha256=\(receipt.sha256) mtime=\(receipt.mtime)"
        return ToolExecutionOutput(digesting: summary, maximumSummaryCharacters: 4096)
    }
}

// MARK: workspace.replaceText

/// Replace one exact UTF-8 range in the revision the user approved. The
/// atomic exchange keeps the original inode at a unique sibling name, so
/// edits through an already-open descriptor remain recoverable.
public struct MacAgentWorkspaceReplaceTextTool: AgentTool, MacAgentWorkspaceExecutable {
    public struct Arguments: Decodable, Sendable {
        public let path: String
        public let oldText: String
        public let newText: String
        public let expectedSHA256: String
        public let expectedOccurrences: Int?
        public let scope: String?
    }

    public static let name = MacAgentWorkspaceTools.replaceTextToolName
    public static let toolDescription =
        "Replace one exact UTF-8 text occurrence in an existing workspace file, with approval. Read and inspect the file first; pass its complete pre-edit SHA256. The original is preserved beside the updated file. Inspect again if the revision changed."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "path": {"type": "string", "description": "Workspace-relative path to an existing text file"},
        "oldText": {"type": "string", "minLength": 1, "description": "Exact existing text with enough context to match once"},
        "newText": {"type": "string", "description": "Exact replacement text"},
        "expectedSHA256": {"type": "string", "description": "Complete SHA256 from workspace.inspectFileMetadata"},
        "expectedOccurrences": {"type": "integer", "enum": [1], "description": "Optional; this tool replaces one occurrence"}
      },
      "required": ["path", "oldText", "newText", "expectedSHA256"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.writesFiles]
    public static let isSideEffecting = true

    static let descriptor = ToolCatalog.Descriptor(
        name: name, toolDescription: toolDescription, parametersJSON: parametersJSON,
        riskLabels: riskLabels, isSideEffecting: isSideEffecting, requiresHostScope: false
    )

    private let root: MacAgentWorkspaceRoot

    public init(rootURL: URL) { root = MacAgentWorkspaceRoot(rootURL) }

    public func validate(_ args: Arguments) throws {
        let digest = args.expectedSHA256.lowercased().utf8
        guard !args.path.isEmpty, !args.oldText.isEmpty, (args.expectedOccurrences ?? 1) == 1,
              digest.count == 64, digest.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw MacAgentWorkspaceToolsError.invalidArguments("path, exact old text and a complete SHA256 are required")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        try Task.checkCancellation()
        try validate(args)
        try macWorkspacePreflight(path: args.path, context: context, scopeArgument: args.scope)
        let (physicalRoot, relative) = try macWorkspacePinSetup(root: root, path: args.path)
        let limit = MacAgentWorkspaceTools.maxWriteBytes
        let oldText = Data(args.oldText.utf8), newText = Data(args.newText.utf8)
        guard oldText.count <= limit, newText.count <= limit else {
            throw MacAgentWorkspaceToolsError.tooLarge(limit: limit)
        }
        guard !newText.contains(0) else { throw MacAgentWorkspaceToolsError.notTextFile(args.path) }

        let receipt = try MacAgentWorkspacePinSupport.withPinnedTarget(
            physicalRoot: physicalRoot, relative: relative, root: root
        ) { pin in
            let originalFD = try MacAgentWorkspacePinSupport.openVerifiedRegularFile(
                pin, physicalRoot: physicalRoot, displayPath: args.path, writable: true)
            defer { Darwin.close(originalFD) }
            guard flock(originalFD, LOCK_EX | LOCK_NB) == 0 else {
                throw MacAgentWorkspaceToolsError.revisionChanged
            }
            var originalIdentity = stat()
            guard fstat(originalFD, &originalIdentity) == 0 else {
                throw MacAgentWorkspaceToolsError.revisionChanged
            }
            guard originalIdentity.st_mode & (S_ISUID | S_ISGID) == 0 else {
                throw MacAgentWorkspaceToolsError.invalidArguments("files with setuid or setgid permissions cannot be edited")
            }
            let original = try MacAgentWorkspaceTextMutation.readBytes(originalFD, limit: limit)
            guard FloeDigest.sha256Hex(original) == args.expectedSHA256.lowercased() else {
                throw MacAgentWorkspaceToolsError.revisionChanged
            }
            guard !original.contains(0), String(data: original, encoding: .utf8) != nil else {
                throw MacAgentWorkspaceToolsError.notTextFile(args.path)
            }
            guard let match = original.range(of: oldText),
                  original[(match.lowerBound + 1)...].range(of: oldText) == nil else {
                throw MacAgentWorkspaceToolsError.exactTextMismatch
            }
            var updated = original
            updated.replaceSubrange(match, with: newText)
            guard updated.count <= limit else { throw MacAgentWorkspaceToolsError.tooLarge(limit: limit) }
            if updated == original { return (FloeDigest.sha256Hex(original), nil as String?) }

            let published = try MacAgentWorkspaceTextMutation.publishStagedReplacement(
                pin: pin, originalFD: originalFD, originalIdentity: originalIdentity,
                originalBytes: original, updated: updated, relative: relative,
                limit: limit, cancellation: context.cancellation
            )
            return (published.sha256, published.previous)
        }
        let previous = receipt.1.map { " previous=\($0)" } ?? ""
        return ToolExecutionOutput(digesting: "edited=\(relative) sha256=\(receipt.0)\(previous)",
                                   maximumSummaryCharacters: 4096)
    }
}

struct MacWorkspacePublishOutputTool: AgentTool, MacAgentWorkspaceExecutable {
    typealias Arguments = WorkspaceOutputPublication.Arguments

    static let name = WorkspaceOutputPublication.name
    static let toolDescription = WorkspaceOutputPublication.toolDescription
    static let parametersJSON = WorkspaceOutputPublication.parametersJSON
    static let riskLabels: Set<RiskLabel> = [.writesFiles]
    static let isSideEffecting = true

    let root: MacAgentWorkspaceRoot
    let artifactRoot: URL

    func validate(_ arguments: Arguments) throws {
        if let displayName = arguments.displayName, !RunOutputFile.isValidDisplayName(displayName) {
            throw MacAgentWorkspaceToolsError.invalidArguments("displayName must be a safe single filename component")
        }
    }

    func execute(_ arguments: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        let path = arguments.path
        try macWorkspacePreflight(path: path, context: context, scopeArgument: arguments.scope)
        let (physicalRoot, relative) = try macWorkspacePinSetup(root: root, path: path)
        let staging = try await StorageCleanupLeaseCenter.shared.makeLeasedScratch(purpose: "workspace")
        let folder = staging.url
        defer {
            try? FileManager.default.removeItem(at: folder)
            staging.lease.release()
        }
        try macWorkspacePreflight(path: path, context: context, scopeArgument: arguments.scope)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        return try MacAgentWorkspacePinSupport.withPinnedTarget(physicalRoot: physicalRoot, relative: relative, root: root) { pin in
            let descriptor = try MacAgentWorkspacePinSupport.openVerifiedRegularFile(pin, physicalRoot: physicalRoot, displayPath: path)
            defer { Darwin.close(descriptor) }
            let displayName = arguments.displayName ?? pin.name
            guard RunOutputFile.isValidDisplayName(displayName) else {
                throw MacAgentWorkspaceToolsError.invalidArguments("displayName must be a safe single filename component")
            }
            var before = stat()
            guard fstat(descriptor, &before) == 0, before.st_size >= 0 else { throw MacAgentWorkspaceToolsError.revisionChanged }
            let limit = RunOutputCaps.standard.perFileBytes
            guard before.st_size <= limit else { throw MacAgentWorkspaceToolsError.tooLarge(limit: limit) }

            // Freeze the authorized descriptor in private scratch so the shared
            // publisher never follows a user-controlled path after validation.
            let snapshot = folder.appendingPathComponent(pin.name)
            try Data().write(to: snapshot, options: .withoutOverwriting)
            let writer = try FileHandle(forWritingTo: snapshot)
            defer { try? writer.close() }
            let source = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            var count = 0
            while let chunk = try source.read(upToCount: 262_144), !chunk.isEmpty {
                try context.cancellation.throwIfCancelled()
                try Task.checkCancellation()
                guard chunk.count <= Int(before.st_size) - count else { throw MacAgentWorkspaceToolsError.revisionChanged }
                try writer.write(contentsOf: chunk)
                count += chunk.count
            }
            var after = stat(), named = stat()
            guard count == before.st_size, fstat(descriptor, &after) == 0, after.st_size == before.st_size, after.st_nlink == 1,
                  after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec, after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
                  after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec, after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec,
                  fstatat(pin.parentFileDescriptor, pin.name, &named, AT_SYMLINK_NOFOLLOW) == 0,
                  named.st_dev == before.st_dev, named.st_ino == before.st_ino else {
                throw MacAgentWorkspaceToolsError.revisionChanged
            }
            return try WorkspaceOutputPublication.publish(sourceURL: snapshot, displayName: displayName,
                                                           byteCount: count, context: context, artifactRoot: artifactRoot)
        }
    }
}

// MARK: - Executor

/// The focused native project-file executor. It owns the listed
/// catalog tools, each scoped to one verified workspace root; `readOnly`
/// builds simply omit the write tool so a plan-style session has no write
/// runner at all. Nothing else in the process registry is reachable through
/// this executor.
public struct MacAgentWorkspaceToolExecutor: ToolExecutor {
    public let workspaceRootURL: URL
    private let tools: [String: any MacAgentWorkspaceExecutable]

    public var allDescriptors: [ToolCatalog.Descriptor] {
        tools.values.map(\.executionDescriptor).sorted { $0.name < $1.name }
    }

    public init(workspaceRootURL: URL, runOutputArtifactRoot: URL? = nil, readOnly: Bool = false, search: MacSearchAccess? = nil,
                conversations: FloeMacConversationToolCapability? = nil,
                imageInspectionAvailable: Bool = false,
                imageTools: MacTaskImageTools? = nil, videoTools: [AnyAgentTool] = [], browserTools: [AnyAgentTool] = [],
                computerUseBackend: MacComputerUseBackend = .kimi,
                extensionTools: [AnyAgentTool] = [],
                observeShellOutput: (@Sendable (MacShellOutputUpdate) async -> Void)? = nil) {
        let root = workspaceRootURL.resolvingSymlinksInPath().standardizedFileURL
        self.workspaceRootURL = root
        var table: [String: any MacAgentWorkspaceExecutable] = [
            MacPublicWebFetch.name: MacPublicWebFetch(),
            MacAgentWorkspaceTools.listDirectoryToolName: MacAgentWorkspaceListDirectoryTool(rootURL: root),
            MacAgentWorkspaceTools.readFileToolName: MacAgentWorkspaceReadFileTool(rootURL: root),
            MacAgentWorkspaceTools.inspectFileMetadataToolName: MacAgentWorkspaceInspectMetadataTool(rootURL: root),
            MacAgentWorkspaceTools.searchFilesToolName: MacAgentWorkspaceSearchFilesTool(rootURL: root),
            MacAgentWorkspaceTools.readDocumentToolName: MacAgentWorkspaceReadDocumentTool(rootURL: root),
        ]
        if let search, search.isConfigured { table[MacSearchTool.name] = MacSearchTool(access: search) }
        if imageInspectionAvailable, !readOnly {
            table[MacAgentWorkspaceInspectImageTool.name] = MacAgentWorkspaceInspectImageTool(root: MacAgentWorkspaceRoot(root))
        }
        // Local Apple Vision tools mirror the iPad execution registry: they
        // run on-device and return text, so they stay available for every
        // task model, including text-only primaries.
        table[MacAgentWorkspaceOCRTool.name] = MacAgentWorkspaceOCRTool(root: MacAgentWorkspaceRoot(root))
        table[MacAgentWorkspaceBarcodeScanTool.name] = MacAgentWorkspaceBarcodeScanTool(root: MacAgentWorkspaceRoot(root))
        for tool in conversations?.tools ?? [] where !readOnly || ConversationToolAccess.plan.allows(tool.descriptor) {
            table[tool.descriptor.name] = tool
        }
        if !readOnly {
            if let imageTools {
                table[MacTaskImageModelsTool.name] = MacTaskImageModelsTool(access: imageTools)
                table[MacTaskImageGenerateTool.name] = MacTaskImageGenerateTool(access: imageTools, rootURL: root)
            }
            for tool in videoTools { table[tool.descriptor.name] = tool }
            for tool in browserTools { table[tool.descriptor.name] = tool }
            if FileManager.default.isExecutableFile(atPath: MacNativeShellTool.sandbox) {
                table[MacNativeShellTool.name] = MacNativeShellTool(root: MacAgentWorkspaceRoot(root), observe: observeShellOutput)
            }
            for tool in MacNativeDesktopTools.available(rootURL: root, backend: computerUseBackend) {
                table[tool.executionDescriptor.name] = tool
            }
            table[MacAgentWorkspaceTools.createFileToolName] = MacAgentWorkspaceCreateFileTool(rootURL: root)
            table[MacAgentWorkspaceTools.replaceTextToolName] = MacAgentWorkspaceReplaceTextTool(rootURL: root)
            table[MacAgentWorkspaceTools.writeFileToolName] = MacAgentWorkspaceWriteFileTool(rootURL: root)
            table[MacAgentWorkspaceTools.appendFileToolName] = MacAgentWorkspaceAppendFileTool(rootURL: root)
            table[MacAgentWorkspaceTools.applyPatchToolName] = MacAgentWorkspaceApplyPatchTool(rootURL: root, artifactRoot: runOutputArtifactRoot)
            table[MacAgentWorkspaceTools.createDirectoryToolName] = MacAgentWorkspaceCreateDirectoryTool(rootURL: root)
            if let runOutputArtifactRoot {
                table[WorkspaceOutputPublication.name] = MacWorkspacePublishOutputTool(
                    root: MacAgentWorkspaceRoot(root), artifactRoot: runOutputArtifactRoot)
            }
        }
        for tool in extensionTools where table[tool.descriptor.name] == nil && tool.isAvailable() {
            if !readOnly || ConversationToolAccess.plan.allows(tool.descriptor) {
                table[tool.descriptor.name] = tool
            }
        }
        self.tools = table
    }

    public func descriptor(named name: String) -> ToolCatalog.Descriptor? {
        tools[name]?.executionDescriptor
    }

    public func execute(_ call: ToolCall, context: ToolContext) async throws -> ToolResult {
        try await execute(call, expectedAuthorizationIdentity: nil, context: context)
    }

    public func execute(
        _ call: ToolCall,
        expectedAuthorizationIdentity: String?,
        context: ToolContext
    ) async throws -> ToolResult {
        guard let tool = tools[call.toolName] else {
            return ToolResult(
                callID: call.id,
                status: .failed,
                outputSummary: "No runner registered for tool '\(call.toolName)'",
                outputDigest: ""
            )
        }
        if context.callOrigin?.kind == .delegatedChild || context.childExecution != nil {
            do {
                guard tool.executionDescriptor.executionBoundary != .mainRunOnly else { throw CancellationError() }
                try MacTaskWebAccess.validate(tool.executionDescriptor, context: context)
            } catch {
                return ToolResult(callID: call.id, status: .denied,
                                  outputSummary: "The parent task did not authorize this child call.", outputDigest: "")
            }
        }
        if let expectedAuthorizationIdentity,
           tool.executionDescriptor.authorizationIdentity != expectedAuthorizationIdentity {
            return ToolResult(
                callID: call.id,
                status: .denied,
                outputSummary: "Tool authority changed after approval; review the updated tool before retrying",
                outputDigest: ""
            )
        }
        do {
            let output = try await tool.run(argumentsJSON: call.argumentsJSON, context: context)
            let status: ToolResult.Status = context.cancellation.isCancelled
                ? .cancelled
                : ((output.exitStatus ?? 0) == 0 ? .ok : .failed)
            // Match the runtime's page-size treatment for bounded JSON pages.
            let longReads = [MacAgentWorkspaceTools.readFileToolName, MacAgentWorkspaceTools.readDocumentToolName, MacPublicWebFetch.name]
            let visionReads: Set<String> = [MacAgentWorkspaceOCRTool.name, MacAgentWorkspaceBarcodeScanTool.name]
            let summaryCap = FloeMacConversationTools.readToolNames.contains(call.toolName) ? ConversationEnvelope.maximumEnvelopeCharacters
                : call.toolName == MacTaskImageModelsTool.name ? 262_144
                : longReads.contains(call.toolName) || visionReads.contains(call.toolName) ? 196_608
                : (call.toolName == MacAgentWorkspaceTools.searchFilesToolName ? 32_768 : 4096)
            return ToolResult(
                callID: call.id,
                status: status,
                outputSummary: output.summary,
                outputDigest: output.fullOutputSHA256,
                exitStatus: output.exitStatus,
                artifacts: output.artifacts,
                outputFiles: output.outputFiles,
                maximumSummaryCharacters: summaryCap,
                capturedOutput: output.capturedOutput ?? output.summary,
                capturedOutputTruncated: output.capturedOutput == nil
                    ? output.summaryTruncated : output.capturedOutputTruncated,
                outcomeUnknown: output.outcomeUnknown,
                ephemeralSensitiveOutput: output.ephemeralSensitiveOutput
            )
        } catch is CancellationError {
            return ToolResult(callID: call.id, status: .cancelled,
                              outputSummary: "Cancelled", outputDigest: "")
        } catch {
            return ToolResult(
                callID: call.id,
                status: .failed,
                outputSummary: "Execution error: \(error.localizedDescription)",
                outputDigest: ""
            )
        }
    }
}
