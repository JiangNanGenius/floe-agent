// SPDX-License-Identifier: MPL-2.0
// Opt-in real guest + native editor/reader. Default suites never install.
#if canImport(UIKit) && DEBUG
import Foundation
import SwiftUI
import UIKit
import PDFKit
import XCTest
import FloeCore
import FloeModels
import FloePersistence
import FloeSecurity
import FloeTools
import FloeExecution
import FloeEnvironments
import FloeProviders
import FloeAgentRuntime
import FloeLaTeXCore
import FloeLaTeXEngine
import FloeLaTeXHostAdapter
import FloeTestSupport
@testable import FloeApp

@MainActor private final class LaTeXRealAPTOwnedReceipt {
    let directory: URL
    private var facts: [String: String]
    private var phases: [[String: String]] = []
    init(id: UUID, namespace: String = "LaTeXRealAPT", kind: String = "floe.qa.latex.real-apt",
         scope: String = "new owned QA original/task/session overlay only") throws {
        directory = URL.applicationSupportDirectory.appendingPathComponent("FloeAgent/QualificationEvidence/" + namespace + "/" + id.uuidString, isDirectory: true)
        facts = ["kind": kind, "caseID": id.uuidString,
                 "scope": scope, "liveModelInference": "false",
                 "cleanup": "retain original and owned IDs until Root has exported and reviewed evidence"]
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try record("created")
    }
    func record(_ phase: String, _ values: [String: String] = [:]) throws {
        facts.merge(values) { _, new in new }; facts["phase"] = phase
        phases.append(values.merging(["phase": phase, "at": String(Date().timeIntervalSince1970)]) { _, new in new })
        let body: [String: Any] = ["version": 1, "facts": facts, "phases": phases]
        try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .prettyPrinted])
            .write(to: directory.appendingPathComponent("owned-manifest.json"), options: .atomic)
    }
    func copy(_ source: URL, as name: String) throws {
        let bytes = try Data(contentsOf: source)
        try bytes.write(to: directory.appendingPathComponent(name), options: .atomic)
        try record("evidence-exported", [name + ".sha256": FloeDigest.sha256Hex(bytes), name + ".bytes": String(bytes.count)])
    }
}

