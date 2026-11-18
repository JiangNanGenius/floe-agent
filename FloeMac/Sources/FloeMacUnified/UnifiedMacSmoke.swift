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
        model.macWorkspace.openAgent()
        var nativeChat = false
        if let agent = model.macWorkspace.agent {
            await agent.prepare()
            // The visible SwiftUI view may already own preparation.
            let prepareDeadline = ContinuousClock.now + .seconds(8)
            while (agent.isPreparing || model.updates.installation.activity.activityCount != 0)
                    && ContinuousClock.now < prepareDeadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            nativeChat = await agent.verifyChatSmoke { model.verifyActiveAgentDefersInstall() }
            if agent.beginTermination() { try? await agent.finishTermination() }
        }
        let toolbox = await exerciseToolbox(model: model)
        let output: [String: Any] = [
            "sameProcessBridgeReady": model.listenerReady,
            "legacyPairAndSignatureVerified": pairedRequest,
            "nativeChatAndUpdateAdmissionVerified": nativeChat,
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

    private func exerciseToolbox(model: BridgeAppModel) async -> Bool {
        let workspace = model.macWorkspace
        workspace.openToolbox()
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
