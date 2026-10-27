// FloeApp — Setup guide navigation state machine.
//
// SPDX-License-Identifier: MPL-2.0
//
// Pure and side-effect free so the guide's navigation rules are testable
// without a view, a service or a network: every path visits all ten sections
// in order and then the summary; Back, Next and Later are always available;
// an already-configured main model never ends the guide; progress is kept
// separately from provider readiness, so the guide can be left and resumed
// even before any provider works.

import Foundation

/// Stable product groups, shared by navigation and resumable progress.
enum SetupGuideSection: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case chatModels, creation, webSearch, voice, files, personalization
    case permissions, background, syncStorage, skills, summary

    var id: String { rawValue }
    static var configurable: [Self] { allCases.filter { $0 != .summary } }
    var titleKey: String { "setup.section.\(rawValue)" }
    var detailKey: String { "setup.section.\(rawValue).detail" }
    var systemImage: String {
        switch self {
        case .chatModels: "bubble.left.and.bubble.right"
        case .creation: "photo.on.rectangle"
        case .webSearch: "globe"
        case .voice: "waveform"
        case .files: "folder"
        case .personalization: "person.crop.circle"
        case .permissions: "hand.raised"
        case .background: "arrow.triangle.2.circlepath"
        case .syncStorage: "icloud"
        case .skills: "puzzlepiece.extension"
        case .summary: "checkmark.circle"
        }
    }
    var next: Self? {
        guard let index = Self.allCases.firstIndex(of: self), index + 1 < Self.allCases.count else { return nil }
        return Self.allCases[index + 1]
    }
    var previous: Self? {
        guard let index = Self.allCases.firstIndex(of: self), index > 0 else { return nil }
        return Self.allCases[index - 1]
    }
}

enum SetupSectionStatus: String, Codable, Equatable, Sendable {
    case unset, defaulted, configured, deferred, preparing, needsAttention
}

/// Navigation only. Actual settings and resource choices remain in their owners.
struct SetupGuideProgress: Codable, Equatable, Sendable {
    var preset: SetupGuidePreset?
    var currentSection: SetupGuideSection
    var statuses: [String: SetupSectionStatus] = [:]
    var visitedSections: [SetupGuideSection] = []
    var pendingVoiceModelID: String? = nil
    var updatedAt: Date = Date()

    func status(for section: SetupGuideSection) -> SetupSectionStatus {
        statuses[section.rawValue] ?? .unset
    }
}

enum SetupGuideProgressStore {
    static let storageKey = "floe.setupGuide.progress.v1"
    static func load(from defaults: UserDefaults = .standard) -> SetupGuideProgress? {
        guard let data = defaults.data(forKey: storageKey) else { return nil }
        return try? JSONDecoder().decode(SetupGuideProgress.self, from: data)
    }
    static func save(_ progress: SetupGuideProgress, to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(progress) else { return }
        defaults.set(data, forKey: storageKey)
    }
    static func clear(from defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }
}

/// One immutable guide position.
struct SetupGuideState: Equatable, Sendable {
    var section: SetupGuideSection = .chatModels
    var preset: SetupGuidePreset?
    var statuses: [SetupGuideSection: SetupSectionStatus] = [:]
    var visited: Set<SetupGuideSection> = [.chatModels]
    /// True once the user pressed Finish on the summary. Never set by a
    /// configured model, a successful test or a completed download.
    var finished = false

    func status(for section: SetupGuideSection) -> SetupSectionStatus {
        statuses[section] ?? .unset
    }

    /// Sections still without any user decision. Only used for the summary
    /// badge: the guide never blocks on them.
    var openSections: [SetupGuideSection] {
        SetupGuideSection.configurable.filter { status(for: $0) == .unset }
    }

    var preparingSections: [SetupGuideSection] {
        SetupGuideSection.configurable.filter { status(for: $0) == .preparing }
    }

