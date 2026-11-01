import Combine
import Foundation
import UIKit
import BridgeCore

/// UI-facing state. It only mirrors the shared lifecycle and real subsystem
/// statuses; it never advances readiness itself.
@MainActor
final class BridgeAppModel: ObservableObject {
    static let shared = BridgeAppModel()

    @Published private(set) var snapshot = BridgeSharedState.shared.snapshot()
    @Published private(set) var tunnelPhase: BridgeTunnelPhase = .unknown
    @Published private(set) var tunnelDetail: String?
    @Published private(set) var ddiStatus = BridgeDDIProbe.status()
    @Published private(set) var pairingImported = false
    @Published private(set) var ddiDownloading = false
    @Published private(set) var ddiDownloadProgress: Double = 0
    @Published private(set) var ddiStatusText: String?
    @Published private(set) var ddiError: String?
    @Published var banner: String?
    @Published var mountProgress: Double = 0
    /// Concise result of the latest prototype stage check. It is diagnostic
    /// only and never changes engine/readiness state.
    @Published private(set) var stageProbeSummary: String?
    /// Latest explicitly user-triggered on-device canary. It is service-owned
    /// and survives view rebuilds; it never changes readiness by itself.
    @Published private(set) var canaryReport: BridgeCanaryReport?
    /// Set by the coordinator around the blocking DDI worker. The UI uses it
    /// to disable Start/mount/removal without guessing from the phase, which
    /// Stop can fence before the worker actually returns.
    @Published var ddiWorkerBusy = false
    @Published var autoStart: Bool {
        didSet {
            // Reading an absent preference at init must not create an
            // explicit false. Only user/default transitions persist a value.
            guard !isLoadingInitialAutoStart else { return }
            UserDefaults.standard.set(autoStart, forKey: Self.autoStartKey)
        }
    }
#if BRIDGE_PROTOTYPE
    @Published var lanEnabled: Bool {
        didSet { UserDefaults.standard.set(lanEnabled, forKey: Self.lanEnabledKey) }
    }
    /// Separate encrypted LAN control switch. It is off by default and never
    /// inherits the read-only diagnostics preference.
    @Published var controlEnabled: Bool {
        didSet { UserDefaults.standard.set(controlEnabled, forKey: Self.controlEnabledKey) }
    }
    @Published var revealToken = false
    @Published private(set) var lanListening = false
    @Published private(set) var lanError: String?
    @Published private(set) var controlListening = false
    @Published private(set) var controlError: String?
    @Published private(set) var controlURLs: [String] = []
    @Published private(set) var controlKeyFingerprint: String?
    @Published private(set) var prototypeToken: String?
    @Published private(set) var lanToken: String?

#endif

    // MARK: - Product RPC surface

    /// Actual canonical RPC state. It is the single source for listener,
    /// client, capability and engine-readiness display.
    @Published private(set) var rpcSnapshot = BridgeRPCHostSnapshot()
    /// One visible owner decision at a time. The value is display-only; the
    /// checked continuation lives in `approvalGate`.
    @Published private(set) var pendingApproval: BridgeProductPendingApproval?
    @Published private(set) var productListenerError: String?
    /// Product network preferences never inherit historical diagnostic settings.
    @Published private(set) var productLANEnabled = false
    @Published private(set) var productBonjourEnabled = false
    /// Owner desired-running intent. It is independent of the user's
    /// auto-restore preference (`autoStart`) and is the only value a launch
    /// restore may consult for "was this left running?".
    @Published private(set) var desiredRunning = false
    @Published private(set) var isApplicationActive = true

    let rpcHost: BridgeRPCHostService
    let videoService: BridgeVideoService
    /// One structured status-event source. It observes typed transitions and
    /// is injected into the canonical RPC service; no raw host/engine log is
    /// reachable through the product API.
    let statusLog: BridgeProductStatusLog
    private let approvalGate = BridgePairingApprovalGate()
    private var notificationTokens: [NSObjectProtocol] = []
    private var lastTerminalFaultAt: String?
    private var isHandlingAuthenticatedStop = false

#if BRIDGE_PROTOTYPE
    private static let autoStartKey = "org.floeagent.iosbridge.prototype.autostart"
    private static let hasCompletedSetupKey = "org.floeagent.iosbridge.prototype.completed"
    private static let lanEnabledKey = "org.floeagent.iosbridge.prototype.lan"
    private static let controlEnabledKey = "org.floeagent.iosbridge.prototype.control"
#else
    private static let autoStartKey = BridgeProductLifecyclePreferences.autoRestoreKey
    private static let hasCompletedSetupKey = BridgeProductLifecyclePreferences.completedSetupKey
#endif

    let tunnel: BridgeTunnelManager
    let pairing: BridgePairingStore
    let ddiStore: BridgeDDIStore
    let ddiManager: BridgeDDIManager
#if BRIDGE_PROTOTYPE
    let diagnostics = BridgeDiagnosticsServer()
    let lanControl = BridgeLANControlService()
#endif

    private lazy var coordinator = BridgeCoordinator(
        model: self,
        tunnel: tunnel,
        pairing: pairing,
        ddiStore: ddiStore,
        ddiManager: ddiManager
    )
    private var timer: Timer?
    private var didActivate = false
    private var autoStartTask: Task<Void, Never>?
    private var isLoadingInitialAutoStart = false
#if BRIDGE_PROTOTYPE
    private lazy var hostPoller = BridgeHostCommandPoller(model: self)
#endif

