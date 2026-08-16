// FloeApp — Locked information architecture destinations.
//
// SPDX-License-Identifier: MPL-2.0
//
// iPhone shows exactly five tabs (workbench, files, browser, hosts, more);
// iPad surfaces the same destinations in the sidebar plus the More
// sub-destinations as first-class sections. Titles resolve through the
// string catalog — views never hard-code user-facing text.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Top-level destinations shared by both idioms. The case order is the
/// locked tab order; do not reorder or add cases without a product decision.
enum AppDestination: String, Hashable, CaseIterable, Identifiable, Sendable {
    /// `chat` remains a compatibility route for old deep links, but the
    /// visible shell has one Workbench entry instead of separate Home/Chat.
    case home, chat, files, browser, hosts, more

    static let allCases: [AppDestination] = [.home, .files, .browser, .hosts, .more]

    var id: String { rawValue }

    /// Localized title key in `Localizable.xcstrings`.
    var title: LocalizedStringKey {
        switch self {
        case .home: "tab.workbench"
        case .chat: "tab.chat"
        case .files: "tab.files"
        case .browser: "browser.title"
        case .hosts: "tab.hosts"
        case .more: "tab.more"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "rectangle.grid.2x2"
        case .chat: "bubble.left.and.bubble.right"
        case .files: "folder"
        case .browser: "safari"
        case .hosts: "server.rack"
        case .more: "ellipsis.circle"
        }
    }
}

/// Sub-destinations reachable from the More tab on iPhone, and promoted to
/// sidebar sections on iPad. Order is the locked display order.
enum MoreDestination: String, Hashable, CaseIterable, Identifiable, Sendable {
    case runs, setupGuide, providers, auxiliaryModels, skills, memory, settings, privacy, diagnostics

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .runs: "more.runs"
        case .setupGuide: "more.setup_guide"
        case .providers: "more.providers"
        case .auxiliaryModels: "more.auxiliary_models"
        case .skills: "skills.title"
        case .memory: "memory.title"
        case .settings: "more.settings"
        case .privacy: "more.privacy"
        case .diagnostics: "more.diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .runs: "play.rectangle"
        case .setupGuide: "wand.and.stars"
        case .providers: "antenna.radiowaves.left.and.right"
        case .auxiliaryModels: "photo.badge.plus"
        case .skills: "puzzlepiece.extension"
        case .memory: "brain"
        case .settings: "gearshape"
        case .privacy: "hand.raised"
        case .diagnostics: "stethoscope"
        }
    }

    /// User-facing redacted diagnostics ships in Release so TestFlight
    /// testers can report actionable failures without attaching secrets.
    var isReleaseVisible: Bool {
        true
    }

    /// Destinations shown in the current build configuration.
    static var visibleCases: [MoreDestination] {
#if DEBUG
        MoreDestination.allCases
#else
        MoreDestination.allCases.filter(\.isReleaseVisible)
#endif
    }
}

/// Anything that can be selected in the iPad sidebar: a primary destination
/// or a More sub-destination promoted to a sidebar section.
enum SidebarSelection: Hashable, Sendable {
    case workbench(WorkbenchSelection)
    case primary(AppDestination)
    case more(MoreDestination)
}
#endif
