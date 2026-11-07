// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Darwin
import FloeTools
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

    /// The resolved personal-work owner and file-use lease are supplied by the
    /// coordinator. This reads only the cell archive, never a default example.
    static func savedCellInspection(cadURL:URL, projectDirectory:URL, ownerID:UUID,
                                    cancellation:CancellationToken) async throws -> CADManufacturingCellInspection {
        let operation = Task.detached(priority:.userInitiated) {
            try CADSavedManufacturingCellReader.inspect(cadURL:cadURL,projectDirectory:projectDirectory,
                                                       ownerID:ownerID,cancellation:cancellation)
        }
        return try await withTaskCancellationHandler(operation:{ try await operation.value },onCancel:{ operation.cancel() })
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

/// A cell is an independent saved program in this CAD work's companion. Its
/// schedule/material results do not imply the ordinary CAM study was computed
/// or that the cell program uses the current CAD geometry.
struct CADManufacturingCellInspection:Codable,Sendable {
    enum Status:String,Codable,Sendable { case none, saved }
    struct RemainingWorkpiece:Codable,Sendable {
        let workpieceID:String
        let remainingVolumeMM3:Double
    }
    struct SavedResult:Codable,Sendable {
        let cellProjectID:UUID
        let name:String
        let inputSHA256:String
        let archiveSHA256:String
        let archiveByteCount:Int
        let scheduleTotalSeconds:Double
        let computedOperationCount:Int
        let transferRecordCount:Int
        let remainingWorkpieces:[RemainingWorkpiece]
        let calculationElapsedSeconds:Double
    }
    let family:String
    let ownerCADProjectID:UUID
    let status:Status
    let savedResult:SavedResult?
}

/// Descriptor-relative reads prevent a replaced cell path or symbolic link
/// from selecting another work. The service's existing shared storage lease
/// also fences supported CAD/companion transfers during validation.
private enum CADSavedManufacturingCellReader {
    static func inspect(cadURL:URL,projectDirectory:URL,ownerID:UUID,
                        cancellation:CancellationToken) throws -> CADManufacturingCellInspection {
        func checkCancellation() throws { try Task.checkCancellation(); try cancellation.throwIfCancelled() }
        func none() throws -> CADManufacturingCellInspection {
            try checkCancellation()
            return .init(family:"manufacturingCell",ownerCADProjectID:ownerID,status:.none,savedResult:nil)
        }
        try checkCancellation()
        let root = Darwin.open(projectDirectory.path,O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard root >= 0 else { throw ManufacturingError.stale }
        defer { Darwin.close(root) }
        let rootIdentity = try status(root,directory:true)
        guard let manufacturing = try openDirectory(root,"Manufacturing") else { return try none() }
        defer { Darwin.close(manufacturing) }
        let manufacturingIdentity = try status(manufacturing,directory:true)
        guard let cell = try openDirectory(manufacturing,"cell") else { return try none() }
        defer { Darwin.close(cell) }
        let cellIdentity = try status(cell,directory:true)
        let file = openat(cell,"latest.floecell",O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if file < 0, errno == ENOENT { return try none() }
        guard file >= 0 else { throw ManufacturingError.archive("Saved manufacturing cell cannot be opened without following links") }
        defer { Darwin.close(file) }
        let before = try status(file,directory:false)
        guard before.st_size >= 0, before.st_size <= ResearchArchive.byteLimit else {
            throw ManufacturingError.archive("Saved manufacturing cell exceeds the inspection byte budget")
        }
        let directory = projectDirectory.appendingPathComponent("Manufacturing",isDirectory:true)
        let storageLease = try CADMachiningCompanion.storageLease(cadURL:cadURL,directory:directory)
        defer { withExtendedLifetime(storageLease) {} }
        let generation = try CADMachiningCompanion.locationGeneration(directory:directory)
        var bytes = Data(); bytes.reserveCapacity(Int(before.st_size))
        var buffer = [UInt8](repeating:0,count:64 * 1_024)
        while true {
            try checkCancellation()
            let count = buffer.withUnsafeMutableBytes { Darwin.read(file,$0.baseAddress!,$0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw ManufacturingError.archive("Saved manufacturing cell could not be read") }
            if count == 0 { break }
            guard bytes.count <= ResearchArchive.byteLimit - count else {
                throw ManufacturingError.archive("Saved manufacturing cell grew beyond the inspection byte budget")
            }
            bytes.append(contentsOf:buffer.prefix(count))
        }
        try verify()
        let (project,artifact) = try ManufacturingCellArchive.open(data:bytes)
        try checkCancellation()
        let result = CADManufacturingCellInspection.SavedResult(cellProjectID:project.id,name:project.cell.name,
            inputSHA256:artifact.inputSHA256,archiveSHA256:ManufacturingStudy.digest(bytes),archiveByteCount:bytes.count,
            scheduleTotalSeconds:artifact.schedule.totalSeconds,computedOperationCount:artifact.jobs.count,
            transferRecordCount:artifact.schedule.transfers.count,
            remainingWorkpieces:artifact.finalStock.keys.sorted().map {
                .init(workpieceID:$0,remainingVolumeMM3:artifact.finalStock[$0]!.remainingMM3)
            },calculationElapsedSeconds:artifact.elapsedSeconds)
        try verify()
        return .init(family:"manufacturingCell",ownerCADProjectID:ownerID,status:.saved,savedResult:result)

        func verify() throws {
            try checkCancellation()
            let after = try status(file,directory:false)
            guard sameFile(before,after), bytes.count == after.st_size,
                  sameFile(after,try namedStatus(cell,"latest.floecell")),
                  sameIdentity(rootIdentity,try namedStatus(AT_FDCWD,projectDirectory.path)),
                  sameIdentity(manufacturingIdentity,try namedStatus(root,"Manufacturing")),
                  sameIdentity(cellIdentity,try namedStatus(manufacturing,"cell")),
                  try CADMachiningCompanion.locationGeneration(directory:directory) == generation else {
                throw ManufacturingError.stale
            }
        }
    }
    private static func openDirectory(_ parent:Int32,_ name:String) throws -> Int32? {
        let descriptor = openat(parent,name,O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw ManufacturingError.archive("Saved manufacturing cell directory is not a regular owned directory") }
        return descriptor
    }
    private static func status(_ descriptor:Int32,directory:Bool) throws -> stat {
        var value = stat()
        guard fstat(descriptor,&value) == 0,
              value.st_mode & S_IFMT == (directory ? S_IFDIR:S_IFREG) else {
            throw ManufacturingError.archive("Saved manufacturing cell source has an invalid file type")
        }
        return value
    }
    private static func namedStatus(_ parent:Int32,_ name:String) throws -> stat {
        var value = stat()
        guard fstatat(parent,name,&value,AT_SYMLINK_NOFOLLOW) == 0 else { throw ManufacturingError.stale }
        return value
    }
    private static func sameIdentity(_ a:stat,_ b:stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && (a.st_mode & S_IFMT) == (b.st_mode & S_IFMT)
    }
    private static func sameFile(_ a:stat,_ b:stat) -> Bool {
        sameIdentity(a,b) && a.st_size == b.st_size &&
        a.st_mtimespec.tv_sec == b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec == b.st_mtimespec.tv_nsec &&
        a.st_ctimespec.tv_sec == b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec == b.st_ctimespec.tv_nsec
    }
}
#endif
