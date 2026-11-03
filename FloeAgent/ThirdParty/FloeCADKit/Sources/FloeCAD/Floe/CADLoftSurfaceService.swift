import Foundation
import CoreFoundation

/// One source of truth for native settings and assistant parameter actions.
/// Both create/update call the existing graph transaction: one feature, one
/// undo, all downstream bodies rebuilt, failed edits preserve the old design.
@MainActor
final class CADLoftSurfaceService {
    static let actions = ["loft.describe","loft.create","loft.update","surface.catalog","surface.create","surface.update","surface.inspect"]
    static let reads: Set<String> = ["loft.describe","surface.catalog","surface.inspect"]
    private let document: FloeCADDocument
    init(document: FloeCADDocument) { self.document=document }
    private func failure(_ code: String, _ detail: String) -> [String: Any] {
        ["ok":false,"mutated":false,"error":code,
         "message":FloeCADStrings.text("cad.feature.editRejected","Couldn't change this feature. Check its values and references."),
         "details":[detail]]
    }
    private func number(_ raw: Any?) -> Double? {
        guard let n=raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    private func decode<T: Decodable>(_ value: Any?, as type: T.Type) throws -> T {
        guard let value, JSONSerialization.isValidJSONObject(value) else {
            throw LoftSurfaceError.invalid("Provide the typed definition object.")
        }
        return try JSONDecoder().decode(type,from:JSONSerialization.data(withJSONObject:value))
    }
    private func json<T: Encodable>(_ value: T) -> Any {
        (try? JSONSerialization.jsonObject(with:JSONEncoder().encode(value))) ?? NSNull()
    }
    private func feature(_ args: [String:Any]) throws -> FeatureNode {
        guard let text=args["feature_id"] as? String, let raw=UUID(uuidString:text),
              let node=document.session.document.features.node(FeatureID(raw:raw)) else {
            throw LoftSurfaceError.invalid("Select the existing feature_id.")
        }
        return node
    }
    private static var guidedRuns:[ObjectIdentifier:UUID]=[:]
    #if DEBUG
    static var testBeforeGuidedPrepare: (@Sendable ()->Void)?
    static var testAfterGuidedPrepare: (@MainActor ()->Void)?
    #endif
    /// The same loft.create/update authority, with an off-main preparation
    /// phase. Commit still uses the existing single transaction and replays
    /// downstream features with freshly deserialized, identity-bound geometry.
    func handleAsync(action:String,args:[String:Any]) async -> [String:Any] {
        guard action == "loft.create" || action == "loft.update" else { return handle(action:action,args:args) }
        if let refusal=CADServiceOperations.readOnlyRefusal(document:document,kind:"parameter",action:action) { return refusal }
        do {
            let node:FeatureNode?=action == "loft.update" ? try feature(args) : nil
            let oldSections:[ProfileRef],oldDefinition:LoftDefinition?
            if let node {
                guard case let .loft(sections,_,definition)=node.kind else { throw LoftSurfaceError.invalid("This is not a loft feature.") }
                oldSections=sections;oldDefinition=definition
            } else { oldSections=[];oldDefinition=nil }
            let changes=action == "loft.update" ? (args["changes"] as? [String:Any] ?? [:]) : args
            let sections=try changes["sections"].map { try decode($0,as:[ProfileRef].self) } ?? oldSections
            let definition:LoftDefinition
            if let raw=changes["definition"] {
                if raw is NSNull { definition=LoftDefinition() }
                else { definition=try decode(raw,as:LoftDefinition.self) }
            } else { definition=oldDefinition ?? LoftDefinition() }
            guard !definition.guides.isEmpty || oldDefinition?.guides.isEmpty == false || definition.hasEndpointConstraints || oldDefinition?.hasEndpointConstraints == true else { return handle(action:action,args:args) }
            try definition.requireSupported(sectionCount:sections.count)
            let generation=document.session.changeCount
            if let raw=args["expected_change_count"] {
                guard let number=number(raw),Int(exactly:number) == generation else { return failure("stale_feature","The design changed. Read the current feature before calculating.") }
            }
            let owner=ObjectIdentifier(document),run=UUID()
            guard Self.guidedRuns[owner] == nil,Self.guidedRuns.count < 2 else { return failure("guided_loft_busy","A guided calculation is finishing. Try again after it stops.") }
            Self.guidedRuns[owner]=run
            defer { if Self.guidedRuns[owner] == run { Self.guidedRuns.removeValue(forKey:owner) } }
            var snapshots:[CADGuidedLoftSnapshot]=[]
            if let oldDefinition,!oldDefinition.guides.isEmpty {
                snapshots.append(try document.session.guidedLoftSnapshot(sections:oldSections,definition:oldDefinition,before:node?.id))
            }
            if !definition.guides.isEmpty {
                snapshots.append(try document.session.guidedLoftSnapshot(sections:sections,definition:definition,before:node?.id))
            }
            var endpointSnapshots:[CADLoftEndpointSnapshot]=[]
            if let oldDefinition,oldDefinition.hasEndpointConstraints {
                endpointSnapshots += try document.session.endpointLoftSnapshots(sections:oldSections,definition:oldDefinition,before:node?.id)
            }
            if definition.hasEndpointConstraints {
                endpointSnapshots += try document.session.endpointLoftSnapshots(sections:sections,definition:definition,before:node?.id)
            }
            #if DEBUG
            let probe=Self.testBeforeGuidedPrepare
            #else
            let probe:(@Sendable ()->Void)?=nil
            #endif
            let guidedReady=await CADGuidedLoftPreparation.prepare(snapshots,probe:endpointSnapshots.isEmpty ? probe:nil)
            let endpointReady=guidedReady ? await CADLoftEndpointPreparation.prepare(endpointSnapshots,probe:endpointSnapshots.isEmpty ? nil:probe):false
            let ready=guidedReady && endpointReady
            #if DEBUG
            Self.testAfterGuidedPrepare?()
            #endif
            guard !document.isClosed else { return failure("document_closed","The document is closed. The calculation was discarded.") }
            guard !Task.isCancelled else { return failure("guided_loft_cancelled","The native phase finished; its cancelled result was discarded.") }
            guard document.session.changeCount == generation else { return failure("stale_feature","The design changed during calculation. Nothing was applied.") }
            guard ready else { return failure("guided_loft_refused","The native loft failed its bounded section, boundary or topology checks. Nothing changed.") }
            // handle rechecks revision/read-only and owns one ordinary undo.
            var reply=handle(action:action,args:args)
            if reply["ok"] as? Bool == true,!definition.guides.isEmpty,let snapshot=snapshots.last,let report=CADGuidedLoftStore.shared.cached(snapshot)?.metrics {
                reply["guided_validation"]=report.dictionary;reply["exactness"]="nativeToleranceBRep"
            }
            if reply["ok"] as? Bool == true,definition.hasEndpointConstraints {
                let count=(sections.first?.holeEntityIDs.count ?? 0)+1
                reply["endpoint_validation"]=endpointSnapshots.suffix(count).compactMap { CADLoftEndpointStore.shared.cached($0)?.report }
                reply["exactness"]="exactSectionConstrainedBRep"
            }
            return reply
        } catch { return failure("invalid_guided_loft",error.localizedDescription) }
    }

    func handle(action: String, args: [String:Any]) -> [String:Any] {
        if let refusal=CADServiceOperations.readOnlyRefusal(document:document,kind:"parameter",action:action) { return refusal }
        do {
            if !Self.reads.contains(action), let raw=args["expected_change_count"] {
                guard let value=number(raw), let expected=Int(exactly:value), expected == document.session.changeCount else {
                    return failure("stale_feature","The design changed. Read its current feature before editing.")
                }
            }
            switch action {
            case "surface.catalog":
                return ["ok":true,"mutated":false,"actions":Self.actions,
                    "definition_version":1,"package_floor":7,
                    "operations":["loft","trim","patch","sew","thicken"],
                    "loft_create_inputs":["sections","definition","boolean","expected_change_count"],
                    "loft_update_inputs":["feature_id","changes.sections","changes.definition","expected_change_count"],
                    "inspect_inputs":["body_id","before_feature_id?"],
                    "create_inputs":["definition"],"update_inputs":["feature_id","definition","expected_change_count"],
                    "definition_fields":["version","operation","sections","sources","ruled","tolerance","trim","thickness","requireClosed"],
                    "section_schema":"SweepPathDefinition {version:1,segments:[{sketchID,entityID,reversed}]}; one sketch per open section, equal edge counts",
                    "source_schema":"BodyRef from the current feature: {producer:{raw:uuid},bodyID:{raw:uuid}}",
                    "trim_schema":"{uMin,uMax,vMin,vMax}; read current face_domains with surface.inspect",
                    "thickness_units":"signed mm; open: authored normal, closed: positive outward",
                    "patch_scope":"all closed planar free-boundary wires; one connected shell",
                    "sew_scope":"exact authored surfaces; requireClosed:true rejects remaining free edges",
                    "unsupported":["nonrectangular_UV_trim","nonplanar_patch","unowned_import_surface_inputs"],
                    "limits":["sections":64,"edges_per_section":256,"total_edges":2048,"native_curve_bytes":8_388_608]]
            case "loft.describe":
                let node=try feature(args)
                guard case let .loft(sections,_,definition)=node.kind else { throw LoftSurfaceError.invalid("This is not a loft feature.") }
                var report:Any=NSNull()
                if let definition,!definition.guides.isEmpty,
                   let snapshot=try? document.session.guidedLoftSnapshot(sections:sections,definition:definition,before:node.id),
                   let measured=CADGuidedLoftStore.shared.cached(snapshot)?.metrics { report=measured.dictionary }
                let endpointReports:Any
                if let definition,definition.hasEndpointConstraints,
                   let inputs=try? document.session.endpointLoftSnapshots(sections:sections,definition:definition,before:node.id) {
                    endpointReports=inputs.compactMap { CADLoftEndpointStore.shared.cached($0)?.report }
                } else { endpointReports=NSNull() }
                return ["ok":true,"mutated":false,"feature_id":node.id.raw.uuidString,"sections":json(sections),
                    "endpoint_validation":endpointReports,"guided_validation":report,
                    "definition":definition.map { json($0) } ?? NSNull(),"update_action":"loft.update",
                    "supported":["section_replacement","section_reordering","ruled","exact_paired_inner_loops","single_auxiliary_guide_native_tolerance","specified_longitudinal_endpoint_direction","specified_longitudinal_normal_curvature"],
                    "guided_scope":"2–8 parallel normal-plane sections on their origin main spine; one ordered auxiliary Contact guide; no inner loops or ruled; exact line/conic inputs; native tolerance BRep",
                    "guided_precision":"OCCT ErrorOnSurface plus explicitly sampled independent rail/section deviations; no whole-curve distance certificate",
                    "endpoint_scope":"2–4 equally spaced parallel normal-plane sections; up to 16 compatible exact edges/256 U poles per loop; common rational weights; up to three paired holes; no ruled or guide combination",
                    "boundary_schema":"{tangent:{point:[x,y,z]},curvature?:{point:[kx,ky,kz]},angularTolerance:rad,curvatureTolerance:1/mm}; both directions follow first-to-last section; curvature is perpendicular longitudinal normal curvature, not adjacent-face G2",
                    "unsupported":["multiple_guides","guided_inner_loops","guide_plus_endpoints","adjacent_support_face_G2","unequal_rational_weights"],
                    "change_count":document.session.changeCount]
            case "loft.create":
                guard document.session.document.features.rollbackIndex == nil else {
                    throw LoftSurfaceError.invalid("Return to the latest history before creating a loft.")
                }
                let sections=try decode(args["sections"],as:[ProfileRef].self)
                let definition: LoftDefinition?
                if let raw=args["definition"], !(raw is NSNull) { definition=try decode(raw,as:LoftDefinition.self) }
                else { definition=LoftDefinition() }
                try (definition ?? LoftDefinition()).requireSupported(sectionCount:sections.count)
                let boolean: BooleanIntent
                if let raw=args["boolean"] { boolean=try decode(raw,as:BooleanIntent.self) }
                else { boolean=BooleanIntent(op:.newBody,resolvedTargets:[]) }
                guard (boolean.op == .newBody && boolean.resolvedTargets.isEmpty) || (boolean.op != .newBody && boolean.resolvedTargets.count == 1
                    && document.session.document.body(with:boolean.resolvedTargets[0].bodyID)?.brep != nil) else {
                    throw LoftSurfaceError.invalid("Choose one existing exact solid for the loft boolean.")
                }
                let output=boolean.op == .newBody ? BodyID() : boolean.resolvedTargets[0].bodyID
                let node=FeatureNode(name:FloeCADStrings.text("cad.ui.tool.loft","Loft"),
                    kind:.loft(sections:sections,boolean:boolean,definition:definition),outputBodyIDs:[output])
                let hidden=Set(sections.map(\.sketchID)).compactMap { id -> DocumentCommand? in
                    guard let source=document.session.document.sketches.first(where:{ $0.id == id }),!source.isHidden else { return nil }
                    return SetItemVisibilityCommand(item:.sketch(id),isHidden:true)
                }
                guard document.session.performAssociativeTransaction([AppendFeatureCommand(node:node)]+hidden,title:node.name) else {
                    return rejected()
                }
                return reply(node)
            case "loft.update":
                let node=try feature(args)
                guard case let .loft(beforeSections,boolean,beforeDefinition)=node.kind,
                      let changes=args["changes"] as? [String:Any], !changes.isEmpty,
                      Set(changes.keys).isSubset(of:["sections","definition"]) else {
                    throw LoftSurfaceError.invalid("Use changes.sections and/or changes.definition on an existing loft.")
                }
                let sections: [ProfileRef] = try changes["sections"].map { try decode($0,as:[ProfileRef].self) } ?? beforeSections
                let definition: LoftDefinition?
                if let raw=changes["definition"] {
                    if raw is NSNull { definition=LoftDefinition() }
                    else { definition=try decode(raw,as:LoftDefinition.self) }
                } else { definition=beforeDefinition ?? LoftDefinition() }
                try (definition ?? LoftDefinition()).requireSupported(sectionCount:sections.count)
                return commit(node,kind:.loft(sections:sections,boolean:boolean,definition:definition),title:FloeCADStrings.text("cad.cmd.model.loft","Loft"))
            case "surface.create":
                guard document.session.document.features.rollbackIndex == nil else {
                    throw LoftSurfaceError.invalid("Return to the latest history before creating a surface step.")
                }
                let definition=try decode(args["definition"],as:CADSurfaceDefinition.self)
                try definition.validate()
                let id=definition.sources.first?.bodyID ?? BodyID()
                let node=FeatureNode(name:Self.surfaceTitle(definition.operation),
                    kind:.surface(definition:definition),outputBodyIDs:[id])
                guard document.session.performAssociativeTransaction([AppendFeatureCommand(node:node)],title:node.name) else {
                    return rejected()
                }
                return reply(node)
            case "surface.update":
                let node=try feature(args)
                guard case let .surface(before)=node.kind else { throw LoftSurfaceError.invalid("This is not a surface feature.") }
                let after=try decode(args["definition"],as:CADSurfaceDefinition.self)
                try after.validate()
                guard before.operation == after.operation,
                      after.operation == .loft || after.sources.first?.bodyID == node.outputBodyIDs.first else {
                    throw LoftSurfaceError.invalid("Edit this same surface step without changing its operation or original body identity.")
                }
                return commit(node,kind:.surface(definition:after),title:FloeCADStrings.text("cad.material.section.surface","Surface"))
            case "surface.inspect":
                guard let text=args["body_id"] as? String,let raw=UUID(uuidString:text) else {
                    throw LoftSurfaceError.invalid("Select a current exact body_id.")
                }
                let input: EvalResult?
                let before: FeatureID?
                if let value=args["before_feature_id"] {
                    guard let text=value as? String,let id=UUID(uuidString:text),
                          document.session.document.features.node(FeatureID(raw:id)) != nil else {
                        throw LoftSurfaceError.invalid("Select the existing feature whose input surface you need.")
                    }
                    before=FeatureID(raw:id)
                    input=document.session.inputState(before:FeatureID(raw:id))
                } else { before=nil;input=document.session.previewLoftSurface() }
                let body: Body?
                if before != nil { body=input?.bodies.first { $0.id == BodyID(raw:raw) } }
                else { body=document.session.document.body(with:BodyID(raw:raw)) }
                guard let body,let native=body.surfaceBRep ?? body.brep,
                      let handle=OCCTKernel.transformed(native,by:body.transform) else {
                    throw LoftSurfaceError.invalid("The exact body is unavailable in the requested history state.")
                }
                var reply=OCCTKernel.surfaceDiagnostics(handle)
                reply["ok"] = reply["error"] == nil
                reply["mutated"]=false;reply["body_id"]=text;reply["mesh_revision"]=body.meshRevision
                reply["scope"]=before == nil ? "current" : "featureInput"
                reply["before_feature_id"]=before.map { $0.raw.uuidString as Any } ?? NSNull()
                reply["revision"]=document.revision;reply["change_count"]=document.session.changeCount
                reply["quality"] = handle.containsSolid ? "exactBRepSolid" : "exactBRepSurface"
                reply["health"]=OCCTKernel.healthReportDictionary(for:handle)
                if body.surfaceBRep != nil,let writer=input?.lastBodyWriters[body.id],!document.session.isReadOnly {
                    reply["source"]=json(BodyRef(producer:writer,bodyID:body.id));reply["authoring_input"]=true
                } else { reply["source"]=NSNull();reply["authoring_input"]=false }
                return reply
            default: return failure("unknown_action","Unknown loft/surface action.")
            }
        } catch { return failure("invalid_loft_surface",error.localizedDescription) }
    }
    static func surfaceTitle(_ operation: CADSurfaceDefinition.Operation) -> String {
        switch operation {
        case .loft:return FloeCADStrings.text("cad.material.section.surface","Surface")
        case .trim:return FloeCADStrings.text("cad.loftSurface.trim","Trim")
        case .patch:return FloeCADStrings.text("cad.loftSurface.patch","Fill planar openings")
        case .sew:return FloeCADStrings.text("cad.loftSurface.sew","Sew surfaces")
        case .thicken:return FloeCADStrings.text("cad.loftSurface.thicken","Thicken")
        }
    }
    private func commit(_ node: FeatureNode, kind: FeatureKind, title: String) -> [String:Any] {
        let encoder=JSONEncoder(); encoder.outputFormatting=[.sortedKeys]
        if let before=try? encoder.encode(node.kind), let after=try? encoder.encode(kind), before == after {
            return ["ok":true,"mutated":false,"feature_id":node.id.raw.uuidString]
        }
        guard document.session.performAssociativeTransaction([
            EditFeatureCommand(featureID:node.id,before:node.kind,after:kind)
        ],title:title) else { return rejected() }
        return reply(node)
    }
    private func rejected() -> [String:Any] {
        var result=failure("loft_surface_rebuild_failed","The exact feature could not be rebuilt. Nothing changed.")
        result["details"]=document.session.lastRejectedFeatureErrors.values.map { String(describing:$0) }
            + document.session.lastRebuildRejection.values.map(\.message)
        return result
    }
    private func reply(_ node: FeatureNode) -> [String:Any] {
        let current=document.session.document.features.node(node.id) ?? node
        return ["ok":true,"mutated":true,"feature_id":current.id.raw.uuidString,
            "body_ids":current.outputBodyIDs.map { $0.raw.uuidString },"definition":json(current.kind),
            "revision":document.revision,"change_count":document.session.changeCount,
            "can_undo":document.session.undoStack.canUndo,"can_redo":document.session.undoStack.canRedo]
    }
}
