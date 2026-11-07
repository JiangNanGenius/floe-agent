// SPDX-License-Identifier: MPL-2.0
import Foundation

public nonisolated enum CADNamedItemKind: String, Codable, Sendable { case body, sketch }

public extension FloeCADDocument {
    /// Renames one existing native item through the same command/undo path
    /// as Items Manager. Geometry and unrelated item names are untouched.
    /// The host still owns task permission, source generation and save/CAS.
    func renameExistingItem(kind: CADNamedItemKind, id: UUID, name rawName: String,
                            expectedChangeCount: Int) -> CADCommandOutcome {
        guard !isClosed, !isReadOnly, session.writeBlock == nil else {
            return Self.jsonOutcome(status: 409, object: ["ok": false, "error": "read_only", "message": "The current CAD document cannot be changed."])
        }
        guard expectedChangeCount == session.changeCount else {
            return Self.jsonOutcome(status: 409, object: ["ok": false, "error": "concurrent_edit", "message": "Re-read the current CAD work before renaming an item."])
        }
        guard let name = CADSavedCamera.normalizedName(rawName) else {
            return Self.jsonOutcome(status: 400, object: ["ok": false, "error": "invalid_name", "message": "Use a nonempty item name of at most 60 characters."])
        }
        let item: DocumentItemRef, before: String
        switch kind {
        case .body:
            guard let body = session.document.bodies.first(where: { $0.id.raw == id }) else {
                return Self.jsonOutcome(status: 404, object: ["ok": false, "error": "unknown_body", "message": "Use an existing body ID from this work's studio.read bodies."])
            }
            item = .body(body.id); before = body.name
        case .sketch:
            guard let sketch = session.document.sketches.first(where: { $0.id.raw == id }) else {
                return Self.jsonOutcome(status: 404, object: ["ok": false, "error": "unknown_sketch", "message": "Use an existing sketch ID from this work's studio.read nativeCAD.sketches."])
            }
            item = .sketch(sketch.id); before = sketch.name
        }
        if before == name {
            return Self.jsonOutcome(status: 200, object: ["ok": true, "mutated": false, "id": id.uuidString, "name": name])
        }
        guard session.performOwned(RenameItemCommand(item: item, before: before, after: name),
            tag: "native-item-rename", useStandardCommandPath: true) != nil else {
            return Self.jsonOutcome(status: 409, object: ["ok": false, "error": "rename_refused", "message": "The native rename was refused; re-read this work."])
        }
        return Self.jsonOutcome(status: 200, object: ["ok": true, "mutated": true, "id": id.uuidString,
            "kind": kind.rawValue, "name": name, "change_count": session.changeCount])
    }
}
