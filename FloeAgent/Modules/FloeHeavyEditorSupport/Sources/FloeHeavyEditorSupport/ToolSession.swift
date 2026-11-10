// SPDX-License-Identifier: MPL-2.0
import Foundation

/// This closure belongs to one queued operation, never the visible controller.
public typealias HeavyEditorOperationAuthorizer = @Sendable (HeavyEditorAccessRequest) async throws -> Void
public struct HeavyEditorDiscoveryPage: Codable, Sendable {
    public var query: String
    public var offset: Int
    public var limit: Int
    public init(query: String = "", offset: Int = 0, limit: Int = 40) {
        self.query = query; self.offset = offset; self.limit = limit
    }
    private enum CodingKeys: String, CodingKey { case query, offset, limit }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        query = try values.decodeIfPresent(String.self, forKey: .query) ?? ""
        offset = try values.decodeIfPresent(Int.self, forKey: .offset) ?? 0
        limit = try values.decodeIfPresent(Int.self, forKey: .limit) ?? 40
    }
}

/// A real host supplies a context-bound editor instance and owns its lease.
/// A model can name an indexed project, never its directory, owner or hooks.
public struct HeavyEditorModelLease: Sendable {
    public let controller: HeavyEditorController
    public let authorize: HeavyEditorOperationAuthorizer?
    public let release: @Sendable () async -> Void
    public init(controller: HeavyEditorController, authorize: HeavyEditorOperationAuthorizer? = nil, release: @escaping @Sendable () async -> Void) {
        self.controller = controller; self.authorize = authorize; self.release = release
    }
}

public enum HeavyEditorToolOperation: String, Codable, Sendable { case describe, query, invoke, export }
public struct HeavyEditorModelRequest: Codable, Sendable {
    public let projectID: UUID
    public let baseRevision: UInt64?
    public let command: String?
    public let arguments: EditorJSON?
    public let discovery: HeavyEditorDiscoveryPage?
    public init(projectID: UUID, baseRevision: UInt64? = nil, command: String? = nil, arguments: EditorJSON? = nil, discovery: HeavyEditorDiscoveryPage? = nil) {
        self.projectID = projectID; self.baseRevision = baseRevision; self.command = command; self.arguments = arguments; self.discovery = discovery
    }
}

public enum HeavyEditorModelCalls {
    /// Publication finishes before exactly one host lease release, including
    /// failures. The host may still verify its original and output receipts.
    public static func withLease<Value: Sendable>(_ lease: HeavyEditorModelLease,
        operation: @Sendable (HeavyEditorModelLease) async throws -> Value) async throws -> Value {
        try await heavyEditorWithLeaseRelease(release: lease.release) { try await operation(lease) }
    }
    public static func execute(_ operation: HeavyEditorToolOperation, kind: HeavyEditorKind,
                               request: HeavyEditorModelRequest, lease: HeavyEditorModelLease) async throws -> EditorJSON {
        try await withLease(lease) { try await run(operation, kind: kind, request: request, lease: $0) }
    }
    @MainActor public static func run(_ operation: HeavyEditorToolOperation, kind: HeavyEditorKind,
                                      request: HeavyEditorModelRequest, lease: HeavyEditorModelLease) async throws -> EditorJSON {
        try Task.checkCancellation()
        let controller = lease.controller
        guard controller.document.id == request.projectID, controller.descriptor.kind == kind else { throw HeavyEditorError.wrongDocument }
        try await controller.waitUntilReady()
        if operation == .describe {
            if let revision = request.baseRevision, revision != controller.document.revision { throw HeavyEditorError.revisionConflict }
            return try await controller.describe(command: request.command, arguments: request.arguments ?? .object([:]), discovery: request.discovery ?? .init(), authorization: lease.authorize)
        }
        guard let revision = request.baseRevision, let command = request.command else { throw HeavyEditorError.invalidCommand }
        let metadata = try await controller.commandMetadata(command)
        let access = metadata["access"].string
        guard metadata["hidden"] != .bool(true) else { throw HeavyEditorError.invalidCommand }
        if operation == .export {
            guard access == HeavyEditorAccess.exportFile.rawValue else { throw HeavyEditorError.invalidCommand }
        } else if operation == .query {
            guard access == HeavyEditorAccess.read.rawValue, metadata["sideEffecting"] != .bool(true) else { throw HeavyEditorError.invalidCommand }
        } else {
            // File imports require the host's file/attachment resolver; models
            // cannot smuggle arbitrary base64 files through an editing command.
            guard access == HeavyEditorAccess.read.rawValue || access == HeavyEditorAccess.edit.rawValue else { throw HeavyEditorError.invalidCommand }
        }
        let response = try await controller.execute(command, arguments: request.arguments ?? .object([:]), expectedRevision: revision, authorization: lease.authorize)
        let result = response["result"]
        let bounded: EditorJSON
        if try result.data().count <= 512 * 1024 { bounded = result }
        else { bounded = .object(["truncated": .bool(true), "message": .string("Use a narrower query or export the result through the authorized file service.")]) }
        return .object(["projectID": .string(request.projectID.uuidString), "baseRevision": .number(Double(controller.document.revision)),
                        "result": bounded, "exports": response["exports"]])
    }
}

