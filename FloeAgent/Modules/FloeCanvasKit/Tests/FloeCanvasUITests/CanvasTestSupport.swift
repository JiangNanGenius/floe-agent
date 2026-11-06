#if canImport(UIKit)
import Foundation
import XCTest
@testable import FloeCanvasUI
import FloeCanvasCore
import FloeCanvasIntegration
import FloeCanvasFlow

/// Shared host stubs for UI tests. Only Integration protocols are
/// conformed; no production types are involved.
enum CanvasTestStubs {
    actor HeldCommitStore: CanvasDocumentStore {
        let base: InMemoryCanvasRepository
        private var pending: CheckedContinuation<Void, Error>?
        private var observer: CheckedContinuation<Void, Never>?
        init(base: InMemoryCanvasRepository) { self.base = base }
        func waitUntilHeld() async {
            if pending != nil { return }
            await withCheckedContinuation { observer = $0 }
        }
        func release(failing: Bool) {
            let next = pending
            pending = nil
            if failing { next?.resume(throwing: CanvasKitError.io("controlled save failure")) }
            else { next?.resume() }
        }
        private func hold() async throws {
            try await withCheckedThrowingContinuation { pending = $0; observer?.resume(); observer = nil }
        }
        func load(canvasID: UUID) async throws -> CanvasSnapshot { try await base.load(canvasID: canvasID) }
        func commit(_ batch: CanvasEditBatch, canvasID: UUID, expectedRevision: Int64, requestID: UUID) async throws -> CanvasCommitReceipt {
            try await hold()
            return try await base.commit(batch, canvasID: canvasID, expectedRevision: expectedRevision, requestID: requestID)
        }
        func commitDocument(_ batch: CanvasDocumentBatch, canvasID: UUID, expectedRevision: Int64, requestID: UUID) async throws -> CanvasCommitReceipt {
            try await hold()
            return try await base.commitDocument(batch, canvasID: canvasID, expectedRevision: expectedRevision, requestID: requestID)
        }
        func undo(canvasID: UUID, expectedRevision: Int64, requestID: UUID) async throws -> CanvasCommitReceipt {
            try await base.undo(canvasID: canvasID, expectedRevision: expectedRevision, requestID: requestID)
        }
        func redo(canvasID: UUID, expectedRevision: Int64, requestID: UUID) async throws -> CanvasCommitReceipt {
            try await base.redo(canvasID: canvasID, expectedRevision: expectedRevision, requestID: requestID)
        }
        func undoHistory(canvasID: UUID) async throws -> [CanvasUndoEntry] { try await base.undoHistory(canvasID: canvasID) }
        func historyAvailability(canvasID: UUID) async throws -> CanvasHistoryAvailability { try await base.historyAvailability(canvasID: canvasID) }
    }

    // MARK: Source service (ICH04)

    final class FakeSourceService: CanvasSourceService, @unchecked Sendable {
        var revision: Int64
        var text: String
        var typed: CanvasContent?
        private(set) var readCount = 0

        init(revision: Int64, text: String, typed: CanvasContent? = nil) {
            self.revision = revision
            self.text = text
            self.typed = typed
        }

        func currentRevision(sourceID: UUID) async throws -> Int64 {
            revision
        }

        func read(
            sourceID: UUID,
            fragment: String?
        ) async throws -> CanvasSourceContent {
            readCount += 1
            return CanvasSourceContent(
                sourceID: sourceID,
                revision: revision,
                text: text,
                fragment: fragment,
                typedContent: typed)
        }
    }

    // MARK: Assistant gateways

    struct FakeAssistantGateway: CanvasAssistantGateway {
        var batch: CanvasEditBatch
        func perform(request: CanvasAssistantRequest) async throws -> CanvasEditBatch {
            batch
        }
    }

    struct FakeProposalGateway: CanvasAssistantProposalGateway {
        var proposal: CanvasAssistantProposal
        func propose(request: CanvasAssistantRequest) async throws -> CanvasAssistantProposal {
            proposal
        }
    }

    // MARK: Step executor (controlled)

    final class FakeStepExecutor: CanvasStepExecutor, @unchecked Sendable {
        struct Call: Hashable {
            var kind: String
            var attemptID: UUID
        }
        private(set) var calls: [Call] = []
        var result: CanvasStepQueryResult

        init(result: CanvasStepQueryResult) {
            self.result = result
        }

        func submitStep(
            _ request: CanvasStepExecutionRequest
        ) async throws -> CanvasStepQueryResult {
            calls.append(.init(kind: "submit", attemptID: request.attemptID))
            var copy = result
            copy.attemptID = request.attemptID
            copy.nodeID = request.node.id
            return copy
        }

        func queryStep(
            attemptID: UUID,
            runID: UUID
        ) async throws -> CanvasStepQueryResult {
            calls.append(.init(kind: "query", attemptID: attemptID))
            var copy = result
            copy.attemptID = attemptID
            return copy
        }

        func queryRun(runID: UUID) async throws -> FlowRunCheckpoint {
            FlowRunCheckpoint(
                runID: runID,
                completedStepIDs: [],
                loopCounters: [:])
        }

        func cancelRun(runID: UUID) async throws {}
    }

