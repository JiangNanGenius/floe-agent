import Foundation

final class CanaryHeartbeat {
    private let files: TestFiles
    private let testMethod: String
    private let startedAt = Date()
    private let queue = DispatchQueue(label: "org.floeagent.iosbridge.canary.heartbeat")
    private let stateLock = NSLock()
    private var timer: DispatchSourceTimer?
    private var count = 0
    private var lastTick: Date?
    private var lastUptime: TimeInterval = 0
    private var running = false

    init(files: TestFiles, testMethod: String) {
        self.files = files
        self.testMethod = testMethod
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.timer == nil else { return }
            self.stateLock.lock()
            self.running = true
            self.stateLock.unlock()

            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: 2.0, leeway: .milliseconds(200))
            timer.setEventHandler { [weak self] in
                self?.tick()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.timer?.cancel()
            self.timer = nil
            self.stateLock.lock()
            self.running = false
            self.stateLock.unlock()
        }
    }

    private func tick() {
        let now = Date()
        let uptime = ProcessInfo.processInfo.systemUptime
        stateLock.lock()
        count += 1
        let currentCount = count
        lastTick = now
        lastUptime = uptime
        stateLock.unlock()

        let payload: [String: Any] = [
            "heartbeatCount": currentCount,
            "startedAt": files.timestamp(startedAt),
            "lastHeartbeatAt": files.timestamp(now),
            "systemUptime": uptime,
            "processIdentifier": ProcessInfo.processInfo.processIdentifier,
            "testMethod": testMethod,
            "source": "XCTest test method dispatch timer",
            "queue": "org.floeagent.iosbridge.canary.heartbeat",
        ]
        files.writeJSON(payload, to: files.heartbeatURL)
        files.appendHeartbeatLine(
            "\(files.timestamp(now))\tuptime=\(String(format: "%.3f", uptime))\tcount=\(currentCount)\tpid=\(ProcessInfo.processInfo.processIdentifier)"
        )
    }

    func snapshot() -> [String: Any] {
        stateLock.lock()
        let currentCount = count
        let currentLastTick = lastTick
        let currentUptime = lastUptime
        let isRunning = running
        stateLock.unlock()

        var snapshot: [String: Any] = [
            "heartbeatCount": currentCount,
            "startedAt": files.timestamp(startedAt),
            "systemUptime": currentUptime,
            "testMethod": testMethod,
            "source": "XCTest test method dispatch timer",
            "running": isRunning,
        ]
        if let currentLastTick {
            snapshot["lastHeartbeatAt"] = files.timestamp(currentLastTick)
        }
        return snapshot
    }
}