/// Observable service stages. Views may present these without owning or
/// cancelling the command when a panel is temporarily reconstructed.
public enum HeavyEditorOperationPhase: Sendable {
    case preparing, queued, authorizing, running, saving, returning, stopping, idle, unavailable
    public var title: String {
        switch self {
        case .preparing: EditorText.t("正在准备", "Preparing")
        case .queued: EditorText.t("正在排队", "Queued")
        case .authorizing: EditorText.t("正在确认权限", "Checking access")
        case .running: EditorText.t("正在处理", "Working")
        case .saving: EditorText.t("正在保存", "Saving")
        case .returning: EditorText.t("正在整理结果", "Preparing results")
        case .stopping: EditorText.t("正在停止", "Stopping")
        case .idle: EditorText.t("已就绪", "Ready")
        case .unavailable: EditorText.t("请重新打开作品", "Reopen the work")
        }
    }
}


enum HeavyEditorOperationStateError: Error, Sendable, Equatable {
    case queueFull, timedOut, invalidated
}

/// The host lease ends once on every outcome, including a caller cancellation
/// or a failed callback deadline. A release is not interpreted as a successful
/// operation and never replaces the original result.
func heavyEditorWithLeaseRelease<Value: Sendable>(
    release: @Sendable () async -> Void,
    operation: @Sendable () async throws -> Value
) async throws -> Value {
    let result: Result<Value, any Error>
    do {
        try Task.checkCancellation()
        result = .success(try await operation())
    } catch { result = .failure(error) }
    await release()
    return try result.get()
}

