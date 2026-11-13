// SPDX-License-Identifier: MPL-2.0
//
// n08 optional-cleanup corrective opportunity (one-shot113). The recorded
// run proposed one compound exec.shell command whose required part was
// directory setup and whose optional part was `rm -rf` of an accidental
// literal directory. The action-review model escalated, the runtime parked
// the only continuation and the user stopped the run.
//
// These regressions pin the bounded policy contract authored with the
// repair:
//   * an unrequested destructive cleanup inside an already-escalated local
//     guest exec.shell becomes an honest NON-DISPATCHED replan denial;
//   * an explicit user request to delete/clean keeps the exact human card;
//   * a safe non-destructive setup command is never classified as cleanup;
//   * remote/native/non-shell scopes keep the existing approval path;
//   * the real shell contract (dash, POSIX arguments, exit-status checks,
//     no trailing-echo masking) is present in the model-facing surfaces.
// The helper can only refine an ALREADY-ESCALATED model-reviewed action into
// a denial; it never allows, executes or reroutes anything. Synthetic local
// fixtures only; no provider, device, shell, network or App run.
// AUTHORED, NOT EXECUTED — compilation and the unified test run stay with
// the primary coordinator.

import XCTest
import Foundation
import FloeCore
import FloeModels
import FloeSecurity
import FloeTools
@testable import FloeAgentRuntime

final class ApprovalOptionalCleanupReplanTests: XCTestCase {
    private let recordedCleanupCommand =
        "cd /workspace/demo_event && ls -la && rm -rf '{sources,images' 2>/dev/null; "
        + "mkdir -p sources images/raw images/processed poster video docs && find . -type d | sort"

    private func action(
        command: String,
        goal: String,
        environment: ApprovalEnvironmentClass = .localLinuxVM,
        scope: ToolScope = .local,
        toolName: String = "exec.shell",
        priorUserMessages: [String]? = nil
    ) throws -> ProposedAction {
        let arguments = try JSONSerialization.data(withJSONObject: ["command": command])
        let call = try ToolCall(
            id: "call-optional-cleanup",
            toolName: toolName,
            argumentsJSON: arguments,
            scope: scope
        )
        return ProposedAction(
            toolCall: call,
            riskLabels: ["deletesFiles", "executesLocalCode"],
            userGoal: goal,
            userRequests: priorUserMessages,
            hostAndPathScope: scope,
            trustedContext: TrustedExecutionContext(environmentClass: environment)
        )
    }

    // MARK: - The recorded failure

    func testUnexecutedUnrequestedCleanupBecomesReplanDenial() throws {
        let proposal = try action(
            command: recordedCleanupCommand,
            goal: "Prepare a Sydney event folder with sources, images, a poster, video and docs."
        )
        let reason = try XCTUnwrap(LocalGuestCleanupReplan.denialReason(for: proposal, localLinuxShellTarget: true))
        XCTAssertTrue(reason.hasPrefix(LocalGuestCleanupReplan.denialMarker))
        XCTAssertTrue(reason.contains("NOT dispatched"))
        XCTAssertTrue(reason.contains("nothing was removed"))
        XCTAssertTrue(reason.contains("Do not resend the same command"))
        XCTAssertTrue(reason.contains("/bin/sh -lc"))
        XCTAssertTrue(reason.contains("brace expansion"))
        XCTAssertTrue(reason.contains("retryable=false"))
    }

    func testSafeNonDestructiveSetupIsNotClassifiedAsCleanup() throws {
        let proposal = try action(
            command: "mkdir -p sources images/raw images/processed poster video docs",
            goal: "Prepare a Sydney event folder with sources, images, a poster, video and docs."
        )
        XCTAssertNil(LocalGuestCleanupReplan.denialReason(for: proposal, localLinuxShellTarget: true))
    }

    func testFindDeleteAndGitCleanAreRecognisedAsDestructive() throws {
        let findProposal = try action(
            command: "find . -name '*.tmp' -delete",
            goal: "Prepare the event folder."
        )
        XCTAssertNotNil(LocalGuestCleanupReplan.denialReason(for: findProposal, localLinuxShellTarget: true))
        let gitProposal = try action(
            command: "git clean -fdx && mkdir -p sources",
            goal: "Prepare the event folder."
        )
        XCTAssertNotNil(LocalGuestCleanupReplan.denialReason(for: gitProposal, localLinuxShellTarget: true))
    }

    // MARK: - Genuine authority keeps the exact human card

    func testExplicitEnglishDeletionRequestKeepsHumanApprovalPath() throws {
        let proposal = try action(
            command: "rm -rf /workspace/demo_event/old && mkdir -p sources",
            goal: "Delete the old demo_event folder, then recreate the sources and images folders."
        )
        XCTAssertNil(LocalGuestCleanupReplan.denialReason(for: proposal, localLinuxShellTarget: true))
    }

