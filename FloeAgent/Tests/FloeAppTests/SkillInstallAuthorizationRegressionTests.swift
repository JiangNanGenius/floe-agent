// FloeAppTests — task-path Skill install authorization regressions
// (build-303 deadlock repair, App side).
//
// The module-level decision matrix, exact-delta copy and same-call resume
// contract live in FloeSkillsTests/SkillInstallAuthorizationTests.swift; the
// runtime waiting/liveness/cancel lifecycle proofs live in
// FloeAgentRuntimeTests/SkillInstallApprovalContinuationTests.swift. This
// suite pins the App wiring that neither module can see:
// - `SkillsCenter.installHubSkill` refuses a temporary chat and an
//   unapproved call BEFORE any network or staging work;
// - a persisted decline for this exact owner/run/package is terminal and
//   cannot re-prompt;
// - an open GLOBAL Skill Hub review sheet is a retryable busy conflict for a
//   task install — never a park and never a second sheet;
// - the task-path decision and the human Get consent gate agree on every
//   overlapping fact (fresh install proceeds; adds-scope update asks once);
// - the nested card copy is present in both languages and names no internal
//   flow vocabulary.
// No test here touches the network, a real catalog, or user installs.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Testing
import SwiftUI
import UIKit
import FloeCore
import FloeModels
import FloePersistence
import FloeSkills
import FloeTools
@testable import FloeApp

@Suite("FloeApp.SkillInstallAuthorization")
@MainActor
struct SkillInstallAuthorizationRegressionTests {

    private func liveCenter() async throws -> (SkillsCenter, AppEnvironment) {
        let environment = AppEnvironment.preview()
        try await environment.database.migrate()
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("skill-auth-\(UUID())")
        return (SkillsCenter(environment: environment, installationRoot: root), environment)
    }

    private func context(ownerID: UUID = UUID(), runID: UUID = UUID(),
                         approved: Bool = true, temporary: Bool = false,
                         origin: ToolApprovalOrigin? = .humanCard,
                         nested: Bool = true) -> ToolContext {
        ToolContext(
            runID: runID,
            toolCallID: "call-app-1",
            approvalGrantID: approved ? UUID() : nil,
            cancellation: CancellationToken(),
            conversationID: ownerID,
            temporaryReadOnly: temporary,
            approvalOrigin: origin,
            nestedApproval: nested
                ? RuntimeNestedApprovalHandle { _ in .denied(reason: "must not be asked in this test") }
                : nil
        )
    }

    private func request(_ id: String = "fixture-skill") throws -> SkillHubInstallRequest {
        try SkillHubInstallRequest(id: id)
    }

