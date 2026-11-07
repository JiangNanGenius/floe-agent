import SwiftUI
import FloeSimulationCore
import FloeSimulationEngineering
import FloeSimulationPhysics
import FloeSimulationFields
import FloeSimulationRuntime

struct SimulationStudySettingsView: View {
    @Bindable var model: SimulationWorkbenchModel
    var kind: SimulationStudyKind
    var body: some View {
        Form {
            Section(simulationText("Study","研究")) {
                TextField(simulationText("Name","名称"),text:Binding(get:{ model.selectedStudy?.name ?? "" },set:{ model.renameStudy($0) }))
                if let mesh = model.activeMesh { LabeledContent(simulationText("Mesh","网格"),value:"\(mesh.nodes.count) / \(mesh.elements.count)") }
            }
            switch kind {
            case .rigidBody,.skeletalPhysics,.cloth,.rope,.softBody:
                PhysicsSettings(configuration:Binding(get:{ model.physics },set:{ model.writeConfiguration($0) }),names:Dictionary(uniqueKeysWithValues:model.sourceObjects.map { ($0.id,$0.name) }))
            case .structuralStatic,.beamShell,.laminate,.modal,.buckling,.nonlinearContact,.thermalSteady,.thermalTransient,.thermalStress:
                EngineeringSettings(configuration:Binding(get:{ model.engineering },set:{ model.writeConfiguration($0) }),kind:kind,mesh:model.activeMesh,results:model.savedResults)
            case .incompressibleFlow,.compressibleFlow,.turbulentFlow:
                FlowSettings(configuration:Binding(get:{ model.flow },set:{ model.writeConfiguration($0) }),mesh:model.activeMesh)
            case .pressureAcoustics:
                AcousticSettings(configuration:Binding(get:{ model.acoustics },set:{ model.writeConfiguration($0) }),mesh:model.activeMesh)
            case .electrostatic,.magnetostatic,.eddyCurrent,.radioFrequency,.electromagneticModes,.antenna:
                EMSettings(configuration:Binding(get:{ model.electromagnetics },set:{ model.writeConfiguration($0) }),mesh:model.activeMesh,kind:kind)
            case .particles:
                ParticleSettings(configuration:Binding(get:{ model.particles },set:{ model.writeConfiguration($0) }))
            case .conjugateHeatTransfer,.fluidStructure,.structuralAcoustics:
                CouplingSettings(model:model)
            }
            if ![SimulationStudyKind.rigidBody,.skeletalPhysics,.cloth,.rope,.softBody,.particles].contains(kind) { materialSections }
        }
    }
    @ViewBuilder private var materialSections: some View {
        Section(simulationText("Materials","材料")) {
            ForEach(model.document.materials) { material in
                DisclosureGroup(material.name) {
                    SimulationMaterialSettings(material:Binding(get:{ model.document.materials.first { $0.id == material.id } ?? material },set:{ model.updateMaterial($0) }),materials:model.document.materials)
                }
            }
            Button(simulationText("Add material","添加材料")) { model.updateMaterial(.init(name:simulationText("New material","新材料"),properties:SimulationStudyDefaults.materialProperties(kind).values)) }
        }
        if let mesh = model.activeMesh {
            Section(simulationText("Region assignments","区域材料")) {
                ForEach(Set(mesh.elements.map(\.regionID)).sorted(),id:\.self) { region in
                    Picker(region,selection:Binding(get:{ model.selectedStudy?.materialAssignments[region] },set:{ if let id = $0 { model.assignMaterial(id,regionID:region) } })) {
                        Text(simulationText("Choose material","选择材料")).tag(Optional<UUID>.none)
                        ForEach(model.document.materials) { Text($0.name).tag(Optional($0.id)) }
                    }
                }
            }
        }
    }
}

