// FloeExecutionTests — static contracts for the bundled Linux cleanup script
// and its service payload. No guest, job, network or host cleanup is started.

import Foundation
import Testing
import FloeCore
import FloeModels
import FloeTools
import FloePersistence
@testable import FloeExecution

@Suite("Linux cache cleanup script contracts", .serialized)
struct LinuxCacheCleanupScriptContractTests {
    @Test("Script is fixed-root, model-free and never sweeps generic home/tmp trees")
    func scriptBoundary() {
        let source = LinuxCacheCleanupScript.source
        #expect(source.hasPrefix("#!/bin/sh\n"))
        #expect(source.contains("FLOE_LINUX_CLEANUP_V1"))
        #expect(source.contains("/floe/env/cache/pip"))
        #expect(source.contains("/floe/env/cache/npm"))
        #expect(source.contains("/var/tmp/floe-runtime"))
        #expect(source.contains("apt-get clean"))
        #expect(source.contains("cleanup_already_running"))
        #expect(source.contains("skipped-busy"))
        #expect(source.contains("skipped-symlink"))
        #expect(source.contains("find \"$_root\" -type l"))
        #expect(!source.contains("rm -rf \"$HOME/.cache\""))
        #expect(!source.contains("find \"$HOME/.cache\""))
        #expect(!source.contains("huggingface"))
        #expect(!source.contains("torch"))
        #expect(!source.contains("pip install"))
        #expect(!source.contains("npm install"))
        #expect(!source.contains("apt-get remove"))
        #expect(!source.contains("dpkg --purge"))
        #expect(!source.contains("rm -rf / "))
        #expect(!source.contains("curl "))
        #expect(!source.contains("wget "))
    }

    @Test("Native payload carries the script and validated env only: no command/path argument")
    func payloadShape() throws {
        let data = try LinuxCacheCleanupService.makePayload(
            script: LinuxCacheCleanupScript.source,
            mode: "clean",
            categories: [.apt, .npm]
        )
        let raw = try JSONSerialization.jsonObject(with: data)
        let object = try #require(raw as? [String: Any])
        #expect(object["command"] == nil)
        #expect(object["cwd"] == nil)
        #expect(object["args"] == nil)
        #expect(object["script"] as? String == LinuxCacheCleanupScript.source)
        let env = try #require(object["env"] as? [String: String])
        #expect(env["FLOE_CLEANUP_SCHEMA"] == LinuxCacheCleanupScript.schema)
        #expect(env["FLOE_CLEANUP_NATIVE"] == "1")
        #expect(env["FLOE_CLEANUP_MODE"] == "clean")
        #expect(env["FLOE_CLEANUP_CATEGORIES"] == "apt,npm")
        #expect(object["maxOutputBytes"] as? Int == 262_144)
        #expect(object["timeoutPolicy"] as? String == "advisory")
    }

    @Test("Category validation refuses unknown, duplicate and non-canonical order")
    func categoryValidation() {
        #expect(LinuxCacheCleanupCategory.validated(rawValues: ["npm", "apt"]) == [.apt, .npm])
        #expect(LinuxCacheCleanupCategory.validated(rawValues: ["apt", "apt"]) == nil)
        #expect(LinuxCacheCleanupCategory.validated(rawValues: ["../Documents"]) == nil)
        #expect(LinuxCacheCleanupCategory.validated(rawValues: ["scratch"]) == nil)
        #expect(LinuxCacheCleanupCategory.validated(rawValues: ["apt", "scratch"]) == nil)
        #expect(LinuxCacheCleanupCategory.allKnown == [.apt, .pip, .npm])
        #expect(LinuxCacheCleanupCategory.defaultSafe == [.apt, .pip, .npm])
        #expect(!LinuxCacheCleanupCategory.scratch.isDefaultSafe)
    }

