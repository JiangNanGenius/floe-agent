import SwiftUI
import FloeChemistryCore

public struct ChemistryScene: Sendable {
    public struct Atom: Sendable { public let z: Int; public let x: Double; public let y: Double; public let zc: Double }
    public struct Bond: Sendable { public let a: Int; public let b: Int; public let order: Int }
    public var atoms: [Atom] = []
    public var bonds: [Bond] = []
    public var isThreeDimensional = false
    /// Derived with the same decoded structure; no second JSON pass on the UI actor.
    public var cellVertices:[SIMD3<Float>]=[]
    public static func load(_ source:String) async throws -> Self {
        let worker=Task.detached(priority:.userInitiated) {
            try Task.checkCancellation();let value=try Self.parse(source);try Task.checkCancellation();return value
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel:{worker.cancel()}
    }
    public static func parse(_ source: String) throws -> Self {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
        let elements = json["atoms"]?["elements"]?["number"]?.array ?? []
        let coordinates = json["atoms"]?["coords"]?["3d"]?.array ?? []
        let connections = json["bonds"]?["connections"]?["index"]?.array ?? []
        let orders = json["bonds"]?["order"]?.array ?? []
        var scene = Self(); scene.isThreeDimensional = coordinates.count == elements.count * 3 && !elements.isEmpty
        if !coordinates.isEmpty && !scene.isThreeDimensional { throw ChemistryError.invalid("Invalid scene coordinates.") }
        // This is a display budget; the project retains the complete source.
        for (i, element) in elements.prefix(10000).enumerated() {
            if i % 128 == 0 { try Task.checkCancellation() }
            guard let z = element.number, z >= 1, z <= 118, z.rounded() == z else { throw ChemistryError.invalid("Invalid scene element.") }
            if scene.isThreeDimensional {
                guard let x = coordinates[i*3].number, let y = coordinates[i*3+1].number, let v = coordinates[i*3+2].number,
                      x.isFinite, y.isFinite, v.isFinite else { throw ChemistryError.invalid("Invalid scene coordinates.") }
                scene.atoms.append(Atom(z: Int(z), x: x, y: y, zc: v))
            } else {
                // Preserve the graph for counts/selection without inventing
                // coordinates. isThreeDimensional remains false, so these
                // placeholders are never rendered as a spatial structure.
                scene.atoms.append(Atom(z: Int(z), x: 0, y: 0, zc: 0))
            }
        }
        for i in stride(from: 0, to: max(0, connections.count - 1), by: 2) {
            if i % 256 == 0 { try Task.checkCancellation() }
            guard let a = connections[i].number, let b = connections[i+1].number,
                  a.rounded() == a, b.rounded() == b, a >= 0, b >= 0,
                  a < Double(scene.atoms.count), b < Double(scene.atoms.count) else { continue }
            scene.bonds.append(Bond(a: Int(a), b: Int(b), order: Int(orders.indices.contains(i/2) ? (orders[i/2].number ?? 1) : 1)))
        }
        if scene.atoms.count > 1, let first = scene.atoms.first,
           scene.atoms.allSatisfy({ abs($0.x-first.x)+abs($0.y-first.y)+abs($0.zc-first.zc) < 1e-6 }) { scene.isThreeDimensional = false }
        scene.cellVertices=Self.parseCell(json)
        return scene
    }
    private static func parseCell(_ json:JSONValue) -> [SIMD3<Float>] {
        guard let cell=json["unitCell"],let a=cell["a"]?.number,let b=cell["b"]?.number,let c=cell["c"]?.number,
              let alpha=cell["alpha"]?.number,let beta=cell["beta"]?.number,let gamma=cell["gamma"]?.number else { return [] }
        let ar=alpha * .pi/180,br=beta * .pi/180,gr=gamma * .pi/180
        guard [a,b,c,ar,br,gr].allSatisfy(\.isFinite),min(a,b,c)>0,abs(sin(gr))>1e-8 else { return [] }
        let cx=c*cos(br),cy=c*(cos(ar)-cos(br)*cos(gr))/sin(gr),cz=sqrt(max(0,c*c-cx*cx-cy*cy))
        let va=SIMD3<Float>(Float(a),0,0),vb=SIMD3<Float>(Float(b*cos(gr)),Float(b*sin(gr)),0),vc=SIMD3<Float>(Float(cx),Float(cy),Float(cz))
        return [.zero,va,vb,va+vb,vc,va+vc,vb+vc,va+vb+vc]
    }

}
