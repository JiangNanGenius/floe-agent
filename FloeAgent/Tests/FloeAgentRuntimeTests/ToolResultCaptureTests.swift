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

        // The same task in another run (a resumed run or a delegated child)
        // can read the task's retained evidence by its stable ref/call id.
        let otherRun = ToolContext(runID: UUID(), cancellation: CancellationToken(),
                                   conversationID: owner)
        let crossRun = try await tool.execute(args, context: otherRun)
        #expect(crossRun.exitStatus == 0)
        #expect(crossRun.summary.contains("status=ok"))
        #expect(crossRun.summary.contains("abc"))
        #expect(crossRun.summary.contains("run="))
        // A different task still cannot.
        let foreignTask = ToolContext(runID: run, cancellation: CancellationToken(),
                                      conversationID: UUID())
        let foreignDenied = try await tool.execute(args, context: foreignTask)
        #expect(foreignDenied.exitStatus == 66)
        #expect(foreignDenied.summary.contains("status=missing"))

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
        // The complete 40 KiB post-redaction capture fits this 128K model, so
        // the first continuation receives it whole instead of an arbitrary
        // 2 KiB excerpt.
        let ordinary = adapter.requests[1].toolResults
            .first { $0.callID == sourceCall.id }?.output ?? ""
        #expect(!ordinary.contains("[middle of tool output compacted]"))
        #expect(ordinary.contains(large))
        #expect(ordinary.utf8.count >= large.utf8.count)
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

@Suite("Budget-aware tool result selection")
struct ToolResultSelectionTests {
    private func input(
        _ callID: String,
        text: String,
        ref: String? = nil,
        paging: Bool = false,
        captureUnavailable: Bool = false
    ) -> ToolResultSelectionInput {
        ToolResultSelectionInput(
            callID: callID,
            toolName: paging ? ToolResultPagingTool.name : "exec.shell",
            text: text,
            ref: ref,
            totalBytes: text.utf8.count,
            captureUnavailable: captureUnavailable,
            isPagingPage: paging
        )
    }

    @Test("Complete results are sent whole when the real budget fits")
    func completeWhenFits() {
        let text = String(repeating: "A", count: 50_000)
        let plan = ToolResultPlanner.plan(
            inputs: [input("c1", text: text, ref: "tr_0123456789abcdef01234567")],
            budgetBytes: 100_000
        )
        #expect(plan.allComplete)
        #expect(plan.items[0].output == text)
        #expect(plan.items[0].complete)
    }

    @Test("An over-budget result keeps a head/tail excerpt with its stable ref and length")
    func excerptNamesRefAndLength() {
        let text = String(repeating: "B", count: 50_000)
        let plan = ToolResultPlanner.plan(
            inputs: [input("c1", text: text, ref: "tr_0123456789abcdef01234567")],
            budgetBytes: 4_000
        )
        let item = plan.items[0]
        #expect(!plan.allComplete)
        #expect(item.excerpted)
        #expect(item.output.contains("tr_0123456789abcdef01234567"))
        #expect(item.output.contains("of 50000 bytes"))
        #expect(item.output.utf8.count <= 4_000)
        #expect(item.output.hasPrefix("BBBB"))
    }

    @Test("A paging page is never partially cut")
    func pagingPageIsNeverPartiallyCut() {
        let text = String(repeating: "P", count: 32_000)
        let plan = ToolResultPlanner.plan(
            inputs: [input("page", text: text, paging: true)],
            budgetBytes: 2_000
        )
        #expect(plan.items[0].pointerOnly)
        #expect(!plan.items[0].output.contains(String(repeating: "P", count: 100)))
        #expect(plan.items[0].output.contains("not repeated"))
    }

    @Test("Excerpt continuation starts after the head, without skipping the unseen middle")
    func excerptCursorDoesNotCountTail() async throws {
        let text = String(repeating: "中文段落0123456789\n", count: 1_000)
        let store = ToolResultCaptureStore(durableRoot: nil)
        let task = UUID(), run = UUID()
        await store.capture(conversationID: task, runID: run, callID: "cursor",
                            toolName: "exec.shell", status: "ok", text: text, temporary: false)
        let ref = ToolResultCaptureStore.reference(runID: run, callID: "cursor")
        let output = ToolResultPlanner.plan(
            inputs: [input("cursor", text: text, ref: ref)], budgetBytes: 4_000
        ).items[0].output
        let marker = try #require(output.range(of: "\n[tool output truncated for this request:"))
        let head = String(output[..<marker.lowerBound])
        let offsetStart = try #require(output.range(of: #""offset":"#)).upperBound
        let cursor = try #require(Int(output[offsetStart...].prefix(while: \.isNumber)))
        #expect(cursor == head.utf8.count)
        var rebuilt = head
        var offset = cursor
        while case .page(let page) = await store.page(
            conversationID: task, ref: ref, offset: offset, maxBytes: 1_024
        ) {
            rebuilt += page.text
            guard let next = page.nextOffset else { break }
            offset = next
        }
        #expect(rebuilt == text)
    }