struct SimulationNumberField: View {
    var label: String
    @Binding var value: Double
    var unit: String = ""
    var body: some View { LabeledContent(label) { HStack { TextField(label,value:$value,format:.number.precision(.significantDigits(1...10))).multilineTextAlignment(.trailing).frame(minWidth:64); if !unit.isEmpty { Text(unit).foregroundStyle(.secondary).font(.caption) } }.frame(minHeight:36) } }
}
struct SimulationVectorFields: View {
    var title: String
    @Binding var value: SimulationVector3
    var unit: String = ""
    var body: some View {
        DisclosureGroup(title) { SimulationNumberField(label:"X",value:$value.x,unit:unit); SimulationNumberField(label:"Y",value:$value.y,unit:unit); SimulationNumberField(label:"Z",value:$value.z,unit:unit) }
    }
}
struct SimulationChoicePicker<Choice: RawRepresentable & Hashable & CaseIterable>: View where Choice.RawValue == String {
    var title: String
    @Binding var selection: Choice
    var body: some View { Picker(title,selection:$selection) { ForEach(Array(Choice.allCases),id:\.self) { Text(simulationOption($0.rawValue)).tag($0) } } }
}
struct SimulationBoundaryPicker: View {
    var title: String
    @Binding var selection: SimulationSelection
    var mesh: SimulationMesh?
    var body: some View {
        Picker(title,selection:Binding(get:{ if case .boundary(let id) = selection { return id }; return "" },set:{ selection = .boundary($0) })) {
            Text(simulationText("Selected nodes","已选节点")).tag("")
            ForEach(mesh?.boundaries ?? []) { Text($0.id).tag($0.id) }
        }
    }
}
private struct SimulationBoundaryIDPicker: View {
    @Binding var id: String
    var mesh: SimulationMesh?
    var excluding: Set<String> = []
    var body: some View { Picker(simulationText("Boundary","边界"),selection:$id) { ForEach((mesh?.boundaries ?? []).filter { !excluding.contains($0.id) }) { Text($0.id).tag($0.id) } } }
}
struct SimulationTimeFields: View {
    @Binding var time: SimulationTimeSettings
    var body: some View {
        SimulationNumberField(label:simulationText("Duration","时长"),value:$time.durationSeconds,unit:"s")
        SimulationNumberField(label:simulationText("Time step","时间步长"),value:$time.stepSeconds,unit:"s")
        SimulationNumberField(label:simulationText("Output interval","输出间隔"),value:$time.outputIntervalSeconds,unit:"s")
    }
}

