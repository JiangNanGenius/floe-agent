//
//  ItemsPanelView.swift
//  openshape3d
//
//  Items Manager (spec §11): trailing sidebar listing bodies, sketches,
//  inserted images, construction planes/axes and symbols with visibility,
//  rename, Zoom to, and delete — and FOLDERS: a nested tree at the top that
//  groups any scene items, with a folder eye that toggles all children,
//  rename, "Move to Folder" from any row's menu, and drag-and-drop of rows
//  onto folder rows (or onto a section header to file them back out).
//

import SwiftUI

/// A destination in a row's "Move to Folder" submenu.
struct ItemsMoveTarget: Identifiable {
    let id: ItemFolderID?
    let title: String
    let depth: Int
    let isCurrent: Bool
    var menuID: String { id?.raw.uuidString ?? "top" }
}

struct ItemsPanelView: View {
    @Bindable var viewModel: EditorViewModel

    /// Folders shown collapsed (view state — not part of the document).
    @State private var collapsedFolders: Set<ItemFolderID> = []

    var body: some View {
        let document = viewModel.session.document
        let tree = viewModel.itemFolderTree
        let filed = tree.filedKeys
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                panelHeader

                if !tree.isEmpty {
                    sectionHeader("Folders", dropsToTopLevel: false)
                    ForEach(tree.children(of: nil)) { folder in
                        folderRows(folder, depth: 0, tree: tree)
                    }
                }

                sectionHeader("Bodies")
                let looseBodies = document.bodies.filter { !filed.contains(.body($0.id)) }
                if looseBodies.isEmpty {
                    emptyRow(document.bodies.isEmpty ? "No bodies yet" : "All bodies are in folders")
                }
                ForEach(looseBodies) { body in
                    itemRow(.body(body.id), depth: 0, tree: tree)
                }

                sectionHeader("Sketches")
                let sketches = viewModel.itemSketches
                let looseSketches = sketches.filter { !filed.contains(.sketch($0.id)) }
                if looseSketches.isEmpty {
                    emptyRow(sketches.isEmpty ? "No sketches yet" : "All sketches are in folders")
                }
                ForEach(looseSketches) { sketch in
                    itemRow(.sketch(sketch.id), depth: 0, tree: tree)
                }

                // Constraints + dimensions of the active sketch (plan §C3).
                if viewModel.mode.isSketching {
                    let constraints = viewModel.activeSketchConstraintRows
                    let dimensions = viewModel.activeSketchDimensionRows
                    sectionHeader("Constraints", dropsToTopLevel: false)
                    if constraints.isEmpty && dimensions.isEmpty {
                        emptyRow("No constraints yet")
                    }
                    ForEach(constraints, id: \.id) { row in
                        ConstraintRowView(
                            code: row.code,
                            title: row.title,
                            isSelected: viewModel.selectedConstraintID == row.id,
                            onSelect: { viewModel.selectConstraint(row.id) },
                            onDelete: { viewModel.deleteConstraint(row.id) }
                        )
                    }
                    ForEach(dimensions, id: \.id) { row in
                        ConstraintRowView(
                            code: row.code,
                            title: row.title,
                            isSelected: viewModel.selectedDimensionID == row.id,
                            onSelect: { viewModel.selectDimension(row.id) },
                            onDelete: { viewModel.deleteDimension(row.id) }
                        )
                    }
                }

                sectionHeader("Images")
                let looseImages = document.images.filter { !filed.contains(.image($0.id)) }
                if looseImages.isEmpty {
                    emptyRow(document.images.isEmpty ? "No images yet" : "All images are in folders")
                }
                ForEach(looseImages) { image in
                    itemRow(.image(image.id), depth: 0, tree: tree)
                }

                sectionHeader("Planes")
                let loosePlanes = document.planes.filter { !filed.contains(.plane($0.id)) }
                if loosePlanes.isEmpty {
                    emptyRow(document.planes.isEmpty ? "No planes yet" : "All planes are in folders")
                }
                ForEach(loosePlanes) { plane in
                    itemRow(.plane(plane.id), depth: 0, tree: tree)
                }

                sectionHeader("Axes")
                let looseAxes = document.axes.filter { !filed.contains(.axis($0.id)) }
                if looseAxes.isEmpty {
                    emptyRow(document.axes.isEmpty ? "No axes yet" : "All axes are in folders")
                }
                ForEach(looseAxes) { axis in
                    itemRow(.axis(axis.id), depth: 0, tree: tree)
                }

                sectionHeader("Symbols", dropsToTopLevel: false)
                if document.symbols.isEmpty {
                    emptyRow("No symbols yet")
                }
                // Symbols (plan §B16, spec §1.16): reusable sketch groups.
                // Not scene items, so no visibility eye, Zoom to, or folders.
                ForEach(document.symbols) { symbol in
                    ItemRowView(
                        icon: "rectangle.stack",
                        name: symbol.name,
                        isHidden: false,
                        renameable: true,
                        showsVisibility: false,
                        showsZoom: false,
                        onSelect: {},
                        onToggleVisibility: {},
                        onRename: { viewModel.renameSymbol(symbol.id, to: $0) },
                        onZoom: {},
                        onDelete: { viewModel.deleteSymbol(symbol.id) }
                    )
                }
            }
            .padding(12)
        }
        .frame(width: 290)
        .frame(maxHeight: 520)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
        .shadow(color: .black.opacity(0.15), radius: 10, y: 3)
        .accessibilityIdentifier("ItemsPanel")
    }

    // MARK: Header

    private var panelHeader: some View {
        HStack {
            Text("Items")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button {
                viewModel.createItemFolder()
            } label: {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 15))
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.primary)
            .help("New Folder — with the selected bodies, when there are any")
            .accessibilityLabel("New Folder")
            .accessibilityIdentifier("ItemsNewFolderButton")
        }
        .padding(.horizontal, 8)
        .padding(.top, 2)
    }

    // MARK: Folder tree

    /// A folder row followed by its members and child folders. Recursion
    /// through `AnyView` because an opaque return type cannot recurse.
    private func folderRows(_ folder: ItemFolder, depth: Int, tree: ItemFolderTree) -> AnyView {
        let collapsed = collapsedFolders.contains(folder.id)
        let children = tree.children(of: folder.id)
        let liveMembers = folder.members.filter { viewModel.isItemHidden($0) != nil }
        return AnyView(
            Group {
                FolderRowView(
                    name: folder.name,
                    depth: depth,
                    isHidden: viewModel.itemFolderIsHidden(folder.id),
                    holdsItems: !tree.keys(inSubtree: folder.id).contains { viewModel.isItemHidden($0) != nil } == false,
                    isCollapsed: collapsed,
                    hasContents: !liveMembers.isEmpty || !children.isEmpty,
                    dragPayload: ItemsDragPayload.folder(folder.id),
                    moveTargets: moveTargets(forFolder: folder.id, tree: tree),
                    onToggleCollapse: {
                        if collapsed { collapsedFolders.remove(folder.id) } else { collapsedFolders.insert(folder.id) }
                    },
                    onToggleVisibility: {
                        viewModel.setItemFolderHidden(folder.id, hidden: !viewModel.itemFolderIsHidden(folder.id))
                    },
                    onRename: { viewModel.renameItemFolder(folder.id, to: $0) },
                    onNewSubfolder: {
                        viewModel.createItemFolder(in: folder.id, containing: [])
                        collapsedFolders.remove(folder.id)
                    },
                    onMove: { viewModel.moveItemFolder(folder.id, into: $0) },
                    onRemove: { viewModel.removeItemFolder(folder.id) },
                    onDeleteAll: { viewModel.deleteItemFolderAndItems(folder.id) },
                    onDrop: { payloads in
                        collapsedFolders.remove(folder.id)
                        return handleDrop(payloads, into: folder.id)
                    }
                )
                if !collapsed {
                    ForEach(liveMembers, id: \.self) { key in
                        itemRow(key, depth: depth + 1, tree: tree)
                    }
                    ForEach(children) { child in
                        folderRows(child, depth: depth + 1, tree: tree)
                    }
                }
            }
        )
    }

    /// One item row wherever it appears (a type section or inside a folder).
    @ViewBuilder
    private func itemRow(_ key: DocumentItemKey, depth: Int, tree: ItemFolderTree) -> some View {
        if let row = rowView(for: key, depth: depth, tree: tree) {
            row
        }
    }

    private func rowView(for key: DocumentItemKey, depth: Int, tree: ItemFolderTree) -> ItemRowView? {
        let document = viewModel.session.document
        let targets = moveTargets(forItem: key, tree: tree)
        let payload = ItemsDragPayload.item(key)
        let onMove: (ItemFolderID?) -> Void = { viewModel.moveItems([key], toFolder: $0) }
        let onNewFolder: () -> Void = { viewModel.createItemFolder(containing: [key]) }
        switch key {
        case .body(let id):
            guard let body = document.body(with: id) else { return nil }
            return ItemRowView(
                icon: "cube", name: body.name, isHidden: body.isHidden, renameable: true,
                nameTapSelects: true,
                depth: depth, dragPayload: payload, moveTargets: targets,
                onMove: onMove, onNewFolder: onNewFolder,
                onSelect: { viewModel.selectItemBody(id) },
                onToggleVisibility: { viewModel.setItemHidden(.body(id), hidden: !body.isHidden) },
                onRename: { viewModel.renameItem(.body(id), to: $0) },
                onZoom: { viewModel.zoomToItem(.body(id)) },
                onDelete: { viewModel.deleteItem(.body(id)) })
        case .sketch(let id):
            guard let sketch = document.sketches.first(where: { $0.id == id }) else { return nil }
            return ItemRowView(
                icon: "pencil.and.outline", name: sketch.name, isHidden: sketch.isHidden, renameable: true,
                nameTapSelects: true,
                depth: depth, dragPayload: payload, moveTargets: targets,
                onMove: onMove, onNewFolder: onNewFolder,
                onSelect: { viewModel.selectItemSketch(id) },
                onToggleVisibility: { viewModel.setItemHidden(.sketch(id), hidden: !sketch.isHidden) },
                onRename: { viewModel.renameItem(.sketch(id), to: $0) },
                onZoom: { viewModel.zoomToItem(.sketch(id)) },
                onDelete: { viewModel.deleteItem(.sketch(id)) })
        case .image(let id):
            guard let image = document.images.first(where: { $0.id == id }) else { return nil }
            return ItemRowView(
                icon: "photo", name: image.name, isHidden: image.isHidden, renameable: true,
                depth: depth, dragPayload: payload, moveTargets: targets,
                onMove: onMove, onNewFolder: onNewFolder,
                onSelect: { viewModel.selectImageItem(id) },
                onToggleVisibility: { viewModel.setImageHidden(id, hidden: !image.isHidden) },
                onRename: { viewModel.renameImage(id, to: $0) },
                onZoom: { viewModel.zoomToImage(id) },
                onDelete: { viewModel.deleteImage(id) })
        case .plane(let id):
            guard let index = document.planes.firstIndex(where: { $0.id == id }) else { return nil }
            let plane = document.planes[index]
            return ItemRowView(
                icon: "square.3.layers.3d", name: "Plane \(index + 1)", isHidden: plane.isHidden,
                renameable: false, isSelected: viewModel.selectedPlane?.id == id,
                depth: depth, dragPayload: payload, moveTargets: targets,
                onMove: onMove, onNewFolder: onNewFolder,
                onSelect: { viewModel.selectItemPlane(id) },
                onToggleVisibility: { viewModel.setItemHidden(.plane(id), hidden: !plane.isHidden) },
                onRename: { _ in },
                onZoom: { viewModel.zoomToItem(.plane(id)) },
                onDelete: { viewModel.deleteItem(.plane(id)) })
        case .axis(let id):
            guard let axis = document.axes.first(where: { $0.id == id }) else { return nil }
            return ItemRowView(
                icon: "line.diagonal.arrow", name: axis.name, isHidden: axis.isHidden, renameable: true,
                depth: depth, dragPayload: payload, moveTargets: targets,
                onMove: onMove, onNewFolder: onNewFolder,
                onSelect: {},
                onToggleVisibility: { viewModel.setAxisHidden(id, hidden: !axis.isHidden) },
                onRename: { viewModel.renameAxis(id, to: $0) },
                onZoom: { viewModel.zoomToAxis(id) },
                onDelete: { viewModel.deleteAxis(id) })
        }
    }

    private func moveTargets(forItem key: DocumentItemKey, tree: ItemFolderTree) -> [ItemsMoveTarget] {
        let current = tree.folder(containing: key)
        return [ItemsMoveTarget(id: nil, title: "Top Level", depth: 0, isCurrent: current == nil)]
            + tree.flattened().map {
                ItemsMoveTarget(id: $0.folder.id, title: $0.folder.name, depth: $0.depth + 1,
                                isCurrent: $0.folder.id == current)
            }
    }

    private func moveTargets(forFolder id: ItemFolderID, tree: ItemFolderTree) -> [ItemsMoveTarget] {
        let parent = tree.parent(of: id)
        let excluded = Set([id] + tree.descendants(of: id).map(\.id))
        return [ItemsMoveTarget(id: nil, title: "Top Level", depth: 0, isCurrent: parent == nil)]
            + tree.flattened().filter { !excluded.contains($0.folder.id) }.map {
                ItemsMoveTarget(id: $0.folder.id, title: $0.folder.name, depth: $0.depth + 1,
                                isCurrent: $0.folder.id == parent)
            }
    }

    /// A drop on a folder row (or `nil`: a section header = top level).
    private func handleDrop(_ payloads: [AppDragPayload], into folder: ItemFolderID?) -> Bool {
        let decoded = ItemsDragPayload.decode(payloads)
        guard !decoded.keys.isEmpty || !decoded.folders.isEmpty else { return false }
        if !decoded.keys.isEmpty { viewModel.moveItems(decoded.keys, toFolder: folder) }
        for id in decoded.folders { viewModel.moveItemFolder(id, into: folder) }
        return true
    }

    // MARK: Section chrome

    @ViewBuilder
    private func sectionHeader(_ title: String, dropsToTopLevel: Bool = true) -> some View {
        if dropsToTopLevel {
            SectionHeaderDropView(title: title) { handleDrop($0, into: nil) }
        } else {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.barLabel)
                .padding(.top, 10)
                .padding(.bottom, 2)
        }
    }

    private func emptyRow(_ text: String) -> some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(.barLabelDim)
            .padding(.vertical, 4)
            .padding(.horizontal, 8)
    }
}

