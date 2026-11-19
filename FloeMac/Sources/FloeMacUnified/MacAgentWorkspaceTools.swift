// SPDX-License-Identifier: MPL-2.0
//
// MacAgentWorkspaceTools — focused, production native project-file tool
// capability for the unified Mac host ("Floe SelfCore" runtime).
//
// This file is the whole capability: a scoped ToolExecutor over the
// explicitly user-selected project workspace, plus a one-shot approval
// policy composition, exposed as one binding factory for the host to hand
// to `FloeMacSelfRuntime.startSession(_:provider:tools:)`.
//
// Design constraints honored here:
// - Explicit known-safe initial catalog only: three reads
//   (workspace.listDirectory / workspace.readFile /
//   workspace.inspectFileMetadata) and approved text creation/replacement.
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
// - One-shot approval: the policy composes the existing HumanApprovalPolicy
//   so every side-effecting call surfaces exactly one human card; reads are
//   non-side-effecting and are auto-allowed by the runtime before policy
//   consultation (the policy still allows them if consulted directly).

import Foundation
import Darwin
import UniformTypeIdentifiers
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
    /// Payload or file exceeds the bounded size cap.
    case tooLarge(limit: Int)

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
        case .tooLarge(let limit):
            "the payload exceeds the \(limit)-byte limit"
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
    public static let createFileToolName = "workspace.createFile"
    public static let replaceTextToolName = "workspace.replaceText"

    /// Read-only tools: allowed in both plan-style (`readOnly: true`) and
    /// agent/goal sessions. Plan sessions bind exactly this set.
    public static let readToolNames: Set<String> = [
        listDirectoryToolName,
        readFileToolName,
        inspectFileMetadataToolName,
    ]
    public static let writeToolNames: Set<String> = [createFileToolName, replaceTextToolName]

    /// Stable labels for the host gate (provenance, not secrets).
    public static let approvalPolicySource = "floe.security.human-one-shot"
    public static let toolCorpusIdentifier = "floe.macunified.workspace-tools.v1"
    public static let issuer = "floe.macunified.mac-agent-workspace-tools"

    /// Bounded sizes shared by every tool in this catalog.
    public static let maxReadBytes = 10 * 1024 * 1024
    public static let maxWriteBytes = 4 * 1024 * 1024
    public static let readChunkBytes = 64 * 1024
    public static let listPageSize = 200

    /// Composes the complete tool capability for one explicit user-selected
    /// project workspace.
    ///
    /// - Parameters:
    ///   - workspace: A real stored `.project` workspace record. Its
    ///     security-scoped root bookmark is resolved here; a stale or
    ///     unresolvable bookmark, a non-directory root, or the filesystem /
    ///     user-home root fails closed.
    ///   - readOnly: When true (plan-style investigation) the binding
    ///     advertises and permits only the read tools. When false
    ///     (agent/goal) text writes are added; every write
    ///     still requires exactly one human approval through the session's
    ///     pending-approval card.
    /// - Returns: A binding ready for `FloeMacSelfRuntime.startSession`.
    public static func binding(
        workspace: WorkspaceRecord,
        readOnly: Bool
    ) throws -> FloeMacSelfToolBinding {
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
        // The executor pins descriptors against the physical root; it must
        // exist at composition time or every tool would fail identically.
        guard MacAgentWorkspacePinSupport.physicalPath(root.path) != nil else {
            throw MacAgentWorkspaceToolsError.workspaceRootInvalid(
                "the physical workspace path is unavailable"
            )
        }

        let executor = MacAgentWorkspaceToolExecutor(
            workspaceRootURL: root,
            readOnly: readOnly
        )
        let allowed = readOnly ? readToolNames : readToolNames.union(writeToolNames)
        let gate = (try? CatastrophicActionGate.withBundledPatterns())
            ?? CatastrophicActionGate.failClosed(
                reason: "Mac workspace tool gate corpus unavailable"
            )
        let boundary = FloeMacSelfTaskBoundary(
            workspaceID: workspace.id,
            workspaceRootURL: root,
            allowedWorkspacePaths: [],
            ownership: .nativeHost
        )
        let hostGate = FloeMacSelfHostGate(
            workspaceID: workspace.id,
            workspaceRootPath: root.path,
            approvalPolicySource: approvalPolicySource,
            toolCorpusIdentifier: toolCorpusIdentifier,
            approvedToolNames: allowed,
            issuer: issuer
        )
        return FloeMacSelfToolBinding(
            executor: executor,
            policy: MacAgentWorkspaceOneShotApprovalPolicy(),
            gate: gate,
            auditSink: nil,
            boundary: boundary,
            allowedToolNames: allowed,
            hostGate: hostGate
        )
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

// MARK: - One-shot approval policy

/// Every side-effecting call composes to exactly one human decision; reads
/// never require a card.
///
/// The runtime already auto-allows non-side-effecting descriptors before
/// policy consultation, so in production only the two write tools reach
/// the decision path and `HumanApprovalPolicy` escalates it to the session's
/// pending-approval card. The read fast-path keeps the policy correct even
/// if a future runtime consults it for a read: it returns a single-use allow
/// instead of incorrectly escalating. No reusable grant is ever minted here.
public struct MacAgentWorkspaceOneShotApprovalPolicy: ApprovalPolicy {
    public let policyName = MacAgentWorkspaceTools.approvalPolicySource

    /// Risk labels whose presence makes a call side-effecting. Mirrors the
    /// runtime's descriptor classification for this catalog.
    private static let sideEffectingRisks: Set<String> = [
        RiskLabel.writesFiles.rawValue,
        RiskLabel.deletesFiles.rawValue,
        RiskLabel.executesLocalCode.rawValue,
        RiskLabel.executesRemoteCommand.rawValue,
        RiskLabel.modifiesRemoteSystem.rawValue,
        RiskLabel.controlsGUI.rawValue,
        RiskLabel.accessesCredentials.rawValue,
        RiskLabel.sendsDataToProvider.rawValue,
        RiskLabel.persistsPersonalData.rawValue,
        RiskLabel.changesAgentBehavior.rawValue,
    ]

    private let human = HumanApprovalPolicy()

    public init() {}

    public func decide(_ action: ProposedAction) async throws -> ApprovalDecision {
        guard !action.riskLabels.isDisjoint(with: Self.sideEffectingRisks) else {
            return .allow(
                scope: ApprovalScope(toolName: action.toolCall.toolName, singleUse: true),
                expiresAt: nil
            )
        }
        // The user decides this exact workspace mutation once.
        return try await human.decide(action)
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
}

// MARK: - Tool implementations

/// Shared executable surface so the executor can hold a homogeneous table.
/// `descriptor` is a static catalog fact; the constrained extension binds it
/// to the instance requirement.
protocol MacAgentWorkspaceExecutable: Sendable {
    static var descriptor: ToolCatalog.Descriptor { get }
    var executionDescriptor: ToolCatalog.Descriptor { get }
    func run(argumentsJSON: Data, context: ToolContext) async throws -> ToolExecutionOutput
}

extension MacAgentWorkspaceExecutable where Self: AgentTool {
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
private func macWorkspacePreflight(
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

private func macWorkspacePinSetup(root: MacAgentWorkspaceRoot, path: String) throws -> (String, String) {
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
            let original = try Self.readFile(originalFD, limit: limit)
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

            let parent = pin.parentFileDescriptor
            let previous = ".floe-previous-\(UUID().uuidString)"
            let staged = openat(parent, previous, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard staged >= 0 else {
                throw MacAgentWorkspaceToolsError.invalidArguments("the workspace directory is not writable")
            }
            var stagedIdentity = stat()
            guard fstat(staged, &stagedIdentity) == 0 else {
                Darwin.close(staged)
                throw MacAgentWorkspaceToolsError.replacementUnconfirmed(previous)
            }
            defer {
                // Unlink only the inode we staged. After the exchange this
                // name holds the original or a concurrent writer's entry.
                if Self.matches(stagedIdentity, named: previous, in: parent) {
                    unlinkat(parent, previous, 0)
                }
                Darwin.close(staged)
            }
            guard fcopyfile(originalFD, staged, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
                throw MacAgentWorkspaceToolsError.invalidArguments("the file metadata could not be preserved")
            }
            let file = FileHandle(fileDescriptor: staged, closeOnDealloc: false)
            try file.write(contentsOf: updated)
            try file.synchronize()
            guard try Self.readFile(staged, limit: limit) == updated else {
                throw MacAgentWorkspaceToolsError.invalidArguments("the staged replacement could not be verified")
            }
            try context.cancellation.throwIfCancelled()
            try Task.checkCancellation()
            var heldParent = stat(), currentParent = stat()
            guard fstat(parent, &heldParent) == 0, stat(pin.parentPhysicalPath, &currentParent) == 0,
                  heldParent.st_dev == currentParent.st_dev, heldParent.st_ino == currentParent.st_ino,
                  Self.matches(originalIdentity, named: pin.name, in: parent),
                  Self.matches(stagedIdentity, named: previous, in: parent),
                  try Self.readFile(originalFD, limit: limit) == original else {
                throw MacAgentWorkspaceToolsError.revisionChanged
            }
            guard renameatx_np(parent, previous, parent, pin.name, UInt32(RENAME_SWAP)) == 0 else {
                throw MacAgentWorkspaceToolsError.invalidArguments("the filesystem could not exchange the file and its staged revision")
            }
            var displaced = stat()
            let foundDisplaced = fstatat(parent, previous, &displaced, AT_SYMLINK_NOFOLLOW) == 0
            guard Self.matches(stagedIdentity, named: pin.name, in: parent),
                  Self.matches(originalIdentity, named: previous, in: parent),
                  (try? Self.readFile(originalFD, limit: limit)) == original else {
                // Restore the displaced entry only while our staged inode
                // still owns the target. A later writer's entry is kept.
                if foundDisplaced,
                   Self.matches(stagedIdentity, named: pin.name, in: parent),
                   Self.matches(displaced, named: previous, in: parent),
                   renameatx_np(parent, previous, parent, pin.name, UInt32(RENAME_SWAP)) == 0 {
                    throw MacAgentWorkspaceToolsError.revisionChanged
                }
                throw MacAgentWorkspaceToolsError.replacementUnconfirmed(previous)
            }
            guard fsync(parent) == 0, (try? Self.readFile(staged, limit: limit)) == updated,
                  Self.matches(stagedIdentity, named: pin.name, in: parent),
                  Self.matches(originalIdentity, named: previous, in: parent) else {
                throw MacAgentWorkspaceToolsError.replacementUnconfirmed(previous)
            }
            let parentPath = relative.split(separator: "/").dropLast().joined(separator: "/")
            return (FloeDigest.sha256Hex(updated), parentPath.isEmpty ? previous : parentPath + "/" + previous)
        }
        let previous = receipt.1.map { " previous=\($0)" } ?? ""
        return ToolExecutionOutput(digesting: "edited=\(relative) sha256=\(receipt.0)\(previous)",
                                   maximumSummaryCharacters: 4096)
    }

    private static func readFile(_ descriptor: Int32, limit: Int) throws -> Data {
        let reader = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        try reader.seek(toOffset: 0)
        let data = try reader.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw MacAgentWorkspaceToolsError.tooLarge(limit: limit) }
        return data
    }

    private static func matches(_ expected: stat, named path: String, in parent: Int32) -> Bool {
        var actual = stat()
        return fstatat(parent, path, &actual, AT_SYMLINK_NOFOLLOW) == 0
            && actual.st_dev == expected.st_dev && actual.st_ino == expected.st_ino
            && actual.st_nlink == 1 && (actual.st_mode & S_IFMT) == S_IFREG
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

    public init(workspaceRootURL: URL, readOnly: Bool = false) {
        let root = workspaceRootURL.resolvingSymlinksInPath().standardizedFileURL
        self.workspaceRootURL = root
        var table: [String: any MacAgentWorkspaceExecutable] = [
            MacAgentWorkspaceTools.listDirectoryToolName: MacAgentWorkspaceListDirectoryTool(rootURL: root),
            MacAgentWorkspaceTools.readFileToolName: MacAgentWorkspaceReadFileTool(rootURL: root),
            MacAgentWorkspaceTools.inspectFileMetadataToolName: MacAgentWorkspaceInspectMetadataTool(rootURL: root),
        ]
        if !readOnly {
            table[MacAgentWorkspaceTools.createFileToolName] = MacAgentWorkspaceCreateFileTool(rootURL: root)
            table[MacAgentWorkspaceTools.replaceTextToolName] = MacAgentWorkspaceReplaceTextTool(rootURL: root)
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
            let summaryCap = call.toolName == MacAgentWorkspaceTools.readFileToolName ? 196_608 : 4096
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
