// SPDX-License-Identifier: MPL-2.0
import Foundation
import CryptoKit

public nonisolated struct CADBuildingCheck: Identifiable, Sendable {
    public enum Status: String, Sendable { case information, passed, failed, notEvaluated }
    public var id: String
    public var status: Status
    public var title: String
    public var detail: String
    public var elementIDs: [UUID]
}

public nonisolated enum CADBuildingProfessionalAction: String, Codable, CaseIterable, Identifiable, Sendable {
    case ifc, structure, mep, information
    public var id: String { rawValue }
}

public nonisolated struct CADBuildingStructuralSettings: Codable, Equatable, Sendable {
    public enum Support: String, Codable, CaseIterable, Sendable { case simplySupported, cantilever }
    public var memberID: UUID?
    public var support: Support = .simplySupported
    public var elasticModulusNPerMM2: Double = 200_000
    public var poissonRatio: Double = 0.3
    /// Explicit uniform downward load, N/mm (numerically kN/m).
    public var lineLoadNPerMM: Double = 1
    public init() {}
}

public nonisolated struct CADBuildingProfessionalPackage: Sendable {
    public var action: CADBuildingProfessionalAction
    public var revision: Int
    public var changeCount: Int
    public var sourceSHA256: String
    public var files: [String: Data]
}