    @Test("Parser reports actual cleanup, busy skip, guest df and partial evidence")
    func parsesResult() throws {
        let output = """
        FLOE_LINUX_CLEANUP_V1
        schema=floe.linux-cache-cleanup.v1
        mode=clean
        df_path=/floe/env
        df_available_before_bytes=1000000
        category=apt status=cleaned bytes_before=500000 bytes_after=100000 note=package_manager_lock_held
        category=pip status=skipped-busy bytes_before=900000 bytes_after=900000 note=cache_in_use
        df_available_after_bytes=1400000
        cancelled=0
        summary cleaned_categories=1 skipped_categories=1 failed_categories=0
        """
        let receipt = try #require(LinuxCacheCleanupScriptResult.parse(output))
        #expect(receipt.state == "completed")
        #expect(receipt.mode == "clean")
        #expect(receipt.dfAvailableBeforeBytes == 1_000_000)
        #expect(receipt.dfAvailableAfterBytes == 1_400_000)
        #expect(receipt.categoryResults.count == 2)
        #expect(receipt.categoryResults[0].status == "cleaned")
        #expect(receipt.categoryResults[1].status == "skipped-busy")
        #expect(!receipt.partial)
        #expect(receipt.modelSummary.contains("not iPad physical space"))
    }

    @Test("Cancelled output is never reported as a successful cleanup")
    func cancelledOutput() throws {
        let output = """
        FLOE_LINUX_CLEANUP_V1
        schema=floe.linux-cache-cleanup.v1
        mode=clean
        df_path=/floe/env
        df_available_before_bytes=1000
        category=apt status=partial bytes_before=100 bytes_after=100 note=delete_failed
        df_available_after_bytes=1000
        cancelled=1
        summary cleaned_categories=0 skipped_categories=0 failed_categories=1
        error=cancelled
        """
        let receipt = try #require(LinuxCacheCleanupScriptResult.parse(output))
        #expect(receipt.state == "cancelled")
        #expect(receipt.cancelled)
    }

    @Test("Malformed or missing protocol output is not guessed")
    func malformedOutput() {
        #expect(LinuxCacheCleanupScriptResult.parse("done") == nil)
        #expect(LinuxCacheCleanupScriptResult.parse("") == nil)
    }

