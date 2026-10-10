//
//  CADServiceOperations.swift
//  FloeCADKit
//
//  Model-accessible workbench mutations (assembly/drawing/script/mesh) MUST go
//  through the same propose → preview → UI confirm → apply transaction as
//  geometry edits. This file supplies the dispatch table the proposal service
//  uses on its throwaway clone (propose) and on the live document (apply), and
//  the classifier the host uses to refuse direct mutating payload calls.
//
//  Read-only service actions (reports, pages, dimensions, script list/status/
//  preview, mesh boundary) stay directly callable; every mutating action name
//  is listed here so the host never has to guess.
//
//  SPDX-License-Identifier: MPL-2.0
//

import Foundation

/// Result of one service operation, normalized so the proposal service can
/// treat it like an executor outcome.
public nonisolated struct CADServiceOperationOutcome: Sendable {
    public var ok: Bool
    public var errorCode: String?
    public var message: String?
    public var mutated: Bool

    public init(ok: Bool, errorCode: String? = nil, message: String? = nil, mutated: Bool = false) {
        self.ok = ok
        self.errorCode = errorCode
        self.message = message
        self.mutated = mutated
    }
}

public nonisolated enum CADServiceOperations {

    // MARK: Classification

    /// Mutating assembly actions (every one that writes `assemblyData` or
    /// bodies). `report`/`instances`/`dof`/`interference` are read-only.
    public static let mutatingAssemblyActions: Set<String> = [
        "addInstance", "removeInstance", "setTransform", "setVisible",
        "addConstraint", "removeConstraint", "suppressConstraint",
        "solve", "sourceUpdate", "clear",
    ]

    /// Mutating drawing actions. `pages`/`project`/`dimensions`/`export` are
    /// read-only (project pins the fingerprint, which is metadata, but it does
    /// not change user-visible geometry — kept read-only deliberately).
    public static let mutatingDrawingActions: Set<String> = [
        "addPage", "updatePage", "removePage", "standardSheet",
    ]

    /// Mutating script actions. `list`/`status`/`preview` are read-only.
    public static let mutatingScriptActions: Set<String> = [
        "put", "remove", "apply",
    ]

    /// Mutating mesh actions. `boundary` is read-only.
    public static let mutatingMeshActions: Set<String> = [
        "combine", "boolean", "transform", "recomputeNormals",
        "repair", "simplify", "material", "text", "image",
    ]

    /// True when `kind` + `action` would mutate the document and therefore must
    /// not be reachable through a direct payload call.
    public static func isMutating(kind: String, action: String) -> Bool {
        switch kind {
        case "assembly": return mutatingAssemblyActions.contains(action)
        case "drawing": return mutatingDrawingActions.contains(action)
        case "script": return mutatingScriptActions.contains(action)
        case "mesh": return mutatingMeshActions.contains(action)
        default: return false
        }
    }

    /// True when the operation JSON (`{op: "assembly.addConstraint", args:…}`)
    /// names a service operation rather than a geometry command.
    public static func isServiceOperation(_ operation: [String: Any]) -> Bool {
        guard let op = operation["op"] as? String else { return false }
        return op.hasPrefix("assembly.") || op.hasPrefix("drawing.")
            || op.hasPrefix("script.") || op.hasPrefix("mesh.")
    }

    /// The `kind`/`action` behind a service operation name, or nil.
    public static func split(_ op: String) -> (kind: String, action: String)? {
        let parts = op.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        guard ["assembly", "drawing", "script", "mesh"].contains(parts[0]) else { return nil }
        return (parts[0], parts[1])
    }
}

@MainActor
public enum CADServiceOperationExecutor {

    /// Executes one `{op,args}` service operation against `document`. `op` must
    /// be a recognized service operation; the caller has already checked
    /// `CADServiceOperations.isServiceOperation`.
    public static func execute(_ operation: [String: Any],
                               on document: FloeCADDocument) async -> CADServiceOperationOutcome {
        guard let op = operation["op"] as? String,
              let (kind, action) = CADServiceOperations.split(op) else {
            return CADServiceOperationOutcome(ok: false, errorCode: "unknown_service_operation",
                                              message: "Not a workbench service operation.")
        }
        let args = operation["args"] as? [String: Any] ?? [:]
        let reply: [String: Any]
        switch kind {
        case "assembly":
            reply = await CADAssemblyService(document: document).handleAsync(action: action, args: args)
        case "drawing":
            reply = CADDrawingService(document: document).handle(action: action, args: args)
        case "script":
            reply = await CADScriptService(document: document).handle(action: action, args: args)
        case "mesh":
            reply = CADMeshService(document: document).handle(action: action, args: args)
        default:
            return CADServiceOperationOutcome(ok: false, errorCode: "unknown_service_operation",
                                              message: "Unknown service '\(kind)'.")
        }
        let ok = reply["ok"] as? Bool ?? false
        return CADServiceOperationOutcome(ok: ok,
                                          errorCode: reply["error"] as? String,
                                          message: reply["message"] as? String,
                                          mutated: reply["mutated"] as? Bool ?? false)
    }
}
