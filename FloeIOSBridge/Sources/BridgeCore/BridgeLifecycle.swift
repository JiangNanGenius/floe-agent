import Foundation

public enum BridgeEnginePhase: String, Codable, Sendable, CaseIterable {
    case idle
    case preparing
    case downloadingDDI = "downloading-ddi"
    case startingTunnel = "starting-tunnel"
    case mountingDDI = "mounting-ddi"
    case bootstrapping
    case waitingForEngine = "waiting-for-engine"
    case ready
    case stopped
    case failed

    public var isActive: Bool {
        switch self {
        case .preparing, .downloadingDDI, .startingTunnel, .mountingDDI,
             .bootstrapping, .waitingForEngine:
            return true
        case .idle, .ready, .stopped, .failed:
            return false
        }
    }
}

public enum BridgeTunnelPhase: String, Codable, Sendable, CaseIterable {
    case unknown
    case disconnected
    case connecting
    case connected
    case disconnecting
    case invalid
    case failed
}

public enum BridgeDDIPhase: String, Codable, Sendable, CaseIterable {
    case unknown
    case notMounted = "not-mounted"
    case downloading
    case mounting
    case mounted
    case failed
}

public enum BridgeStartDecision: Equatable, Sendable {
    case started(UInt64)
    case waitingForExistingBootstrap(UInt64)
    case resumed
    /// A terminal post-dispatch fault is latched. This process cannot retry the
    /// one-shot bootstrap; the app must be reopened.
    case reopenRequired(code: String)
    case ignored
}

public enum BridgeResumeDecision: Equatable, Sendable {
    case resumed
    /// A terminal fault must survive Stop; only a new process may retry.
    case reopenRequired(code: String)
    case unavailable
}

/// Who supplied the currently readable DDI. A missing report flag is treated
/// conservatively as preexisting; an on-device claim additionally requires the
/// worker to have verified that both service queries succeeded and reported
/// absence before the install. A mount report alone is not provenance.
public enum BridgeDDIMountProvenance: String, Codable, Sendable {
    case onDevice = "on-device"
    case preexisting

    public static func classify(
        alreadyMounted: Bool?,
        preStateVerifiedAbsent: Bool
    ) -> BridgeDDIMountProvenance {
        (alreadyMounted == false && preStateVerifiedAbsent) ? .onDevice : .preexisting
    }
}

/// Durable view of the prototype's true state.
///
/// `serviceRunning` is the user-requested service state. It is deliberately
/// separate from `oneShotDispatched` and `engineEntryObserved`: Stop can close
/// the service and fence preparation while an already-enqueued XCTest
/// initializer continues and later records that the driver was initialized.
public struct BridgeSnapshot: Codable, Equatable, Sendable {
    public var schema = 1
    public var hostPid: Int32 = 0
    public var marketingVersion: String = BridgeBuild.marketingVersion
    public var buildNumber: String = BridgeBuild.buildNumber
    public var phase: BridgeEnginePhase = .idle
    public var generation: UInt64 = 0
    public var serviceRunning = false
    public var startAttempted = false
    public var oneShotDispatched = false
    public var dispatchedGeneration: UInt64?
    public var engineEntryObserved = false
    public var engineRunning = false
    public var enginePid: Int32?
    public var engineTestMethod: String?
    public var engineInitializedAt: String?
    /// Sticky post-dispatch fault. Stop does not clear it and no later Start or
    /// Resume may re-arm the one-shot bootstrap in this process.
    public var terminalFault = false
    public var terminalFaultCode: String?
    public var terminalFaultMessage: String?
    public var terminalFaultAt: String?
    public var tunnel: BridgeTunnelPhase = .unknown
    public var tunnelDetail: String?
    public var tunnelProbe: String = "not-run"
    public var ddi: BridgeDDIPhase = .unknown
    public var ddiLayout: String?
    public var ddiSource: String?
    public var ddiDetail: String?
    public var pairingImported = false
    /// Timestamped pre-start probe event. Both mounted and absent outcomes are
    /// recorded so a later readback can prove the DDI state before a mount.
    public var lastDDIProbeAt: String?
    public var lastDDIProbeMounted: Bool?
    public var lastDDIProbeLayout: String?
    public var lastDDIProbePath: String?
    public var lastDDIProbeSource: String?
    /// Set only after an install by this app was verified readable. Ordinary
    /// observations must never refresh this timestamp.
    public var lastOnDeviceMountAt: String?
    public var lastOnDeviceMountLayout: String?
    public var lastOnDeviceMountPath: String?
    public var lastError: String?
    public var errorCode: String?
    public var activity: String?
    public var notes: [String] = []
    public var startedAt: String?
    public var readyAt: String?
    public var stoppedAt: String?
    public var updatedAt: String = BridgeClock.timestamp()

