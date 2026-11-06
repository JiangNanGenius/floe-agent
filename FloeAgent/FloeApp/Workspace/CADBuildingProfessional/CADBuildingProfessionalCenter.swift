// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCAD
import FloeCore
import FloeTools

nonisolated struct CADBuildingProfessionalResult: Codable, Sendable {
    nonisolated struct Analysis: Codable, Sendable {
        var memberID: String
        var support: String
        var spanMM: Double
        var lineLoadNPerMM: Double
        var minimumDeflectionMM: Double
        var reactionSumN: Double
        var wholeBuildingAnalysis: Bool
        var designCodeApproval: Bool
    }
    nonisolated struct Coordination: Codable, Sendable {
        nonisolated struct Clash: Codable, Sendable {
            var a: String; var b: String
            var distanceM: Double? // Read-only compatibility with historical receipts.
            var bodyA: String?
            var bodyB: String?
            var overlapVolumeM3: Double?
            var intersectionBoundsM: [[Double]]?
            var intersectionTriangleCount: Int?
        }
        var status: String
        var reason: String?
        var toleranceM: Double?
        var clashes: [Clash]
        var evaluatedMeshPairs: Int?
        var unevaluatedMeshPairs: Int?
    }
    nonisolated struct Information: Codable, Sendable {
        nonisolated struct Check: Codable, Sendable { var name: String; var passed: Bool; var applicable: Int; var failed: Int }
        var buildingRegulations: Bool
        var checks: [Check]
    }
    var schemaVersion: Int
    var action: CADBuildingProfessionalAction
    var sourceSHA256: String
    var sourceRevision: Int
    var triangles: Int
    var backendVersions: [String: String]
    var artifacts: [String: String]
    var analysis: Analysis?
    var coordination: Coordination?
    var information: Information?
}

nonisolated struct CADBuildingProfessionalOperation: Codable, Identifiable, Sendable {
    nonisolated enum State: String, Codable, Sendable { case preparing, running, ready, cancelling, cancelled, failed, interrupted }
    var id: UUID
    var action: CADBuildingProfessionalAction
    var documentURL: URL
    var workspaceRoot: URL?
    var conversationID: UUID?
    var environmentID: String?
    var runID: UUID?
    var jobID: UUID?
    var relativeDirectory: String
    var payload: Data
    var sourceSHA256: String
    var structural: CADBuildingStructuralSettings?
    var inputHashes: [String: String]
    var revision: Int
    var changeCount: Int
    var state: State
    var error: String?
    var result: CADBuildingProfessionalResult?
    var createdAt: Date
    var executionBackend: String? = nil
    var isRunning: Bool { [.preparing, .running, .cancelling].contains(state) }
}

private nonisolated final class CADBuildingStudyCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.withLock { value = true } }
    var isCancelled: Bool { lock.withLock { value } }
}

