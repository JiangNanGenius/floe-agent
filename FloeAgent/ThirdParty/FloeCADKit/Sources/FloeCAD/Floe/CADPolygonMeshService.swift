import Foundation
import CoreFoundation
import simd

/// Polygon edits use the same mesh service/proposal router, feature graph,
/// checkpoint, undo and save authority as existing document geometry.
@MainActor
final class CADPolygonMeshService {
    nonisolated static let actions = ["topology.create","topology.capture","topology.inspect","topology.extrude","topology.loopCut","topology.inset","topology.weld","modifier.add","modifier.update","modifier.move","modifier.remove"]
    nonisolated static let mutatingActions = Set(actions.filter { $0 != "topology.inspect" })
    private static var active: [ObjectIdentifier: CADMeshCancellation] = [:]
    private static var activeActions: [ObjectIdentifier: String] = [:]
    static func activeOperationStatus(for document: FloeCADDocument) -> [String: Any]? {
        let key = ObjectIdentifier(document)
        guard let token = active[key] else { return nil }
        return ["ok":true,"active":true,"action":activeActions[key] ?? "topology",
                "cancelRequested":token.isCancelled,"mutated":false]
    }
    static func cancelActiveOperation(for document: FloeCADDocument) -> Bool {
        guard let token = active[ObjectIdentifier(document)] else { return false }; token.cancel(); return true
    }
    /// One source authority for service and visible cage picking. A direct
    /// mesh edit cannot be overwritten with an older stored cage. Cold reopen
    /// may lack a writer memo, so the active graph prefix is the fallback.
    static func currentCage(in session: DocumentSession, bodyID: BodyID) -> (node: FeatureNode, definition: CADPolygonMeshDefinition, body: Body)? {
        guard let body = session.document.body(with: bodyID), body.brep == nil, body.surfaceBRep == nil,
              (try? CADPolygonMeshDefinition.validatePlacement(body.transform)) != nil else { return nil }
        let graph = session.document.features
        let prefix = graph.nodes.prefix(max(0,min(graph.rollbackIndex ?? graph.nodes.count,graph.nodes.count)))
        let node: FeatureNode?
        if let writer = session.lastBodyWriters[bodyID] { node = prefix.first { $0.id == writer && !$0.suppressed } }
        else { node = prefix.last { !$0.suppressed && $0.outputBodyIDs.contains(bodyID) } }
        guard let node, case let .polygonCage(definition, _) = node.kind,
              let evaluated = try? CADPolygonMeshKernel.evaluate(definition), evaluated.render == body.render else { return nil }
        return (node,definition,body)
    }
    private let document: FloeCADDocument
    init(document: FloeCADDocument) { self.document = document }
    private nonisolated enum Edit: Sendable {
        case unchanged
        case extrude(UUID,Double), inset(UUID,Double), loopCut(UUID,Double), weld([UUID],Double)
    }
    private nonisolated struct Plan: Sendable {
        var node: FeatureNode
        var body: BodyID
        var definition: CADPolygonMeshDefinition
        var placement: Transform3D
        var edit: Edit
        var creating: Bool
        var changeCount: Int
    }
    func handle(action: String, args: [String: Any]) -> [String: Any] {
        do {
            if action == "topology.inspect" { return try inspect(args) }
            let plan = try prepare(action,args)
            let token = CADMeshCancellation()
            if Task.isCancelled { token.cancel() }
            let changed = try Self.compute(plan,cancellation: token)
            return try commit(plan,definition: changed,cancellation: token)
        } catch { return Self.fail(error) }
    }
    func handleAsync(action: String, args: [String: Any]) async -> [String: Any] {
        do {
            if action == "topology.inspect" { return try inspect(args) }
            let plan = try prepare(action,args), cancellation = CADMeshCancellation()
            let owner = ObjectIdentifier(document)
            _ = CADMeshService.cancelActiveOperation(for: document)
            Self.active[owner] = cancellation; Self.activeActions[owner] = action
            defer { if Self.active[owner] === cancellation { Self.active.removeValue(forKey: owner); Self.activeActions.removeValue(forKey: owner) } }
            let result: Result<CADPolygonMeshDefinition,CADPolygonFailure> = await withTaskCancellationHandler {
                await Task.detached(priority: .userInitiated) {
                    do { return .success(try Self.compute(plan,cancellation: cancellation)) }
                    catch let failure as CADPolygonFailure { return .failure(failure) }
                    catch { return .failure(.invalid(error.localizedDescription)) }
                }.value
            } onCancel: { cancellation.cancel() }
            return try commit(plan,definition: result.get(),cancellation: cancellation)
        } catch { return Self.fail(error) }
    }
    private func prepare(_ action: String, _ args: [String: Any]) throws -> Plan {
        guard !document.isClosed else { throw CADPolygonFailure.invalid("The document is closed.") }
        if let block = document.session.writeBlock { throw CADPolygonFailure.invalid(block.message) }
        let session = document.session
        let bodyID: BodyID, node: FeatureNode, creating: Bool, placement: Transform3D
        var definition: CADPolygonMeshDefinition
        if action == "topology.create" {
            bodyID = BodyID(); placement = .identity; creating = true
            definition = .init(cage: try .box(width: try Self.number(args,"width",default: 10),height: try Self.number(args,"height",default: 10),depth: try Self.number(args,"depth",default: 10)))
            node = FeatureNode(name: FloeCADStrings.text("cad.mesh.cage","Polygon cage"),kind: .polygonCage(definition: definition,placement: placement),outputBodyIDs: [bodyID])
        } else if action == "topology.capture" {
            bodyID = BodyID(raw: try Self.uuid(args,"bodyID")); creating = true
            guard let body = session.document.body(with: bodyID), body.surfaceBRep == nil,
                  body.render.triangleCount <= 4096 else { throw CADPolygonFailure.unsupported("Capture needs one bounded mesh body; exact open surfaces are unavailable.") }
            guard body.brep == nil || args["forceMesh"] as? Bool == true else { throw CADPolygonFailure.unsupported("Enable mesh conversion before capturing an exact solid.") }
            guard body.uvData == nil, body.materialFaceBindings.isEmpty, body.render.texcoords == nil else { throw CADPolygonFailure.unsupported("Capture cannot yet retain face materials or UV editing. The source was kept.") }
            placement = body.transform
            definition = .init(cage: try .capture(body.euclidMesh()))
            node = FeatureNode(name: FloeCADStrings.text("cad.mesh.cage","Polygon cage"),kind: .polygonCage(definition: definition,placement: placement),outputBodyIDs: [bodyID])
        } else {
            bodyID = BodyID(raw: try Self.uuid(args,"bodyID"))
            guard let currentCage = Self.currentCage(in: session, bodyID: bodyID) else {
                throw CADPolygonFailure.unsupported("Select the latest editable polygon cage. Capture a new cage after other mesh edits.")
            }
            let owner = currentCage.node, value = currentCage.definition, transform = currentCage.body.transform
            guard let current = session.document.body(with: bodyID), current.uvData == nil,
                  current.materialFaceBindings.isEmpty, current.render.texcoords == nil else {
                throw CADPolygonFailure.unsupported("This cage has face materials or UV editing that cannot yet follow a topology change. The body was kept.")
            }
            node = owner; definition = value; placement = transform; creating = false
            guard args["cageDigest"] as? String == definition.digest else { throw CADPolygonFailure.invalid("The cage changed. Refresh its selection before editing.") }
        }
        let edit: Edit
        switch action {
        case "topology.create","topology.capture": edit = .unchanged
        case "topology.extrude": edit = .extrude(try Self.uuid(args,"faceID"),try Self.number(args,"distance"))
        case "topology.inset": edit = .inset(try Self.uuid(args,"faceID"),try Self.number(args,"distance"))
        case "topology.loopCut": edit = .loopCut(try Self.uuid(args,"edgeID"),try Self.number(args,"fraction",default: 0.5))
        case "topology.weld":
            guard let values = args["vertexIDs"] as? [String], (2...8).contains(values.count),
                  values.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw CADPolygonFailure.invalid("Choose existing vertex identities.") }
            edit = .weld(values.compactMap(UUID.init(uuidString:)),try Self.number(args,"tolerance"))
        case "modifier.add":
            definition.modifiers.append(.init(operation: try Self.operation(args))); edit = .unchanged
        case "modifier.update":
            let id = try Self.uuid(args,"modifierID")
            guard let i = definition.modifiers.firstIndex(where: { $0.id == id }) else { throw CADPolygonFailure.invalid("The modifier is missing.") }
            if let raw = args["enabled"] {
                guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw CADPolygonFailure.invalid("enabled must be a boolean.") }
                definition.modifiers[i].enabled = value.boolValue
            }
            if args["kind"] != nil { definition.modifiers[i].operation = try Self.operation(args) }
            edit = .unchanged
        case "modifier.move":
            let id = try Self.uuid(args,"modifierID"), raw = try Self.number(args,"index")
            guard raw.rounded() == raw, raw >= 0, raw < Double(definition.modifiers.count),
                  let old = definition.modifiers.firstIndex(where: { $0.id == id }) else { throw CADPolygonFailure.invalid("Choose an existing modifier and valid stack position.") }
            let value = definition.modifiers.remove(at: old); definition.modifiers.insert(value,at: Int(raw)); edit = .unchanged
        case "modifier.remove":
            let id = try Self.uuid(args,"modifierID")
            guard definition.modifiers.contains(where: { $0.id == id }) else { throw CADPolygonFailure.invalid("The modifier is missing.") }
            definition.modifiers.removeAll { $0.id == id }; edit = .unchanged
        default: throw CADPolygonFailure.unsupported("Unknown polygon mesh action.")
        }
        try CADPolygonMeshDefinition.validatePlacement(placement)
        return Plan(node: node,body: bodyID,definition: definition,placement: placement,edit: edit,creating: creating,changeCount: session.changeCount)
    }
    private nonisolated static func compute(_ plan: Plan, cancellation: CADMeshCancellation) throws -> CADPolygonMeshDefinition {
        let started = Date()
        let cancelled: @Sendable () -> Bool = { cancellation.isCancelled || Date().timeIntervalSince(started) > 10 }
        do {
        var result = plan.definition
        switch plan.edit {
        case .unchanged: break
        case let .extrude(id,distance): result.cage = try CADPolygonMeshKernel.extrude(result.cage,face: id,distance: distance,cancelled: cancelled)
        case let .inset(id,distance): result.cage = try CADPolygonMeshKernel.inset(result.cage,face: id,distance: distance)
        case let .loopCut(id,fraction): result.cage = try CADPolygonMeshKernel.loopCut(result.cage,edge: id,fraction: fraction)
        case let .weld(ids,tolerance): result.cage = try CADPolygonMeshKernel.weld(result.cage,vertices: ids,tolerance: tolerance)
        }
        _ = try CADPolygonMeshKernel.evaluate(result,cancelled: cancelled)
        if cancelled() { throw CADPolygonFailure.cancelled }; return result
        } catch {
            if !cancellation.isCancelled, Date().timeIntervalSince(started) > 10 { throw CADPolygonFailure.timedOut }
            throw error
        }
    }
    private func commit(_ plan: Plan, definition: CADPolygonMeshDefinition, cancellation: CADMeshCancellation) throws -> [String: Any] {
        guard !cancellation.isCancelled, !Task.isCancelled, !document.isClosed,
              document.session.changeCount == plan.changeCount, document.session.writeBlock == nil else { throw CADPolygonFailure.invalid("The document changed or the operation was cancelled. The model was kept.") }
        let session = document.session
        if !plan.creating, case let .polygonCage(original, _) = plan.node.kind, definition == original {
            throw CADPolygonFailure.invalid("Nothing changed.")
        }
        let kind = FeatureKind.polygonCage(definition: definition,placement: plan.placement)
        let checkpoint = document.captureEditCheckpoint(), beforeErrors = session.lastEvalErrors
        if plan.creating {
            var node = plan.node; node.kind = kind; session.recordAndRebuild([node],title: FloeCADStrings.text("cad.mesh.topology.createUndo","Create Polygon Cage"))
        } else { session.editFeature(plan.node.id,to: kind,title: FloeCADStrings.text("cad.mesh.topology.editUndo","Edit Polygon Cage")) }
        let introduced = session.lastEvalErrors.contains { id,error in beforeErrors[id] != error }
        guard !introduced, session.lastRebuildRejection.isEmpty,
              let body = session.document.body(with: plan.body), body.brep == nil else {
            document.restoreEditCheckpoint(checkpoint); throw CADPolygonFailure.invalid("The polygon edit could not rebuild. The previous model and redo were kept.")
        }
        session.save()
        var response = try Self.payload(definition)
        response.merge(["ok":true,"mutated":true,"undoSteps":1,"bodyID":plan.body.raw.uuidString,"featureID":plan.node.id.raw.uuidString,"exactness":"mesh"]) { _,new in new }
        return response
    }
    private func inspect(_ args: [String: Any]) throws -> [String: Any] {
        guard !document.isClosed else { throw CADPolygonFailure.invalid("The document is closed.") }
        let id = BodyID(raw: try Self.uuid(args,"bodyID"))
        guard let current = Self.currentCage(in: document.session, bodyID: id) else { throw CADPolygonFailure.unsupported("Select the latest editable polygon cage.") }
        let node = current.node, definition = current.definition
        var value = try Self.payload(definition); value.merge(["ok":true,"mutated":false,"bodyID":id.raw.uuidString,"featureID":node.id.raw.uuidString]) { _,new in new }; return value
    }
    private static func payload(_ definition: CADPolygonMeshDefinition) throws -> [String: Any] {
        let result = try CADPolygonMeshKernel.evaluate(definition)
        let value = try JSONSerialization.jsonObject(with: JSONEncoder().encode(definition))
        return ["cageDigest":definition.digest,"definition":value,"controlTriangles":result.controlRender.triangleCount,
                "finalTriangles":result.render.triangleCount,"signedVolume":result.mesh.signedVolume,"watertight":result.mesh.isWatertight]
    }
    private static func operation(_ args: [String: Any]) throws -> CADPolygonMeshDefinition.Modifier.Operation {
        switch args["kind"] as? String {
        case "subdivision":
            let value = try number(args,"levels",default: 1)
            guard value.rounded() == value, (1...2).contains(value) else { throw CADPolygonFailure.unsupported("Use one or two subdivision levels.") }; return .subdivision(levels: Int(value))
        case "mirror":
            let axis = try number(args,"axis",default: 0)
            guard axis.rounded() == axis, (0...2).contains(axis) else { throw CADPolygonFailure.invalid("Choose X, Y or Z mirror axis.") }; return .mirror(axis: Int(axis),offset: try number(args,"offset",default: 0))
        case "bevel": return .bevel(edge: try uuid(args,"edgeID"),width: try number(args,"width"))
        default: throw CADPolygonFailure.unsupported("Choose Subdivision, Mirror or Bevel.")
        }
    }
    private static func uuid(_ args: [String: Any], _ key: String) throws -> UUID {
        guard let raw = args[key] as? String, let value = UUID(uuidString: raw) else { throw CADPolygonFailure.invalid("Select an existing \(key).") }; return value
    }
    private static func number(_ args: [String: Any], _ key: String, default fallback: Double? = nil) throws -> Double {
        if args[key] == nil, let fallback { return fallback }
        guard let n = args[key] as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { throw CADPolygonFailure.invalid("\(key) must be a finite number.") }; return n.doubleValue
    }
    private static func fail(_ error: Error) -> [String: Any] {
        ["ok":false,"mutated":false,"error":(error as? CADPolygonFailure)?.code ?? "invalid_topology","message":error.localizedDescription]
    }
}
