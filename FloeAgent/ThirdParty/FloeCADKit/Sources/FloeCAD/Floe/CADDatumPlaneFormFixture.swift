//
//  CADDatumPlaneFormFixture.swift
//  FloeCADKit
//
//  DEBUG-only M07 native datum-plane FORM qualification fixture and readback.
//
//  This is not a second datum implementation. The two packages are built
//  through the production command/session vocabulary (the same `Sketch`,
//  `FeatureNode`, `AddSketchCommand`, `AppendFeatureCommand`,
//  `performAssociativeTransaction` and `CADDatumService` path the editor and
//  the M07 service tests use). The editor presented by the App fixture harness
//  is the real `FloeCADWorkbenchView`, and every create/edit/reselect action
//  in the UI test goes through the shipped angle bar, `ThreePointPlaneSheet`,
//  `DatumPlaneEditSheet`, Items rows, History scalar editor, Undo/Redo and the
//  host Save control. The only thing this file decides is the saved starting
//  package and the readback of the resulting document state.
//
//  Readback is derived from the live `EditorViewModel`/`DocumentSession`
//  model, never from a success label: plane id/kind/version/formula, ordered
//  point refs, resolved origin/normal/xAxis, non-degenerate source area,
//  dependent sketch support/frame, body bounds, save revision/change count and
//  current reference/eval/rejection counts. The qualification panel is shown
//  only for the `--ui-test-cad-datum-*` launch arguments and only in DEBUG.
//

#if DEBUG
import Foundation
import simd

#if canImport(SwiftUI)
import SwiftUI
#endif

@MainActor
public enum CADDatumPlaneFormFixture {
    /// Which real form this launch exercises. The flags are DEBUG launch
    /// choices read only by `CADWorkbenchFixtureHarness`; no product code
    /// reads them.
    public enum Mode: String, Sendable {
        case angle
        case threePoint

        public static let angleArgument = "--ui-test-cad-datum-angle"
        public static let threePointArgument = "--ui-test-cad-datum-three-point"
        public static let reopenArgument = "--ui-test-cad-datum-reopen"
        public static let resetArgument = "--ui-test-cad-datum-reset"
        public static let cleanupArgument = "--ui-test-cad-datum-cleanup"

        public static func selected(from arguments: [String]) -> Mode? {
            if arguments.contains(angleArgument) { return .angle }
            if arguments.contains(threePointArgument) { return .threePoint }
            return nil
        }

        /// The readback target. The three-point package also owns an offset
        /// helper plane; the panel must report the datum under test, not the
        /// helper.
        public enum Focus: String, Sendable {
            case angle
            case threePoint
        }

        public var focus: Focus {
            switch self {
            case .angle: return .angle
            case .threePoint: return .threePoint
            }
        }

        fileprivate var packageFileName: String {
            switch self {
            case .angle: return "datum-angle-form.floecad"
            case .threePoint: return "datum-three-point-form.floecad"
            }
        }

        fileprivate var documentName: String {
            switch self {
            case .angle: return "Datum angle form"
            case .threePoint: return "Datum three-point form"
            }
        }
    }

    private static let parentFeatureName = "ParentPlate"
    private static let childSketchName = "Three point child"
    private static let anchorAName = "Anchor A"
    private static let anchorBName = "Anchor B"
    private static let plateThickness = 10.0
    private static let childDistance = 3.0

    // MARK: - Open / seed

    /// Opens the fixture package. `reset` removes only this mode's package;
    /// `reopen` never reseeds a missing package. A missing package without
    /// `reopen` seeds once so a first launch cannot silently present an empty
    /// document.
    public static func open(mode: Mode, reset: Bool, reopen: Bool) async throws -> FloeCADDocument {
        let url = try fixtureURL(mode)
        if reset, FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        let document: FloeCADDocument
        if FileManager.default.fileExists(atPath: url.path) {
            document = try await FloeCADDocument.open(at: url)
        } else if reopen {
            throw fixtureError(
                "The saved \(mode.rawValue) datum form is missing; the first launch must reset/seed it.")
        } else {
            document = try await seed(mode, at: url)
        }
        do {
            switch mode {
            case .angle:
                try prepareAngle(document)
            case .threePoint:
                try prepareThreePoint(document)
            }
            return document
        } catch {
            document.close()
            throw error
        }
    }

