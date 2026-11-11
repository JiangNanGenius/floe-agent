// SPDX-License-Identifier: MPL-2.0
import Foundation
import Combine
import FloeCore

struct HelpPresentationOwner: Codable, Hashable, Sendable {
    let conversationID: UUID?
    let runID: UUID
    let requestID: String

    init(conversationID: UUID?, runID: UUID, requestID: String) {
        self.conversationID = conversationID
        self.runID = runID
        self.requestID = requestID
    }
}

struct HelpPresentationReceipt: Codable, Equatable, Sendable {
    let status: String
    let reference: HelpReference
    let explanation: String
}

enum HelpPresentationLayout: String, Sendable { case sheet, popover }

struct HelpPresentation: Identifiable, Equatable, Sendable {
    let id: UUID
    let reference: HelpReference
    let owner: HelpPresentationOwner
    let sceneID: String
    let hostID: UUID
    let generation: UInt64
    var layout: HelpPresentationLayout = .sheet
    var anchorID: UUID?
    var isUserInitiated = false
    var isVisible = false
}

/// Task cancellation can arrive off the main actor. Record it synchronously
/// so a native appearance callback cannot win while actor cleanup is queued.
private final class HelpPresentationCancellationState: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool { lock.withLock { cancelled } }
    func cancel() { lock.withLock { cancelled = true } }
}

/// Routes only to an explicitly registered, current task surface. There is
/// deliberately no key-window lookup, queued presentation, or first-scene fallback.
@MainActor
final class HelpPresentationCoordinator: ObservableObject {
    static let shared = HelpPresentationCoordinator()

    @Published private(set) var presentation: HelpPresentation?

    private struct Host {
        let sceneID: String
        var conversationID: UUID?
        var currentRunID: UUID?
        var isActive: Bool
        var prefersPopover: Bool
        var generation: UInt64 = 0
        let canRead: @MainActor (HelpReference) -> Bool
    }
    private struct AnswerAnchor {
        let sceneID: String
        let conversationID: UUID
        let runID: UUID?
        let reference: HelpReference
        let isVisible: @MainActor () -> Bool
    }
    private struct Pending {
        let continuation: CheckedContinuation<HelpPresentationReceipt, Never>
        let timeout: Task<Void, Never>
        let cancellation: HelpPresentationCancellationState
    }
    private var hosts: [UUID: Host] = [:]
    private var anchors: [UUID: AnswerAnchor] = [:]
    private var pending: [HelpPresentationOwner: Pending] = [:]
    private var retired: Set<HelpPresentationOwner> = []
    private var retiredOrder: [HelpPresentationOwner] = []
    private var retiredRuns: Set<UUID> = []
    private var retiredRunOrder: [UUID] = []
    private var userAppearanceTimeout: Task<Void, Never>?
    private let appearanceTimeout: Duration

    init(appearanceTimeout: Duration = .seconds(3)) {
        self.appearanceTimeout = appearanceTimeout
    }

    @discardableResult
    func registerHost(
        sceneID: String,
        currentConversationID: UUID?,
        currentRunID: UUID? = nil,
        isActive: Bool,
        prefersPopover: Bool = false,
        canRead: @escaping @MainActor (HelpReference) -> Bool = { _ in true }
    ) -> UUID {
        let id = UUID()
        hosts[id] = Host(sceneID: sceneID, conversationID: currentConversationID,
                         currentRunID: currentRunID, isActive: isActive,
                         prefersPopover: prefersPopover, canRead: canRead)
        return id
    }

