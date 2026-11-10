// SPDX-License-Identifier: MPL-2.0
#if canImport(UIKit) && DEBUG
import Foundation
import CryptoKit
import XCTest
import FloeModels
import FloePersistence
import FloeEnvironments
import FloeExecution
@testable import FloeApp

/// Operational opt-in only. Originals stay for the separate exact-work case.
@MainActor final class OwnedSimulatorLaTeXTaskEnvironmentCleanupTests: XCTestCase {
    private struct Source: Decodable {
        let sourceBase64: String
        let sourceSHA256: String
    }
    private struct Request: Decodable {
        let schema: Int
        let action: String
        let operationID: UUID
        let appBundleID: String
        let simulatorUDID: String
        let allUIAndAPTWorkSettled: Bool
        let cases: [Source]
    }
    private struct OwnedManifest: Decodable {
        let version: Int
        let facts: [String: String]
    }
    private struct Scope {
        let source: Data
        let caseID: UUID
        let projectID: UUID?
        let kind: String
        let facts: [String: String]
        let taskID: UUID
        let workspaceID: UUID
        let environmentID: String
        let generation: Int64
        var title: String { (kind == "floe.qa.linux.real-pip" ? "QA-Linux-Pip-" : "QA-LaTeX-APT-") + caseID.uuidString }
    }
    private struct Target {
        let scope: Scope
        let privateRoot: URL
        let layer: URL
        let runtimeData: URL
        let projectMetadata: URL?
        let originalMetadataSHA256: String?
        let protectedEvidenceHashes: [URL: String]
    }
    private enum Refusal: Error { case invalidManifest, ownershipChanged, activeWork, unsafePath, changed, unavailable }

