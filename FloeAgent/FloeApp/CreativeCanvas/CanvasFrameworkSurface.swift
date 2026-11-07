// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeCore
import FloeCanvasUI

/// A personal canvas opens in exactly the established native framework.
struct CreativeCanvasSurface: View {
    let record: PersonalContentRecord
    @ObservedObject var store: CanvasEditorStore
    @State private var backing: CanvasFrameworkBacking?
    @State private var project: FloeCore.CanvasProject?
    @State private var error: String?

    var body: some View {
        Group {
            if let backing, let project {
                WorkspaceCanvasView(backing: backing, project: project, kitStore: store)
            } else if let error {
                ContentUnavailableView(IDELanguageRunText.t("无法打开画布", "Unable to open canvas"),
                    systemImage: "exclamationmark.triangle", description: Text(error))
            } else { ProgressView(IDELanguageRunText.t("正在打开画布", "Opening canvas")) }
        }.task(id: record.id) { await open() }
    }

    @MainActor private func open() async {
        guard backing == nil else { return }
        do {
            await store.load()
            try Task.checkCancellation()
            let location = try await PersonalContentService.shared.library().resolve(record.id)
            let repository = try CanvasHostServices.repository(record: location.record, directory: location.url)
            let backing = try CanvasFrameworkBacking(record: location.record, directory: location.url, repository: repository)
            let project = try CanvasFrameworkProjection.project(backing.snapshot, record: location.record)
            try Task.checkCancellation()
            self.project = project; self.backing = backing
        } catch is CancellationError {} catch { self.error = error.localizedDescription }
    }
}
#endif
