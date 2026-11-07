// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCAD
import FloeManufacturingCore
import FloeManufacturingUI
import FloeWorkspace

private struct CADManufacturingHandoffError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Calculation state outlives an individual editor presentation. Every
/// window opening this same project observes the same native service model.
@MainActor enum ManufacturingSessions {
    private static var models: [UUID: ManufacturingModel] = [:]
    static func requireIdleForDeletion(id: UUID) throws {
        guard models[id]?.isBusy != true else { throw PersonalFileActionError.busy }
    }

    private static var cadModels: [URL: ManufacturingModel] = [:]
    private static var cadGenerations: [URL: Data] = [:]
    private static var openingCAD: Set<URL> = []
    static func open(id: UUID, directory: URL) -> ManufacturingModel {
        if let value = models[id] { return value }
        let value = ManufacturingModel(directory: directory)
        models[id] = value
        return value
    }

    /// Both CAD hosts and task tools resolve the same process-owned model.
    /// The first job contains the actual CAD mesh, never the shaft sample.
    static func openCAD(document: FloeCADDocument, directory: URL, ownerID: UUID? = nil) async throws -> ManufacturingModel {
        let key = directory.standardizedFileURL
        if let existing = try readExistingCAD(document: document, directory: key, ownerID: ownerID) { return existing }
        guard openingCAD.insert(key).inserted else { throw PersonalFileActionError.busy }
        defer { openingCAD.remove(key) }
        let initial = try await captureCAD(document, ownerID: ownerID)
        let value = ManufacturingModel(directory: key, initialStudy: initial)
        try installStorageLease(value, cadURL: document.url)
        cadModels[key] = value
        return value
    }

    static func prepareForCADMove(directory: URL) throws {
        let key = directory.standardizedFileURL
        guard !openingCAD.contains(key), cadModels[key]?.isBusy != true else { throw PersonalFileActionError.busy }
        cadModels.removeValue(forKey: key)
        cadGenerations.removeValue(forKey:key)
    }

    /// Read-only discovery for the CAD assistant. Missing work never creates a
    /// draft or a sample. Corrupt documents are reported rather than replaced.
    static func readExistingCAD(document: FloeCADDocument, directory: URL, ownerID: UUID? = nil) throws -> ManufacturingModel? {
        let key = directory.standardizedFileURL
        if let value = cadModels[key] {
            if cadGenerations[key] != (try CADMachiningCompanion.locationGeneration(directory:key)) {
                guard !value.isBusy else { throw ManufacturingError.stale }
                cadModels.removeValue(forKey:key); cadGenerations.removeValue(forKey:key)
            } else {
            if let ownerID, value.study.source.documentID != "cad:" + ownerID.uuidString.lowercased() { throw ManufacturingError.stale }
            return value
            }
        }
        let draft = key.appendingPathComponent("draft.json"), archive = key.appendingPathComponent("latest.floemanufacturing")
        let initial: ManufacturingStudy
        if FileManager.default.fileExists(atPath: draft.path) {
            let size = try draft.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? Int.max
            guard size <= 32_000_000 else { throw ManufacturingError.invalid("draft file budget") }
            initial = try JSONDecoder().decode(ManufacturingStudy.self, from: Data(contentsOf: draft))
            try initial.validate(requireOperations: false)
        } else if FileManager.default.fileExists(atPath: archive.path) {
            initial = try ManufacturingArchive.open(archive).0
        } else { return nil }
        if let ownerID {
            guard initial.source.documentID == "cad:" + ownerID.uuidString.lowercased() else { throw ManufacturingError.stale }
        } else {
            guard initial.source.documentID.hasPrefix("cad:") else { throw ManufacturingError.stale }
        }
        let value = ManufacturingModel(directory: key, initialStudy: initial)
        try installStorageLease(value, cadURL: document.url)
        cadModels[key] = value
        return value
    }

    private static func installStorageLease(_ model:ManufacturingModel,cadURL:URL) throws {
        let directory = model.directory
        let generation = try CADMachiningCompanion.locationGeneration(directory:directory)
        cadGenerations[directory.standardizedFileURL] = generation
        model.storageLeaseProvider = {
            let lease = try CADMachiningCompanion.storageLease(cadURL:cadURL,directory:directory)
            guard try CADMachiningCompanion.locationGeneration(directory:directory) == generation else { throw ManufacturingError.stale }
            return lease
        }
    }

    static func refreshCAD(document: FloeCADDocument, model: ManufacturingModel, ownerID: UUID? = nil) async throws {
        guard !model.isBusy else { throw ManufacturingError.invalid(IDELanguageRunText.t("请先停止当前计算。", "Stop the current calculation first.")) }
        let expected = try model.study.fingerprint()
        let captured = try await captureCAD(document, ownerID: ownerID, existingSourceID: model.study.source.documentID)
        var fresh = model.study
        fresh.source = captured.source; fresh.profile = captured.profile
        if fresh.cam == nil { fresh.cam = captured.cam }
        else { fresh.cam?.partMesh = captured.cam?.partMesh }
        try model.replaceStudy(fresh, expectedFingerprint: expected)
    }

