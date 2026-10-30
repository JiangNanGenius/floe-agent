// FloeAppTests — task workspace three-way mirror contracts.
//
// These are source/static tests for the pure decisions and the local scan the
// real SSH mirror uses. No network, credential or device is involved. The
// end-to-end POSIX/SSH path remains a real-target check for the integration
// owner because `TaskWorkspaceMirror` deliberately consumes the existing
// `SSHCommandService` rather than introducing a test-only transport protocol.
//
// Covered here:
//  * local inventory rejects symlinks/special names and records exact bytes,
//    digests and execute bits while excluding protected trees;
//  * the three-way plan uploads/downloads only the changed side and leaves
//    both copies untouched on a genuine conflict;
//  * the remote manifest parser rejects duplicate/traversal/absolute/reserved
//    paths and malformed digests/flags/base64/UTF-8;
//  * a partial transfer resumes only when its full SHA-256 prefix equals the
//    expected prefix; otherwise it restarts, and chunks stay 32 KiB-bounded;
//  * the explicit-cancel root guard accepts only canonical deep UUID-leaf task
//    roots and rejects `/`, shallow or traversing paths;
//  * process-restart recovery restores only the recorded preimage/postimage,
//    preserves an independent edit or corrupt/foreign journal, refuses an
//    active owner, and stays read-only for inventory/status scans;
//  * shell quoting keeps a hostile path literal.
//
// The FloeAppTests target membership entry is carried by the integration
// owner's project.yml batch (this task must not edit project.yml).

#if canImport(UIKit)
import Foundation
import Testing
import FloeCore
import FloeEnvironments
import FloeExecution
import FloeTools
@testable import FloeApp

