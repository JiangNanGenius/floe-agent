import SwiftUI
import FloeSimulationCore
import FloeSimulationPhysics
import FloeSimulationFields

struct ParticleSettings: View {
    @Binding var configuration: ParticleSimulationConfiguration
    var body: some View {
        Section(simulationText("Particle world","粒子场景")) {
            SimulationVectorFields(title:simulationText("Gravity","重力"),value:$configuration.gravity,unit:"m/s²")
            SimulationTimeFields(time:$configuration.time)
            TextField(simulationText("Random seed","随机种子"),value:$configuration.seed,format:.number)
        }
        Section(simulationText("Emitters","发射器")) {
            ForEach($configuration.emitters) { $emitter in
                DisclosureGroup(simulationText("Emitter","发射器")) {
                    SimulationVectorFields(title:simulationText("Origin","原点"),value:$emitter.origin,unit:"m")
                    SimulationVectorFields(title:simulationText("Emission half extents","发射范围半尺寸"),value:$emitter.halfExtents,unit:"m")
                    SimulationVectorFields(title:simulationText("Velocity","速度"),value:$emitter.velocity,unit:"m/s")
                    SimulationVectorFields(title:simulationText("Velocity spread","速度扰动"),value:$emitter.velocitySpread,unit:"m/s")
                    SimulationNumberField(label:simulationText("Start","开始"),value:$emitter.startSeconds,unit:"s")
                    SimulationNumberField(label:simulationText("End","结束"),value:$emitter.endSeconds,unit:"s")
                    SimulationNumberField(label:simulationText("Rate","发射速率"),value:$emitter.particlesPerSecond,unit:"1/s")
                    Stepper(simulationText("Burst","初始数量")+": \(emitter.burstCount)",value:$emitter.burstCount,in:0...4096)
                    SimulationNumberField(label:simulationText("Lifetime","寿命"),value:$emitter.lifetimeSeconds,unit:"s")
                    SimulationNumberField(label:simulationText("Mass","质量"),value:$emitter.massKg,unit:"kg")
                    SimulationNumberField(label:simulationText("Radius","半径"),value:$emitter.radiusMeters,unit:"m")
                    SimulationNumberField(label:simulationText("Drag","阻力"),value:$emitter.dragPerSecond,unit:"1/s")
                    Button(simulationText("Remove emitter","移除发射器"),role:.destructive) { configuration.emitters.removeAll { $0.id == emitter.id } }
                }
            }
            Button(simulationText("Add emitter","添加发射器")) { configuration.emitters.append(.init()) }
        }
        SimulationForceFieldSettings(fields:$configuration.forceFields)
    }
}
struct SimulationForceFieldSettings: View {
    @Binding var fields: [SimulationPhysicsForceField]
    var body: some View {
        Section(simulationText("Force fields","力场")) {
            ForEach($fields) { $field in
                DisclosureGroup(simulationOption(field.kind.rawValue)) {
                    SimulationChoicePicker(title:simulationText("Type","类型"),selection:$field.kind)
                    SimulationVectorFields(title:simulationText("Acceleration","加速度"),value:$field.acceleration,unit:"m/s²")
                    SimulationVectorFields(title:simulationText("Center","中心"),value:$field.center,unit:"m")
                    SimulationVectorFields(title:simulationText("Axis","轴向"),value:$field.axis)
                    SimulationNumberField(label:simulationText("Strength","强度"),value:$field.strength)
                    SimulationNumberField(label:simulationText("Core radius","核心半径"),value:$field.softeningRadiusMeters,unit:"m")
                    Toggle(simulationText("Affect soft bodies","影响柔体"),isOn:$field.affectsSoftBodies)
                    Button(simulationText("Remove field","移除力场"),role:.destructive) { fields.removeAll { $0.id == field.id } }
                }
            }
            Button(simulationText("Add field","添加力场")) { fields.append(.init()) }
        }
    }
}

