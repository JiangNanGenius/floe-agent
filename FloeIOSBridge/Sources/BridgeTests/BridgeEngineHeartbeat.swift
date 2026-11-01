import Foundation
import BridgeCore

/// Heartbeat owned by the XCTest test method. A host-only heartbeat is not
/// engine evidence, so this timer lives here and is only running while the
/// engine accepts work.
final class BridgeEngineHeartbeat: @unchecked Sendable {
    private let files: BridgeTestFiles
    private let testMethod: String
    private let queue = DispatchQueue(label: "org.floeagent.iosbridge.engine.heartbeat")
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var count: UInt64 = 0
    private var startedAt = Date()
    private var lastTick: Date?
    private var running = false

    init(files: BridgeTestFiles, testMethod: String) {
        self.files = files
        self.testMethod = testMethod
    }

    func ensureRunning() {
        lock.lock()
        let needsStart = !running
        if needsStart {
            running = true
            startedAt = Date()
        }
        lock.unlock()
        guard needsStart else { return }

        queue.async { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let already = self.timer != nil
            self.lock.unlock()
            guard !already else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 2.0, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.lock.lock()
            self.timer = timer
            self.lock.unlock()
            timer.resume()
        }
    }

    func stop() {
        lock.lock()
        running = false
        let timer = self.timer
        self.timer = nil
        lock.unlock()
        timer?.cancel()
    }

    private func tick() {
        lock.lock()
        guard running else {
            lock.unlock()
            return
        }
        count &+= 1
        let currentCount = count
        let currentStartedAt = startedAt
        lastTick = Date()
        lock.unlock()

        let payload: [String: Any] = [
            "heartbeatCount": currentCount,
            "startedAt": BridgeClock.timestamp(currentStartedAt),
            "lastHeartbeatAt": BridgeClock.timestamp(),
            "systemUptime": ProcessInfo.processInfo.systemUptime,
            "processIdentifier": ProcessInfo.processInfo.processIdentifier,
            "testMethod": testMethod,
            "source": "BridgeCore test engine dispatch timer",
            "queue": "org.floeagent.iosbridge.engine.heartbeat",
        ]
        BridgeAtomicFile.writeJSON(payload, to: BridgePaths.engineHeartbeatFile)
        files.appendHeartbeatLine(
            "\(BridgeClock.timestamp())\tuptime=\(String(format: "%.3f", ProcessInfo.processInfo.systemUptime))\tcount=\(currentCount)\tpid=\(ProcessInfo.processInfo.processIdentifier)"
        )
    }

    func snapshot() -> [String: Any] {
        lock.lock()
        let currentCount = count
        let currentStartedAt = startedAt
        let currentLastTick = lastTick
        let isRunning = running
        lock.unlock()
        var value: [String: Any] = [
            "heartbeatCount": currentCount,
            "startedAt": BridgeClock.timestamp(currentStartedAt),
            "systemUptime": ProcessInfo.processInfo.systemUptime,
            "testMethod": testMethod,
            "running": isRunning,
            "source": "BridgeCore test engine dispatch timer",
        ]
        if let currentLastTick { value["lastHeartbeatAt"] = BridgeClock.timestamp(currentLastTick) }
        return value
    }
}
