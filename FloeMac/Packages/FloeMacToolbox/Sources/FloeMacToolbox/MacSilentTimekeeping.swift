// SPDX-License-Identifier: MPL-2.0
import Combine
import Darwin
import Foundation
import FloeToolboxUtilities

protocol MacSilentClockStoring: Sendable {
    func load() async throws -> ToolboxTimekeepingArchive
    func save(_ archive: ToolboxTimekeepingArchive) async throws
}

/// Separate Mac-only archive. Cooperating instances use one lock. An older or
/// noncooperating process is not fenced; this is not a general filesystem CAS.
actor MacSilentClockStore: MacSilentClockStoring {
    private let root: URL
    private let store: ToolboxTimekeepingStore
    private var lockFD: Int32 = -1
    init(root: URL) {
        self.root = root
        self.store = ToolboxTimekeepingStore(url: root.appendingPathComponent("state.json"))
    }
    deinit { if lockFD >= 0 { _ = Darwin.close(lockFD) } }

    private func ensureLock() throws {
        if lockFD >= 0 {
            var fdInfo = stat(), pathInfo = stat()
            guard fstat(lockFD, &fdInfo) == 0,
                  lstat(root.appendingPathComponent("owner.lock").path, &pathInfo) == 0,
                  fdInfo.st_dev == pathInfo.st_dev, fdInfo.st_ino == pathInfo.st_ino,
                  pathInfo.st_nlink == 1 else { throw ToolboxTimekeepingError.staleArchive }
            return
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var directoryInfo = stat()
        guard lstat(root.path, &directoryInfo) == 0,
              (directoryInfo.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR),
              directoryInfo.st_uid == geteuid(), (directoryInfo.st_mode & 0o077) == 0 else {
            throw ToolboxTimekeepingError.invalid
        }
        let path = root.appendingPathComponent("owner.lock").path
        let fd = open(path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ToolboxTimekeepingError.invalid }
        var file = stat(), named = stat()
        guard fstat(fd, &file) == 0, lstat(path, &named) == 0,
              (file.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              file.st_uid == geteuid(), (file.st_mode & 0o077) == 0,
              file.st_nlink == 1, file.st_dev == named.st_dev, file.st_ino == named.st_ino,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            _ = Darwin.close(fd); throw ToolboxTimekeepingError.staleArchive
        }
        lockFD = fd
    }

    func load() async throws -> ToolboxTimekeepingArchive {
        try ensureLock()
        try validateArchivePath()
        let value = try await store.load()
        try ensureLock()
        guard !value.timers.contains(where: { $0.reminder || $0.pendingAlarmAction != nil }) else {
            throw ToolboxTimekeepingError.invalid
        }
        return value
    }

    func save(_ archive: ToolboxTimekeepingArchive) async throws {
        try ensureLock()
        try validateArchivePath()
        guard !archive.timers.contains(where: { $0.reminder || $0.pendingAlarmAction != nil }) else {
            throw ToolboxTimekeepingError.invalid
        }
        try await store.save(archive)
        try ensureLock()
    }

    private func validateArchivePath() throws {
        let path = root.appendingPathComponent("state.json").path
        var info = stat()
        if lstat(path, &info) != 0 {
            guard errno == ENOENT else { throw ToolboxTimekeepingError.invalid }
            return
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
              info.st_uid == geteuid(), info.st_nlink == 1,
              (info.st_mode & 0o077) == 0 else { throw ToolboxTimekeepingError.invalid }
    }
}

/// App-owned silent timer state. Work is admitted synchronously, persisted in
/// order and retained across page reconstruction. No notification bridge is
/// installed and no native reminder is created or pruned.
@MainActor
final class MacSilentTimekeeping: ObservableObject {
    enum Issue: Equatable { case load, save, invalid, limit }
    @Published private(set) var archive = ToolboxTimekeepingArchive()
    @Published private(set) var loaded = false
    @Published private(set) var loading = false
    @Published private(set) var saving = false
    @Published private(set) var issue: Issue?
    private let store: any MacSilentClockStoring
    private var loadTask: Task<Void, Never>?
    private var saveTail: Task<Void, Never>?
    private var saveID: UUID?
    private var deadlineTask: Task<Void, Never>?
    private var closed = false
    private var unconfirmedSave = false
    private var exitOverride = false

    init(store: any MacSilentClockStoring) { self.store = store }

    func load() async {
        if loaded { return }
        if let loadTask { await loadTask.value; return }
        guard !closed else { return }
        loading = true
        let store = self.store
        let task = Task { @MainActor [weak self] in
            do {
                var value = try await store.load()
                let original = value
                value.recover(at: .now)
                guard let self else { return }
                self.archive = value
                self.loaded = true
                self.loading = false
                self.issue = nil
                self.loadTask = nil
                if value != original {
                    self.archive.revision += 1
                    self.enqueueSave()
                }
                self.reschedule()
            } catch {
                guard let self else { return }
                self.loading = false; self.issue = .load; self.loadTask = nil
            }
        }
        loadTask = task
        await task.value
    }

    func startStopwatch() { change { $0.stopwatch.start(at: .now) } }
    func pauseStopwatch() { change { $0.stopwatch.pause(at: .now) } }
    func resetStopwatch() { change { $0.stopwatch.reset() } }
    func lap() { change { try $0.stopwatch.lap(at: .now) } }
    func addTimer(name: String, seconds: Double) {
        change {
            guard $0.timers.count < ToolboxTimekeepingArchive.maximumTimers else { throw ToolboxTimekeepingError.limit }
            $0.timers.append(try ToolboxCountdown(label: name, duration: seconds, now: .now))
        }
    }
    func pause(_ id: UUID) { update(id) { $0.pause(at: .now) } }
    func resume(_ id: UUID) { update(id) { $0.resume(at: .now) } }
    func remove(_ id: UUID) { change { $0.timers.removeAll { $0.id == id } } }

    private func update(_ id: UUID, _ action: (inout ToolboxCountdown) -> Void) {
        change { value in
            guard let index = value.timers.firstIndex(where: { $0.id == id }) else { throw ToolboxTimekeepingError.invalid }
            action(&value.timers[index])
        }
    }

    private func change(_ action: (inout ToolboxTimekeepingArchive) throws -> Void) {
        guard loaded, !closed else { return }
        do {
            var next = archive
            try action(&next)
            guard next != archive, next.isValid, next.revision < UInt64.max - 1_000_000 else { return }
            next.revision += 1
            guard next.isValid else { throw ToolboxTimekeepingError.limit }
            archive = next
            exitOverride = false
            enqueueSave()
            reschedule()
        } catch ToolboxTimekeepingError.limit {
            if issue != .save { issue = .limit }
        } catch {
            if issue != .save { issue = .invalid }
        }
    }

    private func enqueueSave() {
        let previous = saveTail, snapshot = archive, store = self.store, id = UUID()
        // A fresh save attempt is new state: a prior one-shot quit choice may
        // not silently authorize quitting after this attempt fails again.
        exitOverride = false
        saveID = id; saving = true; unconfirmedSave = true
        saveTail = Task { @MainActor [weak self] in
            await previous?.value
            do {
                try await store.save(snapshot)
                guard let self, self.saveID == id else { return }
                self.saving = false; self.unconfirmedSave = false; self.saveTail = nil
                if self.issue == .save { self.issue = nil }
            } catch {
                guard let self, self.saveID == id else { return }
                self.saving = false; self.unconfirmedSave = true; self.saveTail = nil; self.issue = .save
            }
        }
    }

    func retrySave() {
        guard loaded, !closed, !saving, unconfirmedSave else { return }
        enqueueSave()
    }

    /// Explicit one-shot user choice. State and its warning remain in memory;
    /// a cancelled quit clears this choice instead of silently dropping work.
    func allowExitWithoutConfirmedSave() {
        guard !saving, loadTask == nil else { return }
        exitOverride = true
    }

    func closeAdmissions() { closed = true; deadlineTask?.cancel(); deadlineTask = nil }
    func resumeAfterCancelledTermination() { closed = false; exitOverride = false; reschedule() }

    func drain(timeout: TimeInterval = 5) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(max(0, timeout))
        while loadTask != nil || saveTail != nil {
            guard ContinuousClock.now < deadline else { return false }
            do { try await Task.sleep(for: .milliseconds(20)) } catch { return false }
        }
        return !unconfirmedSave || exitOverride
    }

    func wake() { reschedule() }

    private func reschedule() {
        deadlineTask?.cancel(); deadlineTask = nil
        guard loaded, !closed else { return }
        let now = ToolboxTimeSample.now
        if archive.timers.contains(where: { $0.phase == .running && $0.remaining(at: now) <= 0 }) {
            change { state in
                for index in state.timers.indices { _ = state.timers[index].finishIfNeeded(at: now) }
            }
            return
        }
        guard let delay = archive.timers.filter({ $0.phase == .running }).map({ $0.remaining(at: now) }).min() else { return }
        deadlineTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(max(0.01, delay))) } catch { return }
            self?.reschedule()
        }
    }
}
