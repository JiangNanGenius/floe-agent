// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeTools
import FloeModels
import FloeChemistryCore

struct ChemistryResultProvenance: Encodable {
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
    struct Owner: Encodable {
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
struct ChemistryResultPageReceipt: Encodable {
    let provenance: ChemistryResultProvenance
    let page: ChemistryResultData.Page
    init(projectID: UUID, run: ChemistryRun, page: ChemistryResultData.Page, owner: ChemistryHostRunOwner? = nil) {
        provenance = .init(projectID: projectID, run: run, resultSHA256: page.resultSHA256, owner: owner); self.page = page
    }
}
private struct ChemistryJSONResult: Encodable {
    let format = "org.floe.chemistry.saved-result"
    let version = 1
    let provenance: ChemistryResultProvenance
    let result: JSONValue
}
private struct ChemistryCSVProvenance: Encodable {
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
private struct ChemistryResultExportReceipt: Encodable {
    let provenance: ChemistryResultProvenance
    let format: String
    let resultKey: String?
    let files: [File]
    struct File: Encodable { let name: String; let byteCount: Int; let sha256: String }
}

extension ChemistryProjectSession {
    func exportSavedResult(_ run: ChemistryRun, input: ChemistryNativeInput, context: ToolContext) async throws -> ToolExecutionOutput {
        guard !closing, run.status == .succeeded, let result = run.result, let format = input.format,
              ["json", "csv"].contains(format) else { throw PersonalContentError.invalidProject }
        guard try await service.savedResultForExport(projectID, runID: run.id) == run else { throw PersonalContentError.changedDocument }
        let snapshot = try ChemistryResultData.snapshot(result)
        if let expected = input.expectedResultSHA256, expected != snapshot.sha256 { throw PersonalContentError.changedDocument }
        let provenance = ChemistryResultProvenance(projectID: projectID, run: run, resultSHA256: snapshot.sha256, owner: savedRunOwner(run.id))
        var files: [(name: String, data: Data)] = []
        let stem = "Chemistry-" + run.id.uuidString.lowercased()
        if format == "json" {
            guard input.resultKey == nil else { throw FloeError.validationFailed("JSON exports the complete saved result; omit resultKey.") }
            let data = try StudioToolOutput.data(ChemistryJSONResult(provenance: provenance, result: result))
            files = [(stem + ".json", data)]
        } else {
            guard let key = input.resultKey else { throw FloeError.validationFailed("CSV requires an exact numeric resultKey from resultFields.") }
            let table = try ChemistryResultData.numericCSV(result, resultKey: key) { try context.cancellation.throwIfCancelled(); try Task.checkCancellation() }
            let name = stem + "-" + StudioToolOutput.hash(Data(key.utf8)) + ".csv"
            let manifest = ChemistryCSVProvenance(provenance: provenance, resultKey: key, columns: table.columns,
                rowCount: table.rowCount, fileName: name, byteCount: table.csv.count, sha256: StudioToolOutput.hash(table.csv),
                otherResultFields: snapshot.fields.map(\.key).filter { $0 != key })
            files = [(name, table.csv), (stem + "-provenance.json", try StudioToolOutput.data(manifest))]
        }
        guard files.allSatisfy({ !$0.data.isEmpty && $0.data.count <= ChemistryResultData.maximumResultBytes + 64 * 1_024 }) else {
            throw FloeError.validationFailed("Result export exceeds its byte budget.")
        }
        let validate: @MainActor @Sendable () async throws -> Void = { [self] in
            try context.cancellation.throwIfCancelled(); try Task.checkCancellation()
            guard !closing else { throw PersonalContentError.changedDocument }
            let current = try await service.savedResultForExport(projectID, runID: run.id)
            guard current == run else { throw PersonalContentError.changedDocument }
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
        let metadata = files.map { ChemistryResultExportReceipt.File(name: $0.name, byteCount: $0.data.count, sha256: StudioToolOutput.hash($0.data)) }
        var output = try StudioToolOutput.make(ChemistryResultExportReceipt(provenance: provenance, format: format,
            resultKey: input.resultKey, files: metadata))
        output.outputFiles = published
        return output
    }
}
#endif