// MARK: - Drag payloads

/// Rows drag an `AppDragPayload` (typed, so name text fields refuse it):
/// kind "body"/"sketch"/"plane"/"axis"/"image" or "itemfolder", id = UUID.
private enum ItemsDragPayload {
    static func item(_ key: DocumentItemKey) -> AppDragPayload {
        switch key {
        case .body(let id): return AppDragPayload(kind: "body", id: id.raw.uuidString)
        case .sketch(let id): return AppDragPayload(kind: "sketch", id: id.raw.uuidString)
        case .plane(let id): return AppDragPayload(kind: "plane", id: id.raw.uuidString)
        case .axis(let id): return AppDragPayload(kind: "axis", id: id.raw.uuidString)
        case .image(let id): return AppDragPayload(kind: "image", id: id.raw.uuidString)
        }
    }

    static func folder(_ id: ItemFolderID) -> AppDragPayload {
        AppDragPayload(kind: "itemfolder", id: id.raw.uuidString)
    }

    static func decode(_ payloads: [AppDragPayload]) -> (keys: [DocumentItemKey], folders: [ItemFolderID]) {
        var keys: [DocumentItemKey] = []
        var folders: [ItemFolderID] = []
        for payload in payloads {
            guard let uuid = UUID(uuidString: payload.id) else { continue }
            switch payload.kind {
            case "itemfolder": folders.append(ItemFolderID(raw: uuid))
            case "body": keys.append(.body(BodyID(raw: uuid)))
            case "sketch": keys.append(.sketch(SketchID(raw: uuid)))
            case "plane": keys.append(.plane(ConstructionPlaneID(raw: uuid)))
            case "axis": keys.append(.axis(ConstructionAxisID(raw: uuid)))
            case "image": keys.append(.image(InsertedImageID(raw: uuid)))
            default: break
            }
        }
        return (keys, folders)
    }
}