@MainActor final class LaTeXFreshAPTAppIntegrationTests: XCTestCase {
    private func require(_ value: Bool, _ message: String) throws {
        if !value { throw FloeError.validationFailed(message) }
    }
    private func runShell(_ script: String, app: AppEnvironment, taskID: UUID, pin: TaskExecutionBinding,
                          root: URL, receipt: LaTeXRealAPTOwnedReceipt, phase: String,
                          registry suppliedRegistry: ToolRunnerRegistry? = nil,
                          marker: String = "FLOE_REAL_APT_QA ", callPrefix: String = "qa.latex.apt.") async throws -> [String: Any] {
        let runID = UUID()
        let registry: ToolRunnerRegistry
        if let suppliedRegistry { registry = suppliedRegistry }
        else { registry = try await app.latexComposition.host().registry }
        let policy = try await SQLiteWorkspaceStore(database: app.database).taskPolicy(conversationID: taskID)
        try require(policy.allowedToolNames?.contains("exec.shell") != false, "The fresh task does not permit exec.shell")
        try require(policy.approvalMode == TaskApprovalMode.automatic.rawValue && policy.networkAllowed == true,
                    "Respect the new assistant's actual saved policy; this fixture never changes an existing policy")
        let arguments = try JSONEncoder().encode(LocalShellTool.Arguments(script: script, cwd: ".",
            timeoutSeconds: 600, timeoutPolicy: "hard", maxOutputBytes: 16_384))
        let call = try ToolCall(id: callPrefix + runID.uuidString, toolName: "exec.shell", argumentsJSON: arguments, scope: .local)
        let adapter = MockAdapter()
        adapter.script = [[.toolRequest(call), .completed(.init(stopReason: .toolUse))],
                          [.textDelta(.init(text: "The owned guest fixture operation returned.")), .completed(.init(stopReason: .endTurn))]]
        let provider = TestFixtures.localhostProvider()
        let service = ConversationRunService(configuration: .init(conversationID: taskID, provider: provider,
            model: TestFixtures.testModel(providerID: provider.id), allowedToolNames: ["exec.shell"],
            workspaceRootURL: root, allowedWorkspacePaths: policy.filePaths, pauseTimeout: 0.2,
            verifyFinalAnswer: false, maxProviderRetries: 0, environmentID: pin.target.environmentID,
            executionBinding: pin, localLinuxGuestEnvironment: true,
            serviceStorePaths: suppliedRegistry == nil ? app.latexComposition.typedServiceStorePaths : [:]), adapter: adapter,
            policy: AutomaticApprovalPolicy(), executor: CatalogToolExecutor(runners: registry),
            checkpointStore: MockCheckpointStore(), conversationStore: app.conversationStore,
            runStore: app.runStore, runID: runID)
        let argumentsSHA256 = FloeDigest.sha256Hex(arguments)
        let scriptSHA256 = FloeDigest.sha256Hex(Data(script.utf8))
        let expectedCall = call.withIDContext(runID: runID)
        func exactCall(_ value: ToolCall) -> Bool {
            value.id == expectedCall.id && value.toolName == expectedCall.toolName
                && value.scope == .local && value.idempotencyKey == expectedCall.idempotencyKey
                && value.argumentsJSON == arguments
                && FloeDigest.sha256Hex(value.argumentsJSON) == argumentsSHA256
        }
        try require(pin.conversationID == taskID && pin.target.backend == .linuxVM,
                    "The fixture call must retain its own task's Linux binding")
        try receipt.record(phase + "-starting", [phase + ".runID": runID.uuidString,
            phase + ".callID": call.id, phase + ".environmentID": pin.target.environmentID,
            phase + ".argumentsSHA256": argumentsSHA256, phase + ".scriptSHA256": scriptSHA256])
        // Subscribe before start: the production runtime can publish its human
        // approval boundary before start() returns. Never infer it from a log.
        let approvalEvents = service.events()
        let approvals = Task { @MainActor in
            var allowedOnce = false, durableReceipt = false
            do {
                for await event in approvalEvents {
                    try Task.checkCancellation()
                    switch event {
                    case .approvalRequested(let request):
                        try require(!allowedOnce && exactCall(request.toolCall),
                                    "Refuse any repeated or different fixture approval request")
                        let savedRun = try await app.runStore.run(id: runID)
                        let savedPin = try await TaskExecutionBindingStore(database: app.database).binding(conversationID: taskID)
                        let savedPolicy = try await SQLiteWorkspaceStore(database: app.database).taskPolicy(conversationID: taskID)
                        let environment = await app.environmentRegistry.record(id: pin.target.environmentID)
                        let live = await service.snapshot()
                        let pending = try XCTUnwrap(live.pendingApproval, "Approval request must still be pending in this exact live service")
                        try require(service.runID == runID && service.conversationID == taskID && service.executionBinding == pin
                            && live.runID == runID && live.conversationID == taskID
                            && live.stateName == "waitingApproval" && !live.isTerminal,
                            "Never approve a different or settled runtime")
                        try require(savedRun?.id == runID && savedRun?.conversationID == taskID
                            && savedRun?.state == "waitingApproval" && savedRun?.endedAt == nil
                            && savedRun?.executionBinding == pin && savedPin == pin && savedPolicy == policy,
                            "The exact persisted run, task binding or policy changed before approval")
                        try require(environment?.id == pin.target.environmentID && environment?.kind == .session
                            && environment?.ownerID == taskID.uuidString,
                            "The pending call's environment must still belong only to this new fixture task")
                        try require(exactCall(pending.toolCall) && pending.requestedAt == request.requestedAt,
                                    "The live pending request no longer matches the original call and exact arguments")
                        let pendingArguments = try JSONDecoder().decode(LocalShellTool.Arguments.self, from: pending.toolCall.argumentsJSON)
                        try require(pendingArguments.script == script
                            && FloeDigest.sha256Hex(Data((pendingArguments.script ?? "").utf8)) == scriptSHA256,
                            "Only the exact fixture script may receive this single-use decision")
                        try receipt.record(phase + "-approval-request-verified", [phase + ".approvalID": request.id.uuidString,
                            phase + ".bindingGeneration": String(pin.generation), phase + ".approvalDecision": "allow-once"])
                        try Task.checkCancellation()
                        let accepted = await service.resolveApproval(
                            .allow(scope: ApprovalScope(toolName: "exec.shell", singleUse: true),
                                   expiresAt: Date().addingTimeInterval(60)), for: call.id)
                        try require(accepted, "The production runtime refused the exact single-use approval continuation")
                        allowedOnce = true
                        try receipt.record(phase + "-approval-accepted")
                    case .approvalResolved(let callID):
                        try require(callID == call.id, "A different call reached an approval receipt")
                        durableReceipt = true
                        try receipt.record(phase + "-approval-durably-recorded", [phase + ".resolvedCallID": callID])
                    default: break
                    }
                }
                try require(!allowedOnce || durableReceipt,
                            "An accepted fixture approval needs its normal durable pre-dispatch receipt")
            } catch {
                try? receipt.record(phase + "-approval-refused", [phase + ".approvalFailure": error.localizedDescription])
                await service.cancel()
                throw error
            }
        }
        do {
            try await service.start(goal: "Perform only the explicitly authorized fixture operation in this new QA task's own Linux overlay.")
            try await approvals.value
        } catch {
            await service.cancel(); approvals.cancel(); _ = try? await approvals.value
            throw error
        }
        let events = try await app.runStore.events(runID: runID)
        let values = try events.filter { $0.kind == .toolResult }.map {
            try JSONDecoder().decode([String: String].self, from: Data($0.payloadJSON.utf8))
        }
        try require(values.count == 1 && values[0]["id"] == call.id && values[0]["status"] == "ok" && values[0]["dispatched"] == "true",
                    "The exact real shell call did not complete successfully")
        let terminal = try await app.runStore.run(id: runID)
        try require(terminal?.state == "completed" && terminal?.endedAt != nil, "The seed/readback runtime is not terminal")
        let text = values[0]["summary"] ?? ""
        guard let line = text.split(separator: "\n").first(where: { $0.hasPrefix(marker) }),
              let bytes = Data(base64Encoded: String(line.dropFirst(marker.count))),
              let result = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
            throw FloeError.validationFailed("The real guest did not return its verified fixture receipt")
        }
        try bytes.write(to: receipt.directory.appendingPathComponent(phase + "-guest.json"), options: .atomic)
        try JSONEncoder().encode(events).write(to: receipt.directory.appendingPathComponent(phase + "-events.json"), options: .atomic)
        try receipt.record(phase + "-completed")
        return result
    }
    private func runIDs(_ app: AppEnvironment, _ taskID: UUID) async throws -> Set<UUID> {
        Set(try await app.runStore.runs(conversationID: taskID).map(\.id))
    }
    private func onlyNewRun(_ app: AppEnvironment, _ taskID: UUID, before: Set<UUID>) async throws -> RunRecord {
        let values = try await app.runStore.runs(conversationID: taskID).filter { !before.contains($0.id) }
        try require(values.count == 1, "A native action must have exactly one new owned run; never choose latest/first")
        return values[0]
    }
    private func views(_ root: UIView) -> [UIView] { [root] + root.subviews.flatMap { views($0) } }
    private func capture(_ name: String, window: UIWindow) {
        window.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: true) }
        let attachment = XCTAttachment(image: image); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }

    /// Linux package acceptance is independent of native LaTeX. The existing
    /// one-use approval helper is reused with only the production shell tool.
    func testFreshOwnedLightweightPipInstallsImportsAndComputes() async throws {
        guard ProcessInfo.processInfo.environment["FLOE_LINUX_REAL_PIP"] == "1" else {
            throw XCTSkip("Explicit opt-in only: one new QA task and a tiny online pip install")
        }
        executionTimeAllowance = 900
        let app = try await appQualificationEnvironment()
        let receipt = try LaTeXRealAPTOwnedReceipt(id: UUID(), namespace: "LinuxRealPip",
            kind: "floe.qa.linux.real-pip", scope: "one new owned ordinary task/workspace/session; no TeX or apt")
        print("FLOE_LINUX_REAL_PIP_EVIDENCE=" + receipt.directory.path)
        var rootLease: WorkspaceCenter.TaskRootLease?, environmentID: String?, ownedTaskID: UUID?
        defer { rootLease?.release() }
        func stopOwnedEnvironment() async throws {
            guard let environmentID else { return }
            let record = await app.environmentRegistry.record(id: environmentID)
            try require(record?.id == environmentID && record?.kind == .session
                && record?.ownerID == ownedTaskID?.uuidString, "Never stop an environment outside this exact QA task")
            try await FloePlatformServices.shared.stopEnvironment(id: environmentID)
            let status = await FloePlatformServices.shared.linuxGuestStatus(id: environmentID)
            try require(status?.running == false, "Owned pip guest stop is not confirmed; retain owner and evidence")
            try receipt.record("owned-guest-stopped", ["cleanup": "task/workspace/environment/evidence retained for Root's exact-ID export and normal cleanup"])
        }
        do {
            try await app.environmentRegistry.prepare()
            let priorIDs = Set(await app.environmentRegistry.all().map(\.id))
            let task = try await app.conversationCenter.createConversation(
                title: "QA-Linux-Pip-" + receipt.directory.lastPathComponent, purpose: .ordinary)
            ownedTaskID = task.id
            try receipt.record("task-created", ["taskID": task.id.uuidString])
            let store = SQLiteWorkspaceStore(database: app.database)
            let before = try await store.taskPolicy(conversationID: task.id)
            try require(before.approvalMode == nil && before.allowedToolNames == nil && before.networkAllowed == nil,
                        "Only this new task's unset policy may be initialized")
            try await store.saveTaskPolicy(.init(conversationID: task.id,
                approvalMode: TaskApprovalMode.automatic.rawValue, allowedToolNames: ["exec.shell"], networkAllowed: true))
            let workspace = try await store.ensureWorkspace(conversationID: task.id, title: task.title)
            let root = try await app.workspaceCenter.acquireTaskRoot(workspace, conversationID: task.id); rootLease = root
            try receipt.record("workspace-created", ["workspaceID": workspace.id.uuidString, "workspaceRoot": root.url.path])
            let bindingStore = TaskExecutionBindingStore(database: app.database)
            try require(try await bindingStore.binding(conversationID: task.id) == nil, "Never replace an existing task binding")
            let target = try await app.taskExecutionEnvironments.prepareTarget(.init(id: "local", name: "QA Linux", kind: .linux),
                conversationID: task.id, root: root.url, fresh: true)
            let record = await app.environmentRegistry.record(id: target.environmentID)
            try require(target.backend == .linuxVM && !priorIDs.contains(target.environmentID)
                && record?.kind == .session && record?.ownerID == task.id.uuidString,
                "The new Linux session must belong only to this QA task")
            environmentID = target.environmentID
            let pin = try await app.taskExecutionEnvironments.resolveBinding(conversationID: task.id,
                runID: UUID(), root: root.url, workspace: workspace)
            try require(pin.target == target, "Retain this exact new target and binding")
            try receipt.record("fresh-environment-selected", ["environmentID": target.environmentID,
                "bindingGeneration": String(pin.generation), "defaultCatalogImageID": LinuxGuestImageDistributionCatalog.defaultImageID,
                "package": "simpleeval==1.0.8", "wheelSHA256": "c9c4ff42879ebf0c05f6562cb81031869948916be343bcc950b81fcc081fe9ce"])
            let registry = ToolRunnerRegistry(); registry.register(LocalShellTool(shell: app.localShellService))
            let project = "e" + String(FloeDigest.sha256Hex(Data(target.environmentID.utf8)).prefix(63))
            let script = Self.lightweightPip.replacingOccurrences(of: "__FLOE_PROJECT__", with: project)
            let result = try await runShell("python3 -u - <<'FLOE_PIP_QA'\n" + script + "\nFLOE_PIP_QA\n",
                app: app, taskID: task.id, pin: pin, root: root.url, receipt: receipt, phase: "pip",
                registry: registry, marker: "FLOE_REAL_PIP_QA ", callPrefix: "qa.linux.pip.")
            try require(result["kind"] as? String == "fresh-online-pip-import-compute"
                && result["initiallyAbsent"] as? Bool == true && result["packageVersion"] as? String == "1.0.8"
                && (result["result46_5"] as? NSNumber)?.doubleValue == 46.5
                && (result["result42"] as? NSNumber)?.intValue == 42,
                "Require actual first install, import and both independent computations")
            for name in ["preflight.json", "install.log", "pip-report.json", "result.json"] {
                try receipt.copy(root.url.appendingPathComponent("qualification/linux-pip/" + name), as: name)
            }
            try receipt.record("actual-install-import-computation-verified")
            try await stopOwnedEnvironment()
            try receipt.record("completed-retained-for-root-cleanup")
        } catch {
            try? receipt.record("failed-preserved", ["failure": error.localizedDescription])
            if let rootLease {
                for name in ["preflight.json", "install.log", "pip-report.json", "result.json"] {
                    let file = rootLease.url.appendingPathComponent("qualification/linux-pip/" + name)
                    if FileManager.default.fileExists(atPath: file.path) { try? receipt.copy(file, as: name) }
                }
            }
            do { try await stopOwnedEnvironment() }
            catch { try? receipt.record("owned-stop-unconfirmed", ["stopFailure": error.localizedDescription]) }
            throw error
        }
    }

    func testFreshOwnedMissingDependencyInstallsThroughNativeTypesetAndShowsItsSavedPDF() async throws {
        guard ProcessInfo.processInfo.environment["FLOE_LATEX_REAL_APT"] == "1" else {
            throw XCTSkip("Explicit opt-in only: real downloads in a new owned QA overlay")
        }
        executionTimeAllowance = 1800
        let app = try await appQualificationEnvironment(), receipt = try LaTeXRealAPTOwnedReceipt(id: UUID())
        print("FLOE_LATEX_REAL_APT_EVIDENCE=" + receipt.directory.path)
        var retained: LaTeXProjectSession?, environmentID: String?
        var rootLease: WorkspaceCenter.TaskRootLease?
        var window: UIWindow?, previousKey: UIWindow?
        defer { window?.isHidden = true; window?.rootViewController = nil; previousKey?.makeKeyAndVisible(); rootLease?.release() }
        do {
            try await app.environmentRegistry.prepare()
            let priorEnvironmentIDs = Set(await app.environmentRegistry.all().map(\.id))
            let record = try await PersonalContentService.shared.create(kind: .latex,
                title: "QA-LaTeX-APT-" + receipt.directory.lastPathComponent)
            try receipt.record("original-created", ["projectID": record.id.uuidString])
            let original = try await app.latexComposition.original(record.id)
            let taskID = try await app.latexComposition.assistantForNativeOriginal(original)
            try receipt.record("assistant-created", ["taskID": taskID.uuidString, "originalRoot": original.root.path])
            let conversation = try await app.conversationStore.conversation(id: taskID)
            try require(conversation?.purpose == .ordinary, "The normal native assistant must be an ordinary saved task")
            let workspaceStore = SQLiteWorkspaceStore(database: app.database)
            let workspace = try await workspaceStore.ensureWorkspace(conversationID: taskID, title: record.title)
            try receipt.record("workspace-created", ["workspaceID": workspace.id.uuidString])
            let root = try await app.workspaceCenter.acquireTaskRoot(workspace, conversationID: taskID); rootLease = root
            let bindingStore = TaskExecutionBindingStore(database: app.database)
            let priorPin = try await bindingStore.binding(conversationID: taskID)
            try require(priorPin == nil, "Never replace a pre-existing task pin")
            let target = try await app.taskExecutionEnvironments.prepareTarget(.init(id: "local", name: "QA Linux", kind: .linux),
                conversationID: taskID, root: root.url, fresh: true)
            try receipt.record("target-created", ["environmentID": target.environmentID, "workspaceRoot": root.url.path])
            let environment = await app.environmentRegistry.record(id: target.environmentID)
            try require(target.backend == .linuxVM && !priorEnvironmentIDs.contains(target.environmentID), "Require a new Linux target")
            try require(environment?.kind == .session && environment?.ownerID == taskID.uuidString, "The overlay must belong only to this newly created task")
            environmentID = target.environmentID
            let pin = try await app.taskExecutionEnvironments.resolveBinding(conversationID: taskID, runID: UUID(), root: root.url, workspace: workspace)
            try require(pin.target == target, "Normal task binding must retain the exact newly created target")
            try receipt.record("fresh-environment-selected", ["bindingGeneration": String(pin.generation)])
            let project = "e" + String(FloeDigest.sha256Hex(Data(pin.target.environmentID.utf8)).prefix(63))
            let seed = Self.seed.replacingOccurrences(of: "__FLOE_PROJECT__", with: String(project))
            let seeded = try await runShell("python3 - <<'FLOE_APT_QA'\n" + seed + "\nFLOE_APT_QA\n",
                app: app, taskID: taskID, pin: pin, root: root.url, receipt: receipt, phase: "seed")
            try require(seeded["project"] as? String == project && seeded["installedAfter"] as? Bool == false,
                        "The exact owned guest must prove the missing package")

            let session = try await LaTeXProjectSession.open(id: record.id, composition: app.latexComposition); retained = session
            session.editor.autoCompile = false
            let marker = "FLOEQAAPT" + receipt.directory.lastPathComponent.replacingOccurrences(of: "-", with: "")
            session.editor.update("\\documentclass{article}\n\\usepackage{fontspec}\n\\setmainfont{TeX Gyre Heros}\n\\begin{document}\n" + marker + "\n\\end{document}\n", groupTyping: false)
            try await session.editor.save()
            let sourceBefore = try await session.editor.store.manifest()
            try require(sourceBefore.engine == .xeLaTeX, "The actual QA source must use XeLaTeX")
            let manifestURL = original.root.appendingPathComponent("LaTeXProject.json")
            let sourceURL = original.root.appendingPathComponent("Source/" + sourceBefore.mainFile)
            let manifestSHA = FloeDigest.sha256Hex(try Data(contentsOf: manifestURL))
            let sourceSHA = FloeDigest.sha256Hex(try Data(contentsOf: sourceURL))
            try receipt.record("source-saved", ["revision": String(sourceBefore.revision), "manifestSHA256": manifestSHA, "sourceSHA256": sourceSHA, "marker": marker])
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.filter { $0.activationState == .foregroundActive }
            let scene = try XCTUnwrap(scenes.count == 1 ? scenes.first : nil, "Run under Root's normal single iPad App-host configuration")
            previousKey = scene.windows.first(where: \.isKeyWindow)
            let host = UIHostingController(rootView: AnyView(NavigationStack { LaTeXEditorSurface(session: session) }))
            let mounted = UIWindow(windowScene: scene); mounted.frame = scene.effectiveGeometry.coordinateSpace.bounds
            mounted.rootViewController = host; mounted.makeKeyAndVisible(); window = mounted
            capture("latex-real-apt-01-original-no-PDF", window: mounted)

            session.editor.offline = true
            let beforeFailure = try await runIDs(app, taskID)
            await session.editor.compile()
            let failedRun = try await onlyNewRun(app, taskID, before: beforeFailure)
            let offlineMessage = session.editor.error ?? ""
            try require(failedRun.state == "failed" && failedRun.endedAt != nil &&
                (offlineMessage.lowercased().contains("offline") || offlineMessage.contains("离线")), "Require a real missing-resource offline failure, not an unrelated backend failure")
            try receipt.record("offline-missing-failed", ["offlineRunID": failedRun.id.uuidString, "message": offlineMessage])
            capture("latex-real-apt-02-actual-missing-resources", window: mounted)

            session.editor.offline = false
            let beforeOnline = try await runIDs(app, taskID)
            @MainActor final class Completion { var finished = false }
            let completion = Completion()
            let compilation = Task { await session.editor.compile(); completion.finished = true }
            var lastStatus: String?
            do {
                while !completion.finished {
                    if let status = session.workbenchOperation?.status, status != lastStatus {
                        try receipt.record("native-preparation-or-build", ["status": status]); lastStatus = status
                    }
                    try await Task.sleep(for: .milliseconds(200))
                }
                await compilation.value
            } catch {
                session.cancelPreparation(); compilation.cancel(); await compilation.value
                throw error
            }
            let onlineRun = try await onlyNewRun(app, taskID, before: beforeOnline)
            let build = try XCTUnwrap(session.editor.build)
            try require(onlineRun.state == "completed" && onlineRun.endedAt != nil && build.succeeded && build.workerStopped == true,
                        "Native preparation/typesetting did not finish successfully")
            try require(build.projectID == record.id && build.revision == sourceBefore.revision &&
                build.executionOwner?.runID == onlineRun.id && build.executionOwner?.taskID == taskID &&
                build.executionOwner?.environmentID == pin.target.environmentID, "The PDF build must remain attached to the same source/task/environment")
            let buildRoot = original.root.appendingPathComponent("Builds/" + build.id.uuidString)
            let preparationURL = buildRoot.appendingPathComponent("Output/DependencyPreparation-initial.json")
            let preparation = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: preparationURL)) as? [String: Any])
            try require(preparation["changedResources"] as? Bool == true && preparation["environmentID"] as? String == pin.target.environmentID,
                        "A real changed-resource preparation receipt is required")
            try require(!(preparation["installedPackages"] as? [String: String] ?? [:]).isEmpty &&
                !(preparation["preparationLogs"] as? [[String: Any]] ?? []).isEmpty, "Do not substitute cached/no-op preparation for actual APT installation")
            try receipt.copy(preparationURL, as: "DependencyPreparation-initial.json")
            let preparationLogs = preparation["preparationLogs"] as? [[String: Any]] ?? []
            for (index, log) in preparationLogs.enumerated() {
                let relative = try XCTUnwrap(log["path"] as? String)
                try require(relative.hasPrefix(".floe-latex/" + record.id.uuidString.lowercased() + "/preparation-") &&
                    !relative.split(separator: "/").contains(".."), "Preparation log must belong to this exact original")
                let file = root.url.appendingPathComponent(relative).standardizedFileURL
                try require(file.path == file.resolvingSymlinksInPath().path &&
                    file.path.hasPrefix(root.url.standardizedFileURL.resolvingSymlinksInPath().path + "/"), "No external or symbolic-link preparation log")
                try receipt.copy(file, as: String(format: "APT-%02d.log", index))
            }
            try receipt.copy(buildRoot.appendingPathComponent("Build.json"), as: "Build.json")
            try receipt.copy(buildRoot.appendingPathComponent("SourceManifest.json"), as: "SourceManifest.json")
            try receipt.record("native-APT-and-PDF-completed", ["onlineRunID": onlineRun.id.uuidString, "buildID": build.id.uuidString])
            let verifyPrefix = String(seed.components(separatedBy: "root, options = root_mount()  # This gate")[0])
            let verify = verifyPrefix + "\nroot_mount()\nrequire(installed(), 'Production APT did not install the selected package')\nprint('FLOE_REAL_APT_QA '+base64.b64encode(json.dumps(dict(project=EXPECTED_PROJECT,package=PACKAGE,installedAfter=True)).encode()).decode(),flush=True)\n"
            let verified = try await runShell("python3 - <<'FLOE_APT_QA'\n" + verify + "\nFLOE_APT_QA\n",
                app: app, taskID: taskID, pin: pin, root: root.url, receipt: receipt, phase: "installed-readback")
            try require(verified["installedAfter"] as? Bool == true && verified["project"] as? String == project, "Require a real same-overlay dpkg readback")
            try require(await session.flushForClose(), "The native original did not save")
            let reopened = try await LaTeXProjectSession.open(id: record.id, composition: app.latexComposition)
            let pdf = try XCTUnwrap(reopened.editor.pdfURL)
            try require(reopened.editor.pdfIsCurrent && reopened.editor.manifest?.revision == sourceBefore.revision, "Native reopening must find this revision's actual PDF")
            try require(FloeDigest.sha256Hex(try Data(contentsOf: manifestURL)) == manifestSHA &&
                FloeDigest.sha256Hex(try Data(contentsOf: sourceURL)) == sourceSHA, "Preparation must not edit or replace the source")
            let afterPin = try await bindingStore.binding(conversationID: taskID)
            try require(afterPin?.target == pin.target && afterPin?.generation == pin.generation, "The task pin changed")
            try receipt.copy(pdf, as: "document.pdf")
            if let relative = build.synctexRelativePath { try receipt.copy(buildRoot.appendingPathComponent(relative), as: "document.synctex.gz") }
            host.rootView = AnyView(NavigationStack { InlinePDFReader(url: pdf).navigationTitle(record.title) })
            let previewDeadline = Date().addingTimeInterval(15)
            var reader: PDFView?
            while Date() < previewDeadline {
                mounted.layoutIfNeeded()
                reader = views(host.view).compactMap { $0 as? PDFView }.first { view in
                    !view.isHidden && view.window === mounted && view.bounds.width > 0 && view.bounds.height > 0 &&
                        ((try? withPDFExceptionGuard { view.document?.pageCount ?? 0 }) ?? 0) > 0
                }
                if reader != nil { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            let actualReader = try XCTUnwrap(reader)
            let text = try withPDFExceptionGuard { actualReader.document?.string ?? "" }
            try require(text.contains(marker), "The production InlinePDFReader did not decode this real PDF's marker")
            capture("latex-real-apt-03-saved-native-InlinePDFReader", window: mounted)
            try receipt.record("passed-retained-for-root-review", ["preview": "actual production InlinePDFReader/PDFView", "previewMarkerFound": "true",
                "cleanupReady": "true"])
            try await FloePlatformServices.shared.stopEnvironment(id: pin.target.environmentID)
            try receipt.record("owned-runtime-stopped")
        } catch {
            retained?.cancelPreparation()
            try? receipt.record("failed-retained-for-root-recovery", ["error": String(error.localizedDescription.prefix(2000)), "cleanupReady": "false"])
            if let environmentID {
                do { try await FloePlatformServices.shared.stopEnvironment(id: environmentID); try receipt.record("failed-owned-runtime-stop-returned") }
                catch { try? receipt.record("owned-stop-unconfirmed", ["stopError": String(error.localizedDescription.prefix(1000))]) }
            }
            if let window { capture("latex-real-apt-FAILED-current-state", window: window) }
            throw error
        }
    }

    private static let lightweightPip = #"""
