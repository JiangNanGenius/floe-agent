import Foundation

/// Bounded, synchronous checkpoints at execution boundaries, never per output chunk.
/// The fixed vocabulary deliberately excludes commands, paths, arguments and output.
public final class ExecutionBreadcrumbs: @unchecked Sendable {
    public static let shared = ExecutionBreadcrumbs(folder: FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("ExecutionBreadcrumbs", isDirectory: true))

    public enum Operation: String, Codable, Sendable { case shell, serviceStart, serviceStop }
    public enum Phase: String, Codable, Sendable {
        case began, negotiated, sending, awaitingReply, interruptRequested, completed, failed
    }
    private struct Entry: Codable {
        let time: Date
        let id: UUID
        let operation: Operation
        let phase: Phase
        let code: Int32?
    }
    private let lock = NSLock()
    private let file: URL
    private var entries: [Entry] = []
    private let previous: [Entry]
    private var writeFailed = false

    public init(folder: URL) {
        file = folder.appendingPathComponent("current.json")
        let old = (try? Data(contentsOf: file)).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
        previous = Array(old.suffix(64))
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            // Rotate before this process can overwrite its predecessor's final checkpoints.
            if !old.isEmpty {
                try JSONEncoder().encode(previous).write(to: folder.appendingPathComponent("previous.json"), options: .atomic)
            }
        } catch { writeFailed = true }
    }

    public func record(_ operation: Operation, _ phase: Phase, id: UUID, code: Int32? = nil) {
        lock.lock()
        defer { lock.unlock() }
        entries.append(Entry(time: Date(), id: id, operation: operation, phase: phase, code: code))
        if entries.count > 64 { entries.removeFirst(entries.count - 64) }
        do {
            try JSONEncoder().encode(entries).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { writeFailed = true }
    }

    public func report() -> String {
        lock.lock()
        defer { lock.unlock() }
        func render(_ items: [Entry]) -> String {
            items.reversed().map {
                "\($0.time.timeIntervalSince1970) \($0.id) \($0.operation.rawValue) \($0.phase.rawValue) code=\($0.code.map(String.init) ?? "none")"
            }.joined(separator: "\n")
        }
        return "Checkpoints are not a crash diagnosis. write_failed=\(writeFailed)\n== Previous process (newest first) ==\n"
            + render(previous) + "\n== Current process (newest first) ==\n" + render(entries)
    }
}
