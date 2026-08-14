// FloeApp — Locked information architecture destinations.
//
// SPDX-License-Identifier: MPL-2.0
//
// iPhone shows exactly five tabs (home, chat, files, hosts, more); iPad
// surfaces the same destinations in the sidebar plus the More
// sub-destinations as first-class sections. Titles resolve through the
// string catalog — views never hard-code user-facing text.

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

/// Top-level destinations shared by both idioms. The case order is the
/// locked tab order; do not reorder or add cases without a product decision.
enum AppDestination: String, Hashable, CaseIterable, Identifiable, Sendable {
    case home, chat, files, hosts, more

    var id: String { rawValue }

    /// Localized title key in `Localizable.xcstrings`.
    var title: LocalizedStringKey {
        switch self {
        case .home: "tab.home"
        case .chat: "tab.chat"
        case .files: "tab.files"
        case .hosts: "tab.hosts"
        case .more: "tab.more"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .chat: "bubble.left.and.bubble.right"
        case .files: "folder"
        case .hosts: "server.rack"
        case .more: "ellipsis.circle"
        }
    }
}

/// Sub-destinations reachable from the More tab on iPhone, and promoted to
/// sidebar sections on iPad. Order is the locked display order.
enum MoreDestination: String, Hashable, CaseIterable, Identifiable, Sendable {
    case runs, setupGuide, providers, auxiliaryModels, settings, privacy, diagnostics

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .runs: "more.runs"
        case .setupGuide: "more.setup_guide"
        case .providers: "more.providers"
        case .auxiliaryModels: "more.auxiliary_models"
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
        case .settings: "gearshape"
        case .privacy: "hand.raised"
        case .diagnostics: "stethoscope"
        }
    }

    /// Whether this destination is available outside DEBUG builds.
    /// Diagnostics is an internal screen and ships only in DEBUG.
    var isReleaseVisible: Bool {
        switch self {
        case .diagnostics: false
        default: true
        }
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
    case primary(AppDestination)
    case more(MoreDestination)
}
#endif
