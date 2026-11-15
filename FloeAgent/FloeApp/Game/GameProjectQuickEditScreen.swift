// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeCore
import FloeGameCore
import FloeGameEditingCore
import FloeGameEditingUI
import FloeGameSpriteUI
import FloeGameIDEBridge
import FloeGameAppIntegration
import FloeRPGCore
import FloeRPGTilesetUI

/// Native quick editor over the same `GameEditingSession` as the IDE and AI.
/// It never creates a second file tree or a duplicate save path. A covering
/// list/inspector does not close the project session.
struct GameProjectQuickEditScreen: View {
    let session: GameWorkspaceSession
    @EnvironmentObject private var environment: AppEnvironment
    @Environment(\.dismiss) private var dismiss
    @State private var editing: GameEditingSession?
    @State private var selected: GameRelativePath?
    @State private var entries: [GameEditorEntry] = []
    @State private var error: String?
    @State private var showingIDE = false
    @State private var ideRequest: GameIDEOpenRequest?
    @State private var preparing = true
    @State private var openingIDE = false
    @State private var visualContentGeneration: UInt64 = 0

    private var engine: GameEngineID? { session.project.selectionSnapshot?.selectedEngine }

    var body: some View {
        NavigationSplitView {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView {
                        Label(IDELanguageRunText.t("没有可预览文件", "No preview files"),
                              systemImage: "folder")
                    } description: {
                        Text(IDELanguageRunText.t("未知文件仍保留在工程中，可在 IDE 中查看。", "Unknown files remain in the project and are available in the IDE."))
                    }
                } else {
                    List(entries, selection: Binding(get: { selected?.value }, set: { value in
                        selected = value.flatMap { try? GameRelativePath($0) }
                    })) { entry in
                        Label {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(entry.path.value).lineLimit(1)
                                Text(GameQuickEditCopy.title(for: entry.kind, zh: FloeL10n.isChinese))
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                        } icon: {
                            Image(systemName: icon(entry.kind))
                        }
                        .tag(entry.path.value)
                    }
                }
            }
            .navigationTitle(IDELanguageRunText.t("简易编辑", "Quick edit"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(IDELanguageRunText.t("完成", "Done")) { Task { await close() } }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(IDELanguageRunText.t("IDE", "IDE"), systemImage: "chevron.left.forwardslash.chevron.right") {
                        Task { await openIDE() }
                    }.disabled(preparing || openingIDE)
                }
            }
        } detail: {
            Group {
                if let selected, let engine, let rpg = RPGEngine(rawValue: engine.rawValue),
                   entries.first(where: { $0.path == selected })?.kind == .tileMap,
                   !RPGTileMapEditorView.supports(path: selected, engine: rpg,
                                                  selectedRoot: session.selection?.selectedRoot) {
                    ContentUnavailableView {
                        Label(IDELanguageRunText.t("此文件不适用于当前地图编辑器", "This file cannot be edited as a map"),
                              systemImage: "map")
                    } actions: {
                        Button(IDELanguageRunText.t("在 IDE 中打开", "Open in IDE")) {
                            Task { await openIDE(selected) }
                        }
                    }
                } else if let editing, let selected {
                    GameVisualEditingSurface(session: editing, path: selected,
                        tileMapEditorFactory: rpgMapEditor,
                        imageEditorFactory: { value, path in
                            AnyView(GameSpriteEditorView(session: value, path: path))
                        },
                        onOpenIDE: { path in Task { await openIDE(path, visualHandoffPrepared: true) } },
                        onClose: { Task { await close() } },
                        onSaved: { _ in
                            Task { try? await session.project.refresh(); await loadEntries() }
                        })
                        .id(visualContentGeneration)
                        .disabled(openingIDE)
                } else if preparing {
                    ProgressView()
                } else {
                    ContentUnavailableView {
                        Label(IDELanguageRunText.t("选择一个文件", "Choose a file"),
                              systemImage: "sidebar.left")
                    }
                }
            }
        }
        .environment(\.gameEditLocale, FloeL10n.isChinese ? .chinese : .english)
        .task { await prepare() }
        .overlay(alignment: .bottom) {
            if let error { Text(error).font(.callout).foregroundStyle(.red).padding(10) }
        }
        .fullScreenCover(item: $ideBox, onDismiss: {
            Task { await resumeVisualEditing() }
        }) { box in
            GameProjectIDEPresentation(request: box.request, session: session, environment: environment)
        }
        .onDisappear {
            // The project service retains drafts/conflicts. Closing this view
            // only detaches it from the native surface.
            try? session.attachVisual(nil)
        }
    }

    private struct IDEBox: Identifiable {
        let id = UUID()
        let request: GameIDEOpenRequest
    }
    @State private var ideBox: IDEBox?

    private func icon(_ kind: GameNativeEditorKind) -> String {
        switch kind {
        case .tileMap: "map"
        case .sprite: "photo"
        case .parameterForm: "slider.horizontal.3"
        case .narrative: "text.book.closed"
        case .audio: "waveform"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .document: "doc.text"
        case .binary: "shippingbox"
        case .unsupported: "questionmark.square.dashed"
        }
    }

    private func prepare() async {
        preparing = true
        defer { preparing = false }
        do {
            guard let engine else { throw GameWorkspaceRegistryError.notGameRecord }
            var adapters = GameEditingAdapterRegistry()
            if let rpg = RPGEngine(rawValue: engine.rawValue) {
                try adapters.register(RPGEditingAdapter(engine: rpg))
            } else {
                try adapters.register(GameUnknownEditingAdapter(engine: engine))
            }
            guard let adapter = adapters.adapter(for: engine) else {
                throw GameProjectError.unsupportedRoute(engine)
            }
            let created = try await GameEditingSession.open(repository: session.project.repository,
                projectID: session.key.projectID, owner: session.key.owner, adapter: adapter)
            try Task.checkCancellation()
            guard self.engine == engine else { throw GameWorkspaceRegistryError.notGameRecord }
            try session.attachVisual(created)
            editing = created
            updateEntries(created.baseProject, engine: engine)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func loadEntries() async {
        guard let engine else { return }
        do {
            let project = try await session.project.repository.open(session.key.projectID,
                owner: session.key.owner)
            updateEntries(project, engine: engine)
        } catch { self.error = error.localizedDescription }
    }

    private var rpgMapEditor: (@MainActor (GameEditingSession, GameRelativePath) -> AnyView)? {
        guard let engine, let rpg = RPGEngine(rawValue: engine.rawValue) else { return nil }
        return { editing, path in
            AnyView(RPGTileMapEditorView(session: editing, path: path, engine: rpg).id(path))
        }
    }

    private func updateEntries(_ project: GameStoredProject, engine: GameEngineID) {
        let root = session.selection?.selectedRoot
        entries = GameEditorPresentation.entries(project: project, engine: engine, prefix: root?.value, limit: 2_000)
        var firstMap: GameRelativePath?
        if let rpg = RPGEngine(rawValue: engine.rawValue) {
            // A large audio/art folder may fill the file browser before Data.
            let directories = Set(project.files.compactMap { file -> String? in
                guard RPGTileMapEditorView.supports(path: file.path, engine: rpg, selectedRoot: root) else { return nil }
                return file.path.value.split(separator: "/").dropLast().joined(separator: "/")
            })
            let maps = directories.sorted().flatMap {
                GameEditorPresentation.entries(project: project, engine: engine, prefix: $0, limit: 2_000)
            }.filter { RPGTileMapEditorView.supports(path: $0.path, engine: rpg, selectedRoot: root) }
            let mapPaths = Set(maps.map(\.path))
            entries = maps + entries.filter { !mapPaths.contains($0.path) }
            firstMap = maps.first?.path
        }
        if let selected, entries.contains(where: { $0.path == selected }) { return }
        let preferred = GameEditorPresentation.preferredEntry(project: project, engine: engine)?.path
        selected = firstMap ?? entries.first(where: { $0.path == preferred })?.path ?? entries.first?.path
    }

    private func openIDE(_ path: GameRelativePath? = nil,
                         visualHandoffPrepared: Bool = false) async {
        guard !openingIDE else { return }
        openingIDE = true
        defer { openingIDE = false }
        do {
            // Commit the visual draft through the existing CAS path before the
            // IDE reads its initial buffers. Conflicts keep this editor open.
            if visualHandoffPrepared {
                try await session.project.refresh()
            } else {
                try await session.project.prepareForHandoff()
            }
            try Task.checkCancellation()
            guard let workspace = session.center.currentWorkspace else {
                throw GameIDEBridgeError.workspaceChanged
            }
            let pin = try GameIDEWorkspacePin(workspaceID: workspace.id,
                context: try session.project.context)
            ideBox = IDEBox(request: GameIDEOpenRequest(workspace: pin,
                destination: .code(path)))
        } catch { self.error = error.localizedDescription }
    }

    private func resumeVisualEditing() async {
        guard let editing else { return }
        do {
            // The cover may have detached the visual surface. Reconcile any
            // real IDE saves before reattaching this same editor/session.
            _ = try session.project.context
            try session.attachVisual(editing)
            try await session.project.refresh()
            if editing.expectedRevision != session.project.project.revision {
                try await editing.refreshAfterProjectImport()
                // Pixel/text/map editors cache their document in view state.
                // Recreate them only after an actual external IDE revision.
                visualContentGeneration &+= 1
            }
            await loadEntries()
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func close() async {
        do { _ = try await editing?.prepareForHandoff() }
        catch { self.error = error.localizedDescription }
        if editing?.isDirty == true || editing?.pendingDraft != nil || editing?.conflict != nil {
            self.error = IDELanguageRunText.t("请先保存或处理冲突。", "Save or resolve conflicts first.")
            return
        }
        try? session.attachVisual(nil)
        dismiss()
    }
}
#endif
