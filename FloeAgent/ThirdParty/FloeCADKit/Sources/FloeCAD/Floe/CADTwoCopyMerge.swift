import Foundation

/// This is a semantic feature-history merge, never whole-project insertion.
/// Every decision is made against an immutable, verified common checkpoint.
public nonisolated struct CADTwoCopyMergeRow: Codable, Sendable, Identifiable {
    public var id: String
    public var name: String
    /// current, incoming, same, conflict, unsupported
    public var status: String
    public var current: String
    public var incoming: String
}

public nonisolated struct CADTwoCopyMergeReview: Codable, Sendable, Identifiable {
    public var id: UUID
    public var baseVersionID: UUID
    public var baseName: String
    public var baseModelSHA256: String
    public var baseContentSHA256: String
    public var baseRevision: Int
    public var currentRevision: Int
    public var currentContentSHA256: String
    public var currentModelSHA256: String
    public var incomingRevision: Int
    public var incomingContentSHA256: String
    public var incomingModelSHA256: String
    public var rows: [CADTwoCopyMergeRow]
    public var conflictIDs: [String]
    public var unsupportedIDs: [String]
}

public nonisolated struct CADTwoCopyMergeResult: Codable, Sendable {
    public var applied: Bool
    public var revision: Int
    public var contentSHA256: String
    public var modelSHA256: String
}

nonisolated struct CADTwoCopyMergeBase: Sendable {
    var manifest: CADManifest
    var document: CADDocumentRecord
    var modelSHA256: String
    var resourceSHA256: [String: String]
    var name: String
}

nonisolated struct CADTwoCopyMergeSnapshot: Sendable {
    var manifest: CADManifest
    var record: CADDocumentRecord
    var modelSHA256: String
    var resourceSHA256: [String: String]
    var base: CADTwoCopyMergeBase
}

