// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameIDEBridge
import FloeGameStarterKit

/// What the current snapshot can be used for. This is a selection state, not a
/// build/run claim: no value here means an engine, editor or runtime is installed.
public enum GameProjectSelectionState: String, Codable, Equatable, Sendable {
    /// The owned project exists but has no game source yet.
    case empty
    /// Source exists but no catalog engine was recognized at any root.
    case unresolved
    /// More than one root or engine is available and no valid choice is stored.
    case ambiguous
    /// Exactly one root and one recognized engine were selected automatically.
    case automatic
    /// A user choice or a revalidated persisted choice is authoritative.
    case confirmed
}

public enum GameProjectSelectionSource: String, Codable, Equatable, Sendable {
    case automatic
    case explicit
    case restored
}

public enum GameProjectEngineStarterSource: String, Codable, Equatable, Sendable {
    case bundledTemplate
    case delegatedProvider
    case preparedRuntimePack
}

/// Whether the host's own toolchain/jobs service reported a prerequisite.
/// `.unverified` is the default and must never be rendered as "installed".
public enum GameProjectHostRequirementState: Equatable, Sendable {
    case unverified
    case reported(available: Bool, detail: String, provider: String)
}

public struct GameProjectPrerequisiteState: Equatable, Sendable {
    public let kind: GameStarterPrerequisiteKind
    public let name: String
    public let version: String
    public let requiredFor: [GameStarterPrerequisiteTarget]
    public let host: GameProjectHostRequirementState

    init(kind: GameStarterPrerequisiteKind, name: String, version: String,
         requiredFor: [GameStarterPrerequisiteTarget], host: GameProjectHostRequirementState) {
        self.kind = kind
        self.name = name
        self.version = version
        self.requiredFor = requiredFor
        self.host = host
    }

    func withHost(_ host: GameProjectHostRequirementState) -> Self {
        .init(kind: kind, name: name, version: version, requiredFor: requiredFor, host: host)
    }
}

/// Catalog-declared creation/readiness metadata plus observed recognition paths.
/// `preparedRuntimePackPresent` only reports whether the host supplied a path;
/// the starter materializer still verifies every pack byte before writing.
public struct GameProjectEngineCapability: Equatable, Sendable {
    public let engine: GameEngineID
    public let displayName: String
    public let starterReadiness: GameStarterReadiness
    public let starterSource: GameProjectEngineStarterSource
    public let prerequisites: [GameProjectPrerequisiteState]
    public let recognizedMarkerPaths: [GameRelativePath]
    public let preparedRuntimePackPresent: Bool?
    public let sourceLicense: String
    public let engineLicense: String

    init(engine: GameEngineID, displayName: String, starterReadiness: GameStarterReadiness,
         starterSource: GameProjectEngineStarterSource,
         prerequisites: [GameProjectPrerequisiteState],
         recognizedMarkerPaths: [GameRelativePath],
         preparedRuntimePackPresent: Bool?, sourceLicense: String, engineLicense: String) {
        self.engine = engine
        self.displayName = displayName
        self.starterReadiness = starterReadiness
        self.starterSource = starterSource
        self.prerequisites = prerequisites
        self.recognizedMarkerPaths = recognizedMarkerPaths
        self.preparedRuntimePackPresent = preparedRuntimePackPresent
        self.sourceLicense = sourceLicense
        self.engineLicense = engineLicense
    }

    func applying(_ reports: [GameProjectHostPrerequisiteReport]) -> Self {
        guard !reports.isEmpty else { return self }
        let updated = prerequisites.map { state -> GameProjectPrerequisiteState in
            guard let report = reports.first(where: {
                $0.engine == engine && $0.kind == state.kind && $0.name == state.name
            }) else { return state }
            return state.withHost(.reported(
                available: report.isAvailable,
                detail: GameProjectSelectionText.bounded(report.detail),
                provider: GameProjectSelectionText.bounded(report.provider)))
        }
        return .init(engine: engine, displayName: displayName,
                     starterReadiness: starterReadiness, starterSource: starterSource,
                     prerequisites: updated, recognizedMarkerPaths: recognizedMarkerPaths,
                     preparedRuntimePackPresent: preparedRuntimePackPresent,
                     sourceLicense: sourceLicense, engineLicense: engineLicense)
    }
}

