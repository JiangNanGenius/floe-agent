// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCore
import FloeTools

@MainActor
func registerHelpAgentTools(center: HelpContentCenter,
                            presentation: HelpPresentationCoordinator = .shared,
                            registry: ToolRunnerRegistry = .shared) {
    let library = HelpToolLibraryAccess(
        prepare: { await center.prepare() },
        snapshot: { language in try center.snapshot(language: language) },
        snapshotForReference: { reference in try center.snapshot(for: reference) })
    let presenter = HelpToolPresentationAccess(present: { reference, runID, conversationID, requestID in
        let receipt = await presentation.present(reference: reference,
            owner: HelpPresentationOwner(conversationID: conversationID, runID: runID, requestID: requestID))
        return .init(status: receipt.status, reference: receipt.reference, explanation: receipt.explanation)
    }, cancel: { runID, conversationID, requestID in
        presentation.cancel(owner: HelpPresentationOwner(conversationID: conversationID,
            runID: runID, requestID: requestID))
    })
    ToolCatalog.register(HelpSearchTool.self)
    ToolCatalog.register(HelpReadTool.self)
    ToolCatalog.register(HelpPresentTool.self)
    registry.register(HelpSearchTool(library: library))
    registry.register(HelpReadTool(library: library))
    registry.register(HelpPresentTool(library: library, presentation: presenter))
}
