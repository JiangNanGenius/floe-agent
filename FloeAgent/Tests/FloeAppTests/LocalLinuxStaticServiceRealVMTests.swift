// Real service qualification, not a model or UI test. Opt-in only: the
// production pinned Linux image may be downloaded on first activation.
// Run this suite serially with other real-guest tests; it owns only the
// canonical project environment for its unique workspace root.
#if canImport(UIKit) && DEBUG
import Foundation
import Testing
import UserNotifications
import FloeCore
import FloeExecution
import FloeModels
import FloePersistence
import FloeTools
@testable import FloeApp

@Suite("FloeApp.LocalLinuxStaticServiceRealVM", .serialized)
@MainActor struct LocalLinuxStaticServiceRealVMTests {
    // Operational cleanup for one explicitly identified, obsolete fixture.
    // Disabled in normal qualification; never scan or remove user environments.
    @Test("remove one explicitly owned stopped qualification layer through production lifecycle",
          .enabled(if: ProcessInfo.processInfo.environment["FLOE_OWNED_QA_CLEANUP"] == "1"))
    func cleanupExplicitStoppedQualificationLayer() async throws {
        let values = ProcessInfo.processInfo.environment
        let id = try #require(values["FLOE_OWNED_QA_ENVIRONMENT_ID"])
        let owner = try #require(values["FLOE_OWNED_QA_OWNER_SHA256"])
        try #require(UUID(uuidString: id) != nil && owner.count == 64
                     && owner.allSatisfy { "0123456789abcdef".contains($0) })
        let app = AppEnvironment.live()
        await app.bootstrap()
        try #require(app.persistenceReady)
        let registry = app.environmentRegistry
        // App bootstrap opens persistence; the environment registry is loaded
        // lazily by execution. This explicit maintenance path must load it too.
        try await registry.prepare()
        let record = try #require(await registry.record(id: id))
        let name = try #require(record.name)
        try #require(record.kind == .project && record.state == .stopped && record.ownerID == owner)
        try #require(name.hasPrefix("subagent-guest-")
                     && UUID(uuidString: String(name.dropFirst("subagent-guest-".count))) != nil)
        let workspace = try #require(try await registry.workspaceRoot(for: id))
        try #require(workspace.lastPathComponent == name
                     && !FileManager.default.fileExists(atPath: workspace.path))
        let layer = try #require(await registry.layerURL(for: id))
        try #require(layer.lastPathComponent == id && layer.deletingLastPathComponent().lastPathComponent == "Containers")
        let mappingURL = layer.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("workspace-containers.json")
        let mappingBefore = try JSONDecoder().decode([String: [String: String]].self,
                                                     from: Data(contentsOf: mappingURL))
        try #require(mappingBefore[owner]?["containerID"] == id)
        let otherIDs = await registry.all().filter { $0.id != id }.map(\.id)
        let services = FloePlatformServices.shared
        try await services.stopEnvironment(id: id)
        let stopped = try #require(await services.linuxGuestStatus(id: id))
        try #require(!stopped.running)
        try await services.deleteEnvironment(id: id)
        try #require(await registry.record(id: id) == nil)
        try #require(!FileManager.default.fileExists(atPath: layer.path))
        let mappingAfter = try JSONDecoder().decode([String: [String: String]].self,
                                                    from: Data(contentsOf: mappingURL))
        try #require(!mappingAfter.values.contains { $0["containerID"] == id })
        for (key, value) in mappingBefore where value["containerID"] != id {
            #expect(mappingAfter[key] == value)
        }
        for otherID in otherIDs { #expect(await registry.record(id: otherID) != nil) }
        #expect(await services.linuxGuestStatus(id: id)?.running != true)
        print("FLOE_OWNED_QA_CLEANUP_VERIFIED id=\(id) otherRecordsPreserved=\(otherIDs.count)")
    }

    // Opt-in service acceptance, never a mock or a UI/physical-device claim.
    // Select this method alone and serialize it with all other real-VM work.
    @Test("real guest ordered soft restart preserves its disk and shares and exact replay does not reboot",
          .enabled(if: ProcessInfo.processInfo.environment["FLOE_REALVM_SOFT_RESTART_QUALIFICATION"] == "1"))
    func realGuestSoftRestartPersistenceGenerationAndReplay() async throws {
        let app = AppEnvironment.live()
        await app.bootstrap()
        try #require(app.persistenceReady, "Production persistence bootstrap failed")
        let services = FloePlatformServices.shared
        let controller = try #require(services.linuxGuestController(), "Production Linux controller is unavailable")
        let runner = try #require(services.linuxCommandRunner(), "Production Linux command runner is unavailable")
        let qualificationID = UUID().uuidString
        // The lifecycle tools pass the trusted run UUID in this field.
        // This test owns one synthetic run identity and never adopts one.
        let ownerTaskID = UUID().uuidString
        let operationKey = "soft-restart-once-" + UUID().uuidString
        let nonce = UUID().uuidString
        let root = URL.applicationSupportDirectory
            .appendingPathComponent("FloeAgent/QualificationWorkspaces/SoftRestart/" + qualificationID, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let evidenceRoot = URL.applicationSupportDirectory
            .appendingPathComponent("FloeAgent/QualificationEvidence/SoftRestart/" + qualificationID, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: evidenceRoot, withIntermediateDirectories: true)
        let workspaceOwner = FloeDigest.sha256Hex(Data(root.path.utf8))
        let shareName = "qa-share-" + qualificationID
        let reconnectName = "qa-reconnected-" + qualificationID
        try Data(nonce.utf8).write(to: root.appendingPathComponent(shareName), options: .atomic)
        let guestFile = "/var/lib/floe/qa-soft-restart-" + qualificationID
        // This is the actual live assembly's store, opened independently for
        // readback. It is never injected into/replaced on the live manager.
        let store = LinuxGuestFileSoftRestartStore(directory: URL.applicationSupportDirectory
            .appendingPathComponent("FloeAgent/LinuxGuestSoftRestart", isDirectory: true))
        var environmentID: String?
        var restartAttempted = false
        var evidence: [String: String] = ["kind": "real-live-service-soft-restart",
            "workspace": root.path, "workspaceOwner": workspaceOwner,
            "ownerTaskID": ownerTaskID, "operationKey": operationKey,
            "guestFile": guestFile, "nonce": nonce, "evidenceRoot": evidenceRoot.path]

        func retain(_ phase: String) throws {
            evidence["phase"] = phase
            try JSONEncoder().encode(evidence).write(to: evidenceRoot.appendingPathComponent("evidence.json"), options: .atomic)
            print("FLOE_SOFT_RESTART_REALVM phase=\(phase) evidence=\(evidenceRoot.path)")
        }

        func saveDurableEvidence(_ id: String, suffix: String) async throws {
            if let operation = try await store.load(environmentID: id) {
                try JSONEncoder().encode(operation).write(to: evidenceRoot
                    .appendingPathComponent("operation-" + suffix + ".json"), options: .atomic)
                evidence["durableStatus"] = operation.status.rawValue
                evidence["durableOperationID"] = operation.operationID
            }
            if let committed = try await store.loadCommittedReceipt(environmentID: id, operationKey: operationKey) {
                try JSONEncoder().encode(committed).write(to: evidenceRoot
                    .appendingPathComponent("receipt-" + suffix + ".json"), options: .atomic)
            }
        }

        func ownRuntime(_ id: String) async throws -> LinuxGuestRuntimeState {
            let states = await controller.runtimeStates().filter { $0.environmentID == id }
            try #require(states.count == 1, "Own environment must have exactly one authoritative runtime")
            let state = try #require(states.first)
            try #require(state.running, "Own runtime is not running")
            return state
        }

        func guest(_ id: String, script: String, arguments: [String] = []) async throws -> LinuxCommandResult {
            let result = try await runner.run(environmentID: id,
                argv: ["/bin/sh", "-c", script, "soft-restart-qualification"] + arguments,
                workingDirectory: "/workspace", standardInput: nil, timeout: 90,
                maxOutputBytes: 8_192, cancellation: CancellationToken())
            evidence["lastGuestStdout"] = result.stdout
            evidence["lastGuestStderr"] = result.stderr
            evidence["lastGuestExit"] = String(result.exitCode)
            try #require(result.exitCode == 0, "Real guest command failed; bounded output is retained")
            return result
        }

        func cleanupSettledOwnEnvironment() async throws {
            // Resolve only this exact unique workspace, even if preparation
            // failed after creating its record. Never use first/latest all().
            let ownID: String?
            if let id = environmentID { ownID = id }
            else { ownID = try await ownedEnvironment(root: root, app: app) }
            if let id = ownID {
                let record = try #require(await app.environmentRegistry.record(id: id))
                try #require(record.kind == .project && record.ownerID == workspaceOwner)
                let mappedRoot = try #require(try await app.environmentRegistry.workspaceRoot(for: id))
                try #require(mappedRoot.resolvingSymlinksInPath().standardizedFileURL == root)
                let layer = try #require(await app.environmentRegistry.layerURL(for: id))
                // A pending/corrupt/missing-after-submission record is an
                // unresolved outcome. Do not force-stop or delete its disk.
                let operation = try await store.load(environmentID: id)
                if restartAttempted {
                    try #require(operation != nil && operation?.status != .pending,
                        "Restart outcome remains unresolved; retain own guest, disk and evidence for reconciliation")
                }
                let beforeStop = await app.linuxGuestLifecycle.reconciliationSnapshot(environmentID: id)
                if !beforeStop.isQuietlyStopped {
                    let stopped = try await app.linuxGuestLifecycle.stop(environmentID: id, cancellation: CancellationToken())
                    try #require(stopped.phase == .stopped)
                }
                let quiet = await app.linuxGuestLifecycle.reconciliationSnapshot(environmentID: id)
                try #require(quiet.isQuietlyStopped, "Own worker exit/capture is unconfirmed; preserve its disk")
                try await services.deleteEnvironment(id: id)
                try #require(await app.environmentRegistry.record(id: id) == nil)
                try #require(!FileManager.default.fileExists(atPath: layer.path))
                evidence["cleanup"] = "own environment stopped, reconciled quiet and deleted; durable receipts retained with exported evidence"
            }
            try FileManager.default.removeItem(at: root)
        }

        do {
            try await services.prepareWorkspaceEnvironment(root: root)
            let id = try #require(try await ownedEnvironment(root: root, app: app), "Own project environment was not prepared")
            environmentID = id; evidence["environmentID"] = id
            let record = try #require(await app.environmentRegistry.record(id: id))
            try #require(record.kind == .project && record.ownerID == workspaceOwner)
            let layerBefore = try #require(await app.environmentRegistry.layerURL(for: id))
            evidence["environmentLayer"] = layerBefore.path
            try #require(await runner.ownsLinuxEnvironment(environmentID: id))
            try retain("starting-own-guest")
            // Uses the same live manager/image preparation, resource policy
            // and engine as the App tools. No seeded image or fake performer.
            let started = try await app.linuxGuestLifecycle.start(environmentID: id,
                config: LinuxGuestLifecycleConfig(vcpus: 1, memoryMB: 256),
                ownerTaskID: ownerTaskID, cancellation: CancellationToken())
            try #require(started.phase == .running && !started.reused)
            let before = try await ownRuntime(id)
            let oldGeneration = try #require(before.identity.launchGeneration, "Generation evidence is required")
            evidence["oldGeneration"] = String(oldGeneration)
            try #require(started.launchGeneration == Int(exactly: oldGeneration))
            // The file is written by the real guest on its root ext4 disk,
            // explicitly excluding the host-backed workspace/environment 9p
            // shares and RAM filesystems from the persistence proof.
            _ = try await guest(id, script: #"""
            set -eu
            mkdir -p /var/lib/floe
            test "$(stat -c %d /var/lib/floe)" = "$(stat -c %d /)"
            awk '$2 == "/" && $3 == "ext4" { found=1 } END { exit !found }' /proc/mounts
            printf '%s' "$2" > "$1"
            sync
            """#, arguments: [guestFile, nonce])
            let witnessScript = #"""
            set -eu
            test "$(cat "$1")" = "$2"
            test "$(cat "$3")" = "$2"
            test "$(stat -c %d "$1")" = "$(stat -c %d /)"
            awk '$2 == "/" && $3 == "ext4" { found=1; print "root=" $1 ":" $3 } END { exit !found }' /proc/mounts
            printf 'nonce='; cat "$1"
            printf '\ninode='; stat -c %i "$1"
            """#
            let witnessArguments = [guestFile, nonce, "/workspace/" + shareName]
            let witnessBefore = try await guest(id, script: witnessScript, arguments: witnessArguments)
            evidence["diskWitnessBefore"] = witnessBefore.stdout
            try retain("persistent-ext4-file-written")

            restartAttempted = true
            let receipt = try await app.linuxGuestLifecycle.softRestart(environmentID: id,
                config: nil, ownerTaskID: ownerTaskID, operationKey: operationKey, cancellation: CancellationToken())
            try #require(receipt.phase == .running && receipt.environmentID == id && !receipt.reused)
            let operationID = try #require(receipt.operationID)
            try JSONEncoder().encode(receipt).write(to: evidenceRoot.appendingPathComponent("returned-receipt.json"), options: .atomic)
            try await saveDurableEvidence(id, suffix: "committed")
            let operation = try #require(try await store.load(environmentID: id))
            try #require(operation.status == .committed && operation.progress == .diskCaptureCommitted)
            try #require(operation.environmentID == id && operation.ownerTaskID == ownerTaskID
                         && operation.operationKey == operationKey && operation.operationID == operationID)
            try #require(operation.preLaunchGeneration == oldGeneration && operation.committedReceipt == receipt)
            try #require(operation.stageReceipts.map(\.stage) == [.flush, .rebootRequest, .guestExit, .diskCapture, .newBoot],
                "The real transport must prove ordered flush, guest exit, disk capture and reconnect")
            try #require(operation.stageReceipts.allSatisfy { $0.outcome == "ok" })
            let journal = try #require(try await store.loadCommittedReceipt(environmentID: id, operationKey: operationKey))
            try #require(journal.ownerTaskID == ownerTaskID && journal.receipt == receipt)
            let after = try await ownRuntime(id)
            let newGeneration = try #require(after.identity.launchGeneration)
            try #require(newGeneration != oldGeneration && receipt.launchGeneration == Int(exactly: newGeneration))
            try #require(after.vcpus == before.vcpus && after.ramMB == before.ramMB)
            try #require(receipt.actualVCPUs == after.vcpus && receipt.actualMemoryMB == after.ramMB)
            try #require(await app.environmentRegistry.layerURL(for: id) == layerBefore)
            evidence["newGeneration"] = String(newGeneration)
            let witnessAfter = try await guest(id, script: witnessScript, arguments: witnessArguments)
            try #require(witnessAfter.stdout == witnessBefore.stdout, "Persistent nonce, inode and root disk witness changed")
            evidence["diskWitnessAfter"] = witnessAfter.stdout
            let diskNonce = try await guest(id, script: #"cat "$1""#,
                arguments: [LinuxGuestServiceSoftRestartTransport.defaultNoncePath])
            try #require(diskNonce.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == operationID)
            _ = try await guest(id, script: #"set -eu; printf '%s' "$1" > "$2"; sync"#,
                arguments: [nonce, "/workspace/" + reconnectName])
            try #require(try Data(contentsOf: root.appendingPathComponent(reconnectName)) == Data(nonce.utf8),
                "Replacement must reconnect to the exact owned workspace share")
            try retain("ordered-restart-disk-and-share-verified")

            // One exact replay, with the same trusted owner/key/payload.
            // Compare the complete original receipt and durable record, then
            // execute on the replacement and re-read authoritative identity.
            let replay = try await app.linuxGuestLifecycle.softRestart(environmentID: id,
                config: nil, ownerTaskID: ownerTaskID, operationKey: operationKey, cancellation: CancellationToken())
            try #require(replay == receipt, "Exact replay must return the original receipt verbatim")
            let replayWitness = try await guest(id, script: witnessScript, arguments: witnessArguments)
            try #require(replayWitness.stdout == witnessBefore.stdout)
            let afterReplay = try await ownRuntime(id)
            try #require(afterReplay.identity == after.identity, "Exact replay must not launch another generation")
            try #require(try await store.load(environmentID: id) == operation)
            try #require(try await store.loadCommittedReceipt(environmentID: id, operationKey: operationKey) == journal)
            try await saveDurableEvidence(id, suffix: "replayed")
            evidence["replayGeneration"] = String(try #require(afterReplay.identity.launchGeneration))
            try retain("exact-replay-verified")
            try await cleanupSettledOwnEnvironment()
            try retain("passed-and-cleaned")
        } catch {
            evidence["failure"] = String(describing: error)
            if let id = environmentID {
                do { try await saveDurableEvidence(id, suffix: "failure") }
                catch { evidence["durableEvidenceError"] = String(describing: error) }
                evidence["guestStatusOnFailure"] = String(describing: await services.linuxGuestStatus(id: id))
                evidence["reconciliationOnFailure"] = String(describing:
                    await app.linuxGuestLifecycle.reconciliationSnapshot(environmentID: id))
            }
            do { try retain("failed-before-cleanup") }
            catch {
                // Export failure must not permit deletion of recoverable data.
                Issue.record("Soft restart failure evidence export failed; retain own workspace: \(root.path); \(error)")
                throw error
            }
            do { try await cleanupSettledOwnEnvironment() }
            catch {
                evidence["cleanupPreservedReason"] = String(describing: error)
                Issue.record("Soft restart outcome/cleanup is unresolved; retain only own workspace and disk: \(root.path)")
            }
            do { try retain("failed") }
            catch { Issue.record("Final soft restart evidence update failed: \(error)") }
            throw error // Unsupported, boot, stage and cleanup failures remain failures.
        }
    }


    private struct Progress: Decodable {
        var state: String
        var previewURL: String?
    }

    private func ownedEnvironment(root: URL, app: AppEnvironment) async throws -> String? {
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        let owner = FloeDigest.sha256Hex(Data(canonical.path.utf8))
        let matches = await app.environmentRegistry.containersOwned(by: owner)
            .filter { $0.kind == .project && $0.state != .deleting }
        guard matches.count <= 1 else {
            throw FloeError.validationFailed("Qualification workspace has multiple project environments; none was selected")
        }
        return matches.first?.id
    }

    private func waitForTerminal(_ jobs: BackgroundJobService, id: UUID, seconds: TimeInterval = 90) async throws -> BackgroundJob {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let job = try await jobs.job(id: id), job.state.isTerminal { return job }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw FloeError.validationFailed("Own service did not acknowledge exit; preserve its environment and workspace")
    }

    private func waitForPreview(_ jobs: BackgroundJobService, id: UUID) async throws -> URL {
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            guard let job = try await jobs.job(id: id) else { throw FloeError.notFound("Qualification job disappeared") }
            if job.state.isTerminal {
                throw FloeError.validationFailed("Static service ended before readiness: \(job.lastError ?? job.state.rawValue)")
            }
            if let data = job.progressJSON,
               let progress = try? JSONDecoder().decode(Progress.self, from: data),
               progress.state == "running", let value = progress.previewURL, let url = URL(string: value) {
                return url
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw FloeError.validationFailed("Static HTML readiness deadline exceeded; inspect the one existing job, do not resubmit")
    }

    private func fetch(_ url: URL, session: URLSession) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 3)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FloeError.validationFailed("Preview did not return HTTP") }
        return (data, http)
    }

    // Separate opt-in from offline/service qualification: public network is
    // not a prerequisite for those already-proven lifecycle tests. This uses
    // controlled public PyPI, never copies an account's configured index.
    @Test("real guest diagnoses public package network stages and imports an installed Office package set",
          .enabled(if: ProcessInfo.processInfo.environment["FLOE_REALVM_NETWORK_PIP_QUALIFICATION"] == "1"))
    func networkOfficePipStagedDiagnosis() async throws {
        let app = try await appQualificationEnvironment()
        let jobs = try #require(app.backgroundJobService)
        let services = FloePlatformServices.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("network-pip-real-vm-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let conversationID = UUID(), runID = UUID()
        var environmentID: String?
        var jobIDs: [UUID] = []
        var recordsCreated = false
        var evidence = ["kind": "real-network-pip-stages-not-model-not-ui",
                        "root": root.path, "index": "https://pypi.org/simple",
                        "versions": "python-pptx==1.0.2 openpyxl==3.1.5 python-docx==1.2.0",
                        "limit": "binary wheels only; no source build or implicit retry; not the unknown original index",
                        "budgetPolicy": "python startup 30s; pip cold import 120s; network command 120s including imports, operation DNS12/TLS15/index15s"]
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let evidenceDirectory = support.appendingPathComponent("FloeAgent/QualificationEvidence/NetworkPip", isDirectory: true)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let evidenceURL = evidenceDirectory.appendingPathComponent(conversationID.uuidString + ".json")
        func retain(_ stage: String) throws {
            evidence["stage"] = stage
            evidence["observedAt"] = ISO8601DateFormatter().string(from: Date())
            try JSONEncoder().encode(evidence).write(to: evidenceURL, options: .atomic)
        }
        func stage(_ name: String, command: String, timeout: Int) async throws {
            let id = try #require(environmentID)
            evidence[name + ".effectiveTimeoutRequested"] = String(timeout)
            try retain(name + ".submitting-once")
            let started = Date()
            let job = try await jobs.submit(runID: runID,
                toolCallID: "network-pip-" + name + "-" + UUID().uuidString,
                targetTool: "exec.shell",
                payloadJSON: JSONSerialization.data(withJSONObject: ["command": command, "cwd": ".",
                    "timeout": timeout, "maxOutputBytes": 24_576]),
                scope: .local, workspaceRootURL: root, allowedWorkspacePaths: [],
                environmentID: id, waitForCompletion: false)
            jobIDs.append(job.id)
            evidence[name + ".jobID"] = job.id.uuidString
            try retain(name + ".running")
            let terminal = try await waitForTerminal(jobs, id: job.id, seconds: Double(timeout) + 45)
            evidence[name + ".durationSeconds"] = String(Date().timeIntervalSince(started))
            evidence[name + ".state"] = terminal.state.rawValue
            // Production shell output has already passed its bounded redactor
            // before BackgroundJobService stores this result. No raw env/config.
            evidence[name + ".output"] = terminal.resultSummary ?? terminal.lastError ?? "No output"
            try retain(name + ".terminal")
            try #require(terminal.state == .completed,
                "Network pip stage failed: \(name); retained evidence: \(evidenceURL.path)")
            try #require(terminal.resultSummary?.contains("effectiveTimeoutSeconds=\(timeout)") == true,
                "Stage did not report its real effective command limit")
        }
        func cleanup() async throws {
            for id in jobIDs {
                guard let job = try await jobs.job(id: id) else {
                    throw FloeError.validationFailed("Network qualification job missing; preserve owned guest until reconciled")
                }
                if !job.state.isTerminal { _ = try await jobs.cancel(id: id) }
                _ = try await waitForTerminal(jobs, id: id)
            }
            let ownID: String?
            if let id = environmentID { ownID = id }
            else { ownID = try await ownedEnvironment(root: root, app: app) }
            if let id = ownID {
                try await services.stopEnvironment(id: id)
                guard let status = await services.linuxGuestStatus(id: id), !status.running else {
                    throw FloeError.validationFailed("Network qualification guest stop unconfirmed; preserve owned layer")
                }
                try await services.deleteEnvironment(id: id)
            }
            if recordsCreated { try await app.conversationStore.deleteConversation(id: conversationID) }
            let center = UNUserNotificationCenter.current()
            let notificationIDs = jobIDs.map { "jobs." + $0.uuidString }
            center.removePendingNotificationRequests(withIdentifiers: notificationIDs)
            center.removeDeliveredNotifications(withIdentifiers: notificationIDs)
            try FileManager.default.removeItem(at: root)
        }
        do {
            let date = Date()
            try await app.conversationStore.saveConversation(ConversationRecord(id: conversationID,
                title: "Network package qualification", createdAt: date, updatedAt: date, titleOrigin: .manual))
            recordsCreated = true
            try await app.database.writer { database in
                try database.execute(sql: "INSERT INTO runs (id, conversation_id, state, goal, started_at) VALUES (?, ?, 'running', 'Synthetic network package diagnosis', ?)",
                    arguments: [runID.uuidString, conversationID.uuidString, ISO8601DateFormatter().string(from: date)])
            }
            try retain("preparing-own-guest")
            try await services.prepareWorkspaceEnvironment(root: root)
            environmentID = try await ownedEnvironment(root: root, app: app)
            let id = try #require(environmentID)
            evidence["environmentID"] = id
            try await services.activateLinuxGuestWithPreparation(id: id, cancellation: CancellationToken())
            try await stage("python-startup", command: #"""
            set -e
            mkdir -p /workspace/qualification/home /workspace/qualification/wheels /workspace/qualification/site
            python3 -u -c 'import sys,platform,ssl;print("PYTHON",sys.version);print("ARCH",platform.machine());print("TLS",ssl.OPENSSL_VERSION)'
            """#, timeout: 30)
            // The first actual run printed Python/architecture/OpenSSL, then
            // hit the old shared 30s deadline while pip imported platformdirs.
            // Isolate that CPU/import work: no network, retry or install here.
            try await stage("pip-startup", command: #"""
            env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/workspace/qualification/home PIP_CONFIG_FILE=/dev/null python3 -u - <<'PY'
            import sys,time
            start=time.monotonic()
            print('PIP_STARTUP_BEGIN',flush=True)
            import runpy
            sys.argv=['pip','--isolated','--disable-pip-version-check','--version']
            try:
                runpy.run_module('pip',run_name='__main__')
            finally:
                print('PIP_STARTUP_ELAPSED_SECONDS',round(time.monotonic()-start,3),flush=True)
            PY
            """#, timeout: 120)
            // Each Python network probe has the existing normal 120s command
            // budget for cold imports plus bounded operations. IMPORT_READY
            // precedes all DNS/transport work, whose own deadlines are separate.
            try await stage("dns", command: #"""
            python3 -u - <<'PY'
            import time
            startup=time.monotonic()
            print('DNS_PYTHON_START',flush=True)
            import socket,signal
            print('DNS_IMPORT_READY','startupSeconds',round(time.monotonic()-startup,3),flush=True)
            def deadline(signum,frame):
                raise TimeoutError('DNS_LOOKUP_DEADLINE_12_SECONDS')
            signal.signal(signal.SIGALRM,deadline)
            for host in ('pypi.org','files.pythonhosted.org'):
                start=time.monotonic()
                print('DNS_LOOKUP_BEGIN',host,'operationBudgetSeconds',12,flush=True)
                signal.alarm(12)
                try:
                    addresses=socket.getaddrinfo(host,443,type=socket.SOCK_STREAM)
                    assert addresses,'DNS returned no addresses'
                    print('DNS_OK',host,'addressCount',len(addresses),'seconds',round(time.monotonic()-start,3),flush=True)
                finally:
                    signal.alarm(0)
            PY
            """#, timeout: 120)
            try await stage("tls", command: #"""
            python3 -u - <<'PY'
            import time
            startup=time.monotonic()
            print('TLS_PYTHON_START',flush=True)
            import socket,ssl,signal
            context=ssl.create_default_context()
            print('TLS_IMPORT_AND_CA_READY','startupSeconds',round(time.monotonic()-startup,3),flush=True)
            def deadline(signum,frame):
                raise TimeoutError('TLS_OPERATION_DEADLINE_15_SECONDS')
            signal.signal(signal.SIGALRM,deadline)
            for host in ('pypi.org','files.pythonhosted.org'):
                start=time.monotonic()
                print('TLS_OPERATION_BEGIN',host,'operationBudgetSeconds',15,'socketTimeoutSeconds',10,flush=True)
                signal.alarm(15)
                try:
                    with socket.create_connection((host,443),timeout=10) as raw:
                        with context.wrap_socket(raw,server_hostname=host) as connection:
                            print('TLS_VERIFIED',host,connection.version(),'seconds',round(time.monotonic()-start,3),flush=True)
                finally:
                    signal.alarm(0)
            PY
            """#, timeout: 120)
            try await stage("index", command: #"""
            python3 -u - <<'PY'
            import time
            startup=time.monotonic()
            print('INDEX_PYTHON_START',flush=True)
            import urllib.request,signal
            opener=urllib.request.build_opener(urllib.request.ProxyHandler({}))
            print('INDEX_IMPORT_READY','startupSeconds',round(time.monotonic()-startup,3),flush=True)
            def deadline(signum,frame):
                raise TimeoutError('INDEX_OPERATION_DEADLINE_15_SECONDS')
            signal.signal(signal.SIGALRM,deadline)
            for package in ('python-pptx','openpyxl','python-docx'):
                start=time.monotonic()
                print('INDEX_REQUEST_BEGIN',package,'operationBudgetSeconds',15,'socketTimeoutSeconds',12,flush=True)
                request=urllib.request.Request('https://pypi.org/simple/'+package+'/',headers={'Accept':'application/vnd.pypi.simple.v1+html'})
                signal.alarm(15)
                try:
                    with opener.open(request,timeout=12) as response:
                        prefix=response.read(8192)
                        assert response.status==200 and b'href=' in prefix,'Unexpected index response'
                        print('INDEX_OK',package,'status',response.status,'sampleBytes',len(prefix),'seconds',round(time.monotonic()-start,3),flush=True)
                finally:
                    signal.alarm(0)
            PY
            """#, timeout: 120)
            // Clear inherited index/proxy settings without reading or printing
            // them. --only-binary prohibits a lengthy riscv64 lxml source build.
            let pip = "env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/workspace/qualification/home PIP_CONFIG_FILE=/dev/null python3 -u -m pip --isolated --disable-pip-version-check --no-input --no-cache-dir"
            let pins = "python-pptx==1.0.2 openpyxl==3.1.5 python-docx==1.2.0"
            try await stage("direct-wheel-download", command: pip + " download --index-url https://pypi.org/simple --retries 0 --timeout 15 --progress-bar off --only-binary=:all: --no-deps --dest /workspace/qualification/wheels " + pins, timeout: 180)
            // This stage may honestly fail with a missing compatible dependency
            // wheel. Do not retry, compile a replacement, or call that a network
            // timeout. Its real pip error is preserved in the stage receipt.
            try await stage("dependency-wheel-download", command: pip + " download --index-url https://pypi.org/simple --retries 0 --timeout 15 --progress-bar off --only-binary=:all: --find-links /workspace/qualification/wheels --dest /workspace/qualification/wheels " + pins, timeout: 300)
            try await stage("install", command: pip + " install --no-index --only-binary=:all: --find-links /workspace/qualification/wheels --target /workspace/qualification/site " + pins, timeout: 180)
            // Separate process: installation success alone does not prove usable
            // modules or that the requested versions resolve from our target.
            try await stage("independent-import", command: #"""
            python3 -u - <<'PY'
            import sys,pathlib,importlib,importlib.metadata,hashlib
            target=pathlib.Path('/workspace/qualification/site').resolve()
            sys.path.insert(0,str(target))
            for module,distribution,version in (('pptx','python-pptx','1.0.2'),('openpyxl','openpyxl','3.1.5'),('docx','python-docx','1.2.0')):
                imported=importlib.import_module(module)
                path=pathlib.Path(imported.__file__).resolve()
                assert target in path.parents,'Import resolved outside own install target'
                actual=importlib.metadata.version(distribution)
                assert actual==version,(distribution,actual,version)
                print('IMPORT_VERIFIED',distribution,actual,'sha256',hashlib.sha256(path.read_bytes()).hexdigest(),flush=True)
            for path in sorted(pathlib.Path('/workspace/qualification/wheels').glob('*.whl')):
                print('WHEEL_SHA256',path.name,hashlib.sha256(path.read_bytes()).hexdigest(),flush=True)
            PY
            """#, timeout: 60)
            try retain("all-stages-verified")
            try await cleanup()
            evidence["cleanup"] = "own jobs terminal; own guest stopped/deleted; synthetic conversation/root removed"
            try retain("completed-and-cleaned")
            print("FLOE_NETWORK_PIP_EVIDENCE=" + evidenceURL.path)
        } catch {
            evidence["failure"] = String(describing: error)
            try? retain("failed-preserved")
            do { try await cleanup(); evidence["cleanup"] = "completed" }
            catch { evidence["cleanupFailure"] = String(describing: error); Issue.record("Own network pip cleanup incomplete; preserve workspace: \(root.path)") }
            try? retain("failed-cleanup-recorded")
            print("FLOE_NETWORK_PIP_FAILURE_EVIDENCE=" + evidenceURL.path)
            throw error
        }
    }

    private actor SharedVenvTerminalEvidence {
        private var deliveries: [UUID: (UUID, UUID, String)] = [:]
        func record(_ job: BackgroundJob) {
            deliveries[job.id] = (job.conversationID, job.runID, job.state.rawValue)
        }
        func matches(jobID: UUID, conversationID: UUID, runID: UUID, state: String) -> Bool {
            guard let value = deliveries[jobID] else { return false }
            return value.0 == conversationID && value.1 == runID && value.2 == state
        }
    }

    // This is separate from the unchanged strict PyPI wheel-set probe above.
    // Native-service QA owns real jobs and their terminal evidence; it never
    // invokes ConversationCenter's model-continuation callback.
    @Test("real guest installs distro extensions and fixed Office packages into its own shared venv",
          .enabled(if: ProcessInfo.processInfo.environment["FLOE_REALVM_SHARED_VENV_OFFICE_QUALIFICATION"] == "1"))
    func sharedVenvOfficeDistroDependenciesRoundtrip() async throws {
        let app = try await appQualificationEnvironment()
        let services = FloePlatformServices.shared
        let terminalEvidence = SharedVenvTerminalEvidence()
        let jobs = BackgroundJobService(store: BackgroundJobStore(database: app.database),
            onTerminal: { job in await terminalEvidence.record(job) })
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("shared-venv-office-real-vm-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let conversationID = UUID(), runID = UUID()
        var environmentID: String?
        var jobIDs: [UUID] = []
        var recordsCreated = false
        var runCreated = false
        let provisioningCancellation = CancellationToken()
        var evidence = ["kind": "real-shared-venv-office-native-service-not-model-not-ui",
                        "root": root.path,
                        "versions": "python-pptx==1.0.2 openpyxl==3.1.5 python-docx==1.2.0",
                        "dependencyStrategy": "signed guest distro Pillow/lxml; normal dependency-resolving pip in production system-site-enabled venv",
                        "terminalDelivery": "production BackgroundJobService with test-owned native-service evidence sink; not App model continuation",
                        "budgetPolicy": "exec.shell foreground unchanged; distinct background jobs at reported limits up to 600s; no implicit retry"]
        let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                  appropriateFor: nil, create: true)
        let evidenceDirectory = support.appendingPathComponent("FloeAgent/QualificationEvidence/SharedVenvOffice")
            .appendingPathComponent(conversationID.uuidString)
        try FileManager.default.createDirectory(at: evidenceDirectory, withIntermediateDirectories: true)
        let evidenceURL = evidenceDirectory.appendingPathComponent("qualification.json")
        func retain(_ stage: String) throws {
            evidence["stage"] = stage
            evidence["observedAt"] = ISO8601DateFormatter().string(from: Date())
            try JSONEncoder().encode(evidence).write(to: evidenceURL, options: .atomic)
        }
        func retainArtifacts(requireAll: Bool) throws {
            let retained = evidenceDirectory.appendingPathComponent("artifacts")
            try FileManager.default.createDirectory(at: retained, withIntermediateDirectories: true)
            for name in ["real.docx", "real.xlsx", "real.pptx", "dependency.png"] {
                let source = root.appendingPathComponent("qualification/artifacts/" + name)
                guard FileManager.default.fileExists(atPath: source.path) else {
                    if requireAll { throw FloeError.notFound("Missing qualification artifact: " + name) }
                    continue
                }
                let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
                guard values.isRegularFile == true, values.isSymbolicLink != true,
                      let size = values.fileSize, size > 0, size <= 16 * 1024 * 1024 else {
                    throw FloeError.validationFailed("Qualification artifact is not a bounded regular file: " + name)
                }
                let bytes = try Data(contentsOf: source)
                evidence["artifact." + name + ".sha256"] = FloeDigest.sha256Hex(bytes)
                evidence["artifact." + name + ".bytes"] = String(bytes.count)
                try bytes.write(to: retained.appendingPathComponent(name), options: .atomic)
            }
        }
        func assertNoModelTurn() async throws {
            let runs = try await app.runStore.runs(conversationID: conversationID)
            let messages = try await app.conversationStore.messages(conversationID: conversationID)
            try #require(runs.count == 1 && runs.first?.id == runID,
                         "Tool-only qualification unexpectedly created another run")
            try #require(messages.isEmpty, "Tool-only qualification unexpectedly generated chat messages")
        }
        func reportsEffectiveTimeout(_ result: String, timeout: Int) -> Bool {
            let header = result.components(separatedBy: "\n--- stdout ---\n").first ?? result
            let fields = header.split(whereSeparator: { $0.isWhitespace })
                .filter { $0.hasPrefix("effectiveTimeoutSeconds=") }
            return fields.count == 1 && fields[0] == "effectiveTimeoutSeconds=\(Double(timeout))"
        }
        @discardableResult
        func stage(_ name: String, command: String, timeout: Int) async throws -> String {
            try Task.checkCancellation()
            let id = try #require(environmentID)
            evidence[name + ".effectiveTimeoutRequested"] = String(timeout)
            try retain(name + ".submitting-once")
            let started = Date()
            let job = try await jobs.submit(runID: runID,
                toolCallID: "shared-venv-office-" + name + "-" + UUID().uuidString,
                targetTool: "exec.shell",
                payloadJSON: JSONSerialization.data(withJSONObject: ["command": command, "cwd": ".",
                    "timeout": timeout, "maxOutputBytes": 24_576]),
                scope: .local, workspaceRootURL: root, allowedWorkspacePaths: [],
                environmentID: id, allowedToolNames: ["exec.shell"],
                submissionSource: .nativeService, waitForCompletion: false)
            jobIDs.append(job.id)
            try #require(job.runID == runID && job.conversationID == conversationID && job.environmentID == id)
            evidence[name + ".jobID"] = job.id.uuidString
            try retain(name + ".running")
            let terminal = try await waitForTerminal(jobs, id: job.id, seconds: Double(timeout) + 45)
            let result = terminal.resultSummary ?? terminal.lastError ?? "No output"
            evidence[name + ".durationSeconds"] = String(Date().timeIntervalSince(started))
            evidence[name + ".state"] = terminal.state.rawValue
            // Registered production shell runner already bounded/redacted this.
            evidence[name + ".output"] = result
            try retain(name + ".terminal")
            let notificationDeadline = Date().addingTimeInterval(5)
            while !(await terminalEvidence.matches(jobID: job.id, conversationID: conversationID,
                                                    runID: runID, state: terminal.state.rawValue)),
                  Date() < notificationDeadline {
                try await Task.sleep(for: .milliseconds(50))
            }
            try #require(await terminalEvidence.matches(jobID: job.id, conversationID: conversationID,
                                                        runID: runID, state: terminal.state.rawValue),
                         "Owned native-service terminal callback was not observed")
            try await assertNoModelTurn()
            try #require(terminal.state == .completed,
                         "Shared venv Office stage failed: \(name); evidence: \(evidenceURL.path)")
            try #require(reportsEffectiveTimeout(result, timeout: timeout),
                         "Stage \(name) did not report the actual effective command limit \(Double(timeout)); evidence: \(evidenceURL.path)")
            return result
        }
        func cleanup() async throws {
            provisioningCancellation.cancel()
            for id in jobIDs {
                guard let job = try await jobs.job(id: id) else {
                    throw FloeError.validationFailed("Owned shared venv job missing; preserve its workspace/layer")
                }
                if !job.state.isTerminal { _ = try await jobs.cancel(id: id) }
                _ = try await waitForTerminal(jobs, id: id)
            }
            let ownID = try await ownedEnvironment(root: root, app: app)
            if let expected = environmentID {
                try #require(expected == ownID, "Qualification ownership changed or disappeared; preserve its layer and workspace")
            }
            if let id = ownID {
                try await services.stopEnvironment(id: id)
                guard let status = await services.linuxGuestStatus(id: id), !status.running else {
                    throw FloeError.validationFailed("Owned shared venv guest stop unconfirmed; preserve its layer")
                }
                try await services.deleteEnvironment(id: id)
            }
            if recordsCreated {
                if runCreated { try await assertNoModelTurn() }
                try await app.conversationStore.deleteConversation(id: conversationID)
            }
            try FileManager.default.removeItem(at: root)
        }
        do {
            let now = Date()
            try await app.conversationStore.saveConversation(ConversationRecord(id: conversationID,
                title: "Shared venv Office tool qualification", createdAt: now, updatedAt: now, titleOrigin: .manual))
            recordsCreated = true
            try await app.database.writer { database in
                try database.execute(sql: "INSERT INTO runs (id, conversation_id, state, goal, started_at) VALUES (?, ?, 'running', 'Native-service Office package qualification; no model', ?)",
                    arguments: [runID.uuidString, conversationID.uuidString, ISO8601DateFormatter().string(from: now)])
            }
            runCreated = true
            try retain("preparing-own-project-guest")
            try await services.prepareWorkspaceEnvironment(root: root)
            let id = try #require(try await ownedEnvironment(root: root, app: app))
            environmentID = id
            let record = try #require(await app.environmentRegistry.record(id: id))
            let expectedOwner = FloeDigest.sha256Hex(Data(root.resolvingSymlinksInPath().standardizedFileURL.path.utf8))
            try #require(record.kind == .project && record.ownerID == expectedOwner,
                         "Qualification must own a project layer, never shared/base/user layers")
            let layer = try #require(await app.environmentRegistry.layerURL(for: id))
            try #require(layer.lastPathComponent == id)
            evidence["environmentID"] = id
            evidence["ownedLayer"] = layer.path
            try await services.activateLinuxGuestWithPreparation(id: id, cancellation: provisioningCancellation)
            try await stage("guest-identity", command: #"""
            set -e
            mkdir -p /workspace/qualification/home /workspace/qualification/artifacts
            cat /etc/os-release
            printf 'DPKG_ARCH '; dpkg --print-architecture
            python3 -u - <<'PY'
            import platform,sys
            print('PYTHON',sys.version)
            print('ARCH',platform.machine())
            release=platform.freedesktop_os_release()
            assert release.get('ID')=='debian' and release.get('VERSION_ID')=='13',release
            assert platform.machine()=='riscv64'
            assert sys.version_info[:2]==(3,13)
            PY
            test "$(dpkg --print-architecture)" = riscv64
            """#, timeout: 120)
            let aptProbe = #"""
            set -e
            python3 -u - <<'PY'
            import subprocess
            missing=[]
            for package in ('python3-pil','python3-lxml'):
                result=subprocess.run(['apt-cache','policy',package],text=True,capture_output=True)
                print('APT_POLICY',package,'exit',result.returncode,flush=True)
                print(result.stdout,flush=True)
                if result.stderr: print(result.stderr,flush=True)
                assert result.returncode==0,'apt-cache failed'
                candidate=next((line.split(':',1)[1].strip() for line in result.stdout.splitlines() if line.strip().startswith('Candidate:')),None)
                if not candidate or candidate=='(none)': missing.append(package)
                else: print('APT_CANDIDATE',package,candidate,flush=True)
            print('APT_NEEDS_INDEX_UPDATE' if missing else 'APT_CANDIDATES_READY',*missing,flush=True)
            PY
            """#
            let policy = try await stage("apt-policy-before", command: aptProbe, timeout: 120)
            if policy.contains("APT_NEEDS_INDEX_UPDATE") {
                try await stage("apt-index-update-once", command:
                    "apt-get -o APT::Get::AllowUnauthenticated=false -o Acquire::AllowInsecureRepositories=false -o Acquire::AllowDowngradeToInsecureRepositories=false -o Acquire::Retries=0 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 update", timeout: 600)
            }
            let verifiedPolicy = try await stage("apt-policy-verified", command: aptProbe, timeout: 120)
            try #require(verifiedPolicy.contains("APT_CANDIDATES_READY"),
                         "Signed guest repository has no Pillow/lxml candidate; retain original apt output")
            try await stage("apt-simulate", command:
                "apt-get -s --no-install-recommends install python3-pil python3-lxml", timeout: 120)
            try await stage("apt-install", command:
                "env DEBIAN_FRONTEND=noninteractive apt-get -y --no-install-recommends -o APT::Get::AllowUnauthenticated=false -o Acquire::AllowInsecureRepositories=false -o Acquire::AllowDowngradeToInsecureRepositories=false -o Acquire::Retries=0 -o Acquire::http::Timeout=20 -o Acquire::https::Timeout=20 install python3-pil python3-lxml", timeout: 600)
            // Independently verify dpkg finished configuring the real packages.
            // The install log may be bounded before its last progress line.
            try await stage("apt-installed-verification", command: #"""
            set -e
            python3 -u - <<'PY'
            import subprocess
            audit=subprocess.run(['dpkg','--audit'],text=True,capture_output=True)
            print('DPKG_AUDIT_EXIT',audit.returncode,flush=True)
            if audit.stdout: print(audit.stdout,flush=True)
            if audit.stderr: print(audit.stderr,flush=True)
            assert audit.returncode==0 and not audit.stdout.strip(),'dpkg reports incomplete package configuration'
            check=subprocess.run(['apt-get','check'],text=True,capture_output=True)
            print('APT_DEPENDENCY_CHECK_EXIT',check.returncode,flush=True)
            print(check.stdout,flush=True)
            if check.stderr: print(check.stderr,flush=True)
            assert check.returncode==0,'apt dependency consistency failed'
            for package in ('python3-pil','python3-lxml'):
                result=subprocess.run(['dpkg-query','-W','-f=${db:Status-Status}|${Version}|${Architecture}',package],text=True,capture_output=True)
                print('CONFIGURED_PACKAGE',package,result.returncode,result.stdout.strip(),flush=True)
                if result.stderr: print(result.stderr,flush=True)
                fields=result.stdout.strip().split('|')
                assert result.returncode==0 and len(fields)==3 and fields[0]=='installed' and fields[1] and fields[2]=='riscv64',package
            print('APT_REAL_CONFIGURATION_VERIFIED',flush=True)
            PY
            """#, timeout: 120)
            guard let runner = services.linuxCommandRunner() else {
                throw FloeError.validationFailed("Production Linux command runner is unavailable")
            }
            try retain("production-shared-venv-provisioning")
            let venv = try await LinuxGuestPythonProvisioner.shared.ensure(environmentID: id,
                runner: runner, cancellation: provisioningCancellation)
            try #require(venv.environmentID == id && venv.venvPath == "/floe/env/python/venv")
            evidence["venvPath"] = venv.venvPath
            evidence["venvPythonPath"] = venv.pythonPath
            evidence["venvSitePackages"] = venv.sitePackages
            try #require(venv.pythonPath == venv.venvPath + "/bin/python3"
                         && venv.sitePackages.hasPrefix(venv.venvPath + "/"))
            // RuntimeV2 exports its own environment data directory over 9p,
            // not EnvironmentRegistry's legacy host container layer. Inspect
            // the actual guest mount/config/interpreter, never assume the
            // obsolete host <container>/python/venv mirror exists.
            evidence["venvVerificationContract"] = "owned project environment; actual guest floe-env 9p mount and independent interpreter"
            try await stage("distro-extension-imports", command: #"""
            set -e
            dpkg-query -W -f='${Package} ${Version} ${Architecture} ${db:Status-Status}
            ' python3-pil python3-lxml
            /floe/env/python/venv/bin/python3 -u - <<'PY'
            import sys,pathlib,sysconfig,site,importlib.metadata
            venv=pathlib.Path('/floe/env/python/venv').resolve()
            print('VENV_INTERPRETER',sys.executable,'PREFIX',sys.prefix,'BASE',sys.base_prefix,flush=True)
            assert sys.prefix!=sys.base_prefix
            assert pathlib.Path(sys.prefix).resolve()==venv
            assert pathlib.Path(sysconfig.get_path('purelib')).resolve().is_relative_to(venv)
            configPath=venv/'pyvenv.cfg'
            config=dict(line.split('=',1) for line in configPath.read_text().splitlines() if '=' in line)
            config={key.strip().lower():value.strip().lower() for key,value in config.items()}
            print('VENV_CONFIG',str(configPath),'systemSitePackages',config.get('include-system-site-packages'),flush=True)
            assert config.get('include-system-site-packages')=='true'
            mounts=[]
            for line in pathlib.Path('/proc/self/mountinfo').read_text().splitlines():
                fields=line.split()
                if len(fields)>6 and fields[4]=='/floe/env':
                    separator=fields.index('-')
                    mounts.append((fields[separator+1],fields[separator+2]))
            print('ACTUAL_ENVIRONMENT_MOUNT',mounts,flush=True)
            assert ('9p','floe-env') in mounts,'production venv is not in the actual environment 9p data share'
            systemSite=pathlib.Path('/usr/lib/python3/dist-packages').resolve()
            sitePaths=[pathlib.Path(path).resolve() for path in site.getsitepackages()]
            print('SYSTEM_SITE_VISIBLE',str(systemSite),systemSite in sitePaths,flush=True)
            assert systemSite in sitePaths
            from PIL import _imaging
            from lxml import etree
            for module,distribution in ((_imaging,'Pillow'),(etree,'lxml')):
                modulePath=pathlib.Path(module.__file__).resolve()
                print('DISTRO_EXTENSION',distribution,importlib.metadata.version(distribution),str(modulePath),flush=True)
                assert modulePath.suffix=='.so' and modulePath.is_file() and modulePath.is_relative_to(systemSite)
            assert etree.fromstring(b'<root><value>real-extension</value></root>').findtext('value')=='real-extension'
            print('PRODUCTION_VENV_DISTRO_EXTENSIONS_VERIFIED',flush=True)
            PY
            """#, timeout: 120)
            try await stage("shared-venv-pip-install", command: #"""
            env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/workspace/qualification/home PIP_CONFIG_FILE=/dev/null /floe/env/python/venv/bin/python3 -u -m pip --isolated --disable-pip-version-check --no-input --no-cache-dir install --index-url https://pypi.org/simple --retries 0 --timeout 15 --progress-bar off --only-binary=:all: python-pptx==1.0.2 openpyxl==3.1.5 python-docx==1.2.0
            """#, timeout: 600)
            // Keep the global pip check and its exact result. Debian 13's
            // apt-listchanges 4.8 declares the distro-only debconf module as
            // a Python distribution (Debian #1145641). Classify only that
            // exact diagnostic after independently proving its real owner,
            // import and apt state; every other pip error remains fatal.
            try await stage("shared-venv-pip-check", command: #"""
            /floe/env/python/venv/bin/python3 -u - <<'PY'
            import importlib.metadata as metadata
            import json,os,pathlib,subprocess,sys,tempfile
            from pip._vendor.packaging.requirements import Requirement
            from pip._vendor.packaging.utils import canonicalize_name
            from pip._vendor.packaging.markers import default_environment
            from pip._vendor.packaging.specifiers import SpecifierSet
            prefix=pathlib.Path('/floe/env/python/venv').resolve()
            assert pathlib.Path(sys.prefix).resolve()==prefix and sys.prefix!=sys.base_prefix
            # Verify all active transitive dependencies, including extras if
            # requested by any edge. Missing distributions and mismatched
            # versions fail here independently of global pip's diagnostic.
            pending=[('python-pptx',frozenset(), '==1.0.2'),('openpyxl',frozenset(), '==3.1.5'),('python-docx',frozenset(), '==1.2.0')]
            visited=set()
            while pending:
                name,extras,specifier=pending.pop()
                dist=metadata.distribution(name)
                requirement=Requirement(name+specifier)
                assert requirement.specifier.contains(dist.version,prereleases=True),(name,specifier,dist.version)
                pythonRequirement=dist.metadata.get('Requires-Python')
                if pythonRequirement:
                    assert SpecifierSet(pythonRequirement).contains(default_environment()['python_full_version'],prereleases=True),(name,pythonRequirement,sys.version)
                key=(canonicalize_name(name),extras)
                if key in visited: continue
                visited.add(key)
                print('VERIFIED_DEPENDENCY',name,dist.version,str(dist.locate_file('')),sorted(extras),flush=True)
                for text in dist.requires or ():
                    dependency=Requirement(text)
                    active=dependency.marker is None or any(dependency.marker.evaluate(dict(default_environment(),extra=extra)) for extra in ({''}|set(extras)))
                    if active:
                        assert dependency.url is None,('unverified direct-URL dependency',text)
                        print('REQUIRED_DEPENDENCY',name,text,flush=True)
                        pending.append((dependency.name,frozenset(dependency.extras),str(dependency.specifier)))
            assert {'python-pptx','openpyxl','python-docx','pillow','lxml','typing-extensions','xlsxwriter','et-xmlfile'} <= {name for name,_ in visited}
            print('OFFICE_FULL_DEPENDENCY_CLOSURE_VERIFIED',len(visited),flush=True)
            # Isolated pip ignores PIP_CACHE_DIR and chooses XDG's pip cache.
            # A host-backed 9p UID can fail pip's owner check despite being
            # writable. Probe actual writes without changing ownership/modes.
            from pip._internal.utils.filesystem import check_path_owner
            for cache in (pathlib.Path(os.environ['PIP_CACHE_DIR']),pathlib.Path(os.environ['XDG_CACHE_HOME'])/'pip'):
                cache.mkdir(parents=True,exist_ok=True)
                stat=cache.stat()
                with tempfile.TemporaryFile(dir=cache) as handle:
                    assert handle.write(b'cache-write-probe')==17
                    handle.seek(0);assert handle.read()==b'cache-write-probe'
                print('CACHE_WRITE_VERIFIED',str(cache),'uid',stat.st_uid,'euid',os.geteuid(),'pipOwnerAccepted',check_path_owner(str(cache)),flush=True)
            # No cache is needed for this read-only check. This does not
            # modify installed packages, their metadata or pip's resolver.
            check=subprocess.run([sys.executable,'-u','-m','pip','--isolated','--disable-pip-version-check','--no-cache-dir','check'],text=True,capture_output=True)
            print('GLOBAL_PIP_CHECK_RAW',json.dumps({'exit':check.returncode,'stdout':check.stdout,'stderr':check.stderr},sort_keys=True),flush=True)
            if check.returncode==0:
                assert check.stdout.strip()=='No broken requirements found.' and not check.stderr.strip()
                print('GLOBAL_PIP_CHECK_CLEAN',flush=True)
            else:
                assert check.returncode==1 and check.stdout.strip()=='apt-listchanges 4.8 requires debconf, which is not installed.' and not check.stderr.strip(),'unexpected pip dependency failure'
                systemSite=pathlib.Path('/usr/lib/python3/dist-packages').resolve()
                distro=metadata.distribution('apt-listchanges')
                assert distro.version=='4.8' and pathlib.Path(distro.locate_file('')).resolve()==systemSite
                assert any(Requirement(text).name=='debconf' for text in distro.requires or ())
                import debconf
                module=pathlib.Path(debconf.__file__).resolve()
                assert module==systemSite/'debconf.py' and callable(debconf.Debconf)
                for package in ('apt-listchanges','debconf','python3-debconf'):
                    result=subprocess.run(['dpkg-query','-W','-f=${db:Status-Status}|${Version}',package],text=True,capture_output=True)
                    print('SYSTEM_DEPENDENCY_PACKAGE',package,result.returncode,result.stdout.strip(),flush=True)
                    assert result.returncode==0 and result.stdout.startswith('installed|')
                owner=subprocess.run(['dpkg-query','-S',str(module)],text=True,capture_output=True)
                assert owner.returncode==0 and owner.stdout.strip()=='python3-debconf: '+str(module)
                for argv in (['dpkg','--audit'],['apt-get','check']):
                    result=subprocess.run(argv,text=True,capture_output=True)
                    print('SYSTEM_DEPENDENCY_AUDIT',json.dumps({'argv':argv,'exit':result.returncode,'stdout':result.stdout,'stderr':result.stderr},sort_keys=True),flush=True)
                    assert result.returncode==0
                    if argv[0]=='dpkg': assert not result.stdout.strip()
                print('SYSTEM_METADATA_COMPATIBILITY_DEBIAN_1145641_VERIFIED',str(module),flush=True)
            PY
            """#, timeout: 120)
            try await stage("independent-imports-and-three-format-roundtrip", command: #"""
            /floe/env/python/venv/bin/python3 -u - <<'PY'
            import sys,pathlib,importlib,importlib.metadata,hashlib,json
            from PIL import Image,_imaging
            from lxml import etree
            prefix=pathlib.Path('/floe/env/python/venv').resolve()
            assert pathlib.Path(sys.prefix).resolve()==prefix and sys.prefix!=sys.base_prefix
            for module,distribution,version in (('pptx','python-pptx','1.0.2'),('openpyxl','openpyxl','3.1.5'),('docx','python-docx','1.2.0')):
                imported=importlib.import_module(module)
                actual=importlib.metadata.version(distribution)
                path=pathlib.Path(imported.__file__).resolve()
                assert actual==version,(distribution,actual,version)
                assert prefix in path.parents,(distribution,str(path))
                print('VERIFIED_IMPORT',distribution,actual,str(path),flush=True)
            for module in (_imaging,etree):
                assert pathlib.Path(module.__file__).suffix=='.so'
                print('VERIFIED_NATIVE_EXTENSION',module.__file__,flush=True)
            target=pathlib.Path('/workspace/qualification/artifacts');target.mkdir(parents=True,exist_ok=True)
            image=target/'dependency.png';Image.new('RGB',(3,2),(12,34,56)).save(image)
            with Image.open(image) as reopened:
                assert reopened.size==(3,2) and reopened.getpixel((0,0))==(12,34,56)
            from docx import Document
            word=Document();word.add_paragraph('SHARED-VENV-DOCX-中文');word.save(target/'real.docx')
            word2=Document(target/'real.docx');assert any(p.text=='SHARED-VENV-DOCX-中文' for p in word2.paragraphs)
            from openpyxl import Workbook,load_workbook
            book=Workbook();sheet=book.active;sheet['A1']='SHARED-VENV-XLSX';sheet['B1']=17;sheet['B2']=25;sheet['B3']='=SUM(B1:B2)';book.save(target/'real.xlsx')
            book2=load_workbook(target/'real.xlsx',data_only=False)
            assert book2.active['A1'].value=='SHARED-VENV-XLSX' and book2.active['B1'].value==17 and book2.active['B2'].value==25
            assert book2.active['B3'].value=='=SUM(B1:B2)'  # formula persistence, not an Excel recalc claim
            from pptx import Presentation
            deck=Presentation();slide=deck.slides.add_slide(deck.slide_layouts[6]);box=slide.shapes.add_textbox(0,0,2000000,500000)
            box.text_frame.text='SHARED-VENV-PPTX-中文';slide.shapes.add_picture(str(image),0,600000);deck.save(target/'real.pptx')
            deck2=Presentation(target/'real.pptx')
            assert len(deck2.slides)==1
            assert any(shape.has_text_frame and shape.text_frame.text=='SHARED-VENV-PPTX-中文' for shape in deck2.slides[0].shapes)
            assert any(shape.shape_type==13 for shape in deck2.slides[0].shapes),'picture missing on reopen'
            assert etree.fromstring(b'<real>parsed</real>').text=='parsed'
            for name in ('real.docx','real.xlsx','real.pptx','dependency.png'):
                path=target/name;data=path.read_bytes();assert data
                print('ROUNDTRIP_FILE',json.dumps({'name':name,'bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()},sort_keys=True),flush=True)
            print('SHARED_VENV_OFFICE_ROUNDTRIP_VERIFIED',flush=True)
            PY
            """#, timeout: 180)
            try retainArtifacts(requireAll: true)
            try await assertNoModelTurn()
            try retain("actual-install-imports-roundtrip-verified")
            try await cleanup()
            evidence["cleanup"] = "owned jobs terminal; own project guest stopped/deleted; synthetic records/workspace removed; artifacts retained"
            try retain("completed-and-cleaned")
            print("FLOE_SHARED_VENV_OFFICE_EVIDENCE=" + evidenceURL.path)
        } catch {
            evidence["failure"] = String(describing: error)
            do { try retainArtifacts(requireAll: false) }
            catch { evidence["artifactRetentionFailure"] = String(describing: error) }
            try? retain("failed-preserved")
            do { try await cleanup(); evidence["cleanup"] = "completed" }
            catch { evidence["cleanupFailure"] = String(describing: error); Issue.record("Shared venv qualification cleanup incomplete; preserve owned workspace: \(root.path)") }
            try? retain("failed-cleanup-recorded")
            print("FLOE_SHARED_VENV_OFFICE_FAILURE_EVIDENCE=" + evidenceURL.path)
            throw error
        }
    }

    @Test("offline tiny wheel installs through the real job and timed-out shell preserves output after child cleanup",
          .enabled(if: ProcessInfo.processInfo.environment["FLOE_REALVM_QUALIFICATION"] == "1"))
    func offlinePipAndTimeoutOutputLifecycle() async throws {
        let app = AppEnvironment.live()
        await app.bootstrap()
        try #require(app.persistenceReady)
        let jobs = try #require(app.backgroundJobService)
        let services = FloePlatformServices.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("pip-real-vm-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let conversationID = UUID(), runID = UUID()
        var environmentID: String?, jobID: UUID?
        var recordsCreated = false
        var evidence = ["kind": "real-offline-pip-and-timeout-not-model-not-ui", "root": root.path]

        func runShell(_ command: String, timeout: Double) async throws -> ToolExecutionOutput {
            let id = try #require(environmentID)
            let context = ToolContext(runID: runID, toolCallID: "pip-qualification-" + UUID().uuidString,
                allowedToolNames: ["exec.shell"], workspaceRootURL: root, cancellation: CancellationToken(),
                environmentID: id, conversationID: conversationID)
            let lease = try await ToolEnvironmentRouting.shared.acquire(context)
            do {
                let tool = LocalShellTool(shell: app.localShellService)
                let args = LocalShellTool.Arguments(command: command, cwd: ".", timeout: timeout, maxOutputBytes: 16_384)
                try tool.validate(args)
                let output = try await tool.execute(args, context: lease.context)
                await lease.finish()
                return output
            } catch { await lease.finish(); throw error }
        }
        func cleanup() async throws {
            if let id = jobID, let job = try await jobs.job(id: id), !job.state.isTerminal {
                _ = try await jobs.cancel(id: id)
                _ = try await waitForTerminal(jobs, id: id)
            }
            if let id = environmentID {
                try await services.stopEnvironment(id: id)
                guard let status = await services.linuxGuestStatus(id: id), !status.running else {
                    throw FloeError.validationFailed("Pip qualification guest stop not confirmed; preserve owned layer")
                }
                try await services.deleteEnvironment(id: id)
            }
            if recordsCreated { try await app.conversationStore.deleteConversation(id: conversationID) }
            if let id = jobID {
                let center = UNUserNotificationCenter.current()
                center.removePendingNotificationRequests(withIdentifiers: ["jobs." + id.uuidString])
                center.removeDeliveredNotifications(withIdentifiers: ["jobs." + id.uuidString])
            }
            try FileManager.default.removeItem(at: root)
        }
        do {
            let date = Date()
            try await app.conversationStore.saveConversation(ConversationRecord(id: conversationID,
                title: "Offline pip qualification", createdAt: date, updatedAt: date, titleOrigin: .manual))
            recordsCreated = true
            try await app.database.writer { database in
                try database.execute(sql: "INSERT INTO runs (id, conversation_id, state, goal, started_at) VALUES (?, ?, 'running', 'Synthetic offline pip qualification', ?)",
                    arguments: [runID.uuidString, conversationID.uuidString, ISO8601DateFormatter().string(from: date)])
            }
            try await services.prepareWorkspaceEnvironment(root: root)
            environmentID = try await ownedEnvironment(root: root, app: app)
            let id = try #require(environmentID)
            evidence["environmentID"] = id
            try await services.activateLinuxGuestWithPreparation(id: id, cancellation: CancellationToken())
            // No network, package source lookup, venv bootstrap or download.
            let fixtureCommand = #"""
            set -e
            python3 -m pip --version
            python3 - <<'PY'
            import base64,hashlib,zipfile
            files={
              'floe_install_probe/__init__.py':b'VALUE = "FLOE_PIP_QUALIFICATION_OK"\n',
              'floe_install_probe-0.0.1.dist-info/METADATA':b'Metadata-Version: 2.1\nName: floe-install-probe\nVersion: 0.0.1\n',
              'floe_install_probe-0.0.1.dist-info/WHEEL':b'Wheel-Version: 1.0\nGenerator: FloeSyntheticQualification\nRoot-Is-Purelib: true\nTag: py3-none-any\n'
            }
            records=[]
            for path,data in files.items():
                digest=base64.urlsafe_b64encode(hashlib.sha256(data).digest()).rstrip(b'=').decode()
                records.append(f'{path},sha256={digest},{len(data)}\n')
            record='floe_install_probe-0.0.1.dist-info/RECORD'
            files[record]=(''.join(records)+record+',,\n').encode()
            with zipfile.ZipFile('floe_install_probe-0.0.1-py3-none-any.whl','w') as z:
                for path,data in files.items():z.writestr(path,data)
            print('OFFLINE_WHEEL_READY')
            PY
            """#
            let prepared = try await runShell(fixtureCommand, timeout: 120)
            evidence["preflight"] = prepared.summary
            try #require(prepared.exitStatus == 0 && prepared.summary.contains("OFFLINE_WHEEL_READY"), "Real pip prerequisite/fixture failed")
            let wheel = root.appendingPathComponent("floe_install_probe-0.0.1-py3-none-any.whl")
            let wheelBytes = try Data(contentsOf: wheel)
            try #require(wheelBytes.count < 10_240)
            evidence["wheelSHA256"] = FloeDigest.sha256Hex(wheelBytes)
            let install = #"""
            set -e
            python3 -m pip install --no-index --no-deps --disable-pip-version-check --target /workspace/qualification/site /workspace/floe_install_probe-0.0.1-py3-none-any.whl
            python3 -c 'import sys,importlib.metadata;sys.path.insert(0,"/workspace/qualification/site");import floe_install_probe;assert floe_install_probe.VALUE=="FLOE_PIP_QUALIFICATION_OK";assert importlib.metadata.version("floe-install-probe")=="0.0.1";print("OFFLINE_PIP_IMPORT_OK",floe_install_probe.__file__)'
            """#
            let job = try await jobs.submit(runID: runID, toolCallID: "pip-install-once-" + UUID().uuidString,
                targetTool: "exec.shell", payloadJSON: JSONSerialization.data(withJSONObject: ["command": install, "timeout": 180, "maxOutputBytes": 16_384]),
                scope: .local, workspaceRootURL: root, allowedWorkspacePaths: [], environmentID: id, waitForCompletion: false)
            jobID = job.id; evidence["jobID"] = job.id.uuidString
            let finished = try await waitForTerminal(jobs, id: job.id, seconds: 210)
            evidence["installResult"] = finished.resultSummary ?? finished.lastError ?? finished.state.rawValue
            try #require(finished.state == .completed, "Offline pip job failed: \(evidence["installResult"] ?? "unknown")")
            try #require(finished.resultSummary?.contains("OFFLINE_PIP_IMPORT_OK") == true)
            try #require(finished.resultSummary?.contains("effectiveTimeoutSeconds=180") == true)
            let installed = root.appendingPathComponent("qualification/site/floe_install_probe/__init__.py")
            evidence["installedSHA256"] = FloeDigest.sha256Hex(try Data(contentsOf: installed))
            let reopened = try await runShell("PYTHONPATH=/workspace/qualification/site python3 -c 'import floe_install_probe;assert floe_install_probe.VALUE==\"FLOE_PIP_QUALIFICATION_OK\";print(\"REOPEN_IMPORT_OK\")'", timeout: 30)
            try #require(reopened.exitStatus == 0 && reopened.summary.contains("REOPEN_IMPORT_OK"))
            let timeoutCommand = #"""
            python3 -u - <<'PY'
            import pathlib,subprocess,sys,time
            child=subprocess.Popen([sys.executable,'-c','import pathlib,time;time.sleep(8);pathlib.Path("/workspace/child-late").write_text("UNEXPECTED_LATE_CHILD")'])
            pathlib.Path('/workspace/child.pid').write_text(str(child.pid))
            print('TIMEOUT_PROGRESS_MARKER',flush=True)
            print('TIMEOUT_STDERR_MARKER',file=sys.stderr,flush=True)
            time.sleep(20)
            PY
            """#
            let timed = try await runShell(timeoutCommand, timeout: 5)
            evidence["timeoutResult"] = timed.summary
            try #require(timed.exitStatus == 124 && timed.summary.contains("status=timedOut"))
            try #require(timed.summary.contains("effectiveTimeoutSeconds=5"))
            try #require(timed.summary.contains("TIMEOUT_PROGRESS_MARKER") && timed.summary.contains("TIMEOUT_STDERR_MARKER"))
            // Outwait the child's intentional late write, then inspect only
            // its recorded PID. No killing/inspection of unrelated processes.
            try await Task.sleep(for: .seconds(9))
            let checked = try await runShell(#"python3 -c 'import pathlib;pid=int(pathlib.Path("/workspace/child.pid").read_text());assert not pathlib.Path("/proc/"+str(pid)).exists(),"owned child still exists";assert not pathlib.Path("/workspace/child-late").exists(),"owned child escaped timeout";print("CHILD_CLEANUP_CONFIRMED")'"#, timeout: 30)
            evidence["childCheck"] = checked.summary
            try #require(checked.exitStatus == 0 && checked.summary.contains("CHILD_CLEANUP_CONFIRMED"))
            if let data = try? JSONEncoder().encode(evidence) { print("FLOE_PIP_REALVM " + String(decoding: data, as: UTF8.self)) }
            try await cleanup()
            print("FLOE_PIP_REALVM_CLEANUP_OK")
        } catch {
            evidence["failure"] = String(describing: error)
            if let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true) {
                let folder = base.appendingPathComponent("FloeAgent/QualificationEvidence/OfflinePip")
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try JSONEncoder().encode(evidence).write(to: folder.appendingPathComponent(conversationID.uuidString + ".json"), options: .atomic)
                } catch { Issue.record("Offline pip failure evidence could not be retained: \(error)") }
            }
            do { try await cleanup() } catch { Issue.record("Offline pip cleanup incomplete; preserve own workspace: \(error)") }
            throw error
        }
    }

    @Test("real guest static service serves nested Unicode HTML and relative CSS, survives observer close, and exits on cancel",
          .enabled(if: ProcessInfo.processInfo.environment["FLOE_REALVM_QUALIFICATION"] == "1"))
    func staticHTMLNestedResourcesLifecycle() async throws {
        let app = AppEnvironment.live()
        await app.bootstrap()
        try #require(app.persistenceReady, "Production persistence bootstrap failed")
        let jobs = try #require(app.backgroundJobService, "Production job service is unavailable")
        let services = FloePlatformServices.shared
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("static-real-vm-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let conversationID = UUID(), runID = UUID()
        var environmentID: String?
        var jobID: UUID?
        var observer: Task<Void, Never>?
        var recordsCreated = false
        var evidence: [String: String] = ["kind": "real-service-not-model-not-ui", "root": root.path]
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 3
        configuration.timeoutIntervalForResource = 5
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        func retainEvidence(_ phase: String) {
            evidence["phase"] = phase
            if let data = try? JSONEncoder().encode(evidence) {
                try? data.write(to: root.appendingPathComponent("qualification-evidence.json"), options: .atomic)
                print("FLOE_STATIC_REALVM " + String(decoding: data, as: UTF8.self))
            }
        }

        func retainFailureEvidence() {
            guard let base = try? FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true) else { return }
            let directory = base.appendingPathComponent("FloeAgent/QualificationEvidence/StaticServices", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                let file = directory.appendingPathComponent(conversationID.uuidString + ".json")
                try JSONEncoder().encode(evidence).write(to: file, options: .atomic)
                print("FLOE_STATIC_REALVM_FAILURE_EVIDENCE=" + file.path)
            } catch { Issue.record("Could not retain synthetic service failure evidence: \(error)") }
        }

        // Async cleanup is explicitly awaited on both paths. No unstructured
        // defer Task can outlive the test and delete a still-mounted share.
        func cleanup() async throws {
            if let poller = observer {
                poller.cancel(); await poller.value; observer = nil
            }
            if let id = jobID {
                guard let job = try await jobs.job(id: id) else {
                    throw FloeError.validationFailed("Own submitted job is missing; preserve its environment until its worker is reconciled")
                }
                if !job.state.isTerminal { _ = try await jobs.cancel(id: id) }
                _ = try await waitForTerminal(jobs, id: id)
            }
            let ownID: String?
            if let id = environmentID { ownID = id }
            else { ownID = try await ownedEnvironment(root: root, app: app) }
            if let id = ownID {
                try await services.stopEnvironment(id: id)
                guard let status = await services.linuxGuestStatus(id: id), !status.running else {
                    throw FloeError.validationFailed("Own guest stop was not confirmed; preserve its layer")
                }
                try await services.deleteEnvironment(id: id)
            }
            if recordsCreated {
                try await app.conversationStore.deleteConversation(id: conversationID)
            }
            if let id = jobID {
                let center = UNUserNotificationCenter.current()
                center.removePendingNotificationRequests(withIdentifiers: ["jobs." + id.uuidString])
                center.removeDeliveredNotifications(withIdentifiers: ["jobs." + id.uuidString])
            }
            try FileManager.default.removeItem(at: root)
        }

        do {
            let date = Date()
            try await app.conversationStore.saveConversation(ConversationRecord(id: conversationID,
                title: "Static service qualification", createdAt: date, updatedAt: date, titleOrigin: .manual))
            recordsCreated = true
            let started = ISO8601DateFormatter().string(from: date)
            try await app.database.writer { database in
                try database.execute(sql: "INSERT INTO runs (id, conversation_id, state, goal, started_at) VALUES (?, ?, 'running', 'Synthetic static service qualification', ?)",
                    arguments: [runID.uuidString, conversationID.uuidString, started])
            }
            let relativeEntry = "嵌套 demo/页面 目录/预览 页面.html"
            let relativeCSS = "资源 子目录/配色 样式.css"
            let html = "<!doctype html><meta charset='utf-8'><link rel='stylesheet' href='\(relativeCSS)'><h1>FLOE_STATIC_REALVM_中文</h1>"
            let css = "h1 { color: rgb(17, 53, 97); } /* FLOE_STATIC_CSS_中文 */"
            let entry = root.appendingPathComponent(relativeEntry)
            let cssFile = entry.deletingLastPathComponent().appendingPathComponent(relativeCSS)
            try FileManager.default.createDirectory(at: cssFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(html.utf8).write(to: entry, options: .atomic)
            try Data(css.utf8).write(to: cssFile, options: .atomic)
            retainEvidence("workspace-ready")

            try await services.prepareWorkspaceEnvironment(root: root)
            environmentID = try await ownedEnvironment(root: root, app: app)
            let id = try #require(environmentID, "No own project environment was prepared")
            evidence["environmentID"] = id
            retainEvidence("activating-own-guest")
            try await services.activateLinuxGuestWithPreparation(id: id, cancellation: CancellationToken())
            try #require(await services.linuxEnvironmentAvailable(id: id), "Own guest did not become usable")

            // One submission only. A port conflict is a recorded test failure,
            // never a reason to secretly resubmit or restart another service.
            let port = Int.random(in: 20_000...45_000)
            let invocation = LocalServiceTool.Arguments(runtime: "static", entry: relativeEntry,
                arguments: [], cwd: "嵌套 demo/页面 目录", port: port)
            let submitted = try await jobs.submit(runID: runID, toolCallID: "static-qualification-" + UUID().uuidString,
                targetTool: "exec.localService", payloadJSON: JSONEncoder().encode(invocation), scope: .local,
                workspaceRootURL: root, allowedWorkspacePaths: [], environmentID: id,
                waitForCompletion: false)
            jobID = submitted.id; evidence["jobID"] = submitted.id.uuidString
            retainEvidence("submitted-once")
            let preview = try await waitForPreview(jobs, id: submitted.id)
            evidence["previewURL"] = preview.absoluteString
            try #require(preview.host == "127.0.0.1" && preview.port == port)
            #expect(preview.lastPathComponent == "预览 页面.html")
            let (htmlData, htmlResponse) = try await fetch(preview, session: session)
            try #require(htmlResponse.statusCode == 200)
            #expect(htmlData == Data(html.utf8))
            let cssReference = try #require(relativeCSS.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed))
            let cssURL = try #require(URL(string: cssReference, relativeTo: preview)?.absoluteURL)
            let (cssData, cssResponse) = try await fetch(cssURL, session: session)
            try #require(cssResponse.statusCode == 200)
            #expect(cssData == Data(css.utf8))
            evidence["htmlSHA256"] = FloeDigest.sha256Hex(htmlData)
            evidence["cssSHA256"] = FloeDigest.sha256Hex(cssData)
            retainEvidence("html-css-verified")

            // A consumer/observer owns polling only, not the service task.
            // This is intentionally not a SwiftUI/view-lifetime UI test.
            observer = Task { @MainActor in
                while !Task.isCancelled {
                    _ = try? await jobs.job(id: submitted.id)
                    do { try await Task.sleep(for: .milliseconds(100)) } catch { break }
                }
            }
            try await Task.sleep(for: .milliseconds(250))
            if let poller = observer { poller.cancel(); await poller.value; observer = nil }
            let (stillData, stillResponse) = try await fetch(preview, session: session)
            #expect(stillResponse.statusCode == 200 && stillData == htmlData)
            #expect(try await jobs.job(id: submitted.id)?.state.isTerminal == false)
            retainEvidence("observer-closed-service-alive")

            _ = try await jobs.cancel(id: submitted.id)
            let terminal = try await waitForTerminal(jobs, id: submitted.id)
            try #require(terminal.state == .cancelled, "Cancellation did not finish honestly: \(terminal.state.rawValue)")
            evidence["terminalState"] = terminal.state.rawValue
            let deadline = Date().addingTimeInterval(15)
            var accessible = true
            repeat {
                do { _ = try await fetch(preview, session: session); accessible = true }
                catch { accessible = false }
                if !accessible { break }
                try await Task.sleep(for: .milliseconds(250))
            } while Date() < deadline
            try #require(!accessible, "Cancelled service still has an accessible endpoint")
            retainEvidence("cancel-exit-endpoint-closed")
            try await cleanup()
            print("FLOE_STATIC_REALVM_CLEANUP_OK conversation=\(conversationID) job=\(submitted.id)")
        } catch {
            evidence["failure"] = String(describing: error)
            // Capture the OWN synthetic worker's guest-side log before cleanup.
            // A blank host 9p tail alone is not proof of no process error.
            if let id = environmentID, let ownJob = jobID, let runner = services.linuxCommandRunner() {
                do {
                    let diagnostic = try await runner.run(environmentID: id,
                        argv: ["/bin/sh", "-c", #"printf 'OWN_SERVICE_LOG\n'; cat "$1"; printf '\nPYTHON_CHECK\n'; python3 -c 'import sys,http.server; print(sys.version)'"#,
                               "static-qualification-diagnostic", "/floe/env/services/" + ownJob.uuidString + ".log"],
                        workingDirectory: "/workspace", standardInput: nil, timeout: 30,
                        maxOutputBytes: 16_384, cancellation: CancellationToken())
                    evidence["guestDiagnostic"] = String(describing: diagnostic)
                } catch { evidence["guestDiagnosticError"] = String(describing: error) }
            }
            retainEvidence("failed")
            retainFailureEvidence()
            do { try await cleanup() }
            catch {
                evidence["cleanupFailure"] = String(describing: error)
                retainEvidence("cleanup-preserved")
                retainFailureEvidence()
                Issue.record("Own service cleanup incomplete; retained qualification workspace: \(root.path)")
            }
            throw error
        }
    }
}
#endif
