// FloeApp — App-level lifecycle for the optional local speech preload.
//
// SPDX-License-Identifier: MPL-2.0
//
// The root owns WHEN speculation may run; this coordinator owns the single
// App-wide wiring of the default-off preference to the residency runtime. It
// never downloads a model, opens the microphone, requests Apple speech
// permission or retries after a failure/memory-pressure release.
//
// RE-ARM EVENTS are exactly:
// - an explicit user ON;
// - a genuine scene transition into foreground while persisted settings are
//   ready;
// - the launch transition where foreground and persistence readiness first
//   become true together.
//
// Redundant `activate(true)` reports (scene notifications, view rebuilds),
// settings entry and model/key/endpoint/language edits never re-arm. They may
// reconcile the route, but never undo a memory-pressure release. Re-arming
// happens BEFORE scheduling, so a foreground return cannot consume its one
// attempt while the runtime is still suppressed.
//
// A task generation token fences late completions: a cancelled warm task can
// never clear the handle of its successor.

import Foundation

@MainActor
final class CloudASRPreloadCoordinator {
    struct Runtime: Sendable {
        var isInstalled: @Sendable () async -> Bool
        var allowSpeculativeWarmUp: @Sendable () async -> Void
        var warmUp: @Sendable () async -> Bool
        var cancelSpeculativeWarmUp: @Sendable () async -> Bool

        static let disabled = Runtime(
            isInstalled: { false },
            allowSpeculativeWarmUp: {},
            warmUp: { false },
            cancelSpeculativeWarmUp: { false })
    }

    private let defaults: UserDefaults
    private let store: CloudASRSettingsStore
    private let methodProvider: @MainActor () -> String
    private let runtime: Runtime

    private var isForeground = false
    private var persistenceReady = false
    private var warmTask: Task<Void, Never>?
    private var warmGeneration: UInt64 = 0
    private var lastAttemptedRoute: String?

    init(
        store: CloudASRSettingsStore,
        defaults: UserDefaults = .standard,
        methodProvider: @escaping @MainActor () -> String = {
            VoiceRecognitionPreferences.method.rawValue
        },
        runtime: Runtime = .disabled
    ) {
        self.store = store
        self.defaults = defaults
        self.methodProvider = methodProvider
        self.runtime = runtime
    }

    var isEnabled: Bool {
        VoiceRecognitionPreloadPolicy.isEnabled(defaults: defaults)
    }

    /// The current stable primary-route identity. Reading it never mounts a
    /// model, asks for authorization or probes a credential.
    func primaryRouteIdentity() -> String {
        resolution().identity
    }

    /// Reconciling the route is idempotent. `.reset` is the ONLY moment this
    /// coordinator cancels an unused speculative demand; an unrelated edit
    /// (language/model/endpoint/key) leaves the route identity untouched.
    @discardableResult
    func syncPrimaryRoute() async -> VoiceRecognitionPreloadPolicy.PrimaryIdentityUpdate {
        let identity = resolution().identity
        let update = VoiceRecognitionPreloadPolicy.observePrimaryIdentity(
            identity, defaults: defaults)
        if update == .reset {
            invalidateWarmTask()
            _ = await runtime.cancelSpeculativeWarmUp()
        }
        if isEnabled {
            await scheduleWarmIfAllowed()
        }
        return update
    }

    /// Called by the root after foreground AND persisted-settings readiness.
    /// Only the launch readiness transition or a genuine background→foreground
    /// transition re-arms. A duplicate `true` notification is inert.
    func activate(foreground: Bool, persistenceReady: Bool) async {
        let wasForeground = isForeground
        let wasReady = self.persistenceReady
        isForeground = foreground
        self.persistenceReady = persistenceReady
        guard foreground, persistenceReady else { return }

        let launchTransition = !wasForeground || !wasReady
        if launchTransition, isEnabled {
            // Re-arm BEFORE route reconciliation can schedule the single
            // permitted attempt. `allowSpeculativeWarmUp` is never called for
            // an ordinary duplicate foreground=true notification.
            lastAttemptedRoute = nil
            await runtime.allowSpeculativeWarmUp()
        }
        await syncPrimaryRoute()
    }

    /// Kept for explicit scene plumbing. A redundant `true` never re-arms.
    func setForeground(_ foreground: Bool) async {
        let wasForeground = isForeground
        isForeground = foreground
        guard foreground, persistenceReady else { return }
        if !wasForeground, isEnabled {
            lastAttemptedRoute = nil
            await runtime.allowSpeculativeWarmUp()
        }
        await syncPrimaryRoute()
    }

    /// Explicit user toggle. ON re-arms and may warm an already-installed
    /// model; OFF cancels only unused speculative demand.
    func setEnabled(_ enabled: Bool) async {
        let identity = resolution().identity
        VoiceRecognitionPreloadPolicy.setEnabled(
            enabled, primaryIdentity: identity, defaults: defaults)
        if enabled {
            invalidateWarmTask()
            lastAttemptedRoute = nil
            await runtime.allowSpeculativeWarmUp()
            await scheduleWarmIfAllowed()
        } else {
            invalidateWarmTask()
            _ = await runtime.cancelSpeculativeWarmUp()
        }
    }

    /// Settings entry: reconcile the route exactly once, never re-arm after a
    /// memory-pressure release. If a warm attempt has never run on this route,
    /// the normal scheduling rule may still warm it once.
    func refreshAfterSettingsEntry() async {
        await syncPrimaryRoute()
    }

    /// Test/qualification seam.
    var isWarmingForTesting: Bool { warmTask != nil }

    /// Test/qualification seam: await the current warm attempt, if any.
    func waitForWarmCompletion() async {
        await warmTask?.value
    }

    private func resolution() -> CloudASRRouteResolution {
        // Readiness deliberately does not participate in IDENTITY. It only
        // decides whether the selected cloud is usable for this request.
        let readyIDs = Set(store.readyProfiles.map(\.id))
        return CloudASRRouteResolver.resolve(
            method: methodProvider(),
            profiles: store.profiles,
            primaryProfileID: store.primaryProfileID,
            readyProfileIDs: readyIDs)
    }

    private func scheduleWarmIfAllowed() async {
        guard isEnabled, isForeground, persistenceReady, warmTask == nil else { return }
        let identity = resolution().identity
        guard lastAttemptedRoute != identity else { return }
        lastAttemptedRoute = identity
        warmGeneration &+= 1
        let generation = warmGeneration
        let runtime = self.runtime
        warmTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let installed = await runtime.isInstalled()
            guard !Task.isCancelled, let self else { return }
            let allowed = VoiceRecognitionPreloadPolicy.shouldWarm(
                isEnabled: self.isEnabled,
                isForeground: self.isForeground,
                isInstalled: installed,
                isReady: self.persistenceReady)
            guard allowed else {
                self.finishWarm(generation: generation)
                return
            }
            _ = await runtime.warmUp()
            guard !Task.isCancelled else { return }
            self.finishWarm(generation: generation)
        }
    }

    /// A late completion from a superseded generation must not clear the
    /// successor's handle or reopen the attempt gate.
    private func finishWarm(generation: UInt64) {
        guard generation == warmGeneration else { return }
        warmTask = nil
    }

    private func invalidateWarmTask() {
        warmGeneration &+= 1
        warmTask?.cancel()
        warmTask = nil
        lastAttemptedRoute = nil
    }
}
