// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum CabinetDrawingKind: String, Codable, Sendable, CaseIterable {
    case front,internalElevation,section,exploded,individualParts,partsSchedule,edging,machining,nesting
}
public struct CabinetDrawingPlan: Codable, Equatable, Sendable {
    public var kind: CabinetDrawingKind
    public var panelIDs: [String]
    public var fingerprint: String
    public var status: String
    public var issues: [String]
}
public struct NativePanelDraft: Codable, Equatable, Sendable {
    public var panelID: String
    public var rectangleMin: [Double]
    public var rectangleMax: [Double]
    public var extrusionMM: Double
    public var translationXYZ: [Double]
}

public enum CabinetDerivations {
    /// Data for the existing Floe public sketch/extrude/transform commands.
    /// The native ground plane maps (u,v) to world (x,0,-v); its extrusion is +Y.
    public static func nativeDrafts(_ assembly: CabinetAssembly) throws -> [NativePanelDraft] {
        try assembly.validateGeneratedSnapshot()
        return assembly.panels.map { p in
            .init(panelID:p.id,rectangleMin:[p.originMM.x,p.originMM.y],
                  rectangleMax:[p.originMM.x+p.sizeMM.x,p.originMM.y+p.sizeMM.y],
                  extrusionMM:p.sizeMM.z,translationXYZ:[0,p.originMM.z,0])
        }
    }
    public static func drawingPlans(_ assembly: CabinetAssembly, maximumNativeSources: Int=12) throws -> [CabinetDrawingPlan] {
        try assembly.validateGeneratedSnapshot()
        guard maximumNativeSources>0 else { throw InteriorDesignError.invalidBayConfiguration }
        return try CabinetDrawingKind.allCases.map { kind in
            let panels=(kind == .internalElevation ? assembly.panels.filter{$0.role != .front}:assembly.panels)
            var issues:[String]=[]
            switch kind {
            case .edging: issues=["edge-and-grain-rules-required"]
            case .machining: issues=["joinery-and-hardware-drilling-rules-required"]
            case .nesting: issues=["cut-size-stock-grain-and-cutting-rules-required"]
            default: break
            }
            if [.front,.internalElevation,.section,.exploded].contains(kind), panels.count>maximumNativeSources {
                issues.append("native-drawing-source-budget-exceeded")
            }
            let source=(kind == .partsSchedule ? assembly.scheduleFingerprint:assembly.geometryFingerprint)
            struct Dependency:Encodable { var kind:CabinetDrawingKind; var source:String; var panels:[String] }
            return .init(kind:kind,panelIDs:panels.map(\.id),
                         fingerprint:try InteriorFingerprint.hash(Dependency(kind:kind,source:source,panels:panels.map(\.id))),
                         status:issues.isEmpty ? "design-draft":"needs-input-or-adapter",issues:issues)
        }
    }
    public static func partsCSV(_ assembly: CabinetAssembly) throws -> String {
        try assembly.validateGeneratedSnapshot()
        func quote(_ s:String)->String { "\""+s.replacingOccurrences(of:"\"",with:"\"\"")+"\"" }
        func number(_ n:Double)->String { String(format:"%.4f",locale:Locale(identifier:"en_US_POSIX"),n) }
        var rows=[["part_id","role","face_u_mm","face_v_mm","thickness_mm","material_id","material_version","size_basis","manufacturing_state"]]
        rows += assembly.panels.map { p in
            [p.id,p.role.rawValue,number(p.faceDimensionsMM[0]),number(p.faceDimensionsMM[1]),
             number(p.material.thicknessMM),p.material.id,p.material.version,"design-finished-dimensions","not-validated"]
        }
        return rows.map { $0.map(quote).joined(separator:",") }.joined(separator:"\r\n")+"\r\n"
    }
}