    public init() {}
}

/// Externally observed preparation facts. Applying these never changes the
/// engine phase, generation, service ownership, one-shot dispatch, entry
/// observation or readiness; it only keeps the displayed facts truthful.
public struct BridgePreparationFacts: Equatable, Sendable {
    public var pairingImported: Bool
    public var ddi: BridgeDDIPhase
    public var ddiLayout: String?
    public var ddiSource: String?
    public var ddiDetail: String?

    public init(pairingImported: Bool,
                ddi: BridgeDDIPhase,
                ddiLayout: String? = nil,
                ddiSource: String? = nil,
                ddiDetail: String? = nil) {
        self.pairingImported = pairingImported
        self.ddi = ddi
        self.ddiLayout = ddiLayout
        self.ddiSource = ddiSource
        self.ddiDetail = ddiDetail
    }
}

/// Pure default-state policy for the prototype's Auto-recover preference.
///
/// A missing stored value is not the same as a saved `false`: the default is
/// applied only after a real engine-ready transition, while an explicit user
/// choice always wins.
public enum BridgeAutoStartPolicy {
    /// Launch value. A saved value, including an explicit `false`, is used
    /// verbatim. An absent preference starts `false`; only a real engine-ready
    /// transition below may apply the `true` default.
    public static func initialValue(stored: Bool?) -> Bool {
        stored ?? false
    }

    /// Returns the value to apply on a real engine-ready transition, or nil
    /// when a preference is already stored and must not be replaced.
    public static func valueAfterEngineReady(stored: Bool?) -> Bool? {
        stored == nil ? true : nil
    }
}

/// Ownership record for the read-only DDI stage probe fence. It is only a
/// generation and the phase/activity to restore, never a readiness claim.
public struct BridgeDDIStageProbeFence: Equatable, Sendable {
    public var generation: UInt64
    public var previousPhase: BridgeEnginePhase
    public var previousActivity: String?

    public init(
        generation: UInt64,
        previousPhase: BridgeEnginePhase,
        previousActivity: String?
    ) {
        self.generation = generation
        self.previousPhase = previousPhase
        self.previousActivity = previousActivity
    }
}

/// Pure state machine, exercised directly by the host checks.
///
/// Irreversible XCTest dispatch is identified by `dispatchedGeneration`, not
/// by the current service generation. A late real entry is accepted if it
/// belongs to that dispatch and matches this PID; it does not promote a service
/// the user already stopped. Truly stale pre-dispatch callbacks still fail the
/// generation checks.
public struct BridgeLifecycle: Sendable {
    public private(set) var snapshot: BridgeSnapshot

    public init(hostPid: Int32 = Int32(ProcessInfo.processInfo.processIdentifier)) {
        var value = BridgeSnapshot()
        value.hostPid = hostPid
        snapshot = value
    }

    public var isEngineReady: Bool {
        snapshot.serviceRunning && snapshot.engineEntryObserved &&
            snapshot.engineRunning && snapshot.phase == .ready
    }

    public var acceptsEngineCommands: Bool {
        isEngineReady && snapshot.enginePid == snapshot.hostPid
    }

    public mutating func beginStart(trigger: String) -> UInt64 {
        guard !snapshot.terminalFault else {
            snapshot.notes.append("begin-start refused terminal-fault trigger=\(trigger)")
            trimNotes()
            touch()
            return snapshot.generation
        }
        snapshot.generation &+= 1
        snapshot.serviceRunning = true
        snapshot.phase = .preparing
        snapshot.startAttempted = true
        snapshot.engineRunning = false
        snapshot.activity = "prepare"
        snapshot.lastError = nil
        snapshot.errorCode = nil
        snapshot.startedAt = BridgeClock.timestamp()
        snapshot.stoppedAt = nil
        snapshot.notes.append("start trigger=\(trigger) generation=\(snapshot.generation)")
        trimNotes()
        touch()
        return snapshot.generation
    }