    private init() {
        tunnel = BridgeTunnelManager()
        pairing = BridgePairingStore()
        ddiStore = BridgeDDIStore()
        ddiManager = BridgeDDIManager()
        let media = BridgeVideoService()
        videoService = media
        let productStatusLog = BridgeProductStatusLog()
        statusLog = productStatusLog
        // One process-wide engine registry is shared with the embedded test
        // entry. The listener owns no second registry and never replaces it.
        rpcHost = BridgeRPCHostService(
            configuration: BridgeRPCHostService.Configuration(
                requestedPort: BridgeProductRuntime.requestedPort,
                lanEnabled: false,
                bonjourEnabled: false,
                limits: BridgeProductRuntime.limits()
            ),
            resources: BridgeRemoteResources(),
            logs: productStatusLog,
            streamSource: media,
            registry: BridgeRuntime.engineRegistry
        )
        let defaults = UserDefaults.standard
        isLoadingInitialAutoStart = true
        autoStart = BridgeAutoStartPolicy.initialValue(
            stored: Self.storedAutoStart(in: defaults)
        )
        isLoadingInitialAutoStart = false
        desiredRunning = BridgeProductRunIntent.load(from: defaults)
#if BRIDGE_PROTOTYPE
        lanEnabled = defaults.bool(forKey: Self.lanEnabledKey)
        controlEnabled = defaults.bool(forKey: Self.controlEnabledKey)
#endif
        let productPreferences = BridgeProductPreferences.load(from: defaults)
        productLANEnabled = productPreferences.lanEnabled
        productBonjourEnabled = productPreferences.bonjourEnabled
        BridgePaths.prepare()
        BridgeLog.shared.configure(url: BridgePaths.hostLogFile)
        BridgeSharedState.shared.publishInitialStatus()
#if BRIDGE_PROTOTYPE
        if BridgeBuild.prototypeDiagnostics {
            prototypeToken = try? BridgeInstallToken.loadOrCreate(account: BridgeInstallToken.fileChannelAccount)
        }
#endif
        pairingImported = pairing.isImported
        installProductHandlers()
        try? rpcHost.setLANEnabled(productLANEnabled)
        try? rpcHost.setBonjourEnabled(productBonjourEnabled)
        refresh()
        statusLog.record(kind: .launch,
                         shared: snapshot,
                         rpc: rpcSnapshot)
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Installs the one owner bridge between the canonical RPC host and this
    /// service-owned model. All callbacks hop back to the main actor.
    private func installProductHandlers() {
        rpcHost.setApprovalHandler { [weak self] request in
            guard let self else { return .deny }
            // Admission is foreground-independent: a same-phone client may
            // request pairing while Bridge is background. The gate queues one
            // bounded request and the owner approves after reopening Bridge;
            // `approve` still rechecks live activity and the deadline.
            return await self.approvalGate.request(request)
        }
        rpcHost.setStateHandler { [weak self] snapshot in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.applyRPCSnapshot(snapshot)
            }
        }
        rpcHost.setStopHandler { [weak self] in
            // The RPC transport invokes this from its non-main callback queue.
            Task { @MainActor [weak self] in
                self?.handleAuthenticatedServiceStop()
            }
        }
        approvalGate.onPendingChanged = { [weak self] pending in
            self?.pendingApproval = pending
        }
        isApplicationActive = UIApplication.shared.applicationState == .active

        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.isApplicationActive = true
            }
        })
        for name in [UIApplication.willResignActiveNotification,
                     UIApplication.didEnterBackgroundNotification] {
            notificationTokens.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.isApplicationActive = false
                    if self.approvalGate.withdraw() {
                        self.statusLog.record(kind: .pairingWithdrawn,
                                              shared: self.snapshot,
                                              rpc: self.rpcSnapshot)
                    }
                }
            })
        }
    }

    /// One place that adopts a canonical RPC snapshot. Only an actual value
    /// change produces a structured status event, so polling and repeated
    /// callbacks cannot fill the bounded log.
    private func applyRPCSnapshot(_ next: BridgeRPCHostSnapshot,
                                  kind: BridgeProductStatusEvent.Kind = .rpcState) {
        guard next != rpcSnapshot else { return }
        let statusChanged = BridgeProductStatusLog.rpcChanged(
            previous: rpcSnapshot,
            current: next
        )
        rpcSnapshot = next
        if next.running {
            productListenerError = nil
        }
        if statusChanged {
            statusLog.record(kind: kind,
                             shared: snapshot,
                             rpc: next)
        }
    }

    private func productErrorDetail(_ error: Error) -> String {
        let raw = (error as? BridgeRPCNetworkError)?.message ?? error.localizedDescription
        return BridgeProductRedaction.text(raw)
    }

    private func startProduct(trigger: String) {
        guard ensureProductListener() else { return }
        coordinator.start(trigger: trigger)
    }

    /// Starts the one canonical RPC listener for this process. A partially
    /// successful start (loopback live, LAN bind failed) is reported as such
    /// and remains usable locally; a failed loopback start does not start the
    /// engine as if the product were ready.
    private func ensureProductListener() -> Bool {
        if rpcSnapshot.running { return true }
        do {
            try rpcHost.start()
            applyRPCSnapshot(rpcHost.snapshot())
            productListenerError = nil
            return true
        } catch {
            let detail = productErrorDetail(error)
            applyRPCSnapshot(rpcHost.snapshot())
            productListenerError = detail
            if rpcSnapshot.running {
                // The loopback service is live but the optional LAN bind
                // failed. Do not leave the owner toggle claiming LAN success.
                if productLANEnabled {
                    productLANEnabled = false
                    productBonjourEnabled = false
                    BridgeProductPreferences.saveLAN(false)
                    BridgeProductPreferences.saveBonjour(false)
                    try? rpcHost.setLANEnabled(false)
                    applyRPCSnapshot(rpcHost.snapshot())
                }
                banner = BridgeProductCopy.listenerPartialFailure(detail)
                return true
            }
            banner = BridgeProductCopy.listenerStartFailed(detail)
            return false
        }
    }

    /// Closes the canonical entrance, denies a pending pairing decision and
    /// stops any subscribed media. It never reopens a listener and never calls
    /// back into `coordinator.stop`, so it is safe from the disarm hook.
    private func closeProductEntrance(reason: String) {
        let withdrew = approvalGate.withdraw()
        videoService.stop()
        rpcHost.stop()
        applyRPCSnapshot(rpcHost.snapshot(), kind: .serviceClosed)
        if withdrew {
            statusLog.record(kind: .pairingWithdrawn,
                             shared: snapshot,
                             rpc: rpcSnapshot)
        }
        BridgeLog.shared.append("product_entrance_closed reason=\(reason)")
    }

    /// An authenticated client requested `stop_server`. This is a real owner
    /// stop: fence the same model/coordinator epoch and persist the stopped
    /// intent, not only the HTTP listener. The user's auto-restore preference
    /// remains independent; the desired-running intent is what prevents a
    /// later launch from reopening stopped work.
    private func handleAuthenticatedServiceStop() {
        guard !isHandlingAuthenticatedStop else { return }
        isHandlingAuthenticatedStop = true
        defer { isHandlingAuthenticatedStop = false }
        autoStartTask?.cancel()
        markDesiredRunning(false)
        statusLog.record(kind: .authenticatedStop,
                         shared: snapshot,
                         rpc: rpcSnapshot)
        coordinator.stop(trigger: "rpc-stop")
        closeProductEntrance(reason: "rpc-stop")
        banner = BridgeProductCopy.remoteStopped
    }

    private func markDesiredRunning(_ running: Bool) {
        desiredRunning = running
        if running {
            BridgeProductRunIntent.markRunning()
        } else {
            BridgeProductRunIntent.markStopped()
        }
#if BRIDGE_PROTOTYPE
        if BridgeBuild.prototypeDiagnostics, !running {
            // Preserve the legacy prototype's old auto-restore behavior only
            // in the diagnostic build; the product keeps the user preference.
            autoStart = false
        }
#endif
    }

    func activate() {
        guard !didActivate else { return }
        didActivate = true
        Task { [weak self] in
            guard let self else { return }
            await self.tunnel.load()
            // Product startup owns no legacy file-command poller, LAN
            // diagnostics port or control listener. Keep the old activation
            // only for the prototype-diagnostics build.
#if BRIDGE_PROTOTYPE
            if BridgeBuild.prototypeDiagnostics {
                self.hostPoller.start()
            }
#endif
            let current = BridgeSharedState.shared.snapshot()
            if BridgeProductRestorationPolicy.shouldRestoreOnLaunch(
                autoRestore: self.autoStart,
                desiredRunning: self.desiredRunning,
                completedSetup: self.hasCompletedSetup,
                terminalFault: current.terminalFault,
                engineRunning: current.engineRunning
            ) {
                self.autoStartTask = Task { [weak self] in
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled,
                          let self,
                          self.autoStart,
                          self.desiredRunning,
                          self.didActivate else { return }
                    let latest = BridgeSharedState.shared.snapshot()
                    guard BridgeProductRestorationPolicy.shouldRestoreOnLaunch(
                        autoRestore: self.autoStart,
                        desiredRunning: self.desiredRunning,
                        completedSetup: self.hasCompletedSetup,
                        terminalFault: latest.terminalFault,
                        engineRunning: latest.engineRunning
                    ) else { return }
                    self.statusLog.record(kind: .autoRestore,
                                          shared: latest,
                                          rpc: self.rpcSnapshot)
                    self.startProduct(trigger: "auto-restore")
                }
            }
#if BRIDGE_PROTOTYPE
            if BridgeBuild.prototypeDiagnostics {
                if self.lanEnabled { self.startLAN() }
                if self.controlEnabled { self.startControl() }
            }
#endif
            self.refresh()
        }
    }

    func refresh() {
        let previousShared = snapshot
        tunnel.syncStatus()
        var current = BridgeSharedState.shared.snapshot()
        if current.tunnel != tunnel.phase || current.tunnelDetail != tunnel.detail {
            BridgeSharedState.shared.withLifecycle {
                $0.setTunnel(tunnel.phase, detail: tunnel.detail)
            }
            current = BridgeSharedState.shared.snapshot()
        }

        let observedDDI = BridgeDDIProbe.status()
        ddiStatus = observedDDI
        if let facts = observedPreparationFacts(snapshot: current, probe: observedDDI),
           BridgeSharedState.shared.applyPreparationFacts(facts) {
            current = BridgeSharedState.shared.snapshot()
        }

        snapshot = current
        tunnelPhase = tunnel.phase
        tunnelDetail = tunnel.detail
        ddiDownloading = ddiStore.isDownloading
        ddiDownloadProgress = ddiStore.progress
        ddiStatusText = ddiStore.statusText
        ddiError = ddiStore.lastError
#if BRIDGE_PROTOTYPE
        controlListening = lanControl.isListening
        controlError = lanControl.lastError
        controlURLs = lanControl.urls
        controlKeyFingerprint = lanControl.keyFingerprint
#endif

        if current.phase == .ready, current.engineRunning, current.engineEntryObserved {
            let defaults = UserDefaults.standard
            defaults.set(true, forKey: Self.hasCompletedSetupKey)
            if let value = BridgeAutoStartPolicy.valueAfterEngineReady(
                stored: Self.storedAutoStart(in: defaults)
            ) {
                autoStart = value
            }
        }

        // Read the canonical service snapshot directly so engine readiness
        // changes are reflected even when no listener/authority callback fires.
        applyRPCSnapshot(rpcHost.snapshot())
        if current.terminalFault {
            let faultToken = current.terminalFaultAt ?? "terminal"
            if lastTerminalFaultAt != faultToken {
                lastTerminalFaultAt = faultToken
                // A latched terminal fault cannot be retried in this process.
                // Cancel owned preparation/canary work as well as closing the
                // canonical entrance and its media streams.
                coordinator.stop(trigger: "terminal-fault")
                closeProductEntrance(reason: "terminal-fault")
            }
        } else {
            lastTerminalFaultAt = nil
        }
        if !current.serviceRunning,
           !current.phase.isActive,
           !current.engineRunning,
           current.phase == .stopped,
           rpcSnapshot.running {
            // A stop recorded by the shared lifecycle outside the UI action
            // still closes the canonical entrance instead of leaving a
            // listener claiming an owner-intended run.
            closeProductEntrance(reason: "lifecycle-stopped")
        }
        if BridgeProductStatusLog.sharedChanged(previous: previousShared,
                                                current: current) {
            statusLog.record(kind: .sharedState,
                             shared: current,
                             rpc: rpcSnapshot)
        }
    }

    /// Builds facts from the current probe/model state. Active preparation is
    /// owned by the coordinator, so the idle reconciliation does not race its
    /// DDI or mount transitions. A latched failure keeps its diagnostic detail
    /// instead of being flattened into an ordinary observation.
    private func observedPreparationFacts(snapshot: BridgeSnapshot,
                                          probe: BridgeDDIProbe.Status) -> BridgePreparationFacts? {
        switch snapshot.phase {
        case .idle, .ready, .stopped:
            break
        case .preparing, .downloadingDDI, .startingTunnel, .mountingDDI,
             .bootstrapping, .waitingForEngine, .failed:
            return nil
        }

        let phase: BridgeDDIPhase
        if probe.mounted {
            phase = .mounted
        } else if probe.developerDirectoryExists {
            phase = .notMounted
        } else {
            phase = .unknown
        }

        let source: String?
        let detail: String?
        if phase == .mounted {
            // An observation never manufactures an on-device claim. Preserve
            // only a verified on-device mount of this same layout; otherwise
            // the readable mount predates this host and is preexisting.
            let verifiedOnDevice = snapshot.ddiSource == BridgeDDIMountProvenance.onDevice.rawValue &&
                snapshot.lastOnDeviceMountAt != nil &&
                snapshot.lastOnDeviceMountLayout == probe.layout?.rawValue
            source = verifiedOnDevice
                ? BridgeDDIMountProvenance.onDevice.rawValue
                : BridgeDDIMountProvenance.preexisting.rawValue
            detail = snapshot.ddi == .mounted ? snapshot.ddiDetail : "observed mounted runtime"
        } else {
            source = nil
            detail = nil
        }

        return BridgePreparationFacts(
            pairingImported: pairingImported,
            ddi: phase,
            ddiLayout: probe.layout?.rawValue,
            ddiSource: source,
            ddiDetail: detail
        )
    }

    // MARK: - Actions

    func start() {
        autoStartTask?.cancel()
        banner = nil
        markDesiredRunning(true)
        statusLog.record(kind: .ownerStart,
                         shared: snapshot,
                         rpc: rpcSnapshot)
        startProduct(trigger: "ui")
    }

    func stop() {
        autoStartTask?.cancel()
        // Owner Stop records a stopped desired-running intent. The independent
        // auto-restore preference is deliberately untouched in the product;
        // the persisted intent is what keeps the next launch stopped.
        markDesiredRunning(false)
        statusLog.record(kind: .ownerStop,
                         shared: snapshot,
                         rpc: rpcSnapshot)
        // Close the entrance before the lifecycle fence so an already-connected
        // client cannot start new work during the same stop.
        closeProductEntrance(reason: "manual-stop")
        coordinator.stop(trigger: "ui")
        // The coordinator's legacy one-shot warning is diagnostic jargon on
        // the product Run surface; the real state and recovery section carry
        // the truthful result.
        banner = nil
    }

    // MARK: - Product owner actions

    var hasCompletedSetup: Bool {
#if BRIDGE_PROTOTYPE
        UserDefaults.standard.bool(forKey: Self.hasCompletedSetupKey)
#else
        BridgeProductLifecyclePreferences.completedSetup()
#endif
    }

    /// A first-run or missing-prerequisite route. Existing completed installs
    /// keep their normal Run surface even when the image is currently unmounted.
    var requiresSetup: Bool {
        if snapshot.engineRunning { return false }
        if !pairingImported { return true }
        return !ddiStatus.mounted && !ddiStore.isComplete
    }

    /// True only for the first use/missing-requirement route, not every launch.
    var shouldOfferInitialSetup: Bool {
        !hasCompletedSetup && requiresSetup
    }

    var productRunState: BridgeProductRunState {
        BridgeProductRunStatePolicy.runState(
            shared: snapshot,
            rpcRunning: rpcSnapshot.running,
            requiresSetup: requiresSetup
        )
    }

    var productPrimaryAction: BridgeProductPrimaryAction {
        BridgeProductRunStatePolicy.primaryAction(
            shared: snapshot,
            rpcRunning: rpcSnapshot.running,
            requiresSetup: requiresSetup
        )
    }

    var productCanStart: Bool {
        !ddiWorkerBusy && productPrimaryAction != .reopen
    }

    var productCanStop: Bool {
        snapshot.phase.isActive || snapshot.engineRunning ||
            snapshot.serviceRunning || rpcSnapshot.running
    }

    var productActivityText: String? {
        if ddiDownloading { return BridgeProductCopy.downloadingImage }
        switch snapshot.phase {
        case .preparing:
            return BridgeProductCopy.checkingDevice
        case .downloadingDDI:
            return BridgeProductCopy.downloadingImage
        case .startingTunnel:
            return BridgeProductCopy.connectingLocally
        case .mountingDDI:
            return BridgeProductCopy.preparingImage
        case .bootstrapping:
            return BridgeProductCopy.startingEngine
        case .waitingForEngine:
            return BridgeProductCopy.waitingForEngine
        case .ready:
            // The status block already explains the ready state; do not repeat
            // it as a second "current step".
            return nil
        case .stopped:
            return nil
        case .failed:
            return nil
        case .idle:
            return requiresSetup ? BridgeProductCopy.setupNeededDetail : nil
        }
    }

    var productLocalURLs: [URL] {
        BridgeProductReadinessPolicy.localURLs(rpc: rpcSnapshot, shared: snapshot)
    }

    var productPrimaryLocalURL: URL? {
        productLocalURLs.first
    }

    var productRemotePageURL: URL? {
        BridgeProductReadinessPolicy.remotePageURL(rpc: rpcSnapshot, shared: snapshot)
    }

    var productLANURLs: [URL] {
        BridgeProductReadinessPolicy.lanURLs(
            rpc: rpcSnapshot,
            shared: snapshot,
            addresses: BridgeProductNetworkInfo.ipv4Addresses()
        )
    }

    var productNetworkError: String? {
        if let productListenerError, !productListenerError.isEmpty {
            return productListenerError
        }
        return rpcSnapshot.networkError.map { BridgeProductRedaction.text($0) }
    }

    /// LAN and Bonjour are owner toggles only. Bonjour can never be enabled
    /// while LAN is off, and disabling LAN disables Bonjour and closes both
    /// wildcard sockets.
    func setProductLAN(_ enabled: Bool) {
        let previousLAN = productLANEnabled
        let previousBonjour = productBonjourEnabled
        if !enabled {
            productBonjourEnabled = false
            BridgeProductPreferences.saveBonjour(false)
            productLANEnabled = false
            BridgeProductPreferences.saveLAN(false)
            do {
                try rpcHost.setBonjourEnabled(false)
                try rpcHost.setLANEnabled(false)
                productListenerError = nil
            } catch {
                let detail = productErrorDetail(error)
                productListenerError = detail
                banner = BridgeProductCopy.listenerPartialFailure(detail)
            }
            applyRPCSnapshot(rpcHost.snapshot())
            recordNetworkPreferenceIfChanged(previousLAN: previousLAN,
                                             previousBonjour: previousBonjour)
            return
        }

        productLANEnabled = true
        BridgeProductPreferences.saveLAN(true)
        do {
            try rpcHost.setLANEnabled(true)
            productListenerError = nil
        } catch {
            // The bind failed. Do not leave the toggle claiming success.
            productLANEnabled = false
            productBonjourEnabled = false
            BridgeProductPreferences.saveLAN(false)
            BridgeProductPreferences.saveBonjour(false)
            try? rpcHost.setLANEnabled(false)
            let detail = productErrorDetail(error)
            productListenerError = detail
            banner = BridgeProductCopy.listenerPartialFailure(detail)
            applyRPCSnapshot(rpcHost.snapshot())
            recordNetworkPreferenceIfChanged(previousLAN: previousLAN,
                                             previousBonjour: previousBonjour)
            return
        }
        if productBonjourEnabled {
            do {
                try rpcHost.setBonjourEnabled(true)
            } catch {
                try? rpcHost.setBonjourEnabled(false)
                productBonjourEnabled = false
                BridgeProductPreferences.saveBonjour(false)
                banner = BridgeProductCopy.bonjourError + " " + productErrorDetail(error)
            }
        }
        applyRPCSnapshot(rpcHost.snapshot())
        recordNetworkPreferenceIfChanged(previousLAN: previousLAN,
                                         previousBonjour: previousBonjour)
    }

    func setProductBonjour(_ enabled: Bool) {
        let previousBonjour = productBonjourEnabled
        guard productLANEnabled else {
            if enabled {
                banner = BridgeProductCopy.bonjourRequiresLAN
            }
            productBonjourEnabled = false
            BridgeProductPreferences.saveBonjour(false)
            recordNetworkPreferenceIfChanged(previousLAN: productLANEnabled,
                                             previousBonjour: previousBonjour,
                                             kind: .bonjourPreference)
            return
        }
        productBonjourEnabled = enabled
        BridgeProductPreferences.saveBonjour(enabled)
        do {
            try rpcHost.setBonjourEnabled(enabled)
        } catch {
            try? rpcHost.setBonjourEnabled(false)
            productBonjourEnabled = false
            BridgeProductPreferences.saveBonjour(false)
            banner = BridgeProductCopy.bonjourError + " " + productErrorDetail(error)
        }
        applyRPCSnapshot(rpcHost.snapshot())
        recordNetworkPreferenceIfChanged(previousLAN: productLANEnabled,
                                         previousBonjour: previousBonjour,
                                         kind: .bonjourPreference)
    }

    private func recordNetworkPreferenceIfChanged(
        previousLAN: Bool,
        previousBonjour: Bool,
        kind: BridgeProductStatusEvent.Kind = .lanPreference
    ) {
        guard previousLAN != productLANEnabled ||
                previousBonjour != productBonjourEnabled else { return }
        statusLog.record(kind: kind,
                         shared: snapshot,
                         rpc: rpcSnapshot,
                         lanPreference: productLANEnabled,
                         bonjourPreference: productBonjourEnabled)
    }

    func approvePendingPairing() {
        guard let id = pendingApproval?.id else { return }
        let approved = approvalGate.approve(
            requestID: id,
            isForeground: { self.isApplicationActive }
        )
        statusLog.record(kind: .pairingDecision,
                         shared: snapshot,
                         rpc: rpcSnapshot,
                         allowed: approved)
    }

    func denyPendingPairing() {
        guard let id = pendingApproval?.id else { return }
        let denied = approvalGate.deny(requestID: id)
        statusLog.record(kind: .pairingDecision,
                         shared: snapshot,
                         rpc: rpcSnapshot,
                         allowed: false,
                         succeeded: denied)
    }

    func setSensitiveInputGrant(clientID: String, granted: Bool) {
        let changed = rpcHost.grantSensitiveInput(clientID: clientID, granted: granted)
        applyRPCSnapshot(rpcHost.snapshot())
        statusLog.record(kind: .sensitiveInputChanged,
                         shared: snapshot,
                         rpc: rpcSnapshot,
                         granted: granted,
                         succeeded: changed)
        if !changed {
            banner = BridgeProductCopy.storageWriteFailed
        }
    }

    func revokeClient(clientID: String) {
        let revoked = rpcHost.revoke(clientID: clientID)
        applyRPCSnapshot(rpcHost.snapshot())
        statusLog.record(kind: .clientRevoked,
                         shared: snapshot,
                         rpc: rpcSnapshot,
                         succeeded: revoked)
        if !revoked {
            banner = BridgeProductCopy.storageWriteFailed
        }
    }

    func revokeAllClients() {
        let revoked = rpcHost.revokeAll()
        applyRPCSnapshot(rpcHost.snapshot())
        statusLog.record(kind: .allClientsRevoked,
                         shared: snapshot,
                         rpc: rpcSnapshot,
                         succeeded: revoked)
        if !revoked {
            banner = BridgeProductCopy.storageWriteFailed
        }
    }

    func copyProductAddress(_ url: URL) {
        UIPasteboard.general.string = url.absoluteString
        banner = BridgeProductCopy.addressCopied
    }

    var statusLogHealth: BridgeProductStatusLogHealth {
        statusLog.health()
    }

    func recentStatusEvents(limit: Int = 30) -> [String] {
        statusLog.recentLog(limit: limit, matching: nil)
    }

    func safeDiagnosticsJSON() -> String {
        BridgeProductDiagnosticsReport.make(
            shared: snapshot,
            rpc: rpcSnapshot,
            listenerError: productListenerError,
            pendingApproval: pendingApproval != nil,
            statusLog: statusLog.health()
        ).jsonString()
    }

    func copySafeDiagnostics() {
        UIPasteboard.general.string = safeDiagnosticsJSON()
        banner = BridgeProductCopy.safeDiagnosticsCopied
    }

    func resume() {
        markDesiredRunning(true)
        statusLog.record(kind: .ownerResume,
                         shared: snapshot,
                         rpc: rpcSnapshot)
        coordinator.resume(trigger: "ui")
    }

    func mountOnly() {
        coordinator.prepareAndMount(trigger: "ui")
    }

    @discardableResult
    func removeDDI() -> BridgeDDIRemovalDispatch {
        autoStartTask?.cancel()
        return coordinator.removeDDI(trigger: "ui")
    }

    @discardableResult
    func runStageProbe() -> BridgeDDIStageProbeDispatch {
        autoStartTask?.cancel()
        return coordinator.runStageProbe(trigger: "ui")
    }

    func noteStageProbeSummary(_ value: String?) {
        stageProbeSummary = value
    }

    func noteCanary(_ report: BridgeCanaryReport?) {
        canaryReport = report
    }

    var canaryRunning: Bool {
        canaryReport?.state.isLive ?? false
    }

    var canarySummary: String? {
        guard let report = canaryReport else { return nil }
        let total = report.steps.count
        switch report.state {
        case .idle:
            return nil
        case .pending:
            return BridgeL10n.t(
                "Self-check waiting for the real engine entry.",
                "自检正在等待真实引擎入口。"
            )
        case .running:
            let step = report.currentStepIndex.map { $0 + 1 } ?? report.passedCount
            let action = report.currentStepIndex.flatMap {
                report.steps.indices.contains($0) ? report.steps[$0].action : nil
            } ?? "—"
            return BridgeL10n.t(
                "Self-check running: step \(step)/\(total) (\(action)).",
                "自检进行中：第 \(step)/\(total) 步（\(action)）。"
            )
        case .completed:
            return BridgeL10n.t(
                "Self-check complete: \(report.passedCount)/\(total) steps passed.",
                "自检完成：\(report.passedCount)/\(total) 步通过。"
            )
        case .partial:
            let action = report.steps.first(where: {
                $0.state == .failed || $0.state == .unobserved
            })?.action ?? report.failureCode ?? "—"
            return BridgeL10n.t(
                "Self-check partial: \(report.passedCount)/\(total) passed; stopped at \(action).",
                "自检部分完成：\(report.passedCount)/\(total) 通过；停在 \(action)。"
            )
        case .failed:
            let action = report.steps.first(where: {
                $0.state == .failed || $0.state == .unobserved
            })?.action ?? "start"
            return BridgeL10n.t(
                "Self-check failed at \(action) (\(report.failureCode ?? "error")).",
                "自检在 \(action) 处失败（\(report.failureCode ?? "错误")）。"
            )
        case .cancelled:
            return BridgeL10n.t("Self-check cancelled.", "自检已取消。")
        }
    }

    func startAndCheck() {
        autoStartTask?.cancel()
        banner = nil
        markDesiredRunning(true)
        statusLog.record(kind: .ownerStart,
                         shared: snapshot,
                         rpc: rpcSnapshot)
        let dispatch = coordinator.startAndCheck(trigger: "ui")
        if case .refused(_, let message) = dispatch {
            banner = message
        }
        refresh()
    }

    func importPairing(_ url: URL) {
        Task { [weak self] in
            await self?.coordinator.importPairing(url: url)
            self?.pairingImported = self?.pairing.isImported ?? false
        }
    }

    func removePairing() {
        coordinator.removePairing()
        pairingImported = false
    }

    func downloadDDI() {
        coordinator.downloadDDI()
    }

    func cancelDDIDownload() {
        coordinator.cancelDDIDownload()
    }

    func importDDIFolder(_ url: URL) {
        Task { [weak self] in
            await self?.coordinator.importDDIFolder(url: url)
        }
    }

    func toggleTunnel() {
        Task { [weak self] in
            await self?.coordinator.toggleTunnel()
        }
    }

    func startTunnel() {
        Task { [weak self] in
            await self?.coordinator.startTunnelOnly()
        }
    }

    func stopTunnel() {
        coordinator.stopTunnelOnly()
    }

