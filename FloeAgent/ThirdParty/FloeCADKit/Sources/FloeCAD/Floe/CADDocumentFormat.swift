// The schema is a writer gate understood by existing format-1 readers.
// Additive association fields alone cannot protect their meaning from old apps.
import Foundation

nonisolated enum CADDocumentFormatError: Error, LocalizedError, Equatable, Sendable {
    case unsupportedFormat(Int)
    case insufficientFormat(provided: Int, required: Int)
    case downgrade(provided: Int, stored: Int)
    case opaqueAssociations
    case malformedAssociation(String)
    case unsupportedHoleVersion(Int)
    case invalidHole(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let version): return "This build cannot write CAD format \(version)."
        case let .insufficientFormat(provided, required): return "CAD format \(provided) cannot store this document; format \(required) is required."
        case let .downgrade(provided, stored): return "CAD format cannot decrease from \(stored) to \(provided)."
        case .opaqueAssociations: return CADDocumentFormat.opaqueReadOnlyMessage
        case .malformedAssociation(let record): return "The \(record) association payload is malformed."
        case .unsupportedHoleVersion(let version):
            return "This build cannot read mechanical-hole definition version \(version)."
        case .invalidHole(let message):
            return "The mechanical hole definition is invalid: \(message)"
        }
    }
}