    func updateHost(
        _ hostID: UUID,
        currentConversationID: UUID?,
        currentRunID: UUID? = nil,
        isActive: Bool,
        prefersPopover: Bool? = nil
    ) {
        guard var host = hosts[hostID] else { return }
        let changedConversation = host.conversationID != currentConversationID
        let changedRun = host.currentRunID != currentRunID
        let changedLayout = prefersPopover.map { $0 != host.prefersPopover } ?? false
        if changedConversation {
            host.generation &+= 1
            if let runID = host.currentRunID,
               !hosts.contains(where: { $0.key != hostID && $0.value.currentRunID == runID
                   && $0.value.conversationID == host.conversationID }) { retireRun(runID) }
        }
        host.conversationID = currentConversationID
        host.currentRunID = currentRunID
        host.isActive = isActive
        if let prefersPopover { host.prefersPopover = prefersPopover }
        hosts[hostID] = host
        guard let current = presentation, current.hostID == hostID else { return }
        if changedConversation || changedLayout {
            finish(current, status: "cancelled", explanation: "The task changed.", retire: true)
        } else if !current.isVisible && (!isActive || !current.isUserInitiated && changedRun && currentRunID != current.owner.runID) {
            finish(current, status: "deferred", explanation: "The task surface is no longer ready.", retire: true)
        }
    }

    func unregisterHost(_ hostID: UUID) {
        guard let host = hosts.removeValue(forKey: hostID) else { return }
        if let runID = host.currentRunID,
           !hosts.values.contains(where: { $0.currentRunID == runID && $0.conversationID == host.conversationID }) {
            retireRun(runID)
        }
        guard let current = presentation, current.hostID == hostID else { return }
        finish(current, status: "cancelled", explanation: "The task surface closed.", retire: true)
    }

    func presentation(for hostID: UUID?) -> HelpPresentation? {
        guard let hostID, presentation?.hostID == hostID else { return nil }
        return presentation
    }

    func presentation(forAnchor anchorID: UUID?) -> HelpPresentation? {
        guard let anchorID, presentation?.layout == .popover,
              presentation?.anchorID == anchorID else { return nil }
        return presentation
    }

    @discardableResult
    func registerAnswerAnchor(sceneID: String, conversationID: UUID, runID: UUID?,
                              reference: HelpReference,
                              isVisible: @escaping @MainActor () -> Bool) -> UUID? {
        guard !sceneID.isEmpty, anchors.count < 256 else { return nil }
        let id = UUID()
        anchors[id] = AnswerAnchor(sceneID: sceneID, conversationID: conversationID, runID: runID,
                                   reference: reference, isVisible: isVisible)
        return id
    }

    func unregisterAnswerAnchor(_ anchorID: UUID) {
        anchors[anchorID] = nil
        guard let current = presentation, current.anchorID == anchorID else { return }
        finish(current, status: "cancelled", explanation: "The guide citation is no longer on this surface.", retire: true)
    }

    func isCurrentAnswerAnchor(_ anchorID: UUID?) -> Bool {
        guard let anchorID, let anchor = anchors[anchorID], anchor.isVisible() else { return false }
        return hosts.values.contains { host in
            host.isActive && host.sceneID == anchor.sceneID && host.conversationID == anchor.conversationID
        }
    }

    /// A historical citation opens only from an explicit user gesture in its
    /// current scene. It has no authority to resume or impersonate an agent run.
    @discardableResult
    func presentFromUser(reference: HelpReference, sceneID: String, currentConversationID: UUID?,
                         preferredAnchorID: UUID? = nil) -> Bool {
        guard presentation == nil, let conversationID = currentConversationID else { return false }
        let matching = hosts.filter { _, host in
            host.isActive && host.sceneID == sceneID && host.conversationID == conversationID
        }
        guard matching.count == 1, let (hostID, host) = matching.first, host.canRead(reference) else { return false }
        let owner = HelpPresentationOwner(conversationID: conversationID,
                                          runID: UUID(), requestID: "user:" + UUID().uuidString)
        let anchorID: UUID?
        if host.prefersPopover {
            let candidates = matchingAnchors(sceneID: sceneID, conversationID: conversationID,
                                             runID: nil, reference: reference, requireRun: false)
            if let preferredAnchorID, candidates.contains(preferredAnchorID) { anchorID = preferredAnchorID }
            else { anchorID = candidates.count == 1 ? candidates.first : nil }
        } else { anchorID = nil }
        presentation = HelpPresentation(id: UUID(), reference: reference, owner: owner,
            sceneID: sceneID, hostID: hostID, generation: host.generation,
            layout: anchorID == nil ? .sheet : .popover, anchorID: anchorID, isUserInitiated: true)
        let presentationID = presentation?.id
        userAppearanceTimeout = Task { [weak self, appearanceTimeout] in
            do { try await Task.sleep(for: appearanceTimeout) } catch { return }
            guard let self, let current = self.presentation, current.id == presentationID,
                  !current.isVisible else { return }
            self.finish(current, status: "deferred", explanation: "The guide did not become visible.", retire: true)
        }
        return true
    }