#if BRIDGE_PROTOTYPE
    func startLAN() {
        if diagnostics.isStarted {
            lanListening = diagnostics.isListening
            return
        }
        do {
            let token = try BridgeInstallToken.loadOrCreate(account: BridgeInstallToken.fileChannelAccount)
            prototypeToken = token
            lanToken = token
            diagnostics.onStateChange = { [weak self] listening, error in
                Task { @MainActor in
                    self?.lanListening = listening
                    self?.lanError = error
                }
            }
            try diagnostics.start(token: token) {
                BridgeDiagnosticsStatus.buildJSONData()
            }
            lanError = nil
        } catch {
            lanEnabled = false
            lanError = error.localizedDescription
            banner = error.localizedDescription
            BridgeLog.shared.append("lan_diagnostics_start_failed error=\(error.localizedDescription)")
        }
    }

    func stopLAN() {
        diagnostics.stop()
        lanListening = false
    }

    // MARK: - Encrypted LAN control

    func startControl() {
        do {
            try lanControl.start()
            controlError = nil
            controlListening = lanControl.isListening
            controlURLs = lanControl.urls
            controlKeyFingerprint = lanControl.keyFingerprint
            lanControl.setShutdownHandler { [weak self] identifier in
                Task { @MainActor in
                    // Give the sealed acknowledgement a bounded chance to
                    // flush before the control listener closes. A lost
                    // acknowledgement is reported by the client as an
                    // unknown outcome and is never retried.
                    try? await Task.sleep(for: .milliseconds(150))
                    self?.performRemoteShutdown(identifier: identifier)
                }
            }
        } catch {
            controlEnabled = false
            controlError = error.localizedDescription
            controlListening = false
            controlURLs = []
            banner = error.localizedDescription
            BridgeLog.shared.append("lan_control_start_failed")
        }
    }

    func stopControl() {
        lanControl.stop()
        controlListening = false
        controlURLs = []
    }

    func setControl(_ enabled: Bool) {
        controlEnabled = enabled
        if enabled {
            startControl()
        } else {
            stopControl()
        }
    }

    func revokeControlKey() {
        lanControl.revoke()
        controlEnabled = false
        controlListening = false
        controlURLs = []
        controlKeyFingerprint = nil
        controlError = nil
        banner = BridgeL10n.t("Remote access revoked.", "遥控授权已撤销。")
    }

    func fenceLANControl(reason: String) {
        lanControl.fence(reason: reason)
    }

