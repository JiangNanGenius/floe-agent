// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeTools
import FloeModels
import FloeChemistryCore

nonisolated struct ChemistryResultProvenance: Encodable, Sendable {
    let projectID: UUID
    let calculationID: UUID
    let objectID: UUID
    let inputRevision: String
    let inputDigest: String
    let method: String
    let options: JSONValue
    let environmentID: String
    let engineVersion: String
    let resultSHA256: String
    let calculationOwner: Owner?
    struct Owner: Encodable, Sendable {
        let taskID: UUID
        let hostRunID: UUID
        let callID: String?
        let attemptID: UUID?
    }
    init(projectID: UUID, run: ChemistryRun, resultSHA256: String, owner: ChemistryHostRunOwner? = nil) {
        self.projectID = projectID; calculationID = run.id; objectID = run.input.id
        inputRevision = String(run.input.revision); inputDigest = run.inputDigest
        method = run.method; options = run.options; environmentID = run.environmentID
        engineVersion = run.engineVersion; self.resultSHA256 = resultSHA256
        if let owner {
            calculationOwner = .init(taskID: owner.conversationID, hostRunID: owner.taskRunID, callID: owner.toolCallID, attemptID: nil)
        } else if let identity = run.externalExecution?.identity {
            calculationOwner = .init(taskID: identity.taskID, hostRunID: identity.hostRunID, callID: nil, attemptID: identity.attemptID)
        } else { calculationOwner = nil } // Legacy/UI runs never gain invented task/call ownership.
    }
}
nonisolated struct ChemistryResultPageReceipt: Encodable, Sendable {
    let provenance: ChemistryResultProvenance
    let page: ChemistryResultData.Page
    init(projectID: UUID, run: ChemistryRun, page: ChemistryResultData.Page, owner: ChemistryHostRunOwner? = nil) {
        provenance = .init(projectID: projectID, run: run, resultSHA256: page.resultSHA256, owner: owner); self.page = page
    }
}
nonisolated private struct ChemistryJSONResult: Encodable, Sendable {
    let format = "org.floe.chemistry.saved-result"
    let version = 1
    let provenance: ChemistryResultProvenance
    let result: JSONValue
}
nonisolated private struct ChemistryCSVProvenance: Encodable, Sendable {
    let format = "org.floe.chemistry.result-table"
    let version = 1
    let provenance: ChemistryResultProvenance
    let resultKey: String
    let columns: [String]
    let rowCount: Int
    let fileName: String
    let byteCount: Int
    let sha256: String
    let wholeResultIncluded = false
    let otherResultFields: [String]
    let valuePolicy = "Actual finite numeric cells only; null is an empty cell. No imputation, unit conversion or curve interpolation. Use the JSON export for the complete saved result."
}
nonisolated private struct ChemistryResultExportReceipt: Encodable, Sendable {
    let provenance: ChemistryResultProvenance
    let format: String
    let resultKey: String?
    let files: [File]
    struct File: Encodable, Sendable { let name: String; let byteCount: Int; let sha256: String }
}

