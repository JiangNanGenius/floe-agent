// SPDX-License-Identifier: MPL-2.0
//
// C02 — production composition of generic tool-result retention.
//
// Main calls `install` once per accepted root generation, after the artifact
// root exists and before ordinary runs are served. It uses that existing
// app-owned artifact root (no second DB/session/job registry), registers the
// one generic `tools.readResult` runner and binds the host bridge. The runtime
// itself resolves the SAME store actor from the SAME root, so a live run and a
// later host/UI read observe one bounded index.
import Foundation
import FloeCore
import FloeModels
import FloeTools
import FloeAndroidToolResults

public final class C02ToolResultRuntime: @unchecked Sendable {
    public let epoch: UInt64
    public let artifactRoot: URL
    public let storeRoot: URL
    public let store: ToolResultCaptureStore
    public let service: C02ToolResultService
    private let liveEpoch: @Sendable () -> UInt64

    init(
        epoch: UInt64,
        artifactRoot: URL,
        store: ToolResultCaptureStore,
        service: C02ToolResultService,
        liveEpoch: @escaping @Sendable () -> UInt64
    ) {
        self.epoch = epoch
        self.artifactRoot = artifactRoot
        self.storeRoot = artifactRoot.appendingPathComponent("ToolResults", isDirectory: true)
        self.store = store
        self.service = service
        self.liveEpoch = liveEpoch
    }

    public func isLive() -> Bool {
        epoch > 0 && liveEpoch() == epoch
    }

    public func handle(requestData: Data, fallbackRequestID: String?) -> [String: Any] {
        C02ToolResultBridge.handle(
            requestData: requestData,
            fallbackRequestID: fallbackRequestID,
            service: service,
            epoch: epoch,
            liveEpoch: liveEpoch
        )
    }

    @discardableResult
    public func purge(conversationID: UUID) async -> ToolResultCapturePurgeResult {
        await store.purge(conversationID: conversationID)
    }
}

public enum C02ToolResultIntegration {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var runtime: C02ToolResultRuntime?
        func get() -> C02ToolResultRuntime? {
            lock.lock(); defer { lock.unlock() }; return runtime
        }
        func set(_ value: C02ToolResultRuntime?) {
            lock.lock(); runtime = value; lock.unlock()
        }
        func clear(epoch: UInt64) {
            lock.withLock {
                guard runtime?.epoch == epoch else { return }
                runtime = nil
            }
        }
    }

    private static let box = Box()

    /// Installs (or replaces) the generation's result retention, registers the
    /// model paging runner on the SAME registry ordinary runs use, and returns
    /// the runtime Main binds on `floe.results/20`.
    @discardableResult
    public static func install(
        epoch: UInt64,
        artifactRoot: URL,
        registry: ToolRunnerRegistry = .shared,
        liveEpoch: @escaping @Sendable () -> UInt64 = { G02NativeRootEpoch.readback() ?? 0 }
    ) -> C02ToolResultRuntime {
        let root = artifactRoot.appendingPathComponent("ToolResults", isDirectory: true)
        let store = ToolResultCaptureStore.shared(durableRoot: root, caps: .durableStandard)
        let service = C02ToolResultService(
            epoch: epoch,
            store: store,
            liveEpoch: liveEpoch
        )
        let runtime = C02ToolResultRuntime(
            epoch: epoch,
            artifactRoot: artifactRoot,
            store: store,
            service: service,
            liveEpoch: liveEpoch
        )
        // The paging tool is a normal read-only catalog runner. Its availability
        // is generation-bound so a retired root can never serve stale bytes.
        var paging = AnyAgentTool(ToolResultPagingTool(store: store))
        paging.isAvailable = { epoch > 0 && liveEpoch() == epoch }
        registry.register(paging)
        ToolCatalog.register(ToolResultPagingTool.self)
        box.set(runtime)
        return runtime
    }

    public static var current: C02ToolResultRuntime? { box.get() }

    /// Clears the bridge binding for one retiring generation. A newer
    /// generation is never cleared by an old retirement callback.
    public static func uninstall(epoch: UInt64) {
        box.clear(epoch: epoch)
    }

    /// Adds the model paging tool to an explicitly-bounded ordinary run. A nil
    /// ceiling already means "compiled default", which includes the registered
    /// runner; a temporary run is never widened.
    public static func offeredToolNames(
        _ base: Set<String>?,
        temporary: Bool
    ) -> Set<String>? {
        guard !temporary, var names = base else { return base }
        names.insert(ToolResultPagingTool.name)
        return names
    }

    /// Purges one deleted task's captured results through the installed
    /// generation, if any. Returns nil when retention was never bound; the
    /// caller can report that honestly instead of pretending a delete.
    @discardableResult
    public static func purgeRetainedResults(
        conversationID: UUID,
        epoch: UInt64
    ) async -> ToolResultCapturePurgeResult? {
        guard let runtime = box.get() else { return nil }
        guard runtime.epoch == epoch else {
            return .init(removedDurableDirectory: false,
                         failure: .removalFailed, retryScheduled: false)
        }
        return await runtime.purge(conversationID: conversationID)
    }

    /// Retries persisted deletion tombstones for the current generation.
    /// Bounded and idempotent; called by the app's launch/readiness path after
    /// `install` so an interrupted purge converges without a new registry.
    @discardableResult
    public static func reconcilePendingPurges() async -> (retried: Int, failed: Int) {
        guard let runtime = box.get() else { return (0, 0) }
        let pending = await runtime.store.pendingPurgeConversationIDs()
        var retried = 0
        var failed = 0
        for conversationID in pending {
            let result = await runtime.store.retryPendingPurge(conversationID: conversationID)
            retried += 1
            if !result.succeeded { failed += 1 }
        }
        return (retried, failed)
    }
}
