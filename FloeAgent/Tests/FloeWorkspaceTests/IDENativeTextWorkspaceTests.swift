// FloeWorkspaceTests — Native IDE text editing model.
//
// SPDX-License-Identifier: MPL-2.0
//
// Focused coverage for the native editor path: default-surface policy,
// load/save/reopen against a real WorkspaceFileService, baseline-aware
// conflict review, dirty multi-file switching, UTF-16/emoji-safe find &
// replace, the IME composition guard and the 4 MiB policy.

import Foundation
import Testing
@testable import FloeWorkspace

private struct NativeTextFixture {
    let root: URL
    let service: WorkspaceFileService

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("floe-native-ide-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root))
    }

    func remove() { try? FileManager.default.removeItem(at: root) }

    @discardableResult
    func write(_ relativePath: String, _ content: String) throws -> WorkspaceFileService {
        try service.createFile(relativePath, content: content)
        return service
    }

    var onDisk: (String) throws -> String {
        { relativePath in try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8) }
    }
}

@Suite("IDE native text policy")
struct IDENativeTextPolicyTests {
    @Test("Text, code and unknown extensions default to the native editor")
    func nativeDefaults() {
        for path in ["note.txt", "README.md", "Sources/Main.swift", "data.json", "script.sh", "weird.xyz", "Makefile"] {
            #expect(IDENativeTextPolicy.defaultSurface(forPath: path) == .native, "\(path) should be native")
            #expect(IDENativeTextPolicy.supportsNativeEditing(path))
        }
    }

    @Test("Typed non-text documents are routed to the Web workbench baseline")
    func nonTextPathsFallBack() {
        let expected: [(String, WorkspaceFileKind)] = [
            ("report.docx", .office), ("manual.pdf", .pdf), ("plan.dxf", .cad),
            ("photo.png", .image), ("clip.mov", .media), ("bundle.zip", .archive),
            ("firmware.bin", .binary)
        ]
        for (path, kind) in expected {
            #expect(IDENativeTextPolicy.defaultSurface(forPath: path) == .webFallback(.nonTextKind(kind)))
            #expect(!IDENativeTextPolicy.supportsNativeEditing(path))
        }
    }

    @Test("The native editor shares the 4 MiB workspace policy")
    func sharedLimit() {
        #expect(IDENativeTextPolicy.maximumBytes == 4 * 1024 * 1024)
        #expect(IDENativeTextPolicy.maximumBytes == IDEWorkspaceSession.maximumFileBytes)
    }

    @Test("Close policy asks the user only when text would be lost")
    func closePolicy() {
        #expect(IDENativeTextCloseDecision.decide(isDirty: false, isSaving: false) == .closeImmediately)
        #expect(IDENativeTextCloseDecision.decide(isDirty: true, isSaving: false) == .askUser)
        #expect(IDENativeTextCloseDecision.decide(isDirty: false, isSaving: true) == .askUser)
        #expect(IDENativeTextCloseDecision.decide(isDirty: true, isSaving: true) == .askUser)
    }
}

@Suite("IDE native text editing primitives")
struct IDENativeTextEditingTests {
    @Test("Clamping never splits a surrogate pair")
    func clampSurrogateBoundaries() {
        let text = "😀B"
        #expect(IDENativeTextEditing.clamp(NSRange(location: 0, length: 0), to: text) == NSRange(location: 0, length: 0))
        #expect(IDENativeTextEditing.clamp(NSRange(location: 1, length: 0), to: text) == NSRange(location: 0, length: 0))
        #expect(IDENativeTextEditing.clamp(NSRange(location: 2, length: 0), to: text) == NSRange(location: 2, length: 0))
        #expect(IDENativeTextEditing.clamp(NSRange(location: 99, length: 0), to: text) == NSRange(location: 3, length: 0))
        #expect(!IDENativeTextEditing.isComposedBoundary(in: text, offset: 1))
        #expect(IDENativeTextEditing.isComposedBoundary(in: text, offset: 2))
    }

