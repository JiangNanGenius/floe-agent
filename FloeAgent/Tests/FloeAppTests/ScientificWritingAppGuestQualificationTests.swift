// SPDX-License-Identifier: MPL-2.0
// Opt-in, fixed-input real App/guest qualification. No production tool or API.
// Main owns target membership, object compilation and canonical Simulator use.
#if canImport(UIKit) && DEBUG
import Foundation
import CryptoKit
import XCTest
import UserNotifications
import FloeCore
import FloeModels
import FloePersistence
import FloeProviders
import FloeTools
import FloeEnvironments
import FloeExecution
import FloeAgentRuntime
import FloeSecurity
@testable import FloeApp

private struct ScientificWritingHoldingAdapter: ProviderAdapter {
    let protocolKind: ModelProtocol = .openAIChatCompletions
    let hold: CancellationToken
    func stream(request: ProviderStreamRequest, credentials: ProviderCredentials) -> AsyncThrowingStream<AgentEvent, Error> {
        let hold = hold
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta(.init(text: "Synthetic scientific-writing qualification; no model inference.")))
            let producer = Task {
                var ticks = 0
                while !hold.isCancelled && !Task.isCancelled {
                    do { try await Task.sleep(for: .milliseconds(50)) }
                    catch { break }
                    ticks += 1
                    if ticks % 100 == 0, !hold.isCancelled, !Task.isCancelled {
                        continuation.yield(.textDelta(.init(text: ".")))
                    }
                }
                if !Task.isCancelled { continuation.yield(.completed(.init(stopReason: .endTurn))) }
                continuation.finish()
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }
    func listModels(provider: ProviderProfile, credentials: ProviderCredentials) async throws -> [ModelProfile] { [] }
}

private actor ScientificWritingCheckpointStore: CheckpointStore {
    private var checkpoints: [UUID: AgentCheckpoint] = [:]
    func save(_ checkpoint: AgentCheckpoint) throws { checkpoints[checkpoint.runID] = checkpoint }
    func load(runID: UUID) throws -> AgentCheckpoint? { checkpoints[runID] }
}

private actor ScientificWritingAuditSink: AuditSink {
    func record(_ entry: AuditEntry) async throws { }
}

@MainActor private final class ScientificWritingGuestOwner {
    static let pins: [(name: String, bytes: Int, sha256: String)] = [
        ("scientific-writing-1.0.0.zip", 192365, "d6b162961e4018cddb8595b4deacbf6dc0cc7543e67eb3245166421e84c37a61"),
        ("qualify_component.py", 12230, "1f8d7bb3440c00365ab4bf1ad6559916433cd2d973b00559b320133489a59e11"),
        ("run_guest_qualification.py", 5358, "d37bed5192c100a13b0e82ab11741bec3038f70e7a62e28d22752f7a9fc1d15e"),
        ("INPUTS.json", 1239, "51734c3c6f41ba16482e04161df40c58202b32867406745246bf82d9278bbe44"),
    ]
    let app: AppEnvironment
    let runID = UUID(), conversationID = UUID()
    let root: URL, evidence: URL
    let hold = CancellationToken()
    var runtime: FloeAgentRuntime?
    var parent: Task<Void, Error>?
    var environmentID: String?
    var binding: TaskExecutionBinding?
    var conversationCreated = false
    var runCreated = false
    var jobs: BackgroundJobService?
    var payload: Data?
    var initialEnvironmentIDs: Set<String>?
    var facts: [String: String] = [
        "kind": "fixed-scientific-writing-real-app-guest-not-official-install",
        "passed": "false", "executionPassed": "false", "cleanupComplete": "false",
        "modelInference": "false", "explicitNetworkOrPackageInstall": "false",
        "syntheticHumanMetadataIsNotActualApproval": "true", "minimumAppVersion": "unassigned",
    ]
    var callID: String { "qa.scientific-writing." + runID.uuidString.lowercased() }