@Suite("Task workspace mirror contracts")
struct TaskWorkspaceMirrorTests: Sendable {
    // MARK: - Fixtures

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("floe-mirror-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func write(_ text: String, path: String, in root: URL, mode: Int? = nil) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if let mode {
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: url.path)
        }
        return url
    }

    private func file(_ path: String, _ text: String, executable: Bool = false) -> TaskWorkspaceFile {
        TaskWorkspaceFile(path: path, bytes: Int64(text.utf8.count),
                          digest: FloeDigest.sha256Hex(Data(text.utf8)), executable: executable)
    }

    private func base64(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
    }

    private func manifestLine(_ path: String, bytes: Int64, digest: String, executable: Bool = false) -> String {
        "\(base64(path))\t\(bytes)\t\(digest)\t\(executable ? "1" : "0")\n"
    }

    /// Leaves an uncommitted, mirror-owned journal behind. Returning from this
    /// function releases the in-process transaction object while the on-disk
    /// journal remains, which is the same state a process death leaves.
    private func crashTransaction(root: URL, paths: [String], writes: [String: String]) throws {
        let transaction = try EnvironmentFileTransaction(root: root, paths: paths,
            owner: TaskWorkspaceMirror.transactionOwner)
        for (path, text) in writes.sorted(by: { $0.key < $1.key }) {
            try transaction.write(Data(text.utf8), to: path)
        }
    }

    // MARK: - Local inventory

    @Test("files records exact bytes/digests/modes and excludes protected trees")
    func filesInventory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("hello", path: "notes.txt", in: root)
        try write("#!/bin/sh\necho hi\n", path: "scripts/run.sh", in: root, mode: 0o755)
        try write("", path: "empty.bin", in: root, mode: 0o644)
        try write("ignored", path: ".git/config", in: root)
        try write("ignored", path: "node_modules/pkg/index.js", in: root)
        try write("ignored", path: ".floe/remote-sync/x/baseline.json", in: root)
        try write("ignored", path: ".floe-transfer/manifest", in: root)

        let files = try TaskWorkspaceMirror.files(root: root)
        #expect(files.map(\.path) == ["empty.bin", "notes.txt", "scripts/run.sh"])
        #expect(files[0].bytes == 0)
        #expect(files[0].digest == FloeDigest.sha256Hex(Data()))
        #expect(files[1].digest == FloeDigest.sha256Hex(Data("hello".utf8)))
        #expect(!files[1].executable)
        #expect(files[2].executable)
        #expect(files[2].bytes == Int64(Data("#!/bin/sh\necho hi\n".utf8).count))
    }

    @Test("files rejects a symbolic link instead of following it")
    func filesRejectsSymlink() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("target", path: "notes.txt", in: root)
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link").path,
                                                   withDestinationPath: "notes.txt")
        #expect(throws: FloeError.self) {
            _ = try TaskWorkspaceMirror.files(root: root)
        }
    }

    @Test("files rejects names that cannot be represented as a safe POSIX relative path")
    func filesRejectsUnsafeNames() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("bad", path: "line\nbreak", in: root)
        #expect(throws: FloeError.self) {
            _ = try TaskWorkspaceMirror.files(root: root)
        }

        let second = try makeRoot()
        defer { try? FileManager.default.removeItem(at: second) }
        try write("bad", path: "back\\slash", in: second)
        #expect(throws: FloeError.self) {
            _ = try TaskWorkspaceMirror.files(root: second)
        }
    }

    @Test("files refuses the filesystem root and honours cancellation")
    func filesRefusesRootAndCancellation() throws {
        #expect(throws: FloeError.self) {
            _ = try TaskWorkspaceMirror.files(root: URL(fileURLWithPath: "/"))
        }
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("one", path: "one.txt", in: root)
        let token = CancellationToken()
        token.cancel()
        #expect(throws: FloeError.self) {
            _ = try TaskWorkspaceMirror.files(root: root, cancellation: token)
        }
    }

    // MARK: - Three-way plan

    @Test("plan uploads only the locally changed side and downloads only the remotely changed side")
    func planSeparatesDirections() throws {
        let a0 = file("a.txt", "a0"), a1 = file("a.txt", "a1")
        let b0 = file("b.txt", "b0"), b1 = file("b.txt", "b1")
        let plan = try TaskWorkspaceMirror.plan(local: [a1, b0], remote: [a0, b1], baseline: [a0, b0])
        #expect(plan.uploads == ["a.txt"])
        #expect(plan.downloads == ["b.txt"])
        #expect(plan.conflicts.isEmpty)
    }

    @Test("plan propagates additions and deletions in both directions")
    func planAdditionsAndDeletions() throws {
        let existing = file("old.txt", "old")
        let added = file("new.txt", "new")

        let localAdd = try TaskWorkspaceMirror.plan(local: [added], remote: [], baseline: [])
        #expect(localAdd.uploads == ["new.txt"])
        #expect(localAdd.downloads.isEmpty)

        let remoteAdd = try TaskWorkspaceMirror.plan(local: [], remote: [added], baseline: [])
        #expect(remoteAdd.downloads == ["new.txt"])
        #expect(remoteAdd.uploads.isEmpty)

        let localDelete = try TaskWorkspaceMirror.plan(local: [], remote: [existing], baseline: [existing])
        #expect(localDelete.uploads == ["old.txt"])

        // A partial remote deletion is unambiguous and propagates.
        let keep = file("keep.txt", "keep")
        let remotePartialDelete = try TaskWorkspaceMirror.plan(
            local: [existing, keep], remote: [keep], baseline: [existing, keep])
        #expect(remotePartialDelete.downloads == ["old.txt"])

        let bothDelete = try TaskWorkspaceMirror.plan(local: [], remote: [], baseline: [existing])
        #expect(bothDelete.unchanged == ["old.txt"])
        #expect(bothDelete.uploads.isEmpty)
        #expect(bothDelete.downloads.isEmpty)
    }

    @Test("plan treats a changed execute bit as content change")
    func planTracksExecuteBit() throws {
        let old = file("run.sh", "same", executable: false)
        let new = file("run.sh", "same", executable: true)
        let plan = try TaskWorkspaceMirror.plan(local: [new], remote: [old], baseline: [old])
        #expect(plan.uploads == ["run.sh"])
    }

    @Test("plan refuses to choose a side when both copies changed differently")
    func planConflictPreservesBoth() throws {
        let base = file("note.txt", "base")
        let local = file("note.txt", "local")
        let remote = file("note.txt", "remote")
        let plan = try TaskWorkspaceMirror.plan(local: [local], remote: [remote], baseline: [base])
        #expect(plan.conflicts == ["note.txt"])
        #expect(plan.uploads.isEmpty)
        #expect(plan.downloads.isEmpty)
        #expect(plan.unchanged.isEmpty)
    }

    @Test("plan refuses to interpret a baseline-backed empty remote as deletion")
    func planAmbiguousRemoteWipePreservesLocal() throws {
        let base = file("note.txt", "base")
        let plan = try TaskWorkspaceMirror.plan(local: [base], remote: [], baseline: [base])
        #expect(plan.conflicts == ["note.txt"])
        #expect(plan.uploads.isEmpty)
        #expect(plan.downloads.isEmpty)

        let bothGone = try TaskWorkspaceMirror.plan(local: [], remote: [], baseline: [base])
        #expect(bothGone.unchanged == ["note.txt"])
    }

    @Test("plan accepts both sides becoming byte-identical")
    func planIdenticalChangesAreNoOp() throws {
        let base = file("note.txt", "base")
        let same = file("note.txt", "same")
        let plan = try TaskWorkspaceMirror.plan(local: [same], remote: [same], baseline: [base])
        #expect(plan.unchanged == ["note.txt"])
        #expect(plan.conflicts.isEmpty)
    }

    @Test("plan rejects a duplicate or invalid baseline entry instead of silently choosing one")
    func planRejectsCorruptBaseline() throws {
        let valid = file("a.txt", "a")
        #expect(throws: FloeError.self) {
            _ = try TaskWorkspaceMirror.plan(local: [], remote: [], baseline: [valid, valid])
        }
        let corrupt = TaskWorkspaceFile(path: "a.txt", bytes: 1, digest: "not-a-digest", executable: false)
        #expect(throws: FloeError.self) {
            _ = try TaskWorkspaceMirror.plan(local: [], remote: [], baseline: [corrupt])
        }
    }

    // MARK: - Manifest parser

    @Test("parseRemoteManifest decodes base64 paths, bytes, digests and execute bits")
    func parseManifest() throws {
        let digestA = FloeDigest.sha256Hex(Data("a".utf8))
        let digestB = FloeDigest.sha256Hex(Data())
        let manifest = manifestLine("dir/a b.txt", bytes: 1, digest: digestA, executable: true)
            + manifestLine("empty.bin", bytes: 0, digest: digestB)
        let files = try TaskWorkspaceMirror.parseRemoteManifest(Data(manifest.utf8))
        #expect(files.map(\.path) == ["dir/a b.txt", "empty.bin"])
        #expect(files[0].bytes == 1)
        #expect(files[0].digest == digestA)
        #expect(files[0].executable)
        #expect(files[1].bytes == 0)
        #expect(!files[1].executable)
        #expect(try TaskWorkspaceMirror.parseRemoteManifest(Data()).isEmpty)
    }

    @Test("parseRemoteManifest fails closed on malformed or unsafe rows")
    func parseManifestRejectsUnsafeRows() throws {
        let digest = String(repeating: "a", count: 64)
        let badRows: [String] = [
            manifestLine("x", bytes: 1, digest: digest) + manifestLine("x", bytes: 1, digest: digest),
            "\(base64("x"))\t1\t\(String(repeating: "A", count: 64))\t0\n",
            "\(base64("x"))\t1\t\(String(repeating: "a", count: 63))\t0\n",
            "\(base64("x"))\t-1\t\(digest)\t0\n",
            "\(base64("x"))\t1.0\t\(digest)\t0\n",
            "\(base64("x"))\t9223372036854775808\t\(digest)\t0\n",
            "\(base64("x"))\t1\t\(digest)\t2\n",
            "\(base64("x"))\t1\t\(digest)\n",
            "not-base64\t1\t\(digest)\t0\n",
            "\(base64("../escape"))\t1\t\(digest)\t0\n",
            "\(base64("/absolute"))\t1\t\(digest)\t0\n",
            "\(base64(""))\t1\t\(digest)\t0\n",
            "\(base64("./x"))\t1\t\(digest)\t0\n",
            "\(base64("x/../y"))\t1\t\(digest)\t0\n",
            "\(base64("x//y"))\t1\t\(digest)\t0\n",
            "\(base64("x\\y"))\t1\t\(digest)\t0\n",
            "\(base64("x\ny"))\t1\t\(digest)\t0\n",
            "\(base64(".floe-package-transaction/x"))\t1\t\(digest)\t0\n",
            "\(base64(".git/config"))\t1\t\(digest)\t0\n",
            "\(base64("node_modules/pkg/index.js"))\t1\t\(digest)\t0\n",
            "\(base64(".floe/private"))\t1\t\(digest)\t0\n",
            "\(base64("nested/.git/config"))\t1\t\(digest)\t0\n",
            "\(base64("nested/.floe-transfer/x"))\t1\t\(digest)\t0\n",
            "\(Data([0xff]).base64EncodedString())\t1\t\(digest)\t0\n",
            "\n"
        ]
        for row in badRows {
            #expect(throws: FloeError.self) {
                _ = try TaskWorkspaceMirror.parseRemoteManifest(Data(row.utf8))
            }
        }
    }

    // MARK: - Resume policy and chunks

    @Test("transferResumeDecision completes only a full digest, resumes only a verified prefix")
    func transferResumePolicy() {
        let digest = String(repeating: "a", count: 64)
        let other = String(repeating: "b", count: 64)
        #expect(TaskWorkspaceMirror.transferResumeDecision(
            expectedBytes: 10, expectedDigest: digest, partialBytes: 10,
            partialDigest: digest, partialPrefixDigest: nil) == .complete)
        #expect(TaskWorkspaceMirror.transferResumeDecision(
            expectedBytes: 10, expectedDigest: digest, partialBytes: 10,
            partialDigest: other, partialPrefixDigest: nil) == .restart)
        #expect(TaskWorkspaceMirror.transferResumeDecision(
            expectedBytes: 10, expectedDigest: digest, partialBytes: 4,
            partialDigest: digest, partialPrefixDigest: digest) == .append(offset: 4))
        #expect(TaskWorkspaceMirror.transferResumeDecision(
            expectedBytes: 10, expectedDigest: digest, partialBytes: 4,
            partialDigest: other, partialPrefixDigest: digest) == .restart)
        #expect(TaskWorkspaceMirror.transferResumeDecision(
            expectedBytes: 10, expectedDigest: digest, partialBytes: 4,
            partialDigest: digest, partialPrefixDigest: nil) == .restart)
        #expect(TaskWorkspaceMirror.transferResumeDecision(
            expectedBytes: 10, expectedDigest: digest, partialBytes: 11,
            partialDigest: digest, partialPrefixDigest: digest) == .restart)
        #expect(TaskWorkspaceMirror.transferResumeDecision(
            expectedBytes: 10, expectedDigest: digest, partialBytes: 0,
            partialDigest: nil, partialPrefixDigest: nil) == .append(offset: 0))
        #expect(TaskWorkspaceMirror.transferResumeDecision(
            expectedBytes: 10, expectedDigest: digest, partialBytes: -1,
            partialDigest: nil, partialPrefixDigest: nil) == .restart)
    }

    @Test("chunkCount is bounded at 32 KiB and cannot overflow Int64")
    func chunkCountIsBounded() {
        #expect(TaskWorkspaceMirror.chunkCount(forBytes: 0) == 0)
        #expect(TaskWorkspaceMirror.chunkCount(forBytes: 1) == 1)
        #expect(TaskWorkspaceMirror.chunkCount(forBytes: 32 * 1024) == 1)
        #expect(TaskWorkspaceMirror.chunkCount(forBytes: 32 * 1024 + 1) == 2)
        #expect(TaskWorkspaceMirror.chunkCount(forBytes: 64 * 1024) == 2)
        #expect(TaskWorkspaceMirror.chunkCount(forBytes: Int64.max) > 0)
        #expect(TaskWorkspaceMirror.chunkCount(forBytes: 10, chunkSize: 0) == 0)
    }

    // MARK: - Explicit-cancel root guard and quoting

    @Test("removableTaskRoot accepts only canonical deep UUID-leaf task roots")
    func removableRootGuard() throws {
        let id = UUID().uuidString.lowercased()
        #expect(try TaskWorkspaceMirror.removableTaskRoot("/home/floe/.floe/tasks/\(id)") == "/home/floe/.floe/tasks/\(id)")
        #expect(try TaskWorkspaceMirror.removableTaskRoot("/srv/floe/tasks/\(id)") == "/srv/floe/tasks/\(id)")

        let bad = [
            "/", "/tmp", "/home/floe", "/home/floe/.floe",
            "/home/floe/tasks/not-a-uuid",
            "/home/floe/tasks/\(id)/child",
            "/home/floe/tasks/\(id)/",
            "/home/floe/tasks//\(id)",
            "/home/floe/tasks/../\(id)",
            "/home/floe/tasks/./\(id)",
            "/home/floe/tasks/\(id)\n",
            "/home/floe/tasks/\(id)\\child",
            "home/floe/tasks/\(id)"
        ]
        for root in bad {
            #expect(throws: FloeError.self) {
                _ = try TaskWorkspaceMirror.removableTaskRoot(root)
            }
        }
    }

    @Test("shell quote keeps hostile text literal")
    func shellQuote() {
        #expect(TaskWorkspaceMirror.quote("plain/path") == "'plain/path'")
        #expect(TaskWorkspaceMirror.quote("it's") == "'it'\\''s'")
        #expect(TaskWorkspaceMirror.quote("$HOME; rm -rf /") == "'$HOME; rm -rf /'")
        #expect(TaskWorkspaceMirror.quote("a b\tc") == "'a b\tc'")
    }

    // MARK: - Process-restart recovery

    @Test("mirror recovery restores the preimage, removes a created file and clears an owned journal")
    func mirrorRecoveryAfterSimulatedProcessDeath() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let notes = try write("original", path: "notes.txt", in: root, mode: 0o640)
        try crashTransaction(root: root, paths: ["notes.txt", "created.txt"],
                             writes: ["notes.txt": "changed", "created.txt": "new"])
        // A staged orphan from the interrupted commit must not confuse recovery.
        try Data("partial".utf8).write(to: root.appendingPathComponent(
            "\(EnvironmentFileTransaction.directoryName)/staged-orphan"))

        #expect(try TaskWorkspaceMirror.recoverInterruptedFileTransaction(root: root))
        #expect(try String(contentsOf: notes, encoding: .utf8) == "original")
        let attributes = try FileManager.default.attributesOfItem(atPath: notes.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("created.txt").path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(
            EnvironmentFileTransaction.directoryName).path))
    }

    @Test("mirror recovery rolls back only entries the interrupted transaction actually mutated")
    func mirrorRecoveryPartialTransaction() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let one = try write("one-base", path: "one.txt", in: root)
        let two = try write("two-base", path: "two.txt", in: root)
        try crashTransaction(root: root, paths: ["one.txt", "two.txt"], writes: ["one.txt": "one-new"])

        #expect(try TaskWorkspaceMirror.recoverInterruptedFileTransaction(root: root))
        #expect(try String(contentsOf: one, encoding: .utf8) == "one-base")
        #expect(try String(contentsOf: two, encoding: .utf8) == "two-base")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(
            EnvironmentFileTransaction.directoryName).path))
    }

    @Test("mirror recovery restores a file removed by an interrupted transaction")
    func mirrorRecoveryRestoresRemoval() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try write("keep", path: "note.txt", in: root, mode: 0o600)
        do {
            let transaction = try EnvironmentFileTransaction(root: root, paths: ["note.txt"],
                owner: TaskWorkspaceMirror.transactionOwner)
            try transaction.remove("note.txt")
        }
        #expect(!FileManager.default.fileExists(atPath: note.path))

        #expect(try TaskWorkspaceMirror.recoverInterruptedFileTransaction(root: root))
        #expect(try String(contentsOf: note, encoding: .utf8) == "keep")
        let attributes = try FileManager.default.attributesOfItem(atPath: note.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test("mirror recovery never overwrites an independent edit and keeps both copies")
    func mirrorRecoveryPreservesIndependentEdit() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try write("base", path: "note.txt", in: root, mode: 0o644)
        try crashTransaction(root: root, paths: ["note.txt"], writes: ["note.txt": "transaction"])
        try write("independent", path: "note.txt", in: root, mode: 0o600)

        do {
            _ = try TaskWorkspaceMirror.recoverInterruptedFileTransaction(root: root)
            Issue.record("Expected recovery to refuse an independently edited file")
        } catch let error as FloeError {
            #expect(error.localizedDescription.contains("note.txt"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(try String(contentsOf: note, encoding: .utf8) == "independent")
        let directory = root.appendingPathComponent(EnvironmentFileTransaction.directoryName)
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(try String(contentsOf: directory.appendingPathComponent("backup-0"),
                           encoding: .utf8) == "base")
        #expect(try EnvironmentFileTransaction.pendingTransaction(root: root)?.owner
            == TaskWorkspaceMirror.transactionOwner)
    }

    @Test("mirror recovery refuses a transaction that a live operation still owns")
    func mirrorRecoveryRefusesActiveTransaction() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try write("base", path: "note.txt", in: root)
        let transaction = try EnvironmentFileTransaction(root: root, paths: ["note.txt"],
            owner: TaskWorkspaceMirror.transactionOwner)
        try transaction.write(Data("transaction".utf8), to: "note.txt")
        #expect(try EnvironmentFileTransaction.pendingTransaction(root: root)?.isActive == true)

        do {
            _ = try TaskWorkspaceMirror.recoverInterruptedFileTransaction(root: root)
            Issue.record("Expected recovery to refuse an active transaction")
        } catch let error as FloeError {
            #expect(error.localizedDescription.contains("still using"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(try String(contentsOf: note, encoding: .utf8) == "transaction")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(
            EnvironmentFileTransaction.directoryName).path))
        try transaction.commit()
    }

    @Test("an owning transaction rolls back its own failure while the original error is rethrown")
    func owningTransactionRollsBackAfterFailure() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try write("base", path: "note.txt", in: root)
        let transaction = try EnvironmentFileTransaction(root: root, paths: ["note.txt"],
            owner: TaskWorkspaceMirror.transactionOwner)
        try transaction.write(Data("changed".utf8), to: "note.txt")
        struct SimulatedFailure: Error {}
        var original: Error?
        do {
            throw SimulatedFailure()
        } catch {
            original = error
            do { _ = try transaction.rollback() }
            catch { Issue.record("Own rollback failed: \(error)") }
        }
        #expect(original.map { $0 is SimulatedFailure } == true)
        #expect(try String(contentsOf: note, encoding: .utf8) == "base")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(
            EnvironmentFileTransaction.directoryName).path))
        #expect(try !TaskWorkspaceMirror.recoverInterruptedFileTransaction(root: root))
    }

    @Test("an owning rollback refuses a journal that now belongs to another owner")
    func owningRollbackRefusesForeignJournal() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try write("base", path: "note.txt", in: root)
        let transaction = try EnvironmentFileTransaction(root: root, paths: ["note.txt"],
            owner: TaskWorkspaceMirror.transactionOwner)
        try transaction.write(Data("changed".utf8), to: "note.txt")
        let journal = root.appendingPathComponent(
            "\(EnvironmentFileTransaction.directoryName)/journal.json")
        guard var object = try JSONSerialization.jsonObject(with: Data(contentsOf: journal)) as? [String: Any] else {
            Issue.record("The journal was not a JSON object")
            return
        }
        object["owner"] = "another-owner"
        try JSONSerialization.data(withJSONObject: object).write(to: journal)

        do {
            _ = try transaction.rollback()
            Issue.record("Expected rollback to refuse a replaced journal")
        } catch let error as FloeError {
            #expect(error.localizedDescription.contains("no longer owned"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(try String(contentsOf: note, encoding: .utf8) == "changed")
        #expect(FileManager.default.fileExists(atPath: journal.path))
    }

    @Test("owned recovery checks cancellation before touching the journal")
    func mirrorRecoveryCancellation() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try write("base", path: "note.txt", in: root)
        try crashTransaction(root: root, paths: ["note.txt"], writes: ["note.txt": "transaction"])
        let token = CancellationToken()
        token.cancel()
        #expect(throws: FloeError.self) {
            _ = try TaskWorkspaceMirror.recoverInterruptedFileTransaction(root: root, cancellation: token)
        }
        #expect(try String(contentsOf: note, encoding: .utf8) == "transaction")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(
            EnvironmentFileTransaction.directoryName).path))
    }

    @Test("mirror recovery discards its own pre-mutation initialization directory")
    func mirrorRecoveryDiscardsOwnedInitializationDirectory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try write("base", path: "note.txt", in: root)
        do {
            let transaction = try EnvironmentFileTransaction(root: root, paths: ["note.txt"],
                owner: TaskWorkspaceMirror.transactionOwner)
            // Simulate a crash after the owner marker/backup copy but before
            // the journal was persisted: no target file was ever mutated.
            try FileManager.default.removeItem(at: root.appendingPathComponent(
                "\(EnvironmentFileTransaction.directoryName)/journal.json"))
            _ = transaction
        }
        #expect(try TaskWorkspaceMirror.recoverInterruptedFileTransaction(root: root))
        #expect(try String(contentsOf: note, encoding: .utf8) == "base")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent(
            EnvironmentFileTransaction.directoryName).path))
    }

    @Test("mirror recovery refuses a legacy owner-tagged journal without receipts")
    func mirrorRecoveryRefusesLegacyOwnedJournal() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try write("base", path: "note.txt", in: root)
        let directory = root.appendingPathComponent(EnvironmentFileTransaction.directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: note, to: directory.appendingPathComponent("backup-0"))
        try Data(TaskWorkspaceMirror.transactionOwner.utf8)
            .write(to: directory.appendingPathComponent("owner"))
        try write("changed", path: "note.txt", in: root)
        let journal: [String: Any] = [
            "entries": [["path": "note.txt", "backup": "backup-0"]],
            "committed": false,
            "owner": TaskWorkspaceMirror.transactionOwner
        ]
        try JSONSerialization.data(withJSONObject: journal)
            .write(to: directory.appendingPathComponent("journal.json"))

        do {
            _ = try TaskWorkspaceMirror.recoverInterruptedFileTransaction(root: root)
            Issue.record("Expected recovery to refuse a legacy journal")
        } catch let error as FloeError {
            #expect(error.localizedDescription.contains("legacy"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(try String(contentsOf: note, encoding: .utf8) == "changed")
        #expect(FileManager.default.fileExists(atPath: directory.path))

        #expect(try EnvironmentFileTransaction.recover(root: root))
        #expect(try String(contentsOf: note, encoding: .utf8) == "base")
    }

    @Test("mirror recovery preserves an unmarked generic transaction")
    func mirrorRecoveryPreservesForeignTransaction() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try write("base", path: "note.txt", in: root)
        do {
            let transaction = try EnvironmentFileTransaction(root: root, paths: ["note.txt"])
            try transaction.write(Data("foreign".utf8), to: "note.txt")
        }

        do {
            _ = try TaskWorkspaceMirror.recoverInterruptedFileTransaction(root: root)
            Issue.record("Expected recovery to refuse an unmarked transaction")
        } catch let error as FloeError {
            #expect(error.localizedDescription.contains("different file transaction"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(try String(contentsOf: note, encoding: .utf8) == "foreign")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(
            EnvironmentFileTransaction.directoryName).path))

        // The owning generic caller can still recover it; the mirror only
        // refused to touch a journal it does not own.
        #expect(try EnvironmentFileTransaction.recover(root: root))
        #expect(try String(contentsOf: note, encoding: .utf8) == "base")
    }

    @Test("mirror recovery preserves a corrupt journal instead of deleting or committing it")
    func mirrorRecoveryPreservesCorruptJournal() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try write("base", path: "note.txt", in: root)
        try crashTransaction(root: root, paths: ["note.txt"], writes: ["note.txt": "transaction"])
        let journal = root.appendingPathComponent(
            "\(EnvironmentFileTransaction.directoryName)/journal.json")
        let corrupt = Data("not-a-journal".utf8)
        try corrupt.write(to: journal)

        do {
            _ = try TaskWorkspaceMirror.recoverInterruptedFileTransaction(root: root)
            Issue.record("Expected recovery to refuse a corrupt journal")
        } catch let error as FloeError {
            #expect(error.localizedDescription.contains("unreadable"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(try Data(contentsOf: journal) == corrupt)
        #expect(try String(contentsOf: note, encoding: .utf8) == "transaction")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(
            EnvironmentFileTransaction.directoryName).path))
    }

    @Test("mirror recovery never deletes an unmarked transaction directory without a journal")
    func mirrorRecoveryPreservesUnmarkedEmptyDirectory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(EnvironmentFileTransaction.directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("evidence".utf8).write(to: directory.appendingPathComponent("intruder"))

        do {
            _ = try TaskWorkspaceMirror.recoverInterruptedFileTransaction(root: root)
            Issue.record("Expected recovery to refuse an unmarked directory")
        } catch let error as FloeError {
            #expect(error.localizedDescription.contains("without a recovery journal"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
        #expect(FileManager.default.fileExists(atPath: directory.path))
        #expect(try String(contentsOf: directory.appendingPathComponent("intruder"),
                           encoding: .utf8) == "evidence")
    }

    @Test("mirror recovery reclaims only an empty reserved directory left by committed cleanup")
    func mirrorRecoveryDiscardsEmptyUnmarkedDirectory() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(EnvironmentFileTransaction.directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(try TaskWorkspaceMirror.recoverInterruptedFileTransaction(root: root))
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("a committed mirror journal is discarded without rolling back committed files")
    func mirrorRecoveryCommittedJournal() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try write("committed", path: "note.txt", in: root, mode: 0o644)
        let directory = root.appendingPathComponent(EnvironmentFileTransaction.directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("base".utf8).write(to: directory.appendingPathComponent("backup-0"))
        try Data(TaskWorkspaceMirror.transactionOwner.utf8)
            .write(to: directory.appendingPathComponent("owner"))
        let journal: [String: Any] = [
            "entries": [[
                "path": "note.txt",
                "backup": "backup-0",
                "preimageDigest": FloeDigest.sha256Hex(Data("base".utf8)),
                "preimageMode": 0o644,
                "postimageDigest": FloeDigest.sha256Hex(Data("committed".utf8)),
                "postimageMode": 0o644
            ]],
            "committed": true,
            "version": 2,
            "owner": TaskWorkspaceMirror.transactionOwner,
            "id": UUID().uuidString
        ]
        try JSONSerialization.data(withJSONObject: journal)
            .write(to: directory.appendingPathComponent("journal.json"))

        #expect(try TaskWorkspaceMirror.recoverInterruptedFileTransaction(root: root))
        #expect(try String(contentsOf: note, encoding: .utf8) == "committed")
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }

    @Test("inventory and status reads leave an interrupted journal untouched")
    func mirrorInventoryIsReadOnly() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try write("base", path: "note.txt", in: root)
        try crashTransaction(root: root, paths: ["note.txt"], writes: ["note.txt": "transaction"])
        let journal = root.appendingPathComponent(
            "\(EnvironmentFileTransaction.directoryName)/journal.json")
        let before = try Data(contentsOf: journal)

        let files = try TaskWorkspaceMirror.files(root: root)
        #expect(files.map(\.path) == ["note.txt"])
        #expect(try Data(contentsOf: journal) == before)
        #expect(try String(contentsOf: note, encoding: .utf8) == "transaction")
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(
            EnvironmentFileTransaction.directoryName).path))
    }

    @Test("mirror recovery is a read-only no-op when no journal exists")
    func mirrorRecoveryWithoutJournal() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try write("keep", path: "note.txt", in: root)
        #expect(try !TaskWorkspaceMirror.recoverInterruptedFileTransaction(root: root))
        #expect(try String(contentsOf: note, encoding: .utf8) == "keep")
    }

    @Test("mirror recovery restores a multi-megabyte preimage and its mode")
    func mirrorRecoveryLargeFile() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let size = 3 * 1024 * 1024 + 17
        var original = Data(count: size)
        for index in 0..<size { original[index] = UInt8(truncatingIfNeeded: index &* 7) }
        let url = root.appendingPathComponent("large.bin")
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o754)],
            ofItemAtPath: url.path)
        try crashTransaction(root: root, paths: ["large.bin"],
                             writes: ["large.bin": String(repeating: "x", count: size)])

        #expect(try TaskWorkspaceMirror.recoverInterruptedFileTransaction(root: root))
        let restored = try Data(contentsOf: url)
        #expect(restored == original)
        #expect(restored.count > 1 << 20)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o754)
    }

    @Test("legacy journals without receipts keep the original generic rollback contract")
    func legacyJournalRollback() throws {
        let root = try makeRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let note = try write("base", path: "note.txt", in: root)
        let directory = root.appendingPathComponent(EnvironmentFileTransaction.directoryName)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: note, to: directory.appendingPathComponent("backup-0"))
        try write("changed", path: "note.txt", in: root)
        let journal: [String: Any] = [
            "entries": [["path": "note.txt", "backup": "backup-0"]],
            "committed": false
        ]
        try JSONSerialization.data(withJSONObject: journal)
            .write(to: directory.appendingPathComponent("journal.json"))

        #expect(try EnvironmentFileTransaction.recover(root: root))
        #expect(try String(contentsOf: note, encoding: .utf8) == "base")
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}
#endif