nonisolated enum CADTwoCopyMergeCore {
    static func bytes<T: Encodable>(_ value: T) throws -> Data {
        try cadRecordEncoder().encode(value)
    }

    /// Feature order is merged separately from each feature's authored fields.
    static func value(_ feature: CADFeatureRecord?) throws -> Data? {
        guard var feature else { return nil }
        feature.orderIndex = 0
        guard let kind = decodeFeatureKind(feature.kind),
              let outputs = decodeBodyIDs(feature.outputBodyIDs) else {
            throw failure("unsupported", "cad.merge.unsupported", "These changes cannot be merged yet.")
        }
        feature.kind = try bytes(kind)
        feature.outputBodyIDs = try bytes(outputs)
        return try bytes(feature)
    }

    static func indexed(_ rows: [CADFeatureRecord]) throws -> [UUID: CADFeatureRecord] {
        var result: [UUID: CADFeatureRecord] = [:]
        for row in rows {
            guard result.updateValue(row, forKey: row.featureID) == nil else {
                throw failure("invalid_history", "cad.merge.invalidHistory", "The feature history is not valid.")
            }
        }
        return result
    }

    static func order(_ record: CADDocumentRecord) -> [UUID] {
        record.features.sorted { $0.orderIndex < $1.orderIndex }.map(\.featureID)
    }

    static func status<T: Equatable>(_ base: T, _ current: T, _ incoming: T) -> String? {
        if current == base, incoming == base { return nil }
        if current == incoming { return "same" }
        if incoming == base { return "current" }
        if current == base { return "incoming" }
        return "conflict"
    }

    static func describe(_ feature: CADFeatureRecord?) -> String {
        guard let feature else {
            return FloeCADStrings.text("cad.merge.removed", "Removed")
        }
        guard let kind = decodeFeatureKind(feature.kind) else { return feature.name }
        if case let .baseSolid(source) = kind {
            return source.name.isEmpty
                ? FloeCADStrings.text("cad.feature.importedBody", "Imported body") : source.name
        }
        let values = DocumentSession.expressionSlots(in: kind).map {
            "\($0.name): \($0.expr.formula ?? String(format: "%.6g", $0.expr.value))"
        }
        if !values.isEmpty { return values.joined(separator: ", ") }
        // Primitive dimensions and non-expression fields remain inspectable
        // in the explicit comparison details, rather than being replaced by a
        // digest or an invented parameter value.
        guard let json = try? JSONSerialization.jsonObject(with: feature.kind),
              let data = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return feature.name }
        return String(text.prefix(320))
    }

    static func rows(base: CADTwoCopyMergeSnapshot, current: CADTwoCopyMergeSnapshot,
                     incoming: CADTwoCopyMergeSnapshot) throws -> [CADTwoCopyMergeRow] {
        for snapshot in [base, current, incoming] {
            let bodies = snapshot.record.bodies.map(\.bodyID)
            let positions = snapshot.record.features.map(\.orderIndex)
            guard Set(bodies).count == bodies.count, Set(positions).count == positions.count else {
                throw failure("invalid_history", "cad.merge.invalidHistory", "The feature history is not valid.")
            }
        }
        let b = try indexed(base.record.features)
        let a = try indexed(current.record.features)
        let c = try indexed(incoming.record.features)
        var rows: [CADTwoCopyMergeRow] = []
        for id in Set(b.keys).union(a.keys).union(c.keys).sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let state = status(try value(b[id]), try value(a[id]), try value(c[id])) else { continue }
            rows.append(CADTwoCopyMergeRow(
                id: "feature:\(id.uuidString)", name: a[id]?.name ?? c[id]?.name ?? b[id]?.name ?? "",
                status: state, current: describe(a[id]), incoming: describe(c[id])))
        }
        if let state = status(order(base.record), order(current.record), order(incoming.record)) {
            rows.append(CADTwoCopyMergeRow(id: "order", name: FloeCADStrings.text("cad.merge.historyOrder", "History order"),
                status: state, current: current.record.features.sorted { $0.orderIndex < $1.orderIndex }.map(\.name).joined(separator: " → "),
                incoming: incoming.record.features.sorted { $0.orderIndex < $1.orderIndex }.map(\.name).joined(separator: " → ")))
        }
        let old = try context(base), local = try context(current), other = try context(incoming)
        for key in Set(old.keys).union(local.keys).union(other.keys).sorted() {
            guard let state = status(old[key], local[key], other[key]) else { continue }
            // Existing local records are retained. Incoming changes to a
            // non-feature section are never silently discarded or copied with
            // guessed resource ownership, including material/UV payloads.
            let unsupported = state == "incoming" || state == "conflict"
                || key == "appearance" || key == "resources"
            rows.append(CADTwoCopyMergeRow(id: "section:\(key)", name: sectionName(key),
                status: unsupported ? "unsupported" : state,
                current: FloeCADStrings.text("cad.merge.current", "Current copy"),
                incoming: unsupported ? FloeCADStrings.text("cad.merge.unsupported", "These changes cannot be merged yet.")
                    : FloeCADStrings.text("cad.merge.retained", "Kept in the current copy")))
        }
        // An integrated body schema may gain authored UV/topology fields
        // after this bounded merge implementation. Detect their serialized
        // presence without erasing, copying or guessing their semantics.
        // Keep this check before rebuilding any geometry, even when the new
        // field is identical in the two copies.
        if rows.contains(where: { $0.id.hasPrefix("feature:") }),
           try [base, current, incoming].contains(where: { snapshot in
               try snapshot.record.bodies.contains(where: hasUnmergedBodyFields)
           }) {
            rows.append(CADTwoCopyMergeRow(id: "section:bodyExtensions",
                name: FloeCADStrings.text("cad.merge.section.bodyExtensions", "Additional shape data"),
                status: "unsupported", current: "",
                incoming: FloeCADStrings.text("cad.merge.unsupported", "These changes cannot be merged yet.")))
        }
        // Geometry caches are derived only when an authored feature that
        // writes that body changed on the SAME branch. A raw geometry edit
        // cannot disappear merely because a different feature also changed.
        for (label, branch) in [("current", current), ("incoming", incoming)] {
            let changed = try Set(branch.record.features.filter {
                try value($0) != value(b[$0.featureID])
            }.map(\.featureID)).union(Set(b.keys).subtracting(branch.record.features.map(\.featureID)))
            let owned = Set((base.record.features + branch.record.features).filter { changed.contains($0.featureID) }
                .flatMap { decodeBodyIDs($0.outputBodyIDs) ?? [] }.map(\.raw))
            let left = Dictionary(uniqueKeysWithValues: base.record.bodies.map { ($0.bodyID, $0) })
            let right = Dictionary(uniqueKeysWithValues: branch.record.bodies.map { ($0.bodyID, $0) })
            for id in Set(left.keys).union(right.keys) where !owned.contains(id) {
                if try geometry(left[id]) != geometry(right[id]) {
                    rows.append(CADTwoCopyMergeRow(id: "geometry:\(label):\(id.uuidString)",
                        name: right[id]?.name ?? left[id]?.name ?? "", status: "unsupported",
                        current: "", incoming: FloeCADStrings.text("cad.merge.untrackedGeometry", "This shape change has no matching feature edit.")))
                }
            }
        }
        return rows
    }

    static func mergedFeatures(base: CADTwoCopyMergeSnapshot, current: CADTwoCopyMergeSnapshot,
                               incoming: CADTwoCopyMergeSnapshot, rows: [CADTwoCopyMergeRow],
                               resolutions: [String: String]) throws -> [FeatureNode] {
        guard !rows.contains(where: { $0.status == "unsupported" }) else {
            throw failure("unsupported", "cad.merge.unsupported", "These changes cannot be merged yet.")
        }
        let conflicts = Set(rows.filter { $0.status == "conflict" }.map(\.id))
        guard Set(resolutions.keys).isSubset(of: conflicts),
              conflicts.allSatisfy({ ["current", "incoming"].contains(resolutions[$0] ?? "") }) else {
            throw failure("unresolved_conflicts", "cad.merge.resolveConflicts", "Choose a copy for each conflict.")
        }
        let b = try indexed(base.record.features), a = try indexed(current.record.features), c = try indexed(incoming.record.features)
        var selected: [UUID: CADFeatureRecord] = [:]
        for id in Set(b.keys).union(a.keys).union(c.keys) {
            let state = status(try value(b[id]), try value(a[id]), try value(c[id]))
            let useIncoming = state == "incoming" || (state == "conflict" && resolutions["feature:\(id.uuidString)"] == "incoming")
            if let value = useIncoming ? c[id] : a[id] { selected[id] = value }
        }
        let state = status(order(base.record), order(current.record), order(incoming.record))
        let useIncoming = state == "incoming" || (state == "conflict" && resolutions["order"] == "incoming")
        let preferred = useIncoming ? order(incoming.record) : order(current.record)
        var seen = Set<UUID>()
        let ids = (preferred + order(current.record) + order(incoming.record) + order(base.record))
            .filter { selected[$0] != nil && seen.insert($0).inserted }
        return try ids.map { id in
            let row = selected[id]!
            guard let kind = decodeFeatureKind(row.kind), let outputs = decodeBodyIDs(row.outputBodyIDs) else {
                throw failure("unsupported", "cad.merge.unsupported", "These changes cannot be merged yet.")
            }
            return FeatureNode(id: FeatureID(raw: id), name: row.name, kind: kind,
                               suppressed: row.suppressed, outputBodyIDs: outputs)
        }
    }

    private static func geometry(_ row: CADBodyRecord?) throws -> Data? {
        guard let row else { return nil }
        return try bytes([row.meshSHA256 ?? "", row.brepSHA256 ?? "",
                          row.transform.base64EncodedString(), row.primitive?.base64EncodedString() ?? ""])
    }

    private static func hasUnmergedBodyFields(_ body: CADBodyRecord) throws -> Bool {
        let known: Set<String> = ["bodyID", "name", "transform", "primitive", "meshBlob", "meshSHA256",
            "isHidden", "material", "faceMaterials", "faceNamingSnapshot", "brepBlob", "brepSHA256"]
        let object = try JSONSerialization.jsonObject(with: bytes(body)) as? [String: Any] ?? [:]
        return !Set(object.keys).isSubset(of: known)
    }

    private static func context(_ state: CADTwoCopyMergeSnapshot) throws -> [String: Data] {
        let r = state.record
        var bodyValues: [String: Data] = [:]
        for var body in r.bodies {
            body.meshBlob = nil; body.meshSHA256 = nil; body.brepBlob = nil; body.brepSHA256 = nil
            body.faceNamingSnapshot = nil; body.transform = Data(); body.primitive = nil
            bodyValues[body.bodyID.uuidString] = try bytes(body)
        }
        return ["metadata": try bytes([state.manifest.name, state.manifest.unit ?? "", String(describing: state.manifest.tolerance)]),
                "sketches": try bytes(r.sketches), "planes": try bytes(r.planes), "axes": try bytes(r.axes),
                "datumPoints": try bytes(r.datumPoints), "variables": try bytes(r.variables),
                "images": try bytes(r.images), "symbols": try bytes(r.symbols),
                "rollback": try bytes(r.rollbackIndex), "folders": try bytes(r.itemFolders),
                "folderID": try bytes(r.folderID), "assembly": try bytes(r.assembly),
                "drawings": try bytes(r.drawings), "scripts": try bytes(r.scripts),
                "presentation": try bytes(r.sceneSettings), "materials": try bytes(r.materials),
                "animation": try bytes(r.animation), "appearance": try bytes(bodyValues),
                "resources": try bytes(state.resourceSHA256)]
    }

    /// Derived mesh/B-rep and image blobs are reduced to resource digests.
    /// Authored feature records remain in the plan, including any immutable
    /// native import source required to replay that feature history.
    static func resources(_ record: CADDocumentRecord, blobs: [String: Data]) -> [String: String] {
        let derived = Set(record.bodies.flatMap { [$0.meshBlob, $0.brepBlob].compactMap { $0 } })
        return blobs.filter { !derived.contains($0.key) && $0.key != "blobs/thumbnail.img" }
            .mapValues { FileCADDocumentStore.sha256($0) }
    }

    private static func sectionName(_ section: String) -> String {
        FloeCADStrings.text("cad.merge.section.\(section)", section.capitalized)
    }

    static func failure(_ code: String, _ key: String, _ fallback: String) -> CADDocumentError {
        CADDocumentError(code: "merge_\(code)", message: FloeCADStrings.text(key, fallback))
    }
}

nonisolated struct CADTwoCopyMergeFeaturesCommand: DocumentCommand {
    let title: String
    let before: FeatureGraph
    let after: FeatureGraph
    func apply(to document: inout DesignDocument) { document.features = after }
    func revert(in document: inout DesignDocument) { document.features = before }
}