/// One discovered project root and the catalog engines recognized there.
/// A nil root means the owned project root itself.
public struct GameProjectSelectionChoice: Equatable, Sendable, Identifiable {
    public var id: String { root?.value ?? "." }
    public let root: GameRelativePath?
    public let engines: [GameProjectEngineCapability]
    public let diagnostic: String?

    init(root: GameRelativePath?, engines: [GameProjectEngineCapability],
         diagnostic: String?) {
        self.root = root
        self.engines = engines
        self.diagnostic = diagnostic
    }

    public var isProjectRoot: Bool { root == nil }
}

public enum GameProjectSelectionAmbiguity: Hashable, Sendable {
    case multipleRoots(roots: [GameRelativePath?])
    case multipleEngines(root: GameRelativePath?, engines: [GameEngineID])
    case noEngineRecognized(root: GameRelativePath?)
    case noEngineRecognizedAnywhere
    case persistedSelectionInvalidated(root: GameRelativePath?, engine: GameEngineID?)
}

/// Only the injected host model/task callback can produce this type. The
/// deterministic recommendation below is a distinct type and is never labelled AI.
public struct GameProjectAIEngineRecommendation: Equatable, Sendable {
    public let engine: GameEngineID
    public let root: GameRelativePath?
    public let rationale: String
    /// Host-supplied model/task identity. This package never invents one.
    public let generatedBy: String

    public init(engine: GameEngineID, root: GameRelativePath?,
                rationale: String, generatedBy: String) {
        self.engine = engine
        self.root = root
        self.rationale = rationale
        self.generatedBy = generatedBy
    }
}

public enum GameProjectHeuristicReason: String, Codable, Equatable, Sendable {
    case strongestEvidence
    case tieByCatalogOrder
}

/// Deterministic recognition summary. It is advisory and explicitly not AI.
public struct GameProjectHeuristicRecommendation: Equatable, Sendable {
    public let engine: GameEngineID
    public let root: GameRelativePath?
    public let evidenceCount: Int
    public let tiedEngines: [GameEngineID]
    public let reason: GameProjectHeuristicReason

    init(engine: GameEngineID, root: GameRelativePath?, evidenceCount: Int,
         tiedEngines: [GameEngineID], reason: GameProjectHeuristicReason) {
        self.engine = engine
        self.root = root
        self.evidenceCount = evidenceCount
        self.tiedEngines = tiedEngines
        self.reason = reason
    }
}

public struct GameProjectSelectionChoiceSummary: Equatable, Sendable {
    public let root: GameRelativePath?
    public let engines: [GameEngineID]

    init(root: GameRelativePath?, engines: [GameEngineID]) {
        self.root = root
        self.engines = engines
    }
}

/// Metadata-only request sent to the host's existing model/task callback.
/// File bytes are not forwarded by this package.
public struct GameProjectSelectionRecommendationRequest: Equatable, Sendable {
    public let projectTitle: String
    public let baseRevision: String
    public let recordedEngine: GameEngineID?
    public let isEmptyProject: Bool
    public let choices: [GameProjectSelectionChoiceSummary]

    init(projectTitle: String, baseRevision: String, recordedEngine: GameEngineID?,
         isEmptyProject: Bool, choices: [GameProjectSelectionChoiceSummary]) {
        self.projectTitle = projectTitle
        self.baseRevision = baseRevision
        self.recordedEngine = recordedEngine
        self.isEmptyProject = isEmptyProject
        self.choices = choices
    }
}