// MARK: - Rows

/// A section header that also accepts drops: rows dropped here leave their
/// folder ("Bodies" header = back to the top level of the Bodies list).
private struct SectionHeaderDropView: View {
    let title: String
    let onDrop: ([AppDragPayload]) -> Bool
    @State private var isTargeted = false

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(isTargeted ? Color.accentColor : Color.barLabel)
            .padding(.top, 10)
            .padding(.bottom, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .dropDestination(for: AppDragPayload.self) { payloads, _ in
                onDrop(payloads)
            } isTargeted: { isTargeted = $0 }
    }
}

/// A folder row: disclosure chevron, folder icon, editable name, eye that
/// toggles every item inside. Drop target; context menu for folder ops.
private struct FolderRowView: View {
    let name: String
    let depth: Int
    let isHidden: Bool
    /// False when the subtree holds no live item (the eye has nothing to do).
    let holdsItems: Bool
    let isCollapsed: Bool
    let hasContents: Bool
    let dragPayload: AppDragPayload
    let moveTargets: [ItemsMoveTarget]
    let onToggleCollapse: () -> Void
    let onToggleVisibility: () -> Void
    let onRename: (String) -> Void
    let onNewSubfolder: () -> Void
    let onMove: (ItemFolderID?) -> Void
    let onRemove: () -> Void
    let onDeleteAll: () -> Void
    let onDrop: ([AppDragPayload]) -> Bool

