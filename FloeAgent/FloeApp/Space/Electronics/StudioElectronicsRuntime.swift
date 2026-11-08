// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import CoreFoundation
import ImageIO
import FloeCore
import FloeModels
import FloeTools
import FloeElectronicsCore
import FloeElectronicsUI

@MainActor enum StudioElectronicsRuntime {
    struct Selection: Encodable, Sendable {
        let status: String
        let nativeRevision: String?
        let hasUnsavedChanges: Bool
        let conflictsWithOriginal: Bool
        let context: String?
        let contextID: UUID?
        let objectIDs: [UUID]
        let objectIDsTruncated: Bool
    }
    static func selection(id: UUID, directory: URL) throws -> Selection {
        guard let session = try ElectronicsProjectSession.existing(id: id, directory: directory) else {
            return .init(status: "noExistingNativeSession", nativeRevision: nil, hasUnsavedChanges: false, conflictsWithOriginal: false,
                context: nil, contextID: nil, objectIDs: [], objectIDsTruncated: false)
        }
        let value = session.workbench
        let kind: String?, contextID: UUID?
        switch value.selection.context {
        case .schematic(let id): kind = "schematic"; contextID = id
        case .board(let id): kind = "board"; contextID = id
        case .symbol(let id): kind = "symbolDefinition"; contextID = id
        case .footprint(let id): kind = "footprintDefinition"; contextID = id
        case nil: kind = nil; contextID = nil
        }
        let ids = value.selection.objectIDs.sorted { $0.uuidString < $1.uuidString }
        return .init(status: "existingNativeSession", nativeRevision: String(value.revision), hasUnsavedChanges: value.isDirty,
            conflictsWithOriginal: value.conflictWithOriginal, context: kind, contextID: contextID,
            objectIDs: Array(ids.prefix(500)), objectIDsTruncated: ids.count > 500)
    }
    private struct Receipt: Encodable {
        let projectID: UUID
        let action: String
        let revision: String
        let sourceSHA256: String
        let summary: [String: String]
        let resultJSON: String?
        let limitations: [String]
        let openURL: String
    }
    private struct Computation: Sendable {
        let files: [EDAExchangeFile]
        let summary: [String: String]
        let limitations: [String]
    }
    static func run(record: PersonalContentRecord, directory: URL, action: String, inputJSON: String?, context: ToolContext,
                    validateOwner: @escaping @MainActor @Sendable () async throws -> Void) async throws -> ToolExecutionOutput {
        guard StudioElectronicsContract.runActions.contains(action) else { throw FloeError.validationFailed("Read electronicsCapabilities.runActions for implemented operations") }
        let allowed: Set<String> = action == "eda.export" ? ["expectedRevision", "boardID", "format", "variant", "gerberLayers"]
            : ["eda.drc", "eda.forwardAnnotation", "eda.refillCopper"].contains(action) ? ["expectedRevision", "boardID"] : ["expectedRevision"]
        let input = try options(inputJSON, allowed: allowed)
        try context.cancellation.throwIfCancelled(); try await validateOwner()
        var saved = try await personalPreviewOffMain { try ElectronicsSavedSnapshot(id: record.id, directory: directory) }
        guard String(saved.project.revision) == input.revision else { throw PersonalContentError.changedDocument }
        let boardID = try board(input.object["boardID"], project: saved.project)
        if action == "eda.refillCopper" {
            guard let boardID else { throw FloeError.validationFailed("This original has no PCB board") }
            let session = try await ElectronicsProjectSession.open(id: record.id, directory: directory)
            try context.cancellation.throwIfCancelled(); try await validateOwner(); try saved.validate()
            let cancellation = context.cancellation
            let report: EDACopperFillReport
            do {
                report = try await session.workbench.refillCopper(boardID:boardID,expectedRevision:saved.project.revision,
                    cancelled:{cancellation.isCancelled})
            } catch let failure as EDACopperFillFailure {
                throw FloeError.validationFailed("Copper refill refused: " + String(decoding:try encoded(failure.issues),as:UTF8.self))
            }
            await session.awaitPublication()
            saved = try await personalPreviewOffMain { try ElectronicsSavedSnapshot(id: record.id, directory: directory) }
            try context.cancellation.throwIfCancelled(); try await validateOwner()
            guard report.resultRevision == saved.project.revision else { throw PersonalContentError.changedDocument }
            return try StudioToolOutput.make(Receipt(projectID:record.id,action:action,revision:String(saved.project.revision),
                sourceSHA256:saved.digest,summary:["boardID":boardID.uuidString,"zones":String(report.zones.count),
                    "polygons":String(report.zones.reduce(0){$0+$1.polygonCount})],
                resultJSON:String(decoding:try encoded(report),as:UTF8.self),limitations:report.limitations,
                openURL:"floe://work/"+record.id.uuidString.lowercased()))
        }
        if action == "eda.forwardAnnotation" {
            guard let boardID else { throw FloeError.validationFailed("This original has no PCB board") }
            let session = try await ElectronicsProjectSession.open(id: record.id, directory: directory)
            try context.cancellation.throwIfCancelled(); try await validateOwner(); try saved.validate()
            try await session.workbench.forwardAnnotation(boardID: boardID, expectedRevision: saved.project.revision)
            await session.awaitPublication()
            saved = try await personalPreviewOffMain { try ElectronicsSavedSnapshot(id: record.id, directory: directory) }
            try context.cancellation.throwIfCancelled(); try await validateOwner()
            return try StudioToolOutput.make(Receipt(projectID: record.id, action: action, revision: String(saved.project.revision),
                sourceSHA256: saved.digest, summary: ["boardID": boardID.uuidString, "footprints": String(saved.project.boards.first { $0.id == boardID }?.footprints.count ?? 0)],
                resultJSON: nil, limitations: ["Routed physical objects are retained; inspect the actual synchronization result and DRC."],
                openURL: "floe://work/" + record.id.uuidString.lowercased()))
        }
        let source = saved, cancellation = context.cancellation
        let format: EDAExportFormat?
        if action == "eda.export" {
            guard let raw = input.object["format"] as? String, let value = EDAExportFormat(rawValue: raw) else {
                throw FloeError.validationFailed("eda.export inputJSON.format must be one of " + EDAExportFormat.allCases.map(\.rawValue).joined(separator: ", "))
            }
            format = value
        } else { format = nil }
        let gerberLayers:[String]?
        if let raw=input.object["gerberLayers"]{
            guard let values=raw as? [String],(1...8).contains(values.count) else{throw FloeError.validationFailed("inputJSON.gerberLayers must be 1...8 supported layer IDs")}
            gerberLayers=values
        }else{gerberLayers=nil}
        let variant = input.object["variant"] as? String
            ?? (source.project.variants.contains("Default") ? "Default" : source.project.variants.first ?? "Default")
        if input.object["variant"] != nil && !(input.object["variant"] is String) { throw FloeError.validationFailed("inputJSON.variant must be a string") }
        let task = Task.detached(priority: .userInitiated) { () throws -> Computation in
            let cancelled: @Sendable () -> Bool = { cancellation.isCancelled || Task.isCancelled }
            switch action {
            case "eda.erc":
                let report = try EDAERC.check(source.project, cancelled: cancelled), bytes = try encoded(report)
                return .init(files: [.init(name: "ERC.json", mimeType: "application/json", data: bytes)], summary: ["issues": String(report.issues.count)], limitations: [])
            case "eda.drc":
                guard let boardID else { throw FloeError.validationFailed("This original has no PCB board") }
                let report = try EDADRC.check(source.project, boardID: boardID, cancelled: cancelled), bytes = try encoded(report)
                return .init(files: [.init(name: "DRC.json", mimeType: "application/json", data: bytes)],
                    summary: ["issues": String(report.issues.count), "supportedChecksComplete": String(report.isCompleteForSupportedChecks), "boardID": boardID.uuidString],
                    limitations: report.excludedChecks + report.coverage.flatMap(\.limitationCodes))
            case "eda.netlist":
                let result = try EDAExchange.export(source.project, format: .netlist, cancelled: cancelled)
                return .init(files: result.files, summary: [:], limitations: result.limitations)
            case "eda.export":
                guard let format else { throw PersonalContentError.invalidProject }
                do {
                    let result = try EDAExchange.export(source.project, format: format, boardID: boardID, variant: variant, gerberLayers: gerberLayers, cancelled: cancelled)
                    return .init(files: result.files, summary: ["format": format.rawValue, "files": String(result.files.count), "boardID": boardID?.uuidString ?? ""], limitations: result.limitations)
                } catch let failure as EDAManufacturingFailure {
                    let details = String(decoding: try encoded(failure.issues), as: UTF8.self)
                    throw FloeError.validationFailed("Manufacturing export requires explicit supported design data: " + details)
                }
            default: throw PersonalContentError.invalidProject
            }
        }
        let result = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
        let validate: @MainActor @Sendable () async throws -> Void = {
            try context.cancellation.throwIfCancelled(); try Task.checkCancellation(); try await validateOwner(); try source.validate()
        }
        try await validate()
        let outputRoot = directory.appendingPathComponent("Electronics/Exports", isDirectory: true)
        if FileManager.default.fileExists(atPath: outputRoot.path) {
            let attributes = try outputRoot.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
            guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { throw PersonalContentError.changedDocument }
        } else { try FileManager.default.createDirectory(at: outputRoot, withIntermediateDirectories: false) }
        guard outputRoot == outputRoot.resolvingSymlinksInPath().standardizedFileURL else { throw PersonalContentError.changedDocument }
        let stage = outputRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        var files: [RunOutputFile] = []
        for file in result.files {
            try await validate()
            guard !file.name.isEmpty, file.name == (file.name as NSString).lastPathComponent, file.name != ".", file.name != ".." else { throw PersonalContentError.invalidProject }
            let url = stage.appendingPathComponent(file.name)
            try await personalPreviewOffMain { try file.data.write(to: url, options: .withoutOverwriting) }
            let output = try await StudioResultPublication.publish(file: url, projectRoot: directory, action: action, fileKey: file.name, context: context, validateSource: validate)
            files.append(output.file)
        }
        try await validate()
        let inline = result.files.count == 1 && result.files[0].mimeType == "application/json" && result.files[0].data.count <= 48_000
            ? String(decoding: result.files[0].data, as: UTF8.self) : nil
        var output = try StudioToolOutput.make(Receipt(projectID: record.id, action: action, revision: String(source.project.revision), sourceSHA256: source.digest,
            summary: result.summary.merging(["files": String(files.count)], uniquingKeysWith: { _, new in new }),
            resultJSON: inline, limitations: result.limitations, openURL: "floe://work/" + record.id.uuidString.lowercased()))
        output.outputFiles = files
        return output
    }
    static func inspectFrame(record: PersonalContentRecord, directory: URL, inputJSON: String?, context: ToolContext,
        validateOwner: @escaping @MainActor @Sendable () async throws -> Void) async throws -> ToolExecutionOutput {
        guard !context.temporaryReadOnly else { throw PersonalContentError.invalidProject }
        let input = try options(inputJSON, allowed: ["expectedRevision", "boardID", "sheetID", "maximumPixelSize"])
        try context.cancellation.throwIfCancelled(); try await validateOwner()
        let saved = try await personalPreviewOffMain { try ElectronicsSavedSnapshot(id: record.id, directory: directory) }
        guard String(saved.project.revision) == input.revision else { throw PersonalContentError.changedDocument }
        guard input.object["boardID"] == nil || input.object["sheetID"] == nil else { throw FloeError.validationFailed("Choose one boardID or sheetID") }
        let selection: EDADocumentContext?
        if input.object["boardID"] != nil, let id = try board(input.object["boardID"], project: saved.project) { selection = .board(boardID: id) }
        else if let raw = input.object["sheetID"] {
            guard let text = raw as? String, let id = UUID(uuidString: text), saved.project.sheets.contains(where: { $0.id == id }) else { throw FloeError.validationFailed("inputJSON.sheetID is absent from this original") }
            selection = .schematic(sheetID: id)
        } else { selection = nil }
        let size = input.object["maximumPixelSize"] as? Int ?? 1_024
        guard (64...1_024).contains(size), input.object["maximumPixelSize"] == nil || input.object["maximumPixelSize"] is Int else { throw FloeError.validationFailed("maximumPixelSize must be 64...1024") }
        let bytes = try ElectronicsSnapshotRenderer.png(saved, context: selection, maximumPixelSize: size)
        try context.cancellation.throwIfCancelled(); try await validateOwner(); try saved.validate()
        let artifact = try await StudioResultPublication.imageArtifact(bytes, context: context)
        try context.cancellation.throwIfCancelled(); try await validateOwner(); try saved.validate()
        struct FrameReceipt: Encodable { let projectID: UUID; let revision: String; let sourceSHA256: String; let artifact: ToolArtifactReference; let semantics: String }
        var output = try StudioToolOutput.make(FrameReceipt(projectID: record.id, revision: String(saved.project.revision), sourceSHA256: saved.digest,
            artifact: artifact, semantics: "Actual saved 2D native schematic/PCB drawing, not a UI screenshot or fabrication/3D clearance proof."))
        output.artifacts = [artifact]
        return output
    }
    private nonisolated static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    private static func options(_ json: String?, allowed: Set<String>) throws -> (revision: String, object: [String: Any]) {
        guard let json, json.utf8.count <= 256 * 1_024,
              let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any], Set(object.keys).isSubset(of: allowed) else {
            throw FloeError.validationFailed("inputJSON requires expectedRevision and only this action's documented fields; no host paths")
        }
        let revision: String
        if let text = object["expectedRevision"] as? String { revision = text }
        else if let number = object["expectedRevision"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue >= 0,
                number.doubleValue <= 9_007_199_254_740_991, number.doubleValue == Double(number.int64Value) { revision = String(number.int64Value) }
        else { throw FloeError.validationFailed("inputJSON.expectedRevision must be the exact revision from studio.read, preferably a string") }
        guard revision.range(of: "^(0|[1-9][0-9]*)$", options: .regularExpression) != nil, UInt64(revision) != nil else { throw PersonalContentError.changedDocument }
        return (revision, object)
    }
    private static func board(_ raw: Any?, project: EDAProject) throws -> UUID? {
        guard let raw else { return project.boards.first?.id }
        guard let text = raw as? String, let id = UUID(uuidString: text), project.boards.contains(where: { $0.id == id }) else {
            throw FloeError.validationFailed("inputJSON.boardID is absent from this original")
        }
        return id
    }
}
#endif
