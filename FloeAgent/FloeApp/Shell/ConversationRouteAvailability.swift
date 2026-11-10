// SPDX-License-Identifier: MPL-2.0
import Foundation

/// A sidebar projection is positive evidence for IDs it contains, never a
/// complete inventory: archived/feature-owned/older conversations may be absent.
/// Only an exact native store lookup can establish that a selected row is gone.
struct ConversationRouteAvailability: Sendable {
    enum Evidence: Sendable { case present, missing, unavailable }
    enum Decision: Equatable, Sendable { case keepSelection, removeSelected(UUID), ignoreObsolete }
    struct Request: Equatable, Sendable {
        let conversationID: UUID
        fileprivate let routeGeneration: UUID
        fileprivate let id: UUID
    }
    private(set) var selectedID: UUID?
    private var generation = UUID()
    private var activeRequest: Request?

    mutating func selectionChanged(to id: UUID?) {
        guard selectedID != id else { return }
        selectedID = id
        generation = UUID()
        activeRequest = nil
    }
    mutating func beginCheck(listedIDs: Set<UUID>) -> Request? {
        guard let selectedID, !listedIDs.contains(selectedID) else {
            activeRequest = nil
            return nil
        }
        let request = Request(conversationID: selectedID, routeGeneration: generation, id: UUID())
        activeRequest = request
        return request
    }
    mutating func resolve(_ request: Request, evidence: Evidence) -> Decision {
        guard activeRequest == request, selectedID == request.conversationID,
              generation == request.routeGeneration else { return .ignoreObsolete }
        activeRequest = nil
        switch evidence {
        case .present, .unavailable: return .keepSelection
        case .missing: return .removeSelected(request.conversationID)
        }
    }
}
