// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Observation
import FloeChemistryCore
import FloeChemistryEngine
import FloeChemistryUI
import FloeTools

enum ChemistryHostFactory {
    static func storeDirectory(in directory: URL) -> URL { directory.appendingPathComponent("Chemistry", isDirectory: true) }
    static func create(id: UUID, title: String, directory: URL) async throws {
        let store = try ChemistryProjectStore(root: storeDirectory(in: directory))
        // The PersonalContentLibrary writer owns this new original. Using
        // service.create would create a second, unrelated project identity.
        _ = try await store.save(ChemistryProject(id: id, title: title), expectedRevision: 0)
    }
    static func verifiedStore(id: UUID, directory: URL) async throws -> ChemistryProjectStore {
        let folder = storeDirectory(in: directory)
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true,
              folder.resolvingSymlinksInPath().path.hasPrefix(directory.resolvingSymlinksInPath().path + "/") else {
            throw PersonalContentError.invalidProject
        }
        let store = try ChemistryProjectStore(root: folder)
        guard try await store.load(id).id == id else { throw PersonalContentError.invalidProject }
        return store
    }
}

/// A single service owns the calculation tasks for this original. Opening
/// Notes or an assistant must not construct a second service and mislabel
/// this service's live calculations as interrupted.
@MainActor @Observable final class ChemistryProjectSession {
    private static var sessions: [UUID: ChemistryProjectSession] = [:]
    private static var opening: [UUID: Task<ChemistryProjectSession, Error>] = [:]
    let projectID: UUID
    let root: URL
    let service: ChemistryService
    let editor: ChemistryEditorState
    @ObservationIgnored weak var environment: AppEnvironment?
    var diagnostic: String?
    private(set) var closing = false
    private var owners: [UUID: ChemistryHostRunOwner] = [:]

