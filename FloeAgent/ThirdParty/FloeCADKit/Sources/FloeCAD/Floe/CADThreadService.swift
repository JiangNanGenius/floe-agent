import Foundation
import CoreFoundation
import simd

/// UI and AI use the same source guard, typed specification and transaction.
@MainActor
final class CADThreadService {
    static let actions = ["thread.catalog", "thread.sources", "thread.create", "thread.update"]
    static let reads: Set<String> = ["thread.catalog", "thread.sources"]
    private let document: FloeCADDocument
    init(document: FloeCADDocument) { self.document = document }

    func handle(action: String, args: [String: Any]) -> [String: Any] {
        if let refusal = CADServiceOperations.readOnlyRefusal(document: document, kind: "parameter", action: action) { return refusal }
        do {
            if !Self.reads.contains(action), let raw = args["expected_change_count"] {
                guard let number = number(raw), let expected = Int(exactly: number),
                      expected == document.session.changeCount else {
                    return fail("stale_thread", "The design changed. Re-open the thread settings before applying.")
                }
            }
            switch action {
            case "thread.catalog":
                return ["ok": true, "standard": "ISO 68-1:2023 basic profile", "tolerance_fit": "unspecified",
                    "sizes": ThreadCatalog.diameters.map { d -> [String: Any] in ["diameter": d, "pitches": ThreadCatalog.pitches(for: d)] },
                    "sides": ["external", "internal"], "hands": ["right", "left"],
                    "ends": ["flatTrim", "onePitchSetback"], "representations": ["geometry", "schematic"],
                    "length_min_pitches": 2, "length_max_pitches": 32, "length_max_mm": 100,
                    "create_action": "thread.create", "update_action": "thread.update",
                    "create_inputs": ["body_id", "face_index", "query_token", "side", "diameter", "pitch", "effective_length", "hand", "ends", "representation"],
                    "update_inputs": ["feature_id", "changes", "expected_change_count"],
                    "source_action": "thread.sources"]
            case "thread.sources": return sources()
            case "thread.create": return try create(args)
            case "thread.update": return try update(args)
            default: return fail("unknown_action", "Unknown thread action.")
            }
        } catch { return fail("invalid_thread", error.localizedDescription) }
    }
    private func fail(_ code: String, _ message: String) -> [String: Any] {
        ["ok": false, "mutated": false, "error": code, "message": message]
    }
    private func rebuildFailure(_ message: String) -> [String: Any] {
        var reply = fail("thread_rebuild_failed", message)
        let diagnostics = document.session.lastRejectedFeatureErrors.values.map { String(describing: $0) }
            + document.session.lastRebuildRejection.values.map(\.message)
        reply["details"] = diagnostics
        return reply
    }
    private func number(_ raw: Any?) -> Double? {
        guard let n = raw as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    private func expression(_ raw: Any?, fallback: Expr? = nil) throws -> Expr {
        if raw == nil, let fallback { return fallback }
        if let number = number(raw) { return Expr(value: number) }
        if let text = raw as? String,
           let value = ExpressionEvaluator.evaluate(text, variables: document.session.variableValues()), value.isFinite {
            return Expr(value: value, formula: text)
        }
        throw CADThreadError.invalid("Use a finite number or a resolvable length/pitch expression.")
    }
    private func choice<T: RawRepresentable>(_ raw: Any?, fallback: T) throws -> T where T.RawValue == String {
        guard let raw else { return fallback }
        guard let text = raw as? String, let value = T(rawValue: text) else {
            throw CADThreadError.invalid("Unsupported thread option.")
        }
        return value
    }

    private struct Source {
        var reference: FaceRef
        var version: GeometryVersionRef
        var cylinder: OCCTKernel.ThreadCylinder
    }
    private func source(_ args: [String: Any],
                        acquired supplied: (version: GeometryVersionRef, snapshot: GeometryVersionSnapshot)? = nil) throws -> Source {
        guard let text = args["body_id"] as? String, let uuid = UUID(uuidString: text),
              let indexNumber = number(args["face_index"]), let index = Int(exactly: indexNumber), index > 0,
              let body = document.session.document.body(with: BodyID(raw: uuid)), let brep = body.brep,
              let token = args["query_token"] as? String,
              let generation = CADGeometryQueryGeneration.parse(token), generation.scope == "faces",
              generation.matches(documentRevision: document.revision, changeCount: document.session.changeCount,
                bodyID: uuid, meshRevision: body.meshRevision),
              document.session.lastNamingRevisions[body.id] == body.meshRevision,
              let name = document.session.lastKernelNames[body.id]?[index], name.isStableFaceIdentity,
              !Self.isIndexOnly(name),
              document.session.lastKernelNames[body.id]?.values.filter({ $0 == name }).count == 1,
              OCCTKernel.threadCylinder(brep, faceIndex: index) != nil,
              let acquired = supplied ?? document.session.associativeSource(for: body.id),
              let snapshot = acquired.snapshot.body.brep else {
            throw CADThreadError.invalid("Select a current, named complete cylindrical face; re-query faces after an edit.")
        }
        let matches = acquired.snapshot.kernelNames.filter { $0.value == name }
        guard matches.count == 1, let frozenIndex = matches.first?.key,
              let cylinder = OCCTKernel.threadCylinder(snapshot, faceIndex: frozenIndex),
              let face = OCCTKernel.faceInfo(snapshot).first(where: { $0.index == frozenIndex }),
              let signature = face.signature, case .cylindrical = signature.kind else {
            throw CADThreadError.invalid("The actual input writer no longer contains that cylindrical face.")
        }
        let ref = FaceRef(body: BodyRef(producer: acquired.version.writer, bodyID: body.id),
            creator: name.creator, role: .derived(index: frozenIndex), signature: signature, elementName: name)
        return Source(reference: ref, version: acquired.version,
                      cylinder: try cylinder.world(acquired.snapshot.body.transform))
    }
    private static func isIndexOnly(_ name: ElementName) -> Bool {
        if case .kernelFace = name.source { return true }
        return false
    }
    private func sources() -> [String: Any] {
        var rows: [[String: Any]] = []
        for body in document.session.document.bodies {
            guard let brep = body.brep,
                  document.session.lastNamingRevisions[body.id] == body.meshRevision,
                  let acquired = document.session.associativeSource(for: body.id) else { continue }
            let token = CADGeometryQueryGeneration(scope: "faces", bodyID: body.id.raw,
                documentRevision: document.revision, changeCount: document.session.changeCount,
                meshRevision: body.meshRevision).token
            for face in OCCTKernel.faceInfo(brep) {
                let args: [String: Any] = ["body_id": body.id.raw.uuidString, "face_index": face.index, "query_token": token]
                guard let s = try? source(args, acquired: acquired) else { continue }
                rows.append(["id": "\(body.id.raw.uuidString):\(face.index)",
                    "name": body.name, "body_id": body.id.raw.uuidString,
                    "face_index": face.index, "query_token": token,
                    "side": s.cylinder.isInternal ? "internal" : "external",
                    "stock_diameter": s.cylinder.radius * 2,
                    "available_length": s.cylinder.upper - s.cylinder.lower])
            }
        }
        return ["ok": true, "rows": rows]
    }

    private func changes(_ args: [String: Any], spec initial: ThreadSpec) throws -> ThreadSpec {
        var spec = initial
        let allowed: Set<String> = ["diameter", "pitch", "effective_length", "hand", "ends", "representation", "phase_degrees"]
        guard Set(args.keys).isSubset(of: allowed) else { throw CADThreadError.invalid("Unsupported thread field.") }
        if let value = args["diameter"] {
            guard let n = number(value) else { throw CADThreadError.invalid("Use a supported metric nominal diameter.") }
            spec.diameter = n
        }
        spec.pitch = try expression(args["pitch"], fallback: spec.pitch)
        spec.effectiveLength = try expression(args["effective_length"], fallback: spec.effectiveLength)
        spec.hand = try choice(args["hand"], fallback: spec.hand)
        spec.ends = try choice(args["ends"], fallback: spec.ends)
        spec.representation = try choice(args["representation"], fallback: spec.representation)
        if let raw = args["phase_degrees"] {
            guard let value = number(raw) else { throw CADThreadError.invalid("Use a finite thread phase.") }
            spec.phaseRadians = value * .pi / 180
        }
        _ = try spec.resolved(variables: document.session.variableValues())
        return spec
    }
    private func create(_ args: [String: Any]) throws -> [String: Any] {
        let sourceFields: Set<String> = ["body_id", "face_index", "query_token", "side", "revision", "expected_revision", "expected_change_count", "action"]
        let s = try source(args)
        let side = try choice(args["side"], fallback: s.cylinder.isInternal ? ThreadSpec.Side.internal : .external)
        let initial = ThreadSpec(side: side, diameter: 8, pitch: Expr(value: 1.25),
            effectiveLength: Expr(value: 5), source: s.reference, sourceVersion: s.version)
        let payload = args.filter { !sourceFields.contains($0.key) }
        let spec = try changes(payload, spec: initial)
        let node = FeatureNode(name: Self.title(spec), kind: .thread(target: s.reference.body, spec: spec),
            outputBodyIDs: [s.version.bodyID])
        guard document.session.performAssociativeTransaction([AppendFeatureCommand(node: node)], title: "Thread") else {
            return rebuildFailure("The thread could not be rebuilt. Nothing was changed.")
        }
        return reply(node.id, spec: spec)
    }
    private func update(_ args: [String: Any]) throws -> [String: Any] {
        guard let text = args["feature_id"] as? String, let id = UUID(uuidString: text),
              let node = document.session.document.features.node(FeatureID(raw: id)),
              case let .thread(target, before) = node.kind,
              let fields = args["changes"] as? [String: Any] else {
            return fail("missing_thread", "Use the existing thread feature_id and changes object.")
        }
        let after = try changes(fields, spec: before)
        if after == before { return ["ok": true, "mutated": false, "feature_id": text] }
        guard document.session.performAssociativeTransaction([
            EditFeatureCommand(featureID: node.id, before: node.kind, after: .thread(target: target, spec: after))
        ], title: "Edit Thread") else {
            return rebuildFailure("The edited thread cannot be rebuilt from this stock. Nothing was changed.")
        }
        return reply(node.id, spec: after)
    }
    private func reply(_ id: FeatureID, spec: ThreadSpec) -> [String: Any] {
        ["ok": true, "mutated": true, "feature_id": id.raw.uuidString,
         "thread": Self.describe(spec), "revision": document.revision,
         "change_count": document.session.changeCount, "can_undo": document.session.undoStack.canUndo,
         "can_redo": document.session.undoStack.canRedo]
    }
    static func title(_ spec: ThreadSpec) -> String {
        FloeCADStrings.text("cad.thread.title", "Metric thread")
    }
    static func describe(_ spec: ThreadSpec) -> [String: Any] {
        ["standard": "ISO 68-1:2023 basic profile", "tolerance_fit": "unspecified",
         "side": spec.side.rawValue, "diameter": spec.diameter,
         "pitch": spec.pitch.value, "hand": spec.hand.rawValue,
         "effective_length": spec.effectiveLength.value, "ends": spec.ends.rawValue,
         "representation": spec.representation.rawValue,
         "exact_thread_geometry": spec.representation == .geometry,
         "schematic_keeps_original_solid": spec.representation == .schematic,
         "update_action": "thread.update", "editable_fields": ["diameter", "pitch", "hand", "effective_length", "ends", "representation"],
         "pitch_choices": ThreadCatalog.pitches(for: spec.diameter)]
    }
}