private struct PhysicsSettings: View {
    @Binding var configuration: PhysicsSimulationConfiguration
    var names: [String:String] = [:]
    var body: some View {
        Section(simulationText("World","场景")) { SimulationVectorFields(title:simulationText("Gravity","重力"),value:$configuration.gravity,unit:"m/s²"); SimulationTimeFields(time:$configuration.time) }
        SimulationForceFieldSettings(fields:$configuration.forceFields)
        Section(simulationText("Bodies","物体")) {
            ForEach($configuration.bodies) { $body in
                DisclosureGroup(names[body.sourceObjectID] ?? body.sourceObjectID) {
                    if let name = names[body.sourceObjectID] { LabeledContent(simulationText("Object","对象"),value:name) }
                    else { TextField(simulationText("Name","名称"),text:$body.sourceObjectID) }
                    SimulationChoicePicker(title:simulationText("Motion","运动模式"),selection:$body.motion)
                    SimulationChoicePicker(title:simulationText("Collider","碰撞形体"),selection:$body.collider.kind)
                    SimulationVectorFields(title:simulationText("Position","位置"),value:$body.translation,unit:"m")
                    SimulationVectorFields(title:simulationText("Velocity","速度"),value:$body.velocity,unit:"m/s")
                    SimulationVectorFields(title:simulationText("Angular velocity","角速度"),value:$body.angularVelocity,unit:"rad/s")
                    if body.collider.kind == .box { SimulationVectorFields(title:simulationText("Half extents","半尺寸"),value:$body.collider.halfExtents,unit:"m") }
                    if [.sphere,.capsule].contains(body.collider.kind) { SimulationNumberField(label:simulationText("Radius","半径"),value:$body.collider.radius,unit:"m") }
                    if body.collider.kind == .capsule { SimulationNumberField(label:simulationText("Half height","半高度"),value:$body.collider.halfHeight,unit:"m") }
                    SimulationNumberField(label:simulationText("Mass","质量"),value:$body.massKg,unit:"kg")
                    Toggle(simulationText("Custom inertia","自定义惯量"),isOn:Binding(get:{ body.principalInertiaKgSquareMeters != nil },set:{ body.principalInertiaKgSquareMeters = $0 ? .init(1,1,1) : nil; if !$0 { body.centerOfMassMeters = .zero } }))
                    if let inertia = body.principalInertiaKgSquareMeters {
                        SimulationVectorFields(title:simulationText("Center of mass","质心"),value:$body.centerOfMassMeters,unit:"m")
                        SimulationVectorFields(title:simulationText("Principal inertia","主惯量"),value:Binding(get:{ body.principalInertiaKgSquareMeters ?? inertia },set:{ body.principalInertiaKgSquareMeters = $0 }),unit:"kg·m²")
                    }
                    SimulationNumberField(label:simulationText("Friction","摩擦系数"),value:$body.friction)
                    SimulationNumberField(label:simulationText("Restitution","恢复系数"),value:$body.restitution)
                    SimulationNumberField(label:simulationText("Linear damping","线性阻尼"),value:$body.linearDamping)
                    SimulationNumberField(label:simulationText("Angular damping","角阻尼"),value:$body.angularDamping)
                    Button(simulationText("Remove body","移除物体"),role:.destructive) { configuration.bodies.removeAll { $0.id == body.id } }
                }
            }
            Button(simulationText("Add box","添加立方体")) { configuration.bodies.append(.init(sourceObjectID:"body-\(configuration.bodies.count+1)")) }
        }
        Section(simulationText("Joints and drives","关节与驱动")) {
            ForEach($configuration.joints) { $joint in
                DisclosureGroup(simulationOption(joint.kind.rawValue)) {
                    SimulationChoicePicker(title:simulationText("Type","类型"),selection:$joint.kind)
                    Picker(simulationText("First body","物体一"),selection:$joint.firstBody) { ForEach(configuration.bodies) { Text(names[$0.sourceObjectID] ?? $0.sourceObjectID).tag($0.id) } }
                    Picker(simulationText("Second body","物体二"),selection:$joint.secondBody) { ForEach(configuration.bodies) { Text(names[$0.sourceObjectID] ?? $0.sourceObjectID).tag($0.id) } }
                    SimulationVectorFields(title:simulationText("First anchor","锚点一"),value:$joint.firstAnchor,unit:"m")
                    SimulationVectorFields(title:simulationText("Second anchor","锚点二"),value:$joint.secondAnchor,unit:"m")
                    SimulationVectorFields(title:simulationText("Axis","轴向"),value:$joint.axis)
                    SimulationNumberField(label:simulationText("Motor speed","驱动速度"),value:$joint.motorVelocity)
                    SimulationNumberField(label:simulationText("Maximum drive","最大驱动力"),value:$joint.motorForce)
                    if joint.kind == .revolute || joint.kind == .prismatic {
                        Toggle(simulationText("Joint limits","关节限位"),isOn:Binding(get:{ joint.limits.count == 2 },set:{ joint.limits = $0 ? [-1,1] : [] }))
                        if joint.limits.count == 2 {
                            SimulationNumberField(label:simulationText("Lower limit","下限"),value:$joint.limits[0],unit:joint.kind == .revolute ? "rad" : "m")
                            SimulationNumberField(label:simulationText("Upper limit","上限"),value:$joint.limits[1],unit:joint.kind == .revolute ? "rad" : "m")
                        }
                    }
                    SimulationNumberField(label:simulationText("Rest length","原长"),value:$joint.restLengthMeters,unit:"m")
                    SimulationNumberField(label:simulationText("Stiffness","刚度"),value:$joint.stiffness)
                    SimulationNumberField(label:simulationText("Damping","阻尼"),value:$joint.damping)
                    Button(simulationText("Remove joint","移除关节"),role:.destructive) { configuration.joints.removeAll { $0.id == joint.id } }
                }
            }
            Button(simulationText("Add joint","添加关节")) { if configuration.bodies.count >= 2 { configuration.joints.append(.init(kind:.revolute,firstBody:configuration.bodies[0].id,secondBody:configuration.bodies[1].id)) } }.disabled(configuration.bodies.count < 2)
        }
        Section(simulationText("Cloth, ropes and soft bodies","布料、绳索与软体")) {
            ForEach($configuration.softBodies) { $soft in
                DisclosureGroup(soft.sourceObjectID) {
                    SimulationChoicePicker(title:simulationText("Type","类型"),selection:$soft.kind)
                    SimulationVectorFields(title:simulationText("Origin","原点"),value:$soft.origin,unit:"m")
                    SimulationVectorFields(title:simulationText("End","终点"),value:$soft.end,unit:"m")
                    SimulationVectorFields(title:simulationText("First lattice direction","网格方向一"),value:$soft.du,unit:"m")
                    SimulationVectorFields(title:simulationText("Second lattice direction","网格方向二"),value:$soft.dv,unit:"m")
                    SimulationVectorFields(title:simulationText("Half extents","半尺寸"),value:$soft.halfExtents,unit:"m")
                    ForEach(0..<min(3,soft.dimensions.count),id:\.self) { axis in Stepper("\(axis+1): \(soft.dimensions[axis])",value:$soft.dimensions[axis],in:2...64) }
                    TextField(simulationText("Pinned point indices","固定点编号"),text:Binding(get:{ soft.pinnedIndices.map(String.init).joined(separator:",") },set:{ soft.pinnedIndices = $0.split(separator:",").compactMap { UInt32($0.trimmingCharacters(in:.whitespaces)) } }))
                    SimulationNumberField(label:simulationText("Particle mass","质点质量"),value:$soft.particleMassKg,unit:"kg")
                    SimulationNumberField(label:simulationText("Thickness radius","厚度半径"),value:$soft.particleRadiusMeters,unit:"m")
                    SimulationNumberField(label:simulationText("Natural frequency","固有频率"),value:$soft.naturalFrequencyHz,unit:"Hz")
                    SimulationNumberField(label:simulationText("Damping ratio","阻尼比"),value:$soft.dampingRatio)
                    Toggle(simulationText("Self collision","自碰撞"),isOn:$soft.selfCollision)
                    Button(simulationText("Remove soft body","移除柔体"),role:.destructive) { configuration.softBodies.removeAll { $0.id == soft.id } }
                }
            }
            Menu(simulationText("Add deformable body","添加柔体")) { ForEach(SimulationSoftBodyKind.allCases,id:\.self) { kind in Button(simulationOption(kind.rawValue)) { configuration.softBodies.append(.init(sourceObjectID:"soft-\(configuration.softBodies.count+1)",kind:kind)) } } }
        }
    }
}

