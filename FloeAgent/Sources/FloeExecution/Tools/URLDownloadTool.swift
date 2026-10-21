// FloeExecution — network.download agent tool.
//
// Saves a bounded public HTTPS (or explicitly enabled LAN) GET response
// directly into the task workspace. The file never exists partially: the
// service downloads to a sandbox temporary file first, enforces the byte
// cap, and only then moves it beside the user's files.

import Foundation
import Crypto
import FloeCore
import FloeModels
import FloeTools
import FloeWorkspace

/// Downloads a URL straight into the workspace without routing the payload
/// through the model context.
public struct URLDownloadTool: AgentTool {
    public struct Arguments: Decodable, Sendable {
        public var url: String
        public var destination: String
        public var maxBytes: Int?
        public var timeout: Double?
        public var localNetwork: Bool?
        /// Explicit consent to replace an existing destination, asked for
        /// after the user confirms.
        public var overwrite: Bool?

        public init(
            url: String,
            destination: String,
            maxBytes: Int? = nil,
            timeout: Double? = nil,
            localNetwork: Bool? = nil,
            overwrite: Bool? = nil
        ) {
            self.url = url
            self.destination = destination
            self.maxBytes = maxBytes
            self.timeout = timeout
            self.localNetwork = localNetwork
            self.overwrite = overwrite
        }
    }

