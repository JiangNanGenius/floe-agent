import Foundation
import Testing
import FloeTools
import FloeCore
import FloeModels
import FloeProviders
import FloeSecurity
import FloeTestSupport
@testable import FloeAgentRuntime

@Suite("Captured tool results")
struct ToolResultCaptureTests {
    private func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-captures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("pages are UTF-8 safe, offset-correct and complete")
    func pagingIsUtf8SafeAndComplete() async throws {
        let store = ToolResultCaptureStore(durableRoot: nil)
        let task = UUID()
        let run = UUID()
        let text = "中文结果 — first\nsecond line\nthird line with more bytes\n"
        await store.capture(conversationID: task, runID: run, callID: "call_1",
                            toolName: "exec.shell", status: "ok", text: text, temporary: false)
        var offset = 0
        var rebuilt = ""
        while true {
            guard case .page(let page) = await store.page(
                conversationID: task, runID: run, callID: "call_1", offset: offset, maxBytes: 7
            ) else {
                Issue.record("page missing at offset \(offset)")
                return
            }
            #expect(page.totalBytes == text.utf8.count)
            rebuilt += page.text
            if let next = page.nextOffset {
                #expect(next > offset)
                offset = next
            } else {
                break
            }
        }
        #expect(rebuilt == text)
        // Out-of-range offsets are reported, never clamped into invented bytes.
        if case .outOfRange(let total, _) = await store.page(
            conversationID: task, runID: run, callID: "call_1",
            offset: text.utf8.count, maxBytes: 8
        ) {
            #expect(total == text.utf8.count)
        } else {
            Issue.record("expected outOfRange")
        }
    }