    @State private var draft = ""
    @State private var isTargeted = false

    var body: some View {
        // The draggable sits on the INNER content and the context menu on
        // the outer wrapper: on one view the menu's long press wins and a
        // drag never lifts (the gallery cards are built the same way).
        rowContent
            .draggable(dragPayload)
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
            .padding(.leading, CGFloat(depth) * 14)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isTargeted ? Color.accentColor.opacity(0.14) : Color.clear)
            )
            .contentShape(Rectangle())
            .dropDestination(for: AppDragPayload.self) { payloads, _ in
                onDrop(payloads)
            } isTargeted: { isTargeted = $0 }
            .contextMenu { menuItems }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("ItemFolderRow-\(name)")
            .onAppear { draft = name }
            .onChange(of: name) { _, updated in draft = updated }
    }

    private var rowContent: some View {
        HStack(spacing: 6) {
            Button(action: onToggleCollapse) {
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .rotationEffect(.degrees(isCollapsed ? 0 : 90))
                    .frame(width: 14, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(hasContents ? Color.barLabel : Color.barLabelDim)
            .accessibilityLabel(isCollapsed ? "Expand" : "Collapse")
            .accessibilityIdentifier("ItemFolderDisclosure-\(name)")
            Image(systemName: isHidden ? "folder" : "folder.fill")
                .font(.system(size: 15))
                .frame(width: 20)
                .foregroundStyle(isHidden ? Color.barLabelDim : Color.accentColor)
            TextField("Folder", text: $draft)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .onSubmit { onRename(draft) }
                .foregroundStyle(isHidden ? Color.barLabel : Color.primary)
                .accessibilityIdentifier("ItemName-\(name)")
            Spacer(minLength: 4)
            Button(action: onToggleVisibility) {
                Image(systemName: isHidden ? "eye.slash" : "eye")
                    .font(.system(size: 14))
                    .foregroundStyle(!holdsItems ? Color.barLabelDim
                                     : isHidden ? Color.barLabel : Color.primary)
            }
            .buttonStyle(.plain)
            .disabled(!holdsItems)
            .accessibilityIdentifier("ItemEye-\(name)")
            .accessibilityValue(isHidden ? "hidden" : "visible")
        }
    }

    @ViewBuilder
    private var menuItems: some View {
            Button {
                onNewSubfolder()
            } label: {
                Label("New Subfolder", systemImage: "folder.badge.plus")
            }
            Menu {
                ForEach(moveTargets, id: \.menuID) { target in
                    Button {
                        onMove(target.id)
                    } label: {
                        if target.isCurrent {
                            Label(target.title, systemImage: "checkmark")
                        } else {
                            Text(String(repeating: "    ", count: target.depth) + target.title)
                        }
                    }
                    .disabled(target.isCurrent)
                }
            } label: {
                Label("Move to Folder", systemImage: "folder")
            }
            Button {
                onRemove()
            } label: {
                Label("Remove Folder", systemImage: "folder.badge.minus")
            }
            Button(role: .destructive) {
                onDeleteAll()
            } label: {
                Label("Delete Folder and Items", systemImage: "trash")
            }
    }
}

/// One constraint/dimension row: a code badge, its title, tap-to-select, and a
/// trailing trash button that deletes it (undoable, re-solves).
private struct ConstraintRowView: View {
    let code: String
    let title: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(code)
                .font(.caption.weight(.bold))
                .frame(width: 24)
                .foregroundStyle(Color.blue)
            Text(title)
                .font(.footnote)
                .foregroundStyle(isSelected ? Color.blue : Color.primary)
            Spacer(minLength: 4)
            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.system(size: 13))
                    .foregroundStyle(.barLabel)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("ConstraintDelete-\(title)")
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 8)
        .background(
            isSelected ? Color.blue.opacity(0.12) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6)
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("ConstraintRow-\(title)")
    }
}

