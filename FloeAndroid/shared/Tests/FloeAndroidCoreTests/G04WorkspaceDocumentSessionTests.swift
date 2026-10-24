// SPDX-License-Identifier: MPL-2.0
// Component tests: real original file service, injected ownership admission.
// These are not App/SAF/device acceptance and are run in the grouped cohort.
import Foundation
import Testing
import FloeCore
import FloeTools
import FloeWorkspace
@testable import FloeAndroidCore

private actor G04TestAccess: G04WorkspaceAccessPort {
    let owner: G04WorkspaceOwner
    var service: WorkspaceFileService
    var entered = 0
    var released = 0
    var cancelled = false
    var deniedPath: String?
    var admissions: [String] = []

    init(owner: G04WorkspaceOwner, service: WorkspaceFileService) {
        self.owner = owner; self.service = service
    }
    func acquire(owner: G04WorkspaceOwner, intent: G04WorkspaceIntent,
                 relativePath: String?) async throws -> G04WorkspaceAccessLease {
        guard owner == self.owner else { throw G04DocumentError.ownerChanged }
        admissions.append(relativePath ?? "<root>")
        if relativePath == deniedPath, deniedPath != nil { throw G04DocumentError.ownerChanged }
        entered += 1
        let token = CancellationToken()
        if cancelled { token.cancel() }
        return G04WorkspaceAccessLease(service: service, cancellation: token,
                                        release: { await self.finish() })
    }
    func finish() { released += 1 }
    func counts() -> (Int, Int) { (entered, released) }
    func setCancelled() { cancelled = true }
    func deny(_ path: String?) { deniedPath = path }
    func admittedPaths() -> [String] { admissions }
    func changeService(_ service: WorkspaceFileService) { self.service = service }
}

private struct G04DocumentFixture: Sendable {
    let base: URL
    let root: URL
    let access: G04TestAccess
    let session: G04WorkspaceDocumentSession

    init() throws {
        let configured = ProcessInfo.processInfo.environment["FLOE_G04_TEST_ROOT"].map {
            URL(fileURLWithPath: $0, isDirectory: true)
        }
        let package = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let parent = configured ?? package.appendingPathComponent(".build/test-fixtures/g04-documents", isDirectory: true)
        base = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        root = base.appendingPathComponent("workspace", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let owner = G04WorkspaceOwner(epoch: 1, taskID: UUID(), workspaceID: UUID())
        access = G04TestAccess(owner: owner, service: WorkspaceFileService(guard: WorkspacePathGuard(rootURL: root)))
        session = G04WorkspaceDocumentSession(owner: owner, access: access)
    }
    func write(_ path: String, _ text: String) throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(path), options: .atomic)
    }
    func cleanup() { try? FileManager.default.removeItem(at: base) }
}

