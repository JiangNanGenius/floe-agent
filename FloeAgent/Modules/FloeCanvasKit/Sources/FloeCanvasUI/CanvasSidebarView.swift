#if canImport(UIKit)
import SwiftUI
import FloeCanvasCore

/// Pages + named scene sidebar. Search/focus lives here for the large
/// samples (ICH12); scenes save views, never duplicates.
public struct CanvasSidebarView: View {
    @ObservedObject var store: CanvasEditorStore
    @FocusState private var searchFocused: Bool

    private var strings: CanvasStrings { store.strings }

    public init(store: CanvasEditorStore) {
        self.store = store
    }

    public var body: some View {
        VStack(spacing: 0) {
            searchField
            ScrollViewReader { proxy in
              List {
                if !store.searchQuery.isEmpty { searchResultsSection }
                if !store.page.scenes.isEmpty {
                    Section(strings[.toolbarScene]) {
                        ForEach(store.page.scenes.sorted(by: { $0.order < $1.order })) { scene in
                            Button {
                                store.jumpToScene(scene.id)
                            } label: {
                                Label(scene.name, systemImage: "viewfinder")
                            }
                            .accessibilityIdentifier(sceneAccessibilityID(scene))
                            .contextMenu {
                                Button(strings[.toolbarDelete], role: .destructive) {
                                    Task { await store.apply(.removeScene(scene.id)) }
                                }
                            }
                        }
                    }
                }
                Section(strings[.toolbarPages]) {
                    ForEach(store.snapshot.pages) { page in
                        pageRow(page)
                            .id(page.id)
                            .contextMenu {
                                Button(strings[.toolbarDelete], role: .destructive) {
                                    Task { await store.apply(.deletePage(page.id)) }
                                }
                                .disabled(store.snapshot.pages.count <= 1)
                            }
                    }
                    .onDelete { offsets in
                        // Deletion reorders through the store; offsets map
                        // to sorted page order (pages are identity-stable).
                        let pages = store.snapshot.pages
                        for index in offsets {
                            guard pages.indices.contains(index) else { continue }
                            let page = pages[index]
                            guard store.snapshot.pages.count > 1 else { continue }
                            Task { await store.apply(.deletePage(page.id)) }
                        }
                    }
                    Button {
                        Task { await store.apply(.createPage(name: "Page \(store.snapshot.pages.count + 1)", select: true)) }
                    } label: {
                        Label(strings[.toolbarNew], systemImage: "plus")
                    }
                }

            }
              .listStyle(.sidebar)
              .onChange(of: store.selectedPageID) { _, pageID in
                  guard store.searchQuery.isEmpty else { return }
                  proxy.scrollTo(pageID, anchor: .center)
              }
              .onChange(of: store.searchQuery) { _, query in
                  proxy.scrollTo(query.isEmpty ? AnyHashable(store.selectedPageID) : AnyHashable("canvasSearchResults"), anchor: .top)
              }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(CanvasAccessibilityID.sidebar.identifier)
    }

    @ViewBuilder private var searchResultsSection: some View {
        if !store.searchResults.isEmpty {
            Section(strings[.toolbarSearch]) {
                ForEach(store.searchResults) { result in
                    Button {
                        searchFocused = false
                        store.focusSearchResult(result)
                    } label: {
                        VStack(alignment: .leading) {
                            Text(result.node.title ?? strings[.canvasTitleUntitled]).lineLimit(1)
                            Text(result.excerpt).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    .accessibilityIdentifier("floe.canvas.sidebar.result.\(result.node.id.uuidString)")
                }
            }
            .id("canvasSearchResults")
        }
    }

    private var searchField: some View {
        HStack {
            Image(systemName: "magnifyingglass")
            TextField(strings[.toolbarSearch], text: $store.searchQuery)
                .focused($searchFocused)
                .onSubmit { searchFocused = false }
                .onChange(of: store.searchQuery) { _, value in
                    store.updateSearchQuery(value)
                }
                .accessibilityIdentifier(CanvasAccessibilityID.sidebarSearchField.identifier)
            if !store.searchQuery.isEmpty {
                Button {
                    store.updateSearchQuery("")
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .accessibilityLabel(Text(strings[.searchClear]))
            }
        }
        .padding(8)
    }

    private func pageRow(_ page: CanvasPageSnapshot) -> some View {
        HStack {
            Button {
                Task { await store.selectPage(page.id) }
            } label: {
                HStack {
                    Image(systemName: page.id == store.selectedPageID
                        ? "doc.fill" : "doc")
                    Text(page.name)
                        .lineLimit(1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(page.id == store.selectedPageID ? .isSelected : [])
            Spacer()
            Text("\(page.nodes.count)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .accessibilityIdentifier("\(CanvasAccessibilityID.sidebarPages.identifier).\(page.id.uuidString)")
    }

    private func sceneAccessibilityID(_ scene: CanvasSceneRecord) -> String {
        "\(CanvasAccessibilityID.sidebarScenes.identifier).\(scene.id.uuidString)"
    }
}

/// Inspector presentation for narrow layouts (390pt): same content, native
/// sheet, Done stays clear of the keyboard.
public struct CanvasInspectorSheet: View {
    @ObservedObject var store: CanvasEditorStore
    @ObservedObject var previews: CanvasPreviewPipeline

    public var body: some View {
        NavigationStack {
            CanvasInspectorView(store: store, previews: previews)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(stringsDone) {
                            store.showsInspector = false
                        }
                        .accessibilityIdentifier(CanvasAccessibilityID.toolbarDone.identifier)
                    }
                }
        }
    }

    private var stringsDone: String { store.strings[.toolbarDone] }
}
#endif