nonisolated struct ChemistryPreparedExport: Sendable {
    struct File: Sendable { let name: String; let data: Data; let sha256: String }
    let files: [File]
    let receipt: Data
}
nonisolated enum ChemistryResultPreparation {
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func export(projectID: UUID, run: ChemistryRun, owner: ChemistryHostRunOwner?, format: String,
                       resultKey: String?, expectedSHA256: String?,
                       checkCancellation: @Sendable () throws -> Void) throws -> ChemistryPreparedExport {
        try checkCancellation()
        guard let result = run.result else { throw ChemistryError.invalid("No saved calculation result.") }
        let snapshot = try ChemistryResultData.snapshot(result)
        if let expectedSHA256, expectedSHA256 != snapshot.sha256 { throw ChemistryError.invalid("The saved result changed.") }
        let source = ChemistryResultProvenance(projectID: projectID, run: run, resultSHA256: snapshot.sha256, owner: owner)
        let stem = "Chemistry-" + source.calculationID.uuidString.lowercased()
        var files: [(name: String, data: Data)]
        if format == "json" {
            guard resultKey == nil else { throw ChemistryError.invalid("JSON exports the complete saved result; omit resultKey.") }
            files = [(stem + ".json", try encode(ChemistryJSONResult(provenance: source, result: result)))]
        } else {
            guard let key = resultKey else { throw ChemistryError.invalid("CSV requires an exact numeric resultKey.") }
            let table = try ChemistryResultData.numericCSV(result, resultKey: key, checkCancellation: checkCancellation)
            let name = stem + "-" + ChemistryProjectStore.digest(Data(key.utf8)) + ".csv"
            let manifest = ChemistryCSVProvenance(provenance: source, resultKey: key, columns: table.columns,
                rowCount: table.rowCount, fileName: name, byteCount: table.csv.count, sha256: ChemistryProjectStore.digest(table.csv),
                otherResultFields: snapshot.fields.map(\.key).filter { $0 != key })
            files = [(name, table.csv), (stem + "-provenance.json", try encode(manifest))]
        }
        guard files.allSatisfy({ !$0.data.isEmpty && $0.data.count <= ChemistryResultData.maximumResultBytes + 64 * 1_024 }) else {
            throw ChemistryError.invalid("Result export exceeds its byte budget.")
        }
        let prepared = try files.map { file -> ChemistryPreparedExport.File in
            try checkCancellation()
            return .init(name: file.name, data: file.data, sha256: ChemistryProjectStore.digest(file.data))
        }
        let metadata = prepared.map { ChemistryResultExportReceipt.File(name: $0.name, byteCount: $0.data.count, sha256: $0.sha256) }
        let receipt = try encode(ChemistryResultExportReceipt(provenance: source, format: format, resultKey: resultKey, files: metadata))
        guard receipt.count <= 96 * 1_024 else { throw ChemistryError.invalid("Read a smaller page of this result.") }
        try checkCancellation()
        return .init(files: prepared, receipt: receipt)
    }
}

extension ChemistryProjectSession {
    func exportSavedResult(_ run: ChemistryRun, input: ChemistryNativeInput, context: ToolContext) async throws -> ToolExecutionOutput {
        guard !closing, run.status == .succeeded, run.result != nil, let format = input.format,
              ["json", "csv"].contains(format) else { throw PersonalContentError.invalidProject }
        guard try await service.savedResultMatchesForExport(projectID, run: run) else { throw PersonalContentError.changedDocument }
        let id = projectID, owner = savedRunOwner(run.id)
        let key = input.resultKey, expected = input.expectedResultSHA256, token = context.cancellation
        let prepared = try await personalPreviewOffMain {
            try ChemistryResultPreparation.export(projectID: id, run: run, owner: owner, format: format,
                resultKey: key, expectedSHA256: expected,
                checkCancellation: { try token.throwIfCancelled(); try Task.checkCancellation() })
        }
        let files = prepared.files
        let validate: @MainActor @Sendable () async throws -> Void = { [self] in
            try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
            guard !closing else { throw PersonalContentError.changedDocument }
            let matches = try await service.savedResultMatchesForExport(projectID, run: run)
            try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
            guard !closing, matches else { throw PersonalContentError.changedDocument }
        }
        try await validate()
        // The verified Chemistry folder belongs to this exact personal original.
        // Refuse aliased ancestors/directories, rather than stage outside it.
        let base = root.standardizedFileURL
        guard base == base.resolvingSymlinksInPath() else { throw PersonalContentError.changedDocument }
        var parent = base
        for part in ["Chemistry", "ResultExports"] {
            parent.appendPathComponent(part, isDirectory: true)
            if FileManager.default.fileExists(atPath: parent.path) {
                let values = try parent.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard values.isDirectory == true, values.isSymbolicLink != true else { throw PersonalContentError.changedDocument }
            } else { try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false) }
            guard parent == parent.resolvingSymlinksInPath().standardizedFileURL else { throw PersonalContentError.changedDocument }
        }
        let stage = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: stage) }
        var published: [RunOutputFile] = []
        for file in files {
            try await validate()
            let url = stage.appendingPathComponent(file.name)
            try await personalPreviewOffMain { try file.data.write(to: url, options: .withoutOverwriting) }
            published.append(try await StudioResultPublication.publish(file: url, projectRoot: base,
                action: "chemistry-result", fileKey: file.name, context: context, validateSource: validate).file)
        }
        try await validate()
        var output = ToolExecutionOutput(digesting: String(decoding: prepared.receipt, as: UTF8.self), exitStatus: 0)
        output.outputFiles = published
        return output
    }
}
#endif