    @Test("Unverified runtime/origin errors map to repair guidance, never to a reset claim")
    func repairGuidance() throws {
        let guidance = try #require(LinuxCacheCleanupEnvironmentRepair.guidance(
            forMessage: "Linux runtime origin is unverified; image must be revalidated"))
        #expect(guidance.contains("Execution Environments") || guidance.contains("执行环境"))
        #expect(guidance.contains("did not reset disk") || guidance.contains("没有重置磁盘"))
        #expect(LinuxCacheCleanupEnvironmentRepair.guidance(forMessage: "network timeout") == nil)
    }

    @Test("Inspect engine failure is a failed card with unchanged job/error and unknown capacity")
    func inspectFailedReceiptIsFailure() throws {
        let jobID = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        let receipt = LinuxCacheCleanupReceipt(jobID: jobID, state: "failed", mode: "inspect",
            categories: ["apt", "pip", "npm"], error: "engineUnavailable: origin unverified; exit125")
        let output = LinuxCacheCleanupInspectTool.output(receipt)
        #expect(output.exitStatus == 1)
        let captured = try #require(output.capturedOutput)
        let decoded = try JSONDecoder().decode(LinuxCacheCleanupReceipt.self, from: Data(captured.utf8))
        #expect(decoded.jobID == jobID && decoded.state == "failed")
        #expect(decoded.error == receipt.error)
        #expect(decoded.dfAvailableBeforeBytes == nil && decoded.categoryResults.isEmpty)
        for state in ["queued", "running", "completed"] {
            var ordinary = receipt; ordinary.state = state; ordinary.error = nil
            #expect(LinuxCacheCleanupInspectTool.output(ordinary).exitStatus == 0)
        }
    }

    @Test("Legacy scratch is retained without traversing or deleting generic temporary files")
    func scratchHasNoDeletionCapability() throws {
        let source = LinuxCacheCleanupScript.source
        let start = try #require(source.range(of: "clean_scratch() {"))
        let end = try #require(source.range(of: "\n}\n", range: start.upperBound..<source.endIndex))
        let body = String(source[start.upperBound..<end.lowerBound])
        #expect(body.contains("emit_category scratch retained unknown unknown ownership_unverified"))
        #expect(!body.contains("rm "))
        #expect(!body.contains("find "))
        #expect(!body.contains("du_bytes"))
        #expect(!source.contains("SCRATCH_MIN_AGE_MINUTES"))
        let output = """
        FLOE_LINUX_CLEANUP_V1
        schema=floe.linux-cache-cleanup.v1
        mode=clean
        category=scratch status=retained bytes_before=unknown bytes_after=unknown note=ownership_unverified
        df_available_before_bytes=unknown
        df_available_after_bytes=unknown
        cancelled=0
        summary cleaned_categories=0 skipped_categories=1 failed_categories=0
        """
        let receipt = try #require(LinuxCacheCleanupScriptResult.parse(output))
        #expect(receipt.categoryResults.first?.status == "retained")
        #expect(receipt.categoryResults.first?.bytesBefore == nil)
    }

    @Test("No offered schema or native payload can select scratch")
    func schemasAndPayloadRefuseScratch() throws {
        for schema in [LinuxCacheCleanupInspectTool.parametersJSON, LinuxCacheCleanupCleanTool.parametersJSON] {
            let root = try #require(JSONSerialization.jsonObject(with: Data(schema.utf8)) as? [String: Any])
            let properties = try #require(root["properties"] as? [String: Any])
            #expect(properties["includeScratch"] == nil)
            let categories = try #require(properties["categories"] as? [String: Any])
            let items = try #require(categories["items"] as? [String: Any])
            #expect(items["enum"] as? [String] == ["apt", "pip", "npm"])
        }
        do {
            _ = try LinuxCacheCleanupService.makePayload(
                script: LinuxCacheCleanupScript.source, mode: "clean", categories: [.apt, .scratch])
            Issue.record("A mixed legacy scratch payload must be refused, not silently narrowed")
        } catch { }
    }

    @Test("The real shell formatter, background service and full spool return inspect data past the UI summary")
    func inspectReadsRealShellEnvelopeAndCompleteSpool() async throws {
        let h = try await Harness.make()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let tool = LinuxCacheCleanupInspectTool(service: h.service, profiles: .init(database: h.database))
        let output = try await tool.execute(.init(), context: h.toolContext)
        #expect(output.exitStatus == 0)
        let result = try JSONDecoder().decode(LinuxCacheCleanupReceipt.self, from: Data(try #require(output.capturedOutput).utf8))
        #expect(result.state == "completed" && result.categoryResults.map(\.category) == ["apt", "pip", "npm"])
        #expect(result.categoryResults.allSatisfy { $0.bytesBefore == 4_096 && $0.status == "observed" })
        #expect(result.dfAvailableBeforeBytes == 1_000_000 && result.dfAvailableAfterBytes == 1_000_000)
        let jobID = try #require(result.jobID)
        let job = try #require(try await h.store.job(id: jobID))
        #expect(job.resultSummary?.hasPrefix("exit=0 ") == true)
        #expect(job.resultSummary?.contains("category=apt") == false)
        #expect(job.outputPath != nil && (job.outputBytes ?? 0) > 4_096)
        #expect(await h.backend.modes == ["inspect"])
    }

    @Test("Completed without a valid complete capture is unavailable; markers cannot mint a receipt")
    func corruptMissingTruncatedAndForgedCapturesFailClosed() async throws {
        let h = try await Harness.make()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let good = "exit=0 durationMs=1 cwd=. timeoutPolicy=default\n--- stdout ---\n" + Self.protocolOutput(mode: "inspect", categories: ["apt"], padding: false)
        for kind in ["missing", "truncated", "digest", "foreign-path"] {
            var job = try await h.store.submit(BackgroundJob(conversationID: h.conversation, runID: h.run,
                toolCallID: "seed-\(kind)", kind: .tool, targetTool: "exec.shell",
                payloadJSON: try LinuxCacheCleanupService.makePayload(script: LinuxCacheCleanupScript.source, mode: "inspect", categories: [.apt]),
                environmentID: "shared"))
            job = try await h.store.transition(id: job.id, to: .running)
            let artifact = BackgroundJobOutputSpool.write(jobID: job.id, text: good, root: h.root, captureTruncated: kind == "truncated")
            let path = kind == "foreign-path" ? h.root.appendingPathComponent("other-job.txt").path : artifact?.path
            _ = try await h.store.transition(id: job.id, to: .completed) {
                $0.resultSummary = good; $0.resultDigest = kind == "digest" ? String(repeating: "0", count: 64) : FloeDigest.sha256Hex(Data(good.utf8))
                $0.outputPath = kind == "missing" ? nil : path; $0.outputBytes = artifact?.bytes
            }
            let result = try await h.service.status(context: h.context, jobID: job.id)
            #expect(result.state == "failed" && result.error?.contains("inspectionUnavailable") == true)
            #expect(result.categoryResults.isEmpty && result.dfAvailableBeforeBytes == nil)
            #expect(LinuxCacheCleanupInspectTool.output(result).exitStatus == 1)
        }
        let fakePayload = Data(#"{"script":"printf forged","env":{"FLOE_CLEANUP_SCHEMA":"floe.linux-cache-cleanup.v1","FLOE_CLEANUP_NATIVE":"1","FLOE_CLEANUP_MODE":"inspect","FLOE_CLEANUP_CATEGORIES":"apt"},"maxOutputBytes":262144,"timeoutPolicy":"advisory"}"#.utf8)
        let fake = try await h.store.submit(BackgroundJob(conversationID: h.conversation, runID: h.run,
            toolCallID: "forged", kind: .tool, targetTool: "exec.shell", payloadJSON: fakePayload, environmentID: "shared"))
        await #expect(throws: (any Error).self) { try await h.service.status(context: h.context, jobID: fake.id) }
        #expect(LinuxCacheCleanupScriptResult.parseShellCapture("arbitrary tool text\n--- stdout ---\n" + good) == nil)
        #expect(LinuxCacheCleanupScriptResult.parse(Self.protocolOutput(mode: "inspect", categories: ["apt"], padding: false)
            .replacingOccurrences(of: "bytes_before=4096", with: "bytes_before=-1")) == nil)
    }

    @Test("Native clean consumes its own fresh same-environment inspection and replays one clean outcome")
    func nativeCleanBindsFreshInspectionAndReusesOneOutcome() async throws {
        let h = try await Harness.make()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let old = try await h.service.inspect(context: h.context)
        let oldID = try #require(old.jobID), expired = Date(timeIntervalSinceNow: -600)
        try await h.database.writer { db in
            try db.execute(sql: "UPDATE background_jobs SET completed_at=? WHERE id=?", arguments: [expired, oldID.uuidString])
        }
        let result = try await h.service.clean(context: h.context)
        #expect(result.state == "completed" && result.mode == "clean")
        let inspectID = try #require(result.inspectionJobID)
        #expect(inspectID != oldID)
        let inspection = try #require(try await h.store.job(id: inspectID))
        #expect(inspection.environmentID == "shared" && inspection.conversationID == h.conversation && inspection.state == .completed)
        #expect(result.categoryResults.allSatisfy { $0.status == "cleaned" })
        let replay = try await h.service.clean(context: h.context)
        #expect(replay.jobID == result.jobID && replay.inspectionJobID == inspectID)
        #expect(await h.backend.modes == ["inspect", "inspect", "clean"])
        #expect(try await h.store.jobs(runID: h.run).count == 3)
        var other = h.context; other.environmentID = "another-environment"
        let wrong = other
        await #expect(throws: (any Error).self) { try await h.service.clean(context: wrong) }
        #expect(await h.backend.modes == ["inspect", "inspect", "clean"])
    }

    @Test("A queued native inspect is an acknowledgment, never measurement or fallback completion")
    func pendingInspectKeepsJobIDAndCannotStartClean() async throws {
        let h = try await Harness.make()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let queued = try await h.store.submit(BackgroundJob(conversationID: h.conversation, runID: h.run,
            toolCallID: "queued-inspect", kind: .tool, targetTool: "exec.shell",
            payloadJSON: try LinuxCacheCleanupService.makePayload(script: LinuxCacheCleanupScript.source, mode: "inspect", categories: [.apt, .pip, .npm]),
            environmentID: "shared"))
        let pending = try await h.service.inspect(context: h.context)
        #expect(pending.awaitingCompletion && pending.jobID == queued.id && pending.categoryResults.isEmpty)
        #expect(pending.modelSummary.contains("Accepted only") && pending.modelSummary.contains("linux.cache.status"))
        let clean = try await h.service.clean(context: h.context)
        #expect(clean.awaitingCompletion && clean.mode == "inspect" && clean.jobID == queued.id)
        let currentJobs = try await h.store.jobs(runID: h.run), modes = await h.backend.modes
        #expect(currentJobs.count == 1 && modes.isEmpty)
        let stopped = try await h.service.cancel(context: h.context, jobID: queued.id)
        #expect(stopped.state == "cancelled" && stopped.cancelled)
    }

    @Test("An actual ordinary shell job dispatch/readback works without invoking the optional inspect")
    func terminalJobDispatchAndOwnedReadbackDoNotRequireInspect() async throws {
        let h = try await Harness.make()
        defer { try? FileManager.default.removeItem(at: h.root) }
        let payload = try JSONSerialization.data(withJSONObject: ["tool": "exec.shell",
            "arguments": #"{"command":"df -Pk /; du -sk /var/cache/apt/archives"}"#, "wait": true] as [String: Any])
        let raw = AnyAgentTool(JobsSubmitTool(service: h.jobs))
        let runner = AnyAgentTool(descriptor: raw.descriptor, run: raw.run, validateArguments: raw.validateArguments, routing: h.routing)
        let profile = LinuxCacheCleanupTaskProfile(conversationID: h.conversation, environmentID: "shared")
        #expect(LinuxCacheCleanupScope.denialReason(profile: profile, conversationID: h.conversation,
            environmentID: "shared", descriptor: raw.descriptor, arguments: payload, scope: .local) == nil)
        let context = ToolContext(runID: h.run, toolCallID: "terminal-dispatch", allowedToolNames: LinuxCacheCleanupScope.allowedToolNames,
            workspaceRootURL: h.root, cancellation: CancellationToken(), environmentID: "shared", conversationID: h.conversation,
            callOrigin: .init(kind: .mainRunDelegate, runID: h.run, callID: "terminal-dispatch", toolName: "jobs.submit"))
        let submitted = try await runner.execute(argumentsJSON: payload, context: context)
        let object = try #require(try JSONSerialization.jsonObject(with: Data(submitted.summary.utf8)) as? [String: Any])
        let jobID = try #require((object["jobID"] as? String).flatMap(UUID.init(uuidString:)))
        let deadline = Date().addingTimeInterval(5)
        while let job = try await h.jobs.job(id: jobID), !job.state.isTerminal, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
        let final = try #require(try await h.jobs.job(id: jobID))
        #expect(final.state == .completed && final.environmentID == "shared" && final.conversationID == h.conversation)
        let read = JobsResultTool(service: h.jobs, outputRoot: h.root)
        let result = try await read.execute(.init(jobID: jobID.uuidString, maxBytes: 16_000), context: h.toolContext)
        #expect(result.summary.contains("df_available_before_bytes=1000000"))
        #expect(await h.backend.modes == ["terminal"])
        await #expect(throws: (any Error).self) {
            try await read.execute(.init(jobID: jobID.uuidString), context: .init(runID: UUID(), cancellation: CancellationToken()))
        }
        let ordinary = ToolContext(runID: h.run, workspaceRootURL: h.root, cancellation: CancellationToken(), environmentID: "shared", conversationID: UUID())
        await #expect(throws: (any Error).self) {
            try await LinuxCacheCleanupInspectTool(service: h.service, profiles: .init(database: h.database)).execute(.init(), context: ordinary)
        }
    }

    /// Deterministic backend only: no process, guest, network or host command.
    /// The actual formatter, registry, SQLite jobs and canonical spool execute.
    private actor CaptureBackend: LocalShellBackend {
        private(set) var modes: [String] = []
        func run(_ request: ShellRunRequest, cancellation: CancellationToken?) async -> ShellRunOutcome {
            let mode = request.environment["FLOE_CLEANUP_MODE"] ?? "terminal"
            modes.append(mode)
            let selected = (request.environment["FLOE_CLEANUP_CATEGORIES"] ?? "apt,pip,npm").split(separator: ",").map(String.init)
            return .exited(code: 0, stdout: LinuxCacheCleanupScriptContractTests.protocolOutput(mode: mode, categories: selected, padding: true),
                           stderr: "", truncated: false, stderrTruncated: false, durationMs: 1)
        }
        func openSession(_ request: ShellOpenRequest, cancellation: CancellationToken?) async throws -> ShellOpenResult { .init(sessionID: request.sessionID, initialOutput: "", alive: true) }
        func exchangeSession(_ request: ShellExchangeRequest, cancellation: CancellationToken?) async throws -> ShellExchangeResult { .init(output: "", alive: true) }
        func closeSession(sessionID: String) async { }
    }

    nonisolated private static func protocolOutput(mode: String, categories: [String], padding: Bool) -> String {
        var text = "FLOE_LINUX_CLEANUP_V1\nschema=floe.linux-cache-cleanup.v1\nmode=\(mode)\n"
        if padding { text += "diagnostic=" + String(repeating: "x", count: 6_000) + "\n" }
        text += "df_path=/floe/env\ndf_available_before_bytes=1000000\n"
        for name in categories { text += "category=\(name) status=\(mode == "clean" ? "cleaned" : "observed") bytes_before=4096 bytes_after=\(mode == "clean" ? 0 : 4096) note=none\n" }
        text += "df_available_after_bytes=1000000\ncancelled=0\nsummary cleaned_categories=\(categories.count) skipped_categories=0 failed_categories=0\n"
        return text
    }

    private struct Harness {
        let root: URL, database: DatabaseManager, conversation: UUID, run: UUID
        let store: BackgroundJobStore, service: LinuxCacheCleanupService, backend: CaptureBackend
        let jobs: BackgroundJobService, routing: ToolEnvironmentRouting
        var context: LinuxCacheCleanupContext { .init(runID: run, conversationID: conversation, environmentID: "shared", workspaceRootURL: root, allowedWorkspacePaths: [], cancellation: CancellationToken()) }
        var toolContext: ToolContext { .init(runID: run, workspaceRootURL: root, cancellation: CancellationToken(), environmentID: "shared", conversationID: conversation) }
        static func make() async throws -> Self {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("linux-cache-contract-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let db = try DatabaseManager.inMemory(); try await db.migrate()
            let conversation = UUID(), run = UUID(), now = ISO8601DateFormatter().string(from: Date())
            try await db.writer { db in
                try db.execute(sql: "INSERT INTO conversations(id,title,created_at,updated_at) VALUES (?,'Cache contract',?,?)", arguments: [conversation.uuidString, now, now])
                try db.execute(sql: "INSERT INTO runs(id,conversation_id,state,goal,started_at) VALUES (?,?,'running','Cache contract',?)", arguments: [run.uuidString, conversation.uuidString, now])
            }
            let profiles = LinuxCacheCleanupTaskStore(database: db)
            _ = try await profiles.create(.init(conversationID: conversation, environmentID: "shared"))
            let backend = CaptureBackend(), registry = ToolRunnerRegistry(), routing = ToolEnvironmentRouting()
            routing.configure { context in
                guard context.environmentID == "shared", context.conversationID == conversation, context.runID == run else { throw FloeError.unauthorized }
                return ToolEnvironmentLease(context: context)
            }
            let native = AnyAgentTool(LocalShellTool(shell: LocalShellService(backend: backend, rootProvider: { root })))
            registry.register(AnyAgentTool(descriptor: native.descriptor, run: native.run,
                validateArguments: native.validateArguments, preflightSubmission: native.preflightSubmission, routing: routing))
            let store = BackgroundJobStore(database: db)
            let jobs = BackgroundJobService(store: store, registry: registry, outputSpooler: { id, text, truncated in
                guard let artifact = BackgroundJobOutputSpool.write(jobID: id, text: text, root: root, captureTruncated: truncated) else { throw CocoaError(.fileWriteUnknown) }
                return artifact
            })
            let service = LinuxCacheCleanupService(jobs: jobs, jobStore: store,
                profileResolver: { id in try? await profiles.profile(conversationID: id) }, recordMetadata: { _, _ in }, outputRootURL: root)
            return Self(root: root, database: db, conversation: conversation, run: run, store: store, service: service, backend: backend, jobs: jobs, routing: routing)
        }
    }

}