    var attentionSections: [SetupGuideSection] {
        SetupGuideSection.configurable.filter { status(for: $0) == .needsAttention }
    }

    var visitedCount: Int { visited.count }
}

enum SetupGuideAction: Equatable, Sendable {
    case start(SetupGuidePreset)
    case next
    case back
    /// "Later" on the current section: keeps the shipped behaviour and moves
    /// forward. It never marks the section as configured.
    case deferCurrentSection
    case jump(SetupGuideSection)
    case setStatus(SetupGuideSection, SetupSectionStatus)
    /// A service-owned preparation transition. Navigation is never gated on
    /// it, and it can never set `.configured` on its own.
    case setPreparation(SetupGuideSection, Bool)
    case finish
    case resumeFrom(SetupGuideProgress)
}

enum SetupGuideReducer {
    static func reduce(_ state: inout SetupGuideState, _ action: SetupGuideAction) {
        // Terminal fence. Once the user finished, nothing — a late service
        // refresh, a mirrored resource stage, a navigation callback or a view
        // teardown — may reopen the guide as work in progress.
        if state.finished { return }
        switch action {
        case .start(let preset):
            // Choosing a preset only records intent and pre-fills through the
            // model layer; the position stays at the first section.
            state.preset = preset
            state.section = .chatModels
            state.visited.insert(.chatModels)

        case .next:
            guard !state.finished else { return }
            if state.section == .summary {
                // "Finish" is an explicit summary action, not a plain Next.
                return
            }
            move(from: state.section, forward: true, in: &state)

        case .back:
            move(from: state.section, forward: false, in: &state)

        case .deferCurrentSection:
            guard state.section != .summary else { return }
            // An explicit user decision is authoritative from now on: a
            // preset cannot silently re-fill a deferred section.
            if state.status(for: state.section) == .unset {
                state.statuses[state.section] = .deferred
            }
            move(from: state.section, forward: true, in: &state)

        case .jump(let section):
            state.section = section
            state.visited.insert(section)

        case .setStatus(let section, let status):
            state.statuses[section] = status

        case .setPreparation(let section, let isPreparing):
            let current = state.status(for: section)
            switch (current, isPreparing) {
            case (.preparing, true): break
            case (.unset, true), (.defaulted, true): state.statuses[section] = .preparing
            case (_, true): break
            // A finished preparation never claims "configured": only a real
            // user decision or an explicit model-layer confirmation does.
            case (.preparing, false): state.statuses[section] = .defaulted
            default: break
            }

        case .finish:
            guard state.section == .summary else { return }
            state.finished = true

        case .resumeFrom(let progress):
            state.preset = progress.preset
            state.section = progress.currentSection
            for (raw, status) in progress.statuses {
                guard let section = SetupGuideSection(rawValue: raw) else { continue }
                state.statuses[section] = status
            }
            state.visited.formUnion(progress.visitedSections)
            state.visited.insert(progress.currentSection)
        }
    }

    /// Forward/back always stay inside the ordered path and end at the
    /// summary. No section is skipped because it is unconfigured.
    private static func move(
        from section: SetupGuideSection,
        forward: Bool,
        in state: inout SetupGuideState
    ) {
        let target = forward ? section.next : section.previous
        guard let target else { return }
        state.section = target
        state.visited.insert(target)
    }

    /// Snapshot for durable resume. Only navigation facts and section status
    /// keys are written; no model name, endpoint, credential or file path.
    static func progress(from state: SetupGuideState) -> SetupGuideProgress {
        SetupGuideProgress(
            preset: state.preset,
            currentSection: state.section,
            statuses: Dictionary(uniqueKeysWithValues: state.statuses.map { ($0.key.rawValue, $0.value) }),
            visitedSections: SetupGuideSection.allCases.filter { state.visited.contains($0) },
            pendingVoiceModelID: nil,
            updatedAt: Date()
        )
    }
}