private struct EngineeringSettings: View {
    @Binding var configuration: EngineeringSimulationConfiguration
    var kind: SimulationStudyKind
    var mesh: SimulationMesh?
    var results: [SimulationSavedResult]
    private var thermalOnly: Bool { kind == .thermalSteady || kind == .thermalTransient }
    var body: some View {
        if !thermalOnly {
        Section(simulationText("Model","模型")) {
            SimulationChoicePicker(title:simulationText("Material law","材料模型"),selection:$configuration.materialModel)
            if kind == .nonlinearContact {
                Toggle(simulationText("Large deformation","大变形"),isOn:$configuration.largeDeformation)
                Stepper(simulationText("Load steps","载荷步")+": \(configuration.loadSteps)",value:$configuration.loadSteps,in:1...1000)
            }
            if kind == .modal || kind == .buckling { Stepper(simulationText("Modes","模态数")+": \(configuration.requestedModes)",value:$configuration.requestedModes,in:1...100) }
            if kind == .buckling {
                Picker(simulationText("Preloaded result","预载结果"),selection:$configuration.preloadedResultID) {
                    Text(simulationText("Choose result","选择结果")).tag(Optional<UUID>.none)
                    ForEach(results.filter { [.structuralStatic,.nonlinearContact,.thermalStress].contains($0.kind) }) { Text($0.name).tag(Optional($0.id)) }
                }
            }
            if kind == .thermalStress {
                Picker(simulationText("Temperature result","温度结果"),selection:$configuration.temperatureResultID) {
                    Text(simulationText("Choose result","选择结果")).tag(Optional<UUID>.none)
                    ForEach(results.filter { [.thermalSteady,.thermalTransient].contains($0.kind) }) { Text($0.name).tag(Optional($0.id)) }
                }
                SimulationNumberField(label:simulationText("Stress-free temperature","无应力温度"),value:$configuration.referenceTemperatureKelvin,unit:"K")
            }
            SimulationNumberField(label:simulationText("Relative tolerance","相对误差"),value:$configuration.relativeTolerance)
        }
        Section(simulationText("Supports","支撑")) {
            ForEach($configuration.constraints) { $constraint in
                DisclosureGroup(simulationText("Displacement","位移约束")) {
                    SimulationBoundaryPicker(title:simulationText("Selection","选区"),selection:$constraint.selection,mesh:mesh)
                    ForEach(0..<min(3,constraint.fixedAxes.count),id:\.self) { axis in Toggle(["X","Y","Z"][axis],isOn:$constraint.fixedAxes[axis]) }
                    SimulationVectorFields(title:simulationText("Prescribed displacement","给定位移"),value:$constraint.displacementMeters,unit:"m")
                    Button(simulationText("Remove support","移除支撑"),role:.destructive) { configuration.constraints.removeAll { $0.id == constraint.id } }
                }
            }
            Button(simulationText("Add support","添加支撑")) { if let id = mesh?.boundaries.first?.id { configuration.constraints.append(.init(selection:.boundary(id))) } }.disabled(mesh?.boundaries.isEmpty != false)
        }
        if kind != .modal && kind != .buckling {
        Section(simulationText("Loads","载荷")) {
            ForEach($configuration.forces) { $force in
                SimulationBoundaryPicker(title:simulationText("Selection","选区"),selection:$force.selection,mesh:mesh)
                SimulationVectorFields(title:simulationText("Total force","总力"),value:$force.value,unit:"N")
                Button(simulationText("Remove force","移除力"),role:.destructive) { configuration.forces.removeAll { $0.id == force.id } }
            }
            ForEach($configuration.pressures) { $pressure in
                SimulationBoundaryPicker(title:simulationText("Selection","选区"),selection:$pressure.selection,mesh:mesh)
                SimulationNumberField(label:simulationText("Pressure inward","向内压力"),value:$pressure.value,unit:"Pa")
                Button(simulationText("Remove pressure","移除压力"),role:.destructive) { configuration.pressures.removeAll { $0.id == pressure.id } }
            }
            SimulationVectorFields(title:simulationText("Body force density","体积力"),value:$configuration.bodyForceNewtonsPerCubicMeter,unit:"N/m³")
            HStack {
                Button(simulationText("Add force","添加力")) { if let id = mesh?.boundaries.last?.id { configuration.forces.append(.init(selection:.boundary(id),value:.init(0,-1,0))) } }
                Button(simulationText("Add pressure","添加压力")) { if let id = mesh?.boundaries.last?.id { configuration.pressures.append(.init(selection:.boundary(id),value:1000)) } }
            }.disabled(mesh?.boundaries.isEmpty != false)
        }
        }
        if kind == .beamShell || kind == .laminate { SimulationSectionSettings(configuration:$configuration,mesh:mesh) }
        if kind == .nonlinearContact { SimulationContactSettings(configuration:$configuration,mesh:mesh) }
        }
        if thermalOnly {
        Section(simulationText("Thermal conditions","热条件")) {
            ForEach($configuration.fixedTemperatures) { $temperature in
                SimulationBoundaryPicker(title:simulationText("Selection","选区"),selection:$temperature.selection,mesh:mesh)
                SimulationNumberField(label:simulationText("Temperature","温度"),value:$temperature.value,unit:"K")
                Button(simulationText("Remove temperature","移除温度"),role:.destructive) { configuration.fixedTemperatures.removeAll { $0.id == temperature.id } }
            }
            ForEach($configuration.faceHeatFluxes) { $flux in
                SimulationBoundaryPicker(title:simulationText("Selection","选区"),selection:$flux.selection,mesh:mesh)
                SimulationNumberField(label:simulationText("Outward heat flux","向外热流"),value:$flux.value,unit:"W/m²")
                Button(simulationText("Remove heat flux","移除热流"),role:.destructive) { configuration.faceHeatFluxes.removeAll { $0.id == flux.id } }
            }
            Button(simulationText("Add temperature","添加温度")) { if let id = mesh?.boundaries.first?.id { configuration.fixedTemperatures.append(.init(selection:.boundary(id),value:293.15)) } }.disabled(mesh?.boundaries.isEmpty != false)
            Button(simulationText("Add heat flux","添加热流")) { if let id = mesh?.boundaries.last?.id { configuration.faceHeatFluxes.append(.init(selection:.boundary(id),value:100)) } }.disabled(mesh?.boundaries.isEmpty != false)
            if kind == .thermalTransient {
                SimulationNumberField(label:simulationText("Initial temperature","初始温度"),value:$configuration.initialTemperatureKelvin,unit:"K")
                SimulationTimeFields(time:$configuration.time)
            }
            ForEach(Set(mesh?.elements.map(\.regionID) ?? []).sorted(),id:\.self) { region in
                SimulationNumberField(label:simulationText("Heat source","体积热源")+" · "+region,value:Binding(get:{ configuration.volumeHeatSourcesWPerCubicMeter[region] ?? 0 },set:{ configuration.volumeHeatSourcesWPerCubicMeter[region] = $0 }),unit:"W/m³")
            }
        }
        }
    }
}

