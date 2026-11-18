// Floe Mac M00 — role model for the single-app Agent/Bridge mode host.
//
// SPDX-License-Identifier: MPL-2.0

import Foundation

/// The two ways one installed Floe Mac app can run. This value is local
/// preference only: model output, file contents or remote claims must never
/// select an execution backend or permission set.
enum AppMode: String, Codable, CaseIterable, Sendable {
    case agent
    case bridge

    /// The core confirmed by the user for the next implementation stage.
    /// M00 does not start or adapt it.
    static let confirmedAgentCore = "Floe"

    var displayName: String {
        switch self {
        case .agent: String(localized: "host.role.agent")
        case .bridge: String(localized: "host.role.bridge")
        }
    }

    var shortName: String {
        switch self {
        case .agent: String(localized: "host.mode.agent")
        case .bridge: String(localized: "host.mode.bridge")
        }
    }

    var iconResourceName: String {
        switch self {
        case .agent: "FloeBrand"
        case .bridge: "FloeBridgeIcon"
        }
    }

    var modeDescription: String {
        switch self {
        case .agent: String(localized: "host.firstRun.agent.body")
        case .bridge: String(localized: "host.firstRun.bridge.body")
        }
    }
}