#endif

    /// Normal Stop closes the control entrance and clears the owner-armed
    /// preference. A subsequent Start/Resume must be a device-owner action;
    /// an authenticated controller cannot reopen engine work through the old
    /// listener. The separate key is retained until an explicit revoke.
    func disarmLANControlForStop() {
        // This hook is called by every coordinator stop (UI, remote control,
        // authenticated RPC). The canonical product entrance must close even
        // when the legacy control service was never started.
        closeProductEntrance(reason: "stop")
#if BRIDGE_PROTOTYPE
        guard BridgeLANControlArmPolicy.shouldDisarm(
            controlEnabled: controlEnabled,
            serverStarted: lanControl.isStarted,
            listening: controlListening
        ) else {
            lanControl.fence(reason: "stop")
            return
        }
        lanControl.stop()
        controlEnabled = false
        controlListening = false
        controlURLs = []
        controlError = nil
        BridgeLog.shared.append("lan_control_disarmed reason=stop")
#endif
    }

#if BRIDGE_PROTOTYPE
    func performAuthenticatedShutdown(identifier: String) {
        performRemoteShutdown(identifier: identifier)
    }

    /// Authenticated one-way cleanup from the LAN control entrance. It stops
    /// owned engine work, closes the read-only diagnostics listener and then
    /// revokes the control key and closes this listener. It never enables
    /// anything or touches the install token; it records a stopped desired
    /// intent so automation cannot reopen the session on the next launch.
    private func performRemoteShutdown(identifier: String) {
        BridgeLog.shared.append("lan_control_shutdown_begin id=\(identifier)")
        markDesiredRunning(false)
        statusLog.record(kind: .remoteStop,
                         shared: snapshot,
                         rpc: rpcSnapshot)
        coordinator.stop(trigger: "lan-shutdown")
        setLAN(false)
        controlEnabled = false
        lanControl.revoke()
        controlListening = false
        controlURLs = []
        controlKeyFingerprint = nil
        controlError = nil
        banner = BridgeL10n.t(
            "Remote control stopped and access revoked.",
            "已停止遥控并撤销授权。"
        )
        BridgeLog.shared.append("lan_control_shutdown_end id=\(identifier)")
    }

    func setLAN(_ enabled: Bool) {
        lanEnabled = enabled
        if enabled {
            startLAN()
        } else {
            stopLAN()
        }
    }

    struct RecoveryConfigurationResult {
        var autoStart: Bool
        var lanEnabled: Bool
        var lanListening: Bool
        var lanURL: String?
        var controlEnabled: Bool
        var controlListening: Bool
        var controlURLs: [String]
        var controlKeyFingerprint: String?
    }

    enum RecoveryConfigurationError: LocalizedError {
        case noFields

        var errorDescription: String? {
            "At least one recovery field is required."
        }
    }

    /// Applies only the supplied preferences. The response reports the actual
    /// post-apply state; no control key or other credential is returned.
    func configureRecovery(autoStart: Bool?,
                           lanEnabled: Bool?,
                           controlEnabled: Bool?,
                           controlKey: String?) throws -> RecoveryConfigurationResult {
        guard autoStart != nil || lanEnabled != nil ||
                controlEnabled != nil || controlKey != nil else {
            throw RecoveryConfigurationError.noFields
        }
        if controlEnabled == true, controlKey == nil, !lanControl.hasKey {
            throw BridgeLANControlError.missingKey
        }
        if let autoStart { self.autoStart = autoStart }
        if let lanEnabled { setLAN(lanEnabled) }
        if let controlKey {
            _ = try lanControl.provision(keyString: controlKey)
        }
        if let controlEnabled {
            if controlEnabled && !lanControl.hasKey {
                throw BridgeLANControlError.missingKey
            }
            setControl(controlEnabled)
        }
        refresh()
        return RecoveryConfigurationResult(
            autoStart: self.autoStart,
            lanEnabled: self.lanEnabled,
            lanListening: diagnostics.isListening,
            lanURL: diagnostics.isStarted ? lanURL : nil,
            controlEnabled: self.controlEnabled,
            controlListening: lanControl.isListening,
            controlURLs: lanControl.urls,
            controlKeyFingerprint: lanControl.keyFingerprint
        )
    }

