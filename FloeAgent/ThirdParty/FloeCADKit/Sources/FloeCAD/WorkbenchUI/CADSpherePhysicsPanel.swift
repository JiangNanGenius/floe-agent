// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

@MainActor
struct CADSpherePhysicsPanel: View {
    let document: FloeCADDocument
    @State private var candidates: [[String: Any]] = []
    @State private var selected = Set<String>()
    @State private var radii: [String: String] = [:]
    @State private var duration = "2", gravity = "-9810", floor = "0", bounce = "0.7", mass = "1"
    @State private var vx = "0", vy = "0", vz = "0"
    @State private var state = "empty"
    @State private var remoteRunID: String?
    @State private var loadedDefinitionID: String?
    @State private var message: String?
    @State private var busy = false
    @State private var owner = UUID()
    @State private var operation: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(FloeCADStrings.text("cad.physics.scope", "Sphere collision proxies and one static ground plane. No friction or spin. Mass, restitution and velocity apply to all selected proxies."))
                .font(.callout).foregroundStyle(.secondary)
            if candidates.isEmpty {
                Text(FloeCADStrings.text("cad.physics.noInstances", "Add visible parts in Assembly before configuring their sphere proxies."))
            }
            ForEach(candidates.compactMap { $0["instance_id"] as? String }, id: \.self) { id in
                HStack {
                    Toggle(candidates.first { $0["instance_id"] as? String == id }?["name"] as? String ?? "",
                           isOn: Binding(get: { selected.contains(id) }, set: { value in
                        if value && selected.count < 16 { selected.insert(id) } else if !value { selected.remove(id) }
                    }))
                    TextField(FloeCADStrings.text("cad.physics.radius", "Radius (mm)"), text: Binding(
                        get: { radii[id] ?? "1" }, set: { radii[id] = $0 })).textFieldStyle(.roundedBorder).frame(width: 110)
                }.frame(minHeight: 44)
            }
            Group {
                input("cad.physics.duration", "Duration (s)", $duration)
                input("cad.physics.gravity", "Gravity Y (mm/s²)", $gravity)
                input("cad.physics.ground", "Ground Y (mm)", $floor)
                input("cad.physics.restitution", "Restitution (0–1)", $bounce)
                input("cad.physics.mass", "Mass (kg)", $mass)
                input("cad.physics.velocityX", "Initial velocity X (mm/s)", $vx)
                input("cad.physics.velocityY", "Initial velocity Y (mm/s)", $vy)
                input("cad.physics.velocityZ", "Initial velocity Z (mm/s)", $vz)
            }.disabled(busy || document.isReadOnly)
            HStack {
                Button(FloeCADStrings.text("cad.physics.configure", "Configure")) { configure() }.disabled(busy || selected.isEmpty || document.isReadOnly)
                Button(FloeCADStrings.text("cad.physics.simulate", "Simulate")) { run("physics.run", [:]) }.disabled(busy || state == "empty" || state == "stale" || document.isReadOnly)
                if busy || state == "running" {
                    ProgressView()
                    Button(FloeCADStrings.text("cad.physics.cancel", "Cancel")) {
                        if let operation { operation.cancel() }
                        else if let id = remoteRunID {
                            Task { @MainActor in
                                _ = await CADViewOverlayService(document: document).handleAsync(action: "physics.cancel", args: ["run_id": id])
                            }
                        }
                    }
                }
            }.buttonStyle(.bordered).frame(minHeight: 44)
            if let message { Text(message).font(.callout).foregroundStyle(.red) }
            if state == "ready" {
                Text(FloeCADStrings.text("cad.physics.ready", "Cache ready. Replay, frame capture and video export use the existing Present timeline."))
            }
            if state == "stale" { Text(FloeCADStrings.text("cad.physics.stale", "The source changed. Configure and simulate the proxies again.")) }
            Button(FloeCADStrings.text("cad.physics.clear", "Clear simulation")) { run("physics.clear", [:]) }.disabled(busy || document.isReadOnly || state == "empty")
        }
        .onAppear { owner = UUID(); reload() }
        .onChange(of: document.liveChangeCount) { _, _ in if !busy { reload() } }
        .onReceive(NotificationCenter.default.publisher(for: CADSpherePhysicsService.stateDidChange, object: document)) { _ in
            if !busy { reload() }
        }
        // The service-owned simulation/save continues after navigation. Only
        // explicit Cancel or document close cancels its joined worker.
        .onDisappear { owner = UUID(); operation = nil; busy = false }
        .accessibilityIdentifier("CADSpherePhysicsPanel")
    }

    private func input(_ key: String, _ fallback: String, _ value: Binding<String>) -> some View {
        HStack { Text(FloeCADStrings.text(key, fallback)); Spacer(); TextField("", text: value).textFieldStyle(.roundedBorder).frame(width: 130) }.frame(minHeight: 44)
    }
    private func reload() {
        guard !document.isClosed else { return }
        let reply = CADSpherePhysicsService(document: document).handleSync(action: "physics.get", args: [:])
        candidates = reply["candidates"] as? [[String: Any]] ?? []; state = reply["state"] as? String ?? "empty"
        remoteRunID = reply["run_id"] as? String
        let definitionID = reply["definition_id"] as? String
        if definitionID != loadedDefinitionID, let parameters = reply["parameters"] as? [String: Any] {
            loadedDefinitionID = definitionID
            func text(_ value: Any?, _ fallback: String) -> String { (value as? NSNumber).map { String($0.doubleValue) } ?? fallback }
            duration = text(parameters["duration"], duration); gravity = text(parameters["gravity_y"], gravity)
            floor = text(parameters["floor_y"], floor); bounce = text(parameters["floor_restitution"], bounce)
            let spheres = parameters["spheres"] as? [[String: Any]] ?? []
            selected = Set(spheres.compactMap { $0["instance_id"] as? String })
            for sphere in spheres {
                if let id = sphere["instance_id"] as? String { radii[id] = text(sphere["radius_mm"], "1") }
            }
            // The common controls explicitly apply to every selected proxy.
            // AI-authored per-proxy values remain in the saved definition
            // until the user deliberately presses Configure.
            if let first = spheres.first {
                mass = text(first["mass_kg"], mass)
                if let values = first["velocity_mm_s"] as? [Double], values.count == 3 {
                    vx = String(values[0]); vy = String(values[1]); vz = String(values[2])
                }
            }
        } else if definitionID == nil { loadedDefinitionID = nil }
        selected.formIntersection(Set(candidates.compactMap { $0["instance_id"] as? String }))
        for candidate in candidates {
            if let id = candidate["instance_id"] as? String, radii[id] == nil,
               let radius = candidate["radius_mm"] as? Double { radii[id] = String(radius) }
        }
        if reply["ok"] as? Bool != true { message = reply["message"] as? String }
    }
    private func configure() {
        let values = [duration, gravity, floor, bounce, mass, vx, vy, vz].compactMap(Double.init)
        guard values.count == 8, values.allSatisfy(\.isFinite) else { message = CADSpherePhysicsError.invalid.localizedDescription; return }
        var spheres: [[String: Any]] = []
        for id in selected.sorted() {
            guard let radius = radii[id].flatMap(Double.init), radius.isFinite else { message = CADSpherePhysicsError.invalid.localizedDescription; return }
            spheres.append(["instance_id": id, "radius_mm": radius, "mass_kg": values[4], "restitution": values[3], "velocity_mm_s": [values[5], values[6], values[7]]])
        }
        run("physics.configure", ["duration": values[0], "gravity_y": values[1], "floor_y": values[2], "floor_restitution": values[3], "spheres": spheres])
    }
    private func run(_ action: String, _ payload: [String: Any]) {
        guard !busy, !document.isClosed else { return }
        busy = true; message = nil; let generation = owner
        operation = Task { @MainActor in
            defer { if owner == generation { busy = false; operation = nil } }
            var args = payload; args["expected_change_count"] = document.liveChangeCount
            let reply = await CADViewOverlayService(document: document).handleAsync(action: action, args: args)
            if reply["ok"] as? Bool != true { if owner == generation { message = reply["message"] as? String }; return }
            if reply["mutated"] as? Bool == true {
                let command = document.pendingOwnedCommand
                if Task.isCancelled {
                    if let command { _ = document.rollbackOwnedCommand(command) }; return
                }
                let saved = await document.save()
                if !saved.succeeded {
                    if let command { _ = document.rollbackOwnedCommand(command) }
                    if owner == generation { message = saved.error }; return
                }
            }
            if owner == generation, !document.isClosed { reload() }
        }
    }
}
#endif
