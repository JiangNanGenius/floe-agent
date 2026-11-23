// FloeMacUnified LocalModelsParity — host-facing service for local models.
//
// SPDX-License-Identifier: MPL-2.0
//
// Thin Mac composition layer over the SHARED local-model modules
// (FloeLocalModelCatalog + FloeLocalModels). The shared types own everything
// heavy: catalog pins, verified download/install, the MLX/llama engines,
// streaming via the normal `ProviderAdapter` contract, idle offload and the
// Apple Foundation Model row. This file keeps only what is Mac-native:
//
//   - runtime availability probing (`MacLocalModelAvailability`),
//   - one owned `LocalModelStore` + `LocalModelRuntime` pair,
//   - the provider profile/adapter handoff for the host's model picker,
//   - one host callback that publishes the installed model profiles,
//   - teardown/idle coordination for the host and settings UI.
//
// There is deliberately no second engine, no second inference lifecycle and
// no remote fallback: if the shared runtime cannot serve a model, the typed
// shared error surfaces unchanged.

import Foundation
import Synchronization
import FloeCore
import FloeModels
import FloeProviders
import FloeLocalModelCatalog
import FloeLocalModels

@available(macOS 15.4, *)
public struct MacLocalModelHostHooks: Sendable {
    /// Published whenever the installed-model set may have changed (after a
    /// download/remove from the settings surface, or after an explicit
    /// `refreshInstalledModels()`). The value is exactly
    /// `LocalProviderAdapter.listModels(...)` output — the same rows the
    /// iPad publishes — including the Apple Foundation Model row.
    public var installedModelsDidChange: (@Sendable (Result<[ModelProfile], Error>) -> Void)?

    public init(installedModelsDidChange: (@Sendable (Result<[ModelProfile], Error>) -> Void)? = nil) {
        self.installedModelsDidChange = installedModelsDidChange
    }
}

/// Host-facing entry point for the Mac local-model lifecycle.
@available(macOS 15.4, *)
public final class MacLocalModelService: Sendable {
    /// The one on-device provider record, shared-verified identity.
    public static let providerProfile = LocalProviderAdapter.providerProfile

    public let store: LocalModelStore
    public let runtime: LocalModelRuntime

    private let hooksMutex = Mutex<MacLocalModelHostHooks?>(nil)

    public init(
        store: LocalModelStore = LocalModelStore(),
        runtime: LocalModelRuntime? = nil
    ) {
        self.store = store
        self.runtime = runtime ?? LocalModelRuntime(store: store)
    }

    // MARK: Host hooks

    public func setHostHooks(_ hooks: MacLocalModelHostHooks?) {
        hooksMutex.withLock { $0 = hooks }
    }

    /// Re-runs model discovery through the shared adapter and delivers the
    /// result to the host callback. Call after install/remove completes or
    /// when the picker (re)appears.
    public func refreshInstalledModels() async {
        let result: Result<[ModelProfile], Error>
        do {
            result = .success(try await installedModelProfiles())
        } catch {
            result = .failure(error)
        }
        let callback = hooksMutex.withLock { $0?.installedModelsDidChange }
        callback?(result)
    }

    /// The same discovery the iPad uses: shared adapter, on-device provider
    /// profile, empty credentials. Never touches the network.
    public func installedModelProfiles() async throws -> [ModelProfile] {
        let adapter = makeAdapter()
        return try await adapter.listModels(
            provider: LocalProviderAdapter.providerProfile,
            credentials: ProviderCredentials()
        )
    }

    // MARK: Adapter handoff

    /// Builds the shared on-device adapter bound to this service's store and
    /// runtime. The host dispatches chat runs for `providerProfile` to this
    /// adapter exactly like the iPad's ConversationCenter does.
    public func makeAdapter(ownerRunID: UUID? = nil) -> LocalProviderAdapter {
        LocalProviderAdapter(
            runtime: runtime,
            store: store,
            ownerRunID: ownerRunID
        )
    }

    // MARK: Availability

    /// Verdict for settings and picker chrome.
    public func runtimeSupport(
        probe: MacLocalModelAvailability.Probe = MacLocalModelAvailability.currentProbe()
    ) -> MacLocalModelRuntimeSupport {
        MacLocalModelAvailability.support(probe: probe)
    }

    // MARK: Settings-facing lifecycle (thin passthroughs over shared types)

    /// Warm-up load from settings; throws the shared typed errors.
    public func preload(modelID: String) async throws {
        try await runtime.preload(modelID: modelID)
    }

    /// Explicit unload from settings or a model switch.
    public func unload(modelID: String? = nil) async {
        await runtime.unload(modelID: modelID)
    }

    /// Settings benchmark entry (same shared benchmark the iPad settings use).
    @discardableResult
    public func benchmark(modelID: String) async throws -> LocalModelBenchmarkResult {
        try await runtime.benchmark(modelID: modelID)
    }

    /// Residency/idle coordination for the host: true while a load, benchmark
    /// or chat turn holds the inference slot.
    public func hasActiveInferenceOperation() async -> Bool {
        await runtime.hasActiveInferenceOperation()
    }

    public func residentModelID() async -> String? {
        await runtime.residentModelID()
    }

    /// Linux-guest style arbitration: physically releases the resident
    /// engine only when nothing claims it. Returns the released model id.
    public func releaseIdleResidentEngine(reason: String) async -> String? {
        await runtime.releaseIdleResidentEngineIfUnclaimed(reason: reason)
    }

    /// App/settings teardown: cancels the idle timer and unloads everything.
    public func unloadForTeardown() async {
        await runtime.unload()
    }
}
