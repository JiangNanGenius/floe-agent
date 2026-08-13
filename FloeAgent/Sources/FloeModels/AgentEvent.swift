// FloeModels — Normalized agent event stream.
// See docs/DEVELOPMENT_PLAN.md §2.2.

import Foundation

/// Unified event emitted by every provider adapter. The agent runtime
/// consumes only this type; wire-format specifics never leak past
/// `FloeProviders.WireTranslator`.
public enum AgentEvent: Sendable, Codable, Hashable {
    case textDelta(TextDelta)
    case reasoningSummary(ReasoningSummary)
    case toolRequest(ToolCall)
    case toolResult(ToolResult)
    case usage(UsageReport)
    case error(NormalizedError)
    case completed(CompletionInfo)

    public struct TextDelta: Sendable, Codable, Hashable {
        public var text: String
        /// Opaque block identifier for multi-block responses (Anthropic).
        public var blockID: String?
        public init(text: String, blockID: String? = nil) {
            self.text = text
            self.blockID = blockID
        }
    }

    public struct ReasoningSummary: Sendable, Codable, Hashable {
        public var text: String
        public init(text: String) { self.text = text }
    }

    public struct UsageReport: Sendable, Codable, Hashable {
        public var inputTokens: Int
        public var outputTokens: Int
        public var costEstimate: Decimal?
        public init(inputTokens: Int, outputTokens: Int, costEstimate: Decimal? = nil) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.costEstimate = costEstimate
        }
    }

    public struct NormalizedError: Sendable, Codable, Hashable {
        public var kind: Kind
        public var providerMessage: String
        public var httpStatus: Int?

        public enum Kind: String, Sendable, Codable, Hashable {
            case rateLimited
            case auth
            case contextOverflow
            case network
            case malformed
            case server
            case cancelled
        }

        public init(kind: Kind, providerMessage: String, httpStatus: Int? = nil) {
            self.kind = kind
            self.providerMessage = providerMessage
            self.httpStatus = httpStatus
        }
    }

    public struct CompletionInfo: Sendable, Codable, Hashable {
        public var stopReason: StopReason
        public init(stopReason: StopReason) { self.stopReason = stopReason }
    }

    public enum StopReason: String, Sendable, Codable, Hashable {
        case endTurn
        case toolUse
        case maxTokens
        case stopSequence
        case cancelled
    }
}
