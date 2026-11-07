import SwiftUI
import FloeSimulationCore
import FloeSimulationEngineering

struct SimulationSectionSettings: View {
    @Binding var configuration: EngineeringSimulationConfiguration
    var mesh: SimulationMesh?
    private var beamRegions: [String] { Set((mesh?.elements ?? []).filter { $0.kind == .line2 }.map(\.regionID)).sorted() }
    private var shellRegions: [String] { Set((mesh?.elements ?? []).filter { $0.kind == .triangle3 || $0.kind == .quadrilateral4 }.map(\.regionID)).sorted() }
    var body: some View {
        Section(simulationText("Sections","截面与壳厚")) {
            if beamRegions.isEmpty && shellRegions.isEmpty { Text(simulationText("Select a beam or shell mesh to define its section.","选择梁或壳网格后设置截面。")).font(.caption).foregroundStyle(.secondary) }
            ForEach(beamRegions,id:\.self) { region in
                DisclosureGroup(region) {
                    if let initial = configuration.beamSections[region] {
                        let value = Binding(get:{ configuration.beamSections[region] ?? initial },set:{ configuration.beamSections[region] = $0 })
                        SimulationNumberField(label:simulationText("Area","截面积"),value:value.areaSquareMeters,unit:"m²")
                        SimulationNumberField(label:"Iy",value:value.inertiaYFourthMeters,unit:"m⁴")
                        SimulationNumberField(label:"Iz",value:value.inertiaZFourthMeters,unit:"m⁴")
                        SimulationNumberField(label:simulationText("Torsional constant","扭转常数"),value:value.torsionalConstantFourthMeters,unit:"m⁴")
                        SimulationVectorFields(title:simulationText("Section direction","截面方向"),value:value.orientation)
                    } else {
                        Button(simulationText("Define beam section","定义梁截面")) { configuration.beamSections[region] = .init(areaSquareMeters:0.0001,inertiaYFourthMeters:8.333333333e-10,inertiaZFourthMeters:8.333333333e-10,torsionalConstantFourthMeters:1.4e-9) }
                    }
                }
            }
            ForEach(shellRegions,id:\.self) { region in
                DisclosureGroup(region) {
                    if let initial = configuration.shellSections[region] {
                        let value = Binding(get:{ configuration.shellSections[region] ?? initial },set:{ configuration.shellSections[region] = $0 })
                        SimulationNumberField(label:simulationText("Thickness","厚度"),value:value.thicknessMeters,unit:"m")
                        SimulationNumberField(label:simulationText("Offset","偏置"),value:value.offsetMeters,unit:"m")
                        SimulationVectorFields(title:simulationText("Material direction","材料方向"),value:value.materialDirection)
                    } else { Button(simulationText("Define shell section","定义壳截面")) { configuration.shellSections[region] = .init() } }
                }
            }
        }
    }
}
struct SimulationContactSettings: View {
    @Binding var configuration: EngineeringSimulationConfiguration
    var mesh: SimulationMesh?
    var body: some View {
        Section(simulationText("Contacts","接触")) {
            ForEach($configuration.contacts) { $contact in
                DisclosureGroup(simulationText("Contact pair","接触对")) {
                    Picker(simulationText("Primary surface","主面"),selection:$contact.primaryBoundary) { ForEach(mesh?.boundaries ?? []) { Text($0.id).tag($0.id) } }
                    Picker(simulationText("Secondary surface","从面"),selection:$contact.secondaryBoundary) { ForEach(mesh?.boundaries ?? []) { Text($0.id).tag($0.id) } }
                    SimulationNumberField(label:simulationText("Friction","摩擦系数"),value:$contact.friction)
                    SimulationNumberField(label:simulationText("Penalty factor","罚因子"),value:$contact.penalty)
                    Button(simulationText("Remove contact","移除接触"),role:.destructive) { configuration.contacts.removeAll { $0.id == contact.id } }
                }
            }
            Button(simulationText("Add contact pair","添加接触对")) {
                guard let boundaries = mesh?.boundaries, boundaries.count >= 2 else { return }
                configuration.contacts.append(.init(primaryBoundary:boundaries[0].id,secondaryBoundary:boundaries[1].id))
            }.disabled((mesh?.boundaries.count ?? 0) < 2)
        }
    }
}