import base64, hashlib, importlib.util, json, os, pathlib, subprocess, sys, time, urllib.parse
EXPECTED_PROJECT = "__FLOE_PROJECT__"
PIN = "simpleeval==1.0.8"
DIGEST = "c9c4ff42879ebf0c05f6562cb81031869948916be343bcc950b81fcc081fe9ce"
OUT = pathlib.Path('/workspace/qualification/linux-pip')
OUT.mkdir(parents=True, exist_ok=False)

def save(name, value):
    (OUT/name).write_text(json.dumps(value, sort_keys=True, indent=2))

def run(argv, seconds=120):
    return subprocess.run(argv, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=seconds)

def require(value, message):
    if not value:
        raise RuntimeError(message)

# Verify the actual per-session overlay, not a caller-authored environment label.
roots=[]
for line in pathlib.Path('/proc/self/mountinfo').read_text().splitlines():
    left,right=line.split(' - ',1); a,b=left.split(),right.split()
    if a[4]=='/': roots.append((b[0],dict(x.split('=',1) for x in b[2].split(',') if '=' in x)))
require(sys.platform=='linux' and len(roots)==1 and roots[0][0]=='overlay','Use only the owned Linux root overlay')
options=roots[0][1]
require(options.get('upperdir','').endswith('/projects/'+EXPECTED_PROJECT+'/upper'),'Wrong session overlay')
pre={'kind':'new-owned-linux-pip-preflight','project':EXPECTED_PROJECT,'sysExecutable':sys.executable,
     'pythonVersion':sys.version,'prefix':sys.prefix,'basePrefix':sys.base_prefix,
     'initiallyAbsent':importlib.util.find_spec('simpleeval') is None,'upperdir':options['upperdir'],
     'sourcePolicy':'preserve production environment/guest pip config; no index override or invented fallback'}
