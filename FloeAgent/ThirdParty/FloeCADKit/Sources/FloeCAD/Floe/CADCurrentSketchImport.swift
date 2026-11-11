// SPDX-License-Identifier: MPL-2.0
import Foundation
import simd

/// A caller cannot substitute a different document, sketch or edit generation.
public nonisolated struct CADSketchImportContext: Sendable {
    public let sketchID: UUID
    public let sketchName: String
    public let documentRevision: Int
    public let editRevision: Int
    fileprivate let document: ObjectIdentifier
    fileprivate let url: URL
}

public nonisolated struct CADSketchImportReceipt: Sendable, Equatable {
    public let sketchID: UUID
    public let entityIDs: [UUID]
    public let editRevision: Int
}

public nonisolated struct CADLibrarySketchItem: Identifiable, Sendable, Equatable {
    public let id: UUID
    public let name: String
    public let entityCount: Int
    public let constructionCount: Int
    public let constraintCount: Int
    public let dimensionCount: Int
}

/// Verified saved data only. No live source editor, body insertion, save or recovery.
public nonisolated struct CADLibrarySketchSource: Sendable {
    public let packageURL: URL
    public let revision: Int
    public let contentSHA256: String
    public let schemaVersion: Int
    public let displayUnit: String?
    public let sketches: [CADLibrarySketchItem]
    fileprivate let values: [Sketch]
}

public nonisolated enum CADSketchImportError: Error, LocalizedError, Sendable {
    case targetUnavailable, targetChanged, sourceChanged, unsupportedSource
    case emptySketch, invalidGeometry, rebuildFailed, resultNeedsReview

    public var errorDescription: String? {
        switch self {
        case .targetUnavailable:
            FloeCADStrings.text("cad.sketchImport.targetUnavailable", "Open an editable sketch first.")
        case .targetChanged:
            FloeCADStrings.text("cad.sketchImport.targetChanged", "The sketch changed. Reopen Import and try again.")
        case .sourceChanged:
            FloeCADStrings.text("cad.sketchImport.sourceChanged", "The 2D project changed. Select the sketch again.")
        case .unsupportedSource:
            FloeCADStrings.text("cad.sketchImport.unsupportedSource", "This project cannot provide an editable sketch in this version.")
        case .emptySketch:
            FloeCADStrings.text("cad.sketchImport.emptySketch", "The selected sketch is empty.")
        case .invalidGeometry:
            FloeCADStrings.text("cad.sketchImport.invalidGeometry", "This sketch cannot be imported. Check its geometry and try again.")
        case .rebuildFailed:
            FloeCADStrings.text("cad.sketchImport.rebuildFailed", "Import could not be applied. The sketch was left unchanged.")
        case .resultNeedsReview:
            FloeCADStrings.text("cad.sketchImport.resultNeedsReview", "The import result could not be confirmed. Check the sketch before trying again.")
        }
    }
}

@MainActor public extension FloeCADDocument {
    func currentSketchImportContext() throws -> CADSketchImportContext {
        guard !isClosed, !isReadOnly, session.writeBlock == nil,
              let sketch = viewModel().activeSketch,
              session.lastReferenceErrors[.sketch(sketch.id)] == nil else {
            throw CADSketchImportError.targetUnavailable
        }
        return CADSketchImportContext(sketchID: sketch.id.raw, sketchName: sketch.name,
            documentRevision: revision, editRevision: session.changeCount,
            document: ObjectIdentifier(self), url: url)
    }

    func validateSketchImportContext(_ context: CADSketchImportContext) throws {
        let current = try currentSketchImportContext()
        // A save alone advances savedIdentity without changing geometry. The
        // monotonic edit generation fences edits/undo/redo/preview instead.
        guard current.document == context.document, current.url == context.url,
              current.sketchID == context.sketchID,
              current.editRevision == context.editRevision else { throw CADSketchImportError.targetChanged }
    }

