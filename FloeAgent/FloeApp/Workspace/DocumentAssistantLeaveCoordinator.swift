// SPDX-License-Identifier: MPL-2.0
import Foundation
import Combine

enum DocumentAssistantLeavePolicy: String, CaseIterable, Sendable {
    case ask, continueInBackground, stopCurrentWork
    static let defaultsKey = "documentAssistant.leavePolicy.v1"
    static func restored(_ raw: String?) -> Self { raw.flatMap(Self.init(rawValue:)) ?? .ask }
}

enum DocumentAssistantNavigationReason: CaseIterable, Sendable {
    case leaveDocument, closeTab, switchDocumentTab, collapseAssistant, temporaryCover, appBackground
    var requiresLeaveDecision: Bool { self == .leaveDocument || self == .closeTab }
}

/// These identities are resolved from the native document/conversation owner,
/// never from model text. The request freezes only the work being left now;
/// another document or a newly started independent run is never added later.
struct DocumentAssistantLeaveSnapshot: Equatable, Sendable {
    let documentID: UUID
    let conversationID: UUID
    let title: String
    let invocationIDs: Set<UUID>
    let preparationIDs: Set<UUID>
    var hasWork: Bool { !invocationIDs.isEmpty || !preparationIDs.isEmpty }
}

@MainActor
final class DocumentAssistantLeaveCoordinator: ObservableObject {
    enum Choice: Sendable { case continueInBackground, stopCurrentWork, cancelNavigation }
    enum Failure: Equatable { case stillStopping, ownerChanged }
    struct Prompt: Identifiable {
        let id: UUID
        let snapshot: DocumentAssistantLeaveSnapshot
    }
    private struct Reply {
        let choice: Choice
        let remember: Bool
    }
    @Published private(set) var prompt: Prompt?
    @Published private(set) var isStopping = false
    @Published private(set) var failure: Failure?
    private(set) var continuedSnapshot: DocumentAssistantLeaveSnapshot?
    private var activeRequest: UUID?
    private var reply: CheckedContinuation<Reply, Never>?
    private var ownerIsCurrent: (@MainActor () -> Bool)?
    private let stopDeadline: Duration

    init(stopDeadline: Duration = .seconds(15)) {
        self.stopDeadline = min(.seconds(15), max(.milliseconds(1), stopDeadline))
    }

    func requestLeave(snapshot: DocumentAssistantLeaveSnapshot,
                      reason: DocumentAssistantNavigationReason,
                      policy: DocumentAssistantLeavePolicy,
                      isStillCurrent: @escaping @MainActor () -> Bool,
                      requestStop: @escaping @MainActor (DocumentAssistantLeaveSnapshot) -> Void,
                      hasOutstandingWork: @escaping @MainActor (DocumentAssistantLeaveSnapshot) -> Bool,
                      remember: @escaping @MainActor (DocumentAssistantLeavePolicy) -> Void) async -> Bool {
        guard activeRequest == nil, !Task.isCancelled, isStillCurrent() else { return false }
        failure = nil
        continuedSnapshot = nil
        guard reason.requiresLeaveDecision, snapshot.hasWork else { return true }
        let id = UUID()
        activeRequest = id
        ownerIsCurrent = isStillCurrent
        defer {
            if activeRequest == id {
                activeRequest = nil; prompt = nil; reply = nil; ownerIsCurrent = nil; isStopping = false
            }
        }
        let decision: Reply
        switch policy {
        case .continueInBackground: decision = Reply(choice: .continueInBackground, remember: false)
        case .stopCurrentWork: decision = Reply(choice: .stopCurrentWork, remember: false)
        case .ask:
            decision = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    reply = continuation
                    prompt = Prompt(id: id, snapshot: snapshot)
                }
            } onCancel: {
                Task { @MainActor [weak self] in self?.choose(requestID: id, .cancelNavigation) }
            }
        }
        guard !Task.isCancelled else { return false }
        guard isStillCurrent() else { failure = .ownerChanged; return false }
        switch decision.choice {
        case .cancelNavigation: return false
        case .continueInBackground:
            continuedSnapshot = snapshot
            if decision.remember { remember(.continueInBackground) }
            return true
        case .stopCurrentWork:
            isStopping = true
            requestStop(snapshot)
            let end = ContinuousClock.now.advanced(by: stopDeadline)
            while hasOutstandingWork(snapshot) {
                guard !Task.isCancelled else { return false }
                guard isStillCurrent() else { failure = .ownerChanged; return false }
                guard ContinuousClock.now < end else { failure = .stillStopping; return false }
                do { try await Task.sleep(for: .milliseconds(10)) }
                catch { return false }
            }
            guard !Task.isCancelled else { return false }
            guard isStillCurrent() else { failure = .ownerChanged; return false }
            if decision.remember { remember(.stopCurrentWork) }
            return true
        }
    }

    func clearFailure() { failure = nil }

    func choose(requestID: UUID, _ choice: Choice, remember: Bool = false) {
        guard activeRequest == requestID, prompt?.id == requestID, let waiting = reply else { return }
        let current = ownerIsCurrent?() == true
        reply = nil; prompt = nil
        waiting.resume(returning: Reply(choice: current ? choice : .cancelNavigation,
                                        remember: current && remember))
    }
}

/// Launch preparation is registered before its first suspension. IDs survive
/// the preparation -> invocation handoff, so a choice made while attachments
/// are being prepared cannot miss the subsequently registered runtime.
struct DocumentAssistantPreparationOwnership: Sendable {
    private struct Entry: Sendable {
        var conversationID: UUID?
        var cancelled = false
    }
    private var entries: [UUID: Entry] = [:]
    mutating func begin(conversationID: UUID?, id: UUID = UUID()) -> UUID {
        precondition(entries[id] == nil)
        entries[id] = Entry(conversationID: conversationID)
        return id
    }
    mutating func bind(_ id: UUID, conversationID: UUID) { entries[id]?.conversationID = conversationID }
    func identities(conversationID: UUID) -> Set<UUID> {
        Set(entries.compactMap { $0.value.conversationID == conversationID ? $0.key : nil })
    }
    func mayExecute(_ id: UUID) -> Bool { entries[id]?.cancelled == false }
    func hasOutstanding(_ ids: Set<UUID>) -> Bool { ids.contains { entries[$0] != nil } }
    mutating func cancel(_ ids: Set<UUID>) { for id in ids { entries[id]?.cancelled = true } }
    mutating func finish(_ id: UUID) { entries[id] = nil }
}

/// The Office host asks before its native close mutates the session. The
/// subsequent Notes selection consumes this one-shot proof instead of asking
/// again after teardown. An unrelated or replacement navigation cannot use it.
struct DocumentAssistantNavigationApproval: Equatable, Sendable {
    let documentID: UUID
    let generation: UUID
    fileprivate let id: UUID
}
struct DocumentAssistantNavigationApprovals: Sendable {
    private var current: DocumentAssistantNavigationApproval?
    mutating func issue(documentID: UUID, generation: UUID) -> DocumentAssistantNavigationApproval {
        let approval = DocumentAssistantNavigationApproval(documentID: documentID, generation: generation, id: UUID())
        current = approval
        return approval
    }
    mutating func consume(_ approval: DocumentAssistantNavigationApproval?, documentID: UUID, generation: UUID) -> Bool {
        guard let approval, approval == current, approval.documentID == documentID,
              approval.generation == generation else { return false }
        current = nil
        return true
    }
    mutating func invalidate() { current = nil }
}