    /// Removes only the fixture-owned directory. It contains the two datum
    /// form packages and nothing belonging to a user document. Returns true
    /// only after the fixture root no longer exists.
    @discardableResult
    public static func removeAllFixtures() -> Bool {
        guard let root = try? fixtureRoot() else { return false }
        if FileManager.default.fileExists(atPath: root.path) {
            try? FileManager.default.removeItem(at: root)
        }
        return !FileManager.default.fileExists(atPath: root.path)
    }

    private static func seed(_ mode: Mode, at url: URL) async throws -> FloeCADDocument {
        let document = try await FloeCADDocument.create(at: url, name: mode.documentName)
        do {
            let plate = try addPlate(document, name: parentFeatureName,
                                     min: SIMD2(0, 0), max: SIMD2(100, 60),
                                     distance: plateThickness)
            try validateBodyWriter(document, body: plate.body)
            switch mode {
            case .angle:
                break
            case .threePoint:
                let top = try topFace(document, bodyID: plate.body.raw.uuidString)
                let offset = CADParameterService(document: document).handle(
                    action: "datum.offsetPlane.create",
                    args: ["body_id": plate.body.raw.uuidString,
                           "face_index": top.index,
                           "query_token": top.token,
                           "expression": "0",
                           "size": 120])
                guard offset["ok"] as? Bool == true,
                      let rawID = offset["plane_id"] as? String,
                      let uuid = UUID(uuidString: rawID) else {
                    throw fixtureError(
                        "The three-point fixture could not create its real offset support plane: "
                            + "\(offset["message"] as? String ?? "unknown error")")
                }
                let offsetID = ConstructionPlaneID(raw: uuid)
                guard let support = document.session.document.planes.first(where: { $0.id == offsetID }),
                      support.plane.normal.y > 0.99,
                      abs(support.plane.origin.y - plateThickness) < 1e-6 else {
                    throw fixtureError("The anchor support must be the actual +Y top cap at the plate thickness.")
                }

                let lineA = UUID()
                let sketchA = Sketch(
                    name: anchorAName, plane: .ground,
                    entities: [.line(id: lineA, a: SIMD2(-10, 0), b: SIMD2(10, 0))],
                    support: PlaneRef(source: .construction(offsetID)))
                guard document.session.performAssociativeTransaction(
                    [AddSketchCommand(sketch: sketchA)], title: anchorAName) else {
                    throw fixtureError(
                        "The three-point fixture could not add its offset-supported anchor sketch.")
                }
                guard document.session.lastEvalErrors.isEmpty,
                      document.session.lastReferenceErrors.isEmpty else {
                    throw fixtureError(
                        "The three-point anchor A support did not resolve: "
                            + "\(document.session.lastReferenceErrors)")
                }

                let lineB = UUID()
                let sketchB = Sketch(
                    name: anchorBName, plane: .ground,
                    entities: [.line(id: lineB, a: SIMD2(-5, 5), b: SIMD2(-5, 15))])
                guard document.session.performAssociativeTransaction(
                    [AddSketchCommand(sketch: sketchB)], title: anchorBName) else {
                    throw fixtureError(
                        "The three-point fixture could not add its second anchor sketch.")
                }
                guard document.session.lastEvalErrors.isEmpty,
                      document.session.lastReferenceErrors.isEmpty else {
                    throw fixtureError(
                        "The three-point anchor B sketch did not resolve: "
                            + "\(document.session.lastReferenceErrors)")
                }
            }
            let save = await document.save()
            guard save.succeeded else {
                throw fixtureError(save.error ?? "The datum form fixture could not be saved.")
            }
            return document
        } catch {
            document.close()
            throw error
        }
    }

    // MARK: - Real picker / follow preparation

