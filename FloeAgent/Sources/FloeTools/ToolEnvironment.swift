import Foundation
import FloeCore
import FloeModels

/// Dependency/data environment resolved for one execution. This is not a process sandbox.
public struct ToolEnvironment: Sendable {
    public var id: String
    public var writableLayerURL: URL
    public var layerURLs: [URL]
    public var variables: [String: String]
    public init(id: String, writableLayerURL: URL, layerURLs: [URL], variables: [String: String]) {
        self.id = id; self.writableLayerURL = writableLayerURL
        self.layerURLs = layerURLs; self.variables = variables
    }
}

public struct ToolEnvironmentLease: Sendable {
    public var context: ToolContext
    public var finish: @Sendable () async -> Void
    public init(context: ToolContext, finish: @escaping @Sendable () async -> Void = {}) {
        self.context = context; self.finish = finish
    }
}

/// The live run's pin. Native routing publishes a new value only after the
/// saved binding was committed against a verified retaining Linux rebuild.
public final class LiveTaskExecutionBinding: @unchecked Sendable {
    private let lock = NSLock()
    private var binding: TaskExecutionBinding

    public init(_ binding: TaskExecutionBinding) { self.binding = binding }

    public var current: TaskExecutionBinding { lock.withLock { binding } }

    /// A concurrent call can read the new SQLite pin before its owner has
    /// published it here. The physical guard still has to verify that disk.
    public func canUse(_ saved: TaskExecutionBinding) -> Bool {
        lock.withLock {
            binding == saved || Self.isRetainedRebuild(from: binding, to: saved)
                || Self.isRetainedRebuild(from: saved, to: binding)
        }
    }

    @discardableResult
    public func adopt(_ committed: TaskExecutionBinding) -> Bool {
        lock.withLock {
            if binding == committed { return true }
            guard Self.isRetainedRebuild(from: binding, to: committed) else { return false }
            binding = committed
            return true
        }
    }

    private static func isRetainedRebuild(from binding: TaskExecutionBinding, to next: TaskExecutionBinding) -> Bool {
        var target = binding.target
        target.runtimeGeneration = next.target.runtimeGeneration
        return binding.target.backend == .linuxVM && target == next.target
            && next.target != binding.target && next.conversationID == binding.conversationID
            && LinuxResidentRuntimeGeneration.recoveryID(from: target.runtimeGeneration) != nil
            && binding.generation < Int64.max && next.generation == binding.generation + 1
    }
}

/// Raised only when the tool can prove no requested command was dispatched.
/// A retry handler must still revalidate the original task and environment.
public struct ToolPreDispatchRetry: Error, Sendable {
    public let expectedLinuxImageID: String
    public init(expectedLinuxImageID: String) { self.expectedLinuxImageID = expectedLinuxImageID }
}

/// App-injected environment routing keeps tool implementations independent of storage modules.
public final class ToolEnvironmentRouting: @unchecked Sendable {
    public typealias Begin = @Sendable (ToolContext) async throws -> ToolEnvironmentLease
    public typealias Retry = @Sendable (ToolContext, ToolPreDispatchRetry) async throws -> Bool
    public static let shared = ToolEnvironmentRouting()
    private let lock = NSLock()
    private var begin: Begin?
    private var retry: Retry?
    public init() {}
    public func configure(_ begin: @escaping Begin) { lock.withLock { self.begin = begin } }
    public func configureRetry(_ retry: @escaping Retry) { lock.withLock { self.retry = retry } }
    public func waitForPreDispatchRetry(_ context: ToolContext, reason: ToolPreDispatchRetry) async throws -> Bool {
        guard let retry = lock.withLock({ self.retry }) else { return false }
        return try await retry(context, reason)
    }
    public func acquire(_ context: ToolContext) async throws -> ToolEnvironmentLease {
        guard let begin = lock.withLock({ self.begin }) else { return ToolEnvironmentLease(context: context) }
        return try await begin(context)
    }
}
