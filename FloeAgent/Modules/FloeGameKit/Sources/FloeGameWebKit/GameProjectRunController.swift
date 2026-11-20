// SPDX-License-Identifier: MPL-2.0
import Foundation
import Combine
import FloeGameCore

/// The existing IDE/Space host supplies project-level identity. A selected
/// editor file is intentionally absent from the command contract.
public protocol GameRunContextHost: Sendable {
    func currentContext(for captured: GameProjectContext) async throws -> GameProjectContext
    /// Cheap currency probe for read-only fences. Hosts bound to a repository
    /// answer from authenticated HEAD metadata without walking the tree; the
    /// default keeps the full context open for every other host.
    func currentContextMetadata(for captured: GameProjectContext) async throws -> GameProjectContext
}

extension GameRunContextHost {
    public func currentContextMetadata(for captured: GameProjectContext) async throws -> GameProjectContext {
        try await currentContext(for: captured)
    }
}

public struct GamePreparedWebRun: Sendable {
    public let inspection: GameProjectInspection
    public let package: GameWebArtifactPackage
    public init(inspection: GameProjectInspection, package: GameWebArtifactPackage) {
        self.inspection = inspection; self.package = package
    }
}

public struct GameWebRunRequest: Equatable, Sendable {
    public let id: UUID
    public let context: GameProjectContext
    public let engine: GameEngineID
    public init(id: UUID, context: GameProjectContext, engine: GameEngineID) {
        self.id = id; self.context = context; self.engine = engine
    }
}

/// Build/import adapters use the host's existing jobs, Linux environment or CI.
/// This interface creates no generic shell, JS, Ruby or WASM execution tool.
public protocol GameWebRunPreparationHost: Sendable {
    func prepare(_ request: GameWebRunRequest) async throws -> GamePreparedWebRun
    func cancel(_ request: GameWebRunRequest) async
}

public enum GameProjectRunPhase: Equatable, Sendable { case idle, preparing, running, stopping, failed(String) }

/// Reusable internal command contribution for Run/Stop in IDE or Space. The
/// adapter registry is compiled Swift code rather than downloadable plugins.
/// The host service retains this controller across editor/tab reconstruction.
@MainActor public final class GameProjectRunController: ObservableObject {
    @Published public private(set) var phase: GameProjectRunPhase = .idle
    @Published public private(set) var player: GameWebPlayer?
    public private(set) var context: GameProjectContext?
    private let contexts: any GameRunContextHost
    private let preparationHost: any GameWebRunPreparationHost
    private var generation = 0
    private var preparation: Task<GamePreparedWebRun, any Error>?
    private var request: GameWebRunRequest?
    /// Host-owned development bridge configuration. It is deliberately not
    /// decodable from project metadata and does not expose controls to a
    /// production/exported game.
    public var developerBridgeConfiguration: GameDeveloperBridgeConfiguration?
    public var activeRunID: UUID? { request?.id }

    public init(contexts: any GameRunContextHost, preparation: any GameWebRunPreparationHost) {
        self.contexts = contexts; self.preparationHost = preparation
    }

    public func run(context captured: GameProjectContext, engine: GameEngineID, requestID: UUID = UUID()) async throws {
        guard request?.id != requestID else { throw GameWebPlayerError.staleRun }
        generation += 1; let token = generation
        let prior = player, priorPreparation = preparation, priorRequest = request
        let request = GameWebRunRequest(id: requestID, context: captured, engine: engine); self.request = request
        preparation = nil; player = nil; context = captured; phase = .preparing
        priorPreparation?.cancel()
        if let priorRequest { await preparationHost.cancel(priorRequest) }
        if let priorPreparation { _ = await priorPreparation.result }
        if let prior, !(await prior.stop()) {
            guard token == generation else { throw GameWebPlayerError.staleRun }
            phase = .failed("Unable to confirm the previous game stopped")
            throw GameWebPlayerError.staleRun
        }
        do {
            try await check(captured, token: token)
            let host = preparationHost
            let task = Task { try await host.prepare(request) }
            preparation = task
            let prepared = try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
            try await check(captured, token: token)
            preparation = nil
            var registry = GameAdapterRegistry()
            try registry.register(GameAdapterRegistration(engine: engine, route: .webKit, runtimeReady: true))
            let decision = try GameLaunchPlanner.plan(inspection: prepared.inspection, context: captured,
                selectedEngine: engine, registry: registry, artifact: prepared.package.prepared)
            guard case .launch(let plan) = decision else { throw GameProjectError.invalidArtifact }
            let player = try GameWebPlayer(package: prepared.package, plan: plan, current: captured)
            self.player = player
            if let developerBridgeConfiguration {
                _ = try await player.enableDeveloperBridge(developerBridgeConfiguration)
            }
            try await player.start(current: captured)
            try await check(captured, token: token)
            phase = .running
        } catch {
            if token == generation {
                let owned = player; player = nil; preparation = nil
                if let owned { _ = await owned.stop() }
                if token == generation { phase = .failed(String(describing: error)) }
            }
            throw error
        }
    }

    @discardableResult public func stop(runID: UUID? = nil) async -> Bool {
        if let runID, request?.id != runID { return false }
        generation += 1; let token = generation
        phase = .stopping
        let owned = player, preparing = preparation, captured = request
        player = nil; preparation = nil
        preparing?.cancel()
        if let captured { await preparationHost.cancel(captured) }
        let stopped = await owned?.stop() ?? true
        if let preparing { _ = await preparing.result }
        guard token == generation else { return false }
        context = nil; request = nil; phase = stopped ? .idle : .failed("Unable to confirm the game stopped")
        return stopped
    }

    private func check(_ captured: GameProjectContext, token: Int) async throws {
        try Task.checkCancellation()
        guard token == generation else { throw GameWebPlayerError.staleRun }
        let current = try await contexts.currentContext(for: captured)
        guard token == generation else { throw GameWebPlayerError.staleRun }
        try captured.validate(current: current)
    }
}

/// Ready-to-run static Web projects need no build process. Generated or compiled
/// outputs use another preparation adapter and the same controller above.
public actor GameStaticWebRunPreparer: GameWebRunPreparationHost {
    public let artifactDirectory: URL
    public let entry: GameRelativePath
    private var jobs: [UUID: Task<GamePreparedWebRun, any Error>] = [:]
    public init(artifactDirectory: URL, entry: GameRelativePath) throws {
        guard artifactDirectory.isFileURL else { throw GameProjectError.invalidContext }
        self.artifactDirectory = artifactDirectory; self.entry = entry
        try FileManager.default.createDirectory(at: artifactDirectory, withIntermediateDirectories: true)
    }
    public func prepare(_ request: GameWebRunRequest) async throws -> GamePreparedWebRun {
        guard jobs[request.id] == nil else { throw GameProjectError.invalidContext }
        let context = request.context, engine = request.engine
        let target = artifactDirectory.appendingPathComponent(request.id.uuidString.lowercased()), entry = entry
        let task = Task.detached {
            let inspection = try GameProjectInspector().inspect(context: context)
            let package = try GameWebArtifactPackage.build(source: context, engine: engine, entry: entry, to: target)
            return GamePreparedWebRun(inspection: inspection, package: package)
        }
        jobs[request.id] = task
        defer { jobs.removeValue(forKey: request.id) }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { task.cancel() })
    }
    public func cancel(_ request: GameWebRunRequest) async {
        guard let job = jobs[request.id] else { return }
        job.cancel(); _ = await job.result
        jobs.removeValue(forKey: request.id)
    }
}
