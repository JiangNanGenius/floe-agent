import SwiftUI
import RealityKit
import FloeChemistryCore
import simd
#if os(iOS)
import UIKit
private typealias ChemistryColor = UIColor
#else
import AppKit
private typealias ChemistryColor = NSColor
#endif

private enum MolecularStyle: String, CaseIterable { case ballStick, spaceFill, sticks
    var title: String { switch self { case .ballStick: chemistryText("Ball and stick", "球棍"); case .spaceFill: chemistryText("Space filling", "空间填充"); case .sticks: chemistryText("Sticks", "棍状") } }
}
private enum MolecularNavigation: CaseIterable { case orbit, pan, zoom
    var title: String { switch self { case .orbit: chemistryText("Rotate", "旋转"); case .pan: chemistryText("Pan", "平移"); case .zoom: chemistryText("Zoom", "缩放") } }
    var symbol: String { switch self { case .orbit: "rotate.3d"; case .pan: "hand.draw"; case .zoom: "plus.magnifyingglass" } }
    var controls: CameraControls { switch self { case .orbit: .orbit; case .pan: .pan; case .zoom: .dolly } }
}

@MainActor public struct ChemistryMoleculeView: View {
    public let object: ChemicalObject
    @Binding public var selectedAtoms: [Int]
    @State private var scene = ChemistryScene()
    @State private var style = MolecularStyle.ballStick
    @State private var navigation = MolecularNavigation.orbit
    @State private var reset = UUID()
    @State private var showCell = true
    @State private var cell: [SIMD3<Float>] = []
    @State private var error: String?
    public init(object: ChemicalObject, selectedAtoms: Binding<[Int]>) { self.object = object; _selectedAtoms = selectedAtoms }
    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Menu { ForEach(MolecularStyle.allCases, id: \.self) { item in Button(item.title) { style = item; reset = UUID() } } } label: {
                    Label(style.title, systemImage: "circle.hexagongrid")
                }.frame(minHeight: 44)
                Spacer(minLength: 4)
                ForEach(MolecularNavigation.allCases, id: \.self) { item in
                    Button { navigation = item } label: { Image(systemName: item.symbol).frame(width: 36, height: 44) }
                        .tint(navigation == item ? .accentColor : .secondary).accessibilityLabel(item.title)
                }
                Button { reset = UUID() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right").frame(width: 36, height: 44) }.accessibilityLabel(chemistryText("Fit structure", "适合窗口"))
                if !cell.isEmpty { Toggle(isOn: $showCell) { Image(systemName: "cube") }.toggleStyle(.button).accessibilityLabel(chemistryText("Unit cell", "晶胞")) }
            }.font(.subheadline).padding(.horizontal, 12)
            ZStack {
                if scene.isThreeDimensional {
                    MolecularRealityView(scene: scene, cell: showCell ? cell : [], style: style, selectedAtoms: $selectedAtoms)
                        .realityViewCameraControls(navigation.controls).id(reset)
                } else if let error { ContentUnavailableView(chemistryText("Preview unavailable", "暂时无法预览"), systemImage: "atom", description: Text(error)) }
                else { ContentUnavailableView(chemistryText("No spatial coordinates", "尚无空间坐标"), systemImage: "atom", description: Text(chemistryText("Use 2D drawing, or generate a 3D structure in a configured environment.", "可使用二维绘图，或在已配置的环境中生成三维结构。"))) }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack(spacing: 12) {
                Text("\(Int(object.facts?["atomCount"]?.number ?? Double(scene.atoms.count))) " + chemistryText("atoms", "个原子") + " · \(scene.bonds.count) " + chemistryText("bonds", "条键"))
                if !selectedAtoms.isEmpty { Text(chemistryText("Selected", "已选") + " " + selectedAtoms.map { String($0+1) }.joined(separator: ", ")) }
                Spacer()
                Text(object.facts?["geometryDimension"]?.number == 2 ? chemistryText("2D drawing coordinates · Å", "二维绘图坐标 · Å") : "Å").accessibilityLabel(chemistryText("Coordinates in angstroms", "坐标单位为埃"))
            }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 8)
            if scene.atoms.count == 10000 { Text(chemistryText("Preview shows the first 10,000 atoms", "预览显示前 10,000 个原子")).font(.caption).foregroundStyle(.secondary) }
        }
        .task(id: "\(object.id)-\(object.revision)") {
            do {
                let source = object.facts?["cjson"]?.string ?? (object.format == "cjson" ? object.source : "{}")
                let value = try await ChemistryScene.load(source)
                guard !Task.isCancelled else { return }; scene = value; cell = value.cellVertices; reset = UUID(); error = nil
            } catch {
                guard !Task.isCancelled else { return }
                self.error=error.localizedDescription;scene=ChemistryScene();cell=[]
            }
        }
        .onChange(of: showCell) { _, _ in reset = UUID() }
    }

}