    @Test("The rendered paging result preserves a full 32000-byte page")
    func renderedLargePage() async throws {
        let store = ToolResultCaptureStore(durableRoot: nil)
        let task = UUID()
        let text = String(repeating: "A", count: 32000)
        let run = UUID()
        await store.capture(conversationID: task, runID: run, callID: "large",
                            toolName: "exec.shell", status: "ok", text: text, temporary: false)
        let tool = ToolResultPagingTool(store: store)
        let context = ToolContext(runID: run, cancellation: CancellationToken(), conversationID: task)
        let args = try JSONDecoder().decode(ToolResultPagingTool.Arguments.self,
            from: Data(#"{"callID":"large","maxBytes":32000}"#.utf8))
        let output = try await tool.execute(args, context: context)
        #expect(output.summary.contains(text))
        #expect(output.summary.contains("nextOffset=none"))
    }

    @Test("oversized dynamic metadata is display-bounded and never starves the page")
    func oversizedMetadataIsBounded() async throws {
        let store = ToolResultCaptureStore(durableRoot: nil)
        let task = UUID()
        let run = UUID()
        let text = String(repeating: "A", count: 32_000)
        // A dynamic MCP-style descriptor: long, multi-byte and containing
        // control characters that must not become header lines.
        let hugeName = String(repeating: "mcp.😀\n", count: 20_000)
        await store.capture(conversationID: task, runID: run, callID: "huge",
                            toolName: hugeName,
                            status: String(repeating: "s", count: 10_000),
                            text: text, temporary: false)
        let tool = ToolResultPagingTool(store: store)
        let context = ToolContext(runID: run, cancellation: CancellationToken(),
                                  conversationID: task)
        let pageArgs = try JSONDecoder().decode(
            ToolResultPagingTool.Arguments.self,
            from: Data(#"{"callID":"huge","maxBytes":32000}"#.utf8)
        )
        let page = try await tool.execute(pageArgs, context: context)
        #expect(page.summary.utf8.count <= ToolResultPagingTool.maximumRenderedBytes)
        // The complete page reached the model; a bounded header cannot make
        // nextOffset skip undelivered bytes.
        #expect(page.summary.contains(text))
        #expect(page.summary.contains("nextOffset=none"))
        let header = page.summary.split(separator: "\n", maxSplits: 1,
                                        omittingEmptySubsequences: false).first ?? ""
        #expect(header.utf8.count < 2048)
        #expect(!header.contains("mcp.😀\nmcp"), "newlines from captured metadata must be escaped")

        // The index path applies the same display bound to every row.
        let index = try await tool.execute(ToolResultPagingTool.Arguments(), context: context)
        #expect(index.summary.utf8.count <= ToolResultPagingTool.maximumRenderedBytes)
        #expect(index.summary.contains("callID=huge"))
        #expect(index.summary.contains("tool=mcp."))
    }

    @Test("Offsets inside a UTF-8 scalar never return a stuck continuation")
    func midScalarOffsetIsRejected() async {
        let store = ToolResultCaptureStore(durableRoot: nil)
        let task = UUID()
        let run = UUID()
        await store.capture(conversationID: task, runID: run, callID: "unicode",
                            toolName: "web.fetch", status: "ok", text: "中文", temporary: false)
        guard case .outOfRange = await store.page(conversationID: task, runID: run,
            callID: "unicode", offset: 1, maxBytes: 4) else {
            Issue.record("an invalid scalar boundary must not yield a stuck page")
            return
        }
    }

    @Test("retention caps are explicit, and eviction is reported")
    func capsAndEvictionAreHonest() async throws {
        let store = ToolResultCaptureStore(
            durableRoot: nil,
            caps: .init(perResultBytes: 64, perTaskBytes: 20_000, perTaskResults: 2)
        )
        let task = UUID()
        let run = UUID()
        let long = String(repeating: "字", count: 100)
        await store.capture(conversationID: task, runID: run, callID: "big",
                            toolName: "web.fetch", status: "ok", text: long, temporary: false)
        guard case .page(let truncated) = await store.page(
            conversationID: task, runID: run, callID: "big", offset: 0, maxBytes: 64
        ) else {
            Issue.record("expected the leading bytes to be retained")
            return
        }
        #expect(truncated.capture.retentionTruncated)
        #expect(truncated.totalBytes <= 64)

        for index in 0..<3 {
            await store.capture(conversationID: task, runID: run, callID: "call_\(index)",
                                toolName: "exec.shell", status: "ok", text: "output \(index)",
                                temporary: false)
        }
        // The two newest survive; the oldest is evicted and said so.
        if case .missing(_, let reason) = await store.page(
            conversationID: task, runID: run, callID: "call_0", offset: 0, maxBytes: 32
        ) {
            #expect(reason.contains("evicted"))
        } else {
            Issue.record("expected the evicted call to be missing")
        }
        if case .index(let rows, let evicted) = await store.index(conversationID: task, runID: run) {
            #expect(rows.count == 2)
            #expect(evicted >= 1)
        } else {
            Issue.record("expected an index")
        }
    }

    @Test("captures are task-scoped and never readable across conversations")
    func foreignTaskCannotReadCaptures() async throws {
        let store = ToolResultCaptureStore(durableRoot: nil)
        let owner = UUID()
        let other = UUID()
        let run = UUID()
        await store.capture(conversationID: owner, runID: run, callID: "call_secret",
                            toolName: "exec.shell", status: "ok", text: "owned bytes", temporary: false)
        if case .missing(_, let reason) = await store.page(
            conversationID: other, runID: run, callID: "call_secret", offset: 0, maxBytes: 64
        ) {
            #expect(!reason.contains("owned bytes"))
        } else {
            Issue.record("a foreign conversation must not read another task's capture")
        }
        if case .page(let page) = await store.page(
            conversationID: owner, runID: run, callID: "call_secret", offset: 0, maxBytes: 64
        ) {
            #expect(page.text == "owned bytes")
        } else {
            Issue.record("the owning task keeps access")
        }
    }

    @Test("a temporary conversation is RAM-only even with a durable root")
    func temporaryConversationStaysInRAM() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = UUID()
        let run = UUID()
        let store = ToolResultCaptureStore(durableRoot: root)
        await store.capture(conversationID: task, runID: run, callID: "call_temp",
                            toolName: "exec.shell", status: "ok", text: "ephemeral bytes",
                            temporary: true)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).isEmpty,
                "no per-task directory is created for a temporary conversation")
        // A different process (new store) sees nothing: the bytes were never
        // written for a temporary conversation.
        let later = ToolResultCaptureStore(durableRoot: root)
        if case .missing = await later.page(conversationID: task, runID: run,
                                            callID: "call_temp", offset: 0, maxBytes: 32) {
        } else {
            Issue.record("temporary captures must not survive the runtime")
        }
        // A runtime resolves a nil-root store for a temporary conversation.
        // Even when an owned directory already exists for that task (for
        // example an orphan from a crashed ordinary run), that store must not
        // open it.
        await store.capture(conversationID: task, runID: run, callID: "ordinary",
                            toolName: "exec.shell", status: "ok", text: "durable bytes",
                            temporary: false)
        let temporaryStore = ToolResultCaptureStore.shared(durableRoot: nil)
        if case .missing = await temporaryStore.page(conversationID: task, runID: run,
                                                     callID: "ordinary", offset: 0, maxBytes: 32) {
        } else {
            Issue.record("a temporary runtime must never read a durable capture directory")
        }
    }

