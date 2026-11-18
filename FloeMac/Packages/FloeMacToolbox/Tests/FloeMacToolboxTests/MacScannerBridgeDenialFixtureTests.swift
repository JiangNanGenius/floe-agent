import Foundation
import Testing
import FloeToolboxUtilities
import FloeMacMediaSystem
@testable import FloeMacToolbox

@MainActor private final class DenyingBridgeFixture {
    private(set) var calls = 0
    func prepareToQuit() async -> Bool { calls += 1; return false }
}

@Suite("Scanner quit with bridge denial", .serialized)
@MainActor struct MacScannerBridgeDenialFixtureTests {
    @Test func bridgeDenialRestoresDraftAndRequiresNewChoice() async throws {
        let root = try MacToolboxTestRoot.unique("scanner-bridge-denial")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = MacToolboxMediaEnvironment()
        let services = MacToolboxServices(storageRoot: root, mediaEnvironment: environment)
        let draft = environment.scannerDraft
        let ticket = draft.appear()
        try draft.addImage(ToolboxQR.png(text: "fixture"), source: .imported, ticket: ticket)
        services.closeAdmissionsForTermination()
        #expect(await services.drainNonScannerForTermination())
        var promptCount = 0
        let first = await MacScannerQuitDecision.resolve(
            status: { await services.scannerTerminationStatus() },
            choose: { promptCount += 1; return .discard },
            discard: { await services.discardScannerDraftForTermination() }
        )
        #expect(first == .ready)
        let bridge = DenyingBridgeFixture()
        #expect(!(await bridge.prepareToQuit()))
        services.resumeAfterCancelledTermination()
        #expect(draft.pages.count == 1)
        services.closeAdmissionsForTermination()
        let second = await MacScannerQuitDecision.resolve(
            status: { await services.scannerTerminationStatus() },
            choose: { promptCount += 1; return .cancel },
            discard: { await services.discardScannerDraftForTermination() }
        )
        #expect(second == .cancelled)
        #expect(promptCount == 2)
        #expect(bridge.calls == 1)
        services.resumeAfterCancelledTermination()
        #expect(draft.pages.count == 1)
        services.shutdown()
    }
}
