import Foundation
import Dispatch
import Darwin

// Focused scheduling-primitive probe for the BridgeHost / embedded-XCTest
// single-process design. This is deliberately NOT an XCTest-validity test and
// not a substitute for the real DDI/SDK/UI run. It measures only whether main
// queue / MainActor work can progress while a long-lived main-thread driver
// loop is running.
//
// Run one scenario per process:
//   scheduling-probe gcd-nested-runloop
//   scheduling-probe runloop-nested-runloop
//   scheduling-probe runloop-cooperative
//
// Exit status 0 means the scenario produced the expected primitive behavior;
// exit status 2 means the measurement did not match (details in JSON).

private let scenarioArgument = CommandLine.arguments.dropFirst().first ?? "gcd-nested-runloop"
private let measurementSeconds = 2.0
private let reportPath = CommandLine.arguments.dropFirst(2).first

/// Lock-protected primitive counters. The main queue, a main-runloop timer, a
/// background heartbeat and a watchdog all touch this; it is intentionally not
/// actor-isolated so the probe cannot silently hide a starved executor.
final class ProbeCounters: @unchecked Sendable {
    static let shared = ProbeCounters()

    private let lock = NSLock()
    private var integers: [String: Int] = [:]
    private var booleans: [String: Bool] = [:]

    func set(_ key: String, _ value: Int) {
        lock.lock()
        integers[key] = value
        lock.unlock()
    }

    func increment(_ key: String) {
        lock.lock()
        integers[key, default: 0] += 1
        lock.unlock()
    }

    func setFlag(_ key: String, _ value: Bool) {
        lock.lock()
        booleans[key] = value
        lock.unlock()
    }

    func integer(_ key: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return integers[key] ?? 0
    }

    func flag(_ key: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return booleans[key] ?? false
    }
}

/// Mirrors BridgeAppModel's actual timer shape: a main-runloop Timer whose
/// callback hops to the MainActor with `Task { @MainActor in ... }`.
@MainActor
final class HostActorProbe {
    static let shared = HostActorProbe()
    private(set) var ticks = 0

    func recordHostTimerTick() {
        ticks += 1
        ProbeCounters.shared.increment("hostActorTaskTicks")
    }
}

enum Driver {
    /// Mimics the real synchronous test method: never returns, keeps the main
    /// thread alive and pumps a nested run loop (UIKit/Foundation events work).
    static func runNestedForever() {
        ProbeCounters.shared.setFlag("driverEntered", true)
        ProbeCounters.shared.setFlag("driverThreadIsMain", Thread.isMainThread)
        var iterations = 0
        while true {
            iterations += 1
            ProbeCounters.shared.set("driverIterations", iterations)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }

    /// Mimics the current test class shape more closely: the synchronous
    /// nested-run-loop driver is itself MainActor-isolated.
    @MainActor
    static func runIsolatedNestedForever() {
        ProbeCounters.shared.setFlag("driverEntered", true)
        ProbeCounters.shared.setFlag("driverThreadIsMain", pthread_main_np() != 0)
        var iterations = 0
        while true {
            iterations += 1
            ProbeCounters.shared.set("driverIterations", iterations)
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }

    /// Mimics the cooperative replacement: a long-lived MainActor task that
    /// suspends between bounded sleeps so queued MainActor work can run.
    @MainActor
    static func runCooperativeForever() async {
        ProbeCounters.shared.setFlag("driverEntered", true)
        ProbeCounters.shared.setFlag("driverThreadIsMain", pthread_main_np() != 0)
        var iterations = 0
        while true {
            iterations += 1
            ProbeCounters.shared.set("driverIterations", iterations)
            try? await Task.sleep(for: .milliseconds(50))
        }
    }
}

private func installHostPatternPrimitives() {
    // Exactly the BridgeAppModel/BridgeHostCommandPoller pattern.
    let timer = Timer(timeInterval: 0.05, repeats: true) { _ in
        Task { @MainActor in HostActorProbe.shared.recordHostTimerTick() }
    }
    RunLoop.main.add(timer, forMode: .common)

    // Direct run-loop timer: proves the nested run loop itself is pumping even
    // when the main queue is unavailable.
    let runLoopTimer = Timer(timeInterval: 0.05, repeats: true) { _ in
        ProbeCounters.shared.increment("runLoopTimerTicks")
    }
    RunLoop.main.add(runLoopTimer, forMode: .common)

    // Main dispatch queue liveness: a queued block that reschedules itself.
    scheduleMainQueueBlock()
}

private func scheduleMainQueueBlock() {
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        ProbeCounters.shared.increment("mainQueueBlocks")
        scheduleMainQueueBlock()
    }
}

private func startHeartbeat() {
    // Mirrors BridgeEngineHeartbeat: a private-queue DispatchSourceTimer proves
    // the process and a non-main executor stay alive in every scenario.
    let queue = DispatchQueue(label: "org.floeagent.iosbridge.probe.heartbeat")
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now(), repeating: 0.05, leeway: .milliseconds(5))
    timer.setEventHandler {
        ProbeCounters.shared.increment("heartbeatTicks")
    }
    timer.resume()
    // Keep it alive for the process lifetime.
    probeRetainedHeartbeat = timer
}

