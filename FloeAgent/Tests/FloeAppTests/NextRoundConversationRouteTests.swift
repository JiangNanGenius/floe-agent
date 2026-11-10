// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit)
import Foundation
import Testing
import FloePersistence
@testable import FloeApp

@Suite("RQ28 exact conversation existence and navigation generation")
struct NextRoundConversationRouteAvailabilityTests {
    @Test("An archived assistant can be missing from ordinary history while its actual record remains present")
    func filteredProjectionDoesNotMeanDeletion() throws {
        var state = ConversationRouteAvailability()
        let conversation = UUID()
        state.selectionChanged(to: conversation)
        let issued = state.beginCheck(listedIDs: [])
        let request = try #require(issued)
        let result = state.resolve(request, evidence: .present)
        #expect(result == .keepSelection && state.selectedID == conversation)
    }
    @Test("Only an exact missing-store proof can clear the selected conversation")
    func definitiveDeletionRepairsOnlySameOwner() throws {
        var state = ConversationRouteAvailability()
        let conversation = UUID()
        state.selectionChanged(to: conversation)
        let issued = state.beginCheck(listedIDs: [])
        let request = try #require(issued)
        let result = state.resolve(request, evidence: .missing)
        #expect(result == .removeSelected(conversation))
        let duplicate = state.resolve(request, evidence: .missing)
        #expect(duplicate == .ignoreObsolete)
    }
    @Test("Suspended or unavailable storage preserves the existing document instead of inventing a fresh task")
    func unavailableIsNotADeletionDecision() throws {
        var state = ConversationRouteAvailability()
        let conversation = UUID()
        state.selectionChanged(to: conversation)
        let issued = state.beginCheck(listedIDs: [])
        let request = try #require(issued)
        let result = state.resolve(request, evidence: .unavailable)
        #expect(result == .keepSelection && state.selectedID == conversation)
    }
    @Test("A/B/A navigation fences the first A's late missing result")
    func navigationABAIsNotTheOriginalOwner() throws {
        var state = ConversationRouteAvailability()
        let first = UUID(), second = UUID()
        state.selectionChanged(to: first)
        let oldIssued = state.beginCheck(listedIDs: [])
        let old = try #require(oldIssued)
        state.selectionChanged(to: second)
        state.selectionChanged(to: first)
        let currentIssued = state.beginCheck(listedIDs: [])
        let current = try #require(currentIssued)
        let oldResult = state.resolve(old, evidence: .missing)
        #expect(oldResult == .ignoreObsolete && state.selectedID == first)
        let currentResult = state.resolve(current, evidence: .present)
        #expect(currentResult == .keepSelection)
    }
    @Test("A newer positive projection invalidates an outstanding missing probe")
    func positiveReadbackFencesOlderNegativeProbe() throws {
        var state = ConversationRouteAvailability()
        let conversation = UUID()
        state.selectionChanged(to: conversation)
        let oldIssued = state.beginCheck(listedIDs: [])
        let old = try #require(oldIssued)
        let noLookup = state.beginCheck(listedIDs: [conversation])
        #expect(noLookup == nil)
        let stale = state.resolve(old, evidence: .missing)
        #expect(stale == .ignoreObsolete && state.selectedID == conversation)
    }
    @Test("Overlapping history reloads cannot let an older callback consume the current probe")
    func sameRouteProbeOwnershipIsOneShot() throws {
        var state = ConversationRouteAvailability()
        let conversation = UUID()
        state.selectionChanged(to: conversation)
        let firstIssued = state.beginCheck(listedIDs: [])
        let first = try #require(firstIssued)
        let currentIssued = state.beginCheck(listedIDs: [])
        let current = try #require(currentIssued)
        let stale = state.resolve(first, evidence: .missing)
        #expect(stale == .ignoreObsolete)
        let live = state.resolve(current, evidence: .unavailable)
        #expect(live == .keepSelection)
    }
}


