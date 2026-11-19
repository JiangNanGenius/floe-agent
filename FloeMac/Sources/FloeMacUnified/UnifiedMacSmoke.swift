// SPDX-License-Identifier: MPL-2.0

#if FLOE_MAC_HOST_SMOKE
import AppKit
import CloudKit
import CryptoKit
import Darwin
import FloeCore
import FloeMacBridgeProtocol
import FloeMacToolbox
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
        if CommandLine.arguments.contains("--icloud-model-sync-smoke") {
            await verifyCloudKitModelSync()
            return
        }
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
        let bridgeSwitchUserEvent = await exerciseBridgeSwitch(model: model)
        // The first leg uses a real button event. Other desktop windows can
        // intercept synthetic events, so also exercise the same handler in
        // the insulated fixture to keep independent task tests runnable.
        if model.macWorkspace.agent == nil { model.openAgentWorkspace() }
        let switchedToAgent = model.macWorkspace.agent != nil
        let workbenchVisible = NSApp.windows.contains {
            $0.isVisible && $0.title == String(localized: "host.role.agent")
        }
        let modeRoundTrip = await exerciseModeRoundTrip(model: model)
        var nativeChat = false
        var storedTaskRun = false
        var taskMetadataSaved = false
        var archivedTaskRestored = false
        var deletedFixtureTask = false
        var workspaceAndAttachmentStaging = false
        var conversationHistoryVerified = false
        var workspaceTextEditsVerified = false
        var catalog = false
        var agentApproval = (allowed: false, denied: false)
        var planning = (planSaved: false, goalSaved: false)
        var pressedApprovalButton = false
        if let agent = model.macWorkspace.agent {
            var normalChatID: UUID?
            await agent.prepare()
            // The visible SwiftUI view may already own preparation.
            let prepareDeadline = ContinuousClock.now + .seconds(8)
            while (agent.isPreparing || model.updates.installation.activity.activityCount != 0)
                    && ContinuousClock.now < prepareDeadline {
                try? await Task.sleep(for: .milliseconds(50))
            }
            workspaceAndAttachmentStaging = await verifyWorkspaceAndAttachmentStaging(agent)
            if let window = NSApp.windows.first(where: {
                $0.isVisible && $0.title == String(localized: "host.role.agent")
            }), let content = window.contentView {
                capture(content, extension: "png")
                // The welcome page has exactly one trailing toolbar action.
                // Press it before sending so the same file pane remains open
                // when the newly created conversation is selected.
                if !pressAccessibilityButton(content, id: "workspace.files.toggle") {
                    let point = NSPoint(x: content.bounds.width - 29, y: content.isFlipped ? 22 : content.bounds.height - 22)
                    _ = click(content, at: point, in: window)
                }
            }
            nativeChat = await agent.verifyChatSmoke { model.verifyActiveAgentDefersInstall() }
            if nativeChat, workspaceAndAttachmentStaging {
                conversationHistoryVerified = await agent.verifyConversationHistorySmoke(
                    reference: root.appendingPathComponent("Fixture Project/fixture.md")
                )
            }
            await agent.loadTaskRuns()
            let historyDeadline = ContinuousClock.now + .seconds(3)
            if let id = agent.selectedID {
                normalChatID = id
                while agent.recentTaskRuns[id] == nil && ContinuousClock.now < historyDeadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                storedTaskRun = agent.recentTaskRuns[id]?.conversationID == id
                let renamed = await agent.changeConversationMetadata(id: id, change: .rename("Fixture desktop task"))
                let pinned = await agent.changeConversationMetadata(id: id, change: .pin(true))
                let saved = agent.conversations.first { $0.id == id }
                taskMetadataSaved = renamed && pinned && saved?.title == "Fixture desktop task" && saved?.isPinned == true
                let archived = await agent.changeConversationMetadata(id: id, change: .archive(true))
                let archivedRow = agent.conversations.first { $0.id == id }
                await agent.loadTaskRuns()
                let archivedRunIsVisible = agent.recentTaskRuns[id]?.conversationID == id
                let restored = await agent.changeConversationMetadata(id: id, change: .archive(false))
                let restoredRow = agent.conversations.first { $0.id == id }
                archivedTaskRestored = archived && archivedRunIsVisible && archivedRow?.archivedAt != nil && restored
                    && restoredRow?.isVisibleInOrdinaryList == true && restoredRow?.isPinned == true
            }
            if let content = NSApp.windows.first(where: {
                $0.isVisible && $0.title == String(localized: "host.role.agent")
            })?.contentView {
                capture(content, extension: "task.png")
            }
            if let project = agent.workspaces.first(where: { $0.name == "Fixture Project" }) {
                let folder = root.appendingPathComponent("Fixture Project", isDirectory: true)
                agentApproval = await agent.verifyAgentApprovalSmoke(project: project, checkingFile: folder) { allow in
                    guard let content = NSApp.windows.first(where: {
                        $0.isVisible && $0.title == String(localized: "host.role.agent")
                    })?.contentView else { return false }
                    capture(content, extension: "approval.png")
                    let pressed = pressAccessibilityButton(content, id: allow ? "mac.agent.allowOnce" : "mac.agent.deny")
                    pressedApprovalButton = pressedApprovalButton || pressed
                    return pressed
                }
                workspaceTextEditsVerified = await agent.verifyAgentTextEditSmoke(project: project, folder: folder)
                planning = await agent.verifyPlanningSmoke(project: project)
            }
            if let normalChatID {
                let removed = await agent.changeConversationMetadata(id: normalChatID, change: .delete)
                deletedFixtureTask = removed && !agent.conversations.contains { $0.id == normalChatID }
            }
            catalog = await verifyProviderCatalog(in: agent)
            if agent.beginTermination() { try? await agent.finishTermination() }
        }
        let toolbox = await exerciseToolbox(model: model)
        let output: [String: Any] = [
            "sameProcessBridgeReady": model.listenerReady,
            "legacyPairAndSignatureVerified": pairedRequest,
            "switchedToAgentFromBridge": switchedToAgent,
            "bridgeSwitchUserEventVerified": bridgeSwitchUserEvent,
            "workbenchWindowVisible": workbenchVisible,
            "modeRoundTripVerified": modeRoundTrip,
            "nativeChatAndUpdateAdmissionVerified": nativeChat,
            "storedTaskRunFound": storedTaskRun,
            "taskMetadataSaved": taskMetadataSaved,
            "archivedTaskRestored": archivedTaskRestored,
            "deletedFixtureTask": deletedFixtureTask,
            "composerDraftsReloaded": verifyDraftStorage(),
            "providerCatalogFetched": catalog,
            "workspaceAndAttachmentStagingVerified": workspaceAndAttachmentStaging,
            "workspaceTextEditsVerified": workspaceTextEditsVerified,
            "conversationHistoryVerified": conversationHistoryVerified,
            "agentApprovedFileCreated": agentApproval.allowed,
            "agentDeclinedFileAbsent": agentApproval.denied,
            "planAcceptedAndReloaded": planning.planSaved,
            "goalRunBoundAndReloaded": planning.goalSaved,
            "workspaceApprovalAXPress": pressedApprovalButton,
            "taskDiagnostics": model.macWorkspace.agent?.smokeRunDiagnostics ?? [],
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

    private func verifyCloudKitModelSync() async {
        var status = "missingEntitlement"
        var removedZone = false
        var verified: [String: Bool] = [:]
        defer {
            let output: [String: Any] = ["status": status, "removedTestZone": removedZone, "checks": verified]
            if let bytes = try? JSONSerialization.data(withJSONObject: output, options: .sortedKeys) {
                try? bytes.write(to: report, options: .atomic)
            }
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        guard MacICloudModelSync.hasCloudKitEntitlement, let namespace = Bundle.main.bundleIdentifier else { return }
        let container = CKContainer(identifier: MacICloudModelSync.containerIdentifier)
        let zoneName = "FloeMacVerification-\(UUID().uuidString)"
        let zoneID = CKRecordZone.ID(zoneName: zoneName, ownerName: CKCurrentUserDefaultName)
        let secondRoot = root.appendingPathComponent("Second Repository", isDirectory: true)
        do {
            guard try await container.accountStatus() == .available else { status = "noSystemICloudAccount"; return }
            let accountID = try await container.userRecordID()
            let firstRuntime = try HostAgentDatabase.open(applicationSupport: root, namespace: namespace)
            _ = try await firstRuntime.bootstrap()
            try FileManager.default.createDirectory(at: secondRoot, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            let secondRuntime = try HostAgentDatabase.open(applicationSupport: secondRoot, namespace: namespace)
            _ = try await secondRuntime.bootstrap()
            _ = try await firstRuntime.shutdown(cancelActive: false)
            _ = try await secondRuntime.shutdown(cancelActive: false)
            let sender = MacICloudModelSync(applicationSupport: root, namespace: namespace, zoneName: zoneName)
            let receiver = MacICloudModelSync(applicationSupport: secondRoot, namespace: namespace, zoneName: zoneName)
            let profile = ProviderProfile(kind: .custom, wireProtocol: .openAIChatCompletions,
                                          baseURL: URL(string: "https://example.invalid/v1")!,
                                          displayName: "Floe Verification")
            let configuredModel = ModelProfile(providerID: profile.id, remoteModelID: "cloud-fixture",
                                               displayName: "Floe Cloud Fixture",
                                               limits: .init(contextTokens: 8192, maxOutputTokens: 256),
                                               capabilities: [.text])
            do {
                let entry = MacCloudModelEntry(provider: profile, model: configuredModel)
                let published = try await sender.synchronize(publishing: entry)
                verified["published"] = published.contains { $0.id == configuredModel.id }
                let downloaded = try await receiver.synchronize()
                verified["downloaded"] = downloaded.count == 1 && downloaded.first?.id == configuredModel.id
                    && downloaded.first?.provider.id == profile.id
                    && downloaded.first?.provider.secretRef == nil
                status = verified.values.allSatisfy { $0 } ? "passed" : "readBackMismatch"
            } catch let error as CKError {
                status = "cloudKit-\(error.code.rawValue)"
            } catch let error as MacICloudModelError {
                status = String(describing: error)
            } catch let error as FloeError {
                status = "floe-\(error.self)"
            } catch {
                let underlying = error as NSError
                status = "synchronizationFailure-\(underlying.domain)-\(underlying.code)"
            }
            guard try await container.userRecordID() == accountID else { status = "accountChanged"; return }
            do {
                _ = try await container.privateCloudDatabase.deleteRecordZone(withID: zoneID)
                removedZone = true
            } catch let error as CKError where error.code == .zoneNotFound {
                removedZone = true
            }
        } catch let error as CKError {
            status = "cloudKit-\(error.code.rawValue)"
        } catch {
            status = "fixtureSetupFailure"
        }
    }

    private func verifyDraftStorage() -> Bool {
        let directory = root.appendingPathComponent("Draft Storage Probe", isDirectory: true)
        let conversation = UUID()
        let first = MacWorkspaceDraftStore(directory: directory)
        first.setText("New task text", for: nil)
        first.setText("Saved task text", for: conversation)
        first.flush()
        let reopened = MacWorkspaceDraftStore(directory: directory)
        let readBack = reopened.text(for: nil) == "New task text"
            && reopened.text(for: conversation) == "Saved task text" && reopened.text(for: UUID()).isEmpty
        reopened.setText("", for: conversation)
        reopened.flush()
        return readBack && !first.saveFailed && !reopened.saveFailed
            && MacWorkspaceDraftStore(directory: directory).text(for: conversation).isEmpty
    }

    private func verifyProviderCatalog(in workspace: HostAgentWorkspace) async -> Bool {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--model-catalog-fixture"), flag < arguments.count - 1,
              let endpoint = URL(string: arguments[flag + 1]), endpoint.scheme == "http",
              endpoint.host == "127.0.0.1", endpoint.port != nil else {
            return false
        }
        defer { workspace.cancelModelDiscovery() }
        workspace.requestModelDiscovery(endpoint: endpoint.absoluteString, protocolKind: .openAIChatCompletions,
                                        apiKey: "superseded-fixture-key", debounce: true)
        workspace.requestModelDiscovery(endpoint: endpoint.absoluteString, protocolKind: .openAIChatCompletions,
                                        apiKey: "floe-catalog-fixture", debounce: true)
        let deadline = ContinuousClock.now + .seconds(6)
        while workspace.modelDiscoveryState == .idle || workspace.modelDiscoveryState == .discovering {
            guard ContinuousClock.now < deadline else { return false }
            try? await Task.sleep(for: .milliseconds(40))
        }
        guard case .succeeded = workspace.modelDiscoveryState,
              Set(workspace.discoveredModels.map(\.remoteModelID)) == ["fixture-model-a", "fixture-model-b"] else {
            return false
        }
        workspace.requestModelDiscovery(endpoint: endpoint.appendingPathComponent("redirect").absoluteString,
                                        protocolKind: .anthropicMessages,
                                        apiKey: "redirect-fixture-key", debounce: false)
        while ContinuousClock.now < deadline {
            switch workspace.modelDiscoveryState {
            case .failed:
                return workspace.discoveredModels.isEmpty
            case .succeeded, .listingUnavailable:
                return false
            case .idle, .discovering:
                try? await Task.sleep(for: .milliseconds(40))
            }
        }
        return false
    }

    private func exerciseBridgeSwitch(model: BridgeAppModel) async -> Bool {
        guard model.macWorkspace.agent == nil else { return false }
        model.openSettings()
        let deadline = ContinuousClock.now + .seconds(5)
        while ContinuousClock.now < deadline {
            if let bridge = NSApp.windows.first(where: { $0.title == "Floe Bridge" && $0.isVisible }),
               let content = bridge.contentView {
                if !pressAccessibilityButton(content, id: "bridge.switchToAgent") {
                    guard let frame = model.smokeSwitchFrame, !frame.isEmpty else {
                        try? await Task.sleep(for: .milliseconds(50))
                        continue
                    }
                    capture(content, extension: "bridge.png")
                    let point = NSPoint(x: frame.midX, y: content.isFlipped ? frame.midY : content.bounds.height - frame.midY)
                    guard click(content, at: point, in: bridge) else { return false }
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

    private func pressAccessibilityButton(_ value: Any, id: String, remaining: Int = 16) -> Bool {
        guard remaining > 0, let element = value as? any NSAccessibilityProtocol else { return false }
        if element.accessibilityIdentifier() == id { return element.accessibilityPerformPress() }
        return (element.accessibilityChildren() ?? []).contains {
            pressAccessibilityButton($0, id: id, remaining: remaining - 1)
        }
    }

    private func capture(_ view: NSView, extension suffix: String) {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try? bitmap.representation(using: .png, properties: [:])?.write(to: report.appendingPathExtension(suffix))
    }

    private func click(_ view: NSView, at point: NSPoint, in window: NSWindow) -> Bool {
        let location = view.convert(point, to: nil)
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: 1) else { return false }
            NSApp.postEvent(event, atStart: false)
        }
        return true
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
        let tools = MacToolboxCatalog.groups(locale: Locale(identifier: "en")).flatMap(\.tools)
        let remoteToolsAvailable = ["terminal", "vnc"].allSatisfy { id in
            tools.contains { $0.id == id && $0.isAvailable }
        }
        workspace.openToolbox(toolID: "terminal")
        let terminalVisible = workspace.toolbox === reopened && reopened?.window?.isVisible == true
        workspace.openToolbox(toolID: "vnc")
        let vncVisible = workspace.toolbox === reopened && reopened?.window?.isVisible == true
        let closed = await workspace.closeToolbox()
        return pingPassed && distinctOwner && remoteToolsAvailable && terminalVisible && vncVisible && closed
    }

    private func verifyWorkspaceAndAttachmentStaging(_ agent: HostAgentWorkspace) async -> Bool {
        let project = root.appendingPathComponent("Fixture Project", isDirectory: true)
        let reference = project.appendingPathComponent("fixture.md")
        do {
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
            try Data("Synthetic attachment".utf8).write(to: reference, options: .withoutOverwriting)
        } catch {
            return false
        }
        guard await agent.addWorkspace(name: "Fixture Project", rootURL: project),
              let first = agent.selectedWorkspaceID,
              await agent.addWorkspace(name: "Fixture Project", rootURL: project),
              agent.selectedWorkspaceID == first,
              agent.workspaces.filter({ $0.id == first }).count == 1,
              let staged = agent.stageAttachments([reference]).first,
              staged.displayName == "fixture.md",
              agent.stagedAttachments.count == 1 else { return false }
        agent.unstageAttachment(staged.id)
        agent.selectWorkspace(nil)
        return agent.stagedAttachments.isEmpty
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