#endif

    private static func storedAutoStart(in defaults: UserDefaults) -> Bool? {
#if BRIDGE_PROTOTYPE
        defaults.object(forKey: autoStartKey) == nil
            ? nil
            : defaults.bool(forKey: autoStartKey)
#else
        BridgeProductLifecyclePreferences.storedAutoRestore(in: defaults)
#endif
    }

    func channelToken() -> String? {
#if BRIDGE_PROTOTYPE
        // Product builds never create or load the legacy file-command token.
        guard BridgeBuild.prototypeDiagnostics else { return nil }
        if let prototypeToken { return prototypeToken }
        do {
            let token = try BridgeInstallToken.loadOrCreate(account: BridgeInstallToken.fileChannelAccount)
            prototypeToken = token
            return token
        } catch {
            banner = "Could not read the prototype channel token: \(error.localizedDescription)"
            return nil
        }
#else
        // Kept for the historical coordinator API; product owns no file token.
        return nil
#endif
    }

#if BRIDGE_PROTOTYPE
    func diagnosticsJSON() -> String {
        String(decoding: BridgeDiagnosticsStatus.buildJSONData(logTail: true), as: UTF8.self)
    }

    func logTail() -> String {
        BridgeLog.shared.tail(maxBytes: 16_384)
    }

    func copyDiagnostics() {
        UIPasteboard.general.string = diagnosticsJSON()
        banner = BridgeL10n.t("Diagnostics copied.", "诊断信息已复制。")
    }

    func copyToken() {
        guard let token = prototypeToken ?? channelToken() else { return }
        UIPasteboard.general.string = token
        banner = BridgeL10n.t("Prototype token copied. It is required for file commands and the LAN endpoint.",
                              "原型令牌已复制。文件命令和局域网端点都需要它。")
    }

    enum TokenRotationOutcome {
        case rotated
        case invalidReplacement
        case unchanged
        case failed
    }

    /// Prototype-only rotation. The replacement is validated before any write,
    /// the Keychain update is the single source of truth, and the LAN listener
    /// is stopped before the update so an old bearer cannot remain accepted
    /// while the in-memory cache catches up. No token is logged or returned.
    func rotatePrototypeToken(replacementToken: String?) -> TokenRotationOutcome {
        if let replacementToken {
            do {
                _ = try BridgeInstallToken.validateReplacement(
                    replacementToken,
                    current: try? BridgeInstallToken.load(account: BridgeInstallToken.fileChannelAccount)
                )
            } catch let error as BridgeInstallToken.RotationError {
                switch error {
                case .invalidReplacement: return .invalidReplacement
                case .unchangedReplacement: return .unchanged
                }
            } catch {
                return .failed
            }
        }

        // Token rotation fences every queued LAN command and closes in-flight
        // HTTP connections. The control key is separate and is not rederived
        // from this token.
        lanControl.fence(reason: "token-rotation")
        let lanWasRunning = diagnostics.isStarted
        if lanWasRunning {
            diagnostics.stop()
            lanListening = false
        }

        do {
            try BridgeInstallToken.rotate(
                account: BridgeInstallToken.fileChannelAccount,
                replacementToken: replacementToken
            )
        } catch {
            BridgeLog.shared.append("prototype_token_rotation_failed")
            if lanWasRunning || lanEnabled { startLAN() }
            return .failed
        }

        if let token = try? BridgeInstallToken.load(account: BridgeInstallToken.fileChannelAccount) {
            prototypeToken = token
            lanToken = token
        } else {
            prototypeToken = nil
            lanToken = nil
            BridgeLog.shared.append("prototype_token_cache_refresh_failed")
        }

        if lanEnabled { startLAN() }
        return .rotated
    }

    var lanURL: String? {
        diagnostics.listeningURL()
    }