save('preflight.json',pre)
require(pre['initiallyAbsent'],'The fixed package already exists; do not uninstall or fabricate first use')
require(sys.version_info>=(3,9),'The pinned wheel requires Python>=3.9')
pip=run([sys.executable,'-m','pip','--version'],60)
pre['systemPipAvailable']=pip.returncode==0
pre['systemPipVersion']=pip.stdout.strip() if pip.returncode==0 else 'unavailable'
save('preflight.json',pre)
require(pip.returncode==0,'The base has no usable pip; no apt/ensurepip repair in this scenario')
venv=pathlib.Path('/floe/env/python/venv')
if not (venv/'bin/python3').is_file():
    require(not venv.exists(),'Refuse to replace an existing incomplete venv')
    created=run([sys.executable,'-m','venv','--without-pip','--system-site-packages',str(venv)],120)
    require(created.returncode==0,'Normal distribution-backed venv creation failed; no apt fallback')
python=str(venv/'bin/python3')
# Resolve effective pip options without printing credentials or unrelated config.
probe=run([python,'-u','-c',"""
import importlib.util,json,sys,urllib.parse
from pip._internal.commands import create_command
opts,args=create_command('install').parse_args([])
def public(url):
    p=urllib.parse.urlsplit(url)
    assert p.scheme=='https' and p.hostname in ('pypi.org','mirrors.tuna.tsinghua.edu.cn')
    assert p.username is None and p.password is None and not p.query and not p.fragment
    return urllib.parse.urlunsplit((p.scheme,p.netloc,p.path,'',''))
assert not opts.trusted_hosts,'No TLS-verification bypass'
print(json.dumps(dict(executable=sys.executable,prefix=sys.prefix,basePrefix=sys.base_prefix,
    initiallyAbsent=importlib.util.find_spec('simpleeval') is None,
    index=public(opts.index_url),extraIndexes=[public(u) for u in opts.extra_index_urls])))
"""],120)
require(probe.returncode==0,'Effective pip configuration is unavailable or outside the public-source fixture scope')
selected=json.loads(probe.stdout.strip())
require(selected['initiallyAbsent'] and selected['prefix']!=selected['basePrefix'],'Require an empty real venv')
pre['venv']=selected;save('preflight.json',pre)
requirements=OUT/'requirements.txt';requirements.write_text(PIN+' --hash=sha256:'+DIGEST+'\n')
started=time.monotonic()
argv=[python,'-u','-m','pip','--disable-pip-version-check','--no-input','--no-cache-dir','install',
      '--only-binary=:all:','--no-deps','--require-hashes','--retries','0','--timeout','15','--progress-bar','off',
      '--report',str(OUT/'pip-report.json'),'-r',str(requirements)]