    /// Reads the existing strict package reader without its interrupted-commit
    /// promotion path. Unknown versions remain untouched and cannot be imported.
    static func readSketchLibrarySource(at packageURL: URL) async throws -> CADLibrarySketchSource {
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let store = FileCADDocumentStore(packageURL: packageURL)
            let project = try store.readWithoutRecovery()
            guard project.formatVersion <= Project.currentFormatVersion,
                  !project.hasOpaqueAssociations, project.sketches.count <= 20_000 else {
                throw CADSketchImportError.unsupportedSource
            }
            var values: [Sketch] = []
            var ids = Set<UUID>()
            var totalBytes = 0
            for record in project.sketches {
                try Task.checkCancellation()
                guard record.sketchData.count <= 64 * 1024 * 1024 - totalBytes else {
                    throw CADSketchImportError.invalidGeometry
                }
                totalBytes += record.sketchData.count
                let sketch = try JSONDecoder().decode(Sketch.self, from: record.sketchData)
                guard sketch.id.raw == record.sketchID, ids.insert(record.sketchID).inserted else {
                    throw CADSketchImportError.invalidGeometry
                }
                values.append(sketch)
            }
            let items = values.map {
                CADLibrarySketchItem(id: $0.id.raw, name: $0.name,
                    entityCount: $0.entities.count, constructionCount: $0.constructionEntityIDs.count,
                    constraintCount: $0.constraints.count, dimensionCount: $0.dimensions.count)
            }
            try Task.checkCancellation()
            return CADLibrarySketchSource(packageURL: packageURL, revision: store.revision,
                contentSHA256: store.contentSHA256, schemaVersion: store.schemaVersion,
                displayUnit: project.unitRaw, sketches: items, values: values)
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: { worker.cancel() }
    }

    /// The App re-resolves/leases its exact source record and compares a fresh
    /// saved source before calling this synchronous commit. Native coordinates
    /// are already mm regardless of the source/target display unit.
    func appendLibrarySketch(_ source: CADLibrarySketchSource, sketchID: UUID,
                             context: CADSketchImportContext) throws -> CADSketchImportReceipt {
        guard source.packageURL.standardizedFileURL.resolvingSymlinksInPath()
                != url.standardizedFileURL.resolvingSymlinksInPath(),
              let sketch = source.values.first(where: { $0.id.raw == sketchID }) else {
            throw CADSketchImportError.sourceChanged
        }
        try CADCurrentSketchGeometry.validate(sketch.entities)
        let oldIDs = Set(sketch.entities.map(\.id))
        guard sketch.constructionEntityIDs.isSubset(of: oldIDs) else {
            throw CADSketchImportError.invalidGeometry
        }
        var normal: [SketchEntity] = [], construction: [SketchEntity] = []
        for entity in sketch.entities {
            let copy = CADCurrentSketchGeometry.copy(entity)
            if sketch.isConstruction(entity.id) { construction.append(copy) }
            else { normal.append(copy) }
        }
        return try appendCurrentSketch(normal: normal, construction: construction, context: context)
    }

    /// Explicit sketch-page intent. The existing generic transfer still creates
    /// a new sketch and retains its drawing source; that behavior is unchanged.
    /// This geometry append never overwrites an existing drawingSource record.
    func appendDrawingTransfer(_ source: CADSketchTransferEnvelope,
                               placement: CADSketchTransferPlacement,
                               context: CADSketchImportContext) throws -> CADSketchImportReceipt {
        try source.validate()
        guard source.purpose == .modelSketch, placement.target == .selected else {
            throw CADSketchImportError.targetChanged
        }
        let entities = try placement.entities(snapshot: source.snapshot)
        try CADCurrentSketchGeometry.validate(entities)
        return try appendCurrentSketch(normal: entities, construction: [], context: context)
    }

