// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeGameCore
import FloeGameEditingCore
import FloeGameEditingUI
import FloeGameSpriteCore

/// Native PNG pixel/sprite-sheet/frame editor for one project asset. It uses
/// the shared `GameEditingSession` for bytes, undo/redo, save, drafts and
/// conflicts; the outer `GameVisualEditingSurface` toolbar remains the save
/// and handoff authority.
@MainActor
public struct GameSpriteEditorView: View {
    @ObservedObject public var session: GameEditingSession
    public let path: GameRelativePath
    @StateObject private var model: SpriteEditorDocument
    @Environment(\.gameEditLocale) private var locale

    public init(session: GameEditingSession, path: GameRelativePath) {
        self.session = session
        self.path = path
        _model = StateObject(wrappedValue: SpriteEditorDocument(session: session, path: path))
    }

    public var body: some View {
        Group {
            if model.image == nil && !model.isLoading {
                unavailable
            } else {
                editor
            }
        }
        .task(id: path) { await model.load() }
        .onReceive(session.objectWillChange) { _ in
            model.scheduleSessionRefresh()
        }
        .onDisappear { model.detach() }
        .alert(
            Text(model.issue?.title.text(locale) ?? SpriteUICopy.unsupported.text(locale)),
            isPresented: Binding(
                get: { model.issue != nil },
                set: { if !$0 { model.clearIssue() } })) {
            Button(role: .cancel) { model.clearIssue() } label: {
                Text(SpriteUICopy.cancel.text(locale))
            }
        } message: {
            Text(model.issue?.message(locale) ?? "")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("game.sprite.editor")
    }

    private var editor: some View {
        GameEditorAdaptive { _ in
            HStack(spacing: 0) {
                SpriteFrameSidebar(model: model)
                    .frame(width: 236)
                Divider()
                SpriteCanvasWorkspace(model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                SpriteInspectorView(model: model, scrolls: true)
                    .frame(width: 312)
            }
        } compact: {
            ScrollView {
                VStack(spacing: 0) {
                    SpriteFrameStrip(model: model)
                    Divider()
                    SpriteCanvasWorkspace(model: model)
                        .frame(height: 420)
                    Divider()
                    SpriteInspectorView(model: model, scrolls: false)
                }
            }
            .accessibilityIdentifier("game.sprite.compact.scroll")
        }
    }

    private var unavailable: some View {
        ContentUnavailableView {
            Label {
                Text(SpriteUICopy.unsupported.text(locale))
            } icon: {
                Image(systemName: "photo.badge.exclamationmark")
            }
        } description: {
            VStack(spacing: 6) {
                Text(path.value)
                    .font(.caption.monospaced())
                if let issue = model.issue {
                    Text(issue.message(locale))
                } else {
                    Text(GameEditCopy(
                        "The original file is kept. Open it in the IDE or ask AI to inspect it.",
                        "原文件已保留。可在 IDE 中打开，或让 AI 检查。").text(locale))
                }
            }
        } actions: {
            Button {
                Task { await model.load() }
            } label: {
                Text(SpriteUICopy.retry.text(locale))
            }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("game.sprite.retry")
        }
        .accessibilityIdentifier("game.sprite.unavailable")
    }
}