private enum RouteQualificationError: Error { case unavailable, deadline }
@Suite("RQ28 actual router/store reconciliation", .serialized)
@MainActor
struct NextRoundConversationRouterTests {
    private func until(_ ready: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !ready() {
            guard ContinuousClock.now < deadline else { throw RouteQualificationError.deadline }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test("The real store hides an archived ordinary assistant in history but retains the selected route until actual deletion")
    func archivedStoreRecordIsNotDeleted() async throws {
        let database = try DatabaseManager.inMemory()
        try await database.migrate()
        let store = SQLiteConversationStore(database: database)
        let conversation = UUID(), run = UUID(), now = Date()
        try await store.saveConversation(.init(id: conversation, title: "Archived assistant fixture", createdAt: now, updatedAt: now))
        try await store.setArchived(id: conversation, archived: true)
        let ordinaryList = try await store.conversations()
        #expect(!ordinaryList.contains { $0.id == conversation })
        let existing = try await store.conversation(id: conversation)
        #expect(existing != nil)
        let router = AppRouter()
        router.openConversation(conversation, runID: run)
        router.showInspector(.progress)
        router.reconcileConversations(Set(ordinaryList.map(\.id)), verifyExists: { id in
            try await store.conversation(id: id) != nil
        })
        try await until { !router.isValidatingConversation }
        #expect(router.workbenchSelection == .conversation(conversation))
        #expect(router.workbenchPath == [conversation] && router.selectedRunID == run)
        #expect(router.inspectorRoute?.content == .progress)
        try await store.deleteConversation(id: conversation)
        router.reconcileConversations([], verifyExists: { id in try await store.conversation(id: id) != nil })
        try await until { !router.isValidatingConversation }
        #expect(router.workbenchSelection == .newTask(workspaceID: nil))
        #expect(router.workbenchPath.isEmpty && router.selectedRunID == nil && !router.inspectorVisible)
    }

    @Test("A failed exact lookup keeps the same task, run, inspector and path")
    func storageFailureCannotNavigateToNewTask() async throws {
        let router = AppRouter(), conversation = UUID(), run = UUID()
        router.openConversation(conversation, runID: run)
        router.showInspector(.workspaceFiles)
        router.reconcileConversations([], verifyExists: { _ in throw RouteQualificationError.unavailable })
        try await until { !router.isValidatingConversation }
        #expect(router.workbenchSelection == .conversation(conversation))
        #expect(router.workbenchPath == [conversation] && router.selectedRunID == run)
        #expect(router.inspectorRoute?.content == .workspaceFiles)
    }

    @Test("An obsolete A callback cannot clear the second A or consume its pending check after A/B/A navigation")
    func oldCallbackCannotEraseReplacementRoute() async throws {
        let router = AppRouter(), first = UUID(), second = UUID()
        var oldReply: CheckedContinuation<Bool, Never>?
        var newReply: CheckedContinuation<Bool, Never>?
        var oldReturned = false
        defer { oldReply?.resume(returning: true); newReply?.resume(returning: true) }
        router.openConversation(first)
        router.reconcileConversations([], verifyExists: { _ in
            let result = await withCheckedContinuation { oldReply = $0 }
            oldReturned = true
            return result
        })
        try await until { oldReply != nil }
        router.openConversation(second)
        router.openConversation(first)
        router.reconcileConversations([], verifyExists: { _ in await withCheckedContinuation { newReply = $0 } })
        try await until { newReply != nil }
        let obsolete = oldReply; oldReply = nil; obsolete?.resume(returning: false)
        try await until { oldReturned }
        await Task.yield()
        #expect(router.workbenchSelection == .conversation(first) && router.isValidatingConversation)
        let current = newReply; newReply = nil; current?.resume(returning: true)
        try await until { !router.isValidatingConversation }
        #expect(router.workbenchSelection == .conversation(first) && router.workbenchPath == [first])
    }

    @Test("A positively listed current or live temporary route does not start an unnecessary durable lookup")
    func listedPresenceKeepsTheExistingSurface() {
        let router = AppRouter(), conversation = UUID()
        router.openConversation(conversation)
        var called = false
        router.reconcileConversations([conversation], verifyExists: { _ in called = true; return false })
        #expect(!called && !router.isValidatingConversation)
        #expect(router.workbenchSelection == .conversation(conversation))
    }
}
#endif