@MainActor
public extension FloeCADDocument {
    /// Native data/rule checks are intentionally separate from structural
    /// analysis, geometric coordination and jurisdictional approval.
    func inspectBuilding() throws -> [CADBuildingCheck] {
        guard let model = try building() else { throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.createOrImportABuildingFirst","Create or import a building first.")) }
        try model.validate()
        var rows = [CADBuildingCheck(id:"model",status:.passed,
            title:FloeCADStrings.text("cad.building.check.model","Building records"),
            detail:"\(model.storeys.count) / \(model.elements.count)", elementIDs:[])]
        let represented = Set(session.document.bodies.map { $0.id.raw })
        let absent = model.elements.filter { !Set($0.bodyIDs).isSubset(of:represented) }
        rows.append(.init(id:"geometry",status:absent.isEmpty ? .passed:.failed,
            title:FloeCADStrings.text("cad.building.check.geometry","Model geometry"),
            detail:absent.isEmpty ? FloeCADStrings.text("cad.building.check.linked","Building elements have model geometry.") : FloeCADStrings.text("cad.building.check.missing","Some building elements no longer have model geometry. Rebuild or review them."),elementIDs:absent.map(\.id)))
        for floor in model.storeys {
            let members = model.elements.filter { $0.storeyID == floor.id }
            let area = members.filter { $0.kind == .space }.reduce(0) { $0 + $1.areaM2 }
            rows.append(.init(id:floor.id.uuidString,status:.information,title:floor.name,
                detail:String(format:"%d · %.2f m²",members.count,area),elementIDs:members.map(\.id)))
        }
        if model.rules.isEmpty || model.jurisdiction.subdivision.isEmpty || model.jurisdiction.buildingUse.isEmpty || model.jurisdiction.edition.isEmpty {
            rows.append(.init(id:"jurisdiction",status:.notEvaluated,
                title:FloeCADStrings.text("cad.building.rules.title","Project rules"),
                detail:FloeCADStrings.text("cad.building.rules.missing","Choose the region, use and code edition, then add sourced rules to evaluate them."),elementIDs:[]))
        } else {
            for rule in model.rules {
                var measured: [(UUID,Double)] = []
                switch rule.metric {
                case .doorWidth: measured=model.elements.filter { $0.kind == .door }.map { ($0.id,$0.widthMM ?? 0) }
                case .stairWidth: measured=model.elements.filter { $0.kind == .stair }.map { ($0.id,$0.thicknessMM) }
                case .spaceArea: measured=model.elements.filter { $0.kind == .space }.map { ($0.id,$0.areaM2) }
                case .storeyHeight: measured=model.storeys.map { ($0.id,$0.heightMM) }
                }
                let failures = measured.filter { $0.1 < rule.minimum }.map(\.0)
                rows.append(.init(id:rule.id.uuidString,status:measured.isEmpty ? .notEvaluated : failures.isEmpty ? .passed:.failed,
                    title:rule.clause,detail:"\(rule.metric.rawValue) ≥ \(rule.minimum) · \(rule.sourceURL)",elementIDs:failures))
            }
        }
        return rows
    }

    /// Saved CAD buffers (including deliberate subsequent CAD edits) are the
    /// IFC geometry source. Semantics and quantities are kept separately. IFC
    /// exchange is explicitly tessellated, never advertised as native BRep.
    func prepareBuildingProfessional(action: CADBuildingProfessionalAction,
                                     structural: CADBuildingStructuralSettings = .init()) async throws -> CADBuildingProfessionalPackage {
        guard let model = try building() else { throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.createOrImportABuildingFirst","Create or import a building first.")) }
        try model.validate()
        let change = session.changeCount
        let saved = await save()
        guard saved.succeeded, change == session.changeCount, !isClosed else { throw CADBuildingError.invalid(saved.error ?? "The design changed while preparing the study.") }
        try Task.checkCancellation()
        if action == .structure {
            guard structural.elasticModulusNPerMM2.isFinite, (1...1e7).contains(structural.elasticModulusNPerMM2),
                  structural.poissonRatio.isFinite, (0..<0.5).contains(structural.poissonRatio),
                  structural.lineLoadNPerMM.isFinite, (0.000001...1e6).contains(structural.lineLoadNPerMM),
                  let id = structural.memberID, model.elements.contains(where: { $0.id == id && $0.kind == .beam }) else {
                throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.selectABeamAndEnterItsMaterial","Select a beam and enter its material, supports and load before analysis."))
            }
        }
        var snapshot = model; snapshot.sources = []
        var geometry: [[String:Any]] = [], triangleCount = 0
        for element in model.elements where element.kind != .space {
            let ids = Set(element.bodyIDs)
            let bodies = session.document.bodies.filter { ids.contains($0.id.raw) }
            guard bodies.count == ids.count else { throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.someBuildingGeometryIsMissingRebuildOr","Some building geometry is missing. Rebuild or review it before export.")) }
            for body in bodies {
                triangleCount += body.render.indices.count/3
                guard triangleCount <= 500_000 else { throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.thisStudyIsLimitedTo500000","This study is limited to 500,000 triangles.")) }
                let vertices = body.render.positions.map { vertex -> [Double] in
                    let p = body.transform.applying(to:SIMD3<Double>(vertex))
                    return [p.x/1000,-p.z/1000,p.y/1000]
                }
                geometry.append(["elementID":element.id.uuidString,"bodyID":body.id.raw.uuidString,
                    "verticesM":vertices,"indices":body.render.indices])
            }
        }
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
        let modelJSON=try JSONSerialization.jsonObject(with:encoder.encode(snapshot))
        let settingsJSON=try JSONSerialization.jsonObject(with:encoder.encode(structural))
        let input=try JSONSerialization.data(withJSONObject:["schemaVersion":1,"action":action.rawValue,
            "revision":revision,"changeCount":change,"modelSHA256":modelSHA256,
            "model":modelJSON,"geometry":geometry,"structural":settingsJSON],options:.sortedKeys)
        guard input.count <= 64 * 1024 * 1024 else { throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.theBuildingStudyIsTooLarge","The building study is too large.")) }
        guard let runnerURL=Bundle.module.url(forResource:"runner",withExtension:"py",subdirectory:"Support") else {
            throw CADBuildingError.invalid(FloeCADStrings.text("cad.building.error.buildingStudyResourcesAreUnavailable","Building study resources are unavailable."))
        }
        let runner=try Data(contentsOf:runnerURL)
        return CADBuildingProfessionalPackage(action:action,revision:revision,changeCount:change,
            sourceSHA256:CADSketchTransferEnvelope.digest(input),files:["input.json":input,"runner.py":runner])
    }
}
