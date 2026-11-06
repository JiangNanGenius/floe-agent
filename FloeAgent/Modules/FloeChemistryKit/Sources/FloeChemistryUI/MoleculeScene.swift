import SwiftUI
import FloeChemistryCore

public struct ChemistryScene: Sendable {
    public struct Atom: Sendable { public let z: Int; public let x: Double; public let y: Double; public let zc: Double }
    public struct Bond: Sendable { public let a: Int; public let b: Int; public let order: Int }
    public var atoms: [Atom] = []
    public var bonds: [Bond] = []
    public var isThreeDimensional = false
    public static func parse(_ source: String) throws -> Self {
        let json = try JSONDecoder().decode(JSONValue.self, from: Data(source.utf8))
        let elements = json["atoms"]?["elements"]?["number"]?.array ?? []
        let coordinates = json["atoms"]?["coords"]?["3d"]?.array ?? []
        let connections = json["bonds"]?["connections"]?["index"]?.array ?? []
        let orders = json["bonds"]?["order"]?.array ?? []
        var scene = Self(); scene.isThreeDimensional = coordinates.count == elements.count * 3 && !elements.isEmpty
        guard scene.isThreeDimensional else { return scene }
        // This is a display budget; the project retains the complete source.
        for (i, element) in elements.prefix(10000).enumerated() {
            guard let z = element.number, z >= 1, z <= 118, z.rounded() == z else { throw ChemistryError.invalid("Invalid scene element.") }
            if scene.isThreeDimensional {
                guard let x = coordinates[i*3].number, let y = coordinates[i*3+1].number, let v = coordinates[i*3+2].number,
                      x.isFinite, y.isFinite, v.isFinite else { throw ChemistryError.invalid("Invalid scene coordinates.") }
                scene.atoms.append(Atom(z: Int(z), x: x, y: y, zc: v))
            }
        }
        for i in stride(from: 0, to: max(0, connections.count - 1), by: 2) {
            guard let a = connections[i].number, let b = connections[i+1].number,
                  a.rounded() == a, b.rounded() == b, a >= 0, b >= 0,
                  a < Double(scene.atoms.count), b < Double(scene.atoms.count) else { continue }
            scene.bonds.append(Bond(a: Int(a), b: Int(b), order: Int(orders.indices.contains(i/2) ? (orders[i/2].number ?? 1) : 1)))
        }
        if scene.atoms.count > 1, let first = scene.atoms.first,
           scene.atoms.allSatisfy({ abs($0.x-first.x)+abs($0.y-first.y)+abs($0.zc-first.zc) < 1e-6 }) { scene.isThreeDimensional = false }
        return scene
    }
}

