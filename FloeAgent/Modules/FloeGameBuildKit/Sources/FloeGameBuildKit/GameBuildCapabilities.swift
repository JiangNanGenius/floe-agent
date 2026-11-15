// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public enum GameBuildCapabilityError: Error, Equatable, Sendable {
    /// Retained only for source compatibility with the historical API. Plans no
    /// longer throw this for an engine that has a concrete adapter route.
    case sourceOnlyEngine(GameEngineID)
    case unknownEngine(GameEngineID)
    case inspectionConflict(String)
    case invalidRouteCatalog(String)
    case distributionProfileMissing(String)
}

public enum GameBuildRunner: String, Codable, Sendable {
    /// Steps run on the user's own configured CI runner (GitHub Actions etc.).
    case userCI
    /// A typed in-process host exporter uses existing prepared components.
    case hostExporter
    /// The step genuinely requires the engine's desktop editor (manual).
    case manualEditor
}

public enum GameBuildPlatform: String, Codable, Sendable, CaseIterable {
    case web, windows, macOS, linux, android, ios
}

public enum GameBuildOutputKind: String, Codable, Sendable {
    /// Static files playable through the existing WebKit route.
    case webBundle
    /// A standalone native package for one platform.
    case nativeInstaller
    /// A native project only (for example an Xcode project or a Cocos Android
    /// Gradle project). Never presented as a signed installer.
    case nativeProject
    /// Byte-preserving source archive of the project.
    case sourceArchive
    /// Result of a manual editor export step, packaged afterwards.
    case manualEditorExport
    /// A source-accompanying distribution bundle (notices, readable Floe
    /// source, paired corresponding source/relink material).
    case distributionBundle
}

public struct GameBuildOutput: Equatable, Sendable {
    public let kind: GameBuildOutputKind
    public let platform: GameBuildPlatform?
    public let artifactName: String
    public let producedByStage: String
    /// Honest delivery label; never claims installability a template cannot give.
    public let deliveryNote: String
    public let proof: GameBuildProofLevel
    public let playable: Bool
    public let routeID: String
    public let enabledByDefault: Bool
    public let validation: GameArtifactValidationRule

    public init(kind: GameBuildOutputKind, platform: GameBuildPlatform?, artifactName: String,
                producedByStage: String, deliveryNote: String, proof: GameBuildProofLevel,
                playable: Bool, routeID: String, enabledByDefault: Bool,
                validation: GameArtifactValidationRule) {
        self.kind = kind; self.platform = platform; self.artifactName = artifactName
        self.producedByStage = producedByStage; self.deliveryNote = deliveryNote
        self.proof = proof; self.playable = playable; self.routeID = routeID
        self.enabledByDefault = enabledByDefault; self.validation = validation
    }
}

public struct GameBuildStage: Equatable, Sendable, Codable {
    public let id: String
    public let name: String
    public let runner: GameBuildRunner
    /// Documented engine tool invocations (data for the CI template, never
    /// executed by this package).
    public let commands: [String]
    /// Typed host-exporter binding, when the stage runs in-process.
    public let component: String?

    public init(id: String, name: String, runner: GameBuildRunner,
                commands: [String], component: String? = nil) {
        self.id = id; self.name = name; self.runner = runner
        self.commands = commands; self.component = component
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        runner = try values.decode(GameBuildRunner.self, forKey: .runner)
        commands = try values.decodeIfPresent([String].self, forKey: .commands) ?? []
        component = try values.decodeIfPresent(String.self, forKey: .component)
    }

    private enum CodingKeys: String, CodingKey { case id, name, runner, commands, component }
}

public struct GameEngineTool: Equatable, Sendable {
    public let id: String
    public let version: String
    public let documentation: URL
    public init(id: String, version: String, documentation: URL) {
        self.id = id; self.version = version; self.documentation = documentation
    }
}

public struct GameBuildPrerequisite: Equatable, Sendable, Decodable {
    public let tool: GameEngineTool
    /// Provided by the user's own CI configuration (secrets/runners), never by
    /// this package and never gated on a developer-paid account.
    public let note: String
    /// Optional native/editor/runtime prerequisites must not block a Web or
    /// source route. They are still reported so the user can configure them.
    public let required: Bool

    public init(tool: GameEngineTool, note: String, required: Bool = true) {
        self.tool = tool; self.note = note; self.required = required
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let id = try values.decode(String.self, forKey: .id)
        let version = try values.decode(String.self, forKey: .version)
        let documentation = try values.decode(String.self, forKey: .documentation)
        guard let url = URL(string: documentation), url.scheme == "https" else {
            throw DecodingError.dataCorruptedError(forKey: .documentation, in: values,
                debugDescription: "prerequisite documentation must be HTTPS")
        }
        self.tool = GameEngineTool(id: id, version: version, documentation: url)
        self.note = try values.decode(String.self, forKey: .note)
        self.required = try values.decodeIfPresent(Bool.self, forKey: .required) ?? true
    }

