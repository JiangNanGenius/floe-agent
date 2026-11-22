// SPDX-License-Identifier: MPL-2.0

import Foundation
import UniformTypeIdentifiers
import FloeCore
import FloeModels

/// The tool contract and immutable snapshot publication shared by workspace hosts.
/// Each host resolves and authorizes the source using its own workspace lease.
public enum WorkspaceOutputPublication {
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
    private static let slot = "output"

    public static func publish(sourceURL: URL, displayName: String, byteCount: Int,
                               context: ToolContext, artifactRoot: URL? = nil) throws -> ToolExecutionOutput {
        // MIME/UTI identity from the real extension (bounded; the core store
        // validates the bounded fields again).
        let detected = UTType(filenameExtension: sourceURL.pathExtension)
        let mimeType = detected?.preferredMIMEType ?? "application/octet-stream"
        let uti = detected?.identifier

        // Streamed stat+digest of the real local bytes (1 MiB chunks, never a
        // whole-file load; cancellation aborts before the core copy begins).
        let sha256 = try FloeDigest.sha256Hex(
            ofFileAt: sourceURL,
            isCancelled: { context.cancellation.isCancelled }
        )
        try context.cancellation.throwIfCancelled()

        do {
            let published = try RunOutputSnapshotStore.publish(
                RunOutputSnapshotRequest(
                    producerTool: Self.name,
                    slot: Self.slot,
                    commit: RunOutputCommit(
                        sourceURL: sourceURL,
                        sha256: sha256,
                        byteCount: byteCount,
                        displayName: displayName,
                        mimeType: mimeType,
                        uti: uti
                    )
                ),
                using: context,
                artifactRoot: artifactRoot
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
    private static func publicationFailure(_ error: RunOutputSnapshotError) -> FloeError {
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
