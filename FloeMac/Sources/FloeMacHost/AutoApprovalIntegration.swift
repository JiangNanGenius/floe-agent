// Floe Mac M00 — reserved integration seam for Floe-owned task auto-approval.
//
// SPDX-License-Identifier: MPL-2.0
//
// The first Mac version configures auto-approval in Floe itself, using the
// existing task scope and permission settings. It must not delegate that
// decision to OpenCode's own approval mechanism. M00 only reserves and
// reports the seam; it does not claim a working approval engine.

import Foundation

enum TaskApprovalScope: String, Codable, CaseIterable, Sendable {
    case currentTask
    case currentSession
    case workspace
}

enum TaskRiskClass: String, Codable, CaseIterable, Sendable {
    case readOnly
    case reversibleWrite
    case externalEffect
    case irreversible
}

/// The policy shape the first Mac version will persist through Floe's task
/// scope/permission services. No OpenCode approval field is part of it.
struct FloeAutoApprovalPolicy: Codable, Equatable, Sendable {
    var enabled: Bool
    var scope: TaskApprovalScope
    var allowedRiskClasses: Set<TaskRiskClass>
    var taskID: String?
    var environmentID: String?
    var expiresAt: Date?
    var updatedAt: Date
    var owner: String = "Floe"
}

enum AutoApprovalStatus: Equatable, Sendable {
    case reserved
    case connected(FloeAutoApprovalPolicy)
    case unavailable(String)

    var displayText: String {
        switch self {
        case .reserved:
            String(localized: "host.autoapproval.status.reserved")
        case .connected(let policy):
            policy.enabled
                ? String(localized: "host.autoapproval.status.enabled")
                : String(localized: "host.autoapproval.status.disabled")
        case .unavailable(let message):
            String(format: String(localized: "host.autoapproval.status.unavailable"), message)
        }
    }
}

enum AutoApprovalIntegrationError: LocalizedError {
    case notIntegrated

    var errorDescription: String? {
        String(localized: "host.autoapproval.notIntegrated")
    }
}

/// M02 will provide an implementation backed by the existing Floe task,
/// permission and audit services. Bridge mode never reads this provider:
/// Bridge keeps its own existing approval/permission lifecycle.
protocol FloeAutoApprovalProviding: Sendable {
    func status() async -> AutoApprovalStatus
    func apply(_ policy: FloeAutoApprovalPolicy) async throws
    func clear() async throws
}

struct ReservedAutoApprovalProvider: FloeAutoApprovalProviding {
    func status() async -> AutoApprovalStatus { .reserved }

    func apply(_ policy: FloeAutoApprovalPolicy) async throws {
        throw AutoApprovalIntegrationError.notIntegrated
    }

    func clear() async throws {
        throw AutoApprovalIntegrationError.notIntegrated
    }
}
