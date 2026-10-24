// ANDROID NARROW MIRROR (lane job-bf610b6f22fe42ab): this file carries the
// tool-environment + support closure that the archive/browser/tool entry
// points require — `WorkspaceToolEnvironment` (including its network-mount
// route helpers) and `WorkspaceToolSupport`. Every retained statement is
// byte-equal to the ORIGINAL FloeAgent/Sources/FloeWorkspace/Tools/
// FileReadTools.swift at immutable public source
// 3fd597b537590b4e6c11c0a25f413361a66b42b6 (lines 1–170: the file comment,
// the shared environment struct and the support enum). The four read tool
// structs that follow in the original (workspace.listDirectory /
// workspace.readFile / workspace.searchFiles /
// workspace.inspectFileMetadata) are the FILES-domain agent-tool surface
// owned by the accepted B0 handoff's future relink — exactly as recorded in
// Local/Private/android-g04-20261024/r1/files-domain/SOURCE_READY.json and
// in Tools/TextEditTools.swift's pending-boundary note — and are therefore
// not duplicated here. Main replaces this whole file with the original when
// the files-domain tool relink lands; no symbol or semantics are redefined.
//
// No archive tool is registered by this lane: `WorkspaceArchiveTool` stays
// unregistered here (ToolCatalog/CapabilityExecutionRouter policy is Main's),
// so model-visible tool availability still reflects enabled+configured+usable,
// not merely compiled source.

// FloeWorkspace — Read-only agent file tools.
// See docs/ARCHITECTURE_AGENT_WORKSPACE.md §6: listDirectory / readFile /
// searchFiles / inspectFileMetadata. All are non-side-effecting, resolve
// every path through WorkspacePathGuard, and enforce the output limits in
// the tool table. Host scope is rejected with `unsupportedScope` (P1 is
// local workspace only).

import Foundation
import Crypto
import FloeCore
import FloeModels
import FloeTools

/// Shared dependencies for the workspace file tools.
public struct WorkspaceToolEnvironment: Sendable {
    /// Supplies the current workspace root; nil means no workspace is open.
    public var rootProvider: @Sendable () -> URL?
    /// Maximum read size applied to every guard created from the root.
    public var maxReadBytes: Int
    /// Maximum write size applied to every guard created from the root.
    public var maxWriteBytes: Int

    public init(
        rootProvider: @escaping @Sendable () -> URL?,
        maxReadBytes: Int = 10 * 1024 * 1024,
        maxWriteBytes: Int = 4 * 1024 * 1024
    ) {
        self.rootProvider = rootProvider
        self.maxReadBytes = maxReadBytes
        self.maxWriteBytes = maxWriteBytes
    }

    /// Builds a file service for the current workspace root. Agent
    /// executions carry the design freeze gate: ordinary model writes to a
    /// frozen design original are refused (with the recovery action) until
    /// the owning task adopts or rejects its candidate. Reads are unaffected.
    public func makeService(context: ToolContext) throws -> WorkspaceFileService {
        let root = try rootURL(context: context)
        let guardResolver = WorkspacePathGuard(
            rootURL: root,
            maxReadBytes: maxReadBytes,
            maxWriteBytes: maxWriteBytes,
            mounts: WorkspaceMountRegistry.shared.mounts(for: root)
        )
        return WorkspaceFileService(
            guard: guardResolver,
            mutationGuard: Self.designFreezeGate(registry: DesignFreezeRegistry.shared))
    }

    /// The design freeze gate. A mutation is rejected when its canonical
    /// target path — or the live (device, inode) identity of that target —
    /// is frozen by a design task, when the target is an EXISTING file
    /// inside a frozen webroot, or when the target is an ANCESTOR directory
    /// of a frozen original (deleting/renaming the parent would move the
    /// original to a path and inode the registry can no longer guard).
    /// New files at unprotected paths (including new staging paths inside a
    /// frozen webroot), reads, and trusted manual edits (which never pass
    /// through the agent tool services) are untouched.
    public static func designFreezeGate(
        registry: DesignFreezeRegistry = .shared
    ) -> (@Sendable (URL) throws -> Void) {
        { url in
            guard let protection = registry.protection(for: url)
                ?? registry.protection(ancestorOf: url) else {
                return
            }
            throw DesignFreezeError.sourceFrozen(
                path: url.lastPathComponent,
                conversationID: protection.conversationID,
                reason: "Stage the change as a design candidate (design.propose) and let the user adopt it, or ask the user to reject/cancel the pending design change first."
            )
        }
    }

    public func rootURL(context: ToolContext) throws -> URL {
        guard let root = context.workspaceRootURL ?? rootProvider() else {
            throw WorkspaceToolError.notFound("workspace (no workspace is currently open)")
        }
        return root
    }

    public func networkRoute(
        path: String,
        context: ToolContext
    ) async throws -> NetworkWorkspaceMountRegistry.Route? {
        try await NetworkWorkspaceMountRegistry.shared.route(
            rootURL: rootURL(context: context),
            virtualPath: path
        )
    }

    public func networkMounts(context: ToolContext) async throws -> [NetworkWorkspaceMount] {
        await NetworkWorkspaceMountRegistry.shared.mounts(rootURL: try rootURL(context: context))
    }

    /// Direct UI/test access retains the legacy environment-root behavior.
    /// Agent executions use the context-bearing overload above.
    public func makeService() throws -> WorkspaceFileService {
        guard let root = rootProvider() else {
            throw WorkspaceToolError.notFound("workspace (no workspace is currently open)")
        }
        return WorkspaceFileService(guard: WorkspacePathGuard(
            rootURL: root,
            maxReadBytes: maxReadBytes,
            maxWriteBytes: maxWriteBytes,
            mounts: WorkspaceMountRegistry.shared.mounts(for: root)
        ))
    }
}

enum WorkspaceToolSupport {
    /// P1: workspace tools operate on the local workspace only.
    static func rejectHostScope(_ scope: ToolScope) throws {
        switch scope {
        case .local:
            return
        case .host(let id):
            throw WorkspaceToolError.unsupportedScope("host(\(id.uuidString))")
        case .hostPath(let hostID, let path):
            throw WorkspaceToolError.unsupportedScope("hostPath(\(hostID.uuidString), \(path))")
        }
    }

    static func output(
        _ summary: String,
        artifacts: [ToolArtifactReference] = []
    ) -> ToolExecutionOutput {
        ToolExecutionOutput(
            summary: summary,
            fullOutputSHA256: WorkspaceFileService.sha256Hex(of: Data(summary.utf8)),
            artifacts: artifacts
        )
    }

    /// Persists a bounded, digest-addressed unified diff in Floe's own
    /// Application Support directory. The workspace itself is never used as
    /// an evidence store, so reviewing a change cannot modify user files.
    static func changeArtifact(diff: String, runID: UUID) throws -> ToolArtifactReference? {
        guard !diff.isEmpty else { return nil }
        let data = Data(diff.utf8)
        guard data.count <= 512 * 1024 else { return nil }
        let digest = WorkspaceFileService.sha256Hex(of: data)
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let relativeDirectory = "ChangeArtifacts/\(runID.uuidString)"
        let directory = support
            .appendingPathComponent("FloeAgent", isDirectory: true)
            .appendingPathComponent(relativeDirectory, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let name = "\(digest).diff"
        let url = directory.appendingPathComponent(name, isDirectory: false)
        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: [.atomic])
        }
        return ToolArtifactReference(
            id: UUID(),
            relativePath: "\(relativeDirectory)/\(name)",
            mimeType: "text/x-diff",
            byteCount: data.count,
            sha256: digest
        )
    }
}
