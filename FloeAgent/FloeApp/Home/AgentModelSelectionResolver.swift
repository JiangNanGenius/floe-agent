// FloeApp — Home model-selection fallback policy.
//
// SPDX-License-Identifier: MPL-2.0
//
// A provider/model can be disabled, deleted or hidden from Settings at any
// time. When that happens the stored default agent model may point at a model
// the picker no longer offers, which used to zero out `canSend` and show
// "no model configured". This pure resolver keeps the fallback order fixed and
// testable:
//
//   1. the current selection while it is still usable,
//   2. the stored default while it is still usable,
//   3. the most recent model actually used by a run,
//   4. the first usable model offered by the picker.
//
// Selecting a replacement never touches a running request: runs hold their own
// provider/model pair; only the Home draft and the persisted default are
// repaired.

import Foundation

struct AgentModelCandidate: Equatable, Sendable {
    let id: UUID
    let isUsable: Bool

    init(id: UUID, isUsable: Bool) {
        self.id = id
        self.isUsable = isUsable
    }
}

enum AgentModelSelectionResolver {
    enum Reason: String, Equatable, Sendable {
        case selected
        case storedDefault
        case recent
        case firstUsable
        case unavailable
    }

    struct Resolution: Equatable, Sendable {
        let modelID: UUID?
        let reason: Reason
    }

    static func resolve(
        selected: UUID?,
        defaultModel: UUID?,
        recent: UUID?,
        candidates: [AgentModelCandidate]
    ) -> Resolution {
        func usable(_ id: UUID?) -> Bool {
            guard let id else { return false }
            return candidates.contains { $0.id == id && $0.isUsable }
        }
        if usable(selected) { return Resolution(modelID: selected, reason: .selected) }
        if usable(defaultModel) { return Resolution(modelID: defaultModel, reason: .storedDefault) }
        if usable(recent) { return Resolution(modelID: recent, reason: .recent) }
        if let first = candidates.first(where: \.isUsable) {
            return Resolution(modelID: first.id, reason: .firstUsable)
        }
        return Resolution(modelID: nil, reason: .unavailable)
    }
}
