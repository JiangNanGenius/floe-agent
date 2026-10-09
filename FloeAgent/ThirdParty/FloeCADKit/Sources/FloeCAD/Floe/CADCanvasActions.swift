//
//  CADCanvasActions.swift
//  FloeCADKit
//
//  Host injection for the native workbench's Canvas integration. FloeCADKit
//  must not know about the app's Canvas model, so the host installs closures
//  at the presentation site (`FloeCADWorkbenchView(canvasActions:)`) and the
//  workbench exposes exactly two explicit actions:
//
//    * `apply`     — the host writes the current CAD result as an asset and
//                    updates the ORIGINAL bound Canvas node atomically, or
//                    reports that no binding exists.
//    * `makeVariant` — the host creates a NEW Canvas node/branch; the
//                    original node is never touched.
//
//  The closures run on the main actor with the live document and the exact
//  package URL the view was opened for; they own persistence and every error
//  string the workbench shows.
//
//  SPDX-License-Identifier: MPL-2.0
//

import Foundation

/// One Canvas-sync action outcome for the status line. `message` already
/// contains whatever the host wants the user to read (success or failure);
/// the workbench only presents it.
public struct CADCanvasActionResult: Sendable {
    public enum Kind: Sendable {
        case success
        case status
    }

    public var kind: Kind
    public var message: String

    public init(kind: Kind, message: String) {
        self.kind = kind
        self.message = message
    }

    public static func success(_ message: String) -> CADCanvasActionResult {
        CADCanvasActionResult(kind: .success, message: message)
    }

    public static func status(_ message: String) -> CADCanvasActionResult {
        CADCanvasActionResult(kind: .status, message: message)
    }
}

/// Host-injected Canvas workbench actions. The closures are stored as
/// `@MainActor` and are invoked with the exact `FloeCADDocument` the
/// workbench is showing and the package URL it was opened for.
@MainActor
public final class CADCanvasActions {
    public typealias Operation = @MainActor (FloeCADDocument, URL) async -> CADCanvasActionResult

    /// Update the ORIGINAL bound Canvas node in place (identity, name,
    /// position, size and edges preserved). Nil hides the entry.
    public let applyToCanvas: Operation?
    /// Create a NEW Canvas node for this result; the original node is never
    /// modified. Nil hides the entry.
    public let makeVariant: Operation?

    public init(applyToCanvas: Operation? = nil, makeVariant: Operation? = nil) {
        self.applyToCanvas = applyToCanvas
        self.makeVariant = makeVariant
    }
}