    /// The angle form starts from a REAL face-picker selection: the fixture
    /// sends the same tap ray the viewport sends through `EditorViewModel`,
    /// then verifies the selected frame is the plate's +Y top cap. It does not
    /// arm the angle command; the UI test runs the shipped `plane.angle`
    /// command from Command Search.
    private static func prepareAngle(_ document: FloeCADDocument) throws {
        let state = document.session.document
        if state.planes.contains(where: { plane in
            if case .angle? = plane.definition { return true }
            return false
        }) {
            return
        }
        guard let body = state.bodies.first(where: { $0.brep != nil }) else {
            throw fixtureError("The angle fixture package has no analytic source body.")
        }
        guard let plateSketch = state.sketches.first(where: { $0.name == "Plate" }) else {
            throw fixtureError("The angle fixture package has no source sketch.")
        }
        let model = document.viewModel()
        let local = SIMD2<Double>(50, 30)
        let world = plateSketch.plane.toWorld(local)
        let normal = simd_normalize(plateSketch.plane.normal)
        let origin = world + normal * 200
        let ray = Ray(
            origin: SIMD3<Float>(Float(origin.x), Float(origin.y), Float(origin.z)),
            direction: SIMD3<Float>(Float(-normal.x), Float(-normal.y), Float(-normal.z)))
        model.handle(.tap(ray: ray))
        guard let selection = model.currentDatumFaceSelection else {
            throw fixtureError(
                "The real native face picker did not select the plate top face for the angle form.")
        }
        guard selection.bodyID == body.id,
              selection.basePlane.normal.y > 0.99,
              abs(selection.basePlane.origin.y - plateThickness) < 1e-6 else {
            throw fixtureError(
                "The angle fixture picker selected an unexpected source face; expected the +Y top cap.")
        }
    }

    /// On the saved-package reopen, the fixture installs one real downstream
    /// sketch + Extrude supported by the three-point plane, once. It uses the
    /// same `performAssociativeTransaction` command path as the M07 service
    /// tests (no resolver copy). The install is fixture input, not a UI
    /// success claim.
    private static func prepareThreePoint(_ document: FloeCADDocument) throws {
        let state = document.session.document
        guard let plane = state.planes.last(where: { plane in
            if case .threePoints? = plane.definition { return true }
            return false
        }) else {
            // First launch: the UI test creates the plane through the real
            // three-point sheet. There is no follow probe to install yet.
            return
        }
        let support = PlaneRef(source: .construction(plane.id))
        if state.sketches.contains(where: {
            $0.name == childSketchName && $0.support == support
        }) {
            return
        }
        let rectID = UUID()
        let child = Sketch(
            name: childSketchName, plane: .ground,
            entities: [.rect(id: rectID, min: SIMD2(-20, -10), max: SIMD2(20, 10))],
            support: support)
        let bodyID = BodyID()
        let node = FeatureNode(
            name: childSketchName,
            kind: .extrude(
                profile: ProfileRef(sketchID: child.id, entityIDs: [rectID],
                                    holeEntityIDs: [], seedPoint: .zero),
                plane: PlaneRef(source: .sketch(child.id)),
                distance: Expr(value: childDistance),
                symmetric: false,
                boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
                extraProfiles: []),
            outputBodyIDs: [bodyID])
        guard document.session.performAssociativeTransaction(
            [AddSketchCommand(sketch: child),
             AppendFeatureCommand(node: node, title: childSketchName)],
            title: childSketchName) else {
            throw fixtureError(
                "The three-point downstream sketch transaction was refused.")
        }
        guard document.session.lastEvalErrors.isEmpty,
              document.session.lastReferenceErrors.isEmpty else {
            throw fixtureError(
                "The three-point downstream sketch did not resolve: "
                    + "\(document.session.lastReferenceErrors)")
        }
        guard let installed = document.session.document.sketches.first(where: {
            $0.id == child.id
        }) else {
            throw fixtureError("The three-point downstream sketch was not committed.")
        }
        guard abs(installed.plane.origin.y - plane.plane.origin.y) < 1e-6 else {
            throw fixtureError(
                "The three-point downstream sketch did not adopt the datum plane frame.")
        }
    }

    // MARK: - Seed helpers

