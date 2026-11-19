// SPDX-License-Identifier: MPL-2.0

import Combine
import Darwin
import Foundation

@MainActor
final class MacWorkspaceDraftStore: ObservableObject {
    private static let byteLimit = 1_048_576
    private let directory: URL?
    @Published private var entries: [String: String] = [:]
    private var loaded: [String: String] = [:]
    private var dirty: Set<String> = []
    private var deferredWrite: Task<Void, Never>?
    @Published private(set) var saveFailed = false

    init(directory: URL?) { self.directory = directory }

    func text(for conversation: UUID?) -> String {
        let key = conversation?.uuidString ?? "new-task"
        if let text = entries[key] { return text }
        if let text = loaded[key] { return text }
        guard let directory, directoryIsPrivate(directory) else { return "" }
        let file = directory.appendingPathComponent(key, isDirectory: false)
        let descriptor = open(file.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return "" }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == geteuid(), info.st_nlink == 1, info.st_size <= Self.byteLimit,
              let data = try? handle.read(upToCount: Self.byteLimit + 1), data.count <= Self.byteLimit else {
            return ""
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        loaded[key] = text
        return text
    }

    func setText(_ text: String, for conversation: UUID?) {
        let key = conversation?.uuidString ?? "new-task"
        entries[key] = text
        guard directory != nil else { return }
        dirty.insert(key)
        deferredWrite?.cancel()
        deferredWrite = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.flush()
        }
    }

    func flush() {
        deferredWrite?.cancel()
        deferredWrite = nil
        guard let directory, !dirty.isEmpty else { return }
        do {
            if !directoryIsPrivate(directory) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            }
            guard directoryIsPrivate(directory) else {
                throw CocoaError(.fileWriteNoPermission)
            }
            for key in dirty.sorted() {
                let data = Data((entries[key] ?? "").utf8)
                guard data.count <= Self.byteLimit else { throw CocoaError(.fileWriteOutOfSpace) }
                let file = directory.appendingPathComponent(key, isDirectory: false)
                try data.write(to: file, options: .atomic)
                dirty.remove(key)
            }
            saveFailed = false
        } catch {
            saveFailed = true
        }
    }

    private func directoryIsPrivate(_ directory: URL) -> Bool {
        var info = stat()
        return lstat(directory.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR
            && info.st_uid == geteuid() && info.st_mode & 0o077 == 0
    }
}
