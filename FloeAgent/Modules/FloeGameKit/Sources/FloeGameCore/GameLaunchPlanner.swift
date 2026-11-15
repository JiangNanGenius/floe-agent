// SPDX-License-Identifier: MPL-2.0
import Foundation

public enum GameRuntimeRoute: Equatable, Sendable {
    case webKit
    /// An App-compiled adapter ID, never the path of a downloaded library.
    case bundledNative(adapterID: String)
}

/// Only the host registers adapters after real capability/resource checks.
/// Project metadata is deliberately unable to decode this registry.
public struct GameAdapterRegistration: Sendable {
    public let engine: GameEngineID
    public let route: GameRuntimeRoute
    public let runtimeReady: Bool
    /// ID of an existing host build service/template, never a shell command.
    public let buildAdapterID: String?

    public init(engine: GameEngineID, route: GameRuntimeRoute,
                runtimeReady: Bool, buildAdapterID: String? = nil) throws {
        guard buildAdapterID.map(GameProjectContext.validIdentifier) ?? true else {
            throw GameProjectError.invalidContext
        }
        if case .bundledNative(let id) = route {
            guard GameProjectContext.validIdentifier(id) else { throw GameProjectError.invalidContext }
            // The selected first Unity route is CI -> Web, not Unity as a Library.
            guard engine != .unity else { throw GameProjectError.unsupportedRoute(engine) }
        }
        self.engine = engine
        self.route = route
        self.runtimeReady = runtimeReady
        self.buildAdapterID = buildAdapterID
    }
}

public struct GameAdapterRegistry: Sendable {
    private var registrations: [GameEngineID: GameAdapterRegistration] = [:]
    public init() {}

    public mutating func register(_ adapter: GameAdapterRegistration) throws {
        guard registrations[adapter.engine] == nil else { throw GameProjectError.duplicateAdapter(adapter.engine) }
        registrations[adapter.engine] = adapter
    }

    public func adapter(for engine: GameEngineID) -> GameAdapterRegistration? { registrations[engine] }
}

/// Metadata for an artifact whose bytes/signature/provenance the host has verified.
/// This module validates structure and context only; it does not verify the bytes
/// or confer runtime, filesystem, networking or build permissions.
public struct GamePreparedArtifact: Equatable, Sendable {
    public let id: UUID
    public let engine: GameEngineID
    public let source: GameProjectContext
    public let route: GameRuntimeRoute
    public let sha256: String
    public let entry: GameRelativePath
    public let gameRoot: String

    public init(id: UUID, engine: GameEngineID, source: GameProjectContext, route: GameRuntimeRoute,
                sha256: String, entry: GameRelativePath, gameRoot: String = ".") throws {
        guard sha256.utf8.count == 64,
              sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
            throw GameProjectError.invalidArtifact
        }
        self.id = id
        self.engine = engine
        self.source = source
        self.route = route
        self.sha256 = sha256
        self.entry = entry
        if gameRoot != "." {
            let path = try GameRelativePath(gameRoot)
            guard !path.value.split(separator: "/").contains(where: { GameProjectReader.versionControlNames.contains($0.lowercased()) }) else {
                throw GameProjectError.invalidArtifact
            }
        }
        self.gameRoot = gameRoot
    }
}

public struct GameBuildRequest: Equatable, Sendable {
    public let engine: GameEngineID
    public let context: GameProjectContext
    public let buildAdapterID: String

    public func validate(current: GameProjectContext) throws { try context.validate(current: current) }
}

public struct GameLaunchPlan: Equatable, Sendable {
    public let engine: GameEngineID
    public let context: GameProjectContext
    public let route: GameRuntimeRoute
    public let artifact: GamePreparedArtifact

    /// Call again after every await and immediately before the host side effect.
    /// Existing jobs/services retain cancellation, run ownership and lifecycle.
    public func validate(current: GameProjectContext) throws { try context.validate(current: current) }
}

public enum GameLaunchUnavailable: Equatable, Sendable {
    case adapterNotRegistered
    case runtimeNotReady
    case buildAdapterNotRegistered
}

public enum GameLaunchDecision: Equatable, Sendable {
    case unrecognized
    case chooseEngine([GameEngineID])
    case unavailable(engine: GameEngineID, reason: GameLaunchUnavailable)
    case build(GameBuildRequest)
    case launch(GameLaunchPlan)
}

/// Pure project-level planning. Never uses an active editor file, spawns a
/// process, opens WebKit, downloads an engine or dispatches a CI workflow.
public enum GameLaunchPlanner {
    public static func plan(inspection: GameProjectInspection, context: GameProjectContext,
                            selectedEngine: GameEngineID? = nil, registry: GameAdapterRegistry,
                            artifact: GamePreparedArtifact? = nil) throws -> GameLaunchDecision {
        guard let inspectedContext = inspection.context else { throw GameProjectError.invalidContext }
        try inspectedContext.validate(current: context)
        guard inspection.rootURL == context.rootURL else {
            throw GameProjectError.contextChanged(.root)
        }
        let engines = inspection.candidates.map(\.engine)
        let engine: GameEngineID
        if let selectedEngine {
            guard engines.contains(selectedEngine) else { throw GameProjectError.engineNotDetected(selectedEngine) }
            engine = selectedEngine
        } else {
            guard let first = engines.first else { return .unrecognized }
            guard engines.count == 1 else { return .chooseEngine(engines) }
            engine = first
        }
        guard let adapter = registry.adapter(for: engine) else {
            return .unavailable(engine: engine, reason: .adapterNotRegistered)
        }
        guard adapter.runtimeReady else { return .unavailable(engine: engine, reason: .runtimeNotReady) }
        if let artifact {
            guard artifact.engine == engine, artifact.route == adapter.route else { throw GameProjectError.invalidArtifact }
            try artifact.source.validate(current: context)
            return .launch(.init(engine: engine, context: context, route: adapter.route, artifact: artifact))
        }
        guard let builder = adapter.buildAdapterID else {
            return .unavailable(engine: engine, reason: .buildAdapterNotRegistered)
        }
        return .build(.init(engine: engine, context: context, buildAdapterID: builder))
    }
}
