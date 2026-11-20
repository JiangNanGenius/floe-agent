// SPDX-License-Identifier: MPL-2.0
import SwiftUI
import FloeGameCore
import FloeGameEditingCore

/// Selected-file visual controls for the simple game shell or an existing IDE
/// extension. The host owns file selection, file management and Git. Code and
/// unsupported formats return to the existing IDE, never a second text editor.
public struct GameVisualEditorPanel: View {
    @ObservedObject public var session: GameEditingSession
    public let path: GameRelativePath
    public let onOpenIDE: @MainActor (GameRelativePath) -> Void
    public var tileMapEditorFactory: (@MainActor (GameEditingSession, GameRelativePath) -> AnyView)?
    /// Optional PNG pixel/sprite editor. It is invoked for `.png` paths even
    /// when the engine adapter does not classify the file as an image; the
    /// decoder validates the bytes and `AssetPreviewView` remains the
    /// fallback when no factory is injected.
    public var imageEditorFactory: (@MainActor (GameEditingSession, GameRelativePath) -> AnyView)?
    @State private var showEvents = false
    @Environment(\.gameEditLocale) private var locale

    public init(session: GameEditingSession, path: GameRelativePath,
                tileMapEditorFactory: (@MainActor (GameEditingSession, GameRelativePath) -> AnyView)? = nil,
                imageEditorFactory: (@MainActor (GameEditingSession, GameRelativePath) -> AnyView)? = nil,
                onOpenIDE: @escaping @MainActor (GameRelativePath) -> Void) {
        self.session = session; self.path = path
        self.tileMapEditorFactory = tileMapEditorFactory
        self.imageEditorFactory = imageEditorFactory
        self.onOpenIDE = onOpenIDE
    }

    public var body: some View {
        Group {
            if hasMap && hasEvents {
                VStack(spacing: 0) {
                    Picker(GameEditCopy("Edit content", "编辑内容").text(locale), selection: $showEvents) {
                        Text(GameEditCopy("Map", "地图").text(locale)).tag(false)
                        Text(GameEditCopy("Story / events", "剧情／事件").text(locale)).tag(true)
                    }
                    .pickerStyle(.segmented)
                    .padding(8)
                    .accessibilityIdentifier("game.visual.content.mode")
                    if showEvents { NarrativeEditorView(session: session, path: path) }
                    else { mapEditor }
                }
            } else if hasMap { mapEditor }
            else if hasEvents { NarrativeEditorView(session: session, path: path) }
            else if hasParameters { ParameterFormView(session: session, path: path) }
            else if isPNG, let imageEditorFactory { imageEditorFactory(session, path) }
            else if visualAsset || isPNG { AssetPreviewView(session: session, path: path) }
            else {
                ContentUnavailableView {
                    Label(GameEditCopy("Open in IDE", "在 IDE 中打开").text(locale), systemImage: "curlybraces")
                } description: {
                    Text(path.value)
                } actions: {
                    Button(GameEditCopy("Open IDE", "打开 IDE").text(locale)) { onOpenIDE(path) }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("game.visual.panel.openIDE")
                }
            }
        }
        // The host freezes explicit commands. A transient byte edit must not
        // disable the focused text control; the session serializes mutations.
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("game.visual.panel")
        .id(path)
        .onChange(of: path) { _, _ in showEvents = false }
    }

    private var hasMap: Bool { session.adapter.tileMapBinding(for: path, in: session.baseProject) != nil }
    private var hasEvents: Bool { session.adapter.narrativeBinding(for: path, in: session.baseProject) != nil }
    private var hasParameters: Bool {
        session.adapter.parameterBinding(for: path, in: session.baseProject) != nil
            || (path.value.hasSuffix(".json") && !session.adapter.parameterSchemas(for: path, in: session.baseProject).isEmpty)
    }
    private var visualAsset: Bool {
        guard let kind = session.adapter.assetKind(for: path, in: session.baseProject) else { return false }
        return [.image, .tileset].contains(kind)
    }
    private var isPNG: Bool {
        path.value.lowercased().hasSuffix(".png")
    }
    @ViewBuilder private var mapEditor: some View {
        if let tileMapEditorFactory { tileMapEditorFactory(session, path) }
        else { TileMapEditorView(session: session, path: path) }
    }
}