    init(app: AppEnvironment) throws {
        self.app = app
        root = FileManager.default.temporaryDirectory.appendingPathComponent("scientific-writing-guest-" + runID.uuidString, isDirectory: true)
        evidence = URL.applicationSupportDirectory.appendingPathComponent("FloeAgent/QualificationEvidence/ScientificWriting/" + runID.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        facts["runID"] = runID.uuidString; facts["conversationID"] = conversationID.uuidString
        facts["workspace"] = root.path; facts["phase"] = "created"
        try persist()
    }
    func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw FloeError.validationFailed(message) }
    }
    func persist() throws {
        facts["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        try JSONEncoder().encode(facts).write(to: evidence.appendingPathComponent("evidence.json"), options: .atomic)
    }
    func fixedFile(_ url: URL, count: Int, digest: String) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        try require(values.isRegularFile == true && values.isSymbolicLink != true && values.fileSize == count, "Fixed input size/type mismatch: " + url.lastPathComponent)
        let data = try Data(contentsOf: url)
        try require(FloeDigest.sha256Hex(data) == digest, "Fixed input SHA256 mismatch: " + url.lastPathComponent)
        return data
    }
    private func artifactDigest(_ file: URL) throws -> String {
        let stream = try FileHandle(forReadingFrom: file)
        defer { try? stream.close() }
        var hash = SHA256()
        while let bytes = try stream.read(upToCount: 1_048_576), !bytes.isEmpty { hash.update(data: bytes) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func verifyArtifact() throws {
        let env = ProcessInfo.processInfo.environment
        guard let executable = Bundle.main.executableURL else { throw FloeError.notFound("App executable") }
        let key = "FLOE_SCIENTIFIC_WRITING_APP_SHA256"
        guard let expected = env[key], expected.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
            throw FloeError.validationFailed("Supply the exact exported App artifact digest: " + key)
        }
        let actual = try artifactDigest(executable)
        try require(actual == expected, "Actual hosted App artifact differs from the exported artifact")
        facts[key] = actual
        // The current App explicitly disables ENABLE_DEBUG_DYLIB. Bind that
        // actual artifact shape too; never enable split debugging for this test.
        let dylib = executable.deletingLastPathComponent().appendingPathComponent(executable.lastPathComponent + ".debug.dylib")
        let debugFiles = try FileManager.default.contentsOfDirectory(at: executable.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasSuffix(".debug.dylib") }
        let dylibKey = "FLOE_SCIENTIFIC_WRITING_DYLIB_SHA256"
        if env[dylibKey] == "absent" {
            try require(debugFiles.isEmpty, "Expected the exported monolithic App, but found a debug dylib")
            facts[dylibKey] = "absent"; facts["artifactShape"] = "monolithic"
        } else {
            guard let expected = env[dylibKey], expected.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else {
                throw FloeError.validationFailed("Supply the exact exported debug dylib digest or explicit absence")
            }
            try require(debugFiles.count == 1 && debugFiles[0] == dylib, "Actual split App differs from the exported artifact")
            let actual = try artifactDigest(dylib)
            try require(actual == expected, "Actual hosted App artifact differs from the exported artifact")
            facts[dylibKey] = actual; facts["artifactShape"] = "split"
        }
        guard let source = env["FLOE_SCIENTIFIC_WRITING_SOURCE_SHA"], source.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
            throw FloeError.validationFailed("Supply the build's recorded source SHA, independently bound by Main's artifact index")
        }
        facts["callerRecordedSourceSHA"] = source
        facts["appVersion"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        facts["appBuild"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
    }
    func checkBinding() async throws {
        guard let binding else { throw FloeError.validationFailed("No resolved task pin") }
        let saved = try await TaskExecutionBindingStore(database: app.database).binding(conversationID: conversationID)
        let run = try await app.runStore.run(id: runID)
        try require(saved?.target == binding.target && saved?.generation == binding.generation &&
                    run?.executionBinding?.target == binding.target && run?.executionBinding?.generation == binding.generation,
                    "Task/run pin changed; preserve the exact owner and evidence")
    }
    func execute() async throws {
        try verifyArtifact()
        let inputs = URL.applicationSupportDirectory.appendingPathComponent("FloeAgent/QualificationInputs/ScientificWriting", isDirectory: true)
        let staged = root.appendingPathComponent("qualification/inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        for pin in Self.pins {
            let data = try fixedFile(inputs.appendingPathComponent(pin.name), count: pin.bytes, digest: pin.sha256)
            try data.write(to: staged.appendingPathComponent(pin.name), options: .atomic)
            facts[pin.name + ".sha256"] = pin.sha256
        }
        // Read the existing registry first. Never trigger an old-generation
        // migration/reset as a side effect of this bounded content test.
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(EnvironmentRegistry.Snapshot.self, from: Data(contentsOf: EnvironmentRoots.shared.registryURL))
        let revision = await app.environmentRegistry.baseRevision
        try require(snapshot.schemaVersion == EnvironmentRegistry.schemaVersion && snapshot.baseRevision == revision &&
                    snapshot.containers.allSatisfy { $0.effectiveExecutionBackend != .linuxVM || $0.baseRevision == revision },
                    "Existing registry requires separate migration; no environment was prepared")
        try await app.environmentRegistry.prepare()
        initialEnvironmentIDs = Set(await app.environmentRegistry.all().map(\.id))
        try require(initialEnvironmentIDs == Set(snapshot.containers.map(\.id)), "Registry initialization changed its inventory")
        let services = FloePlatformServices.shared
        guard let image = await services.linuxImageStatus(id: LinuxGuestImageDistributionCatalog.defaultImageID),
              image.installed, image.verificationIssue == nil else {
            throw FloeError.validationFailed("A verified local default image is required; this test does not download or repair one")
        }
        facts["imageID"] = image.id
        try await services.prepareWorkspaceEnvironment(root: root)
        let canonical = root.resolvingSymlinksInPath().standardizedFileURL
        let ownerKey = FloeDigest.sha256Hex(Data(canonical.path.utf8))
        let owned = await app.environmentRegistry.containersOwned(by: ownerKey).filter { $0.kind == .project && $0.state != .deleting }
        try require(owned.count == 1, "Expected exactly one environment for THIS unique workspace owner")
        let record = owned[0]
        try require(initialEnvironmentIDs?.contains(record.id) == false, "Never adopt an existing environment")
        environmentID = record.id; facts["environmentID"] = record.id
        let registeredRoot = try await app.environmentRegistry.workspaceRoot(for: record.id)
        try require(registeredRoot?.resolvingSymlinksInPath().standardizedFileURL == canonical, "Registered workspace ownership mismatch")
        try persist()
        // Empty shape preserves the resident engine's existing configuration.
        // Explicit dimensions could request a shared-engine reshape before
        // the per-environment check; this content test must never do that.
        let boot = try await app.linuxGuestLifecycle.start(environmentID: record.id,
            config: .init(), ownerTaskID: nil, cancellation: CancellationToken())
        try JSONEncoder().encode(boot).write(to: evidence.appendingPathComponent("boot-receipt.json"), options: .atomic)
        try require(boot.phase == .running && boot.environmentID == record.id && boot.actualVCPUs > 0 && boot.actualMemoryMB >= 256,
                    "Owned logical environment did not start with a real granted shape")
        let deadline = Date().addingTimeInterval(1200)
        while !(await services.linuxEnvironmentAvailable(id: record.id)), Date() < deadline {
            try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(250))
        }
        try require(await services.linuxEnvironmentAvailable(id: record.id), "Owned Linux guest did not become ready")
        let date = Date()
        try await app.conversationStore.saveConversation(.init(id: conversationID, title: "QA scientific-writing synthetic", createdAt: date, updatedAt: date, titleOrigin: .manual))
        conversationCreated = true
        let pin = try await app.taskExecutionEnvironments.resolveBinding(conversationID: conversationID, runID: runID, root: root, workspace: nil, override: record.id)
        binding = pin
        try require(pin.target.backend == .linuxVM && pin.target.environmentID == record.id && pin.target.remoteHostID == nil &&
                    pin.target.operatingSystem == "linux" && pin.target.architecture == "arm64", "Production resolver returned a different target")
        try JSONEncoder().encode(pin).write(to: evidence.appendingPathComponent("execution-binding.json"), options: .atomic)
        try await app.runStore.saveRun(.init(id: runID, conversationID: conversationID, state: "executing", goal: "Fixed scientific-writing synthetic component qualification; no model", startedAt: date, executionBinding: pin))
        runCreated = true
        let provider = ProviderProfile(kind: .openAI, wireProtocol: .openAIChatCompletions,
            baseURL: URL(string: "https://scientific-writing-qualification.invalid/v1")!, displayName: "Scripted qualification; no network")
        let model = ModelProfile(providerID: provider.id, remoteModelID: "no-inference", displayName: "Scripted hold",
            limits: ModelLimits(contextTokens: 8192, maxOutputTokens: 1024), capabilities: [.tools])
        let active = FloeAgentRuntime(configuration: .init(conversationID: conversationID, provider: provider, model: model,
                allowedToolNames: ["exec.shell"], workspaceRootURL: root, environmentID: record.id, executionBinding: pin),
            adapter: ScientificWritingHoldingAdapter(hold: hold), policy: TaskFullAccessPolicy(), executor: CatalogToolExecutor(),
            auditSink: ScientificWritingAuditSink(), checkpointStore: ScientificWritingCheckpointStore(), runID: runID)
        runtime = active
        parent = Task { try await active.start(goal: "Hold exact synthetic scientific-writing owner") }
        let parentDeadline = Date().addingTimeInterval(20)
        while Date() < parentDeadline {
            if case .streamingModel = await active.state { break }
            try Task.checkCancellation(); try await Task.sleep(for: .milliseconds(50))
        }
        guard case .streamingModel = await active.state else { throw FloeError.validationFailed("Scripted parent never became active") }
        try await checkBinding()
        let identity = ChildExecutionIdentity(parentRunID: runID, rootTaskID: conversationID, delegateCallID: "scientific-writing-fixed-preflight")
        let context = ToolContext(runID: runID, scope: .local, allowedToolNames: ["exec.shell"], workspaceRootURL: root,
            cancellation: CancellationToken(), environmentID: record.id, executionBindingGeneration: pin.generation, conversationID: conversationID)
        let script = """
        python3 -E -B -S - <<'PY'
        import hashlib, json, pathlib, platform, sys
        p = pathlib.Path('qualification/inputs')
        assert sys.platform == 'linux' and platform.machine() == 'aarch64'
        assert platform.release() == '6.12.107+deb13-arm64'
        assert sys.version_info >= (3, 11)
        raw = (p/'INPUTS.json').read_bytes()
        assert len(raw) == 1239 and hashlib.sha256(raw).hexdigest() == '51734c3c6f41ba16482e04161df40c58202b32867406745246bf82d9278bbe44'
        for name, pin in json.loads(raw)['files'].items():
            data = (p/name).read_bytes()
            assert len(data) == pin['bytes'] and hashlib.sha256(data).hexdigest() == pin['sha256'], name
        proof = dict(system=platform.system(), machine=platform.machine(), kernel=platform.release(), python=platform.python_version(), files=4)
        pathlib.Path('qualification/GUEST-PREFLIGHT.json').write_text(json.dumps(proof, sort_keys=True)+'\\n')
        print('SCIENTIFIC_WRITING_GUEST_PREFLIGHT_OK')
        PY
        """
        let preflight = try ToolCall(id: "scientific-writing-preflight", toolName: "exec.shell",
            argumentsJSON: JSONSerialization.data(withJSONObject: ["command": script, "cwd": ".", "maxOutputBytes": 24576]), scope: .local)
        let response = await active.dispatchChildTool(preflight, identity: identity, childContext: context)
        try JSONEncoder().encode(response).write(to: evidence.appendingPathComponent("preflight-tool-result.json"), options: .atomic)
        try require(response.status == .ok && response.outputSummary.contains("SCIENTIFIC_WRITING_GUEST_PREFLIGHT_OK"), "Actual guest preflight failed; retain original tool result")
        guard let jobs = app.backgroundJobService else { throw FloeError.notFound("App background job service") }
        self.jobs = jobs
        let payload = try JSONSerialization.data(withJSONObject: [
            "command": "python3 -E -B -S qualification/inputs/run_guest_qualification.py --inputs qualification/inputs --output qualification/output",
            "cwd": ".", "maxOutputBytes": 24576,
        ])
        self.payload = payload
        try payload.write(to: evidence.appendingPathComponent("submitted-payload.json"), options: .atomic)
        facts["phase"] = "submitting"; facts["payloadSHA256"] = FloeDigest.sha256Hex(payload); try persist()
        let job = try await jobs.submit(runID: runID, toolCallID: callID, targetTool: "exec.shell", payloadJSON: payload,
            scope: .local, workspaceRootURL: root, allowedWorkspacePaths: [], environmentID: record.id,
            allowedToolNames: ["exec.shell"], submissionSource: .nativeService, waitForCompletion: true)
        try validate(job)
        facts["jobID"] = job.id.uuidString; facts["phase"] = "running"; try persist()
        let terminal = try await waitForJob(job.id, service: jobs)
        try JSONEncoder().encode(terminal).write(to: evidence.appendingPathComponent("terminal-job.json"), options: .atomic)
        try require(terminal.state == .completed, "Scientific-writing job failed; retain actual service result")
        let receipt = try json("qualification/output/LINUX-RECEIPT.json")
        let result = try json("qualification/output/component/RESULT.json")
        try require(receipt["passed"] as? Bool == true && receipt["packageSHA256"] as? String == Self.pins[0].sha256 &&
                    receipt["runnerSHA256"] as? String == Self.pins[1].sha256 && receipt["machine"] as? String == "aarch64" &&
                    receipt["platform"] as? String == "Linux" && receipt["runnerExit"] as? Int == 0, "Guest receipt identity/exit mismatch")
        let records = result["records"] as? [[String: Any]]
        try require(result["platform"] as? String == "Linux" && result["machine"] as? String == "aarch64" &&
                    result["cases"] as? Int == 42 && result["passed"] as? Int == 42 &&
                    (result["failures"] as? [String]) == [] && records?.count == 42 && records?.allSatisfy { $0["passed"] as? Bool == true } == true,
                    "The exact 42 checks did not all pass; no case may be skipped or weakened")
        try await checkBinding()
        facts["executionPassed"] = "true"; facts["cases"] = "42"; facts["phase"] = "verified-awaiting-cleanup"; try persist()
    }
    func json(_ path: String) throws -> [String: Any] {
        let file = root.appendingPathComponent(path)
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        try require(values.isRegularFile == true && values.isSymbolicLink != true, "Expected regular evidence file")
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
    }
    func validate(_ job: BackgroundJob) throws {
        try require(job.runID == runID && job.conversationID == conversationID && job.environmentID == environmentID &&
                    job.toolCallID == callID && job.targetTool == "exec.shell" && job.payloadJSON == payload &&
                    URL(fileURLWithPath: job.workspaceRootPath ?? "").resolvingSymlinksInPath().standardizedFileURL == root.resolvingSymlinksInPath().standardizedFileURL,
                    "Persisted job does not match the exact synthetic owner/payload")
    }
    func waitForJob(_ id: UUID, service: BackgroundJobService, cleanup: Bool = false) async throws -> BackgroundJob {
        let deadline = cleanup ? Date().addingTimeInterval(120) : nil
        var lastProgress = Date()
        while true {
            if !cleanup { try Task.checkCancellation() }
            let saved = try await service.job(id: id)
            let job = try XCTUnwrap(saved); try validate(job)
            if job.state.isTerminal { return job }
            if let deadline, Date() >= deadline { throw FloeError.validationFailed("Owned worker stop is unconfirmed; retain its environment/workspace") }
            if Date().timeIntervalSince(lastProgress) >= 30 {
                print("FLOE_SCIENTIFIC_WRITING_WAIT job=\(id) state=\(job.state.rawValue)"); lastProgress = Date()
            }
            try await Task.sleep(for: .milliseconds(250))
        }
    }
    private func verifyExportedEvidence(source: URL, destination: URL) throws {
        guard let files = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isRegularFileKey]) else {
            throw FloeError.notFound("Owned evidence enumeration")
        }
        for case let file as URL in files {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                let relative = String(file.path.dropFirst(source.path.count + 1))
                try require(try Data(contentsOf: file) == Data(contentsOf: destination.appendingPathComponent(relative)),
                            "Exported evidence readback mismatch")
            }
        }
    }
    func finish() async throws {
        // This function runs in an unstructured MainActor task so a cancelled
        // XCTest waiter cannot cancel the service's stop/drain ownership.
        await runtime?.cancel(); hold.cancel(); parent?.cancel()
        if let parent {
            do { try await parent.value }
            catch is CancellationError { }
            catch let error as FloeError where error == .cancelled { }
            catch { facts["parentJoinError"] = error.localizedDescription; try persist() }
        }
        facts["parentStopped"] = "true"
        // Reconcile by exact run/call/payload even when submit threw after
        // persistence. Never resubmit, guess a job ID or cancel another job.
        let rows = try await BackgroundJobStore(database: app.database).jobs(runID: runID, limit: 10)
        try require(rows.count <= 1, "Unexpected jobs attached to the unique qualification run")
        for row in rows {
            try validate(row)
            guard let jobs else { throw FloeError.validationFailed("A persisted worker has no service owner; preserve it") }
            if !row.state.isTerminal { _ = try await jobs.cancel(id: row.id) }
            let terminal = try await waitForJob(row.id, service: jobs, cleanup: true)
            try JSONEncoder().encode(terminal).write(to: evidence.appendingPathComponent("cleanup-terminal-job.json"), options: .atomic)
        }
        facts["workersStopped"] = "true"; try persist()
        if runCreated { try await checkBinding() }
        if let environmentID {
            try await FloePlatformServices.shared.stopEnvironment(id: environmentID)
            let status = await FloePlatformServices.shared.linuxEnvironmentStatus(id: environmentID)
            try require(status?.environmentID == environmentID && status?.running == false, "Guest stop is unconfirmed; preserve its environment/workspace")
        }
        facts["guestStopped"] = "true"; try persist()
        let source = root.appendingPathComponent("qualification")
        if FileManager.default.fileExists(atPath: source.path) {
            let destination = evidence.appendingPathComponent("qualification")
            try FileManager.default.copyItem(at: source, to: destination)
            try verifyExportedEvidence(source: source, destination: destination)
        }
        facts["evidenceExportedAndReadBack"] = "true"; try persist()
        if facts["parentJoinError"] != nil {
            throw FloeError.validationFailed("Parent join reported an original error; stopped workers and exported evidence retained")
        }
        if let environmentID {
            let ownerKey = FloeDigest.sha256Hex(Data(root.resolvingSymlinksInPath().standardizedFileURL.path.utf8))
            let owned = await app.environmentRegistry.containersOwned(by: ownerKey)
            try require(owned.count == 1 && owned[0].id == environmentID && initialEnvironmentIDs?.contains(environmentID) == false, "Cleanup environment ownership changed")
            try await FloePlatformServices.shared.deleteEnvironment(id: environmentID)
            try require(await app.environmentRegistry.record(id: environmentID) == nil, "Owned environment deletion not confirmed")
        }
        if let initialEnvironmentIDs {
            try require(Set(await app.environmentRegistry.all().map(\.id)) == initialEnvironmentIDs, "Existing environment inventory changed; preserve remaining records/workspace")
        }
        if runCreated { try await app.runStore.updateRunState(id: runID, state: facts["executionPassed"] == "true" ? "completed" : "failed", endedAt: Date()) }
        if conversationCreated { try await app.conversationStore.deleteConversation(id: conversationID) }
        let notifications = UNUserNotificationCenter.current(), ids = rows.map { "jobs." + $0.id.uuidString }
        notifications.removePendingNotificationRequests(withIdentifiers: ids); notifications.removeDeliveredNotifications(withIdentifiers: ids)
        try FileManager.default.removeItem(at: root)
        facts["cleanupComplete"] = "true"
        facts["passed"] = facts["executionPassed"] == "true" && facts["originalFailure"] == nil ? "true" : "false"
        facts["phase"] = "finished"; try persist()
    }
}

