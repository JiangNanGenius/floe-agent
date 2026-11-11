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
            scientificEnvironmentID: session.scientificEnvironmentID,
            // The same persistent, shared file assistant as every other editor:
            // streaming/history/tool feedback and queue semantics live there.
            // Opening it validates the current asset/revision and refreshes the
            // persisted real selection through the existing service path, so the
            // shared conversation reads the same current asset via biology.read.
            assistantContent: { _ in
                AnyView(StudioAssistantView(record: session.record, embedded: true))
            },
            prepareAssistant: { context in try await session.syncAssistantSelection(context) })
        .accessibilityIdentifier("biology.personalEditor")
        .task { await session.prepareExecutionLocation() }
    }
}
#endif