    private func appendCurrentSketch(normal: [SketchEntity], construction: [SketchEntity],
                                     context: CADSketchImportContext) throws -> CADSketchImportReceipt {
        try Task.checkCancellation()
        try validateSketchImportContext(context)
        guard let sketch = viewModel().activeSketch else { throw CADSketchImportError.targetChanged }
        let ids = (normal + construction).map(\.id)
        let existingIDs = Set(session.document.sketches.flatMap { $0.entities.map(\.id) })
        guard !ids.isEmpty, Set(ids).count == ids.count,
              Set(ids).isDisjoint(with: existingIDs),
              sketch.entities.count <= 40_000 - ids.count else { throw CADSketchImportError.invalidGeometry }
        let title = FloeCADStrings.text("cad.sketchImport.undo", "Import sketch")
        var commands: [DocumentCommand] = []
        if !normal.isEmpty { commands.append(AddSketchEntitiesCommand(sketchID: sketch.id, entities: normal, title: title)) }
        if !construction.isEmpty {
            commands.append(AddSketchEntitiesCommand(sketchID: sketch.id, entities: construction,
                title: title, asConstruction: true))
        }
        let command = CompositeCommand(title: title, commands: commands)
        guard session.performWithSketchRebuild(command, sketchID: sketch.id) else {
            throw CADSketchImportError.rebuildFailed
        }
        guard let result = session.document.sketches.first(where: { $0.id == sketch.id }),
              Set(ids).isSubset(of: Set(result.entities.map(\.id))) else {
            throw CADSketchImportError.resultNeedsReview
        }
        return CADSketchImportReceipt(sketchID: sketch.id.raw, entityIDs: ids, editRevision: session.changeCount)
    }
}

private nonisolated enum CADCurrentSketchGeometry {
    static func validate(_ entities: [SketchEntity]) throws {
        guard !entities.isEmpty else { throw CADSketchImportError.emptySketch }
        guard entities.count <= 40_000, Set(entities.map(\.id)).count == entities.count else {
            throw CADSketchImportError.invalidGeometry
        }
        func number(_ value: Double) -> Bool { value.isFinite && abs(value) <= 1e12 }
        func point(_ value: SIMD2<Double>) -> Bool { number(value.x) && number(value.y) }
        func radius(_ value: Double) -> Bool { number(value) && value > 0 }
        for entity in entities {
            let valid: Bool
            switch entity {
            case let .line(_, a, b): valid = point(a) && point(b) && a != b
            case let .rect(_, lo, hi): valid = point(lo) && point(hi) && lo.x < hi.x && lo.y < hi.y
            case let .circle(_, center, r): valid = point(center) && radius(r)
            case let .arc(_, center, r, a, b):
                valid = point(center) && radius(r) && number(a) && number(b)
                    && SketchEntity.arcSweep(startAngle: a, endAngle: b) > 1e-9
            case let .ellipse(_, center, rx, ry, rotation):
                valid = point(center) && radius(rx) && radius(ry) && number(rotation)
            case let .polygon(_, center, r, sides, rotation):
                valid = point(center) && radius(r) && (3...20_000).contains(sides) && number(rotation)
            case let .spline(_, points, _): valid = (2...40_000).contains(points.count) && points.allSatisfy(point)
            case let .exactCurve(_, definition): try definition.validate(); valid = true
            }
            guard valid else { throw CADSketchImportError.invalidGeometry }
        }
    }

    /// Re-identification only: do not rotate, tessellate or evaluate a source formula.
    static func copy(_ entity: SketchEntity) -> SketchEntity {
        let id = UUID()
        switch entity {
        case let .line(_, a, b): return .line(id: id, a: a, b: b)
        case let .rect(_, lo, hi): return .rect(id: id, min: lo, max: hi)
        case let .circle(_, c, r): return .circle(id: id, center: c, radius: r)
        case let .arc(_, c, r, a, b): return .arc(id: id, center: c, radius: r, startAngle: a, endAngle: b)
        case let .ellipse(_, c, rx, ry, rotation): return .ellipse(id: id, center: c, radiusX: rx, radiusY: ry, rotation: rotation)
        case let .polygon(_, c, r, sides, rotation): return .polygon(id: id, center: c, radius: r, sides: sides, rotation: rotation)
        case let .spline(_, points, closed): return .spline(id: id, points: points, closed: closed)
        case let .exactCurve(_, definition): return .exactCurve(id: id, definition: definition)
        }
    }
}
