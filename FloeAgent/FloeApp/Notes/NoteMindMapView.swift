// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import SwiftUI
import FloeNotes

/// Native free-layout mind map surface. Replaces the previous MindElixir
/// web bridge: the same NoteDocument model renders as native topic cards with
/// direct manipulation, and every structural change still commits through
/// `onEdit` as one undoable batch (Notes session, store and undo stack stay
/// independent from Canvas). Old documents without node positions decode
/// unchanged; positions are written only when the user first edits the map.
struct NoteMindMapView: View {
    let document: NoteDocument
    let onEdit: @MainActor ([NoteEdit], Int) async throws -> NoteDocument
    let onHistory: @MainActor (Bool) -> Void
    let onError: (String) -> Void
    var images: [UUID: Data] = [:]
    var onSelection: (UUID?) -> Void = { _ in }

    @Environment(\.colorScheme) private var colorScheme
    @State private var viewport = CanvasViewportTransform(scale: 1, pan: .zero)
    @State private var sizes: [UUID: MindMapSize] = [:]
    @State private var selectedID: UUID?
    @State private var editingID: UUID?
    @State private var editDraft = ""
    @State private var drag: NodeDrag?
    @State private var connectionDrag: ConnectionDrag?
    @State private var isMultiTouchNavigating = false
    @State private var hint: String?
    @State private var reparentSource: UUID?
    @State private var subtreeNextDrag = false
    @State private var committing = false
    @State private var fittedKey: String?
    @State private var decodedImages: [UUID: UIImage] = [:]
    @State private var panBaseline: CGSize?
    @FocusState private var keyboardFocused: Bool

    // MARK: - Layout

    private var visibleNodes: [MindMapNode] {
        guard let root = document.nodes.first(where: { $0.parentID == nil }) else { return [] }
        var output: [MindMapNode] = [root]
        var queue: [UUID] = root.isCollapsed ? [] : [root.id]
        while let id = queue.first {
            queue.removeFirst()
            for child in MindMapLayout.orderedChildren(of: id, in: document) {
                output.append(child)
                if !child.isCollapsed { queue.append(child.id) }
            }
        }
        return output
    }

    private var frames: [UUID: NoteRect] {
        MindMapLayout.frames(document: document, sizes: sizes)
    }

    private var renderedFrames: [UUID: NoteRect] {
        guard let drag else { return frames }
        var output = frames
        let scale = viewport.scale > 0 ? viewport.scale : 1
        let delta = CGSize(width: drag.translation.width / scale, height: drag.translation.height / scale)
        for id in drag.movingIDs {
            guard var frame = output[id] else { continue }
            frame.x += Double(delta.width)
            frame.y += Double(delta.height)
            output[id] = frame
        }
        return output
    }