    @Test("durable captures survive a store recreation and are purged with the task")
    func durableCapturesAndTaskCleanup() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = UUID()
        let run = UUID()
        let first = ToolResultCaptureStore(durableRoot: root)
        await first.capture(conversationID: task, runID: run, callID: "call_x",
                            toolName: "exec.shell", status: "ok", text: "durable bytes",
                            temporary: false)
        let second = ToolResultCaptureStore(durableRoot: root)
        guard case .page(let restored) = await second.page(
            conversationID: task, runID: run, callID: "call_x", offset: 0, maxBytes: 64
        ) else {
            Issue.record("expected the durable capture to be readable after recreation")
            return
        }
        #expect(restored.text == "durable bytes")
        #expect(restored.restoredFromDisk)
        #expect(restored.capture.durability == .durable)
        #expect(await second.purge(conversationID: task).succeeded)
        if case .missing = await second.page(conversationID: task, runID: run,
                                             callID: "call_x", offset: 0, maxBytes: 64) {
        } else {
            Issue.record("purge must remove the capture")
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(task.uuidString).path))
        // A late settlement after the deletion fence is ignored and cannot
        // recreate the owned directory.
        await second.capture(conversationID: task, runID: run, callID: "late",
                             toolName: "exec.shell", status: "ok", text: "late bytes",
                             temporary: false)
        if case .missing = await second.page(conversationID: task, runID: run,
                                             callID: "late", offset: 0, maxBytes: 64) {
        } else {
            Issue.record("a fenced task must not accept a late capture")
        }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(task.uuidString).path))
    }

    @Test("execution truncation and retention/compaction are reported distinctly")
    func truncationProvenanceIsExplicit() async throws {
        let store = ToolResultCaptureStore(durableRoot: nil)
        let task = UUID()
        let run = UUID()
        await store.capture(conversationID: task, runID: run, callID: "call_t",
                            toolName: "exec.shell", status: "ok",
                            text: "exit=0\n--- stdout ---\npartial\n[output truncated]",
                            temporary: false, executionReportedTruncation: true)
        let tool = ToolResultPagingTool(store: store)
        let context = ToolContext(runID: run, toolCallID: "read", cancellation: CancellationToken(),
                                  conversationID: task)
        let args = try JSONDecoder().decode(
            ToolResultPagingTool.Arguments.self,
            from: Data(#"{"callID":"call_t"}"#.utf8)
        )
        let output = try await tool.execute(args, context: context)
        #expect(output.summary.contains("capture=executionOutputTruncated"))
        #expect(output.summary.contains("captureNote="))
        #expect(output.summary.contains("contextNote="))
        #expect(output.summary.contains("partial"))
        #expect(!output.summary.contains("retentionNote="))
        #expect(output.summary.contains("persistence=memory-only-no-durable-root"))
    }

    @Test("the paging tool refuses foreign tasks and validates bounds")
    func pagingToolOwnershipAndValidation() async throws {
        let store = ToolResultCaptureStore(durableRoot: nil)
        let owner = UUID()
        let run = UUID()
        await store.capture(conversationID: owner, runID: run, callID: "call_z",
                            toolName: "exec.shell", status: "ok", text: "abc", temporary: false)
        let tool = ToolResultPagingTool(store: store)
        let foreign = ToolContext(runID: run, cancellation: CancellationToken(), conversationID: UUID())
        let args = try JSONDecoder().decode(
            ToolResultPagingTool.Arguments.self, from: Data(#"{"callID":"call_z"}"#.utf8)
        )
        let denied = try await tool.execute(args, context: foreign)
        #expect(denied.exitStatus == 66)
        #expect(denied.summary.contains("status=missing"))

        // The same task but a different run is also outside this read's scope.
        let otherRun = ToolContext(runID: UUID(), cancellation: CancellationToken(),
                                   conversationID: owner)
        let crossRun = try await tool.execute(args, context: otherRun)
        #expect(crossRun.exitStatus == 66)
        #expect(crossRun.summary.contains("current run"))

        let unbounded = try JSONDecoder().decode(
            ToolResultPagingTool.Arguments.self,
            from: Data(#"{"callID":"call_z","maxBytes":100000}"#.utf8)
        )
        #expect(throws: (any Error).self) { try tool.validate(unbounded) }
        let negative = try JSONDecoder().decode(
            ToolResultPagingTool.Arguments.self,
            from: Data(#"{"callID":"call_z","offset":-1}"#.utf8)
        )
        #expect(throws: (any Error).self) { try tool.validate(negative) }
        let control = try JSONDecoder().decode(
            ToolResultPagingTool.Arguments.self,
            from: Data(#"{"callID":"bad\u0001id"}"#.utf8)
        )
        #expect(throws: (any Error).self) { try tool.validate(control) }

        let noTask = ToolContext(runID: run, cancellation: CancellationToken())
        let unbound = try await tool.execute(args, context: noTask)
        #expect(unbound.summary.contains("no-task-binding"))
    }

    // MARK: - Run identity

    @Test("same task, two runs and a reused call id never cross-read or overwrite")
    func runCollisionIsolation() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = UUID()
        let runA = UUID()
        let runB = UUID()
        let store = ToolResultCaptureStore(durableRoot: root)
        await store.capture(conversationID: task, runID: runA, callID: "call_1",
                            toolName: "exec.shell", status: "ok", text: "run-A output",
                            temporary: false)
        await store.capture(conversationID: task, runID: runB, callID: "call_1",
                            toolName: "exec.shell", status: "ok", text: "run-B output",
                            temporary: false)

        if case .page(let page) = await store.page(
            conversationID: task, runID: runA, callID: "call_1", offset: 0, maxBytes: 64
        ) {
            #expect(page.text == "run-A output")
        } else {
            Issue.record("run A must read its own capture")
        }
        if case .page(let page) = await store.page(
            conversationID: task, runID: runB, callID: "call_1", offset: 0, maxBytes: 64
        ) {
            #expect(page.text == "run-B output")
        } else {
            Issue.record("run B must read its own capture")
        }
        // The durable identity is run-qualified: two distinct records on disk.
        let directory = root.appendingPathComponent(task.uuidString)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(files.count == 2)

        // A fresh process (restart) preserves the same run scoping in both
        // page and index.
        let restarted = ToolResultCaptureStore(durableRoot: root)
        if case .index(let rows, _) = await restarted.index(conversationID: task, runID: runA) {
            #expect(rows.map(\.callID) == ["call_1"])
        } else {
            Issue.record("expected the run-A index")
        }
        if case .page(let page) = await restarted.page(
            conversationID: task, runID: runB, callID: "call_1", offset: 0, maxBytes: 64
        ) {
            #expect(page.text == "run-B output")
            #expect(page.restoredFromDisk)
        } else {
            Issue.record("run B's durable record must survive the restart")
        }

        // Within one run a reused call id is the explicit latest-settled
        // convenience contract, not an older-occurrence archive.
        await store.capture(conversationID: task, runID: runA, callID: "call_1",
                            toolName: "exec.shell", status: "ok", text: "run-A latest",
                            temporary: false)
        if case .page(let page) = await store.page(
            conversationID: task, runID: runA, callID: "call_1", offset: 0, maxBytes: 64
        ) {
            #expect(page.text == "run-A latest")
        } else {
            Issue.record("the latest same-run settlement must win")
        }
        if case .index(let rows, _) = await store.index(conversationID: task, runID: runA) {
            #expect(rows.count == 1)
        } else {
            Issue.record("expected one retained row for run A")
        }
    }

    @Test("a restarted index applies the same run filter and matches page")
    func restartIndexMatchesPage() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = UUID()
        let runA = UUID()
        let runB = UUID()
        let writer = ToolResultCaptureStore(durableRoot: root)
        await writer.capture(conversationID: task, runID: runA, callID: "a_1",
                             toolName: "exec.shell", status: "ok", text: "A1", temporary: false)
        await writer.capture(conversationID: task, runID: runA, callID: "a_2",
                             toolName: "web.fetch", status: "ok", text: "A2", temporary: false)
        await writer.capture(conversationID: task, runID: runB, callID: "b_1",
                             toolName: "exec.shell", status: "ok", text: "B1", temporary: false)
        let reader = ToolResultCaptureStore(durableRoot: root)
        guard case .index(let rows, _) = await reader.index(conversationID: task, runID: runA) else {
            Issue.record("expected a durable index after restart")
            return
        }
        #expect(Set(rows.map(\.callID)) == ["a_1", "a_2"])
        #expect(rows.allSatisfy { $0.durability == .durable })
        guard case .index(let otherRows, _) = await reader.index(conversationID: task, runID: runB) else {
            Issue.record("expected the run-B index")
            return
        }
        #expect(otherRows.map(\.callID) == ["b_1"])
        guard case .page(let page) = await reader.page(
            conversationID: task, runID: runA, callID: "a_2", offset: 0, maxBytes: 64
        ) else {
            Issue.record("expected a durable page")
            return
        }
        #expect(page.text == "A2")
    }

    @Test("durable eviction removes exactly the owned record and never writes evicted ones")
    func durableEvictionDeletesExactRecord() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = UUID()
        let run = UUID()
        let store = ToolResultCaptureStore(
            durableRoot: root,
            caps: .init(perResultBytes: 64 * 1024, perTaskBytes: 64 * 1024, perTaskResults: 2)
        )
        await store.capture(conversationID: task, runID: run, callID: "call_0",
                            toolName: "exec.shell", status: "ok", text: "oldest", temporary: false)
        await store.capture(conversationID: task, runID: run, callID: "call_1",
                            toolName: "exec.shell", status: "ok", text: "middle", temporary: false)
        await store.capture(conversationID: task, runID: run, callID: "call_2",
                            toolName: "exec.shell", status: "ok", text: "newest", temporary: false)
        let directory = root.appendingPathComponent(task.uuidString)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(files.count == 2, "the evicted capture's exact file must be removed")
        // The writing process knows it evicted a copy and says so.
        if case .missing(_, let reason) = await store.page(
            conversationID: task, runID: run, callID: "call_0", offset: 0, maxBytes: 64
        ) {
            #expect(reason.contains("evicted"))
        } else {
            Issue.record("the writing process must report its eviction")
        }
        if case .index(let liveRows, let liveEvicted) = await store.index(
            conversationID: task, runID: run
        ) {
            #expect(liveRows.count == 2)
            #expect(liveEvicted >= 1)
        } else {
            Issue.record("expected the live index")
        }
        // A restart sees exactly the two surviving files. The evicted record
        // is gone; this process has no eviction evidence to report, so it
        // must not invent one.
        let restarted = ToolResultCaptureStore(durableRoot: root)
        if case .missing(_, let reason) = await restarted.page(
            conversationID: task, runID: run, callID: "call_0", offset: 0, maxBytes: 64
        ) {
            #expect(!reason.contains("call_0"))
        } else {
            Issue.record("an evicted record must not be readable from disk after restart")
        }
        guard case .index(let rows, let evicted) = await restarted.index(conversationID: task, runID: run) else {
            Issue.record("expected the bounded durable index")
            return
        }
        #expect(rows.count == 2)
        #expect(evicted == 0)
        if case .page(let restored) = await restarted.page(
            conversationID: task, runID: run, callID: "call_1", offset: 0, maxBytes: 64
        ) {
            #expect(restored.restoredFromDisk)
        } else {
            Issue.record("the surviving middle record must be readable after restart")
        }

        // A capture that the byte cap evicts in the same settlement must not
        // be written at all.
        let tight = ToolResultCaptureStore(
            durableRoot: root,
            caps: .init(perResultBytes: 4, perTaskBytes: 4, perTaskResults: 64)
        )
        let tightTask = UUID()
        await tight.capture(conversationID: tightTask, runID: run, callID: "first",
                            toolName: "exec.shell", status: "ok", text: "aaaa", temporary: false)
        await tight.capture(conversationID: tightTask, runID: run, callID: "second",
                            toolName: "exec.shell", status: "ok", text: "bbbb", temporary: false)
        let tightDirectory = root.appendingPathComponent(tightTask.uuidString)
        let tightFiles = (try? FileManager.default.contentsOfDirectory(atPath: tightDirectory.path)) ?? []
        #expect(tightFiles.count == 1)
        let tightReader = ToolResultCaptureStore(durableRoot: root)
        if case .missing = await tightReader.page(
            conversationID: tightTask, runID: run, callID: "first", offset: 0, maxBytes: 4
        ) {
        } else {
            Issue.record("an already-evicted capture must never be written")
        }
        if case .page(let page) = await tightReader.page(
            conversationID: tightTask, runID: run, callID: "second", offset: 0, maxBytes: 4
        ) {
            #expect(page.text == "bbbb")
        } else {
            Issue.record("the surviving capture must be durable")
        }
    }

    @Test("escape-heavy text writes a bounded record and survives a restart")
    func escapedTextDurableRoundTrip() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let task = UUID()
        let run = UUID()
        let caps = ToolResultCaptureStore.Caps(
            perResultBytes: 128 * 1024,
            perTaskBytes: 2 * 1024 * 1024,
            perTaskResults: 8
        )
        let store = ToolResultCaptureStore(durableRoot: root, caps: caps)
        // A payload that JSON would escape up to six times per byte. The old
        // read bound (perResultBytes + 16 KiB) made a successfully written
        // record silently unreadable after a restart for text like this.
        let unit = "\"\\\n\r\t\u{1}\u{2}az中文😀"
        var text = ""
        while text.utf8.count < 100_000 { text += unit }
        await store.capture(conversationID: task, runID: run, callID: "escaped",
                            toolName: "exec.shell", status: "ok", text: text, temporary: false)
        // Dynamic metadata is bounded before it reaches the durable record.
        await store.capture(conversationID: task, runID: run, callID: "meta",
                            toolName: String(repeating: "\u{1}\"\\", count: 20_000),
                            status: String(repeating: "s", count: 20_000),
                            text: "meta", temporary: false)

        let directory = root.appendingPathComponent(task.uuidString)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        #expect(files.count == 2)
        for name in files {
            let path = directory.appendingPathComponent(name).path
            let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
            #expect(size <= store.maximumEncodedRecordBytes,
                    "a written record must fit the same envelope the reader accepts")
        }

        let restarted = ToolResultCaptureStore(durableRoot: root, caps: caps)
        var offset = 0
        var rebuilt = ""
        while true {
            guard case .page(let page) = await restarted.page(
                conversationID: task, runID: run, callID: "escaped",
                offset: offset, maxBytes: 16_000
            ) else {
                Issue.record("the escape-heavy record must be readable after restart")
                return
            }
            #expect(page.restoredFromDisk)
            rebuilt += page.text
            if let next = page.nextOffset {
                #expect(next > offset)
                offset = next
            } else {
                break
            }
        }
        #expect(rebuilt == text)
        guard case .index(let rows, _) = await restarted.index(conversationID: task, runID: run) else {
            Issue.record("expected the durable index")
            return
        }
        #expect(Set(rows.map(\.callID)) == ["escaped", "meta"])
        let meta = rows.first { $0.callID == "meta" }
        #expect((meta?.toolName.utf8.count ?? .max) <= 2048,
                "the durable metadata envelope must not grow with the captured descriptor")
    }

    @Test("a durable write failure is reported as a real RAM-only state")
    func persistFailureIsReportedHonestly() async throws {
        let base = try tempRoot()
        defer { try? FileManager.default.removeItem(at: base) }
        // A regular file where the root directory should be makes every
        // create/write fail without relying on permissions.
        let blockedRoot = base.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: blockedRoot)
        let task = UUID()
        let run = UUID()
        let store = ToolResultCaptureStore(durableRoot: blockedRoot)
        await store.capture(conversationID: task, runID: run, callID: "ram",
                            toolName: "exec.shell", status: "ok", text: "in memory", temporary: false)
        guard case .page(let page) = await store.page(
            conversationID: task, runID: run, callID: "ram", offset: 0, maxBytes: 64
        ) else {
            Issue.record("the RAM copy must still be readable")
            return
        }
        #expect(page.capture.durability == .durableWriteFailed)
        #expect(!page.restoredFromDisk)
        let tool = ToolResultPagingTool(store: store)
        let context = ToolContext(runID: run, cancellation: CancellationToken(), conversationID: task)
        let args = try JSONDecoder().decode(
            ToolResultPagingTool.Arguments.self, from: Data(#"{"callID":"ram"}"#.utf8)
        )
        let output = try await tool.execute(args, context: context)
        #expect(output.summary.contains("persistence=memory-only-write-failed"))
        #expect(output.summary.contains("will not survive a restart"))
    }

    @Test("a failed durable removal keeps a retry tombstone and is retried at launch")
    func purgeFailurePersistsRetryTombstone() async throws {
        let root = try tempRoot()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                   ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        let task = UUID()
        let run = UUID()
        let store = ToolResultCaptureStore(durableRoot: root)
        await store.capture(conversationID: task, runID: run, callID: "owned",
                            toolName: "exec.shell", status: "ok", text: "owned", temporary: false)
        let directory = root.appendingPathComponent(task.uuidString)
        // Make the owned directory non-writable so recursive removal of its
        // record fails while the root (tombstone) stays writable.
        try FileManager.default.setAttributes([.posixPermissions: 0o500],
                                               ofItemAtPath: directory.path)
        let failed = await store.purge(conversationID: task)
        #expect(!failed.succeeded)
        #expect(failed.failure == .removalFailed)
        #expect(failed.retryScheduled)
        #expect(await store.pendingPurgeConversationIDs() == [task])
        // The fence is installed even though bytes remain: no late settlement
        // can re-add evidence for the deleted task.
        await store.capture(conversationID: task, runID: run, callID: "late",
                            toolName: "exec.shell", status: "ok", text: "late", temporary: false)
        if case .missing = await store.page(conversationID: task, runID: run,
                                            callID: "late", offset: 0, maxBytes: 64) {
        } else {
            Issue.record("a fenced task must not accept a late capture")
        }
        // Restore permission and let the launch-style retry finish the job.
        try FileManager.default.setAttributes([.posixPermissions: 0o755],
                                               ofItemAtPath: directory.path)
        let cleaned = await store.retryPendingPurge(conversationID: task)
        #expect(cleaned.succeeded)
        #expect(await store.pendingPurgeConversationIDs().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("one shared store actor exists per canonical durable root")
    func sharedStoreIdentity() async throws {
        let root = try tempRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = ToolResultCaptureStore.shared(durableRoot: root)
        let second = ToolResultCaptureStore.shared(durableRoot: root.standardizedFileURL)
        #expect(first === second)
        let other = ToolResultCaptureStore.shared(durableRoot: try tempRoot())
        #expect(first !== other)
        // A nil root is a temporary/unpersisted store and is intentionally
        // not shared between callers.
        let tempA = ToolResultCaptureStore.shared(durableRoot: nil)
        let tempB = ToolResultCaptureStore.shared(durableRoot: nil)
        #expect(tempA !== tempB)
        // A capture through one handle is visible through the other.
        let task = UUID()
        let run = UUID()
        await first.capture(conversationID: task, runID: run, callID: "shared",
                            toolName: "exec.shell", status: "ok", text: "one store",
                            temporary: false)
        if case .page(let page) = await second.page(
            conversationID: task, runID: run, callID: "shared", offset: 0, maxBytes: 64
        ) {
            #expect(page.text == "one store")
        } else {
            Issue.record("the shared store must expose the same retained set")
        }
    }

    @Test("a 32 KiB tools.readResult page reaches the provider wire intact")
    func pagingPageReachesProviderWire() async throws {
        let adapter = MockAdapter()
        let provider = TestFixtures.localhostProvider()
        let model = TestFixtures.testModel(providerID: provider.id)
        let executor = MockExecutor()
        executor.descriptors["test.echo"] = ToolCatalog.Descriptor(
            name: "test.echo", riskLabels: [], isSideEffecting: false
        )
        let sourceCall = try TestFixtures.toolCall(
            id: "source-call", toolName: "test.echo", arguments: "{}"
        )
        let readCall = try TestFixtures.toolCall(
            id: "page-call",
            toolName: ToolResultPagingTool.name,
            arguments: #"{"callID":"source-call","maxBytes":32000}"#
        )
        adapter.script = [
            [.toolRequest(sourceCall), .completed(.init(stopReason: .toolUse))],
            [.toolRequest(readCall), .completed(.init(stopReason: .toolUse))],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let large = String(repeating: "A", count: 40_000)
        executor.results = [ToolResult(
            callID: sourceCall.id,
            status: .ok,
            outputSummary: String(repeating: "B", count: 4_000),
            outputDigest: "source-digest",
            capturedOutput: large
        )]
        let checkpointStore = MockCheckpointStore()
        let runtime = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                provider: provider,
                model: model,
                pauseTimeout: 0.1,
                providerRetryBaseDelay: 0,
                providerRetryMaxDelay: 0,
                providerRetryJitterRatio: 0
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: executor,
            auditSink: MockAuditSink(),
            checkpointStore: checkpointStore,
            sink: MockSink()
        )

        try await runtime.start(goal: "page the large result")

        #expect(adapter.requests.count == 3)
        // Ordinary results keep the existing 2 KiB compaction.
        let ordinary = adapter.requests[1].toolResults
            .first { $0.callID == sourceCall.id }?.output ?? ""
        #expect(ordinary.contains("[middle of tool output compacted]"))
        #expect(ordinary.count < 4_000)
        // The explicit page crosses the provider boundary in full: the
        // dispatcher must not compact it a second time and make nextOffset
        // point past bytes the model never received.
        let page = adapter.requests[2].toolResults
            .first { $0.callID == readCall.id }?.output ?? ""
        #expect(page.count > 32_000)
        // The wire output prepends the runtime-authored provenance envelope;
        // the page body itself must be complete after its separator.
        let expectedBody = String(repeating: "A", count: 32_000)
        #expect(page.contains(expectedBody))
        if let separator = page.range(of: "\n--- output ---\n") {
            #expect(page[separator.upperBound...].hasPrefix(expectedBody))
        } else {
            Issue.record("the paging page marker is missing from the wire output")
        }
        #expect(page.contains("nextOffset=32000"))
        #expect(page.contains("persistence=memory-only-no-durable-root"))

        // The durable pending projection must keep the same page, or a
        // restart would resume with a 2 KiB excerpt while the header still
        // advanced the cursor. Find the settlement checkpoint that owns the
        // page result and resume from it.
        let settlement = try #require(checkpointStore.saved.last { checkpoint in
            checkpoint.pendingToolResults.contains { $0.callID == readCall.id }
        })
        let persistedPage = settlement.pendingToolResults.first {
            $0.callID == readCall.id
        }?.outputSummary ?? ""
        #expect(persistedPage.contains(expectedBody))
        #expect(persistedPage.contains("nextOffset=32000"))

        var resumable = settlement
        // This test starts a fresh run identity; the dispatch-envelope guard
        // belongs to the original run boundary. Clearing only the envelope
        // keeps the durable pending call/result reconstruction under test.
        resumable.providerDispatchEnvelope = nil
        resumable.providerDispatchRequest = nil
        let resumeAdapter = MockAdapter()
        resumeAdapter.script = [[
            .textDelta(.init(text: "done")),
            .completed(.init(stopReason: .endTurn))
        ]]
        let resumed = FloeAgentRuntime(
            configuration: FloeAgentRuntime.Configuration(
                provider: provider,
                model: model,
                pauseTimeout: 0.1,
                providerRetryBaseDelay: 0,
                providerRetryMaxDelay: 0,
                providerRetryJitterRatio: 0
            ),
            adapter: resumeAdapter,
            policy: HumanApprovalPolicy(),
            executor: MockExecutor(),
            auditSink: MockAuditSink(),
            checkpointStore: MockCheckpointStore(),
            sink: MockSink()
        )
        try await resumed.resume(from: resumable)
        let resumedPage = resumeAdapter.requests.first?.toolResults
            .first { $0.callID == readCall.id }?.output ?? ""
        #expect(resumedPage.contains(expectedBody))
        #expect(resumedPage.contains("nextOffset=32000"))
    }

    @Test("exact-name discovery returns the complete callable schema")
    func exactNameDiscoveryCarriesFullSchema() throws {
        func descriptor(_ name: String) -> ToolCatalog.Descriptor {
            .init(name: name,
                  toolDescription: "Run \(name) for the test.",
                  parametersJSON: #"{"type":"object","properties":{"path":{"type":"string"}},"required":["path"],"additionalProperties":false}"#,
                  riskLabels: [], isSideEffecting: false)
        }
        let offered = [descriptor("exec.shell"), descriptor("web.fetch"), descriptor("document.read")]
        let exact = ToolDiscovery.exactNameMatches(["exec.shell"], descriptors: offered)
        #expect(exact.map(\.name) == ["exec.shell"])
        let section = ToolDiscovery.exactSchemaSection(exact, wireSafeNames: false)
        #expect(section.contains("Complete schema for exec.shell"))
        #expect(section.contains(#""required":["path"]"#))
        // A fuzzy capability query must not pretend to be an exact schema hit.
        #expect(ToolDiscovery.exactNameMatches(["run a shell command"], descriptors: offered).isEmpty)
        // The paging tool is offered in ordinary and temporary conversations.
        for publicWebOnly in [true, false] {
            let descriptors = ToolDiscovery.runtimeDescriptors(publicWebOnly: publicWebOnly)
            #expect(descriptors.map(\.name).contains(ToolResultPagingTool.name))
        }
    }

    @Test("capture-truncation markers are recognized without confusing compaction")
    func truncationMarkerDetection() {
        #expect(FloeAgentRuntime.reportsExecutionCaptureTruncation("exit=0 stdoutTruncated\n..."))
        #expect(FloeAgentRuntime.reportsExecutionCaptureTruncation("...\n[output truncated]"))
        #expect(!FloeAgentRuntime.reportsExecutionCaptureTruncation(
            "head\n[middle of tool output compacted]\ntail\n[tool output compacted; originalBytes=9000; digest=ab]"
        ))
    }
}

