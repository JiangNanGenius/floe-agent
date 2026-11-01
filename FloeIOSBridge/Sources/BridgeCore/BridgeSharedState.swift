import Foundation

/// Process-wide lifecycle authority shared by the ordinary host and the
/// embedded XCTest bundle. Both run in the same process; keeping one instance
/// is what lets Stop fence the engine and Start reuse the initialized driver
/// without a second bootstrap.
public final class BridgeSharedState: @unchecked Sendable {
    public static let shared = BridgeSharedState()

    private let lock = NSLock()
    private var lifecycle: BridgeLifecycle

    public init(hostPid: Int32 = Int32(ProcessInfo.processInfo.processIdentifier)) {
        lifecycle = BridgeLifecycle(hostPid: hostPid)
    }

    public func snapshot() -> BridgeSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return lifecycle.snapshot
    }

    @discardableResult
    public func withLifecycle<T>(_ body: (inout BridgeLifecycle) -> T) -> T {
        lock.lock()
        let result = body(&lifecycle)
        let snapshot = lifecycle.snapshot
        lock.unlock()
        publish(snapshot)
        return result
    }

    public func publishInitialStatus() {
        publish(snapshot())
    }

    /// Applies observed preparation facts and publishes only when one changed.
    /// This never publishes an unchanged status on every UI timer tick.
    @discardableResult
    public func applyPreparationFacts(_ facts: BridgePreparationFacts) -> Bool {
        lock.lock()
        let changed = lifecycle.applyPreparationFacts(facts)
        let snapshot = lifecycle.snapshot
        lock.unlock()
        if changed { publish(snapshot) }
        return changed
    }

    private func publish(_ snapshot: BridgeSnapshot) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(snapshot) else { return }
        do {
            try BridgeAtomicFile.write(data, to: BridgePaths.statusFile)
        } catch {
            BridgeLog.shared.append("status_write_failed error=\(error.localizedDescription)")
        }
    }

    /// Called by the actual test method. The marker file is independent
    /// evidence; the host never writes it on the engine's behalf.
    @discardableResult
    public func markEngineEntry(generation: UInt64,
                                testMethod: String,
                                testBundleIdentifier: String,
                                hostBundleIdentifier: String,
                                containsUITests: Bool,
                                threadIsMain: Bool) -> Bool {
        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        let accepted = withLifecycle {
            $0.noteEngineEntry(
                generation,
                pid: pid,
                testMethod: testMethod,
                hostPid: Int32(ProcessInfo.processInfo.processIdentifier)
            )
        }
        if accepted {
            let current = snapshot()
            let marker: [String: Any] = [
                "ready": true,
                "authoredBy": "BridgeCore test entry",
                "testMethod": testMethod,
                "processIdentifier": pid,
                "hostBundleIdentifier": hostBundleIdentifier,
                "testBundleIdentifier": testBundleIdentifier,
                "bundleIdentifiersMatch": testBundleIdentifier == hostBundleIdentifier,
                "XCTContainsUITests": containsUITests,
                "threadIsMain": threadIsMain,
                "serviceRunningAtEntry": current.serviceRunning,
                "dispatchedGeneration": current.dispatchedGeneration ?? generation,
                "marketingVersion": BridgeBuild.marketingVersion,
                "buildNumber": BridgeBuild.buildNumber,
                "readyAt": BridgeClock.timestamp(),
            ]
            BridgeAtomicFile.writeJSON(marker, to: BridgePaths.engineReadyFile)
            BridgeLog.shared.append("engine_entry_marker_written pid=\(pid) test=\(testMethod)")
        } else {
            BridgeLog.shared.append("engine_entry_rejected reason=stale-or-not-dispatched generation=\(generation) pid=\(pid)")
        }
        return accepted
    }

    public func engineEntryMarker() -> [String: Any]? {
        BridgeAtomicFile.readJSON(BridgePaths.engineReadyFile)
    }

    public func engineAcceptsCommands() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return lifecycle.acceptsEngineCommands
    }

    /// One atomic lifecycle read for the final generic-mutation admission
    /// check. Generation and readiness must describe the same instant; using
    /// separate reads could accept a command with a new generation but a stale
    /// readiness value.
    public func mutationAdmissionState() -> BridgeMutationAdmissionState {
        lock.lock()
        defer { lock.unlock() }
        return BridgeMutationAdmissionState(
            generation: lifecycle.snapshot.generation,
            acceptsEngineCommands: lifecycle.acceptsEngineCommands
        )
    }
}

public struct BridgeMutationAdmissionState: Equatable, Sendable {
    public var generation: UInt64
    public var acceptsEngineCommands: Bool

    public init(generation: UInt64, acceptsEngineCommands: Bool) {
        self.generation = generation
        self.acceptsEngineCommands = acceptsEngineCommands
    }
}
