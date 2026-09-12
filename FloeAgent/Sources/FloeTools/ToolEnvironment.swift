import Foundation

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

/// App-injected environment routing keeps tool implementations independent of storage modules.
public final class ToolEnvironmentRouting: @unchecked Sendable {
    public typealias Begin = @Sendable (ToolContext) async throws -> ToolEnvironmentLease
    public static let shared = ToolEnvironmentRouting()
    private let lock = NSLock()
    private var begin: Begin?
    public init() {}
    public func configure(_ begin: @escaping Begin) { lock.withLock { self.begin = begin } }
    public func acquire(_ context: ToolContext) async throws -> ToolEnvironmentLease {
        guard let begin = lock.withLock({ self.begin }) else { return ToolEnvironmentLease(context: context) }
        return try await begin(context)
    }
}