    @Test("A lost capture is explicitly unrecoverable rather than promised")
    func lostCaptureIsExplicit() {
        let plan = ToolResultPlanner.plan(
            inputs: [input("lost", text: String(repeating: "x", count: 5_000), captureUnavailable: true)],
            budgetBytes: 1_000
        )
        #expect(plan.items[0].output.localizedCaseInsensitiveContains("not retained"))
        #expect(!plan.items[0].output.contains("read it with"))
    }

    @Test("Retention truncation stays explicit even when all retained bytes fit")
    func fittingRetainedPrefixStillReportsMissingOriginal() {
        var retained = input("short", text: "retained prefix", ref: "tr_retained_prefix")
        retained.captureTruncated = true
        let full = ToolResultPlanner.plan(inputs: [retained], budgetBytes: 4_000)
        #expect(full.items[0].output.hasPrefix("retained prefix"))
        #expect(full.items[0].output.contains("retention truncated"))
        #expect(full.items[0].output.contains("tr_retained_prefix"))
        #expect(full.sentBytes == full.items[0].output.utf8.count)
        #expect(full.sentBytes <= full.budgetBytes)
    }

    @Test("A saved summary reads its retained original from byte zero")
    func projectedSummaryDoesNotInventSourceOffset() {
        var projection = input("saved", text: String(repeating: "Summary text. ", count: 800), ref: "tr_saved")
        projection.continuationOffset = 0
        let plan = ToolResultPlanner.plan(inputs: [projection], budgetBytes: 4_000)
        #expect(plan.items[0].output.contains(#""offset":0"#))
        #expect(plan.items[0].output.contains("tr_saved"))
    }

