// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeGameCore
import FloeGameEditingCore

/// Auxiliary editing inside the simple game shell. The existing IDE owns
/// files, code and Git; this surface supplies only visual-edit commands and
/// its own draft/conflict/save lifecycle. Its host retains the workspace lease
/// and validates the active project before opening another destination.
public struct GameVisualEditingSurface: View {
    @ObservedObject public var session: GameEditingSession
    public let path: GameRelativePath
    public let onOpenIDE: @MainActor (GameRelativePath) throws -> Void
    public let onClose: (@MainActor () throws -> Void)?
    public let onSaved: @MainActor (GameStoredProject) -> Void
    public var tileMapEditorFactory: (@MainActor (GameEditingSession, GameRelativePath) -> AnyView)?
    /// Optional PNG pixel/sprite editor, forwarded unchanged. Nil preserves
    /// the existing `AssetPreviewView` fallback.
    public var imageEditorFactory: (@MainActor (GameEditingSession, GameRelativePath) -> AnyView)?
    @Environment(\.gameEditLocale) private var locale
    @State private var commandInFlight = false
    @State private var errorMessage: String?

    public init(session: GameEditingSession, path: GameRelativePath,
                tileMapEditorFactory: (@MainActor (GameEditingSession, GameRelativePath) -> AnyView)? = nil,
                imageEditorFactory: (@MainActor (GameEditingSession, GameRelativePath) -> AnyView)? = nil,
                onOpenIDE: @escaping @MainActor (GameRelativePath) throws -> Void,
                onClose: (@MainActor () throws -> Void)? = nil,
                onSaved: @escaping @MainActor (GameStoredProject) -> Void = { _ in }) {
        self.session = session; self.path = path
        self.tileMapEditorFactory = tileMapEditorFactory
        self.imageEditorFactory = imageEditorFactory
        self.onOpenIDE = onOpenIDE; self.onClose = onClose; self.onSaved = onSaved
    }

    public var body: some View {
        VStack(spacing: 0) {
            if session.pendingDraft != nil { draftControls }
            if session.conflict != nil || !session.fileConflicts.isEmpty { conflictControls }
            GameVisualEditorPanel(session: session, path: path,
                tileMapEditorFactory: tileMapEditorFactory,
                imageEditorFactory: imageEditorFactory,
                onOpenIDE: { target in handoff { try onOpenIDE(target) } })
                // Parameter/text bindings briefly acquire the session operation
                // on each edit. Disabling their controls drops keyboard focus.
                // Explicit save/undo/handoff commands still freeze the surface;
                // the session itself continues to serialize all byte mutations.
                .disabled(commandInFlight || session.pendingDraft != nil || session.conflict != nil || !session.fileConflicts.isEmpty)
        }
        .navigationTitle(path.value)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .buttonBorderShape(.roundedRectangle(radius: 8))
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if busy { ProgressView() }
                Button { perform { try await session.undo() } } label: {
                    Label(text("撤销", "Undo"), systemImage: "arrow.uturn.backward")
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityIdentifier("game.visual.undo")
                .disabled(busy || !session.canUndo || session.pendingDraft != nil || hasConflict)
                Button { perform { try await session.redo() } } label: {
                    Label(text("重做", "Redo"), systemImage: "arrow.uturn.forward")
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                }
                .accessibilityIdentifier("game.visual.redo")
                .disabled(busy || !session.canRedo || session.pendingDraft != nil || hasConflict)
                Button {
                    perform { onSaved(try await session.prepareForHandoff()) }
                } label: {
                    Label(text("保存", "Save"), systemImage: "square.and.arrow.down")
                        .labelStyle(.iconOnly).frame(minWidth: 44, minHeight: 44)
                }
                    .accessibilityIdentifier("game.visual.save")
                    .disabled(busy || !session.isDirty || session.pendingDraft != nil || hasConflict)
                Menu {
                    Button { handoff { try onOpenIDE(path) } } label: {
                        Label(text("打开 IDE", "Open IDE"), systemImage: "curlybraces")
                    }
                    .accessibilityIdentifier("game.visual.openIDE")
                    if let onClose {
                        Button { handoff { try onClose() } } label: {
                            Label(text("完成", "Done"), systemImage: "checkmark")
                        }
                        .accessibilityIdentifier("game.visual.done")
                    }
                } label: { Label(text("更多", "More"), systemImage: "ellipsis.circle") }
                    .accessibilityIdentifier("game.visual.more")
                    .disabled(busy || session.pendingDraft != nil || hasConflict)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("game.visual.surface")
        .interactiveDismissDisabled(session.isDirty || session.pendingDraft != nil || busy)
        .alert(text("无法完成操作", "Could not complete the action"), isPresented: errorPresented) {
            Button(text("关闭", "Close"), role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var busy: Bool { commandInFlight || session.isBusy }
    private var hasConflict: Bool { session.conflict != nil || !session.fileConflicts.isEmpty }
    private var errorPresented: Binding<Bool> {
        Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })
    }
    private func text(_ zh: String, _ en: String) -> String { locale == .chinese ? zh : en }

    private var draftControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text("有未保存的草稿", "An unsaved draft is available"))
                .font(.headline)
                .accessibilityIdentifier("game.visual.draft.banner")
            HStack {
                Button(text("恢复草稿", "Recover draft")) { perform { try await session.recoverDraft() } }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("game.visual.draft.recover")
                Button(text("丢弃草稿", "Discard draft"), role: .destructive) {
                    perform { try session.discardDraft() }
                }
                .accessibilityIdentifier("game.visual.draft.discard")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding().disabled(busy)
    }

    private var conflictControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text("项目有其他修改，请先处理冲突。", "The project changed. Resolve conflicts first."))
                .accessibilityIdentifier("game.visual.conflict.banner")
            if session.conflict != nil {
                Button(text("检查修改", "Review changes")) { perform { try await session.reloadForRebase() } }
                    .accessibilityIdentifier("game.visual.conflict.review")
            }
            ForEach(session.fileConflicts.keys.sorted(by: { $0.value < $1.value }), id: \.value) { path in
                VStack(alignment: .leading, spacing: 4) {
                    Text(path.value).font(.callout).textSelection(.enabled)
                    HStack {
                        Button(text("保留本次编辑", "Keep these edits")) {
                            perform { try session.resolveConflict(at: path, .keepMine) }
                        }
                        .accessibilityIdentifier("game.visual.conflict.keepMine")
                        Button(text("使用文件中的修改", "Use saved file")) {
                            perform { try session.resolveConflict(at: path, .keepTheirs) }
                        }
                        .accessibilityIdentifier("game.visual.conflict.keepTheirs")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding().disabled(busy)
    }

    private func handoff(_ action: @escaping @MainActor () throws -> Void) {
        perform {
            let stored = try await session.prepareForHandoff()
            try Task.checkCancellation()
            onSaved(stored)
            try action()
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        commandInFlight = true
        Task { @MainActor in
            defer { commandInFlight = false }
            do { try await operation() }
            catch is CancellationError { }
            catch let issue as GameEditIssue {
                errorMessage = issue.diagnostics.map { $0.message.text(locale) }.joined(separator: "\n")
            } catch { errorMessage = error.localizedDescription }
        }
    }
}