private struct FlowSettings: View {
    @Binding var configuration: FlowSimulationConfiguration
    var mesh: SimulationMesh?
    var body: some View {
        Section(simulationText("Flow","流动")) {
            SimulationChoicePicker(title:simulationText("Regime","流动类型"),selection:$configuration.regime)
            SimulationChoicePicker(title:simulationText("Turbulence","湍流模型"),selection:$configuration.turbulence)
            SimulationVectorFields(title:simulationText("Freestream velocity","来流速度"),value:$configuration.freestreamVelocity,unit:"m/s")
            SimulationNumberField(label:simulationText("Freestream pressure","来流压力"),value:$configuration.freestreamPressurePascal,unit:"Pa")
            SimulationNumberField(label:simulationText("Freestream temperature","来流温度"),value:$configuration.freestreamTemperatureKelvin,unit:"K")
            SimulationNumberField(label:simulationText("Mach number","马赫数"),value:$configuration.machNumber)
            SimulationNumberField(label:simulationText("Reynolds number","雷诺数"),value:$configuration.reynoldsNumber)
            SimulationNumberField(label:simulationText("Turbulence intensity","湍流强度"),value:$configuration.turbulenceIntensity)
            SimulationNumberField(label:"CFL",value:$configuration.cfl)
            Toggle(simulationText("Transient","瞬态"),isOn:$configuration.transient)
            if configuration.transient { SimulationTimeFields(time:$configuration.time) }
        }
        Section(simulationText("Flow boundaries","流动边界")) {
            ForEach($configuration.boundaries) { $boundary in
                DisclosureGroup(boundary.boundaryID) {
                    SimulationBoundaryIDPicker(id:$boundary.boundaryID,mesh:mesh)
                    SimulationChoicePicker(title:simulationText("Condition","条件"),selection:$boundary.kind)
                    SimulationVectorFields(title:simulationText("Velocity","速度"),value:$boundary.velocityMetersPerSecond,unit:"m/s")
                    SimulationNumberField(label:simulationText("Pressure","压力"),value:$boundary.pressurePascal,unit:"Pa")
                    SimulationNumberField(label:simulationText("Temperature","温度"),value:$boundary.temperatureKelvin,unit:"K")
                    Toggle(simulationText("No slip","无滑移"),isOn:$boundary.noSlip)
                    Button(simulationText("Remove boundary","移除边界"),role:.destructive) { configuration.boundaries.removeAll { $0.id == boundary.id } }
                }
            }
            Button(simulationText("Add remaining walls","添加其余壁面")) { for boundary in mesh?.boundaries ?? [] where !configuration.boundaries.contains(where:{ $0.boundaryID == boundary.id }) { configuration.boundaries.append(.init(boundaryID:boundary.id,kind:.wall)) } }
        }
    }
}