    private static func addPlate(_ document: FloeCADDocument, name: String,
                                 min: SIMD2<Double>, max: SIMD2<Double>,
                                 distance: Double) throws -> (body: BodyID, sketch: Sketch) {
        let sketch = Sketch(name: "Plate", plane: .ground, entities: [
            .rect(id: UUID(), min: min, max: max),
        ])
        let body = BodyID()
        let node = FeatureNode(
            name: name,
            kind: .extrude(
                profile: ProfileRef(sketchID: sketch.id,
                                    entityIDs: sketch.entities.map(\.id),
                                    holeEntityIDs: [], seedPoint: .zero),
                plane: PlaneRef(source: .sketch(sketch.id)),
                distance: Expr(value: distance),
                symmetric: false,
                boolean: BooleanIntent(op: .newBody, resolvedTargets: []),
                extraProfiles: []),
            outputBodyIDs: [body])
        document.session.recordAndRebuild([node], extra: [AddSketchCommand(sketch: sketch)],
                                          title: name)
        guard document.session.lastEvalErrors.isEmpty,
              document.session.lastReferenceErrors.isEmpty else {
            throw fixtureError("The \(name) plate did not rebuild: \(document.session.lastEvalErrors)")
        }
        return (body, sketch)
    }

    private static func validateBodyWriter(_ document: FloeCADDocument, body: BodyID) throws {
        guard document.session.document.body(with: body) != nil else {
            throw fixtureError("The plate Extrude produced no real body.")
        }
        guard document.session.lastBodyWriters[body] != nil else {
            throw fixtureError("The plate body writer did not become available.")
        }
    }

    /// The named planar +Y cap with the exact query generation token the datum
    /// service requires. The query/token contract is the same one the App
    /// harness and Material inspector use; the index is never identity.
    private static func topFace(_ document: FloeCADDocument,
                                bodyID: String) throws -> (index: Int, token: String) {
        let outcome = document.nativeQueryJSON(["scope": "faces"])
        guard outcome.isOK,
              let object = (try? JSONSerialization.jsonObject(with: outcome.payload))
                as? [String: Any],
              let rows = object["rows"] as? [[String: Any]] else {
            throw fixtureError(outcome.message ?? "The fixture could not query the plate faces.")
        }
        func number(_ value: Any?) -> Double? {
            (value as? NSNumber)?.doubleValue
        }
        let own = rows.filter { row in
            guard let id = row["bodyID"] as? String else { return false }
            return id.caseInsensitiveCompare(bodyID) == .orderedSame
        }
        let tops = own.filter { row in
            guard (row["kind"] as? String) == "planar",
                  let normal = row["normal"] as? [Any], normal.count == 3,
                  let y = number(normal[1]) else { return false }
            return y > 0.99
        }
        guard let top = tops.max(by: { lhs, rhs in
            (number(lhs["areaMM2"]) ?? 0) < (number(rhs["areaMM2"]) ?? 0)
        }),
        let index = (top["index"] as? NSNumber)?.intValue,
        let token = top["query_token"] as? String else {
            throw fixtureError("The fixture found no +Y planar cap on the plate.")
        }
        return (index, token)
    }

    // MARK: - Readback

    /// Everything the UI test asserts is read from the live document/session,
    /// not from a status label. The panel renders this same value.
    public struct Readback: Sendable, Equatable {
        public var identity: String
        public var selection: String
        public var plane: String
        public var child: String
        public var bodies: String
        public var errors: String
    }

