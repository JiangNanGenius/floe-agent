// SPDX-License-Identifier: MPL-2.0

#if FLOE_MAC_HOST_SMOKE
import AppKit
import CryptoKit
import Darwin
import FloeMacBridgeProtocol
import Foundation

@MainActor
final class UnifiedMacSmoke {
    static let flag = "--unified-smoke-report"
    let root: URL
    let report: URL
    let serverKey = Curve25519.Signing.PrivateKey()
    private let clientKey = Curve25519.Signing.PrivateKey()

    static func configured() -> UnifiedMacSmoke? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: flag) else { return nil }
        guard index + 1 < args.count, args[index + 1].hasPrefix("/"),
              let smoke = try? UnifiedMacSmoke(report: URL(fileURLWithPath: args[index + 1])) else {
            exit(2)
        }
        return smoke
    }

    private init(report: URL) throws {
        self.report = report
        guard let physicalTemp = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw BridgeFailure.unsafePath
        }
        defer { free(physicalTemp) }
        let prefix = String(cString: physicalTemp) + "/floe-unified-smoke.XXXXXX"
        var name = Array(prefix.utf8CString)
        guard let root = name.withUnsafeMutableBufferPointer({ bytes in
            mkdtemp(bytes.baseAddress).map { URL(fileURLWithPath: String(cString: $0), isDirectory: true) }
        }) else {
            throw BridgeFailure.unsafePath
        }
        self.root = root
    }

    func seedLegacyState() throws -> BridgePaths {
        let paths = try BridgePaths(home: root)
        let key = clientKey.publicKey.rawRepresentation
        let pair = BridgeService.Pair(key: key, name: "Previously paired fixture",
                                      acceptedAt: Date(), verification: nil, nonce: nil)
        let encoded = try BridgeWire.encode([BridgeWire.digest(key): pair])
        let file = paths.root.appendingPathComponent("State/paired-clients.json")
        try encoded.write(to: file, options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        return paths
    }

    func exercise(model: BridgeAppModel) async {
        let deadline = ContinuousClock.now + .seconds(8)
        while !model.listenerReady && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        var pairedRequest = false
        if let port = model.smokePort {
            let path = model.paths?.root.appendingPathComponent("State/paired-clients.json")
            let before = path.flatMap { try? Data(contentsOf: $0) }
            pairedRequest = (try? await callPairedBridge(port: port)) == true
                && before != nil && before == path.flatMap { try? Data(contentsOf: $0) }
        }
        let switchedToAgent = await exerciseBridgeSwitch(model: model)
        let workbenchVisible = NSApp.windows.contains {
            $0.isVisible && $0.title == String(localized: "host.role.agent")
        }
        let modeRoundTrip = await exerciseModeRoundTrip(model: model)
        var nativeChat = false
        var storedTaskRun = false
        var taskMetadataSaved = false
        if let agent = model.macWorkspace.agent {
            await agent.prepare()
            // The visible SwiftUI view may already own preparation.
            let prepareDeadline = ContinuousClock.now + .seconds(8)
            while (agent.isPreparing || model.updates.installation.activity.activityCount != 0)
                    && ContinuousClock.now < prepareDeadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if let view = NSApp.windows.first(where: {
                $0.isVisible && $0.title == String(localized: "host.role.agent")
            })?.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: bitmap)
                try? bitmap.representation(using: .png, properties: [:])?.write(to: report.appendingPathExtension("png"))
            }
            nativeChat = await agent.verifyChatSmoke { model.verifyActiveAgentDefersInstall() }
            await agent.loadTaskRuns()
            let historyDeadline = ContinuousClock.now + .seconds(3)
            if let id = agent.selectedID {
                while agent.recentTaskRuns[id] == nil && ContinuousClock.now < historyDeadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                storedTaskRun = agent.recentTaskRuns[id]?.conversationID == id
                let renamed = await agent.changeConversationMetadata(id: id, change: .rename("Fixture desktop task"))
                let pinned = await agent.changeConversationMetadata(id: id, change: .pin(true))
                let saved = agent.conversations.first { $0.id == id }
                taskMetadataSaved = renamed && pinned && saved?.title == "Fixture desktop task" && saved?.isPinned == true
            }
            if agent.beginTermination() { try? await agent.finishTermination() }
        }
        let toolbox = await exerciseToolbox(model: model)
        let output: [String: Any] = [
            "sameProcessBridgeReady": model.listenerReady,
            "legacyPairAndSignatureVerified": pairedRequest,
            "switchedToAgentFromBridge": switchedToAgent,
            "workbenchWindowVisible": workbenchVisible,
            "modeRoundTripVerified": modeRoundTrip,
            "nativeChatAndUpdateAdmissionVerified": nativeChat,
            "storedTaskRunFound": storedTaskRun,
            "taskMetadataSaved": taskMetadataSaved,
            "toolboxAndLoopbackVerified": toolbox,
            "activityBeforeQuit": model.updates.installation.activity.activityCount,
            "pid": getpid()
        ]
        if let bytes = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: report, options: .atomic)
        }
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    private func exerciseBridgeSwitch(model: BridgeAppModel) async -> Bool {
        guard model.macWorkspace.agent == nil else { return false }
        model.openSettings()
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let bridge = NSApp.windows.first(where: { $0.title == "Floe Bridge" && $0.isVisible }),
               let content = bridge.contentView,
               let frame = model.smokeSwitchFrame, !frame.isEmpty {
                let point = NSPoint(x: frame.midX, y: content.isFlipped ? frame.midY : content.bounds.height - frame.midY)
                let location = content.convert(point, to: nil)
                for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
                    guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                         timestamp: ProcessInfo.processInfo.systemUptime,
                                                         windowNumber: bridge.windowNumber, context: nil,
                                                         eventNumber: 0, clickCount: 1, pressure: 1) else { return false }
                    NSApp.postEvent(event, atStart: false)
                }
                while model.macWorkspace.agent == nil && ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                return model.macWorkspace.agent != nil
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }

    private func exerciseToolbox(model: BridgeAppModel) async -> Bool {
        let workspace = model.macWorkspace
        workspace.openToolbox(toolID: "ping")
        guard let first = workspace.toolbox, first.window?.isVisible == true else { return false }
        let command = first.services.networkOwner
        let started = command.start(.ping("127.0.0.1"), locale: Locale(identifier: "en"))
        let completed = await command.drain(timeout: 9)
        let pingPassed = started && completed && command.result?.contains("4 packets received") == true
        guard await workspace.closeToolbox() else { return false }
        workspace.openToolbox()
        let reopened = workspace.toolbox
        let distinctOwner = reopened?.window?.isVisible == true
            && reopened?.services.mediaEnvironment !== first.services.mediaEnvironment
        let closed = await workspace.closeToolbox()
        return pingPassed && distinctOwner && closed
    }

    private func exerciseModeRoundTrip(model: BridgeAppModel) async -> Bool {
        guard let initialAgent = model.macWorkspace.agent, NSApp.activationPolicy() == .regular else { return false }
        model.switchToBridge()
        let deadline = ContinuousClock.now + .seconds(3)
        while !NSApp.windows.contains(where: { $0.title == "Floe Bridge" && $0.isVisible }),
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard NSApp.activationPolicy() == .accessory,
              NSApp.windows.contains(where: { $0.title == "Floe Bridge" && $0.isVisible }) else { return false }
        model.reopenPreferredWindow()
        guard model.macWorkspace.agent === initialAgent else { return false }
        model.openAgentWorkspace()
        return NSApp.activationPolicy() == .regular && model.macWorkspace.agent === initialAgent
            && NSApp.windows.contains { $0.isVisible && $0.title == String(localized: "host.role.agent") }
    }

    private func callPairedBridge(port: UInt16) async throws -> Bool {
        let body = BridgeRequestBody(clientKey: clientKey.publicKey.rawRepresentation,
                                     method: "storage", payload: [:])
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/rpc")!, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try BridgeWire.encode(BridgeRequest(body: body, key: clientKey))
        let (bytes, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return false }
        let signed = try BridgeWire.decode(BridgeResponse.self, from: bytes)
        _ = try signed.verified(for: body, pinnedKey: serverKey.publicKey.rawRepresentation)
        return true
    }
}
#endif
