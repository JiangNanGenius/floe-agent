// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameStarterKit

/// One presentation record for the exact 20-engine contract. It is derived
/// from the reviewed starter catalog, not a second engine list: every value
/// (entry file, readiness, licenses, prerequisites, physical key declaration)
/// is copied from `GameStarterDescriptor`. A caller cannot register an engine.
public struct GameEngineLibraryEntry: Identifiable, Equatable, Sendable {
    public let engine: GameEngineID
    public let displayName: String
    public let starterVersion: String
    public let entry: GameRelativePath
    public let webEntry: GameRelativePath?
    public let readiness: GameStarterReadiness
    public let templateKind: GameStarterTemplateKind
    public let sourceLicense: String
    public let engineLicense: String
    public let prerequisites: [GameStarterPrerequisite]
    public let runtimePackID: String?
    public let runtimePackFileCount: Int
    public let defaultMovement: GameStarterInputDeclaration.Movement
    public let defaultButtons: [GameStarterInputDeclaration.Button]
    public let expectedFileCount: Int
    public let notes: [String]

    public var id: GameEngineID { engine }

    /// True when creating the starter requires a prepared, byte-verified
    /// Phaser/KAPLAY/Babylon/PlayCanvas pack. It is not an "installed" claim.
    public var requiresPreparedRuntimePack: Bool {
        readiness == .runtimePackRequired
    }

    /// Buttons whose declaration contains more than one key are real chords.
    /// The App must never flatten these into a single synthetic ABXY button.
    public var chordButtons: [GameStarterInputDeclaration.Button] {
        defaultButtons.filter { $0.keys.count > 1 }
    }

    public var movementChordCount: Int {
        [defaultMovement.left, defaultMovement.right, defaultMovement.up, defaultMovement.down]
            .filter { $0.count > 1 }.count
    }

    /// Human-readable prerequisites for the overview. It never renders a
    /// prerequisite as installed; the starter host decides its own readiness.
    public var prerequisiteSummary: String {
        let values = prerequisites.map { "\($0.name) \($0.version)" }
        return values.isEmpty ? "" : values.joined(separator: " · ")
    }
}

/// The exact twenty engines from the bundled starter catalog. Loading is
/// fail-closed: a missing/corrupt catalog or a non-20 set throws instead of
/// returning an empty or partial product list.
public struct GameEngineLibrary: Sendable {
    public let catalogVersion: String
    public let entries: [GameEngineLibraryEntry]

    public init(catalog: GameStarterCatalog) throws {
        guard catalog.engines.count == GameEngineID.allCases.count,
              Set(catalog.engines.map(\.engine)) == Set(GameEngineID.allCases) else {
            throw GameStarterError.invalidCatalog("engine library must cover exactly the 20 engines")
        }
        self.catalogVersion = catalog.catalogVersion
        self.entries = catalog.engines
            .sorted { $0.engine.rawValue < $1.engine.rawValue }
            .map { descriptor in
                GameEngineLibraryEntry(
                    engine: descriptor.engine,
                    displayName: descriptor.displayName,
                    starterVersion: descriptor.starterVersion,
                    entry: descriptor.entry,
                    webEntry: descriptor.webEntry,
                    readiness: descriptor.readiness,
                    templateKind: descriptor.templateKind,
                    sourceLicense: descriptor.sourceLicense,
                    engineLicense: descriptor.engineLicense,
                    prerequisites: descriptor.prerequisites,
                    runtimePackID: descriptor.runtimePack?.id,
                    runtimePackFileCount: descriptor.runtimePack?.files.count ?? 0,
                    defaultMovement: descriptor.defaultInput.movement,
                    defaultButtons: descriptor.defaultInput.buttons,
                    expectedFileCount: descriptor.expectedFiles.count,
                    notes: descriptor.notes)
            }
    }

    public static func bundled() throws -> GameEngineLibrary {
        try GameEngineLibrary(catalog: try GameStarterCatalog.bundled())
    }

    public func entry(for engine: GameEngineID) throws -> GameEngineLibraryEntry {
        guard let entry = entries.first(where: { $0.engine == engine }) else {
            throw GameStarterError.unsupportedEngine(engine)
        }
        return entry
    }

    /// Recognition reuses the existing inspector evidence. The recorded
    /// engine never wins unless the actual project tree contains it.
    public func recognizedEngine(in inspection: GameProjectInspection,
                                 preferred: GameEngineID? = nil) -> GameEngineID? {
        let found = Set(inspection.candidates.map(\.engine))
        if let preferred, found.contains(preferred), entries.contains(where: { $0.engine == preferred }) {
            return preferred
        }
        for entry in entries where found.contains(entry.engine) { return entry.engine }
        return nil
    }

    /// What the creation UI may offer. A runtime-pack starter can be listed
    /// with its actual missing prerequisite, but it is not silently selected.
    public func creationChoices() -> [GameEngineLibraryEntry] {
        entries
    }
}

/// Presentation state for one opened game project. The App maps its actual
/// `GameProjectSelectionSnapshot` into this value; this type only decides
/// which overview controls are honest for that state.
public struct GameProjectOverviewState: Equatable, Sendable {
    public enum State: String, Equatable, Sendable {
        case emptyProject
        case needsExplicitChoice
        case ready
        case unavailable
    }

    public let state: State
    public let engine: GameEngineID?
    public let selectedRoot: String?
    public let identifiedEngines: [GameEngineID]
    public let roots: [String]
    public let hasFiles: Bool
    public let status: String?

    public init(state: State, engine: GameEngineID?, selectedRoot: String?,
                identifiedEngines: [GameEngineID], roots: [String],
                hasFiles: Bool, status: String?) {
        self.state = state
        self.engine = engine
        self.selectedRoot = selectedRoot
        self.identifiedEngines = identifiedEngines
        self.roots = roots
        self.hasFiles = hasFiles
        self.status = status
    }

    /// The four primary overview actions are shown only when a real selected
    /// engine/root exists. Empty or ambiguous projects must choose first.
    public var showsPrimaryActions: Bool { state == .ready && engine != nil }

    /// A user choice is required when a whole-tree import produced multiple
    /// possible roots/engines. AI must not auto-apply a recommendation here.
    public var requiresExplicitSelection: Bool { state == .needsExplicitChoice }

    public var canQuickEdit: Bool { showsPrimaryActions }
    public var canOpenIDE: Bool { showsPrimaryActions }
    public var canPlay: Bool { showsPrimaryActions }
    public var canUseAI: Bool { state == .ready || state == .emptyProject }
}

public enum GameEngineLibraryError: Error, Equatable, LocalizedError {
    case noEngineSelected
    case engineNotRecognized(GameEngineID)
    case runtimePackMissing(GameEngineID)

    public var errorDescription: String? {
        switch self {
        case .noEngineSelected:
            return "Choose a game engine before using this action."
        case .engineNotRecognized(let engine):
            return "The project files do not identify \(engine.rawValue). Choose another engine or inspect the imported tree."
        case .runtimePackMissing(let engine):
            return "The \(engine.rawValue) starter needs its prepared runtime pack before files can be created."
        }
    }
}
