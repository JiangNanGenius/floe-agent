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
import FloeTools
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
        if CommandLine.arguments.contains("--creative-only") {
            model.openAgentWorkspace()
            guard let agent = model.macWorkspace?.agent else { finish(["creative": false, "details": ["Agent did not open"]]); return }
            await agent.prepare()
            guard agent.isReady else { finish(["creative": false, "details": ["Task database did not open"]]); return }
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
        var workspaceAndAttachmentStaging = false
        var desktopFilesLayout = false
        var conversationHistoryVerified = false
        var approvalReviewerVerified = false
        var filePermissionsVerified = false
        var taskPermissionsVerified = false
        var workspaceTextEditsVerified = false
        var workspaceModelReadTools = false
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
            workspaceAndAttachmentStaging = await verifyWorkspaceAndAttachmentStaging(agent)
            if let window = visibleWorkbench, let content = window.contentView {
                capture(content, extension: "png")
                desktopFilesLayout = await verifyDesktopFilesLayout(window: window, content: content, workspace: agent)
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
            if let content = visibleWorkbench?.contentView {
                capture(content, extension: "task.png")
            }
            if let project = agent.workspaces.first(where: { $0.name == "Fixture Project" }) {
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
                                return await self.answerProjectQuestion()
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
                    if !pressAccessibilityButton(body, id: "settings.openAuxiliaryModels"), let frame = agent.smokeAuxiliaryButtonFrame {
                        let point = NSPoint(x: frame.midX, y: body.isFlipped ? frame.midY : body.bounds.height - frame.midY)
                        _ = click(body, at: point, in: window)
                    }
                    let deadline = ContinuousClock.now + .seconds(3)
                    while !agent.smokeAuxiliaryModelsMounted && ContinuousClock.now < deadline {
                        try? await Task.sleep(for: .milliseconds(40))
                    }
                    auxiliaryPanelVerified = agent.smokeAuxiliaryModelsMounted
                    if auxiliaryPanelVerified {
                        try? await Task.sleep(for: .milliseconds(240))
                        let sheet = window.attachedSheet ?? NSApp.keyWindow ?? window
                        if let content = sheet.contentView {
                            capture(content, extension: "settings-auxiliary.png")
                            if !pressAccessibilityButton(content, id: "settings.closeAuxiliaryModels") && sheet !== window {
                                sheet.performClose(nil)
                            }
                        }
                        try? await Task.sleep(for: .milliseconds(180))
                    }
                }
            }
            standardTaskMenus = await verifyTaskMenus(model: model, workspace: agent)
            imageGeneration = await verifyImageGeneration()
            if CommandLine.arguments.contains("--creative-fixture") { creative = await verifyCreative(model) }
        }
        let spaceNavigation = await exerciseSpaceNavigation(model: model)
        let toolbox = await exerciseToolbox(model: model)
        let fileEditorFailures = MacWorkspaceFileEditingSmoke.runSyntheticChecks()
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
            "desktopFilesLayoutVerified": desktopFilesLayout,
            "approvalReviewerVerified": approvalReviewerVerified,
            "savedFilePermissionVerified": filePermissionsVerified,
            "taskApprovalPolicyVerified": taskPermissionsVerified,
            "workspaceTextEditsVerified": workspaceTextEditsVerified,
            "fileEditorSaveVerified": fileEditorFailures.isEmpty,
            "fileEditorFailures": fileEditorFailures,
            "workspaceModelReadToolsVerified": workspaceModelReadTools,
            "projectTaskWorkflowVerified": projectWorkflow,
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
        if let firstID { await agent.select(firstID) }
        checks["reopen"] = firstRoot != nil && taskRoot()?.standardizedFileURL == firstRoot?.standardizedFileURL
        if agent.beginTermination() { try? await agent.finishTermination() }
        finish(["checks": checks, "diagnostics": agent.smokeRunDiagnostics, "notice": agent.notice ?? ""])
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
            try batch.save(.init(presetID: .openAI, endpoint: endpoint.absoluteString, modelID: "gpt-image-1"),
                           apiKey: "floe-image-fixture")
            batch.generate(prompt: "Storyboard candidates", options: .init(count: 2))
            let imageDeadline = ContinuousClock.now + .seconds(8)
            while batch.isGenerating && ContinuousClock.now < imageDeadline { try await Task.sleep(for: .milliseconds(50)) }
            let candidates = batch.history.filter { $0.prompt == "Storyboard candidates" }
            guard candidates.count == 2, Set(candidates.map(\.id)).count == 2,
                  candidates.allSatisfy({ NSImage(contentsOf: batch.imageURL(for: $0))?.isValid == true })
            else {
                settingsDiagnostics.append("Batch image fixture: " + (batch.notice ?? "missing candidates"))
                return false
            }
            try videos.save(.init(presetID: .volcengineArk, endpoint: endpoint.absoluteString,
                                  modelID: "doubao-seedance-2-5-260628"), apiKey: "floe-video-fixture")
            videos.generate(prompt: "Synthetic clip", options: .init(aspectRatio: "16:9", durationSeconds: 5),
                            referenceImage: batch.imageURL(for: candidates[0]))
            let deadline = ContinuousClock.now + .seconds(16)
            while videos.isGenerating && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(60)) }
            guard let item = videos.history.first, let url = videos.videoURL(for: item),
                  try await AVURLAsset(url: url).load(.isPlayable) else {
                settingsDiagnostics.append("Video fixture: " + (videos.notice ?? "no saved playable video"))
                return false
            }
            let videoDirectory = library.directory.deletingLastPathComponent().appendingPathComponent("Videos")
            let reopenedVideos = MacVideoGeneration(directory: videoDirectory, namespace: "fixture.no-keychain",
                                                     useKeychain: false, admitWork: { {} })
            guard reopenedVideos.history.first?.id == item.id, reopenedVideos.videoURL(for: item) == url else { return false }
            guard try await verifyVideoRecovery(in: videoDirectory, configuration: item.configuration, savedID: item.id) else { return false }
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
                model.openSettings(.models, media: role)
                let timeout = ContinuousClock.now + .seconds(3)
                while agent.smokeMediaSettingsRole != expected && ContinuousClock.now < timeout {
                    try await Task.sleep(for: .milliseconds(40))
                }
                guard agent.smokeMediaSettingsRole == expected, let view = model.smokeAgentSettingsSheet?.contentView else {
                    settingsDiagnostics.append("Missing media settings pane: " + expected)
                    return false
                }
                capture(view, extension: "creative-" + expected + "-settings.png")
            }
            model.closeSettingsWindow()
            let closed = ContinuousClock.now + .seconds(3)
            while (visibleWorkbench?.isKeyWindow != true || model.smokeAgentSettingsSheet != nil) && ContinuousClock.now < closed {
                try await Task.sleep(for: .milliseconds(40))
            }
            return visibleWorkbench?.isKeyWindow == true && model.smokeAgentSettingsSheet == nil
        } catch {
            settingsDiagnostics.append("Creative fixture: " + error.localizedDescription)
            return false
        }
    }

    private func verifyVideoRecovery(in directory: URL, configuration: MacVideoGeneration.Configuration, savedID: UUID) async throws -> Bool {
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
        let resumed = MacVideoGeneration(directory: pendingDirectory, namespace: "fixture.no-keychain", useKeychain: false) {
            leases += 1
            return { leases -= 1 }
        }
        try resumed.save(configuration, apiKey: "floe-video-fixture")
        resumed.resume()
        resumed.resume()
        let timeout = ContinuousClock.now + .seconds(10)
        while resumed.history.first?.state != .ready && ContinuousClock.now < timeout { try await Task.sleep(for: .milliseconds(50)) }
        guard let restored = resumed.history.first, restored.id == savedID, resumed.videoURL(for: restored) != nil,
              leases == 0 else {
            settingsDiagnostics.append("Submitted video fixture did not resume and release its activity lease.")
            return false
        }
        resumed.generate(prompt: "Cancel fixture", options: .init())
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
              performMenuShortcut("f", title: findTitle) else { return false }
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
              await workspace.verifyChatSmoke(admissionIsClosedToInstall: { true }),
              performMenuShortcut("f", title: findTitle) else { return false }
        let conversationDeadline = ContinuousClock.now + .seconds(2)
        while !workspace.smokeConversationSearchMounted && ContinuousClock.now < conversationDeadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
        guard workspace.smokeConversationSearchMounted, workspace.smokeTaskFindInvocations == 2,
              performMenuShortcut("f", title: String(localized: "mac.workspace.findTask"), modifiers: [.command, .shift]) else {
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
        guard performMenuShortcut("0", title: title, modifiers: modifiers),
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
        guard performMenuShortcut("0", title: title, modifiers: modifiers),
              await waitForState(shown: false, inDetail: false) else { return false }
        capture(content, extension: "narrow-composer.png")
        return true
    }

    private func openNewTaskFromMenu(workspace: HostAgentWorkspace) async -> Bool {
        guard performMenuShortcut("n", title: String(localized: "workbench.new_task")) else { return false }
        let newTaskDeadline = ContinuousClock.now + .seconds(2)
        while workspace.selectedID != nil && ContinuousClock.now < newTaskDeadline {
            try? await Task.sleep(for: .milliseconds(30))
        }
        return workspace.selectedID == nil
    }

    private func openNewProjectTask(workspace: HostAgentWorkspace, projectID: UUID,
                                    screenshot: String? = "project-task-start.png", fromName: Bool = false) async -> Bool {
        let action = fromName ? "open" : "new"
        guard clickWorkbenchButton(ids: ["sidebar.workspace.\(action).\(projectID.uuidString)"],
                                   frame: (fromName ? workspace.smokeProjectNameFrames : workspace.smokeProjectNewTaskFrames)[projectID],
                                   screenshot: nil) else {
            settingsDiagnostics.append("The sidebar’s project control was unavailable.")
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

    private func performMenuShortcut(_ key: String, title: String, modifiers: NSEvent.ModifierFlags = .command) -> Bool {
        for root in NSApp.mainMenu?.items ?? [] {
            guard let menu = root.submenu else { continue }
            menu.update()
            if let index = menu.items.firstIndex(where: {
                $0.keyEquivalent == key && $0.keyEquivalentModifierMask == modifiers && $0.title == title && $0.isEnabled
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

    private func answerProjectQuestion() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(8)
        while ContinuousClock.now < deadline {
            if UserQuestionCardView.smokeActionFrames["user_question.option.report"] != nil,
               clickWorkbenchButton(ids: ["user_question.option.report"], frame: UserQuestionCardView.smokeActionFrames["user_question.option.report"], screenshot: nil) {
                try? await Task.sleep(for: .milliseconds(160))
                return clickWorkbenchButton(ids: ["user_question.continue"], frame: UserQuestionCardView.smokeActionFrames["user_question.continue"], screenshot: "project-question.png")
            }
            try? await Task.sleep(for: .milliseconds(80))
        }
        settingsDiagnostics.append("The project question did not expose its report option.")
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

    private func verifyWorkspaceAndAttachmentStaging(_ agent: HostAgentWorkspace) async -> Bool {
        let project = root.appendingPathComponent("Fixture Project", isDirectory: true)
        let reference = project.appendingPathComponent("fixture.md")
        do {
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: false)
            try Data("Synthetic attachment".utf8).write(to: reference, options: .withoutOverwriting)
        } catch {
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
        model.openSettings(.permissions)
        try? await Task.sleep(for: .milliseconds(180))
        guard model.settingsPane == .permissions, model.smokeAgentSettingsSheet === window else { return false }
        if let content = window.contentView { capture(content, extension: "settings-permissions.png") }
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
