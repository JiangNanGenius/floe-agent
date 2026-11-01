// FloeModels — Tool call and result value types.
// See docs/DEVELOPMENT_PLAN.md §2.2, §3.2.

import Foundation
import Crypto
import FloeCore

/// What a tool call is allowed to touch. Used by the policy engine and
/// rendered to the user during approval.
public enum ToolScope: Sendable, Codable, Hashable {
    case local
    case host(UUID)
    case hostPath(hostID: UUID, path: String)
}

/// Maximum size of validated tool arguments, in bytes.
public let toolArgumentsMaxBytes = 65_536 // 64 KiB

/// Text-file mutations accept a bounded long document; all other tools retain
/// the smaller default. Underscore aliases cover compatible provider wire names.
public func toolArgumentsByteLimit(for toolName: String) -> Int {
    switch toolName {
    case "document.createMarkdown", "document_createMarkdown",
         "workspace.createFile", "workspace.writeFile", "workspace.applyPatch",
         "workspace_createFile", "workspace_writeFile", "workspace_applyPatch":
        return 1_048_576
    default: return toolArgumentsMaxBytes
    }
}

/// A model-requested invocation of a compiled, catalog-registered tool.
/// Model-provided code is never executed; only catalog entries can run.
public struct ToolCall: Sendable, Codable, Identifiable, Hashable {
    /// Stable identifier assigned by the provider (e.g. OpenAI `call_id`,
    /// Anthropic `tool_use_id`).
    public var id: String
    /// Must exist in `ToolCatalog` at execution time.
    public var toolName: String
    /// Validated JSON arguments with a tool-specific byte ceiling.
    public var argumentsJSON: Data
    public var scope: ToolScope
    /// Deduplication key: sha256(runID ‖ callID).
    public var idempotencyKey: String

    public init(id: String, toolName: String, argumentsJSON: Data, scope: ToolScope) throws {
        let maximumBytes = toolArgumentsByteLimit(for: toolName)
        guard argumentsJSON.count <= maximumBytes else {
            throw FloeError.validationFailed(
                "Tool arguments exceed \(maximumBytes) bytes"
            )
        }
        let decoded: Any
        do {
            decoded = try JSONSerialization.jsonObject(with: argumentsJSON)
        } catch {
            throw FloeError.validationFailed("Tool arguments must be valid JSON: \(error.localizedDescription)")
        }
        guard decoded is [String: Any] else {
            throw FloeError.validationFailed("Tool arguments must be a JSON object")
        }
        self.id = id
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.scope = scope
        self.idempotencyKey = ""
    }

    /// Computes the idempotency key once the run identifier is known.
    public func withIDContext(runID: UUID) -> ToolCall {
        var copy = self
        var data = Data(runID.uuidString.utf8)
        data.append(Data(id.utf8))
        copy.idempotencyKey = FloeDigest.sha256Hex(data)
        return copy
    }
}

/// Safe receipt metadata for the ONE retained copy of a result. It contains
/// only a reference and byte facts, so it can survive checkpoints without
/// carrying the (possibly multi-megabyte) body.
public struct ToolResultCaptureInfo: Sendable, Codable, Hashable {
    /// Deterministic `tr_...` identity. Present only when retention succeeded.
    public var ref: String?
    /// Full post-redaction captured length BEFORE the store's per-result cap.
    public var originalBytes: Int
    /// Bytes actually retained; this is the pageable length.
    public var retainedBytes: Int
    /// The store kept only a prefix of the captured body.
    public var retentionTruncated: Bool
    /// The tool itself reported truncating its own output.
    public var executionReportedTruncation: Bool
    /// Retention actually kept a readable record.
    public var available: Bool

    public init(
        ref: String?,
        originalBytes: Int,
        retainedBytes: Int,
        retentionTruncated: Bool,
        executionReportedTruncation: Bool,
        available: Bool
    ) {
        self.ref = available ? ref : nil
        self.originalBytes = max(0, originalBytes)
        self.retainedBytes = max(0, retainedBytes)
        self.retentionTruncated = retentionTruncated
        self.executionReportedTruncation = executionReportedTruncation
        self.available = available
    }
}