    /// Starts the bounded prototype DDI-removal operation. It uses the same
    /// generation and service fence as a start, but does not record an engine
    /// start attempt or promise that a bootstrap will be dispatched.
    public mutating func beginDDIRemoval(trigger: String) -> UInt64 {
        guard !snapshot.terminalFault else {
            snapshot.notes.append("begin-removal refused terminal-fault trigger=\(trigger)")
            trimNotes()
            touch()
            return snapshot.generation
        }
        snapshot.generation &+= 1
        snapshot.serviceRunning = true
        snapshot.phase = .preparing
        snapshot.engineRunning = false
        snapshot.activity = "remove-ddi"
        snapshot.lastError = nil
        snapshot.errorCode = nil
        snapshot.startedAt = BridgeClock.timestamp()
        snapshot.stoppedAt = nil
        snapshot.notes.append("ddi-removal begin trigger=\(trigger) generation=\(snapshot.generation)")
        trimNotes()
        touch()
        return snapshot.generation
    }

    /// Fence for the prototype-only read-only DDI stage probe. It uses the same
    /// generation and service fence as removal (so Stop can abort it and late
    /// results are rejected) without recording a start attempt or changing the
    /// DDI/readiness state. The previous phase and activity are restored on a
    /// clean completion; a Stop during the probe wins and is not overwritten.
    @discardableResult
    public mutating func beginDDIStageProbe(trigger: String) -> BridgeDDIStageProbeFence {
        let previousPhase = snapshot.phase
        let previousActivity = snapshot.activity
        guard !snapshot.terminalFault else {
            snapshot.notes.append(
                "begin-stage-probe refused terminal-fault trigger=\(trigger)"
            )
            trimNotes()
            touch()
            return BridgeDDIStageProbeFence(
                generation: snapshot.generation,
                previousPhase: previousPhase,
                previousActivity: previousActivity
            )
        }
        snapshot.generation &+= 1
        snapshot.serviceRunning = true
        snapshot.phase = .preparing
        snapshot.engineRunning = false
        snapshot.activity = "ddi-stage-probe"
        snapshot.notes.append(
            "ddi-stage-probe begin trigger=\(trigger) generation=\(snapshot.generation)"
        )
        trimNotes()
        touch()
        return BridgeDDIStageProbeFence(
            generation: snapshot.generation,
            previousPhase: previousPhase,
            previousActivity: previousActivity
        )
    }

    /// Completes only the probe fence owned by `fence`. A Stop (or any other
    /// fence) has advanced the generation and closed the phase, so this cannot
    /// resurrect stale state.
    @discardableResult
    public mutating func endDDIStageProbe(
        _ fence: BridgeDDIStageProbeFence,
        reason: String
    ) -> Bool {
        guard fence.generation == snapshot.generation, snapshot.phase.isActive else {
            return false
        }
        snapshot.generation &+= 1
        snapshot.serviceRunning = false
        snapshot.engineRunning = false
        snapshot.phase = snapshot.terminalFault ? .failed : fence.previousPhase
        snapshot.activity = fence.previousActivity
        snapshot.notes.append(
            "ddi-stage-probe end reason=\(reason) generation=\(snapshot.generation)"
        )
        trimNotes()
        touch()
        return true
    }

    /// One atomic decision for Start, so an entry arriving concurrently cannot
    /// be missed between inspecting the snapshot and mutating it.
    public mutating func requestStart(trigger: String) -> BridgeStartDecision {
        if snapshot.terminalFault {
            return .reopenRequired(code: snapshot.terminalFaultCode ?? "terminal-fault")
        }
        if snapshot.engineRunning && snapshot.serviceRunning {
            return .ignored
        }
        if snapshot.oneShotDispatched && snapshot.engineEntryObserved {
            switch requestEngineResume() {
            case .resumed:
                snapshot.notes.append("start resumed-initialized-driver trigger=\(trigger)")
                trimNotes()
                return .resumed
            case .reopenRequired(let code):
                return .reopenRequired(code: code)
            case .unavailable:
                return .ignored
            }
        }
        if snapshot.oneShotDispatched {
            guard let generation = reenableServiceForPendingBootstrap(reason: trigger) else {
                // The entry can land between the first check and this call.
                if snapshot.engineEntryObserved {
                    switch requestEngineResume() {
                    case .resumed:
                        snapshot.notes.append("start resumed-at-pending-race trigger=\(trigger)")
                        trimNotes()
                        return .resumed
                    case .reopenRequired(let code):
                        return .reopenRequired(code: code)
                    case .unavailable:
                        break
                    }
                }
                return .ignored
            }
            return .waitingForExistingBootstrap(generation)
        }
        if snapshot.phase.isActive {
            return .ignored
        }
        return .started(beginStart(trigger: trigger))
    }

