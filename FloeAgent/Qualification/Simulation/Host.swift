import SwiftUI
import FloeSimulationCore
import FloeSimulationUI
import FloeSimulationSamples

@main @MainActor struct SimulationQualificationApp: App {
    @State private var model: SimulationWorkbenchModel?
    @State private var failure: String?
    var body: some Scene {
        WindowGroup {
            NavigationStack {
                if let model { SimulationWorkbenchView(model:model) { value in QualificationWireframe(model:value) } }
                else if let failure { ContentUnavailableView("Unable to open simulation",systemImage:"exclamationmark.triangle",description:Text(failure)) }
                else { ProgressView().task { await open() } }
            }
        }
    }
    private func open() async {
        do {
            let document = try SimulationSamples.workspace()
            let directory = try FileManager.default.url(for:.documentDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("SimulationQualification",isDirectory:true)
            model = try await SimulationWorkbenchFactory.openOrCreate(initial:document,directory:directory)
        } catch { failure = error.localizedDescription }
    }
}

/// Only the qualification host draws this wireframe. The actual editor injects
/// its existing Metal viewport through SimulationWorkbenchView's content closure.
private struct QualificationWireframe: View {
    var model: SimulationWorkbenchModel
    var body: some View {
        let frame = model.currentFrame, scene = model.physics
        let displayedMesh = model.result?.mesh ?? model.activeMesh
        let deformationScale = model.deformationScale
        Canvas { context,size in
            let physics = frame?.fields.first { $0.id == "body_position" }
            if let physics {
                let visible = frame?.fields.first { $0.id == "body_visible" }?.values
                func project(_ p: SimulationVector3) -> CGPoint { .init(x:size.width*0.45+(p.x+p.z*0.45)*size.width*0.24,y:size.height*0.82-(p.y-p.z*0.25)*size.height*0.52) }
                for (i,body) in scene.bodies.enumerated() where i*3+2 < physics.values.count {
                    if let visible, visible.indices.contains(i), visible[i] < 0.5 { continue }
                    let p = SimulationVector3(physics.values[i*3],physics.values[i*3+1],physics.values[i*3+2])
                    let extent = body.collider.kind == .sphere ? body.collider.radius : body.collider.halfExtents.x
                    let center = project(p), radius = max(2,extent*size.width*0.24)
                    context.stroke(Path(CGRect(x:center.x-radius,y:center.y-radius,width:radius*2,height:radius*2)),with:.color(body.motion == .fixed ? .secondary : .accentColor),lineWidth:2)
                }
                for field in frame?.fields ?? [] where field.id.hasPrefix("soft/") {
                    for i in stride(from:0,to:field.values.count,by:3) where i+2 < field.values.count {
                        let p = project(.init(field.values[i],field.values[i+1],field.values[i+2]))
                        context.fill(Path(ellipseIn:CGRect(x:p.x-2,y:p.y-2,width:4,height:4)),with:.color(.orange))
                    }
                }
            } else if let mesh = displayedMesh {
                let displacements = frame?.fields.first { $0.id == "displacement" }?.values
                func project(_ index: Int) -> CGPoint {
                    var p = mesh.nodes[index]
                    if let displacements, index*3+2 < displacements.count { p = p + SimulationVector3(displacements[index*3],displacements[index*3+1],displacements[index*3+2])*deformationScale }
                    return .init(x:size.width*0.15+(p.x+p.z*0.5)*size.width*6,y:size.height*0.7-(p.y-p.z*0.3)*size.height*12)
                }
                for element in mesh.elements {
                    for a in element.nodes.indices { for b in element.nodes.indices where b>a {
                        var path = Path(); path.move(to:project(element.nodes[a])); path.addLine(to:project(element.nodes[b])); context.stroke(path,with:.color(.accentColor.opacity(0.5)),lineWidth:1)
                    } }
                }
            }
        }.background(.background.secondary).accessibilityIdentifier("simulation.qualification.viewport")
    }
}