    @Test("Find is case-insensitive, wraps, and searches backwards")
    func findWraps() {
        let text = "Alpha beta ALPHA\n中文中文"
        let first = IDENativeTextEditing.find(in: text, query: "alpha", backwards: false, from: NSRange(location: 0, length: 0))
        #expect(first == NSRange(location: 0, length: 5))
        let second = IDENativeTextEditing.find(in: text, query: "alpha", backwards: false, from: first ?? .init())
        #expect(second == NSRange(location: 11, length: 5))
        let wrapped = IDENativeTextEditing.find(in: text, query: "alpha", backwards: false, from: second ?? .init())
        #expect(wrapped == NSRange(location: 0, length: 5))
        let chinese = IDENativeTextEditing.find(in: text, query: "中文", backwards: false, from: NSRange(location: 0, length: 0))
        #expect(chinese == NSRange(location: 17, length: 2))
        let backwards = IDENativeTextEditing.find(in: text, query: "alpha", backwards: true, from: NSRange(location: 16, length: 0))
        #expect(backwards == NSRange(location: 11, length: 5))
        #expect(IDENativeTextEditing.find(in: text, query: "", backwards: false, from: NSRange(location: 0, length: 0)) == nil)
        #expect(IDENativeTextEditing.find(in: text, query: "missing", backwards: false, from: NSRange(location: 0, length: 0)) == nil)
    }

    @Test("Replace-current replaces only a matching selection, else advances")
    func replaceCurrentMatchesSelection() {
        let text = "one two two"
        let matched = IDENativeTextEditing.replaceCurrent(
            in: text, query: "TWO", replacement: "2", selection: NSRange(location: 4, length: 3)
        )
        #expect(matched.replaced)
        #expect(matched.text == "one 2 two")
        #expect(matched.selection == NSRange(location: 5, length: 0))
        let advanced = IDENativeTextEditing.replaceCurrent(
            in: text, query: "two", replacement: "2", selection: NSRange(location: 0, length: 0)
        )
        #expect(!advanced.replaced)
        #expect(advanced.text == text)
        #expect(advanced.selection == NSRange(location: 4, length: 3))
    }

    @Test("Replace-all is case-insensitive and keeps a clamped cursor")
    func replaceAllClampsCursor() {
        let text = "Alpha alpha ALPHA"
        let result = IDENativeTextEditing.replaceAll(
            in: text, query: "alpha", replacement: "x", selection: NSRange(location: 17, length: 0)
        )
        #expect(result.text == "x x x")
        #expect(result.selection == NSRange(location: 5, length: 0))
        #expect(result.replaced)
    }

    @Test("Cursor line/column survives emoji and Chinese at the cursor")
    func lineAndColumn() {
        let text = "first\n中文😀 tail"
        let cursor = (text as NSString).range(of: "😀").location
        let position = IDENativeTextEditing.lineAndColumn(in: text, at: cursor)
        #expect(position.line == 2)
        #expect(position.column == 3)
        // A location inside the surrogate pair is rounded back to the boundary.
        let split = IDENativeTextEditing.lineAndColumn(in: text, at: cursor + 1)
        #expect(split.line == 2)
        #expect(split.column == 3)
        #expect(IDENativeTextEditing.lineCount(in: text) == 2)
    }
}

@Suite("IDE native IME composition guard")
struct IDENativeEditorCompositionGuardTests {
    @Test("Programmatic updates are deferred while marked text is active")
    func defersDuringComposition() {
        var guardState = IDENativeEditorCompositionGuard()
        let immediate = guardState.requestProgrammaticUpdate("a", hasMarkedText: false)
        #expect(immediate)
        #expect(guardState.pendingProgrammaticText == nil)
        let deferred = guardState.requestProgrammaticUpdate("partial 中", hasMarkedText: true)
        #expect(!deferred)
        #expect(guardState.pendingProgrammaticText == "partial 中")
        #expect(!IDENativeEditorCompositionGuard.mayWriteTextStorage(hasMarkedText: true))
    }

    @Test("The newest deferred update wins and is applied exactly once")
    func appliesOnceAfterComposition() {
        var guardState = IDENativeEditorCompositionGuard()
        _ = guardState.requestProgrammaticUpdate("old", hasMarkedText: true)
        _ = guardState.requestProgrammaticUpdate("new", hasMarkedText: true)
        #expect(guardState.compositionDidEnd() == "new")
        #expect(guardState.pendingProgrammaticText == nil)
        #expect(guardState.compositionDidEnd() == nil)
        #expect(!guardState.hasMarkedText)
    }

    @Test("An immediate update clears any stale pending text")
    func immediateUpdateClearsPending() {
        var guardState = IDENativeEditorCompositionGuard()
        _ = guardState.requestProgrammaticUpdate("deferred", hasMarkedText: true)
        let immediate = guardState.requestProgrammaticUpdate("direct", hasMarkedText: false)
        #expect(immediate)
        #expect(guardState.pendingProgrammaticText == nil)
        #expect(guardState.compositionDidEnd() == nil)
    }
}

