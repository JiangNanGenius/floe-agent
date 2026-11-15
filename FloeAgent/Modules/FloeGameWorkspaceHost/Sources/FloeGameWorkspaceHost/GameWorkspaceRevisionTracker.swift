// SPDX-License-Identifier: MPL-2.0
import Foundation
import FloeGameCore
import FloeGameIDEBridge
import FloeGit

/// A process-local preparation checkpoint, never an imported authorization or
/// a persisted Git/project revision. The actual file snapshot is checked too.
public struct GameWorkspaceRevisionCheckpoint: Equatable, Sendable {
    fileprivate let tracker: UUID
    fileprivate let generation: UInt64
}

public enum GameWorkspaceRevisionFailure: Error, Equatable, Sendable {
    case workspaceChanged
    case sourceChanged
    case closed
}

extension GameWorkspaceRevisionFailure: LocalizedError {
    public var errorDescription: String? {
        let zh = Locale.current.language.languageCode?.identifier == "zh"
        switch self {
        case .workspaceChanged: return zh ? "工作区已切换，请重新打开游戏。" : "The workspace changed. Reopen the game."
        case .sourceChanged: return zh ? "项目已更新，请重新运行。" : "The project changed. Run it again."
        case .closed: return zh ? "游戏项目已关闭。" : "The game project is closed."
        }
    }
}

/// Consumes the SAME Git change event as SourceControlCenter. It stores only
/// an ephemeral invalidation counter; no Git index, file tree or history.
///
/// Notification callbacks are synchronous on the posting thread. A Git event
/// can fence preparation immediately, without waiting for a SwiftUI refresh.
/// File bytes still require the repository's own snapshot/CAS validation:
/// uncooperative external programs need not post this notification.
public final class GameWorkspaceRevisionTracker: @unchecked Sendable {
    public let binding: GameIDEWorkspacePin
    private let id = UUID()
    private let lock = NSLock()
    private let notifications: NotificationCenter
    private var observer: NSObjectProtocol?
    private var generation: UInt64 = 0
    private var active = true
    private var closed = false

    public init(binding: GameIDEWorkspacePin, notifications: NotificationCenter = .default) {
        self.binding = binding; self.notifications = notifications
        observer = notifications.addObserver(forName: .floeGitRepositoryDidChange,
            object: nil, queue: nil) { [weak self] notification in
                guard let root = notification.userInfo?[GitRepositoryChange.rootKey] as? URL else { return }
                self?.noteFilesChanged(under: root)
            }
    }

    deinit { if let observer { notifications.removeObserver(observer) } }

    public func checkpoint() throws -> GameWorkspaceRevisionCheckpoint {
        lock.lock(); defer { lock.unlock() }
        try checkActive()
        return .init(tracker: id, generation: generation)
    }

    public func revisionID() throws -> String {
        lock.lock(); defer { lock.unlock() }
        try checkActive()
        return id.uuidString.lowercased() + ":" + String(generation)
    }

    public func validate(_ checkpoint: GameWorkspaceRevisionCheckpoint) throws {
        lock.lock(); defer { lock.unlock() }
        try checkActive()
        guard checkpoint.tracker == id, checkpoint.generation == generation else {
            throw GameWorkspaceRevisionFailure.sourceChanged
        }
    }

    /// Called by the actual host workspace/lifecycle observer. Returning to
    /// the same workspace never makes an earlier preparation valid again.
    public func noteWorkspaceChanged(to current: GameIDEWorkspacePin?) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        let nextActive = current == binding
        if nextActive != active { generation &+= 1 }
        active = nextActive
    }

    /// Call after an existing file service commits. A changed repository above
    /// a nested game root and a changed file below it both affect this session.
    public func noteFilesChanged(under changed: URL) {
        guard changed.isFileURL, Self.related(binding.rootURL, changed) else { return }
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        generation &+= 1
    }

    /// The host calls this only after adopting an actual managed-file save.
    /// SourceControlCenter then refreshes its existing status/diff pane using
    /// its existing event contract. This does not stage, commit or push.
    public func notifySavedFilesChanged() {
        lock.lock(); let shouldNotify = !closed && active; lock.unlock()
        guard shouldNotify else { return }
        notifications.post(name: .floeGitRepositoryDidChange, object: nil,
            userInfo: [GitRepositoryChange.rootKey: binding.rootURL])
    }

    public func close() {
        lock.lock()
        closed = true; active = false; generation &+= 1
        let old = observer; observer = nil
        lock.unlock()
        if let old { notifications.removeObserver(old) }
    }

    private func checkActive() throws {
        guard !closed else { throw GameWorkspaceRevisionFailure.closed }
        guard active else { throw GameWorkspaceRevisionFailure.workspaceChanged }
    }

    private static func related(_ lhs: URL, _ rhs: URL) -> Bool {
        let a = lhs.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        let b = rhs.standardizedFileURL.resolvingSymlinksInPath().pathComponents
        return a.starts(with: b) || b.starts(with: a)
    }
}