nonisolated enum CADDocumentFormat {
    /// First package floor that can store structured manufacturing drawing
    /// annotations (tolerances, GD&T frames, surface/weld/thread/counterbore
    /// callouts) and reusable sheet templates. These records are NON-ADDITIVE
    /// for an older drawing writer: JSON decoding tolerates unknown keys, but
    /// a format-6 writer would drop them on its next save. A document raises
    /// its package floor to this value ONLY when its real drawing JSON stores
    /// one of those records; ordinary drawings keep their existing floor.
    ///
    /// Merge note: this is the coordinated next number, owned by Root. If
    /// another feature packet also needs a new non-additive floor, assign one
    /// shared number and keep each feature's own intent check; never lower a
    /// floor or bump ordinary documents just because this build can write 7.
    static let drawingManufacturingVersion = 7
    static let supportedVersion = 7
    /// Shared unreleased format-7 floor. A pre-contract writer ignores an
    /// edge's qualifier and would reinterpret it as an ordinal. Raise only
    /// packages that actually contain a qualified edge reference.
    static let qualifiedEdgeIdentityVersion = 7
    /// Same unreleased floor, only when a new operation-region name is
    /// actually persisted. Released306 understands format 1 and must not
    /// decode away or reinterpret these non-additive identity semantics.
    static let operationFaceIdentityVersion = 7
    /// A saved material name is now an active binding, not merely provenance
    /// that an older similarity-based writer may ignore.
    static let namedFaceMaterialVersion = 7
    /// Ordered sweep edges are semantic references, not cached spine points.
    /// Share the coordinated unreleased floor; old writers must not drop them.
    static let associativeSweepVersion = 7
    /// Coordinated package floor for a document that actually stores
    /// user-named versions. Ordinary documents keep their existing schema
    /// floor; only a package that gains a checkpoint is raised to this floor.
    static let namedVersionFormatVersion = 6
    static let legacyVersion = 1
    static let associativeVersion = 2
    /// First format that can store a typed mechanical hole. Ordinary format
    /// 1/2 documents keep their existing floor; only a REAL hole raises it.
    static let holeVersion = 3
    /// First format that can store durable external part references and the
    /// nested subassembly instance tree. These are NON-additive for an older
    /// writer: JSON decoding tolerates unknown keys, but a format-3 writer
    /// would drop the hierarchy/reference semantics on its next save. A real
    /// nested/reference document therefore raises the package manifest to 4,
    /// which every older build opens read-only. Ordinary flat documents keep
    /// their format-1/2/3 floor. Saved exploded views are already decoded and
    /// preserved by the released reader, so they do not raise this floor.
    static let nestedAssemblyVersion = 4
    /// First format that can store engineering part metadata. This is a NEW
    /// association relative to the already-released format 4, so it needs its
    /// own floor: a format-4 writer knows neither `CADPartMetadata` nor the new
    /// action and would decode the record away on its next save. Only documents
    /// that actually store a record are raised to 5; the format-4
    /// hierarchy/reference floor and every older floor stay intact.
    ///
    /// Merge note: if another feature also needs a non-additive floor, add its
    /// own feature constant/check to `requiredFormat` and `assess` below, and
    /// let `supportedVersion` be the maximum. Do not treat codable tolerance as
    /// compatibility; do not lower an existing floor.
    static let partMetadataVersion = 5
    /// First drawing-JSON schema whose shared-sheet intent a pre-v4 build
    /// cannot represent. Frozen older readers decode away `sheetViews`,
    /// read the deliberately empty page-level `sourceBodyIDs` of a
    /// multi-view page and project/export a BLANK sheet (their drawing
    /// persist guard refuses edits, but no newer-format warning runs on
    /// read/project/export). A document whose drawing set actually uses
    /// that intent — a page carrying `sheetViews`, or a dimension linked
    /// through a `feature` reference — therefore raises the package floor
    /// to 4, which older builds already open read-only. Flat/ordinary
    /// drawings keep the existing lower floor: the stamped drawing
    /// schemaVersion alone is NOT intent, so a flat sheet written by this
    /// build does not force older clients read-only.
    static let drawingSheetViewVersion = 4
    static var opaqueReadOnlyMessage: String {
        FloeCADStrings.text("cad.document.readOnlyAssociation", "This document uses newer features. Update the app to edit it.")
    }

    nonisolated struct Assessment: Sendable {
        var requiredVersion = legacyVersion
        var opaquePlanes: Set<UUID> = []
        var opaqueSketches: Set<UUID> = []
        /// M08 rows whose present axis/point definition this build cannot
        /// read. Cached display geometry is preserved and the document opens
        /// view-only; no replay consumes a guessed definition.
        var opaqueAxes: Set<UUID> = []
        var opaqueDatumPoints: Set<UUID> = []
        /// Feature rows whose KNOWN kind carries a future semantic version or
        /// an unknown future kind. Their cached body geometry is preserved and
        /// the whole document opens view-only; no replay consumes guessed data.
        var opaqueFeatures: Set<UUID> = []
        /// The drawing JSON is malformed, carries an unknown future record or
        /// is stamped with a future drawing schema. The bytes are preserved and
        /// the whole document opens read-only; no writer may overwrite them.
        var opaqueDrawings = false
        /// A future animation schema carries semantics this build cannot
        /// verify. Preserve the bytes and open the document view-only rather
        /// than letting an edit remove targets that future schema depends on.
        var opaqueAnimation = false
        var opaqueBodyAppearance = false
        var isOpaqueReadOnly: Bool {
            !opaquePlanes.isEmpty || !opaqueSketches.isEmpty
                || !opaqueAxes.isEmpty || !opaqueDatumPoints.isEmpty
                || !opaqueFeatures.isEmpty || opaqueDrawings
                || opaqueAnimation || opaqueBodyAppearance
        }
    }

    static func requiredFormat(document: DesignDocument) -> Int {
        var required = legacyVersion
        if document.features.nodes.contains(where: {
            if case let .sweep(_, _, _, _, _, path) = $0.kind { return path != nil }
            return false
        }) { required = max(required, associativeSweepVersion) }
        if document.bodies.contains(where: { $0.materialFaceBindings.contains { $0.key.elementName != nil } }) {
            required = max(required, namedFaceMaterialVersion)
        }
        if edgeReferences(in: document).contains(where: { $0.faceNames?.schemeVersion != nil }) {
            required = max(required, qualifiedEdgeIdentityVersion)
        }
        if faceNames(in: document).contains(where: \.containsQualifiedOperationIdentity) {
            required = max(required, operationFaceIdentityVersion)
        }
        if assemblyRequiresNestedFormat(document.assemblyData) {
            required = max(required, nestedAssemblyVersion)
        }
        if assemblyRequiresPartMetadataFormat(document.assemblyData) {
            required = max(required, partMetadataVersion)
        }
        required = max(required, drawingRequiredVersion(document.drawingsData))
        if document.features.nodes.contains(where: {
            if case .hole = $0.kind { return true }
            return false
        }) {
            required = max(required, holeVersion)
        }
        // X23-X25 R2: a persisted timing curve is non-additive for the
        // released schema-1 animation writer, which decodes the record
        // without the curve and drops it on its next animation edit. The
        // floor comes from the REAL bytes (`timingCurve` member and/or a
        // schema-2 header), never from "this build can write 2". Ordinary
        // legacy/default clips without a curve keep floor 1. A future
        // animation schema keeps at least its own floor so an older package
        // writer cannot claim compatibility.
        required = max(required, CADAnimationFormat.intent(document.animationData).requiredVersion)
        // M08 intent is the REFERENCE, not only the source definition. A
        // pattern's `axisRef` or a revolve's `AxisRef.constructionAxis` can
        // point at a LEGACY absolute axis (`definition == nil`), and a datum
        // point row is a new top-level entity even when its own `definition`
        // is nil. A released format-1 writer ignores `axisRef`, rejects the
        // unknown revolve source, and knows no `datumPoints` column at all, so
        // leaving the floor at 1 lets it stay writable and drop the new
        // relationship. Ordinary legacy absolute axes, old explicit revolve
        // lines, absolute patterns and an EMPTY datum-point list keep floor 1.
        if document.planes.contains(where: { $0.definition != nil })
            || document.sketches.contains(where: { $0.support != nil })
            || document.axes.contains(where: { $0.definition != nil })
            || !document.datumPoints.isEmpty
            || document.features.nodes.contains(where: {
                !$0.referencedConstructionAxisIDs.isEmpty
            }) {
            required = max(required, associativeVersion)
        }
        return required
    }

    private static func edgeReferences(in document: DesignDocument) -> [EdgeRef] {
        var references = document.features.nodes.flatMap { node -> [EdgeRef] in
            switch node.kind {
            case let .fillet(_, edges, _), let .chamfer(_, edges, _): return edges
            default: return []
            }
        }
        for axis in document.axes {
            if case let .edge(definition)? = axis.definition { references.append(definition.source) }
        }
        for point in document.datumPoints {
            if case let .edgePoint(definition)? = point.definition { references.append(definition.source) }
        }
        return references
    }

    private static func faceNames(in document: DesignDocument) -> [ElementName] {
        var names = edgeReferences(in: document).flatMap { reference -> [ElementName] in
            reference.faceNames.map { [$0.faceA, $0.faceB] } ?? []
        }
        for node in document.features.nodes {
            let refs: [FaceRef]
            switch node.kind {
            case let .pushPull(face, _, _), let .moveFace(face, _), let .scaleFace(face, _),
                 let .rotateFace(face, _, _), let .draftFace(face, _, _, _), let .replaceFace(face, _, _, _):
                refs = [face]
            case let .shell(_, faces, _), let .deleteFace(_, faces): refs = faces
            default: refs = []
            }
            names += refs.compactMap(\.elementName)
        }
        for plane in document.planes {
            switch plane.definition {
            case let .offset(definition)?: names += [definition.source.elementName].compactMap { $0 }
            case let .angle(definition)?: names += [definition.source.elementName].compactMap { $0 }
            default: break
            }
        }
        for axis in document.axes {
            switch axis.definition {
            case let .face(definition)?: names += [definition.source.elementName].compactMap { $0 }
            case let .cylinder(definition)?: names += [definition.source.elementName].compactMap { $0 }
            default: break
            }
        }
        for point in document.datumPoints {
            if case let .faceCenter(definition)? = point.definition {
                names += [definition.source.elementName].compactMap { $0 }
            }
        }
        names += document.bodies.flatMap { $0.materialFaceBindings.compactMap(\.key.elementName) }
        return names
    }

    /// Inspect versioned names in actual persisted reference locations. A
    /// future version keeps its original bytes view-only; a malformed known
    /// identity cannot be silently decoded away by a writer.
    private static func operationIdentityIntent(_ object: Any) throws -> (present: Bool, opaque: Bool) {
        var present = false, opaque = false
        if let array = object as? [Any] {
            for value in array {
                let child = try operationIdentityIntent(value)
                present = present || child.present; opaque = opaque || child.opaque
            }
        } else if let fields = object as? [String: Any] {
            for value in fields.values {
                let child = try operationIdentityIntent(value)
                present = present || child.present; opaque = opaque || child.opaque
            }
            if fields["creator"] != nil, let source = fields["source"] as? [String: Any],
               let raw = source["operationFace"] {
                present = true
                guard let payload = raw as? [String: Any], let value = payload["version"],
                      let version = jsonIntegerValue(value) else {
                    throw CADDocumentFormatError.malformedAssociation("operation-face-identity")
                }
                if version != 1 { opaque = true }
                else if !opaque {
                    guard let bytes = try? JSONSerialization.data(withJSONObject: fields),
                          let name = try? JSONDecoder().decode(ElementName.self, from: bytes),
                          name.hasSupportedOperationIdentity else {
                        throw CADDocumentFormatError.malformedAssociation("operation-face-identity")
                    }
                }
            }
        }
        return (present, opaque)
    }

    /// Inspect the actual field in known edge-reference locations; no name,
    /// model capability flag or global supported-version stamp implies intent.
    private static func edgeIdentityIntent(_ references: [Any]) throws -> (present: Bool, opaque: Bool) {
        var present = false, opaque = false
        for reference in references {
            guard let ref = reference as? [String: Any],
                  let name = ref["faceNames"] as? [String: Any],
                  let raw = name["schemeVersion"], !(raw is NSNull) else { continue }
            present = true
            guard let version = jsonIntegerValue(raw) else {
                throw CADDocumentFormatError.malformedAssociation("edge-identity")
            }
            if version != 1 { opaque = true }
        }
        return (present, opaque)
    }

    nonisolated struct DrawingIntent {
        var version = legacyVersion
        var opaque = false
    }

    /// Inspect the REAL drawing-set bytes. The stamped drawing schema alone is
    /// NOT intent: a flat sheet written by this build must keep its lower
    /// package floor. Only records this build can verify raise the floor.
    /// Malformed bytes, a future drawing schema and unknown/malformed
    /// manufacturing records fail CLOSED (opaque read-only), so an older or
    /// newer writer can never silently drop them.
    static func drawingRequiredVersion(_ data: Data?) -> Int {
        drawingIntent(data).version
    }

    static func drawingIntent(_ data: Data?) -> DrawingIntent {
        var result = DrawingIntent()
        guard let data, !data.isEmpty else { return result }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            result.version = supportedVersion
            result.opaque = true
            return result
        }
        if let rawSchema = object["schemaVersion"] {
            guard let schema = jsonIntegerValue(rawSchema), schema >= legacyVersion else {
                result.version = max(result.version, drawingManufacturingVersion)
                result.opaque = true
                return result
            }
            if schema > CADDrawingSet.currentSchemaVersion {
                result.version = max(result.version, schema)
                result.opaque = true
            }
        }
        if let templates = object["templates"] {
            guard let rows = templates as? [[String: Any]] else {
                result.version = max(result.version, drawingManufacturingVersion)
                result.opaque = true
                return result
            }
            if !rows.isEmpty {
                result.version = max(result.version, drawingManufacturingVersion)
                for row in rows {
                    guard templateRecordIsKnown(row) else {
                        result.opaque = true
                        continue
                    }
                }
            }
        }
        guard let rawPages = object["pages"] else { return result }
        guard let pages = rawPages as? [[String: Any]] else {
            result.version = max(result.version, supportedVersion)
            result.opaque = true
            return result
        }
        for page in pages {
            if let views = page["sheetViews"] as? [[String: Any]], !views.isEmpty {
                result.version = max(result.version, drawingSheetViewVersion)
            }
            if let dimensions = page["manualDimensions"] as? [[String: Any]],
               dimensions.contains(where: { dimension in
                   guard let feature = dimension["feature"] else { return false }
                   return !(feature is NSNull)
               }) {
                result.version = max(result.version, drawingSheetViewVersion)
            }
            if let rawAnnotations = page["manufacturingAnnotations"] {
                guard let annotations = rawAnnotations as? [[String: Any]] else {
                    result.version = max(result.version, drawingManufacturingVersion)
                    result.opaque = true
                    continue
                }
                if !annotations.isEmpty {
                    result.version = max(result.version, drawingManufacturingVersion)
                    for row in annotations where !manufacturingRecordIsKnown(row) {
                        result.opaque = true
                    }
                }
            }
            if let rawTemplate = page["sheetTemplate"], !(rawTemplate is NSNull) {
                result.version = max(result.version, drawingManufacturingVersion)
                guard let row = rawTemplate as? [String: Any] else {
                    result.opaque = true
                    continue
                }
                let snapshot = row["snapshot"] as? [String: Any]
                if snapshot == nil || !templateRecordIsKnown(snapshot ?? [:], requireID: false) {
                    result.opaque = true
                }
            }
            let presentation = pagePresentationIntent(page)
            if presentation.present {
                result.version = max(result.version, drawingManufacturingVersion)
            }
            if !presentation.known { result.opaque = true }
        }
        if result.opaque {
            result.version = max(result.version, drawingManufacturingVersion)
        }
        return result
    }

    /// Page-level v5 presentation records (revision rows, units, precision and
    /// a per-page title-block override). Any present record raises the floor;
    /// a malformed/unknown record is opaque instead of decoding to a blank
    /// fallback and being silently re-encoded over the original bytes.
    private static func pagePresentationIntent(_ page: [String: Any])
        -> (present: Bool, known: Bool) {
        var present = false
        var known = true
        if let raw = page["revisionRows"] {
            if !(raw is NSNull) {
                guard let rows = raw as? [[String: Any]] else { return (true, false) }
                if !rows.isEmpty {
                    present = true
                    if rows.count > CADDrawingTemplateRules.maximumRevisionRows {
                        known = false
                    }
                    for row in rows where !revisionRowIsKnown(row) { known = false }
                }
            }
        }
        if let raw = page["units"], !(raw is NSNull) {
            present = true
            guard let name = raw as? String, CADDrawingUnit(rawValue: name) != nil else {
                return (true, false)
            }
        }
        if let raw = page["precision"], !(raw is NSNull) {
            present = true
            guard let value = jsonIntegerValue(raw), (0...4).contains(value) else {
                return (true, false)
            }
        }
        if let raw = page["titleBlock"], !(raw is NSNull) {
            present = true
            guard let object = raw as? [String: Any],
                  Set(object.keys).isSubset(of: Set(["company", "drawingNumber"])),
                  let company = object["company"] as? String,
                  let number = object["drawingNumber"] as? String,
                  company.count <= 80, number.count <= 60 else {
                return (true, false)
            }
        }
        return (present, known)
    }

    /// JSONSerialization bridges booleans to NSNumber and `as? Int` accepts
    /// them as 1/0. A version or precision field must be a real integer.
    private static func jsonIntegerValue(_ raw: Any?) -> Int? {
        guard let number = raw as? NSNumber else { return nil }
        guard String(cString: number.objCType) != "c" else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value == value.rounded(),
              value >= Double(Int.min), value <= Double(Int.max) else { return nil }
        return number.intValue
    }

    private static func revisionRowIsKnown(_ row: [String: Any]) -> Bool {
        let allowed = Set(["id", "revision", "date", "description", "approvedBy"])
        guard Set(row.keys).isSubset(of: allowed),
              let revision = row["revision"] as? String,
              let description = row["description"] as? String,
              row["date"] == nil || row["date"] is String || row["date"] is NSNull,
              row["approvedBy"] == nil || row["approvedBy"] is String || row["approvedBy"] is NSNull,
              revision.count <= 16,
              (row["date"] as? String ?? "").count <= 24,
              description.count <= 80,
              ((row["approvedBy"] as? String)?.count ?? 0) <= 40,
              let data = try? JSONSerialization.data(withJSONObject: row),
              (try? JSONDecoder().decode(CADDrawingRevisionRow.self, from: data)) != nil else {
            return false
        }
        return true
    }

    private static func manufacturingRecordIsKnown(_ row: [String: Any]) -> Bool {
        let allowedKeys = Set(["id", "kind", "viewID", "position", "heightMM", "feature",
                               "datum", "featureControlFrame", "surfaceFinish",
                               "weld", "thread", "counterbore"])
        guard Set(row.keys).isSubset(of: allowedKeys),
              let kind = row["kind"] as? String,
              let parsedKind = CADDrawingManufacturingKind(rawValue: kind) else {
            return false
        }
        let payloadKey: String
        switch parsedKind {
        case .datumFeature: payloadKey = "datum"
        case .featureControlFrame: payloadKey = "featureControlFrame"
        case .surfaceFinish: payloadKey = "surfaceFinish"
        case .weld: payloadKey = "weld"
        case .threadCallout: payloadKey = "thread"
        case .counterboreCallout: payloadKey = "counterbore"
        }
        let payloadKeys = ["datum", "featureControlFrame", "surfaceFinish",
                           "weld", "thread", "counterbore"]
        let present = payloadKeys.filter { key in
            guard let value = row[key] else { return false }
            return !(value is NSNull)
        }
        let allowedPayloadKeys: [CADDrawingManufacturingKind: Set<String>] = [
            .datumFeature: ["letter", "leaderTarget"],
            .featureControlFrame: ["characteristic", "toleranceMM", "diameterZone",
                                   "materialCondition", "datumReferences", "leaderTarget"],
            .surfaceFinish: ["raMicrometres", "machiningMethod", "allAround"],
            .weld: ["type", "sizeMM", "lengthMM", "pitchMM", "allAround",
                    "fieldWeld", "tailNote", "leaderTarget"],
            .threadCallout: ["designation", "pitchMM", "threadClass", "handedness",
                             "through", "depthMM", "leaderTarget"],
            .counterboreCallout: ["leaderTarget"],
        ]
        guard let payload = row[payloadKey] as? [String: Any],
              present == [payloadKey],
              let allowed = allowedPayloadKeys[parsedKind],
              Set(payload.keys).isSubset(of: allowed),
              let decoded = try? JSONDecoder().decode(
                  CADDrawingManufacturingAnnotation.self,
                  from: JSONSerialization.data(withJSONObject: row)) else {
            return false
        }
        return CADDrawingManufacturingRules.validate(decoded).isEmpty
    }

    private static func templateRecordIsKnown(_ row: [String: Any],
                                              requireID: Bool = true) -> Bool {
        let allowedKeys = Set(["id", "name", "paper", "customWidthMM", "customHeightMM",
                               "projection", "units", "precision", "style", "titleBlock",
                               "revisionRows", "builtIn"])
        guard Set(row.keys).isSubset(of: allowedKeys),
              row["name"] is String else { return false }
        if requireID, row["id"] == nil { return false }
        if let style = row["style"] {
            guard let object = style as? [String: Any],
                  Set(object.keys).isSubset(of: Set(["marginMM", "titleBlockWidthMM",
                                                     "titleBlockHeightMM", "lineWidthMM",
                                                     "textHeightMM", "showZoneGrid"])) else {
                return false
            }
        }
        if let block = row["titleBlock"] {
            guard let object = block as? [String: Any],
                  Set(object.keys).isSubset(of: Set(["company", "drawingNumber"])) else {
                return false
            }
        }
        if let rows = row["revisionRows"] {
            guard let objects = rows as? [[String: Any]],
                  objects.allSatisfy({ Set($0.keys).isSubset(of: Set(["id", "revision",
                                                                      "date", "description",
                                                                      "approvedBy"])) }) else {
                return false
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: row),
              let template = try? JSONDecoder().decode(CADDrawingSheetTemplate.self,
                                                       from: data) else {
            return false
        }
        return CADDrawingTemplateRules.validate(template).isEmpty
    }

    /// Best-effort inspection of the persisted assembly record. A malformed
    /// record is treated as a future/non-additive document (format 4) rather
    /// than allowing an older writer to overwrite it; the service still owns
    /// its recoverable corrupt-assembly diagnostics.
    static func assemblyRequiresNestedFormat(_ data: Data?) -> Bool {
        guard let data, !data.isEmpty else { return false }
        guard let assembly = try? CADAssembly.decode(from: data) else { return true }
        return assembly.requiresNestedFormat
    }

    /// True when the persisted assembly actually carries engineering part
    /// metadata. The floor is feature-based, not stamped: an empty/legacy
    /// assembly keeps its existing lower floor.
    static func assemblyRequiresPartMetadataFormat(_ data: Data?) -> Bool {
        guard let data, !data.isEmpty else { return false }
        guard let assembly = try? CADAssembly.decode(from: data) else { return true }
        return assembly.requiresPartMetadataFormat
    }

    /// Existing save diffs preserve unreadable legacy rows, but a new
    /// association must never be silently skipped by a try?-encode fallback.
    static func validateLiveAssociations(_ document: DesignDocument) throws {
        if faceNames(in: document).contains(where: { !$0.hasSupportedOperationIdentity }) {
            throw CADDocumentFormatError.opaqueAssociations
        }
        if edgeReferences(in: document).contains(where: {
            if let version = $0.faceNames?.schemeVersion { return version != 1 }
            return false
        }) { throw CADDocumentFormatError.opaqueAssociations }
        let encoder = JSONEncoder()
        for plane in document.planes {
            guard let definition = plane.definition else { continue }
            guard definition.isSupportedSemanticVersion else {
                throw CADDocumentFormatError.opaqueAssociations
            }
            _ = try encoder.encode(plane)
        }
        for axis in document.axes {
            guard let definition = axis.definition else { continue }
            guard definition.isSupportedSemanticVersion else {
                throw CADDocumentFormatError.opaqueAssociations
            }
            // A non-encodable definition (non-finite scalar) must FAIL the
            // transaction, never be dropped by a try? row update.
            guard (try? encoder.encode(axis)) != nil else {
                throw CADDocumentFormatError.malformedAssociation("construction-axis")
            }
        }
        for point in document.datumPoints {
            guard let definition = point.definition else {
                guard (try? encoder.encode(point)) != nil else {
                    throw CADDocumentFormatError.malformedAssociation("datum-point")
                }
                continue
            }
            guard definition.isSupportedSemanticVersion else {
                throw CADDocumentFormatError.opaqueAssociations
            }
            guard (try? encoder.encode(point)) != nil else {
                throw CADDocumentFormatError.malformedAssociation("datum-point")
            }
        }
        for sketch in document.sketches where sketch.support != nil { _ = try encoder.encode(sketch) }
        // A hole is the first non-additive feature kind: its semantic version,
        // every stored scalar and the actual pilot relation are validated
        // before any commit. A non-encodable hole must FAIL the transaction,
        // never be silently dropped by a try?-encode row update.
        for node in document.features.nodes {
            if case let .sweep(_, _, _, _, helix, path) = node.kind, let path {
                guard helix == nil else { throw CADDocumentFormatError.malformedAssociation("sweep-path") }
                do { try path.validate(); _ = try encoder.encode(node.kind) }
                catch { throw CADDocumentFormatError.malformedAssociation("sweep-path") }
            }
            guard case let .hole(_, profile, _, spec) = node.kind else { continue }
            guard spec.version == HoleSpec.supportedVersion else {
                throw CADDocumentFormatError.unsupportedHoleVersion(spec.version)
            }
            let sketch = document.sketches.first { $0.id == profile.sketchID }
            let pilot = sketch.flatMap {
                HoleKit.circle(in: $0, matching: profile)
            }.map { $0.radius * 2 }
            if let issue = HoleKit.validationIssue(spec, pilotDiameter: pilot) {
                throw CADDocumentFormatError.invalidHole(issue)
            }
            do {
                _ = try encoder.encode(node.kind)
            } catch {
                throw CADDocumentFormatError.invalidHole(
                    "a stored parameter is not encodable (non-finite value)")
            }
        }
    }

    /// Inspect real inline bytes, not a caller's flag. Unsupported semantics
    /// are a view-only document; malformed known associations are corruption.
    /// Legacy undecodable rows with no identifiable association keep the
    /// existing unreadable-row preservation contract.
    static func assess(planes: [CADBlobRecord], sketches: [CADBlobRecord],
                       axes: [CADBlobRecord] = [],
                       datumPoints: [CADBlobRecord] = [],
                       features: [CADFeatureRecord] = [],
                       bodies: [CADBodyRecord] = [],
                       assembly: Data? = nil,
                       drawings: Data? = nil,
                       animation: Data? = nil) throws -> Assessment {
        var result = Assessment()
        if assemblyRequiresNestedFormat(assembly) {
            result.requiredVersion = max(result.requiredVersion, nestedAssemblyVersion)
        }
        if assemblyRequiresPartMetadataFormat(assembly) {
            result.requiredVersion = max(result.requiredVersion, partMetadataVersion)
        }
        let drawingIntent = drawingIntent(drawings)
        result.requiredVersion = max(result.requiredVersion, drawingIntent.version)
        if drawingIntent.opaque { result.opaqueDrawings = true }
        // R2: inspect the persisted animation bytes for non-additive curve
        // intent. A malformed/future curve is preserved by the animation
        // load/edit guard; the floor still rises so a schema-1 package writer
        // can never overwrite the curve semantics.
        let animationIntent = CADAnimationFormat.intent(animation)
        result.requiredVersion = max(result.requiredVersion,
                                     animationIntent.requiredVersion)
        if animationIntent.isFutureSchema { result.opaqueAnimation = true }
        for body in bodies {
            guard let bytes = body.faceMaterials,
                  let object = try? JSONSerialization.jsonObject(with: bytes) else { continue }
            if let bindings = object as? [[String: Any]], bindings.contains(where: {
                guard let key = $0["key"] as? [String: Any], let name = key["elementName"] else { return false }
                return !(name is NSNull)
            }) {
                result.requiredVersion = max(result.requiredVersion, namedFaceMaterialVersion)
                if (try? JSONDecoder().decode([CADFaceMaterialBinding].self, from: bytes)) == nil {
                    result.opaqueBodyAppearance = true
                }
            }
            let identity = try operationIdentityIntent(object)
            if identity.present { result.requiredVersion = max(result.requiredVersion, operationFaceIdentityVersion) }
            if identity.opaque { result.opaqueBodyAppearance = true }
        }
        for row in planes {
            guard let object = try? JSONSerialization.jsonObject(with: row.data) as? [String: Any] else { continue }
            let identity = try operationIdentityIntent(object)
            if identity.present { result.requiredVersion = max(result.requiredVersion, operationFaceIdentityVersion) }
            if identity.opaque { result.opaquePlanes.insert(row.blobID) }
            guard let definition = object["definition"], !(definition is NSNull) else { continue }
            result.requiredVersion = max(result.requiredVersion, associativeVersion)
            do {
                _ = try JSONDecoder().decode(ConstructionPlane.self, from: row.data)
            } catch let error as AssociativeGeometryError where error.requiresOpaqueReadOnlyDocument {
                // Prove the cached display portion itself is readable. Never
                // classify a broken id/plane as a supported future definition.
                _ = try cachedPlane(from: row.data)
                result.opaquePlanes.insert(row.blobID)
            } catch {
                throw CADDocumentFormatError.malformedAssociation("construction-plane")
            }
        }
        for row in axes {
            guard let object = try? JSONSerialization.jsonObject(with: row.data) as? [String: Any] else { continue }
            let operationIdentity = try operationIdentityIntent(object)
            if let sweep = object["sweep"] as? [String: Any], let raw = sweep["path"], !(raw is NSNull) {
                result.requiredVersion = max(result.requiredVersion, associativeSweepVersion)
                guard let definition = raw as? [String: Any],
                      let version = definition["version"] as? Int, version > 0 else {
                    throw CADDocumentFormatError.malformedAssociation("sweep-path")
                }
                if version > SweepPathDefinition.supportedVersion {
                    result.opaqueFeatures.insert(row.featureID)
                } else {
                    do {
                        let data = try JSONSerialization.data(withJSONObject: definition)
                        _ = try JSONDecoder().decode(SweepPathDefinition.self, from: data)
                    } catch { throw CADDocumentFormatError.malformedAssociation("sweep-path") }
                }
            }
            if operationIdentity.present { result.requiredVersion = max(result.requiredVersion, operationFaceIdentityVersion) }
            if operationIdentity.opaque { result.opaqueAxes.insert(row.blobID) }
            guard let definition = object["definition"], !(definition is NSNull) else { continue }
            result.requiredVersion = max(result.requiredVersion, associativeVersion)
            let edge = (definition as? [String: Any])?["edge"] as? [String: Any]
            let identity = try edgeIdentityIntent((edge?["source"]).map { [$0] } ?? [])
            if identity.present { result.requiredVersion = max(result.requiredVersion, qualifiedEdgeIdentityVersion) }
            if identity.opaque {
                _ = try cachedAxis(from: row.data)
                result.opaqueAxes.insert(row.blobID)
                continue
            }
            do {
                _ = try JSONDecoder().decode(ConstructionAxis.self, from: row.data)
            } catch let error as AssociativeAxisPointError where error.requiresOpaqueReadOnlyDocument {
                _ = try cachedAxis(from: row.data)
                result.opaqueAxes.insert(row.blobID)
            } catch {
                throw CADDocumentFormatError.malformedAssociation("construction-axis")
            }
        }
        for row in datumPoints {
            // Every datum-point row is a new top-level entity to a released
            // format-1 writer, even when the point itself is ABSOLUTE
            // (`definition == nil`). Only an EMPTY list is legacy. The row is
            // still inspected below so a present future definition opens
            // opaque/read-only with its original bytes.
            result.requiredVersion = max(result.requiredVersion, associativeVersion)
            guard let object = try? JSONSerialization.jsonObject(with: row.data) as? [String: Any] else { continue }
            let operationIdentity = try operationIdentityIntent(object)
            if operationIdentity.present { result.requiredVersion = max(result.requiredVersion, operationFaceIdentityVersion) }
            if operationIdentity.opaque { result.opaqueDatumPoints.insert(row.blobID) }
            guard let definition = object["definition"], !(definition is NSNull) else { continue }
            let edge = (definition as? [String: Any])?["edgePoint"] as? [String: Any]
            let identity = try edgeIdentityIntent((edge?["source"]).map { [$0] } ?? [])
            if identity.present { result.requiredVersion = max(result.requiredVersion, qualifiedEdgeIdentityVersion) }
            if identity.opaque {
                _ = try cachedDatumPoint(from: row.data)
                result.opaqueDatumPoints.insert(row.blobID)
                continue
            }
            do {
                _ = try JSONDecoder().decode(DatumPoint.self, from: row.data)
            } catch let error as AssociativeAxisPointError where error.requiresOpaqueReadOnlyDocument {
                _ = try cachedDatumPoint(from: row.data)
                result.opaqueDatumPoints.insert(row.blobID)
            } catch {
                throw CADDocumentFormatError.malformedAssociation("datum-point")
            }
        }
        let knownSupportCases: Set<String> = ["sketch", "construction", "ground", "explicit"]
        for row in sketches {
            guard let object = try? JSONSerialization.jsonObject(with: row.data) as? [String: Any],
                  let support = object["support"], !(support is NSNull) else { continue }
            result.requiredVersion = max(result.requiredVersion, associativeVersion)
            do {
                _ = try JSONDecoder().decode(Sketch.self, from: row.data)
            } catch {
                guard let support = support as? [String: Any],
                      let source = support["source"] as? [String: Any], source.count == 1,
                      let unknown = source.keys.first, !knownSupportCases.contains(unknown),
                      source[unknown] is [String: Any] else {
                    throw CADDocumentFormatError.malformedAssociation("sketch-support")
                }
                _ = try cachedSketch(from: row.data)
                result.opaqueSketches.insert(row.blobID)
            }
        }
        for row in features {
            // A raw/unknown payload stays on the existing unreadable-feature
            // path (skip + preserve). Known pattern/revolve rows are inspected
            // for the M08 consumer identity BEFORE the hole contract below.
            guard let object = try? JSONSerialization.jsonObject(with: row.kind) as? [String: Any] else {
                continue
            }
            let operationIdentity = try operationIdentityIntent(object)
            if operationIdentity.present { result.requiredVersion = max(result.requiredVersion, operationFaceIdentityVersion) }
            if operationIdentity.opaque { result.opaqueFeatures.insert(row.featureID) }
            if try featureConsumesConstructionAxis(object) {
                result.requiredVersion = max(result.requiredVersion, associativeVersion)
            }
            for kind in ["fillet", "chamfer"] {
                let payload = object[kind] as? [String: Any]
                let identity = try edgeIdentityIntent(payload?["edges"] as? [Any] ?? [])
                if identity.present { result.requiredVersion = max(result.requiredVersion, qualifiedEdgeIdentityVersion) }
                if identity.opaque { result.opaqueFeatures.insert(row.featureID) }
            }
            guard let hole = object["hole"], !(hole is NSNull) else { continue }
            result.requiredVersion = max(result.requiredVersion, holeVersion)
            guard let hole = hole as? [String: Any],
                  let spec = hole["spec"] as? [String: Any] else {
                throw CADDocumentFormatError.malformedAssociation("hole-feature")
            }
            guard let version = spec["version"] as? Int else {
                throw CADDocumentFormatError.malformedAssociation("hole-feature")
            }
            if version > HoleSpec.supportedVersion {
                result.opaqueFeatures.insert(row.featureID)
                continue
            }
            // Distinguish a malformed KNOWN definition from a future one:
            // an unknown kind is future/opaque; a missing/wrong field at a
            // supported version is corruption, reported (and preserved).
            guard let rawKind = spec["kind"] as? String else {
                throw CADDocumentFormatError.malformedAssociation("hole-feature")
            }
            guard HoleSpec.Kind(rawValue: rawKind) != nil else {
                result.opaqueFeatures.insert(row.featureID)
                continue
            }
            do {
                let decoded = try JSONDecoder().decode(FeatureKind.self, from: row.kind)
                guard case let .hole(_, _, _, decodedSpec) = decoded else {
                    throw CADDocumentFormatError.malformedAssociation("hole-feature")
                }
                if let issue = HoleKit.validationIssue(decodedSpec, pilotDiameter: nil) {
                    throw CADDocumentFormatError.malformedAssociation(
                        "hole-feature: \(issue)")
                }
            } catch let error as CADDocumentFormatError {
                throw error
            } catch {
                throw CADDocumentFormatError.malformedAssociation("hole-feature")
            }
        }
        return result
    }

    static func assess(_ record: CADDocumentRecord) throws -> Assessment {
        try assess(planes: record.planes, sketches: record.sketches,
                   axes: record.axes, datumPoints: record.datumPoints ?? [],
                   features: record.features, bodies: record.bodies, assembly: record.assembly,
                   drawings: record.drawings, animation: record.animation)
    }

    /// RAW twin of `FeatureNode.referencedConstructionAxisIDs`: true only when
    /// a persisted pattern actually stores `spec.axisRef`, or a persisted
    /// revolve actually stores `AxisRef.Source.constructionAxis`.
    ///
    /// The REFERENCE is the intent, so a legacy absolute axis
    /// (`definition == nil`) still raises the coordinated floor: a released
    /// format-1 reader ignores the pattern field or rejects the unknown revolve
    /// source, so it must not stay writable over the relationship. An
    /// ordinary explicit/sketch-line revolve and an absolute pattern stay
    /// legacy. A present but unreadable reference on a KNOWN row is corruption
    /// (reported, bytes preserved), while an unknown/future feature kind is
    /// left on the existing unreadable-row path.
    private static func featureConsumesConstructionAxis(_ object: [String: Any]) throws -> Bool {
        if let raw = object["pattern"] {
            guard let payload = raw as? [String: Any],
                  let spec = payload["spec"] as? [String: Any] else {
                throw CADDocumentFormatError.malformedAssociation("pattern-feature")
            }
            guard let rawReference = spec["axisRef"], !(rawReference is NSNull) else {
                return false
            }
            guard let object = rawReference as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: object),
                  (try? JSONDecoder().decode(ConstructionAxisRef.self, from: data)) != nil else {
                throw CADDocumentFormatError.malformedAssociation("pattern-axis-reference")
            }
            return true
        }
        if let raw = object["revolve"] {
            guard let payload = raw as? [String: Any],
                  let axis = payload["axis"] as? [String: Any],
                  let source = axis["source"] as? [String: Any] else {
                throw CADDocumentFormatError.malformedAssociation("revolve-feature")
            }
            guard let rawSource = source["constructionAxis"] else { return false }
            guard !(rawSource is NSNull),
                  let data = try? JSONSerialization.data(withJSONObject: axis),
                  let reference = try? JSONDecoder().decode(AxisRef.self, from: data),
                  case .constructionAxis = reference.source else {
                throw CADDocumentFormatError.malformedAssociation("revolve-axis-reference")
            }
            return true
        }
        return false
    }

    static func validateWrite(_ payload: CADWritePayload, storedSchema: Int? = nil) throws {
        guard (legacyVersion...supportedVersion).contains(payload.schemaVersion) else {
            throw CADDocumentFormatError.unsupportedFormat(payload.schemaVersion)
        }
        let assessment = try assess(payload.document)
        guard !assessment.isOpaqueReadOnly else { throw CADDocumentFormatError.opaqueAssociations }
        guard payload.schemaVersion >= assessment.requiredVersion else {
            throw CADDocumentFormatError.insufficientFormat(provided: payload.schemaVersion, required: assessment.requiredVersion)
        }
        if let storedSchema {
            guard storedSchema <= supportedVersion else { throw CADDocumentFormatError.unsupportedFormat(storedSchema) }
            guard payload.schemaVersion >= storedSchema else {
                throw CADDocumentFormatError.downgrade(provided: payload.schemaVersion, stored: storedSchema)
            }
        }
    }

    /// These stripped copies are DISPLAY caches only. The original persisted
    /// rows stay byte-for-byte intact, the entire session is read-only, and no
    /// evaluator may consume them as an absolute editable replacement.
    static func cachedPlane(from data: Data) throws -> ConstructionPlane {
        try cachedValue(ConstructionPlane.self, data: data, removing: "definition")
    }
    static func cachedSketch(from data: Data) throws -> Sketch {
        try cachedValue(Sketch.self, data: data, removing: "support")
    }
    /// Display-only copy of an unreadable associative axis: the cached line
    /// survives, the definition does not. The original row bytes stay intact
    /// and the document is read-only.
    static func cachedAxis(from data: Data) throws -> ConstructionAxis {
        try cachedValue(ConstructionAxis.self, data: data, removing: "definition")
    }
    static func cachedDatumPoint(from data: Data) throws -> DatumPoint {
        try cachedValue(DatumPoint.self, data: data, removing: "definition")
    }
    private static func cachedValue<T: Decodable>(_ type: T.Type, data: Data, removing key: String) throws -> T {
        guard var object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CADDocumentFormatError.malformedAssociation(key)
        }
        object.removeValue(forKey: key)
        return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: object))
    }
}