    @Test("A temporary chat install is refused before any network or staging work")
    func temporaryChatRefused() async throws {
        let (center, _) = try await liveCenter()
        await #expect(throws: SkillHubInstallError.userChoiceBlocked) {
            _ = try await center.installHubSkill(request(), context: self.context(temporary: true))
        }
        // Nothing parked anywhere: the task path owns no global sheet.
        #expect(center.pendingInstallation == nil)
    }

    @Test("An unapproved call is refused before any network or staging work")
    func missingGrantRefused() async throws {
        let (center, _) = try await liveCenter()
        await #expect(throws: SkillHubInstallError.userChoiceBlocked) {
            _ = try await center.installHubSkill(request(), context: self.context(approved: false))
        }
        #expect(center.pendingInstallation == nil)
    }

    @Test("A persisted decline for this owner/run/package is terminal and cannot re-prompt")
    func persistedDeclineIsTerminal() async throws {
        let (center, environment) = try await liveCenter()
        let ownerID = UUID()
        let runID = UUID()
        let skillID = "fixture-skill"
        let choiceKey = "skills.hub.reviewChoice.\(ownerID.uuidString).\(runID.uuidString).\(skillID)"
        try await SQLiteSettingsStore(database: environment.database)
            .setValue("false", forKey: choiceKey)
        await #expect(throws: SkillHubInstallError.reviewDeclined) {
            _ = try await center.installHubSkill(
                self.request(skillID),
                context: self.context(ownerID: ownerID, runID: runID))
        }
        #expect(center.pendingInstallation == nil)
    }

    @Test("An open global review sheet makes a task install retryably busy — never a second park")
    func globalSheetIsBusyConflict() async throws {
        let (center, _) = try await liveCenter()
        center.pendingInstallation = SkillsCenter.PendingInstallation(
            sourceURL: URL(string: "https://example.com/fixture")!,
            skillMarkdown: "# fixture",
            manifest: SkillManifest(id: "sheet-fixture", version: "1.0.0"),
            files: [:],
            capabilityNames: [],
            toolNames: [],
            containsScripts: false,
            sourceDigest: String(repeating: "a", count: 64),
            rewriteModelID: nil
        )
        // The global sheet belongs to the Skill Hub UI flow; a task install
        // must fail honestly as a retryable conflict instead of parking or
        // stacking a second review surface.
        await #expect(throws: SkillUpgradeError.localConflict) {
            _ = try await center.installHubSkill(request(), context: self.context())
        }
        // The user's open sheet is untouched by the refused task install.
        #expect(center.pendingInstallation != nil)
        center.pendingInstallation = nil
    }

    @Test("Task-path decision and the human Get consent gate agree on every overlapping fact")
    func taskAndGetConsentStayAligned() {
        // Fresh audited entry: Get installs directly (tap = consent to the
        // declared ceiling); the task path proceeds under the call's
        // authorization. Neither parks a review.
        let getFresh = SkillHubConsentDecision.decide(
            existingRow: false, permissionDeltaRequiresApproval: true,
            missingCapabilities: ["data.transform"], missingTools: [], missingPackages: [])
        let taskFresh = SkillHubTaskInstallPolicy.decide(SkillHubTaskInstallFacts(
            temporaryReadOnly: false, hasApprovalGrant: true, persistedDecline: false,
            explicitUserChoiceBlocked: false, existingRow: false, deltaRequiresApproval: true,
            addedCapabilities: ["data.transform"], addedTools: [], addedPythonPackageSpecs: []))
        #expect(getFresh == .directFreshInstall)
        #expect(taskFresh == .proceedUnderCallAuthorization)

        // Covered update: both proceed with no prompt.
        let getCovered = SkillHubConsentDecision.decide(
            existingRow: true, permissionDeltaRequiresApproval: false,
            missingCapabilities: [], missingTools: [], missingPackages: [])
        let taskCovered = SkillHubTaskInstallPolicy.decide(SkillHubTaskInstallFacts(
            temporaryReadOnly: false, hasApprovalGrant: true, persistedDecline: false,
            explicitUserChoiceBlocked: false, existingRow: true, deltaRequiresApproval: false,
            addedCapabilities: [], addedTools: [], addedPythonPackageSpecs: []))
        #expect(getCovered == .directUpdate)
        #expect(taskCovered == .proceedUnderCallAuthorization)

        // Adds-scope update: Get parks at its focused in-panel confirmation;
        // the task path asks ONCE inline under a human card grant — and
        // proceeds silently under standing-policy authority, which the Get
        // panel does not model (its tap is always human).
        let getAdds = SkillHubConsentDecision.decide(
            existingRow: true, permissionDeltaRequiresApproval: true,
            missingCapabilities: ["network.read"], missingTools: ["web.fetch"], missingPackages: [])
        let taskAddsHuman = SkillHubTaskInstallPolicy.decide(SkillHubTaskInstallFacts(
            temporaryReadOnly: false, hasApprovalGrant: true, persistedDecline: false,
            explicitUserChoiceBlocked: false, existingRow: true, deltaRequiresApproval: true,
            addedCapabilities: ["network.read"], addedTools: ["web.fetch"],
            addedPythonPackageSpecs: [],
            humanScopedApproval: true, inlineApprovalSurfaceAvailable: true))
        let taskAddsPolicy = SkillHubTaskInstallPolicy.decide(SkillHubTaskInstallFacts(
            temporaryReadOnly: false, hasApprovalGrant: true, persistedDecline: false,
            explicitUserChoiceBlocked: false, existingRow: true, deltaRequiresApproval: true,
            addedCapabilities: ["network.read"], addedTools: ["web.fetch"],
            addedPythonPackageSpecs: [],
            humanScopedApproval: false, inlineApprovalSurfaceAvailable: false))
        #expect(getAdds == .requiresScopeApproval(addedCapabilities: ["network.read"],
                                                  addedTools: ["web.fetch"],
                                                  addedPackages: []))
        #expect(taskAddsHuman == .requestInlineDeltaApproval(addedCapabilities: ["network.read"],
                                                             addedTools: ["web.fetch"],
                                                             addedPythonPackageSpecs: []))
        #expect(taskAddsPolicy == .proceedUnderCallAuthorization)
    }

    @Test("The nested card copy is bilingual, concise and free of internal flow vocabulary")
    func deltaCopyStaysProductLevel() {
        let reason = SkillHubCopy.deltaApprovalReason
        #expect(!reason.isEmpty)
        #expect(reason != "skills.hub.delta.reason", "the copy must resolve, not leak the raw key")
        #expect(reason.count <= 160)
        for banned in ["pending", "reviewRequired", "PendingInstallation", "grant", "bridge"] {
            #expect(!reason.lowercased().contains(banned.lowercased()),
                    "product copy must not expose internal flow vocabulary (\(banned))")
        }
    }
}
#endif
