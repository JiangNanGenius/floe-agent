// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore

public enum RGSSRuntimeError: Error, Equatable, Sendable, CustomStringConvertible {
    case invalidEngine(String)
    case unsupportedWebEngine(GameEngineID)
    case missingProjectMarker
    case missingScripts(String)
    case encryptedScripts([String])
    case hostPolicyRequiresWebAssembly
    case runtimePackMissing(String)
    case runtimePackDigestMismatch(String)
    case runtimePackFileTooLarge(String)
    case unsafeRelativePath(String)
    case invalidArtifact(String)
    case contextChanged
    case saveStateTooLarge(expected: Int, actual: Int)
    case invalidSaveState(String)
    case invalidInputDeclaration(String)
    case guestEnvironmentMissing
    case guestContextMismatch
    case guestEngineUnavailable(GameEngineID)
    case guestJobNotOwned
    case guestLaunchRejected(String)
    case guestStopFailed
    case io(String)

    public var description: String {
        switch self {
        case .invalidEngine(let value): "invalid RGSS engine \(value)"
        case .unsupportedWebEngine(let engine): "no reviewed Web engine for \(engine.rawValue)"
        case .missingProjectMarker: "no RPG Maker XP/VX/VX Ace project marker or Data scripts layout found"
        case .missingScripts(let path): "missing RGSS script archive \(path)"
        case .encryptedScripts(let names): "encrypted RGSS archives cannot be read: \(names.joined(separator: ", "))"
        case .hostPolicyRequiresWebAssembly: "the host Web runtime policy does not enable WebAssembly"
        case .runtimePackMissing(let path): "runtime pack file missing: \(path)"
        case .runtimePackDigestMismatch(let path): "runtime pack hash mismatch: \(path)"
        case .runtimePackFileTooLarge(let path): "runtime pack file exceeds the bound: \(path)"
        case .unsafeRelativePath(let path): "unsafe relative path: \(path)"
        case .invalidArtifact(let reason): "invalid RGSS artifact: \(reason)"
        case .contextChanged: "the bound project context changed"
        case .saveStateTooLarge(let expected, let actual): "save state is \(actual) bytes (limit \(expected))"
        case .invalidSaveState(let reason): "invalid RGSS save state: \(reason)"
        case .invalidInputDeclaration(let reason): "invalid floe-inputs.json: \(reason)"
        case .guestEnvironmentMissing: "the Linux guest request has no explicit environmentID"
        case .guestContextMismatch: "the Linux guest context no longer matches"
        case .guestEngineUnavailable(let engine): "the Linux guest engine does not support \(engine.rawValue)"
        case .guestJobNotOwned: "the Linux guest job is not owned by this run"
        case .guestLaunchRejected(let reason): "Linux guest launch rejected: \(reason)"
        case .guestStopFailed: "the owned Linux guest job could not be stopped"
        case .io(let reason): "I/O error: \(reason)"
        }
    }
}
