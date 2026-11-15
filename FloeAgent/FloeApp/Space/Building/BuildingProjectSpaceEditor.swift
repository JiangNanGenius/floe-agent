// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeBuildingEditor

/// Space's building-project surface. The central Space editor resolves the
/// record and presents this view; it never mounts a CAD-document workspace for
/// a personal building record. A missing package is created once, then the
/// existing project host owns Save/Close/Reopen and the real assistant mount.
@MainActor
struct BuildingProjectSpaceEditor: View {
    let recordID: UUID
    let title: String
    let directory: URL
    var opensAssistantOnLoad: Bool = false
    let onClose: () -> Void

    private enum Preparation: Equatable {
        case loading
        case ready(URL, URL)
        case failed(String)
    }

    @State private var preparation: Preparation = .loading
    @State private var attempt = 0
    @Environment(\.locale) private var locale

    private func copy(_ zh: String, _ en: String) -> String {
        locale.language.languageCode?.identifier == "zh" ? zh : en
    }

    var body: some View {
        Group {
            switch preparation {
            case .ready(let project, let library):
                BuildingProjectWorkspaceView(
                    projectDirectory: project,
                    assetLibraryDirectory: library,
                    launch: .open,
                    spaceRecordID: recordID,
                    opensAssistantOnLoad: opensAssistantOnLoad,
                    onFinished: onClose
                )
            case .loading:
                VStack(spacing: 12) {
                    ProgressView(copy("正在打开建筑项目…", "Opening building project…"))
                    Button(copy("取消", "Cancel"), role: .cancel) { onClose() }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView {
                    Label(copy("建筑项目未能打开", "The building project could not be opened"),
                          systemImage: "exclamationmark.folder")
                } description: {
                    Text(message).textSelection(.enabled)
                } actions: {
                    Button(copy("重试", "Retry")) { attempt += 1 }
                    Button(copy("关闭", "Close"), role: .cancel) { onClose() }
                }
            }
        }
        .task(id: attempt) {
            guard case .loading = preparation else { return }
            do {
                try await prepare()
            } catch {
                guard !Task.isCancelled else { return }
                preparation = .failed(error.localizedDescription)
            }
        }
        .onChange(of: directory) { _, _ in
            preparation = .loading
            attempt += 1
        }
    }

    private func prepare() async throws {
        let project = BuildingProjectSpaceOriginal.projectURL(directory: directory)
        if !FileManager.default.fileExists(atPath: project.path) {
            try await BuildingProjectSpaceOriginal.create(
                spaceRecordID: recordID, title: title, directory: directory)
        }
        try Task.checkCancellation()
        _ = try BuildingProjectSpaceOriginal.verify(
            spaceRecordID: recordID, title: title, directory: directory)
        preparation = .ready(
            project,
            BuildingProjectSpaceOriginal.assetLibraryURL(directory: directory)
        )
    }
}
#endif