    private var bounds: CGRect {
        renderedFrames.values.reduce(into: CGRect.null) { rect, frame in
            rect = rect.union(CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height))
        }
    }

    private func worldPoint(from screen: CGPoint) -> CGPoint {
        let scale = viewport.scale > 0 ? viewport.scale : 1
        return CGPoint(x: (screen.x - viewport.pan.width) / scale,
                       y: (screen.y - viewport.pan.height) / scale)
    }

    private func hitTest(_ world: CGPoint) -> MindMapNode? {
        let current = renderedFrames
        for node in visibleNodes.reversed() {
            guard let frame = current[node.id] else { continue }
            if CGRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height).insetBy(dx: 4, dy: 4).contains(world) {
                return node
            }
        }
        return nil
    }

    private func fit(in size: CGSize) {
        let rect = bounds.insetBy(dx: -80, dy: -60)
        guard rect.width > 0, rect.height > 0 else { return }
        let scale = min(3, max(0.05, min(size.width / rect.width, size.height / rect.height) * 0.92))
        viewport = CanvasViewportTransform(
            scale: scale,
            pan: CGSize(width: size.width / 2 - rect.midX * scale,
                        height: size.height / 2 - rect.midY * scale)
        )
    }

    // MARK: - Body

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                mapCanvas(size: geometry.size)
                toolbarOverlay
                MindMapMultiTouchNavigator(
                    onActiveChanged: { active in
                        isMultiTouchNavigating = active
                        if active {
                            // A second finger switches intent to navigation;
                            // drop any in-flight direct manipulation without
                            // committing a partial move.
                            drag = nil
                            connectionDrag = nil
                        }
                    },
                    onPan: { delta in
                        viewport = CanvasViewportTransform(scale: viewport.scale, pan: viewport.pan).panned(by: delta)
                    },
                    onZoom: { factor, anchor in
                        viewport = CanvasViewportTransform(scale: viewport.scale, pan: viewport.pan)
                            .zoomed(by: factor, around: anchor)
                    },
                    onFinished: {}
                )
                .allowsHitTesting(false)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { handleCanvasTap() }
            .onAppear { fitIfNeeded(in: geometry.size) }
            .onChange(of: document.id) { _, _ in fitIfNeeded(in: geometry.size, force: true) }
            .onChange(of: geometry.size) { _, newValue in
                // Window resize or rotation re-fits, matching the document reader.
                fittedKey = nil
                fitIfNeeded(in: newValue)
            }
        }
        .accessibilityIdentifier("notes.mindmap")
        .overlay(alignment: .bottom) {
            if let hint {
                Text(hint)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 12)
                    .transition(.opacity)
                    .accessibilityIdentifier("notes.mindmap.hint")
            }
        }
        .onChange(of: hint) { _, _ in
            guard hint != nil else { return }
            let current = hint
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2.4))
                if hint == current { withAnimation { hint = nil } }
            }
        }
        .task(id: images) { decodeImages() }
        .focusable()
        .focusEffectDisabled()
        .focused($keyboardFocused)
        .onAppear { keyboardFocused = true }
        .onKeyPress { press in handleKeyPress(press) }
    }

    private func fitIfNeeded(in size: CGSize, force: Bool = false) {
        let key = "\(document.id.uuidString):\(Int(size.width))x\(Int(size.height))"
        guard force || fittedKey != key else { return }
        fittedKey = key
        fit(in: size)
    }

    @ViewBuilder private var toolbarOverlay: some View {
        HStack(spacing: 2) {
            Button {
                addTopic(sibling: false)
            } label: {
                Label("notes.mindmap.addChild", systemImage: "arrow.turn.down.right")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
            }
            .help("notes.mindmap.addChild.help")
            .disabled(committing || editingID != nil)
            .accessibilityIdentifier("notes.mindmap.addChild")
            Button {
                addTopic(sibling: true)
            } label: {
                Label("notes.mindmap.addSibling", systemImage: "arrow.turn.right")
                    .labelStyle(.iconOnly)
                    .frame(width: 44, height: 44)
            }
            .help("notes.mindmap.addSibling.help")
            .disabled(committing || editingID != nil)
            .accessibilityIdentifier("notes.mindmap.addSibling")
        }
        .buttonStyle(NotesToolbarButtonStyle())
        .padding(6)
        .background(.bar, in: RoundedRectangle(cornerRadius: 12))
        .padding(.top, 10)
        .padding(.leading, 10)
    }

    private func mapCanvas(size: CGSize) -> some View {
        let current = renderedFrames
        return ZStack(alignment: .topLeading) {
            MindMapEdgesLayer(
                document: document,
                frames: current,
                connectionDraft: connectionDraft.flatMap { draft in
                    guard let source = current[draft.sourceID] else { return nil }
                    let world = worldPoint(from: draft.screenPoint)
                    return (source: source, point: world)
                },
                colorScheme: colorScheme
            )
            .allowsHitTesting(false)
            ForEach(visibleNodes) { node in
                if let frame = current[node.id] {
                    nodeCard(node, frame: frame)
                        .position(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
                }
            }
        }
        .frame(width: max(size.width, 1), height: max(size.height, 1), alignment: .topLeading)
        .scaleEffect(viewport.scale, anchor: .topLeading)
        .offset(x: viewport.pan.width, y: viewport.pan.height)
        .gesture(connectionDragGesture)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    guard canNavigateViewport else { return }
                    // DragGesture reports total translation; anchor it to the
                    // viewport at gesture start to avoid accumulating drift.
                    if panBaseline == nil { panBaseline = viewport.pan }
                    guard let baseline = panBaseline else { return }
                    viewport.pan = CGSize(width: baseline.width + value.translation.width,
                                          height: baseline.height + value.translation.height)
                }
                .onEnded { _ in panBaseline = nil }
        )
    }

    private var canNavigateViewport: Bool {
        !isMultiTouchNavigating && editingID == nil && drag == nil && connectionDrag == nil
    }

    // MARK: - Node card

    private func nodeCard(_ node: MindMapNode, frame: NoteRect) -> some View {
        let isSelected = selectedID == node.id
        let isEditing = editingID == node.id
        return MindMapNodeCard(
            node: node,
            isSelected: isSelected,
            isEditing: isEditing,
            image: decodedImages[node.imageResourceID ?? UUID()],
            titleDraft: $editDraft,
            beginEditing: { beginEditing(node) },
            commitEditing: { commitEditing(node) },
            toggleCollapse: { toggleCollapse(node) },
            hasChildren: !MindMapLayout.orderedChildren(of: node.id, in: document).isEmpty,
            reportSize: { size in
                let scale = max(viewport.scale, 0.0001)
                let world = MindMapSize(width: Double(size.width) / scale, height: Double(size.height) / scale)
                if sizes[node.id] != world { sizes[node.id] = world }
            }
        )
        .frame(width: frame.width, height: frame.height)
        .contextMenu { nodeMenu(node) }
        .gesture(nodeDragGesture(node))
        .onTapGesture { handleNodeTap(node) }
        .accessibilityLabel(node.title.isEmpty ? String(localized: "notes.mindmap.untitled") : node.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private func nodeMenu(_ node: MindMapNode) -> some View {
        Button("notes.mindmap.menu.editTopic", systemImage: "pencil") { beginEditing(node) }
        Button("notes.mindmap.menu.addChild", systemImage: "arrow.turn.down.right") { addTopic(sibling: false, to: node) }
        if node.parentID != nil {
            Button("notes.mindmap.menu.addSibling", systemImage: "arrow.turn.right") { addTopic(sibling: true, to: node) }
        }
        Button("notes.mindmap.menu.connect", systemImage: "point.3.connected.trianglepath.dotted") {
            showHint(String(localized: "notes.mindmap.hint.connection"))
            guard let frame = frames[node.id] else { return }
            let world = CGPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
            let screen = CGPoint(x: world.x * viewport.scale + viewport.pan.width,
                                 y: world.y * viewport.scale + viewport.pan.height)
            connectionDrag = ConnectionDrag(sourceID: node.id, screenPoint: screen)
        }
        Button("notes.mindmap.menu.moveSubtree", systemImage: "arrow.up.and.down.and.arrow.left.and.right") {
            subtreeNextDrag = true
            showHint(String(localized: "notes.mindmap.hint.subtreeDrag"))
        }
        if node.parentID != nil {
            Button("notes.mindmap.menu.reparent", systemImage: "arrow.right.to.line") {
                reparentSource = node.id
                showHint(String(localized: "notes.mindmap.hint.reparent"))
            }
        }
        Button("notes.mindmap.menu.autoLayout", systemImage: "rectangle.3.group") { autoLayout() }
        if !MindMapLayout.orderedChildren(of: node.id, in: document).isEmpty {
            Button(node.isCollapsed ? "notes.mindmap.menu.expand" : "notes.mindmap.menu.collapse",
                   systemImage: node.isCollapsed ? "arrow.down.forward.and.arrow.up.backward" : "arrow.up.backward.and.arrow.down.forward") {
                toggleCollapse(node)
            }
        }
        if node.parentID != nil {
            Divider()
            Button("notes.mindmap.menu.delete", systemImage: "trash", role: .destructive) {
                commitMaterializing(edits: [.deleteBranch(node.id)])
            }
        }
    }

    // MARK: - Gestures

    private func nodeDragGesture(_ node: MindMapNode) -> some Gesture {
        DragGesture(minimumDistance: 3)
            .onChanged { value in
                guard CanvasNodeGesturePolicy.allowsNodeDrag(
                    isSelectMode: true,
                    isMultiTouchNavigating: isMultiTouchNavigating,
                    hasLiveConnectionDrag: connectionDrag != nil,
                    isEditing: editingID != nil,
                    isLocked: false
                ) else { return }
                if drag == nil {
                    let mode: NodeDrag.Mode = subtreeNextDrag ? .subtree : .single
                    subtreeNextDrag = false
                    var moving: Set<UUID> = [node.id]
                    if mode == .subtree {
                        moving.formUnion(MindMapLayout.descendants(of: node.id, in: document).map(\.id))
                    }
                    let fullFrames = MindMapLayout.frames(document: document, sizes: sizes, includeCollapsed: true)
                    drag = NodeDrag(nodeID: node.id, mode: mode, movingIDs: moving,
                                    pinFrames: fullFrames, translation: .zero)
                }
                drag?.translation = value.translation
            }
            .onEnded { value in
                guard var active = drag else { return }
                active.translation = value.translation
                drag = nil
                commitDrag(active)
            }
    }

    private var connectionDragGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard connectionDrag != nil else { return }
                connectionDrag?.screenPoint = value.location
            }
            .onEnded { value in
                guard let draft = connectionDrag else { return }
                connectionDrag = nil
                let world = worldPoint(from: value.location)
                guard let target = hitTest(world), target.id != draft.sourceID else { return }
                commitMaterializing(edits: [.upsertConnection(MindMapConnection(from: draft.sourceID, to: target.id))])
            }
    }

    private func commitDrag(_ drag: NodeDrag) {
        let scale = viewport.scale > 0 ? viewport.scale : 1
        let dx = drag.translation.width / scale
        let dy = drag.translation.height / scale
        guard abs(dx) > 1 || abs(dy) > 1 else { return }
        var overrides: [UUID: MindMapPoint] = [:]
        for id in drag.movingIDs {
            guard let start = drag.pinFrames[id] else { continue }
            overrides[id] = MindMapPoint(x: start.x + start.width / 2 + Double(dx),
                                         y: start.y + start.height / 2 + Double(dy))
        }
        commitMaterializing(edits: [], pinFrames: drag.pinFrames, pinOverrides: overrides)
    }

    private func handleNodeTap(_ node: MindMapNode) {
        if editingID != nil { commitActiveEditing() }
        if let source = reparentSource {
            reparent(source: source, target: node)
            return
        }
        if selectedID != node.id {
            selectedID = node.id
            onSelection(node.id)
        }
    }

    private func handleCanvasTap() {
        if editingID != nil { commitActiveEditing() }
        if reparentSource != nil {
            reparentSource = nil
            showHint(nil)
            return
        }
        if selectedID != nil {
            selectedID = nil
            onSelection(nil)
        }
    }

    // MARK: - Editing

    private func beginEditing(_ node: MindMapNode) {
        if editingID != nil { commitActiveEditing() }
        selectedID = node.id
        onSelection(node.id)
        editDraft = node.title
        editingID = node.id
    }

    private func commitActiveEditing() {
        guard let id = editingID, let node = document.nodes.first(where: { $0.id == id }) else {
            editingID = nil
            return
        }
        commitEditing(node)
    }

    private func commitEditing(_ node: MindMapNode) {
        guard editingID == node.id else { return }
        editingID = nil
        let title = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard title != node.title else { return }
        var updated = node
        updated.title = title
        commitMaterializing(edits: [.upsertNode(updated)])
    }

    private func toggleCollapse(_ node: MindMapNode) {
        if editingID != nil { commitActiveEditing() }
        var updated = node
        updated.isCollapsed.toggle()
        commitMaterializing(edits: [.upsertNode(updated)])
    }

    // MARK: - Structure

    private var referenceNode: MindMapNode? {
        if let selectedID, let node = document.nodes.first(where: { $0.id == selectedID }) { return node }
        return document.nodes.first(where: { $0.parentID == nil })
    }

    private func addTopic(sibling: Bool, to explicit: MindMapNode? = nil) {
        guard !committing else {
            showHint(String(localized: "notes.mindmap.hint.saving"))
            return
        }
        guard let reference = explicit ?? referenceNode else {
            showHint(String(localized: sibling ? "notes.mindmap.hint.noSelectionSibling" : "notes.mindmap.hint.noSelectionChild"))
            return
        }
        if sibling && reference.parentID == nil {
            showHint(String(localized: "notes.mindmap.hint.rootSibling"))
            return
        }
        let currentFrames = frames
        let parentID: UUID
        let order: Int
        let position: MindMapPoint?
        if sibling, let value = reference.parentID {
            parentID = value
            order = reference.order + 1
            position = MindMapLayout.newSiblingPosition(document: document, frames: currentFrames, siblingID: reference.id)
        } else {
            parentID = reference.id
            order = MindMapLayout.orderedChildren(of: reference.id, in: document).count
            position = MindMapLayout.newChildPosition(document: document, frames: currentFrames, parentID: reference.id)
        }
        let newNode = MindMapNode(parentID: parentID, title: String(localized: "notes.mindmap.newTopic"),
                                  order: order, position: position)
        var edits: [NoteEdit] = []
        if sibling {
            // Shift later siblings up in descending order so no intermediate
            // state contains two children with the same order; order ties
            // would make summary re-anchoring depend on id tie-breaks. The
            // inserted topic commits last, into its freed slot.
            let later = MindMapLayout.orderedChildren(of: parentID, in: document)
                .filter { $0.order >= order }
                .sorted { $0.order > $1.order }
            for child in later {
                var shifted = child
                shifted.order += 1
                edits.append(.upsertNode(shifted))
            }
        }
        edits.append(.upsertNode(newNode))
        commitMaterializing(edits: edits) { committed in
            selectedID = newNode.id
            onSelection(newNode.id)
            editDraft = newNode.title
            editingID = newNode.id
        }
    }

    private func reparent(source: UUID, target: MindMapNode) {
        defer { reparentSource = nil }
        guard source != target.id, let node = document.nodes.first(where: { $0.id == source }) else { return }
        guard !MindMapLayout.descendants(of: source, in: document).contains(where: { $0.id == target.id }) else {
            showHint(String(localized: "notes.mindmap.hint.invalidReparent"))
            return
        }
        var updated = node
        updated.parentID = target.id
        updated.order = MindMapLayout.orderedChildren(of: target.id, in: document).count
        // Keep the moved topic where the user sees it, even when it was still
        // floating on the automatic layout.
        var overrides: [UUID: MindMapPoint] = [:]
        if updated.position == nil, let frame = frames[source] {
            overrides[source] = MindMapPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
        }
        commitMaterializing(edits: [.upsertNode(updated)], pinOverrides: overrides)
    }

    private func autoLayout() {
        var stripped = document
        for index in stripped.nodes.indices { stripped.nodes[index].position = nil }
        let laid = MindMapLayout.frames(document: stripped, sizes: sizes, includeCollapsed: true)
        let edits: [NoteEdit] = document.nodes.compactMap { node in
            guard let frame = laid[node.id] else { return nil }
            var updated = node
            updated.position = MindMapPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
            return updated != node ? .upsertNode(updated) : nil
        }
        guard !edits.isEmpty else { return }
        commitPlain(edits)
    }

    // MARK: - Commit pipeline

    /// One undoable commit. Any node still floating on the automatic layout
    /// gets its current frame written (including hidden collapsed-subtree
    /// members) so later opens and expands never silently rearrange the map.
    private func commitMaterializing(
        edits: [NoteEdit],
        pinFrames: [UUID: NoteRect]? = nil,
        pinOverrides: [UUID: MindMapPoint] = [:],
        onCommitted: (@MainActor (NoteDocument) -> Void)? = nil
    ) {
        guard !committing else { return }
        committing = true
        Task { @MainActor in
            defer { committing = false }
            do {
                var working = document
                for edit in edits { try edit.apply(to: &working) }
                let preEdit = MindMapLayout.frames(document: document, sizes: sizes, includeCollapsed: true)
                let postEdit = pinFrames ?? MindMapLayout.frames(document: working, sizes: sizes, includeCollapsed: true)
                // Prefer post-edit frames (nothing visibly jumps); pre-edit
                // frames fill nodes hidden by the edit itself.
                let base = preEdit.merging(postEdit) { _, new in new }
                var all = edits
                for node in working.nodes {
                    var updated = node
                    if let override = pinOverrides[node.id] { updated.position = override }
                    if updated.position == nil, let frame = base[node.id] {
                        updated.position = MindMapPoint(x: frame.x + frame.width / 2, y: frame.y + frame.height / 2)
                    }
                    if updated != node { all.append(.upsertNode(updated)) }
                }
                guard !all.isEmpty else { return }
                let committed = try await onEdit(all, document.revision)
                guard committed.id == document.id else { return }
                onCommitted?()
            } catch {
                onError(error.localizedDescription)
            }
        }
    }

    private func commitPlain(_ edits: [NoteEdit]) {
        guard !committing else { return }
        committing = true
        Task { @MainActor in
            defer { committing = false }
            do { _ = try await onEdit(edits, document.revision) }
            catch { onError(error.localizedDescription) }
        }
    }

    // MARK: - Keyboard

    private func handleKeyPress(_ press: KeyPress) -> KeyPress.Result {
        if press.key == "z" && press.modifiers.contains(.command) {
            onHistory(press.modifiers.contains(.shift))
            return .handled
        }
        if press.key == "\u{8}" || press.key == "\u{7F}" {
            guard editingID == nil, let selectedID, let node = document.nodes.first(where: { $0.id == selectedID }),
                  node.parentID != nil else { return .ignored }
            commitMaterializing(edits: [.deleteBranch(selectedID)])
            return .handled
        }
        if press.key == "\r" || press.key == "\n" {
            guard editingID == nil, let referenceNode else { return .ignored }
            beginEditing(referenceNode)
            return .handled
        }
        if press.key == "\t" {
            guard editingID == nil else { return .ignored }
            addTopic(sibling: press.modifiers.contains(.shift))
            return .handled
        }
        return .ignored
    }

    // MARK: - Misc

    private func showHint(_ value: String?) {
        withAnimation(.easeOut(duration: 0.2)) { hint = value }
    }

    private func decodeImages() {
        var decoded: [UUID: UIImage] = [:]
        for (id, data) in images {
            guard let image = UIImage(data: data), image.size.width > 0, image.size.height > 0 else { continue }
            let scale = min(200 / image.size.width, 150 / image.size.height)
            if scale < 1 {
                let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                let renderer = UIGraphicsImageRenderer(size: size)
                decoded[id] = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            } else {
                decoded[id] = image
            }
        }
        if decodedImages != decoded { decodedImages = decoded }
    }

    // MARK: - Drag state

    private struct NodeDrag {
        enum Mode { case single, subtree }
        let nodeID: UUID
        let mode: Mode
        let movingIDs: Set<UUID>
        /// Full layout (including collapsed subtrees) captured at drag start.
        let pinFrames: [UUID: NoteRect]
        var translation: CGSize
    }

    private struct ConnectionDrag {
        let sourceID: UUID
        var screenPoint: CGPoint
    }
}

