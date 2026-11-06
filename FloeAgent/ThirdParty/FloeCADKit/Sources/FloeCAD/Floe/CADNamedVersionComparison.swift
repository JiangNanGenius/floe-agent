//
//  CADNamedVersionComparison.swift
//  FloeCADKit
//
//  Exact, source-level comparison of two committed whole-document states.
//
//  This is deliberately NOT a visual or geometric diff. It compares the
//  persisted records body-by-body, feature-by-feature, material-by-material,
//  assembly/drawing/presentation/animation records and the document's exact
//  content/model digests. Parameter differences are read from the ACTUAL
//  stored JSON (feature kind, material PBR values, transforms, variables), so
//  no change is invented and no rendered image is treated as evidence.
//

import Foundation

nonisolated struct CADNamedVersionComparisonBuilder {
    /// Page size for the default/visible summary. The caller can request a
    /// different bounded page and every remaining difference is reachable.
    static let maximumDifferences = CADNamedVersionComparison.defaultPageLimit
    /// Hard upper bound for one requested comparison page. A client can page
    /// through an arbitrarily large diff in bounded chunks.
    static let maximumPageLimit = 240
    static let maximumRecordChunkLimit = 256
    /// One record page chunk is byte-bounded so a single huge embedded string
    /// (for example a texture) cannot produce an unbounded reply line. Chunks
    /// are split at Unicode scalar boundaries and concatenate back exactly.
    static let maximumRecordChunkBytes = 512

    static func compare(from: CADNamedVersionState,
                        fromReference: CADNamedVersionReference,
                        to: CADNamedVersionState,
                        toReference: CADNamedVersionReference,
                        currentHasUnsavedChanges: Bool,
                        offset: Int = 0,
                        limit: Int = maximumDifferences) -> CADNamedVersionComparison {
        let pageOffset = max(0, offset)
        let pageLimit = min(max(1, limit), maximumPageLimit)
        var collector = Collector(offset: pageOffset, limit: pageLimit)
        compareMetadata(from, to, into: &collector)
        compareBodies(from, to, into: &collector)
        compareInlineRecords("sketches", from.document.sketches, to.document.sketches,
                             into: &collector)
        compareInlineRecords("planes", from.document.planes, to.document.planes,
                             into: &collector)
        compareInlineRecords("axes", from.document.axes, to.document.axes,
                             into: &collector)
        compareInlineRecords("symbols", from.document.symbols, to.document.symbols,
                             into: &collector)
        compareImages(from, to, into: &collector)
        compareFeatures(from, to, into: &collector)
        compareVariables(from, to, into: &collector)
        compareMaterials(from, to, into: &collector)
        compareAssembly(from, to, into: &collector)
        compareDrawings(from, to, into: &collector)
        if from.document.building != to.document.building {
            let differences=jsonDifferences(from.document.building,to.document.building,prefix:"building",limit:6)
            if !differences.isEmpty {
                collector.add(section:"metadata",change:"modified",identifier:"building",
                    name:FloeCADStrings.text("cad.building.title","Building Design"),detail:differences.joined(separator:"; "))
            }
        }
        comparePresentation(from, to, into: &collector)
        compareAnimation(from, to, into: &collector)
        compareScripts(from, to, into: &collector)
        compareItemFolders(from, to, into: &collector)

        let identical = fromReference.modelSHA256 == toReference.modelSHA256
        let contentIdentical = fromReference.contentSHA256 == toReference.contentSHA256
        if identical && !contentIdentical {
            collector.add(section: "preview", change: "modified", identifier: "preview",
                          name: "Viewport preview",
                          detail: "The stored preview image changed; the document model is identical.")
        }

        let order = ["metadata", "geometry", "sketches", "planes", "axes", "images",
                     "symbols", "features", "parameters", "variables", "materials",
                     "assembly", "drawings", "presentation", "animation", "scripts",
                     "preview"]
        let sections = Array(collector.sections).sorted {
            (order.firstIndex(of: $0) ?? order.count)
                < (order.firstIndex(of: $1) ?? order.count)
        }
        let endOffset = pageOffset + collector.items.count
        let hasMore = endOffset < collector.total
        let note = currentHasUnsavedChanges
            ? FloeCADStrings.text("cad.versions.compare.unsavedNote",
                "This comparison uses the last committed document. Unsaved edits are not included; save or create a version to compare them.")
            : nil
        return CADNamedVersionComparison(
            from: fromReference, to: toReference,
            identical: identical, contentIdentical: contentIdentical,
            revisionChanged: fromReference.revision != toReference.revision,
            changedSections: sections,
            differences: collector.items,
            truncated: hasMore,
            currentHasUnsavedChanges: currentHasUnsavedChanges,
            note: note,
            totalDifferences: collector.total,
            nextOffset: hasMore ? endOffset : nil)
    }

    // MARK: - Metadata

    private static func compareMetadata(_ a: CADNamedVersionState,
                                        _ b: CADNamedVersionState,
                                        into collector: inout Collector) {
        if a.manifest.name != b.manifest.name {
            collector.add(section: "metadata", change: "modified", identifier: "name",
                          name: "Document name",
                          detail: "\(display(a.manifest.name)) → \(display(b.manifest.name))")
        }
        if a.manifest.unit != b.manifest.unit {
            collector.add(section: "metadata", change: "modified", identifier: "unit",
                          name: "Unit",
                          detail: "\(display(a.manifest.unit)) → \(display(b.manifest.unit))")
        }
        if a.manifest.tolerance != b.manifest.tolerance {
            collector.add(section: "metadata", change: "modified", identifier: "tolerance",
                          name: "Tolerance",
                          detail: "\(number(a.manifest.tolerance)) → \(number(b.manifest.tolerance))")
        }
    }

    // MARK: - Geometry

    private static func compareBodies(_ a: CADNamedVersionState,
                                      _ b: CADNamedVersionState,
                                      into collector: inout Collector) {
        let left = Dictionary(uniqueKeysWithValues: a.document.bodies.map { ($0.bodyID, $0) })
        let right = Dictionary(uniqueKeysWithValues: b.document.bodies.map { ($0.bodyID, $0) })
        for id in Set(left.keys).subtracting(right.keys).sorted(by: uuidOrder) {
            guard let body = left[id] else { continue }
            collector.add(section: "geometry", change: "removed", identifier: id.uuidString,
                          name: body.name,
                          detail: "Body removed (mesh \(shortDigest(body.meshSHA256))\(body.brepBlob == nil ? "" : ", B-rep present")).")
        }
        for id in Set(right.keys).subtracting(left.keys).sorted(by: uuidOrder) {
            guard let body = right[id] else { continue }
            collector.add(section: "geometry", change: "added", identifier: id.uuidString,
                          name: body.name,
                          detail: "Body added (mesh \(shortDigest(body.meshSHA256))\(body.brepBlob == nil ? "" : ", B-rep present")).")
        }
        for id in Set(left.keys).intersection(right.keys).sorted(by: uuidOrder) {
            guard let before = left[id], let after = right[id] else { continue }
            var changes: [String] = []
            var parameterChanges: [String] = []
            if before.name != after.name {
                changes.append("name \(display(before.name)) → \(display(after.name))")
            }
            if before.isHidden != after.isHidden {
                changes.append("visibility \(before.isHidden ? "hidden" : "visible") → \(after.isHidden ? "hidden" : "visible")")
            }
            if valuesDiffer(before.transform, after.transform, Transform3D.self) {
                changes.append("transform")
                parameterChanges += jsonDifferences(before.transform, after.transform,
                                                    prefix: "transform", limit: 4)
            }
            if valuesDiffer(before.primitive, after.primitive, PrimitiveSpec.self) {
                changes.append("primitive parameters")
                parameterChanges += jsonDifferences(before.primitive, after.primitive,
                                                    prefix: "primitive", limit: 4)
            }
            let beforeMesh = digest(before.meshBlob, declared: before.meshSHA256, blobs: a.blobs)
            let afterMesh = digest(after.meshBlob, declared: after.meshSHA256, blobs: b.blobs)
            if beforeMesh != afterMesh {
                changes.append("mesh bytes \(shortDigest(beforeMesh)) → \(shortDigest(afterMesh))")
            }
            let beforeBrep = digest(before.brepBlob, declared: before.brepSHA256, blobs: a.blobs)
            let afterBrep = digest(after.brepBlob, declared: after.brepSHA256, blobs: b.blobs)
            if beforeBrep != afterBrep {
                changes.append("B-rep bytes \(shortDigest(beforeBrep)) → \(shortDigest(afterBrep))")
            }
            if valuesDiffer(before.material, after.material, BodyMaterialSpec.self) {
                changes.append("material")
                parameterChanges += jsonDifferences(before.material, after.material,
                                                    prefix: "material", limit: 5)
            }
            if valuesDiffer(before.faceMaterials, after.faceMaterials,
                            [CADFaceMaterialBinding].self) {
                changes.append("face materials")
                parameterChanges += jsonDifferences(before.faceMaterials, after.faceMaterials,
                                                    prefix: "faceMaterials", limit: 4)
            }
            guard !changes.isEmpty else { continue }
            let detail = (changes + parameterChanges).joined(separator: "; ")
            collector.add(section: "geometry", change: "modified",
                          identifier: id.uuidString, name: after.name, detail: detail)
        }
    }

    // MARK: - Inline records

    private static func compareInlineRecords(_ section: String,
                                             _ before: [CADBlobRecord],
                                             _ after: [CADBlobRecord],
                                             into collector: inout Collector) {
        let left = Dictionary(uniqueKeysWithValues: before.map { ($0.blobID, $0) })
        let right = Dictionary(uniqueKeysWithValues: after.map { ($0.blobID, $0) })
        for id in Set(left.keys).subtracting(right.keys).sorted(by: uuidOrder) {
            collector.add(section: section, change: "removed", identifier: id.uuidString,
                          name: inlineName(section, id), detail: "Stored \(section) record removed.")
        }
        for id in Set(right.keys).subtracting(left.keys).sorted(by: uuidOrder) {
            collector.add(section: section, change: "added", identifier: id.uuidString,
                          name: inlineName(section, id), detail: "Stored \(section) record added.")
        }
        for id in Set(left.keys).intersection(right.keys).sorted(by: uuidOrder) {
            guard let a = left[id], let b = right[id], a.data != b.data || a.sha256 != b.sha256 else { continue }
            // Re-encoding the same model can change JSON key order without any
            // semantic change. Report only actual value differences; fall
            // back to the byte change when the record is unreadable.
            switch section {
            case "sketches":
                if let old = decoded(a.data, as: Sketch.self),
                   let new = decoded(b.data, as: Sketch.self), old == new { continue }
            case "planes":
                if let old = decoded(a.data, as: ConstructionPlane.self),
                   let new = decoded(b.data, as: ConstructionPlane.self), old == new { continue }
            case "axes":
                if let old = decoded(a.data, as: ConstructionAxis.self),
                   let new = decoded(b.data, as: ConstructionAxis.self), old == new { continue }
            case "symbols":
                if let old = decoded(a.data, as: Symbol.self),
                   let new = decoded(b.data, as: Symbol.self), old == new { continue }
            default:
                break
            }
            var detail = "Stored bytes changed (\(shortDigest(a.sha256)) → \(shortDigest(b.sha256)))."
            if section == "sketches" {
                if let old = try? JSONDecoder().decode(Sketch.self, from: a.data),
                   let new = try? JSONDecoder().decode(Sketch.self, from: b.data) {
                    detail += " Entities \(old.entities.count) → \(new.entities.count); constraints \(old.constraints.count) → \(new.constraints.count)."
                }
            }
            collector.add(section: section, change: "modified", identifier: id.uuidString,
                          name: inlineName(section, id), detail: detail)
        }
    }

    private static func compareImages(_ a: CADNamedVersionState,
                                      _ b: CADNamedVersionState,
                                      into collector: inout Collector) {
        let left = Dictionary(uniqueKeysWithValues: a.document.images.map { ($0.imageID, $0) })
        let right = Dictionary(uniqueKeysWithValues: b.document.images.map { ($0.imageID, $0) })
        for id in Set(left.keys).subtracting(right.keys).sorted(by: uuidOrder) {
            collector.add(section: "images", change: "removed", identifier: id.uuidString,
                          name: "Image", detail: "Stored image record removed.")
        }
        for id in Set(right.keys).subtracting(left.keys).sorted(by: uuidOrder) {
            collector.add(section: "images", change: "added", identifier: id.uuidString,
                          name: "Image", detail: "Stored image record added.")
        }
        for id in Set(left.keys).intersection(right.keys).sorted(by: uuidOrder) {
            guard let x = left[id], let y = right[id] else { continue }
            let oldInfo = FileCADDocumentStore.sha256(x.info)
            let newInfo = FileCADDocumentStore.sha256(y.info)
            let oldBlob = digest(x.imageBlob, declared: x.imageSHA256, blobs: a.blobs)
            let newBlob = digest(y.imageBlob, declared: y.imageSHA256, blobs: b.blobs)
            guard oldInfo != newInfo || oldBlob != newBlob else { continue }
            if let old = decoded(x.info, as: InsertedImage.self),
               let new = decoded(y.info, as: InsertedImage.self),
               old == new, oldBlob == newBlob { continue }
            collector.add(section: "images", change: "modified", identifier: id.uuidString,
                          name: "Image",
                          detail: "Image metadata \(shortDigest(oldInfo)) → \(shortDigest(newInfo)); bytes \(shortDigest(oldBlob)) → \(shortDigest(newBlob)).")
        }
    }

    // MARK: - Features / parameters

    private static func compareFeatures(_ a: CADNamedVersionState,
                                        _ b: CADNamedVersionState,
                                        into collector: inout Collector) {
        let left = Dictionary(uniqueKeysWithValues: a.document.features.map { ($0.featureID, $0) })
        let right = Dictionary(uniqueKeysWithValues: b.document.features.map { ($0.featureID, $0) })
        for id in Set(left.keys).subtracting(right.keys).sorted(by: uuidOrder) {
            guard let feature = left[id] else { continue }
            collector.add(section: "features", change: "removed", identifier: id.uuidString,
                          name: feature.name, detail: "Feature removed from history.")
        }
        for id in Set(right.keys).subtracting(left.keys).sorted(by: uuidOrder) {
            guard let feature = right[id] else { continue }
            collector.add(section: "features", change: "added", identifier: id.uuidString,
                          name: feature.name, detail: "Feature added to history.")
        }
        for id in Set(left.keys).intersection(right.keys).sorted(by: uuidOrder) {
            guard let x = left[id], let y = right[id] else { continue }
            var featureChanges: [String] = []
            if x.name != y.name {
                featureChanges.append("name \(display(x.name)) → \(display(y.name))")
            }
            if x.suppressed != y.suppressed {
                featureChanges.append("suppressed \(x.suppressed) → \(y.suppressed)")
            }
            if x.orderIndex != y.orderIndex {
                featureChanges.append("history position \(x.orderIndex) → \(y.orderIndex)")
            }
            if x.outputBodyIDs != y.outputBodyIDs {
                featureChanges.append("output body ids")
            }
            if !featureChanges.isEmpty {
                collector.add(section: "features", change: "modified",
                              identifier: id.uuidString, name: y.name,
                              detail: featureChanges.joined(separator: "; "))
            }
            if x.kind != y.kind {
                let parameterChanges = jsonDifferences(x.kind, y.kind,
                                                       prefix: "parameters", limit: 8)
                if !parameterChanges.isEmpty {
                    collector.add(section: "parameters", change: "modified",
                                  identifier: id.uuidString, name: y.name,
                                  detail: parameterChanges.joined(separator: "; "))
                }
            }
        }
        if a.document.rollbackIndex != b.document.rollbackIndex {
            collector.add(section: "features", change: "modified", identifier: "rollback",
                          name: "History rollback",
                          detail: "Active feature count \(number(a.document.rollbackIndex)) → \(number(b.document.rollbackIndex)).")
        }
    }

    // MARK: - Variables

    private static func compareVariables(_ a: CADNamedVersionState,
                                         _ b: CADNamedVersionState,
                                         into collector: inout Collector) {
        let left = Dictionary(uniqueKeysWithValues: a.document.variables.map { ($0.variableID, $0) })
        let right = Dictionary(uniqueKeysWithValues: b.document.variables.map { ($0.variableID, $0) })
        for id in Set(left.keys).subtracting(right.keys).sorted(by: uuidOrder) {
            guard let variable = left[id] else { continue }
            collector.add(section: "variables", change: "removed", identifier: id.uuidString,
                          name: variable.name, detail: "Variable removed.")
        }
        for id in Set(right.keys).subtracting(left.keys).sorted(by: uuidOrder) {
            guard let variable = right[id] else { continue }
            collector.add(section: "variables", change: "added", identifier: id.uuidString,
                          name: variable.name,
                          detail: "Variable added with expression \(display(variable.expression)).")
        }
        for id in Set(left.keys).intersection(right.keys).sorted(by: uuidOrder) {
            guard let x = left[id], let y = right[id] else { continue }
            var changes: [String] = []
            if x.name != y.name { changes.append("name \(display(x.name)) → \(display(y.name))") }
            if x.expression != y.expression {
                changes.append("expression \(display(x.expression)) → \(display(y.expression))")
            }
            if x.value != y.value { changes.append("value \(number(x.value)) → \(number(y.value))") }
            guard !changes.isEmpty else { continue }
            collector.add(section: "variables", change: "modified", identifier: id.uuidString,
                          name: y.name, detail: changes.joined(separator: "; "))
        }
    }

    // MARK: - Materials

    private static func compareMaterials(_ a: CADNamedVersionState,
                                         _ b: CADNamedVersionState,
                                         into collector: inout Collector) {
        let rawA = a.document.materials
        let rawB = b.document.materials
        guard rawA != rawB else { return }
        let libraryA = rawA.flatMap { try? JSONDecoder().decode(CADMaterialLibrary.self, from: $0) }
        let libraryB = rawB.flatMap { try? JSONDecoder().decode(CADMaterialLibrary.self, from: $0) }
        guard let libraryA, let libraryB else {
            collector.add(section: "materials", change: "modified", identifier: "library",
                          name: "Material library",
                          detail: "Stored material-library bytes changed; typed comparison is unavailable for this record. No appearance change is inferred.")
            return
        }
        let left = Dictionary(uniqueKeysWithValues: libraryA.entries.map { ($0.id.raw, $0) })
        let right = Dictionary(uniqueKeysWithValues: libraryB.entries.map { ($0.id.raw, $0) })
        for id in Set(left.keys).subtracting(right.keys).sorted(by: uuidOrder) {
            guard let material = left[id] else { continue }
            collector.add(section: "materials", change: "removed", identifier: id.uuidString,
                          name: material.name, detail: "Material removed from the library.")
        }
        for id in Set(right.keys).subtracting(left.keys).sorted(by: uuidOrder) {
            guard let material = right[id] else { continue }
            collector.add(section: "materials", change: "added", identifier: id.uuidString,
                          name: material.name,
                          detail: "Material added with \(material.textures.count) texture map(s).")
        }
        for id in Set(left.keys).intersection(right.keys).sorted(by: uuidOrder) {
            guard let x = left[id], let y = right[id], x != y else { continue }
            let differences = jsonDifferences(encoded(x), encoded(y),
                                              prefix: "material", limit: 10)
            collector.add(section: "materials", change: "modified", identifier: id.uuidString,
                          name: y.name,
                          detail: differences.isEmpty
                              ? "Material values changed."
                              : differences.joined(separator: "; "))
        }
    }

    // MARK: - Assembly

    private static func compareAssembly(_ a: CADNamedVersionState,
                                        _ b: CADNamedVersionState,
                                        into collector: inout Collector) {
        let rawA = a.document.assembly
        let rawB = b.document.assembly
        guard rawA != rawB else { return }
        let assemblyA = (try? CADAssembly.decode(from: rawA)) ?? nil
        let assemblyB = (try? CADAssembly.decode(from: rawB)) ?? nil
        guard let assemblyA, let assemblyB else {
            collector.add(section: "assembly", change: "modified", identifier: "assembly",
                          name: "Assembly",
                          detail: "Stored assembly bytes changed; typed comparison is unavailable. No component change is inferred.")
            return
        }
        let left = Dictionary(uniqueKeysWithValues: assemblyA.occurrences(includeHidden: true).map { ($0.id, $0) })
        let right = Dictionary(uniqueKeysWithValues: assemblyB.occurrences(includeHidden: true).map { ($0.id, $0) })
        for id in Set(left.keys).subtracting(right.keys).sorted(by: uuidOrder) {
            guard let occurrence = left[id] else { continue }
            collector.add(section: "assembly", change: "removed", identifier: id.uuidString,
                          name: occurrence.pathNames.joined(separator: " / "),
                          detail: "Placed occurrence removed.")
        }
        for id in Set(right.keys).subtracting(left.keys).sorted(by: uuidOrder) {
            guard let occurrence = right[id] else { continue }
            collector.add(section: "assembly", change: "added", identifier: id.uuidString,
                          name: occurrence.pathNames.joined(separator: " / "),
                          detail: "Placed occurrence added.")
        }
        for id in Set(left.keys).intersection(right.keys).sorted(by: uuidOrder) {
            guard let x = left[id], let y = right[id] else { continue }
            var changes: [String] = []
            if x.worldTransform != y.worldTransform {
                changes.append("placement position \(number(x.worldTransform.position.x)),\(number(x.worldTransform.position.y)),\(number(x.worldTransform.position.z)) → \(number(y.worldTransform.position.x)),\(number(y.worldTransform.position.y)),\(number(y.worldTransform.position.z))")
            }
            if x.isVisible != y.isVisible {
                changes.append("visibility \(x.isVisible ? "visible" : "hidden") → \(y.isVisible ? "visible" : "hidden")")
            }
            if x.effectiveBodyID != y.effectiveBodyID {
                changes.append("source body changed")
            }
            if x.sourceReferenceID != y.sourceReferenceID {
                changes.append("external reference changed")
            }
            if x.instance.name != y.instance.name {
                changes.append("name \(display(x.instance.name)) → \(display(y.instance.name))")
            }
            guard !changes.isEmpty else { continue }
            collector.add(section: "assembly", change: "modified", identifier: id.uuidString,
                          name: y.pathNames.joined(separator: " / "),
                          detail: changes.joined(separator: "; "))
        }
        compareScopedConstraints(assemblyA, assemblyB, into: &collector)
        compareKeyedEncodable("assembly", "Part reference", assemblyA.partReferences,
                              assemblyB.partReferences, into: &collector)
        compareKeyedEncodable("assembly", "Part metadata", assemblyA.partMetadata,
                              assemblyB.partMetadata, into: &collector)
        compareKeyedEncodable("assembly", "Exploded view", assemblyA.explodedViews,
                              assemblyB.explodedViews, into: &collector)
        if assemblyA.constraints.map(\.id) != assemblyB.constraints.map(\.id) {
            // Root constraints are covered by the keyed comparison; this only
            // notes a reordering that does not change any stored value.
            let leftOrder = assemblyA.constraints.map(\.id.uuidString)
            let rightOrder = assemblyB.constraints.map(\.id.uuidString)
            if Set(leftOrder) == Set(rightOrder), leftOrder != rightOrder {
                collector.add(section: "assembly", change: "modified", identifier: "constraint-order",
                              name: "Constraints",
                              detail: "Constraint order changed; values are unchanged.")
            }
        }
    }

    private struct ScopedConstraintRow: Encodable {
        let parent: UUID?
        let constraint: CADAssemblyConstraint
    }

    private static func compareScopedConstraints(_ a: CADAssembly, _ b: CADAssembly,
                                                 into collector: inout Collector) {
        let left = Dictionary(uniqueKeysWithValues: a.constraintsWithScope().map {
            ($0.constraint.id, ScopedConstraintRow(parent: $0.parentID, constraint: $0.constraint))
        })
        let right = Dictionary(uniqueKeysWithValues: b.constraintsWithScope().map {
            ($0.constraint.id, ScopedConstraintRow(parent: $0.parentID, constraint: $0.constraint))
        })
        for id in Set(left.keys).subtracting(right.keys).sorted(by: uuidOrder) {
            collector.add(section: "assembly", change: "removed", identifier: id.uuidString,
                          name: "Constraint", detail: "Assembly constraint removed.")
        }
        for id in Set(right.keys).subtracting(left.keys).sorted(by: uuidOrder) {
            collector.add(section: "assembly", change: "added", identifier: id.uuidString,
                          name: "Constraint", detail: "Assembly constraint added.")
        }
        for id in Set(left.keys).intersection(right.keys).sorted(by: uuidOrder) {
            guard let x = left[id], let y = right[id] else { continue }
            let differences = jsonDifferences(encoded(x), encoded(y),
                                              prefix: "constraint", limit: 8)
            guard !differences.isEmpty else { continue }
            collector.add(section: "assembly", change: "modified", identifier: id.uuidString,
                          name: "Constraint", detail: differences.joined(separator: "; "))
        }
    }

    private static func compareKeyedEncodable<T: Encodable & Identifiable>(
        _ section: String, _ label: String, _ a: [T], _ b: [T],
        into collector: inout Collector
    ) where T.ID == UUID {
        let left = Dictionary(uniqueKeysWithValues: a.map { ($0.id, $0) })
        let right = Dictionary(uniqueKeysWithValues: b.map { ($0.id, $0) })
        for id in Set(left.keys).subtracting(right.keys).sorted(by: uuidOrder) {
            collector.add(section: section, change: "removed", identifier: id.uuidString,
                          name: label, detail: "\(label) removed.")
        }
        for id in Set(right.keys).subtracting(left.keys).sorted(by: uuidOrder) {
            collector.add(section: section, change: "added", identifier: id.uuidString,
                          name: label, detail: "\(label) added.")
        }
        for id in Set(left.keys).intersection(right.keys).sorted(by: uuidOrder) {
            guard let x = left[id], let y = right[id] else { continue }
            let differences = jsonDifferences(encoded(x), encoded(y),
                                              prefix: label.lowercased(), limit: 8)
            guard !differences.isEmpty else { continue }
            collector.add(section: section, change: "modified", identifier: id.uuidString,
                          name: label, detail: differences.joined(separator: "; "))
        }
    }

    // MARK: - Drawings / presentation / animation / scripts

    private static func compareDrawings(_ a: CADNamedVersionState,
                                        _ b: CADNamedVersionState,
                                        into collector: inout Collector) {
        let rawA = a.document.drawings
        let rawB = b.document.drawings
        guard rawA != rawB else { return }
        let setA = (try? CADDrawingSet.decode(from: rawA)) ?? nil
        let setB = (try? CADDrawingSet.decode(from: rawB)) ?? nil
        guard let setA, let setB else {
            collector.add(section: "drawings", change: "modified", identifier: "drawings",
                          name: "Drawings",
                          detail: "Stored drawing bytes changed; typed comparison is unavailable.")
            return
        }
        if setA.schemaVersion != setB.schemaVersion {
            collector.add(section: "drawings", change: "modified", identifier: "schema",
                          name: "Drawing schema",
                          detail: "\(setA.schemaVersion) → \(setB.schemaVersion)")
        }
        let left = Dictionary(uniqueKeysWithValues: setA.pages.map { ($0.id, $0) })
        let right = Dictionary(uniqueKeysWithValues: setB.pages.map { ($0.id, $0) })
        for id in Set(left.keys).subtracting(right.keys).sorted(by: uuidOrder) {
            guard let page = left[id] else { continue }
            collector.add(section: "drawings", change: "removed", identifier: id.uuidString,
                          name: page.name, detail: "Drawing page removed.")
        }
        for id in Set(right.keys).subtracting(left.keys).sorted(by: uuidOrder) {
            guard let page = right[id] else { continue }
            collector.add(section: "drawings", change: "added", identifier: id.uuidString,
                          name: page.name,
                          detail: "Drawing page added with \(page.sheetViews?.count ?? 1) view(s).")
        }
        for id in Set(left.keys).intersection(right.keys).sorted(by: uuidOrder) {
            guard let x = left[id], let y = right[id], x != y else { continue }
            let differences = jsonDifferences(encoded(x), encoded(y),
                                              prefix: "page", limit: 8)
            collector.add(section: "drawings", change: "modified", identifier: id.uuidString,
                          name: y.name,
                          detail: differences.isEmpty
                              ? "Drawing page values changed."
                              : differences.joined(separator: "; "))
        }
    }

    private static func comparePresentation(_ a: CADNamedVersionState,
                                            _ b: CADNamedVersionState,
                                            into collector: inout Collector) {
        let rawA = a.document.sceneSettings
        let rawB = b.document.sceneSettings
        guard rawA != rawB else { return }
        let settingsA = rawA.flatMap { try? JSONDecoder().decode(CADSceneSettings.self, from: $0) }
        let settingsB = rawB.flatMap { try? JSONDecoder().decode(CADSceneSettings.self, from: $0) }
        guard let settingsA, let settingsB else {
            collector.add(section: "presentation", change: "modified", identifier: "scene",
                          name: "Presentation",
                          detail: "Stored presentation bytes changed; typed comparison is unavailable.")
            return
        }
        guard settingsA != settingsB else { return }
        let differences = jsonDifferences(encoded(settingsA), encoded(settingsB),
                                          prefix: "presentation", limit: 10)
        collector.add(section: "presentation", change: "modified", identifier: "scene",
                      name: "Presentation",
                      detail: differences.isEmpty
                          ? "Presentation values changed."
                          : differences.joined(separator: "; "))
    }

    private static func compareAnimation(_ a: CADNamedVersionState,
                                         _ b: CADNamedVersionState,
                                         into collector: inout Collector) {
        let rawA = a.document.animation
        let rawB = b.document.animation
        guard rawA != rawB else { return }
        let animationA = rawA.flatMap { try? CADAnimationCodec.decode($0) }
        let animationB = rawB.flatMap { try? CADAnimationCodec.decode($0) }
        guard let animationA, let animationB else {
            collector.add(section: "animation", change: "modified", identifier: "animation",
                          name: "Animation",
                          detail: "Stored animation bytes changed; typed comparison is unavailable.")
            return
        }
        guard animationA != animationB else { return }
        let differences = jsonDifferences(encoded(animationA), encoded(animationB),
                                          prefix: "animation", limit: 10)
        collector.add(section: "animation", change: "modified", identifier: "animation",
                      name: "Animation",
                      detail: differences.isEmpty
                          ? "Animation values changed."
                          : differences.joined(separator: "; "))
    }

    private static func compareScripts(_ a: CADNamedVersionState,
                                       _ b: CADNamedVersionState,
                                       into collector: inout Collector) {
        guard a.document.scripts != b.document.scripts else { return }
        let differences = jsonDifferences(a.document.scripts, b.document.scripts,
                                          prefix: "scripts", limit: 6)
        guard !differences.isEmpty else { return }
        collector.add(section: "scripts", change: "modified", identifier: "scripts",
                      name: "ShapeScript records",
                      detail: differences.joined(separator: "; "))
    }

    private static func compareItemFolders(_ a: CADNamedVersionState,
                                           _ b: CADNamedVersionState,
                                           into collector: inout Collector) {
        guard a.document.itemFolders != b.document.itemFolders else { return }
        let differences = jsonDifferences(a.document.itemFolders, b.document.itemFolders,
                                          prefix: "itemFolders", limit: 6)
        guard !differences.isEmpty else { return }
        collector.add(section: "metadata", change: "modified", identifier: "itemFolders",
                      name: "Items folders",
                      detail: differences.joined(separator: "; "))
    }

    // MARK: - Exact selected-record access

    /// Locate the exact stored record (or the whole stored section when the
    /// section is a single JSON document) for one difference identifier on each
    /// side. Values come from the verified package state and are never
    /// re-saved; the caller serializes them for bounded line paging.
    static func recordAccess(section: String, identifier: String,
                             from: CADNamedVersionState,
                             to: CADNamedVersionState)
    -> (from: Any?, to: Any?, name: String, change: String, note: String?) {
        let old = recordValue(section: section, identifier: identifier, state: from)
        let new = recordValue(section: section, identifier: identifier, state: to)
        let name = new.name ?? old.name ?? defaultRecordName(section: section,
                                                             identifier: identifier)
        let change: String
        switch (old.value == nil, new.value == nil) {
        case (true, true):
            change = "unavailable"
        case (true, false):
            change = "added"
        case (false, true):
            change = "removed"
        default:
            let oldData = old.value.flatMap { try? JSONSerialization.data(
                withJSONObject: normalizedJSONObject($0), options: [.sortedKeys]) }
            let newData = new.value.flatMap { try? JSONSerialization.data(
                withJSONObject: normalizedJSONObject($0), options: [.sortedKeys]) }
            change = oldData == newData ? "unchanged" : "modified"
        }
        var note: String?
        if old.value == nil && new.value == nil {
            note = "This identifier is not present in the stored records. No record was invented."
        } else if isWholeSection(section) {
            note = "This section is stored as one JSON record; the exact section value is returned. Select \(identifier) inside it."
        }
        return (old.value, new.value, name, change, note)
    }

    private static func isWholeSection(_ section: String) -> Bool {
        switch section {
        case "assembly", "drawings", "presentation", "animation", "scripts":
            return true
        default:
            return false
        }
    }

    private static func defaultRecordName(section: String, identifier: String) -> String {
        switch section {
        case "metadata": return "Document metadata"
        case "geometry": return "Body \(identifier.prefix(8))"
        case "materials": return "Material library"
        case "assembly": return "Assembly"
        case "drawings": return "Drawings"
        case "presentation": return "Presentation"
        case "animation": return "Animation"
        case "scripts": return "ShapeScript records"
        case "preview": return "Viewport preview"
        default: return identifier
        }
    }

    private static func recordValue(section: String, identifier: String,
                                    state: CADNamedVersionState)
    -> (value: Any?, name: String?) {
        switch section {
        case "metadata":
            if identifier == "building" {
                return (rawJSON(state.document.building),FloeCADStrings.text("cad.building.title","Building Design"))
            }
            if identifier == "itemFolders" {
                return (rawJSON(state.document.itemFolders), "Items folders")
            }
            var metadata: [String: Any] = ["name": state.manifest.name]
            metadata["unit"] = state.manifest.unit.map { $0 as Any } ?? NSNull()
            metadata["tolerance"] = state.manifest.tolerance.map { $0 as Any } ?? NSNull()
            return (metadata, "Document metadata")
        case "geometry":
            guard let body = state.document.bodies.first(where: {
                matches(identifier, $0.bodyID)
            }) else { return (nil, nil) }
            return (encodedObject(body), body.name)
        case "sketches", "planes", "axes", "symbols":
            let records: [CADBlobRecord]
            switch section {
            case "sketches": records = state.document.sketches
            case "planes": records = state.document.planes
            case "axes": records = state.document.axes
            default: records = state.document.symbols
            }
            guard let record = records.first(where: { matches(identifier, $0.blobID) }) else {
                return (nil, nil)
            }
            var value: [String: Any] = [:]
            value["record"] = encodedObject(record)
            value["data"] = rawJSON(record.data) ?? NSNull()
            return (value, inlineName(section, record.blobID))
        case "images":
            guard let image = state.document.images.first(where: {
                matches(identifier, $0.imageID)
            }) else { return (nil, nil) }
            var value: [String: Any] = [:]
            value["record"] = encodedObject(image)
            value["info"] = rawJSON(image.info) ?? NSNull()
            return (value, "Image \(identifier.prefix(8))")
        case "features", "parameters":
            if identifier == "rollback" {
                var value: [String: Any] = [:]
                value["rollbackIndex"] = state.document.rollbackIndex.map { $0 as Any } ?? NSNull()
                return (value, "History rollback")
            }
            guard let feature = state.document.features.first(where: {
                matches(identifier, $0.featureID)
            }) else { return (nil, nil) }
            var value: [String: Any] = [:]
            value["record"] = encodedObject(feature)
            value["kind"] = rawJSON(feature.kind) ?? NSNull()
            value["outputBodyIDs"] = rawJSON(feature.outputBodyIDs) ?? NSNull()
            return (value, feature.name)
        case "variables":
            guard let variable = state.document.variables.first(where: {
                matches(identifier, $0.variableID)
            }) else { return (nil, nil) }
            return (encodedObject(variable), variable.name)
        case "materials":
            guard let data = state.document.materials else { return (nil, nil) }
            if identifier != "library",
               let library = try? JSONDecoder().decode(CADMaterialLibrary.self,
                                                       from: data),
               let entry = library.entries.first(where: {
                   matches(identifier, $0.id.raw)
               }) {
                return (encodedObject(entry), entry.name)
            }
            return (rawJSON(data), "Material library")
        case "assembly":
            return (rawJSON(state.document.assembly), "Assembly")
        case "drawings":
            return (rawJSON(state.document.drawings), "Drawings")
        case "presentation":
            return (rawJSON(state.document.sceneSettings), "Presentation")
        case "animation":
            return (rawJSON(state.document.animation), "Animation")
        case "scripts":
            return (rawJSON(state.document.scripts), "ShapeScript records")
        case "preview":
            var value: [String: Any] = [
                "contentSHA256": state.manifest.contentSHA256,
            ]
            value["modelSHA256"] = state.manifest.modelSHA256.map { $0 as Any } ?? NSNull()
            value["thumbnailSHA256"] = state.manifest.thumbnailSHA256.map { $0 as Any } ?? NSNull()
            return (value, "Viewport preview")
        default:
            return (nil, nil)
        }
    }

    private static func matches(_ identifier: String, _ id: UUID) -> Bool {
        identifier.caseInsensitiveCompare(id.uuidString) == .orderedSame
    }

    private static func encodedObject<T: Encodable>(_ value: T) -> Any? {
        guard let data = try? JSONEncoder().encode(value) else { return nil }
        return try? JSONSerialization.jsonObject(with: data,
                                                 options: [.fragmentsAllowed])
    }

    private static func rawJSON(_ data: Data?) -> Any? {
        guard let data, !data.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: data,
                                                 options: [.fragmentsAllowed])
    }

    private static func normalizedJSONObject(_ value: Any) -> Any {
        if JSONSerialization.isValidJSONObject(value) { return value }
        return ["value": value]
    }

    // MARK: - Helpers

    private static func decoded<T: Decodable>(_ data: Data, as type: T.Type) -> T? {
        try? JSONDecoder().decode(type, from: data)
    }

    /// True only when the stored values actually differ. JSON key-order churn
    /// re-encodes the same value to different bytes; decoding first prevents a
    /// no-op save from being reported as a transform/parameter change.
    private static func valuesDiffer<T: Codable & Equatable>(
        _ a: Data?, _ b: Data?, _ type: T.Type
    ) -> Bool {
        if a == b { return false }
        guard let a, let b,
              let left = try? JSONDecoder().decode(type, from: a),
              let right = try? JSONDecoder().decode(type, from: b) else { return true }
        return left != right
    }

    private static func encoded<T: Encodable>(_ value: T) -> Data? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try? encoder.encode(value)
    }

    private static func inlineName(_ section: String, _ id: UUID) -> String {
        switch section {
        case "sketches": return "Sketch \(id.uuidString.prefix(8))"
        case "planes": return "Plane \(id.uuidString.prefix(8))"
        case "axes": return "Axis \(id.uuidString.prefix(8))"
        case "symbols": return "Symbol \(id.uuidString.prefix(8))"
        default: return id.uuidString
        }
    }

    private static func digest(_ path: String?, declared: String?, blobs: [String: Data]) -> String? {
        if let declared, !declared.isEmpty { return declared }
        guard let path, let data = blobs[path] else { return nil }
        return FileCADDocumentStore.sha256(data)
    }

    private static func digest(_ data: Data?) -> String? {
        guard let data else { return nil }
        return FileCADDocumentStore.sha256(data)
    }

    private static func shortDigest(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "none" }
        return String(value.prefix(12))
    }

    private static func display(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "none" }
        return "“\(value)”"
    }

    private static func number(_ value: Double?) -> String {
        guard let value else { return "none" }
        return String(format: "%.9g", value)
    }

    private static func number(_ value: Int?) -> String {
        guard let value else { return "none" }
        return String(value)
    }

    private static func uuidOrder(_ a: UUID, _ b: UUID) -> Bool {
        a.uuidString < b.uuidString
    }

    // MARK: - Actual JSON leaf diff

    /// Compares two stored JSON payloads and reports leaf paths whose values
    /// actually differ. Large embedded strings (texture/image bytes) are
    /// reduced to a length + SHA-256 summary so a material diff cannot dump a
    /// multi-megabyte base64 payload into a tool/UI reply.
    static func jsonDifferences(_ a: Data?, _ b: Data?, prefix: String,
                                limit: Int) -> [String] {
        guard let a, let b else {
            if a == nil && b == nil { return [] }
            return ["\(prefix): \(a == nil ? "absent" : "present") → \(b == nil ? "absent" : "present")"]
        }
        let old = try? JSONSerialization.jsonObject(with: a, options: [.fragmentsAllowed])
        let new = try? JSONSerialization.jsonObject(with: b, options: [.fragmentsAllowed])
        guard let old, let new else {
            return a == b ? [] : ["\(prefix): stored JSON changed (not comparable as a tree)"]
        }
        var output: [String] = []
        diffJSON(old, new, path: prefix, into: &output, limit: limit)
        return output
    }

    private static func diffJSON(_ old: Any, _ new: Any, path: String,
                                 into output: inout [String], limit: Int) {
        guard output.count < limit else { return }
        if let old = old as? [String: Any], let new = new as? [String: Any] {
            let ignored: Set<String> = ["createdAt", "updatedAt", "created_at", "updated_at"]
            for key in Set(old.keys).union(new.keys).sorted() where !ignored.contains(key) {
                guard output.count < limit else { return }
                if let oldValue = old[key], let newValue = new[key] {
                    diffJSON(oldValue, newValue, path: "\(path).\(key)", into: &output, limit: limit)
                } else if let oldValue = old[key] {
                    output.append("\(path).\(key): \(scalar(oldValue)) → absent")
                } else if let newValue = new[key] {
                    output.append("\(path).\(key): absent → \(scalar(newValue))")
                }
            }
            return
        }
        if let old = old as? [Any], let new = new as? [Any] {
            if old.count != new.count {
                output.append("\(path): \(old.count) item(s) → \(new.count) item(s)")
                for index in 0..<min(old.count, new.count, 8) {
                    guard output.count < limit else { return }
                    diffJSON(old[index], new[index], path: "\(path)[\(index)]",
                             into: &output, limit: limit)
                }
                return
            }
            for index in 0..<min(old.count, new.count) {
                guard output.count < limit else { return }
                diffJSON(old[index], new[index], path: "\(path)[\(index)]",
                         into: &output, limit: limit)
            }
            return
        }
        if scalar(old) != scalar(new) {
            output.append("\(path): \(scalar(old)) → \(scalar(new))")
        }
    }

    private static func scalar(_ value: Any) -> String {
        switch value {
        case is NSNull:
            return "null"
        case let value as String:
            if value.count > 160 {
                let data = Data(value.utf8)
                return "<\(value.count) chars, sha256 \(String(FileCADDocumentStore.sha256(data).prefix(12)))>"
            }
            return "\"\(value)\""
        case let value as NSNumber:
            if CFGetTypeID(value) == CFBooleanGetTypeID() {
                return value.boolValue ? "true" : "false"
            }
            let double = value.doubleValue
            if double == double.rounded(), abs(double) < 1e15 {
                return String(value.int64Value)
            }
            return String(format: "%.9g", double)
        default:
            if JSONSerialization.isValidJSONObject(value),
               let data = try? JSONSerialization.data(withJSONObject: value),
               let text = String(data: data, encoding: .utf8) {
                return text.count > 160
                    ? "<\(text.count) chars, sha256 \(String(FileCADDocumentStore.sha256(data).prefix(12)))>"
                    : text
            }
            return String(describing: value)
        }
    }

    private struct Collector {
        var items: [CADNamedVersionDifference] = []
        /// Exact number of differences the comparison produced, including the
        /// tail beyond this page. Computed by counting every add, not by
        /// trusting the page length.
        var total = 0
        var sections: Set<String> = []
        let offset: Int
        let limit: Int
        private var seen = 0

        init(offset: Int, limit: Int) {
            self.offset = offset
            self.limit = limit
        }

        mutating func add(section: String, change: String, identifier: String,
                          name: String, detail: String) {
            seen += 1
            total = seen
            sections.insert(section)
            guard seen > offset else { return }
            guard items.count < limit else { return }
            let bounded = detail.count > 600 ? String(detail.prefix(600)) + "…" : detail
            items.append(CADNamedVersionDifference(
                section: section, change: change, identifier: identifier,
                name: name, detail: bounded))
        }
    }
}