    public static func readback(document: FloeCADDocument,
                                focus: Mode.Focus) -> Readback {
        let state = document.session.document
        let model = document.viewModel()
        let associative = state.planes.filter { $0.definition != nil }
        let target: ConstructionPlane?
        switch focus {
        case .angle:
            target = associative.last(where: { plane in
                if case .angle? = plane.definition { return true }
                return false
            })
        case .threePoint:
            target = associative.last(where: { plane in
                if case .threePoints? = plane.definition { return true }
                return false
            })
        }

        let identity = "rev=\(document.revision) changes=\(document.liveChangeCount)"
            + " sha=\(short(document.contentSHA256)) model=\(short(document.modelSHA256))"
            + " undo=\(document.session.undoStack.undoCommands.count)"
            + " redo=\(document.session.undoStack.redoCommands.count)"

        let selection: String
        if let current = model.currentDatumFaceSelection {
            selection = "face=\(current.bodyID.raw.uuidString)"
                + "/index=\(current.faceIndex)"
                + "/token=\(short(current.queryToken))"
                + "/origin=\(vector(current.basePlane.origin))"
                + "/normal=\(vector(current.basePlane.normal))"
        } else {
            selection = "face=none"
        }

        let planeLine = target.map { planeLine(for: $0, in: state) } ?? "none"
        let childLine = target.map { childLine(for: $0, in: state) } ?? "none"
        let bodies = state.bodies.map { body in
            let aabb = body.render.localAABB
            return "body=\(body.id.raw.uuidString) name=\(body.name)"
                + " min=\(vector(aabb.min)) max=\(vector(aabb.max))"
                + " brep=\(body.brep == nil ? 0 : 1)"
        }.joined(separator: ";")

        let errors = "reference=\(document.session.lastReferenceErrors.count)"
            + " eval=\(document.session.lastEvalErrors.count)"
            + " rejection=\(document.session.lastRebuildRejection.count)"
            + " error=\(oneLine(model.errorMessage ?? "none"))"

        return Readback(identity: identity, selection: selection, plane: planeLine,
                        child: childLine, bodies: bodies.isEmpty ? "none" : bodies,
                        errors: errors)
    }

    private static func planeLine(for plane: ConstructionPlane,
                                  in state: DesignDocument) -> String {
        var line = "id=\(plane.id.raw.uuidString)"
            + " kind=\(plane.definition?.kind.rawValue ?? "static")"
            + " v=\(plane.definition?.semanticVersion ?? 0)"
            + " size=\(format(plane.size))"
            + " origin=\(vector(plane.plane.origin))"
            + " normal=\(vector(plane.plane.normal))"
            + " xAxis=\(vector(plane.plane.xAxis))"
            + " normalLen=\(format(simd_length(plane.plane.normal)))"
        switch plane.definition {
        case let .angle(definition)?:
            line += " formula=\"\(definition.angle.formula ?? "")\""
                + " value=\(format(definition.angle.value))"
                + " unit=deg"
                + " hinge=\(vector(definition.hinge))"
                + " area=n/a"
                + " sourceWriter=\(definition.sourceVersion.writer.raw.uuidString)"
                + " sourceBody=\(definition.sourceVersion.bodyID.raw.uuidString)"
                + " sourceRole=\(String(describing: definition.source.role))"
                + " sourceName=\(String(describing: definition.source.elementName))"
                + " sourceNormal=\(vector(definition.source.signature.normal))"
        case let .threePoints(definition)?:
            let refs = definition.points.map {
                "\($0.sketchID.raw.uuidString)/\($0.entityID.uuidString)/\($0.role.rawValue)"
            }
            line += " formula=none"
                + " points=[\(refs.joined(separator: ";"))]"
                + " area=\(format(threePointArea(definition, in: state)))"
        case let .offset(definition)?:
            line += " formula=\"\(definition.distance.formula ?? "")\""
                + " value=\(format(definition.distance.value))"
                + " unit=mm"
                + " area=n/a"
                + " sourceRole=\(String(describing: definition.source.role))"
        case nil:
            line += " formula=none area=n/a"
        }
        return line
    }

    private static func childLine(for plane: ConstructionPlane,
                                  in state: DesignDocument) -> String {
        let support = PlaneRef(source: .construction(plane.id))
        guard let child = state.sketches.first(where: { $0.support == support }) else {
            return "none"
        }
        let bodyID = state.features.nodes.compactMap { node -> BodyID? in
            guard case let .extrude(profile, _, _, _, _, _, _) = node.kind,
                  profile.sketchID == child.id else { return nil }
            return node.outputBodyIDs.first
        }.first
        var line = "sketch=\(child.id.raw.uuidString) name=\(child.name)"
            + " support=\(plane.id.raw.uuidString)"
            + " origin=\(vector(child.plane.origin))"
            + " normal=\(vector(child.plane.normal))"
            + " xAxis=\(vector(child.plane.xAxis))"
        if let bodyID, let body = state.body(with: bodyID) {
            let aabb = body.render.localAABB
            line += " body=\(body.id.raw.uuidString)"
                + " min=\(vector(aabb.min)) max=\(vector(aabb.max))"
                + " brep=\(body.brep == nil ? 0 : 1)"
        } else {
            line += " body=none"
        }
        return line
    }

