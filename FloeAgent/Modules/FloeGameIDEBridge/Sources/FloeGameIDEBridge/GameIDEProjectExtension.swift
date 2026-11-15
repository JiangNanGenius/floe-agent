// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// A host-resolved existing workspace, shared by the game shell, IDE and Git.
/// Not Codable: imported game metadata cannot select another workspace.
public struct GameIDEWorkspacePin: Equatable, Sendable {
    public let workspaceID: UUID
    public let projectID: UUID
    public let owner: GameProjectOwner
    public let rootURL: URL
    public let environmentID: String?

    public init(workspaceID: UUID, context: GameProjectContext) throws {
        if case .conversation(_, let ownedWorkspace) = context.owner,
           ownedWorkspace != workspaceID { throw GameIDEBridgeError.workspaceChanged }
        self.workspaceID = workspaceID; projectID = context.projectID
        owner = context.owner; rootURL = context.rootURL; environmentID = context.environmentID
    }
    public func validate(context: GameProjectContext) throws {
        guard projectID == context.projectID, owner == context.owner,
              rootURL == context.rootURL, environmentID == context.environmentID else {
            throw GameIDEBridgeError.workspaceChanged
        }
    }
}

public enum GameIDEDestination: Equatable, Sendable {
    case files
    case code(GameRelativePath?)
    case sourceControl
}

public struct GameIDEOpenRequest: Equatable, Sendable {
    public let workspace: GameIDEWorkspacePin
    public let destination: GameIDEDestination
    public init(workspace: GameIDEWorkspacePin, destination: GameIDEDestination) {
        self.workspace = workspace; self.destination = destination
    }
}

/// Whole-project dispatch. There is deliberately no active editor-file field.
public struct GameIDEProjectRunRequest: Equatable, Sendable {
    public let id: UUID
    public let workspace: GameIDEWorkspacePin
    public let context: GameProjectContext
    public let engine: GameEngineID
    public let gameRoot: GameRelativePath?
}

public enum GameIDEBridgeError: Error, Equatable, Sendable {
    case workspaceChanged
    case unsavedChanges
    case superseded
}

extension GameIDEBridgeError: LocalizedError {
    public var errorDescription: String? {
        let zh = Locale.current.language.languageCode?.identifier == "zh"
        switch self {
        case .workspaceChanged: return zh ? "工程已切换，请重新打开游戏。" : "The project changed. Reopen the game."
        case .unsavedChanges: return zh ? "请先保存修改或处理文件冲突。" : "Save changes or resolve file conflicts first."
        case .superseded: return zh ? "这次运行准备已停止。" : "This run preparation was stopped."
        }
    }
}

/// The App adapter opens WorkspaceIDEView/IDESidebar/SourceControlCenter.
/// snapshot() uses the existing authoritative workspace/save service. launch()
/// uses the existing game run/jobs service, not a new process or interpreter.
@MainActor public protocol GameIDEProjectHost: AnyObject {
    func currentWorkspace() -> GameIDEWorkspacePin?
    func open(_ request: GameIDEOpenRequest) throws
    func snapshot(_ workspace: GameIDEWorkspacePin) async throws -> GameProjectContext
    func launch(_ request: GameIDEProjectRunRequest) async throws
    /// The unique request identifies only its owned run. Late cleanup must
    /// never mean "stop whichever run is currently active".
    func stop(requestID: UUID) async
}

/// Optional built-in IDE extension. The IDE passes its actual existing
/// saveAllSurfaces closure, retaining dirty-buffer and conflict handling.
@MainActor public struct IDEProjectRunExtension {
    public let run: @MainActor (_ saveAllSurfaces: @escaping @MainActor () async -> Bool) async throws -> Void
    public let stop: @MainActor () async -> Void
    public init(run: @escaping @MainActor (_ saveAllSurfaces: @escaping @MainActor () async -> Bool) async throws -> Void,
                stop: @escaping @MainActor () async -> Void = {}) {
        self.run = run; self.stop = stop
    }
}

/// Shared by the simple game shell and its existing IDE presentation. This
/// stores no file tree, text buffers, Git index, commits or terminal session.
@MainActor public final class GameIDEProjectExtension {
    public let workspace: GameIDEWorkspacePin
    private let host: any GameIDEProjectHost
    private var generation: UInt64 = 0
    private var activeRequest: UUID?
    private var preparingRequests: Set<UUID> = []

    public init(workspace: GameIDEWorkspacePin, host: any GameIDEProjectHost) {
        self.workspace = workspace; self.host = host
    }
    public func open(_ destination: GameIDEDestination) throws {
        try checkWorkspace()
        try host.open(.init(workspace: workspace, destination: destination))
    }
    public func ideRunExtension(engine: GameEngineID, gameRoot: GameRelativePath? = nil) -> IDEProjectRunExtension {
        IDEProjectRunExtension(run: { [self] saveAll in
            try await run(engine: engine, gameRoot: gameRoot, saveAllSurfaces: saveAll)
        }, stop: { [self] in await stop() })
    }
    public func run(engine: GameEngineID, gameRoot: GameRelativePath? = nil,
                    saveAllSurfaces: @escaping @MainActor () async -> Bool) async throws {
        generation &+= 1
        let token = generation
        try checkWorkspace()
        try Task.checkCancellation()
        let previousPreparations = preparingRequests
        preparingRequests.removeAll()
        for id in previousPreparations {
            await host.stop(requestID: id)
            try check(token)
        }
        guard await saveAllSurfaces() else { throw GameIDEBridgeError.unsavedChanges }
        try check(token)
        let snapshot = try await host.snapshot(workspace)
        try check(token)
        try workspace.validate(context: snapshot)
        // A concurrent Git checkout/save after the snapshot must fence launch.
        let current = try await host.snapshot(workspace)
        try check(token)
        try snapshot.validate(current: current)
        let request = GameIDEProjectRunRequest(id: UUID(), workspace: workspace,
            context: snapshot, engine: engine, gameRoot: gameRoot)
        if let old = activeRequest {
            activeRequest = nil
            await host.stop(requestID: old)
            try check(token)
        }
        preparingRequests.insert(request.id)
        do {
            try await host.launch(request)
            try check(token)
            let after = try await host.snapshot(workspace)
            try check(token)
            try snapshot.validate(current: after)
            preparingRequests.remove(request.id)
            activeRequest = request.id
        } catch {
            preparingRequests.remove(request.id)
            await host.stop(requestID: request.id)
            throw error
        }
    }
    public func stop() async {
        generation &+= 1
        let old = activeRequest
        activeRequest = nil
        var owned = preparingRequests
        preparingRequests.removeAll()
        if let old { owned.insert(old) }
        for id in owned { await host.stop(requestID: id) }
    }
    private func checkWorkspace() throws {
        guard host.currentWorkspace() == workspace else { throw GameIDEBridgeError.workspaceChanged }
    }
    private func check(_ token: UInt64) throws {
        try Task.checkCancellation()
        guard generation == token else { throw GameIDEBridgeError.superseded }
        try checkWorkspace()
    }
}
