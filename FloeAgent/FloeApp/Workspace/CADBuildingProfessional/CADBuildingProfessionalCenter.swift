// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeCAD
import FloeCore
import FloeEnvironments
import FloeExecution
import FloeModels
import FloePersistence
import FloeTools
import FloeWorkbench

struct CADBuildingProfessionalResult: Codable, Sendable {
    struct Analysis: Codable, Sendable {
        var memberID: String
        var support: String
        var spanMM: Double
        var lineLoadNPerMM: Double
        var minimumDeflectionMM: Double
        var reactionSumN: Double
        var wholeBuildingAnalysis: Bool
        var designCodeApproval: Bool
    }
    struct Coordination: Codable, Sendable {
        struct Clash: Codable, Sendable { var a: String; var b: String; var distanceM: Double }
        var status: String
        var reason: String?
        var toleranceM: Double?
        var clashes: [Clash]
    }
    struct Information: Codable, Sendable {
        struct Check: Codable, Sendable { var name: String; var passed: Bool; var applicable: Int; var failed: Int }
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

struct CADBuildingProfessionalOperation: Codable, Identifiable, Sendable {
    enum State: String, Codable, Sendable { case preparing, running, ready, cancelling, cancelled, failed, interrupted }
    var id: UUID
    var action: CADBuildingProfessionalAction
    var documentURL: URL
    var workspaceRoot: URL
    var conversationID: UUID
    var environmentID: String
    var runID: UUID
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
    var isRunning: Bool { [.preparing, .running, .cancelling].contains(state) }
}

@MainActor
final class CADBuildingProfessionalCenter {
    weak var environment: AppEnvironment?
    init(environment: AppEnvironment) { self.environment = environment }
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
    func latest(documentURL: URL, action: CADBuildingProfessionalAction, root: URL, conversationID: UUID) -> CADBuildingProfessionalOperation? {
        guard let base = try? self.root(), let urls = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) else { return nil }
        return urls.compactMap { url -> CADBuildingProfessionalOperation? in
            guard let id = UUID(uuidString: url.lastPathComponent) else { return nil }; return try? load(id)
        }.filter { $0.documentURL == documentURL.standardizedFileURL.resolvingSymlinksInPath() && $0.action == action
            && $0.workspaceRoot == root.standardizedFileURL.resolvingSymlinksInPath() && $0.conversationID == conversationID }
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
                     structural: CADBuildingStructuralSettings, root: URL, workspaceID: UUID,
                     conversationID: UUID) async throws -> CADBuildingProfessionalOperation {
        guard let environment, let jobs = environment.backgroundJobService else { throw FloeError.validationFailed("Background jobs are unavailable.") }
        let owners = try await SQLiteWorkspaceStore(database: environment.database).conversations(workspaceID: workspaceID)
        guard owners.contains(conversationID),
              let binding = try await TaskExecutionBindingStore(database: environment.database).binding(conversationID: conversationID),
              let record = await environment.environmentRegistry.record(id: binding.target.environmentID), record.state == .active,
              [.linuxVM, .remoteSSH].contains(record.effectiveExecutionBackend) else {
            throw FloeError.validationFailed("Select a Linux execution environment for this task before running a building study.")
        }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        if let prior = latest(documentURL: document.url, action: action, root: canonicalRoot, conversationID: conversationID), prior.isRunning {
            let current = try await refresh(prior.id); if current.isRunning { return current }
        }
        let package = try await document.prepareBuildingProfessional(action: action, structural: structural)
        try Task.checkCancellation()
        let id = UUID(), runID = UUID(), relative = "BuildingStudies/\(id.uuidString)"
        let workspaceDirectory = canonicalRoot.appendingPathComponent(relative, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: workspaceDirectory.path),
              workspaceDirectory.standardizedFileURL == workspaceDirectory.resolvingSymlinksInPath().standardizedFileURL else { throw FloeError.unauthorized }
        try FileManager.default.createDirectory(at: workspaceDirectory, withIntermediateDirectories: true)
        guard Set(package.files.keys) == ["input.json", "runner.py"] else { throw FloeError.validationFailed("The building input package is incomplete.") }
        for (name, bytes) in package.files { try bytes.write(to: workspaceDirectory.appendingPathComponent(name), options: .atomic) }
        let script = #"""
        set -eu
        umask 077
        test "$(uname -s)" = Linux || { echo 'This study requires the selected Linux environment.' >&2; exit 69; }
        command -v python3 >/dev/null
        test ! -e result.json
        python3 -m venv .venv
        .venv/bin/python -m pip install --disable-pip-version-check 'ifcopenshell==0.9.0.post1' 'ifctester==0.9.0' 'PyniteFEA==3.2.1'
        .venv/bin/python runner.py
        test -s result.json
        test -s model.ifc
        """#
        let payload = try JSONSerialization.data(withJSONObject: ["script": script, "cwd": relative, "maxOutputBytes": 65536], options: .sortedKeys)
        var operation = CADBuildingProfessionalOperation(id: id, action: action,
            documentURL: document.url.standardizedFileURL.resolvingSymlinksInPath(), workspaceRoot: canonicalRoot,
            conversationID: conversationID, environmentID: binding.target.environmentID, runID: runID,
            relativeDirectory: relative, payload: payload, sourceSHA256: package.sourceSHA256,
            structural: action == .structure ? structural : nil,
            inputHashes: package.files.mapValues(FloeDigest.sha256Hex), revision: package.revision,
            changeCount: package.changeCount, state: .preparing, createdAt: Date())
        try save(operation)
        try await environment.runStore.saveRun(RunRecord(id: runID, conversationID: conversationID, state: "completed",
            goal: "Building study", startedAt: Date(), endedAt: Date(), executionBinding: binding))
        do {
            let job = try await jobs.submit(runID: runID, toolCallID: nil, targetTool: "exec.shell", payloadJSON: payload,
                scope: .local, workspaceRootURL: canonicalRoot, allowedWorkspacePaths: [], environmentID: binding.target.environmentID,
                allowedToolNames: ["exec.shell"], submissionSource: .nativeService)
            operation.jobID = job.id; operation.state = .running; try save(operation)
        } catch { operation.state = .failed; operation.error = error.localizedDescription; try save(operation); throw error }
        return operation
    }
    func refresh(_ id: UUID) async throws -> CADBuildingProfessionalOperation {
        var operation = try load(id)
        guard operation.isRunning else { return operation }
        guard let jobs = environment?.backgroundJobService, let jobID = operation.jobID else {
            operation.state = .interrupted; operation.error = "Preparation was interrupted. Start a new study."; try save(operation); return operation
        }
        let job = try await jobs.ownedJob(id: jobID, runID: operation.runID)
        operation = try load(id)
        guard job.conversationID == operation.conversationID, job.environmentID == operation.environmentID,
              job.targetTool == "exec.shell", job.payloadJSON == operation.payload,
              job.workspaceRootPath.map({ URL(fileURLWithPath: $0).standardizedFileURL.resolvingSymlinksInPath() }) == operation.workspaceRoot else { throw FloeError.unauthorized }
        guard job.state.isTerminal else { return operation }
        if operation.state == .cancelling || job.state == .cancelled { operation.state = .cancelled }
        else if job.state == .interrupted { operation.state = .interrupted; operation.error = job.lastError }
        else if job.state == .failed { operation.state = .failed; operation.error = job.lastError ?? "The study failed. Inspect its saved job output." }
        else if job.state == .completed {
            do {
                let frozen = operation, archive = try directory(id)
                let worker = Task.detached(priority: .userInitiated) { try Self.verifyAndArchive(frozen, archive: archive) }
                let result = try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
                operation = try load(id)
                guard operation.state != .cancelling, operation.state != .cancelled else { return operation }
                operation.result = result; operation.state = .ready
            } catch is CancellationError { throw CancellationError() }
            catch { operation.state = .failed; operation.error = error.localizedDescription }
        }
        try save(operation); return operation
    }
    func cancel(_ id: UUID) async throws -> CADBuildingProfessionalOperation {
        var operation = try load(id); guard operation.isRunning else { return operation }
        operation.state = .cancelling; try save(operation)
        if let jobs = environment?.backgroundJobService, let job = operation.jobID {
            _ = try await jobs.cancel(id: job); return try await refresh(id)
        }
        operation.state = .cancelled; try save(operation); return operation
    }
    nonisolated static func verifyAndArchive(_ operation: CADBuildingProfessionalOperation, archive: URL) throws -> CADBuildingProfessionalResult {
        let directory = operation.workspaceRoot.appendingPathComponent(operation.relativeDirectory, isDirectory: true)
        for (name, digest) in operation.inputHashes {
            try Task.checkCancellation()
            guard ["input.json", "runner.py"].contains(name),
                  FloeDigest.sha256Hex(try checkedFile(directory.appendingPathComponent(name), root: directory, limit: 64 * 1024 * 1024)) == digest else { throw FloeError.validationFailed("The prepared building inputs have changed.") }
        }
        let bytes = try checkedFile(directory.appendingPathComponent("result.json"), root: directory, limit: 2 * 1024 * 1024)
        let result = try JSONDecoder().decode(CADBuildingProfessionalResult.self, from: bytes)
        guard result.schemaVersion == 1, result.action == operation.action, result.sourceSHA256 == operation.sourceSHA256,
              result.sourceRevision == operation.revision, (0...500_000).contains(result.triangles),
              result.backendVersions["ifcopenshell"] == "0.9.0.post1", result.backendVersions["ifctester"] == "0.9.0",
              result.backendVersions["PyniteFEA"] == "3.2.1", result.artifacts["model.ifc"] != nil,
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
            guard coordination.clashes.count <= 10_000, coordination.clashes.allSatisfy({ $0.distanceM.isFinite && $0.a.count <= 80 && $0.b.count <= 80 }) else { throw FloeError.validationFailed("The coordination result is invalid.") }
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
