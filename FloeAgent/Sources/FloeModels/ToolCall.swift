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

    public enum Status: String, Sendable, Codable, Hashable {
        case ok
        case failed
        case denied
        case expired
        case cancelled
    }

    public init(
        callID: String,
        status: Status,
        outputSummary: String,
        outputDigest: String,
        exitStatus: Int32? = nil
    ) {
        self.callID = callID
        self.status = status
        self.outputSummary = String(outputSummary.prefix(4096))
        self.outputDigest = outputDigest
        self.exitStatus = exitStatus
    }
}
