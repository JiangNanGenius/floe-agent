// FloeModelsTests — Task notification policy and delivery decision.
//
// These are the durable rules behind "reliable notification authorization /
// foreground / background / deep link policies": which events a policy allows,
// and what the app may actually present given real authorization state and
// whether a scene is foreground.

import Foundation
import Testing
@testable import FloeModels

@Suite("FloeModels.TaskNotificationPolicy")
struct TaskNotificationPolicyTests {

    @Test("Terminal notifications follow the policy and the outcome")
    func terminalMatrix() {
        #expect(!TaskNotificationPolicy.off.shouldNotifyTerminal(succeeded: true))
        #expect(!TaskNotificationPolicy.off.shouldNotifyTerminal(succeeded: false))
        #expect(TaskNotificationPolicy.terminal.shouldNotifyTerminal(succeeded: true))
        #expect(TaskNotificationPolicy.terminal.shouldNotifyTerminal(succeeded: false))
        #expect(TaskNotificationPolicy.stages.shouldNotifyTerminal(succeeded: true))
        #expect(TaskNotificationPolicy.stages.shouldNotifyTerminal(succeeded: false))
        // "仅关键" means failures only — a success is never a critical alert.
        #expect(!TaskNotificationPolicy.critical.shouldNotifyTerminal(succeeded: true))
        #expect(TaskNotificationPolicy.critical.shouldNotifyTerminal(succeeded: false))
    }

    @Test("Only the stages policy reports mid-run progress")
    func stageMatrix() {
        #expect(TaskNotificationPolicy.stages.shouldNotifyStages)
        #expect(!TaskNotificationPolicy.off.shouldNotifyStages)
        #expect(!TaskNotificationPolicy.terminal.shouldNotifyStages)
        #expect(!TaskNotificationPolicy.critical.shouldNotifyStages)
    }

    @Test("Approval is actionable, so critical and stages both surface it")
    func approvalMatrix() {
        #expect(!TaskNotificationPolicy.off.shouldNotifyApproval)
        #expect(!TaskNotificationPolicy.terminal.shouldNotifyApproval)
        #expect(TaskNotificationPolicy.critical.shouldNotifyApproval)
        #expect(TaskNotificationPolicy.stages.shouldNotifyApproval)
    }

    @Test("Authorization state maps to whether an alert can be presented")
    func authorizationCapability() {
        #expect(NotificationAuthorizationState.authorized.canPresentAlert)
        #expect(NotificationAuthorizationState.provisional.canPresentAlert)
        #expect(NotificationAuthorizationState.ephemeral.canPresentAlert)
        #expect(!NotificationAuthorizationState.denied.canPresentAlert)
        #expect(!NotificationAuthorizationState.notDetermined.canPresentAlert)
    }
}

@Suite("FloeModels.TaskNotificationDecision")
struct TaskNotificationDecisionTests {

    private func resolve(
        policy: TaskNotificationPolicy?,
        event: TaskNotificationEvent = .terminal,
        succeeded: Bool = true,
        authorization: NotificationAuthorizationState,
        foreground: Bool
    ) -> TaskNotificationDecision {
        TaskNotificationDecision.resolve(
            policy: policy,
            event: event,
            succeeded: succeeded,
            authorization: authorization,
            appIsForeground: foreground
        )
    }

    @Test("A disabled policy never notifies, in any state")
    func policyOffSuppressesEverything() {
        for authorization in [NotificationAuthorizationState.authorized, .denied, .notDetermined] {
            for foreground in [true, false] {
                #expect(resolve(
                    policy: .off, authorization: authorization, foreground: foreground
                ).delivery == .none)
            }
        }
    }

    @Test("Foreground uses one in-app banner instead of a system alert")
    func foregroundUsesBanner() {
        for authorization in [NotificationAuthorizationState.authorized, .denied, .notDetermined] {
            let decision = resolve(
                policy: .terminal, authorization: authorization, foreground: true
            )
            #expect(decision.delivery == .inAppBanner)
            #expect(!decision.presentSystemInForeground)
        }
    }

    @Test("Background posts through the system only when authorized")
    func backgroundNeedsAuthorization() {
        #expect(resolve(
            policy: .terminal, authorization: .authorized, foreground: false
        ).delivery == .system)
        // Provisional/quiet authorization still delivers a notification.
        #expect(resolve(
            policy: .terminal, authorization: .provisional, foreground: false
        ).delivery == .system)
        #expect(resolve(
            policy: .terminal, authorization: .ephemeral, foreground: false
        ).delivery == .system)
    }

    @Test("Denied or never-asked authorization blocks a background alert")
    func backgroundWithoutAuthorizationIsBlocked() {
        #expect(resolve(
            policy: .terminal, authorization: .denied, foreground: false
        ).delivery == .blockedByAuthorization)
        #expect(resolve(
            policy: .terminal, authorization: .notDetermined, foreground: false
        ).delivery == .blockedByAuthorization)
    }

    @Test("A critical-only policy reports failures and stays quiet on success")
    func criticalPolicyOnlyReportsFailures() {
        #expect(resolve(
            policy: .critical, succeeded: true, authorization: .authorized, foreground: false
        ).delivery == .none)
        #expect(resolve(
            policy: .critical, succeeded: false, authorization: .authorized, foreground: false
        ).delivery == .system)
    }

    @Test("A missing policy follows the documented default (stages)")
    func missingPolicyDefaultsToStages() {
        #expect(resolve(
            policy: nil, event: .terminal, authorization: .authorized, foreground: false
        ).delivery == .system)
        #expect(resolve(
            policy: nil, event: .stage, authorization: .authorized, foreground: false
        ).delivery == .system)
        #expect(resolve(
            policy: nil, event: .approval, authorization: .authorized, foreground: false
        ).delivery == .system)
    }

    @Test("Approval decisions follow the approval rule, not the terminal rule")
    func approvalUsesApprovalRule() {
        // `.terminal` policy never reports approvals; a waiting task would
        // otherwise appear to be a completed one.
        #expect(resolve(
            policy: .terminal, event: .approval, authorization: .authorized, foreground: false
        ).delivery == .none)
        #expect(resolve(
            policy: .critical, event: .approval, authorization: .authorized, foreground: false
        ).delivery == .system)
        #expect(resolve(
            policy: .stages, event: .approval, authorization: .authorized, foreground: false
        ).delivery == .system)
    }
}
