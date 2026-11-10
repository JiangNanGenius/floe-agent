// SPDX-License-Identifier: MPL-2.0
import Foundation

public struct EDALibrarySnapshot: Codable, Hashable, Sendable {
    public let packageID: String
    public let packageVersion: String
    public let packageSHA256: String
    public let part: EDALibraryPart
    public let licenses: [EDALibraryLicense]
    public let originalSources: [String: Data]?
    public init(package: EDALibraryPackage, partID: String) throws {
        try package.validate()
        guard let part = package.parts.first(where: { $0.id == partID }) else { throw EDAError.missing("library part") }
        packageID = package.id; packageVersion = package.version
        packageSHA256 = try EDALibraryDigest.sha256(EDALibraryDigest.encoded(package)); self.part = part; licenses = package.licenses
        guard Set(part.sources.map(\.path)).count == part.sources.count else { throw EDAError.duplicate("snapshot source path") }
        originalSources = Dictionary(uniqueKeysWithValues: part.sources.map { ($0.path, package.sourcePayloads[$0.path]!) })
    }
    public func validate() throws {
        guard EDALibraryDigest.validSHA256(packageSHA256) else { throw EDAError.invalid("snapshot package digest") }
        try part.validate()
        if let originalSources {
            guard originalSources.count == part.sources.count else { throw EDAError.invalid("snapshot source count") }
            for source in part.sources {
                guard let bytes = originalSources[source.path], EDALibraryPackage.safeRelativePath(source.path),
                      bytes.count == source.byteCount, EDALibraryDigest.sha256(bytes) == source.sha256 else { throw EDAError.invalid("snapshot original source bytes") }
            }
        }
    }
    public var sha256: String { get throws { try EDALibraryDigest.sha256(EDALibraryDigest.encoded(self)) } }
}
public struct EDALibraryAdoption: Codable, Hashable, Sendable {
    public let snapshotSHA256: String
    public let symbolID: UUID?
    public let footprintID: UUID?
}
public struct EDALibraryPlacementReceipt: Codable, Hashable, Sendable {
    public let projectID: UUID
    public let componentID: UUID?
    public let objectID: UUID
    public let contextID: UUID
    public let snapshotSHA256: String
    public let symbolID: UUID?
    public let footprintID: UUID?
    public let reference: String
}
public struct EDALibraryDifference: Codable, Hashable, Sendable {
    public let code: String
    public let detail: String
    public init(_ code: String, _ detail: String) { self.code = code; self.detail = detail }
}
public struct EDALibraryReplacementPlan: Codable, Hashable, Sendable {
    public let projectID: UUID
    public let sourceRevision: UInt64
    public let componentID: UUID
    public let original: EDAComponent
    public let snapshot: EDALibrarySnapshot
    public let differences: [EDALibraryDifference]
    public let blockingReasons: [String]
    public var canApply: Bool { blockingReasons.isEmpty }
}

