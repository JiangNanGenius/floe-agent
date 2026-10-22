// FloeCore — Conversation-local chat reasoning preference.
//
// SPDX-License-Identifier: MPL-2.0
//
// Fast chat is a product setting of ONE conversation, never a global model
// decision. `ChatReasoningPreference` is persisted per conversation (an
// absent record decodes as `.fast`); resolution happens per run against the
// selected provider/model and is frozen for that run and its continuations.
// The global `ModelProfile.reasoningEffort` is never written through this
// path, and task modes (.agent/.plan/.goal) never read it.

import Foundation

/// One conversation's chat reasoning preference. `.fast` is the product
/// default: the shortest documented reasoning setting the endpoint actually
/// supports (disabled where documented, otherwise the lowest supported known
/// effort, otherwise no reasoning fields at all). The explicit levels let a
/// conversation deliberately use more thinking than the model default
/// without touching the model profile globally.
public enum ChatReasoningPreference: String, Sendable, Codable, CaseIterable, Hashable, Identifiable {
    case fast
    case low
    case medium
    case high
    case maximum

    public var id: String { rawValue }

    /// Fresh conversations and legacy rows without a saved value resolve to
    /// `.fast`. Chat only — no other surface reads this default.
    public static let defaultValue: ChatReasoningPreference = .fast

    /// The explicit level for the run's model copy. `.fast` returns nil: its
    /// concrete wire tier is decided by the provider/model resolution, not a
    /// fixed level, and the decision record keeps the resolved tier.
    public var modelEffortOverride: ModelReasoningEffort? {
        switch self {
        case .fast: return nil
        case .low: return .low
        case .medium: return .medium
        case .high: return .high
        case .maximum: return .maximum
        }
    }
}

/// The durable per-conversation chat snapshot. Every field is optional so a
/// missing row or a missing key decodes to the product default (`.fast`)
/// without any migration backfill; nothing here is model-global state.
public struct ChatConversationPreferences: Sendable, Codable, Hashable {
    public var chatReasoning: ChatReasoningPreference?

    /// The composer execution mode the user last chose for THIS conversation,
    /// stored as the stable raw value of the App's `AgentExecutionMode`
    /// ("agent" / "chat" / "plan" / "goal"). FloeCore deliberately owns no
    /// App type: it only carries the string, while the App validates it.
    ///
    /// Semantics every reader must honor:
    /// - `nil` (legacy row / never chosen) = no explicit choice was saved;
    ///   such conversations keep the historical Agent default.
    /// - A recognized raw value is an explicit user choice and must be
    ///   restored, never replaced by a background path.
    /// - A present but unrecognized value is NOT legacy data: it must fail
    ///   closed to the least-privilege chat ceiling (with one actionable
    ///   notice), never silently fall back to Agent authority.
    ///
    /// A snapshot write from a writer that intentionally changes another
    /// field must merge atomically (`ChatPreferenceStore` field updates) so
    /// this value and `chatReasoning` can never erase each other.
    public var preferredExecutionMode: String?

    public init(
        chatReasoning: ChatReasoningPreference? = nil,
        preferredExecutionMode: String? = nil
    ) {
        self.chatReasoning = chatReasoning
        self.preferredExecutionMode = preferredExecutionMode
    }

    public var effectiveChatReasoning: ChatReasoningPreference {
        chatReasoning ?? .defaultValue
    }
}

/// The frozen reasoning outcome for ONE run. Threaded through a durable
/// `.status` run event (payload key `chatReasoning`) exactly like the
/// automatic-effort decision: resume/retry/recovery reuse it, and a
/// preference or model switch only affects the NEXT run. `level == nil` with
/// `appliesDisabledPolicy == false` means "omit every reasoning field"
/// (unknown endpoints under `.fast`), which is the wire truth, not a tier
/// claim.
public struct ChatReasoningDecision: Sendable, Codable, Equatable {
    /// Durable `.status` event payload key. The payload carries no user text
    /// and no secrets.
    public static let payloadKey = "chatReasoning"

    /// The conversation-local preference captured when the run started.
    public var preference: ChatReasoningPreference
    /// True when `.fast` resolved to the endpoint's documented disable knob.
    public var appliesDisabledPolicy: Bool
    /// The effort tier the run's model copy actually carries (nil = send no
    /// effort tier). For a disabled-policy run this is always nil.
    public var level: ModelReasoningEffort?
    /// The user's explicit level BEFORE any wire clamp (nil for `.fast`), so
    /// a same-round target re-selection re-resolves the abstract choice
    /// instead of inheriting the previous target's downgrade.
    public var abstractLevel: ModelReasoningEffort?
    public var targetProviderID: UUID
    public var targetModelID: UUID
    public var targetRemoteModelID: String

    public init(
        preference: ChatReasoningPreference,
        appliesDisabledPolicy: Bool,
        level: ModelReasoningEffort?,
        abstractLevel: ModelReasoningEffort?,
        targetProviderID: UUID,
        targetModelID: UUID,
        targetRemoteModelID: String
    ) {
        self.preference = preference
        self.appliesDisabledPolicy = appliesDisabledPolicy
        self.level = level
        self.abstractLevel = abstractLevel
        self.targetProviderID = targetProviderID
        self.targetModelID = targetModelID
        self.targetRemoteModelID = targetRemoteModelID
    }

    public func matches(provider: ProviderProfile, model: ModelProfile) -> Bool {
        provider.id == targetProviderID
            && model.id == targetModelID
            && model.remoteModelID == targetRemoteModelID
    }

    /// The run's model profile with the frozen tier applied. This copy only
    /// ever reaches the launched run; the stored model profile is untouched.
    public func applied(to model: ModelProfile) -> ModelProfile {
        var resolved = model
        resolved.reasoningEffort = level
        return resolved
    }

    public func payloadJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(DecisionPayload(chatReasoning: self)),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// Decodes one `.status` payload's chat reasoning record, if present.
    public static func decision(fromEventPayloadJSON json: String) -> ChatReasoningDecision? {
        let decoder = JSONDecoder()
        guard let data = json.data(using: .utf8),
              let payload = try? decoder.decode(DecisionPayload.self, from: data) else {
            return nil
        }
        return payload.chatReasoning
    }

    private struct DecisionPayload: Codable {
        var chatReasoning: ChatReasoningDecision
    }
}
