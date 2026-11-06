// SPDX-License-Identifier: MPL-2.0
import Foundation
import ImageIO
import FloeCAD
import FloeCore
import FloeTools
import FloeWorkbench

nonisolated struct CADOfflineRenderOperation: Codable, Identifiable, Sendable {
    nonisolated enum State: String, Codable, Sendable { case preparing, rendering, ready, cancelling, cancelled, failed, interrupted }
    var id: UUID
    var documentURL: URL
    var workspaceRoot: URL?
    var conversationID: UUID?
    var environmentID: String?
    var runID: UUID?
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
    var backendID: String?
    var completedSamples: Int?
    var isRunning: Bool { [.preparing, .rendering, .cancelling].contains(state) }
}

@MainActor
final class CADOfflineRenderCenter {
    weak var environment: AppEnvironment?
    static let shared = CADOfflineRenderCenter()
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var hosts: [UUID: CADNativeRenderHost] = [:]
    init(environment: AppEnvironment? = nil) { self.environment = environment }
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
    func latest(documentURL: URL, conversationID: UUID? = nil, workspaceRoot: URL? = nil) -> CADOfflineRenderOperation? {
        guard let root = try? storeRoot(), let urls = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return nil }
        return urls.compactMap { url -> CADOfflineRenderOperation? in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }
            return try? operation(id)
        }.filter { $0.documentURL == documentURL.standardizedFileURL.resolvingSymlinksInPath()
            && (conversationID == nil || $0.conversationID == conversationID)
            && (workspaceRoot == nil || $0.workspaceRoot == workspaceRoot?.standardizedFileURL.resolvingSymlinksInPath()) }
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

    /// App-owned on-device render. Workspace/task arguments remain optional
    /// context for existing callers; they never select an execution machine.
    func startFromUI(document: FloeCADDocument, settings: CADOfflineRenderSettings,
                     workspaceRoot: URL? = nil, workspaceID: UUID? = nil,
                     conversationID: UUID? = nil) async throws -> CADOfflineRenderOperation {
        if let prior = latest(documentURL: document.url), prior.isRunning {
            let current = try await refresh(prior.id); if current.isRunning { return current }
        }
        guard workers.isEmpty else { throw CADNativeRenderError.busy }
        let package = try await document.prepareOfflineRender(settings: settings)
        try Task.checkCancellation()
        guard workers.isEmpty else { throw CADNativeRenderError.busy }
        guard Set(package.files.keys) == ["scene.json"], let input = package.files["scene.json"] else { throw CADNativeRenderError.invalidResult }
        let id = UUID(), archive = try operationDirectory(id), directory = archive.appendingPathComponent("input", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try input.write(to: directory.appendingPathComponent("scene.json"), options: .atomic)
        let operation = CADOfflineRenderOperation(id: id,
            documentURL: document.url.standardizedFileURL.resolvingSymlinksInPath(), workspaceRoot: workspaceRoot?.standardizedFileURL.resolvingSymlinksInPath(),
            conversationID: conversationID, relativeDirectory: "input", payload: Data(), settings: settings,
            revision: package.revision, changeCount: package.changeCount, sourceSHA256: package.sourceSHA256,
            inputHashes: ["scene.json": FloeDigest.sha256Hex(input)], warnings: package.warnings,
            state: .rendering, createdAt: Date(), backendID: CADNativeSceneExporter.backendID)
        try save(operation)
        workers[id] = Task { [self] in
            let host = CADNativeRenderHost(input: input, settings: settings) { [weak self] samples in
                guard let self, var current = try? self.operation(id), current.state == .rendering else { return }
                current.completedSamples = samples; try? self.save(current)
            }
            hosts[id] = host
            defer { host.release(); hosts[id] = nil; workers[id] = nil }
            do {
                let output = try await host.render()
                try Task.checkCancellation()
                guard var current = try? self.operation(id), current.state == .rendering else { return }
                try output.png.write(to: directory.appendingPathComponent("render.png"), options: .atomic)
                let receipt = try CADOfflineRenderCommands.receipt(sceneSHA256: FloeDigest.sha256Hex(input),
                    imageSHA256: FloeDigest.sha256Hex(output.png), samples: output.samples)
                try receipt.write(to: directory.appendingPathComponent("result.json"), options: .atomic)
                let frozen = current
                let verifier = Task.detached(priority: .userInitiated) { try Self.verifyAndArchive(frozen, archive: archive) }
                let hash = try await withTaskCancellationHandler { try await verifier.value } onCancel: { verifier.cancel() }
                try Task.checkCancellation()
                current = try self.operation(id)
                guard current.state == .rendering else { return }
                current.imageSHA256 = hash; current.completedSamples = output.samples; current.state = .ready
                try self.save(current)
            } catch {
                guard var current = try? self.operation(id) else { return }
                if current.state == .cancelled || current.state == .cancelling || error is CancellationError {
                    current.state = .cancelled
                } else {
                    if let local = error as? CADNativeRenderError, case .interrupted = local { current.state = .interrupted }
                    else { current.state = .failed }
                    current.error = error.localizedDescription
                }
                try? self.save(current)
            }
        }
        return operation
    }

    /// Reopening never restarts a renderer or resumes an old external job.
    func refresh(_ id: UUID) async throws -> CADOfflineRenderOperation {
        var current = try operation(id)
        if current.isRunning && workers[id] == nil {
            current.state = .interrupted
            current.error = CADNativeRenderError.interrupted.localizedDescription
            try save(current)
        }
        return current
    }
    func cancel(_ id: UUID) async throws -> CADOfflineRenderOperation {
        var current = try operation(id); guard current.isRunning else { return current }
        current.state = .cancelling; try save(current)
        workers[id]?.cancel(); hosts[id]?.cancel()
        current = try operation(id); current.state = .cancelled; try save(current)
        return current
    }
    nonisolated static func verifyAndArchive(_ operation: CADOfflineRenderOperation, archive: URL) throws -> String {
        let isNative = operation.backendID == CADNativeSceneExporter.backendID
        let directory: URL
        if isNative { directory = archive.appendingPathComponent("input", isDirectory: true) }
        else if let root = operation.workspaceRoot { directory = root.appendingPathComponent(operation.relativeDirectory, isDirectory: true) }
        else { throw CADNativeRenderError.invalidResult }
        for (name, hash) in operation.inputHashes {
            try Task.checkCancellation()
            guard FloeDigest.sha256Hex(try checkedFile(directory.appendingPathComponent(name), root: directory,
                limit: isNative ? CADNativeSceneExporter.maximumPackageBytes : CADPBRTSceneExporter.maximumPackageBytes)) == hash else { throw FloeError.validationFailed("The prepared render inputs have changed.") }
        }
        let manifestBytes = try checkedFile(directory.appendingPathComponent("result.json"), root: directory, limit: 4096)
        guard let object = try JSONSerialization.jsonObject(with: manifestBytes) as? [String: Any],
              let manifestImageSHA = object["imageSHA256"] as? String else { throw CADNativeRenderError.invalidResult }
        if isNative {
            guard object["backend"] as? String == CADNativeSceneExporter.backendID,
                  object["revision"] as? String == CADNativeSceneExporter.backendRevision,
                  object["sceneSHA256"] as? String == operation.inputHashes["scene.json"],
                  let count = object["samples"] as? Int, count >= operation.settings.quality.samples else { throw CADNativeRenderError.invalidResult }
        } else {
            // Read-only compatibility for already saved PBRT receipts. This
            // never launches, installs, polls or cancels an external process.
            guard object["backend"] as? String == "pbrt-v4",
                  object["revision"] as? String == CADOfflineRenderCommands.revision,
                  object["sceneSHA256"] as? String == operation.inputHashes["scene.pbrt"] else { throw CADNativeRenderError.invalidResult }
        }
        let png = try checkedFile(directory.appendingPathComponent("render.png"), root: directory, limit: 64 * 1024 * 1024)
        let hash = FloeDigest.sha256Hex(png)
        guard manifestImageSHA == hash, png.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]),
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

extension AppEnvironment {
    var offlineRenderCenter: CADOfflineRenderCenter { .shared }
}
