// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

/// Fail-closed installer errors. The host can map these to concise diagnostics;
/// no case contains project bytes, credentials or a model response.
public enum GameDeveloperInstrumentationError: Error, Equatable, Sendable {
    case unsupportedEngine(GameEngineID)
    case catalogMismatch(GameEngineID, String)
    case staleContext
    case rootNotSelected(String)
    case rootUnrecognized(GameEngineID, String)
    case unsupportedEngineVersion(GameEngineID, String)
    case existingFileCollision(GameRelativePath, String)
    case targetIsDirectory(GameRelativePath)
    case duplicateHelperDefinition(GameRelativePath, String)
    case conflictingAutoload(String, String)
    case sceneSelectionRequired(String)
    case sceneNotFound(String)
    case unsupportedProjectShape(String)
    case invalidProjectFile(String)
    case templateMissing(String)
    case templateIntegrity(String)
    case templateDrift(String)
    case dormancyUnverified(String)
    case planMismatch(String)
    case stalePlan(String)
    case postCommitVerificationFailed(String)
    case contextHandoffFailed(String)
    case limitExceeded(String)
}

extension GameDeveloperInstrumentationError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .unsupportedEngine(let engine):
            return "No project-side developer hook installer exists for \(engine.rawValue)."
        case .catalogMismatch(let engine, let detail):
            return "The \(engine.rawValue) catalog descriptor no longer matches the reviewed installer: \(detail)"
        case .staleContext:
            return "The project, owner, root, environment or saved revision changed. Reopen the project and plan again."
        case .rootNotSelected(let root):
            return "The selected game root is not a directory in this saved revision: \(root.isEmpty ? "<project root>" : root)"
        case .rootUnrecognized(let engine, let detail):
            return "The selected \(engine.rawValue) root does not contain the required engine files: \(detail)"
        case .unsupportedEngineVersion(let engine, let detail):
            return "This \(engine.rawValue) version cannot use the installed hook: \(detail)"
        case .existingFileCollision(let path, let sha):
            return "\(path.value) already exists with different bytes (sha256 \(sha)); the installer never overwrites it."
        case .targetIsDirectory(let path):
            return "\(path.value) is an existing directory; the installer will not replace it with a file."
        case .duplicateHelperDefinition(let path, let symbol):
            return "\(path.value) already declares \(symbol); adding the reviewed helper would create a duplicate."
        case .conflictingAutoload(let key, let value):
            return "The Godot autoload \(key) already exists with a different value: \(value)"
        case .sceneSelectionRequired(let detail):
            return "Choose one Cocos scene explicitly before installing the hook: \(detail)"
        case .sceneNotFound(let detail):
            return "The requested Cocos scene is not in this saved revision: \(detail)"
        case .unsupportedProjectShape(let detail):
            return "This project does not have a supported shape for the requested hook: \(detail)"
        case .invalidProjectFile(let detail):
            return "The project.godot file cannot be patched safely: \(detail)"
        case .templateMissing(let resource):
            return "The reviewed template resource is missing: \(resource)"
        case .templateIntegrity(let detail):
            return "The reviewed template bytes do not match their pins: \(detail)"
        case .templateDrift(let detail):
            return "The plan was created with different template bytes: \(detail)"
        case .dormancyUnverified(let detail):
            return "The helper failed the production-dormancy gate: \(detail)"
        case .planMismatch(let detail):
            return "The plan is not valid for this installer: \(detail)"
        case .stalePlan(let detail):
            return "The project changed after this plan was previewed: \(detail)"
        case .postCommitVerificationFailed(let detail):
            return "The revision was committed but could not be verified: \(detail)"
        case .contextHandoffFailed(let detail):
            return "The revision was committed but the host context handoff failed: \(detail)"
        case .limitExceeded(let detail):
            return "A bounded installer limit was exceeded: \(detail)"
        }
    }
}
