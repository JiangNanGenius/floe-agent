import Foundation
import UIKit

final class CanaryCoordinator {
    static let shared = CanaryCoordinator()

    enum Phase: String {
        case idle
        case starting
        case bootstrapDispatched = "bootstrap-dispatched"
        case bootstrapFailed = "bootstrap-failed"
    }

    private let queue = DispatchQueue(label: "org.floeagent.iosbridge.canary.coordinator")
    private weak var viewController: CanaryViewController?
    private var pollTimer: DispatchSourceTimer?
    private var phase: Phase = .idle
    private var startAttempted = false
    private var didBootstrap = false
    private var lastHostCommandID: String?
    private var ddiInfo: [String: Any] = [:]
    private var ddiSelected = "<not probed>"
    private var testInfo: [String: Any] = [:]

    private init() {}

    func attach(viewController: CanaryViewController) {
        self.viewController = viewController
        render()
    }

    func bootstrapOnLaunch() {
        queue.async { [weak self] in
            guard let self else { return }
            guard !self.didBootstrap else {
                CanaryFiles.appendLog("host_bootstrap_skipped already_started")
                return
            }
            self.didBootstrap = true
            CanaryFiles.prepare()
            CanaryFiles.appendLog(
                "host_launch pid=\(ProcessInfo.processInfo.processIdentifier) " +
                "bundle=\(Bundle.main.bundleIdentifier ?? "<missing>")"
            )
            self.refreshEnvironmentFacts()
            self.writeHostStatus()
            self.render()
            self.startCommandPolling()
        }
    }

    func requestStartFromUI() {
        queue.async { [weak self] in
            self?.performStart(trigger: "ui")
        }
    }

    private func refreshEnvironmentFacts() {
        ddiInfo = FBCProbeDDI(CanaryFiles.logURL.path)
        if let selected = ddiInfo["selected"] as? String {
            ddiSelected = selected
        } else {
            ddiSelected = "<none>"
        }
        testInfo = CanaryFiles.testBundleInfo()
    }

    private func startCommandPolling() {
        guard pollTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in
            self?.pollCommand()
        }
        pollTimer = timer
        timer.resume()
        CanaryFiles.appendLog("host_command_poll_started interval=0.5s")
    }

    private func stopCommandPolling() {
        pollTimer?.cancel()
        pollTimer = nil
    }

    private func pollCommand() {
        guard !startAttempted, phase == .idle else {
            stopCommandPolling()
            return
        }
        guard let command = CanaryFiles.readJSON(CanaryFiles.commandURL),
              let identifier = command["id"] as? String,
              let action = command["action"] as? String else {
            return
        }
        let safeIdentifier = CanaryFiles.safeIdentifier(identifier)
        guard lastHostCommandID != identifier else { return }
        lastHostCommandID = identifier

        let processedURL = CanaryFiles.processedURL
            .appendingPathComponent("host-command-\(safeIdentifier)-\(Int(Date().timeIntervalSince1970)).json")
        try? FileManager.default.moveItem(at: CanaryFiles.commandURL, to: processedURL)

        if action == "start" {
            performStart(trigger: "command:\(identifier)")
            return
        }

        let result: [String: Any] = [
            "id": identifier,
            "action": action,
            "status": action == "status" ? "ok" : "engine_not_started",
            "authoredBy": "host-coordinator",
            "processedAt": CanaryFiles.timestamp(),
            "phase": phase.rawValue,
            "ddiSelected": ddiSelected,
            "testBundle": testInfo,
            "hint": "The test engine is not running. Use an explicit start command or the Start button.",
        ]
        CanaryFiles.writeJSON(result, to: CanaryFiles.baseURL.appendingPathComponent("host-result-\(safeIdentifier).json"))
        CanaryFiles.appendLog("host_command action=\(action) id=\(identifier) status=engine_not_started")
    }

    private func performStart(trigger: String) {
        guard !startAttempted else { return }
        startAttempted = true
        phase = .starting
        CanaryFiles.appendLog("start_requested trigger=\(trigger) pid=\(ProcessInfo.processInfo.processIdentifier)")

        let request: [String: Any] = [
            "id": "start-\(Int(Date().timeIntervalSince1970))",
            "trigger": trigger,
            "requestedAt": CanaryFiles.timestamp(),
            "build": CanaryFiles.buildInfo(),
            "ddiSelected": ddiSelected,
            "testBundle": testInfo,
        ]
        CanaryFiles.writeJSON(request, to: CanaryFiles.startRequestURL)
        writeHostStatus()
        render()

        let xctestPath = Bundle.main.bundlePath + "/PlugIns/BootstrapCanaryUITests.xctest"
        let result = FBCStartBootstrap(xctestPath, CanaryFiles.logURL.path)
        let errorMessage = FBCLastBootstrapError()

        if result.rawValue == 0 {
            phase = .bootstrapDispatched
            CanaryFiles.appendLog("start_dispatched trigger=\(trigger) result=\(result.rawValue)")
        } else {
            phase = .bootstrapFailed
            CanaryFiles.appendLog(
                "start_failed trigger=\(trigger) result=\(result.rawValue) error=\(errorMessage ?? "<none>")"
            )
        }

        stopCommandPolling()
        writeHostStatus()
        render()
    }

    private func writeHostStatus() {
        let engineReady = CanaryFiles.readJSON(CanaryFiles.engineReadyURL)
        let heartbeat = CanaryFiles.readJSON(CanaryFiles.heartbeatURL)

        var status: [String: Any] = [
            "phase": phase.rawValue,
            "generatedAt": CanaryFiles.timestamp(),
            "startAttempted": startAttempted,
            "lastBootstrapError": FBCLastBootstrapError() ?? "",
            "build": CanaryFiles.buildInfo(),
            "ddi": ddiInfo,
            "ddiSelected": ddiSelected,
            "testBundle": testInfo,
            "paths": [
                "base": CanaryFiles.baseURL.path,
                "bootstrapLog": CanaryFiles.logURL.path,
                "command": CanaryFiles.commandURL.path,
                "engineReady": CanaryFiles.engineReadyURL.path,
                "heartbeat": CanaryFiles.heartbeatURL.path,
            ],
        ]
        if let engineReady {
            status["engineReady"] = engineReady
        }
        if let heartbeat {
            status["heartbeat"] = heartbeat
        }
        CanaryFiles.writeJSON(status, to: CanaryFiles.hostStatusURL)
    }

    private func render() {
        let phase = self.phase
        let detail = """
        DDI: \(ddiSelected)
        Test bundle: \(testInfo["exists"] as? Bool == true ? "present" : "missing")
        Files: Documents/canary/
        Log: bootstrap.log / engine-test.log
        """
        DispatchQueue.main.async { [weak self] in
            self?.viewController?.render(phase: phase, detail: detail)
        }
    }
}