/// A cancelled caller can finish before an uncooperative asynchronous provider.
/// Only the first outcome is observable, and late callbacks cannot resume a
/// continuation twice. No provider operation or write is retried here.
final class HeavyEditorOneShot<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, any Error>?
    private var waiters: [CheckedContinuation<Value, any Error>] = []

    var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return result != nil
    }

    @discardableResult
    func resolve(_ value: Result<Value, any Error>) -> Bool {
        lock.lock()
        guard result == nil else { lock.unlock(); return false }
        result = value
        let waiting = waiters
        waiters.removeAll()
        lock.unlock()
        for continuation in waiting { continuation.resume(with: value) }
        return true
    }

    func value() async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let result {
                lock.unlock()
                continuation.resume(with: result)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// The serial execution slot belongs to the service, separately from the
/// caller's result. Cancelling a queued caller never releases its predecessor's
/// barrier, and cancelling active work never admits the successor until that
/// work actually exits. Other callers are not cancelled.
@MainActor
final class HeavyEditorOperationQueue<Value: Sendable> {
    private final class Entry {
        let id: UUID
        let completion: HeavyEditorOneShot<Value>
        let operation: @MainActor @Sendable (UUID) async throws -> Value
        let onCancel: @MainActor @Sendable (UUID) -> Void
        var cancellationDelivered = false

        init(id: UUID, completion: HeavyEditorOneShot<Value>,
             operation: @escaping @MainActor @Sendable (UUID) async throws -> Value,
             onCancel: @escaping @MainActor @Sendable (UUID) -> Void) {
            self.id = id; self.completion = completion
            self.operation = operation; self.onCancel = onCancel
        }
    }

    private let capacity: Int
    private var pending: [Entry] = []
    private var active: Entry?
    private var activeTask: Task<Void, Never>?
    var onStateChanged: (@MainActor @Sendable () -> Void)?

    init(capacity: Int = 256) { self.capacity = max(1, capacity) }

    var pendingCount: Int { pending.count }
    var activeID: UUID? { active?.id }

    func isActive(_ id: UUID) -> Bool {
        active?.id == id && active?.completion.isResolved == false
    }

    func execute(id: UUID = UUID(),
                 onCancel: @escaping @MainActor @Sendable (UUID) -> Void = { _ in },
                 operation: @escaping @MainActor @Sendable (UUID) async throws -> Value) async throws -> Value {
        try Task.checkCancellation()
        guard pending.count + (active == nil ? 0 : 1) < capacity else {
            throw HeavyEditorOperationStateError.queueFull
        }
        let completion = HeavyEditorOneShot<Value>()
        let entry = Entry(id: id, completion: completion, operation: operation, onCancel: onCancel)
        return try await withTaskCancellationHandler {
            // onCancel may have won before registration on the main actor.
            if !completion.isResolved {
                pending.append(entry)
                onStateChanged?()
                startNextIfIdle()
            }
            return try await completion.value()
        } onCancel: {
            guard completion.resolve(.failure(CancellationError())) else { return }
            Task { @MainActor [weak self] in self?.cancel(id) }
        }
    }

    func cancelActive() {
        guard let active else { return }
        active.completion.resolve(.failure(CancellationError()))
        cancel(active.id)
    }

    private func cancel(_ id: UUID) {
        if let entry = active, entry.id == id {
            guard !entry.cancellationDelivered else { return }
            entry.cancellationDelivered = true
            activeTask?.cancel()
            entry.onCancel(id)
        } else if let index = pending.firstIndex(where: { $0.id == id }) {
            pending.remove(at: index)
            onStateChanged?()
        }
    }

    private func startNextIfIdle() {
        guard active == nil else { return }
        while !pending.isEmpty {
            let entry = pending.removeFirst()
            onStateChanged?()
            guard !entry.completion.isResolved else { continue }
            active = entry
            onStateChanged?()
            activeTask = Task { @MainActor [self] in
                do {
                    try Task.checkCancellation()
                    let value = try await entry.operation(entry.id)
                    try Task.checkCancellation()
                    entry.completion.resolve(.success(value))
                } catch {
                    entry.completion.resolve(.failure(error))
                }
                // Completion of the owned task, not the caller's cancelled
                // continuation, advances the FIFO execution barrier.
                guard active?.id == entry.id else { return }
                active = nil; activeTask = nil
                onStateChanged?()
                startNextIfIdle()
            }
            return
        }
    }
}

/// Adapts a callback API to one cancellable, bounded continuation. A provider
/// that never calls back cannot keep its caller or a tool lease waiting forever.
/// Invalidating this bridge is terminal for one editor-page generation.
@MainActor
final class HeavyEditorCallbackBridge<Value: Sendable> {
    typealias Completion = @MainActor @Sendable (Result<Value, any Error>) -> Void

    private struct Pending {
        let generation: UInt64
        let owner: UUID?
        let completion: HeavyEditorOneShot<Value>
        let providerSettled: HeavyEditorOneShot<Void>
        let onCancel: @MainActor @Sendable () -> Void
        let onTimeout: @MainActor @Sendable () -> Void
        var timer: Task<Void, Never>?
        var cancellationDelivered = false
    }

    private(set) var generation: UInt64 = 0
    private var invalidated = false
    private var pending: [UUID: Pending] = [:]

    var pendingCount: Int { pending.count }
    var isValid: Bool { !invalidated }

    func perform(timeout: Duration, owner: UUID? = nil,
                 onCancel: @escaping @MainActor @Sendable () -> Void = {},
                 onTimeout: @escaping @MainActor @Sendable () -> Void = {},
                 start: @escaping @MainActor @Sendable (@escaping Completion) throws -> Void) async throws -> Value {
        try Task.checkCancellation()
        guard !invalidated else { throw HeavyEditorOperationStateError.invalidated }
        guard pending.count < 256 else { throw HeavyEditorOperationStateError.queueFull }
        let id = UUID(), expected = generation
        let completion = HeavyEditorOneShot<Value>()
        return try await withTaskCancellationHandler {
            guard !completion.isResolved else { return try await completion.value() }
            guard timeout > .zero else { throw HeavyEditorOperationStateError.timedOut }
            pending[id] = Pending(generation: expected, owner: owner, completion: completion,
                providerSettled: HeavyEditorOneShot<Void>(), onCancel: onCancel, onTimeout: onTimeout)
            pending[id]?.timer = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: timeout) } catch { return }
                self?.expire(id, generation: expected)
            }
            do {
                try start { [weak self] result in self?.finish(id, generation: expected, result: result) }
            } catch {
                finish(id, generation: expected, result: .failure(error))
            }
            return try await completion.value()
        } onCancel: {
            guard completion.resolve(.failure(CancellationError())) else { return }
            Task { @MainActor [weak self] in self?.cancel(id, generation: expected) }
        }
    }

    /// A cancelled continuation does not prove that the provider stopped.
    /// The execution slot uses this bounded acknowledgement before restoring
    /// a document or admitting another command to the same mutable page.
    func waitForSettlement(owner: UUID, timeout: Duration) async -> Bool {
        guard !invalidated else { return false }
        let calls = pending.values.filter { $0.owner == owner }.map(\.providerSettled)
        guard !calls.isEmpty else { return true }
        guard timeout > .zero else { return false }
        let finished = HeavyEditorOneShot<Bool>()
        let waiter = Task { @MainActor in
            do {
                for call in calls { try await call.value() }
                finished.resolve(.success(true))
            } catch { finished.resolve(.success(false)) }
        }
        let timer = Task { @MainActor in
            do { try await Task.sleep(for: timeout) } catch { return }
            finished.resolve(.success(false))
        }
        let value = (try? await finished.value()) ?? false
        waiter.cancel(); timer.cancel()
        return value
    }

    func invalidate() {
        invalidated = true
        generation &+= 1
        let previous = Array(pending.values)
        pending.removeAll()
        for request in previous {
            request.timer?.cancel()
            request.completion.resolve(.failure(HeavyEditorOperationStateError.invalidated))
            request.providerSettled.resolve(.failure(HeavyEditorOperationStateError.invalidated))
        }
    }

    private func finish(_ id: UUID, generation expected: UInt64, result: Result<Value, any Error>) {
        guard generation == expected, let request = pending.removeValue(forKey: id),
              request.generation == expected else { return }
        request.timer?.cancel()
        request.providerSettled.resolve(.success(()))
        request.completion.resolve(result)
    }

    private func cancel(_ id: UUID, generation expected: UInt64) {
        guard generation == expected, var request = pending[id],
              request.generation == expected else { return }
        guard !request.cancellationDelivered else { return }
        request.cancellationDelivered = true
        pending[id] = request
        // Keep the provider acknowledgement separate from the caller's
        // cancellation outcome. Its original deadline remains bounded.
        request.onCancel()
    }

    private func expire(_ id: UUID, generation expected: UInt64) {
        guard generation == expected, let request = pending.removeValue(forKey: id),
              request.generation == expected else { return }
        request.timer?.cancel()
        request.providerSettled.resolve(.failure(HeavyEditorOperationStateError.timedOut))
        request.completion.resolve(.failure(HeavyEditorOperationStateError.timedOut))
        request.onTimeout()
    }
}