    func testExplicitChineseCleanupRequestKeepsHumanApprovalPath() throws {
        let proposal = try action(
            command: "rm -rf /workspace/demo_event/old && mkdir -p sources",
            goal: "请清理旧的临时目录，然后重新建立 sources 和 images 目录。"
        )
        XCTAssertNil(LocalGuestCleanupReplan.denialReason(for: proposal, localLinuxShellTarget: true))
    }

    func testPriorUserDeletionAuthoritySurvivesAShortContinuation() throws {
        let proposal = try action(
            command: "rm -rf old && mkdir -p sources",
            goal: "继续",
            priorUserMessages: ["Delete the old folder first, then continue with the event setup."]
        )
        XCTAssertNil(LocalGuestCleanupReplan.denialReason(for: proposal, localLinuxShellTarget: true))
    }

    func testNegatedDeletionIsNotAuthority() throws {
        let proposal = try action(
            command: "rm -rf old && mkdir -p sources",
            goal: "Do not delete anything. Just create the missing folders."
        )
        XCTAssertNotNil(LocalGuestCleanupReplan.denialReason(for: proposal, localLinuxShellTarget: true))
    }

    // MARK: - Scope fences stay authoritative

    func testRemoteAndNonShellScopesAreNotRedirected() throws {
        let host = try action(
            command: "rm -rf old",
            goal: "Prepare the event folder.",
            environment: .remote,
            scope: .host(UUID())
        )
        XCTAssertNil(LocalGuestCleanupReplan.denialReason(for: host, localLinuxShellTarget: true))
        let remoteContext = try action(
            command: "rm -rf old",
            goal: "Prepare the event folder.",
            environment: .remote
        )
        XCTAssertNil(LocalGuestCleanupReplan.denialReason(for: remoteContext, localLinuxShellTarget: true))
        let otherTool = try action(
            command: "rm -rf old",
            goal: "Prepare the event folder.",
            toolName: "shell.open"
        )
        XCTAssertNil(LocalGuestCleanupReplan.denialReason(for: otherTool, localLinuxShellTarget: true))
    }

    func testNonLocalRouteIsNotRedirected() throws {
        let native = try action(
            command: "rm -rf old",
            goal: "Prepare the event folder.",
            environment: .localNative
        )
        XCTAssertNil(LocalGuestCleanupReplan.denialReason(for: native, localLinuxShellTarget: false))
        let unknown = try action(
            command: "rm -rf old",
            goal: "Prepare the event folder.",
            environment: .unknown
        )
        XCTAssertNil(LocalGuestCleanupReplan.denialReason(for: unknown, localLinuxShellTarget: false))
    }

    func testLocalLinuxRouteFlagIsRequired() throws {
        let proposal = try action(
            command: recordedCleanupCommand,
            goal: "Prepare a Sydney event folder with sources, images and docs."
        )
        XCTAssertNil(
            LocalGuestCleanupReplan.denialReason(for: proposal, localLinuxShellTarget: false),
            "the corrective path must be driven by the app-resolved local Linux target, not by a caller label"
        )
    }

    func testMissingTrustedContextFailsClosedToTheExistingPath() throws {
        let arguments = try JSONSerialization.data(withJSONObject: ["command": "rm -rf old"])
        let call = try ToolCall(
            id: "call-no-context",
            toolName: "exec.shell",
            argumentsJSON: arguments,
            scope: .local
        )
        let proposal = ProposedAction(
            toolCall: call,
            riskLabels: ["deletesFiles"],
            userGoal: "Prepare the event folder.",
            hostAndPathScope: .local,
            trustedContext: nil
        )
        XCTAssertNil(LocalGuestCleanupReplan.denialReason(for: proposal, localLinuxShellTarget: true))
    }

    // MARK: - Honest POSIX shell contract

    func testToolWorkflowGuidanceStatesTheSameContract() {
        let guidance = ToolWorkflowGuidance.contextLines(for: ["exec.shell"]).joined(separator: "\n")
        XCTAssertTrue(guidance.contains("/bin/sh -lc"))
        XCTAssertTrue(guidance.contains("dash"))
        XCTAssertTrue(guidance.localizedCaseInsensitiveContains("brace expansion"))
        XCTAssertTrue(guidance.contains("trailing echo"))
        XCTAssertTrue(guidance.contains("did not ask to delete"))
    }

    func testComposedPromptCarriesTheShellAndCleanupContract() {
        let prompt = AgentPromptComposer.compose(mode: .chat, runtimeContext: "")
        XCTAssertTrue(prompt.contains("dash on Debian"))
        XCTAssertTrue(prompt.contains("trailing echo or a later unrelated success does not prove"))
        XCTAssertTrue(prompt.contains("do not delete files or directories the user did not ask to delete"))
    }
}
