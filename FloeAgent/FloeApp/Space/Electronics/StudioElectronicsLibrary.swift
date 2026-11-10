// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloeElectronicsCore
import FloeElectronicsUI

nonisolated enum StudioElectronicsLibraryContract {
    static let actions = ["eda.library.search", "eda.library.read", "eda.library.bind", "eda.library.place", "eda.library.previewReplace", "eda.library.replace"]
    struct Capabilities: Encodable, Sendable {
        let runActions: [String]
        let formats: [String: String]
        let searchExample: String
        let rules: [String]
    }
    static func capabilities(revision: UInt64) -> Capabilities {
        .init(runActions: actions, formats: [
            "search": "{expectedRevision:string,query?:{text?:string,category?:string,manufacturer?:string,pinCount?:integer,footprint?:string,offset?:integer,limit?:1...200}}",
            "reference": "Copy the returned {packageID,version,packageSHA256,partID} exactly. This identity pins an installed source version; a model name is not a reference.",
            "read": "{expectedRevision:string,reference:reference}. Returns actual pins, units, geometry, footprint, pinMap, source hashes and concise attribution; original source bytes remain in the library and saved design.",
            "bind": "{expectedRevision:string,symbolReference:reference,footprintReference:reference,pinMap:{pinToPads:{pinNumber:[padNumber,...]},unconnectedPads?:[padNumber,...]},name?:string}. Explicitly associate two installed entries. Read both first and map every pin and pad; an empty array explicitly leaves that logical pin unconnected. Unconnected physical pads must be listed in unconnectedPads. Returns a saved custom combination, not a verified manufacturer model; it does not alter this original. Use its exact returned reference with place.",
            "place": "{expectedRevision:string,reference:reference,sheetID?:UUID,boardID?:UUID,x:number,y:number,unit?:integer,angle?:degrees,mirrored?:boolean,existingComponentID?:UUID}. Choose exactly one sheetID/boardID from this original. Coordinates are mm. Defaults unit1/angle0/mirroredfalse. Use existingComponentID only for another unit or the same component on PCB, never a guessed UUID.",
            "previewReplace": "{expectedRevision:string,reference:reference,componentID:UUID}. Read canApply, blockingReasons, differences, previewSourceSHA256 and previewSnapshotSHA256 before applying.",
            "replace": "{expectedRevision:string,reference:reference,componentID:UUID,previewSourceSHA256:string,previewSnapshotSHA256:string,acceptedDifferences:[exact difference codes]}. The plan is recalculated from the same source, saved through native CAS/undo and read back. Incompatible pin locations remain blocked."
        ], searchExample: "{\"expectedRevision\":\"\(revision)\",\"query\":{\"text\":\"LM358\",\"limit\":20}}", rules: [
            "For real devices, search/read the installed library before placing; use the exact returned reference and explicit pinMap. Do not infer a footprint from reference prefixes, similar names or the first project footprint.",
            "Search is bounded/paged and reports only actual active installed parts. A missing model is not permission to rename a generic shape into that device; explain the missing part or ask before using a generic symbol.",
            "Libraries and originals are separate. Placement embeds fixed native geometry, mapping, attribution and original source bytes. Library updates cannot modify old designs. UI and AI use the same original/session/undo/save chain."
        ])
    }
}

