// SPDX-License-Identifier: MPL-2.0
// FloeApp — the single building-project surface shared by every CAD entry.
//
// The project owns Save/Close/Reopen; this wrapper only presents it and ends
// the presentation after the project's own close. A full-screen cover has no
// interactive dismissal, so a mounted working copy cannot be orphaned by a
// swipe. The project's failure/recovery screens keep their own exit.

#if canImport(UIKit) && canImport(FloeBuildingEditor)
import SwiftUI
import FloeBuildingEditor

@MainActor
struct BuildingProjectWorkspaceView: View {
    let projectDirectory: URL
    let assetLibraryDirectory: URL
    let launch: BuildingEditorLaunch
    var importingNativeDocument: URL? = nil
    var spaceRecordID: UUID? = nil
    var opensAssistantOnLoad: Bool = false
    let onFinished: () -> Void
    @EnvironmentObject private var environment: AppEnvironment
    @State private var finished = false
    @State private var preview: DeliveryPreview?
    @State private var presenterID = UUID()
    @State private var buildingMount: BuildingStudioMount?
    @State private var assistant: StudioAssistantDocument?
    @State private var assistantError: String?
    @State private var openedAssistantOnLoad = false

    private struct DeliveryPreview: Identifiable {
        let url: URL
        var id: URL { url }
    }

    var body: some View {
        BuildingEditorProjectHost(projectDirectory: projectDirectory,
                                  assetLibraryDirectory: assetLibraryDirectory,
                                  launch: launch,
                                  hostActions: BuildingEditorHostActions(
                                    requestAssistant: { context in
                                        openAssistant(context)
                                    },
                                    projectDidMount: { context in
                                        guard opensAssistantOnLoad, !openedAssistantOnLoad else { return }
                                        openedAssistantOnLoad = true
                                        openAssistant(context)
                                    },
                                    beforeDeparture: { _ in
                                        if let mount = buildingMount {
                                            try await environment.studioCoordinator.retireBuildingAssistant(mount).value
                                            buildingMount = nil
                                        }
                                        return true
                                    },
                                    didClose: { finished = true },
                                    previewFile: { preview = DeliveryPreview(url: $0) },
                                    encodeDWG: { try await CADDrawingModelBridge.encodeDWG($0) },
                                    encodeIFC: { data in
                                        let host = CADBuildingLocalIFCHost()
                                        defer { host.close() }
                                        return try await host.run(input: data).ifc
                                    },
                                    publishCopy: { receipt, url in
                                        _ = try await PersonalContentService.shared.publishBuildingCopy(receipt, at: url)
                                    },
                                    registerIndependentCAD: { handoff in
                                        _ = try await Self.addToSpace(handoff)
                                    }),
                                  importingNativeDocument: importingNativeDocument,
                                  spaceRecordID: spaceRecordID)
            .interactiveDismissDisabled(true)
            .onChange(of: finished) { _, value in if value { onFinished() } }
            .onDisappear {
                if let mount = buildingMount {
                    let studio = environment.studioCoordinator
                    let stop = studio.retireBuildingAssistant(mount)
                    Task { do { try await stop.value } catch { studio.buildingProjects.remove(mount) } }
                }
            }
            .sheet(item: $assistant) { document in
                StudioAssistantView(document: document, onClose: { assistant = nil })
            }
            .alert(IDELanguageRunText.t("助手暂未打开", "Unable to open assistant"),
                   isPresented: Binding(get: { assistantError != nil }, set: { if !$0 { assistantError = nil } })) {
                Button(IDELanguageRunText.t("好", "OK"), role: .cancel) { assistantError = nil }
            } message: { Text(assistantError ?? "") }
            .sheet(item: $preview) { item in
                NavigationStack {
                    InlinePDFReader(url: item.url)
                        .navigationTitle(item.url.lastPathComponent)
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button("workspace.workspace_canvas_view.done") { preview = nil }
                            }
                        }
                }
            }
            .accessibilityIdentifier("cad.building.project.surface")
    }

    /// One native assistant path for both the toolbar and "ask AI on open".
    /// The mount is created only from the project's real tool context.
    private func openAssistant(_ context: BuildingEditorToolContext) {
        do {
            let mount = try environment.studioCoordinator.buildingProjects.attach(
                context, directory: projectDirectory, presenterID: presenterID)
            buildingMount = mount
            assistant = .building(mount)
        } catch { assistantError = error.localizedDescription }
    }

    @discardableResult
    static func addToSpace(_ handoff: BuildingIndependentCADHandoff,
                           service: PersonalContentService = .shared) async throws -> PersonalContentRecord {
        let library = try await service.library()
        let id = AppDesignResultPublicationPort.deterministicUUID("floe.building.delivery|" + handoff.idempotencyKey)
        let kind: PersonalContentKind = handoff.kind == .twoD ? .cad2D : .cad3D
        let title = BuildingProjectLocation.sanitized(handoff.title)
        return try await library.create(kind: kind, title: title, id: id) { directory, _ in
            try await handoff.copyPackage(to: directory.appendingPathComponent("Document.floecad", isDirectory: true))
        }
    }
}
#endif
