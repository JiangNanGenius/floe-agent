// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeGISKit
import FloeHeavyEditorSupport

/// A saved original, read without constructing a WK editor, lock file, cache or store.
nonisolated struct GISProjectSavedSnapshot: Sendable {
    let file: PersonalPreviewFile
    let bytes: Data
    let document: HeavyEditorDocument
    let sha256: String
    var state: EditorJSON { document.content["data"] == .null ? document.content : document.content["data"] }
    func validate() throws { try file.validate(); try file.verifyHash(sha256) }
}

nonisolated enum GISProjectOriginal {
    static func root(in directory: URL) -> URL { directory.appendingPathComponent("GIS", isDirectory: true) }
    static func read(id: UUID, directory: URL, maximumBytes: Int = Int.max) throws -> GISProjectSavedSnapshot {
        let root = root(in: directory)
        let file = try PersonalPreviewFile(root: directory, url: root.appendingPathComponent("Document.json"), maximumBytes: maximumBytes)
        let bytes = try file.data(), document = try JSONDecoder().decode(HeavyEditorDocument.self, from: bytes)
        guard document.schemaVersion == 1, document.id == id, document.kind == .gis else { throw PersonalContentError.invalidProject }
        let state = document.content["data"] == .null ? document.content : document.content["data"]
        guard case .object = state, state["crs"].string != nil, case .array = state["layers"] else { throw PersonalContentError.invalidProject }
        try file.validate()
        return .init(file: file, bytes: bytes, document: document, sha256: previewHash(bytes))
    }
    static func create(id: UUID, title: String, directory: URL) async throws {
        let store = try HeavyEditorProjectStore(directory: root(in: directory), documentID: id, kind: .gis)
        try await store.create(GISWorkbench.makeDocument(title: title, id: id))
        _ = try read(id: id, directory: directory)
    }
    static func copy(_ saved: GISProjectSavedSnapshot, to directory: URL, id: UUID, title: String) async throws {
        try saved.validate()
        var content = saved.document.content.object
        if let existing = content["data"], case .object(var data) = existing {
            data["title"] = .string(title); content["data"] = .object(data)
        } else { content["title"] = .string(title) }
        let copy = HeavyEditorDocument(id: id, kind: .gis, title: title, content: .object(content))
        try await HeavyEditorProjectStore(directory: root(in: directory), documentID: id, kind: .gis).create(copy)
        guard try read(id: id, directory: directory).document == copy else { throw PersonalContentError.invalidProject }
        try saved.validate()
    }
    /// The same project interchange envelope as the actual GIS file.export command.
    static func projectData(_ saved: GISProjectSavedSnapshot) throws -> Data {
        try saved.validate()
        let history = saved.document.content["history"] == .null
            ? EditorJSON.object(["past": .array([]), "future": .array([])]) : saved.document.content["history"]
        return try EditorJSON.object(["kind": .string("gis"), "schemaVersion": .number(1), "data": saved.state, "history": history]).data()
    }
    static func inspection(_ saved: GISProjectSavedSnapshot) throws -> EditorJSON {
        try saved.validate()
        let layers = saved.state["layers"].array.map { layer in
            EditorJSON.object(["id": layer["id"], "name": layer["name"], "kind": layer["kind"], "crs": layer["crs"],
                "visible": layer["visible"], "locked": layer["locked"],
                "featureCount": .number(Double(layer["data"]["features"].array.count)),
                "width": layer["width"], "height": layer["height"], "fields": layer["fields"]])
        }
        return .object(["projectID": .string(saved.document.id.uuidString), "kind": .string("gis"),
            "title": .string(saved.document.title), "baseRevision": .number(Double(saved.document.revision)),
            "contentSHA256": .string(saved.sha256), "crs": saved.state["crs"], "layers": .array(layers)])
    }
}
#endif
