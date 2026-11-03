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
                return ["ok":true,"mutated":false,"feature_id":node.id.raw.uuidString,"sections":json(sections),
                    "definition":definition.map { json($0) } ?? NSNull(),"update_action":"loft.update",
                    "supported":["section_replacement","section_reordering","ruled","exact_paired_inner_loops"],
                    "unsupported":["guide_constraints","specified_start_end_tangency","specified_start_end_curvature"],
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