@Suite("IDE native text buffers")
@MainActor
struct IDENativeTextBufferTests {
    @Test("Load, edit, save and cold reopen stay baseline-aware")
    func saveAndColdReopen() async throws {
        let fixture = try NativeTextFixture()
        defer { fixture.remove() }
        _ = try fixture.write("notes/中文.txt", "第一行\nsecond line\n")

        let workspace = IDENativeTextWorkspace(files: fixture.service)
        let buffer = try #require(await workspace.open("notes/中文.txt"))
        #expect(buffer.isLoaded)
        #expect(buffer.text == "第一行\nsecond line\n")
        #expect(!buffer.isDirty)
        #expect(!workspace.hasDirty)

        buffer.text = "第一行\n已编辑 emoji 😀\n"
        #expect(buffer.isDirty)
        #expect(workspace.hasDirty)
        #expect(try fixture.onDisk("notes/中文.txt") == "第一行\nsecond line\n")

        let report = await workspace.saveAll()
        #expect(report.isClean)
        #expect(report.savedPaths == ["notes/中文.txt"])
        #expect(!workspace.hasDirty)
        #expect(try fixture.onDisk("notes/中文.txt") == "第一行\n已编辑 emoji 😀\n")

        // Cold reopen: a fresh model over the same workspace reads what was
        // committed to disk, not the previous in-memory buffer.
        let reopened = IDENativeTextWorkspace(files: fixture.service)
        let cold = try #require(await reopened.open("notes/中文.txt"))
        #expect(cold.text == "第一行\n已编辑 emoji 😀\n")
        #expect(!cold.isDirty)
    }

    @Test("An agent edit between load and save opens the conflict review and preserves the draft")
    func conflictReviewRetainsDraft() async throws {
        let fixture = try NativeTextFixture()
        defer { fixture.remove() }
        _ = try fixture.write("conflict.txt", "one\ntwo\nthree")

        let workspace = IDENativeTextWorkspace(files: fixture.service)
        let buffer = try #require(await workspace.open("conflict.txt"))
        buffer.text = "USER\ntwo\nthree"
        _ = try fixture.service.writeFile("conflict.txt", content: "one\ntwo\nAGENT")

        let report = await workspace.saveAll()
        #expect(!report.isClean)
        #expect(report.conflictPaths == ["conflict.txt"])
        #expect(report.savedPaths.isEmpty)
        let review = try #require(buffer.conflict)
        #expect(review.base == "one\ntwo\nthree")
        #expect(review.current == "one\ntwo\nAGENT")
        #expect(review.draft == "USER\ntwo\nthree")
        #expect(try fixture.onDisk("conflict.txt") == "one\ntwo\nAGENT")
        // The draft is recoverable even if the review is dismissed.
        let recovery = try #require(review.recoveryPath)
        #expect(try fixture.service.readFileForEditing(recovery).text == "USER\ntwo\nthree")

        let merged = try #require(review.plan.resolved())
        #expect(merged == "USER\ntwo\nAGENT")
        #expect(await workspace.resolveConflict(path: "conflict.txt", content: merged))
        #expect(buffer.conflict == nil)
        #expect(!buffer.isDirty)
        #expect(try fixture.onDisk("conflict.txt") == "USER\ntwo\nAGENT")
    }

    @Test("A newer edit during review re-opens the conflict instead of overwriting")
    func conflictDuringResolutionStaysOpen() async throws {
        let fixture = try NativeTextFixture()
        defer { fixture.remove() }
        _ = try fixture.write("race.txt", "base")
        let service = fixture.service
        let workspace = IDENativeTextWorkspace(files: service)
        let buffer = try #require(await workspace.open("race.txt"))
        buffer.text = "MINE"
        _ = try service.writeFile("race.txt", content: "AGENT-1")
        _ = await workspace.saveAll()
        let review = try #require(buffer.conflict)
        _ = try service.writeFile("race.txt", content: "AGENT-2")
        #expect(!(await workspace.resolveConflict(path: "race.txt", content: review.plan.resolved() ?? "MINE")))
        #expect(buffer.conflict != nil)
        #expect(buffer.conflict?.current == "AGENT-2")
        #expect(try fixture.onDisk("race.txt") == "AGENT-2")
    }

