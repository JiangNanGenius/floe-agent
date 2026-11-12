// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore

/// Maps semantic UI intent only to tokens the selected model advertises.
/// This is not model discovery or a family-name capability heuristic.
enum ReasoningEffortProjection {
    static let orderedTokens = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

    static func supported(_ options: [String]?) -> [String] {
        let declared = Set((options ?? []).prefix(32))
        return orderedTokens.filter { declared.contains($0) }
    }

    static func token(for effort: ModelReasoningEffort, options: [String]?) -> String? {
        let requested: String
        switch effort {
        case .automatic: return nil // Keep the actual server default.
        case .low: requested = "low"
        case .medium: requested = "medium"
        case .high: requested = "high"
        case .maximum: requested = "max"
        }
        let available = supported(options).filter { $0 != "none" }
        guard !available.isEmpty,
              let rank = orderedTokens.firstIndex(of: requested) else { return nil }
        if available.contains(requested) { return requested }
        // Prefer a supported lower level before moving up. Maximum always
        // selects the model's actual highest advertised level.
        return available.last { orderedTokens.firstIndex(of: $0)! <= rank } ?? available.first
    }

    static func clamped(_ effort: ModelReasoningEffort, options: [String]?) -> ModelReasoningEffort {
        guard let native = token(for: effort, options: options) else { return effort }
        let tier: ModelReasoningEffort
        switch native {
        case "minimal", "low": tier = .low
        case "medium": tier = .medium
        case "high": tier = .high
        default: tier = .maximum
        }
        // Floe has four semantic tiers; both xhigh and max can exist on the
        // same model. Do not let converting a native xhigh into 'maximum'
        // silently escalate a resumed request to max.
        return token(for: tier, options: options) == native ? tier : effort
    }
}
