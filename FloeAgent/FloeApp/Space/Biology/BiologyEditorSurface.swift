// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeBiologyUI

/// Reuses the component's workbench; no second library, navigation stack,
/// assistant model implementation, file importer, or scientific executor.
struct BiologyEditorSurface: View {
    let session: BiologyProjectSession
    var onInsertIntoNotes: BiologyNotesInsertion?
    var body: some View {
        BiologyWorkbench(service: session.host.service, projectID: session.projectID,
            onAI: { prompt, context in try await session.requestAI(prompt, context: context) },
            onInsertInNotes: { project, asset, run in
                guard let onInsertIntoNotes else { throw BiologyHostError.unavailable }
                let payload = try await session.notePayload(projectID: project, assetID: asset, runID: run)
                try Task.checkCancellation()
                try await onInsertIntoNotes(payload)
            },
            executionOwner: { project, asset in try await session.executionOwner(project, assetID: asset) },
            makeTools: { project in try await session.makeTools(project) },
            onRunAnalysis: { intent in try await session.runAnalysis(intent) },
            onImportFile: { project, url in try await session.importFile(project, url: url) },
            onAuthorizeFile: { project, asset, revision in try await session.authorizeFile(project, assetID: asset, revision: revision) },
            scientificEnvironmentID: session.scientificEnvironmentID)
        .accessibilityIdentifier("biology.personalEditor")
        .task { await session.prepareExecutionLocation() }
    }
}
#endif
