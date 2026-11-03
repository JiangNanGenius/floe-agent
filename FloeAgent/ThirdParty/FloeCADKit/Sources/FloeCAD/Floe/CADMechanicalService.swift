// SPDX-License-Identifier: MPL-2.0
import Foundation
import CoreFoundation
import simd

/// Specialist UI and tool requests share this authority, typed intent and undo path.
@MainActor
final class CADMechanicalService {
    static let actions = ["mechanical.catalog","mechanical.inspect","sheetMetal.create","sheetMetal.update",
                          "weldment.create","weldment.update","weldment.cutList","mechanical.update"]
    static let reads: Set<String> = ["mechanical.catalog","mechanical.inspect","weldment.cutList"]
    let document: FloeCADDocument
    init(document: FloeCADDocument) { self.document = document }
    static func title(_ definition: CADMechanicalDefinition) -> String {
        definition.operation == .singleBendSheet ? FloeCADStrings.text("cad.mechanical.sheet","Single bend sheet")
            : FloeCADStrings.text("cad.mechanical.weldment","Straight weldment")
    }
    func handle(action: String, args: [String:Any]) -> [String:Any] {
        if let refusal = CADServiceOperations.readOnlyRefusal(document:document,kind:"parameter",action:action) { return refusal }
        do {
            if !Self.reads.contains(action), let raw = args["expected_change_count"] {
                guard let value = number(raw), let count = Int(exactly:value), count == document.session.changeCount else {
                    return fail("stale_mechanical","The design changed. Reopen the part settings.")
                }
            }
            switch action {
            case "mechanical.catalog": return ["ok":true,"backend":"OCCT 7.8.1 analytic wires/prisms",
                "sheet_model":"one constant-width straight bend; tangent flange lengths",
                "sheet_fields":["flange_a","flange_b","width","thickness","inner_radius","bend_degrees","k_factor"],
                "k_factor_range":[0,0.5],"bend_degrees_range":[5,150],"stock_profiles":CADWeldmentMember.Stock.allCases.map(\.rawValue),
                "member_limit":64,"cut_ends":"square","material_is_user_label":true,
                "unsupported":["unfold arbitrary imported sheet","multiple bends","relief/corner design","springback",
                               "automatic miter/notch","weld sizing","qualified gear generation"],
                "gear_backend":"unavailable; no qualified native gear adapter is installed"]
            case "mechanical.inspect": return try inspect(args)
            case "weldment.cutList": return try cutList(args)
            case "sheetMetal.create": return try createSheet(args)
            case "weldment.create": return try createWeldment(args)
            case "sheetMetal.update","weldment.update","mechanical.update": return try update(action,args)
            default: return fail("unknown_action","Unknown specialist mechanical action.")
            }
        } catch { return fail("invalid_mechanical",error.localizedDescription) }
    }
    private func fail(_ code: String, _ message: String) -> [String:Any] {
        ["ok":false,"mutated":false,"error":code,"message":message]
    }
    private func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }; return n.doubleValue
    }
    private func expression(_ raw: Any) throws -> Expr {
        if let n = number(raw) { return Expr(value:n) }
        if let formula = raw as? String, let n = ExpressionEvaluator.evaluate(formula,variables:document.session.variableValues()), n.isFinite {
            return Expr(value:n,formula:formula)
        }
        throw CADMechanicalFailure.invalid("Use a finite dimension or a resolvable expression.")
    }
    private func checkKeys(_ fields: [String:Any], _ allowed: Set<String>) throws {
        guard Set(fields.keys).isSubset(of:allowed) else { throw CADMechanicalFailure.invalid("Unsupported mechanical field: " + Set(fields.keys).subtracting(allowed).sorted().joined(separator:", ")) }
    }
    private static let envelope: Set<String> = ["action","revision","expected_revision","expected_change_count"]
    private func frame(_ raw: Any?) throws -> Transform3D {
        guard let raw else { return .identity }
        guard let object = raw as? [String:Any], Set(object.keys).isSubset(of:["translation","rotation","scale"]) else {
            throw CADMechanicalFailure.invalid("Use a rigid placement with translation, rotation and scale=1.")
        }
        let p = try JSONDecoder().decode(Transform3D.self,from:JSONSerialization.data(withJSONObject:object))
        try CADMechanicalDefinition.validatePlacement(p); return p
    }
    private func createSheet(_ args: [String:Any]) throws -> [String:Any] {
        var definition = CADMechanicalDefinition(sheet:CADSheetMetalSpec())
        let fields = args.filter { !Self.envelope.contains($0.key) && $0.key != "placement" }
        definition = try changed(definition,fields)
        return try append(definition,placement:frame(args["placement"]))
    }
    private func createWeldment(_ args: [String:Any]) throws -> [String:Any] {
        try checkKeys(args,Self.envelope.union(["members","placement"]))
        guard let rows = args["members"] as? [[String:Any]], (1...64).contains(rows.count) else {
            throw CADMechanicalFailure.invalid("Provide 1–64 straight member rows.")
        }
        let members = try rows.map { row -> CADWeldmentMember in
            var definition = CADMechanicalDefinition(members:[CADWeldmentMember()])
            var fields = row; fields["member_id"] = definition.members[0].id.uuidString
            definition = try changed(definition,fields); return definition.members[0]
        }
        return try append(CADMechanicalDefinition(members:members),placement:frame(args["placement"]))
    }
    private func append(_ definition: CADMechanicalDefinition, placement: Transform3D) throws -> [String:Any] {
        try definition.validate()
        let node = FeatureNode(name:Self.title(definition),kind:.mechanical(definition:definition,placement:placement),
            outputBodyIDs:(0..<definition.outputCount).map { _ in BodyID() })
        guard document.session.performAssociativeTransaction([AppendFeatureCommand(node:node)],title:Self.title(definition)) else { return rebuildFailure() }
        return describeReply(node,mutated:true)
    }
    private func existing(_ args: [String:Any]) throws -> (FeatureNode,CADMechanicalDefinition,Transform3D) {
        guard let raw = args["feature_id"] as? String, let uuid = UUID(uuidString:raw),
              let node = document.session.document.features.node(FeatureID(raw:uuid)),
              case let .mechanical(definition,placement) = node.kind else {
            throw CADMechanicalFailure.invalid("Choose an existing specialist feature.")
        }
        let graph = document.session.document.features
        let prefix = graph.nodes.prefix(max(0,min(graph.rollbackIndex ?? graph.nodes.count,graph.nodes.count)))
        guard prefix.contains(where:{ $0.id == node.id }), !node.suppressed,
              node.outputBodyIDs.count == definition.outputCount, Set(node.outputBodyIDs).count == definition.outputCount else {
            throw CADMechanicalFailure.invalid("Restore the feature in history before inspecting or editing it.")
        }
        return (node,definition,placement)
    }
    private func update(_ action: String, _ args: [String:Any]) throws -> [String:Any] {
        try checkKeys(args,Self.envelope.union(["feature_id","changes"]))
        let (node,before,placement) = try existing(args)
        guard action == "mechanical.update" || (action == "sheetMetal.update" && before.operation == .singleBendSheet)
                || (action == "weldment.update" && before.operation == .straightWeldment),
              let fields = args["changes"] as? [String:Any], !fields.isEmpty else {
            throw CADMechanicalFailure.invalid("Use the matching feature update and a changes object.")
        }
        let after = try changed(before,fields)
        if before == after { return describeReply(node,mutated:false) }
        guard document.session.performAssociativeTransaction([EditFeatureCommand(featureID:node.id,before:node.kind,
            after:.mechanical(definition:after,placement:placement))],title:Self.title(after)) else { return rebuildFailure() }
        let updated = document.session.document.features.node(node.id) ?? node
        return describeReply(updated,mutated:true)
    }
    private func changed(_ initial: CADMechanicalDefinition, _ fields: [String:Any]) throws -> CADMechanicalDefinition {
        var definition = initial, remaining = fields
        if definition.operation == .straightWeldment,
           let raw = remaining.removeValue(forKey:"member_id") as? String {
            guard let id = UUID(uuidString:raw), let index = definition.members.firstIndex(where:{ $0.id == id }) else {
                throw CADMechanicalFailure.invalid("The member identity is no longer present.")
            }
            for key in ["width","depth","wall","length"] {
                if let raw = remaining.removeValue(forKey:key) {
                    definition = definition.replacing("member." + id.uuidString + "." + key,with:try expression(raw)) ?? definition
                }
            }
            if let raw = remaining.removeValue(forKey:"profile") {
                guard let string = raw as? String, let profile = CADWeldmentMember.Stock(rawValue:string) else {
                    throw CADMechanicalFailure.invalid("Choose a supported stock profile.")
                }
                definition.members[index].profile = profile
            }
            if let raw = remaining.removeValue(forKey:"material") {
                guard let text = raw as? String else { throw CADMechanicalFailure.invalid("Use a material name.") }
                definition.members[index].material = text
            }
            if let raw = remaining.removeValue(forKey:"placement") { definition.members[index].placement = try frame(raw) }
        }
        let keys = Set(definition.expressions.map(\.name))
        try checkKeys(remaining,keys)
        for (key,raw) in remaining { definition = definition.replacing(key,with:try expression(raw)) ?? definition }
        try definition.resolved(variables:document.session.variableValues()).validate()
        return definition
    }
    private func rebuildFailure() -> [String:Any] {
        var response = fail("mechanical_rebuild_failed","The part could not be rebuilt. The previous shape was kept.")
        response["details"] = document.session.lastRejectedFeatureErrors.values.map { String(describing:$0) }
            + document.session.lastRebuildRejection.values.map(\.message)
        return response
    }
    private func describeReply(_ node: FeatureNode, mutated: Bool) -> [String:Any] {
        guard case let .mechanical(definition,_) = node.kind else { return fail("missing_mechanical","The part is unavailable.") }
        var reply = Self.describe(definition)
        reply["ok"] = true; reply["mutated"] = mutated; reply["feature_id"] = node.id.raw.uuidString
        reply["body_ids"] = node.outputBodyIDs.map { $0.raw.uuidString }
        reply["revision"] = document.revision; reply["change_count"] = document.session.changeCount
        reply["can_undo"] = document.session.undoStack.canUndo; reply["can_redo"] = document.session.undoStack.canRedo
        return reply
    }
    static func describe(_ definition: CADMechanicalDefinition) -> [String:Any] {
        var response: [String:Any] = ["operation":definition.operation.rawValue,"semantic_version":definition.version,
            "update_action":"mechanical.update","editable_fields":definition.expressions.map(\.name),
            "definition":(try? JSONSerialization.jsonObject(with:JSONEncoder().encode(definition))) ?? NSNull()]
        if let s = definition.sheet {
            response["flange_dimension_basis"] = "tangent"; response["bend_allowance"] = s.bendAllowance
            response["blank_length"] = s.blankLength; response["k_factor_is_user_input"] = true
            response["output_order"] = ["formed","flat"]
        } else {
            response["member_ids"] = definition.members.map { $0.id.uuidString }
            response["output_order"] = definition.members.map { $0.id.uuidString }
        }
        return response
    }
    private func inspect(_ args: [String:Any]) throws -> [String:Any] {
        if args["feature_id"] != nil {
            let (node,_,_) = try existing(args)
            var reply = describeReply(node,mutated:false)
            reply["bodies"] = try node.outputBodyIDs.map { id -> [String:Any] in
                guard let body = document.session.document.body(with:id), let solid = body.brep else {
                    throw CADMechanicalFailure.invalid("A specialist output has no exact solid.")
                }
                return ["body_id":id.raw.uuidString,"native_volume":OCCTKernel.volume(solid),
                    "closed_solid":solid.containsSolid,"health":OCCTKernel.healthReportDictionary(for:solid,runBOPCheck:true)]
            }
            return reply
        }
        let rows = document.session.document.features.nodes.compactMap { node -> [String:Any]? in
            guard case .mechanical = node.kind else { return nil }; return describeReply(node,mutated:false)
        }
        return ["ok":true,"rows":rows]
    }
    private func cutList(_ args: [String:Any]) throws -> [String:Any] {
        let (node,definition,placement) = try existing(args)
        guard definition.operation == .straightWeldment else { throw CADMechanicalFailure.invalid("Select a straight weldment.") }
        let resolved = try definition.resolved(variables:document.session.variableValues())
        let expected = try CADMechanicalKernel.build(resolved,placement:placement)
        var rows: [[String:Any]] = []
        let graph = document.session.document.features
        let active = graph.nodes.prefix(max(0,min(graph.rollbackIndex ?? graph.nodes.count,graph.nodes.count)))
        for (index,member) in resolved.members.enumerated() {
            let id = node.outputBodyIDs[index]
            // Do not report old authored length after direct edits, later cuts, scale or writer replacement.
            let writer = document.session.lastBodyWriters[id] ?? active.last { !$0.suppressed && $0.outputBodyIDs.contains(id) }?.id
            guard writer == node.id, let body = document.session.document.body(with:id), let solid = body.brep,
                  body.transform == expected[index].placement else {
                throw CADMechanicalFailure.invalid("A member has subsequent edits. Restore the weldment outputs before generating its square-cut stock list.")
            }
            let mesh = OCCTKernel.renderMesh(from:expected[index].handle)
            guard body.render == RenderMesh(positions:mesh.positions,normals:mesh.normals,indices:mesh.indices) else {
                throw CADMechanicalFailure.invalid("A member no longer matches its manufacturing definition.")
            }
            let length = try CADMechanicalKernel.measuredLength(solid), volume = OCCTKernel.volume(solid)
            guard abs(length-member.length.value) < 1e-6, abs(volume-length*member.sectionArea) < max(1e-5,volume*1e-7) else {
                throw CADMechanicalFailure.invalid("Native stock measurements no longer match the cut list.")
            }
            rows.append(["member_id":member.id.uuidString,"body_id":id.raw.uuidString,"profile":member.profile.rawValue,
                         "width":member.width.value,"depth":member.depth.value,"wall":member.wall.value,
                         "length":length,"volume":volume,"section_area":volume/length,"material":member.material,"quantity":1])
        }
        // Conservative equality: distinct exact stock parameters never collapse through display rounding.
        var groups: [[String:Any]] = []
        for row in rows {
            let keys = ["profile","width","depth","wall","length","material"]
            if let i = groups.firstIndex(where: { group in keys.allSatisfy { key in
                String(describing:group[key]!) == String(describing:row[key]!)
            } }) {
                groups[i]["quantity"] = (groups[i]["quantity"] as? Int ?? 0)+1
                groups[i]["total_length"] = (groups[i]["total_length"] as? Double ?? 0)+(row["length"] as? Double ?? 0)
                groups[i]["total_volume"] = (groups[i]["total_volume"] as? Double ?? 0)+(row["volume"] as? Double ?? 0)
                groups[i]["member_ids"] = (groups[i]["member_ids"] as? [String] ?? []) + [row["member_id"] as! String]
            } else {
                var group = row; group.removeValue(forKey:"member_id"); group.removeValue(forKey:"body_id")
                group["member_ids"] = [row["member_id"] as! String]; group["total_length"] = row["length"]; group["total_volume"] = row["volume"]; groups.append(group)
            }
        }
        return ["ok":true,"mutated":false,"feature_id":node.id.raw.uuidString,"rows":rows,"groups":groups,
                "end_cut":"square","measurement":"OCCT planar end separation and exact solid volume"]
    }
}