    /// Area of the triangle named by the three persisted anchors, in the
    /// current resolved sketch frames. A zero/degenerate frame is therefore
    /// visible as area=0, not hidden behind a UI success label.
    private static func threePointArea(_ definition: ThreePointPlaneDefinition,
                                       in state: DesignDocument) -> Double {
        var world: [SIMD3<Double>] = []
        for ref in definition.points {
            guard let sketch = state.sketches.first(where: { $0.id == ref.sketchID }),
                  let entity = sketch.entities.first(where: { $0.id == ref.entityID }),
                  let local = entity.anchorPoint(for: ref.role) else {
                return .nan
            }
            world.append(sketch.plane.toWorld(local))
        }
        guard world.count == 3 else { return .nan }
        return simd_length(simd_cross(world[1] - world[0], world[2] - world[0])) / 2
    }

    private static func short(_ value: String) -> String {
        String(value.prefix(12))
    }

    private static func oneLine(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }

    private static func format(_ value: Double) -> String {
        guard value.isFinite else { return "nan" }
        return String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func vector(_ value: SIMD3<Double>) -> String {
        "(\(format(value.x)),\(format(value.y)),\(format(value.z)))"
    }

    private static func vector(_ value: SIMD3<Float>) -> String {
        "(\(format(Double(value.x))),\(format(Double(value.y))),\(format(Double(value.z))))"
    }

    private static func vector(_ value: SIMD2<Double>) -> String {
        "(\(format(value.x)),\(format(value.y)))"
    }

    // MARK: - Paths

    private static func fixtureRoot() throws -> URL {
        try FileManager.default.url(for: .applicationSupportDirectory,
                                    in: .userDomainMask,
                                    appropriateFor: nil,
                                    create: true)
            .appendingPathComponent("FloeAgent/CADFixtures/DatumPlane", isDirectory: true)
    }

    private static func fixtureURL(_ mode: Mode) throws -> URL {
        let root = try fixtureRoot()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root.appendingPathComponent(mode.packageFileName)
    }

    private static func fixtureError(_ message: String) -> CADDocumentError {
        CADDocumentError(code: "datum_plane_form_fixture", message: message)
    }
}

#if canImport(SwiftUI)

/// Compact DEBUG-only qualification readback. It is present only when the App
/// fixture harness selected a datum form, so ordinary product/CUA screens do
/// not carry it. Values are computed from the live document every 0.25 s and
/// exposed as individual accessibility labels for the XCUITest.
public struct CADDatumPlaneFormReadbackPanel: View {
    private let document: FloeCADDocument
    private let focus: CADDatumPlaneFormFixture.Mode.Focus

    public init(document: FloeCADDocument,
                focus: CADDatumPlaneFormFixture.Mode.Focus) {
        self.document = document
        self.focus = focus
    }

    public var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            let readback = CADDatumPlaneFormFixture.readback(document: document, focus: focus)
            VStack(alignment: .leading, spacing: 1) {
                Text("M07 datum qualification readback")
                    .font(.caption2.weight(.semibold))
                row("CADDatumReadbackIdentity", readback.identity)
                row("CADDatumReadbackSelection", readback.selection)
                row("CADDatumReadbackPlane", readback.plane)
                row("CADDatumReadbackChild", readback.child)
                row("CADDatumReadbackBodies", readback.bodies)
                row("CADDatumReadbackErrors", readback.errors)
            }
            .font(.system(size: 9, design: .monospaced))
            .lineLimit(1)
            .minimumScaleFactor(0.45)
            .padding(6)
            .frame(maxWidth: 560, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7)
                .stroke(.secondary.opacity(0.35), lineWidth: 0.5))
            .allowsHitTesting(false)
        }
    }

    private func row(_ identifier: String, _ value: String) -> some View {
        Text(value)
            .accessibilityLabel(value)
            .accessibilityIdentifier(identifier)
    }
}

#endif
#endif