    public func isCurrent(_ generation: UInt64) -> Bool {
        generation == snapshot.generation && snapshot.serviceRunning && snapshot.phase.isActive
    }

    @discardableResult
    public mutating func advance(_ generation: UInt64,
                                 to phase: BridgeEnginePhase,
                                 activity: String?) -> Bool {
        guard isCurrent(generation) else { return false }
        snapshot.phase = phase
        snapshot.activity = activity
        touch()
        return true
    }

    /// Ordinary, retryable startup failure (DDI/download/tunnel/pairing). It
    /// does not latch a terminal fault, so a later Start may retry from the
    /// beginning. A fault that is already latched is never cleared here.
    @discardableResult
    public mutating func fail(_ generation: UInt64,
                              code: String,
                              message: String) -> Bool {
        guard isCurrent(generation) else { return false }
        snapshot.phase = .failed
        snapshot.serviceRunning = false
        snapshot.engineRunning = false
        if !snapshot.terminalFault {
            snapshot.errorCode = code
            snapshot.lastError = message
        }
        snapshot.activity = nil
        snapshot.notes.append("failed code=\(code) terminal=\(snapshot.terminalFault)")
        trimNotes()
        touch()
        return true
    }

    public mutating func failWithoutGeneration(code: String, message: String) {
        snapshot.phase = .failed
        snapshot.serviceRunning = false
        snapshot.engineRunning = false
        if !snapshot.terminalFault {
            snapshot.errorCode = code
            snapshot.lastError = message
        }
        snapshot.activity = nil
        touch()
    }

    /// Latches an irreversible post-dispatch initialization failure/timeout.
    /// The one-shot XCTest entry cannot be repeated in this process, so no
    /// later Start/Resume may re-enable waiting or dispatch again.
    @discardableResult
    public mutating func failTerminal(_ generation: UInt64,
                                      code: String,
                                      message: String) -> Bool {
        guard generation == snapshot.generation,
              snapshot.phase.isActive || snapshot.engineRunning else {
            return false
        }
        latchTerminalFault(code: code, message: message)
        return true
    }

    /// Engine-side fatal failure after the real test entry. The driver cannot
    /// be trusted for this process; Stop only fences it, and a new process is
    /// required before another attempt.
    @discardableResult
    public mutating func noteEngineFailure(pid: Int32,
                                           code: String,
                                           message: String) -> Bool {
        guard snapshot.engineEntryObserved, snapshot.enginePid == pid else {
            return false
        }
        latchTerminalFault(code: code, message: message)
        return true
    }

    private mutating func latchTerminalFault(code: String, message: String) {
        guard !snapshot.terminalFault else { return }
        snapshot.terminalFault = true
        snapshot.terminalFaultCode = code
        snapshot.terminalFaultMessage = message
        snapshot.terminalFaultAt = BridgeClock.timestamp()
        snapshot.phase = .failed
        snapshot.serviceRunning = false
        snapshot.engineRunning = false
        snapshot.activity = nil
        snapshot.errorCode = code
        snapshot.lastError = message
        snapshot.notes.append("terminal-fault code=\(code) engineEntry=\(snapshot.engineEntryObserved)")
        trimNotes()
        touch()
    }

    /// Fences every cancellable asynchronous step. It neither aborts an
    /// already-enqueued `_XCTestMain` nor clears the one-shot dispatch record.
    @discardableResult
    public mutating func fence(reason: String) -> UInt64 {
        snapshot.generation &+= 1
        snapshot.serviceRunning = false
        snapshot.phase = snapshot.terminalFault ? .failed : .stopped
        snapshot.engineRunning = false
        snapshot.activity = nil
        snapshot.stoppedAt = BridgeClock.timestamp()
        snapshot.notes.append(
            "fence reason=\(reason) generation=\(snapshot.generation) " +
            "terminalFault=\(snapshot.terminalFault)"
        )
        trimNotes()
        touch()
        return snapshot.generation
    }

    @discardableResult
    public mutating func markBootstrapDispatched(_ generation: UInt64) -> Bool {
        guard isCurrent(generation), !snapshot.oneShotDispatched else { return false }
        snapshot.oneShotDispatched = true
        snapshot.dispatchedGeneration = generation
        snapshot.phase = .waitingForEngine
        snapshot.activity = "waiting-engine"
        touch()
        return true
    }