try:
    installed=run(argv,240)
except subprocess.TimeoutExpired as error:
    text=(error.stdout or b'')
    if isinstance(text,bytes):text=text.decode(errors='replace')
    (OUT/'install.log').write_text(text)
    raise RuntimeError('The bounded pip install did not finish; retain this owned environment')
(OUT/'install.log').write_text(installed.stdout)
require(installed.returncode==0,'The real pinned online pip install failed; preserve its original log')
report=json.loads((OUT/'pip-report.json').read_text())
items=report.get('install',[])
require(len(items)==1 and items[0]['metadata']['name'].lower()=='simpleeval' and items[0]['metadata']['version']=='1.0.8','Unexpected pip report')
require(items[0]['download_info']['archive_info']['hashes']['sha256']==DIGEST,'Installed wheel hash differs')
# Separate interpreter: a successful installer is not an import/computation proof.
computed=run([python,'-u','-c',"""
import importlib.metadata,json,simpleeval
from simpleeval import simple_eval
one=simple_eval('(12.5 * 4) - 7 / 2');two=simple_eval('a*b',names={'a':6,'b':7})
assert one==46.5 and two==42
print(json.dumps(dict(packageVersion=importlib.metadata.version('simpleeval'),modulePath=simpleeval.__file__,result46_5=one,result42=two)))
"""],120)
require(computed.returncode==0,'Installed package failed its independent import/computation')
result=json.loads(computed.stdout.strip())
require(result['modulePath'].startswith(str(venv)+'/'),'Import resolved outside the new owned venv')
result.update(kind='fresh-online-pip-import-compute',initiallyAbsent=True,project=EXPECTED_PROJECT,
              wheelSHA256=DIGEST,installSeconds=time.monotonic()-started,selectedSource=selected)
