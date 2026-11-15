// SPDX-License-Identifier: MPL-2.0
import Foundation
import WebKit

/// Browser storage and engine-internal filesystems have separate durability
/// boundaries. This status only describes the optional engine close hook.
public enum GameWebSaveFlushStatus: Sendable, Equatable {
    case notRequired
    case saved
    case failed
}

/// One bounded, fixed browser operation; no new native permission or evaluator.
/// A new run cancels the old waiter, and late completions cannot touch it.
@MainActor final class GameWebSaveFlush {
    private struct Pending {
        let id: UUID
        var continuations: [CheckedContinuation<GameWebSaveFlushStatus, Never>]
    }
    private var pending: Pending?
    var isPending: Bool { pending != nil }

    func cancel() {
        let previous = pending
        pending = nil
        previous?.continuations.forEach { $0.resume(returning: .failed) }
    }

    func perform(on view: WKWebView) async -> GameWebSaveFlushStatus {
        let id = UUID()
        return await withCheckedContinuation { continuation in
            if pending != nil {
                pending!.continuations.append(continuation)
                return
            }
            pending = Pending(id: id, continuations: [continuation])
            view.callAsyncJavaScript("""
                if (!window.FloeGame || typeof window.FloeGame.prepareToStop !== 'function') return 'unavailable';
                try { return (await window.FloeGame.prepareToStop()) === true ? 'saved' : 'failed'; }
                catch (_) { return 'failed'; }
                """, arguments: [:], in: nil, in: .page) { [weak self] result in
                    let status: GameWebSaveFlushStatus
                    switch result {
                    case .success(let value):
                        switch value as? String {
                        case "unavailable": status = .notRequired
                        case "saved": status = .saved
                        default: status = .failed
                        }
                    case .failure: status = .failed
                    }
                    self?.finish(id: id, status: status)
                }
            // A user game may return an unresolved promise. Always proceed to
            // stop it; a failed flush remains explicit rather than hanging close.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.finish(id: id, status: .failed)
            }
        }
    }

    private func finish(id: UUID, status: GameWebSaveFlushStatus) {
        guard let current = pending, current.id == id else { return }
        pending = nil
        current.continuations.forEach { $0.resume(returning: status) }
    }
}
