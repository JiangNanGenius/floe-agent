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

/// A model-requested invocation of a compiled, catalog-registered tool.
/// Model-provided code is never executed; only catalog entries can run.
public struct ToolCall: Sendable, Codable, Identifiable, Hashable {
    /// Stable identifier assigned by the provider (e.g. OpenAI `call_id`,
    /// Anthropic `tool_use_id`).
    public var id: String
    /// Must exist in `ToolCatalog` at execution time.
    public var toolName: String
    /// Validated JSON arguments, size-limited to 64 KiB.
    public var argumentsJSON: Data
    public var scope: ToolScope
    /// Deduplication key: sha256(runID ‖ callID).
    public var idempotencyKey: String

    public init(id: String, toolName: String, argumentsJSON: Data, scope: ToolScope) throws {
        guard argumentsJSON.count <= toolArgumentsMaxBytes else {
            throw FloeError.validationFailed(
                "Tool arguments exceed \(toolArgumentsMaxBytes) bytes"
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
        copy.idempotencyKey = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return copy
    }
}

/// Terminal outcome of a tool execution. Only results in a terminal state
/// (or explicit recoverable failure) are returned to the model.
public struct ToolResult: Sendable, Codable, Hashable {
    public var callID: String
    public var status: Status
    /// Bounded human-readable summary, ≤ 4 KiB.
    public var outputSummary: String
    /// SHA256 hex digest of the full output. Full output lives in the audit
    /// store or is discarded per size policy; only the digest is kept here.
    public var outputDigest: String
    public var exitStatus: Int32?
    /// Bounded Floe-owned artifacts produced by this tool. The provider only
    /// receives verified image bytes when the selected model supports vision.
    public var artifacts: [ToolArtifactReference]
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
        provenance: ToolResultProvenance? = nil
    ) {
        self.callID = callID
        self.status = status
        self.outputSummary = String(outputSummary.prefix(4096))
        self.outputDigest = outputDigest
        self.exitStatus = exitStatus
        self.artifacts = artifacts
        self.provenance = provenance
    }

    private enum CodingKeys: String, CodingKey {
        case callID, status, outputSummary, outputDigest, exitStatus, artifacts, provenance
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        callID = try values.decode(String.self, forKey: .callID)
        status = try values.decode(Status.self, forKey: .status)
        outputSummary = String(try values.decode(String.self, forKey: .outputSummary).prefix(4096))
        outputDigest = try values.decode(String.self, forKey: .outputDigest)
        exitStatus = try values.decodeIfPresent(Int32.self, forKey: .exitStatus)
        artifacts = try values.decodeIfPresent([ToolArtifactReference].self, forKey: .artifacts) ?? []
        provenance = try values.decodeIfPresent(ToolResultProvenance.self, forKey: .provenance)
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(callID, forKey: .callID)
        try values.encode(status, forKey: .status)
        try values.encode(outputSummary, forKey: .outputSummary)
        try values.encode(outputDigest, forKey: .outputDigest)
        try values.encodeIfPresent(exitStatus, forKey: .exitStatus)
        if !artifacts.isEmpty { try values.encode(artifacts, forKey: .artifacts) }
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
    public var createdAt: Date

    public init(
        sourceID: String,
        toolName: String,
        runID: UUID,
        taskID: UUID? = nil,
        parentCallID: String? = nil,
        resourceBindings: [ToolResourceBinding] = [],
        createdAt: Date = Date()
    ) {
        self.sourceID = String(sourceID.prefix(128))
        self.toolName = String(toolName.prefix(256))
        self.runID = runID
        self.taskID = taskID
        self.parentCallID = parentCallID.map { String($0.prefix(256)) }
        self.resourceBindings = Array(resourceBindings.prefix(16))
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