/// Pure project changes, committed by the existing EDAEditingSession and
/// EDAProjectStore. Snapshots are embedded in the design, not live library
/// pointers: a catalog update cannot mutate an old schematic or board.
public enum EDALibraryProject {
    public static let snapshotField = "FloeLibrarySnapshotSHA256"
    public static let pinMapField = "FloeLibraryPinMap"
    public static func snapshot(_ hash: String, in project: EDAProject) throws -> EDALibrarySnapshot {
        guard EDALibraryDigest.validSHA256(hash), let text = project.preservedSource["library/snapshots/" + hash] else { throw EDAError.missing("project library snapshot") }
        let data = Data(text.utf8)
        guard EDALibraryDigest.sha256(data) == hash else { throw EDAError.invalid("project library snapshot checksum") }
        let value = try JSONDecoder().decode(EDALibrarySnapshot.self, from: data)
        try value.validate(); return value
    }
    public static func boundSnapshot(symbolID: UUID, in project: EDAProject) throws -> EDALibrarySnapshot? {
        guard let symbol = project.symbols.first(where: { $0.id == symbolID }), let hash = symbol.fields[snapshotField] else { return nil }
        let value = try snapshot(hash, in: project)
        guard var expected = value.part.symbol else { return nil }
        expected.id = symbol.id; expected.fields[snapshotField] = hash
        return expected == symbol ? value : nil
    }
    public static func boundSnapshot(footprintID: UUID, in project: EDAProject) throws -> EDALibrarySnapshot? {
        guard let footprint = project.footprints.first(where: { $0.id == footprintID }), let hash = footprint.fields[snapshotField] else { return nil }
        let value = try snapshot(hash, in: project)
        guard var expected = value.part.footprint else { return nil }
        expected.id = footprint.id; expected.fields[snapshotField] = hash
        return expected == footprint ? value : nil
    }
    @discardableResult public static func adopt(_ value: EDALibrarySnapshot, into project: inout EDAProject) throws -> EDALibraryAdoption {
        try value.validate()
        guard value.part.isPlaceable else { throw EDAError.unsupported("library entry has blocking compatibility findings") }
        let data = try EDALibraryDigest.encoded(value), hash = EDALibraryDigest.sha256(data)
        var candidate = project
        var symbolID: UUID?, footprintID: UUID?
        if var symbol = value.part.symbol {
            symbol.fields[snapshotField] = hash
            for generation in 0..<1_000 {
                symbol.id = EDALibraryDigest.identifier(hash + "/symbol" + (generation == 0 ? "" : "/" + String(generation)))
                if let existing = candidate.symbols.first(where: { $0.id == symbol.id }) {
                    if existing == symbol { symbolID = symbol.id; break }
                    // Project-local edits keep their own geometry. A fresh
                    // choice from the immutable library gets a separate copy.
                } else { candidate.symbols.append(symbol); symbolID = symbol.id; break }
            }
            guard symbolID != nil else { throw EDAError.invalid("project symbol variant limit") }
        }
        if var footprint = value.part.footprint {
            footprint.fields[snapshotField] = hash
            for generation in 0..<1_000 {
                footprint.id = EDALibraryDigest.identifier(hash + "/footprint" + (generation == 0 ? "" : "/" + String(generation)))
                if let existing = candidate.footprints.first(where: { $0.id == footprint.id }) {
                    if existing == footprint { footprintID = footprint.id; break }
                } else { candidate.footprints.append(footprint); footprintID = footprint.id; break }
            }
            guard footprintID != nil else { throw EDAError.invalid("project footprint variant limit") }
        }
        let key = "library/snapshots/" + hash, text = String(decoding: data, as: UTF8.self)
        guard candidate.preservedSource[key] == nil || candidate.preservedSource[key] == text else { throw EDAError.duplicate("project source snapshot") }
        candidate.preservedSource[key] = text
        try EDAValidation.validate(candidate); project = candidate
        return .init(snapshotSHA256: hash, symbolID: symbolID, footprintID: footprintID)
    }
    @discardableResult public static func place(_ snapshot: EDALibrarySnapshot, into project: inout EDAProject,
        sheetID: UUID? = nil, boardID: UUID? = nil, position: EDAPoint, unit: Int = 1,
        angle: Double = 0, mirrored: Bool = false, existingComponentID: UUID? = nil) throws -> EDALibraryPlacementReceipt {
        guard (sheetID != nil) != (boardID != nil), position.isValid, angle.isFinite else { throw EDAError.invalid("choose exactly one native placement context") }
        var candidate = project
        let adopted = try adopt(snapshot, into: &candidate)
        var component: EDAComponent?
        if let symbolID = adopted.symbolID {
            if let existingComponentID {
                guard let existing = candidate.components.first(where: { $0.id == existingComponentID }), existing.fields[snapshotField] == adopted.snapshotSHA256 else { throw EDAError.invalid("component belongs to a different library snapshot") }
                guard existing.symbolID == adopted.symbolID, existing.footprintID == adopted.footprintID else { throw EDAError.invalid("component has a project-local symbol or footprint variation; choose it explicitly or review a replacement") }
                component = existing
            } else {
                let prefix = snapshot.part.symbol?.referencePrefix ?? "U"
                component = .init(symbolID: symbolID, footprintID: adopted.footprintID,
                    reference: nextReference(prefix, project: candidate), value: snapshot.part.parameters["Value"] ?? snapshot.part.name,
                    fields: try fields(snapshot, hash: adopted.snapshotSHA256))
                candidate.components.append(component!)
            }
        } else if existingComponentID != nil { throw EDAError.invalid("a footprint-only entry has no logical component") }
        let objectID = UUID(), contextID: UUID
        if let sheetID {
            guard let component, let symbol = snapshot.part.symbol,
                  symbol.pins.contains(where: { $0.unit == unit || $0.unit == 0 }) || (symbol.pins.isEmpty && unit == 1),
                  let index = candidate.sheets.firstIndex(where: { $0.id == sheetID }) else { throw EDAError.invalid("schematic context or symbol unit") }
            guard !candidate.sheets.flatMap(\.symbols).contains(where: { $0.componentID == component.id && $0.unit == unit }) else { throw EDAError.duplicate("symbol unit is already placed") }
            candidate.sheets[index].symbols.append(.init(id: objectID, componentID: component.id, unit: unit, position: position, angle: angle, mirrored: mirrored))
            contextID = sheetID
        } else {
            guard let boardID, let footprintID = adopted.footprintID,
                  let index = candidate.boards.firstIndex(where: { $0.id == boardID }) else { throw EDAError.missing("assigned footprint and board") }
            try requireBoardCompatibility(snapshot.part.footprint, board: candidate.boards[index])
            if let component, candidate.boards[index].footprints.contains(where: { $0.componentID == component.id }) { throw EDAError.duplicate("component already on this board") }
            let reference = component?.reference ?? nextBoardReference(candidate.boards[index])
            candidate.boards[index].footprints.append(.init(id: objectID, definitionID: footprintID, componentID: component?.id,
                reference: reference, value: component?.value ?? snapshot.part.name, position: position, angle: angle, side: mirrored ? "B.Cu" : "F.Cu"))
            contextID = boardID
        }
        try EDAValidation.validate(candidate); project = candidate
        return .init(projectID: project.id, componentID: component?.id, objectID: objectID, contextID: contextID,
            snapshotSHA256: adopted.snapshotSHA256, symbolID: adopted.symbolID, footprintID: adopted.footprintID,
            reference: component?.reference ?? candidate.boards.flatMap(\.footprints).first(where: { $0.id == objectID })?.reference ?? "")
    }
    public static func planReplacement(_ snapshot: EDALibrarySnapshot, componentID: UUID, project: EDAProject) throws -> EDALibraryReplacementPlan {
        try snapshot.validate()
        guard let old = project.components.first(where: { $0.id == componentID }),
              let oldSymbol = project.symbols.first(where: { $0.id == old.symbolID }), let symbol = snapshot.part.symbol else { throw EDAError.missing("logical component or replacement symbol") }
        var changes: [EDALibraryDifference] = [], blocking: [String] = []
        func pinLayout(_ value: EDASymbolDefinition) -> Set<String> { Set(value.pins.map { "\($0.unit)/\($0.number)/\($0.position.x)/\($0.position.y)" }) }
        if pinLayout(oldSymbol) != pinLayout(symbol) {
            changes.append(.init("symbol_pin_layout", "Pin numbers, units or connection locations differ."))
            blocking.append("Replacement pin locations differ. Keep the existing design; use explicit native wiring edits before replacement.")
        }
        let oldFootprint = old.footprintID.flatMap { id in project.footprints.first { $0.id == id } }
        if oldFootprint?.pads != snapshot.part.footprint?.pads { changes.append(.init("footprint_geometry", "Footprint/pads change; existing routing and clearances need review.")) }
        if oldSymbol.graphics != symbol.graphics || oldSymbol.graphicUnits != symbol.graphicUnits {
            changes.append(.init("symbol_graphics", "Symbol artwork or unit assignments change."))
        }
        func pinProperties(_ value: EDASymbolDefinition) -> Set<String> { Set(value.pins.map { "\($0.unit)/\($0.number)/\($0.name)/\($0.type.rawValue)" }) }
        if pinProperties(oldSymbol) != pinProperties(symbol) { changes.append(.init("pin_properties", "Pin names or electrical types change.")) }
        let nextValue = snapshot.part.parameters["Value"] ?? snapshot.part.name
        let nextNumber = snapshot.part.kind == .generic ? "" : snapshot.part.parameters["PartNumber"] ?? snapshot.part.name
        if old.value != nextValue || (old.fields["PartNumber"] ?? "") != nextNumber || (old.fields["Manufacturer"] ?? "") != snapshot.part.manufacturer {
            changes.append(.init("device_identity", "Value, manufacturer or part number changes: " + old.value + " → " + nextValue))
        }
        if old.fields[snapshotField] != (try snapshot.sha256) { changes.append(.init("library_source", "Library identity, source or version changes.")) }
        let oldMap = try pinMap(component: old)
        if oldMap != snapshot.part.pinMap { changes.append(.init("pin_pad_mapping", "Physical pin-to-pad mapping changes.")) }
        for board in project.boards where board.footprints.contains(where: { $0.componentID == componentID }) {
            if board.footprints.contains(where: { $0.componentID == componentID && $0.locked }) { blocking.append("The board component is locked.") }
            do { try requireBoardCompatibility(snapshot.part.footprint, board: board) } catch { blocking.append(String(describing: error)) }
        }
        return .init(projectID: project.id, sourceRevision: project.revision, componentID: componentID, original: old,
            snapshot: snapshot, differences: changes, blockingReasons: blocking)
    }
    public static func replace(_ plan: EDALibraryReplacementPlan, acceptedDifferences: Set<String>, in project: inout EDAProject) throws {
        guard plan.projectID == project.id, plan.sourceRevision == project.revision,
              project.components.first(where: { $0.id == plan.componentID }) == plan.original else { throw EDAError.staleRevision(expected: plan.sourceRevision, actual: project.revision) }
        let current = try planReplacement(plan.snapshot, componentID: plan.componentID, project: project)
        guard current == plan, plan.canApply, Set(plan.differences.map(\.code)).isSubset(of: acceptedDifferences) else { throw EDAError.invalid("review the actual replacement differences before applying") }
        var candidate = project
        let adopted = try adopt(plan.snapshot, into: &candidate)
        guard let index = candidate.components.firstIndex(where: { $0.id == plan.componentID }), let symbolID = adopted.symbolID else { throw EDAError.missing("replacement component") }
        var component = candidate.components[index]
        component.symbolID = symbolID; component.footprintID = adopted.footprintID; component.value = plan.snapshot.part.parameters["Value"] ?? plan.snapshot.part.name
        component.fields.removeValue(forKey: pinMapField)
        component.fields.merge(try fields(plan.snapshot, hash: adopted.snapshotSHA256)) { _, new in new }
        candidate.components[index] = component
        let netlist = try EDAConnectivity.derive(candidate)
        var pinNets: [String: String] = [:]
        for net in netlist.nets { for pin in net.pins where pin.componentID == component.id { pinNets[pin.number] = net.id } }
        for i in candidate.boards.indices {
            for j in candidate.boards[i].footprints.indices where candidate.boards[i].footprints[j].componentID == component.id {
                guard let footprintID = adopted.footprintID else { throw EDAError.invalid("replacement would remove an already placed footprint") }
                candidate.boards[i].footprints[j].definitionID = footprintID; candidate.boards[i].footprints[j].value = component.value
                if let map = plan.snapshot.part.pinMap { candidate.boards[i].footprints[j].padNets = try map.padNets(pinNets: pinNets) }
            }
        }
        try EDAValidation.validate(candidate); project = candidate
    }
    public static func pinMap(component: EDAComponent) throws -> EDALibraryPinMap? {
        guard let text = component.fields[pinMapField] else { return nil }
        return try JSONDecoder().decode(EDALibraryPinMap.self, from: Data(text.utf8))
    }
    private static func fields(_ value: EDALibrarySnapshot, hash: String) throws -> [String: String] {
        var fields = [snapshotField: hash, "FloeLibraryPackage": value.packageID, "FloeLibraryVersion": value.packageVersion,
                      "FloeLibraryPart": value.part.id, "Manufacturer": value.part.manufacturer, "PartNumber": value.part.kind == .generic ? "" : value.part.parameters["PartNumber"] ?? value.part.name]
        if let map = value.part.pinMap { fields[pinMapField] = String(decoding: try EDALibraryDigest.encoded(map), as: UTF8.self) }
        return fields
    }
    private static func requireBoardCompatibility(_ definition: EDAFootprintDefinition?, board: EDABoard) throws {
        guard let definition else { throw EDAError.missing("replacement footprint") }
        if definition.fields["kicad.usesAllCopperLayers"] == "true", board.layers.filter({ $0.kind == .copper }).count > 2 {
            throw EDAError.unsupported("This imported through-hole footprint needs explicit inner copper-layer support; the original is retained.")
        }
    }
    private static func nextReference(_ prefix: String, project: EDAProject) -> String {
        let used = Set(project.components.map(\.reference)); var value = 1
        while used.contains(prefix + String(value)) { value += 1 }; return prefix + String(value)
    }
    private static func nextBoardReference(_ board: EDABoard) -> String {
        let used = Set(board.footprints.map(\.reference)); var value = 1
        while used.contains("FP" + String(value)) { value += 1 }; return "FP" + String(value)
    }
}