    func present(reference: HelpReference, owner: HelpPresentationOwner) async -> HelpPresentationReceipt {
        guard !Task.isCancelled, !retired.contains(owner) else {
            return receipt("cancelled", reference, "This help request has ended. Do not retry it automatically.")
        }
        guard !retiredRuns.contains(owner.runID) else {
            return receipt("cancelled", reference,
                "Automatic help presentation ended for this run. Do not reopen it; the user can open a guide link.")
        }
        guard let conversationID = owner.conversationID,
              !owner.requestID.isEmpty, owner.requestID.utf8.count <= 512 else {
            return receipt("deferred", reference, "A current task owner is required.")
        }
        if let current = presentation {
            if current.owner == owner && current.reference == reference && current.isVisible,
               let host = hosts[current.hostID], host.isActive,
               host.conversationID == owner.conversationID, host.currentRunID == owner.runID {
                return receipt("presented", reference, "The guide is visible in the current task.")
            }
            return receipt("deferred", reference, "A help panel is already open or opening.")
        }
        let matching = hosts.filter { _, host in
            host.isActive && !host.sceneID.isEmpty && host.conversationID == conversationID
                && host.currentRunID == owner.runID
        }
        guard matching.count == 1, let (hostID, host) = matching.first else {
            return receipt("deferred", reference, "There is no single active surface for this task and run.")
        }
        guard host.canRead(reference) else {
            return receipt("unavailable", reference, "This guide version is unavailable on this device.")
        }
        let anchorID: UUID?
        if host.prefersPopover {
            let candidates = matchingAnchors(sceneID: host.sceneID, conversationID: conversationID,
                                             runID: owner.runID, reference: reference, requireRun: true)
            guard candidates.count == 1, let candidate = candidates.first else {
                return receipt("deferred", reference,
                    "There is no single visible guide citation in this answer. Keep its guide link available; do not retry automatically.")
            }
            anchorID = candidate
        } else { anchorID = nil }
        let request = HelpPresentation(id: UUID(), reference: reference, owner: owner,
            sceneID: host.sceneID, hostID: hostID, generation: host.generation,
            layout: anchorID == nil ? .sheet : .popover, anchorID: anchorID)
        let cancellation = HelpPresentationCancellationState()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, !cancellation.isCancelled, !retired.contains(owner) else {
                    continuation.resume(returning: receipt("cancelled", reference, "This help request was cancelled."))
                    return
                }
                let timeout = Task { [weak self, appearanceTimeout] in
                    do { try await Task.sleep(for: appearanceTimeout) } catch { return }
                    guard let self, self.presentation?.id == request.id else { return }
                    self.finish(request, status: "deferred", explanation: "The guide did not become visible.", retire: true)
                }
                pending[owner] = Pending(continuation: continuation, timeout: timeout, cancellation: cancellation)
                presentation = request
            }
        } onCancel: {
            cancellation.cancel()
            Task { @MainActor [weak self] in self?.cancel(owner: owner) }
        }
    }

    /// Called from the sheet's native viewDidAppear, never from a binding write.
    func confirmVisible(presentationID: UUID, hostID: UUID) {
        guard var current = presentation, current.id == presentationID, current.hostID == hostID,
              !current.isVisible else { return }
        if pending[current.owner]?.cancellation.isCancelled == true {
            finish(current, status: "cancelled", explanation: "This help request was cancelled. Do not retry it automatically.", retire: true)
            return
        }
        guard let host = hosts[hostID], host.isActive,
              host.generation == current.generation,
              host.conversationID == current.owner.conversationID,
              (current.isUserInitiated || host.currentRunID == current.owner.runID),
              !retired.contains(current.owner), !retiredRuns.contains(current.owner.runID) else { return }
        if current.layout == .popover {
            guard let anchorID = current.anchorID, let anchor = anchors[anchorID],
                  anchor.sceneID == current.sceneID, anchor.conversationID == current.owner.conversationID,
                  anchor.reference == current.reference, anchor.isVisible(),
                  current.isUserInitiated || anchor.runID == current.owner.runID else { return }
        }
        current.isVisible = true
        userAppearanceTimeout?.cancel()
        userAppearanceTimeout = nil
        presentation = current
        if let waiter = pending.removeValue(forKey: current.owner) {
            waiter.timeout.cancel()
            waiter.continuation.resume(returning: receipt("presented", current.reference,
                "The guide is visible in the current task."))
        }
    }

    func dismiss(presentationID: UUID, hostID: UUID) {
        guard let current = presentation, current.id == presentationID, current.hostID == hostID else { return }
        // Closing expresses a UI decision for this run, including a retry
        // with a new tool call id. An explicit citation click remains usable.
        if !current.isUserInitiated { retireRun(current.owner.runID) }
        finish(current, status: "cancelled", explanation: "The help panel was closed. Do not reopen it automatically.", retire: true)
    }

    /// Cancellation may arrive before present; the tombstone also fences that path.
    func cancel(owner: HelpPresentationOwner) {
        retire(owner)
        guard let current = presentation, current.owner == owner else { return }
        finish(current, status: "cancelled", explanation: "This help request was cancelled. Do not retry it automatically.", retire: true)
    }

    func cancel(runID: UUID) {
        retireRun(runID)
        guard let current = presentation, current.owner.runID == runID else { return }
        finish(current, status: "cancelled", explanation: "The task run was cancelled.", retire: true)
    }

    private func finish(_ current: HelpPresentation, status: String, explanation: String, retire shouldRetire: Bool) {
        userAppearanceTimeout?.cancel()
        userAppearanceTimeout = nil
        if shouldRetire { retire(current.owner) }
        if presentation?.id == current.id { presentation = nil }
        if let waiter = pending.removeValue(forKey: current.owner) {
            waiter.timeout.cancel()
            waiter.continuation.resume(returning: receipt(status, current.reference, explanation))
        }
    }

    private func receipt(_ status: String, _ reference: HelpReference, _ explanation: String) -> HelpPresentationReceipt {
        HelpPresentationReceipt(status: status, reference: reference, explanation: explanation)
    }

    private func matchingAnchors(sceneID: String, conversationID: UUID, runID: UUID?,
                                 reference: HelpReference, requireRun: Bool) -> [UUID] {
        anchors.compactMap { id, anchor in
            anchor.sceneID == sceneID && anchor.conversationID == conversationID
                && anchor.reference == reference && (!requireRun || anchor.runID == runID)
                && anchor.isVisible() ? id : nil
        }
    }

    private func retire(_ owner: HelpPresentationOwner) {
        guard retired.insert(owner).inserted else { return }
        retiredOrder.append(owner)
        if retiredOrder.count > 512 { retired.remove(retiredOrder.removeFirst()) }
    }

    private func retireRun(_ runID: UUID) {
        guard retiredRuns.insert(runID).inserted else { return }
        retiredRunOrder.append(runID)
        if retiredRunOrder.count > 256 { retiredRuns.remove(retiredRunOrder.removeFirst()) }
    }
}