// MARK: - Node card

private struct MindMapNodeCard: View {
    let node: MindMapNode
    let isSelected: Bool
    let isEditing: Bool
    let image: UIImage?
    let titleDraft: Binding<String>
    let beginEditing: () -> Void
    let commitEditing: () -> Void
    let toggleCollapse: () -> Void
    let hasChildren: Bool
    let reportSize: (CGSize) -> Void

    @FocusState private var titleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if isEditing {
                TextField(text: titleDraft) {
                    Text(node.title.isEmpty ? String(localized: "notes.mindmap.untitled") : node.title)
                }
                .textFieldStyle(.plain)
                .font(titleFont)
                .foregroundStyle(foreground)
                .focused($titleFocused)
                .onSubmit { commitEditing() }
            } else {
                Text(node.title.isEmpty ? String(localized: "notes.mindmap.untitled") : node.title)
                    .font(titleFont)
                    .foregroundStyle(foreground)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onTapGesture(count: 2) { beginEditing() }
            }
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 200, maxHeight: 150)
            }
            if let icons = node.icons, !icons.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(icons.prefix(4)), id: \.self) { icon in
                        Text(icon).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if let tags = node.tags, !tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(Array(tags.prefix(3)), id: \.self) { tag in
                        Text(tag)
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.secondary.opacity(0.18), in: Capsule())
                    }
                }
            }
        }
        .frame(maxWidth: 280, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: MindMapNodeSizeKey.self, value: [node.id: proxy.size])
            }
        )
        .onPreferenceChange(MindMapNodeSizeKey.self) { reportSize($0[node.id] ?? .zero) }
        .background(background, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(isSelected ? 0 : 0.12),
                              lineWidth: isSelected ? 2 : 0.5)
        }
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
        .overlay(alignment: .bottomTrailing) {
            if hasChildren {
                Button(action: toggleCollapse) {
                    Image(systemName: node.isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(node.isCollapsed ? String(localized: "notes.mindmap.menu.expand") : String(localized: "notes.mindmap.menu.collapse"))
            }
        }
        .overlay(alignment: .topTrailing) {
            if node.hyperLink != nil {
                Image(systemName: "link")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .accessibilityHidden(true)
            }
        }
        .onChange(of: isEditing) { _, editing in
            if editing { titleFocused = true }
        }
        .onChange(of: titleFocused) { _, focused in
            // Leaving the field without Return still saves the draft.
            if !focused, isEditing { commitEditing() }
        }
    }

    private var titleFont: Font {
        if let size = node.style?["fontSize"], let value = Double(size), (10...72).contains(value) {
            return .system(size: value)
        }
        return .body
    }

    private var background: Color {
        if let hex = node.color ?? node.style?["background"], let color = Color(floeHex: hex) {
            return color
        }
        return Color(uiColor: .secondarySystemBackground)
    }

    private var foreground: Color {
        if node.color != nil || node.style?["background"] != nil { return .white }
        if let hex = node.style?["color"], let color = Color(floeHex: hex) { return color }
        return .primary
    }
}