/// One Items row: type icon, editable name, eye toggle; tap selects, context
/// menu offers Zoom to / Move to Folder / Delete. Draggable onto folder rows.
private struct ItemRowView: View {
    let icon: String
    let name: String
    let isHidden: Bool
    let renameable: Bool
    /// Highlighted like a selected constraint row (a plane picked from Items).
    var isSelected = false
    /// Body names select on tap; Rename is an explicit context-menu action.
    var nameTapSelects = false
    /// Symbols aren't scene items: no eye toggle or Zoom for them.
    var showsVisibility = true
    var showsZoom = true
    /// Indent level (inside a folder).
    var depth = 0
    var dragPayload: AppDragPayload? = nil
    var moveTargets: [ItemsMoveTarget] = []
    var onMove: ((ItemFolderID?) -> Void)? = nil
    var onNewFolder: (() -> Void)? = nil
    let onSelect: () -> Void
    let onToggleVisibility: () -> Void
    let onRename: (String) -> Void
    let onZoom: () -> Void
    let onDelete: () -> Void

    @State private var draft = ""
    @State private var isRenaming = false
    @State private var initialRenameSelectionPending = false
    @FocusState private var renameFocused: Bool

    var body: some View {
        // Draggable on the inner content, context menu on the wrapper — see
        // FolderRowView for why.
        rowContent
            .modifier(OptionalDraggable(payload: dragPayload))
            .padding(.vertical, 7)
            .padding(.horizontal, 8)
            .padding(.leading, CGFloat(depth) * 14 + (depth > 0 ? 20 : 0))
            .background(
                isSelected ? Color.blue.opacity(0.12) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
            .onTapGesture(perform: onSelect)
            .contextMenu { menuItems }
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(isSelected ? .isSelected : [])
            .accessibilityIdentifier("ItemRow-\(name)")
            .onAppear { draft = name }
            .onChange(of: name) { _, updated in draft = updated }
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .frame(width: 24)
                .foregroundStyle(isHidden ? Color.barLabelDim : Color.barLabel)
            if renameable && (!nameTapSelects || isRenaming) {
                TextField("Name", text: $draft)
                    .textFieldStyle(.plain)
                    .autocorrectionDisabled()
                    .focused($renameFocused)
                    .onSubmit {
                        onRename(draft)
                        isRenaming = false
                        renameFocused = false
                    }
                    .onAppear { if isRenaming { renameFocused = true } }
                    .onReceive(NotificationCenter.default.publisher(for: UITextField.textDidBeginEditingNotification)) { notification in
                        guard nameTapSelects, isRenaming, initialRenameSelectionPending,
                              let field = notification.object as? UITextField,
                              field.text == name, draft == name else { return }
                        // Match native Rename: replace the untouched seed on first typing.
                        // Defer until SwiftUI has established this field's caret.
                        DispatchQueue.main.async {
                            guard field.isFirstResponder, isRenaming,
                                  initialRenameSelectionPending,
                                  field.text == name, draft == name else { return }
                            field.selectAll(nil)
                            initialRenameSelectionPending = false
                        }
                    }
                    .foregroundStyle(isHidden ? Color.barLabel : Color.primary)
                    .accessibilityIdentifier("ItemName-\(name)")
            } else {
                Text(name)
                    .foregroundStyle(isHidden ? Color.barLabel : (isSelected ? Color.blue : Color.primary))
                    .accessibilityIdentifier("ItemName-\(name)")
            }
            Spacer(minLength: 4)
            if showsVisibility {
                Button(action: onToggleVisibility) {
                    Image(systemName: isHidden ? "eye.slash" : "eye")
                        .font(.system(size: 14))
                        .foregroundStyle(isHidden ? Color.barLabel : Color.primary)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("ItemEye-\(name)")
                .accessibilityValue(isHidden ? "hidden" : "visible")
            }
        }
    }

    @ViewBuilder
    private var menuItems: some View {
            if renameable && nameTapSelects {
                Button {
                    draft = name
                    initialRenameSelectionPending = true
                    isRenaming = true
                } label: {
                    Label("Rename", systemImage: "pencil")
                }
            }
            if showsZoom {
                Button {
                    onZoom()
                } label: {
                    Label("Zoom to", systemImage: "arrow.up.left.and.arrow.down.right")
                }
            }
            if let onMove, !moveTargets.isEmpty {
                Menu {
                    ForEach(moveTargets, id: \.menuID) { target in
                        Button {
                            onMove(target.id)
                        } label: {
                            if target.isCurrent {
                                Label(target.title, systemImage: "checkmark")
                            } else {
                                Text(String(repeating: "    ", count: target.depth) + target.title)
                            }
                        }
                        .disabled(target.isCurrent)
                    }
                    if let onNewFolder {
                        Divider()
                        Button {
                            onNewFolder()
                        } label: {
                            Label("New Folder with Item", systemImage: "folder.badge.plus")
                        }
                    }
                } label: {
                    Label("Move to Folder", systemImage: "folder")
                }
            }
            Button(role: .destructive) {
                onDelete()
            } label: {
                Label("Delete", systemImage: "trash")
            }
    }
}

/// `.draggable` only when there is a payload (symbol rows have none).
private struct OptionalDraggable: ViewModifier {
    let payload: AppDragPayload?

    func body(content: Content) -> some View {
        if let payload {
            content.draggable(payload)
        } else {
            content
        }
    }
}