#endif

    var activityText: String? {
        if canaryRunning, snapshot.phase == .ready {
            return canarySummary ?? BridgeL10n.t("Self-check running.", "自检进行中。")
        }
        if snapshot.activity == "remove-ddi" || snapshot.activity == "remove-ddi-tunnel" {
            return BridgeL10n.t("Removing the developer image…", "正在移除开发者镜像…")
        }
        if snapshot.activity == "ddi-stage-probe" {
            return BridgeL10n.t("Checking DDI stages…", "正在检查 DDI 阶段…")
        }
        if ddiDownloading {
            return BridgeL10n.t("Downloading DDI files…", "正在下载 DDI 文件…")
        }
        switch snapshot.phase {
        case .preparing: return BridgeL10n.t("Preparing…", "正在准备…")
        case .downloadingDDI: return BridgeL10n.t("Downloading DDI files…", "正在下载 DDI 文件…")
        case .startingTunnel: return BridgeL10n.t("Starting the internal reflector…", "正在启动内部反射隧道…")
        case .mountingDDI: return BridgeL10n.t("Mounting the DDI on this device…", "正在本机挂载 DDI…")
        case .bootstrapping: return BridgeL10n.t("Dispatching the one-shot test entry…", "正在派发一次性测试入口…")
        case .waitingForEngine: return BridgeL10n.t("Waiting for engine entry. The system may ask for your passcode.",
                                                     "正在等待引擎入口。系统可能会要求输入密码。")
        case .ready: return snapshot.engineRunning
            ? BridgeL10n.t("Engine control is active.", "引擎控制已就绪。")
            : BridgeL10n.t("Engine is initialized and stopped. Resume reuses the driver.",
                           "引擎已初始化并停止。恢复会复用驱动。")
        case .stopped:
            if snapshot.oneShotDispatched && !snapshot.engineEntryObserved {
                return BridgeL10n.t("Stopped. The one-shot initializer may still complete; Start will reuse it.",
                                    "已停止。一次性初始化仍可能完成；再次启动会复用它。")
            }
            return BridgeL10n.t("Stopped.", "已停止。")
        case .failed: return snapshot.lastError
        case .idle: return nil
        }
    }

    var engineStateText: String {
        if snapshot.engineRunning { return BridgeL10n.t("Running", "运行中") }
        if snapshot.engineEntryObserved { return BridgeL10n.t("Initialized / stopped", "已初始化 / 已停止") }
        if snapshot.oneShotDispatched { return BridgeL10n.t("Entry dispatched", "入口已派发") }
        switch snapshot.phase {
        case .failed: return BridgeL10n.t("Failed", "失败")
        case .stopped: return BridgeL10n.t("Stopped", "已停止")
        default: return BridgeL10n.t("Not started", "未启动")
        }
    }

    func ddiStateText() -> String {
        if ddiStatus.mounted {
            let layout = ddiStatus.layout?.rawValue ?? "unknown"
            return BridgeL10n.t("Mounted (\(layout))", "已挂载（\(layout)）")
        }
        return ddiStatus.developerDirectoryExists
            ? BridgeL10n.t("Not mounted", "未挂载")
            : BridgeL10n.t("Developer Mode unavailable", "开发者模式不可用")
    }

    func tunnelStateText() -> String {
        switch tunnelPhase {
        case .connected: return BridgeL10n.t("Connected (reflector)", "已连接（反射器）")
        case .connecting: return BridgeL10n.t("Connecting…", "连接中…")
        case .disconnecting: return BridgeL10n.t("Disconnecting…", "断开中…")
        case .disconnected: return BridgeL10n.t("Disconnected", "未连接")
        case .invalid: return BridgeL10n.t("Rejected by the system", "被系统拒绝")
        case .failed: return BridgeL10n.t("Failed", "失败")
        case .unknown: return BridgeL10n.t("Unknown", "未知")
        }
    }
}