    /// Records the real test-method entry. The parameter is the immutable
    /// dispatch generation, not the current service generation. A service that
    /// was stopped during initialization records the initialized driver but
    /// stays stopped; a later Start resumes it without re-dispatching.
    @discardableResult
    public mutating func noteEngineEntry(_ generation: UInt64,
                                         pid: Int32,
                                         testMethod: String,
                                         hostPid expectedHostPid: Int32?) -> Bool {
        guard snapshot.oneShotDispatched,
              snapshot.dispatchedGeneration == generation,
              pid == snapshot.hostPid,
              expectedHostPid == nil || expectedHostPid == pid else {
            return false
        }
        if snapshot.terminalFault {
            // A prior timeout/failure is terminal by policy. Record the late
            // entry for diagnostics, but never promote the faulted service to
            // ready and do not write a ready marker (the caller must see false).
            snapshot.engineEntryObserved = true
            snapshot.enginePid = pid
            snapshot.engineTestMethod = testMethod
            snapshot.engineInitializedAt = BridgeClock.timestamp()
            snapshot.engineRunning = false
            snapshot.phase = .failed
            snapshot.activity = nil
            snapshot.notes.append("engine entry during terminal-fault pid=\(pid) test=\(testMethod) not-promoted")
            trimNotes()
            touch()
            return false
        }
        snapshot.engineEntryObserved = true
        snapshot.enginePid = pid
        snapshot.engineTestMethod = testMethod
        snapshot.engineInitializedAt = BridgeClock.timestamp()
        if snapshot.serviceRunning {
            snapshot.engineRunning = true
            snapshot.phase = .ready
            snapshot.activity = "engine-ready"
            snapshot.readyAt = BridgeClock.timestamp()
        } else {
            snapshot.engineRunning = false
            if snapshot.phase != .failed {
                snapshot.phase = .stopped
            }
            snapshot.activity = nil
        }
        snapshot.notes.append("engine entry pid=\(pid) serviceRunning=\(snapshot.serviceRunning) test=\(testMethod)")
        trimNotes()
        touch()
        return true
    }

    /// Stop is always accepted when there is a service or preparation to close.
    /// It never waits for, kills, or re-dispatches the irreversible XCTest
    /// initializer.
    @discardableResult
    public mutating func requestEngineStop(reason: String) -> Bool {
        let hadWork = snapshot.serviceRunning || snapshot.phase.isActive ||
            snapshot.engineRunning || snapshot.oneShotDispatched
        guard hadWork else { return false }
        let faulted = snapshot.terminalFault
        snapshot.generation &+= 1
        snapshot.serviceRunning = false
        snapshot.engineRunning = false
        // Stop fences a live/starting service but never clears a terminal fault.
        snapshot.phase = faulted ? .failed : .stopped
        snapshot.activity = nil
        snapshot.stoppedAt = BridgeClock.timestamp()
        snapshot.notes.append(
            "stop reason=\(reason) generation=\(snapshot.generation) " +
            "driverEntry=\(snapshot.engineEntryObserved) terminalFault=\(faulted)"
        )
        trimNotes()
        touch()
        return true
    }

    @discardableResult
    public mutating func requestEngineResume() -> BridgeResumeDecision {
        if snapshot.terminalFault {
            return .reopenRequired(code: snapshot.terminalFaultCode ?? "terminal-fault")
        }
        guard snapshot.engineEntryObserved,
              snapshot.oneShotDispatched,
              snapshot.enginePid == snapshot.hostPid,
              !snapshot.engineRunning else {
            return .unavailable
        }
        snapshot.generation &+= 1
        snapshot.serviceRunning = true
        snapshot.engineRunning = true
        snapshot.phase = .ready
        snapshot.activity = "engine-resumed"
        snapshot.stoppedAt = nil
        snapshot.lastError = nil
        snapshot.errorCode = nil
        snapshot.notes.append("engine resume generation=\(snapshot.generation)")
        trimNotes()
        touch()
        return .resumed
    }