save('result.json',result)
print('FLOE_REAL_PIP_QA '+base64.b64encode(json.dumps(result,sort_keys=True).encode()).decode(),flush=True)
"""#

    private static let seed = #"""
import base64
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

EXPECTED_PROJECT = "__FLOE_PROJECT__"
os.environ["LC_ALL"] = "C"
PACKAGE = "fonts-texgyre"
FAMILY = "TeX Gyre Heros"


def require(value, message):
    if not value:
        raise RuntimeError(message)


def root_mount():
    require(sys.platform == "linux" and os.geteuid() == 0, "Use the owned Linux guest, not a native host or sudo fallback")
    mounts = []
    for line in Path("/proc/self/mountinfo").read_text().splitlines():
        left, right = line.split(" - ", 1)
        a, b = left.split(), right.split()
        mounts.append(dict(id=a[0], point=a[4].replace("\\040", " "), kind=b[0], options=b[2]))
    roots = [row for row in mounts if row["point"] == "/"]
    require(len(roots) == 1 and roots[0]["kind"] == "overlay", "The task must have its own root overlay")
    root = roots[0]
    options = dict(part.split("=", 1) for part in root["options"].split(",") if "=" in part)
    suffix = "/projects/" + EXPECTED_PROJECT
    require(options.get("upperdir", "").endswith(suffix + "/upper"), "The overlay upper does not belong to this exact native environment")
    require(options.get("workdir", "").endswith(suffix + "/work"), "The overlay work directory does not match")
    require(options.get("lowerdir") and options["lowerdir"] != options["upperdir"], "No distinct immutable base")
    for path in ["/usr/share/fonts", "/usr/share/texmf", "/var/lib/dpkg", "/var/lib/apt/lists", "/var/cache/apt", "/etc/apt", "/var/cache/fontconfig", "/var/lib/texmf", "/etc/texmf", "/usr/share/texlive"]:
        matches = [row for row in mounts if path == row["point"] or path.startswith(row["point"].rstrip("/") + "/")]
        selected = max(matches, key=lambda row: len(row["point"]))
        require(selected["id"] == root["id"], "APT would touch a separately mounted/shared path: " + path)
    return root, options