    private init(id: UUID, root: URL, service: ChemistryService, environment: AppEnvironment) throws {
        projectID = id; self.root = root; self.service = service; self.environment = environment
        editor = ChemistryEditorState(service: service, projectID: id)
        let file = root.appendingPathComponent("ChemistryHostRuns.json")
        if FileManager.default.fileExists(atPath: file.path) {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true,
                  (values.fileSize ?? Int.max) <= 4 * 1_024 * 1_024 else { throw PersonalContentError.invalidProject }
            owners = try JSONDecoder().decode([UUID: ChemistryHostRunOwner].self, from: Data(contentsOf: file))
        }
    }
    static func open(id: UUID, directory: URL, environment: AppEnvironment,
                     additionalBackends: [any ChemistryBackend] = []) async throws -> ChemistryProjectSession {
        try PersonalLibraryFileActions.requireAvailable(id)
        return try await openVerified(id: id, directory: directory, environment: environment, additionalBackends: additionalBackends)
    }
    /// Called only after the file-action barrier has excluded editors/tools.
    /// The existing job reconciler examines persisted workers before tombstoning.
    static func prepareForLibraryDeletion(id: UUID, directory: URL, environment: AppEnvironment) async throws {
        _ = try await openVerified(id: id, directory: directory, environment: environment, additionalBackends: [])
        try await prepareForDeletion(id: id)
    }
    private static func openVerified(id: UUID, directory: URL, environment: AppEnvironment,
                                     additionalBackends: [any ChemistryBackend]) async throws -> ChemistryProjectSession {
        if let value = sessions[id] {
            guard value.root.standardizedFileURL == directory.standardizedFileURL,
                  value.environment === environment, !value.closing else { throw PersonalContentError.changedDocument }
            return value
        }
        if let pending = opening[id] {
            let value = try await pending.value
            guard value.root.standardizedFileURL == directory.standardizedFileURL,
                  value.environment === environment else { throw PersonalContentError.changedDocument }
            return value
        }
        let pending = Task { @MainActor in
            let location = try await PersonalContentService.shared.library().resolve(id)
            guard location.record.kind == .chemistry, location.url.standardizedFileURL == directory.standardizedFileURL else {
                throw PersonalContentError.changedDocument
            }
            let store = try await ChemistryHostFactory.verifiedStore(id: id, directory: directory)
            var backends: [any ChemistryBackend] = [NativeChemistryBackend()]
            backends.append(contentsOf: additionalBackends)
            let service = try ChemistryService(store: store, backends: backends) { access in
                // This is the native UI's existing personal-original ownership
                // boundary, not an imported task grant. Agent calls additionally
                // pass StudioCoordinator.location on their real ToolContext.
                guard access.projectID == id, access.action != .create else {
                    throw ChemistryError.unavailable("This service is bound to one existing personal chemistry original.")
                }
                let current = try await PersonalContentService.shared.library().resolve(id)
                guard current.record.kind == .chemistry, current.url.standardizedFileURL == directory.standardizedFileURL else {
                    throw PersonalContentError.changedDocument
                }
            }
            let session = try ChemistryProjectSession(id: id, root: directory, service: service, environment: environment)
            environment.chemistryEnvironmentJobs.installEditorHooks(session)
            await session.editor.refresh()
            guard session.editor.project?.id == id else { throw PersonalContentError.invalidProject }
            sessions[id] = session
            return session
        }
        opening[id] = pending
        defer { opening[id] = nil }
        return try await pending.value
    }
    func refreshFromHost() async { if !editor.hasPendingEdits { await editor.refresh() } }
    func flushForClose() async -> Bool {
        await editor.flush()
        guard !editor.hasPendingEdits else {
            diagnostic = IDELanguageRunText.t("请先完成保存或处理未保存的绘图。", "Finish saving or resolve the unsaved drawing first.")
            return false
        }
        return true
    }
    func projectForRead() async throws -> ChemistryProject { try await service.project(projectID) }
    func requireReadyForAgentEdit(expectedRevision: UInt64? = nil) async throws {
        guard !closing, !editor.hasPendingEdits else { throw PersonalContentError.changedDocument }
        let project = try await service.project(projectID)
        if let expectedRevision, project.revision != expectedRevision { throw PersonalContentError.changedDocument }
    }
    func savedRunOwner(_ runID: UUID) -> ChemistryHostRunOwner? { owners[runID] }
    func recordOwner(runID: UUID, context: ToolContext, environmentID: String) throws {
        guard let conversationID = context.conversationID else { throw PersonalContentError.invalidProject }
        var next = owners
        next[runID] = .init(calculationID: runID, taskRunID: context.runID, conversationID: conversationID,
            toolCallID: context.toolCallID, environmentID: environmentID, recordedAt: Date())
        let data = try JSONEncoder().encode(next)
        guard data.count <= 4 * 1_024 * 1_024 else { throw PersonalContentError.invalidProject }
        try data.write(to: root.appendingPathComponent("ChemistryHostRuns.json"), options: .atomic)
        owners = next
    }
    static func prepareForDeletion(id: UUID) async throws {
        if let pending = opening[id] { _ = try await pending.value }
        guard let session = sessions[id] else { return }
        guard await session.flushForClose() else { throw PersonalContentError.changedDocument }
        guard let environment = session.environment else { throw PersonalContentError.storageUnavailable }
        try await environment.chemistryEnvironmentJobs.prepareForDeletion(session: session)
        session.closing = true
        var stopped = false
        defer { if !stopped { session.closing = false } }
        let project = try await session.service.project(id)
        for run in project.runs where [.queued, .running].contains(run.status) {
            try await session.service.cancel(id, runID: run.id)
            _ = try await session.service.wait(id, runID: run.id)
        }
        sessions.removeValue(forKey: id)
        stopped = true
    }
}

struct ChemistryHostRunOwner: Codable, Sendable {
    let calculationID: UUID
    let taskRunID: UUID
    let conversationID: UUID
    let toolCallID: String?
    let environmentID: String
    let recordedAt: Date
}

/// Integration seam only. Root supplies a real, probed environment and its
/// already-authorized job/owner transport. No endpoint, executable, installer,
/// interpreter or transport is configured by this App integration batch.
enum ChemistryHostConfiguredWorkers {
    static func backend(environmentID: UUID, engineVersion: String, verifiedMethods: Set<String>,
        execute: @escaping @Sendable (Data) async throws -> Data) throws -> ConfiguredChemistryBackend {
        guard !engineVersion.isEmpty, engineVersion.utf8.count <= 1024,
              !verifiedMethods.isEmpty, verifiedMethods.count <= 256,
              verifiedMethods.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else { throw PersonalContentError.invalidProject }
        return .worker(environmentID: environmentID.uuidString.lowercased(), engineVersion: engineVersion,
                       methods: verifiedMethods, execute: execute)
    }
}
#endif
