//
//  CADAnimationService.swift (service facade)
//  FloeCADKit
//
//  Small JSON façade matching the existing material/parameter service shape,
//  so the app bridge can route `cad.document` action=animation with the same
//  revision pin and commit/rollback helper. Authored actions are ordinary
//  undoable document commands; capture/export remain explicit async APIs on
//  `FloeCADDocument` because they render the live Present.
//

import Foundation

@MainActor
public final class CADAnimationService {
    public nonisolated static let actions: [String] = [
        "list", "query", "createClip", "updateClip", "deleteClip",
        "setActiveClip", "addTrack", "deleteTrack", "setKeyframe",
        "setCameraKeyframe", "setPartKeyframe", "deleteKeyframe",
        "preset", "evaluate", "undo", "redo",
    ]

    public let document: FloeCADDocument

    public init(document: FloeCADDocument) {
        self.document = document
    }

    /// One JSON-shaped authored/read action. Never throws for expected errors.
    public func handle(action: String, args: [String: Any]) -> [String: Any] {
        var payload = args
        payload["action"] = action
        let outcome = document.animationJSON(payload)
        if let object = (try? JSONSerialization.jsonObject(
            with: outcome.payload)) as? [String: Any] {
            return object
        }
        return [
            "ok": false,
            "error": outcome.errorCode ?? "animation_failed",
            "message": outcome.message ?? "The animation operation returned no readable result.",
        ]
    }

    /// Evaluate one clip (defaults to the active clip) without mutating the
    /// document. Useful for a query action that needs explicit timing.
    public func evaluateJSON(clipID: UUID?, time: Double) -> [String: Any] {
        do {
            let evaluation = try document.evaluateAnimation(
                clipID: clipID, time: time)
            var object = FloeCADDocument.evaluationJSON(evaluation)
            object["ok"] = true
            return object
        } catch let error as CADDocumentError {
            return ["ok": false, "error": error.code, "message": error.message]
        } catch {
            return ["ok": false, "error": "animation_failed",
                    "message": error.localizedDescription]
        }
    }
}