    @Test("Dirty multi-file switching retains every buffer and saves all")
    func dirtySwitchingRetainsBuffers() async throws {
        let fixture = try NativeTextFixture()
        defer { fixture.remove() }
        _ = try fixture.write("a.txt", "A0")
        _ = try fixture.write("b.txt", "B0")
        _ = try fixture.write("c.txt", "C0")

        let workspace = IDENativeTextWorkspace(files: fixture.service)
        let a = try #require(await workspace.open("a.txt"))
        var b = try #require(await workspace.open("b.txt"))
        a.text = "A1"
        b.text = "B1"
        #expect(workspace.activePath == "b.txt")

        // Switching tabs is a pure activation: nothing is flushed or dropped.
        workspace.activate("a.txt")
        #expect(workspace.activeBuffer?.text == "A1")
        #expect(workspace.activeBuffer?.isDirty == true)
        workspace.activate("b.txt")
        #expect(workspace.buffer("b.txt")?.text == "B1")
        #expect(workspace.dirtyPaths == ["a.txt", "b.txt"])

        // Switching to the Web kernel keeps both dirty buffers in memory and
        // reports them for confirmation.
        let plan = workspace.planSurfaceSwitch(to: .web, webHasUnsavedChanges: false)
        #expect(plan.retainedDirtyPaths == ["a.txt", "b.txt"])
        #expect(plan.requiresConfirmation)
        #expect(workspace.openPaths == ["a.txt", "b.txt"])
        #expect(workspace.buffer("a.txt")?.text == "A1")

        // A dirty buffer can never be closed without an explicit decision.
        #expect(workspace.closeDecision(for: "a.txt") == .askUser)
        #expect(!workspace.close("a.txt"))
        #expect(workspace.buffer("a.txt") != nil)
        #expect(workspace.close("a.txt", force: true))
        #expect(workspace.buffer("a.txt") == nil)

        // The clean buffer closes immediately once activated.
        _ = await workspace.open("c.txt")
        #expect(workspace.close("c.txt"))
        #expect(workspace.buffer("c.txt") == nil)

        // Save-all covers the remaining dirty buffer and the clean ones stay
        // untouched. The force-closed A1 draft was discarded by an explicit
        // choice, so its file still holds the last committed content.
        workspace.activate("b.txt")
        let report = await workspace.saveAll()
        #expect(report.savedPaths == ["b.txt"])
        #expect(try fixture.onDisk("b.txt") == "B1")
        #expect(try fixture.onDisk("a.txt") == "A0")
        #expect(!workspace.hasDirty)
        b = try #require(workspace.buffer("b.txt"))
        #expect(!b.isDirty)
    }

    @Test("Binary and oversized files fall back instead of decoding")
    func binaryAndOversizedFallBack() async throws {
        let fixture = try NativeTextFixture()
        defer { fixture.remove() }
        // Binary: NUL byte plus invalid UTF-8.
        try Data([0x50, 0x4B, 0x00, 0xFF, 0xFE]).write(to: fixture.root.appendingPathComponent("blob.txt"))
        // Oversized: one byte past the shared 4 MiB policy.
        let oversized = Data(repeating: 0x61, count: IDENativeTextPolicy.maximumBytes + 1)
        try oversized.write(to: fixture.root.appendingPathComponent("big.txt"))

        let workspace = IDENativeTextWorkspace(files: fixture.service)
        let binary = try #require(await workspace.open("blob.txt"))
        #expect(!binary.isLoaded)
        #expect(binary.fallbackReason == .binaryContent)
        #expect(binary.loadError != nil)
        #expect(!(await binary.save(service: fixture.service)))

        let big = try #require(await workspace.open("big.txt"))
        #expect(!big.isLoaded)
        #expect(big.fallbackReason == .exceedsNativeLimit(IDENativeTextPolicy.maximumBytes))
        #expect(!(await big.save(service: fixture.service)))
        #expect(workspace.hasDirty == false)
    }

    @Test("The open-buffer budget evicts clean buffers only")
    func bufferBudgetEvictsCleanOnly() async throws {
        let fixture = try NativeTextFixture()
        defer { fixture.remove() }
        _ = try fixture.write("keep.txt", "keep")
        _ = try fixture.write("one.txt", "1")
        _ = try fixture.write("two.txt", "2")

        let workspace = IDENativeTextWorkspace(files: fixture.service, maximumOpenBuffers: 2)
        let keep = try #require(await workspace.open("keep.txt"))
        keep.text = "dirty keep"
        _ = await workspace.open("one.txt")
        // Opening two.txt must evict the oldest *clean* buffer (one.txt), never
        // the dirty keep.txt.
        #expect(await workspace.open("two.txt") != nil)
        #expect(workspace.openPaths == ["keep.txt", "two.txt"])
        #expect(workspace.buffer("keep.txt")?.text == "dirty keep")
        #expect(workspace.buffer("keep.txt")?.isDirty == true)
    }

