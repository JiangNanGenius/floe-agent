// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum EDAEdit: Codable, Hashable, Sendable {
    case rename(String)
    case putSymbol(EDASymbolDefinition), removeSymbol(UUID)
    case putFootprintDefinition(EDAFootprintDefinition), removeFootprintDefinition(UUID)
    case putComponent(EDAComponent), removeComponent(UUID)
    case putSheet(EDASheet), removeSheet(UUID)
    case placeSymbol(sheet: UUID, EDASymbolPlacement)
    case putWire(sheet: UUID, EDAWire), putJunction(sheet: UUID, EDAJunction)
    case putLabel(sheet: UUID, EDANetLabel), putNoConnect(sheet: UUID, EDAJunction)
    case putBus(sheet: UUID, EDABus), putSheetLink(sheet: UUID, EDASheetLink)
    case removeSchematicObject(sheet: UUID, object: UUID)
    case putBoard(EDABoard), removeBoard(UUID)
    case putFootprint(board: UUID, EDAFootprint), putTrack(board: UUID, EDATrack)
    case putVia(board: UUID, EDAVia), putZone(board: UUID, EDAZone)
    case putKeepout(board: UUID, EDAKeepout), putHole(board: UUID, EDAHole)
    case removeBoardObject(board: UUID, object: UUID)
    case putSimulation(EDASimulationSetup), removeSimulation(UUID)
}

/// UI and model tools use the same transaction. Editor selection and input
/// state are deliberately outside the document and undo stack.
public struct EDAEditingSession: Sendable {
    public private(set) var project: EDAProject
    public private(set) var savedRevision: UInt64
    public private(set) var savedDigest: String?
    public let readOnly: Bool
    private var undoStates: [EDAProject] = []
    private var redoStates: [EDAProject] = []
    private let maximumUndo: Int
    public init(project: EDAProject, savedDigest: String? = nil, readOnly: Bool = false, maximumUndo: Int = 100) throws {
        try EDAValidation.validate(project)
        self.project = project; self.savedRevision = project.revision; self.savedDigest = savedDigest
        self.readOnly = readOnly; self.maximumUndo = max(1, min(1000, maximumUndo))
    }
    public var isDirty: Bool { project.revision != savedRevision }
    public var canUndo: Bool { !readOnly && !undoStates.isEmpty }
    public var canRedo: Bool { !readOnly && !redoStates.isEmpty }