@MainActor enum StudioElectronicsLibraryRuntime {
    private nonisolated struct Request: Decodable {
        let expectedRevision: String
        let query: EDALibraryQuery?
        let reference: EDALibraryReference?
        let symbolReference: EDALibraryReference?
        let footprintReference: EDALibraryReference?
        let pinMap: EDALibraryPinMap?
        let name: String?
        let sheetID: UUID?
        let boardID: UUID?
        let x: Double?
        let y: Double?
        let unit: Int?
        let angle: Double?
        let mirrored: Bool?
        let existingComponentID: UUID?
        let componentID: UUID?
        let previewSourceSHA256: String?
        let previewSnapshotSHA256: String?
        let acceptedDifferences: [String]?
    }
    private nonisolated struct Outcome<Result: Encodable>: Encodable {
        let projectID: UUID
        let action: String
        let revision: String
        let sourceSHA256: String
        let result: Result
        let openURL: String
    }
    private nonisolated struct Match: Encodable {
        let reference: EDALibraryReference
        let name: String
        let kind: EDALibraryPart.Kind
        let category: String
        let manufacturer: String
        let pinCount: Int
        let footprint: String?
        let isPlaceable: Bool
        let supportsBoundPCB: Bool
        init(_ entry: EDALibraryEntry) {
            reference = entry.reference; name = entry.part.name; kind = entry.part.kind; category = entry.part.category
            manufacturer = entry.part.manufacturer; pinCount = entry.part.pinCount; footprint = entry.part.footprint?.name
            isPlaceable = entry.part.isPlaceable; supportsBoundPCB = entry.part.supportsBoundPCB
        }
    }
    private nonisolated struct Search: Encodable { let inventoryRevision: UInt64; let total: Int; let nextOffset: Int?; let matches: [Match] }
    private nonisolated struct Attribution: Encodable {
        let id: String; let attribution: String; let url: String?; let modifications: String
        init(_ value: EDALibraryLicense) { id = value.id; attribution = value.attribution; url = value.url; modifications = value.modifications }
    }
    private nonisolated struct Read: Encodable { let reference: EDALibraryReference; let snapshotSHA256: String; let part: EDALibraryPart; let attribution: [Attribution]; let originalSourceBytesRetained: Bool }
    private nonisolated struct Replacement: Encodable {
        let componentID: UUID; let previewSourceSHA256: String; let previewSnapshotSHA256: String
        let differences: [EDALibraryDifference]; let blockingReasons: [String]; let canApply: Bool
    }
    static func run(record: PersonalContentRecord, directory: URL, action: String, inputJSON: String?, context: ToolContext,
        validateOwner: @escaping @MainActor @Sendable () async throws -> Void) async throws -> ToolExecutionOutput {
        let request = try decode(inputJSON, action: action)
        let cancellation = context.cancellation
        try context.cancellation.throwIfCancelled(); try await validateOwner()
        let saved = try await personalPreviewOffMain { try ElectronicsSavedSnapshot(id: record.id, directory: directory) }
        guard request.expectedRevision == String(saved.project.revision) else { throw PersonalContentError.changedDocument }
        let library = try ElectronicsLibraryService.shared()
        let catalog = try await library.prepare()
        try context.cancellation.throwIfCancelled(); try await validateOwner(); try saved.validate()
        if action == "eda.library.search" {
            let page = try catalog.search(request.query ?? .init(limit: 20), cancelled: { cancellation.isCancelled })
            return try output(record: record, action: action, saved: saved,
                value: Search(inventoryRevision: page.inventoryRevision, total: page.total, nextOffset: page.nextOffset, matches: page.entries.map(Match.init)))
        }
        if action == "eda.library.bind" {
            guard let symbol = request.symbolReference, let footprint = request.footprintReference, let map = request.pinMap else {
                throw invalid("symbolReference/footprintReference/pinMap", "read both installed entries and supply the complete explicit pin-to-pad map")
            }
            let entry = try await library.associate(symbol: symbol, footprint: footprint, map: map, name: request.name,
                cancelled: { cancellation.isCancelled })
            let bound = try await library.snapshot(entry.reference)
            try context.cancellation.throwIfCancelled(); try await validateOwner(); try saved.validate()
            return try output(record: record, action: action, saved: saved,
                value: Read(reference: entry.reference, snapshotSHA256: try bound.sha256, part: bound.part,
                    attribution: bound.licenses.map(Attribution.init), originalSourceBytesRetained: bound.originalSources != nil))
        }
        guard let reference = request.reference else { throw invalid("reference", "copy an exact reference returned by eda.library.search") }
        let snapshot = try await library.snapshot(reference)
        try context.cancellation.throwIfCancelled(); try await validateOwner(); try saved.validate()
        if action == "eda.library.read" {
            return try output(record: record, action: action, saved: saved,
                value: Read(reference: reference, snapshotSHA256: try snapshot.sha256, part: snapshot.part,
                    attribution: snapshot.licenses.map(Attribution.init), originalSourceBytesRetained: snapshot.originalSources != nil))
        }
        if action == "eda.library.place" {
            guard let x = request.x, let y = request.y, (request.sheetID != nil) != (request.boardID != nil) else { throw invalid("sheetID/boardID/x/y", "choose exactly one native context and supply mm coordinates") }
            let target: EDADocumentContext = request.sheetID.map { .schematic(sheetID: $0) } ?? .board(boardID: request.boardID!)
            let session = try await ElectronicsProjectSession.open(id: record.id, directory: directory)
            try context.cancellation.throwIfCancelled(); try await validateOwner(); try saved.validate()
            guard session.workbench.project == saved.project, !session.workbench.conflictWithOriginal else { throw PersonalContentError.changedDocument }
            let receipt = try await session.workbench.placeLibrary(.init(snapshot: snapshot, unit: request.unit ?? 1, existingComponentID: request.existingComponentID),
                context: target, position: .init(x, y), angle: request.angle ?? 0, mirrored: request.mirrored ?? false,
                expectedRevision: saved.project.revision, cancelled: { cancellation.isCancelled })
            await session.awaitPublication()
            let current = try await personalPreviewOffMain { try ElectronicsSavedSnapshot(id: record.id, directory: directory) }
            try context.cancellation.throwIfCancelled(); try await validateOwner()
            guard current.project.revision == session.workbench.revision,
                  try EDALibraryProject.snapshot(receipt.snapshotSHA256, in: current.project) == snapshot,
                  current.project.sheets.flatMap(\.symbols).contains(where: { $0.id == receipt.objectID }) || current.project.boards.flatMap(\.footprints).contains(where: { $0.id == receipt.objectID }) else { throw PersonalContentError.changedDocument }
            return try output(record: record, action: action, saved: current, value: receipt)
        }
        guard let componentID = request.componentID else { throw invalid("componentID", "use an actual logical component UUID from this original") }
        let plan = try await personalPreviewOffMain { try EDALibraryProject.planReplacement(snapshot, componentID: componentID, project: saved.project) }
        try context.cancellation.throwIfCancelled(); try await validateOwner(); try saved.validate()
        if action == "eda.library.previewReplace" {
            return try output(record: record, action: action, saved: saved,
                value: Replacement(componentID: componentID, previewSourceSHA256: saved.digest, previewSnapshotSHA256: try snapshot.sha256,
                    differences: plan.differences, blockingReasons: plan.blockingReasons, canApply: plan.canApply))
        }
        guard action == "eda.library.replace", request.previewSourceSHA256 == saved.digest, request.previewSnapshotSHA256 == (try snapshot.sha256), let accepted = request.acceptedDifferences else {
            throw invalid("previewSourceSHA256/previewSnapshotSHA256/acceptedDifferences", "preview the same original and exact library reference first")
        }
        let session = try await ElectronicsProjectSession.open(id: record.id, directory: directory)
        try context.cancellation.throwIfCancelled(); try await validateOwner(); try saved.validate()
        guard session.workbench.project == saved.project, !session.workbench.conflictWithOriginal else { throw PersonalContentError.changedDocument }
        try await session.workbench.replaceLibrary(plan, acceptedDifferences: Set(accepted), cancelled: { cancellation.isCancelled })
        await session.awaitPublication()
        let current = try await personalPreviewOffMain { try ElectronicsSavedSnapshot(id: record.id, directory: directory) }
        try context.cancellation.throwIfCancelled(); try await validateOwner()
        guard current.project.revision == session.workbench.revision,
              current.project.components.first(where: { $0.id == componentID })?.fields[EDALibraryProject.snapshotField] == (try snapshot.sha256) else { throw PersonalContentError.changedDocument }
        return try output(record: record, action: action, saved: current, value: Replacement(componentID: componentID,
            previewSourceSHA256: current.digest, previewSnapshotSHA256: try snapshot.sha256, differences: plan.differences, blockingReasons: [], canApply: true))
    }
    private static func output<T: Encodable>(record: PersonalContentRecord, action: String, saved: ElectronicsSavedSnapshot, value: T) throws -> ToolExecutionOutput {
        try StudioToolOutput.make(Outcome(projectID: record.id, action: action, revision: String(saved.project.revision), sourceSHA256: saved.digest, result: value, openURL: "floe://work/" + record.id.uuidString.lowercased()))
    }
    private static func invalid(_ path: String, _ detail: String) -> FloeError { .validationFailed("inputJSON." + path + ": " + detail) }
    private static func decode(_ text: String?, action: String) throws -> Request {
        guard StudioElectronicsLibraryContract.actions.contains(action), let text, text.utf8.count <= 262_144,
              let object = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { throw invalid("$", "use the documented library request object") }
        let allowed: Set<String>
        switch action {
        case "eda.library.search": allowed = ["expectedRevision", "query"]
        case "eda.library.read": allowed = ["expectedRevision", "reference"]
        case "eda.library.bind": allowed = ["expectedRevision", "symbolReference", "footprintReference", "pinMap", "name"]
        case "eda.library.place": allowed = ["expectedRevision", "reference", "sheetID", "boardID", "x", "y", "unit", "angle", "mirrored", "existingComponentID"]
        case "eda.library.previewReplace": allowed = ["expectedRevision", "reference", "componentID"]
        default: allowed = ["expectedRevision", "reference", "componentID", "previewSourceSHA256", "previewSnapshotSHA256", "acceptedDifferences"]
        }
        if let unknown = Set(object.keys).subtracting(allowed).sorted().first { throw invalid(unknown, "unknown field for " + action) }
        let referenceKeys = Set(["packageID", "version", "packageSHA256", "partID"])
        for (field, keys) in [("query", Set(["text", "category", "manufacturer", "pinCount", "footprint", "offset", "limit"])), ("reference", referenceKeys),
            ("symbolReference", referenceKeys), ("footprintReference", referenceKeys), ("pinMap", Set(["pinToPads", "unconnectedPads"]))] {
            if let nested = object[field] as? [String: Any], let unknown = Set(nested.keys).subtracting(keys).sorted().first { throw invalid(field + "." + unknown, "unknown field") }
        }
        do { return try JSONDecoder().decode(Request.self, from: Data(text.utf8)) }
        catch DecodingError.keyNotFound(let key, let detail) { throw invalid((detail.codingPath.map(\.stringValue) + [key.stringValue]).joined(separator: "."), "required field is missing") }
        catch DecodingError.typeMismatch(_, let detail) { throw invalid(detail.codingPath.map(\.stringValue).joined(separator: "."), "wrong value type: " + detail.debugDescription) }
        catch DecodingError.valueNotFound(_, let detail) { throw invalid(detail.codingPath.map(\.stringValue).joined(separator: "."), "required value is null") }
        catch DecodingError.dataCorrupted(let detail) { throw invalid(detail.codingPath.map(\.stringValue).joined(separator: "."), detail.debugDescription) }
    }
}
#endif
