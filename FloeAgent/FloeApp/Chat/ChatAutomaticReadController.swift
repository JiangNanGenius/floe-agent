// FloeApp — Autoplay only a newly completed final answer.
#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import Combine

@MainActor
struct ChatReadAloudStream {
    let append: (String) -> Void
    let finish: () -> Void
    let cancel: () -> Void
}

@MainActor
final class ChatAutomaticReadController: ObservableObject {
    private var stream: ChatReadAloudStream?
    private var endedRuns = Set<UUID>()
    private var endedRunOrder: [UUID] = []
    private var baselineMessageIDs: Set<UUID>?
    private var historicalCompletedRunIDs = Set<UUID>()

    func establishHistoryBaseline(_ messageIDs: [UUID], completedRunIDs: [UUID] = []) {
        guard baselineMessageIDs == nil else { return }
        baselineMessageIDs = Set(messageIDs)
        // Event bodies load after the first message page. Remember the
        // already-completed runs even when their final event is not loaded
        // yet, so hydration cannot replay a historical answer.
        historicalCompletedRunIDs = Set(completedRunIDs)
    }

    /// Call only with the typed final-answer projection after run completion.
    /// There is intentionally no streaming/intermediate-text input API here.
    func observeFinalMessages(
        _ messages: [(id: UUID, runID: UUID?, text: String)],
        enabled: Bool, makeStream: (UUID) -> ChatReadAloudStream
    ) {
        let identifiers = Set(messages.map(\.id))
        guard let previous = baselineMessageIDs else {
            baselineMessageIDs = identifiers
            return
        }
        baselineMessageIDs = identifiers
        guard enabled, let message = messages.last,
              !previous.contains(message.id), let owner = message.runID,
              !historicalCompletedRunIDs.contains(owner),
              !endedRuns.contains(owner),
              !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        stream?.cancel()
        markEnded(owner)
        let completed = makeStream(message.id)
        completed.append(message.text)
        completed.finish()
        // Synthesis/input completion is not playback completion. Retain the
        // handle so navigation or a new send can still stop queued audio.
        stream = completed
    }

    func cancel() { stream?.cancel(); stream = nil }

    private func markEnded(_ id: UUID) {
        guard endedRuns.insert(id).inserted else { return }
        endedRunOrder.append(id)
        if endedRunOrder.count > 64 { endedRuns.remove(endedRunOrder.removeFirst()) }
    }
}
#endif
