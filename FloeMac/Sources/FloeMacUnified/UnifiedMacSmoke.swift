// SPDX-License-Identifier: MPL-2.0

#if FLOE_MAC_HOST_SMOKE
import AVKit
import AppKit
import CloudKit
import CoreText
import CryptoKit
import Darwin
import FloeCore
import FloeMacBridgeProtocol
import FloeMacToolbox
import FloeModels
import FloeProviders
import FloeTools
import Foundation
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
        if CommandLine.arguments.contains("--verify-ark-provider") {
            await exerciseArkProvider(model)
            return
        }
        if CommandLine.arguments.contains("--provider-rejection-only"), let endpoint = projectTaskFixtureEndpoint,
           endpoint.host == "127.0.0.1" {
            await exerciseProviderRejection(model, endpoint: endpoint)
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
            let link = endpoint.appendingPathComponent("workbench-page")
            guard await agent.verifyChatSmoke(reply: "Project check completed. [Preview website](\(link.absoluteString))") else {
                finish(["chat": false]); return
            }
            let ok = await verifyTaskBrowser(workspace, agent: agent, endpoint: endpoint)
            finish(["browser": ok, "link": browserOpenedFromMessageLink, "return": browserReturnButtonPressed, "details": settingsDiagnostics])
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
                        projectWorkflow = await agent.verifyProjectTaskWorkflowSmoke(project: project,
                            folder: folder, attachment: document, endpoint: endpoint, chooseMode: { mode in
                                await selectComposerMode(mode, workspace: agent)
                            }, answerQuestion: {
                                guard CommandLine.arguments.contains("--project-question-fixture") else { return true }
                                return await self.answerProjectQuestion(in: agent)
                            }) {
                                guard clickWorkbenchButton(ids: ["thread.plan.close"], frame: agent.smokeClosePlanFrame,
                                                           screenshot: "project-task-plan.png") else { return false }
                                await Task.yield()
                                guard clickWorkbenchButton(ids: ["thread.plan.reopen"], frame: agent.smokeReopenPlanFrame,
                                                           screenshot: nil) else { return false }
                                await Task.yield()
                                return clickWorkbenchButton(ids: ["thread.plan.executeNormal"],
                                                     frame: agent.smokePlanExecuteFrame, screenshot: "project-task-plan.png")
                            } approve: {
                                guard await enterSteerDuringApproval(workspace: agent) else { return false }
                                return clickApproval(in: agent, allow: true, screenshot: "project-task-approval.png")
                            } newProjectTask: {
                                await openNewProjectTask(workspace: agent, projectID: project.id)
                            } approveSubtask: {
                                try? await Task.sleep(for: .milliseconds(160))
                                return clickApproval(in: agent, allow: true, screenshot: "project-subtask-approval.png")
                            }
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
                    if guidance { agent.steer(prompt, attachments: items) { consumedFromDraft = true } }
                    else { agent.enqueue(prompt, attachments: items) { consumedFromDraft = true } }
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
        finish(["orderedSingleAnswer": savedOrder, "historyPagingAndExactSearch": history,
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
        let promptA = "First independent stream"
        let promptB = "Second independent stream"
        drafts.setText(promptA, for: first)
        let firstSent = agent.send(promptA, mode: .chat) { drafts.setText("", for: first) }
        // No suspension before opening the next composer. This hits the
        // first-send race before the first durable conversation exists.
        let secondOpened = agent.selectNewDraft(in: nil) && !agent.isSending
        let second = agent.uncommittedDraftID
        drafts.setText(promptB, for: second)
        let secondSent = agent.send(promptB, mode: .chat) { drafts.setText("", for: second) }
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
        await agent.select(first)
        let firstSaved = agent.messages.contains { $0.role == "user" && $0.content == promptA }
            && !agent.messages.contains { $0.role == "user" && $0.content == promptB }
        await agent.select(second)
        let secondSaved = agent.messages.contains { $0.role == "user" && $0.content == promptB }
            && !agent.messages.contains { $0.role == "user" && $0.content == promptA }
        var results: [String: Any] = ["firstSent": firstSent, "secondOpenedBeforeAdmission": secondOpened && first != second,
                "secondSent": secondSent, "concurrentStreams": concurrentlyRunning,
                "draftAfterStreams": staysOnDraft, "separateSavedMessages": firstSaved && secondSaved && firstUnused && secondUnused]
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
            // Closing a parent run joins its child workers before releasing the OTA activity lease.
            // The App correctly refuses Quit until that asynchronous cleanup finishes.
            let deadline = ContinuousClock.now + .seconds(8)
            while let model = BridgeApplicationDelegate.model,
                  model.updates.installation.activity.activityCount != 0, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(40))
            }
            NSApp.terminate(nil)
        }
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
            guard agent.smokeCreativeMounted, let view = visibleWorkbench?.contentView else { return false }
            capture(view, extension: "creative.png")
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
            return clickWorkbenchButton(ids: ["composer.running.send"], frame: workspace.smokeSteerFrame, screenshot: nil)
        }
        let next = "Summarize the saved project report."
        let guidance = "Mention the checked attachment in your reply."
        let titles = ["chat.thread_composer_view.add_to_message_queue", "chat.thread_composer_view.steer_the_current_run"].map { NSLocalizedString($0, comment: "") }
        guard await selectMenuChoice(frame: workspace.smokeRunningModeFrame, titles: titles, target: titles[0]),
              workspace.runningInputMode == .queue, await submit(next) else { return false }
        var deadline = ContinuousClock.now + .seconds(2)
        while workspace.queuedInputs[id]?.first?.content != next && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        guard let original = workspace.queuedInputs[id]?.first, original.content == next else { return false }
        await workspace.editQueued(original, content: "Edited queue fixture")
        guard let edited = workspace.queuedInputs[id]?.first, edited.id == original.id,
              edited.content == "Edited queue fixture" else { return false }
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
              workspace.runningInputMode == .steer, await submit(guidance) else { return false }
        deadline = ContinuousClock.now + .seconds(2)
        while workspace.lastSteer != guidance && ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return workspace.lastSteer == guidance && workspace.pendingApproval != nil
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

    private func verifyTaskBrowser(_ workspace: UnifiedMacWorkspace, agent: HostAgentWorkspace, endpoint: URL) async -> Bool {
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
        guard await waitUntil({ browser.existingTaskSession(for: owner)?.page.title == "Floe browser fixture" }),
              let session = browser.existingTaskSession(for: owner), session.page.url == url,
              session.page.window === window else {
            return failed("page did not load in the owning task window")
        }
        capture(content, extension: "browser-task.png")
        // Click WebKit content with a window event so target=_blank follows the same route as a user's link.
        let location = try? await session.page.evaluateJavaScript("(()=>{const r=document.getElementById('next').getBoundingClientRect();return [r.x+r.width/2,r.y+r.height/2]})()") as? [Double]
        guard let location, location.count == 2 else { return failed("fixture link missing") }
        let y = session.page.isFlipped ? location[1] : session.page.bounds.height - location[1]
        _ = clickWindowLocation(session.page.convert(NSPoint(x: location[0], y: y), to: nil), in: window)
        guard await waitUntil({ session.page.title == "Floe second page" }), session.page.canGoBack else { return failed("user link did not navigate in place") }
        session.page.goBack()
        guard await waitUntil({ session.page.title == "Floe browser fixture" }) else { return failed("back history missing") }
        browserReturnButtonPressed = pressAccessibilityButton(content, id: "workspace.browser.backToTask")
        if !browserReturnButtonPressed {
            func findAnchor(_ view: NSView) -> NSView? {
                if view.identifier?.rawValue == "workspace.browser.returnAnchor" { return view }
                return view.subviews.lazy.compactMap(findAnchor).first
            }
            if let anchor = findAnchor(content) {
                let center = NSPoint(x: anchor.bounds.midX, y: anchor.bounds.midY)
                browserReturnButtonPressed = clickWindowLocation(anchor.convert(center, to: nil), in: window)
            }
        }
        guard browserReturnButtonPressed else { return failed("could not press the return button") }
        guard await waitUntil({ !browser.isPresented && agent.windowShowsTask }), agent.selectedID == owner,
              let reopened = await draftEditor(), let reopenedSheet = window.attachedSheet else { return failed("could not return to task") }
        let keptDraft = reopened.string == marker
        reopened.insertText("", replacementRange: NSRange(location: 0, length: (reopened.string as NSString).length))
        guard await closeFixtureSheet(reopenedSheet, id: "thread.composer.expanded.done"), keptDraft else { return failed("draft was lost") }
        let other = browser.session(for: UUID())
        return other !== session && other.currentURL == nil && other.page.configuration.websiteDataStore !== session.page.configuration.websiteDataStore
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
