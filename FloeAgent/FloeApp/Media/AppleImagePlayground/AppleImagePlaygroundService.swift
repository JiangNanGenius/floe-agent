import Foundation
import Combine
#if canImport(UIKit) && canImport(ImagePlayground)
import UIKit
import ImagePlayground
#endif

private final class AppleImagePlaygroundCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func cancel() { lock.lock(); value = true; lock.unlock() }
}

/// One App-owned service. A tool call awaits the actual system completion;
/// presenting a sheet is never reported as a generated or saved image.
@MainActor
final class AppleImagePlaygroundService: ObservableObject {
    struct Presentation: Identifiable {
        let id: UUID
        let sceneID: String
        let owner: AppleImagePlaygroundOwner
        let input: AppleImagePlaygroundInput
    }

    private struct Host {
        var visibleConversationIDs: Set<UUID>
        var active: Bool
        var canPresent: @MainActor () -> Bool
    }
    private struct Pending {
        let presentation: Presentation
        let continuation: CheckedContinuation<AppleImagePlaygroundImage, any Error>
        let isCancelled: @Sendable () -> Bool
    }

    @Published private(set) var presentation: Presentation?
    private var pending: Pending?
    private var mountedID: UUID?
    private var closing: (id: UUID, sceneID: String)?
    private var hosts: [String: Host] = [:]
    private var monitor: Task<Void, Never>?
    private let enabled: @MainActor () -> Bool
    private let ownerIsLive: @MainActor (AppleImagePlaygroundOwner) -> Bool
    private let available: @MainActor () -> Bool
    private let supportsEditing: @MainActor () -> Bool

    init(
        enabled: @escaping @MainActor () -> Bool,
        ownerIsLive: @escaping @MainActor (AppleImagePlaygroundOwner) -> Bool,
        available: @escaping @MainActor () -> Bool = { AppleImagePlaygroundService.systemIsAvailable },
        supportsEditing: @escaping @MainActor () -> Bool = {
            if #available(iOS 27.0, macOS 27.0, *) { return true }
            return false
        }
    ) {
        self.enabled = enabled
        self.ownerIsLive = ownerIsLive
        self.available = available
        self.supportsEditing = supportsEditing
    }

    var isAvailable: Bool { enabled() && available() }

    static var systemIsAvailable: Bool {
        #if canImport(UIKit) && canImport(ImagePlayground)
        ImagePlaygroundViewController.isAvailable
        #else
        false
        #endif
    }

    func updateHost(sceneID: String, visibleConversationIDs: Set<UUID>, active: Bool,
                    canPresent: @escaping @MainActor () -> Bool = { true }) {
        hosts[sceneID] = Host(visibleConversationIDs: visibleConversationIDs, active: active, canPresent: canPresent)
        if let current = pending?.presentation, current.sceneID == sceneID,
           !visibleConversationIDs.contains(current.owner.conversationID) {
            fail(id: current.id, error: .ownerChanged)
        }
        // Inactive/background is not navigation: it does not settle or replace
        // an already presented request. New requests still require foreground.
    }

    func removeHost(sceneID: String) {
        hosts[sceneID] = nil
        if let current = pending?.presentation, current.sceneID == sceneID {
            fail(id: current.id, error: .ownerChanged)
        }
        if closing?.sceneID == sceneID { closing = nil }
    }

    func request(
        _ input: AppleImagePlaygroundInput,
        owner: AppleImagePlaygroundOwner,
        isCancelled: @escaping @Sendable () -> Bool
    ) async throws -> AppleImagePlaygroundImage {
        try input.validate()
        guard !Task.isCancelled, !isCancelled() else { throw AppleImagePlaygroundFailure.cancelled }
        guard isAvailable else { throw AppleImagePlaygroundFailure.unavailable }
        guard ownerIsLive(owner) else { throw AppleImagePlaygroundFailure.ownerChanged }
        if input.intent == .edit {
            guard supportsEditing() else { throw AppleImagePlaygroundFailure.editingUnavailable }
        }
        guard pending == nil, closing == nil else { throw AppleImagePlaygroundFailure.busy }
        // An explicit host must own this conversation. Ambiguous multiple
        // scenes fail closed rather than choosing the first global window.
        let eligible = hosts.filter { $0.value.active && $0.value.visibleConversationIDs.contains(owner.conversationID) && $0.value.canPresent() }
        guard eligible.count == 1, let sceneID = eligible.first?.key else {
            throw AppleImagePlaygroundFailure.foregroundRequired
        }
        let request = Presentation(id: UUID(), sceneID: sceneID, owner: owner, input: input)
        let taskCancellation = AppleImagePlaygroundCancellation()
        let cancelled: @Sendable () -> Bool = { taskCancellation.isCancelled || isCancelled() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard !Task.isCancelled, !cancelled() else {
                    continuation.resume(throwing: AppleImagePlaygroundFailure.cancelled)
                    return
                }
                pending = Pending(presentation: request, continuation: continuation, isCancelled: cancelled)
                presentation = request
                monitor = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                        guard let self, self.pending?.presentation.id == request.id else { return }
                        if cancelled() { self.fail(id: request.id, error: .cancelled); return }
                        if !self.ownerIsLive(owner) { self.fail(id: request.id, error: .ownerChanged); return }
                        if !self.isAvailable { self.fail(id: request.id, error: .unavailable); return }
                    }
                }
            }
        } onCancel: {
            taskCancellation.cancel()
            Task { @MainActor [weak self] in self?.fail(id: request.id, error: .cancelled) }
        }
    }

    func receive(id: UUID, imageURL: URL) {
        guard let current = pending, current.presentation.id == id else { return }
        guard !current.isCancelled() else { fail(id: id, error: .cancelled); return }
        guard ownerIsLive(current.presentation.owner) else { fail(id: id, error: .ownerChanged); return }
        do {
            // Freeze and validate the temporary result before dismissing the
            // system sheet. No URL escapes after its system session ends.
            let image = try AppleImagePlaygroundImage(contentsOf: imageURL)
            finish(id: id, result: .success(image))
        } catch {
            fail(id: id, error: .invalidImage)
        }
    }

    /// The native host calls this when it creates the sheet controller. A
    /// cancellation before that point has no UI dismissal to wait for.
    func beginPresentation(id: UUID) -> Bool {
        guard let current = pending, current.presentation.id == id else { return false }
        guard !current.isCancelled() else { fail(id: id, error: .cancelled); return false }
        guard ownerIsLive(current.presentation.owner) else { fail(id: id, error: .ownerChanged); return false }
        guard isAvailable else { fail(id: id, error: .unavailable); return false }
        mountedID = id
        return true
    }

    func fail(id: UUID, error: AppleImagePlaygroundFailure) {
        finish(id: id, result: .failure(error))
    }

    func didDismiss(id: UUID) {
        if pending?.presentation.id == id { fail(id: id, error: .cancelled) }
        if closing?.id == id { closing = nil }
    }

    private func finish(id: UUID, result: Result<AppleImagePlaygroundImage, any Error>) {
        guard let current = pending, current.presentation.id == id else { return }
        pending = nil
        monitor?.cancel()
        monitor = nil
        closing = mountedID == id ? (id, current.presentation.sceneID) : nil
        mountedID = nil
        presentation = nil
        current.continuation.resume(with: result)
    }
}