private struct MindMapNodeSizeKey: PreferenceKey {
    static let defaultValue: [UUID: CGSize] = [:]
    static func reduce(value: inout [UUID: CGSize], nextValue: () -> [UUID: CGSize]) {
        nextValue().forEach { value[$0.key] = $0.value }
    }
}

private extension Color {
    init?(floeHex hex: String) {
        var value = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.first == "#" else { return nil }
        value.removeFirst()
        guard value.count == 6 || value.count == 8, let number = UInt64(value, radix: 16) else { return nil }
        let red, green, blue, alpha: Double
        if value.count == 6 {
            red = Double((number >> 16) & 0xFF) / 255
            green = Double((number >> 8) & 0xFF) / 255
            blue = Double(number & 0xFF) / 255
            alpha = 1
        } else {
            red = Double((number >> 24) & 0xFF) / 255
            green = Double((number >> 16) & 0xFF) / 255
            blue = Double((number >> 8) & 0xFF) / 255
            alpha = Double(number & 0xFF) / 255
        }
        self = Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }
}

// MARK: - Multi-touch navigation

/// Window-level two-finger pan + pinch, mirroring the workspace canvas: the
/// second finger switches intent from direct manipulation to viewport
/// navigation and cancels any in-flight node/connector gesture.
private struct MindMapMultiTouchNavigator: UIViewRepresentable {
    var onActiveChanged: @MainActor (Bool) -> Void
    var onPan: @MainActor (CGSize) -> Void
    var onZoom: @MainActor (CGFloat, CGPoint) -> Void
    var onFinished: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIView(context: Context) -> NavigatorMarkerView {
        let view = NavigatorMarkerView()
        view.onWindowChanged = { [weak coordinator = context.coordinator] marker in
            guard let coordinator else { return }
            if marker.window != nil { coordinator.attach(to: marker) }
            else { coordinator.detach() }
        }
        return view
    }
    func updateUIView(_ uiView: NavigatorMarkerView, context: Context) {
        context.coordinator.parent = self
    }
    static func dismantleUIView(_ uiView: NavigatorMarkerView, coordinator: Coordinator) {
        coordinator.detach()
    }