@MainActor final class ScientificWritingAppGuestQualificationTests: XCTestCase {
    func testPinnedScientificWritingThroughOwnedGuest() async throws {
        guard ProcessInfo.processInfo.environment["FLOE_SCIENTIFIC_WRITING_QUALIFICATION"] == "1" else {
            throw XCTSkip("Opt in explicitly; a skipped test is not guest qualification")
        }
        let owner = try ScientificWritingGuestOwner(app: await appQualificationEnvironment())
        var failure: Error?
        do { try await owner.execute() }
        catch { failure = error; owner.facts["originalFailure"] = String(error.localizedDescription.prefix(4000)) }
        let cleanup = Task { @MainActor in try await owner.finish() }
        do { try await cleanup.value }
        catch {
            owner.facts["cleanupFailure"] = String(error.localizedDescription.prefix(4000))
            owner.facts["passed"] = "false"; owner.facts["phase"] = "retained-for-recovery"
            try owner.persist()
            print("FLOE_SCIENTIFIC_WRITING_EVIDENCE=" + owner.evidence.path)
            if let failure { XCTFail("Original execution failure: " + failure.localizedDescription) }
            throw error
        }
        print("FLOE_SCIENTIFIC_WRITING_EVIDENCE=" + owner.evidence.path)
        if let failure { throw failure }
    }
}
#endif
