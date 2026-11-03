// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import simd

@MainActor
struct CADSceneObjectsPanel: View {
    let document: FloeCADDocument
    @Bindable var viewModel: EditorViewModel
    @State private var rows: [[String: Any]] = []
    @State private var message: String?
    @State private var groupName = ""
    @State private var showNewGroup = false
    @State private var renameID: String?
    @State private var showRename = false
    @State private var editing: SceneObjectEditorTarget?
    @State private var operation: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var busy = false

    private var groups: [[String: Any]] { rows.filter { $0["kind"] as? String == "group" } }
    private var ordered: [(row: [String: Any], depth: Int)] {
        var output: [(row: [String: Any], depth: Int)] = [], visited = Set<String>()
        func walk(_ parent: String, _ depth: Int) {
            guard depth <= CADSceneObjectHierarchy.maximumDepth else { return }
            for row in rows where (row["parent_id"] as? String ?? "") == parent {
                guard let id = row["id"] as? String, visited.insert(id).inserted else { continue }
                output.append((row, depth)); walk(id, depth + 1)
            }
        }
        walk("", 0)
        return output
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(FloeCADStrings.text("cad.scene.newGroup", "New group"), systemImage: "folder.badge.plus") {
                    groupName = FloeCADStrings.text("cad.scene.group", "Group"); showNewGroup = true
                }.disabled(document.isReadOnly)
                Spacer()
                Button(FloeCADStrings.text("cad.scene.refresh", "Refresh"), systemImage: "arrow.clockwise") { reload() }
            }
            .buttonStyle(.bordered).frame(minHeight: 44)
            if let message { Text(message).foregroundStyle(.red).font(.callout) }
            ForEach(Array(ordered.enumerated()), id: \.offset) { _, entry in
                objectRow(entry.row, depth: entry.depth)
            }
        }
        .disabled(busy)
        .onAppear { generation = UUID(); reload() }
        .onChange(of: document.session.changeCount) { _, _ in reload() }
        .onDisappear { generation = UUID(); operation?.cancel(); operation = nil; busy = false }
        .alert(FloeCADStrings.text("cad.scene.newGroup", "New group"), isPresented: $showNewGroup) {
            TextField(FloeCADStrings.text("cad.scene.name", "Name"), text: $groupName)
            Button(FloeCADStrings.text("cad.scene.cancel", "Cancel"), role: .cancel) {}
            Button(FloeCADStrings.text("cad.scene.create", "Create")) { run("object.createGroup", ["name": groupName]) }
        }
        .alert(FloeCADStrings.text("cad.scene.rename", "Rename"), isPresented: $showRename) {
            TextField(FloeCADStrings.text("cad.scene.name", "Name"), text: $groupName)
            Button(FloeCADStrings.text("cad.scene.cancel", "Cancel"), role: .cancel) {}
            Button(FloeCADStrings.text("cad.scene.apply", "Apply")) { if let id = renameID { run("object.rename", ["id": id, "name": groupName]) } }
        }
        .sheet(item: $editing) { target in
            CADSceneObjectTransformSheet(target: target) { pose, frame in
                run("object.transform", ["id": target.id, "frame": frame, "transform": CADSceneObjectCodec.transformJSON(pose), "expected_change_count": target.expectedChangeCount])
            }
        }
        .accessibilityIdentifier("CADSceneObjectsPanel")
    }

    private func objectRow(_ row: [String: Any], depth: Int) -> some View {
        let id = row["id"] as? String ?? "", kind = row["kind"] as? String ?? ""
        return HStack(spacing: 8) {
            Button {
                if let uuid = UUID(uuidString: id) {
                    if kind == "body" { viewModel.selectItemBody(BodyID(raw: uuid)) }
                    if kind == "assembly" { viewModel.selectedAssemblyInstances = [uuid] }
                }
            } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Label(row["name"] as? String ?? "", systemImage: icon(kind))
                    if row["available"] as? Bool == false {
                        Text(FloeCADStrings.text("cad.scene.unavailable", "Unavailable")).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }.buttonStyle(.plain)
            Menu {
                if let local = row["local"] as? [String: Any], let world = row["world"] as? [String: Any] {
                    Button(FloeCADStrings.text("cad.scene.editTransform", "Edit transform")) {
                        editing = SceneObjectEditorTarget(id: id, name: row["name"] as? String ?? "", local: local, world: world, expectedChangeCount: document.session.changeCount)
                    }
                }
                Button(FloeCADStrings.text("cad.scene.rename", "Rename")) {
                    renameID = id; groupName = row["name"] as? String ?? ""; showRename = true
                }
                Menu(FloeCADStrings.text("cad.scene.moveTo", "Move to")) {
                    Button(FloeCADStrings.text("cad.scene.root", "Scene root")) { run("object.reparent", ["id": id, "parent_id": NSNull(), "keep_world": true]) }
                    ForEach(groups.compactMap { $0["id"] as? String }.filter { $0 != id }, id: \.self) { groupID in
                        Button(groups.first { $0["id"] as? String == groupID }?["name"] as? String ?? "") {
                            run("object.reparent", ["id": id, "parent_id": groupID, "keep_world": true])
                        }
                    }
                }
                Button(FloeCADStrings.text("cad.scene.detach", "Detach / ungroup")) {
                    run("object.remove", ["id": id, "promote_children": true])
                }
            } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
            .disabled(document.isReadOnly)
        }
        .padding(.leading, CGFloat(min(depth, 12)) * 14)
        .accessibilityIdentifier("CADSceneObject-" + id)
    }

    private func icon(_ kind: String) -> String {
        switch kind {
        case "group": "folder"
        case "assembly": "square.3.layers.3d"
        case "light": "lightbulb"
        case "camera": "camera"
        default: "cube"
        }
    }

    private func reload() {
        guard !document.isClosed else { return }
        let reply = CADViewOverlayService(document: document).handle(action: "objects", args: [:])
        rows = reply["objects"] as? [[String: Any]] ?? []
        if reply["ok"] as? Bool != true { message = reply["message"] as? String }
    }

    private func run(_ action: String, _ payload: [String: Any]) {
        guard !busy, !document.isClosed else { return }
        busy = true; message = nil
        let owner = generation
        operation = Task { @MainActor in
            defer { if generation == owner { busy = false; operation = nil } }
            guard !Task.isCancelled, generation == owner, !document.isClosed else { return }
            var args = payload
            if args["expected_change_count"] == nil { args["expected_change_count"] = document.session.changeCount }
            let checkpoint = document.session.captureEditCheckpoint()
            let reply = CADViewOverlayService(document: document).handle(action: action, args: args)
            let changed = document.session.changeCount
            if reply["ok"] as? Bool != true {
                if generation == owner { message = reply["message"] as? String }; return
            }
            if reply["mutated"] as? Bool == true {
                if Task.isCancelled || generation != owner {
                    if !document.isClosed, document.session.changeCount == changed { document.session.restoreEditCheckpoint(checkpoint) }
                    return
                }
                let save = await document.save()
                // Save remains document-owned. Never roll back an intervening
                // edit or report a committed save as cancellation.
                if !save.succeeded {
                    if !document.isClosed, document.session.changeCount == changed { document.session.restoreEditCheckpoint(checkpoint) }
                    if generation == owner { message = save.error ?? FloeCADStrings.text("cad.scene.saveFailed", "The scene could not be saved.") }
                    return
                }
            }
            guard generation == owner, !document.isClosed else { return }
            reload()
        }
    }
}