/// Terminal outcome of a tool execution. Only results in a terminal state
/// (or explicit recoverable failure) are returned to the model.
///
/// `Equatable`/`Hashable` are implemented explicitly over the durable fields
/// only. The transient capture is deliberately NOT part of result identity and
/// is excluded from Codable, so a checkpoint/UI dictionary never hashes or
/// re-encodes megabytes and a decoded result still equals its encoded source.
public struct ToolResult: Sendable, Codable, Hashable {
    /// Transient already-redacted capture. Excluded from CodingKeys.
    public var capturedOutput: String? = nil
    /// The transient capture is not the complete producer output.
    public var capturedOutputTruncated: Bool = false
    /// Safe receipt metadata for the retained copy. Codable, but excluded from
    /// result identity (it describes a side record, not the settled result).
    public var captureInfo: ToolResultCaptureInfo? = nil
    public var callID: String
    public var status: Status
    /// Ordinary results use 4096 characters; native skill reads may carry a
    /// bounded complete document so JSON/scripts survive checkpoints intact.
    public var outputSummary: String
    public let maximumSummaryCharacters: Int
    /// SHA256 hex digest of the full output. Full output lives in the audit
    /// store or is discarded per size policy; only the digest is kept here.
    public var outputDigest: String
    public var exitStatus: Int32?
    /// Bounded Floe-owned artifacts produced by this tool. The provider only
    /// receives verified image bytes when the selected model supports vision.
    public var artifacts: [ToolArtifactReference]
    /// Stable run-owned user-file outputs produced by this exact call
    /// (S3-D). Executors may propose receipts, but the runtime seals every
    /// identity field against its real run/call context before persistence;
    /// model text, quoted paths and artifact namespaces cannot grant
    /// ownership. Each path is a canonical `RunOutputs` snapshot, never a
    /// live workspace pointer, and the field is empty for ordinary tools.
    public var outputFiles: [RunOutputFile]
    /// Harness-authored provenance. Executors may return a value, but the
    /// runtime overwrites it before persistence so model/tool output cannot
    /// spoof resource identity or execution ownership.
    public var provenance: ToolResultProvenance?

    public enum Status: String, Sendable, Codable, Hashable {
        case ok
        case failed
        case denied
        case expired
        case cancelled
        case needsUser
    }

    public init(
        callID: String,
        status: Status,
        outputSummary: String,
        outputDigest: String,
        exitStatus: Int32? = nil,
        artifacts: [ToolArtifactReference] = [],
        outputFiles: [RunOutputFile] = [],
        provenance: ToolResultProvenance? = nil,
        maximumSummaryCharacters: Int = 4096,
        capturedOutput: String? = nil,
        capturedOutputTruncated: Bool = false,
        captureInfo: ToolResultCaptureInfo? = nil
    ) {
        self.callID = callID
        self.status = status
        self.maximumSummaryCharacters = min(max(0, maximumSummaryCharacters), 262_144)
        self.outputSummary = String(outputSummary.prefix(self.maximumSummaryCharacters))
        self.capturedOutput = capturedOutput
        self.captureInfo = captureInfo
        self.capturedOutputTruncated = capturedOutputTruncated
            || (capturedOutput == nil && self.outputSummary != outputSummary)
        self.outputDigest = outputDigest
        self.exitStatus = exitStatus
        self.artifacts = artifacts
        self.outputFiles = outputFiles
        self.provenance = provenance
    }

    /// Drops the transient capture fields. Durable projections (checkpoints,
    /// provider/replay history, UI state) use this so a large capture is
    /// neither encoded nor retained. Safe receipt metadata stays: it is only a
    /// small reference and byte facts.
    public func durableProjection() -> ToolResult {
        var projected = self
        projected.capturedOutput = nil
        projected.capturedOutputTruncated = false
        return projected
    }

    /// Identity covers only what a checkpoint round-trip preserves.
    public static func == (lhs: ToolResult, rhs: ToolResult) -> Bool {
        lhs.callID == rhs.callID
            && lhs.status == rhs.status
            && lhs.outputSummary == rhs.outputSummary
            && lhs.maximumSummaryCharacters == rhs.maximumSummaryCharacters
            && lhs.outputDigest == rhs.outputDigest
            && lhs.exitStatus == rhs.exitStatus
            && lhs.artifacts == rhs.artifacts
            && lhs.outputFiles == rhs.outputFiles
            && lhs.provenance == rhs.provenance
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(callID)
        hasher.combine(status)
        hasher.combine(outputSummary)
        hasher.combine(maximumSummaryCharacters)
        hasher.combine(outputDigest)
        hasher.combine(exitStatus)
        hasher.combine(artifacts)
        hasher.combine(outputFiles)
        hasher.combine(provenance)
    }