public typealias GameProjectSelectionRecommendationHandler =
    @Sendable (GameProjectSelectionRecommendationRequest) async throws -> GameProjectAIEngineRecommendation?

public struct GameProjectHostPrerequisiteReport: Equatable, Sendable {
    public let engine: GameEngineID
    public let kind: GameStarterPrerequisiteKind
    public let name: String
    public let isAvailable: Bool
    public let detail: String
    public let provider: String

    public init(engine: GameEngineID, kind: GameStarterPrerequisiteKind, name: String,
                isAvailable: Bool, detail: String, provider: String) {
        self.engine = engine
        self.kind = kind
        self.name = name
        self.isAvailable = isAvailable
        self.detail = detail
        self.provider = provider
    }
}

/// Optional adapter over the host's existing toolchain/jobs state. Omitting it
/// leaves every prerequisite `.unverified`; this package never probes or installs.
public protocol GameProjectSelectionCapabilityProbe: Sendable {
    func reports(engines: [GameEngineID], context: GameProjectContext) async throws
        -> [GameEngineID: [GameProjectHostPrerequisiteReport]]
}

public struct GameProjectSelectionDiagnostic: Equatable, Sendable {
    public enum Source: String, Equatable, Sendable {
        case store
        case discovery
        case inspection
        case recommendation
        case capabilityProbe
        case coordination
    }

    public let source: Source
    public let message: String

    init(_ source: Source, _ message: String) {
        self.source = source
        self.message = GameProjectSelectionText.bounded(message)
    }
}

/// Immutable result of one refresh/select. All values are read-only; callers
/// cannot fabricate a snapshot that bypasses discovery or ownership checks.
public struct GameProjectSelectionSnapshot: Equatable, Sendable {
    public let schemaVersion: Int
    public let projectID: UUID
    public let owner: GameProjectOwner
    public let environmentID: String?
    public let rootURL: URL
    public let baseRevision: String
    public let recordedEngine: GameEngineID?
    public let fileCount: Int
    public let directoryCount: Int
    public let isEmptyProject: Bool
    public let choices: [GameProjectSelectionChoice]
    public let state: GameProjectSelectionState
    public let selectedRoot: GameRelativePath?
    public let selectedEngine: GameEngineID?
    public let selectionSource: GameProjectSelectionSource?
    public let ambiguities: [GameProjectSelectionAmbiguity]
    public let aiRecommendation: GameProjectAIEngineRecommendation?
    public let heuristicRecommendation: GameProjectHeuristicRecommendation?
    public let diagnostics: [GameProjectSelectionDiagnostic]
    public let persisted: Bool

    init(schemaVersion: Int = 1, projectID: UUID, owner: GameProjectOwner,
         environmentID: String?, rootURL: URL, baseRevision: String,
         recordedEngine: GameEngineID?, fileCount: Int, directoryCount: Int,
         isEmptyProject: Bool, choices: [GameProjectSelectionChoice],
         state: GameProjectSelectionState, selectedRoot: GameRelativePath?,
         selectedEngine: GameEngineID?,
         selectionSource: GameProjectSelectionSource?,
         ambiguities: [GameProjectSelectionAmbiguity],
         aiRecommendation: GameProjectAIEngineRecommendation?,
         heuristicRecommendation: GameProjectHeuristicRecommendation?,
         diagnostics: [GameProjectSelectionDiagnostic], persisted: Bool) {
        self.schemaVersion = schemaVersion
        self.projectID = projectID
        self.owner = owner
        self.environmentID = environmentID
        self.rootURL = rootURL
        self.baseRevision = baseRevision
        self.recordedEngine = recordedEngine
        self.fileCount = fileCount
        self.directoryCount = directoryCount
        self.isEmptyProject = isEmptyProject
        self.choices = choices
        self.state = state
        self.selectedRoot = selectedRoot
        self.selectedEngine = selectedEngine
        self.selectionSource = selectionSource
        self.ambiguities = ambiguities
        self.aiRecommendation = aiRecommendation
        self.heuristicRecommendation = heuristicRecommendation
        self.diagnostics = diagnostics
        self.persisted = persisted
    }

