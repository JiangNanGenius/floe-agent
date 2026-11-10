// SPDX-License-Identifier: MPL-2.0
#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeNotes

@MainActor
enum DocumentAssistantLeaveBindings {
    static func installNotes(on session: NotesSession, environment: AppEnvironment,
                             coordinator: DocumentAssistantLeaveCoordinator) {
        session.assistantLeaveGuard = { [weak session, weak environment, weak coordinator] id, reason in
            guard let session, let environment, let coordinator else { return false }
            let visibleID = session.document?.id
            let generation = session.navigationGeneration
            let stillCurrent: @MainActor () -> Bool = { [weak session] in
                guard let session else { return false }
                return session.navigationGeneration == generation && session.document?.id == visibleID
                    && session.documents.contains { $0.id == id && $0.deletedAt == nil }
            }
            do {
                guard let store = session.store, let document = session.documents.first(where: { $0.id == id }),
                      let conversation = try await store.assistantConversation(documentID: id) else {
                    return stillCurrent()
                }
                guard stillCurrent() else { return false }
                let center = environment.conversationCenter
                let work = center.documentAssistantWork(documentID: id, conversationID: conversation, title: document.title)
                return await coordinator.requestLeave(snapshot: work, reason: reason,
                    policy: environment.settingsCenter.documentAssistantLeavePolicy,
                    isStillCurrent: stillCurrent,
                    requestStop: { center.requestStopDocumentAssistantWork($0) },
                    hasOutstandingWork: { center.documentAssistantWorkIsOutstanding($0) },
                    remember: { environment.settingsCenter.setDocumentAssistantLeavePolicy($0) })
            } catch {
                if stillCurrent() { session.errorMessage = error.localizedDescription }
                return false
            }
        }
    }

    /// Looking up the saved binding must not create a new assistant merely
    /// because the user tapped Done on an otherwise untouched document.
    static func studio(record: PersonalContentRecord, environment: AppEnvironment,
                       coordinator: DocumentAssistantLeaveCoordinator,
                       isStillCurrent: @escaping @MainActor () -> Bool) async throws -> Bool {
        let authority = try environment.studioCoordinator.access.get()
        guard let conversation = try await authority.assistant(projectID: record.id) else { return isStillCurrent() }
        guard isStillCurrent() else { return false }
        let center = environment.conversationCenter
        let work = center.documentAssistantWork(documentID: record.id, conversationID: conversation, title: record.title)
        return await coordinator.requestLeave(snapshot: work, reason: .leaveDocument,
            policy: environment.settingsCenter.documentAssistantLeavePolicy,
            isStillCurrent: isStillCurrent,
            requestStop: { center.requestStopDocumentAssistantWork($0) },
            hasOutstandingWork: { center.documentAssistantWorkIsOutstanding($0) },
            remember: { environment.settingsCenter.setDocumentAssistantLeavePolicy($0) })
    }
}
#endif
