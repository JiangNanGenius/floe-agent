// SPDX-License-Identifier: MPL-2.0
#if os(iOS)
import Foundation
import simd
import FloeCAD
import FloeInteriorCore
import simd

/// Builds a real, independent native 2D CAD document from one already
/// projected drawing page.
///
/// The result is NOT an empty sketch, a renamed 3D package or a parameter JSON
/// file: every exported point is a native `SketchEntity` created through the
/// public `sketch.create` / `sketch.addEntities` / `sketch.addText` command
/// path. The document is saved, hash-verified and reopened before success is
/// reported. Source drawing layers become sketch names; annotation text is
/// converted to native outline geometry when requested. Every representational
/// loss is written to the receipt.
@MainActor
struct FloeBuildingCADNative2DBuilder {
    let source: FloeCADDocument
    let pageID: UUID
    let sourcePageIdentity: FloeBuildingCADNativeIdentity

    struct PreparedEntity {
        var layer: String
        var payload: [String: Any]
    }

    func build(at url: URL,
               options: FloeBuildingCADNative2DOptions) async throws
        -> FloeBuildingCADNative2DReceipt {
        guard !source.isClosed else { throw FloeBuildingCADError.documentClosed }
        guard !source.hasUnsavedChanges else{throw FloeBuildingCADError.sourceNotSaved}
        let sourceChangeCount=source.buildingChangeCount
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw FloeBuildingCADError.existingOutput(url.path)
        }
        let saved = source.savedIdentity
        guard !saved.modelSHA256.isEmpty,
              saved.revision == sourcePageIdentity.revision,
              saved.contentSHA256 == sourcePageIdentity.contentSHA256,
              saved.modelSHA256 == sourcePageIdentity.modelSHA256 else {
            throw FloeBuildingCADError.sourceNotSaved
        }
        guard let stored = await FloeCADDocument.storedIdentity(at: source.url),
              stored.revision == saved.revision,
              stored.contentSHA256 == saved.contentSHA256,
              stored.modelSHA256 == saved.modelSHA256 else {
            throw FloeBuildingCADError.sourceNotSaved
        }

