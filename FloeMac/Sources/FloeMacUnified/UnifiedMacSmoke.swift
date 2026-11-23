// SPDX-License-Identifier: MPL-2.0

#if FLOE_MAC_HOST_SMOKE
import AVKit
import AppKit
import CloudKit
import CoreText
import CryptoKit
import Darwin
import FloeAgentRuntime
import FloeCore
import FloeDeviceSync
import FloeLocalModelCatalog
import FloeLocalModels
import FloeMacBridgeProtocol
import FloeMacToolbox
import FloeModels
import FloePersistence
import FloeProviders
import FloeTools
import Foundation
import PencilKit
import Quartz
import Vision
import WebKit

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
    private var browserOpenedFromMessageLink = false
    private var browserReturnButtonPressed = false
    private static let recoveryPathKey = "floe.mac.smoke.workbenchRecoveryPath"

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
        let temporary = URL(fileURLWithPath: String(cString: physicalTemp), isDirectory: true)
        if CommandLine.arguments.contains("--workbench-reopen") {
            guard let path = preferences.string(forKey: Self.recoveryPathKey), let resolved = realpath(path, nil) else {
                throw BridgeFailure.unsafePath
            }
            defer { free(resolved) }
            let saved = URL(fileURLWithPath: path, isDirectory: true)
            guard saved.deletingLastPathComponent().path == temporary.path,
                  saved.lastPathComponent.hasPrefix("floe-unified-smoke."), String(cString: resolved) == saved.path,
                  (try? saved.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true else {
                throw BridgeFailure.unsafePath
            }
            self.root = saved
            return
        }
        let prefix = temporary.appendingPathComponent("floe-unified-smoke.XXXXXX").path
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
        if CommandLine.arguments.contains("--verify-ark-provider") {
            await exerciseArkProvider(model)
            return
        }
        if CommandLine.arguments.contains("--provider-rejection-only"), let endpoint = projectTaskFixtureEndpoint,
           endpoint.host == "127.0.0.1" {
            await exerciseProviderRejection(model, endpoint: endpoint)
            return
        }
        if CommandLine.arguments.contains("--task-lifecycle-only"), let endpoint = projectTaskFixtureEndpoint, endpoint.host == "127.0.0.1" {
            await exerciseTaskLifecycle(model, endpoint: endpoint)
            return
        }
        if CommandLine.arguments.contains("--extension-tools-only"), let endpoint = projectTaskFixtureEndpoint, endpoint.host == "127.0.0.1" {
            await exerciseExtensionTools(model, endpoint: endpoint)
            return
        }
        if CommandLine.arguments.contains("--connector-parity-only"), let endpoint = projectTaskFixtureEndpoint, endpoint.host == "127.0.0.1" {
            await exerciseConnectorParity(model, endpoint: endpoint)
            return
        }
        if CommandLine.arguments.contains("--task-terminals-only") {
            await exerciseTaskTerminals(model)
            return
        }
        if CommandLine.arguments.contains("--goal-composer-parity-only"), let endpoint = projectTaskFixtureEndpoint {
            await exerciseGoalComposerParity(model, endpoint: endpoint)
            return
        }
        if CommandLine.arguments.contains("--composer-paste-only") {
            await exerciseComposerPaste(model)
            return
        }
        if CommandLine.arguments.contains("--transcript-stage-order-only"), let endpoint = projectTaskFixtureEndpoint {
            await exerciseTranscriptStageOrder(model, endpoint: endpoint)
            return
        }
        let pagedHistoryPair = CommandLine.arguments.contains("--device-history-paged-pair-only")
        if CommandLine.arguments.contains("--device-history-only") || pagedHistoryPair {
            await exerciseDeviceHistory(model, usePagedPeer: pagedHistoryPair)
            return
        }
        if CommandLine.arguments.contains("--device-history-resume-only") {
            await exerciseDeviceHistoryResume(model)
            return
        }
        if CommandLine.arguments.contains("--memory-only") {
            await exerciseMemoryLibrary(model)
            return
        }
        if CommandLine.arguments.contains("--icloud-configuration-only") {
            await exerciseCloudConfiguration(model)
            return
        }
        if CommandLine.arguments.contains("--managed-storage-and-sites-only") {
            await exerciseManagedStorageAndSites(model)
            return
        }
        if CommandLine.arguments.contains("--memory-runtime-only"), let endpoint = projectTaskFixtureEndpoint,
           endpoint.host == "127.0.0.1" {
            await exerciseMemoryRuntime(model, endpoint: endpoint)
            return
        }
        if CommandLine.arguments.contains("--voice-host-only"), let endpoint = projectTaskFixtureEndpoint,
           endpoint.host == "127.0.0.1" {
            await exerciseVoiceTurn(model, endpoint: endpoint)
            return
        }
        if let index = CommandLine.arguments.firstIndex(of: "--local-model-only"),
           CommandLine.arguments.indices.contains(index + 1),
           CommandLine.arguments[index + 1].hasPrefix("/") {
            await exerciseLocalModel(model, directory: URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true))
            return
        }
        if CommandLine.arguments.contains("--concurrent-drafts-only"), let endpoint = projectTaskFixtureEndpoint,
           endpoint.host == "127.0.0.1" {
            await exerciseConcurrentDrafts(model, endpoint: endpoint)
            return
        }
        if CommandLine.arguments.contains("--official-catalog-only") {
            await exerciseOfficialCatalog(model)
            return
        }
        if CommandLine.arguments.contains("--running-attachments-only"), let endpoint = projectTaskFixtureEndpoint,
           endpoint.host == "127.0.0.1" {
            await exerciseRunningAttachments(model, endpoint: endpoint)
            return
        }
        if CommandLine.arguments.contains("--transcript-parity-only") {
            await exerciseTranscriptParity(model)
            return
        }
        if CommandLine.arguments.contains("--project-workbench-only"), let endpoint = projectTaskFixtureEndpoint {
            await exerciseProjectWorkbench(model, endpoint: endpoint)
            return
        }
        if CommandLine.arguments.contains("--question-recovery-only"), let endpoint = projectTaskFixtureEndpoint {
            await exerciseQuestionRecovery(model, endpoint: endpoint)
            return
        }
        if CommandLine.arguments.contains("--cold-recovery-only"), let endpoint = projectTaskFixtureEndpoint {
            await exerciseColdRecovery(model, endpoint: endpoint)
            return
        }
        if CommandLine.arguments.contains("--workspace-authoring-only"), let endpoint = projectTaskFixtureEndpoint {
            await exerciseWorkspaceAuthoring(model, endpoint: endpoint)
            return
        }
        if CommandLine.arguments.contains("--goal-controls-only") {
            await exerciseGoalControls(model)
            return
        }
        let goalBlocker = CommandLine.arguments.contains("--goal-blocker-only")
        if (CommandLine.arguments.contains("--goal-evidence-only") || goalBlocker), let endpoint = projectTaskFixtureEndpoint {
            await exerciseGoalEvidence(model, endpoint: endpoint, blocker: goalBlocker)
            return
        }
        let firstLaunch = CommandLine.arguments.contains("--verify-first-launch")
        if firstLaunch || CommandLine.arguments.contains("--verify-saved-launch-mode") {
            let deadline = ContinuousClock.now + .seconds(5)
            while (!model.listenerReady || model.macWorkspace?.agent == nil) && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(30))
            }
            let startedInAgent = model.isAgentMode && model.listenerReady && NSApp.activationPolicy() == .regular
                && visibleWorkbench != nil
                && model.smokeSettingsWindow?.isVisible != true
            if firstLaunch {
                let preferenceWasAbsent = preferences.string(forKey: "floe.mac.launchMode") == nil
                if let agent = model.macWorkspace?.agent {
                    await agent.prepare()
                    while (agent.isPreparing || model.updates.installation.activity.activityCount != 0) && ContinuousClock.now < deadline {
                        try? await Task.sleep(for: .milliseconds(30))
                    }
                }
                let switched = (try? await model.switchToBridge()) == true
                finish(["agentIsDefault": preferenceWasAbsent && startedInAgent,
                        "explicitBridgeSaved": switched && preferences.string(forKey: "floe.mac.launchMode") == "bridge"
                            && model.macWorkspace == nil, "pid": getpid()])
                return
            }
            var defaultsRestored = false
            if let agent = model.macWorkspace?.agent {
                await agent.prepare()
                defaultsRestored = agent.defaultMode == .plan && agent.runningInputMode == .steer
                    && !agent.allowsWorkspaceWrites && agent.verifyAgentAnswers
                while model.updates.installation.activity.activityCount != 0 && ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(30))
                }
                if agent.beginTermination() { try? await agent.finishTermination() }
            }
            finish(["agentModeRestoredOnRelaunch": startedInAgent, "settingsRestoredOnRelaunch": defaultsRestored, "pid": getpid()])
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--background-window-fixture"),
           CommandLine.arguments.indices.contains(flag + 2), let pid = Int32(CommandLine.arguments[flag + 1]),
           let window = Int(CommandLine.arguments[flag + 2]) {
            await verifyBackgroundWindow(model, fixturePID: pid, window: window)
            return
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--native-command-fixture"),
           CommandLine.arguments.indices.contains(flag + 1), let endpoint = URL(string: CommandLine.arguments[flag + 1]) {
            await exerciseNativeCommands(model, endpoint: endpoint)
            return
        }
        if CommandLine.arguments.contains("--touch-layout-only") {
            model.openAgentWorkspace()
            if CommandLine.arguments.contains("--touch-dark") {
                NSApp.appearance = NSAppearance(named: .darkAqua)
            }
            guard let agent = model.macWorkspace?.agent, let window = visibleWorkbench,
                  let content = window.contentView else { finish(["opened": false]); return }
            await agent.prepare()
            let deadline = ContinuousClock.now + .seconds(6)
            while !agent.isReady && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(30)) }
            var checks: [String: Bool] = [:]
            var heights: [String: Double] = [:]
            for (label, size) in [("wide", NSSize(width: 1150, height: 750)), ("narrow", NSSize(width: 720, height: 560))] {
                window.setContentSize(size)
                try? await Task.sleep(for: .milliseconds(350))
                content.layoutSubtreeIfNeeded()
                refreshButtonFrames(in: content)
                capture(content, extension: label + ".png")
                captureWindow(window, suffix: label + "-window.png")
                if let frame = HostAgentWorkspaceView.smokeExpandFrame {
                    heights[label + "Expand"] = frame.height
                    let point = NSPoint(x: frame.minX + 5, y: frame.minY + 6)
                    let clicked = clickWindowLocation(point, in: window)
                    let until = ContinuousClock.now + .seconds(2)
                    while window.attachedSheet == nil && ContinuousClock.now < until { try? await Task.sleep(for: .milliseconds(30)) }
                    if let sheet = window.attachedSheet {
                        let closed = await closeFixtureSheet(sheet, id: "thread.composer.expanded.done")
                        checks[label + "Expand"] = clicked && frame.width >= 44 && frame.height >= 44 && closed
                    } else { checks[label + "Expand"] = false }
                } else { checks[label + "Expand"] = false }
                model.openSettings(.general)
                let opened = ContinuousClock.now + .seconds(3)
                while model.smokeAgentSettingsSheet?.contentView == nil && ContinuousClock.now < opened { try? await Task.sleep(for: .milliseconds(30)) }
                if let sheet = model.smokeAgentSettingsSheet, let body = sheet.contentView {
                    try? await Task.sleep(for: .milliseconds(300))
                    body.layoutSubtreeIfNeeded()
                    refreshButtonFrames(in: body)
                    capture(body, extension: label + "-settings.png")
                    heights[label + "SheetWidth"] = body.bounds.width
                    if label == "wide" {
                        checks["wideUpdateSettings"] = model.updates.smokeAutomaticChecksFrame?.isEmpty == false
                    }
                    let row = model.smokeSettingsFrames[.permissions]
                    heights[label + "SettingsRow"] = row?.height ?? 0
                    let pressed = clickSettingsPane(.permissions, model: model, in: sheet)
                    try? await Task.sleep(for: .milliseconds(220))
                    checks[label + "Settings"] = (row?.height ?? 0) >= 44 && pressed && model.settingsPane == .permissions
                    if label == "narrow" {
                        let hit = pressAccessibilityButton(body, id: "settings.categories.back") || model.smokeSettingsBackFrame.map {
                            clickWindowLocation(NSPoint(x: $0.midX, y: $0.midY), in: sheet)
                        } == true
                        try? await Task.sleep(for: .milliseconds(200))
                        checks["narrowBack"] = hit && clickSettingsPane(.general, model: model, in: sheet) && model.settingsPane == .general
                        let updateDeadline = ContinuousClock.now + .seconds(2)
                        while model.updates.smokeAutomaticChecksFrame == nil && ContinuousClock.now < updateDeadline {
                            try? await Task.sleep(for: .milliseconds(40))
                        }
                        checks["narrowUpdateSettings"] = model.updates.smokeAutomaticChecksFrame?.isEmpty == false
                        capture(body, extension: "narrow-general-settings.png")
                    }
                } else { checks[label + "Settings"] = false }
                model.closeSettingsWindow()
                try? await Task.sleep(for: .milliseconds(400))
            }
            finish(["checks": checks, "heights": heights])
            return
        }
        if CommandLine.arguments.contains("--task-media-workbench-only") {
            model.openAgentWorkspace()
            guard let agent = model.macWorkspace?.agent, let endpoint = projectTaskFixtureEndpoint else {
                finish(["media": false]); return
            }
            await agent.prepare()
            let deadline = ContinuousClock.now + .seconds(6)
            while !agent.isReady && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(40)) }
            finish(await MacTaskMediaWorkbenchSmoke.verify(in: agent, endpoint: endpoint, root: root) {
                self.clickApproval(in: agent, allow: true, screenshot: "task-media-approval.png")
            })
            return
        }
        if CommandLine.arguments.contains("--peer-workbench-only") {
            model.openAgentWorkspace()
            guard let agent = model.macWorkspace?.agent, let endpoint = projectTaskFixtureEndpoint else {
                finish(["peers": false]); return
            }
            await agent.prepare()
            let deadline = ContinuousClock.now + .seconds(6)
            while !agent.isReady && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(40)) }
            finish(await MacPeerWorkbenchSmoke.verify(in: agent, endpoint: endpoint, root: root))
            return
        }
        if CommandLine.arguments.contains("--workbench-basics-only") {
            model.openAgentWorkspace()
            guard let mac = model.macWorkspace, let agent = mac.agent, let temporary = mac.temporaryChat
            else { finish(["opened": false]); return }
            await agent.prepare()
            let ready = ContinuousClock.now + .seconds(6)
            while !agent.isReady && ContinuousClock.now < ready { try? await Task.sleep(for: .milliseconds(40)) }
            var checks = ["settings": await exerciseUnifiedSettings(model: model)]
            checks["files"] = await MacWorkspaceFileOperationsSmoke.verify(in: root)
            let fileEditorFailures = MacWorkspaceFileEditingSmoke.runSyntheticChecks()
            checks["sharedFileEditor"] = fileEditorFailures.isEmpty
            settingsDiagnostics.append(contentsOf: fileEditorFailures)
            checks["temporaryLifecycle"] = await MacTemporaryChatModel.verify(in: agent)
            _ = agent.addProvider(name: "Workbench fixture", endpoint: "https://example.invalid/v1",
                                  protocolKind: .openAIChatCompletions, modelID: "workbench-fixture", key: "")
            await Task.yield()
            let clicked = clickWorkbenchButton(ids: ["home.temporary.toggle"], frame: MacWorkspaceRootView.smokeTemporaryFrame,
                                               screenshot: nil)
            let entered = ContinuousClock.now + .seconds(2)
            while temporary.session == nil && ContinuousClock.now < entered { try? await Task.sleep(for: .milliseconds(40)) }
            checks["temporaryOpened"] = clicked && temporary.session != nil
            temporary.draft = "unsaved temporary fixture"
            if let content = visibleWorkbench?.contentView { capture(content, extension: "temporary.png") }
            let closed = await openNewTaskFromMenu(workspace: agent)
            let left = ContinuousClock.now + .seconds(2)
            while temporary.session != nil && ContinuousClock.now < left { try? await Task.sleep(for: .milliseconds(40)) }
            checks["temporaryNewTaskCleared"] = closed && temporary.session == nil && temporary.draft.isEmpty
            finish(["checks": checks, "diagnostics": settingsDiagnostics])
            return
        }
        if CommandLine.arguments.contains("--thread-ownership-only"), let endpoint = projectTaskFixtureEndpoint {
            model.openAgentWorkspace()
            guard let agent = model.macWorkspace?.agent else { finish(["opened": false]); return }
            await agent.prepare()
            let deadline = ContinuousClock.now + .seconds(6)
            while !agent.isReady && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            await verifyThreadOwnership(agent, endpoint: endpoint)
            return
        }
        if CommandLine.arguments.contains("--child-execution-only"), let endpoint = projectTaskFixtureEndpoint {
            model.openAgentWorkspace()
            guard let agent = model.macWorkspace?.agent else { finish(["opened": false]); return }
            await agent.prepare()
            let deadline = ContinuousClock.now + .seconds(6)
            while !agent.isReady && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            await verifyChildExecution(agent, endpoint: endpoint)
            return
        }
        if CommandLine.arguments.contains("--browser-only"), let endpoint = projectTaskFixtureEndpoint {
            model.openAgentWorkspace()
            guard let workspace = model.macWorkspace, let agent = workspace.agent else { finish(["opened": false]); return }
            await agent.prepare()
            let deadline = ContinuousClock.now + .seconds(6)
            while (!agent.isReady || HostAgentWorkspaceView.smokeExpandFrame == nil) && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(60))
            }
            if CommandLine.arguments.contains("--workbench-reopen") {
                await verifyBrowserRelaunch(workspace, agent: agent, endpoint: endpoint)
                return
            }
            let link = endpoint.appendingPathComponent("workbench-page")
            guard await agent.verifyChatSmoke(reply: "Project check completed. [Preview website](\(link.absoluteString))") else {
                finish(["chat": false]); return
            }
            let testsDownload = CommandLine.arguments.contains("--browser-download-and-restore")
            let ok = await verifyTaskBrowser(workspace, agent: agent, endpoint: endpoint, leavesBrowserOpen: testsDownload)
            var result: [String: Any] = ["browser": ok, "link": browserOpenedFromMessageLink]
            if ok, let taskID = agent.selectedID, testsDownload {
                result["taskID"] = taskID.uuidString
                if let digest = await verifyBrowserDownload(workspace, owner: taskID, endpoint: endpoint) {
                    result["downloadSHA256"] = digest
                    preferences.set(root.path, forKey: Self.recoveryPathKey)
                    preferences.synchronize()
                }
            }
            result["return"] = browserReturnButtonPressed
            result["details"] = settingsDiagnostics
            finish(result)
            return
        }
        if CommandLine.arguments.contains("--model-browser-only"), let endpoint = projectTaskFixtureEndpoint {
            await exerciseModelBrowser(model, endpoint: endpoint)
            return
        }
        if CommandLine.arguments.contains("--conversation-sheets-only") {
            model.openAgentWorkspace()
            guard let agent = model.macWorkspace?.agent else { finish(["opened": false]); return }
            await agent.prepare()
            let deadline = ContinuousClock.now + .seconds(4)
            while (!agent.isReady || HostAgentWorkspaceView.smokeExpandFrame == nil) && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(60))
            }
            let expanded = await verifyExpandedComposer(agent)
            let chat = await agent.verifyChatSmoke { true }
            var preview = false
            if chat, let pdf = try? writePDFTextAttachment(), await agent.verifyConversationHistorySmoke(reference: pdf) {
                preview = await verifyAttachmentPreview(agent, expected: pdf)
            }
            finish(["expandedComposer": expanded, "attachmentPreview": preview, "details": settingsDiagnostics])
            return
        }
        if CommandLine.arguments.contains("--task-permissions-only") {
            await verifyTaskPermissionsSheet(model)
            return
        }
        if CommandLine.arguments.contains("--creative-only") {
            model.openAgentWorkspace()
            guard let agent = model.macWorkspace?.agent else { finish(["creative": false, "details": ["Agent did not open"]]); return }
            await agent.prepare()
            let deadline = ContinuousClock.now + .seconds(6)
            while agent.isPreparing && !agent.isReady && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(40))
            }
            guard agent.isReady else { finish(["images": false, "creative": false, "details": ["Task database did not open"]]); return }
            let images = await verifyImageGeneration()
            let creative = images ? await verifyCreative(model) : false
            finish(["images": images, "creative": creative, "details": settingsDiagnostics])
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
        let workbenchVisible = visibleWorkbench != nil
        let modeRoundTrip = await exerciseModeRoundTrip(model: model)
        let unifiedSettings = await exerciseUnifiedSettings(model: model)
        var nativeChat = false
        var storedTaskRun = false
        var taskMetadataSaved = false
        var taskMoveVerified = false
        var archivedTaskRestored = false
        var deletedFixtureTask = false
        var searchChecks: [String: Bool] = [:]
        var publicWebRead = false
        var localWebsite = false
        var expandedComposer = false
        var attachmentPreview = false
        let fileOperations = await MacWorkspaceFileOperationsSmoke.verify(in: root)
        var workspaceAndAttachmentStaging = false
        var desktopFilesLayout = false
        var conversationHistoryVerified = false
        var approvalReviewerVerified = false
        var filePermissionsVerified = false
        var taskPermissionsVerified = false
        var workspaceTextEditsVerified = false
        var workspaceModelReadTools = false
        var childDetails = false
        var taskBrowser = false
        var projectWorkflow = false
        var concurrentTasks = false
        var catalog = false
        var providerAccountsVerified = false
        var auxiliaryModelsVerified = false
        var auxiliaryPanelVerified = false
        var providerConnectionVerified = false
        var standardTaskMenus = false
        var creative = false
        var imageGeneration = false
        var agentApproval = (allowed: false, denied: false)
        var planning = (planSaved: false, goalSaved: false)
        var goalControls = false
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
            expandedComposer = await verifyExpandedComposer(agent)
            workspaceAndAttachmentStaging = await verifyWorkspaceAndAttachmentStaging(agent)
            if let window = visibleWorkbench, let content = window.contentView {
                capture(content, extension: "png")
                desktopFilesLayout = await verifyDesktopFilesLayout(window: window, content: content, workspace: agent)
            }
            nativeChat = await agent.verifyChatSmoke { model.verifyActiveAgentDefersInstall() }
            if nativeChat, workspaceAndAttachmentStaging, let pdf = try? writePDFTextAttachment() {
                conversationHistoryVerified = await agent.verifyConversationHistorySmoke(reference: pdf)
                if conversationHistoryVerified { attachmentPreview = await verifyAttachmentPreview(agent, expected: pdf) }
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
            if let content = visibleWorkbench?.contentView {
                capture(content, extension: "task.png")
            }
            if let project = agent.workspaces.first(where: { $0.name == "Fixture Project" }) {
                if let binding = try? MacAgentWorkspaceTools.binding(workspace: project, readOnly: true, chatOnly: true),
                   let normalChatID {
                    publicWebRead = await MacPublicWebFetch.verify(binding: binding, conversationID: normalChatID,
                        readPublicPage: CommandLine.arguments.contains("--check-public-page"))
                }
                do {
                    searchChecks = try await MacSearchSmoke.verify(discover: { access in
                        let binding = try MacAgentWorkspaceTools.binding(workspace: project, readOnly: true, chatOnly: true, search: access)
                        return binding.allowedToolNames.contains(MacSearchTool.name) &&
                            binding.executor.descriptor(named: MacSearchTool.name) != nil
                    })
                } catch { settingsDiagnostics.append("Public search fixture: " + error.localizedDescription) }
                localWebsite = await MacWorkspaceHTMLPreviewSmoke.verify(in: root)
                let folder = root.appendingPathComponent("Fixture Project", isDirectory: true)
                if let normalChatID {
                    taskMoveVerified = await agent.verifyTaskMoveSmoke(normalChatID, project: project)
                }
                let openedNewTask = await openNewTaskFromMenu(workspace: agent)
                agentApproval = await agent.verifyAgentApprovalSmoke(project: project, checkingFile: folder) { allow in
                    guard openedNewTask, clickApproval(in: agent, allow: allow, screenshot: "approval.png") else {
                        return false
                    }
                    pressedApprovalButtons.insert(allow)
                    return true
                }
                approvalReviewerVerified = await agent.verifyApprovalReviewerSmoke()
                filePermissionsVerified = await agent.verifySavedFilePermissionSmoke(project: project, folder: folder)
                taskPermissionsVerified = await agent.verifyTaskPermissionSmoke(project: project, folder: folder)
                workspaceTextEditsVerified = await agent.verifyAgentTextEditSmoke(project: project, folder: folder)
                planning = await agent.verifyPlanningSmoke(project: project)
                if planning.goalSaved { goalControls = await agent.verifyGoalControlsSmoke() }
                if let document = try? writePDFTextAttachment(in: folder) {
                    workspaceModelReadTools = await agent.verifyReadOnlyModelToolsSmoke(
                        project: project, documentName: document.lastPathComponent
                    )
                    if let endpoint = projectTaskFixtureEndpoint,
                       await openNewProjectTask(workspace: agent, projectID: project.id) {
                        projectWorkflow = await verifyProjectWorkflow(agent, project: project, folder: folder,
                                                                    attachment: document, endpoint: endpoint)
                        if CommandLine.arguments.contains("--task-browser-fixture"), let workspace = model.macWorkspace {
                            childDetails = await verifyChildDetail(agent)
                            taskBrowser = await verifyTaskBrowser(workspace, agent: agent, endpoint: endpoint)
                        }
                    }
                }
                let otherFolder = root.appendingPathComponent("Second Fixture Project", isDirectory: true)
                if (try? FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: false)) != nil,
                   let otherProject = await agent.addWorkspace(name: otherFolder.lastPathComponent, rootURL: otherFolder) {
                    concurrentTasks = await agent.verifyConcurrentTasksSmoke(project: project, folder: folder,
                        otherProject: otherProject, otherFolder: otherFolder) { projectID in
                            await openNewProjectTask(workspace: agent, projectID: projectID,
                                screenshot: projectID == otherProject.id ? "project-task-concurrent.png" : nil,
                                fromName: projectID != otherProject.id)
                        }
                } else {
                    settingsDiagnostics.append("The second project test folder could not be registered.")
                }
            }
            if let normalChatID {
                let removed = await agent.changeConversationMetadata(id: normalChatID, change: .delete)
                deletedFixtureTask = removed && !agent.conversations.contains { $0.id == normalChatID }
            }
            catalog = await verifyProviderCatalog(in: agent)
            providerConnectionVerified = await verifyProviderConnection(in: agent)
            providerAccountsVerified = await agent.verifyProviderAccountsSmoke()
            if let index = CommandLine.arguments.firstIndex(of: "--model-catalog-fixture"), index + 1 < CommandLine.arguments.count,
               let endpoint = URL(string: CommandLine.arguments[index + 1]) {
                auxiliaryModelsVerified = await agent.verifyAuxiliaryModelsSmoke(endpoint: endpoint) {
                    model.openSettings(.models)
                    defer { model.closeSettingsWindow() }
                    try? await Task.sleep(for: .milliseconds(220))
                    guard let window = model.smokeAgentSettingsSheet, let body = window.contentView else { return }
                    capture(body, extension: "settings-provider-accounts.png")
                    guard clickSettingsPane(.auxiliary, model: model, in: window) else { return }
                    let deadline = ContinuousClock.now + .seconds(3)
                    while !agent.smokeAuxiliaryModelsMounted && ContinuousClock.now < deadline {
                        try? await Task.sleep(for: .milliseconds(40))
                    }
                    auxiliaryPanelVerified = agent.smokeAuxiliaryModelsMounted && model.settingsPane == .auxiliary && window.attachedSheet == nil
                    if auxiliaryPanelVerified { capture(body, extension: "settings-auxiliary.png") }
                }
            }
            standardTaskMenus = await verifyTaskMenus(model: model, workspace: agent)
            imageGeneration = await verifyImageGeneration()
            if CommandLine.arguments.contains("--creative-fixture") { creative = await verifyCreative(model) }
        }
        let spaceNavigation = await exerciseSpaceNavigation(model: model)
        let toolbox = await exerciseToolbox(model: model)
        let fileEditorFailures = MacWorkspaceFileEditingSmoke.runSyntheticChecks()
        if let agent = model.macWorkspace?.agent {
            agent.defaultMode = .plan
            agent.runningInputMode = .steer
            agent.allowsWorkspaceWrites = false
            agent.verifyAgentAnswers = true
            if agent.beginTermination() { try? await agent.finishTermination() }
        }
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
            "creativeMediaVerified": creative,
            "settingsDiagnostics": settingsDiagnostics,
            "nativeChatAndUpdateAdmissionVerified": nativeChat,
            "storedTaskRunFound": storedTaskRun,
            "taskMetadataSaved": taskMetadataSaved,
            "taskMoveVerified": taskMoveVerified,
            "archivedTaskRestored": archivedTaskRestored,
            "deletedFixtureTask": deletedFixtureTask,
            "composerDraftsReloaded": verifyDraftStorage(),
            "providerCatalogFetched": catalog,
            "providerCatalogPreservedOverrides": verifyCatalogOverrides(),
            "providerAccountsVerified": providerAccountsVerified,
            "auxiliaryModelsVerified": auxiliaryModelsVerified,
            "auxiliaryPanelVerified": auxiliaryPanelVerified,
            "providerConnectionVerified": providerConnectionVerified,
            "workspaceAndAttachmentStagingVerified": workspaceAndAttachmentStaging,
            "fileOperationsVerified": fileOperations,
            "publicWebReadVerified": publicWebRead,
            "webSearchVerified": !searchChecks.isEmpty && searchChecks.values.allSatisfy { $0 },
            "webSearchChecks": searchChecks,
            "localWebsiteVerified": localWebsite,
            "expandedComposerVerified": expandedComposer,
            "attachmentPreviewVerified": attachmentPreview,
            "desktopFilesLayoutVerified": desktopFilesLayout,
            "approvalReviewerVerified": approvalReviewerVerified,
            "savedFilePermissionVerified": filePermissionsVerified,
            "taskApprovalPolicyVerified": taskPermissionsVerified,
            "workspaceTextEditsVerified": workspaceTextEditsVerified,
            "fileEditorSaveVerified": fileEditorFailures.isEmpty,
            "fileEditorFailures": fileEditorFailures,
            "workspaceModelReadToolsVerified": workspaceModelReadTools,
            "projectTaskWorkflowVerified": projectWorkflow,
            "taskBrowserVerified": taskBrowser,
            "browserMessageLinkPressed": browserOpenedFromMessageLink,
            "browserReturnButtonPressed": browserReturnButtonPressed,
            "childDetailsVerified": childDetails,
            "concurrentTasksIsolated": concurrentTasks,
            "conversationHistoryVerified": conversationHistoryVerified,
            "agentApprovedFileCreated": agentApproval.allowed,
            "agentDeclinedFileAbsent": agentApproval.denied,
            "planAcceptedAndReloaded": planning.planSaved,
            "goalRunBoundAndReloaded": planning.goalSaved,
            "goalControlsVerified": goalControls,
            "workspaceApprovalUserEvents": pressedApprovalButtons.count == 2,
            "taskDiagnostics": model.macWorkspace?.agent?.smokeRunDiagnostics ?? [],
            "spaceFilesAndToolboxVerified": spaceNavigation,
            "toolboxAndLoopbackVerified": toolbox,
            "enabledToolboxEntries": MacToolboxCatalog.availableTools.count,
            "activityBeforeQuit": model.updates.installation.activity.activityCount,
            "pid": getpid()
        ]
        finish(output)
    }

    private func verifyBackgroundWindow(_ model: BridgeAppModel, fixturePID: Int32, window: Int) async {
        let app = "org.floeagent.qa.background-window"
        let before = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard fixturePID > 0, window > 0, before != fixturePID,
              NSRunningApplication(processIdentifier: fixturePID)?.bundleIdentifier == app,
              let desktop = MacNativeDesktopTools.available(rootURL: root).compactMap({ $0 as? MacDesktopControl }).first else {
            finish(["error": "Background fixture or signed companion unavailable"]); return
        }
        let context = ToolContext(runID: UUID(), approvalGrantID: UUID(), workspaceRootURL: root,
                                  cancellation: CancellationToken(), approvalOrigin: .humanCard)
        func invoke(_ action: MacDesktopControl.Action, snapshot: String? = nil, index: Int? = nil,
                    value: String? = nil) async throws -> ToolExecutionOutput {
            try await desktop.execute(.init(action: action, app: app, pid: fixturePID, windowID: window,
                                            snapshotID: snapshot, index: index, value: value), context: context)
        }
        func snapshot(_ text: String, role: String) throws -> (String, Int) {
            let pattern = #"(?<=snapshot_id=)[A-Fa-f0-9-]{36}"#
            guard let id = text.range(of: pattern, options: .regularExpression),
                  let line = text.split(separator: "\n").first(where: { $0.contains(role) }),
                  let range = line.range(of: #"(?<=\[)[0-9]+(?=\])"#, options: .regularExpression),
                  let index = Int(line[range]) else { throw MacKimiError.invalidTarget }
            return (String(text[id]), index)
        }
        var result: [String: Any] = [:]
        do {
            let fieldState = try await invoke(.inspect)
            let field = try snapshot(fieldState.summary, role: "AXTextField")
            _ = try await invoke(.setValue, snapshot: field.0, index: field.1, value: "Floe background edit")
            let buttonState = try await invoke(.inspect)
            result["fieldVerified"] = buttonState.summary.contains("Floe background edit")
            let button = try snapshot(buttonState.summary, role: "Record fixture click")
            let clicked = try await invoke(.click, snapshot: button.0, index: button.1)
            result["clickDelivered"] = clicked.exitStatus != 1 && clicked.summary.contains("Window after action:")
            let capture = try await invoke(.screenshot)
            if let item = capture.artifacts.first {
                let data = try Data(contentsOf: root.appendingPathComponent(item.relativePath))
                result["imageVerified"] = NSImage(data: data) != nil && FloeDigest.sha256Hex(data) == item.sha256
            }
            result["foregroundPreserved"] = NSWorkspace.shared.frontmostApplication?.processIdentifier == before
        } catch { result["error"] = error.localizedDescription }
        if let agent = model.macWorkspace?.agent {
            let end = ContinuousClock.now + .seconds(8)
            while agent.isPreparing && ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(30)) }
            if agent.beginTermination() { try? await agent.finishTermination() }
        }
        finish(result)
    }

    private func exerciseRunningAttachments(_ model: BridgeAppModel, endpoint: URL) async {
        model.openAgentWorkspace()
        guard let agent = model.macWorkspace?.agent else { finish(["opened": false]); return }
        await agent.prepare()
        let ready = ContinuousClock.now + .seconds(8)
        while !agent.isReady && ContinuousClock.now < ready { try? await Task.sleep(for: .milliseconds(40)) }
        guard agent.addProvider(name: "Attachment Fixture", endpoint: endpoint.absoluteString,
                                protocolKind: .openAIChatCompletions, modelID: "running-attachments",
                                key: "", allowsPlainHTTP: true) else { finish(["configured": false]); return }
        var checks: [String: Bool] = [:]
        for (name, guidance) in [("guidance", true), ("queue", false)] {
            guard agent.selectNewDraft(in: nil), agent.send("Begin the \(name) attachment check.", mode: .chat) else {
                checks[name] = false
                continue
            }
            let active = ContinuousClock.now + .seconds(6)
            while !agent.canSteer && ContinuousClock.now < active { try? await Task.sleep(for: .milliseconds(40)) }
            let file = root.appendingPathComponent("\(name)-fixture.txt")
            let token = "ATTACHMENT_QA_" + name.uppercased()
            let prompt = "Read the \(name) fixture document."
            let reply = "DOCUMENT_READ_" + name.uppercased()
            var consumedFromDraft = false
            if (try? Data(token.utf8).write(to: file)) != nil, agent.canSteer {
                let items = agent.stageAttachments([file])
                if !items.isEmpty {
                    agent.submitRunningInput(prompt, mode: guidance ? .steer : .queue, attachments: items) {
                        consumedFromDraft = true
                    }
                }
            }
            let done = ContinuousClock.now + .seconds(19)
            while ContinuousClock.now < done {
                if !agent.isSending && agent.messages.contains(where: { $0.role == "assistant" && $0.content.contains(reply) }) { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            if let id = agent.selectedID, !agent.isSending { await agent.select(id) }
            checks[name] = consumedFromDraft && agent.stagedAttachments.isEmpty
                && agent.messages.contains { $0.role == "assistant" && $0.content.contains(reply) }
                && agent.messages.contains { $0.role == "user" && $0.content == prompt
                    && $0.parts.contains { $0.attachmentID != nil && $0.kind == .file } }
        }
        let image = NSImage(size: NSSize(width: 700, height: 180))
        image.lockFocus()
        NSColor.white.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: image.size)).fill()
        ("Floe document number 421" as NSString).draw(at: NSPoint(x: 30, y: 50), withAttributes: [
            .font: NSFont.systemFont(ofSize: 46), .foregroundColor: NSColor.black,
        ])
        image.unlockFocus()
        if let bytes = image.tiffRepresentation,
           let raster = NSBitmapImageRep(data: bytes)?.representation(using: .png, properties: [:]),
           let read = try? MacComposerImageTextImport.recognizedText(from: raster) {
            checks["imageTextRecognition"] = read.contains("421")
        } else { checks["imageTextRecognition"] = false }
        finish(["checks": checks])
    }

    private func exerciseProjectWorkbench(_ model: BridgeAppModel, endpoint: URL) async {
        model.openAgentWorkspace()
        guard let agent = model.macWorkspace?.agent else { finish(["opened": false]); return }
        await agent.prepare()
        let deadline = ContinuousClock.now + .seconds(6)
        while !agent.isReady && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(40)) }
        let folder = root.appendingPathComponent("Fixture Project", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)) != nil,
              let project = await agent.addWorkspace(name: folder.lastPathComponent, rootURL: folder, selectForNewTask: false),
              let document = try? writePDFTextAttachment(in: folder),
              await openNewProjectTask(workspace: agent, projectID: project.id) else {
            finish(["opened": false, "diagnostics": settingsDiagnostics]); return
        }
        let passed = await verifyProjectWorkflow(agent, project: project, folder: folder, attachment: document, endpoint: endpoint)
        var organization = false
        if passed, let taskID = agent.selectedID {
            organization = await verifyProjectOrganization(agent, project: project, taskID: taskID)
        }
        let fileEditorFailures = MacWorkspaceFileEditingSmoke.runSyntheticChecks()
        finish(["projectTaskWorkflowVerified": passed, "projectOrganizationVerified": organization,
                "sharedFileEditor": fileEditorFailures.isEmpty,
                "diagnostics": agent.smokeRunDiagnostics + settingsDiagnostics + fileEditorFailures])
    }

    private func verifyProjectWorkflow(_ agent: HostAgentWorkspace, project: WorkspaceRecord, folder: URL,
                                       attachment: URL, endpoint: URL) async -> Bool {
        await agent.verifyProjectTaskWorkflowSmoke(project: project, folder: folder, attachment: attachment,
            endpoint: endpoint, chooseModel: { title in
                await selectMenuChoice(frame: agent.smokeComposerModelFrame, titles: [title], target: title)
            }, chooseMode: { mode in
                await selectComposerMode(mode, workspace: agent)
            }, answerQuestion: {
                guard CommandLine.arguments.contains("--project-question-fixture") else { return true }
                return await answerProjectQuestion(in: agent)
            }, confirm: {
                guard clickWorkbenchButton(ids: ["thread.plan.close"], frame: agent.smokeClosePlanFrame,
                                           screenshot: "project-task-plan.png") else { return false }
                await Task.yield()
                guard clickWorkbenchButton(ids: ["thread.plan.reopen"], frame: agent.smokeReopenPlanFrame,
                                           screenshot: nil) else { return false }
                await Task.yield()
                return clickWorkbenchButton(ids: ["thread.plan.executeNormal"], frame: agent.smokePlanExecuteFrame,
                                            screenshot: "project-task-plan.png")
            }, approve: {
                guard await enterSteerDuringApproval(workspace: agent) else { return false }
                return clickApproval(in: agent, allow: true, screenshot: "project-task-approval.png")
            }, newProjectTask: {
                await openNewProjectTask(workspace: agent, projectID: project.id)
            }, approveSubtask: {
                try? await Task.sleep(for: .milliseconds(160))
                return clickApproval(in: agent, allow: true, screenshot: "project-subtask-approval.png")
            })
    }

    private func verifyProjectOrganization(_ agent: HostAgentWorkspace, project: WorkspaceRecord, taskID: UUID) async -> Bool {
        let name = "Renamed Fixture Project"
        let persisted = agent.workspaces.first { $0.id == project.id }
        guard await agent.renameProject(project.id, name: "  \(name)  "),
              let renamed = agent.workspaces.first(where: { $0.id == project.id }), renamed.name == name,
              renamed.rootBookmark == project.rootBookmark, renamed.createdAt == persisted?.createdAt,
              agent.selectedConversationWorkspace?.name == name,
              await openNewTaskFromSidebar(workspace: agent),
              await agent.verifyChatSmoke(reply: "Acceptance report saved. Personal fixture."),
              let personalID = agent.selectedID, personalID != taskID,
              agent.selectedConversationWorkspace?.kind == .privateTask,
              let scoped = try? await agent.taskContentMatches("Acceptance report saved", archived: false, projectID: project.id),
              scoped.contains(where: { $0.conversationID == taskID && $0.messageID != nil }),
              !scoped.contains(where: { $0.conversationID == personalID }),
              clickWorkbenchButton(ids: ["workspace.space"], frame: agent.smokeSpaceFrame, screenshot: nil),
              await selectMenuChoice(frame: MacWorkspaceRootView.smokeSpaceProjectPickerFrame, titles: [name], target: name) else {
            settingsDiagnostics.append("Project rename or folder ownership could not be verified.")
            return false
        }
        MacWorkspaceTaskCenter.smokeResultFrames.removeAll()
        let showTasks = String(localized: "mac.workspace.projectTasks")
        guard await selectMenuChoice(frame: MacWorkspaceRootView.smokeSpaceProjectPickerFrame, titles: [showTasks], target: showTasks),
              let window = visibleWorkbench, let content = window.contentView else { return false }
        let deadline = ContinuousClock.now + .seconds(3)
        while MacWorkspaceTaskCenter.smokeResultFrames[taskID] == nil && ContinuousClock.now < deadline {
            content.layoutSubtreeIfNeeded()
            refreshButtonFrames(in: content)
            try? await Task.sleep(for: .milliseconds(40))
        }
        guard MacWorkspaceTaskCenter.smokeResultFrames[personalID] == nil,
              let frame = MacWorkspaceTaskCenter.smokeResultFrames[taskID], !frame.isEmpty else {
            settingsDiagnostics.append("The project task list did not filter by stored ownership.")
            return false
        }
        capture(content, extension: "project-tasks.png")
        guard clickWorkbenchButton(ids: ["workspace.task.open.\(taskID.uuidString)"], frame: frame, screenshot: nil) else { return false }
        let reopenDeadline = ContinuousClock.now + .seconds(3)
        while (agent.selectedID != taskID || agent.selectedConversationWorkspace?.id != project.id)
                && ContinuousClock.now < reopenDeadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
        return agent.selectedID == taskID && agent.selectedConversationWorkspace?.id == project.id
            && agent.selectedConversationWorkspace?.name == name
            && agent.selectedConversationWorkspace?.rootBookmark == project.rootBookmark
    }

    private func readyFixtureWorkbench(_ model: BridgeAppModel) async -> HostAgentWorkspace? {
        model.openAgentWorkspace()
        guard let agent = model.macWorkspace?.agent else { return nil }
        await agent.prepare()
        let deadline = ContinuousClock.now + .seconds(8)
        while !agent.isReady && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
        return agent.isReady ? agent : nil
    }

    private func exerciseTaskLifecycle(_ model: BridgeAppModel, endpoint: URL) async {
        guard let agent = await readyFixtureWorkbench(model), await agent.verifyChatSmoke(), let original = agent.selectedID else {
            finish(["ready": false]); return
        }
        let followed = await agent.editSelectedTaskPolicy(.approval(nil))
        let changed = await agent.setApprovalMode(.automatic, asDefault: true)
        let choseRecovery = await agent.editSelectedTaskPolicy(.recovery(.alwaysRetry))
        let choseNotice = await agent.editSelectedTaskPolicy(.notifications(.critical))
        await agent.select(original)
        let policy = followed && changed && choseRecovery && choseNotice && agent.taskApprovalMode == .automatic &&
            agent.selectedTaskPolicy?.approvalMode == nil && agent.selectedTaskPolicy?.recoveryPolicy == .alwaysRetry &&
            agent.selectedTaskPolicy?.notificationPolicy == .critical
        let center = agent.taskSchedules
        while center.isBusy { try? await Task.sleep(for: .milliseconds(20)) }
        let folder = root.appendingPathComponent("Scheduled project", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)) != nil,
              let project = await agent.addWorkspace(name: "Scheduled project", rootURL: folder, selectForNewTask: false),
              agent.useNativeCommandFixture(endpoint: endpoint) else { finish(["policy": policy, "fixture": false]); return }
        let once = TaskScheduleRecord(title: "Fixture calendar", prompt: "Respond to the scheduled task.",
            workspaceID: project.id, cadence: .once, scheduledAt: Date().addingTimeInterval(2))
        let repeating = TaskScheduleRecord(title: "Fixture repeat", prompt: "Respond to the recurring task.",
            cadence: .daily, scheduledAt: Date().addingTimeInterval(3600), anchorTimezone: "Etc/UTC")
        let missed = TaskScheduleRecord(title: "Fixture missed", prompt: "Respond to the manual make-up.",
            cadence: .once, scheduledAt: Date().addingTimeInterval(-600))
        let firstKey = TaskSchedulePlanner.dedupeKey(for: once.scheduledAt, record: once)
        let firstRunID = TaskScheduleOccurrence.stableID(scheduleID: once.id, dedupeKey: firstKey)
        let dependent = TaskScheduleRecord(title: "Fixture dependent", prompt: "Respond to the following task.",
            workspaceID: project.id, cadence: .afterSuccess, scheduledAt: Date(), upstreamRunID: firstRunID,
            originConversationID: firstRunID)
        let stored = await center.save(once)
        let dependentStored = await center.save(dependent)
        let recurringStored = await center.save(repeating)
        await center.setEnabled(repeating, enabled: false)
        let paused = center.records.first(where: { $0.id == repeating.id })?.isEnabled == false
        await center.setEnabled(repeating, enabled: true)
        let rearmed = center.records.first(where: { $0.id == repeating.id })?.nextExpectedAt != nil
        let missedStored = await center.save(missed)
        let deadline = ContinuousClock.now + .seconds(13)
        while ContinuousClock.now < deadline && (!center.recent.contains(where: { $0.scheduleID == once.id && $0.state == .completed })
            || !center.recent.contains(where: { $0.scheduleID == missed.id && $0.state == .skipped })
            || !center.recent.contains(where: { $0.scheduleID == dependent.id && $0.state == .completed })) {
            try? await Task.sleep(for: .milliseconds(60))
        }
        let result = center.recent.filter { $0.scheduleID == once.id }
        await center.upstreamCompleted(firstRunID)
        let followups = center.recent.filter { $0.scheduleID == dependent.id }
        let directed = dependentStored && followups.count == 1 && followups.first?.state == .completed
            && followups.first?.dedupeKey == "upstream:\(firstRunID.uuidString)"
        let linked = await center.linkedSchedules(for: firstRunID).contains(dependent.id)
        let correctSelection = agent.selectedID == original
        var projectOwner = false
        if let id = result.first?.conversationID {
            await agent.select(id)
            projectOwner = agent.selectedConversationWorkspace?.id == project.id
            await agent.select(original)
        }
        let recordedMiss = center.recent.contains(where: { $0.scheduleID == missed.id && $0.state == .skipped && $0.runID == nil })
        await center.runNow(missed)
        let manualDeadline = ContinuousClock.now + .seconds(10)
        while ContinuousClock.now < manualDeadline && !center.recent.contains(where: { $0.scheduleID == missed.id && $0.isManualRun && $0.state == .completed }) {
            try? await Task.sleep(for: .milliseconds(60))
        }
        let manual = center.recent.contains(where: { $0.scheduleID == missed.id && $0.isManualRun && $0.state == .completed })
        var notificationRoutes = false
        if let scheduledID = result.first?.conversationID {
            model.openNotifiedTask(scheduledID)
            let routeDeadline = ContinuousClock.now + .seconds(3)
            while agent.selectedID != scheduledID && ContinuousClock.now < routeDeadline {
                try? await Task.sleep(for: .milliseconds(35))
            }
            notificationRoutes = agent.selectedID == scheduledID
        }
        func probe(_ name: String, tools: Bool = false) async -> MacProviderDiagnostic {
            await agent.testProviderModel(endpoint: endpoint.absoluteString, protocolKind: .openAIChatCompletions, modelID: name,
                                          key: "", allowsPlainHTTP: true, providerID: nil, presetID: nil, testsTools: tools)
        }
        let successful = await probe("model-replies")
        let limited = await probe("model-limited")
        let toolProbe = await probe("model-tool", tools: true)
        let account = MacProviderDraft(name: "Model list fixture", endpoint: endpoint.absoluteString, allowsPlainHTTP: true)
        let candidates = ["fixture-list-a", "fixture-list-b", "fixture-list-skipped"].map { id in
            ModelProfile(providerID: account.candidateProviderID, remoteModelID: id, displayName: id,
                         limits: .init(contextTokens: 4096, maxOutputTokens: 256), capabilities: [.text, .tools])
        }
        var selection = ProviderModelSelection(candidates: candidates, selectedIDs: [])
        for model in candidates.prefix(2) { selection.setSelected(model.id, true) }
        selection.mergeDiscovered(candidates)
        let modelsSaved = agent.saveProviderModels(accountID: nil, draft: account, selection: selection)
        let storedAccount = agent.accounts.first { $0.name == "Model list fixture" }
        let validSelection = modelsSaved && Set(storedAccount?.models.map(\.id) ?? []) == selection.selectedIDs
            && selection.matching("skipped").count == 1
        var structuredCompatibility = false
        if let taskID = result.first?.conversationID {
            let exported = root.appendingPathComponent("fixture-conversation.jsonl")
            if (try? await agent.exportStructuredConversation(conversationID: taskID, to: exported)) != nil,
               let jsonl = try? String(contentsOf: exported, encoding: .utf8) {
                let rows = jsonl.split(separator: "\n").compactMap {
                    (try? JSONSerialization.jsonObject(with: Data($0.utf8))) as? [String: Any]
                }
                structuredCompatibility = rows.first?["format"] as? String == "floe.task.jsonl"
                    && rows.first?["version"] as? Int == 1 && rows.last?["type"] as? String == "exportComplete"
                    && rows.contains { $0["type"] as? String == "run" && $0["id"] as? String == firstRunID.uuidString }
                    && rows.contains { $0["type"] as? String == "message" && $0["runID"] as? String == firstRunID.uuidString }
            }
        }
        var scheduleSheet = false
        MacWorkspaceTaskCenter.smokeSchedulesFrame = nil
        if clickWorkbenchButton(ids: ["workspace.taskCenter"], frame: MacWorkspaceRootView.smokeTaskCenterFrame, screenshot: nil) {
            let controls = ContinuousClock.now + .seconds(3)
            while MacWorkspaceTaskCenter.smokeSchedulesFrame == nil && ContinuousClock.now < controls {
                try? await Task.sleep(for: .milliseconds(35))
            }
            if clickWorkbenchButton(ids: ["workspace.task.schedules"], frame: MacWorkspaceTaskCenter.smokeSchedulesFrame, screenshot: nil),
               let window = visibleWorkbench {
                let presentation = ContinuousClock.now + .seconds(3)
                while (window.attachedSheet == nil || center.isBusy) && ContinuousClock.now < presentation {
                    try? await Task.sleep(for: .milliseconds(35))
                }
                if let sheet = window.attachedSheet, let content = sheet.contentView {
                    capture(content, extension: "scheduled-tasks-sheet.png")
                    scheduleSheet = await closeFixtureSheet(sheet, id: "mac.schedule.done")
                }
            }
        }
        let modelPicker = if let storedAccount, validSelection {
            await openFixtureModelChoices(model, accountID: storedAccount.id,
                                          expected: Set(selection.selectedModels.map(\.remoteModelID)))
        } else { false }
        finish(["policy": policy, "calendarCompletedOnce": stored && result.count == 1 && result.first?.state == .completed,
                "calendarStates": result.map(\.state.rawValue), "recurringPauseResume": recurringStored && paused && rearmed,
                "recordedMissed": missedStored && recordedMiss, "manualMakeup": manual,
                "afterSuccess": directed, "linkedSchedule": linked, "structuredCompatibility": structuredCompatibility,
                "sameVisibleTask": correctSelection, "ownsProject": projectOwner, "notificationRoute": notificationRoutes, "scheduleSheet": scheduleSheet,
                "modelProbe": successful.result == .response, "toolProbe": toolProbe.result == .toolResponse,
                "modelSelection": validSelection, "modelPicker": modelPicker, "quotaProbe": limited.result == .quotaOrRateLimit,
                "safeDiagnostic": !limited.exportText.contains("private-fixture-content") && !limited.exportText.contains(endpoint.absoluteString),
                "diagnostics": settingsDiagnostics])
    }

    private func openFixtureModelChoices(_ model: BridgeAppModel, accountID: UUID, expected: Set<String>) async -> Bool {
        let accountKey = "\(ProviderCatalogServiceRole.conversation.rawValue).\(accountID.uuidString)"
        MacProviderSettingsView.smokeManageModelsFrame = nil
        MacProviderSettingsView.smokeModelChoices = []
        model.openSettings(.models)
        defer { model.closeSettingsWindow() }
        let deadline = ContinuousClock.now + .seconds(5)
        var accountOpened = false
        var listOpened = false
        while ContinuousClock.now < deadline {
            if let window = model.smokeAgentSettingsSheet, let content = window.contentView {
                content.layoutSubtreeIfNeeded()
                refreshButtonFrames(in: content)
                if !accountOpened {
                    accountOpened = pressAccessibilityButton(content, id: "settings.providers.account." + accountKey)
                    if !accountOpened, let frame = MacProviderSettingsView.smokeAccountFrames[accountKey] {
                        accountOpened = clickWindowLocation(.init(x: frame.midX, y: frame.midY), in: window)
                    }
                } else if !listOpened {
                    listOpened = pressAccessibilityButton(content, id: "settings.providers.manageModels")
                    if !listOpened, let frame = MacProviderSettingsView.smokeManageModelsFrame {
                        listOpened = clickWindowLocation(.init(x: frame.midX, y: frame.midY), in: window)
                    }
                }
                if listOpened && MacProviderSettingsView.smokeModelListMounted &&
                    Set(MacProviderSettingsView.smokeModelChoices) == expected {
                    for surface in [window.attachedSheet, window] + NSApp.windows.filter(\.isVisible).map(Optional.some) {
                        if let view = surface?.contentView, accessibilityElement(view, id: "providers.models.search") != nil {
                            capture(view, extension: "provider-model-list.png")
                            _ = pressAccessibilityButton(view, id: "providers.models.done")
                            return true
                        }
                    }
                    if let view = window.attachedSheet?.contentView {
                        capture(view, extension: "provider-model-list.png")
                        return true
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        settingsDiagnostics.append("Model list account=\(accountOpened) button=\(listOpened) mounted=\(MacProviderSettingsView.smokeModelListMounted) selection=\(MacProviderSettingsView.smokeModelChoices.count)")
        if let view = model.smokeAgentSettingsSheet?.contentView {
            capture(view, extension: "provider-model-list-failed.png")
        }
        return false
    }

    private func exerciseTaskTerminals(_ model: BridgeAppModel) async {
        guard let agent = await readyFixtureWorkbench(model), let unified = model.macWorkspace else {
            finish(["ready": false]); return
        }
        let left = root.appendingPathComponent("Terminal Alpha", isDirectory: true)
        let right = root.appendingPathComponent("Terminal Beta", isDirectory: true)
        do {
            for url in [left, right] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
            guard let firstProject = await agent.addWorkspace(name: "Terminal Alpha", rootURL: left, selectForNewTask: false),
                  let secondProject = await agent.addWorkspace(name: "Terminal Beta", rootURL: right, selectForNewTask: false) else {
                finish(["projects": false]); return
            }
            let first = try unified.smokeTerminalOwner(for: UUID(), record: firstProject)
            let second = try unified.smokeTerminalOwner(for: UUID(), record: secondProject)
            let ledger = model.updates.installation.activity
            let idleCount = ledger.activityCount
            try await first.startLocal()
            try await second.startLocal()
            let firstPID = first.measure(kind: .local).shellPID
            let secondPID = second.measure(kind: .local).shellPID
            let owned = first.workspaceURL.resolvingSymlinksInPath().path == left.resolvingSymlinksInPath().path &&
                second.workspaceURL.resolvingSymlinksInPath().path == right.resolvingSymlinksInPath().path
            let installedBlocked = ledger.activityCount >= idleCount + 2 && ledger.reserveInstallationIfIdle() == nil
            let firstClosed = await first.stopLocal()
            let secondMeasurement = second.measure(kind: .local)
            let secondUnaffected = secondMeasurement.state == .running && secondMeasurement.shellPID == secondPID
            let allClosed = await unified.closeTaskTerminals()
            let deadline = ContinuousClock.now + .seconds(3)
            while ledger.activityCount > idleCount && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(35))
            }
            finish(["taskRoots": owned, "independentPIDs": (firstPID ?? 0) > 0 && (secondPID ?? 0) > 0 && firstPID != secondPID,
                    "installationBlocked": installedBlocked, "stopsIndependently": firstClosed && secondUnaffected,
                    "reapedAndReleased": allClosed && ledger.activityCount <= idleCount])
        } catch {
            _ = await unified.closeTaskTerminals()
            finish(["terminalStarted": false, "diagnostic": String(describing: type(of: error))])
        }
    }

    private func exerciseGoalComposerParity(_ model: BridgeAppModel, endpoint: URL) async {
        guard let agent = await readyFixtureWorkbench(model),
              let draftStore = model.macWorkspace?.smokeDraftStore, let window = visibleWorkbench,
              agent.addProvider(name: "Goal Builder Fixture", endpoint: endpoint.absoluteString,
                                protocolKind: .openAIChatCompletions, modelID: "draft-stream",
                                key: "", supportsTools: true, allowsPlainHTTP: true) else {
            finish(["configured": false]); return
        }
        let objective = "Verify the fixture and report the outcome"
        agent.verifyAgentAnswers = false
        let owner = agent.attachmentOwnerID
        let file = root.appendingPathComponent("goal-note.txt")
        guard (try? "Use this fixture".write(to: file, atomically: true, encoding: .utf8)) != nil,
              let staged = agent.stageAttachments([file]).first,
              await selectComposerMode(.goal, workspace: agent), window.attachedSheet == nil,
              let frame = agent.smokePromptFrame,
              clickWindowLocation(NSPoint(x: frame.midX, y: frame.midY), in: window) else {
            finish(["selectedGoalInComposer": false, "diagnostics": settingsDiagnostics]); return
        }
        await Task.yield()
        guard let editor = window.firstResponder as? NSTextView else { finish(["ordinaryComposer": false]); return }
        editor.insertText(objective, replacementRange: editor.selectedRange())
        await Task.yield()
        guard clickWorkbenchButton(ids: ["composer.send"], frame: agent.smokeSteerFrame, screenshot: "goal-in-composer.png")
        else { finish(["sentGoal": false]); return }
        let ready = ContinuousClock.now + .seconds(4)
        while (agent.goal == nil || agent.selectedID == nil || !agent.canSteer), ContinuousClock.now < ready {
            try? await Task.sleep(for: .milliseconds(25))
        }
        guard let goal = agent.goal, let id = agent.selectedID else {
            finish(["definitionLoaded": false]); return
        }
        let savedDefinition = goal.objective == objective && goal.acceptanceCriteria.count == 1
            && goal.blockingConditions?.isEmpty != false && goal.stoppingConditions?.isEmpty != false
        let noSeparateInput = window.attachedSheet == nil && draftStore.text(for: owner).isEmpty
        let modeWhileRunning = agent.composerMode
        let followUp = "Send this once as a normal Agent message."
        var followUpAccepted = false
        agent.submitRunningInput(followUp, mode: .queue, attachments: []) { followUpAccepted = true }
        let queueDeadline = ContinuousClock.now + .seconds(2)
        while agent.queuedInputs[id]?.first?.content != followUp && ContinuousClock.now < queueDeadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        let followUpWasQueued = followUpAccepted && agent.queuedInputs[id]?.first?.executionMode == HostAgentMode.agent.rawValue
        await agent.deleteGoal(goal)
        let keptRunning = agent.isTaskRunning(id) && agent.goal == nil
        let deadline = ContinuousClock.now + .seconds(18)
        while (agent.isTaskRunning(id) || !agent.messages.contains(where: { $0.content == followUp })),
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        await agent.select(nil)
        await agent.select(id)
        let keptConversation = agent.messages.contains { $0.role == "user" && $0.content == objective }
            && agent.messages.contains { $0.role == "assistant" && !$0.content.isEmpty }
        let sentAttachment = agent.messages.contains { message in
            message.role == "user" && message.content == objective
                && message.parts.contains { $0.attachmentID == staged.id }
        }
        finish(["usedNormalComposer": noSeparateInput, "savedDefinition": savedDefinition, "deletionKeptRunning": keptRunning,
                "keptConversation": keptConversation, "goalStayedDeleted": agent.goal == nil,
                "sentAttachment": sentAttachment, "agentReadyForNextInput": modeWhileRunning == .agent && agent.composerMode == .agent,
                "deliveredFollowUp": followUpWasQueued && agent.messages.filter { $0.role == "user" && $0.content == followUp }.count == 1,
                "noNewGoalRound": agent.transcriptRuns.count == 2 && agent.transcriptRuns.filter { $0.goalID == goal.id }.count == 1])
    }

    private func exerciseComposerPaste(_ model: BridgeAppModel) async {
        guard let agent = await readyFixtureWorkbench(model), let window = visibleWorkbench,
              let content = window.contentView, let drafts = model.macWorkspace?.smokeDraftStore else {
            finish(["ready": false]); return
        }
        window.makeKeyAndOrderFront(nil)
        let limit = ContinuousClock.now + .seconds(5)
        var editor: NSTextView?
        while ContinuousClock.now < limit {
            if let field = window.firstResponder as? NSTextView, field.isEditable {
                editor = field
                break
            }
            content.layoutSubtreeIfNeeded()
            if let frame = agent.smokePromptFrame, !frame.isEmpty {
                _ = clickWindowLocation(NSPoint(x: frame.midX, y: frame.midY), in: window)
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        guard let editor else { finish(["composerFocused": false]); return }
        let owner = agent.uncommittedDraftID
        let board = NSPasteboard.withUniqueName()
        defer { board.releaseGlobally() }
        let longest = String(repeating: "多行粘贴包含中文、emoji ✅ 和字母。\n", count: 18_000)
        let cases = [
            ("multiline", String(repeating: "多行粘贴包含中文、emoji ✅ 和字母。\n", count: 4_000)),
            ("unbroken", String(repeating: "abcdef0123456789", count: 22_500)),
            ("nearDraftLimit", longest)
        ]
        var results: [String: Any] = [:]
        for (label, text) in cases {
            board.clearContents()
            guard board.setString(text, forType: .string) else { finish(["fixturePasteboard": false]); return }
            editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
            try? Data(label.utf8).write(to: report.appendingPathExtension("paste-stage"), options: .atomic)
            let start = ContinuousClock.now
            let accepted = editor.readSelection(from: board, type: .string)
            content.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(60))
            let elapsed = (ContinuousClock.now - start).components
            let seconds = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
            results[label + "Seconds"] = seconds
            results[label + "Bytes"] = text.utf8.count
            results[label + "Retained"] = accepted && drafts.text(for: owner) == text && editor.string == text
            results[label + "Responsive"] = seconds < 2
        }
        drafts.flush()
        let archive = agent.personalTaskLeaseBase.appendingPathComponent("Drafts/drafts.json")
        let saveDeadline = ContinuousClock.now + .seconds(4)
        var savedCompleteDraft = false
        while ContinuousClock.now < saveDeadline {
            if let bytes = try? Data(contentsOf: archive),
               let document = try? JSONDecoder().decode(ComposerDraftDocument<DesignJSONValue, DesignJSONValue>.self, from: bytes),
               document.drafts[owner.uuidString]?.text == longest {
                savedCompleteDraft = true
                break
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        results["savedCompleteDraft"] = savedCompleteDraft

        if let endpoint = projectTaskFixtureEndpoint {
            agent.defaultMode = .chat
            let configured = agent.addProvider(name: "Composer Fixture", endpoint: endpoint.absoluteString,
                                               protocolKind: .openAIChatCompletions, modelID: "draft-stream",
                                               key: "", allowsPlainHTTP: true)
            let text = "Send a pasted draft using the keyboard."
            board.clearContents()
            board.setString(text, forType: .string)
            editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
            if configured, editor.readSelection(from: board, type: .string) {
                window.makeFirstResponder(editor)
                for type: NSEvent.EventType in [.keyDown, .keyUp] {
                    if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [.command],
                                                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                    characters: "\r", charactersIgnoringModifiers: "\r",
                                                    isARepeat: false, keyCode: 36) {
                        NSApp.postEvent(event, atStart: false)
                    }
                }
            }
            let sendDeadline = ContinuousClock.now + .seconds(12)
            while (agent.selectedID != owner || agent.isTaskRunning(owner)), ContinuousClock.now < sendDeadline {
                try? await Task.sleep(for: .milliseconds(40))
            }
            results["commandReturnSent"] = agent.selectedID == owner && drafts.text(for: owner).isEmpty
                && agent.messages.contains { $0.role == "user" && $0.content == text }
        }
        finish(results)
    }

    private func exerciseTranscriptStageOrder(_ model: BridgeAppModel, endpoint: URL) async {
        guard let agent = await readyFixtureWorkbench(model) else { finish(["ready": false]); return }
        let folder = root.appendingPathComponent("Stage order", isDirectory: true)
        let markerA = "Stage A introduction."
        let markerB = "Stage B explanation."
        let markerC = "Stage C conclusion."
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            try Data("First fixture".utf8).write(to: folder.appendingPathComponent("first.txt"))
            try Data("Second fixture".utf8).write(to: folder.appendingPathComponent("second.txt"))
            guard let project = await agent.addWorkspace(name: folder.lastPathComponent, rootURL: folder),
                  agent.startNamedAgentFixture("Read the two local fixtures in order.", modelID: "stage-order-fixture",
                                               endpoint: endpoint, projectID: project.id) else {
                finish(["started": false]); return
            }
        } catch {
            finish(["project": false]); return
        }

        func order() -> [String] {
            let items = ThreadTimelineBuilder.buildConversation(messages: agent.messages, runs: agent.transcriptRuns,
                eventsByRun: agent.transcriptEventsByRun, liveRunID: agent.transcriptLiveRunID, isRunning: agent.isSending,
                liveStreamedText: agent.streamedText, liveReasoningText: agent.liveReasoning, pendingApprovals: [])
            return items.flatMap { item -> [String] in
                switch item {
                case .assistantMessage(let text, _, _): [text]
                case .liveAssistantTail: ["live:" + agent.streamedText]
                case .stepGroup(let events, _):
                    events.compactMap { event in
                        guard event.kind == .toolRequest else { return nil }
                        let fields = ThreadEventPayload.decode(event.payloadJSON)
                        return fields["callID"] ?? fields["id"]
                    }
                default: []
                }
            }
        }

        let firstTool = "fixture-stage-first"
        let secondTool = "fixture-stage-second"
        let expected = [markerA, firstTool, markerB, secondTool, markerC]
        var liveB: [String]?
        var liveC: [String]?
        var decisions = Set<String>()
        let deadline = ContinuousClock.now + .seconds(22)
        while agent.activeRunCount > 0 && ContinuousClock.now < deadline {
            if let approval = agent.pendingApproval, approval.toolName == "workspace.readFile",
               decisions.insert(approval.callID).inserted {
                await agent.resolveApproval(approval, allow: true)
            }
            if agent.streamedText.contains(markerB), !agent.streamedText.contains(markerC), liveB == nil {
                let shown = order()
                if shown.contains(firstTool) { liveB = shown }
            }
            if agent.streamedText.contains(markerC), liveC == nil {
                let shown = order()
                if shown.contains(secondTool) { liveC = shown }
            }
            try? await Task.sleep(for: .milliseconds(35))
        }
        guard agent.activeRunCount == 0, let id = agent.selectedID else {
            if agent.isSending { agent.stop() }
            finish(["completed": false, "liveB": liveB ?? [], "liveC": liveC ?? []]); return
        }
        let settled = order()
        await agent.select(nil)
        await agent.select(id)
        let reopened = order()
        finish(["secondPhaseInPlace": liveB == [markerA, firstTool, "live:" + markerB],
                "thirdPhaseInPlace": liveC == [markerA, firstTool, markerB, secondTool, "live:" + markerC],
                "settledInOrder": settled == expected,
                "reopenedInOrder": reopened == expected,
                "liveB": liveB ?? [], "liveC": liveC ?? [], "settled": settled, "reopened": reopened])
    }

    private actor DeviceHistoryFixturePages {
        let store: SQLiteConversationStore
        var failAfterFirstPage: Bool
        private(set) var startingCursors: [String?] = []

        init(store: SQLiteConversationStore, failAfterFirstPage: Bool = false) {
            self.store = store
            self.failAfterFirstPage = failAfterFirstPage
        }

        func export(id: UUID, after: String?, through: Int64?) async throws -> DeviceHistoryPage {
            if through == nil {
                startingCursors.append(after)
            } else if failAfterFirstPage {
                failAfterFirstPage = false
                throw DeviceHistorySyncError.disconnected
            }
            let page = try await store.deviceHistoryPage(conversationID: id, after: after, through: through)
            return .init(archive: page.archive, nextCursor: page.nextCursor, through: page.through, hasMore: page.hasMore)
        }
    }

    private func deviceHistoryFixturePeer(store: SQLiteConversationStore, pages: DeviceHistoryFixturePages? = nil) -> DeviceHistorySyncCenter {
        func parse(_ id: UUID, _ data: Data) throws -> DeviceConversationHistory {
            let history = try DeviceConversationHistory(data: data)
            guard history.id == id else { throw DeviceHistorySyncError.invalidResponse }
            return history
        }

        let exportPage: (@Sendable (UUID, String?, Int64?) async throws -> DeviceHistoryPage)?
        let destination: DeviceHistoryPageDestination?
        if let pages {
            exportPage = { id, after, through in try await pages.export(id: id, after: after, through: through) }
            destination = .init(cursor: { peerID, id in
                try await store.deviceHistoryCursor(from: peerID, conversationID: id)
            }, commit: { peerID, id, data, nextCursor in
                try await store.importDeviceHistory(parse(id, data), sourcePeerID: peerID, nextCursor: nextCursor).addedMessages
            })
        } else {
            exportPage = nil
            destination = nil
        }

        let file = root.appendingPathComponent("remote-identity")
        return DeviceHistorySyncCenter(
            settingsURL: root.appendingPathComponent("remote-settings.json"),
            identityStorage: .init(load: { try? Data(contentsOf: file) }, save: { try $0.write(to: file, options: .atomic) }),
            source: .init(list: { shared in
                try await store.conversations().filter { shared.contains($0.id) }
                    .map { DeviceHistoryOffer(id: $0.id, title: $0.title) }
            }, export: { try await store.deviceHistory(conversationID: $0).encoded() }, exportPage: exportPage),
            localTasks: {
                try await store.conversations().map { DeviceHistoryOffer(id: $0.id, title: $0.title) }
            },
            importHistory: { id, data in
                try await store.importDeviceHistory(parse(id, data)).addedMessages
            },
            pagedHistory: destination)
    }

    private func pairDeviceHistoryFixtures(_ center: DeviceHistorySyncCenter, _ peer: DeviceHistorySyncCenter)
        async throws -> (mac: DeviceHistoryPairingTicket, peer: DeviceHistoryPairingTicket) {
        await center.activate()
        await center.setEnabled(true)
        await peer.activate()
        await peer.setEnabled(true)
        guard let localCode = center.pairingCode, let remoteCode = peer.pairingCode else {
            throw DeviceHistorySyncError.unavailable
        }
        let local = try DeviceHistoryPairingTicket(code: localCode)
        let remote = try DeviceHistoryPairingTicket(code: remoteCode)
        await center.pair(remote, named: "Remote fixture")
        await peer.pair(local, named: "Native Mac fixture")
        return (local, remote)
    }

    private func exerciseDeviceHistory(_ model: BridgeAppModel, usePagedPeer: Bool) async {
        guard let agent = await readyFixtureWorkbench(model), let center = agent.deviceHistorySync else {
            finish(["ready": false, "storage": model.macWorkspace?.agent?.storageErrorKind ?? ""]); return
        }
        let defaultsOff = !center.enabled
        let remoteID = UUID()
        let remoteMessage = UUID()
        var remotePeer: DeviceHistorySyncCenter?
        do {
            let remoteDatabase = try DatabaseManager.inMemory()
            try await remoteDatabase.migrate()
            let store = SQLiteConversationStore(database: remoteDatabase)
            let date = Date()
            try await store.saveConversationWithCanonicalWorkspace(
                .init(id: remoteID, title: "Paired device fixture", createdAt: date, updatedAt: date))
            try await store.appendMessage(.init(id: remoteMessage, conversationID: remoteID, role: "user",
                                               content: "Arrived from the other device.", createdAt: date))
            let pages = usePagedPeer ? DeviceHistoryFixturePages(store: store) : nil
            let remote = deviceHistoryFixturePeer(store: store, pages: pages)
            remotePeer = remote
            guard await agent.verifyChatSmoke(), let localID = agent.selectedID else {
                finish(["fixtureSaved": false]); return
            }
            let (localTicket, remoteTicket) = try await pairDeviceHistoryFixtures(center, remote)
            await center.share(localID, with: remoteTicket.id, enabled: true)
            await remote.share(remoteID, with: localTicket.id, enabled: true)

            await center.receive(remoteID, from: remoteTicket.id)
            await agent.select(remoteID)
            let nativeReadBack = agent.messages.contains(where: { $0.id == remoteMessage && $0.content == "Arrived from the other device." })
            await center.receive(remoteID, from: remoteTicket.id)
            let duplicate = center.status == .received(0)
            await remote.receive(localID, from: localTicket.id)
            let otherReadBack = try await store.messages(conversationID: localID).contains { $0.content == "Synthetic persisted reply." }

            await agent.select(localID)
            let retainedWorkspace = agent.selectedConversationWorkspace?.id
            let appendedOnMac = await agent.verifyChatSmoke(reply: "Mac follow-up reply.", followUp: "Mac follow-up.")
            let peerAppend = UUID()
            try await store.appendMessage(.init(id: peerAppend, conversationID: localID, role: "user",
                                               content: "Peer appended to the same task.", createdAt: Date()))
            await remote.share(localID, with: localTicket.id, enabled: true)
            await center.receive(localID, from: remoteTicket.id)
            let selectedTranscriptUpdated = center.status == .received(1)
                && agent.selectedID == localID && agent.messages.contains { $0.id == peerAppend }
            await remote.receive(localID, from: localTicket.id)
            let peerImportedMacTurn = remote.status == .received(2)
            await remote.receive(localID, from: localTicket.id)
            await center.receive(localID, from: remoteTicket.id)
            let appendReplayWasIdempotent = remote.status == .received(0) && center.status == .received(0)
            let macCursor = try await agent.receivedDeviceHistoryCursor(from: remoteTicket.id, conversationID: localID)
            let peerCursor = try await store.deviceHistoryCursor(from: localTicket.id, conversationID: localID)
            let correctWireMode = usePagedPeer ? macCursor != nil && peerCursor != nil : macCursor == nil && peerCursor == nil
            let peerMessages = try await store.messages(conversationID: localID)
            let expectedMessages = Set(peerMessages.map(\.id))
            let converged = appendedOnMac && peerImportedMacTurn && expectedMessages.count == 5
                && Set(agent.messages.map(\.id)) == expectedMessages

            model.openSettings(.deviceSync)
            let deadline = ContinuousClock.now + .seconds(4)
            var settingsShown = false
            while ContinuousClock.now < deadline && !settingsShown {
                if let view = model.smokeAgentSettingsSheet?.contentView,
                   model.settingsPane == .deviceSync, model.smokeDeviceSyncMounted {
                    settingsShown = true
                    capture(view, extension: "device-sync-settings.png")
                }
                if !settingsShown { try await Task.sleep(for: .milliseconds(35)) }
            }
            model.closeSettingsWindow()
            await center.pause()
            await center.activate()
            let reconnected = await remote.remoteConversations(from: localTicket.id)?.contains { $0.id == localID } == true
            await center.share(localID, with: remoteTicket.id, enabled: false)
            let stillPaired = center.peers.contains { $0.id == remoteTicket.id }
            let noOffer = await remote.remoteConversations(from: localTicket.id)?.contains { $0.id == localID } == false
            await remote.receive(localID, from: localTicket.id)
            let shareRevokedWhilePaired = stillPaired && noOffer && remote.status == .noLongerShared
            await agent.select(nil)
            await agent.select(localID)
            let peerKeptHistory = try await store.messages(conversationID: localID)
            let reopenedAfterRevoke = agent.selectedID == localID && retainedWorkspace != nil
                && agent.selectedConversationWorkspace?.id == retainedWorkspace
                && Set(agent.messages.map(\.id)) == expectedMessages
                && Set(peerKeptHistory.map(\.id)) == expectedMessages
            await center.remove(remoteTicket.id)
            let revoked = await remote.remoteConversations(from: localTicket.id) == nil
            await center.pause()
            await remote.pause()
            finish(["defaultOff": defaultsOff, "nativeReadBack": nativeReadBack, "reverseReadBack": otherReadBack,
                    "repeatedImport": duplicate, "settingsShown": settingsShown, "revocation": revoked,
                    "correctWireMode": correctWireMode,
                    "sameConversationConverged": converged, "selectedTranscriptUpdated": selectedTranscriptUpdated,
                    "appendReplayWasIdempotent": appendReplayWasIdempotent, "shareRevokedWhilePaired": shareRevokedWhilePaired,
                    "reopenedAfterRevoke": reopenedAfterRevoke,
                    "reconnectedWithoutPairingAgain": reconnected])
        } catch {
            await center.pause()
            await remotePeer?.pause()
            finish(["finished": false, "error": String(describing: type(of: error))])
        }
    }

    private func exerciseDeviceHistoryResume(_ model: BridgeAppModel) async {
        guard let agent = await readyFixtureWorkbench(model), let center = agent.deviceHistorySync else {
            finish(["ready": false, "storage": model.macWorkspace?.agent?.storageErrorKind ?? ""]); return
        }
        let id = UUID()
        let before = Date(timeIntervalSince1970: 1_790_000_000)
        let count = DeviceConversationHistory.maximumMessages + 1
        var remotePeer: DeviceHistorySyncCenter?
        do {
            let database = try DatabaseManager.inMemory()
            try await database.migrate()
            let store = SQLiteConversationStore(database: database)
            try await store.saveConversationWithCanonicalWorkspace(
                .init(id: id, title: "Long paired history", createdAt: before, updatedAt: before))
            var ids: [UUID] = []
            for index in 0..<count {
                let messageID = UUID()
                try await store.appendMessage(.init(id: messageID, conversationID: id, role: "user",
                    content: "Synthetic history message \(index)", createdAt: before.addingTimeInterval(Double(index))))
                ids.append(messageID)
            }
            let pages = DeviceHistoryFixturePages(store: store, failAfterFirstPage: true)
            let remote = deviceHistoryFixturePeer(store: store, pages: pages)
            remotePeer = remote
            let (local, peer) = try await pairDeviceHistoryFixtures(center, remote)
            await remote.share(id, with: local.id, enabled: true)
            await center.receive(id, from: peer.id)
            let interrupted = center.status
            guard case .interrupted(let firstCount) = interrupted, firstCount > 0, firstCount < count,
                  let firstCursor = try await agent.receivedDeviceHistoryCursor(from: peer.id, conversationID: id) else {
                await center.pause(); await remote.pause()
                finish(["interruptedAfterCommit": false, "status": String(describing: interrupted)])
                return
            }
            await agent.select(id)
            let partialReadBack = agent.selectedID == id && !agent.messages.isEmpty
            let workspaceID = agent.selectedConversationWorkspace?.id
            guard try await model.switchToBridge(), let reopened = await readyFixtureWorkbench(model),
                  let resumedCenter = reopened.deviceHistorySync, reopened !== agent else {
                await remote.pause()
                finish(["databaseReopened": false, "storage": model.macWorkspace?.agent?.storageErrorKind ?? ""])
                return
            }
            let savedCursor = try await reopened.receivedDeviceHistoryCursor(from: peer.id, conversationID: id)
            await reopened.select(id)
            await resumedCenter.activate()
            let ready = ContinuousClock.now + .seconds(6)
            while resumedCenter.pairingCode == nil && ContinuousClock.now < ready {
                try await Task.sleep(for: .milliseconds(40))
            }
            await resumedCenter.receive(id, from: peer.id)
            let resumeCountMatches = resumedCenter.status == .received(count - firstCount)
            let starts = await pages.startingCursors
            let resumedFromCursor = starts.count == 2 && starts[0] == nil && starts[1] == firstCursor
            let lastCursor = try await reopened.receivedDeviceHistoryCursor(from: peer.id, conversationID: id)
            let result = try await reopened.transcript(conversationID: id)
            let fullReadBack = result.map(\.id) == ids && reopened.messages.last?.id == ids.last

            let lateID = UUID()
            try await store.appendMessage(.init(id: lateID, conversationID: id, role: "assistant",
                content: "Appended after the cursor with an earlier timestamp.", createdAt: before.addingTimeInterval(-1)))
            await resumedCenter.receive(id, from: peer.id)
            let receivedOnlyAppend = resumedCenter.status == .received(1)
            let afterAppend = try await reopened.transcript(conversationID: id)
            await resumedCenter.receive(id, from: peer.id)
            let repeatedAppend = resumedCenter.status == .received(0)

            await remote.share(id, with: local.id, enabled: false)
            await resumedCenter.receive(id, from: peer.id)
            let revoked = resumedCenter.status == .noLongerShared
            await reopened.select(nil)
            await reopened.select(id)
            let afterReopen = try await reopened.transcript(conversationID: id)
            let keptAfterRevoke = workspaceID != nil && reopened.selectedConversationWorkspace?.id == workspaceID
                && afterReopen.map(\.id) == afterAppend.map(\.id)
            await resumedCenter.pause()
            await remote.pause()
            finish(["interruptedAfterCommit": true, "partialReadBack": partialReadBack, "resumedFromCursor": resumedFromCursor,
                    "cursorSurvivedDatabaseReopen": savedCursor == firstCursor,
                    "fullReadBack": fullReadBack, "resumedMessageCount": resumeCountMatches,
                    "cursorAdvanced": lastCursor != nil && lastCursor != firstCursor, "receivedOnlyAppend": receivedOnlyAppend,
                    "earlierTimestampReadBack": afterAppend.count == count + 1 && afterAppend.first?.id == lateID,
                    "repeatedAppend": repeatedAppend, "revoked": revoked, "keptAfterRevoke": keptAfterRevoke])
        } catch {
            await model.macWorkspace?.agent?.deviceHistorySync?.pause()
            await remotePeer?.pause()
            finish(["finished": false, "error": String(describing: type(of: error))])
        }
    }

    private func exerciseMemoryLibrary(_ model: BridgeAppModel) async {
        guard let agent = await readyFixtureWorkbench(model) else { finish(["ready": false]); return }
        do {
            let saved = try await agent.withMemoryLibrary { library in
                try await library.save(content: "Fixture preference", scope: .userProfile,
                                       pinned: false, forReview: true)
                guard let pending = try await library.pendingReview().candidates.first else { return false }
                try await library.resolveReview(id: pending.id, keep: true)
                return try await library.list(scope: .userProfile, cursor: nil).entries.contains { $0.id == pending.id }
            }
            model.openSettings(.memories)
            var shown = false
            var pressed = false
            var editor = false
            let deadline = ContinuousClock.now + .seconds(4)
            while ContinuousClock.now < deadline {
                if let window = model.smokeAgentSettingsSheet, let content = window.contentView,
                   let frame = MacMemorySettingsView.smokeAddFrame, !frame.isEmpty {
                    shown = model.settingsPane == .memories
                    capture(content, extension: "memory-settings.png")
                    pressed = pressAccessibilityButton(content, id: "settings.memory.add")
                        || clickWindowLocation(NSPoint(x: frame.midX, y: frame.midY), in: window)
                    break
                }
                try await Task.sleep(for: .milliseconds(50))
            }
            while pressed, ContinuousClock.now < deadline {
                editor = MacMemorySettingsView.smokeEditorMounted
                if editor { break }
                try await Task.sleep(for: .milliseconds(40))
            }
            model.closeSettingsWindow()
            finish(["savedInWorkbenchStore": saved, "memorySettingsShown": shown, "openedMemoryEditor": editor])
        } catch {
            finish(["memorySettingsShown": false])
        }
    }

    private func exerciseMemoryRuntime(_ model: BridgeAppModel, endpoint: URL) async {
        guard let agent = await readyFixtureWorkbench(model),
              agent.startNamedAgentFixture("Look for my preference and ask to remember it.", modelID: "memory-fixture",
                                           endpoint: endpoint, projectID: nil, mode: .chat) else {
            finish(["started": false]); return
        }
        let deadline = ContinuousClock.now + .seconds(20)
        var pressed = false
        while agent.activeRunCount > 0 && ContinuousClock.now < deadline {
            if !pressed, agent.pendingApproval?.toolName == MemoryRememberTool.name {
                pressed = clickApproval(in: agent, allow: true, screenshot: "memory-approval.png")
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        let finished = agent.activeRunCount == 0 && agent.messages.contains { $0.content == "Memory saved." }
        if agent.activeRunCount > 0 { agent.stop() }
        let saved = (try? await agent.withMemoryLibrary { library in
            try await library.list(scope: .userProfile, cursor: nil).entries.contains {
                $0.content == "Use numbered review notes"
            }
        }) ?? false
        finish(["approvalPressed": pressed, "completed": finished, "stored": saved])
    }

    private func exerciseManagedStorageAndSites(_ model: BridgeAppModel) async {
        guard await readyFixtureWorkbench(model) != nil, let workspace = model.macWorkspace,
              let service = workspace.managedStorage, let sites = workspace.browser?.taskTools.siteMemory else {
            finish(["ready": false]); return
        }
        let siteURL = URL(string: "https://example.com/index")!
        let otherURL = URL(string: "https://example.org")!
        var result: [String: Bool] = ["defaultEphemeral": sites.store(for: siteURL) == nil]
        if let origin = sites.remember(url: siteURL), let store = sites.store(for: siteURL),
           let cookie = HTTPCookie(properties: [.name: "floe-fixture", .value: "synthetic", .domain: "example.com",
               .path: "/", .secure: "TRUE", .expires: Date().addingTimeInterval(1_200)]) {
            sites.flush()
            await store.httpCookieStore.setCookie(cookie)
            let received = await store.httpCookieStore.allCookies()
            result["rememberedAndIsolated"] = store.isPersistent && received.contains(where: { $0.name == cookie.name })
                && sites.store(for: otherURL) == nil
            let opened = await exerciseSettingsPage(.siteData, model: model)
            result["siteSettingsVisible"] = opened && model.smokeSiteSettingsMounted
            await sites.forget(origin: origin)
            let remaining = await store.httpCookieStore.allCookies()
            result["rememberedDataRemoved"] = sites.store(for: siteURL) == nil && remaining.isEmpty
        }
        let folder = FloeScratch.scratchRoot(temporary: root).appendingPathComponent("skills-" + UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let staleFile = folder.appendingPathComponent("fixture.tmp")
            try Data(repeating: 0x2A, count: 4_096).write(to: staleFile)
            let old: [FileAttributeKey: Any] = [.modificationDate: Date(timeIntervalSinceNow: -172_800)]
            try FileManager.default.setAttributes(old, ofItemAtPath: staleFile.path)
            try FileManager.default.setAttributes(old, ofItemAtPath: folder.path)
            let opened = await exerciseSettingsPage(.dataStorage, model: model)
            result["storageSettingsVisible"] = opened && model.smokeStorageSettingsMounted
            await service.estimateCleanup()
            result["staleFolderEstimated"] = service.estimate?.eligibleItemCount == 1
            await service.performCleanup()
            result["staleFolderRemoved"] = !FileManager.default.fileExists(atPath: folder.path)
            let agentFolder = try HostAgentDatabase.prepareStorageDirectory(applicationSupport: root, namespace: Bundle.main.bundleIdentifier!)
            result["taskDatabasePreserved"] = FileManager.default.fileExists(atPath: agentFolder.appendingPathComponent("floe.sqlite").path)
        } catch { result["storageOperation"] = false }
        finish(result)
    }

    private func exerciseSettingsPage(_ pane: BridgeAppModel.SettingsPane, model: BridgeAppModel) async -> Bool {
        model.openSettings(pane)
        let deadline = ContinuousClock.now + .seconds(3)
        while (model.smokeAgentSettingsSheet == nil || model.settingsPane != pane), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
        try? await Task.sleep(for: .milliseconds(100))
        return model.smokeAgentSettingsSheet?.isVisible == true && model.settingsPane == pane
    }

    private func exerciseCloudConfiguration(_ model: BridgeAppModel) async {
        guard let agent = await readyFixtureWorkbench(model),
              agent.saveProvider(endpoint: "https://example.com/v1", protocolKind: .openAIChatCompletions,
                                 modelID: "fixture-cloud", key: "fixture-local-key"),
              let original = agent.providers.first else {
            finish(["ready": false]); return
        }
        let checked = MacSharedSettingsSnapshot(appearance: "dark", verifyAnswers: true, runningInput: .steer)
        let records = (try? checked.records()) ?? []
        var renamed = original.model
        renamed.displayName = "Renamed iPad model"
        let exchange = MacCloudConfigurationExchange(configuration: .init(
            entries: [.init(provider: original.profile, model: renamed)],
            preferences: .init(defaultAgentModelID: renamed.id),
            settings: records
        ), providerKeys: [original.profile.id: "fixture-icloud-key"])
        let applied = agent.applyCloudConfiguration(exchange)
        let saved = agent.providers.first(where: { $0.model.id == original.model.id })
        var changedOrigin = original.profile
        changedOrigin.baseURL = URL(string: "https://example.org/v1")!
        let rejected = !agent.applyCloudConfiguration(.init(
            configuration: .init(entries: [.init(provider: changedOrigin, model: renamed)])
        ))
        model.openSettings(.iCloud)
        let deadline = ContinuousClock.now + .seconds(3)
        while !model.smokeCloudSettingsMounted, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
        let restored = MacSharedSettingsSnapshot(records: exchange.configuration.settings)
        finish([
            "settingsVisible": model.smokeCloudSettingsMounted,
            "sharedRecordKeys": Set(records.map(\.key)) == [
                MacSharedSettingsSnapshot.appearanceKey, MacSharedSettingsSnapshot.verifyKey, MacSharedSettingsSnapshot.inputKey
            ],
            "decodedSettings": restored.appearance == "dark" && restored.verifyAnswers == true && restored.runningInput == .steer,
            "modelApplied": applied && saved?.model.displayName == renamed.displayName,
            "configuredKeyPreserved": saved?.apiKey == original.apiKey,
            "unrelatedOriginRejected": rejected && agent.providers.first?.profile.baseURL == original.profile.baseURL,
            "credentialsOffByDefault": !agent.cloudSyncPreferences.savedCredentialsEnabled
        ])
    }

    private func exerciseVoiceTurn(_ model: BridgeAppModel, endpoint: URL) async {
        guard let agent = await readyFixtureWorkbench(model), agent.useNativeCommandFixture(endpoint: endpoint),
              let pdf = try? writePDFTextAttachment() else {
            finish(["ready": false]); return
        }
        let owner = agent.attachmentOwnerID
        let staged = agent.stageAttachments([pdf]).map(\.id)
        var rejectedOtherOwner = false
        do { _ = try await agent.runVoiceTurn("Ignored voice source", owner: UUID()) }
        catch { rejectedOtherOwner = true }
        let capture = VoiceCaptureFixture()
        let output = VoicePlaybackFixture()
        let voice = MacVoiceSession(capture: capture, speaker: output)
        var dictation = ""
        var leases = 0
        func admit() -> (() -> Void)? {
            leases += 1
            return { leases -= 1 }
        }
        func waitForListening() async {
            let deadline = ContinuousClock.now + .seconds(5)
            while voice.phase != .listening, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(30))
            }
        }
        voice.start(.dictation, locale: Locale(identifier: "en-US"), admit: admit,
                    compose: { dictation = $0 }, turn: { _ in throw CocoaError(.featureUnsupported) })
        await waitForListening()
        let oldCallback = capture.receive
        capture.receive?(.text("Draft from dictation", final: false))
        voice.finishDictation()
        let finalizedDraft = dictation == "Draft from dictation" && !voice.isActive && leases == 0
        voice.start(.conversation, locale: Locale(identifier: "en-US"), admit: admit,
            compose: { dictation = $0 }, turn: { text in try await agent.runVoiceTurn(text, owner: owner) })
        await waitForListening()
        oldCallback?(.text("Wrong voice generation", final: true))
        let oldFenced = voice.transcript.isEmpty
        capture.receive?(.text("A voice fixture question.", final: false))
        let deadline = ContinuousClock.now + .seconds(10)
        while capture.starts < 3, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
        let continued = capture.starts == 3 && voice.phase == .listening
        voice.stop()
        let runMode = agent.transcriptRuns.last?.conversationMode
        finish(["otherOwnerRejected": rejectedOtherOwner, "ownedAnswer": agent.attachmentOwnerID == owner
            && agent.selectedID == owner && output.played == ["Confirmed fixture response."],
            "chatCeiling": runMode == "chat", "attachmentsPreserved": !staged.isEmpty
                && agent.stagedAttachments.map(\.id) == staged,
            "dictationCommitted": finalizedDraft && dictation == "Draft from dictation",
            "previousRecordingFenced": oldFenced, "continuousListening": continued && leases == 0])
    }

    private final class VoiceCaptureFixture: MacVoiceCapturing {
        var receive: (@MainActor (MacVoiceInputUpdate) -> Void)?
        private(set) var starts = 0
        func start(locale: Locale, receive: @escaping @MainActor (MacVoiceInputUpdate) -> Void) async throws {
            starts += 1
            self.receive = receive
        }
        func finishInput() { receive?(.text("Draft from dictation", final: true)) }
        func cancel() { receive = nil }
    }

    private final class VoicePlaybackFixture: MacVoiceSpeaking {
        private(set) var played: [String] = []
        func speak(_ text: String, locale: Locale) async -> Bool {
            played.append(text)
            return true
        }
        func stop() {}
    }

    private func exerciseLocalModel(_ model: BridgeAppModel, directory: URL) async {
        guard #available(macOS 15.4, *), let agent = await readyFixtureWorkbench(model),
              let entry = CuratedLocalModelCatalog.entries.first,
              agent.useNativeCommandFixture(endpoint: URL(string: "http://127.0.0.1:1/v1")!) else {
            finish(["ready": false]); return
        }
        let store = LocalModelStore(root: directory)
        let runtime = LocalModelRuntime(store: store)
        let provider = LocalProviderAdapter.providerProfile
        let adapter = LocalProviderAdapter(runtime: runtime, store: store)
        let settingsOpened = await exerciseSettingsPage(.localModels, model: model) && model.smokeLocalModelSettingsMounted
        model.closeSettingsWindow()
        let fixture = ModelProfile(id: entry.profileID, providerID: provider.id,
            remoteModelID: entry.id, displayName: entry.displayName,
            limits: .init(contextTokens: 4_096, maxOutputTokens: 256), capabilities: [.text, .tools])
        agent.publishInstalledLocalModels([fixture], provider: provider, adapter: adapter)
        let selected = agent.selectDefaultModel(entry.profileID)
        agent.publishInstalledLocalModels([], provider: provider, adapter: adapter)
        let held = selected && agent.needsLocalModel && agent.composerProvider == nil
            && !agent.send("Keep this prompt on this Mac.", mode: .chat)
        var checks: [String: Any] = ["cloudFallbackPrevented": held, "settingsVisible": settingsOpened]
        do {
            if !(await store.isInstalled(id: entry.id)) { _ = try await store.download(entry) }
            checks["verifiedSnapshot"] = await store.isInstalled(id: entry.id)
            let available = try await adapter.listModels(provider: provider, credentials: .init())
            agent.publishInstalledLocalModels(available, provider: provider, adapter: adapter)
            let picked = agent.selectComposerModel(entry.profileID)
            checks["localPicker"] = picked && agent.composerProvider?.model.id == entry.profileID
                && agent.taskModelProviderProfiles.contains(where: { $0.kind == .local })
            if picked && agent.send("What is 2 + 3? Answer with just the number.", mode: .chat) {
                let deadline = ContinuousClock.now + .seconds(100)
                while agent.activeRunCount > 0 && ContinuousClock.now < deadline {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                let completed = agent.transcriptRuns.last { $0.modelID == entry.profileID }
                checks["inference"] = completed?.state == "completed" && agent.messages.contains {
                    $0.runID == completed?.id && $0.role == "assistant" && $0.content.contains("5")
                }
                if agent.activeRunCount > 0 { agent.stop() }
            }
            await runtime.unload()
        } catch {
            let failure = error as NSError
            checks["failure"] = "\(failure.domain):\(failure.code)"
        }
        finish(checks)
    }

    private func exerciseExtensionTools(_ model: BridgeAppModel, endpoint: URL) async {
        guard let agent = await readyFixtureWorkbench(model), let connector = agent.workbenchConnectors else {
            finish(["ready": false]); return
        }
        do {
            let server = MCPServerConfiguration(displayName: "Fixture connector",
                endpoint: endpoint.deletingLastPathComponent().appendingPathComponent("mcp"),
                allowInsecureHTTP: true)
            try await connector.configure(server: server)
            let live = await connector.testDiscovery()
            await connector.restore()
            guard live.map(\.remoteName) == ["fixture_receipt"], connector.status == .ready(toolCount: 1),
                  let tool = connector.publishedTools.first,
                  agent.startNamedAgentFixture("Obtain the synthetic connector receipt.", modelID: "extension-fixture",
                                               endpoint: endpoint, projectID: nil) else {
                finish(["discovery": false, "diagnostics": String(describing: connector.status)]); return
            }
            let deadline = ContinuousClock.now + .seconds(12)
            var approved = false
            while agent.activeRunCount > 0 && ContinuousClock.now < deadline {
                if !approved, agent.pendingApproval?.toolName == tool.descriptor.name {
                    approved = clickApproval(in: agent, allow: true, screenshot: "connector-approval.png")
                }
                try await Task.sleep(for: .milliseconds(40))
            }
            let called = agent.messages.contains { $0.content == "Connector receipt verified." }
            let events: [RunEventRecord] = agent.transcriptEventsByRun.values.flatMap { $0 }
            let details = events.compactMap { event -> String? in
                switch event.kind {
                case .toolResult, .terminal: return event.payloadJSON
                default: return nil
                }
            }
            if agent.activeRunCount > 0 { agent.stop() }
            try await connector.revoke()
            await connector.restore()
            finish(["discovery": true, "approval": approved, "call": called,
                    "revoked": connector.configuration == nil && connector.publishedTools.isEmpty,
                    "details": details])
        } catch {
            finish(["configured": false, "diagnostics": String(describing: type(of: error))])
        }
    }

    private func exerciseConnectorParity(_ model: BridgeAppModel, endpoint: URL) async {
        guard let agent = await readyFixtureWorkbench(model), let connectors = agent.workbenchConnectors else {
            finish(["ready": false]); return
        }
        let root = endpoint.deletingLastPathComponent()
        let bearer = MCPServerConfiguration(displayName: "Bearer fixture", endpoint: root.appendingPathComponent("mcp-bearer"),
            allowInsecureHTTP: true, authentication: .bearerToken)
        let header = MCPServerConfiguration(displayName: "Header fixture", endpoint: root.appendingPathComponent("mcp-header"),
            allowInsecureHTTP: true, authentication: .customHeader, credentialHeaderName: "X-Floe-Fixture")
        do {
            try await connectors.configure(server: bearer, credential: "fixture-bearer-token")
            try await connectors.configure(server: header, credential: "fixture-header-token")
            guard connectors.servers.count == 2, connectors.publishedTools.count == 2,
                  let first = connectors.toolOrigins.first(where: { $0.value.serverID == bearer.id })?.key,
                  let other = connectors.toolOrigins.first(where: { $0.value.serverID == header.id })?.key,
                  agent.startNamedAgentFixture("Read both synthetic connector receipts.", modelID: "connector-parity-fixture",
                                               endpoint: endpoint, projectID: nil) else {
                finish(["discovery": false]); return
            }
            let deadline = ContinuousClock.now + .seconds(18)
            var remembered = false
            var approvedHeader = false
            while agent.activeRunCount > 0, ContinuousClock.now < deadline {
                if let approval = agent.pendingApproval, approval.toolName == first, !remembered {
                    await agent.resolveApproval(approval, allow: true, remember: nil, rememberScopedTool: .toolTask)
                    remembered = true
                }
                if agent.pendingApproval?.toolName == other, !approvedHeader {
                    approvedHeader = clickApproval(in: agent, allow: true, screenshot: "authenticated-connector.png")
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
            let completed = agent.messages.contains { $0.content == "Both connector receipts verified." }
            let grants = try await MacScopedToolGrants.shared.list()
            let persisted = grants.contains { $0.toolName == first && $0.conversationID == agent.selectedID }
            for grant in grants { try await MacScopedToolGrants.shared.revoke(id: grant.id) }
            let revoked = try await MacScopedToolGrants.shared.list().isEmpty
            if agent.activeRunCount > 0 { agent.stop() }
            try await connectors.setEnabled(false, serverID: header.id)
            let isolated = connectors.toolOrigins[first]?.serverID == bearer.id && connectors.toolOrigins[other] == nil
            try await connectors.remove(serverID: bearer.id)
            try await connectors.remove(serverID: header.id)
            finish(["discovery": true, "bearerApproval": remembered, "headerApproval": approvedHeader,
                    "toolsInvoked": completed, "scopedApprovalPersisted": persisted,
                    "approvalRevoked": revoked, "disabledInIsolation": isolated,
                    "notice": agent.notice ?? "", "runStates": agent.transcriptRuns.map(\.state),
                    "serversRemoved": connectors.servers.isEmpty && connectors.publishedTools.isEmpty])
        } catch {
            finish(["discovery": false, "failure": String(describing: type(of: error))])
        }
    }

    private func verifyTaskPermissionsSheet(_ model: BridgeAppModel) async {
        guard let agent = await readyFixtureWorkbench(model), let window = visibleWorkbench else {
            finish(["ready": false]); return
        }
        func openAndClose(_ screenshot: String) async -> Bool {
            let owner = agent.attachmentOwnerID
            let deadline = ContinuousClock.now + .seconds(3)
            while agent.smokeTaskPermissionsFrame == nil && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(40))
            }
            guard clickWorkbenchButton(ids: ["composer.approvalMode"], frame: agent.smokeTaskPermissionsFrame, screenshot: nil) else {
                return false
            }
            let opening = ContinuousClock.now + .seconds(3)
            while window.attachedSheet == nil && ContinuousClock.now < opening { try? await Task.sleep(for: .milliseconds(40)) }
            guard let sheet = window.attachedSheet, sheet.sheetParent === window, let content = sheet.contentView else {
                return false
            }
            capture(content, extension: screenshot)
            let closed = await closeFixtureSheet(sheet, id: "task.permissions.done")
            return closed && agent.windowShowsTask && agent.attachmentOwnerID == owner
        }

        let draftSheet = await openAndClose("draft-permissions-sheet.png")
        var savedSheet = false
        if await agent.verifyChatSmoke(), let id = agent.selectedID {
            agent.composerMode = .agent
            savedSheet = await openAndClose("saved-task-permissions-sheet.png") && agent.selectedID == id
        }
        agent.composerMode = .chat
        let chat = ContinuousClock.now + .seconds(2)
        while agent.smokeTaskPermissionsFrame != nil && ContinuousClock.now < chat { try? await Task.sleep(for: .milliseconds(40)) }
        finish(["draftSheet": draftSheet, "savedTaskSheet": savedSheet,
                "chatHidesApproval": agent.smokeTaskPermissionsFrame == nil])
    }

    private func exerciseWorkspaceAuthoring(_ model: BridgeAppModel, endpoint: URL) async {
        guard let agent = await readyFixtureWorkbench(model) else { finish(["ready": false]); return }
        let folder = root.appendingPathComponent("Authoring Project", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)) != nil,
              let project = await agent.addWorkspace(name: "Authoring Project", rootURL: folder, selectForNewTask: false),
              agent.startNamedAgentFixture("Prepare the staged authoring output.", modelID: "authoring-fixture",
                                           endpoint: endpoint, projectID: project.id) else {
            finish(["started": false]); return
        }
        var approved = Set<String>()
        let deadline = ContinuousClock.now + .seconds(25)
        while ContinuousClock.now < deadline {
            if let approval = agent.pendingApproval, approval.workspaceID == project.id, approval.canAllow,
               !approved.contains(approval.callID), clickApproval(in: agent, allow: true, screenshot: approval.callID + ".png") {
                approved.insert(approval.callID)
            }
            if !agent.isSending, agent.selectedID != nil { break }
            try? await Task.sleep(for: .milliseconds(35))
        }
        if let id = agent.selectedID { await agent.select(nil); await agent.select(id) }
        let events = agent.transcriptRuns.first.map { agent.transcriptEventsByRun[$0.id, default: []] } ?? []
        let decisions = events.filter { $0.kind == .approval }.compactMap {
            try? JSONDecoder().decode([String: String].self, from: Data($0.payloadJSON.utf8))
        }
        let entitled = Set(decisions.filter { $0["decision"] == "humanAllowed" }.compactMap { $0["callID"] })
        let draft = try? Data(contentsOf: folder.appendingPathComponent("qa/files/draft.txt"))
        let deliverable = try? Data(contentsOf: folder.appendingPathComponent("qa/files/deliverable.md"))
        let expected = Data("\u{feff}old\r\nline changed\r\ntail\r\n".utf8)
        let changes = FloeTaskActivityProjection.changes(runs: agent.transcriptRuns, events: agent.transcriptEventsByRun)
        let diffVerified = changes.compactMap(\.artifact).contains { receipt in
            let diff = try? FloeVerifiedChangeArtifact.verifiedDiff(receipt, floeAgentRoot: agent.runOutputArtifactRoot)
            return diff?.contains("+line changed") == true
        }
        finish(["status": agent.transcriptRuns.first?.state ?? "", "approved": approved.sorted(),
                "durableDecisions": entitled.sorted(), "equalBytes": draft == expected && deliverable == expected,
                "changeDiffVerified": diffVerified,
                "complete": agent.messages.contains(where: {
                    $0.content == "Authoring receipts verified. The append with a stale digest failed and left the file unchanged."
                }),
                "diagnostics": agent.smokeRunDiagnostics + settingsDiagnostics])
    }

    private func exerciseColdRecovery(_ model: BridgeAppModel, endpoint: URL) async {
        let streaming = CommandLine.arguments.contains("--cold-provider")
        let unknown = CommandLine.arguments.contains("--cold-dispatched")
        let expectedState = streaming ? "streamingModel" : unknown ? "executingTool" : "waitingApproval"
        guard let agent = await readyFixtureWorkbench(model) else { finish(["ready": false]); return }
        let folder = root.appendingPathComponent("Cold Recovery Project", isDirectory: true)
        let file = folder.appendingPathComponent("cold-proof.txt")
        if !CommandLine.arguments.contains("--workbench-reopen") {
            guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)) != nil,
                  let project = await agent.addWorkspace(name: "Cold Recovery Project", rootURL: folder, selectForNewTask: false),
                  agent.startNamedAgentFixture("Prepare the cold recovery fixture.", modelID: "recovery-fixture",
                                              endpoint: endpoint, projectID: project.id) else {
                finish(["started": false]); return
            }
            var clicked = false
            let deadline = ContinuousClock.now + .seconds(12)
            while ContinuousClock.now < deadline {
                if !clicked, streaming || unknown, let approval = agent.pendingApproval, approval.workspaceID == project.id {
                    clicked = clickApproval(in: agent, allow: true, screenshot: "cold-initial-approval.png")
                }
                let fileExists = FileManager.default.fileExists(atPath: file.path)
                if let run = await agent.latestRecoveryFixtureRun(), run.state == expectedState,
                   (streaming || unknown ? fileExists && clicked : !fileExists && agent.pendingApproval != nil) {
                    preferences.set(root.path, forKey: Self.recoveryPathKey)
                    let reportFields: [String: Any] = ["parked": true, "pid": getpid(), "state": run.state,
                        "runID": run.id.uuidString, "taskID": run.conversationID.uuidString, "fileExists": fileExists]
                    if let bytes = try? JSONSerialization.data(withJSONObject: reportFields, options: [.prettyPrinted]) {
                        try? bytes.write(to: report, options: .atomic)
                    }
                    return
                }
                try? await Task.sleep(for: .milliseconds(35))
            }
            finish(["parked": false, "clicked": clicked, "diagnostics": agent.smokeRunDiagnostics + settingsDiagnostics])
            return
        }
        guard let task = agent.conversations.first?.id else {
            finish(["reopened": false, "stage": "history"]); return
        }
        let interfaceDeadline = ContinuousClock.now + .seconds(4)
        while MacWorkspaceRootView.smokeTaskCenterFrame == nil && ContinuousClock.now < interfaceDeadline {
            try? await Task.sleep(for: .milliseconds(35))
        }
        guard await openTaskFromCenter(task, agent: agent) else {
            finish(["reopened": false, "stage": "task center", "state": await agent.recoveryFixtureState()]); return
        }
        let routeDeadline = ContinuousClock.now + .seconds(4)
        while agent.continuableRun == nil && ContinuousClock.now < routeDeadline {
            try? await Task.sleep(for: .milliseconds(35))
        }
        guard let original = agent.continuableRun, original.state == expectedState, agent.activeRunCount == 0,
              agent.configureCheckpointFixtureModel(run: original, endpoint: endpoint) else {
            finish(["reopened": false, "stage": "recovery route", "state": await agent.recoveryFixtureState(),
                    "diagnostics": agent.smokeRunDiagnostics + settingsDiagnostics]); return
        }
        let priorUsers = agent.messages.filter { $0.role == "user" }.map(\.id)
        let modification = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let reviewShown = agent.needsInterruptedRunReview
        let savedApprovalShown = agent.restoredApprovalSummary != nil
        guard unknown == reviewShown, agent.resumesOriginalRun == !unknown,
              savedApprovalShown == (!streaming && !unknown),
              clickWorkbenchButton(ids: ["mac.agent.run.continue"], frame: HostAgentWorkspaceView.smokeHistoryContinueFrame,
                                   screenshot: "cold-resume-control.png") else {
            finish(["reopened": true, "rightControl": false, "reviewShown": reviewShown,
                    "savedApprovalShown": savedApprovalShown, "diagnostics": settingsDiagnostics]); return
        }
        var freshDecision = false
        let deadline = ContinuousClock.now + .seconds(14)
        while ContinuousClock.now < deadline {
            if !freshDecision, savedApprovalShown, let approval = agent.pendingApproval,
               approval.path == file.lastPathComponent, approval.workspaceID == agent.selectedConversationWorkspace?.id,
               !FileManager.default.fileExists(atPath: file.path) {
                freshDecision = clickApproval(in: agent, allow: true, screenshot: "cold-fresh-approval.png")
            }
            if !agent.isSending, agent.messages.contains(where: { $0.content == "Cold recovery verified." }) { break }
            try? await Task.sleep(for: .milliseconds(40))
        }
        await agent.select(nil)
        await agent.select(task)
        let latest = agent.transcriptRuns.first
        let sameOriginal = agent.transcriptRuns.map(\.id) == [original.id]
        let activeBranchCorrect = unknown ? latest?.id != original.id
            && agent.transcriptRuns.contains(where: { $0.id == original.id && $0.state == "interrupted" })
            : sameOriginal && agent.messages.filter { $0.role == "user" }.map(\.id) == priorUsers
        let unchanged = modification == (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
        finish(["reopened": true, "originalRunID": original.id.uuidString, "activeBranchCorrect": activeBranchCorrect,
                "state": latest?.state ?? "", "freshDecision": freshDecision, "unchangedExistingFile": unchanged,
                "file": (try? String(contentsOf: file, encoding: .utf8)) ?? "",
                "finished": agent.messages.contains(where: { $0.content == "Cold recovery verified." }),
                "diagnostics": agent.smokeRunDiagnostics + settingsDiagnostics])
    }

    private func exerciseQuestionRecovery(_ model: BridgeAppModel, endpoint: URL) async {
        guard let agent = await readyFixtureWorkbench(model) else { finish(["ready": false]); return }
        let verifiesContinuation = CommandLine.arguments.contains("--continue-checkpoint")
        let verifiesGoal = CommandLine.arguments.contains("--goal-checkpoint-recovery")
        let projectFolder = root.appendingPathComponent("Resume Project", isDirectory: true)
        let savedFile = projectFolder.appendingPathComponent("checkpoint-proof.txt")
        let expectedFile = "Saved before the question.\n"
        if !CommandLine.arguments.contains("--workbench-reopen") {
            var projectID: UUID?
            if verifiesContinuation {
                guard (try? FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: false)) != nil,
                      let project = await agent.addWorkspace(name: "Resume Project", rootURL: projectFolder,
                                                            selectForNewTask: false) else { finish(["project": false]); return }
                projectID = project.id
            }
            guard agent.startNamedAgentFixture("Prepare the project deliverable.", modelID: "recovery-fixture", endpoint: endpoint,
                                               projectID: projectID, mode: verifiesGoal ? .goal : .agent) else {
                finish(["started": false]); return
            }
            let pendingDeadline = ContinuousClock.now + .seconds(12)
            var approved = false
            while agent.pendingQuestion == nil && ContinuousClock.now < pendingDeadline {
                if verifiesContinuation, !approved, let approval = agent.pendingApproval,
                   approval.workspaceID == projectID, approval.path == savedFile.lastPathComponent {
                    approved = clickApproval(in: agent, allow: true, screenshot: "checkpoint-approval.png")
                }
                try? await Task.sleep(for: .milliseconds(50))
            }
            guard let card = agent.pendingQuestion, let question = card.currentQuestion, agent.isSending,
                  !verifiesContinuation || (approved && (try? String(contentsOf: savedFile, encoding: .utf8)) == expectedFile) else {
                finish(["pending": false, "approved": approved, "notice": agent.notice ?? "",
                        "diagnostics": agent.smokeRunDiagnostics]); return
            }
            await agent.saveQuestionDraft(target: card.snapshot.target(for: question), answer: .init(selectedOptionIDs: ["report"]))
            preferences.set(root.path, forKey: Self.recoveryPathKey)
            preferences.synchronize()
            var ready: [String: Any] = ["pending": true, "pid": getpid(), "taskID": card.conversationID.uuidString,
                                        "runID": card.runID.uuidString, "requestID": card.requestID, "approvedFile": approved]
            if verifiesGoal { ready["goalID"] = agent.goal?.id.uuidString }
            if let bytes = try? JSONSerialization.data(withJSONObject: ready, options: [.prettyPrinted]) {
                try? bytes.write(to: report, options: .atomic)
            }
            // The fixture driver terminates the actual process while it is waiting.
            return
        }
        guard let taskID = agent.conversations.first?.id,
              await openTaskFromCenter(taskID, agent: agent) else { finish(["reopenedTask": false]); return }
        let cardDeadline = ContinuousClock.now + .seconds(7)
        while (agent.pendingQuestion == nil || UserQuestionCardView.smokeModel?.currentTarget == nil)
                && ContinuousClock.now < cardDeadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
        guard let card = agent.pendingQuestion, let question = card.currentQuestion else {
            finish(["restoredCard": false, "diagnostics": settingsDiagnostics]); return
        }
        let noResumption = agent.activeRunCount == 0 && !agent.isSending
        let restoredDraft = UserQuestionCardView.smokeModel?.isSelected("report") == true
        let recoveredGoal = agent.goal
        let waitsForGoalAnswer = recoveredGoal.map { !agent.canContinueGoal($0) } ?? false
        let usedVisibleCard = await answerProjectQuestion(in: agent)
        let duplicate = await agent.answerQuestion(target: card.snapshot.target(for: question),
                                                    answer: .init(selectedOptionIDs: ["notes"]))
        await agent.select(nil)
        await agent.select(taskID)
        let receipts = agent.settledQuestions[card.runID]?.filter { $0.requestID == card.requestID } ?? []
        let answer = receipts.first?.questions.first?.answerRecord()
        var result: [String: Any] = ["restoredCard": true, "taskID": taskID.uuidString, "runID": card.runID.uuidString,
                                     "requestID": card.requestID, "restoredDraft": restoredDraft, "usedVisibleCard": usedVisibleCard,
                                     "answeredOnce": !duplicate && receipts.count == 1 && answer?.source == .human
                                         && answer?.selectedOptionIDs == ["report"], "reopenedWithoutRunning": noResumption]
        if verifiesContinuation {
            result["continuedOriginalRun"] = await continueCheckpointFixture(model, agent: agent, runID: card.runID,
                                                                             owner: taskID, endpoint: endpoint, file: savedFile,
                                                                             expectedFile: expectedFile, isGoal: verifiesGoal)
            if result["continuedOriginalRun"] as? Bool == true {
                if verifiesGoal, let recoveredGoal {
                    result["goalID"] = recoveredGoal.id.uuidString
                    result["goalWaitedForAnswer"] = waitsForGoalAnswer
                    result["goalRoundAccountedOnce"] = await verifyRecoveredGoal(agent, id: recoveredGoal.id,
                        taskID: taskID, runID: card.runID)
                }
                result["publishedOutputReopenedAndDeleted"] = await verifyResumedRunOutput(agent, runID: card.runID,
                    taskID: taskID, original: savedFile, expected: expectedFile)
            }
        }
        result["diagnostics"] = settingsDiagnostics + agent.smokeRunDiagnostics
        finish(result)
    }

    private func continueCheckpointFixture(_ model: BridgeAppModel, agent: HostAgentWorkspace, runID: UUID,
                                          owner: UUID, endpoint: URL, file: URL, expectedFile: String,
                                          isGoal: Bool) async -> Bool {
        let candidate = isGoal ? agent.transcriptRuns.first : agent.continuableRun
        guard let run = candidate, run.id == runID, isGoal || agent.resumesOriginalRun,
              agent.configureCheckpointFixtureModel(run: run, endpoint: endpoint),
              let draftStore = model.macWorkspace?.smokeDraftStore,
              let fileDate = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
              let project = agent.selectedConversationWorkspace?.id else {
            settingsDiagnostics.append("Original checkpoint, model or project unavailable in the workbench.")
            return false
        }
        let userMessageIDs = agent.messages.filter { $0.role == "user" }.map(\.id)
        let draft = "Unsent follow-up for this exact task."
        draftStore.setText(draft, for: owner)
        let clicked = if isGoal {
            clickWorkbenchButton(ids: ["mac.agent.goal.continue"], frame: HostAgentWorkspaceView.smokeGoalContinueFrame,
                                 screenshot: "goal-continue.png")
        } else {
            clickWorkbenchButton(ids: ["mac.agent.run.continue"], frame: HostAgentWorkspaceView.smokeHistoryContinueFrame,
                                 screenshot: "checkpoint-continue.png")
        }
        guard clicked else {
            settingsDiagnostics.append("Continue Task was unavailable in the active window.")
            return false
        }
        let deadline = ContinuousClock.now + .seconds(12)
        while ContinuousClock.now < deadline {
            if !agent.isSending, agent.messages.contains(where: { $0.runID == runID && $0.content == "Original task continued." }) { break }
            if agent.pendingApproval?.toolName == WorkspaceOutputPublication.name,
               agent.pendingApproval?.path == file.lastPathComponent {
                _ = clickApproval(in: agent, allow: true, screenshot: "checkpoint-publication-approval.png")
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return !agent.isSending && agent.notice == nil && userMessageIDs.count == 1 && agent.selectedID == owner
            && agent.selectedConversationWorkspace?.id == project && agent.transcriptRuns.map(\.id) == [runID]
            && agent.transcriptRuns.first?.state == "completed"
            && agent.messages.filter { $0.role == "user" }.map(\.id) == userMessageIDs
            && agent.messages.contains { $0.runID == runID && $0.content == "Original task continued." }
            && draftStore.text(for: owner) == draft && (try? String(contentsOf: file, encoding: .utf8)) == expectedFile
            && (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) == fileDate
    }

    private func verifyRecoveredGoal(_ agent: HostAgentWorkspace, id: UUID, taskID: UUID, runID: UUID) async -> Bool {
        await agent.select(nil)
        await agent.select(taskID)
        guard let goal = agent.goal, goal.id == id, goal.status == .verifying,
              agent.transcriptRuns.first?.goalID == id, agent.transcriptRuns.first?.id == runID,
              goal.progress.cycleCount == 1, goal.progress.modelCallCount == 7,
              goal.progress.totalIterationCount == 5,
              goal.evidence.contains(where: { $0.kind == .toolResult && $0.reference.hasPrefix("run:\(runID.uuidString):") }),
              Set(goal.evidence.map(\.reference)).count == goal.evidence.count else {
            settingsDiagnostics.append("The resumed Goal did not retain its identity, evidence and once-only cycle accounting.")
            return false
        }
        await agent.confirmGoal(goal, completedSteps: Set(goal.steps.map(\.id)),
                                confirmedCriteria: Set(goal.acceptanceCriteria.map(\.id)))
        return agent.goal?.id == id && agent.goal?.status == .completed
    }

    private func exerciseGoalEvidence(_ model: BridgeAppModel, endpoint: URL, blocker: Bool) async {
        guard let agent = await readyFixtureWorkbench(model) else { finish(["ready": false]); return }
        let folder = root.appendingPathComponent("Goal Evidence Project", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)) != nil,
              let project = await agent.addWorkspace(name: "Goal Evidence Project", rootURL: folder, selectForNewTask: false),
              agent.startNamedAgentFixture(blocker ? "Read the required receipt before writing the fixture report."
                                                    : "Create and verify the two fixture deliverables.", modelID: "goal-evidence-fixture",
                                           endpoint: endpoint, projectID: project.id, mode: .goal) else {
            finish(["started": false]); return
        }
        var clicked = Set<String>()
        let deadline = ContinuousClock.now + .seconds(24)
        while ContinuousClock.now < deadline {
            if let approval = agent.pendingApproval, let path = approval.path, !clicked.contains(path),
               approval.workspaceID == project.id, clickApproval(in: agent, allow: true, screenshot: "goal-" + path + ".png") {
                clicked.insert(path)
            }
            if !agent.isSending, agent.goal?.status == .completed { break }
            if blocker, !agent.isSending, let status = agent.goal?.status, [.blocked, .verifying].contains(status) { break }
            try? await Task.sleep(for: .milliseconds(35))
        }
        if let id = agent.selectedID { await agent.select(nil); await agent.select(id) }
        let goal = agent.goal
        if blocker {
            finish(["state": goal?.status.rawValue ?? "",
                    "blocker": goal.flatMap { GoalEvidenceReviewContract.blockerExplanation(for: $0) } ?? "",
                    "oneRound": agent.transcriptRuns.count == 1 && agent.transcriptRuns.first?.state == "completed",
                    "noCompletionClaim": goal?.acceptanceCriteria.allSatisfy { !$0.isSatisfied } ?? false,
                    "noUserDefinedBlockers": goal?.blockingConditions?.isEmpty != false,
                    "diagnostics": agent.smokeRunDiagnostics + settingsDiagnostics])
            return
        }
        finish(["state": goal?.status.rawValue ?? "", "cycles": goal?.progress.cycleCount ?? -1,
                "calls": goal?.progress.modelCallCount ?? -1, "approvals": clicked.sorted(),
                "distinctGoalRounds": agent.transcriptRuns.count == 2 && agent.transcriptRuns.allSatisfy {
                    $0.state == "completed" && $0.goalID == goal?.id
                },
                "criteriaHaveProof": goal?.acceptanceCriteria.allSatisfy { $0.isSatisfied && !$0.evidenceIDs.isEmpty } ?? false,
                "firstFile": (try? String(contentsOf: folder.appendingPathComponent("first-proof.txt"), encoding: .utf8)) ?? "",
                "secondFile": (try? String(contentsOf: folder.appendingPathComponent("second-proof.txt"), encoding: .utf8)) ?? "",
                "diagnostics": agent.smokeRunDiagnostics + settingsDiagnostics])
    }

    private func exerciseGoalControls(_ model: BridgeAppModel) async {
        model.openAgentWorkspace()
        guard let agent = model.macWorkspace?.agent else { finish(["opened": false]); return }
        await agent.prepare()
        let deadline = ContinuousClock.now + .seconds(8)
        while !agent.isReady && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(40)) }
        let projectFolder = root.appendingPathComponent("Goal Project", isDirectory: true)
        guard agent.isReady, (try? FileManager.default.createDirectory(at: projectFolder, withIntermediateDirectories: false)) != nil,
              (try? "Goal evidence fixture.\n".write(to: projectFolder.appendingPathComponent("fixture.md"),
                                                    atomically: true, encoding: .utf8)) != nil,
              let project = await agent.addWorkspace(name: "Goal Project", rootURL: projectFolder) else {
            finish(["goalProject": false]); return
        }
        let planning = await agent.verifyPlanningSmoke(project: project)
        let controls = planning.goalSaved ? await agent.verifyGoalControlsSmoke() : false
        finish(["planAccepted": planning.planSaved, "goalSaved": planning.goalSaved, "goalControls": controls,
                "diagnostics": agent.smokeRunDiagnostics])
    }

    private func verifyResumedRunOutput(_ agent: HostAgentWorkspace, runID: UUID, taskID: UUID,
                                        original: URL, expected: String) async -> Bool {
        await agent.select(nil)
        await agent.select(taskID)
        let outputs = (agent.transcriptEventsByRun[runID] ?? []).filter { $0.kind == .toolResult }.flatMap { event in
            let payload = ThreadEventPayload.decode(event.payloadJSON)
            guard payload["tool"] == WorkspaceOutputPublication.name, let encoded = payload["outputFilesJSON"] else {
                return [RunOutputFile]()
            }
            let receipts = (try? JSONDecoder().decode([RunOutputFile].self, from: Data(encoded.utf8))) ?? []
            return RunOutputReceiptGate.accepted(receipts, in: .init(runID: runID, conversationID: taskID,
                callID: payload["id"], toolName: payload["tool"]))
        }
        guard outputs.count == 1, let receipt = outputs.first,
              case .verified(let snapshot) = RunOutputSnapshotStore.verify(receipt, artifactRoot: agent.runOutputArtifactRoot),
              (try? "Edited after publication.\n".write(to: original, atomically: true, encoding: .utf8)) != nil,
              (try? String(contentsOf: snapshot, encoding: .utf8)) == expected else {
            settingsDiagnostics.append("The stored publication receipt or immutable snapshot was unavailable.")
            return false
        }
        let limit = ContinuousClock.now + .seconds(5)
        while visibleWorkbench?.attachedSheet == nil && ContinuousClock.now < limit {
            _ = clickWorkbenchButton(ids: ["chat.runOutput.preview"], frame: RunOutputFileView.smokePreviewFrames[receipt.outputID], screenshot: nil)
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let sheet = visibleWorkbench?.attachedSheet, let body = sheet.contentView,
              descendant(QLPreviewView.self, in: body)?.previewItem?.previewItemURL?.standardizedFileURL == snapshot.standardizedFileURL else {
            settingsDiagnostics.append("The retained file card did not open the verified snapshot.")
            return false
        }
        capture(body, extension: "run-output-preview.png")
        guard await closeFixtureSheet(sheet, id: "chat.runOutput.preview.done"),
              await agent.changeConversationMetadata(id: taskID, change: .delete) else { return false }
        return !FileManager.default.fileExists(atPath: snapshot.path)
            && (try? String(contentsOf: original, encoding: .utf8)) == "Edited after publication.\n"
    }

    private func openTaskFromCenter(_ taskID: UUID, agent: HostAgentWorkspace) async -> Bool {
        MacWorkspaceTaskCenter.smokeResultFrames.removeAll()
        guard clickWorkbenchButton(ids: ["workspace.taskCenter"], frame: MacWorkspaceRootView.smokeTaskCenterFrame,
                                   screenshot: nil) else { return false }
        let deadline = ContinuousClock.now + .seconds(4)
        while MacWorkspaceTaskCenter.smokeResultFrames[taskID] == nil && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
        guard clickWorkbenchButton(ids: ["workspace.task.open.\(taskID.uuidString)"],
                                   frame: MacWorkspaceTaskCenter.smokeResultFrames[taskID], screenshot: nil) else { return false }
        while agent.selectedID != taskID && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
        return agent.selectedID == taskID
    }

    private func exerciseTranscriptParity(_ model: BridgeAppModel) async {
        model.openAgentWorkspace()
        guard let agent = model.macWorkspace?.agent else { finish(["opened": false]); return }
        await agent.prepare()
        let deadline = ContinuousClock.now + .seconds(6)
        while !agent.isReady && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
        guard await agent.verifyChatSmoke(), let id = agent.selectedID else { finish(["savedChat": false]); return }
        await agent.select(id)
        let items = ThreadTimelineBuilder.buildConversation(messages: agent.messages, runs: agent.transcriptRuns,
            eventsByRun: agent.transcriptEventsByRun, liveRunID: nil, isRunning: false,
            liveStreamedText: "", liveReasoningText: "", pendingApprovals: [])
        let prompts = items.indices.filter { if case .userMessage = items[$0] { true } else { false } }
        let answers = items.indices.filter { if case .assistantMessage = items[$0] { true } else { false } }
        let terminals = items.indices.filter { if case .terminal = items[$0] { true } else { false } }
        let savedOrder = prompts.count == 1 && answers.count == 1 && terminals.count == 1
            && prompts[0] < answers[0] && answers[0] < terminals[0]
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let legacyQuestion = PersistedMessage(id: UUID(), conversationID: id, role: "user",
                                              content: "Legacy question", createdAt: timestamp)
        let legacyReply = PersistedMessage(id: UUID(), conversationID: id, role: "assistant",
                                           content: "Legacy reply", createdAt: timestamp.addingTimeInterval(2))
        let legacyRuns = [0.0, 1.0].map { offset in
            RunRecord(id: UUID(), conversationID: id, state: "completed", goal: legacyQuestion.content,
                      startedAt: timestamp.addingTimeInterval(offset), endedAt: timestamp.addingTimeInterval(3))
        }
        let legacy = ThreadTimelineBuilder.buildConversation(messages: [legacyQuestion, legacyReply], runs: legacyRuns,
            eventsByRun: [:], liveRunID: nil, isRunning: false, liveStreamedText: "", liveReasoningText: "", pendingApprovals: [])
        let legacyQuestions = legacy.filter { if case .userMessage(let message) = $0 { message.id == legacyQuestion.id } else { false } }
        let legacyReplies = legacy.filter {
            if case .assistantMessage(_, let suffix, _) = $0 { suffix == legacyReply.id.uuidString } else { false }
        }
        let history: Bool
        if let pdf = try? writePDFTextAttachment() { history = await agent.verifyConversationHistorySmoke(reference: pdf) }
        else { history = false }
        var foundEarlierMessage = false
        if history, let first = try? await agent.transcript(conversationID: id).first {
            foundEarlierMessage = await openSearchResult(query: "\"Fixture earlier message 0\"",
                conversationID: id, messageID: first.id, workspace: agent)
        }
        if let content = visibleWorkbench?.contentView { capture(content, extension: "shared-transcript.png") }
        let projectRoot = root.appendingPathComponent("Transcript Approvals", isDirectory: true)
        var approvals = (allowed: false, denied: false)
        var pressed = Set<Bool>()
        if (try? FileManager.default.createDirectory(at: projectRoot, withIntermediateDirectories: false)) != nil,
           let project = await agent.addWorkspace(name: "Transcript Approvals", rootURL: projectRoot, selectForNewTask: false),
           await openNewTaskFromSidebar(workspace: agent) {
            approvals = await agent.verifyAgentApprovalSmoke(project: project, checkingFile: projectRoot) { allow in
                let image = allow ? "transcript-approve.png" : "transcript-deny.png"
                guard clickApproval(in: agent, allow: allow, screenshot: image) else { return false }
                pressed.insert(allow)
                return true
            }
        }
        finish(["orderedSingleAnswer": savedOrder, "legacyRowsClaimedOnce": legacyQuestions.count == 1 && legacyReplies.count == 1,
                "historyPagingAndExactSearch": history,
                "openedEarlierMessageFromTaskCenter": foundEarlierMessage,
                "approvalButtonsReached": pressed == [true, false],
                "approvalRespected": approvals.allowed && approvals.denied,
                "diagnostics": agent.smokeRunDiagnostics + settingsDiagnostics])
    }

    private func exerciseOfficialCatalog(_ model: BridgeAppModel) async {
        model.openAgentWorkspace()
        guard let agent = model.macWorkspace?.agent, let catalogs = agent.officialCatalogs else {
            finish(["opened": false]); return
        }
        do {
            let bytes = try await catalogs.refresh(.models) { _ = try ProviderCatalogIndex.validated(from: $0) }
            let effective = try bytes.map(ProviderCatalogIndex.validated(from:)) ?? ProviderCatalogIndex.loadBundled()
            let stored = try await catalogs.active(.models)
            try await agent.webSearch.refreshCatalog()
            let modelsFound = effective?.search(query: "DeepSeek", filter: .available, configuredPresetIDs: []).isEmpty == false
            let pickerOpened = await openFixtureSupplierPicker(model, workspace: agent)
            finish(["signedModelCatalog": bytes != nil, "catalogPersisted": bytes != nil && stored == bytes,
                    "modelSearch": modelsFound, "supplierPickerOpenedFromSettings": pickerOpened,
                    "signedWebSearchCheck": true, "webSearchMatches": agent.webSearch.search("Google", language: "en").count,
                    "diagnostics": settingsDiagnostics])
        } catch {
            finish(["signedModelCatalog": false, "error": String(describing: error)])
        }
    }

    private func openFixtureSupplierPicker(_ model: BridgeAppModel, workspace: HostAgentWorkspace) async -> Bool {
        await workspace.prepare()
        let ready = ContinuousClock.now + .seconds(4)
        while !workspace.isReady && ContinuousClock.now < ready { try? await Task.sleep(for: .milliseconds(40)) }
        guard workspace.addProvider(name: "Catalog Fixture", endpoint: "https://example.invalid/v1",
                                    protocolKind: .openAIChatCompletions, modelID: "fixture", key: ""),
              let account = workspace.accounts.first(where: { $0.name == "Catalog Fixture" }) else { return false }
        model.openSettings(.models)
        defer { model.closeSettingsWindow() }
        let accountKey = "\(ProviderCatalogServiceRole.conversation.rawValue).\(account.id.uuidString)"
        let accountID = "settings.providers.account." + accountKey
        let deadline = ContinuousClock.now + .seconds(5)
        var openedAccount = false
        var openedPicker = false
        func press(_ content: NSView, in window: NSWindow, id: String, frame: CGRect?) -> Bool {
            if pressAccessibilityButton(content, id: id) { return true }
            guard let frame, !frame.isEmpty else { return false }
            let point = NSPoint(x: frame.midX, y: frame.midY)
            return content.bounds.contains(content.convert(point, from: nil)) && clickWindowLocation(point, in: window)
        }
        while ContinuousClock.now < deadline {
            if let window = model.smokeAgentSettingsSheet {
                if let content = window.contentView, !openedPicker {
                    content.layoutSubtreeIfNeeded()
                    refreshButtonFrames(in: content)
                    if !openedAccount {
                        openedAccount = press(content, in: window, id: accountID,
                            frame: MacProviderSettingsView.smokeAccountFrames[accountKey])
                    }
                    if openedAccount {
                        openedPicker = press(content, in: window, id: "settings.providers.preset",
                            frame: MacProviderSettingsView.smokeSupplierFrame)
                    }
                }
                if openedPicker && MacProviderSettingsView.smokeSupplierPickerMounted {
                    for pickerWindow in [window.attachedSheet, window] + NSApp.windows.filter(\.isVisible).map(Optional.some) {
                        guard let content = pickerWindow?.contentView,
                              accessibilityElement(content, id: "providers.catalog.search") != nil else { continue }
                        capture(content, extension: "supplier-picker.png")
                        _ = pressAccessibilityButton(content, id: "providers.catalog.cancel")
                        return true
                    }
                    for surface in NSApp.windows where surface.isVisible {
                        if let content = surface.contentView {
                            capture(content, extension: "supplier-picker-\(surface.windowNumber).png")
                        }
                    }
                    return true
                }
            }
            try? await Task.sleep(for: .milliseconds(40))
        }
        settingsDiagnostics.append("Supplier fixture: settings=\(model.smokeAgentSettingsSheet != nil), account=\(openedAccount), picker=\(openedPicker), mounted=\(MacProviderSettingsView.smokeSupplierPickerMounted).")
        return false
    }

    private func exerciseConcurrentDrafts(_ model: BridgeAppModel, endpoint: URL) async {
        model.openAgentWorkspace()
        guard let workspace = model.macWorkspace, let agent = workspace.agent, let drafts = workspace.smokeDraftStore else {
            finish(["opened": false]); return
        }
        await agent.prepare()
        let ready = ContinuousClock.now + .seconds(8)
        while !agent.isReady && ContinuousClock.now < ready { try? await Task.sleep(for: .milliseconds(50)) }
        guard agent.addProvider(name: "Draft Fixture", endpoint: endpoint.absoluteString,
                                protocolKind: .openAIChatCompletions, modelID: "draft-stream",
                                key: "", allowsPlainHTTP: true),
              agent.selectNewDraft(in: nil) else { finish(["configured": false]); return }
        let first = agent.uncommittedDraftID
        let firstRoot = agent.fileWorkspaceForCurrentTask
        let stableDraftScope = firstRoot?.id == first && firstRoot == agent.fileWorkspaceForCurrentTask
        let promptA = "First independent stream"
        let promptB = "Second independent stream"
        drafts.setText(promptA, for: first)
        let firstSent = agent.send(promptA, mode: .chat, onAdmitted: drafts.captureSendCommit(for: first))
        // No suspension before opening the next composer. This hits the
        // first-send race before the first durable conversation exists.
        let secondOpened = agent.selectNewDraft(in: nil) && !agent.isSending
        let second = agent.uncommittedDraftID
        drafts.setText(promptB, for: second)
        let secondSent = agent.send(promptB, mode: .chat, onAdmitted: drafts.captureSendCommit(for: second))
        let repeatedDraft = UUID()
        drafts.setText(promptA, for: repeatedDraft)
        let oldCommit = drafts.captureSendCommit(for: repeatedDraft)
        drafts.setText(promptB, for: repeatedDraft)
        drafts.setText(promptA, for: repeatedDraft)
        oldCommit()
        let retypedDraftPreserved = drafts.text(for: repeatedDraft) == promptA
        drafts.captureSendCommit(for: repeatedDraft)()
        let visible = ContinuousClock.now + .seconds(6)
        while agent.selectedID != second && ContinuousClock.now < visible { try? await Task.sleep(for: .milliseconds(50)) }
        let concurrentlyRunning = agent.isTaskRunning(first) && agent.isTaskRunning(second)
        let usesSidebar = CommandLine.arguments.contains("--verify-sidebar-new-task")
        let newTask = if usesSidebar { await openNewTaskFromSidebar(workspace: agent) }
            else { await performMenuShortcut("n", title: String(localized: "workbench.new_task")) }
        let draft = ContinuousClock.now + .seconds(2)
        while agent.selectedID != nil && ContinuousClock.now < draft { try? await Task.sleep(for: .milliseconds(30)) }
        let third = agent.uncommittedDraftID
        let thirdUsable = newTask && agent.selectedID == nil && !agent.isSending && third != first && third != second
        let unsent = "Keep this unsent draft"
        drafts.setText(unsent, for: third)
        let done = ContinuousClock.now + .seconds(18)
        while agent.activeRunCount != 0 && ContinuousClock.now < done { try? await Task.sleep(for: .milliseconds(50)) }
        let staysOnDraft = agent.selectedID == nil && third == agent.uncommittedDraftID && drafts.text(for: third) == unsent
        let firstUnused = drafts.text(for: first).isEmpty
        let secondUnused = drafts.text(for: second).isEmpty
        let thirdRoot = agent.defaultConversationsDirectory?.appendingPathComponent(third.uuidString, isDirectory: true)
        let hiddenFilesStayedIdle = thirdRoot.map { !FileManager.default.fileExists(atPath: $0.path) } ?? false
        let filesShortcut = await performMenuShortcut("0", title: String(localized: "mac.workspace.toggleFiles"),
                                                      modifiers: [.command, .option])
        let filesDeadline = ContinuousClock.now + .seconds(3)
        var openedOwnFiles = false
        while filesShortcut, ContinuousClock.now < filesDeadline {
            if agent.smokeInspectorShown, let thirdRoot,
               (try? thirdRoot.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
                openedOwnFiles = true
                break
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
        await agent.select(first)
        let firstSaved = agent.messages.contains { $0.role == "user" && $0.content == promptA }
            && !agent.messages.contains { $0.role == "user" && $0.content == promptB }
        await agent.select(second)
        let secondSaved = agent.messages.contains { $0.role == "user" && $0.content == promptB }
            && !agent.messages.contains { $0.role == "user" && $0.content == promptA }
        var results: [String: Any] = ["firstSent": firstSent, "secondOpenedBeforeAdmission": secondOpened && first != second,
                "secondSent": secondSent, "concurrentStreams": concurrentlyRunning,
                "draftAfterStreams": staysOnDraft, "separateSavedMessages": firstSaved && secondSaved && firstUnused && secondUnused,
                "stableDraftScope": stableDraftScope, "hiddenFilesStayedIdle": hiddenFilesStayedIdle, "openedOwnFiles": openedOwnFiles,
                "retypedDraftPreserved": retypedDraftPreserved && drafts.text(for: repeatedDraft).isEmpty]
        if usesSidebar { results["newTaskFromSidebar"] = thirdUsable }
        else {
            results["newTaskFromMenu"] = thirdUsable
            results["batchArchive"] = await exerciseBatchArchive(agent, ids: [first, second])
        }
        results["diagnostics"] = settingsDiagnostics
        finish(results)
    }

    private func exerciseBatchArchive(_ agent: HostAgentWorkspace, ids: Set<UUID>) async -> Bool {
        guard clickWorkbenchButton(ids: ["workspace.taskCenter"], frame: MacWorkspaceRootView.smokeTaskCenterFrame,
                                   screenshot: "before-task-center.png") else { return false }
        for archive in [true, false] {
            MacWorkspaceTaskCenter.smokeSelectionFrame = nil
            MacWorkspaceTaskCenter.smokeApplySelectionFrame = nil
            agent.taskCenterShowsArchived = !archive
            // Let the segmented filter finish replacing the list and reset
            // the preceding selection before pressing the new Select button.
            try? await Task.sleep(for: .milliseconds(300))
            let limit = ContinuousClock.now + .seconds(3)
            var selected = false
            while !selected && ContinuousClock.now < limit {
                selected = clickWorkbenchButton(ids: ["workspace.task.batch.select"],
                                               frame: MacWorkspaceTaskCenter.smokeSelectionFrame, screenshot: nil)
                if !selected { try? await Task.sleep(for: .milliseconds(40)) }
            }
            guard selected else { return false }
            let controlsReady = ContinuousClock.now + .seconds(2)
            while MacWorkspaceTaskCenter.smokeApplySelectionFrame == nil && ContinuousClock.now < controlsReady {
                if let content = visibleWorkbench?.contentView {
                    content.layoutSubtreeIfNeeded()
                    refreshButtonFrames(in: content)
                }
                try? await Task.sleep(for: .milliseconds(40))
            }
            guard MacWorkspaceTaskCenter.smokeApplySelectionFrame != nil else { return false }
            for id in ids {
                guard clickWorkbenchButton(ids: ["workspace.task.open." + id.uuidString],
                                           frame: MacWorkspaceTaskCenter.smokeResultFrames[id], screenshot: nil) else { return false }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard clickWorkbenchButton(ids: ["workspace.task.batch.apply"], frame: MacWorkspaceTaskCenter.smokeApplySelectionFrame,
                                       screenshot: archive ? "archive-selection.png" : "restore-selection.png") else { return false }
            let deadline = ContinuousClock.now + .seconds(4)
            func updated() -> Bool {
                ids.isSubset(of: Set(agent.conversations.filter { ($0.archivedAt != nil) == archive }.map(\.id)))
            }
            while !updated() && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(50)) }
            guard updated() else { return false }
        }
        return true
    }

    private func exerciseProviderRejection(_ model: BridgeAppModel, endpoint: URL) async {
        model.openAgentWorkspace()
        guard let agent = model.macWorkspace?.agent else { finish(["opened": false]); return }
        await agent.prepare()
        let ready = ContinuousClock.now + .seconds(8)
        while !agent.isReady && ContinuousClock.now < ready { try? await Task.sleep(for: .milliseconds(50)) }
        let accounts = await agent.verifyProviderAccountsSmoke()
        let prompt = "Check the saved test message."
        guard agent.addProvider(name: "Rejection Fixture", endpoint: endpoint.absoluteString,
                                protocolKind: .openAIChatCompletions, modelID: "model-unavailable",
                                key: "synthetic-rejection-token", allowsPlainHTTP: true),
              agent.selectNewDraft(in: nil), agent.send(prompt, mode: .chat) else {
            finish(["sent": false, "accounts": accounts]); return
        }
        let done = ContinuousClock.now + .seconds(12)
        while agent.isSending && ContinuousClock.now < done { try? await Task.sleep(for: .milliseconds(50)) }
        let stored = agent.messages.contains { $0.role == "user" && $0.content == prompt }
        let before = agent.notice
        let displayed = agent.showsModelSettingsForFailure && before == MacPermissionsText.t(
            "供应商找不到模型或接口。请检查接口地址、协议和模型 ID。",
            "The provider could not find the model or endpoint. Check the endpoint, protocol and model ID.")
        if let id = agent.selectedID { await agent.select(id) }
        finish(["accounts": accounts, "userMessagePersisted": stored, "providerErrorDisplayed": displayed,
                "providerErrorAfterReopen": displayed && before == agent.notice && agent.showsModelSettingsForFailure,
                "noRawResponse": agent.notice?.contains("synthetic-rejection-token") == false,
                "continuedFromHistoryAvailable": agent.continuableRun != nil])
    }

    private func exerciseArkProvider(_ model: BridgeAppModel) async {
        // In-memory test account in the isolated smoke store. The supplied
        // key is used only for the selected official Ark HTTPS route.
        guard let key = ProcessInfo.processInfo.environment["FLOE_MAC_QA_ARK_KEY"],
              !key.isEmpty else { finish(["configured": false]); return }
        let plan = CommandLine.arguments.contains("--ark-agent-plan")
        let preset: ProviderPreset = plan ? .volcengineAgentPlan : .volcengineArk
        let remoteID = plan ? "ark-code-latest" : "doubao-seed-2-1-lite-260915"
        model.openAgentWorkspace()
        guard let agent = model.macWorkspace?.agent else { finish(["opened": false]); return }
        await agent.prepare()
        let ready = ContinuousClock.now + .seconds(8)
        while !agent.isReady && ContinuousClock.now < ready { try? await Task.sleep(for: .milliseconds(50)) }
        let endpoint = preset.defaultBaseURL.absoluteString
        guard agent.addProvider(name: "Ark QA", endpoint: endpoint, protocolKind: preset.defaultProtocol,
                                modelID: remoteID, key: key, supportsTools: true, presetID: preset.id.rawValue,
                                limits: .init(contextTokens: 32_768, maxOutputTokens: 2_048)) else {
            finish(["configured": false, "ready": agent.isReady]); return
        }

        var checks: [String: Bool] = [:]
        if !plan {
            agent.requestModelDiscovery(endpoint: endpoint, protocolKind: preset.defaultProtocol, apiKey: key,
                                       debounce: false, presetID: preset.id)
            let listed = ContinuousClock.now + .seconds(25)
            while ContinuousClock.now < listed {
                if case .succeeded = agent.modelDiscoveryState { break }
                if case .failed = agent.modelDiscoveryState { break }
                try? await Task.sleep(for: .milliseconds(50))
            }
            checks["remoteList"] = agent.discoveredModels.contains { $0.remoteModelID == remoteID }
        }
        var failures: [[String: Any]] = []
        for (mode, prompt, expected) in [
            (HostAgentMode.agent, "Calculate 19 + 23. Reply with QA_TOTAL= followed by the number. No other work is needed.", "QA_TOTAL=42"),
            (HostAgentMode.chat, "Reply with QA_CHAT= followed by the result of 17 + 8.", "QA_CHAT=25"),
        ] {
            let eventsStart = agent.smokeRunDiagnostics.count
            guard agent.selectNewDraft(in: nil), agent.send(prompt, mode: mode) else {
                checks[mode.rawValue] = false
                continue
            }
            let until = ContinuousClock.now + .seconds(105)
            while agent.isSending && ContinuousClock.now < until { try? await Task.sleep(for: .milliseconds(60)) }
            checks[mode.rawValue] = !agent.isSending && agent.messages.contains {
                $0.role == "assistant" && $0.content.replacingOccurrences(of: " ", with: "").contains(expected)
            }
            if checks[mode.rawValue] == false {
                if agent.isSending { agent.stop() }
                failures.append(contentsOf: agent.smokeRunDiagnostics.dropFirst(eventsStart).compactMap {
                    guard let payload = try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] else { return nil }
                    return payload.filter { ["kind", "status", "httpStatus", "state", "outcome"].contains($0.key) }
                }.filter { !$0.isEmpty })
            }
        }
        finish(["checks": checks, "model": remoteID, "failures": failures])
    }

    private func exerciseNativeCommands(_ model: BridgeAppModel, endpoint: URL) async {
        var checks: [String: Bool] = [:]
        guard let agent = model.macWorkspace?.agent else { finish(["error": "Missing Agent"]); return }
        await agent.prepare()
        let deadline = ContinuousClock.now + .seconds(8)
        while agent.isPreparing && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(30)) }
        guard agent.isReady, agent.useNativeCommandFixture(endpoint: endpoint) else {
            finish(["error": "Test provider unavailable", "ready": agent.isReady,
                    "storage": agent.storageErrorKind ?? "", "notice": agent.notice ?? ""]); return
        }
        // The only host-scoped file touched by the test sits inside its private fixture directory.
        let outside = root.appendingPathComponent("approval-fixture.txt")
        func taskRoot() -> URL? {
            guard let record = agent.fileWorkspaceForCurrentTask else { return nil }
            if record.kind == .privateTask {
                return try? MacAgentWorkspaceTools.resolvePrivateTaskRoot(record, base: agent.personalTaskLeaseBase)
            }
            var stale = false
            return try? URL(resolvingBookmarkData: record.rootBookmark, options: [.withoutUI], relativeTo: nil,
                            bookmarkDataIsStale: &stale)
        }
        func run(_ scenario: String, decide: Bool? = nil, requireCard: Bool = false) async -> Bool {
            let prompt = "Native fixture " + scenario + "\nHost fixture: " + outside.path
            guard agent.send(prompt, mode: agent.composerMode) else { return false }
            let end = ContinuousClock.now + .seconds(15)
            var approvedCalls = Set<String>()
            while agent.isSending && ContinuousClock.now < end {
                if let approval = agent.pendingApproval, approvedCalls.insert(approval.callID).inserted {
                    guard let decide, approval.toolName == "exec.shell" else { agent.stop(); return false }
                    if scenario == "deny" {
                        let changed = await agent.setApprovalMode(.ask, asDefault: false)
                        checks["changeApprovalWhileWaiting"] = changed && agent.taskApprovalMode == .ask
                            && agent.pendingApproval == approval && !FileManager.default.fileExists(atPath: outside.path)
                    }
                    await agent.resolveApproval(approval, allow: decide)
                }
                try? await Task.sleep(for: .milliseconds(30))
            }
            return !agent.isSending && (!requireCard || !approvedCalls.isEmpty)
                && agent.messages.contains { $0.role == "assistant" && $0.content.contains("finished-" + scenario) }
        }
        checks["commandRiskLevels"] = MacNativeCommandPolicy.commandRisk("pwd") == .low
            && MacNativeCommandPolicy.commandRisk("printf from-mac > result.txt") == .medium
            && MacNativeCommandPolicy.commandRisk("rm result.txt") == .high
            && MacNativeCommandPolicy.commandRisk("cat .env") == .high
            && MacNativeCommandPolicy.commandRisk("ls; whoami") == .high
        checks["agentDefault"] = agent.composerMode == .agent && agent.selectedWorkspaceID == nil
        let draftRoot = taskRoot()
        checks["nativeCommand"] = await run("native")
        let firstID = agent.selectedID
        let firstRoot = taskRoot()
        checks["draftRootPreserved"] = draftRoot != nil && firstRoot?.standardizedFileURL == draftRoot?.standardizedFileURL
        checks["write"] = await run("write", decide: true)
        checks["savedOutput"] = firstRoot.flatMap { try? String(contentsOf: $0.appendingPathComponent("result.txt"), encoding: .utf8) } == "from-mac"
        var revealed: String?
        let output = HostAgentToolActivity(id: "fixture-output", toolName: "exec.shell", state: "completed",
            outputPath: "result.txt", outputWorkspaceID: agent.selectedConversationWorkspace?.id)
        agent.withOutputFile(output) { revealed = try? String(contentsOf: $0, encoding: .utf8) }
        checks["openOutput"] = revealed == "from-mac"
        checks["automaticMode"] = await agent.setApprovalMode(.automatic, asDefault: false)
        checks["hostDenied"] = await run("deny", decide: false, requireCard: true) && !FileManager.default.fileExists(atPath: outside.path)
        checks["askMode"] = await agent.setApprovalMode(.ask, asDefault: false)
        checks["hostApproved"] = await run("approve", decide: true, requireCard: true)
        checks["approvedFile"] = (try? String(contentsOf: outside, encoding: .utf8)) == "approved"
        checks["workspaceConfined"] = await run("confine", decide: true)
        checks["symlinkConfined"] = await run("confineRead", decide: true)
        checks["hostFileUnchanged"] = (try? String(contentsOf: outside, encoding: .utf8)) == "approved"
        agent.smokeOwnerAuthentication = { true }
        let full = await agent.setApprovalMode(.fullAccess, asDefault: false)
        checks["fullAccess"] = false
        if full { checks["fullAccess"] = await run("full") }
        checks["fullAccessFile"] = (try? String(contentsOf: outside, encoding: .utf8)) == "full"
        await agent.select(nil)
        checks["secondTask"] = await run("second")
        let secondRoot = taskRoot()
        checks["separateFolders"] = agent.selectedID != firstID && firstRoot != nil && secondRoot != nil
            && firstRoot?.standardizedFileURL != secondRoot?.standardizedFileURL
            && secondRoot.map { !FileManager.default.fileExists(atPath: $0.appendingPathComponent("result.txt").path) } == true
        if let firstID {
            let query = "finished-write"
            do {
                let active = try await agent.taskContentMatches(query, archived: false)
                let hit = active.first { $0.conversationID == firstID && $0.messageID != nil && $0.snippet.contains(query) }
                checks["messageContentSearch"] = hit != nil && !active.contains { $0.conversationID == agent.selectedID }
                let moved = await agent.changeConversationMetadata(id: firstID, change: .archive(true))
                let hidden = try await agent.taskContentMatches(query, archived: false)
                let archived = try await agent.taskContentMatches(query, archived: true)
                checks["archivedSearchScope"] = moved && !hidden.contains { $0.conversationID == firstID }
                    && archived.contains { $0.conversationID == firstID && $0.messageID == hit?.messageID }
                let restored = await agent.changeConversationMetadata(id: firstID, change: .archive(false))
                if let id = hit?.messageID, restored {
                    checks["openSearchResultFromTaskCenter"] = await openSearchResult(
                        query: query, conversationID: firstID, messageID: id, workspace: agent)
                }
                await agent.select(firstID)
                if let id = hit?.messageID {
                    let revealed = await agent.revealMessage(id, in: firstID)
                    checks["revealSearchMessage"] = restored && revealed && agent.messages.contains { $0.id == id && $0.content.contains(query) }
                } else { checks["revealSearchMessage"] = false }
            } catch {
                checks["messageContentSearch"] = false
            }
        }
        checks["reopen"] = firstRoot != nil && taskRoot()?.standardizedFileURL == firstRoot?.standardizedFileURL
        if agent.beginTermination() { try? await agent.finishTermination() }
        finish(["checks": checks, "diagnostics": agent.smokeRunDiagnostics + settingsDiagnostics, "notice": agent.notice ?? ""])
    }

    private func openSearchResult(query: String, conversationID: UUID, messageID: UUID, workspace: HostAgentWorkspace) async -> Bool {
        HostAgentWorkspaceView.smokeLocatedMessageID = nil
        guard clickWorkbenchButton(ids: ["workspace.taskCenter"], frame: MacWorkspaceRootView.smokeTaskCenterFrame,
                                   screenshot: nil) else { return false }
        workspace.taskCenterQuery = query
        let deadline = ContinuousClock.now + .seconds(4)
        while (workspace.taskContentMatchesByID[conversationID]?.messageID != messageID ||
               MacWorkspaceTaskCenter.smokeResultFrames[conversationID] == nil) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
        guard workspace.taskContentMatchesByID[conversationID]?.messageID == messageID,
              clickWorkbenchButton(ids: ["workspace.task.open." + conversationID.uuidString],
                                   frame: MacWorkspaceTaskCenter.smokeResultFrames[conversationID],
                                   screenshot: "content-search.png") else { return false }
        let until = ContinuousClock.now + .seconds(4)
        while HostAgentWorkspaceView.smokeLocatedMessageID != messageID && ContinuousClock.now < until {
            try? await Task.sleep(for: .milliseconds(40))
        }
        if HostAgentWorkspaceView.smokeLocatedMessageID == messageID {
            try? await Task.sleep(for: .milliseconds(320))
        }
        if let content = visibleWorkbench?.contentView { capture(content, extension: "content-search-open.png") }
        let selected = workspace.selectedID == conversationID
        let located = HostAgentWorkspaceView.smokeLocatedMessageID == messageID
        if !selected || !located {
            settingsDiagnostics.append("Search result selected=\(selected) located=\(located) ready=\(workspace.isReady) loading=\(workspace.isLoadingHistory)")
        }
        return selected && located
    }

    private func finish(_ output: [String: Any]) {
        if let bytes = try? JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: report, options: .atomic)
        }
        Task { @MainActor in
            BridgeApplicationDelegate.model?.closeSettingsWindow()
            // Closing a parent run joins its child workers before releasing the OTA activity lease.
            // The App correctly refuses Quit until that asynchronous cleanup finishes.
            let deadline = ContinuousClock.now + .seconds(8)
            while let model = BridgeApplicationDelegate.model,
                  (model.updates.installation.activity.activityCount != 0 || model.smokeAgentSettingsSheet != nil),
                  ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(40))
            }
            NSApp.terminate(nil)
        }
    }

    func cleanup() {
        if CommandLine.arguments.contains("--browser-download-and-restore"),
           !CommandLine.arguments.contains("--workbench-reopen"),
           preferences.string(forKey: Self.recoveryPathKey) == root.path { return }
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

    private func verifyCatalogOverrides() -> Bool {
        guard var saved = try? HostAgentProvider(endpoint: "https://fixture.invalid/v1",
            protocolKind: .openAIChatCompletions, modelID: "fixture-reasoning", apiKey: "",
            supportsImages: true) else { return false }
        saved.model.explicitCapabilities = [.tools, .vision, .imageGeneration]
        saved.model.reasoningEffort = .high
        var discovered = saved.model
        discovered.displayName = "Fixture model"
        discovered.capabilities = [.text, .tools, .imageGeneration]
        discovered.reasoningMetadata = .init(supportsReasoningEffort: true)
        saved.applyCatalogModel(discovered)
        discovered.reasoningMetadata = nil
        saved.applyCatalogModel(discovered)
        return saved.model.displayName == "Fixture model" && saved.model.capabilities == [.text, .vision]
            && saved.model.reasoningMetadata?.supportsReasoningEffort == true && saved.model.reasoningEffort == .high
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
                                        apiKey: "superseded-fixture-key", debounce: true, allowsPlainHTTP: true)
        workspace.requestModelDiscovery(endpoint: endpoint.absoluteString, protocolKind: .openAIChatCompletions,
                                        apiKey: "floe-catalog-fixture", debounce: true, allowsPlainHTTP: true)
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
                                        apiKey: "redirect-fixture-key", debounce: false, allowsPlainHTTP: true)
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

    private func verifyProviderConnection(in workspace: HostAgentWorkspace) async -> Bool {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--model-catalog-fixture"), flag < arguments.count - 1,
              let endpoint = URL(string: arguments[flag + 1]), endpoint.scheme == "http",
              endpoint.host == "127.0.0.1", endpoint.port != nil else { return false }
        do {
            try await workspace.testProviderConnection(endpoint: endpoint.absoluteString,
                protocolKind: .openAIChatCompletions, modelID: "fixture-model-a", key: "floe-catalog-fixture")
            return false
        } catch FloeError.invalidConfiguration {
            // The unacknowledged fixture URL must fail before reaching the model catalog.
        } catch {
            settingsDiagnostics.append("Fixture HTTP validation: \(error.localizedDescription)")
            return false
        }
        do {
            try await workspace.testProviderConnection(endpoint: endpoint.absoluteString, protocolKind: .openAIChatCompletions,
                modelID: "fixture-model-a", key: "floe-catalog-fixture", allowsPlainHTTP: true)
            return true
        } catch {
            settingsDiagnostics.append("Fixture connection test: \(error.localizedDescription)")
            return false
        }
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

    private func verifyCreative(_ model: BridgeAppModel) async -> Bool {
        guard let endpoint = projectTaskFixtureEndpoint, let owner = model.macWorkspace,
              let videos = owner.videos, let library = owner.creativeLibrary, let agent = owner.agent else { return false }
        do {
            guard let batch = owner.images else { return false }
            let primary = agent.selectedModelID
            guard agent.addProvider(name: "Fixture Image", endpoint: endpoint.absoluteString,
                                    protocolKind: .openAIChatCompletions, modelID: "gpt-image-1", key: "old-fixture-key",
                                    presetID: ProviderTemplateID.openAI.rawValue, allowsPlainHTTP: true, role: .image),
                  let imageAccount = agent.accounts.first(where: { $0.name == "Fixture Image" }),
                  let imageModel = imageAccount.models.first, imageModel.supportsImageGenerationSurface,
                  agent.selectedModelID == primary else {
                settingsDiagnostics.append("Image account creation changed chat selection or lost its media role.")
                return false
            }
            guard batch.providerSelection == MacMediaProviderSelection(accountID: imageAccount.id, modelID: imageModel.id) else {
                settingsDiagnostics.append("Missing automatic image default.")
                return false
            }
            try batch.bindProvider(accountID: imageAccount.id, modelID: imageModel.id)
            guard agent.updateProvider(id: imageAccount.id, name: imageAccount.name, endpoint: endpoint.absoluteString,
                                       protocolKind: .openAIChatCompletions, modelID: imageModel.remoteModelID, key: "floe-image-fixture",
                                       presetID: imageAccount.presetID, allowsPlainHTTP: true, editingModelID: imageModel.id) else { return false }
            func otherDefault(role: ProviderCatalogServiceRole, model: String, preset: ProviderTemplateID) -> MacMediaProviderSelection? {
                let name = "Default fixture " + role.rawValue
                guard agent.addProvider(name: name, endpoint: endpoint.absoluteString, protocolKind: .openAIChatCompletions,
                                        modelID: model, key: "unused-default-fixture-key", presetID: preset.rawValue,
                                        allowsPlainHTTP: true, role: role),
                      let account = agent.accounts.first(where: { $0.name == name }), let saved = account.models.first else { return nil }
                return .init(accountID: account.id, modelID: saved.id)
            }
            let imageRef = MacMediaProviderSelection(accountID: imageAccount.id, modelID: imageModel.id)
            guard let defaultImage = otherDefault(role: .image, model: "gpt-image-1", preset: .openAI) else { return false }
            try batch.bindProvider(accountID: defaultImage.accountID, modelID: defaultImage.modelID)
            batch.generate(prompt: "Storyboard candidates", options: .init(count: 2), providerOverride: imageRef)
            let imageDeadline = ContinuousClock.now + .seconds(8)
            while batch.isGenerating && ContinuousClock.now < imageDeadline { try await Task.sleep(for: .milliseconds(50)) }
            let candidates = batch.history.filter { $0.prompt == "Storyboard candidates" }
            guard batch.providerSelection == defaultImage, candidates.count == 2, Set(candidates.map(\.id)).count == 2,
                  candidates.allSatisfy({ NSImage(contentsOf: batch.imageURL(for: $0))?.isValid == true })
            else {
                settingsDiagnostics.append("Batch image fixture: " + (batch.notice ?? "missing candidates"))
                return false
            }
            guard agent.addProvider(name: "Fixture Video", endpoint: endpoint.absoluteString,
                                    protocolKind: .openAIChatCompletions, modelID: "doubao-seedance-2-5-260628",
                                    key: "floe-video-fixture", presetID: ProviderTemplateID.volcengineArk.rawValue, allowsPlainHTTP: true, role: .video),
                  let videoAccount = agent.accounts.first(where: { $0.name == "Fixture Video" }),
                  let videoModel = videoAccount.models.first, videoModel.supportsVideoGenerationSurface,
                  agent.selectedModelID == primary else {
                settingsDiagnostics.append("Video account creation changed chat selection or lost its media role.")
                return false
            }
            guard videos.providerSelection == MacMediaProviderSelection(accountID: videoAccount.id, modelID: videoModel.id) else {
                settingsDiagnostics.append("Missing automatic video default.")
                return false
            }
            let videoRef = MacMediaProviderSelection(accountID: videoAccount.id, modelID: videoModel.id)
            guard let defaultVideo = otherDefault(role: .video, model: videoModel.remoteModelID, preset: .volcengineArk) else { return false }
            try videos.bindProvider(accountID: defaultVideo.accountID, modelID: defaultVideo.modelID)
            videos.generate(prompt: "Synthetic clip", options: .init(aspectRatio: "16:9", durationSeconds: 5),
                            referenceImage: batch.imageURL(for: candidates[0]), providerOverride: videoRef)
            let deadline = ContinuousClock.now + .seconds(16)
            while videos.isGenerating && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(60)) }
            guard videos.providerSelection == defaultVideo, let item = videos.history.first,
                  item.configuration.providerSelection == videoRef, let url = videos.videoURL(for: item),
                  try await AVURLAsset(url: url).load(.isPlayable) else {
                settingsDiagnostics.append("Video fixture: " + (videos.notice ?? "no saved playable video"))
                return false
            }
            let videoDirectory = library.directory.deletingLastPathComponent().appendingPathComponent("Videos")
            let reopenedVideos = MacVideoGeneration(directory: videoDirectory, namespace: "fixture.no-keychain",
                                                     useKeychain: false, admitWork: { {} })
            guard reopenedVideos.history.first?.id == item.id, reopenedVideos.videoURL(for: item) == url else { return false }
            guard try await verifyVideoRecovery(in: videoDirectory, workspace: agent, accountID: videoAccount.id, modelID: videoModel.id, savedID: item.id) else { return false }
            try await MacTaskVideoSmoke.verify(service: videos, modelID: videoModel.id, base: agent.personalTaskLeaseBase,
                                               referenceImage: batch.imageURL(for: candidates[0]))
            let imageChecks = try await MacTaskImageToolSmoke.verify(endpoint: endpoint, directory: root)
            guard imageChecks.values.allSatisfy({ $0 }) else {
                settingsDiagnostics.append("Task image checks failed: " + imageChecks.filter { !$0.value }.keys.sorted().joined(separator: ", "))
                return false
            }
            let imageDirectory = root.appendingPathComponent("Generated Images Fixture", isDirectory: true)
            let images = MacImageGeneration(directory: imageDirectory, namespace: "fixture.no-keychain", useKeychain: false, admitWork: { {} })
            guard let image = images.history.first else { return false }
            try library.create(name: "First board")
            try library.rename("Storyboard")
            try library.addText("Scene one")
            guard let textID = library.page?.nodes.first?.id else { return false }
            try library.setText("Opening shot", id: textID)
            try library.move(textID, x: 36, y: 42)
            try library.addMedia(images.imageURL(for: image), kind: .image, title: "Reference")
            try library.addMedia(url, kind: .video, title: "First take")
            let reopened = MacCreativeLibrary(directory: library.directory, preferences: preferences, admitWork: { {} })
            guard reopened.selectedID == library.selectedID, reopened.selected?.name == "Storyboard",
                  let nodes = reopened.page?.nodes, nodes.map(\.kind) == [.text, .image, .video],
                  nodes[0].text == "Opening shot", nodes[0].position == .init(x: 36, y: 42),
                  let savedImage = reopened.assetURL(nodes[1]), NSImage(contentsOf: savedImage)?.isValid == true,
                  let savedVideo = reopened.assetURL(nodes[2]), try Data(contentsOf: savedVideo) == Data(contentsOf: url),
                  clickWorkbenchButton(ids: ["workspace.creative"], frame: agent.smokeCreativeFrame, screenshot: nil)
            else { return false }
            let mounted = ContinuousClock.now + .seconds(3)
            while !agent.smokeCreativeMounted && ContinuousClock.now < mounted { try await Task.sleep(for: .milliseconds(40)) }
            guard agent.smokeCreativeMounted, !library.smokeCanvasEditorOpen,
                  let window = visibleWorkbench, let view = window.contentView, let canvas = library.selectedID else { return false }
            capture(view, extension: "creative-library.png")
            refreshButtonFrames(in: view)
            guard clickWorkbenchButton(ids: ["canvas.home.create"], frame: library.smokeCanvasCreateFrame, screenshot: nil) else {
                settingsDiagnostics.append("The creative library did not offer the shared New Canvas action.")
                return false
            }
            let sheetDeadline = ContinuousClock.now + .seconds(3)
            while window.attachedSheet == nil && ContinuousClock.now < sheetDeadline { try await Task.sleep(for: .milliseconds(40)) }
            guard let pickerSheet = window.attachedSheet, let picker = pickerSheet.contentView else {
                settingsDiagnostics.append("The shared canvas template picker did not open."); return false
            }
            capture(picker, extension: "creative-template-picker.png")
            pickerSheet.makeKey()
            refreshButtonFrames(in: picker)
            guard let cancel = library.smokeCanvasTemplateCloseFrame, !cancel.isEmpty,
                  clickWindowLocation(NSPoint(x: cancel.midX, y: cancel.midY), in: pickerSheet) else {
                settingsDiagnostics.append("The template picker’s cancel button was unavailable.")
                window.endSheet(pickerSheet)
                return false
            }
            let cancelDeadline = ContinuousClock.now + .seconds(3)
            while window.attachedSheet != nil && ContinuousClock.now < cancelDeadline { try await Task.sleep(for: .milliseconds(40)) }
            guard window.attachedSheet == nil else {
                settingsDiagnostics.append("The template picker did not return to the canvas library.")
                window.endSheet(pickerSheet)
                return false
            }
            window.makeKeyAndOrderFront(nil)
            guard await openFixtureCanvas(canvas, library: library, view: view) else {
                settingsDiagnostics.append("The creative library did not open the selected canvas.")
                return false
            }
            capture(view, extension: "creative.png")
            refreshButtonFrames(in: view)
            guard clickWorkbenchButton(ids: ["canvas.editor.library"], frame: library.smokeCanvasLibraryBackFrame, screenshot: nil) else { return false }
            let libraryDeadline = ContinuousClock.now + .seconds(3)
            while library.smokeCanvasEditorOpen && ContinuousClock.now < libraryDeadline { try await Task.sleep(for: .milliseconds(40)) }
            guard !library.smokeCanvasEditorOpen, await openFixtureCanvas(canvas, library: library, view: view) else { return false }
            for (index, tab) in [(1, "image"), (2, "video")] {
                view.layoutSubtreeIfNeeded()
                refreshButtonFrames(in: view)
                guard let frame = library.smokeTabFrame, let window = view.window, !frame.isEmpty else { return false }
                let point = NSPoint(x: frame.minX + frame.width * (CGFloat(index) + 0.5) / 3, y: frame.midY)
                guard clickWindowLocation(point, in: window) else { return false }
                let limit = ContinuousClock.now + .seconds(2)
                while library.smokeTab != tab && ContinuousClock.now < limit { try await Task.sleep(for: .milliseconds(40)) }
                guard library.smokeTab == tab else {
                    settingsDiagnostics.append("Creative tab did not open: " + tab)
                    return false
                }
                try await Task.sleep(for: .milliseconds(120))
                if tab == "video" {
                    func findPlayer(_ root: NSView) -> AVPlayer? {
                        if let video = root as? AVPlayerView { return video.player }
                        for child in root.subviews { if let player = findPlayer(child) { return player } }
                        return nil
                    }
                    guard let player = findPlayer(view) else { return false }
                    player.isMuted = true
                    player.play()
                    let until = ContinuousClock.now + .seconds(4)
                    while player.currentTime().seconds < 0.1 && ContinuousClock.now < until { try await Task.sleep(for: .milliseconds(50)) }
                    player.pause()
                    guard player.currentTime().seconds >= 0.1 else {
                        settingsDiagnostics.append("The embedded player did not advance the clip.")
                        return false
                    }
                }
                capture(view, extension: "creative-" + tab + ".png")
            }
            let package = root.appendingPathComponent("Storyboard.floeCanvas")
            try await library.exportSelected(to: package)
            let roundTrip = MacCreativeLibrary(directory: root.appendingPathComponent("Restored canvases"), preferences: preferences, admitWork: { {} })
            try await roundTrip.importCanvas(from: package)
            guard roundTrip.selectedID != library.selectedID, let imported = roundTrip.page?.nodes,
                  imported.count == 3, let clip = roundTrip.assetURL(imported[2]),
                  try Data(contentsOf: clip) == Data(contentsOf: url) else { return false }
            if CommandLine.arguments.contains("--timeline-fixture"),
               !(try await verifyTimelineDraft(library: library, video: url, image: savedImage)) {
                settingsDiagnostics.append("The multi-track draft, shared subtitle codec, or playable export failed.")
                return false
            }
            if CommandLine.arguments.contains("--mixed-canvas-fixture"),
               !(try await verifyMixedCanvas(library: library, image: savedImage, video: savedVideo)) {
                settingsDiagnostics.append("The mixed canvas did not survive native edit, undo and export.")
                return false
            }
            if CommandLine.arguments.contains("--verify-creative-destinations"),
               !(try await verifyCreativeDestinations(agent: agent, library: library, video: url,
                                                       image: batch.imageURL(for: candidates[0]))) {
                settingsDiagnostics.append("The generated media did not reach its selected canvas or original task folder.")
                return false
            }
            defer { model.closeSettingsWindow() }
            for role: BridgeAppModel.MediaSettings in [.image, .video] {
                let expected = role == .image ? "image" : "video"
                model.openSettings(.models)
                let mounted = ContinuousClock.now + .seconds(3)
                let providerRole: ProviderCatalogServiceRole = role == .image ? .image : .video
                var pressed = false
                while !pressed && ContinuousClock.now < mounted {
                    try await Task.sleep(for: .milliseconds(50))
                    guard model.providerDetail == nil, let sheet = model.smokeAgentSettingsSheet,
                          let content = sheet.contentView else { continue }
                    content.layoutSubtreeIfNeeded()
                    refreshButtonFrames(in: content)
                    if let frame = MacProviderSettingsView.smokeSelectionFrames[providerRole], !frame.isEmpty,
                       content.bounds.contains(content.convert(NSPoint(x: frame.midX, y: frame.midY), from: nil)) {
                        if role == .image { capture(content, extension: "provider-accounts.png") }
                        pressed = pressAccessibilityButton(content, id: "settings.providers.select." + expected)
                            || clickWindowLocation(NSPoint(x: frame.midX, y: frame.midY), in: sheet)
                    }
                }
                guard pressed else { settingsDiagnostics.append("Provider selection button missing: " + expected); return false }
                let timeout = ContinuousClock.now + .seconds(3)
                while agent.smokeMediaSettingsRole != expected && ContinuousClock.now < timeout {
                    try await Task.sleep(for: .milliseconds(40))
                }
                guard model.settingsPane == .models, model.providerDetail == role, agent.smokeMediaSettingsRole == expected, let view = model.smokeAgentSettingsSheet?.contentView else {
                    settingsDiagnostics.append("Missing media settings pane: " + expected)
                    return false
                }
                capture(view, extension: "creative-" + expected + "-settings.png")
                if role == .video, let sheet = view.window {
                    view.layoutSubtreeIfNeeded()
                    refreshButtonFrames(in: view)
                    let pressedAdd = pressAccessibilityButton(view, id: "settings.providers.addForRole")
                        || agent.smokeMediaAddFrame.map { clickWindowLocation(NSPoint(x: $0.midX, y: $0.midY), in: sheet) } == true
                    let editorDeadline = ContinuousClock.now + .seconds(2)
                    while MacProviderSettingsView.smokeEditorRole != .video && ContinuousClock.now < editorDeadline {
                        try await Task.sleep(for: .milliseconds(40))
                    }
                    guard pressedAdd, model.providerDetail == nil, MacProviderSettingsView.smokeEditorRole == .video else {
                        settingsDiagnostics.append("Add Provider did not open the video account editor.")
                        return false
                    }
                    capture(view, extension: "provider-add-video.png")
                }
            }
            model.closeSettingsWindow()
            let closed = ContinuousClock.now + .seconds(3)
            while (visibleWorkbench?.isKeyWindow != true || model.smokeAgentSettingsSheet != nil) && ContinuousClock.now < closed {
                try await Task.sleep(for: .milliseconds(40))
            }
            try batch.bindProvider(accountID: imageRef.accountID, modelID: imageRef.modelID)
            try videos.bindProvider(accountID: videoRef.accountID, modelID: videoRef.modelID)
            guard visibleWorkbench?.isKeyWindow == true, model.smokeAgentSettingsSheet == nil else {
                settingsDiagnostics.append("Closing the provider editor did not return focus to the workbench.")
                return false
            }
            guard agent.setAccountEnabled(id: imageAccount.id, enabled: false),
                  agent.removeProvider(id: videoAccount.id) else {
                settingsDiagnostics.append("The image or video account change failed.")
                return false
            }
            let invalidated = ContinuousClock.now + .seconds(2)
            while (batch.hasCredential || videos.hasCredential) && ContinuousClock.now < invalidated {
                try await Task.sleep(for: .milliseconds(40))
            }
            guard !batch.hasCredential && !videos.hasCredential && agent.selectedModelID == primary else {
                settingsDiagnostics.append("Media credential invalidation failed (image=\(batch.hasCredential), video=\(videos.hasCredential), primaryChanged=\(agent.selectedModelID != primary)).")
                return false
            }
            return true
        } catch {
            settingsDiagnostics.append("Creative fixture: " + error.localizedDescription)
            return false
        }
    }

    private func openFixtureCanvas(_ id: UUID, library: MacCreativeLibrary, view: NSView) async -> Bool {
        refreshButtonFrames(in: view)
        guard clickWorkbenchButton(ids: ["canvas.home.open." + id.uuidString],
                                   frame: library.smokeCanvasFrames[id], screenshot: nil) else { return false }
        let deadline = ContinuousClock.now + .seconds(3)
        while !library.smokeCanvasEditorOpen && ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(40)) }
        return library.smokeCanvasEditorOpen && library.selectedID == id
    }

    private func verifyTimelineDraft(library: MacCreativeLibrary, video: URL, image: URL) async throws -> Bool {
        guard let store = library.timelineDraftStore else { return false }
        let videoInfo = try await MacTimelineAssetProber.probe(video)
        let imageInfo = try await MacTimelineAssetProber.probe(image)
        guard videoInfo.duration >= 0.9 else { return false }
        var draft = try MacTimelineDraft(name: "Local timeline fixture", canvasWidth: 320, canvasHeight: 180)
        let picture = try draft.addTrack(.visual)
        let clip = try MacTimelineClip.media(sourceURL: video, title: "Picture", timelineStart: 0, duration: 0.9, volume: 0)
        try draft.addClip(clip, toTrack: picture.id)
        try draft.setClipGrade(trackID: picture.id, clipID: clip.id, grade: .init(filterID: "CISepiaTone"))
        if videoInfo.hasAudio {
            let overlay = try draft.addTrack(.visual)
            let sound = try draft.addTrack(.audio)
            try draft.addClip(.media(sourceURL: image, title: "Overlay", timelineStart: 0.5, duration: 0.3), toTrack: overlay.id)
            try draft.addClip(.media(sourceURL: video, title: "Sound", timelineStart: 0, duration: 0.9), toTrack: sound.id)
        }
        let captions = try draft.addTrack(.caption)
        let cues = try MediaV2SubtitleCodec.parse("1\n00:00:00,150 --> 00:00:00,750\n测试 caption\n")
        for cue in cues {
            try draft.addClip(.caption(timelineStart: cue.start, duration: cue.duration, text: cue.text), toTrack: captions.id)
        }
        try library.saveTimelineDraft(draft)
        let reopened = try store.load(id: draft.id)
        guard reopened.id == draft.id, reopened.tracks == draft.tracks,
              library.timelineDrafts().contains(where: { $0.id == draft.id }),
              try MediaV2SubtitleCodec.parse(MediaV2SubtitleCodec.encode(cues, format: .vtt)) == cues else { return false }
        let movie = root.appendingPathComponent("rendered-timeline.mp4")
        try await MacTimelineExporter().export(draft: reopened, assets: [video: videoInfo, image: imageInfo], to: movie)
        let asset = AVURLAsset(url: movie)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        return await MacTimelineExporter.verify(movie, expectedDuration: 0.9) && audio.isEmpty != videoInfo.hasAudio
    }

    private func verifyMixedCanvas(library: MacCreativeLibrary, image: URL, video: URL) async throws -> Bool {
        let source = root.appendingPathComponent("Mixed Canvas Source", isDirectory: true)
        let materials = source.appendingPathComponent("Materials", isDirectory: true)
        try FileManager.default.createDirectory(at: materials, withIntermediateDirectories: true)
        func node(_ kind: CanvasNodeKind, title: String, x: Double, media: URL?, mime: String?) throws -> CanvasNode {
            var node = CanvasNode(kind: kind, title: title, text: title, position: .init(x: x, y: 128),
                                  size: .init(width: 180, height: 120))
            if let media {
                let name = "Mixed-" + UUID().uuidString + "." + media.pathExtension
                let target = materials.appendingPathComponent(name)
                try FileManager.default.copyItem(at: media, to: target)
                let bytes = try Data(contentsOf: target)
                node.asset = .init(contentHash: FloeDigest.sha256Hex(bytes), localRelativePath: "Materials/" + name,
                                   mimeType: mime, byteCount: Int64(bytes.count))
            }
            return node
        }
        let text = try node(.text, title: "Mac iPad QA original", x: 100, media: nil, mime: nil)
        let still = try node(.image, title: "Mixed image", x: 290, media: image, mime: "image/png")
        let clip = try node(.video, title: "Mixed video", x: 480, media: video, mime: "video/mp4")
        var locked = try node(.shape, title: "Locked content", x: 665, media: nil, mime: nil)
        locked.groupID = UUID()
        locked.isLocked = true
        locked.shape = .roundedRectangle
        locked.metadata["fixture-opaque"] = "Preserve this exact value."
        let connector = CanvasConnection(sourceNodeID: text.id, destinationNodeID: still.id)
        let stroke = CanvasStroke(points: [.init(x: 61, y: 42), .init(x: 91, y: 80)])
        let path = PKStrokePath(controlPoints: [CGPoint(x: 64, y: 42), CGPoint(x: 92, y: 78)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.1, size: CGSize(width: 4, height: 4),
                          opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }, creationDate: Date())
        let pencil = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .blue), path: path, transform: .identity, mask: nil)])
            .dataRepresentation()
        let document = CanvasDocument(name: "Mixed page", nodes: [text, still, clip, locked],
                                      connections: [connector], strokes: [stroke], pencilDrawingData: pencil)
        var fixture = CanvasProject(id: UUID(), name: "Floe Mac QA Mixed " + String(UUID().uuidString.prefix(8)),
                                    documents: [document], selectedDocumentID: document.id)
        fixture.sync.isEnabled = false
        fixture = try CanvasFrameworkBackupState.seedFrameworkState(fixture)
        let original = report.deletingLastPathComponent().appendingPathComponent("iPad-shape-input.floecanvas")
        try CanvasBackupPackage.exportToURL(project: fixture, destination: original, layout: .init(
            projectsRoot: source, materialsRoot: materials, fallbackMediaRoot: source))
        try await library.importCanvas(from: original)
        guard let imported = library.selected, imported.id != fixture.id,
              imported.canvasKitState != nil, library.page?.nodes.count == 4 else { return false }
        try library.setText("Edited on Mac", id: text.id)
        try library.move(text.id, x: 85, y: 73)
        try library.undo()
        guard library.page?.nodes.first(where: { $0.id == text.id })?.position == text.position else { return false }
        _ = try library.addConnection(from: still.id, to: clip.id)
        // The view library reopens the published native revision from disk.
        let reopened = MacCreativeLibrary(directory: library.directory, preferences: preferences, admitWork: { {} })
        reopened.selectedID = imported.id
        guard let page = reopened.page, page.strokes == [stroke], page.pencilDrawingData == pencil,
              page.connections.count == 2, page.nodes.first(where: { $0.id == text.id })?.text == "Edited on Mac",
              page.nodes.first(where: { $0.id == locked.id }) == locked,
              let imageNode = page.nodes.first(where: { $0.id == still.id }), let heldImage = reopened.assetURL(imageNode),
              let videoNode = page.nodes.first(where: { $0.id == clip.id }), let heldVideo = reopened.assetURL(videoNode),
              try Data(contentsOf: heldImage) == Data(contentsOf: image),
              try Data(contentsOf: heldVideo) == Data(contentsOf: video) else { return false }
        let exported = report.deletingLastPathComponent().appendingPathComponent("Mac-edited-for-iPad.floecanvas")
        try await reopened.exportSelected(to: exported)
        try Data(fixture.name.utf8).write(to: report.deletingLastPathComponent().appendingPathComponent("mixed-name.txt"))
        return true
    }

    private func verifyCreativeDestinations(agent: HostAgentWorkspace, library: MacCreativeLibrary,
                                            video: URL, image: URL) async throws -> Bool {
        guard let window = visibleWorkbench, let view = window.contentView,
              let task = agent.fileWorkspaceForCurrentTask, let canvas = library.selectedID,
              let nodeCount = library.page?.nodes.count else { return false }
        let owner = agent.attachmentOwnerID
        var stale = false
        let folder = try URL(resolvingBookmarkData: task.rootBookmark, options: [.withoutUI],
                             relativeTo: nil, bookmarkDataIsStale: &stale)
        refreshButtonFrames(in: view)
        guard !stale, clickWorkbenchButton(ids: ["mac.creative.addToCanvas"], frame: MacVideoWorkbenchView.smokeAddToCanvasFrame, screenshot: nil)
            || clickRenderedText(["Add to Canvas", "添加到画布"], in: view, window: window) else {
            settingsDiagnostics.append("Creative add-to-canvas action was absent.")
            return false
        }
        let added = ContinuousClock.now + .seconds(3)
        while library.page?.nodes.count != nodeCount + 1 && ContinuousClock.now < added { try await Task.sleep(for: .milliseconds(40)) }
        guard library.selectedID == canvas, library.page?.nodes.count == nodeCount + 1,
              let node = library.page?.nodes.last, node.kind == .video, let file = library.assetURL(node),
              try Data(contentsOf: file) == Data(contentsOf: video) else {
            settingsDiagnostics.append("The selected canvas did not contain the generated video with matching bytes.")
            return false
        }
        try library.undo()
        guard library.page?.nodes.count == nodeCount else { return false }
        let switchDeadline = ContinuousClock.now + .seconds(3)
        while library.smokeTab != "canvas" && ContinuousClock.now < switchDeadline { try await Task.sleep(for: .milliseconds(40)) }
        refreshButtonFrames(in: view)
        guard let frame = library.smokeTabFrame, !frame.isEmpty,
              clickWindowLocation(NSPoint(x: frame.midX, y: frame.midY), in: window) else { return false }
        let buttonDeadline = ContinuousClock.now + .seconds(3)
        var pressed = false
        while !pressed && ContinuousClock.now < buttonDeadline {
            if library.smokeTab == "image" {
                refreshButtonFrames(in: view)
                pressed = clickWorkbenchButton(ids: ["mac.creative.saveToTask"], frame: MacImageWorkbenchView.smokeSaveToTaskFrame, screenshot: nil)
                    || clickRenderedText(["Save to Task Files", "保存到任务文件"], in: view, window: window)
            }
            if !pressed { try await Task.sleep(for: .milliseconds(100)) }
        }
        guard pressed else { settingsDiagnostics.append("Creative task-save action was absent."); return false }
        let saveDeadline = ContinuousClock.now + .seconds(4)
        while agent.smokeCreativeMounted && ContinuousClock.now < saveDeadline { try await Task.sleep(for: .milliseconds(50)) }
        let contents = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        let reference = try Data(contentsOf: image)
        guard !agent.smokeCreativeMounted, agent.attachmentOwnerID == owner,
              contents.contains(where: { (try? Data(contentsOf: $0)) == reference }) else { return false }
        capture(view, extension: "creative-task-files.png")
        return true
    }

    private func verifyVideoRecovery(in directory: URL, workspace: HostAgentWorkspace, accountID: UUID, modelID: UUID, savedID: UUID) async throws -> Bool {
        let pendingDirectory = root.appendingPathComponent("Video Recovery Fixture", isDirectory: true)
        try FileManager.default.createDirectory(at: pendingDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let bytes = try Data(contentsOf: directory.appendingPathComponent("history.json"))
        guard !String(decoding: bytes, as: UTF8.self).contains("fixture-media-signature"),
              !String(decoding: bytes, as: UTF8.self).contains("floe-video-fixture"),
              var envelope = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              var entries = envelope["results"] as? [[String: Any]], !entries.isEmpty else {
            settingsDiagnostics.append("Video history contains credentials or an unexpected schema.")
            return false
        }
        // Capture the state of the same submitted provider job before its download.
        entries[0]["state"] = "submitted"
        entries[0].removeValue(forKey: "filename")
        envelope["results"] = entries
        try JSONSerialization.data(withJSONObject: envelope).write(to: pendingDirectory.appendingPathComponent("history.json"))
        var leases = 0
        let resumed = MacVideoGeneration(directory: pendingDirectory, namespace: "fixture.no-keychain", useKeychain: false,
                                         workspace: workspace, preferences: preferences) {
            leases += 1
            return { leases -= 1 }
        }
        let original = MacMediaProviderSelection(accountID: accountID, modelID: modelID)
        guard let current = resumed.providerSelection, current != original else { return false }
        resumed.resume()
        resumed.resume()
        let timeout = ContinuousClock.now + .seconds(10)
        while resumed.history.first?.state != .ready && ContinuousClock.now < timeout { try await Task.sleep(for: .milliseconds(50)) }
        guard let restored = resumed.history.first, restored.id == savedID, resumed.videoURL(for: restored) != nil,
              leases == 0 else {
            settingsDiagnostics.append("Submitted video fixture did not resume and release its activity lease.")
            return false
        }
        resumed.generate(prompt: "Cancel fixture", options: .init(), providerOverride: original)
        let cancellation = ContinuousClock.now + .seconds(5)
        while (resumed.history.first?.prompt != "Cancel fixture" || resumed.history.first?.providerTaskID == nil)
                && ContinuousClock.now < cancellation { try await Task.sleep(for: .milliseconds(50)) }
        resumed.cancel()
        let stop = ContinuousClock.now + .seconds(5)
        while resumed.isGenerating && ContinuousClock.now < stop { try await Task.sleep(for: .milliseconds(50)) }
        guard resumed.history.first?.state == .cancelled, leases == 0 else {
            settingsDiagnostics.append("Video cancellation did not reach its terminal state.")
            return false
        }
        return true
    }

    private func verifyTaskMenus(model: BridgeAppModel, workspace: HostAgentWorkspace) async -> Bool {
        model.openAgentWorkspace()
        let activated = ContinuousClock.now + .seconds(2)
        while NSApp.keyWindow?.identifier != UnifiedMacWorkspace.workbenchWindowIdentifier && ContinuousClock.now < activated {
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard NSApp.keyWindow?.identifier == UnifiedMacWorkspace.workbenchWindowIdentifier else {
            settingsDiagnostics.append("Workbench was not key during the shortcut test.")
            return false
        }
        let findTitle = String(localized: "mac.workspace.find")
        guard await openNewTaskFromMenu(workspace: workspace),
              await performMenuShortcut("f", title: findTitle) else { return false }
        let deadline = ContinuousClock.now + .seconds(2)
        while !workspace.smokeTaskSearchMounted && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard workspace.smokeTaskSearchMounted, await performMenuShortcut("f", title: findTitle) else {
            settingsDiagnostics.append("Find did not show the task search field.")
            return false
        }
        while workspace.smokeTaskFindInvocations < 2 && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard workspace.smokeTaskSearchMounted, workspace.smokeTaskFindInvocations == 2,
              await workspace.verifyChatSmoke(admissionIsClosedToInstall: { true }),
              await performMenuShortcut("f", title: findTitle) else { return false }
        let conversationDeadline = ContinuousClock.now + .seconds(2)
        while !workspace.smokeConversationSearchMounted && ContinuousClock.now < conversationDeadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard workspace.smokeConversationSearchMounted, workspace.smokeTaskFindInvocations == 2,
              await performMenuShortcut("f", title: String(localized: "mac.workspace.findTask"), modifiers: [.command, .shift]) else {
            return false
        }
        let taskSearchDeadline = ContinuousClock.now + .seconds(2)
        while workspace.smokeTaskFindInvocations < 3 && ContinuousClock.now < taskSearchDeadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
        return workspace.smokeTaskSearchMounted && workspace.smokeTaskFindInvocations == 3
    }

    private func verifyDesktopFilesLayout(window: NSWindow, content: NSView, workspace: HostAgentWorkspace) async -> Bool {
        guard let project = workspace.workspaces.first(where: { $0.kind == .project }) else { return false }
        window.makeKeyAndOrderFront(nil)
        let keyDeadline = ContinuousClock.now + .seconds(2)
        while (!window.isKeyWindow || !workspace.windowShowsTask) && ContinuousClock.now < keyDeadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        workspace.selectWorkspace(project.id)
        let frame = window.frame
        defer {
            workspace.selectWorkspace(nil)
            window.setFrame(frame, display: true)
        }
        let title = String(localized: "mac.workspace.toggleFiles")
        let modifiers: NSEvent.ModifierFlags = [.command, .option]
        func waitForState(shown: Bool, inDetail: Bool) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(2)
            while ContinuousClock.now < deadline {
                if (workspace.smokeInspectorShown, workspace.smokeFilesTakeDetail) == (shown, inDetail) { return true }
                try? await Task.sleep(for: .milliseconds(35))
            }
            return false
        }
        guard await performMenuShortcut("0", title: title, modifiers: modifiers),
              await waitForState(shown: true, inDetail: false) else {
            settingsDiagnostics.append("The desktop Files command did not open the inspector.")
            return false
        }
        capture(content, extension: "wide-files.png")
        window.setContentSize(NSSize(width: 780, height: 590))
        guard await waitForState(shown: true, inDetail: true) else {
            settingsDiagnostics.append("The inspector did not move into the narrow detail pane.")
            return false
        }
        capture(content, extension: "narrow-files.png")
        guard await performMenuShortcut("0", title: title, modifiers: modifiers),
              await waitForState(shown: false, inDetail: false) else { return false }
        capture(content, extension: "narrow-composer.png")
        return true
    }

    private func openNewTaskFromMenu(workspace: HostAgentWorkspace) async -> Bool {
        guard await performMenuShortcut("n", title: String(localized: "workbench.new_task")) else { return false }
        let newTaskDeadline = ContinuousClock.now + .seconds(2)
        while workspace.selectedID != nil && ContinuousClock.now < newTaskDeadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
        return workspace.selectedID == nil
    }

    private func openNewTaskFromSidebar(workspace: HostAgentWorkspace) async -> Bool {
        guard clickWorkbenchButton(ids: ["sidebar.workbench.new_task"], frame: MacWorkspaceRootView.smokeNewTaskFrame,
                                   screenshot: nil) else { return false }
        let deadline = ContinuousClock.now + .seconds(2)
        while workspace.selectedID != nil && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
        return workspace.selectedID == nil
    }

    private func openNewProjectTask(workspace: HostAgentWorkspace, projectID: UUID,
                                    screenshot: String? = "project-task-start.png", fromName: Bool = false) async -> Bool {
        guard let window = visibleWorkbench, let content = window.contentView, window.attachedSheet == nil else {
            settingsDiagnostics.append("The project sidebar was not interactive.")
            return false
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        func targetFrame() -> CGRect? {
            (fromName ? workspace.smokeProjectNameFrames : workspace.smokeProjectNewTaskFrames)[projectID]
        }
        func visibleAnchor(in view: NSView, matching frame: CGRect) -> NSView? {
            if view is MacWorkbenchButtonFrameReader.Anchor, !view.isHiddenOrHasHiddenAncestor,
               view.convert(view.bounds, to: nil).equalTo(frame),
               content.visibleRect.contains(content.convert(NSPoint(x: frame.midX, y: frame.midY), from: nil)),
               view.visibleRect.contains(NSPoint(x: view.bounds.midX, y: view.bounds.midY)) { return view }
            for child in view.subviews {
                if let match = visibleAnchor(in: child, matching: frame) { return match }
            }
            return nil
        }
        let revealDeadline = ContinuousClock.now + .seconds(3)
        var button: NSView?
        while ContinuousClock.now < revealDeadline {
            content.layoutSubtreeIfNeeded()
            refreshButtonFrames(in: content)
            if window.isKeyWindow, let frame = targetFrame(), !frame.isEmpty,
               let visible = visibleAnchor(in: content, matching: frame) {
                button = visible
                break
            }
            NotificationCenter.default.post(name: MacWorkspaceRootView.smokeRevealProjectRow,
                                            object: workspace, userInfo: ["project": projectID])
            try? await Task.sleep(for: .milliseconds(75))
        }
        guard let button, click(button, at: NSPoint(x: button.bounds.midX, y: button.bounds.midY), in: window) else {
            let action = fromName ? "open" : "new"
            settingsDiagnostics.append("The sidebar’s \(action) control for \(projectID) was not visible after scrolling.")
            return false
        }
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline {
            if workspace.selectedID == nil && workspace.selectedWorkspaceID == projectID {
                if let screenshot {
                    try? await Task.sleep(for: .milliseconds(75))
                    if let content = visibleWorkbench?.contentView {
                        capture(content, extension: screenshot)
                    }
                }
                return true
            }
            try? await Task.sleep(for: .milliseconds(30))
        }
        settingsDiagnostics.append("The sidebar’s project control did not switch to the selected project’s draft.")
        return false
    }

    private func performMenuShortcut(_ key: String, title: String, modifiers: NSEvent.ModifierFlags = .command) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(4)
        let rootTitle = key == "0" ? String(localized: "space.title") : String(localized: "Tasks")
        var requestedFocus = false
        repeat {
            if let workbench = visibleWorkbench, workbench.attachedSheet == nil, NSApp.modalWindow == nil {
                // Accessibility presses can select a row in an inactive test process.
                // A real keyboard equivalent is delivered to the active, key window only.
                if (!NSApp.isActive || !workbench.isKeyWindow) && !requestedFocus {
                    requestedFocus = true
                    NSApp.activate(ignoringOtherApps: true)
                    workbench.makeKeyAndOrderFront(nil)
                }
            }
            if NSApp.isActive, let workbench = visibleWorkbench, workbench.isKeyWindow, workbench.attachedSheet == nil {
                NSApp.mainMenu?.update()
                for root in NSApp.mainMenu?.items ?? [] where root.title == rootTitle {
                    guard let menu = root.submenu else { continue }
                    // CommandMenu can defer building its children until AppKit requests the menu.
                    if menu.numberOfItems == 0 { menu.delegate?.menuNeedsUpdate?(menu) }
                    menu.update()
                    if let index = menu.items.firstIndex(where: {
                        $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers && $0.title == title && $0.isEnabled
                    }) {
                        menu.performActionForItem(at: index)
                        return true
                    }
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
        } while ContinuousClock.now < deadline
        func windowSummary(_ window: NSWindow?) -> String {
            guard let window else { return "nil" }
            return "\(type(of: window))#\(window.windowNumber) id=\(window.identifier?.rawValue ?? "-") " +
                "key=\(window.isKeyWindow) main=\(window.isMainWindow) visible=\(window.isVisible) sheet=\(window.attachedSheet?.windowNumber ?? -1)"
        }
        let menuSummary = NSApp.mainMenu?.items.map { item in
            let keys = item.submenu?.items.filter { !$0.keyEquivalent.isEmpty || item.title == String(localized: "Tasks")
                || item.title == String(localized: "space.title") }.map {
                    "\($0.title) [\($0.keyEquivalent),\($0.keyEquivalentModifierMask.rawValue),enabled=\($0.isEnabled),hidden=\($0.isHidden)]"
                } ?? []
            return "\(item.title){\(keys.joined(separator: ", "))}"
        }.joined(separator: " ") ?? "nil"
        settingsDiagnostics.append("Missing menu command \(title) [\(key),\(modifiers.rawValue)]. " +
            "active=\(NSApp.isActive), policy=\(NSApp.activationPolicy().rawValue), key=\(windowSummary(NSApp.keyWindow)), " +
            "main=\(windowSummary(NSApp.mainWindow)), workbench=\(windowSummary(visibleWorkbench)), menus=\(menuSummary)")
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

    private func accessibilityElement(_ value: Any, id: String, remaining: Int = 16) -> (any NSAccessibilityProtocol)? {
        guard remaining > 0, let element = value as? any NSAccessibilityProtocol else { return nil }
        if element.accessibilityIdentifier() == id { return element }
        for child in element.accessibilityChildren() ?? [] {
            if let found = accessibilityElement(child, id: id, remaining: remaining - 1) { return found }
        }
        return nil
    }

    private func captureWindow(_ window: NSWindow, suffix: String) {
        let capture = Process()
        capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        capture.arguments = ["-x", "-o", "-l", String(window.windowNumber), report.appendingPathExtension(suffix).path]
        guard (try? capture.run()) != nil else { return }
        capture.waitUntilExit()
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

    private func answerProjectQuestion(in agent: HostAgentWorkspace) async -> Bool {
        guard let window = visibleWorkbench, let content = window.contentView, window.attachedSheet == nil else { return false }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        func marker(_ name: String, in view: NSView) -> NSView? {
            guard !view.isHiddenOrHasHiddenAncestor, view.window === window else { return nil }
            if view.identifier?.rawValue == name { return view }
            for child in view.subviews {
                if let found = marker(name, in: child) { return found }
            }
            return nil
        }
        func press(_ action: String, card: UserQuestionCardModel) -> Bool {
            guard let id = UserQuestionCardView.smokeMarker(action, target: card.currentTarget),
                  let anchor = marker(id, in: content), window.isKeyWindow else { return false }
            _ = anchor.scrollToVisible(anchor.bounds)
            content.layoutSubtreeIfNeeded()
            let point = NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY)
            guard !anchor.bounds.isEmpty, anchor.visibleRect.contains(point),
                  content.visibleRect.contains(anchor.convert(point, to: content)) else { return false }
            return click(anchor, at: point, in: window)
        }

        let deadline = ContinuousClock.now + .seconds(10)
        var requestID: String?
        var optionClicked = false
        var optionSelected = false
        var submitClicked = false
        while ContinuousClock.now < deadline {
            if submitClicked, agent.pendingQuestion?.requestID != requestID { return true }
            if let question = agent.pendingQuestion, let card = UserQuestionCardView.smokeModel,
               card.currentTarget?.requestID == question.requestID,
               requestID == nil || requestID == question.requestID {
                requestID = question.requestID
                optionSelected = card.isSelected("report")
                if !optionSelected && !optionClicked {
                    optionClicked = press("option.report", card: card)
                } else if optionSelected, card.canContinue, !card.isSubmitting, !submitClicked {
                    capture(content, extension: "project-question.png")
                    submitClicked = press("continue", card: card)
                }
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        capture(content, extension: "project-question-failed.png")
        settingsDiagnostics.append("The project question did not finish (card=\(requestID != nil), optionClick=\(optionClicked), selected=\(optionSelected), submitClick=\(submitClicked)).")
        return false
    }

    private func enterSteerDuringApproval(workspace: HostAgentWorkspace) async -> Bool {
        guard let window = visibleWorkbench, let content = window.contentView, let id = workspace.selectedID,
              workspace.canSteer else { return false }
        func submit(_ text: String) async -> Bool {
            content.layoutSubtreeIfNeeded()
            refreshButtonFrames(in: content)
            guard let frame = workspace.smokePromptFrame, !frame.isEmpty,
                  clickWindowLocation(NSPoint(x: frame.midX, y: frame.midY), in: window) else { return false }
            await Task.yield()
            guard let field = window.firstResponder as? NSTextView else { return false }
            field.insertText(text, replacementRange: field.selectedRange())
            await Task.yield()
            return clickWorkbenchButton(ids: ["composer.send"], frame: workspace.smokeSteerFrame, screenshot: nil)
        }
        workspace.smokePendingInputsFrame = nil
        let next = "Summarize the saved project report."
        let guidance = "Mention the checked attachment in your reply."
        let editedText = "Edited queue fixture"
        let titles = ["chat.thread_composer_view.add_to_message_queue", "chat.thread_composer_view.steer_the_current_run"].map { NSLocalizedString($0, comment: "") }
        guard await selectMenuChoice(frame: workspace.smokeRunningModeFrame, titles: titles, target: titles[0]),
              workspace.conversationRunningInputMode == .queue, await submit(next) else { return false }
        var deadline = ContinuousClock.now + .seconds(2)
        while workspace.queuedInputs[id]?.first?.content != next && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        content.layoutSubtreeIfNeeded()
        refreshButtonFrames(in: content)
        guard let original = workspace.queuedInputs[id]?.first, original.content == next,
              let queueFrame = workspace.smokePendingInputsFrame,
              let composerFrame = workspace.smokeComposerSurfaceFrame,
              let stopFrame = workspace.smokeStopFrame, let sendFrame = workspace.smokeSteerFrame,
              abs(queueFrame.minY - composerFrame.maxY) <= 1,
              abs(queueFrame.minX - composerFrame.minX) <= 1,
              abs(queueFrame.width - composerFrame.width) <= 1,
              stopFrame.midX < sendFrame.midX else {
            settingsDiagnostics.append("The pending messages must share the composer column, with Stop before Send.")
            return false
        }
        capture(content, extension: "project-pending-above-composer.png")
        let editTitle = NSLocalizedString("workspace.workspace_canvas_view.edit", comment: "")
        PendingInputEditor.smokeSaveFrame = nil
        guard await selectMenuChoice(frame: PendingInputQueueView.smokeMenuFrames[original.id],
                                     titles: [editTitle], target: editTitle),
              let sheet = window.attachedSheet, let sheetContent = sheet.contentView,
              let editor = descendant(NSTextView.self, in: sheetContent) else {
            settingsDiagnostics.append("The queued row did not open the shared editor sheet.")
            return false
        }
        sheet.makeKey()
        _ = sheet.makeFirstResponder(editor)
        editor.insertText(editedText, replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        try? await Task.sleep(for: .milliseconds(75))
        sheetContent.layoutSubtreeIfNeeded()
        refreshButtonFrames(in: sheetContent)
        capture(sheetContent, extension: "project-pending-editor.png")
        let clickedSave = pressAccessibilityButton(sheetContent, id: "thread.pendingInputs.edit.save")
            || PendingInputEditor.smokeSaveFrame.map { clickWindowLocation(NSPoint(x: $0.midX, y: $0.midY), in: sheet) } == true
        guard clickedSave else {
            _ = await closeFixtureSheet(sheet, id: "thread.pendingInputs.edit.cancel")
            settingsDiagnostics.append("The shared queued editor had no Save button.")
            return false
        }
        deadline = ContinuousClock.now + .seconds(2)
        while (window.attachedSheet != nil || workspace.queuedInputs[id]?.first?.content != editedText),
              ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        guard let edited = workspace.queuedInputs[id]?.first, edited.id == original.id,
              edited.content == editedText, window.attachedSheet == nil else { return false }
        window.makeKeyAndOrderFront(nil)
        await workspace.editQueued(edited, content: next)
        guard await submit("Discard this queue fixture") else { return false }
        deadline = ContinuousClock.now + .seconds(2)
        while workspace.queuedInputs[id]?.count != 2 && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard let discard = workspace.queuedInputs[id]?.last, discard.id != original.id else { return false }
        await workspace.moveQueued(discard, offset: -1)
        guard workspace.queuedInputs[id]?.map(\.id) == [discard.id, original.id] else { return false }
        await workspace.cancelQueued(discard)
        guard workspace.queuedInputs[id]?.map(\.id) == [original.id],
              workspace.queuedInputs[id]?.first?.content == next,
              await selectMenuChoice(frame: workspace.smokeRunningModeFrame, titles: titles, target: titles[1]),
              workspace.conversationRunningInputMode == .steer, await submit(guidance) else { return false }
        deadline = ContinuousClock.now + .seconds(2)
        while !((workspace.queuedInputs[id] ?? []).contains { $0.content == guidance && $0.status == .steerPending }),
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard workspace.lastSteer == guidance, workspace.pendingApproval != nil, workspace.runningInputMode == .queue,
              let inserted = workspace.queuedInputs[id]?.first(where: { $0.status == .steerPending && $0.content == guidance })
        else { return false }
        await workspace.demoteQueuedGuidance(inserted)
        guard let queued = workspace.queuedInputs[id]?.first(where: { $0.id == inserted.id }),
              queued.status == .queued else { return false }
        await workspace.promoteQueuedToGuidance(queued)
        return workspace.queuedInputs[id]?.contains { $0.id == inserted.id && $0.status == .steerPending } == true
    }

    private func selectComposerMode(_ mode: HostAgentMode, workspace: HostAgentWorkspace) async -> Bool {
        let titles = HostAgentMode.allCases.map { NSLocalizedString("mac.agent.mode." + $0.rawValue, comment: "") }
        let target = NSLocalizedString("mac.agent.mode." + mode.rawValue, comment: "")
        let chosen = await selectMenuChoice(frame: workspace.smokeModeFrame, titles: titles, target: target)
        if !chosen || workspace.composerMode != mode {
            settingsDiagnostics.append("Mode menu expected \(mode.rawValue), got \(workspace.composerMode.rawValue), selected=\(chosen).")
        }
        return chosen && workspace.composerMode == mode
    }

    private func selectMenuChoice(frame: @autoclosure () -> CGRect?, titles: [String], target: String) async -> Bool {
        guard let window = visibleWorkbench, let content = window.contentView else { return false }
        // The preceding selection can add/remove a project chip before this menu.
        // Wait for its screen position to settle before dispatching the pointer event.
        var previous = CGRect.null
        let layoutDeadline = ContinuousClock.now + .seconds(1)
        repeat {
            try? await Task.sleep(for: .milliseconds(70))
            content.layoutSubtreeIfNeeded()
            refreshButtonFrames(in: content)
            if let now = frame(), now == previous { break }
            previous = frame() ?? .null
        } while ContinuousClock.now < layoutDeadline
        content.layoutSubtreeIfNeeded()
        refreshButtonFrames(in: content)
        guard let frame = frame(), !frame.isEmpty else { settingsDiagnostics.append("Missing frame for \(target)"); return false }
        capture(content, extension: "picker-\(titles.firstIndex(of: target) ?? 0).png")
        let selection = SmokeMenuSelection(titles: titles, target: target)
        NotificationCenter.default.addObserver(selection, selector: #selector(SmokeMenuSelection.menuOpened(_:)),
                                               name: NSMenu.didBeginTrackingNotification, object: nil)
        defer { NotificationCenter.default.removeObserver(selection) }
        let point = content.convert(NSPoint(x: frame.midX, y: frame.midY), from: nil)
        guard content.bounds.contains(point),
              clickWindowLocation(NSPoint(x: frame.midX, y: frame.midY), in: window) else { return false }
        let deadline = ContinuousClock.now + .seconds(2)
        while !selection.selected && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        if !selection.selected {
            settingsDiagnostics.append("Menu \(target) at \(frame) observed \(selection.observedTitles), hit \(String(describing: content.hitTest(point).map { type(of: $0) }))")
        }
        if selection.selected {
            // Await the native popup closing animation before opening the next one.
            try? await Task.sleep(for: .milliseconds(450))
        }
        return selection.selected
    }

    private func exerciseSpaceNavigation(model: BridgeAppModel) async -> Bool {
        guard let workspace = model.macWorkspace, let agent = workspace.agent else { return false }
        let priorToolbox = workspace.toolbox
        func waitForPage(_ page: MacSpacePage) async -> Bool {
            let deadline = ContinuousClock.now + .seconds(2)
            while (agent.smokeSpacePage != page || agent.smokeSpacePickerFrame == nil) && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(30))
            }
            if agent.smokeSpacePage == page, agent.smokeSpacePickerFrame != nil { return true }
            settingsDiagnostics.append("Space did not display \(page). Current page: \(String(describing: agent.smokeSpacePage)).")
            return false
        }
        func clickSpaceSegment(_ index: Int, screenshot: String) -> Bool {
            guard let window = visibleWorkbench, let content = window.contentView else { return false }
            content.layoutSubtreeIfNeeded()
            refreshButtonFrames(in: content)
            guard let frame = agent.smokeSpacePickerFrame, !frame.isEmpty else { return false }
            capture(content, extension: screenshot)
            let location = NSPoint(x: frame.minX + frame.width * (CGFloat(index) + 0.5) / 2, y: frame.midY)
            let point = content.convert(location, from: nil)
            if content.bounds.contains(point), click(content, at: point, in: window) { return true }
            settingsDiagnostics.append("The Space picker could not receive an event at \(point) from \(frame).")
            return false
        }
        let spaceTitle = String(localized: "space.title")
        let toolboxTitle = String(localized: "mac.workspace.toolbox")
        let spaceMenu = NSApp.mainMenu?.item(withTitle: spaceTitle)?.submenu
        spaceMenu?.update()
        guard let spaceMenu, let toolboxItem = spaceMenu.item(withTitle: toolboxTitle), toolboxItem.isEnabled else {
            settingsDiagnostics.append("The Space menu did not contain an enabled Toolbox item.")
            return false
        }
        spaceMenu.performActionForItem(at: spaceMenu.index(of: toolboxItem))
        guard await waitForPage(.toolbox), workspace.toolbox === priorToolbox else {
            settingsDiagnostics.append("The Toolbox menu did not enter Space without opening a second tool window.")
            return false
        }
        guard clickWorkbenchButton(ids: ["workspace.space"], frame: agent.smokeSpaceFrame, screenshot: "space-menu.png") else {
            settingsDiagnostics.append("The Space sidebar control did not accept a click.")
            return false
        }
        guard await waitForPage(.files), clickSpaceSegment(1, screenshot: "space-files.png"),
              await waitForPage(.toolbox), workspace.toolbox === priorToolbox,
              clickSpaceSegment(0, screenshot: "space-toolbox.png") else { return false }
        return await waitForPage(.files)
    }

    private func exerciseToolbox(model: BridgeAppModel) async -> Bool {
        guard let workspace = model.macWorkspace, workspace.toolbox == nil else { return false }
        let activity = model.updates.installation.activity.activityCount
        let catalog = MacToolboxCatalog.groups(locale: Locale(identifier: "en")).flatMap(\.tools)
        let unavailable = catalog.filter { !$0.isAvailable }.map(\.id)
        guard Set(unavailable) == ["level", "motion", "compass", "measure", "barometer"] else { return false }
        for toolID in unavailable { model.openToolbox(toolID: toolID) }
        guard workspace.toolbox == nil, model.updates.installation.activity.activityCount == activity else { return false }
        model.openToolbox(toolID: "ping")
        guard let first = workspace.toolbox, first.window?.isVisible == true else { return false }
        let command = first.services.networkOwner
        let started = command.start(.ping("127.0.0.1"), locale: Locale(identifier: "en"))
        let completed = await command.drain(timeout: 9)
        let pingPassed = started && completed && command.result?.contains("4 packets received") == true
        guard await workspace.closeToolbox() else { return false }
        model.openToolbox(toolID: "ping")
        let reopened = workspace.toolbox
        let distinctOwner = reopened?.window?.isVisible == true
            && reopened?.services.mediaEnvironment !== first.services.mediaEnvironment
        let remoteToolsAvailable = ["terminal", "vnc"].allSatisfy { id in
            MacToolboxCatalog.isAvailable(toolID: id)
        }
        model.openToolbox(toolID: "terminal")
        let terminalVisible = workspace.toolbox === reopened && reopened?.window?.isVisible == true
        model.openToolbox(toolID: "vnc")
        let vncVisible = workspace.toolbox === reopened && reopened?.window?.isVisible == true
        let closed = await workspace.closeToolbox()
        return pingPassed && distinctOwner && remoteToolsAvailable && terminalVisible && vncVisible && closed
    }

    private var projectTaskFixtureEndpoint: URL? {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(of: "--project-task-fixture"), flag + 1 < arguments.count,
              let endpoint = URL(string: arguments[flag + 1]), endpoint.scheme == "http",
              endpoint.host == "127.0.0.1", endpoint.port != nil else { return nil }
        return endpoint
    }

    private func clickApproval(in workspace: HostAgentWorkspace, allow: Bool, screenshot: String) -> Bool {
        clickWorkbenchButton(ids: allow ? ["approval.approve", "mac.agent.allowOnce"] : ["approval.deny", "mac.agent.deny"],
                             frame: workspace.smokeApprovalFrames[allow], screenshot: screenshot)
    }

    private var visibleWorkbench: NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.identifier == UnifiedMacWorkspace.workbenchWindowIdentifier }
    }

    private func clickWorkbenchButton(ids: [String], frame: @autoclosure () -> CGRect?, screenshot: String?) -> Bool {
        guard let window = visibleWorkbench, let content = window.contentView else { return false }
        content.layoutSubtreeIfNeeded()
        refreshButtonFrames(in: content)
        if let screenshot { capture(content, extension: screenshot) }
        if ids.contains(where: { pressAccessibilityButton(content, id: $0) }) { return true }
        guard let frame = frame(), !frame.isEmpty else { return false }
        let point = NSPoint(x: frame.midX, y: frame.midY)
        return content.bounds.contains(content.convert(point, from: nil)) && clickWindowLocation(point, in: window)
    }

    private func refreshButtonFrames(in view: NSView) {
        (view as? MacWorkbenchButtonFrameReader.Anchor)?.recordFrame()
        for subview in view.subviews { refreshButtonFrames(in: subview) }
    }

    private func descendant<T: NSView>(_ type: T.Type, in root: NSView) -> T? {
        if let view = root as? T { return view }
        for child in root.subviews {
            if let view = descendant(type, in: child) { return view }
        }
        return nil
    }

    private func closeFixtureSheet(_ sheet: NSWindow, id: String) async -> Bool {
        let parent = sheet.sheetParent
        sheet.makeKey()
        if let content = sheet.contentView, !pressAccessibilityButton(content, id: id) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: sheet.windowNumber, context: nil, characters: "\u{1B}",
                charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53) else { return false }
            sheet.sendEvent(event)
        }
        let deadline = ContinuousClock.now + .seconds(2)
        while (sheet.isVisible || parent?.attachedSheet === sheet) && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(40))
        }
        guard !sheet.isVisible, parent?.attachedSheet !== sheet else { return false }
        // In-process AX presses do not get the window-server activation of a physical click.
        if let parent, parent.isVisible, parent.attachedSheet == nil {
            parent.makeKeyAndOrderFront(nil)
        }
        return true
    }

    private func verifyThreadOwnership(_ agent: HostAgentWorkspace, endpoint: URL) async {
        let folder = root.appendingPathComponent("Source project", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)) != nil,
              let project = await agent.addWorkspace(name: folder.lastPathComponent, rootURL: folder) else { finish(["project": false]); return }
        var checks: [String: Bool] = [:]
        var approvals: [String] = []
        func run(_ prompt: String, projectID: UUID?) async -> Bool {
            guard agent.startNamedAgentFixture(prompt, modelID: "thread-tools-fixture", endpoint: endpoint, projectID: projectID) else { return false }
            let limit = ContinuousClock.now + .seconds(25)
            var reviewed = Set<String>()
            while agent.isSending, ContinuousClock.now < limit {
                if let card = agent.pendingApproval, !reviewed.contains(card.callID) {
                    guard MacTaskActionPreview(card.toolCall) != nil && card.canAllow else { break }
                    await agent.resolveApproval(card, allow: true)
                    reviewed.insert(card.callID)
                    approvals.append(card.toolName)
                }
                try? await Task.sleep(for: .milliseconds(60))
            }
            return !agent.isSending
        }
        guard await openNewProjectTask(workspace: agent, projectID: project.id),
              await run("Create a new task named Reference notebook. The source marker is Floe-Origin-34.", projectID: project.id),
              let owner = agent.selectedID,
              let spawned = agent.conversations.first(where: { $0.title == "Reference notebook" && $0.id != owner }) else {
            finish(["spawn": false, "reviews": approvals, "diagnostics": agent.smokeRunDiagnostics]); return
        }
        checks["sourceStayedSelected"] = owner != spawned.id && agent.selectedConversationWorkspace?.id == project.id
        await agent.select(spawned.id)
        checks["separateInitialMessage"] = agent.messages.map(\.content) == ["Prepare the separate notebook."]
        checks["independentPermissionsAndFolder"] = agent.taskApprovalMode == .ask && agent.fileWorkspaceForCurrentTask?.kind == .privateTask
        let history = await run("Find the task whose messages contain the source marker and read its original request.", projectID: nil)
        checks["readSource"] = history && agent.messages.contains { $0.role == "assistant" && $0.content.contains("History confirmed: Floe-Origin-34") }
        let prior = Set(agent.conversations.map(\.id))
        let settled = await run("Do not create a new task. Summarize the notebook.", projectID: nil)
        checks["noImplicitSpawn"] = settled && prior == Set(agent.conversations.map(\.id))
        finish(["checks": checks, "reviews": approvals, "diagnostics": agent.smokeRunDiagnostics])
    }

    private func verifyChildExecution(_ agent: HostAgentWorkspace, endpoint: URL) async {
        let folder = root.appendingPathComponent("Child execution project", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)) != nil,
              let project = await agent.addWorkspace(name: folder.lastPathComponent, rootURL: folder) else {
            finish(["project": false]); return
        }
        var checks: [String: Bool] = [:]
        var events: [String] = []
        agent.allowsWorkspaceWrites = true
        for (label, allow) in [("accepted", true), ("denied", false)] {
            guard await openNewProjectTask(workspace: agent, projectID: project.id),
                  await agent.setApprovalMode(.ask, asDefault: false),
                  agent.startNamedAgentFixture("Delegate the \(label) independent command check.", modelID: "child-execution-fixture",
                                               endpoint: endpoint, projectID: project.id) else { break }
            let limit = ContinuousClock.now + .seconds(40)
            var decisions = Set<String>()
            while agent.isSending, ContinuousClock.now < limit {
                if let approval = agent.pendingApproval, !decisions.contains(approval.callID) {
                    let startsChild = approval.toolName == "delegate"
                    guard startsChild || (approval.toolName == MacNativeShellTool.name && approval.text?.contains("child-\(label).txt") == true) else {
                        events.append("Unexpected approval: " + approval.toolName); break
                    }
                    try? await Task.sleep(for: .milliseconds(120))
                    let choice = startsChild || allow
                    if clickApproval(in: agent, allow: choice, screenshot: "child-\(label)-\(startsChild ? "delegate" : "command").png") {
                        decisions.insert(approval.callID)
                        events.append("\(label) \(approval.toolName) \(choice)")
                    }
                }
                try? await Task.sleep(for: .milliseconds(60))
            }
            let path = folder.appendingPathComponent("child-\(label).txt")
            let changed = (try? String(contentsOf: path, encoding: .utf8)) == "child-verified\n"
            let matched = allow ? changed : !FileManager.default.fileExists(atPath: path.path)
            if let owner = agent.selectedID {
                let children = await agent.childSubagents(of: owner)
                checks[label] = !agent.isSending && decisions.count == 2 && matched
                    && children.count == 1 && children[0].conversationID == owner
                    && (children[0].findings?.contains(label) == true || (!allow && children[0].status != .completed))
            }
            if agent.isSending { agent.stop(); break }
        }
        finish(["checks": checks, "reviews": events, "diagnostics": agent.smokeRunDiagnostics])
    }

    private func verifyChildDetail(_ agent: HostAgentWorkspace) async -> Bool {
        guard let window = visibleWorkbench, let owner = agent.selectedID else { return false }
        let limit = ContinuousClock.now + .seconds(4)
        while agent.childSubagents.presentedChildren.first?.conversationID != owner, ContinuousClock.now < limit {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let child = agent.childSubagents.presentedChildren.first, child.conversationID == owner,
              child.findings?.contains("Acceptance") == true, child.status == .completed,
              clickWorkbenchButton(ids: ["mac.child.disclosure"], frame: MacChildTasksView.smokeDisclosureFrame, screenshot: nil) else {
            settingsDiagnostics.append("Could not expand the completed child"); return false
        }
        try? await Task.sleep(for: .milliseconds(150))
        guard clickWorkbenchButton(ids: ["mac.child.details." + child.id.uuidString], frame: MacChildTasksView.smokeDetailFrame, screenshot: nil) else {
            settingsDiagnostics.append("Missing child details button"); return false
        }
        while window.attachedSheet?.contentView == nil, ContinuousClock.now < limit {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let sheet = window.attachedSheet, let content = sheet.contentView else {
            settingsDiagnostics.append("Child details did not open"); return false
        }
        capture(content, extension: "project-child-details.png")
        let closed = await closeFixtureSheet(sheet, id: "mac.child.details.done")
        return closed && agent.selectedID == owner
    }

    /// Click the actual displayed text when the SwiftUI accessibility tree does
    /// not publish a separate element for an inline Markdown link.
    private func clickRenderedText(_ terms: [String], in view: NSView, window: NSWindow) -> Bool {
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return false }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { return false }
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["en-US", "zh-Hans"]
        guard (try? VNImageRequestHandler(cgImage: image).perform([request])) != nil else { return false }
        for observation in request.results ?? [] {
            guard let candidate = observation.topCandidates(1).first else { continue }
            for term in terms {
                guard let range = candidate.string.range(of: term, options: [.caseInsensitive]),
                      let box = try? candidate.boundingBox(for: range) else { continue }
                let point = CGPoint(x: view.bounds.minX + box.boundingBox.midX * view.bounds.width,
                                    y: view.bounds.minY + (view.isFlipped ? 1 - box.boundingBox.midY : box.boundingBox.midY) * view.bounds.height)
                return clickWindowLocation(view.convert(point, to: nil), in: window)
            }
        }
        return false
    }

    private func exerciseModelBrowser(_ model: BridgeAppModel, endpoint: URL) async {
        guard let agent = await readyFixtureWorkbench(model), let browser = model.macWorkspace?.browser else {
            finish(["ready": false]); return
        }
        let folderA = root.appendingPathComponent("Browser Alpha", isDirectory: true)
        let folderB = root.appendingPathComponent("Browser Beta", isDirectory: true)
        guard (try? FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: false)) != nil,
              (try? FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: false)) != nil,
              let projectA = await agent.addWorkspace(name: "Browser Alpha", rootURL: folderA, selectForNewTask: false),
              let projectB = await agent.addWorkspace(name: "Browser Beta", rootURL: folderB, selectForNewTask: false),
              agent.startNamedAgentFixture("Inspect the Alpha page and save its attached PDF.", modelID: "task-browser-alpha",
                                           endpoint: endpoint, projectID: projectA.id) else {
            finish(["started": false]); return
        }
        let marker = report.deletingLastPathComponent().appendingPathComponent("alpha-awaiting-beta")
        let betaReady = report.deletingLastPathComponent().appendingPathComponent("beta-downloading")
        var decisions = Set<String>()
        var unrequestedPresentation = false
        var alpha: UUID?
        var beta: UUID?
        var parallel = false
        var stoppedBeta = false
        let deadline = ContinuousClock.now + .seconds(45)
        while ContinuousClock.now < deadline {
            if browser.isPresented { unrequestedPresentation = true }
            if let approval = agent.pendingApproval, approval.toolName.hasPrefix("browser."),
               !decisions.contains(approval.callID),
               clickApproval(in: agent, allow: true, screenshot: "browser-" + approval.callID + ".png") {
                decisions.insert(approval.callID)
            }
            if beta == nil, FileManager.default.fileExists(atPath: marker.path),
               let current = agent.selectedID, agent.activeRunCount == 1,
               await openNewTaskFromSidebar(workspace: agent),
               agent.startNamedAgentFixture("Inspect the Beta page and begin its separate download.", modelID: "task-browser-beta",
                                            endpoint: endpoint, projectID: projectB.id) {
                alpha = current
                beta = agent.uncommittedDraftID
                parallel = agent.activeRunCount == 2
            }
            if !stoppedBeta, let beta, FileManager.default.fileExists(atPath: betaReady.path) {
                agent.stopTask(beta)
                stoppedBeta = true
            }
            if stoppedBeta, agent.activeRunCount == 0 { break }
            try? await Task.sleep(for: .milliseconds(40))
        }
        var originalReceipt = false
        var finished = false
        if let alpha {
            await agent.select(alpha)
            finished = agent.messages.contains {
                $0.content == "Alpha task browser verified. The stale element click failed before changing the page."
            }
            originalReceipt = agent.transcriptEventsByRun.values.flatMap { $0 }.contains {
                $0.kind == .toolResult && $0.payloadJSON.contains("\"browser.download\"")
                    && $0.payloadJSON.contains("outputFilesJSON")
            }
        }
        let savedAlpha = folderA.appendingPathComponent("alpha.pdf")
        finish(["parallel": parallel, "stoppedBeta": stoppedBeta, "noFrontSwitch": !unrequestedPresentation,
                "alphaFinished": finished, "alphaReceipt": originalReceipt,
                "alphaFile": (try? Data(contentsOf: savedAlpha)).map { FloeDigest.sha256Hex($0) } ?? "",
                "noBetaFile": !FileManager.default.fileExists(atPath: folderB.appendingPathComponent("beta.pdf").path),
                "approvals": decisions.sorted(), "diagnostics": agent.smokeRunDiagnostics + settingsDiagnostics])
    }

    private func verifyTaskBrowser(_ workspace: UnifiedMacWorkspace, agent: HostAgentWorkspace, endpoint: URL,
                                   leavesBrowserOpen: Bool = false) async -> Bool {
        guard let window = visibleWorkbench, let content = window.contentView, let owner = agent.selectedID,
              let browser = workspace.browser else { return false }
        let url = endpoint.appendingPathComponent("workbench-page")
        let marker = "Draft before opening the browser"
        func waitUntil(_ condition: () -> Bool) async -> Bool {
            let limit = ContinuousClock.now + .seconds(5)
            while !condition(), ContinuousClock.now < limit { try? await Task.sleep(for: .milliseconds(50)) }
            return condition()
        }
        func draftEditor() async -> NSTextView? {
            guard window.attachedSheet == nil else { return nil }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            guard await waitUntil({ window.isKeyWindow }),
                  clickWorkbenchButton(ids: ["thread.composer.expand"], frame: HostAgentWorkspaceView.smokeExpandFrame, screenshot: nil),
                  await waitUntil({ window.attachedSheet?.contentView.flatMap { descendant(NSTextView.self, in: $0) } != nil }),
                  let body = window.attachedSheet?.contentView else { return nil }
            return descendant(NSTextView.self, in: body)
        }
        var foundLinkRun = false
        func renderedLink(in view: NSView) -> (NSTextView, NSPoint)? {
            guard !view.isHiddenOrHasHiddenAncestor, view.window === window else { return nil }
            if let text = view as? NSTextView, text.delegate is MacChatLinkText.Coordinator,
               let layout = text.layoutManager, let container = text.textContainer {
                let content = text.attributedString()
                var linkRange: NSRange?
                content.enumerateAttribute(.link, in: NSRange(location: 0, length: content.length)) { target, range, stop in
                    if (target as? URL) == url || (target as? String) == url.absoluteString {
                        linkRange = range
                        stop.pointee = true
                    }
                }
                if let linkRange {
                    foundLinkRun = true
                    layout.ensureLayout(for: container)
                    let glyphs = layout.glyphRange(forCharacterRange: linkRange, actualCharacterRange: nil)
                    for glyph in glyphs.location..<NSMaxRange(glyphs) {
                        let bounds = layout.boundingRect(forGlyphRange: NSRange(location: glyph, length: 1), in: container)
                            .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
                            .intersection(text.visibleRect)
                        guard bounds.width >= 1, bounds.height >= 1 else { continue }
                        let point = NSPoint(x: bounds.midX, y: bounds.midY)
                        if NSLocationInRange(text.characterIndexForInsertion(at: point), linkRange) {
                            return (text, point)
                        }
                    }
                }
            }
            for child in view.subviews {
                if let link = renderedLink(in: child) { return link }
            }
            return nil
        }
        func failed(_ reason: String) -> Bool { settingsDiagnostics.append("Task browser: " + reason); return false }
        guard let editor = await draftEditor(), let sheet = window.attachedSheet else { return failed("draft editor missing") }
        editor.insertText(marker, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        guard await closeFixtureSheet(sheet, id: "thread.composer.expanded.done") else { return failed("draft editor did not close") }
        guard await waitUntil({ window.attachedSheet == nil }) else { return failed("another sheet still covers the chat") }
        window.makeKeyAndOrderFront(nil)
        guard await waitUntil({ window.isKeyWindow }) else { return failed("chat window did not regain focus") }
        content.layoutSubtreeIfNeeded()
        capture(content, extension: "chat-link.png")
        guard await waitUntil({ renderedLink(in: content) != nil }),
              let (text, point) = renderedLink(in: content) else {
            return failed(foundLinkRun ? "link has no visible glyph in the chat" : "chat has no rendered link to the fixture page")
        }
        // Post down and up together. NSTextView tracks a physical click until
        // mouseUp, so synchronously sending down before enqueuing up can stall.
        guard click(text, at: point, in: window) else { return failed("could not click the chat link") }
        browserOpenedFromMessageLink = await waitUntil { browser.isPresented }
        guard browserOpenedFromMessageLink else { return failed("the clicked Markdown link did not open the browser") }
        guard await waitUntil({ browser.taskTools.session(for: owner)?.activeWebView?.title == "Floe browser fixture" }),
              let session = browser.taskTools.session(for: owner), let page = session.activeWebView,
              page.url == url, page.window === window, agent.windowShowsTask,
              page.bounds.width < content.bounds.width * 0.7 else {
            return failed("page did not load alongside the owning task")
        }
        capture(content, extension: "browser-task.png")
        let other = browser.taskTools.ensureSession(for: UUID())
        other.userNavigate(to: url.absoluteString)
        guard let otherPage = other.activeWebView, otherPage !== page,
              otherPage.configuration.websiteDataStore !== page.configuration.websiteDataStore else {
            return failed("the browser shared a page or website state between tasks")
        }
        defer { browser.taskTools.retireSession(for: other.conversationID) }
        if leavesBrowserOpen {
            return true
        }
        // The synthetic page puts Next at the top left. Use AppKit events
        // directly so this test exercises link activation without relying on
        // the asynchronous JavaScript evaluation API.
        let nextLinkPoint = NSPoint(x: 24, y: page.isFlipped ? 16 : page.bounds.height - 16)
        guard page.bounds.contains(nextLinkPoint), click(page, at: nextLinkPoint, in: window) else {
            return failed("fixture link could not be clicked")
        }
        guard await waitUntil({ session.activeWebView?.title == "Floe second page" }),
              let popup = session.activeWebView, popup !== page,
              session.tabs.count == 2, let popupID = session.activeTabID,
              popup.configuration.websiteDataStore === page.configuration.websiteDataStore else {
            return failed("the new tab did not open in the owning task session")
        }
        session.userCloseTab(popupID)
        guard session.activeWebView === page else { return failed("the original tab was not restored") }
        session.userNavigate(to: endpoint.appendingPathComponent("workbench-next").absoluteString)
        guard await waitUntil({ page.title == "Floe second page" }), page.canGoBack else { return failed("user link did not navigate in place") }
        session.userGoBack()
        guard await waitUntil({ page.title == "Floe browser fixture" }) else { return failed("back history missing") }
        func pressChromeButton(_ id: String, anchor: String) -> Bool {
            if pressAccessibilityButton(content, id: id) { return true }
            func findAnchor(_ view: NSView) -> NSView? {
                if view.identifier?.rawValue == anchor { return view }
                return view.subviews.lazy.compactMap(findAnchor).first
            }
            guard let button = findAnchor(content), !button.bounds.isEmpty else { return false }
            return click(button, at: NSPoint(x: button.bounds.midX, y: button.bounds.midY), in: window)
        }
        guard let modelControl = try? browser.taskTools.beginModelControl(owner: owner, runID: UUID()),
              modelControl.session === session, session.isModelActive,
              click(page, at: NSPoint(x: page.bounds.midX, y: page.bounds.midY), in: window),
              await waitUntil({ session.isUserControlling }),
              !session.isModelControlCurrent(modelControl.lease), session.activeWebView === page else {
            return failed("using the browser did not take control of the same model page")
        }
        guard await waitUntil({ pressChromeButton("workspace.browser.returnControl", anchor: "workspace.browser.returnControlAnchor") }),
              await waitUntil({ !session.isUserControlling && !browser.isPresented }),
              session.activeWebView === page, agent.windowShowsTask else {
            return failed("the browser did not return control and close the inspector")
        }
        browser.present()
        guard await waitUntil({ browser.isPresented && page.window === window }) else { return failed("the inspector did not reopen its task page") }
        browserReturnButtonPressed = pressChromeButton("workspace.browser.backToTask", anchor: "workspace.browser.returnAnchor")
        guard browserReturnButtonPressed else { return failed("could not press the return button") }
        guard await waitUntil({ !browser.isPresented && agent.windowShowsTask }), agent.selectedID == owner,
              let reopened = await draftEditor(), let reopenedSheet = window.attachedSheet else { return failed("could not return to task") }
        let keptDraft = reopened.string == marker
        reopened.insertText("", replacementRange: NSRange(location: 0, length: (reopened.string as NSString).length))
        guard await closeFixtureSheet(reopenedSheet, id: "thread.composer.expanded.done"), keptDraft else { return failed("draft was lost") }
        return true
    }

    private func verifyBrowserDownload(_ workspace: UnifiedMacWorkspace, owner: UUID, endpoint: URL) async -> String? {
        guard let browser = workspace.browser, let window = visibleWorkbench, let content = window.contentView else { return nil }
        let output = root.appendingPathComponent("fixture-browser.pdf")
        browser.downloads.smokeDestination = output
        defer { browser.downloads.smokeDestination = nil }
        FileHandle.standardError.write(Data("Browser fixture loaded the task page\n".utf8))
        let url = endpoint.appendingPathComponent("document.pdf")
        browser.present(url: url)
        let documentDeadline = ContinuousClock.now + .seconds(5)
        while (!browser.isPresented || browser.taskTools.session(for: owner)?.activeWebView?.url != url)
                && ContinuousClock.now < documentDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let session = browser.taskTools.session(for: owner), let page = session.activeWebView, page.url == url else {
            settingsDiagnostics.append("The task did not open its authenticated document."); return nil
        }
        FileHandle.standardError.write(Data("Browser fixture navigated to the PDF\n".utf8))
        func downloadAnchor(in view: NSView) -> NSView? {
            if view.identifier?.rawValue == "workspace.browser.downloadAnchor" { return view }
            return view.subviews.lazy.compactMap(downloadAnchor).first
        }
        let panelDeadline = ContinuousClock.now + .seconds(5)
        var clicked = false
        var panel: NSSavePanel?
        while ContinuousClock.now < panelDeadline {
            if let sheet = window.attachedSheet as? NSSavePanel { panel = sheet; break }
            if !clicked {
                clicked = pressAccessibilityButton(content, id: "workspace.browser.download")
                if !clicked, let anchor = downloadAnchor(in: content), !anchor.bounds.isEmpty {
                    clicked = click(anchor, at: NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), in: window)
                }
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard let panel else { settingsDiagnostics.append("No native download destination panel was shown."); return nil }
        FileHandle.standardError.write(Data("Browser fixture opened the destination sheet\n".utf8))
        try? await Task.sleep(for: .milliseconds(300))
        guard let panelDirectory = panel.directoryURL, panelDirectory.resolvingSymlinksInPath() == root.resolvingSymlinksInPath() else {
            settingsDiagnostics.append("The destination sheet did not enter the isolated fixture directory."); return nil
        }
        panel.makeKey()
        for type: NSEvent.EventType in [.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0,
                                            windowNumber: panel.windowNumber, context: nil,
                                            characters: "\r", charactersIgnoringModifiers: "\r",
                                            isARepeat: false, keyCode: 36) {
                NSApp.postEvent(event, atStart: false)
            }
        }
        let transferDeadline = ContinuousClock.now + .seconds(55)
        var bytes: Data?
        while bytes == nil && ContinuousClock.now < transferDeadline {
            bytes = try? Data(contentsOf: output)
            if bytes == nil { try? await Task.sleep(for: .milliseconds(60)) }
        }
        guard let bytes, bytes.starts(with: Data("%PDF-".utf8)) else {
            let sheetStillOpen = window.attachedSheet != nil
            let transferError = browser.downloads.error(for: owner) ?? "none"
            settingsDiagnostics.append("The PDF wasn’t saved. Sheet open: \(sheetStillOpen); transfer error: \(transferError).")
            browser.downloads.cancelAll()
            return nil
        }
        let pageURL = endpoint.appendingPathComponent("workbench-next")
        var routed = URLComponents(url: pageURL, resolvingAgainstBaseURL: false)
        routed?.queryItems = [URLQueryItem(name: "code", value: "synthetic-oauth-value")]
        routed?.fragment = "private-example"
        guard let visitedURL = routed?.url else { return nil }
        session.userNavigate(to: visitedURL.absoluteString)
        let pageDeadline = ContinuousClock.now + .seconds(4)
        while (page.title != "Floe second page" || page.url != visitedURL) && ContinuousClock.now < pageDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard page.url == visitedURL, page.title == "Floe second page" else { return nil }
        capture(content, extension: "browser-saved.png")
        browser.returnToTask()
        let returnDeadline = ContinuousClock.now + .seconds(3)
        while browser.isPresented && ContinuousClock.now < returnDeadline { try? await Task.sleep(for: .milliseconds(40)) }
        browserReturnButtonPressed = !browser.isPresented && workspace.agent?.selectedID == owner
        return browserReturnButtonPressed ? FloeDigest.sha256Hex(bytes) : nil
    }

    private func verifyBrowserRelaunch(_ workspace: UnifiedMacWorkspace, agent: HostAgentWorkspace, endpoint: URL) async {
        guard let browser = workspace.browser, let taskID = agent.conversations.first?.id,
              await openTaskFromCenter(taskID, agent: agent), browser.taskTools.session(for: taskID) == nil else {
            finish(["reopenedTask": false, "diagnostics": settingsDiagnostics]); return
        }
        browser.present()
        let url = endpoint.appendingPathComponent("workbench-next")
        let deadline = ContinuousClock.now + .seconds(6)
        while browser.taskTools.session(for: taskID)?.activeWebView?.title != "Floe second page" && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let page = browser.taskTools.session(for: taskID)?.activeWebView
        let restored = page?.url == url && page?.title == "Floe second page" && browser.isPresented
        finish(["reopenedTask": true, "restoredPageOnOpen": restored, "taskID": taskID.uuidString])
    }

    private func verifyExpandedComposer(_ agent: HostAgentWorkspace) async -> Bool {
        let owner = agent.selectedID
        let messageCount = agent.messages.count
        let sample = Array(repeating: "原生草稿 Mixed text", count: 12).joined(separator: "\n")
        let windowReady = ContinuousClock.now + .seconds(3)
        while (visibleWorkbench?.isKeyWindow != true || visibleWorkbench?.attachedSheet != nil) && ContinuousClock.now < windowReady {
            try? await Task.sleep(for: .milliseconds(50))
        }
        var sheet: NSWindow?
        defer { if let sheet, sheet.isVisible { sheet.performClose(nil) } }
        for first in [true, false] {
            guard clickWorkbenchButton(ids: ["thread.composer.expand"], frame: HostAgentWorkspaceView.smokeExpandFrame, screenshot: nil) else { settingsDiagnostics.append("Expand button missing"); return false }
            let deadline = ContinuousClock.now + .seconds(3)
            var editor: NSTextView?
            while editor == nil && ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
                sheet = visibleWorkbench?.attachedSheet
                if let root = sheet?.contentView { editor = descendant(NSTextView.self, in: root) }
            }
            guard let editor, let active = sheet else { settingsDiagnostics.append("Expand button did not present editor; first=\(first), sheet=\(sheet != nil)"); return false }
            if first {
                editor.insertText(sample, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
                editor.setSelectedRange(NSRange(location: 4, length: 2))
                if let content = active.contentView { capture(content, extension: "expanded-composer.png") }
            } else {
                guard editor.string == sample, editor.selectedRange() == NSRange(location: 4, length: 2) else { settingsDiagnostics.append("Editor reopen text=\(editor.string == sample) selection=\(editor.selectedRange())"); return false }
                editor.insertText("", replacementRange: NSRange(location: 0, length: (sample as NSString).length))
            }
            guard await closeFixtureSheet(active, id: "thread.composer.expanded.done") else { settingsDiagnostics.append("Editor Done failed"); return false }
        }
        return agent.selectedID == owner && !agent.isSending && agent.messages.count == messageCount
    }

    private func verifyAttachmentPreview(_ agent: HostAgentWorkspace, expected: URL) async -> Bool {
        guard let owner = agent.selectedID, let item = agent.messages.flatMap({ AttachmentChipItem.items(in: $0.parts) }).last,
              visibleWorkbench != nil else { settingsDiagnostics.append("Attachment fixture unavailable"); return false }
        let limit = ContinuousClock.now + .seconds(3)
        while visibleWorkbench?.attachedSheet == nil && ContinuousClock.now < limit {
            _ = clickWorkbenchButton(ids: ["thread.attachment." + item.id], frame: HostAgentWorkspaceView.smokeAttachmentFrames[item.id], screenshot: nil)
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let sheet = visibleWorkbench?.attachedSheet, let body = sheet.contentView else { settingsDiagnostics.append("Attachment chip did not open sheet"); return false }
        defer { if sheet.isVisible { sheet.performClose(nil) } }
        let opened = descendant(QLPreviewView.self, in: body)?.previewItem?.previewItemURL
        guard opened?.standardizedFileURL == expected.standardizedFileURL else { settingsDiagnostics.append("Quick Look did not receive the saved attachment"); return false }
        capture(body, extension: "attachment-preview.png")
        let closed = await closeFixtureSheet(sheet, id: "thread.attachment.preview.done")
        return closed && agent.selectedID == owner
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
        guard await MacComposerImport.verify(in: agent, file: reference) else {
            settingsDiagnostics.append("Composer file, image or text paste failed.")
            return false
        }
        guard let first = await agent.addWorkspace(name: "Fixture Project", rootURL: project),
              let repeated = await agent.addWorkspace(name: "Fixture Project", rootURL: project, selectForNewTask: false),
              repeated.id == first.id,
              agent.selectedWorkspaceID == first.id,
              agent.workspaces.filter({ $0.id == first.id }).count == 1,
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
              NSApp.mainMenu?.item(withTitle: String(localized: "space.title")) == nil,
              NSApp.windows.contains(where: { $0.title == "Floe Bridge" && $0.isVisible }) else { return false }
        guard let port = model.smokePort, (try? await callPairedBridge(port: port)) == true else { return false }
        model.reopenPreferredWindow()
        model.openToolbox()
        guard model.macWorkspace == nil else { return false }
        model.openAgentWorkspace()
        return NSApp.activationPolicy() == .regular && model.isAgentMode
            && model.macWorkspace?.agent != nil && model.macWorkspace !== initialWorkspace
            && visibleWorkbench != nil
    }

    private func clickSettingsPane(_ pane: BridgeAppModel.SettingsPane, model: BridgeAppModel, in window: NSWindow) -> Bool {
        guard let content = window.contentView else { return false }
        content.layoutSubtreeIfNeeded()
        refreshButtonFrames(in: content)
        if pressAccessibilityButton(content, id: "settings.pane." + pane.rawValue) { return true }
        guard let frame = model.smokeSettingsFrames[pane], !frame.isEmpty else { return false }
        return clickWindowLocation(NSPoint(x: frame.midX, y: frame.midY), in: window)
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
        guard clickSettingsPane(.permissions, model: model, in: window) else { return false }
        try? await Task.sleep(for: .milliseconds(180))
        guard model.settingsPane == .permissions, model.smokeAgentSettingsSheet === window else { return false }
        if let content = window.contentView {
            capture(content, extension: "settings-permissions.png")
            content.layoutSubtreeIfNeeded()
            refreshButtonFrames(in: content)
            if !pressAccessibilityButton(content, id: "settings.permissions.allowActions"),
               let frame = MacPermissionsSettingsView.smokeActionsFrame {
                _ = clickWindowLocation(NSPoint(x: frame.maxX - 15, y: frame.midY), in: window)
            }
            let toggleDeadline = ContinuousClock.now + .seconds(2)
            while workspace.allowsWorkspaceWrites && ContinuousClock.now < toggleDeadline {
                try? await Task.sleep(for: .milliseconds(40))
            }
            guard !workspace.allowsWorkspaceWrites && !preferences.bool(forKey: "floe.mac.workspace.allowWrites") else {
                settingsDiagnostics.append("The permission switch did not change the saved action setting.")
                return false
            }
            workspace.allowsWorkspaceWrites = true
        } else { return false }
        for pane in [BridgeAppModel.SettingsPane.webSearch, .usage] {
            guard clickSettingsPane(pane, model: model, in: window) else { return false }
            let selectedDeadline = ContinuousClock.now + .seconds(2)
            while model.settingsPane != pane && ContinuousClock.now < selectedDeadline {
                try? await Task.sleep(for: .milliseconds(30))
            }
            guard model.settingsPane == pane, let content = window.contentView else { return false }
            try? await Task.sleep(for: .milliseconds(160))
            capture(content, extension: "settings-\(pane.rawValue).png")
        }
        guard (try? await workspace.usageStatistics()) != nil else { return false }
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
@MainActor
private final class SmokeMenuSelection: NSObject {
    let titles: [String]
    let target: String
    var selected = false
    var observedTitles: [String] = []

    init(titles: [String], target: String) {
        self.titles = titles
        self.target = target
    }

    @objc func menuOpened(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu else { return }
        perform(#selector(choose(_:)), with: menu, afterDelay: 0, inModes: [.eventTracking, .common])
    }

    @objc private func choose(_ menu: NSMenu) {
        observedTitles = menu.items.map(\.title)
        let items = menu.items.filter { titles.contains($0.title) }
        defer { menu.cancelTracking() }
        guard items.map(\.title) == titles, let item = items.first(where: { $0.title == target }) else { return }
        menu.performActionForItem(at: menu.index(of: item))
        selected = true
    }
}

#endif