    public mutating func apply(_ edits: [EDAEdit], expectedRevision: UInt64,
                               cancelled: @Sendable () -> Bool = { false }) throws {
        try transaction(expectedRevision: expectedRevision, cancelled: cancelled) { value in
            for edit in edits {
                if cancelled() { throw EDAError.cancelled }
                try Self.apply(edit, to: &value)
            }
        }
    }
    /// All zones on one board are solved and committed together. A stale,
    /// cancelled, unsupported or geometrically invalid plan mutates nothing.
    /// The App uses this same operation after computing off the main actor.
    @discardableResult
    public mutating func applyCopperFill(_ plan: EDACopperFillPlan, expectedRevision: UInt64,
                                        cancelled: @escaping @Sendable () -> Bool = { false }) throws -> EDACopperFillReport {
        guard !readOnly else { throw EDAError.readOnly }
        guard expectedRevision == project.revision else { throw EDAError.staleRevision(expected: expectedRevision, actual: project.revision) }
        guard !cancelled() else { throw EDAError.cancelled }
        guard plan.source == project else { throw EDAError.invalid("copper fill source changed") }
        guard let i = project.boards.firstIndex(where: { $0.id == plan.report.boardID }) else { throw EDAError.missing("copper fill board") }
        var report = plan.report
        if project.boards[i].zones.allSatisfy({ $0.fillRevision == project.revision && $0.filledPolygons == plan.polygons[$0.id]
            && $0.fillState == ($0.filledPolygons.isEmpty ? .empty : .filled) }) {
            report.resultRevision = project.revision; return report
        }
        guard project.revision < .max else { throw EDAError.invalid("revision overflow") }
        var candidate = project
        candidate.revision += 1; candidate.modifiedAt = Date()
        Self.rebindCurrentFills(&candidate, from: project.revision)
        for j in candidate.boards[i].zones.indices {
            let id = candidate.boards[i].zones[j].id
            guard let polygons = plan.polygons[id] else { throw EDAError.invalid("copper fill zone missing") }
            candidate.boards[i].zones[j].filledPolygons = polygons
            candidate.boards[i].zones[j].fillRevision = candidate.revision
            candidate.boards[i].zones[j].fillState = polygons.isEmpty ? .empty : .filled
        }
        try EDAValidation.validate(candidate)
        let checked = try EDADRC.check(candidate, boardID: plan.report.boardID, cancelled: cancelled)
        let failed = checked.issues.filter {
            $0.severity == .error && [.copperClearance, .boardEdge, .keepout].contains($0.rule)
                && $0.objects.contains(where: { $0.kind == .zone })
        }
        guard failed.isEmpty else {
            throw EDACopperFillFailure(issues: failed.map { d in
                .init(code: "fill_postcondition_" + d.code, severity: .error, boardID: plan.report.boardID,
                      zoneID: d.objects.first(where: { $0.kind == .zone })?.objectID,
                      objectID: d.objects.first(where: { $0.kind != .zone })?.objectID,
                      position: d.position, path: "zone.filledPolygons", details: ["rule": d.rule.rawValue])
            })
        }
        guard !cancelled() else { throw EDAError.cancelled }
        record(candidate)
        report.resultRevision = candidate.revision
        return report
    }
    @discardableResult
    public mutating func refillCopper(boardID: UUID, expectedRevision: UInt64,
                                      cancelled: @escaping @Sendable () -> Bool = { false }) throws -> EDACopperFillReport {
        guard !readOnly else { throw EDAError.readOnly }
        guard expectedRevision == project.revision else { throw EDAError.staleRevision(expected: expectedRevision, actual: project.revision) }
        let plan = try EDACopperFill.plan(project, boardID: boardID, cancelled: cancelled)
        return try applyCopperFill(plan, expectedRevision: expectedRevision, cancelled: cancelled)
    }
    public mutating func transaction(expectedRevision: UInt64, cancelled: @Sendable () -> Bool = { false },
                                     _ edit: (inout EDAProject) throws -> Void) throws {
        guard !readOnly else { throw EDAError.readOnly }
        guard expectedRevision == project.revision else { throw EDAError.staleRevision(expected: expectedRevision, actual: project.revision) }
        guard !cancelled() else { throw EDAError.cancelled }
        var candidate = project
        try edit(&candidate)
        guard candidate.id == project.id, candidate.schemaVersion == project.schemaVersion,
              candidate.revision == project.revision else { throw EDAError.invalid("transaction identity") }
        guard candidate != project else { return }
        for i in candidate.boards.indices {
            for j in candidate.boards[i].zones.indices {
                candidate.boards[i].zones[j].filledPolygons = []
                candidate.boards[i].zones[j].fillRevision = nil
                candidate.boards[i].zones[j].fillState = nil
            }
        }
        // Ordinary UI/native.put transactions cannot author derived copper.
        // Strip it before validation, including model-supplied fillState.
        try EDAValidation.validate(candidate)
        guard !cancelled() else { throw EDAError.cancelled }
        guard project.revision < .max else { throw EDAError.invalid("revision overflow") }
        candidate.revision += 1; candidate.modifiedAt = Date()
        record(candidate)
    }
    public mutating func undo(expectedRevision: UInt64) throws {
        guard !readOnly else { throw EDAError.readOnly }
        guard expectedRevision == project.revision else { throw EDAError.staleRevision(expected: expectedRevision, actual: project.revision) }
        guard var value = undoStates.last else { return }
        guard project.revision < .max else { throw EDAError.invalid("revision overflow") }
        undoStates.removeLast(); redoStates.append(project)
        let restoredRevision = value.revision
        value.revision = project.revision + 1; value.modifiedAt = Date()
        Self.rebindCurrentFills(&value, from: restoredRevision); project = value
    }
    public mutating func redo(expectedRevision: UInt64) throws {
        guard !readOnly else { throw EDAError.readOnly }
        guard expectedRevision == project.revision else { throw EDAError.staleRevision(expected: expectedRevision, actual: project.revision) }
        guard var value = redoStates.last else { return }
        guard project.revision < .max else { throw EDAError.invalid("revision overflow") }
        redoStates.removeLast(); undoStates.append(project)
        let restoredRevision = value.revision
        value.revision = project.revision + 1; value.modifiedAt = Date()
        Self.rebindCurrentFills(&value, from: restoredRevision); project = value
    }
    private mutating func record(_ candidate: EDAProject) {
        undoStates.append(project)
        if undoStates.count > maximumUndo { undoStates.removeFirst(undoStates.count - maximumUndo) }
        redoStates.removeAll(); project = candidate
    }
    private static func rebindCurrentFills(_ value: inout EDAProject, from oldRevision: UInt64) {
        // The complete restored value has the exact geometry/settings against
        // which these fills were computed. Stale/missing fills stay stale.
        for i in value.boards.indices {
            for j in value.boards[i].zones.indices where value.boards[i].zones[j].fillRevision == oldRevision {
                value.boards[i].zones[j].fillRevision = value.revision
            }
        }
    }
    public mutating func markSaved(_ snapshot: EDAStoredProject) throws {
        guard snapshot.project.id == project.id, snapshot.project.revision == project.revision,
              snapshot.project == project else { throw EDAError.invalid("saved original changed") }
        savedRevision = snapshot.project.revision; savedDigest = snapshot.digest
    }
    private static func put<T: Identifiable>(_ value: T, in values: inout [T]) where T.ID == UUID {
        if let index = values.firstIndex(where: { $0.id == value.id }) { values[index] = value } else { values.append(value) }
    }
    private static func apply(_ edit: EDAEdit, to value: inout EDAProject) throws {
        func sheet(_ id: UUID) throws -> Int {
            guard let index = value.sheets.firstIndex(where: { $0.id == id }) else { throw EDAError.missing("sheet") }; return index
        }
        func board(_ id: UUID) throws -> Int {
            guard let index = value.boards.firstIndex(where: { $0.id == id }) else { throw EDAError.missing("board") }; return index
        }
        switch edit {
        case .rename(let title): value.title = title
        case .putSymbol(let v): put(v, in: &value.symbols)
        case .removeSymbol(let id):
            guard !value.components.contains(where: { $0.symbolID == id }) else { throw EDAError.invalid("symbol in use") }
            value.symbols.removeAll { $0.id == id }
        case .putFootprintDefinition(let v): put(v, in: &value.footprints)
        case .removeFootprintDefinition(let id):
            guard !value.components.contains(where: { $0.footprintID == id }),
                  !value.boards.contains(where: { $0.footprints.contains { $0.definitionID == id } }) else { throw EDAError.invalid("footprint in use") }
            value.footprints.removeAll { $0.id == id }
        case .putComponent(let v): put(v, in: &value.components)
        case .removeComponent(let id):
            value.components.removeAll { $0.id == id }
            for i in value.sheets.indices { value.sheets[i].symbols.removeAll { $0.componentID == id } }
            // Board placement is retained for an explicit synchronization;
            // schematic edits never silently delete a routed physical board.
        case .putSheet(let v): put(v, in: &value.sheets)
        case .removeSheet(let id):
            guard value.sheets.count > 1 else { throw EDAError.invalid("last sheet") }
            value.sheets.removeAll { $0.id == id }
            for i in value.sheets.indices { value.sheets[i].children.removeAll { $0.childSheetID == id } }
        case .placeSymbol(let id, let v): let i = try sheet(id); put(v, in: &value.sheets[i].symbols)
        case .putWire(let id, let v): let i = try sheet(id); put(v, in: &value.sheets[i].wires)
        case .putJunction(let id, let v): let i = try sheet(id); put(v, in: &value.sheets[i].junctions)
        case .putLabel(let id, let v): let i = try sheet(id); put(v, in: &value.sheets[i].labels)
        case .putNoConnect(let id, let v): let i = try sheet(id); put(v, in: &value.sheets[i].noConnects)
        case .putBus(let id, let v): let i = try sheet(id); put(v, in: &value.sheets[i].buses)
        case .putSheetLink(let id, let v): let i = try sheet(id); put(v, in: &value.sheets[i].children)
        case .removeSchematicObject(let id, let object):
            let i = try sheet(id)
            value.sheets[i].symbols.removeAll { $0.id == object }; value.sheets[i].wires.removeAll { $0.id == object }
            value.sheets[i].junctions.removeAll { $0.id == object }; value.sheets[i].labels.removeAll { $0.id == object }
            value.sheets[i].noConnects.removeAll { $0.id == object }; value.sheets[i].buses.removeAll { $0.id == object }
            value.sheets[i].children.removeAll { $0.id == object }
        case .putBoard(let v): put(v, in: &value.boards)
        case .removeBoard(let id): value.boards.removeAll { $0.id == id }
        case .putFootprint(let id, let v): let i = try board(id); put(v, in: &value.boards[i].footprints)
        case .putTrack(let id, let v): let i = try board(id); put(v, in: &value.boards[i].tracks)
        case .putVia(let id, let v): let i = try board(id); put(v, in: &value.boards[i].vias)
        case .putZone(let id, let v): let i = try board(id); put(v, in: &value.boards[i].zones)
        case .putKeepout(let id, let v): let i = try board(id); put(v, in: &value.boards[i].keepouts)
        case .putHole(let id, let v): let i = try board(id); put(v, in: &value.boards[i].holes)
        case .removeBoardObject(let id, let object):
            let i = try board(id)
            guard !value.boards[i].footprints.contains(where: { $0.id == object && $0.locked }),
                  !value.boards[i].tracks.contains(where: { $0.id == object && $0.locked }) else { throw EDAError.readOnly }
            value.boards[i].footprints.removeAll { $0.id == object }; value.boards[i].tracks.removeAll { $0.id == object }
            value.boards[i].vias.removeAll { $0.id == object }; value.boards[i].zones.removeAll { $0.id == object }
            value.boards[i].keepouts.removeAll { $0.id == object }; value.boards[i].holes.removeAll { $0.id == object }
        case .putSimulation(let v): put(v, in: &value.simulations)
        case .removeSimulation(let id): value.simulations.removeAll { $0.id == id }
        }
    }
}