def installed():
    value = subprocess.run(["dpkg-query", "-W", "-f=${binary:Package}\t${db:Status-Status}\n", PACKAGE],
                           text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
    if value.returncode == 1:
        require("no packages found matching " + PACKAGE in value.stderr, "Cannot determine the package's real status")
        return False
    require(value.returncode == 0, "dpkg-query failed")
    lines = value.stdout.strip().splitlines()
    require(len(lines) == 1, "Ambiguous package status")
    name, state = lines[0].split("\t")
    require(name.split(":")[0] == PACKAGE, "Package identity changed")
    return state == "installed"


def run_checked(arguments, log):
    with log.open("ab") as stream:
        result = subprocess.run(arguments, stdout=stream, stderr=subprocess.STDOUT, timeout=120)
    require(result.returncode == 0, "Owned fixture preparation failed; keep the original log")


root, options = root_mount()  # This gate precedes every possible package write.
for binary in ["apt-get", "dpkg-query", "python3"]:
    require(shutil.which(binary), "Required guest command missing: " + binary)
folder = Path(".floe-latex-real-apt-qa")
require(not folder.is_symlink(), "Fixture directory is a symbolic link")
folder.mkdir(mode=0o700, exist_ok=True)
log = folder / "seed.log"
require(not log.is_symlink(), "Fixture log is a symbolic link")
before = installed()
plan = subprocess.run(["apt-get", "-s", "--no-auto-remove", "remove", PACKAGE],
                      text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=120)
require(plan.returncode == 0, "APT removal simulation failed")
(folder / "remove-plan.txt").write_text(plan.stdout)
removed = [line.split()[1].split(":")[0] for line in plan.stdout.splitlines() if line.startswith("Remv ")]
require(all(name == PACKAGE for name in removed), "APT would remove another package; no removal was performed")
require(not any(line.startswith(("Inst ", "Conf ")) for line in plan.stdout.splitlines()), "APT simulation would change other packages")
if before:
    require(removed == [PACKAGE], "The exact installed package is not the only removal")
    root_mount()
    run_checked(["apt-get", "-o", "DPkg::Lock::Timeout=120", "--no-auto-remove", "remove", "-y", PACKAGE], log)
else:
    require(not removed, "Absent package unexpectedly has a removal plan")
require(not installed(), "The selected TeX dependency remains installed")
if shutil.which("fc-cache"):
    run_checked(["fc-cache", "-f"], log)
font_checked = bool(shutil.which("fc-list"))
if font_checked:
    fonts = subprocess.run(["fc-list", "--format", "%{family}|%{fullname}|%{postscriptname}\n", ":"],
                           text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, check=True)
    names = {part.strip().casefold() for line in fonts.stdout.splitlines() for field in line.split("|") for part in field.split(",")}
    require(FAMILY.casefold() not in names, "Another installed font still supplies the requested family; do not fake a missing dependency")
facts = dict(kind="owned-overlay-real-missing-TeX-dependency", project=EXPECTED_PROJECT,
             package=PACKAGE, family=FAMILY, installedBefore=before, removed=before,
             initiallyAbsent=not before, installedAfter=False, fontFamilyAbsenceChecked=font_checked,
             overlayType=root["kind"], upperdir=options["upperdir"], lowerdir=options["lowerdir"],
             removalPlanSHA256=hashlib.sha256(plan.stdout.encode()).hexdigest())
(folder / "seed-receipt.json").write_text(json.dumps(facts, sort_keys=True) + "\n")
print("FLOE_REAL_APT_QA " + base64.b64encode(json.dumps(facts, sort_keys=True).encode()).decode(), flush=True)
"""#
}
#endif