    final class NavigatorMarkerView: UIView {
        var onWindowChanged: ((NavigatorMarkerView) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            onWindowChanged?(self)
        }
    }

    @MainActor
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var parent: MindMapMultiTouchNavigator
        private weak var marker: NavigatorMarkerView?
        private weak var hostWindow: UIWindow?
        private var panRecognizer: UIPanGestureRecognizer?
        private var pinchRecognizer: UIPinchGestureRecognizer?
        private var panIsActive = false
        private var pinchIsActive = false
        private var publishedActive = false

        init(_ parent: MindMapMultiTouchNavigator) { self.parent = parent }

        func attach(to marker: NavigatorMarkerView) {
            self.marker = marker
            guard let window = marker.window else { detach(); return }
            guard hostWindow !== window else { return }
            detach()
            hostWindow = window

            let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            pan.minimumNumberOfTouches = 2
            pan.maximumNumberOfTouches = 2
            pan.allowedScrollTypesMask = .continuous
            configure(pan)
            let pinch = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            configure(pinch)
            window.addGestureRecognizer(pan)
            window.addGestureRecognizer(pinch)
            panRecognizer = pan
            pinchRecognizer = pinch
        }

        func detach() {
            if let panRecognizer { hostWindow?.removeGestureRecognizer(panRecognizer) }
            if let pinchRecognizer { hostWindow?.removeGestureRecognizer(pinchRecognizer) }
            panRecognizer = nil
            pinchRecognizer = nil
            hostWindow = nil
            panIsActive = false
            pinchIsActive = false
            publishActivityIfNeeded()
        }

