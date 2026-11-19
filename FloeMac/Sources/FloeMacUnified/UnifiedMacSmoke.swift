// SPDX-License-Identifier: MPL-2.0

#if FLOE_MAC_HOST_SMOKE
import AppKit
import CloudKit
import CoreText
import CryptoKit
import Darwin
import FloeCore
import FloeMacBridgeProtocol
import FloeMacToolbox
import FloeModels
import Foundation

@MainActor
final class UnifiedMacSmoke {
    static let flag = "--unified-smoke-report"
    let root: URL
    let report: URL
    let preferences: UserDefaults
    private let preferenceSuite: String
    let serverKey = Curve25519.Signing.PrivateKey()
    private let clientKey = Curve25519.Signing.PrivateKey()
    private var settingsDiagnostics: [String] = []

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
        preferenceSuite = "org.floeagent.macbridge.smoke."
            + FloeDigest.sha256Hex(Data(report.deletingLastPathComponent().path.utf8))
        guard let preferences = UserDefaults(suiteName: preferenceSuite) else { throw BridgeFailure.unsafePath }
        self.preferences = preferences
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
        if CommandLine.arguments.contains("--verify-saved-launch-mode") {
            let deadline = ContinuousClock.now + .seconds(5)
            while (!model.listenerReady || model.macWorkspace?.agent == nil) && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(30))
            }
            let startedInAgent = model.isAgentMode && model.listenerReady && NSApp.activationPolicy() == .regular
                && NSApp.windows.contains { $0.isVisible && $0.title == String(localized: "host.role.agent") }
                && model.smokeSettingsWindow?.isVisible != true
            if let agent = model.macWorkspace?.agent {
                await agent.prepare()
                while model.updates.installation.activity.activityCount != 0 && ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(30))
                }
                if agent.beginTermination() { try? await agent.finishTermination() }
            }
            finish(["agentModeRestoredOnRelaunch": startedInAgent, "pid": getpid()])
            return
        }
        if CommandLine.arguments.contains("--icloud-model-sync-smoke") {
            await verifyCloudKitModelSync()
            return
        }
        let deadline = ContinuousClock.now + .seconds(8)
        while !model.listenerReady && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        // An Agent-only entry point must also be inert when invoked directly.
        model.openToolbox(toolID: "ping")
        let bridgeOnlyStartup = model.listenerReady && !model.isAgentMode && model.macWorkspace == nil
            && !FileManager.default.fileExists(atPath: root.appendingPathComponent("Floe Mac Agent").path)
            && !FileManager.default.fileExists(atPath: root.appendingPathComponent("Toolbox").path)
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
        if model.macWorkspace?.agent == nil { model.openAgentWorkspace() }
        let switchedToAgent = model.macWorkspace?.agent != nil
        let workbenchVisible = NSApp.windows.contains {
            $0.isVisible && $0.title == String(localized: "host.role.agent")
        }
        let modeRoundTrip = await exerciseModeRoundTrip(model: model)
        let unifiedSettings = await exerciseUnifiedSettings(model: model)
        var nativeChat = false
        var storedTaskRun = false
        var taskMetadataSaved = false
        var archivedTaskRestored = false
        var deletedFixtureTask = false
        var workspaceAndAttachmentStaging = false
        var conversationHistoryVerified = false
        var workspaceTextEditsVerified = false
        var workspaceModelReadTools = false
        var catalog = false
        var standardTaskMenus = false
        var imageGeneration = false
        var agentApproval = (allowed: false, denied: false)
        var planning = (planSaved: false, goalSaved: false)
        var pressedApprovalButtons = Set<Bool>()
        if let agent = model.macWorkspace?.agent {
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
            if nativeChat, workspaceAndAttachmentStaging, let pdf = try? writePDFTextAttachment() {
                conversationHistoryVerified = await agent.verifyConversationHistorySmoke(reference: pdf)
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
                let openedNewTask = await openNewTaskFromMenu(workspace: agent)
                agentApproval = await agent.verifyAgentApprovalSmoke(project: project, checkingFile: folder) { allow in
                    guard openedNewTask, let window = NSApp.windows.first(where: {
                        $0.isVisible && $0.title == String(localized: "host.role.agent")
                    }), let content = window.contentView else { return false }
                    capture(content, extension: "approval.png")
                    let id = allow ? "mac.agent.allowOnce" : "mac.agent.deny"
                    if pressAccessibilityButton(content, id: id) {
                        pressedApprovalButtons.insert(allow)
                        return true
                    }
                    guard let frame = agent.smokeApprovalFrames[allow], !frame.isEmpty else { return false }
                    let point = NSPoint(x: frame.midX, y: frame.midY)
                    guard content.bounds.contains(content.convert(point, from: nil)),
                          clickWindowLocation(point, in: window) else { return false }
                    pressedApprovalButtons.insert(allow)
                    return true
                }
                workspaceTextEditsVerified = await agent.verifyAgentTextEditSmoke(project: project, folder: folder)
                planning = await agent.verifyPlanningSmoke(project: project)
                if let document = try? writePDFTextAttachment(in: folder) {
                    workspaceModelReadTools = await agent.verifyReadOnlyModelToolsSmoke(
                        project: project, documentName: document.lastPathComponent
                    )
                }
            }
            if let normalChatID {
                let removed = await agent.changeConversationMetadata(id: normalChatID, change: .delete)
                deletedFixtureTask = removed && !agent.conversations.contains { $0.id == normalChatID }
            }
            catalog = await verifyProviderCatalog(in: agent)
            standardTaskMenus = await verifyTaskMenus(model: model, workspace: agent)
            imageGeneration = await verifyImageGeneration()
        }
        let toolbox = await exerciseToolbox(model: model)
        if let agent = model.macWorkspace?.agent, agent.beginTermination() { try? await agent.finishTermination() }
        let output: [String: Any] = [
            "sameProcessBridgeReady": model.listenerReady,
            "bridgeOnlyStartupVerified": bridgeOnlyStartup,
            "legacyPairAndSignatureVerified": pairedRequest,
            "switchedToAgentFromBridge": switchedToAgent,
            "bridgeSwitchUserEventVerified": bridgeSwitchUserEvent,
            "workbenchWindowVisible": workbenchVisible,
            "modeRoundTripVerified": modeRoundTrip,
            "unifiedSettingsVerified": unifiedSettings,
            "standardTaskMenuVerified": standardTaskMenus,
            "imageGenerationVerified": imageGeneration,
            "settingsDiagnostics": settingsDiagnostics,
            "nativeChatAndUpdateAdmissionVerified": nativeChat,
            "storedTaskRunFound": storedTaskRun,
            "taskMetadataSaved": taskMetadataSaved,
            "archivedTaskRestored": archivedTaskRestored,
            "deletedFixtureTask": deletedFixtureTask,
            "composerDraftsReloaded": verifyDraftStorage(),
            "providerCatalogFetched": catalog,
            "workspaceAndAttachmentStagingVerified": workspaceAndAttachmentStaging,
            "workspaceTextEditsVerified": workspaceTextEditsVerified,
            "workspaceModelReadToolsVerified": workspaceModelReadTools,
            "conversationHistoryVerified": conversationHistoryVerified,
            "agentApprovedFileCreated": agentApproval.allowed,
            "agentDeclinedFileAbsent": agentApproval.denied,
            "planAcceptedAndReloaded": planning.planSaved,
            "goalRunBoundAndReloaded": planning.goalSaved,
            "workspaceApprovalUserEvents": pressedApprovalButtons.count == 2,
            "taskDiagnostics": model.macWorkspace?.agent?.smokeRunDiagnostics ?? [],
            "toolboxAndLoopbackVerified": toolbox,
            "enabledToolboxEntries": MacToolboxCatalog.groups(locale: .current)
                .flatMap(\.tools).filter(\.isAvailable).count,
            "activityBeforeQuit": model.updates.installation.activity.activityCount,
            "pid": getpid()
        ]
        finish(output)
    }

    private func finish(_ output: [String: Any]) {
        if let bytes = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: report, options: .atomic)
        }
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    func cleanup() {
        if !CommandLine.arguments.contains("--keep-launch-preference-for-relaunch") {
            preferences.removePersistentDomain(forName: preferenceSuite)
        }
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
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            try Data("Legacy draft".utf8).write(to: directory.appendingPathComponent("new-task"))
            try Data("Saved task text".utf8).write(to: directory.appendingPathComponent(conversation.uuidString))
        } catch { return false }
        let first = MacWorkspaceDraftStore(directory: directory)
        guard first.text(for: nil) == "Legacy draft" else { return false }
        let attachment = AttachmentRef(kind: .document, displayName: "Synthetic reference")
        first.setAttachments([attachment], for: conversation)
        first.flush()
        typealias Archive = ComposerDraftDocument<DesignJSONValue, DesignJSONValue>
        guard let bytes = try? Data(contentsOf: directory.appendingPathComponent("drafts.json")),
              let archive = try? JSONDecoder().decode(Archive.self, from: bytes),
              archive.drafts[Archive.homeDraftID.uuidString]?.text == "Legacy draft",
              archive.drafts[conversation.uuidString]?.attachments == [attachment] else { return false }
        let reopened = MacWorkspaceDraftStore(directory: directory)
        let readBack = reopened.text(for: nil) == "Legacy draft"
            && reopened.text(for: conversation) == "Saved task text" && reopened.text(for: UUID()).isEmpty
            && reopened.attachments(for: conversation) == [attachment]
        reopened.clear(for: conversation)
        reopened.flush()
        let cleared = MacWorkspaceDraftStore(directory: directory)
        return readBack && !first.saveFailed && !reopened.saveFailed
            && cleared.text(for: conversation).isEmpty && cleared.attachments(for: conversation).isEmpty
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

    private func verifyImageGeneration() async -> Bool {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--model-catalog-fixture"), flag < arguments.count - 1,
              let endpoint = URL(string: arguments[flag + 1]), endpoint.scheme == "http",
              endpoint.host == "127.0.0.1", endpoint.port != nil else { return false }
        let directory = root.appendingPathComponent("Generated Images Fixture", isDirectory: true)
        let images = MacImageGeneration(directory: directory, namespace: "fixture.no-keychain",
                                        useKeychain: false, admitWork: { {} })
        do {
            try images.save(.init(presetID: .openAI, endpoint: endpoint.absoluteString,
                                  modelID: "gpt-image-fixture"), apiKey: "floe-image-fixture")
        } catch {
            settingsDiagnostics.append("Fixture image settings: \(error.localizedDescription)")
            return false
        }
        do {
            try images.save(.init(presetID: .openAI, endpoint: "https://example.invalid/v1",
                                  modelID: "gpt-image-fixture"), apiKey: nil)
            return false
        } catch MacImageGeneration.MacImageGenerationError.keyRequired {
            guard images.configuration?.endpoint == endpoint.absoluteString else { return false }
        } catch {
            return false
        }
        images.generate(prompt: "Synthetic image prompt")
        let deadline = ContinuousClock.now + .seconds(6)
        while images.isGenerating && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard let item = images.history.first, item.prompt == "Synthetic image prompt",
              NSImage(contentsOf: images.imageURL(for: item))?.isValid == true else {
            settingsDiagnostics.append("Fixture image generation: \(images.notice ?? "no saved image")")
            images.cancel()
            return false
        }
        let reloaded = MacImageGeneration(directory: directory, namespace: "fixture.no-keychain",
                                           useKeychain: false, admitWork: { {} })
        return !reloaded.hasCredential && reloaded.history.first?.id == item.id
            && reloaded.imageData(for: item).flatMap(NSImage.init(data:))?.isValid == true
    }

    private func verifyTaskMenus(model: BridgeAppModel, workspace: HostAgentWorkspace) async -> Bool {
        model.openAgentWorkspace()
        let activated = ContinuousClock.now + .seconds(2)
        while NSApp.keyWindow?.title != String(localized: "host.role.agent") && ContinuousClock.now < activated {
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard NSApp.keyWindow?.title == String(localized: "host.role.agent") else {
            settingsDiagnostics.append("Workbench was not key during the shortcut test.")
            return false
        }
        let findTitle = String(localized: "mac.workspace.findTask")
        guard performMenuShortcut("f", title: findTitle) else { return false }
        let deadline = ContinuousClock.now + .seconds(2)
        while !workspace.smokeTaskSearchMounted && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard workspace.smokeTaskSearchMounted, performMenuShortcut("f", title: findTitle) else {
            settingsDiagnostics.append("Find did not show the task search field.")
            return false
        }
        while workspace.smokeTaskFindInvocations < 2 && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard workspace.smokeTaskSearchMounted, workspace.smokeTaskFindInvocations == 2,
              await openNewTaskFromMenu(workspace: workspace) else { return false }
        return workspace.smokeTaskSearchMounted
    }

    private func openNewTaskFromMenu(workspace: HostAgentWorkspace) async -> Bool {
        guard performMenuShortcut("n", title: String(localized: "workbench.new_task")) else { return false }
        let newTaskDeadline = ContinuousClock.now + .seconds(2)
        while workspace.selectedID != nil && ContinuousClock.now < newTaskDeadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
        return workspace.selectedID == nil
    }

    private func performMenuShortcut(_ key: String, title: String) -> Bool {
        for root in NSApp.mainMenu?.items ?? [] {
            guard let menu = root.submenu else { continue }
            menu.update()
            if let index = menu.items.firstIndex(where: {
                $0.keyEquivalent == key && $0.keyEquivalentModifierMask == .command && $0.title == title
            }) {
                menu.performActionForItem(at: index)
                return true
            }
        }
        let bound = NSApp.mainMenu?.items.compactMap(\.submenu).flatMap(\.items)
            .filter { $0.keyEquivalent == key }.map(\.title) ?? []
        settingsDiagnostics.append("Command-\(key) could not find \(title). Matching keys: \(bound)")
        return false
    }

    private func exerciseBridgeSwitch(model: BridgeAppModel) async -> Bool {
        guard model.macWorkspace?.agent == nil else { return false }
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
                while model.macWorkspace?.agent == nil && ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                return model.macWorkspace?.agent != nil
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

    private func clickWindowLocation(_ point: NSPoint, in window: NSWindow) -> Bool {
        for type: NSEvent.EventType in [.leftMouseDown, .leftMouseUp] {
            guard let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                                 timestamp: ProcessInfo.processInfo.systemUptime,
                                                 windowNumber: window.windowNumber, context: nil,
                                                 eventNumber: 0, clickCount: 1, pressure: 1) else { return false }
            window.sendEvent(event)
        }
        return true
    }

    private func exerciseToolbox(model: BridgeAppModel) async -> Bool {
        guard let workspace = model.macWorkspace else { return false }
        model.openToolbox(toolID: "ping")
        guard let first = workspace.toolbox, first.window?.isVisible == true else { return false }
        let command = first.services.networkOwner
        let started = command.start(.ping("127.0.0.1"), locale: Locale(identifier: "en"))
        let completed = await command.drain(timeout: 9)
        let pingPassed = started && completed && command.result?.contains("4 packets received") == true
        guard await workspace.closeToolbox() else { return false }
        model.openToolbox()
        let reopened = workspace.toolbox
        let distinctOwner = reopened?.window?.isVisible == true
            && reopened?.services.mediaEnvironment !== first.services.mediaEnvironment
        let tools = MacToolboxCatalog.groups(locale: Locale(identifier: "en")).flatMap(\.tools)
        let remoteToolsAvailable = ["terminal", "vnc"].allSatisfy { id in
            tools.contains { $0.id == id && $0.isAvailable }
        }
        model.openToolbox(toolID: "terminal")
        let terminalVisible = workspace.toolbox === reopened && reopened?.window?.isVisible == true
        model.openToolbox(toolID: "vnc")
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
        let conversationID = agent.selectedID
        agent.clearStagedAttachments()
        await agent.select(conversationID)
        guard agent.stagedAttachments.map(\.id) == [staged.id] else { return false }
        agent.unstageAttachment(staged.id)
        agent.selectWorkspace(nil)
        return agent.stagedAttachments.isEmpty
    }

    private func writePDFTextAttachment(in directory: URL? = nil) throws -> URL {
        let output = NSMutableData()
        var bounds = CGRect(x: 0, y: 0, width: 300, height: 300)
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &bounds, nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Synthetic attachment", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 14, nil)
        ]))
        context.textPosition = CGPoint(x: 24, y: 120)
        CTLineDraw(line, context)
        context.endPDFPage()
        context.closePDF()
        let path = (directory ?? root).appendingPathComponent("fixture-document.pdf")
        try (output as Data).write(to: path, options: .withoutOverwriting)
        return path
    }

    private func exerciseModeRoundTrip(model: BridgeAppModel) async -> Bool {
        guard let initialWorkspace = model.macWorkspace, let agent = initialWorkspace.agent,
              NSApp.activationPolicy() == .regular else { return false }
        await agent.prepare()
        let prepareDeadline = ContinuousClock.now + .seconds(5)
        while agent.isPreparing && ContinuousClock.now < prepareDeadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard agent.isReady else { return false }
        model.openToolbox(toolID: "ping")
        guard let toolboxWindow = initialWorkspace.toolbox?.window, toolboxWindow.isVisible else { return false }
        agent.hasPendingWorkspaceFileChanges = true
        let editPreserved: Bool
        do {
            _ = try await model.switchToBridge()
            editPreserved = false
        } catch UnifiedMacWorkspace.CloseError.pendingFiles {
            editPreserved = model.isAgentMode && model.macWorkspace === initialWorkspace && toolboxWindow.isVisible
        } catch { editPreserved = false }
        agent.hasPendingWorkspaceFileChanges = false
        guard editPreserved, (try? await model.switchToBridge()) == true else { return false }
        let deadline = ContinuousClock.now + .seconds(3)
        while !NSApp.windows.contains(where: { $0.title == "Floe Bridge" && $0.isVisible }),
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard !model.isAgentMode, model.macWorkspace == nil, initialWorkspace.agent == nil,
              initialWorkspace.toolbox == nil, !toolboxWindow.isVisible, NSApp.activationPolicy() == .accessory,
              NSApp.windows.contains(where: { $0.title == "Floe Bridge" && $0.isVisible }) else { return false }
        guard let port = model.smokePort, (try? await callPairedBridge(port: port)) == true else { return false }
        model.reopenPreferredWindow()
        model.openToolbox()
        guard model.macWorkspace == nil else { return false }
        model.openAgentWorkspace()
        return NSApp.activationPolicy() == .regular && model.isAgentMode
            && model.macWorkspace?.agent != nil && model.macWorkspace !== initialWorkspace
            && NSApp.windows.contains { $0.isVisible && $0.title == String(localized: "host.role.agent") }
    }

    private func exerciseUnifiedSettings(model: BridgeAppModel) async -> Bool {
        guard model.isAgentMode else { return false }
        let appMenu = NSApp.mainMenu?.items.first?.submenu
        appMenu?.update()
        guard let appMenu, let index = appMenu.items.firstIndex(where: { $0.keyEquivalent == "," }) else {
            settingsDiagnostics.append("Settings menu missing: \(appMenu?.items.map(\.title) ?? [])")
            return false
        }
        appMenu.performActionForItem(at: index)
        let deadline = ContinuousClock.now + .seconds(3)
        while model.smokeAgentSettingsSheet?.isVisible != true && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard let window = model.smokeAgentSettingsSheet, window.isVisible, model.settingsPane == .general,
              model.smokeSettingsWindow?.isVisible != true,
              let workspace = model.macWorkspace?.agent else {
            settingsDiagnostics.append("Settings after menu: \(model.settingsPane), sheet visible=\(model.smokeAgentSettingsSheet?.isVisible == true)")
            return false
        }
        defer { model.closeSettingsWindow() }
        workspace.defaultMode = .plan
        workspace.verifyAgentAnswers = true
        workspace.allowsWorkspaceWrites = false
        let preferencesSaved = preferences.string(forKey: "floe.mac.agent.defaultMode") == "plan"
            && preferences.bool(forKey: "floe.mac.agent.verifyAnswers")
            && !preferences.bool(forKey: "floe.mac.workspace.allowWrites")
        workspace.defaultMode = .chat
        workspace.verifyAgentAnswers = false
        workspace.allowsWorkspaceWrites = true
        guard preferencesSaved else { return false }
        model.openSettings(.models)
        while model.settingsPane != .models && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard model.settingsPane == .models, model.smokeAgentSettingsSheet === window else { return false }
        try? await Task.sleep(for: .milliseconds(200))
        if let content = window.contentView { capture(content, extension: "settings-models.png") }

        model.openSettings(.bridge)
        while model.settingsPane != .bridge && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard model.settingsPane == .bridge, model.isAgentMode, model.smokeAgentSettingsSheet === window,
              window.isVisible, NSApp.activationPolicy() == .regular else { return false }
        // Allow the selected SwiftUI tab to render before capturing it.
        try? await Task.sleep(for: .milliseconds(200))
        if let content = window.contentView { capture(content, extension: "settings-bridge.png") }
        return true
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