    // MARK: Store wrapper with injectable commit failure (draft recovery)

    /// Fails BEFORE delegating while `failNextCommit` is true.
    final class FailingCommitStore: CanvasDocumentStore, @unchecked Sendable {
        let base: InMemoryCanvasRepository
        var failNextCommit = false

        init(base: InMemoryCanvasRepository, failNextCommit: Bool = false) {
            self.base = base
            self.failNextCommit = failNextCommit
        }

        func load(canvasID: UUID) async throws -> CanvasSnapshot {
            try await base.load(canvasID: canvasID)
        }

        func commit(
            _ batch: CanvasEditBatch,
            canvasID: UUID,
            expectedRevision: Int64,
            requestID: UUID
        ) async throws -> CanvasCommitReceipt {
            try await base.commit(
                batch, canvasID: canvasID,
                expectedRevision: expectedRevision, requestID: requestID)
        }

        func commitDocument(
            _ batch: CanvasDocumentBatch,
            canvasID: UUID,
            expectedRevision: Int64,
            requestID: UUID
        ) async throws -> CanvasCommitReceipt {
            if failNextCommit {
                failNextCommit = false
                throw CanvasKitError.io("injected persistence failure")
            }
            return try await base.commitDocument(
                batch, canvasID: canvasID,
                expectedRevision: expectedRevision, requestID: requestID)
        }

        func undo(
            canvasID: UUID,
            expectedRevision: Int64,
            requestID: UUID
        ) async throws -> CanvasCommitReceipt {
            try await base.undo(
                canvasID: canvasID,
                expectedRevision: expectedRevision, requestID: requestID)
        }

        func redo(
            canvasID: UUID,
            expectedRevision: Int64,
            requestID: UUID
        ) async throws -> CanvasCommitReceipt {
            try await base.redo(
                canvasID: canvasID,
                expectedRevision: expectedRevision, requestID: requestID)
        }

        func historyAvailability(canvasID: UUID) async throws -> CanvasHistoryAvailability {
            try await base.historyAvailability(canvasID: canvasID)
        }

        func undoHistory(canvasID: UUID) async throws -> [CanvasUndoEntry] {
            try await base.undoHistory(canvasID: canvasID)
        }
    }

    /// Lost-acknowledgement store: the FIRST commitDocument genuinely
    /// commits and THEN throws I/O, so the caller sees a failure for a
    /// request the repository already accepted. Correct retry behavior is
    /// to replay the SAME request ID and receive the original receipt with
    /// no second mutation.
    final class LostAckStore: CanvasDocumentStore, @unchecked Sendable {
        let base: InMemoryCanvasRepository
        private var armed = true

        init(base: InMemoryCanvasRepository) {
            self.base = base
        }

        func load(canvasID: UUID) async throws -> CanvasSnapshot {
            try await base.load(canvasID: canvasID)
        }

        func commit(
            _ batch: CanvasEditBatch,
            canvasID: UUID,
            expectedRevision: Int64,
            requestID: UUID
        ) async throws -> CanvasCommitReceipt {
            try await base.commit(
                batch, canvasID: canvasID,
                expectedRevision: expectedRevision, requestID: requestID)
        }

        func commitDocument(
            _ batch: CanvasDocumentBatch,
            canvasID: UUID,
            expectedRevision: Int64,
            requestID: UUID
        ) async throws -> CanvasCommitReceipt {
            let receipt = try await base.commitDocument(
                batch, canvasID: canvasID,
                expectedRevision: expectedRevision, requestID: requestID)
            if armed {
                armed = false
                throw CanvasKitError.io("lost acknowledgement after commit")
            }
            return receipt
        }

        func undo(
            canvasID: UUID,
            expectedRevision: Int64,
            requestID: UUID
        ) async throws -> CanvasCommitReceipt {
            try await base.undo(
                canvasID: canvasID,
                expectedRevision: expectedRevision, requestID: requestID)
        }

        func redo(
            canvasID: UUID,
            expectedRevision: Int64,
            requestID: UUID
        ) async throws -> CanvasCommitReceipt {
            try await base.redo(
                canvasID: canvasID,
                expectedRevision: expectedRevision, requestID: requestID)
        }

        func historyAvailability(canvasID: UUID) async throws -> CanvasHistoryAvailability {
            try await base.historyAvailability(canvasID: canvasID)
        }

        func undoHistory(canvasID: UUID) async throws -> [CanvasUndoEntry] {
            try await base.undoHistory(canvasID: canvasID)
        }
    }

    // MARK: Fixtures

    static func snapshot(
        name: String = "Test",
        nodes: [CanvasNodeSnapshot] = []
    ) -> CanvasSnapshot {
        CanvasSnapshot(
            name: name,
            pages: [CanvasPageSnapshot(name: "Page 1", nodes: nodes)])
    }

    static func textNode(
        _ text: String,
        center: CanvasGeometry.Point = .zero,
        title: String? = nil
    ) -> CanvasNodeSnapshot {
        CanvasNodeSnapshot(
            title: title,
            content: .text(text),
            frame: .init(center: center, size: .init(width: 200, height: 120)))
    }
}

#endif // canImport(UIKit)
