// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// How the existing run route can reach this engine. This mirrors the reviewed
/// FloeGameRunKit route vocabulary; it is descriptive, not a launch permission.
public enum GameDeveloperEngineRoute: String, Codable, Sendable, CaseIterable {
    case staticWeb
    case portableAssembly
    case narrativeAssembly
    case runtimePack
    case externalBuild
    case guestRuntime
}

/// The honest source of live controls for one engine.
public enum GameDeveloperEngineSupport: String, Codable, Sendable, CaseIterable {
    /// The engine's standard runtime globals are available and a host-injected
    /// adapter registers real fields/actions. No project rebuild is required.
    case bundledHook
    /// An existing Floe bridge (FloeGame snapshot/restore/input) is present;
    /// project-specific fields may additionally register themselves.
    case bridgeContract
    /// Only a complete snapshot/restore path is exposed; no invented setters.
    case snapshotOnly
    /// A host build/export is required. The project-side bridge template is
    /// supplied but this package does not build or sign an engine SDK.
    case hostBuildHook
    /// A real bounded file-RPC overlay is supplied for the host's existing
    /// guest/job/display service; the host owns process launch and file access.
    case guestRuntimeBridge
    /// A guest/native runtime is required and only a written plan exists.
    case guestRuntimePlan
    /// The imported game plays with its own controls and save system.
    case playbackOnly
}

public struct GameDeveloperInstrumentationFile: Codable, Equatable, Sendable, Identifiable {
    public let path: String
    public let purpose: String
    public let purposeZhHans: String
    /// A template in the FloeGameDeveloperKit resource bundle, when one is
    /// supplied. It is never written to a project by this package.
    public let templateResource: String?
    public let action: String

    public var id: String { path }

    public init(path: String, action: String = "create", purpose: String,
                purposeZhHans: String? = nil, templateResource: String? = nil) {
        self.path = path
        self.purpose = purpose
        self.purposeZhHans = purposeZhHans ?? purpose
        self.templateResource = templateResource
        self.action = action
    }
}

public struct GameDeveloperInstrumentationPlan: Codable, Equatable, Sendable {
    public let summary: String
    public let summaryZhHans: String
    public let files: [GameDeveloperInstrumentationFile]
    public let steps: [String]
    public let stepsZhHans: [String]
    public let hookContract: String
    public let requiresRebuild: Bool
    public let limitations: String
    public let limitationsZhHans: String
    public let officialDocumentation: [String]

    public init(summary: String, summaryZhHans: String,
                files: [GameDeveloperInstrumentationFile],
                steps: [String], stepsZhHans: [String],
                hookContract: String, requiresRebuild: Bool,
                limitations: String, limitationsZhHans: String,
                officialDocumentation: [String]) {
        self.summary = summary
        self.summaryZhHans = summaryZhHans
        self.files = files
        self.steps = steps
        self.stepsZhHans = stepsZhHans
        self.hookContract = hookContract
        self.requiresRebuild = requiresRebuild
        self.limitations = limitations
        self.limitationsZhHans = limitationsZhHans
        self.officialDocumentation = officialDocumentation
    }
}

public struct GameDeveloperEngineDescriptor: Codable, Equatable, Sendable, Identifiable {
    public let engine: GameEngineID
    public let displayName: String
    public let displayNameZhHans: String
    public let route: GameDeveloperEngineRoute
    public let support: GameDeveloperEngineSupport
    /// Resource name of the host-injected engine hook. Every selected engine
    /// has one; some hooks intentionally expose only diagnostics and a plan.
    public let hookID: String?
    public let expectedSupports: GameDeveloperSupports
    public let instrumentation: GameDeveloperInstrumentationPlan
    public let notes: String
    public let notesZhHans: String

    public var id: String { engine.rawValue }

    public init(engine: GameEngineID, displayName: String, displayNameZhHans: String? = nil,
                route: GameDeveloperEngineRoute, support: GameDeveloperEngineSupport,
                hookID: String?, expectedSupports: GameDeveloperSupports,
                instrumentation: GameDeveloperInstrumentationPlan,
                notes: String, notesZhHans: String? = nil) {
        self.engine = engine
        self.displayName = displayName
        self.displayNameZhHans = displayNameZhHans ?? displayName
        self.route = route
        self.support = support
        self.hookID = hookID
        self.expectedSupports = expectedSupports
        self.instrumentation = instrumentation
        self.notes = notes
        self.notesZhHans = notesZhHans ?? notes
    }
}

public struct GameDeveloperCapabilityMatrix: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let catalogVersion: String
    public let engineCount: Int
    public let engines: [GameDeveloperEngineDescriptor]

    public init(schemaVersion: Int = 1, catalogVersion: String,
                engines: [GameDeveloperEngineDescriptor]) {
        self.schemaVersion = schemaVersion
        self.catalogVersion = catalogVersion
        self.engineCount = engines.count
        self.engines = engines
    }
}