        private func configure(_ recognizer: UIGestureRecognizer) {
            recognizer.delegate = self
            recognizer.cancelsTouchesInView = true
            recognizer.delaysTouchesBegan = false
            recognizer.delaysTouchesEnded = false
            recognizer.allowedTouchTypes = [
                NSNumber(value: UITouch.TouchType.direct.rawValue),
                NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
            ]
        }

        @objc private func handlePan(_ recognizer: UIPanGestureRecognizer) {
            guard let hostWindow, let marker else { return }
            switch recognizer.state {
            case .began:
                panIsActive = true
                publishActivityIfNeeded()
            case .changed:
                let delta = recognizer.translation(in: hostWindow)
                recognizer.setTranslation(.zero, in: hostWindow)
                parent.onPan(delta)
            case .ended, .cancelled, .failed:
                panIsActive = false
                publishActivityIfNeeded()
            default:
                break
            }
            _ = marker
        }

        @objc private func handlePinch(_ recognizer: UIPinchGestureRecognizer) {
            guard let marker else { return }
            switch recognizer.state {
            case .began:
                pinchIsActive = true
                publishActivityIfNeeded()
            case .changed:
                let anchor = recognizer.location(in: marker)
                parent.onZoom(recognizer.scale, anchor)
                recognizer.scale = 1
            case .ended, .cancelled, .failed:
                pinchIsActive = false
                publishActivityIfNeeded()
            default:
                break
            }
        }

