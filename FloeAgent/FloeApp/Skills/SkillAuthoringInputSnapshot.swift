#if canImport(UIKit)
import Foundation
import FloeCore
import FloePersistence
import FloeTools

/// Frozen native formatting/context, separate from the user's visible goal.
/// Draft/message text remains in its existing stores. Imported source text is
/// data in these instructions and cannot change the .chat permission ceiling.
struct SkillAuthoringInputSnapshot: Codable, Equatable, Sendable {
    let ownerID: UUID
    let runID: UUID
    let attemptID: UUID
    let inputRevision: Int
    let providerID: UUID
    let modelID: UUID
    let instructions: String

    static func storageRoot() throws -> URL {
        try FloeArtifactStore.root().appendingPathComponent("SkillAuthoring", isDirectory: true)
    }

    func persist(root: URL) throws {
        guard instructions.utf8.count <= 262_144 else { throw SkillAuthoringFlowError.packageUnavailable }
        let directory = root.appendingPathComponent(ownerID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("input-" + runID.uuidString + ".json")
        if FileManager.default.fileExists(atPath: url.path) {
            guard try Self.load(ownerID: ownerID, runID: runID, root: root) == self else {
                throw SkillAuthoringFlowError.staleOperation
            }
            return
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(self).write(to: url, options: .withoutOverwriting)
    }

    /// The caller first resolves the actual authoring metadata. Nonmatching
    /// runs are ordinary continuations and receive no old feature context.
    /// For a matching attempt, missing/corrupt bytes are a real launch error.
    static func instructions(conversationID: UUID, runID: UUID,
                             providerID: UUID, modelID: UUID,
                             expectedAttempt: SkillAuthoringAttemptToken?,
                             root: URL? = nil) throws -> String? {
        guard let expectedAttempt, expectedAttempt.conversationID == conversationID,
              expectedAttempt.runID == runID else { return nil }
        let value = try load(ownerID: conversationID, runID: runID, root: try root ?? storageRoot())
        guard value.ownerID == conversationID, value.runID == runID,
              value.attemptID == expectedAttempt.attemptID,
              value.inputRevision == expectedAttempt.inputRevision,
              value.providerID == providerID, value.modelID == modelID else {
            throw SkillAuthoringFlowError.staleOperation
        }
        return value.instructions
    }

    private static func load(ownerID: UUID, runID: UUID, root: URL) throws -> Self {
        let url = root.appendingPathComponent(ownerID.uuidString, isDirectory: true)
            .appendingPathComponent("input-" + runID.uuidString + ".json")
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey])
        guard attributes.isSymbolicLink != true, let size = attributes.fileSize,
              (1...1_572_864).contains(size) else { throw SkillAuthoringFlowError.sourceUnavailable }
        let data = try Data(contentsOf: url)
        guard data.count <= 1_572_864 else { throw SkillAuthoringFlowError.sourceUnavailable }
        return try JSONDecoder().decode(Self.self, from: data)
    }
}
#endif