@MainActor
final class CADBuildingProfessionalCenter {
    weak var environment: AppEnvironment?
    init(environment: AppEnvironment) { self.environment = environment }
    private var workers: [UUID: Task<Void, Never>] = [:]
    private var cancellations: [UUID: CADBuildingStudyCancellation] = [:]
    private var hosts: [UUID: CADBuildingLocalIFCHost] = [:]
    private var preparing = false
    private func root() throws -> URL {
        let root = try FloeArtifactStore.root().appendingPathComponent("JobDownloads/BuildingStudies", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
    private func directory(_ id: UUID) throws -> URL {
        let directory = try root().appendingPathComponent(id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
    private func save(_ operation: CADBuildingProfessionalOperation) throws {
        try JSONEncoder().encode(operation).write(to: directory(operation.id).appendingPathComponent("operation.json"), options: .atomic)
    }
    private func load(_ id: UUID) throws -> CADBuildingProfessionalOperation {
        try JSONDecoder().decode(CADBuildingProfessionalOperation.self, from: Data(contentsOf: directory(id).appendingPathComponent("operation.json")))
    }
    func latest(documentURL: URL, action: CADBuildingProfessionalAction, root: URL? = nil, conversationID: UUID? = nil) -> CADBuildingProfessionalOperation? {
        guard let base = try? self.root(), let urls = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return nil }
        return urls.compactMap { url -> CADBuildingProfessionalOperation? in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }; return try? load(id)
        }.filter { $0.documentURL == documentURL.standardizedFileURL.resolvingSymlinksInPath() && $0.action == action
            && $0.workspaceRoot == root?.standardizedFileURL.resolvingSymlinksInPath() && $0.conversationID == conversationID }
            .max { $0.createdAt < $1.createdAt }
    }
    func artifactURLs(_ operation: CADBuildingProfessionalOperation) throws -> [URL] {
        guard operation.state == .ready, let result = operation.result else { return [] }
        let base = try directory(operation.id)
        for (name, digest) in result.artifacts {
            guard ["model.ifc", "requirements.ids"].contains(name),
                  FloeDigest.sha256Hex(try Self.checkedFile(base.appendingPathComponent(name), root: base, limit: 128 * 1024 * 1024)) == digest else { throw FloeError.validationFailed("The saved building output has changed.") }
        }
        return result.artifacts.keys.sorted().map { base.appendingPathComponent($0) } + [base.appendingPathComponent("result.json")]
    }
    func startFromUI(document: FloeCADDocument, action: CADBuildingProfessionalAction,
                     structural: CADBuildingStructuralSettings, root: URL? = nil, workspaceID: UUID? = nil,
                     conversationID: UUID? = nil) async throws -> CADBuildingProfessionalOperation {
        let canonicalRoot = root?.standardizedFileURL.resolvingSymlinksInPath()
        if let prior = latest(documentURL: document.url, action: action, root: canonicalRoot, conversationID: conversationID), prior.isRunning {
            let current = try await refresh(prior.id); if current.isRunning { return current }
        }
        // Bound device memory, and fence reentrant starts while saving a snapshot.
        guard !preparing, workers.isEmpty else { throw FloeError.validationFailed("Another building study is running. Wait for it or cancel it first.") }
        preparing = true
        defer { preparing = false }
        let package = try await document.prepareBuildingProfessional(action: action, structural: structural)
        try Task.checkCancellation()
        guard Set(package.files.keys) == ["input.json"], let input = package.files["input.json"],
              FloeDigest.sha256Hex(input) == package.sourceSHA256 else { throw FloeError.validationFailed("The building input package is incomplete.") }
        let id = UUID(), archive = try directory(id)
        try input.write(to: archive.appendingPathComponent("input.json"), options: .atomic)
        let operation = CADBuildingProfessionalOperation(id: id, action: action,
            documentURL: document.url.standardizedFileURL.resolvingSymlinksInPath(), workspaceRoot: canonicalRoot,
            conversationID: conversationID, environmentID: nil, runID: nil,
            relativeDirectory: "", payload: Data(), sourceSHA256: package.sourceSHA256,
            structural: action == .structure ? structural : nil,
            inputHashes: package.files.mapValues(FloeDigest.sha256Hex), revision: package.revision,
            changeCount: package.changeCount, state: .running, createdAt: Date(), executionBackend: "device")
        try save(operation)
        let cancellation = CADBuildingStudyCancellation()
        cancellations[id] = cancellation
        // The centre owns execution; dismissing the sheet does not cancel it.
        workers[id] = Task { [weak self] in
            guard let self else { return }
            await execute(id, input: input, cancellation: cancellation)
        }
        return operation
    }
    func refresh(_ id: UUID) async throws -> CADBuildingProfessionalOperation {
        var operation = try load(id)
        guard operation.isRunning else { return operation }
        if workers[id] == nil {
            // Recover only a complete hash-checked receipt after process death.
            do {
                guard operation.executionBackend == "device", operation.state != .cancelling else { throw CancellationError() }
                operation.result = try Self.verifyAndArchive(operation, archive: directory(id)); operation.state = .ready
            } catch { operation.state = .interrupted; operation.error = "The calculation was interrupted. Start a new study." }
            try save(operation)
        }
        return operation
    }
    func cancel(_ id: UUID) async throws -> CADBuildingProfessionalOperation {
        var operation = try load(id); guard operation.isRunning else { return operation }
        // Persist the fence BEFORE stopping a worker or a WebKit process.
        operation.state = .cancelled; try save(operation)
        cancellations[id]?.cancel(); workers[id]?.cancel(); hosts[id]?.close()
        return operation
    }
    private func execute(_ id: UUID, input: Data, cancellation: CADBuildingStudyCancellation) async {
        defer { hosts[id]?.close(); hosts[id] = nil; cancellations[id] = nil; workers[id] = nil }
        do {
            let operation = try load(id), archive = try directory(id)
            guard operation.state == .running else { return }
            let worker = Task.detached(priority: .userInitiated) { () throws -> Data in
                switch operation.action {
                case .structure: return try CADBuildingLocalAnalysis.evaluate(input: input, cancelled: { cancellation.isCancelled })
                case .mep: return try CADBuildingLocalCoordination.evaluate(input: input, cancelled: { cancellation.isCancelled })
                case .ifc, .information: return Data("{}".utf8)
                }
            }
            let fragment = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel(); cancellation.cancel() }
            try Task.checkCancellation()
            guard !cancellation.isCancelled, try load(id).state == .running else { throw CancellationError() }
            let host = CADBuildingLocalIFCHost(); hosts[id] = host
            let output = try await host.run(input: input)
            try Task.checkCancellation()
            guard !cancellation.isCancelled, try load(id).state == .running else { throw CancellationError() }
            // Hash/serialize on a worker. Only a valid final receipt promotes
            // the operation; partially written artifacts remain recoverable.
            let receiptWorker = Task.detached(priority: .userInitiated) {
                guard var metadata = try JSONSerialization.jsonObject(with: output.metadata) as? [String: Any],
                      let computed = try JSONSerialization.jsonObject(with: fragment) as? [String: Any] else {
                    throw FloeError.validationFailed("The local building result is incomplete.")
                }
                var versions = metadata["backendVersions"] as? [String: String] ?? [:]
                versions.merge(computed["backendVersions"] as? [String: String] ?? [:]) { _, new in new }
                metadata["backendVersions"] = versions
                metadata.removeValue(forKey: "ifcBytes"); metadata.removeValue(forKey: "idsBytes")
                for key in ["analysis", "coordination"] { if let value = computed[key] { metadata[key] = value } }
                metadata["schemaVersion"] = 2; metadata["action"] = operation.action.rawValue
                metadata["sourceSHA256"] = operation.sourceSHA256; metadata["sourceRevision"] = operation.revision
                var files = ["model.ifc": output.ifc]
                if let ids = output.ids { files["requirements.ids"] = ids }
                metadata["artifacts"] = files.mapValues(FloeDigest.sha256Hex)
                for (name, bytes) in files {
                    try Task.checkCancellation()
                    guard !cancellation.isCancelled else { throw CancellationError() }
                    try bytes.write(to: archive.appendingPathComponent(name), options: .atomic)
                }
                let data = try JSONSerialization.data(withJSONObject: metadata, options: .sortedKeys)
                try Task.checkCancellation()
                guard !cancellation.isCancelled else { throw CancellationError() }
                try data.write(to: archive.appendingPathComponent("result.json"), options: .atomic)
                return try Self.verifyAndArchive(operation, archive: archive)
            }
            let result = try await withTaskCancellationHandler { try await receiptWorker.value } onCancel: { receiptWorker.cancel(); cancellation.cancel() }
            var current = try load(id)
            guard current.state == .running, !cancellation.isCancelled else { return }
            current.result = result; current.state = .ready; current.error = nil; try save(current)
        } catch {
            guard var current = try? load(id), current.state == .running else { return }
            current.state = cancellation.isCancelled || error is CancellationError ? .cancelled : .failed
            current.error = current.state == .failed ? error.localizedDescription : nil
            try? save(current)
        }
    }
    /// Historical receipts remain readable, but no new operation executes a
    /// shell/Python job. Device receipts use the service-owned archive only.
    nonisolated static func verifyAndArchive(_ operation: CADBuildingProfessionalOperation, archive: URL) throws -> CADBuildingProfessionalResult {
        let device = operation.executionBackend == "device"
        guard device || operation.workspaceRoot != nil else { throw FloeError.validationFailed("The saved building study has no source directory.") }
        let directory = device ? archive : operation.workspaceRoot!.appendingPathComponent(operation.relativeDirectory, isDirectory: true)
        guard !device || (Set(operation.inputHashes.keys) == ["input.json"] && operation.inputHashes["input.json"] == operation.sourceSHA256) else {
            throw FloeError.validationFailed("The saved building input is incomplete.")
        }
        for (name, digest) in operation.inputHashes {
            try Task.checkCancellation()
            guard ["input.json", "runner.py"].contains(name),
                  FloeDigest.sha256Hex(try checkedFile(directory.appendingPathComponent(name), root: directory, limit: 64 * 1024 * 1024)) == digest else { throw FloeError.validationFailed("The prepared building inputs have changed.") }
        }
        let bytes = try checkedFile(directory.appendingPathComponent("result.json"), root: directory, limit: 2 * 1024 * 1024)
        let result = try JSONDecoder().decode(CADBuildingProfessionalResult.self, from: bytes)
        let versionsMatch = device ? result.backendVersions["web-ifc"] == "0.0.75" :
            result.backendVersions["ifcopenshell"] == "0.9.0.post1" && result.backendVersions["ifctester"] == "0.9.0" && result.backendVersions["PyniteFEA"] == "3.2.1"
        guard result.schemaVersion == (device ? 2 : 1), result.action == operation.action, result.sourceSHA256 == operation.sourceSHA256,
              result.sourceRevision == operation.revision, (0...500_000).contains(result.triangles),
              versionsMatch, result.artifacts["model.ifc"] != nil,
              result.artifacts.keys.allSatisfy({ ["model.ifc", "requirements.ids"].contains($0) }),
              operation.action != .information || result.artifacts["requirements.ids"] != nil else { throw FloeError.validationFailed("The building engine returned an invalid result receipt.") }
        guard (operation.action != .structure || result.analysis != nil),
              (operation.action != .mep || result.coordination != nil),
              (operation.action != .information || result.information != nil) else { throw FloeError.validationFailed("The building engine did not return the requested calculation.") }
        if let analysis = result.analysis {
            guard [analysis.spanMM, analysis.lineLoadNPerMM, analysis.minimumDeflectionMM, analysis.reactionSumN].allSatisfy(\.isFinite),
                  analysis.spanMM > 0, analysis.lineLoadNPerMM > 0, !analysis.wholeBuildingAnalysis, !analysis.designCodeApproval,
                  analysis.memberID.lowercased() == operation.structural?.memberID?.uuidString.lowercased(),
                  analysis.support == operation.structural?.support.rawValue,
                  analysis.lineLoadNPerMM == operation.structural?.lineLoadNPerMM else { throw FloeError.validationFailed("The structural result is invalid.") }
        }
        if let coordination = result.coordination {
            guard coordination.clashes.count <= 10_000, coordination.clashes.allSatisfy({ clash in
                let metric = device ? clash.overlapVolumeM3 : clash.distanceM
                return metric?.isFinite == true && (!device || metric! > 0) && clash.a.count <= 80 && clash.b.count <= 80
            }) else { throw FloeError.validationFailed("The coordination result is invalid.") }
        }
        if let information = result.information {
            guard !information.buildingRegulations, information.checks.count <= 1000,
                  information.checks.allSatisfy({ $0.name.count <= 256 && $0.applicable >= 0 && $0.failed >= 0 && $0.failed <= $0.applicable }) else { throw FloeError.validationFailed("The information result is invalid.") }
        }
        for (name, digest) in result.artifacts {
            try Task.checkCancellation()
            let data = try checkedFile(directory.appendingPathComponent(name), root: directory, limit: 128 * 1024 * 1024)
            guard FloeDigest.sha256Hex(data) == digest else { throw FloeError.validationFailed("The building output digest does not match.") }
            if name == "model.ifc" {
                guard String(decoding: data.prefix(256), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("ISO-10303-21;"),
                      String(decoding: data.suffix(256), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("END-ISO-10303-21;") else { throw FloeError.validationFailed("The building engine did not return a complete IFC file.") }
            }
            let target = archive.appendingPathComponent(name)
            guard target.standardizedFileURL == target.resolvingSymlinksInPath().standardizedFileURL else { throw FloeError.unauthorized }
            try data.write(to: target, options: .atomic)
        }
        try bytes.write(to: archive.appendingPathComponent("result.json"), options: .atomic)
        return result
    }
    nonisolated private static func checkedFile(_ url: URL, root: URL, limit: Int) throws -> Data {
        let path = url.standardizedFileURL, base = root.standardizedFileURL.resolvingSymlinksInPath()
        guard path.path.hasPrefix(base.path + "/"), path == path.resolvingSymlinksInPath(),
              let size = try FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber,
              size.intValue > 0, size.intValue <= limit else { throw FloeError.validationFailed("A building output is missing or too large.") }
        let bytes = try Data(contentsOf: path)
        guard bytes.count == size.intValue else { throw FloeError.validationFailed("The building output changed during readback.") }
        return bytes
    }
}

@MainActor private enum CADBuildingProfessionalCenters {
    static var values: [ObjectIdentifier: CADBuildingProfessionalCenter] = [:]
    static func get(_ environment: AppEnvironment) -> CADBuildingProfessionalCenter {
        values = values.filter { $0.value.environment != nil }; let id = ObjectIdentifier(environment)
        if let value = values[id] { return value }
        let value = CADBuildingProfessionalCenter(environment: environment); values[id] = value; return value
    }
}
extension AppEnvironment {
    var buildingProfessionalCenter: CADBuildingProfessionalCenter { CADBuildingProfessionalCenters.get(self) }
}