        let service = CADDrawingService(document: source)
        let geometry = await service.pageGeometryAsync(pageID: pageID)
        guard geometry["ok"] as? Bool == true,
              geometry["projectionComplete"] as? Bool == true,
              geometry["outputBlocked"] as? Bool == false,
              geometry["missingExplodedView"] as? Bool != true else {
            throw FloeBuildingCADError.projectionIncomplete(
                geometry["message"] as? String
                    ?? "The drawing page is incomplete; no native 2D document was created.")
        }
        let rows = geometry["entities"] as? [[String: Any]] ?? []
        guard !rows.isEmpty else {
            throw FloeBuildingCADError.projectionIncomplete(
                "The drawing page projected no geometry; an empty native 2D document is not a deliverable.")
        }
        guard rows.count <= options.maximumEntityCount else {
            throw FloeBuildingCADError.unsupportedFeature(
                "The drawing page has \(rows.count) projected entities; the native 2D conversion budget is \(options.maximumEntityCount).")
        }
        var polylineConversions = 0
        var prepared: [PreparedEntity] = []
        prepared.reserveCapacity(rows.count)
        for (index, row) in rows.enumerated() {
            guard let kind = row["kind"] as? String else {
                throw FloeBuildingCADError.invalidNativeState(
                    "The projected entity \(index) has no kind.")
            }
            let layer = sanitizedLayer(row["layer"] as? String)
            switch kind {
            case "line":
                guard let a = point(row["a"]), let b = point(row["b"]),
                      simd_distance(a, b) > 1e-9 else {
                    throw FloeBuildingCADError.invalidNativeState(
                        "The projected line \(index) is degenerate.")
                }
                prepared.append(PreparedEntity(layer: layer, payload: [
                    "kind": "line", "a": [a.x, a.y], "b": [b.x, b.y],
                ]))
            case "circle":
                guard let center = point(row["center"]),
                      let radius = FloeBuildingCADGeometry.number(row["radius"]),
                      radius > 1e-9 else {
                    throw FloeBuildingCADError.invalidNativeState(
                        "The projected circle \(index) is degenerate.")
                }
                prepared.append(PreparedEntity(layer: layer, payload: [
                    "kind": "circle", "center": [center.x, center.y], "radius": radius,
                ]))
            case "arc":
                guard let center = point(row["center"]),
                      let radius = FloeBuildingCADGeometry.number(row["radius"]),
                      radius > 1e-9,
                      let start = FloeBuildingCADGeometry.number(row["startAngle"]),
                      let end = FloeBuildingCADGeometry.number(row["endAngle"]) else {
                    throw FloeBuildingCADError.invalidNativeState(
                        "The projected arc \(index) has incomplete values.")
                }
                prepared.append(PreparedEntity(layer: layer, payload: [
                    "kind": "arc", "center": [center.x, center.y],
                    "radius": radius, "startAngle": start, "endAngle": end,
                ]))
            case "polyline":
                guard let rows=row["points"] as? [[Any]],rows.count>=2 else {
                    throw FloeBuildingCADError.invalidNativeState(
                        "The projected polyline \(index) has fewer than two points.")
                }
                let values=try rows.map { raw -> SIMD2<Double> in
                    guard raw.count==2,let x=FloeBuildingCADGeometry.number(raw[0]),
                          let y=FloeBuildingCADGeometry.number(raw[1]),x.isFinite,y.isFinite else {
                        throw FloeBuildingCADError.invalidNativeState("A projected polyline contains an invalid vertex.")
                    }
                    return SIMD2(x,y)
                }
                let segments=try FloeBuildingCADNativePolyline.segments(points:values,
                    closed:row["closed"] as? Bool ?? false,maximumCount:options.maximumEntityCount-prepared.count)
                polylineConversions += 1
                for segment in segments {
                    prepared.append(PreparedEntity(layer:layer,payload:[
                        "kind":"line","a":[segment.a.x,segment.a.y],"b":[segment.b.x,segment.b.y]
                    ]))
                }
            default:
                throw FloeBuildingCADError.unsupportedFeature(
                    "The projected entity kind '\(kind)' has no editable native 2D representation.")
            }
        }

        guard prepared.count<=options.maximumEntityCount else {
            throw FloeBuildingCADError.unsupportedFeature("Expanded page geometry exceeds the native 2D entity budget.")
        }

        var losses: [String] = [
            "The sheet frame and title block are export-render elements, not page geometry; they are not included.",
            "Native sketches have no drawing layer/group table; each projected layer is preserved as one named sketch. Sheet-view grouping and view names are flattened into those layer sketches.",
            "Dimensions are flattened to their vector linework and optional native outline text; they are not associative dimension objects.",
            "The document is 2D sheet-space millimetres: it contains no 3D bodies, features or history.",
        ]
        if polylineConversions > 0 {
            losses.append(
                "\(polylineConversions) projected polyline group(s) were flattened to native line segments; vertex coordinates and closure are preserved.")
        }