    func testDeleteOnlyEndedOwnedLaTeXTasksAndSessionEnvironments() async throws {
        guard let raw = ProcessInfo.processInfo.environment["FLOE_QA_LATEX_TASK_ENV_CLEANUP_JSON"] else {
            throw XCTSkip("Operational cleanup is off; require exact exported case manifests after final UI/APT settlement.")
        }
        #if !targetEnvironment(simulator)
        throw XCTSkip("Operational cleanup is restricted to the existing canonical Simulator.")
        #else
        // The opt-in, source hashes and fixed identity precede bootstrap and
        // all library/DB/runtime access. Imported project files cannot opt in.
        guard raw.utf8.count <= 131_072 else { throw Refusal.invalidManifest }
        let request = try JSONDecoder().decode(Request.self, from: Data(raw.utf8))
        guard request.schema == 1, ["delete-exact-ended-latex-qa-tasks-and-session-environments",
              "delete-exact-ended-linux-pip-qa-task-and-session-environment"].contains(request.action),
              request.appBundleID == "org.floeagent.ios", Bundle.main.bundleIdentifier == request.appBundleID,
              request.simulatorUDID == "6366F0FB-C395-4A9C-8983-0082850F43A6",
              ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == request.simulatorUDID,
              request.allUIAndAPTWorkSettled, (1...16).contains(request.cases.count) else { throw Refusal.invalidManifest }
        let scopes = try request.cases.map(Self.scope)
        let pipOnly = request.action == "delete-exact-ended-linux-pip-qa-task-and-session-environment"
        guard pipOnly ? (scopes.count == 1 && scopes.allSatisfy { $0.kind == "floe.qa.linux.real-pip" })
                      : scopes.allSatisfy({ $0.kind == "floe.qa.latex.real-apt" }) else { throw Refusal.invalidManifest }
        guard Set(scopes.map(\.caseID)).count == scopes.count,
              Set(scopes.compactMap(\.projectID)).count == scopes.compactMap(\.projectID).count,
              Set(scopes.map(\.taskID)).count == scopes.count,
              Set(scopes.map(\.workspaceID)).count == scopes.count,
              Set(scopes.map(\.environmentID)).count == scopes.count else { throw Refusal.invalidManifest }
        let app = try await appQualificationEnvironment()
        let library = try await PersonalContentService.shared.library()
        let workspaces = SQLiteWorkspaceStore(database: app.database)
        let bindings = TaskExecutionBindingStore(database: app.database)
        let jobs = BackgroundJobStore(database: app.database)
        let authority = try app.studioCoordinator.access.get()
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: false)
        let runtime = try RuntimeV2Layout.production() // Actual ARM64 production root, not the stale v2 header comment.
        let environmentRoots = EnvironmentRoots()
        let services = FloePlatformServices.shared
        guard services.linuxGuestController() != nil else { throw Refusal.unavailable }
        try await app.environmentRegistry.prepare()
        let taskIDs = Set(scopes.map(\.taskID)), workspaceIDs = Set(scopes.map(\.workspaceID))
        let environmentIDs = Set(scopes.map(\.environmentID))
        let beforeTasks = try await app.conversationStore.conversations(includeArchived: true)
        let protectedTasks = Dictionary(uniqueKeysWithValues: beforeTasks.filter { !taskIDs.contains($0.id) }.map { ($0.id, $0) })
        let beforeWorkspaces = try await workspaces.workspaces()
        let protectedWorkspaces = Dictionary(uniqueKeysWithValues: beforeWorkspaces.filter { !workspaceIDs.contains($0.id) }.map { ($0.id, $0) })
        let beforeEnvironments = await app.environmentRegistry.all()
        let protectedEnvironments = Dictionary(uniqueKeysWithValues: beforeEnvironments.filter { !environmentIDs.contains($0.id) }.map { ($0.id, $0) })
        let beforeWorks = try await library.records(includingDeleted: true)
        let worksByID = Dictionary(uniqueKeysWithValues: beforeWorks.map { ($0.id, $0) })
        let libraryRoot = await library.root
        let metadataHashes = try Dictionary(uniqueKeysWithValues: beforeWorks.map { record in
            (record.id, try Self.hashFile(libraryRoot.appendingPathComponent(record.relativePath).appendingPathComponent("FloeProject.json")))
        })
        let oldTrash = Set(try await library.recentlyDeleted())
        let oldEnvironmentTrash = try Self.children(environmentRoots.trashURL)
        var targets: [Target] = []
        for scope in scopes {
            let conversation = beforeTasks.first(where: { $0.id == scope.taskID })
            guard conversation?.purpose == .ordinary else { throw Refusal.ownershipChanged }
            let parent = try await authority.assistantProject(conversationID: scope.taskID)
            let grants = try await authority.projectIDs(conversationID: scope.taskID)
            var projectMetadata: URL?, metadataSHA: String?
            var protectedEvidenceHashes: [URL: String] = [:]
            if let projectID = scope.projectID {
                let original = try await library.resolve(projectID)
                let assistant = try await authority.assistant(projectID: projectID)
                guard original.record.kind == .latex, original.record.title == scope.title,
                      original.record.deletedAt == nil, !original.record.needsRecovery,
                      ["作品助手 · " + scope.title, "Work assistant · " + scope.title].contains(conversation?.title ?? ""),
                      assistant == scope.taskID, parent == projectID, Set(grants) == [projectID] else { throw Refusal.ownershipChanged }
                try Self.confined(original.url)
                projectMetadata = original.url.appendingPathComponent("FloeProject.json")
                metadataSHA = try Self.hashFile(projectMetadata!)
            } else {
                guard scope.kind == "floe.qa.linux.real-pip", conversation?.title == scope.title,
                      parent == nil, grants.isEmpty else { throw Refusal.ownershipChanged }
                protectedEvidenceHashes = try await requireCompletedPipProof(scope, app: app, workspace: workspaces, support: support)
            }
            let workspaceID = try await workspaces.workspaceID(conversationID: scope.taskID)
            let workspace = try await workspaces.workspace(id: scope.workspaceID)
            let occupants = try await workspaces.conversations(workspaceID: scope.workspaceID)
            let relative = "PrivateTasks/" + scope.taskID.uuidString
            guard workspaceID == scope.workspaceID, workspace?.kind == .privateTask,
                  workspace?.internalRelativePath == relative, Set(occupants) == [scope.taskID] else { throw Refusal.ownershipChanged }
            let binding = try await bindings.binding(conversationID: scope.taskID)
            guard binding?.generation == scope.generation, binding?.target.backend == .linuxVM,
                  binding?.target.environmentID == scope.environmentID, binding?.target.remoteHostID == nil else { throw Refusal.ownershipChanged }
            guard let record = await app.environmentRegistry.record(id: scope.environmentID),
                  record.kind == .session, record.ownerID == scope.taskID.uuidString,
                  record.effectiveExecutionBackend == .linuxVM, record.pendingRuntimeResetID == nil,
                  record.state != .deleting,
                  !beforeEnvironments.contains(where: { $0.parentID == record.id || $0.templateID == record.id }),
                  let layer = await app.environmentRegistry.layerURL(for: record.id) else { throw Refusal.ownershipChanged }
            try await requireIdle(scope, app: app, jobs: jobs)
            let privateRoot = support.appendingPathComponent("FloeAgent").appendingPathComponent(relative)
            try Self.confined(privateRoot); try Self.confined(layer)
            targets.append(Target(scope: scope, privateRoot: privateRoot, layer: layer,
                runtimeData: try runtime.environmentDirectory(environmentID: scope.environmentID),
                projectMetadata: projectMetadata, originalMetadataSHA256: metadataSHA,
                protectedEvidenceHashes: protectedEvidenceHashes))
        }
        let evidence = support.appendingPathComponent("FloeAgent/OperationalCleanupEvidence")
            .appendingPathComponent(request.operationID.uuidString)
        guard !FileManager.default.fileExists(atPath: evidence.path) else { throw Refusal.changed }
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try Data(raw.utf8).write(to: evidence.appendingPathComponent("EXACT-REQUEST.json"), options: .withoutOverwriting)
        for target in targets {
            try target.scope.source.write(to: evidence.appendingPathComponent(target.scope.caseID.uuidString + ".owned-manifest.json"), options: .withoutOverwriting)
        }
        var report: [String: Any] = ["operationID": request.operationID.uuidString, "phase": "verified-before-cleanup",
            "scope": "Exact owned QA task/private workspace/session environment only; all work originals preserved",
            "filesystemFreeBytesBefore": try Self.freeBytes(support), "before": try targets.map(Self.measure),
            "sharedImagesAndCaches": "Not selected or deleted; directory sizes and filesystem free-space changes do not establish causal attribution",
            "runtimePersistentData": "Native environment deletion may retain Runtime v2 system/data. Measure and report it; never raw-delete or remove a runtime DB row."]
        try persist(report, at: evidence)
        do {
            for target in targets {
                let scope = target.scope
                try await requireIdle(scope, app: app, jobs: jobs)
                report["phase"] = "stopping-owned-environment"; report["currentCaseID"] = scope.caseID.uuidString
                try persist(report, at: evidence)
                try await services.stopEnvironment(id: scope.environmentID)
                let stopped = await services.linuxEnvironmentStatus(id: scope.environmentID)
                let stoppedRecord = await app.environmentRegistry.record(id: scope.environmentID)
                guard stopped?.environmentID == scope.environmentID, stopped?.running == false,
                      stoppedRecord?.state == .stopped else { throw Refusal.activeWork }
                try await requireIdle(scope, app: app, jobs: jobs)
                report["phase"] = "deleting-exact-owned-task"; try persist(report, at: evidence)
                try await app.conversationCenter.deleteConversation(id: scope.taskID)
                let remainingTask = try await app.conversationStore.conversation(id: scope.taskID)
                let remainingWorkspace = try await workspaces.workspace(id: scope.workspaceID)
                let remainingBinding = try await bindings.binding(conversationID: scope.taskID)
                guard remainingTask == nil, remainingWorkspace == nil, remainingBinding == nil,
                      !FileManager.default.fileExists(atPath: target.privateRoot.path) else { throw Refusal.changed }
                report["phase"] = "deleting-exact-session-environment"; try persist(report, at: evidence)
                try await services.deleteEnvironment(id: scope.environmentID)
                let removed = await app.environmentRegistry.record(id: scope.environmentID)
                let status = await services.linuxEnvironmentStatus(id: scope.environmentID)
                guard removed == nil, status?.running == false,
                      !FileManager.default.fileExists(atPath: target.layer.path),
                      try Self.protectedInputsUnchanged(target) else { throw Refusal.changed }
                report["lastCompletedCaseID"] = scope.caseID.uuidString
                report["afterSoFar"] = try targets.map(Self.measure); try persist(report, at: evidence)
            }
            let afterTasks = try await app.conversationStore.conversations(includeArchived: true)
            let afterWorkspaces = try await workspaces.workspaces()
            let afterEnvironments = await app.environmentRegistry.all()
            let afterWorks = try await library.records(includingDeleted: true)
            let afterTrash = Set(try await library.recentlyDeleted())
            guard Dictionary(uniqueKeysWithValues: afterTasks.map { ($0.id, $0) }) == protectedTasks,
                  Dictionary(uniqueKeysWithValues: afterWorkspaces.map { ($0.id, $0) }) == protectedWorkspaces,
                  Dictionary(uniqueKeysWithValues: afterEnvironments.map { ($0.id, $0) }) == protectedEnvironments,
                  Dictionary(uniqueKeysWithValues: afterWorks.map { ($0.id, $0) }) == worksByID,
                  afterTrash == oldTrash, try Self.children(environmentRoots.trashURL) == oldEnvironmentTrash else { throw Refusal.changed }
            for record in afterWorks {
                guard try Self.hashFile(libraryRoot.appendingPathComponent(record.relativePath).appendingPathComponent("FloeProject.json")) == metadataHashes[record.id] else { throw Refusal.changed }
            }
            let freeAfter = try Self.freeBytes(support)
            report["phase"] = "completed-native-task-and-session-record-cleanup"
            report["filesystemFreeBytesAfter"] = freeAfter
            report["observedFilesystemFreeByteDelta"] = freeAfter - ((report["filesystemFreeBytesBefore"] as? Int64) ?? freeAfter)
            report["after"] = try targets.map(Self.measure)
            report["allOriginalsAndOtherTasksEnvironmentsWorkspacesPreserved"] = true
            try persist(report, at: evidence)
        } catch {
            report["phase"] = "failed-partial-result-retained"
            report["error"] = String(describing: error)
            report["afterFailure"] = try? targets.map(Self.measure)
            try? persist(report, at: evidence)
            throw error
        }
        #endif
    }

    private func requireIdle(_ scope: Scope, app: AppEnvironment, jobs: BackgroundJobStore) async throws {
        let runs = try await app.runStore.runs(conversationID: scope.taskID)
        let activeJobs = try await jobs.activeJobs(environmentID: scope.environmentID)
        let taskJobs = try await jobs.jobs(conversationID: scope.taskID, limit: 100)
        let leases = await app.executionLeaseCount(scope.environmentID)
        let allowed = Set(["completed", "failed", "cancelled", "checkpointed", "interrupted"])
        guard runs.allSatisfy({ allowed.contains($0.state) &&
                  ($0.executionBinding == nil || $0.executionBinding?.target.environmentID == scope.environmentID) }),
              activeJobs.isEmpty, taskJobs.count < 100, taskJobs.allSatisfy({ $0.state.isTerminal }), leases == 0,
              !app.conversationCenter.activeRuns.values.contains(where: { $0.conversationID == scope.taskID }),
              !app.conversationCenter.pendingApprovals.contains(where: { $0.conversationID == scope.taskID }),
              !app.taskExecutionEnvironments.isMigrating(scope.taskID) else { throw Refusal.activeWork }
    }
    private static func scope(_ source: Source) throws -> Scope {
        guard let data = Data(base64Encoded: source.sourceBase64), data.count <= 65_536,
              digest(data) == source.sourceSHA256 else { throw Refusal.invalidManifest }
        let value = try JSONDecoder().decode(OwnedManifest.self, from: data), f = value.facts
        guard value.version == 1, let kind = f["kind"], f["liveModelInference"] == "false",
              let caseID = f["caseID"].flatMap(UUID.init(uuidString:)),
              let task = f["taskID"].flatMap(UUID.init(uuidString:)),
              let workspace = f["workspaceID"].flatMap(UUID.init(uuidString:)),
              let environment = f["environmentID"], UUID(uuidString: environment) != nil,
              let generation = f["bindingGeneration"].flatMap(Int64.init), generation > 0 else { throw Refusal.invalidManifest }
        let project: UUID?
        if kind == "floe.qa.latex.real-apt" {
            guard f["scope"] == "new owned QA original/task/session overlay only",
                  let id = f["projectID"].flatMap(UUID.init(uuidString:)) else { throw Refusal.invalidManifest }
            project = id
        } else if kind == "floe.qa.linux.real-pip" {
            // This one completed, already-exported case is authorized. An
            // arbitrary QA prefix or a failed/partial APT case cannot opt in.
            guard source.sourceSHA256 == "14132a05058ff75410663391de5fef1de222a2d691fd414ece904caf94e62c40",
                  f["scope"] == "one new owned ordinary task/workspace/session; no TeX or apt",
                  f["phase"] == "completed-retained-for-root-cleanup", f["projectID"] == nil,
                  f["pip.approvalDecision"] == "allow-once", f["pip.resolvedCallID"] == f["pip.callID"],
                  f["pip.environmentID"] == environment, f["pip.bindingGeneration"] == String(generation) else { throw Refusal.invalidManifest }
            project = nil
        } else { throw Refusal.invalidManifest }
        return Scope(source: data, caseID: caseID, projectID: project, kind: kind, facts: f, taskID: task,
                     workspaceID: workspace, environmentID: environment, generation: generation)
    }

    private func requireCompletedPipProof(_ scope: Scope, app: AppEnvironment,
                                          workspace: SQLiteWorkspaceStore, support: URL) async throws -> [URL: String] {
        let f = scope.facts
        guard scope.kind == "floe.qa.linux.real-pip", let rawRun = f["pip.runID"], let runID = UUID(uuidString: rawRun),
              let callID = f["pip.callID"], f["pip.approvalDecision"] == "allow-once",
              f["pip.resolvedCallID"] == callID, f["pip.bindingGeneration"] == String(scope.generation),
              f["pip.environmentID"] == scope.environmentID else { throw Refusal.invalidManifest }
        let binding = try await TaskExecutionBindingStore(database: app.database).binding(conversationID: scope.taskID)
        let runs = try await app.runStore.runs(conversationID: scope.taskID)
        guard runs.count == 1, let run = runs.first, run.id == runID, run.state == "completed", run.endedAt != nil,
              run.executionBinding == binding, binding?.generation == scope.generation,
              binding?.target.environmentID == scope.environmentID else { throw Refusal.ownershipChanged }
        let policy = try await workspace.taskPolicy(conversationID: scope.taskID)
        guard policy.allowedToolNames == ["exec.shell"], policy.approvalMode == TaskApprovalMode.automatic.rawValue, policy.networkAllowed == true else { throw Refusal.ownershipChanged }
        let events = try await app.runStore.events(runID: runID)
        func payloads(_ kind: RunEventRecord.Kind) throws -> [[String: String]] {
            try events.filter { $0.kind == kind }.map {
                try JSONDecoder().decode([String: String].self, from: Data($0.payloadJSON.utf8))
            }
        }
        let requests = try payloads(.toolRequest), approvals = try payloads(.approval), results = try payloads(.toolResult)
        guard requests.count == 1, requests[0]["id"] == callID, requests[0]["tool"] == "exec.shell",
              approvals.count == 1, approvals[0]["callID"] == callID, approvals[0]["tool"] == "exec.shell",
              approvals[0]["scope"] == "local", results.count == 1, results[0]["id"] == callID,
              results[0]["tool"] == "exec.shell", results[0]["status"] == "ok", results[0]["dispatched"] == "true",
              let input = requests[0]["input"] else { throw Refusal.ownershipChanged }
        let arguments = try JSONDecoder().decode(LocalShellTool.Arguments.self, from: Data(input.utf8))
        guard arguments.cwd == ".", arguments.timeoutSeconds == 600, arguments.timeoutPolicy == "hard",
              arguments.command == nil, arguments.env == nil, arguments.stdin == nil, arguments.timeout == nil,
              arguments.packages == nil, arguments.maxOutputBytes == 16384,
              let script = arguments.script, Self.digest(Data(script.utf8)) == f["pip.scriptSHA256"] else { throw Refusal.ownershipChanged }
        // This native evidence namespace is independent of the private task
        // workspace. Root's preparer also checks the already-exported copies.
        let evidence = support.appendingPathComponent("FloeAgent/QualificationEvidence/LinuxRealPip")
            .appendingPathComponent(scope.caseID.uuidString)
        var hashes: [URL: String] = [:]
        let manifest = evidence.appendingPathComponent("owned-manifest.json")
        guard try Self.hashFile(manifest) == Self.digest(scope.source) else { throw Refusal.changed }
        hashes[manifest] = Self.digest(scope.source)
        for name in ["preflight.json", "install.log", "pip-report.json", "result.json"] {
            let file = evidence.appendingPathComponent(name)
            guard let expected = f[name + ".sha256"], try Self.hashFile(file) == expected,
                  let count = f[name + ".bytes"].flatMap(Int.init),
                  (try file.resourceValues(forKeys: [.fileSizeKey])).fileSize == count else { throw Refusal.changed }
            hashes[file] = expected
        }
        return hashes
    }
    private static func protectedInputsUnchanged(_ target: Target) throws -> Bool {
        if let metadata = target.projectMetadata {
            guard try hashFile(metadata) == target.originalMetadataSHA256 else { return false }
        } else if target.originalMetadataSHA256 != nil { return false }
        for (file, expected) in target.protectedEvidenceHashes {
            guard try hashFile(file) == expected else { return false }
        }
        return true
    }

    private func persist(_ report: [String: Any], at directory: URL) throws {
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: directory.appendingPathComponent("RESULT.json"), options: .atomic)
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "Exact QA task environment cleanup " + (report["phase"] as? String ?? "phase")
        attachment.lifetime = .keepAlways; add(attachment)
        print("FLOE_QA_TASK_ENV_CLEANUP_EVIDENCE=" + directory.path)
    }
    private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    private static func hashFile(_ url: URL) throws -> String {
        try confined(url)
        let info = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard info.isSymbolicLink != true, info.isRegularFile == true, (info.fileSize ?? Int.max) <= 1_048_576 else { throw Refusal.unsafePath }
        return digest(try Data(contentsOf: url))
    }
    private static func confined(_ url: URL) throws {
        let home = URL(fileURLWithPath: NSHomeDirectory()).resolvingSymlinksInPath().standardizedFileURL.path
        let actual = url.standardizedFileURL.resolvingSymlinksInPath()
        guard actual.path.hasPrefix(home + "/"), actual.path == url.standardizedFileURL.path else { throw Refusal.unsafePath }
    }
    private static func children(_ url: URL) throws -> Set<String> {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        try confined(url)
        return Set(try FileManager.default.contentsOfDirectory(atPath: url.path))
    }
    private static func freeBytes(_ url: URL) throws -> Int64 {
        guard let value = try FileManager.default.attributesOfFileSystem(forPath: url.path)[.systemFreeSize] as? NSNumber else { throw Refusal.unavailable }
        return value.int64Value
    }
    private static func measure(_ target: Target) throws -> [String: Any] {
        ["caseID": target.scope.caseID.uuidString, "kind": target.scope.kind,
         "projectID": target.scope.projectID?.uuidString ?? "none",
         "taskID": target.scope.taskID.uuidString, "environmentID": target.scope.environmentID,
         "privateWorkspace": try size(target.privateRoot), "legacyWritableLayer": try size(target.layer),
         "runtimeV2PersistentEnvironment": try size(target.runtimeData)]
    }
    private static func size(_ url: URL) throws -> [String: Any] {
        try confined(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return ["exists": false, "logicalRegularFileBytes": 0, "allocatedFileBytes": 0] }
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey, .fileAllocatedSizeKey]
        var failed = false
        guard let walk = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
            options: [], errorHandler: { _, _ in failed = true; return false }) else { throw Refusal.unsafePath }
        var logical: Int64 = 0, allocated: Int64 = 0, files = 0
        for case let file as URL in walk {
            let info = try file.resourceValues(forKeys: Set(keys))
            if info.isSymbolicLink == true { walk.skipDescendants(); continue }
            if info.isRegularFile == true {
                logical += Int64(info.fileSize ?? 0); allocated += Int64(info.fileAllocatedSize ?? 0); files += 1
            }
        }
        guard !failed else { throw Refusal.unavailable }
        return ["exists": true, "logicalRegularFileBytes": logical, "allocatedFileBytes": allocated, "regularFiles": files,
                "allocationCaveat": "Per-file allocation can share APFS extents; it is not unique physical reclamation."]
    }
}
#endif
