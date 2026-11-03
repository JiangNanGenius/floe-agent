import Foundation
import simd

/// Local sheet state and identity-bound choices. No editor state is persisted
/// here; Apply sends one existing parameter-service transaction.
nonisolated enum CADLoftSurfaceEditorDestination: Identifiable {
    case draftLoft
    case loft(FeatureID)
    case surface(FeatureID?)
    var id: String {
        switch self {
        case .draftLoft: return "draftLoft"
        case let .loft(id): return "loft:\(id.raw)"
        case let .surface(id): return "surface:\(id?.raw.uuidString ?? "new")"
        }
    }
}

nonisolated struct CADLoftSectionChoice: Identifiable {
    var id: String
    var title: String
    var reference: ProfileRef
    var profile: Profile
    var holes: [Profile]
    var plane: SketchPlane
    func matches(_ ref: ProfileRef) -> Bool {
        reference.sketchID == ref.sketchID && Set(reference.entityIDs) == Set(ref.entityIDs)
            && (reference.holeEntityIDs.map { Set($0) }) == (ref.holeEntityIDs.map { Set($0) })
            && (ref.seedPoint.map { profile.contains($0) } ?? true)
    }
}
nonisolated struct CADLoftSectionRow: Identifiable {
    var id=UUID()
    var reference: ProfileRef
}
nonisolated struct CADSurfaceSectionRow: Identifiable {
    var id=UUID()
    var path: SweepPathDefinition
}
nonisolated struct CADSurfaceEdgeChoice: Identifiable {
    var sketchID: SketchID
    var entityID: UUID
    var title: String
    var id: String { sketchID.raw.uuidString+":"+entityID.uuidString }
}
nonisolated struct CADSurfaceInputChoice: Identifiable {
    var id: BodyID { reference.bodyID }
    var reference: BodyRef
    var title: String
    var faceCount: Int
    var freeEdges: Int
    var closed: Bool
    var valid: Bool
    var closedFreeWires: Int
    var canTrim: Bool
    var canPatch: Bool
    var domain: CADSurfaceDefinition.UVTrim?
}
nonisolated enum CADLoftSurfaceUIModel {
    static func moved<T>(_ values: [T], from: Int, by delta: Int) -> [T] {
        guard values.indices.contains(from), values.indices.contains(from+delta) else { return values }
        var result=values; result.swapAt(from,from+delta); return result
    }
    static func closedSections(sketches: [Sketch]) -> [CADLoftSectionChoice] {
        sketches.flatMap { sketch in
            let all=ProfileDetector.detectProfiles(in:sketch)
            return all.enumerated().compactMap { index,profile -> CADLoftSectionChoice? in
                guard !profile.sourceEntityIDs.isEmpty else { return nil }
                let holes=ProfileDetector.holes(of:profile,among:all)
                let ref=ProfileRef(sketchID:sketch.id,entityIDs:profile.sourceEntityIDs.sorted { $0.uuidString < $1.uuidString },
                    holeEntityIDs:holes.map { $0.sourceEntityIDs.sorted { $0.uuidString < $1.uuidString } },seedPoint:profile.interiorPoint)
                let id=sketch.id.raw.uuidString+":"+ref.entityIDs.map(\.uuidString).joined(separator:",")+":\(index)"
                return CADLoftSectionChoice(id:id,title:"\(sketch.name) · \(index+1)",reference:ref,
                    profile:profile,holes:holes,plane:sketch.plane)
            }
        }
    }
    static func openEdges(sketches: [Sketch]) -> [CADSurfaceEdgeChoice] {
        sketches.flatMap { sketch in
            sketch.entities.enumerated().compactMap { index,entity -> CADSurfaceEdgeChoice? in
                guard let curve=try? SketchCurveDefinition(entity), !curve.interval.periodic else { return nil }
                return CADSurfaceEdgeChoice(sketchID:sketch.id,entityID:entity.id,title:"\(sketch.name) · \(index+1)")
            }
        }
    }
    @MainActor static func sources(result: EvalResult) -> [CADSurfaceInputChoice] {
        result.bodies.compactMap { body in
            guard let native=body.surfaceBRep,let handle=OCCTKernel.transformed(native,by:body.transform),body.brep == nil,
                  let writer=result.lastBodyWriters[body.id] else { return nil }
            let diagnostics=OCCTKernel.surfaceDiagnostics(handle), health=OCCTKernel.healthReport(for:handle)
            guard diagnostics["error"] == nil else { return nil }
            let domains=diagnostics["face_domains"] as? [[String:Any]] ?? []
            let domain: CADSurfaceDefinition.UVTrim?
            if domains.count == 1, let first=domains.first,
               let u0=first["u_min"] as? Double, let u1=first["u_max"] as? Double,
               let v0=first["v_min"] as? Double, let v1=first["v_max"] as? Double {
                domain = .init(uMin:u0,uMax:u1,vMin:v0,vMax:v1)
            } else { domain=nil }
            return CADSurfaceInputChoice(reference:BodyRef(producer:writer,bodyID:body.id),title:body.name,
                faceCount:diagnostics["faces"] as? Int ?? 0,freeEdges:diagnostics["free_edges"] as? Int ?? -1,
                closed:diagnostics["closed"] as? Bool ?? false,valid:health.error == nil && health.isValid,
                closedFreeWires:health.closedFreeWires,canTrim:diagnostics["trim_supported"] as? Bool ?? false,
                canPatch:diagnostics["planar_patch_supported"] as? Bool ?? false,domain:domain)
        }
    }
    static func operations(openEdges: [CADSurfaceEdgeChoice], sources: [CADSurfaceInputChoice]) -> [CADSurfaceDefinition.Operation] {
        var result: [CADSurfaceDefinition.Operation]=[]
        if Set(openEdges.map(\.sketchID)).count >= 2 { result.append(.loft) }
        if sources.contains(where: { $0.valid && $0.canTrim }) { result.append(.trim) }
        if sources.contains(where: { $0.valid && $0.canPatch }) { result.append(.patch) }
        if sources.filter(\.valid).count >= 2 { result.append(.sew) }
        if sources.contains(where: \.valid) { result.append(.thicken) }
        return result
    }
    static func trim(domain: CADSurfaceDefinition.UVTrim, across: ClosedRange<Double>, along: ClosedRange<Double>) throws -> CADSurfaceDefinition.UVTrim {
        guard across.lowerBound.isFinite,across.upperBound.isFinite,along.lowerBound.isFinite,along.upperBound.isFinite,
              across.lowerBound >= 0,across.upperBound <= 100,across.lowerBound < across.upperBound,
              along.lowerBound >= 0,along.upperBound <= 100,along.lowerBound < along.upperBound else {
            throw LoftSurfaceError.invalid("Use increasing trim percentages from 0 to 100.")
        }
        return .init(uMin:domain.uMin+(domain.uMax-domain.uMin)*across.lowerBound/100,
            uMax:domain.uMin+(domain.uMax-domain.uMin)*across.upperBound/100,
            vMin:domain.vMin+(domain.vMax-domain.vMin)*along.lowerBound/100,
            vMax:domain.vMin+(domain.vMax-domain.vMin)*along.upperBound/100)
    }
}