private struct AcousticSettings: View {
    @Binding var configuration: AcousticSimulationConfiguration
    var mesh: SimulationMesh?
    private func binding(_ value: SimulationAcousticBoundary) -> Binding<SimulationAcousticBoundary> {
        .init(get:{ configuration.boundaries.first { $0.boundaryID == value.boundaryID } ?? value },set:{ updated in
            if let index = configuration.boundaries.firstIndex(where:{ $0.boundaryID == value.boundaryID }) { configuration.boundaries[index] = updated }
        })
    }
    var body: some View {
        Section(simulationText("Acoustics","声学")) {
            SimulationNumberField(label:simulationText("Density","密度"),value:$configuration.densityKgPerCubicMeter,unit:"kg/m³")
            SimulationNumberField(label:simulationText("Sound speed","声速"),value:$configuration.soundSpeedMetersPerSecond,unit:"m/s")
            SimulationNumberField(label:simulationText("Loss factor","损耗因子"),value:$configuration.lossFactor)
            SimulationNumberField(label:simulationText("Reference pressure","参考声压"),value:$configuration.referencePressurePascal,unit:"Pa")
            FrequencyFields(sweep:$configuration.frequencies)
            Stepper(simulationText("Element order","单元阶数")+": \(configuration.finiteElementOrder)",value:$configuration.finiteElementOrder,in:1...3)
        }
        Section(simulationText("Acoustic boundaries","声学边界")) {
            ForEach(configuration.boundaries,id:\.boundaryID) { boundary in
                let binding = self.binding(boundary)
                DisclosureGroup(boundary.boundaryID) {
                    SimulationBoundaryIDPicker(id:binding.boundaryID,mesh:mesh,excluding:Set(configuration.boundaries.map(\.boundaryID)).subtracting([boundary.boundaryID]))
                    SimulationChoicePicker(title:simulationText("Condition","条件"),selection:binding.kind)
                        .onChange(of:boundary.kind) { _,kind in if [.rigidWall,.radiation].contains(kind) { binding.value.wrappedValue = .init() } }
                    if [.pressure,.normalVelocity,.impedance].contains(boundary.kind) {
                        let unit = boundary.kind == .pressure ? "Pa" : boundary.kind == .normalVelocity ? "m/s" : "Pa·s/m"
                        SimulationNumberField(label:simulationText("Real amplitude","实部幅值"),value:binding.value.real,unit:unit)
                        SimulationNumberField(label:simulationText("Imaginary amplitude","虚部幅值"),value:binding.value.imaginary,unit:unit)
                    } else if boundary.value.magnitude != 0 {
                        Button(simulationText("Clear imposed amplitude","清除外加幅值")) { binding.value.wrappedValue = .init() }
                    }
                    Button(simulationText("Remove boundary","移除边界"),role:.destructive) { configuration.boundaries.removeAll { $0.boundaryID == boundary.boundaryID } }
                }
            }
            Button(simulationText("Add boundary","添加边界")) { if let boundary = mesh?.boundaries.first(where:{ boundary in !configuration.boundaries.contains { $0.boundaryID == boundary.id } }) { configuration.boundaries.append(.init(boundaryID:boundary.id,kind:.rigidWall)) } }
        }
    }
}
private struct FrequencyFields: View {
    @Binding var sweep: SimulationFrequencySweep
    var body: some View {
        TextField(simulationText("Frequencies in Hz, separated by commas","频率 Hz，以逗号分隔"),text:Binding(get:{ sweep.frequenciesHz.map { String(format:"%.9g",$0) }.joined(separator:", ") },set:{ sweep.frequenciesHz = $0.split(separator:",").compactMap { Double($0.trimmingCharacters(in:.whitespaces)) } }))
    }
}
private struct EMSettings: View {
    @Binding var configuration: ElectromagneticSimulationConfiguration
    var mesh: SimulationMesh?
    var kind: SimulationStudyKind
    private func binding(_ value: SimulationEMBoundary) -> Binding<SimulationEMBoundary> {
        .init(get:{ configuration.boundaries.first { $0.boundaryID == value.boundaryID } ?? value },set:{ updated in
            if let index = configuration.boundaries.firstIndex(where:{ $0.boundaryID == value.boundaryID }) { configuration.boundaries[index] = updated }
        })
    }
    var body: some View {
        Section(simulationText("Electromagnetics","电磁")) {
            if [.eddyCurrent,.radioFrequency,.electromagneticModes,.antenna].contains(kind) { FrequencyFields(sweep:$configuration.frequencies) }
            Stepper(simulationText("Element order","单元阶数")+": \(configuration.finiteElementOrder)",value:$configuration.finiteElementOrder,in:1...(kind == .electrostatic ? 3 : 6))
            if kind == .electromagneticModes { Stepper(simulationText("Modes","模态数")+": \(configuration.requestedModes)",value:$configuration.requestedModes,in:1...100) }
            SimulationNumberField(label:simulationText("Relative tolerance","相对误差"),value:$configuration.relativeTolerance)
        }
        Section(simulationText("Boundaries","边界")) {
            ForEach(configuration.boundaries,id:\.boundaryID) { boundary in
                let binding = self.binding(boundary)
                SimulationBoundaryIDPicker(id:binding.boundaryID,mesh:mesh,excluding:Set(configuration.boundaries.map(\.boundaryID)).subtracting([boundary.boundaryID]))
                if kind == .electrostatic {
                    Picker(simulationText("Condition","条件"),selection:binding.kind) {
                        Text(simulationText("Ground","接地")).tag(SimulationEMBoundaryKind.perfectElectric)
                        Text(simulationText("Potential","电势")).tag(SimulationEMBoundaryKind.electricPotential)
                        Text(simulationText("Insulated","绝缘")).tag(SimulationEMBoundaryKind.perfectMagnetic)
                    }
                    .onChange(of:boundary.kind) { _,kind in if kind != .electricPotential { binding.value.wrappedValue = .init() } }
                    if boundary.kind == .electricPotential { SimulationNumberField(label:simulationText("Potential","电势"),value:binding.value.real,unit:"V") }
                    else if boundary.value.magnitude != 0 { Button(simulationText("Reset boundary value","重置边界值")) { binding.value.wrappedValue = .init() } }
                } else {
                    SimulationChoicePicker(title:simulationText("Condition","条件"),selection:binding.kind)
                    SimulationNumberField(label:simulationText("Real part","实部"),value:binding.value.real)
                    SimulationNumberField(label:simulationText("Imaginary part","虚部"),value:binding.value.imaginary)
                }
                Button(simulationText("Remove boundary","移除边界"),role:.destructive) { configuration.boundaries.removeAll { $0.boundaryID == boundary.boundaryID } }
            }
            Button(simulationText("Add boundary","添加边界")) { if let boundary = mesh?.boundaries.first(where:{ boundary in !configuration.boundaries.contains { $0.boundaryID == boundary.id } }) { configuration.boundaries.append(.init(boundaryID:boundary.id,kind:.perfectElectric)) } }
        }
        if kind == .radioFrequency || kind == .antenna { Section(simulationText("RF ports","射频端口")) {
            ForEach($configuration.ports) { $port in
                DisclosureGroup(simulationText("Port","端口")+" \(port.id)") {
                    SimulationBoundaryIDPicker(id:$port.boundaryID,mesh:mesh)
                    SimulationChoicePicker(title:simulationText("Port type","端口类型"),selection:$port.kind)
                    Stepper(simulationText("Mode","模式")+": \(port.mode)",value:$port.mode,in:1...100)
                    SimulationNumberField(label:simulationText("Impedance","阻抗"),value:$port.impedanceOhms,unit:"Ω")
                    SimulationVectorFields(title:simulationText("Direction","方向"),value:$port.direction)
                    SimulationNumberField(label:simulationText("Excitation real","激励实部"),value:$port.excitation.real)
                    SimulationNumberField(label:simulationText("Excitation imaginary","激励虚部"),value:$port.excitation.imaginary)
                    SimulationNumberField(label:simulationText("Reference offset","参考面偏移"),value:$port.referenceOffsetMeters,unit:"m")
                    Button(simulationText("Remove port","移除端口"),role:.destructive) { configuration.ports.removeAll { $0.id == port.id } }
                }
            }
            Button(simulationText("Add port","添加端口")) { if let boundary = mesh?.boundaries.first(where:{ boundary in !configuration.ports.contains { $0.boundaryID == boundary.id } }) { configuration.ports.append(.init(id:(configuration.ports.map(\.id).max() ?? 0)+1,boundaryID:boundary.id)) } }
        } }
    }
}

