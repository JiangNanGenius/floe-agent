import Foundation
import Testing
import FloeToolboxUtilities
import FloeMacMediaSystem
@testable import FloeMacToolbox

@Suite("Scanner quit decision", .serialized)
@MainActor struct MacScannerQuitDecisionTests {
    @Test func syntheticAlertButtonsAndCloseMapToDistinctChoices() {
        #expect(MacScannerQuitDecision.choice(forButtonIndex: 0) == .review)
        #expect(MacScannerQuitDecision.choice(forButtonIndex: 1) == .discard)
        #expect(MacScannerQuitDecision.choice(forButtonIndex: 2) == .cancel)
        #expect(MacScannerQuitDecision.choice(forButtonIndex: nil) == .cancel)
    }
    @Test func readyAndPendingDoNotShowPromptOrDiscard() async {
        for (status, expected) in [(MacScannerTerminationStatus.ready, MacScannerQuitOutcome.ready),
                                   (.pending, .pending)] {
            var prompts = 0, discards = 0
            let result = await MacScannerQuitDecision.resolve(status: { status }, choose: {
                prompts += 1; return .discard
            }, discard: { discards += 1; return true })
            #expect(result == expected)
            #expect(prompts == 0)
            #expect(discards == 0)
        }
    }

    @Test func syntheticPromptRoutesEachChoiceAndNeverApprovesFailedDiscard() async {
        for (choice, expected, expectedDiscards) in [(MacScannerQuitChoice.review, MacScannerQuitOutcome.review, 0),
                                                     (.cancel, .cancelled, 0), (.discard, .ready, 1)] {
            var prompts = 0, discards = 0
            let result = await MacScannerQuitDecision.resolve(status: { .draft }, choose: {
                prompts += 1; return choice
            }, discard: { discards += 1; return true })
            #expect(result == expected)
            #expect(prompts == 1)
            #expect(discards == expectedDiscards)
        }
        let failed = await MacScannerQuitDecision.resolve(status: { .draft }, choose: { .discard }, discard: { false })
        #expect(failed == .pending)
    }

    @Test func reviewAndCancelRestoreOwnersAndKeepTheDraft() async throws {
        for choice in [MacScannerQuitChoice.review, .cancel] {
            let root = try MacToolboxTestRoot.unique("scanner-quit-fixture")
            defer { try? FileManager.default.removeItem(at: root) }
            let environment = MacToolboxMediaEnvironment()
            let services = MacToolboxServices(storageRoot: root, mediaEnvironment: environment)
            let draft = environment.scannerDraft
            let ticket = draft.appear()
            try draft.addImage(ToolboxQR.png(text: "quit fixture"), source: .imported, ticket: ticket)
            services.closeAdmissionsForTermination()
            #expect(await services.drainNonScannerForTermination())
            let outcome = await MacScannerQuitDecision.resolve(
                status: { await services.scannerTerminationStatus() }, choose: { choice },
                discard: { await services.discardScannerDraftForTermination() }
            )
            #expect(outcome == (choice == .review ? .review : .cancelled))
            services.resumeAfterCancelledTermination()
            #expect(draft.pages.count == 1)
            #expect(environment.cameraRegistry.makeCameraAdmissionTicket() != nil)
            let timer = services.silentTimekeeping()
            await timer.load()
            #expect(timer.loaded)
            services.closeAdmissionsForTermination()
            #expect(await services.scannerTerminationStatus() == .draft)
            services.resumeAfterCancelledTermination()
            services.shutdown()
        }
    }

    @Test func laterQuitFailureRevokesDiscardApproval() async throws {
        let root = try MacToolboxTestRoot.unique("scanner-quit-discard")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = MacToolboxMediaEnvironment()
        let services = MacToolboxServices(storageRoot: root, mediaEnvironment: environment)
        let draft = environment.scannerDraft
        let ticket = draft.appear()
        try draft.addImage(ToolboxQR.png(text: "quit fixture"), source: .imported, ticket: ticket)
        services.closeAdmissionsForTermination()
        let outcome = await MacScannerQuitDecision.resolve(
            status: { await services.scannerTerminationStatus() }, choose: { .discard },
            discard: { await services.discardScannerDraftForTermination() }
        )
        #expect(outcome == .ready)
        // Simulate a later camera/Bridge refusal: the real delegate resumes
        // all toolbox owners, which must revoke the one-shot discard choice.
        services.resumeAfterCancelledTermination()
        #expect(draft.pages.count == 1)
        services.closeAdmissionsForTermination()
        #expect(await services.scannerTerminationStatus() == .draft)
        services.resumeAfterCancelledTermination()
        services.shutdown()
    }
}
