// FloeExecutionTests — R3: the environment-scoped unknown-outcome reconciler
// only allows an interrupted environment.startLinux retry when authoritative
// read-only facts prove the environment is quietly stopped and the saved
// shape matches the retried request. Everything else stays suppressed.

import Foundation
import XCTest
@testable import FloeExecution

final class LinuxUnknownOutcomeReconcilerTests: XCTestCase {

    private let environmentID = "env-reconcile-1"

    private func facts(
        phase: LinuxGuestLifecyclePhase = .stopped,
        saved: LinuxGuestLifecycleConfig? = .init(vcpus: 2, memoryMB: 512),
        generation: UInt64? = nil,
        quarantined: Bool = false,
        instanceRegistered: Bool = false,
        engineRunning: Bool = false
    ) -> LinuxGuestStoppedReconciliation {
        LinuxGuestStoppedReconciliation(
            phase: phase,
            savedConfig: saved,
            launchGeneration: generation,
            quarantined: quarantined,
            instanceRegistered: instanceRegistered,
            engineRunning: engineRunning
        )
    }

    private func reconciler(
        _ facts: LinuxGuestStoppedReconciliation
    ) -> LinuxUnknownOutcomeReconciler {
        LinuxUnknownOutcomeReconciler(environmentID: environmentID) { _ in facts }
    }

    private func args(_ json: String) -> Data { Data(json.utf8) }

    func testQuietStoppedMatchingShapeAllowsStart() async {
        let decision = await reconciler(facts()).reconcile(
            reason: "interruptedDispatch",
            retryToolName: LinuxUnknownOutcomeReconciler.startToolName,
            retryArgumentsJSON: args(#"{"vcpus":2,"memoryMB":512}"#)
        )
        guard case .allowed(let explanation) = decision else {
            return XCTFail("expected .allowed, got \(decision)")
        }
        XCTAssertTrue(explanation.contains(environmentID))
        XCTAssertTrue(explanation.contains("quietly stopped"))
        XCTAssertTrue(explanation.contains("2 vCPU / 512 MiB"))
    }

    func testOmittedDimensionsPreserveSavedShapeAndAllow() async {
        let decision = await reconciler(facts()).reconcile(
            reason: "interruptedDispatch",
            retryToolName: LinuxUnknownOutcomeReconciler.startToolName,
            retryArgumentsJSON: args("{}")
        )
        guard case .allowed = decision else {
            return XCTFail("expected .allowed for a preserve-shape retry, got \(decision)")
        }
    }

    func testRunningEnvironmentStaysSuppressed() async {
        let decision = await reconciler(facts(phase: .running, instanceRegistered: true, engineRunning: true)).reconcile(
            reason: "interruptedDispatch",
            retryToolName: LinuxUnknownOutcomeReconciler.startToolName,
            retryArgumentsJSON: args(#"{"vcpus":2,"memoryMB":512}"#)
        )
        XCTAssertEqual(decision, .stillSuppressed)
    }

    func testRegisteredInstanceWithoutEngineSignalStaysSuppressed() async {
        let decision = await reconciler(facts(instanceRegistered: true)).reconcile(
            reason: "interruptedDispatch",
            retryToolName: LinuxUnknownOutcomeReconciler.startToolName,
            retryArgumentsJSON: args(#"{"vcpus":2,"memoryMB":512}"#)
        )
        XCTAssertEqual(decision, .stillSuppressed)
    }

    func testQuarantinedEnvironmentStaysSuppressed() async {
        let decision = await reconciler(facts(quarantined: true)).reconcile(
            reason: "interruptedDispatch",
            retryToolName: LinuxUnknownOutcomeReconciler.startToolName,
            retryArgumentsJSON: args(#"{"vcpus":2,"memoryMB":512}"#)
        )
        XCTAssertEqual(decision, .stillSuppressed)
    }

    func testShapeMismatchStaysSuppressed() async {
        // Saved 2 vCPU but the retried route asks for 3: not the same route's
        // effect — never auto-run.
        let decision = await reconciler(facts()).reconcile(
            reason: "interruptedDispatch",
            retryToolName: LinuxUnknownOutcomeReconciler.startToolName,
            retryArgumentsJSON: args(#"{"vcpus":3,"memoryMB":512}"#)
        )
        XCTAssertEqual(decision, .stillSuppressed)

        let memoryMismatch = await reconciler(facts()).reconcile(
            reason: "interruptedDispatch",
            retryToolName: LinuxUnknownOutcomeReconciler.startToolName,
            retryArgumentsJSON: args(#"{"vcpus":2,"memoryMB":1024}"#)
        )
        XCTAssertEqual(memoryMismatch, .stillSuppressed)
    }

    func testExplicitShapeWithoutSavedShapeStaysSuppressed() async {
        // No last-successful shape was ever recorded; an explicit request
        // cannot be proven to match the interrupted attempt.
        let noFacts = LinuxGuestStoppedReconciliation(
            phase: .stopped,
            savedConfig: nil,
            launchGeneration: nil,
            quarantined: false,
            instanceRegistered: false,
            engineRunning: false
        )
        let reconciler = LinuxUnknownOutcomeReconciler(environmentID: environmentID) { _ in noFacts }
        let decision = await reconciler.reconcile(
            reason: "interruptedDispatch",
            retryToolName: LinuxUnknownOutcomeReconciler.startToolName,
            retryArgumentsJSON: args(#"{"vcpus":2,"memoryMB":512}"#)
        )
        XCTAssertEqual(decision, .stillSuppressed)
    }

    func testNonStartToolStaysSuppressed() async {
        // Arbitrary commands and disruptive restarts are never auto-run.
        for tool in ["exec.shell", "environment.hardRestartLinux", "environment.stopLinux", "workspace.writeFile"] {
            let decision = await reconciler(facts()).reconcile(
                reason: "interruptedDispatch",
                retryToolName: tool,
                retryArgumentsJSON: args("{}")
            )
            XCTAssertEqual(decision, .stillSuppressed, "\(tool) must stay inhibited")
        }
    }

    func testMalformedArgumentsStaySuppressed() async {
        let decision = await reconciler(facts()).reconcile(
            reason: "interruptedDispatch",
            retryToolName: LinuxUnknownOutcomeReconciler.startToolName,
            retryArgumentsJSON: args("not json")
        )
        XCTAssertEqual(decision, .stillSuppressed)
    }

    func testQuietlyStoppedSemantics() {
        let quiet = facts()
        XCTAssertTrue(quiet.isQuietlyStopped)
        XCTAssertFalse(facts(phase: .running, engineRunning: true).isQuietlyStopped)
        XCTAssertFalse(facts(instanceRegistered: true).isQuietlyStopped)
        XCTAssertFalse(facts(engineRunning: true).isQuietlyStopped)
        XCTAssertFalse(facts(quarantined: true).isQuietlyStopped)
    }

    func testPoisonedChannelWordingIsHonestAboutAutoColdBoot() {
        // The quarantine wording must describe the real recovery path
        // (session torn down; NEXT command cold-starts a fresh guest) and
        // must never claim the interrupted command did or did not run.
        for message in [
            LinuxGuestCommandChannel.unresponsiveTokenMessage,
            LinuxGuestCommandChannel.silentStartupMessage
        ] {
            XCTAssertTrue(message.contains("torn down"), message)
            XCTAssertTrue(message.contains("cold-starts a fresh guest"), message)
            XCTAssertTrue(message.contains("last successful configuration"), message)
            XCTAssertTrue(message.contains("Do not assume"), message)
            XCTAssertFalse(message.contains("must be reset"), message)
        }
    }
}
