// SPDX-License-Identifier: MPL-2.0
import Foundation
import ImageIO
import FloeCAD
import FloeCore
import FloeEnvironments
import FloeExecution
import FloeModels
import FloePersistence
import FloeTools
import FloeWorkbench

struct CADOfflineRenderOperation: Codable, Identifiable, Sendable {
    enum State: String, Codable, Sendable { case preparing, rendering, ready, cancelling, cancelled, failed, interrupted }
    var id: UUID
    var documentURL: URL
    var workspaceRoot: URL
    var conversationID: UUID
    var environmentID: String
    var runID: UUID
    var jobID: UUID?
    var relativeDirectory: String
    var payload: Data
    var settings: CADOfflineRenderSettings
    var revision: Int
    var changeCount: Int
    var sourceSHA256: String
    var inputHashes: [String: String]
    var warnings: [String]
    var state: State
    var error: String?
    var imageSHA256: String?
    var createdAt: Date
    var isRunning: Bool { [.preparing, .rendering, .cancelling].contains(state) }
}

@MainActor
final class CADOfflineRenderCenter {
    weak var environment: AppEnvironment?
    init(environment: AppEnvironment) { self.environment = environment }
    private func storeRoot() throws -> URL {
        let root = try FloeArtifactStore.root().appendingPathComponent("JobDownloads/CADOfflineRender", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func operationDirectory(_ id: UUID) throws -> URL {
        let directory = try storeRoot().appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func save(_ operation: CADOfflineRenderOperation) throws {
        try JSONEncoder().encode(operation).write(to: operationDirectory(operation.id).appendingPathComponent("operation.json"), options: .atomic)
    }
    func operation(_ id: UUID) throws -> CADOfflineRenderOperation {
        try JSONDecoder().decode(CADOfflineRenderOperation.self,
            from: Data(contentsOf: operationDirectory(id).appendingPathComponent("operation.json")))
    }
    func latest(documentURL: URL, conversationID: UUID, workspaceRoot: URL) -> CADOfflineRenderOperation? {
        guard let root = try? storeRoot(), let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        return urls.compactMap { url -> CADOfflineRenderOperation? in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            return try? operation(id)
        }.filter { $0.documentURL == documentURL.standardizedFileURL.resolvingSymlinksInPath()
            && $0.conversationID == conversationID && $0.workspaceRoot == workspaceRoot.standardizedFileURL.resolvingSymlinksInPath() }
            .max { $0.createdAt < $1.createdAt }
    }
    func imageURL(_ operation: CADOfflineRenderOperation) throws -> URL? {
        guard operation.state == .ready, let expected = operation.imageSHA256 else { return nil }
        let url = try operationDirectory(operation.id).appendingPathComponent("render.png")
        guard FloeDigest.sha256Hex(try Self.checkedFile(url, root: operationDirectory(operation.id), limit: 64 * 1024 * 1024)) == expected else {
            throw FloeError.validationFailed("The saved render image has changed.")
        }
        return url
    }

    /// Explicit native UI action. Source snapshot and result receipt are
    /// immutable; the existing jobs service owns execution after this returns.
    func startFromUI(document: FloeCADDocument, settings: CADOfflineRenderSettings,
                     workspaceRoot: URL, workspaceID: UUID, conversationID: UUID) async throws -> CADOfflineRenderOperation {
        guard let environment, let jobs = environment.backgroundJobService else { throw FloeError.validationFailed("Background jobs are unavailable.") }
        let owners = try await SQLiteWorkspaceStore(database: environment.database).conversations(workspaceID: workspaceID)
        guard owners.contains(conversationID),
              let binding = try await TaskExecutionBindingStore(database: environment.database).binding(conversationID: conversationID),
              let record = await environment.environmentRegistry.record(id: binding.target.environmentID), record.state == .active,
              record.effectiveExecutionBackend != .native else {
            throw FloeError.validationFailed("Select an available execution environment for this task before rendering.")
        }
        let root = workspaceRoot.standardizedFileURL.resolvingSymlinksInPath()
        if let existing = latest(documentURL: document.url, conversationID: conversationID, workspaceRoot: root), existing.isRunning {
            let current = try await refresh(existing.id)
            guard !current.isRunning else { return current }
        }
        let package = try await document.prepareOfflineRender(settings: settings)
        try Task.checkCancellation()
        let id = UUID(), runID = UUID(), relative = "Renders/\(id.uuidString)"
        let directory = root.appendingPathComponent(relative, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: directory.path), directory.standardizedFileURL == directory.resolvingSymlinksInPath().standardizedFileURL else { throw FloeError.unauthorized }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var files = package.files
        files["install.sh"] = Data(CADOfflineRenderCommands.install.utf8)
        files["render.sh"] = Data(CADOfflineRenderCommands.render.utf8)
        for (name, bytes) in files {
            let target = directory.appendingPathComponent(name)
            guard target.standardizedFileURL.path.hasPrefix(directory.path + "/"),
                  target.standardizedFileURL == target.resolvingSymlinksInPath().standardizedFileURL else { throw FloeError.unauthorized }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: target, options: .atomic)
        }
        let payload = try CADOfflineRenderCommands.payload(script: "set -eu\nsh install.sh\nsh render.sh\n", directory: relative)
        var operation = CADOfflineRenderOperation(id: id, documentURL: document.url.standardizedFileURL.resolvingSymlinksInPath(),
            workspaceRoot: root, conversationID: conversationID, environmentID: binding.target.environmentID,
            runID: runID, relativeDirectory: relative, payload: payload, settings: settings,
            revision: package.revision, changeCount: package.changeCount, sourceSHA256: package.sourceSHA256,
            inputHashes: files.mapValues(FloeDigest.sha256Hex), warnings: package.warnings, state: .preparing, createdAt: Date())
        try save(operation)
        try await environment.runStore.saveRun(RunRecord(id: runID, conversationID: conversationID,
            state: "completed", goal: "Offline CAD render", startedAt: Date(), endedAt: Date(), executionBinding: binding))
        do {
            let job = try await jobs.submit(runID: runID, toolCallID: nil, targetTool: "exec.shell", payloadJSON: payload,
                scope: .local, workspaceRootURL: root, allowedWorkspacePaths: [], environmentID: binding.target.environmentID,
                allowedToolNames: ["exec.shell"], submissionSource: .nativeService)
            operation.jobID = job.id; operation.state = .rendering; try save(operation)
        } catch {
            operation.state = .failed; operation.error = error.localizedDescription; try save(operation); throw error
        }
        return operation
    }

    /// Cold reopen observes the original durable job. It never replays it.
    func refresh(_ id: UUID) async throws -> CADOfflineRenderOperation {
        var operation = try operation(id)
        guard operation.isRunning else { return operation }
        guard let jobs = environment?.backgroundJobService, let jobID = operation.jobID else {
            operation.state = .interrupted; operation.error = "Preparation was interrupted. Start a new render."; try save(operation); return operation
        }
        let job = try await jobs.ownedJob(id: jobID, runID: operation.runID)
        operation = try self.operation(id)
        guard job.conversationID == operation.conversationID, job.environmentID == operation.environmentID,
              job.targetTool == "exec.shell", job.payloadJSON == operation.payload,
              job.workspaceRootPath.map({ URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }) == operation.workspaceRoot else { throw FloeError.unauthorized }
        guard job.state.isTerminal else { return operation }
        if operation.state == .cancelling || job.state == .cancelled {
            operation.state = .cancelled
        } else if job.state == .interrupted {
            operation.state = .interrupted; operation.error = job.lastError
        } else if job.state == .failed {
            operation.state = .failed; operation.error = job.lastError ?? "Rendering failed. Inspect the task's saved job output."
        } else if job.state == .completed {
            do {
                let frozen = operation, archive = try operationDirectory(id)
                let worker = Task.detached(priority: .userInitiated) { try Self.verifyAndArchive(frozen, archive: archive) }
                let hash = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                operation = try self.operation(id)
                guard operation.state != .cancelling, operation.state != .cancelled else { return operation }
                operation.imageSHA256 = hash; operation.state = .ready
            } catch is CancellationError { throw CancellationError() }
            catch { operation.state = .failed; operation.error = error.localizedDescription }
        }
        try save(operation); return operation
    }
    func cancel(_ id: UUID) async throws -> CADOfflineRenderOperation {
        var operation = try operation(id)
        guard operation.isRunning else { return operation }
        operation.state = .cancelling; try save(operation)
        if let jobs = environment?.backgroundJobService, let jobID = operation.jobID {
            _ = try await jobs.cancel(id: jobID)
            return try await refresh(id)
        }
        operation.state = .cancelled; try save(operation); return operation
    }
    nonisolated static func verifyAndArchive(_ operation: CADOfflineRenderOperation, archive: URL) throws -> String {
        let directory = operation.workspaceRoot.appendingPathComponent(operation.relativeDirectory, isDirectory: true)
        for (name, hash) in operation.inputHashes {
            try Task.checkCancellation()
            guard FloeDigest.sha256Hex(try checkedFile(directory.appendingPathComponent(name), root: directory,
                limit: CADPBRTSceneExporter.maximumPackageBytes)) == hash else { throw FloeError.validationFailed("The prepared render inputs have changed.") }
        }
        let manifestBytes = try checkedFile(directory.appendingPathComponent("result.json"), root: directory, limit: 4096)
        guard let manifest = try JSONSerialization.jsonObject(with: manifestBytes) as? [String: String],
              manifest["backend"] == "pbrt-v4", manifest["revision"] == CADOfflineRenderCommands.revision,
              manifest["sceneSHA256"] == operation.inputHashes["scene.pbrt"] else { throw FloeError.validationFailed("The renderer returned an invalid scene receipt.") }
        let png = try checkedFile(directory.appendingPathComponent("render.png"), root: directory, limit: 64 * 1024 * 1024)
        let hash = FloeDigest.sha256Hex(png)
        guard manifest["imageSHA256"] == hash, png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
              let source = CGImageSourceCreateWithData(png as CFData, nil), CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary) as? [CFString: Any],
              (properties[kCGImagePropertyPixelWidth] as? Int) == operation.settings.width,
              (properties[kCGImagePropertyPixelHeight] as? Int) == operation.settings.height,
              let decoded = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCache: false] as CFDictionary),
              decoded.width == operation.settings.width, decoded.height == operation.settings.height else {
            throw FloeError.validationFailed("The renderer did not return a complete image at the requested size.")
        }
        try Task.checkCancellation()
        let imageTarget = archive.appendingPathComponent("render.png"), receiptTarget = archive.appendingPathComponent("result.json")
        guard imageTarget.standardizedFileURL == imageTarget.resolvingSymlinksInPath().standardizedFileURL,
              receiptTarget.standardizedFileURL == receiptTarget.resolvingSymlinksInPath().standardizedFileURL else { throw FloeError.unauthorized }
        try png.write(to: imageTarget, options: .atomic)
        try manifestBytes.write(to: receiptTarget, options: .atomic)
        return hash
    }
    nonisolated private static func checkedFile(_ url: URL, root: URL, limit: Int) throws -> Data {
        let path = url.standardizedFileURL, base = root.standardizedFileURL.resolvingSymlinksInPath()
        guard path.path.hasPrefix(base.path + "/"), path == path.resolvingSymlinksInPath(),
              let size = try FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber,
              size.intValue > 0, size.intValue <= limit else { throw FloeError.validationFailed("A render output is missing or too large.") }
        let bytes = try Data(contentsOf: path)
        guard bytes.count == size.intValue else { throw FloeError.validationFailed("The render output changed while it was being read.") }
        return bytes
    }
}

@MainActor
private enum CADOfflineRenderCenters {
    static var values: [ObjectIdentifier: CADOfflineRenderCenter] = [:]
    static func get(_ environment: AppEnvironment) -> CADOfflineRenderCenter {
        values = values.filter { $0.value.environment != nil }
        let id = ObjectIdentifier(environment)
        if let value = values[id] { return value }
        let value = CADOfflineRenderCenter(environment: environment); values[id] = value; return value
    }
}
extension AppEnvironment {
    var offlineRenderCenter: CADOfflineRenderCenter { CADOfflineRenderCenters.get(self) }
}