    @Test("A single-buffer save (tab close) commits only that file")
    func singleBufferSave() async throws {
        let fixture = try NativeTextFixture()
        defer { fixture.remove() }
        _ = try fixture.write("one.txt", "one")
        _ = try fixture.write("two.txt", "two")
        let workspace = IDENativeTextWorkspace(files: fixture.service)
        let one = try #require(await workspace.open("one.txt"))
        let two = try #require(await workspace.open("two.txt"))
        one.text = "ONE"
        two.text = "TWO"
        #expect(await workspace.save("one.txt"))
        #expect(!one.isDirty)
        #expect(two.isDirty)
        #expect(try fixture.onDisk("one.txt") == "ONE")
        #expect(try fixture.onDisk("two.txt") == "two")
        // The conflict path stays intact for a single save too.
        _ = try fixture.service.writeFile("two.txt", content: "AGENT")
        #expect(!(await workspace.save("two.txt")))
        #expect(two.conflict != nil)
        #expect(try fixture.onDisk("two.txt") == "AGENT")
    }

    @Test("A failed save keeps the draft dirty and reports the error")
    func failedSaveKeepsDraft() async throws {
        let fixture = try NativeTextFixture()
        defer { fixture.remove() }
        _ = try fixture.write("locked.txt", "original")
        let workspace = IDENativeTextWorkspace(files: fixture.service)
        let buffer = try #require(await workspace.open("locked.txt"))
        // Grow the draft past the write cap: the guard refuses it, the buffer
        // stays dirty and the on-disk file is untouched.
        buffer.text = String(repeating: "x", count: IDENativeTextPolicy.maximumBytes + 1)
        let report = await workspace.saveAll()
        #expect(!report.isClean)
        #expect(report.failedPaths == ["locked.txt"])
        #expect(buffer.isDirty)
        #expect(buffer.saveError != nil)
        #expect(try fixture.onDisk("locked.txt") == "original")
    }
}

/// Measured native baseline for the native editing path. These numbers are
/// measurements of this model over a real workspace (no Web/Monaco baseline:
/// that needs an App build on a simulator or device, which this environment
/// does not run). They are printed so a reviewer can compare runs; the
/// assertions are generous sanity budgets, not performance claims.
@Suite("IDE native text measured baseline")
@MainActor
struct IDENativeTextPerformanceTests {
    @Test("Measured open / edit+save / replace-all on a 1 MiB mixed-script file")
    func measuredOpenEditSaveReplace() async throws {
        let fixture = try NativeTextFixture()
        defer { fixture.remove() }
        var body = ""
        var index = 0
        while body.utf8.count < 1024 * 1024 {
            body += "行 \(index) 中文 mixed emoji 😀 func main() { print(\"héllo\") } // note\n"
            index += 1
        }
        _ = try fixture.write("large.swift", body)

        let workspace = IDENativeTextWorkspace(files: fixture.service)
        let clock = ContinuousClock()

        let openStart = clock.now
        let buffer = try #require(await workspace.open("large.swift"))
        let openDuration = openStart.duration(to: clock.now)
        #expect(buffer.isLoaded)
        #expect(buffer.text.utf8.count == body.utf8.count)

        let editStart = clock.now
        buffer.text += "// edited tail\n"
        let editDuration = editStart.duration(to: clock.now)
        let saveStart = clock.now
        let report = await workspace.saveAll()
        let saveDuration = saveStart.duration(to: clock.now)
        #expect(report.isClean)

        let replaceStart = clock.now
        let replaced = IDENativeTextEditing.replaceAll(
            in: buffer.text, query: "中文", replacement: "漢字", selection: NSRange(location: 0, length: 0)
        )
        let replaceDuration = replaceStart.duration(to: clock.now)
        #expect(replaced.replaced)
        #expect(!replaced.text.contains("中文"))

        let reopenStart = clock.now
        let reopened = IDENativeTextWorkspace(files: fixture.service)
        let cold = try #require(await reopened.open("large.swift"))
        let reopenDuration = reopenStart.duration(to: clock.now)
        #expect(cold.isLoaded)

        print("IDENativeText measured bytes=\(body.utf8.count) open=\(openDuration) edit=\(editDuration) save=\(saveDuration) replaceAll=\(replaceDuration) coldReopen=\(reopenDuration)")
        // Guard rails against a pathological regression only.
        #expect(openDuration < .seconds(5))
        #expect(saveDuration < .seconds(5))
        #expect(replaceDuration < .seconds(5))
        #expect(reopenDuration < .seconds(5))
    }
}