// The probe intentionally keeps this reference for the process lifetime; the
// timer source is itself retained by dispatch once resumed.
nonisolated(unsafe) private var probeRetainedHeartbeat: DispatchSourceTimer?

private func startWatchdog() {
    DispatchQueue.global().async {
        let entryDeadline = Date().addingTimeInterval(3.0)
        while !ProbeCounters.shared.flag("driverEntered"), Date() < entryDeadline {
            usleep(10_000)
        }
        let measurementDeadline = Date().addingTimeInterval(measurementSeconds)
        while Date() < measurementDeadline {
            usleep(20_000)
        }

        let counters = ProbeCounters.shared
        let metrics: [String: Int] = [
            "driverIterations": counters.integer("driverIterations"),
            "hostActorTaskTicks": counters.integer("hostActorTaskTicks"),
            "mainQueueBlocks": counters.integer("mainQueueBlocks"),
            "runLoopTimerTicks": counters.integer("runLoopTimerTicks"),
            "heartbeatTicks": counters.integer("heartbeatTicks"),
        ]
        let flags: [String: Bool] = [
            "driverEntered": counters.flag("driverEntered"),
            "driverThreadIsMain": counters.flag("driverThreadIsMain"),
        ]

        let progress = metrics["hostActorTaskTicks"]! > 2 && metrics["mainQueueBlocks"]! > 2
        let primitivesPumping = metrics["runLoopTimerTicks"]! > 2 && metrics["heartbeatTicks"]! > 2
        let driverAlive = flags["driverEntered"]! && flags["driverThreadIsMain"]! &&
            metrics["driverIterations"]! > 2

        let verdict: String
        let expected: String
        switch scenarioArgument {
        case "gcd-nested-runloop":
            // The defect: nested run-loop timers keep firing, but the serial
            // main queue is held by the never-returning work item, so neither
            // the MainActor Task nor the queued main block runs.
            expected = "starved"
            verdict = (driverAlive && primitivesPumping && !progress) ? "reproduced-defect" : "unexpected"
        case "runloop-nested-runloop", "runloop-isolated-nested-runloop", "runloop-cooperative":
            expected = "progress"
            verdict = (driverAlive && primitivesPumping && progress) ? "progress-observed" : "unexpected"
        default:
            expected = "unknown"
            verdict = "unknown-scenario"
        }

        var report: [String: Any] = [
            "scenario": scenarioArgument,
            "expected": expected,
            "verdict": verdict,
            "measurementSeconds": measurementSeconds,
            "metrics": metrics,
            "flags": flags,
            "swiftVersion": ProcessInfo.processInfo.environment["SWIFT_VERSION_TEXT"] ?? "unknown",
            "osVersion": ProcessInfo.processInfo.operatingSystemVersionString,
            "pid": ProcessInfo.processInfo.processIdentifier,
            "authoredBy": "RuntimeScheduling primitive probe (not XCTest validity evidence)",
        ]
        if let reportPath, !reportPath.isEmpty {
            report["reportPath"] = reportPath
        }

        let data = (try? JSONSerialization.data(withJSONObject: report,
                                                options: [.prettyPrinted, .sortedKeys])) ?? Data()
        if let reportPath, !reportPath.isEmpty {
            try? data.write(to: URL(fileURLWithPath: reportPath), options: .atomic)
        }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        exit(verdict == "reproduced-defect" || verdict == "progress-observed" ? 0 : 2)
    }
}

private func startDriver() {
    switch scenarioArgument {
    case "gcd-nested-runloop":
        // Current production shape: a never-returning XCTest driver is invoked
        // from a main-queue work item, which keeps the serial queue busy.
        DispatchQueue.main.async {
            Driver.runNestedForever()
        }
    case "runloop-nested-runloop":
        // Candidate production shape: the same synchronous driver is entered
        // from a main CFRunLoop block, outside the main dispatch queue.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            Driver.runNestedForever()
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    case "runloop-isolated-nested-runloop":
        // Variant: the synchronous driver is MainActor-isolated, as the
        // current test class is. XCTest enters a synchronous test on the main
        // thread; assumeIsolated models that direct call.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            MainActor.assumeIsolated {
                Driver.runIsolatedNestedForever()
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    case "runloop-cooperative":
        // Candidate production shape: the long-lived test method is an async
        // MainActor task that awaits between bounded iterations.
        CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
            Task { @MainActor in
                await Driver.runCooperativeForever()
            }
        }
        CFRunLoopWakeUp(CFRunLoopGetMain())
    default:
        fputs("unknown scenario: \(scenarioArgument)\n", stderr)
        exit(64)
    }
}

// Keep the compiler from warning that these are only used from setup.
@inline(never)
private func keepAlive() {
    _ = scenarioArgument
}

startDriver()
installHostPatternPrimitives()
startHeartbeat()
startWatchdog()
keepAlive()
CFRunLoopRun()