private struct SimulationMaterialSettings: View {
    @Binding var material: SimulationMaterial
    var materials: [SimulationMaterial]
    private func property(_ key: String, scale: Double = 1) -> Binding<Double> { .init(get:{ (material.properties[key] ?? 0)/scale },set:{ material.properties[key] = $0*scale }) }
    var body: some View {
        TextField(simulationText("Name","名称"),text:$material.name)
        SimulationNumberField(label:simulationText("Young's modulus","弹性模量"),value:property("youngModulusPa",scale:1e9),unit:"GPa")
        SimulationNumberField(label:simulationText("Poisson ratio","泊松比"),value:property("poissonRatio"))
        SimulationNumberField(label:simulationText("Density","密度"),value:property("densityKgPerCubicMeter"),unit:"kg/m³")
        SimulationNumberField(label:simulationText("Conductivity","导热率"),value:property("thermalConductivityWPerMeterK"),unit:"W/(m·K)")
        SimulationNumberField(label:simulationText("Specific heat","比热"),value:property("specificHeatJPerKgK"),unit:"J/(kg·K)")
        SimulationNumberField(label:simulationText("Thermal expansion","热膨胀系数"),value:property("thermalExpansionPerKelvin"),unit:"1/K")
        SimulationNumberField(label:simulationText("Yield stress","屈服强度"),value:property("yieldStrengthPa",scale:1e6),unit:"MPa")
        DisclosureGroup(simulationText("Directional properties","方向材料参数")) {
            ForEach(["E1Pa","E2Pa","E3Pa","G12Pa","G13Pa","G23Pa"],id:\.self) { key in SimulationNumberField(label:String(key.dropLast(2)),value:property(key,scale:1e9),unit:"GPa") }
            ForEach(["nu12","nu13","nu23"],id:\.self) { key in SimulationNumberField(label:key,value:property(key)) }
        }
        DisclosureGroup(simulationText("Fluid, acoustic and EM properties","流体、声学与电磁参数")) {
            SimulationNumberField(label:simulationText("Dynamic viscosity","动力黏度"),value:property("dynamicViscosityPascalSeconds"),unit:"Pa·s")
            SimulationNumberField(label:simulationText("Sound speed","声速"),value:property("soundSpeedMetersPerSecond"),unit:"m/s")
            SimulationNumberField(label:simulationText("Acoustic loss factor","声学损耗因子"),value:property("acousticLossFactor"))
            SimulationNumberField(label:simulationText("Relative permittivity","相对介电常数"),value:property("relativePermittivity"))
            SimulationNumberField(label:simulationText("Relative permeability","相对磁导率"),value:property("relativePermeability"))
            SimulationNumberField(label:simulationText("Electrical conductivity","电导率"),value:property("electricalConductivitySiemensPerMeter"),unit:"S/m")
        }
        DisclosureGroup(simulationText("Laminate plies","复材铺层")) {
            ForEach($material.layers) { $layer in
                Picker(simulationText("Ply material","单层材料"),selection:$layer.materialID) { ForEach(materials.filter { $0.id != material.id && $0.layers.isEmpty }) { Text($0.name).tag($0.id) } }
                SimulationNumberField(label:simulationText("Ply thickness","单层厚度"),value:$layer.thicknessMeters,unit:"m")
                SimulationNumberField(label:simulationText("Ply angle","铺层角度"),value:Binding(get:{ layer.angleRadians*180/Double.pi },set:{ layer.angleRadians = $0*Double.pi/180 }),unit:"°")
                Button(simulationText("Remove ply","移除铺层"),role:.destructive) { material.layers.removeAll { $0.id == layer.id } }
            }
            Button(simulationText("Add ply","添加铺层")) { if let ply = materials.first(where:{ $0.id != material.id && $0.layers.isEmpty }) { material.layers.append(.init(materialID:ply.id,thicknessMeters:0.000125,angleRadians:0)) } }.disabled(!materials.contains { $0.id != material.id && $0.layers.isEmpty })
        }
    }
}