@Suite("Tool call argument budget")
struct ToolCallArgumentBudgetTests {
    private func objectPayload(_ bytes: Int, key: String = "command") throws -> Data {
        try JSONSerialization.data(withJSONObject: [key: String(repeating: "a", count: bytes)])
    }

    @Test("exec.shell and its wire alias accept real >1 MiB script arguments")
    func shellArgumentsAreUncapped() throws {
        for name in ["exec.shell", "exec_shell"] {
            let arguments = try objectPayload(1_200_000)
            #expect(arguments.count > 1_048_576)
            let call = try ToolCall(id: "call_shell", toolName: name,
                                    argumentsJSON: arguments, scope: .local)
            #expect(call.argumentsJSON.count == arguments.count)
            #expect(call.toolName == name)
        }
    }

    @Test("Background Shell wrappers accept long scripts without widening other jobs")
    func shellJobEnvelopeIsSelective() throws {
        let inner = String(decoding: try objectPayload(1_200_000), as: UTF8.self)
        for name in ["jobs.submit", "jobs_submit"] {
            let bytes = try JSONSerialization.data(withJSONObject:
                ["tool": "exec.shell", "arguments": inner, "purpose": "Long script"])
            let call = try ToolCall(id: "background-shell", toolName: name,
                                    argumentsJSON: bytes, scope: .local)
            #expect(call.argumentsJSON == bytes)
            let other = try JSONSerialization.data(withJSONObject:
                ["tool": "web.fetch", "arguments": inner])
            #expect(throws: (any Error).self) {
                _ = try ToolCall(id: "background-other", toolName: name,
                                 argumentsJSON: other, scope: .local)
            }
        }
    }

    @Test("Oversized job metadata or a forged Shell payload cannot bypass the wrapper guard")
    func oversizedJobMetadataIsRejected() throws {
        let inner = String(decoding: try objectPayload(100_000), as: UTF8.self)
        let cases: [[String: Any]] = [
            ["tool": "exec.shell", "arguments": inner, "purpose": String(repeating: "x", count: 241)],
            ["tool": "exec.shell", "arguments": inner, "extra": "unexpected"],
            ["tool": "exec.shell", "arguments": ["command": String(repeating: "x", count: 100_000)]],
            ["tool": "exec.shell", "arguments": inner, "wait": ["unexpected": true]]
        ]
        for object in cases {
            let bytes = try JSONSerialization.data(withJSONObject: object)
            #expect(throws: (any Error).self) {
                _ = try ToolCall(id: "forged-job", toolName: "jobs.submit",
                                 argumentsJSON: bytes, scope: .local)
            }
        }
    }

    @Test("every non-shell tool keeps its application byte bound")
    func nonShellToolsStayBounded() throws {
        for name in ["exec.localPython", "web.fetch", "jobs.submit"] {
            let arguments = try objectPayload(toolArgumentsMaxBytes + 1)
            #expect(throws: (any Error).self) {
                _ = try ToolCall(id: "call_other", toolName: name,
                                 argumentsJSON: arguments, scope: .local)
            }
        }
    }

    @Test("the shell exemption never bypasses the JSON-object contract")
    func shellStillRequiresJSONObject() throws {
        let hugeArray = try JSONSerialization.data(
            withJSONObject: Array(repeating: "a", count: 800_000)
        )
        #expect(throws: (any Error).self) {
            _ = try ToolCall(id: "call_array", toolName: "exec.shell",
                             argumentsJSON: hugeArray, scope: .local)
        }
        #expect(throws: (any Error).self) {
            _ = try ToolCall(id: "call_invalid", toolName: "exec.shell",
                             argumentsJSON: Data("{not json".utf8), scope: .local)
        }
        // Ordinary shell-shaped objects still construct normally.
        let call = try ToolCall(id: "call_ok", toolName: "exec.shell",
                                argumentsJSON: try objectPayload(32), scope: .local)
        #expect(call.id == "call_ok")
    }
}

