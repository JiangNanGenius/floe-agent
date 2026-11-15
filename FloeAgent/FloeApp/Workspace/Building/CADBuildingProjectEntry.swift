// SPDX-License-Identifier: MPL-2.0
// FloeApp — building-project entry shared by the CAD building and
// from-drawing workspaces.
//
// The entry only resolves the folder and starts the project; the project
// surface owns Save/Close/Reopen, the native CAD undo and the records service.
// Creating a project imports a verified copy of the drawing that is already
// open, so the original file is never edited from two owners.

#if canImport(UIKit)
import SwiftUI
import FloeCAD
import FloeCore

import FloeBuildingEditor

@MainActor
private struct BuildingProjectPresentation: Identifiable {
    let id = UUID()
    let directory: URL
    let library: URL
    let launch: BuildingEditorLaunch
    let importingNativeDocument: URL?
}

@MainActor
struct CADBuildingProjectEntry: ViewModifier {
    let document: FloeCADDocument
    var root: URL? = nil
    var blocked: Bool = false
    var onCoverChange: ((Bool) -> Void)? = nil
    @State private var presentation: BuildingProjectPresentation?
    @State private var confirming = false
    @State private var preparing = false
    @State private var failure: String?

    private func t(_ zh: String, _ en: String) -> String { FloeL10n.isChinese ? zh : en }
    private var workspaceRoot: URL { root ?? document.url.deletingLastPathComponent() }

    func body(content: Content) -> some View {
        content
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { start() } label: {
                        Label(t("工程", "Project"), systemImage: "building.columns")
                    }
                    .disabled(blocked || preparing || document.isClosed)
                    .accessibilityIdentifier("cad.building.project")
                }
            }
            .confirmationDialog(t("从当前图形建立工程？", "Create a project from this drawing?"),
                                isPresented: $confirming, titleVisibility: .visible) {
                Button(t("建立工程", "Create project")) { createProject() }
                Button(t("取消", "Cancel"), role: .cancel) {}
            } message: {
                Text(t("工程会复制当前已保存的 CAD 图形到工作区的“Building Projects”，原文件保持不变；之后请在工程中继续编辑。",
                       "The project copies the saved CAD drawing into “Building Projects” in this workspace. The original file stays unchanged; continue in the project."))
            }
            .onChange(of: presentation?.id) { _, value in onCoverChange?(value != nil) }
            .fullScreenCover(item: $presentation) { item in
                BuildingProjectWorkspaceView(projectDirectory: item.directory,
                                             assetLibraryDirectory: item.library,
                                             launch: item.launch,
                                             importingNativeDocument: item.importingNativeDocument) {
                    presentation = nil
                }
                .id(item.id)
            }
            .alert(t("工程操作未完成", "The project operation did not finish"),
                   isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
                Button(t("好", "OK"), role: .cancel) { failure = nil }
            } message: { Text(failure ?? "") }
    }

    private func start() {
        guard !blocked, !preparing, !document.isClosed else { return }
        let directory = BuildingProjectLocation.projectDirectory(for: document, workspaceRoot: workspaceRoot)
        if FileManager.default.fileExists(atPath: directory.appendingPathComponent("Manifest.json").path) {
            present(directory: directory, launch: .open, importing: nil)
        } else if FileManager.default.fileExists(atPath: directory.path) {
            // A previous attempt left its own layout or working copy. Its
            // recovery journal decides what can be reopened.
            present(directory: directory, launch: .open, importing: nil)
        } else {
            confirming = true
        }
    }

    private func createProject() {
        guard !blocked, !preparing else { return }
        preparing = true
        let directory = BuildingProjectLocation.projectDirectory(for: document, workspaceRoot: workspaceRoot)
        let library = BuildingProjectLocation.assetLibrary(workspaceRoot: workspaceRoot)
        let name = BuildingProjectLocation.projectName(for: document)
        let source = document.url.standardizedFileURL
        Task { @MainActor in
            defer { preparing = false }
            // The project imports committed bytes only. Its own save, undo and
            // reopening never run on this preview's document afterwards.
            if document.hasUnsavedChanges {
                let outcome = await document.save()
                guard outcome.succeeded else {
                    failure = outcome.error ?? t("当前 CAD 图形未能保存，工程没有建立。",
                                                 "The current CAD drawing could not be saved, so the project was not created.")
                    return
                }
            }
            presentation = BuildingProjectPresentation(directory: directory, library: library,
                                                       launch: .create(name: name),
                                                       importingNativeDocument: source)
        }
    }

    private func present(directory: URL, launch: BuildingEditorLaunch, importing: URL?) {
        presentation = BuildingProjectPresentation(directory: directory,
                                                   library: BuildingProjectLocation.assetLibrary(workspaceRoot: workspaceRoot),
                                                   launch: launch,
                                                   importingNativeDocument: importing)
    }
}

#endif