    private enum CodingKeys: String, CodingKey {
        case callID, status, outputSummary, outputDigest, exitStatus, artifacts, outputFiles, provenance, maximumSummaryCharacters, captureInfo
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        callID = try values.decode(String.self, forKey: .callID)
        status = try values.decode(Status.self, forKey: .status)
        maximumSummaryCharacters = min(max(0, try values.decodeIfPresent(Int.self, forKey: .maximumSummaryCharacters) ?? 4096), 262_144)
        outputSummary = String(try values.decode(String.self, forKey: .outputSummary).prefix(maximumSummaryCharacters))
        outputDigest = try values.decode(String.self, forKey: .outputDigest)
        exitStatus = try values.decodeIfPresent(Int32.self, forKey: .exitStatus)
        artifacts = try values.decodeIfPresent([ToolArtifactReference].self, forKey: .artifacts) ?? []
        // Legacy ToolResult JSON predates S3-D: absent field decodes to the
        // stable empty value, never to a guessed or reconstructed receipt.
        outputFiles = try values.decodeIfPresent([RunOutputFile].self, forKey: .outputFiles) ?? []
        provenance = try values.decodeIfPresent(ToolResultProvenance.self, forKey: .provenance)
        captureInfo = try values.decodeIfPresent(ToolResultCaptureInfo.self, forKey: .captureInfo)
        capturedOutput = nil
        capturedOutputTruncated = false
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(callID, forKey: .callID)
        try values.encode(status, forKey: .status)
        try values.encode(outputSummary, forKey: .outputSummary)
        if maximumSummaryCharacters != 4096 { try values.encode(maximumSummaryCharacters, forKey: .maximumSummaryCharacters) }
        try values.encode(outputDigest, forKey: .outputDigest)
        try values.encodeIfPresent(exitStatus, forKey: .exitStatus)
        if !artifacts.isEmpty { try values.encode(artifacts, forKey: .artifacts) }
        // Emit the key only when non-empty so existing stored payloads and
        // wire shapes stay byte-identical for ordinary tools.
        if !outputFiles.isEmpty { try values.encode(outputFiles, forKey: .outputFiles) }
        try values.encodeIfPresent(provenance, forKey: .provenance)
        try values.encodeIfPresent(captureInfo, forKey: .captureInfo)
    }
}

public struct ToolResourceBinding: Sendable, Codable, Hashable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = String(name.prefix(192))
        self.value = String(value.prefix(512))
    }
}

public struct ToolResultProvenance: Sendable, Codable, Hashable {
    public var sourceID: String
    public var toolName: String
    public var runID: UUID
    public var taskID: UUID?
    public var parentCallID: String?
    public var resourceBindings: [ToolResourceBinding]
    /// Declared execution backend for this tool (CapabilityBackend raw
    /// value) and the routing/fallback reason. Authored by the runtime from
    /// the capability router so tool output cannot spoof the backend.
    public var executionBackend: String?
    public var executionBackendReason: String?
    public var createdAt: Date

    public init(
        sourceID: String,
        toolName: String,
        runID: UUID,
        taskID: UUID? = nil,
        parentCallID: String? = nil,
        resourceBindings: [ToolResourceBinding] = [],
        executionBackend: String? = nil,
        executionBackendReason: String? = nil,
        createdAt: Date = Date()
    ) {
        self.sourceID = String(sourceID.prefix(128))
        self.toolName = String(toolName.prefix(256))
        self.runID = runID
        self.taskID = taskID
        self.parentCallID = parentCallID.map { String($0.prefix(256)) }
        self.resourceBindings = Array(resourceBindings.prefix(16))
        self.executionBackend = executionBackend
        self.executionBackendReason = executionBackendReason
        self.createdAt = createdAt
    }
}

/// A path-scoped, digest-addressed tool artifact. Paths are relative to
/// Floe's Application Support directory; arbitrary filesystem URLs are never
/// accepted from a tool or model.
public struct ToolArtifactReference: Sendable, Codable, Hashable, Identifiable {
    public var id: UUID
    public var relativePath: String
    public var mimeType: String
    public var byteCount: Int
    public var sha256: String

    public init(
        id: UUID, relativePath: String, mimeType: String,
        byteCount: Int, sha256: String
    ) {
        self.id = id
        self.relativePath = relativePath
        self.mimeType = mimeType
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}
