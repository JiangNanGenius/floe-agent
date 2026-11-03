#if DEBUG && canImport(SwiftUI) && canImport(UIKit)
import SwiftUI
import simd

@MainActor
public enum CADAssemblyJointUIFixture {
    public static func prepare(_ document: FloeCADDocument, bodyID: String) throws {
        let service = CADAssemblyService(document: document)
        func run(_ action: String, _ args: [String: Any]) throws -> [String: Any] {
            let reply = service.handle(action: action, args: args)
            guard reply["ok"] as? Bool == true else {
                throw CADDocumentError(code: "joint_fixture", message: reply["message"] as? String ?? "Joint fixture refused")
            }
            return reply
        }
        func instance(_ name: String) throws -> String {
            let result = try run("addInstance", ["bodyID": bodyID, "name": name])
            guard let id = result["id"] as? String else { throw CADDocumentError(code: "joint_fixture", message: "Missing instance") }
            return id
        }
        let base = try instance("Ground"), arm = try instance("Arm"), slide = try instance("Carrier")
        _ = try run("addConstraint", ["kind": "fixed", "instanceA": base])
        _ = try run("addConstraint", ["kind": "hinge", "instanceA": base, "instanceB": arm,
            "pointA": [0,0,0], "pointB": [0,0,0], "directionA": [0,1,0], "directionB": [0,1,0],
            "value": 0, "lowerLimit": -90, "upperLimit": 90])
        _ = try run("addConstraint", ["kind": "slider", "instanceA": arm, "instanceB": slide,
            "pointA": [120,0,0], "pointB": [0,0,0], "directionA": [1,0,0], "directionB": [1,0,0],
            "value": 30, "lowerLimit": 0, "upperLimit": 60])
    }

    static func readback(_ document: FloeCADDocument) -> String {
        guard let assembly = try? CADAssembly.decode(from: document.session.document.assemblyData),
              let hinge = assembly.constraints.first(where: { $0.kind == .hinge }),
              let carrier = assembly.instances.first(where: { $0.name == "Carrier" }) else { return "missing" }
        let p = carrier.transform.position
        return "id=\(hinge.id.uuidString)|hinge=\(Int(hinge.value ?? -999))|carrier=\(String(format: "%.3f,%.3f,%.3f", p.x,p.y,p.z))"
    }
}

public struct CADAssemblyJointReadbackPanel: View {
    let document: FloeCADDocument
    public init(document: FloeCADDocument) { self.document = document }
    public var body: some View {
        TimelineView(.periodic(from: .now, by: 0.3)) { _ in
            Text(CADAssemblyJointUIFixture.readback(document))
                .font(.caption2.monospaced())
                .padding(5).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .frame(maxWidth: 240)
                .accessibilityIdentifier("CADJointState")
                .allowsHitTesting(false)
        }
    }
}
#endif
