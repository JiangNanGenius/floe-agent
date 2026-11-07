import SwiftUI
import FloeSimulationGeometry

struct SimulationMeshSettingsView: View {
    @Bindable var model: SimulationWorkbenchModel
    @State private var expanded = false
    var body: some View {
        DisclosureGroup(isExpanded:$expanded) {
            VStack(alignment:.leading,spacing:8) {
                sizeField(simulationText("Maximum size","最大尺寸"),path:\.maximumSizeMeters)
                sizeField(simulationText("Minimum size","最小尺寸"),path:\.minimumSizeMeters)
                Toggle(simulationText("Refine curved faces","曲面细化"),isOn:$model.meshSettings.curvatureRefinement)
                LabeledContent(simulationText("Growth rate","增长率")) { TextField("0.3",value:$model.meshSettings.growthRate,format:.number).frame(maxWidth:80) }
                ForEach(model.meshSettings.localSizes.keys.sorted(),id:\.self) { tag in
                    HStack {
                        Text(tag).font(.caption).lineLimit(1)
                        TextField("mm",value:Binding(get:{ (model.meshSettings.localSizes[tag] ?? 0)*1000 },set:{ model.meshSettings.localSizes[tag] = $0/1000 }),format:.number).frame(maxWidth:70)
                        Text("mm").font(.caption).foregroundStyle(.secondary)
                        Button { model.meshSettings.localSizes.removeValue(forKey:tag) } label: { Image(systemName:"minus.circle") }.accessibilityLabel(simulationText("Remove local size","移除局部尺寸"))
                    }
                }
                if let mesh = model.activeMesh, !mesh.boundaries.isEmpty {
                    Menu(simulationText("Refine a face","细化面")) {
                        ForEach(mesh.boundaries) { boundary in
                            Button(boundary.id) { model.meshSettings.localSizes[boundary.sourceEntityID] = max(model.meshSettings.minimumSizeMeters,model.meshSettings.maximumSizeMeters/2) }
                        }
                    }
                }
                Button(simulationText("Generate mesh","生成网格")) { Task { await model.generateMesh() } }
                    .disabled(model.meshing?.isAvailable != true || model.meshJobs.contains { !$0.status.isTerminal })
                    .accessibilityIdentifier("simulation.mesh.generate")
                if let mesh = model.activeMesh { Text(simulationText("Nodes","节点")+": \(mesh.nodes.count) · "+simulationText("Elements","单元")+": \(mesh.elements.count)").font(.caption).foregroundStyle(.secondary) }
            }.padding(.vertical,8).textFieldStyle(.roundedBorder)
        } label: { Label(simulationText("Mesh","网格"),systemImage:"square.3.layers.3d") }
        .padding(.horizontal).accessibilityIdentifier("simulation.mesh.settings")
    }
    private func sizeField(_ label: String, path: WritableKeyPath<SimulationMeshSettings,Double>) -> some View {
        LabeledContent(label) {
            TextField("mm",value:Binding(get:{ model.meshSettings[keyPath:path]*1000 },set:{ model.meshSettings[keyPath:path] = $0/1000 }),format:.number).frame(maxWidth:80)
            Text("mm").font(.caption).foregroundStyle(.secondary)
        }
    }
}