        private func publishActivityIfNeeded() {
            let active = panIsActive || pinchIsActive
            guard active != publishedActive else { return }
            publishedActive = active
            parent.onActiveChanged(active)
        }

        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let marker, let hostWindow, marker.window === hostWindow else { return false }
            let point = marker.convert(gestureRecognizer.location(in: hostWindow), from: hostWindow)
            return marker.bounds.insetBy(dx: -1, dy: -1).contains(point)
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            guard let marker, let hostWindow else { return false }
            let point = marker.convert(touch.location(in: hostWindow), from: hostWindow)
            guard marker.bounds.insetBy(dx: -1, dy: -1).contains(point) else { return false }
            return !touchBelongsToControl(touch)
        }

        func gestureRecognizer(
            _ gestureRecognizer: UIGestureRecognizer,
            shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
        ) -> Bool {
            gestureRecognizer === panRecognizer
                || gestureRecognizer === pinchRecognizer
                || otherGestureRecognizer === panRecognizer
                || otherGestureRecognizer === pinchRecognizer
        }

        private func touchBelongsToControl(_ touch: UITouch) -> Bool {
            var candidate = touch.view
            while let view = candidate {
                if view is UITextView || view is UITextField || view is UIControl { return true }
                if view is UIScrollView { return true }
                candidate = view.superview
            }
            return false
        }
    }
}
#endif