    static func validateCADSource(document: FloeCADDocument, model: ManufacturingModel, ownerID: UUID? = nil) async throws {
        let fresh = try await captureCAD(document, ownerID: ownerID, existingSourceID: model.study.source.documentID)
        guard fresh.source.documentID == model.study.source.documentID,
              fresh.source.contentSHA256 == model.study.source.contentSHA256 else { throw ManufacturingError.stale }
    }

    private static func captureCAD(_ document: FloeCADDocument, ownerID: UUID?, existingSourceID: String? = nil) async throws -> ManufacturingStudy {
        guard !document.isClosed else { throw ManufacturingError.stale }
        let revision = document.revision, changes = document.exchangeChangeCount, content = document.contentSHA256
        let data: Data
        switch document.nativePrintGeometrySnapshot(expectedRevision: revision, expectedChangeCount: changes, expectedContentSHA256: content) {
        case .success(let bytes, _, let coverage):
            guard coverage.includedCount > 0, coverage.excludedCount == 0 else { throw CADManufacturingHandoffError(message: IDELanguageRunText.t("请先补齐模型中无法转换的零件。", "Resolve parts that cannot be converted before machining.")) }
            data = bytes
        case .failure(let error):
            if error.code == "empty_selection" {
                throw CADManufacturingHandoffError(message: IDELanguageRunText.t("先在 CAD 中添加实体，再重新准备模型。", "Add a solid in CAD, then prepare the model again."))
            }
            throw error
        case .coverageRequired, .coverage:
            throw CADManufacturingHandoffError(message: IDELanguageRunText.t("加工需要完整模型。请检查模型中的零件后重试。", "Machining needs the complete model. Check the document's parts and try again."))
        }
        let name = document.name
        let emptyModelMessage = IDELanguageRunText.t("当前模型没有立体厚度，请先完成实体建模。", "The model has no 3D thickness. Finish the solid model first.")
        let sourceID = ownerID.map { "cad:" + $0.uuidString.lowercased() } ?? existingSourceID ?? ("cad:" + UUID().uuidString.lowercased())
        let result = try await Task.detached(priority: .userInitiated) {
            let imported = try ManufacturingMeshImport.read(data, extension: "stl")
            let vertices = imported.mesh.vertices
            var lo = [Double](repeating: .infinity, count: 3), hi = [Double](repeating: -.infinity, count: 3)
            for point in vertices { for axis in 0..<3 { lo[axis] = min(lo[axis], point[axis]); hi[axis] = max(hi[axis], point[axis]) } }
            guard zip(lo, hi).allSatisfy({ $0.0 < $0.1 }) else { throw ManufacturingError.invalid(emptyModelMessage) }
            var envelope: [Double: Double] = [:]
            for p in vertices { envelope[p[2]] = max(envelope[p[2]] ?? 0, hypot(p[0], p[1])) }
            let levels = envelope.keys.sorted()
            let stride = max(1, Int(ceil(Double(levels.count)/254)))
            var sampled = levels.enumerated().filter { $0.offset % stride == 0 }.map(\.element)
            if sampled.last != levels.last, let last = levels.last { sampled.append(last) }
            let profile = sampled.map { ProfilePoint(envelope[$0] ?? 0, $0) }
            var study = ManufacturingStudy(name: name, source: .init(documentID: sourceID, revision: revision,
                contentSHA256: imported.contentSHA256), profile: profile)
            study.turning.enabled = false; study.milling.enabled = false; study.fixtures = []
            study.stock.shape = "box"; study.stock.minMM = lo; study.stock.maxMM = hi
            study.stock.zMinMM = lo[2]; study.stock.zMaxMM = hi[2]
            study.stock.radiusMM = max(0.1, vertices.map { hypot($0[0], $0[1]) }.max() ?? 0.1)
            var resolution = max(0.1, min(4, pow(zip(lo, hi).reduce(1.0) { $0 * ($1.1 - $1.0) } / 65_536, 1.0/3.0)))
            while zip(lo, hi).reduce(1.0, { $0 * (ceil(($1.1-$1.0)/resolution)+1) }) > Double(study.budget.maxCells), resolution < 4 { resolution = min(4, resolution * 1.1) }
            study.stock.resolutionMM = resolution
            study.cam = .init(tools: [], operations: [], partMesh: imported.mesh)
            try study.validate(requireOperations: false)
            return study
        }.value
        try Task.checkCancellation()
        guard !document.isClosed, document.revision == revision, document.exchangeChangeCount == changes, document.contentSHA256 == content else { throw ManufacturingError.stale }
        return result
    }
}
#endif