    @Test("Schema admission keeps definitions complete and defers the rest")
    func schemaAdmissionIsComplete() {
        func descriptor(_ name: String, schema: String) -> ToolCatalog.Descriptor {
            .init(name: name, toolDescription: "d", parametersJSON: schema,
                  riskLabels: [], isSideEffecting: false)
        }
        let small = descriptor("tools.search", schema: #"{"type":"object"}"#)
        let wide = descriptor(
            "wide.tool",
            schema: #"{"type":"object","properties":{"a":{"type":"object","properties":{"b":{"type":"string","enum":["x","y"]}}}},"required":["a"]}"#
        )
        let plan = ToolSchemaOfferPlanner.plan(
            descriptors: [wide, small],
            tokenBudget: 30,
            alwaysKeep: ["tools.search"]
        )
        #expect(plan.offered.map(\.name) == ["tools.search"])
        #expect(plan.deferred.contains("wide.tool") || plan.oversized.contains("wide.tool"))
        #expect(plan.offered.allSatisfy { !$0.parametersJSON.isEmpty })
    }

    @Test("A large explicitly loaded CAD schema is admitted whole ahead of optional core")
    func largeLoadedSchemaSurvivesDynamicBudget() {
        func descriptor(_ name: String, description: String, schema: String) -> ToolCatalog.Descriptor {
            .init(name: name, toolDescription: description, parametersJSON: schema,
                  riskLabels: [], isSideEffecting: false)
        }
        let cadSchema = #"{"type":"object","properties":{"operation":{"enum":[""# +
            String(repeating: "x", count: 14_000) +
            #""]},"required":["operation"],"additionalProperties":false}"#
        let cad = descriptor(
            "cad.document",
            description: String(repeating: "drawing operation ", count: 180),
            schema: cadSchema
        )
        let shell = descriptor("exec.shell", description: "shell", schema: #"{"type":"object","properties":{"command":{"type":"string"}},"required":["command"]}"#)
        let skill = descriptor("skill.read", description: "skill", schema: #"{"type":"object","properties":{"name":{"type":"string"}},"required":["name"]}"#)
        #expect(cad.parametersJSON.utf8.count > 14_000)

        // Explicitly loaded CAD ranks before optional core in the dispatch
        // candidate order.
        let ordered = ToolSchemaOfferPlanner.prioritized(
            [shell, skill, cad],
            priority: ["cad.document", "exec.shell"],
            pinned: []
        )
        #expect(ordered.first?.name == "cad.document")

        // A large cloud/local window carries the complete schema.
        let largeBudget = ToolSchemaOfferPlanner.availableTokenBudget(
            contextWindowTokens: 128_000,
            reservedOutputTokens: 4_096,
            messageTokens: 9_000,
            imageTokens: 0,
            replayTokens: 0,
            toolResultReserveTokens: 8_192
        )
        let large = ToolSchemaOfferPlanner.plan(
            descriptors: ordered,
            tokenBudget: largeBudget,
            alwaysKeep: ["tools.search"]
        )
        #expect(large.offered.contains { $0.name == "cad.document" })
        #expect(large.offered.first { $0.name == "cad.document" }?.parametersJSON == cad.parametersJSON)

        // If only the CAD definition fits, it is still admitted before the
        // optional core descriptors rather than being silently dropped.
        let cadOnlyBudget = ToolSchemaOfferPlanner.tokenCost(cad)
            + ToolSchemaOfferPlanner.tokenCost(descriptor(
                "tools.search", description: "search", schema: #"{"type":"object"}"#
            ))
        let tight = ToolSchemaOfferPlanner.plan(
            descriptors: ordered,
            tokenBudget: cadOnlyBudget,
            alwaysKeep: ["tools.search"]
        )
        #expect(tight.offered.contains { $0.name == "cad.document" })
        #expect(!tight.offered.contains { $0.name == "exec.shell" })
    }

    @Test("The request sizer charges messages, schemas, images and output reserve")
    func requestSizerChargesEverySection() {
        let messages = [
            ProviderMessage(role: "system", content: [.text(String(repeating: "s", count: 3_000))]),
            ProviderMessage(role: "user", content: [
                .text("hello"),
                .imageData(mimeType: "image/png", base64: String(repeating: "A", count: 4_000))
            ])
        ]
        let size = ProviderRequestSizer.measure(
            messages: messages,
            schemas: [ToolSchemaDescriptor(
                name: "t", description: "d",
                parametersJSON: String(repeating: "p", count: 3_000)
            )],
            contextWindowTokens: 8_000,
            reservedOutputTokens: 1_000
        )
        #expect(size.messageTokens > 1_000)
        #expect(size.schemaTokens > 1_000)
        #expect(size.reservedOutputTokens == 1_000)
        #expect(size.availableToolResultTokens < 8_000)
    }
}

@Suite("Explicit credential argument sanitisation")
struct ToolArgumentSanitizerTests {
    @Test("Cookie object/array and storage setter values are scrubbed with metadata preserved")
    func cookieShapesAreScrubbed() throws {
        let json = #"{"url":"https://example.test","headers":{"Cookie":"a=1","Authorization":"Bearer t"},"cookie":{"name":"session","value":"SECRET2","domain":"example.test","path":"/"},"cookies":[{"name":"x","value":"SECRET3"}],"storage":{"area":"localStorage","key":"token","value":"SECRET4"}}"#
        let redacted = ToolArgumentSanitizer.redactedArgumentText(json)
        #expect(!redacted.contains("SECRET2"))
        #expect(!redacted.contains("SECRET3"))
        #expect(!redacted.contains("SECRET4"))
        #expect(!redacted.contains("Bearer t"))
        #expect(redacted.contains("example.test"))
        #expect(redacted.contains("localStorage"))
        #expect(redacted.contains("\"name\":\"session\""))
        #expect(ToolArgumentSanitizer.containsSensitiveValues(Data(json.utf8)))
    }

    @Test("Actual browser tool shapes: JSON-string headers/cookies and storage set")
    func browserWireShapesAreScrubbed() {
        let headers = #"{"Cookie":"sid=BROWSER_SECRET","Accept":"application/json"}"#
        let cookies = #"[{"name":"sid","value":"BROWSER_SECRET2","domain":"example.test","path":"/"}]"#
        let arguments: [String: Any] = [
            "url": "https://example.test",
            "headers": headers,
            "cookies": cookies
        ]
        let data = try! JSONSerialization.data(withJSONObject: arguments)
        let redacted = ToolArgumentSanitizer.redactedArgumentText(
            String(decoding: data, as: UTF8.self),
            toolName: "browser.cookies"
        )
        #expect(!redacted.contains("BROWSER_SECRET"))
        #expect(redacted.contains("application/json"))
        #expect(redacted.contains("example.test"))
        #expect(ToolArgumentSanitizer.containsSensitiveValues(data, toolName: "browser.cookies"))

        let storage = Data(#"{"action":"set","key":"token","value":"BROWSER_SECRET3"}"#.utf8)
        let storageRedacted = ToolArgumentSanitizer.redactedArgumentText(
            String(decoding: storage, as: UTF8.self),
            toolName: "browser.storage"
        )
        #expect(!storageRedacted.contains("BROWSER_SECRET3"))
        #expect(storageRedacted.contains("\"key\":\"token\""))
        #expect(ToolArgumentSanitizer.containsSensitiveValues(storage, toolName: "browser.storage"))

        // The same {action,key,value} shape for CAD is ordinary data.
        let cad = Data(#"{"action":"set","key":"foo","value":"bar"}"#.utf8)
        let cadText = ToolArgumentSanitizer.redactedArgumentText(
            String(decoding: cad, as: UTF8.self),
            toolName: "cad.document"
        )
        #expect(cadText.contains("\"value\":\"bar\""))
        #expect(!ToolArgumentSanitizer.containsSensitiveValues(cad, toolName: "cad.document"))
    }

    @Test("A harmless header container cannot hide credentials in another argument")
    func harmlessContainersDoNotShortCircuitSensitiveDetection() throws {
        for container in ["headers", "header", "localStorage"] {
            let arguments: [String: Any] = [
                container: "{\"Accept\":\"application/json\"}",
                "body": ["access_token": "DO_NOT_REPLAY"]
            ]
            let data = try JSONSerialization.data(withJSONObject: arguments)
            #expect(ToolArgumentSanitizer.containsSensitiveValues(data))
            let scrubbed = ToolArgumentSanitizer.redactedArgumentsJSON(data)
            #expect(!String(decoding: scrubbed, as: UTF8.self).contains("DO_NOT_REPLAY"))
        }
        let listedHeader = #"{"headers":[{"name":"Authorization","value":"NO_HEADER_REPLAY"}]}"#
        #expect(ToolArgumentSanitizer.containsSensitiveValues(Data(listedHeader.utf8)))
        #expect(!ToolArgumentSanitizer.redactedArgumentText(listedHeader).contains("NO_HEADER_REPLAY"))
    }

    @Test("Ordinary name/value pairs are not treated as credentials")
    func ordinaryPairsAreUntouched() throws {
        let json = #"{"name":"report.txt","value":"hello"}"#
        let redacted = ToolArgumentSanitizer.redactedArgumentText(json)
        #expect(redacted.contains("report.txt"))
        #expect(redacted.contains("hello"))
        #expect(!ToolArgumentSanitizer.containsSensitiveValues(Data(json.utf8)))
    }

    @Test("Malformed JSON still loses a quoted cookie value")
    func malformedFallback() {
        let redacted = ToolArgumentSanitizer.redactedArgumentText(#"{"headers":{"Cookie":"a=SECRET"#)
        #expect(!redacted.contains("SECRET"))
    }
}

@Suite("Generic large producer capture")
struct LargeProducerCaptureTests {
    struct LargeReplyTool: AgentTool {
        struct Arguments: Decodable, Sendable {}
        static let name = "test.largeNativeReply"
        static let toolDescription = "Return a large structured native reply."
        static let parametersJSON = #"{"type":"object","additionalProperties":false}"#
        static let riskLabels: Set<RiskLabel> = []
        static let isSideEffecting = false
        static let reply: String = {
            let head = #"{"capabilities":["draw","measure"],"payload":"#
            let body = String(repeating: "A", count: 18_000)
            return head + body + #""}"#
        }()

        func validate(_ args: Arguments) throws {}
        func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
            // The producer uses the ordinary digesting factory with the 4K UI
            // summary cap. The shared factory must retain the full admitted
            // text transiently; the runtime must then use that full capture
            // for the model wire when it fits.
            ToolExecutionOutput(
                digesting: Self.reply,
                maximumSummaryCharacters: 4_096
            )
        }
    }

    @Test("A factory-capped 18K native reply reaches the wire whole and stays pageable")
    func factoryCappedReplyReachesWireWhole() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-large-producer-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let conversationID = UUID()
        let provider = TestFixtures.localhostProvider()
        let call = try TestFixtures.toolCall(
            id: "large-producer", toolName: LargeReplyTool.name, arguments: "{}"
        )
        let adapter = MockAdapter()
        adapter.script = [
            [.toolRequest(call), .completed(.init(stopReason: .toolUse))],
            [.textDelta(.init(text: "done")), .completed(.init(stopReason: .endTurn))]
        ]
        let registry = ToolRunnerRegistry()
        registry.register(LargeReplyTool())
        let sink = MockSink()
        let runtime = FloeAgentRuntime(
            configuration: .init(
                conversationID: conversationID,
                provider: provider,
                model: TestFixtures.testModel(providerID: provider.id),
                toolResultCaptureRoot: root
            ),
            adapter: adapter,
            policy: HumanApprovalPolicy(),
            executor: CatalogToolExecutor(runners: registry),
            auditSink: MockAuditSink(),
            checkpointStore: MockCheckpointStore(),
            sink: sink
        )
        try await runtime.start(goal: "return a large native reply")
        #expect(await runtime.state.name == "completed")
        #expect(adapter.requests.count == 2)

        let wire = try #require(adapter.requests[1].toolResults.first?.output)
        #expect(wire.utf8.count >= LargeReplyTool.reply.utf8.count)
        #expect(wire.hasSuffix(String(LargeReplyTool.reply.suffix(64))))
        #expect(!wire.contains("[middle of tool output compacted]"))

        // The UI/event projection stays the bounded 4K summary.
        let eventResult = sink.events.compactMap { event -> ToolResult? in
            if case .toolResult(let result) = event { return result }
            return nil
        }.first
        let summary = try #require(eventResult?.outputSummary)
        #expect(summary.utf8.count <= 4_096)

        // The full bytes are retained and pageable by the stable ref.
        let store = ToolResultCaptureStore.shared(durableRoot: root)
        guard case .index(let rows, _) = await store.taskIndex(
            conversationID: conversationID
        ) else {
            Issue.record("expected a retained result index")
            return
        }
        let row = try #require(rows.first { $0.callID == call.id })
        guard case .page(let tailPage) = await store.page(
            conversationID: conversationID,
            ref: row.ref,
            offset: row.totalBytes - 64,
            maxBytes: 64
        ) else {
            Issue.record("expected a pageable tail")
            return
        }
        #expect(LargeReplyTool.reply.hasSuffix(tailPage.text))
    }
}

@Suite("ToolResult capture receipt metadata")
struct ToolResultCaptureInfoTests {
    @Test("safe receipt metadata is optional, Codable and survives the durable projection")
    func captureInfoRoundTripsWithoutBodiesOrIdentity() throws {
        let info = ToolResultCaptureInfo(
            ref: "tr_0123456789abcdef01234567",
            originalBytes: 90_000,
            retainedBytes: 4_096,
            retentionTruncated: true,
            executionReportedTruncation: false,
            available: true
        )
        let sentinel = "TRANSIENT_BODY_SENTINEL"
        let result = ToolResult(
            callID: "call-info",
            status: .ok,
            outputSummary: "bounded summary",
            outputDigest: "digest",
            capturedOutput: sentinel,
            captureInfo: info
        )
        let data = try JSONEncoder().encode(result)
        let encoded = String(decoding: data, as: UTF8.self)
        // Only the safe ref/byte facts are persisted; the transient capture
        // body never enters the encoded payload.
        #expect(!encoded.contains(sentinel))
        #expect(encoded.contains("tr_0123456789abcdef01234567"))
        let decoded = try JSONDecoder().decode(ToolResult.self, from: data)
        #expect(decoded.captureInfo == info)
        // Receipt metadata describes the retention side record, so it is not
        // part of the settled result's identity.
        #expect(decoded == result)

        let durable = result.durableProjection()
        #expect(durable.capturedOutput == nil)
        #expect(durable.captureInfo == info)
    }

    @Test("an older payload without receipt metadata decodes with none, never a guess")
    func legacyPayloadHasNoReceipt() throws {
        let legacy = #"{"callID":"c","status":"ok","outputSummary":"summary","outputDigest":"d"}"#
        let decoded = try JSONDecoder().decode(ToolResult.self, from: Data(legacy.utf8))
        #expect(decoded.captureInfo == nil)
        #expect(decoded.capturedOutput == nil)
    }

    @Test("an unavailable retention receipt never exposes a usable ref")
    func unavailableReceiptDropsRef() {
        let info = ToolResultCaptureInfo(
            ref: "tr_0123456789abcdef01234567",
            originalBytes: 100,
            retainedBytes: 0,
            retentionTruncated: false,
            executionReportedTruncation: false,
            available: false
        )
        #expect(info.ref == nil)
        #expect(!info.available)
    }
}