struct CouplingSettings: View {
    @Bindable var model: SimulationWorkbenchModel
    @State private var mappingError: String?
    var body: some View {
        Section(simulationText("Participating studies","参与研究")) {
            if let configuration = model.coupling {
                let value = Binding(get:{ model.coupling ?? configuration },set:{ model.writeConfiguration($0) })
                Picker(simulationText("First study","研究一"),selection:value.firstStudyID) { ForEach(eligible) { Text($0.name).tag($0.id) } }
                Picker(simulationText("Second study","研究二"),selection:value.secondStudyID) { ForEach(eligible) { Text($0.name).tag($0.id) } }
                Picker(simulationText("First interface","界面一"),selection:value.firstBoundaryID) { ForEach(mesh(configuration.firstStudyID)?.boundaries ?? []) { Text($0.id).tag($0.id) } }
                Picker(simulationText("Second interface","界面二"),selection:value.secondBoundaryID) { ForEach(mesh(configuration.secondStudyID)?.boundaries ?? []) { Text($0.id).tag($0.id) } }
                SimulationNumberField(label:simulationText("Relaxation","松弛因子"),value:value.relaxation)
                SimulationNumberField(label:simulationText("Relative tolerance","相对误差"),value:value.relativeTolerance)
                Stepper(simulationText("Maximum iterations","最大迭代数")+": \(configuration.maximumIterations)",value:value.maximumIterations,in:1...1000)
                SimulationTimeFields(time:value.time)
                Button(simulationText("Build interface map","建立界面映射")) { build(configuration) }
                if !configuration.interface.rows.isEmpty { LabeledContent(simulationText("Mapped nodes","已映射节点"),value:"\(configuration.interface.rows.count)") }
            } else {
                Text(simulationText("Create two participating studies, then select their interfaces.","先创建两个参与研究，再选择各自的耦合界面。")).font(.callout)
                Button(simulationText("Configure coupling","配置耦合")) { initialize() }.disabled(eligible.count < 2)
            }
            if let mappingError { Text(mappingError).font(.caption).foregroundStyle(.red) }
        }
    }
    private var eligible: [SimulationStudy] { model.document.studies.filter { $0.id != model.selectedStudyID && ![SimulationStudyKind.conjugateHeatTransfer,.fluidStructure,.structuralAcoustics].contains($0.kind) } }
    private func mesh(_ id: UUID) -> SimulationMesh? { guard let study = model.document.studies.first(where:{ $0.id == id }) else { return nil }; return model.document.meshes.first { $0.id == study.meshID } }
    private func initialize() {
        guard eligible.count >= 2 else { return }
        let first = eligible[0], second = eligible[1], a = mesh(first.id), b = mesh(second.id)
        let kind: SimulationCouplingKind = model.selectedStudy?.kind == .fluidStructure ? .fluidStructure : model.selectedStudy?.kind == .structuralAcoustics ? .structuralAcoustics : .conjugateHeatTransfer
        var value = CoupledSimulationConfiguration(kind:kind,firstStudyID:first.id,secondStudyID:second.id,interface:.init(sourceMeshID:a?.id ?? UUID(),destinationMeshID:b?.id ?? UUID(),sourceNodeCount:a?.nodes.count ?? 0,rows:[]))
        value.firstBoundaryID = a?.boundaries.first?.id ?? ""; value.secondBoundaryID = b?.boundaries.first?.id ?? ""
        model.writeConfiguration(value)
    }
    private func build(_ configuration: CoupledSimulationConfiguration) {
        do {
            guard let first = mesh(configuration.firstStudyID), let second = mesh(configuration.secondStudyID) else { throw SimulationError.invalidInput(simulationText("Select the study meshes first.","请先选择参与研究的网格。")) }
            var value = configuration
            value.interface = try SimulationInterfaceMapBuilder.build(source:first,sourceBoundary:value.firstBoundaryID,destination:second,destinationBoundary:value.secondBoundaryID)
            model.writeConfiguration(value); mappingError = nil
        } catch { mappingError = error.localizedDescription }
    }
}