    public var requiresExplicitChoice: Bool { state == .ambiguous }

    public var selectedChoice: GameProjectSelectionChoice? {
        choices.first { $0.root == selectedRoot }
    }

    public func engines(forRoot root: GameRelativePath?) -> [GameProjectEngineCapability] {
        choices.first { $0.root == root }?.engines ?? []
    }

    /// Nil until the snapshot has one runnable root+engine. The run preparer
    /// still performs its own route/prerequisite checks.
    public var runSelection: GameProjectRunSelection? {
        guard state == .automatic || state == .confirmed,
              let engine = selectedEngine,
              choices.contains(where: { choice in
                  choice.root == selectedRoot
                      && choice.engines.contains(where: { $0.engine == engine })
              }) else { return nil }
        return GameProjectRunSelection(projectID: projectID, owner: owner,
            environmentID: environmentID, rootURL: rootURL, baseRevision: baseRevision,
            engine: engine, gameRoot: selectedRoot)
    }

    public func requireRunSelection() throws -> GameProjectRunSelection {
        guard let selection = runSelection else {
            throw GameProjectFlowError.selectionRequired
        }
        return selection
    }

    func withPersistence(_ value: Bool) -> Self {
        .init(schemaVersion: schemaVersion, projectID: projectID, owner: owner,
              environmentID: environmentID, rootURL: rootURL, baseRevision: baseRevision,
              recordedEngine: recordedEngine, fileCount: fileCount,
              directoryCount: directoryCount, isEmptyProject: isEmptyProject,
              choices: choices, state: state, selectedRoot: selectedRoot,
              selectedEngine: selectedEngine, selectionSource: selectionSource,
              ambiguities: ambiguities, aiRecommendation: aiRecommendation,
              heuristicRecommendation: heuristicRecommendation,
              diagnostics: diagnostics, persisted: value)
    }

    func withDiagnostics(_ value: [GameProjectSelectionDiagnostic]) -> Self {
        .init(schemaVersion: schemaVersion, projectID: projectID, owner: owner,
              environmentID: environmentID, rootURL: rootURL, baseRevision: baseRevision,
              recordedEngine: recordedEngine, fileCount: fileCount,
              directoryCount: directoryCount, isEmptyProject: isEmptyProject,
              choices: choices, state: state, selectedRoot: selectedRoot,
              selectedEngine: selectedEngine, selectionSource: selectionSource,
              ambiguities: ambiguities, aiRecommendation: aiRecommendation,
              heuristicRecommendation: heuristicRecommendation,
              diagnostics: value, persisted: persisted)
    }
}

/// Exact engine/root pair consumed by `ExistingWorkspaceGameIDEHost`
/// `ideRunExtension(engine:gameRoot:)`. It carries no files, buffers or Git data.
public struct GameProjectRunSelection: Equatable, Sendable {
    public let projectID: UUID
    public let owner: GameProjectOwner
    public let environmentID: String?
    public let rootURL: URL
    public let baseRevision: String
    public let engine: GameEngineID
    public let gameRoot: GameRelativePath?

    init(projectID: UUID, owner: GameProjectOwner, environmentID: String?,
         rootURL: URL, baseRevision: String, engine: GameEngineID,
         gameRoot: GameRelativePath?) {
        self.projectID = projectID
        self.owner = owner
        self.environmentID = environmentID
        self.rootURL = rootURL
        self.baseRevision = baseRevision
        self.engine = engine
        self.gameRoot = gameRoot
    }

    public func validate(workspace: GameIDEWorkspacePin,
                         context: GameProjectContext) throws {
        guard workspace.projectID == projectID, workspace.owner == owner,
              workspace.rootURL == rootURL,
              workspace.environmentID == environmentID else {
            throw GameProjectFlowError.invalidContext
        }
        try validate(context: context)
    }