private func g04Expect(_ expected: G04DocumentError, _ action: () async throws -> Void) async {
    do { try await action(); Issue.record("Expected a typed document refusal") }
    catch let error as G04DocumentError { #expect(error == expected) }
    catch { Issue.record("Unexpected refusal: \(error)") }
}

private func g04Read(_ session: G04WorkspaceDocumentSession, _ header: G04DocumentHeader,
                     chunkBytes: Int = 7) async throws -> Data {
    let content = try await session.beginContent(header.documentID, revision: header.revision)
    var data = Data(), offset = 0
    repeat {
        let chunk = try await session.readContent(content.handle, offset: offset, limit: chunkBytes)
        let frame = try JSONSerialization.data(withJSONObject: ["bytes": chunk.bytes.base64EncodedString(),
                                                               "offset": chunk.nextOffset])
        #expect(frame.count < 48 * 1024)
        data.append(chunk.bytes); offset = chunk.nextOffset
        if chunk.finished { break }
    } while true
    await session.releaseContent(content.handle)
    #expect(data.count == content.byteCount)
    #expect(FloeDigest.sha256Hex(data) == content.sha256)
    return data
}

@Suite("G04 workspace document adapter")
struct G04WorkspaceDocumentSessionTests {
    @Test func editingUndoSavePreservesBOMCRLFAndEmoji() async throws {
        let fixture = try G04DocumentFixture(); defer { fixture.cleanup() }
        let original = "\u{FEFF}你好🙂\r\nline\r\n"
        try fixture.write("main.kt", original)
        let opened = try await fixture.session.open("main.kt")
        let initial = try await g04Read(fixture.session, opened)
        #expect(initial == Data(original.utf8))
        let range = (original as NSString).range(of: "🙂")
        let edited = try await fixture.session.edit(opened.documentID, revision: opened.revision,
                                                    range: range, replacement: "🚀")
        #expect(edited.dirty && edited.canUndo)
        let undone = try await fixture.session.undo(edited.documentID, revision: edited.revision)
        #expect(!undone.dirty && undone.canRedo)
        let restored = try await g04Read(fixture.session, undone)
        #expect(restored == Data(original.utf8))
        let redone = try await fixture.session.redo(undone.documentID, revision: undone.revision)
        let outcome = try await fixture.session.save(redone.documentID, revision: redone.revision)
        guard case .saved(let saved) = outcome else { Issue.record("Unexpected conflict"); return }
        #expect(!saved.dirty && saved.canUndo)
        let disk = try Data(contentsOf: fixture.root.appendingPathComponent("main.kt"))
        #expect(disk == Data(original.replacingOccurrences(of: "🙂", with: "🚀").utf8))
        let postSaveUndo = try await fixture.session.undo(saved.documentID, revision: saved.revision)
        #expect(postSaveUndo.dirty)
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("main.kt")) == disk)
    }

    @Test func staleRangesCancellationAndRetirementCannotMutate() async throws {
        let fixture = try G04DocumentFixture(); defer { fixture.cleanup() }
        try fixture.write("a.txt", "a🙂b")
        let opened = try await fixture.session.open("a.txt")
        await g04Expect(.invalidRange) {
            _ = try await fixture.session.edit(opened.documentID, revision: opened.revision,
                range: NSRange(location: 2, length: 0), replacement: "bad")
        }
        await g04Expect(.invalidRange) {
            _ = try await fixture.session.edit(opened.documentID, revision: opened.revision,
                range: NSRange(location: Int.max, length: 5), replacement: "bad")
        }
        let edited = try await fixture.session.edit(opened.documentID, revision: opened.revision,
            range: NSRange(location: 0, length: 1), replacement: "A")
        await g04Expect(.staleRevision) {
            _ = try await fixture.session.edit(opened.documentID, revision: opened.revision,
                range: NSRange(location: 0, length: 1), replacement: "wrong")
        }
        let dirty = await fixture.session.beginRetirement()
        #expect(dirty.count == 1 && dirty[0].text == "A🙂b")
        await g04Expect(.retired) { _ = try await fixture.session.save(edited.documentID, revision: edited.revision) }
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("a.txt"), encoding: .utf8) == "a🙂b")
        let counts = await fixture.access.counts()
        #expect(counts.0 == counts.1)

        let cancelled = try G04DocumentFixture(); defer { cancelled.cleanup() }
        try cancelled.write("b.txt", "unchanged")
        await cancelled.access.setCancelled()
        do { _ = try await cancelled.session.open("b.txt"); Issue.record("Cancelled admission succeeded") }
        catch FloeError.cancelled { }
        let cancelledCounts = await cancelled.access.counts()
        #expect(cancelledCounts.0 == cancelledCounts.1)
    }

    @Test func largePasteIsChunkedVerifiedAndReplaySafe() async throws {
        let fixture = try G04DocumentFixture(); defer { fixture.cleanup() }
        try fixture.write("paste.txt", "suffix")
        let opened = try await fixture.session.open("paste.txt")
        let replacement = String(repeating: "中文🙂\r\n", count: 12_000)
        let bytes = Data(replacement.utf8)
        #expect(bytes.count > 65_536)
        let upload = try await fixture.session.beginEditUpload(opened.documentID, revision: opened.revision,
            range: NSRange(location: 0, length: 0), byteCount: bytes.count, sha256: FloeDigest.sha256Hex(bytes))
        var offset = 0
        while offset < bytes.count {
            let end = min(bytes.count, offset + 23_000), chunk = bytes.subdata(in: offset..<end)
            let next = try await fixture.session.appendEditUpload(upload, offset: offset, bytes: chunk)
            #expect(next == end)
            let replay = try await fixture.session.appendEditUpload(upload, offset: offset, bytes: chunk)
            #expect(replay == end)
            offset = next
        }
        let pasted = try await fixture.session.commitEditUpload(upload)
        let result = try await g04Read(fixture.session, pasted, chunkBytes: 24 * 1024)
        #expect(result == Data((replacement + "suffix").utf8))
        let corrupt = try await fixture.session.beginEditUpload(pasted.documentID, revision: pasted.revision,
            range: NSRange(location: 0, length: 0), byteCount: 1, sha256: String(repeating: "0", count: 64))
        _ = try await fixture.session.appendEditUpload(corrupt, offset: 0, bytes: Data([65]))
        await g04Expect(.invalidTransfer) { _ = try await fixture.session.commitEditUpload(corrupt) }
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("paste.txt"), encoding: .utf8) == "suffix")
    }

    @Test func externalEditsKeepOriginalAndRecovery() async throws {
        let fixture = try G04DocumentFixture(); defer { fixture.cleanup() }
        try fixture.write("conflict.txt", "base")
        let opened = try await fixture.session.open("conflict.txt")
        let edited = try await fixture.session.edit(opened.documentID, revision: opened.revision,
            range: NSRange(location: 0, length: 4), replacement: "my draft")
        try fixture.write("conflict.txt", "external")
        let outcome = try await fixture.session.save(edited.documentID, revision: edited.revision)
        guard case .conflict(let current, let conflict) = outcome else { Issue.record("CAS conflict was lost"); return }
        #expect(conflict.current == "external" && conflict.draft == "my draft")
        let recovery = try #require(conflict.recoveryPath)
        #expect(try String(contentsOf: fixture.root.appendingPathComponent(recovery), encoding: .utf8) == "my draft")
        try fixture.write("conflict.txt", "external changed again")
        do {
            _ = try await fixture.session.resolveConflict(current.documentID, revision: current.revision,
                reviewedSHA256: conflict.currentSHA256, text: "reviewed merge")
            Issue.record("Stale review overwrote a new external edit")
        } catch WorkspaceToolError.conflict { }
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("conflict.txt"), encoding: .utf8) == "external changed again")
        let refreshed = try await fixture.session.save(current.documentID, revision: current.revision)
        guard case .conflict(let next, let reviewed) = refreshed else { Issue.record("Refreshed conflict missing"); return }
        #expect(next.revision != current.revision)
        let remote = try await fixture.session.beginContent(next.documentID, revision: next.revision, part: .conflictCurrent)
        let bytes = try await fixture.session.readContent(remote.handle, offset: 0, limit: 1024)
        #expect(bytes.bytes == Data("external changed again".utf8))
        await fixture.session.releaseContent(remote.handle)
        let merged = try await fixture.session.edit(next.documentID, revision: next.revision,
            range: NSRange(location: 0, length: 8), replacement: "reviewed merge")
        let resolved = try await fixture.session.resolveConflictUsingDraft(merged.documentID,
            revision: merged.revision, reviewedSHA256: reviewed.currentSHA256)
        #expect(!resolved.dirty)
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("conflict.txt"), encoding: .utf8) == "reviewed merge")
    }

    @Test func authorizedMountsWorkAndRetargetsRefuse() async throws {
        let fixture = try G04DocumentFixture(); defer { fixture.cleanup() }
        let first = fixture.base.appendingPathComponent("providerA", isDirectory: true)
        let second = fixture.base.appendingPathComponent("providerB", isDirectory: true)
        for directory in [first, second] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("provider original".utf8).write(to: directory.appendingPathComponent("a.txt"))
        }
        await fixture.access.changeService(WorkspaceFileService(guard: WorkspacePathGuard(rootURL: fixture.root,
            mounts: ["Remote": first])))
        let opened = try await fixture.session.open("Mounts/Remote/a.txt")
        let edited = try await fixture.session.edit(opened.documentID, revision: opened.revision,
            range: NSRange(location: 0, length: 0), replacement: "draft ")
        await fixture.access.changeService(WorkspaceFileService(guard: WorkspacePathGuard(rootURL: fixture.root,
            mounts: ["Remote": second])))
        await g04Expect(.ownerChanged) { _ = try await fixture.session.save(edited.documentID, revision: edited.revision) }
        #expect(try String(contentsOf: second.appendingPathComponent("a.txt"), encoding: .utf8) == "provider original")
    }

    @Test func caseSensitiveWholeWordsAndLinearDiffAreReal() async throws {
        let fixture = try G04DocumentFixture(); defer { fixture.cleanup() }
        try fixture.write("words.txt", "cat Cat concatenate 猫猫 猫")
        let opened = try await fixture.session.open("words.txt")
        let found = try await fixture.session.find(opened.documentID, revision: opened.revision,
            query: "cat", caseSensitive: true, wholeWord: true)
        #expect(found.ranges.count == 1)
        let replaced = try await fixture.session.replace(opened.documentID, revision: opened.revision,
            query: "cat", replacement: "dog", caseSensitive: false, wholeWord: true, all: true)
        #expect(replaced.replacements == 2)
        #expect(try await g04Read(fixture.session, replaced.header) == Data("dog dog concatenate 猫猫 猫".utf8))

        let original = String(repeating: "alpha\n", count: 1200) + "尾行"
        try fixture.write("large.txt", original)
        let large = try await fixture.session.open("large.txt")
        let edit = try await fixture.session.edit(large.documentID, revision: large.revision,
            range: NSRange(location: 0, length: 5), replacement: "新内容")
        let patch = try await fixture.session.diff(edit.documentID, revision: edit.revision)
        let targetRoot = fixture.base.appendingPathComponent("patch", isDirectory: true)
        try FileManager.default.createDirectory(at: targetRoot, withIntermediateDirectories: true)
        try Data(original.utf8).write(to: targetRoot.appendingPathComponent("large.txt"))
        let service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: targetRoot))
        _ = try service.applyPatch("large.txt", patch: patch)
        #expect(try String(contentsOf: targetRoot.appendingPathComponent("large.txt"), encoding: .utf8)
                == "新内容" + original.dropFirst(5))
    }
    @Test func movePreservesDraftAndDeleteRefusesDirtyTree() async throws {
        let fixture = try G04DocumentFixture(); defer { fixture.cleanup() }
        try await fixture.session.createDirectory("source")
        _ = try await fixture.session.createFile("source/main.kt", content: "before")
        let opened = try await fixture.session.open("source/main.kt")
        _ = try await fixture.session.edit(opened.documentID, revision: opened.revision,
            range: NSRange(location: 0, length: 6), replacement: "after🙂")
        let moved = try await fixture.session.move("source", to: "renamed")
        let tab = try #require(moved.first)
        #expect(tab.documentID == opened.documentID && tab.relativePath == "renamed/main.kt")
        #expect(tab.dirty && tab.canUndo)
        #expect(try await g04Read(fixture.session, tab) == Data("after🙂".utf8))
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("renamed/main.kt"), encoding: .utf8) == "before")
        await g04Expect(.dirtyDocument) { _ = try await fixture.session.delete("renamed", recursive: true) }
        let outcome = try await fixture.session.save(tab.documentID, revision: tab.revision)
        guard case .saved(let saved) = outcome else { Issue.record("Moved draft must save to moved file"); return }
        #expect(saved.relativePath == "renamed/main.kt")
        try await fixture.session.copy("renamed/main.kt", to: "copy.kt")
        #expect(try Data(contentsOf: fixture.root.appendingPathComponent("copy.kt")) == Data("after🙂".utf8))
        let removed = try await fixture.session.delete("renamed", recursive: true)
        #expect(removed == [opened.documentID])
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("source").path))
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("renamed").path))
        let counts = await fixture.access.counts(); #expect(counts.0 == counts.1)
    }

    @Test func bothFileOperationEndpointsNeedAdmissionAndDeniedTargetReleasesSource() async throws {
        let fixture = try G04DocumentFixture(); defer { fixture.cleanup() }
        try fixture.write("source.txt", "unchanged")
        await fixture.access.deny("denied.txt")
        await g04Expect(.ownerChanged) { try await fixture.session.copy("source.txt", to: "denied.txt") }
        await g04Expect(.ownerChanged) { _ = try await fixture.session.move("source.txt", to: "denied.txt") }
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("source.txt"), encoding: .utf8) == "unchanged")
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("denied.txt").path))
        let paths = await fixture.access.admittedPaths()
        #expect(paths == ["source.txt", "denied.txt", "source.txt", "denied.txt"])
        let counts = await fixture.access.counts(); #expect(counts.0 == 2 && counts.1 == 2)
        await fixture.access.deny(nil)
        await fixture.access.setCancelled()
        do { try await fixture.session.copy("source.txt", to: "cancelled.txt"); Issue.record("Cancelled IO admitted") }
        catch { }
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("cancelled.txt").path))
        let after = await fixture.access.counts(); #expect(after.0 == after.1)
    }

}