/// View-owned entity identities survive ordinary SwiftUI/selection updates.
/// Mutating this reference does not schedule thousands of @State writes.
@MainActor private final class MolecularRenderedAtoms {
    let root=Entity()
    var entities:[Int:ModelEntity]=[:]
    var highlighted:Set<Int>=[]
}
@MainActor private struct MolecularRealityView: View {
    let scene: ChemistryScene
    let cell: [SIMD3<Float>]
    let style: MolecularStyle
    @Binding var selectedAtoms: [Int]
    @State private var rendered=MolecularRenderedAtoms()
    private var root:Entity { rendered.root }
    private func position(_ index: Int) -> SIMD3<Float> { let a = scene.atoms[index]; return SIMD3(Float(a.x),Float(a.y),Float(a.zc)) }
    var body: some View {
        RealityView { content in
            build(); content.camera = .virtual; content.add(root); content.cameraTarget = root
            let key = DirectionalLight(); key.light.intensity = 1800
            key.look(at: .zero, from: [3,4,6], relativeTo: nil); content.add(key)
            let fill = DirectionalLight(); fill.light.intensity = 700
            fill.look(at: .zero, from: [-4,-2,3], relativeTo: nil); content.add(fill)
        } update: { _ in
            let selected=Set(selectedAtoms.filter{scene.atoms.indices.contains($0)})
            for index in rendered.highlighted.symmetricDifference(selected) {
                guard let entity=rendered.entities[index],var model=entity.components[ModelComponent.self] else { continue }
                model.materials=[material(selected.contains(index) ? .systemYellow:atomColor(scene.atoms[index].z))]
                entity.components.set(model)
            }
            rendered.highlighted=selected
        }
        .gesture(SpatialTapGesture().targetedToAnyEntity().onEnded { value in
            guard value.entity.name.hasPrefix("atom-"), let index = Int(value.entity.name.dropFirst(5)) else { return }
            if selectedAtoms.contains(index) { selectedAtoms.removeAll { $0 == index } }
            else { selectedAtoms.append(index); if selectedAtoms.count > 4 { selectedAtoms.removeFirst() } }
        })
        .accessibilityLabel(chemistryText("Molecular structure. Rotate, pan or zoom with the selected tool. Tap atoms to select.", "分子结构。使用所选工具旋转、平移或缩放；点按原子可选择。"))
    }
    private func material(_ color: ChemistryColor) -> SimpleMaterial { SimpleMaterial(color: color, roughness: 0.35, isMetallic: false) }
    private func atomColor(_ z: Int) -> ChemistryColor {
        switch z {
        case 1: .white
        case 6: ChemistryColor(white: 0.22, alpha: 1)
        case 7: .systemBlue
        case 8: .systemRed
        case 9,17: .systemGreen
        case 15: .systemOrange
        case 16: .systemYellow
        default: .systemPurple
        }
    }
    private func radius(_ z: Int) -> Float {
        let vdw: Float = switch z { case 1: 1.2; case 6: 1.7; case 7: 1.55; case 8: 1.52; case 9: 1.47; case 15,16: 1.8; case 17: 1.75; default: 1.8 }
        return style == .spaceFill ? vdw : (style == .sticks ? 0.12 : (z == 1 ? 0.22 : 0.34))
    }
    private func build() {
        let coordinates = scene.atoms.indices.map(position) + cell
        guard let first = coordinates.first else { return }
        var low = first, high = first
        for p in coordinates { low = simd_min(low,p); high = simd_max(high,p) }
        let center = (low+high)/2, span = high-low
        let scale: Float = 2.0 / max(span.x,span.y,span.z,2.5)
        var spheres: [Int: MeshResource] = [:]
        let selected=Set(selectedAtoms.filter{scene.atoms.indices.contains($0)})
        rendered.entities.removeAll(keepingCapacity:true);rendered.highlighted=selected
        for (i, atom) in scene.atoms.enumerated() {
            let mesh = spheres[atom.z] ?? MeshResource.generateSphere(radius: radius(atom.z)*scale)
            spheres[atom.z] = mesh
            let entity = ModelEntity(mesh: mesh, materials: [material(selected.contains(i) ? .systemYellow:atomColor(atom.z))])
            entity.name = "atom-\(i)"; entity.position = (position(i)-center)*scale
            entity.components.set(InputTargetComponent())
            entity.components.set(CollisionComponent(shapes: [.generateSphere(radius: max(radius(atom.z),0.22)*scale)]))
            rendered.entities[i]=entity
            root.addChild(entity)
        }
        if style != .spaceFill {
            for bond in scene.bonds {
                let pa = (position(bond.a)-center)*scale, pb = (position(bond.b)-center)*scale, vector = pb-pa
                guard simd_length(vector) > 1e-6 else { continue }
                var perpendicular = simd_cross(simd_normalize(vector), SIMD3<Float>(0,0,1))
                if simd_length(perpendicular) < 0.1 { perpendicular = simd_cross(simd_normalize(vector), SIMD3<Float>(0,1,0)) }
                perpendicular = simd_normalize(perpendicular)
                let order = min(3,max(1,bond.order))
                for line in 0..<order {
                    let offset = perpendicular * ((Float(line)-Float(order-1)/2)*0.16*scale), mid = (pa+pb)/2+offset
                    cylinder(pa+offset,mid,radius:0.06*scale,color:atomColor(scene.atoms[bond.a].z))
                    cylinder(mid,pb+offset,radius:0.06*scale,color:atomColor(scene.atoms[bond.b].z))
                }
            }
        }
        if cell.count == 8 {
            for (a,b) in [(0,1),(0,2),(0,4),(1,3),(1,5),(2,3),(2,6),(3,7),(4,5),(4,6),(5,7),(6,7)] {
                cylinder((cell[a]-center)*scale,(cell[b]-center)*scale,radius:0.012,color:.systemTeal)
            }
        }
    }
    private func cylinder(_ a: SIMD3<Float>, _ b: SIMD3<Float>, radius: Float, color: ChemistryColor) {
        let delta = b-a, length = simd_length(delta)
        guard length > 1e-6 else { return }
        let entity = ModelEntity(mesh: .generateCylinder(height: length, radius: radius), materials: [material(color)])
        entity.position = (a+b)/2; entity.orientation = simd_quatf(from: SIMD3<Float>(0,1,0), to: delta/length)
        root.addChild(entity)
    }
}