    /// Re-enables the service while the one-shot initializer is still in
    /// flight. No new bootstrap is dispatched. A terminal fault is never
    /// re-armed into another indefinite wait.
    public mutating func reenableServiceForPendingBootstrap(reason: String) -> UInt64? {
        guard !snapshot.terminalFault,
              snapshot.oneShotDispatched,
              !snapshot.engineEntryObserved else { return nil }
        snapshot.generation &+= 1
        snapshot.serviceRunning = true
        snapshot.phase = .waitingForEngine
        snapshot.activity = "waiting-engine"
        snapshot.stoppedAt = nil
        snapshot.lastError = nil
        snapshot.errorCode = nil
        snapshot.notes.append("service re-enabled for pending bootstrap reason=\(reason) generation=\(snapshot.generation)")
        trimNotes()
        touch()
        return snapshot.generation
    }

    public mutating func setTunnel(_ phase: BridgeTunnelPhase, detail: String?) {
        snapshot.tunnel = phase
        snapshot.tunnelDetail = detail
        touch()
    }

    public mutating func setTunnelProbe(_ value: String) {
        snapshot.tunnelProbe = value
        touch()
    }

    /// Updates the observed DDI state. It deliberately never manufactures a
    /// mount timestamp: repeated observations and a preexisting mount keep the
    /// prior verified-install time (or none).
    public mutating func setDDI(_ phase: BridgeDDIPhase,
                                layout: String? = nil,
                                source: String? = nil,
                                detail: String? = nil) {
        snapshot.ddi = phase
        snapshot.ddiLayout = layout
        snapshot.ddiSource = source
        snapshot.ddiDetail = detail
        touch()
    }

    /// Records one timestamped pre-start probe observation, including a
    /// not-mounted result, so a later readback can prove the pre-mount state.
    public mutating func recordDDIProbe(mounted: Bool,
                                        layout: String?,
                                        path: String?,
                                        source: String?,
                                        detail: String?) {
        let observedAt = BridgeClock.timestamp()
        snapshot.lastDDIProbeAt = observedAt
        snapshot.lastDDIProbeMounted = mounted
        snapshot.lastDDIProbeLayout = layout
        snapshot.lastDDIProbePath = path
        snapshot.lastDDIProbeSource = source
        snapshot.ddiDetail = detail
        snapshot.notes.append(
            "ddi probe mounted=\(mounted) layout=\(layout ?? "none") " +
            "path=\(path ?? "none") source=\(source ?? "none") at=\(observedAt)"
        )
        trimNotes()
        touch()
    }

    /// Explicit provenance event for an install performed by this app and then
    /// verified readable. This is the only path that sets the mount time.
    public mutating func recordVerifiedOnDeviceMount(layout: String?, path: String?) {
        snapshot.lastOnDeviceMountAt = BridgeClock.timestamp()
        snapshot.lastOnDeviceMountLayout = layout
        snapshot.lastOnDeviceMountPath = path
        snapshot.notes.append(
            "verified on-device mount layout=\(layout ?? "unknown") path=\(path ?? "unknown")"
        )
        trimNotes()
        touch()
    }

    public mutating func setPairing(imported: Bool) {
        snapshot.pairingImported = imported
        touch()
    }

    /// Reconciles observed preparation facts without advancing readiness or
    /// rewriting state when nothing changed. Returns true only on a real
    /// change, so callers may poll every tick without touching status.json.
    @discardableResult
    public mutating func applyPreparationFacts(_ facts: BridgePreparationFacts) -> Bool {
        var changed = false
        if snapshot.pairingImported != facts.pairingImported {
            snapshot.pairingImported = facts.pairingImported
            changed = true
        }
        if snapshot.ddi != facts.ddi {
            snapshot.ddi = facts.ddi
            changed = true
        }
        if snapshot.ddiLayout != facts.ddiLayout {
            snapshot.ddiLayout = facts.ddiLayout
            changed = true
        }
        if snapshot.ddiSource != facts.ddiSource {
            snapshot.ddiSource = facts.ddiSource
            changed = true
        }
        if snapshot.ddiDetail != facts.ddiDetail {
            snapshot.ddiDetail = facts.ddiDetail
            changed = true
        }
        if changed { touch() }
        return changed
    }

    public mutating func note(_ message: String) {
        snapshot.notes.append(message)
        trimNotes()
        touch()
    }

    private mutating func trimNotes() {
        if snapshot.notes.count > 40 {
            snapshot.notes.removeFirst(snapshot.notes.count - 40)
        }
    }

    private mutating func touch() {
        snapshot.updatedAt = BridgeClock.timestamp()
    }
}
