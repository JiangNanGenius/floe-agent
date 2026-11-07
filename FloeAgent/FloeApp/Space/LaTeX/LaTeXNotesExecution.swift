// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloePersistence

extension TaskExecutionEnvironmentCenter {
    /// Notes already owns a confined session workspace. Pin that exact Linux
    /// environment through the normal binding service, preserving any saved
    /// choice rather than consulting ordinary task/global defaults.
    func resolveNotesBinding(conversationID:UUID,runID:UUID,root:URL) async throws -> TaskExecutionBinding {
        let app=environmentForNotesBinding
        let store=TaskExecutionBindingStore(database:app.database)
        if let saved=try await store.binding(conversationID:conversationID) {
            guard saved.target.backend == .linuxVM else {throw FloeError.validationFailed("This Notes task needs its saved local Linux environment.")}
            return try await resolveBinding(conversationID:conversationID,runID:runID,root:root,workspace:nil,override:saved.target.environmentID)
        }
        let workspaceID=FloeDigest.sha256Hex(Data(root.resolvingSymlinksInPath().standardizedFileURL.path.utf8))
        let record=try await app.environmentRegistry.ensureSessionContainer(conversationID:conversationID.uuidString,
            workspaceID:workspaceID,workspaceRootPath:root.path,executionBackend:.linuxVM)
        guard record.effectiveExecutionBackend == .linuxVM,record.ownerID?.lowercased()==conversationID.uuidString.lowercased() else {throw PersonalContentError.changedDocument}
        return try await resolveBinding(conversationID:conversationID,runID:runID,root:root,workspace:nil,override:record.id)
    }
}
#endif