private struct SceneObjectEditorTarget: Identifiable {
    let id: String
    let name: String
    let local: [String: Any]
    let world: [String: Any]
    let expectedChangeCount: Int
}

@MainActor
private struct CADSceneObjectTransformSheet: View {
    let target: SceneObjectEditorTarget
    let apply: (CADTransform, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var frame = "local"
    @State private var position = ["0", "0", "0"]
    @State private var axis = ["0", "1", "0"]
    @State private var degrees = "0"
    @State private var scale = "1"

    private var pose: CADTransform? {
        let p = position.compactMap(Double.init), a = axis.compactMap(Double.init)
        guard p.count == 3, a.count == 3, p.allSatisfy(\.isFinite), a.allSatisfy(\.isFinite),
              let angle = Double(degrees), angle.isFinite, let s = Double(scale), s.isFinite, s > 0,
              simd_length(SIMD3(a[0], a[1], a[2])) > 1e-12 else { return nil }
        let q = simd_quatd(angle: angle * .pi / 180, axis: simd_normalize(SIMD3(a[0], a[1], a[2])))
        return CADTransform(position: SIMD3(p[0], p[1], p[2]), rotation: q.vector, scale: SIMD3(repeating: s))
    }

    var body: some View {
        NavigationStack {
            Form {
                Picker(FloeCADStrings.text("cad.scene.frame", "Coordinates"), selection: $frame) {
                    Text(FloeCADStrings.text("cad.scene.local", "Local")).tag("local")
                    Text(FloeCADStrings.text("cad.scene.world", "World")).tag("world")
                }.pickerStyle(.segmented)
                Section(FloeCADStrings.text("cad.scene.position", "Position (mm)")) {
                    ForEach(0..<3, id: \.self) { i in TextField(["X", "Y", "Z"][i], text: $position[i]) }
                }
                Section(FloeCADStrings.text("cad.scene.rotation", "Rotation axis and degrees")) {
                    ForEach(0..<3, id: \.self) { i in TextField(["X", "Y", "Z"][i], text: $axis[i]) }
                    TextField(FloeCADStrings.text("cad.scene.degrees", "Degrees"), text: $degrees)
                }
                TextField(FloeCADStrings.text("cad.scene.scale", "Uniform scale"), text: $scale)
            }
            .onAppear { load() }.onChange(of: frame) { _, _ in load() }
            .navigationTitle(target.name)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(FloeCADStrings.text("cad.scene.cancel", "Cancel")) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(FloeCADStrings.text("cad.scene.apply", "Apply")) { if let pose { apply(pose, frame); dismiss() } }.disabled(pose == nil)
                }
            }
        }
        .accessibilityIdentifier("CADSceneObjectTransformSheet")
    }

    private func load() {
        let row = frame == "local" ? target.local : target.world
        if let p = row["position"] as? [Double], p.count == 3 { position = p.map { String($0) } }
        if let r = row["rotation"] as? [Double], r.count == 4 {
            let q = simd_normalize(simd_quatd(vector: SIMD4(r[0], r[1], r[2], r[3])))
            let direction = abs(q.angle) <= 1e-12 ? SIMD3(0.0, 1.0, 0.0) : q.axis
            axis = [direction.x, direction.y, direction.z].map { String($0) }; degrees = String(q.angle * 180 / .pi)
        }
        if let s = row["scale"] as? [Double], let value = s.first { scale = String(value) }
    }
}
#endif