extension G04WorkspaceDocumentSessionTests {
    @Test func gitWorkingTreeMutationRefusesUnsavedDraftAndFencesNewEdits() async throws {
        let fixture = try G04DocumentFixture(); defer { fixture.cleanup() }
        try fixture.write("tracked.txt", "base")
        let opened = try await fixture.session.open("tracked.txt")
        let edited = try await fixture.session.edit(opened.documentID, revision: opened.revision,
            range: NSRange(location: 4, length: 0), replacement: " draft")
        await g04Expect(.dirtyDocument) { _ = try await fixture.session.beginExternalMutation() }
        let clean = try await fixture.session.undo(edited.documentID, revision: edited.revision)
        let token = try await fixture.session.beginExternalMutation()
        await g04Expect(.workspaceBusy) {
            _ = try await fixture.session.edit(clean.documentID, revision: clean.revision,
                range: NSRange(location: 0, length: 0), replacement: "late")
        }
        let service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: fixture.root))
        #expect(try await fixture.session.finishExternalMutation(token, service: service).isEmpty)
        #expect(try String(contentsOf: fixture.root.appendingPathComponent("tracked.txt"), encoding: .utf8) == "base")
        _ = try await fixture.session.edit(clean.documentID, revision: clean.revision,
            range: NSRange(location: 0, length: 0), replacement: "allowed after release")
    }

    @Test func gitWorkingTreeMutationReloadsActualFileAndInvalidatesOldRevision() async throws {
        let fixture = try G04DocumentFixture(); defer { fixture.cleanup() }
        try fixture.write("tracked.txt", "before")
        let opened = try await fixture.session.open("tracked.txt")
        let token = try await fixture.session.beginExternalMutation()
        try fixture.write("tracked.txt", "new branch 🙂")
        let service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: fixture.root))
        #expect(try await fixture.session.finishExternalMutation(token, service: service).isEmpty)
        let tabs = try await fixture.session.tabs()
        let current = try #require(tabs.first)
        #expect(current.documentID == opened.documentID)
        #expect(current.revision != opened.revision)
        #expect(!current.dirty && !current.canUndo && !current.canRedo)
        #expect(try await g04Read(fixture.session, current) == Data("new branch 🙂".utf8))
        await g04Expect(.staleRevision) {
            _ = try await fixture.session.edit(opened.documentID, revision: opened.revision,
                range: NSRange(location: 0, length: 0), replacement: "stale")
        }
    }

    @Test func gitWorkingTreeMutationReportsRemovedFilesInsteadOfOldCachedBody() async throws {
        let fixture = try G04DocumentFixture(); defer { fixture.cleanup() }
        try fixture.write("removed.txt", "old")
        _ = try await fixture.session.open("removed.txt")
        let token = try await fixture.session.beginExternalMutation()
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("removed.txt"))
        let service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: fixture.root))
        #expect(try await fixture.session.finishExternalMutation(token, service: service) == ["removed.txt"])
        #expect(try await fixture.session.tabs().isEmpty)
        // The failed read still releases the barrier for later normal IO.
        _ = try await fixture.session.createFile("new.txt", content: "new")
    }
}