    public static let name = "network.download"
    public static let toolDescription =
        "Download a URL directly into the task workspace as a file (GET only). Public endpoints require HTTPS; set localNetwork only for a user-requested LAN target. The download is size-capped (default 32 MB, max 64 MB) and every redirect is revalidated. An existing destination is never overwritten unless the user explicitly confirms and overwrite=true is passed. Prefer this over network.http when the content belongs in a file rather than in the conversation."
    public static let parametersJSON = #"""
    {
      "type": "object",
      "properties": {
        "url": {"type": "string", "description": "HTTPS URL or local HTTP diagnostic endpoint to download"},
        "destination": {"type": "string", "description": "Workspace-relative output path; must not already exist unless overwrite is confirmed"},
        "maxBytes": {"type": "integer", "description": "Download cap in bytes (default 33554432, max 67108864)"},
        "timeout": {"type": "number", "description": "Timeout in seconds (default 60, max 120)"},
        "localNetwork": {"type": "boolean", "description": "Enable only for a local-network target requested by the user"},
        "overwrite": {"type": "boolean", "description": "Set true only after the user confirms replacing an existing destination file"}
      },
      "required": ["url", "destination"],
      "additionalProperties": false
    }
    """#
    public static let riskLabels: Set<RiskLabel> = [.networkAccess, .writesFiles]
    public static let isSideEffecting = true
    public static let toolEffect: ToolEffect = .mutating

    static let defaultMaxBytes = 32 * 1_024 * 1_024
    static let defaultTimeout: TimeInterval = 60

    private let service: HTTPRequestService

    public init(service: HTTPRequestService = HTTPRequestService()) {
        self.service = service
    }

    public func validate(_ args: Arguments) throws {
        guard let url = URL(string: args.url), !args.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("url must be a valid http/https URL")
        }
        do {
            if args.localNetwork == true { try DiagnosticNetworkTargetPolicy.validate(url) }
            else { try PublicNetworkTargetPolicy.validate(url) }
        } catch {
            throw FloeError.validationFailed(error.localizedDescription)
        }
        let destination = args.destination.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !destination.isEmpty, !destination.hasPrefix("/"), !destination.hasPrefix("~"),
              !destination.split(separator: "/").contains("..") else {
            throw FloeError.validationFailed("destination must be a workspace-relative path")
        }
        if let maxBytes = args.maxBytes, maxBytes <= 0 {
            throw FloeError.validationFailed("maxBytes must be > 0")
        }
        if let timeout = args.timeout, timeout <= 0 {
            throw FloeError.validationFailed("timeout must be > 0")
        }
    }

    public func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        try context.cancellation.throwIfCancelled()
        guard let url = URL(string: args.url) else {
            return Self.output("status=error error=\(HTTPRequestError.invalidURL(args.url).localizedDescription)", exitStatus: 2)
        }
        guard let root = context.workspaceRootURL else {
            return Self.output("status=error error=No task workspace is available", exitStatus: 2)
        }
        do {
            try context.authorizeWorkspacePath(args.destination)
            let guarder = WorkspacePathGuard(rootURL: root)
            let destination = try guarder.resolve(args.destination)
            // Design original-write barrier: this downloader writes through
            // its own atomic committer (NOT WorkspaceFileService), so the
            // registry is consulted here. A NEW destination path stays open;
            // a destination that IS a frozen original (or whose ancestor
            // directory holds one and would be replaced) is refused BEFORE
            // any byte is fetched.
            let registry = DesignGuestWriteGateTesting.registry
            if let protection = registry.protection(for: destination)
                ?? registry.protection(ancestorOf: destination) {
                let denial = DesignGuestWriteGate.Denial(
                    canonicalPath: protection.canonicalPath,
                    conversationID: protection.conversationID)
                return Self.output(denial.message, exitStatus: 126)
            }
            let staging = destination.deletingLastPathComponent()
                .appendingPathComponent(".floe-download-\(UUID().uuidString)")
            defer { try? FileManager.default.removeItem(at: staging) }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let transport = args.localNetwork == true ? HTTPRequestService(allowsPrivateNetwork: true) : service
            let result = try await transport.download(
                url: url,
                timeout: args.timeout ?? Self.defaultTimeout,
                maxBytes: args.maxBytes ?? Self.defaultMaxBytes,
                to: staging
            )
            let receipt = try AtomicFileCommitter.commit(
                stagedFile: staging,
                to: destination,
                policy: FileCommitPolicy(
                    conflict: args.overwrite == true ? .replaceAtomically(consent: true) : .failIfExists,
                    maxBytes: args.maxBytes ?? Self.defaultMaxBytes,
                    checkCancellation: { try context.cancellation.throwIfCancelled() }
                )
            )
            let summary =
                "status=ok path=\(args.destination) statusCode=\(result.statusCode) contentType=\(result.contentType) bytes=\(result.byteCount) sha256=\(receipt.sha256)"
            // S3-D: publish the committed bytes as this run's stable snapshot
            // receipt using the real commit identity. A bound run whose
            // publication fails returns an observable failed result while the
            // downloaded original stays on disk; only genuine legacy direct
            // contexts and temporary runs keep the old summary untouched.
            let publication = try Self.publishRunOutput(
                commit: receipt,
                contentType: result.contentType,
                using: context
            )
            return ToolExecutionOutput(digesting: summary, exitStatus: 0, outputFiles: publication)
        } catch {
            return Self.output("status=error error=\(error.localizedDescription)", exitStatus: 2)
        }
    }

    private static func output(_ text: String, exitStatus: Int32) -> ToolExecutionOutput {
        return ToolExecutionOutput(digesting: text, exitStatus: exitStatus)
    }

    /// S3-D binding state at a producer commit boundary (fixed policy).
    enum RunOutputBinding: Equatable {
        /// The call carries its real provider-call and task binding: the
        /// committed bytes MUST be published; failures are observable.
        case publicationRequired
        /// Genuine legacy direct use: neither call nor task bound. Old
        /// behavior is preserved without any receipt.
        case legacyDirect
        /// Temporary (ephemeral) runs cannot own durable run outputs by
        /// design; core refuses publication for them.
        case temporaryExempt
        /// Exactly one of call/task is bound: partial provenance must fail
        /// rather than silently skip.
        case partiallyBound
    }

    static func runOutputBinding(_ context: ToolContext) -> RunOutputBinding {
        let hasCall = context.toolCallID?.isEmpty == false
        let hasTask = context.conversationID != nil
        if !hasCall && !hasTask { return .legacyDirect }
        if hasCall != hasTask { return .partiallyBound }
        if context.temporaryReadOnly { return .temporaryExempt }
        return .publicationRequired
    }

    /// Maps a typed publication failure into an observable tool error. The
    /// committed original is never touched here; only the receipt outcome
    /// changes. Labels are path-free.
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

    /// The run's stable snapshot for the committed download, from the real
    /// `AtomicFileCommitter` receipt via the core `RunOutputSnapshotStore`.
    /// Returns receipts for publication-required calls, an empty list for
    /// genuine legacy direct and temporary contexts, and THROWS an observable
    /// error for partially bound calls or failed publication — a bound run
    /// never reports success while silently losing its output metadata.
    /// Cancellation always propagates; nothing here deletes the downloaded
    /// original.
    static func publishRunOutput(
        commit receipt: FileCommitReceipt,
        contentType: String,
        using context: ToolContext
    ) throws -> [RunOutputFile] {
        switch runOutputBinding(context) {
        case .legacyDirect, .temporaryExempt:
            return []
        case .partiallyBound:
            throw FloeError.validationFailed(
                "run output publication requires both the tool-call and task binding")
        case .publicationRequired:
            do {
                let output = try RunOutputSnapshotStore.publish(
                    RunOutputSnapshotRequest(
                        producerTool: name,
                        slot: "download",
                        commit: RunOutputCommit(
                            sourceURL: receipt.url,
                            sha256: receipt.sha256,
                            byteCount: receipt.byteCount,
                            displayName: receipt.url.lastPathComponent,
                            mimeType: normalizedContentType(contentType)
                        )
                    ),
                    using: context
                )
                return [output]
            } catch let error as RunOutputSnapshotError {
                // The public seam contract is an observable FloeError (the
                // same mapping every other native producer uses); cancellation
                // (FloeError.cancelled) propagates untouched.
                throw publicationFailure(error)
            }
        }
    }

    static func normalizedContentType(_ raw: String) -> String {
        let base = raw.split(separator: ";", maxSplits: 1).first
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
        guard !base.isEmpty, base.utf8.count <= 128, base.contains("/"),
              !base.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            return "application/octet-stream"
        }
        return base
    }
}
