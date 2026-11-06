#if canImport(UIKit)
import SwiftUI
import FloeCanvasCore

/// Root canvas editor. One native top toolbar, a dismissible pages/scenes
/// sidebar, and a contextual inspector — no stacked lab chrome.
public struct CanvasEditorView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @StateObject private var store: CanvasEditorStore
    @StateObject private var previews: CanvasPreviewPipeline
    @State private var showsNewSceneSheet = false

    // MARK: Initializers (frozen in UI_CONTRACT §2)

    @MainActor public init(
        canvasID: UUID,
        services: CanvasEditorServices,
        configuration: CanvasEditorConfiguration = CanvasEditorConfiguration()
    ) {
        let store = CanvasEditorStore(
            canvasID: canvasID,
            services: services,
            configuration: configuration)
        _store = StateObject(wrappedValue: store)
        // One shared pipeline per editor (store-owned) — the board and the
        // inspector resolve thumbnails through the same cache/authority.
        _previews = StateObject(wrappedValue: store.previews)
    }

    /// Host/tests own the store; the view renders that exact store.
    @MainActor public init(store: CanvasEditorStore) {
        _store = StateObject(wrappedValue: store)
        _previews = StateObject(wrappedValue: store.previews)
    }

    /// Read-only access for host code embedding the view.
    public var storeOwner: CanvasEditorStore { store }

    // MARK: Body

    public var body: some View {
        GeometryReader { geometry in
            let isNarrow = horizontalSizeClass == .compact
                || geometry.size.width <= store.configuration.narrowWidthThreshold
            let inspectorIsSheet = isNarrow || geometry.size.width < 1000
            HStack(spacing: 0) {
                if store.showsSidebar && !isNarrow {
                    CanvasSidebarView(store: store)
                        .frame(width: 280)
                        .transition(.move(edge: .leading))
                }
                VStack(spacing: 0) {
                    CanvasToolbarView(
                        store: store,
                        showsNewSceneSheet: $showsNewSceneSheet,
                        isNarrow: isNarrow)
                    ZStack {
                        CanvasBoardRepresentable(store: store)
                            .canvasKeyCommands(store: store)
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                viewportControls
                            }
                        }
                        .padding(12)
                    }
                    .zIndex(0)
                    CanvasDraftBanner(store: store)
                }
                if store.showsInspector && !inspectorIsSheet {
                    CanvasInspectorView(store: store, previews: previews)
                        .frame(width: 320)
                        .transition(.move(edge: .trailing))
                }
            }
            .onChange(of: isNarrow, initial: true) { _, narrow in
                if narrow {
                    store.showsSidebar = false
                    store.showsInspector = false
                }
            }
            .sheet(isPresented: Binding(
                get: { isNarrow && store.showsSidebar },
                set: { if !$0 { store.showsSidebar = false } })) {
                NavigationStack {
                    CanvasSidebarView(store: store)
                        .navigationTitle(store.strings[.toolbarPages])
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                Button(store.strings[.toolbarDone]) {
                                    store.showsSidebar = false
                                }
                                .accessibilityIdentifier(CanvasAccessibilityID.toolbarDone.identifier)
                            }
                        }
                }
            }
            .sheet(isPresented: Binding(
                get: { inspectorIsSheet && store.showsInspector },
                set: { if !$0 { store.showsInspector = false } })) {
                CanvasInspectorSheet(store: store, previews: previews)
            }
            .animation(.easeInOut(duration: 0.2), value: store.showsSidebar)
            .animation(.easeInOut(duration: 0.2), value: store.showsInspector)
            .overlay {
                if store.showsDebugger {
                    CanvasFlowDebuggerSheet(store: store)
                        .frame(maxWidth: 460)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                        .padding(.trailing, store.showsInspector && !inspectorIsSheet ? 324 : 8)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(CanvasAccessibilityID.rootView.identifier)
        .environmentObject(store)
        .environmentObject(previews)
        .overlay(alignment: .bottomTrailing) {
            if store.isMutating {
                ProgressView(store.strings[.savingStatus])
                    .padding(10)
                    .background(.regularMaterial, in: Capsule())
                    .padding(12)
                    .accessibilityIdentifier("floe.canvas.saving")
                    .allowsHitTesting(false)
            }
        }
        .task {
            if !store.isLoaded {
                await store.load()
            }
        }
        .sheet(isPresented: $showsNewSceneSheet) {
            CanvasNewSceneSheet(store: store)
        }
        .sheet(isPresented: Binding(
            get: { store.focusedNodeID != nil },
            set: { present in
                if !present { store.closeContentEditor() }
            })) {
            if let nodeID = store.focusedNodeID,
               let node = store.page.nodes.first(where: { $0.id == nodeID }) {
                CanvasContentEditorSheet(store: store, node: node)
            }
        }
        .sheet(isPresented: Binding(
            get: { store.inkRecognitionSession != nil },
            set: { present in
                if !present { store.discardInkConversion() }
            })) {
            if let session = store.inkRecognitionSession {
                CanvasInkRecognitionSheet(store: store, session: session)
            }
        }
        .alert(item: Binding(
            get: { store.alert },
            set: { value in
                if value == nil { store.dismissAlert() }
            })) { alert in
            CanvasAlertBuilder.alert(for: alert, store: store)
        }
    }

    private var viewportControls: some View {
        HStack(spacing: 0) {
            Button { store.fitToContent() } label: {
                Image(systemName: "viewfinder").frame(width: 44, height: 44)
            }
            .accessibilityLabel(store.strings[.toolbarFit])
            .accessibilityIdentifier("floe.canvas.viewport.fit")
            Divider().frame(height: 20)
            Menu {
                Button(store.strings[.toolbarZoomIn]) { store.zoomIn() }
                Button(store.strings[.toolbarZoomOut]) { store.zoomOut() }
                Button(store.strings[.zoomActualSize]) {
                    if let next = store.viewport.zoomed(byFactor: 1 / store.viewport.scale) {
                        store.setViewport(next)
                    }
                }
                Button(store.strings[.toolbarFit]) { store.fitToContent() }
            } label: {
                Text(store.viewport.scale, format: .percent.precision(.fractionLength(0)))
                    .font(.caption.monospacedDigit())
                    .frame(minWidth: 60, minHeight: 44)
            }
            .accessibilityIdentifier("floe.canvas.viewport.zoom")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.primary)
        .background(.bar, in: RoundedRectangle(cornerRadius: 12))
    }
}
#endif