func simulationOption(_ raw: String) -> String {
    let words: [String:(String,String)] = [
        "fixed":("Fixed","固定"),"dynamic":("Dynamic","动力学"),"kinematic":("Kinematic","运动学"),"sphere":("Sphere","球"),"box":("Box","立方体"),"capsule":("Capsule","胶囊"),"convexHull":("Convex hull","凸包"),"triangleMesh":("Static surface","静态曲面"),
        "spherical":("Ball joint","球铰"),"revolute":("Hinge","铰链"),"prismatic":("Slider","滑块"),"spring":("Spring","弹簧"),"rope":("Rope","绳索"),"cloth":("Cloth","布料"),"volume":("Volume","体柔体"),
        "linearIsotropic":("Linear isotropic","各向同性线弹性"),"orthotropic":("Orthotropic","正交各向异性"),"j2Plasticity":("J2 plasticity","J2 塑性"),"neoHookean":("Neo-Hookean","Neo-Hookean 超弹性"),
        "incompressible":("Incompressible","不可压缩"),"compressible":("Compressible","可压缩"),"laminar":("Laminar","层流"),"spalartAllmaras":("SA","SA"),"sst":("SST","SST"),"velocityInlet":("Velocity inlet","速度入口"),"pressureOutlet":("Pressure outlet","压力出口"),"wall":("Wall","壁面"),"symmetry":("Symmetry","对称"),"farField":("Far field","远场"),
        "rigidWall":("Rigid wall","刚壁"),"pressure":("Pressure","压力"),"normalVelocity":("Normal velocity","法向速度"),"impedance":("Impedance","阻抗"),"radiation":("Radiation","辐射"),"perfectElectric":("Perfect conductor","理想导体"),"perfectMagnetic":("Magnetic wall","磁壁"),"absorbingLayer":("Absorbing layer","吸收层"),"electricPotential":("Electric potential","电势"),"surfaceCurrent":("Surface current","面电流"),"lumped":("Lumped port","集总端口"),"wave":("Wave port","波端口"),"uniform":("Uniform field","均匀力场"),"pointAttractor":("Point attractor","点吸引力场"),"vortex":("Vortex","涡旋"),"keyframed":("Keyframes","关键帧"),"driven":("Physics drive","物理驱动")]
    guard let value = words[raw] else { return raw }; return simulationText(value.0,value.1)
}