    private enum CodingKeys: String, CodingKey { case id, version, documentation, note, required }
}

/// A concrete, engine-specific route from saved project source to buildable
/// artifacts. Plans name real documented tools, distinguish source / web-ready
/// / native installer / native project outputs, and carry the prerequisites the
/// user's CI or host must satisfy. A route with `proof == .sourceQualified` or
/// `.commandOnly` is usable but is not an executed-build claim.
public struct GameBuildCapabilityPlan: Equatable, Sendable {
    public let engine: GameEngineID
    /// Engine version preserved from inspection metadata (e.g. Unity
    /// ProjectVersion.txt); nil when the source does not declare one.
    public let engineVersion: String?
    public let stages: [GameBuildStage]
    public let outputs: [GameBuildOutput]
    public let prerequisites: [GameBuildPrerequisite]
    public let workflowTemplateID: String
    public let routes: [GameBuildRoute]
    public let adapter: GameBuildAdapterBinding
    public let distributionProfileID: String
    public let sourceTransports: [GameBuildSourceTransportKind]

    public func missingPrerequisites(configured provided: Set<String>) -> [GameBuildPrerequisite] {
        prerequisites.filter { $0.required && !provided.contains($0.tool.id) }
    }

    /// Target-aware prerequisite gate. Only tools required by the routes that
    /// were actually selected may block a build, so a Web-only request does not
    /// fail because an unrelated Android SDK/NDK is not configured. Passing nil
    /// keeps the legacy all-required behavior.
    public func missingPrerequisites(configured provided: Set<String>,
                                     selectedRouteIDs: Set<String>?) -> [GameBuildPrerequisite] {
        guard let selectedRouteIDs else {
            return missingPrerequisites(configured: provided)
        }
        let allRouteRequired = Set(routes.flatMap(\.requires))
        let selectedRequired = Set(routes
            .filter { selectedRouteIDs.contains($0.id) }
            .flatMap(\.requires))
        // Prerequisites that no route names remain global (for example the
        // optional Node toolchain); they preserve the legacy behavior. A tool
        // named by some route is gated only when that route is selected, so a
        // Web-only request does not inherit Android/native tools.
        let globalRequired = Set(prerequisites
            .filter { $0.required && !allRouteRequired.contains($0.tool.id) }
            .map(\.tool.id))
        let requiredIDs = selectedRequired.union(globalRequired)
        return prerequisites.filter {
            $0.required && requiredIDs.contains($0.tool.id) && !provided.contains($0.tool.id)
        }
    }

    public func output(forRouteID id: String) -> GameBuildOutput? {
        outputs.first { $0.routeID == id }
    }

    public var defaultRoutes: [GameBuildRoute] {
        routes.filter(\.enabledByDefault)
    }
}

public enum GameBuildCapabilityRegistry {
    public static func plan(for engine: GameEngineID,
                            inspection: GameProjectInspection) throws -> GameBuildCapabilityPlan {
        guard inspection.context != nil else {
            throw GameBuildCapabilityError.inspectionConflict("planning requires a host-bound inspection")
        }
        let catalog = try GameBuildCatalogLoader.load()
        guard let entry = catalog.engines.first(where: { $0.engine == engine }) else {
            throw GameBuildCapabilityError.unknownEngine(engine)
        }
        let version = inspection.candidates.first(where: { $0.engine == engine })?.evidence
            .compactMap(\.versionHint).first
        let outputs = entry.routes.map { route in
            GameBuildOutput(kind: route.kind, platform: route.platform,
                            artifactName: route.artifactName, producedByStage: route.stageID,
                            deliveryNote: route.deliveryNote, proof: route.proof,
                            playable: route.playable, routeID: route.id,
                            enabledByDefault: route.enabledByDefault, validation: route.validation)
        }
        return .init(engine: engine, engineVersion: version,
                     stages: entry.stages, outputs: outputs,
                     prerequisites: entry.prerequisites,
                     workflowTemplateID: entry.workflowTemplateID ?? "none",
                     routes: entry.routes, adapter: entry.adapter,
                     distributionProfileID: entry.distributionProfileID,
                     sourceTransports: entry.sourceTransports)
    }

    public static func catalog() throws -> GameBuildRouteCatalog {
        try GameBuildCatalogLoader.load()
    }
}