@Suite("ToolResult transient capture identity")
struct ToolResultTransientCaptureTests {
    private func result(capture: String?) -> ToolResult {
        ToolResult(
            callID: "call_identity",
            status: .ok,
            outputSummary: "bounded summary",
            outputDigest: "digest",
            capturedOutput: capture,
            capturedOutputTruncated: capture != nil
        )
    }

    @Test("codable round-trip excludes the capture and preserves result identity")
    func codecRoundTripExcludesCapture() throws {
        let large = String(repeating: "Z", count: 2 * 1024 * 1024)
        let original = result(capture: large)
        let data = try JSONEncoder().encode(original)
        #expect(data.count < 16 * 1024, "the transient capture must not enter the durable encoding")
        let decoded = try JSONDecoder().decode(ToolResult.self, from: data)
        #expect(decoded.capturedOutput == nil)
        #expect(decoded.capturedOutputTruncated == false)
        // Equality is over durable fields only, so a decoded result equals its
        // source even though the transient capture was not encoded.
        #expect(decoded == original)
        let reencoded = try JSONEncoder().encode(decoded)
        #expect(reencoded == data)
    }

    @Test("equality and hashing ignore transient capture data")
    func equalityAndHashingIgnoreCapture() {
        let without = result(capture: nil)
        let small = result(capture: "small")
        let large = result(capture: String(repeating: "Q", count: 2 * 1024 * 1024))
        #expect(small == large)
        #expect(without == large)
        #expect(Set([without, small, large]).count == 1)
        #expect(without.hashValue == large.hashValue)
    }

    @Test("durable projection drops capture and keeps the settled fields")
    func durableProjectionDropsCapture() {
        let original = result(capture: "captured bytes")
        let projected = original.durableProjection()
        #expect(projected.capturedOutput == nil)
        #expect(projected.capturedOutputTruncated == false)
        #expect(projected == original)
        #expect(projected.callID == original.callID)
        #expect(projected.outputSummary == original.outputSummary)
        #expect(projected.outputDigest == original.outputDigest)
    }
}
