import Foundation
import Testing
import FloeToolboxUtilities
import FloeMacMediaSystem
@testable import FloeMacToolbox

@Suite("Mac scanner host ownership", .serialized)
@MainActor struct MacScannerHostOwnershipTests {
    @Test func quitRequiresExplicitDiscardAndCancellationRetainsDraft() async throws {
        let root = try MacToolboxTestRoot.unique("scanner-host-owner")
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = MacToolboxMediaEnvironment()
        let services = MacToolboxServices(storageRoot: root, mediaEnvironment: environment)
        let draft = environment.scannerDraft
        let ticket = draft.appear()
        try draft.addImage(ToolboxQR.png(text: "scanner fixture"), source: .imported, ticket: ticket)
        draft.disappear()
        #expect(draft.pages.count == 1)
        services.closeAdmissionsForTermination()
        #expect(!(await services.drainForTermination()))
        #expect(environment.scannerCamera.appear { true } == nil)
        #expect(draft.allowExitDiscardingDraft())
        #expect(await services.drainForTermination())
        services.resumeAfterCancelledTermination()
        #expect(draft.pages.count == 1)
        services.closeAdmissionsForTermination()
        #expect(!(await services.drainForTermination()))
        services.resumeAfterCancelledTermination()
        services.shutdown()
        let late = draft.appear()
        #expect(throws: (any Error).self) {
            try draft.addImage(ToolboxQR.png(text: "too late"), source: .imported, ticket: late)
        }
        #expect(draft.pages.count == 1)
    }
}
