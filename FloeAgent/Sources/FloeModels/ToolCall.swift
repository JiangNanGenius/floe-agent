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

/// Per-tool application byte ceiling for validated arguments.
///
/// `exec.shell` (and its provider wire alias `exec_shell`) intentionally has
/// NO application-level command-size ceiling: real scripts routinely exceed
/// 64 KiB and the execution transport (staged script file, not argv) owns the
/// real bound. `Int.max` states that uncapped semantic explicitly instead of
/// raising the number to a new guess. The JSON-object validation in
/// `ToolCall.init` still applies, and every other tool keeps its bound.
///
/// `jobs.submit` is deliberately NOT exempted here: its own tool name is
/// stable while only the WRAPPED target may be `exec.shell`, and the job tool
/// must preserve per-target payload limits. `ToolCall.init` admits an oversized
/// wrapper only for its parsed canonical Shell target; the submission tool
/// independently checks the target payload. Other wrappers keep this limit.
///
/// Text-file mutations accept a bounded long document; underscore aliases
/// cover compatible provider wire names.
public func toolArgumentsByteLimit(for toolName: String) -> Int {
    switch toolName {
    case "exec.shell", "exec_shell":
        return Int.max
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
        let oversizedJob = ["jobs.submit", "jobs_submit"].contains(toolName)
            && argumentsJSON.count > maximumBytes
        guard argumentsJSON.count <= maximumBytes || oversizedJob else {
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
        guard let object = decoded as? [String: Any] else {
            throw FloeError.validationFailed("Tool arguments must be a JSON object")
        }
        guard !oversizedJob || Self.isShellJobEnvelope(object) else {
            throw FloeError.validationFailed("Tool arguments exceed \(maximumBytes) bytes")
        }
        self.id = id
        self.toolName = toolName
        self.argumentsJSON = argumentsJSON
        self.scope = scope
        self.idempotencyKey = ""
    }

    /// Only the Shell body can justify a larger job envelope. Keep metadata
    /// bounded and reject unknown fields rather than widening every job tool.
    private static func isShellJobEnvelope(_ object: [String: Any]) -> Bool {
        guard object["tool"] as? String == "exec.shell",
              object["arguments"] is String,
              Set(object.keys).isSubset(of: ["tool", "arguments", "purpose", "wait"]) else {
            return false
        }
        if let purpose = object["purpose"], !(purpose is NSNull) {
            guard let text = purpose as? String, text.utf8.count <= 240 else { return false }
        }
        if let wait = object["wait"], !(wait is NSNull), !(wait is Bool) { return false }
        return true
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

/// Terminal outcome of a tool execution. Only results in a terminal state
/// (or explicit recoverable failure) are returned to the model.
///
/// `Equatable`/`Hashable` are implemented explicitly over the durable fields
/// only. The transient capture (`capturedOutput`, up to the tool-layer cap)
/// is deliberately NOT part of result identity: it is excluded from Codable,
/// exists only between execution and retention, and must never make a UI
/// dictionary/set hash megabytes or make a decoded result unequal to the
/// result it was encoded from.
public struct ToolResult: Sendable, Codable, Hashable {
    /// Transient sanitized capture: deliberately excluded from CodingKeys so
    /// checkpoints retain their bounded projection rather than large outputs.
    public var capturedOutput: String? = nil
    public var capturedOutputTruncated: Bool = false
    public var callID: String
    public var status: Status
    public var outcomeUnknown: Bool
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
        outcomeUnknown: Bool = false
    ) {
        self.callID = callID
        self.status = status
        self.outcomeUnknown = outcomeUnknown
        self.maximumSummaryCharacters = min(max(0, maximumSummaryCharacters), 262_144)
        self.outputSummary = String(outputSummary.prefix(self.maximumSummaryCharacters))
        self.capturedOutput = capturedOutput
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
    /// neither encoded nor retained, and so comparisons/hashes stay bounded.
    public func durableProjection() -> ToolResult {
        var projected = self
        projected.capturedOutput = nil
        projected.capturedOutputTruncated = false
        return projected
    }

    /// Identity covers only what a checkpoint round-trip preserves. The
    /// transient capture and its truncation flag are execution-time evidence
    /// owned by the retention store, not part of the settled result.
    public static func == (lhs: ToolResult, rhs: ToolResult) -> Bool {
        lhs.callID == rhs.callID
            && lhs.status == rhs.status
            && lhs.outcomeUnknown == rhs.outcomeUnknown
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
        hasher.combine(outcomeUnknown)
        hasher.combine(outputSummary)
        hasher.combine(maximumSummaryCharacters)
        hasher.combine(outputDigest)
        hasher.combine(exitStatus)
        hasher.combine(artifacts)
        hasher.combine(outputFiles)
        hasher.combine(provenance)
    }

    private enum CodingKeys: String, CodingKey {
        case callID, status, outcomeUnknown, outputSummary, outputDigest, exitStatus, artifacts, outputFiles, provenance, maximumSummaryCharacters
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        callID = try values.decode(String.self, forKey: .callID)
        status = try values.decode(Status.self, forKey: .status)
        outcomeUnknown = try values.decodeIfPresent(Bool.self, forKey: .outcomeUnknown) ?? false
        maximumSummaryCharacters = min(max(0, try values.decodeIfPresent(Int.self, forKey: .maximumSummaryCharacters) ?? 4096), 262_144)
        outputSummary = String(try values.decode(String.self, forKey: .outputSummary).prefix(maximumSummaryCharacters))
        outputDigest = try values.decode(String.self, forKey: .outputDigest)
        exitStatus = try values.decodeIfPresent(Int32.self, forKey: .exitStatus)
        artifacts = try values.decodeIfPresent([ToolArtifactReference].self, forKey: .artifacts) ?? []
        // Legacy ToolResult JSON predates S3-D: absent field decodes to the
        // stable empty value, never to a guessed or reconstructed receipt.
        outputFiles = try values.decodeIfPresent([RunOutputFile].self, forKey: .outputFiles) ?? []
        provenance = try values.decodeIfPresent(ToolResultProvenance.self, forKey: .provenance)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(callID, forKey: .callID)
        try values.encode(status, forKey: .status)
        if outcomeUnknown { try values.encode(true, forKey: .outcomeUnknown) }
        try values.encode(outputSummary, forKey: .outputSummary)
        if maximumSummaryCharacters != 4096 { try values.encode(maximumSummaryCharacters, forKey: .maximumSummaryCharacters) }
        try values.encode(outputDigest, forKey: .outputDigest)
        try values.encodeIfPresent(exitStatus, forKey: .exitStatus)
        if !artifacts.isEmpty { try values.encode(artifacts, forKey: .artifacts) }
        // Emit the key only when non-empty so existing stored payloads and
        // wire shapes stay byte-identical for ordinary tools.
        if !outputFiles.isEmpty { try values.encode(outputFiles, forKey: .outputFiles) }
        try values.encodeIfPresent(provenance, forKey: .provenance)
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