        try Task.checkCancellation()
        let target = try await FloeCADDocument.create(
            at: url, name: "Cabinet drawing 2D")
        do {
            let session = FloeBuildingCADSession(document: target)
            var layerGroups: [String: [PreparedEntity]] = [:]
            for entity in prepared {
                layerGroups[entity.layer, default: []].append(entity)
            }
            let sortedLayers = layerGroups.keys.sorted()
            var sketchIDs: [UUID] = []
            var nativeEntityCount = 0
            var usedNames = Set<String>()
            for layer in sortedLayers {
                guard let entities = layerGroups[layer], !entities.isEmpty else { continue }
                var name = "Drawing \(layer)"
                var suffix = 2
                while usedNames.contains(name) {
                    name = "Drawing \(layer) \(suffix)"
                    suffix += 1
                }
                usedNames.insert(name)
                let sketch = try session.executeNative("sketch.create", [
                    "name": name,
                    "origin": [0, 0, 0],
                    "xAxis": [1, 0, 0],
                    "yAxis": [0, 1, 0],
                ])
                guard let sketchID = FloeBuildingCADGeometry.uuid(sketch["sketchID"]) else {
                    throw FloeBuildingCADError.invalidNativeState(
                        "sketch.create returned no native 2D sketch id.")
                }
                sketchIDs.append(sketchID)
                var index = 0
                while index < entities.count {
                    try Task.checkCancellation()
                    let end = min(index + 500, entities.count)
                    let batch = Array(entities[index..<end])
                    let reply = try session.executeNative("sketch.addEntities", [
                        "sketchID": sketchID.uuidString,
                        "entities": batch.map(\.payload),
                    ])
                    guard let ids = reply["entityIDs"] as? [String],
                          ids.count == batch.count else {
                        throw FloeBuildingCADError.invalidNativeState(
                            "sketch.addEntities did not confirm every native 2D entity.")
                    }
                    nativeEntityCount += batch.count
                    index = end
                }
            }
            guard nativeEntityCount == prepared.count else {
                throw FloeBuildingCADError.invalidNativeState(
                    "The native 2D document contains \(nativeEntityCount) of \(prepared.count) projected entities.")
            }

            let textRows = (geometry["texts"] as? [[String: Any]] ?? []).filter {
                let text = ($0["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return !text.isEmpty
            }
            var textCount = 0
            if options.includeAnnotationText {
                guard textRows.count <= options.maximumTextCount else {
                    throw FloeBuildingCADError.unsupportedFeature(
                        "The drawing page has \(textRows.count) text rows; the native outline budget is \(options.maximumTextCount). Re-run with includeAnnotationText=false to keep the exact loss explicit.")
                }
                if !textRows.isEmpty {
                    let sketch = try session.executeNative("sketch.create", [
                        "name": "Drawing text",
                        "origin": [0, 0, 0],
                        "xAxis": [1, 0, 0],
                        "yAxis": [0, 1, 0],
                    ])
                    guard let sketchID = FloeBuildingCADGeometry.uuid(sketch["sketchID"]) else {
                        throw FloeBuildingCADError.invalidNativeState(
                            "sketch.create returned no text sketch id.")
                    }
                    sketchIDs.append(sketchID)
                    for row in textRows {
                        try Task.checkCancellation()
                        guard let text = (row["text"] as? String)?
                                .trimmingCharacters(in: .whitespacesAndNewlines),
                              !text.isEmpty,
                              let position = point(row["position"]),
                              let height = FloeBuildingCADGeometry.number(row["height"]),
                              height > 0 else {
                            throw FloeBuildingCADError.invalidNativeState(
                                "A drawing text row has an invalid placement.")
                        }
                        do {
                            let reply = try session.executeNative("sketch.addText", [
                                "sketchID": sketchID.uuidString,
                                "text": text,
                                "height": height,
                                "origin": [position.x, position.y],
                            ])
                            guard let count = FloeBuildingCADGeometry.integer(reply["entityCount"]),
                                  count > 0 else {
                                throw FloeBuildingCADError.invalidNativeState(
                                    "sketch.addText produced no native outline entities.")
                            }
                            nativeEntityCount += count
                            textCount += 1
                        } catch {
                            if Task.isCancelled { throw CancellationError() }
                            let preview = String(text.prefix(60))
                            throw FloeBuildingCADError.unsupportedFeature(
                                "The drawing text '\(preview)' cannot be represented as native outlines: \(error.localizedDescription). Re-run with includeAnnotationText=false to export geometry/dimension lines only and record the text loss.")
                        }
                    }
                }
                if textCount > 0 {
                    losses.append(
                        "Annotation text is native outline geometry in one text sketch, not an editable native text object; each source text layer is not preserved separately.")
                }
            } else if !textRows.isEmpty {
                losses.append(
                    "\(textRows.count) annotation/dimension text row(s) were deliberately omitted (includeAnnotationText=false).")
            }
            guard nativeEntityCount <= options.maximumEntityCount else {
                throw FloeBuildingCADError.unsupportedFeature(
                    "The native 2D document would contain \(nativeEntityCount) entities, above the \(options.maximumEntityCount) budget.")
            }

            let summary = target.summary()
            guard summary.bodyCount == 0,
                  summary.featureCount == 0,
                  summary.hasAssembly == false else {
                throw FloeBuildingCADError.invalidNativeState(
                    "The native 2D document unexpectedly contains 3D bodies, features or an assembly.")
            }
            guard summary.sketchCount == sketchIDs.count else {
                throw FloeBuildingCADError.invalidNativeState(
                    "The native 2D document has \(summary.sketchCount) sketches, expected \(sketchIDs.count).")
            }
            try verifySketchTotals(target, expectedSketchIDs: sketchIDs,
                                   minimumEntityCount: prepared.count)
            try Task.checkCancellation()
            let save = await target.save()
            guard save.succeeded, !save.modelSHA256.isEmpty else {
                throw FloeBuildingCADError.exportFailed(
                    save.error ?? "The native 2D document could not be saved with a verified identity.")
            }
            let identity = FloeBuildingCADNativeIdentity(
                revision: save.revision, contentSHA256: save.contentSHA256,
                modelSHA256: save.modelSHA256)
            guard let readBack = await FloeCADDocument.storedIdentity(at: url),
                  readBack.revision == identity.revision,
                  readBack.contentSHA256 == identity.contentSHA256,
                  readBack.modelSHA256 == identity.modelSHA256 else {
                throw FloeBuildingCADError.exportFailed(
                    "The native 2D document failed its stored identity read-back.")
            }
            target.close()
            try await verifyReopen(at: url, sketchIDs: sketchIDs,
                                   minimumEntityCount: prepared.count)
            guard !source.isClosed,!source.hasUnsavedChanges,source.buildingChangeCount==sourceChangeCount,
                  source.savedIdentity.modelSHA256 == sourcePageIdentity.modelSHA256,
                  source.savedIdentity.contentSHA256 == sourcePageIdentity.contentSHA256,
                  source.savedIdentity.revision == sourcePageIdentity.revision else {
                throw FloeBuildingCADError.invalidNativeState(
                    "Creating the native 2D document changed the source drawing identity.")
            }
            return FloeBuildingCADNative2DReceipt(
                scope: "native-2d",
                units: "mm",
                sourcePageID: pageID,
                sourcePageIdentity: sourcePageIdentity,
                documentIdentity: identity,
                sketchIDs: sketchIDs,
                layers: sortedLayers,
                entityCount: nativeEntityCount,
                textCount: textCount,
                losses: losses)
        } catch {
            target.close()
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }

    private func verifySketchTotals(_ document: FloeCADDocument,
                                    expectedSketchIDs: [UUID],
                                    minimumEntityCount: Int) throws {
        let outcome = document.nativeQueryJSON([
            "scope": "sketches", "sketchLimit": 512, "entityLimit": 1,
        ])
        guard outcome.isOK,
              let object = FloeBuildingCADGeometry.object(outcome),
              let rows = object["rows"] as? [[String: Any]] else {
            throw FloeBuildingCADError.invalidNativeState(
                outcome.message ?? "The native 2D sketch list could not be read.")
        }
        let ids = rows.compactMap { FloeBuildingCADGeometry.uuid($0["id"]) }
        guard Set(ids) == Set(expectedSketchIDs) else {
            throw FloeBuildingCADError.invalidNativeState(
                "The native 2D sketch identities do not match the created sketches.")
        }
        let total = rows.reduce(0) {
            $0 + (FloeBuildingCADGeometry.integer($1["entityTotal"]) ?? 0)
        }
        guard total >= minimumEntityCount else {
            throw FloeBuildingCADError.invalidNativeState(
                "The native 2D document reports \(total) entities, fewer than the \(minimumEntityCount) projected entities.")
        }
    }

    private func verifyReopen(at url: URL, sketchIDs: [UUID],
                              minimumEntityCount: Int) async throws {
        let reopened = try await FloeCADDocument.open(at: url)
        defer { reopened.close() }
        try verifySketchTotals(reopened, expectedSketchIDs: sketchIDs,
                               minimumEntityCount: minimumEntityCount)
        let summary = reopened.summary()
        guard summary.sketchCount == sketchIDs.count else {
            throw FloeBuildingCADError.invalidNativeState(
                "The reopened native 2D document has a different sketch count.")
        }
        guard summary.bodyCount == 0, summary.featureCount == 0,
              summary.hasAssembly == false else {
            throw FloeBuildingCADError.invalidNativeState(
                "The reopened native 2D document contains 3D geometry.")
        }
    }

    private func point(_ value: Any?) -> SIMD2<Double>? {
        guard let rows = value as? [Any], rows.count == 2 else { return nil }
        let numbers = rows.compactMap { FloeBuildingCADGeometry.number($0) }
        guard numbers.count == 2, numbers.allSatisfy(\.isFinite) else { return nil }
        return SIMD2(numbers[0], numbers[1])
    }

    private func sanitizedLayer(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let value = trimmed.isEmpty ? "unspecified" : trimmed
        return String(value.prefix(80))
    }
}

/// A native fit spline smooths its input vertices (SketchTypes.splinePoints).
/// Projected polylines must remain straight spans, including their corners.
nonisolated enum FloeBuildingCADNativePolyline {
    struct Segment:Equatable,Sendable {var a:SIMD2<Double>;var b:SIMD2<Double>}
    static func segments(points:[SIMD2<Double>],closed:Bool,maximumCount:Int) throws -> [Segment] {
        guard points.count>=2,maximumCount>0,points.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else {
            throw FloeBuildingCADError.invalidNativeState("Invalid or over-budget projected polyline.")
        }
        var result:[Segment]=[]
        func append(_ a:SIMD2<Double>,_ b:SIMD2<Double>) throws {
            if a==b{return}
            let length=simd_distance(a,b)
            guard length.isFinite,length>1e-9 else{throw FloeBuildingCADError.invalidNativeState("Degenerate projected polyline span.")}
            guard result.count<maximumCount else{throw FloeBuildingCADError.unsupportedFeature("The expanded polyline exceeds the native 2D entity budget.")}
            result.append(.init(a:a,b:b))
        }
        for index in 1..<points.count {try append(points[index-1],points[index])}
        if closed,let last=points.last,let first=points.first {try append(last,first)}
        guard !result.isEmpty else{throw FloeBuildingCADError.invalidNativeState("The projected polyline has no nondegenerate spans.")}
        return result
    }
}

public extension FloeBuildingCADSession {
    /// Create independent native 2D geometry for one projected page. The
    /// supplied page document may be the project or a verified sheet snapshot;
    /// its saved identity must match `sourcePageIdentity` exactly and is never
    /// written back by this conversion.
    func createNative2DProject(pageDocument: FloeCADDocument,
                               pageID: UUID,
                               sourcePageIdentity: FloeBuildingCADNativeIdentity,
                               at url: URL,
                               options: FloeBuildingCADNative2DOptions = .init()) async throws
        -> FloeBuildingCADNative2DReceipt {
        let builder = FloeBuildingCADNative2DBuilder(
            source: pageDocument, pageID: pageID,
            sourcePageIdentity: sourcePageIdentity)
        return try await builder.build(at: url, options: options)
    }

    /// Build a native 2D document for a page in this session's own document.
    /// The document must already be saved and verified.
    func createNative2DProject(pageID: UUID, at url: URL,
                               options: FloeBuildingCADNative2DOptions = .init()) async throws
        -> FloeBuildingCADNative2DReceipt {
        try beginExclusiveOperation()
        defer { endExclusiveOperation() }
        let identity = try await ensureVerifiedSavedIdentity()
        return try await createNative2DProject(
            pageDocument: document, pageID: pageID,
            sourcePageIdentity: identity, at: url, options: options)
    }
}
#endif
