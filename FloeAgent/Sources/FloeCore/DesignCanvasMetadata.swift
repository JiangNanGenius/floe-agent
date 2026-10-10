import Foundation

// FloeCore — Design state as a typed Canvas node subdocument.
//
// The Canvas project is the single project authority. Design state (brief, spec,
// revisions, anchored feedback, candidates) is stored as a typed JSON
// subdocument inside the bound Canvas node's `metadata`, next to the existing
// `canvas.childProject` binding, and is therefore persisted, revision-checked,
// backed up, synced and forked by the existing Canvas authority — there is no
// independent design store, gallery or project identity. The node ID is the only
// identity and decoding fails when it does not match the requested binding.

public enum DesignCanvasMetadata {
    /// Node-metadata key. Reference the same constant from the app side.
    public static let key = "canvas.design"
    /// Bound to keep a hostile/duplicated payload from bloating a project file.
    public static let maximumBytes = 2 * 1024 * 1024

    public enum CodecError: Error, Equatable {
        case bindingMismatch(expected: String, found: String)
        case tooLarge(Int)
        case newerSchema(found: Int, supported: Int)
        case malformed(String)
        case empty
    }

    /// Encode design state for storage in `node.metadata[key]`. The node binding
    /// is part of the payload so a copied blob cannot silently retarget.
    public static func encode(_ project: DesignProject) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(project)
        guard data.count <= maximumBytes else { throw CodecError.tooLarge(data.count) }
        return String(decoding: data, as: UTF8.self)
    }

    /// Decode design state stored on `nodeID`. Fails closed on binding mismatch,
    /// newer schema or malformed payloads; never rewrites unknown state.
    public static func decode(_ raw: String?, nodeID: String) throws -> DesignProject? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        guard raw.utf8.count <= maximumBytes else { throw CodecError.tooLarge(raw.utf8.count) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let project: DesignProject
        do {
            project = try decoder.decode(DesignProject.self, from: Data(raw.utf8))
        } catch {
            throw CodecError.malformed(String(describing: error))
        }
        guard project.schemaVersion <= DesignProject.currentSchemaVersion else {
            throw CodecError.newerSchema(
                found: project.schemaVersion,
                supported: DesignProject.currentSchemaVersion
            )
        }
        guard project.nodeID == nodeID else {
            throw CodecError.bindingMismatch(expected: nodeID, found: project.nodeID)
        }
        return project
    }

    /// Create or load the design subdocument for a node, verifying that the
    /// content type matches an existing payload.
    public static func loadOrCreate(
        raw: String?,
        nodeID: String,
        contentType: DesignContentType
    ) throws -> DesignProject {
        if let existing = try decode(raw, nodeID: nodeID) { return existing }
        return DesignWorkflowEngine.createProject(nodeID: nodeID, contentType: contentType)
    }
}