    public func validate(context: GameProjectContext) throws {
        guard context.projectID == projectID, context.owner == owner,
              context.rootURL == rootURL,
              context.environmentID == environmentID else {
            throw GameProjectFlowError.invalidContext
        }
        guard context.savedRevision == baseRevision else {
            throw GameProjectFlowError.staleContext(.revision)
        }
    }
}

public enum GameProjectFlowError: Error, Equatable, Sendable {
    case invalidContext
    case wrongOwner
    case staleProject(expected: String, actual: String)
    case staleContext(GameContextChange)
    case unknownEngine(GameEngineID)
    case rootNotAvailable(GameRelativePath?)
    case engineNotRecognized(root: GameRelativePath?, engine: GameEngineID)
    case discovery(String)
    case selectionRequired
    case nonEmptyProject
    case forkIdentityInvalid
    case persistenceFailed(String)
    case superseded
    case contextHandoff(String)
    case project(GameProjectError)
    case starter(GameStarterError)
}

extension GameProjectFlowError: LocalizedError {
    public var errorDescription: String? {
        let zh = Locale.current.language.languageCode?.identifier == "zh"
        switch self {
        case .invalidContext:
            return zh ? "工程或工作区已切换，请重新打开。" : "The project or workspace changed. Reopen it."
        case .wrongOwner:
            return zh ? "这个游戏工程属于另一个任务。" : "This game project belongs to another task."
        case .staleProject:
            return zh ? "工程已更新，请重新读取。" : "The project changed. Refresh it."
        case .staleContext:
            return zh ? "工程内容已更新，请重新选择。" : "The project content changed. Choose again."
        case .unknownEngine:
            return zh ? "这个引擎不在支持的 20 个引擎内。" : "This engine is not one of the supported 20 engines."
        case .rootNotAvailable:
            return zh ? "所选游戏目录已不存在。" : "The selected game folder is no longer available."
        case .engineNotRecognized:
            return zh ? "所选目录中没有识别到这个引擎。" : "That engine was not recognized in the selected folder."
        case .discovery:
            return zh ? "游戏目录无法完成识别。" : "The game folders could not be inspected."
        case .selectionRequired:
            return zh ? "请先选择游戏目录和引擎。" : "Choose a game folder and engine first."
        case .nonEmptyProject:
            return zh ? "请先建立空工程再导入，已有内容不会被覆盖。" : "Create an empty project before importing. Existing content is not overwritten."
        case .forkIdentityInvalid:
            return zh ? "新工程身份无效。" : "The new project identity is invalid."
        case .persistenceFailed:
            return zh ? "无法保存这次选择。" : "The selection could not be saved."
        case .superseded:
            return zh ? "这次选择已被新的操作取代。" : "A newer operation replaced this selection."
        case .contextHandoff:
            return zh ? "工程已导入，但保存上下文尚未更新，请重新打开。" : "The import finished but the saved context is not ready. Reopen the project."
        case .project:
            return zh ? "游戏工程操作失败。" : "The game project operation failed."
        case .starter:
            return zh ? "新游戏创建失败。" : "The new game could not be created."
        }
    }
}

enum GameProjectSelectionText {
    static func bounded(_ value: String, maximum: Int = 2_048) -> String {
        let cleaned = value.unicodeScalars
            .filter { !CharacterSet.controlCharacters.contains($0) }
            .map(String.init)
            .joined()
        guard cleaned.utf8.count > maximum else { return cleaned }
        var result = ""
        for character in cleaned {
            let candidate = result + String(character)
            if candidate.utf8.count > maximum { break }
            result = candidate
        }
        return result
    }

    static func bounded(_ error: any Error) -> String {
        bounded(String(describing: error))
    }

    static func validIdentifier(_ value: String, maximum: Int = 256) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && value.utf8.count <= maximum
            && !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
