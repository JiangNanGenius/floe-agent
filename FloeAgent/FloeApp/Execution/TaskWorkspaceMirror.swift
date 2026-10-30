import CryptoKit
import Foundation
import FloeCore
import FloeExecution
import FloeEnvironments
import FloeTools

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

struct TaskWorkspaceFile: Codable, Sendable, Equatable {
    var path: String
    var bytes: Int64
    var digest: String
    var executable: Bool
}

/// A task-owned three-way file mirror. Existing SSH authentication and file
/// transactions are reused; neither a user's home nor a whole machine is copied.
///
/// Safety contract:
///  * only a root carrying `.floe-owner == environmentID` is read, written or
///    deleted; a foreign/unmarked root is preserved and the operation fails;
///  * local and remote scans reject symlinks, special files, traversal and
///    reserved transaction paths;
///  * both sides exchange expected digests; a conflict changes neither copy;
///  * transfers are bounded chunks and the complete file is re-hashed before a
///    replacement is installed (remote full SHA read-back, not a size check);
///  * an interrupted transfer resumes only after its existing partial prefix
///    is re-hashed and matches the other side; an unverifiable prefix restarts;
///  * cancellation removes this mirror's own staging file/directory, never a
///    foreign path, and never touches the source task workspace.
actor TaskWorkspaceMirror {
    struct SyncPlan: Equatable, Sendable {
        var downloads: [String] = []
        var uploads: [String] = []
        var conflicts: [String] = []
        var unchanged: [String] = []
    }

    enum TransferResume: Equatable, Sendable {
        case complete
        case restart
        case append(offset: Int64)
    }

    /// Journals created by this mirror carry this owner. A generic or
    /// unmarked transaction is never recovered or deleted by the mirror.
    static let transactionOwner = "task-workspace-mirror"

    /// Process-wide serialization for one local task root. Actor `busy` is
    /// keyed by environment, so two environments (or a foreground run and a
    /// migration) could otherwise overlay transactions on the same directory.
    private actor RootGate {
        static let shared = RootGate()
        private var held: Set<String> = []

        func acquire(_ key: String, _ cancellation: CancellationToken?) async throws {
            while held.contains(key) {
                // TaskCenter cancels through the token, not the job Task.
                // Checking both lets one waiter stop without releasing or
                // cancelling the owner of the root.
                try cancellation?.throwIfCancelled(); try Task.checkCancellation()
                try await Task.sleep(for: .milliseconds(30))
            }
            try cancellation?.throwIfCancelled(); try Task.checkCancellation()
            held.insert(key)
        }

        func release(_ key: String) {
            held.remove(key)
        }
    }

    private let ssh: SSHCommandService
    private var busy: Set<String> = []
    private static let chunkSize: Int64 = 32 * 1024
    private static let maxManifestBytes: Int64 = 256 * 1024 * 1024
    private static let excluded: Set<String> = [".git", ".floe", ".floe-transfer", ".floe-owner", ".venv", "venv", "node_modules", ".floe-env", ".floe-node", "__pycache__", EnvironmentFileTransaction.directoryName]
    init(ssh: SSHCommandService) { self.ssh = ssh }

    /// Local task-tree inventory. The root is resolved once so every returned
    /// path is relative to the exact directory that was scanned.
    static func files(root: URL, cancellation: CancellationToken? = nil) throws -> [TaskWorkspaceFile] {
        let root = canonicalRoot(root)
        guard root.path != "/" else { throw FloeError.validationFailed("The task workspace root is invalid") }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FloeError.notFound("Task files")
        }
        guard let walker = FileManager.default.enumerator(at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: []) else {
            throw FloeError.notFound("Task files")
        }
        var files: [TaskWorkspaceFile] = []
        for case let url as URL in walker {
            try cancellation?.throwIfCancelled(); try Task.checkCancellation()
            if excluded.contains(url.lastPathComponent) { walker.skipDescendants(); continue }
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else {
                throw FloeError.validationFailed("Resolve the symbolic link before moving: \(url.lastPathComponent)")
            }
            if values.isDirectory == true { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular else {
                throw FloeError.validationFailed("Only regular task files can be moved: \(url.lastPathComponent)")
            }
            let relative = try relativePath(url, root: root)
            _ = try EnvironmentFileTransaction.location(relative, root: root)
            let bytes = (attributes[.size] as? NSNumber)?.int64Value ?? 0
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            files.append(TaskWorkspaceFile(
                path: relative,
                bytes: bytes,
                digest: try FloeDigest.sha256Hex(ofFileAt: url, isCancelled: { cancellation?.isCancelled == true }),
                executable: (mode & 0o111) != 0
            ))
        }
        return files.sorted { $0.path < $1.path }
    }

    /// Pure three-way decision. A path changed on both sides in different ways
    /// is a conflict and is never scheduled for either direction.
    static func plan(local: [TaskWorkspaceFile], remote: [TaskWorkspaceFile], baseline: [TaskWorkspaceFile]) throws -> SyncPlan {
        let localMap = try uniqueMap(local)
        let remoteMap = try uniqueMap(remote)
        let before = try uniqueMap(baseline)
        var result = SyncPlan()
        // A non-empty baseline with an empty remote inventory is ambiguous:
        // it can be a real "delete everything" or a missing/unmounted target
        // re-created empty by ownership setup. Never turn that uncertainty
        // into local deletions; preserve both sides for an explicit decision.
        if !before.isEmpty, remoteMap.isEmpty, !localMap.isEmpty {
            result.conflicts = Set(localMap.keys).union(before.keys).sorted()
            return result
        }
        let paths = Set(localMap.keys).union(remoteMap.keys).union(before.keys).sorted()
        for path in paths {
            if localMap[path] == remoteMap[path] { result.unchanged.append(path); continue }
            if localMap[path] == before[path] { result.downloads.append(path) }
            else if remoteMap[path] == before[path] { result.uploads.append(path) }
            else { result.conflicts.append(path) }
        }
        return result
    }

    /// Both upload and download use the same rule: a complete partial must
    /// match the full digest; a shorter partial resumes only when its full
    /// digest equals the expected prefix digest. Anything else restarts.
    static func transferResumeDecision(
        expectedBytes: Int64,
        expectedDigest: String,
        partialBytes: Int64,
        partialDigest: String?,
        partialPrefixDigest: String?
    ) -> TransferResume {
        guard expectedBytes >= 0, partialBytes >= 0, partialBytes <= expectedBytes else { return .restart }
        if partialBytes == expectedBytes {
            return partialDigest == expectedDigest ? .complete : .restart
        }
        if partialBytes == 0 { return .append(offset: 0) }
        guard let partialDigest, let partialPrefixDigest, partialDigest == partialPrefixDigest else {
            return .restart
        }
        return .append(offset: partialBytes)
    }

    static func chunkCount(forBytes bytes: Int64, chunkSize: Int = 32 * 1024) -> Int64 {
        guard bytes > 0, chunkSize > 0 else { return 0 }
        return (bytes - 1) / Int64(chunkSize) + 1
    }

    /// Parses the bounded remote manifest. Paths are base64 in the manifest so
    /// whitespace, spaces and non-ASCII names survive without shell splitting.
    static func parseRemoteManifest(_ data: Data) throws -> [TaskWorkspaceFile] {
        guard let text = String(data: data, encoding: .utf8) else {
            throw FloeError.storageCorrupted("Remote file index")
        }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        var result: [TaskWorkspaceFile] = []
        var seen: Set<String> = []
        for line in lines {
            guard !line.isEmpty else { throw FloeError.storageCorrupted("Remote file index") }
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 4,
                  parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let bytes = Int64(parts[1]), bytes >= 0,
                  isSHA256(parts[2]),
                  parts[3] == "0" || parts[3] == "1",
                  let raw = Data(base64Encoded: String(parts[0]).filter { !$0.isWhitespace }),
                  let path = String(data: raw, encoding: .utf8),
                  !path.isEmpty,
                  !path.hasPrefix(EnvironmentFileTransaction.directoryName + "/"),
                  path != EnvironmentFileTransaction.directoryName,
                  !Self.isExcludedRemotePath(path),
                  seen.insert(path).inserted else {
                throw FloeError.storageCorrupted("Remote file index")
            }
            _ = try EnvironmentFileTransaction.location(path, root: URL(fileURLWithPath: "/floe-validation"))
            result.append(TaskWorkspaceFile(path: path, bytes: bytes, digest: String(parts[2]), executable: parts[3] == "1"))
        }
        return result.sorted { $0.path < $1.path }
    }

    static func isExcludedRemotePath(_ path: String) -> Bool {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !components.isEmpty, !components.contains(where: { $0.isEmpty }) else { return true }
        return components.contains { excluded.contains(String($0)) }
    }

    /// The explicit-cancel cleanup accepts only a canonical, deep, UUID-leaf
    /// remote task root. Exact ownership is checked again on the remote side.
    static func removableTaskRoot(_ raw: String) throws -> String {
        guard raw.hasPrefix("/"), raw != "/", !raw.hasSuffix("/"),
              !raw.contains("//"), !raw.contains("\0"), !raw.contains("\n"), !raw.contains("\r"),
              !raw.contains("\\") else {
            throw FloeError.validationFailed("The remote task root is invalid")
        }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.first?.isEmpty == true,
              parts.count - 1 >= 3,
              parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              let last = parts.last, UUID(uuidString: String(last)) != nil else {
            throw FloeError.validationFailed("The remote task root is invalid")
        }
        return raw
    }

    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Recovers a journal left by this mirror after a process death. The call
    /// is read-only when no journal exists. Foreign/unmarked, corrupt or active
    /// transactions are preserved and reported; the mirror never force-commits
    /// or deletes a transaction it does not own.
    @discardableResult
    static func recoverInterruptedFileTransaction(root: URL, cancellation: CancellationToken? = nil) throws -> Bool {
        try cancellation?.throwIfCancelled(); try Task.checkCancellation()
        let root = canonicalRoot(root)
        guard root.path != "/" else { throw FloeError.validationFailed("The task workspace root is invalid") }
        guard let pending = try EnvironmentFileTransaction.pendingTransaction(root: root) else { return false }
        try cancellation?.throwIfCancelled(); try Task.checkCancellation()
        if pending.isActive {
            throw FloeError.validationFailed("Another file operation is still using this task workspace. Wait for it to finish.")
        }
        guard let owner = pending.owner, owner == transactionOwner else {
            if pending.hasJournal {
                throw FloeError.validationFailed("A different file transaction is pending in this task workspace. Resolve it before syncing files.")
            }
            // A committed mirror commit removes payload files, then the
            // journal, then the owner marker. A crash in the final step can
            // leave an empty reserved directory; it contains no transaction
            // evidence, so reclaim it. A directory with any entry is preserved.
            let directory = try EnvironmentFileTransaction.location(
                EnvironmentFileTransaction.directoryName, root: root)
            if (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
                try FileManager.default.removeItem(at: directory)
                return true
            }
            throw FloeError.validationFailed("A file transaction without a recovery journal is present. Check this task's files before continuing.")
        }
        if pending.hasJournal, (pending.version ?? 1) < 2 {
            throw FloeError.validationFailed("A legacy file transaction is present in this task workspace. Resolve it before syncing files.")
        }
        try cancellation?.throwIfCancelled(); try Task.checkCancellation()
        return try EnvironmentFileTransaction.recover(root: root, cancellation: cancellation)
    }

    /// Async entry point for App callers that are about to read or write this
    /// task root outside `synchronize` (for example a linuxVM migration). It
    /// serializes with an in-flight mirror sync on the same root so recovery
    /// cannot inspect a transaction another operation is still building.
    @discardableResult
    func recoverInterruptedTransaction(root: URL, cancellation: CancellationToken? = nil) async throws -> Bool {
        let root = Self.canonicalRoot(root)
        let key = root.path
        try await Self.RootGate.shared.acquire(key, cancellation)
        do {
            let result = try Self.recoverInterruptedFileTransaction(root: root, cancellation: cancellation)
            await Self.RootGate.shared.release(key)
            return result
        } catch {
            await Self.RootGate.shared.release(key)
            throw error
        }
    }

    func synchronize(target: SSHShellTarget, root: URL, cancellation: CancellationToken?, stateDirectory: URL? = nil) async throws -> [TaskWorkspaceFile] {
        let root = Self.canonicalRoot(root)
        let rootKey = root.path
        try await Self.RootGate.shared.acquire(rootKey, cancellation)
        do {
            let result = try await synchronizeLocked(target: target, root: root,
                cancellation: cancellation, stateDirectory: stateDirectory)
            await Self.RootGate.shared.release(rootKey)
            return result
        } catch {
            await Self.RootGate.shared.release(rootKey)
            throw error
        }
    }

    private func synchronizeLocked(target: SSHShellTarget, root: URL, cancellation: CancellationToken?, stateDirectory: URL?) async throws -> [TaskWorkspaceFile] {
        guard target.remoteTaskRoot != "/" else { throw FloeError.validationFailed("The remote task root is invalid") }
        while busy.contains(target.environmentID) {
            try cancellation?.throwIfCancelled(); try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(30))
        }
        busy.insert(target.environmentID)
        defer { busy.remove(target.environmentID) }
        // Baseline is scoped to the exact host + remote root, not merely the
        // environment id: reusing a stale baseline against a fresh target
        // could otherwise interpret "remote empty" as a deletion and remove
        // local files. Runtime generation is intentionally excluded so a
        // reboot of the same target keeps its resumable baseline.
        let targetKey = FloeDigest.shortSHA256(Data("\(target.hostID.uuidString)\n\(target.remoteTaskRoot)".utf8), length: 24)
        let stateRoot = stateDirectory ?? root.appendingPathComponent(".floe/remote-sync/\(target.environmentID)/\(targetKey)", isDirectory: true)
        try Self.ensureLocalDirectory(stateRoot)
        // A process death during a previous commit must be repaired before any
        // inventory or plan. The journal directory is excluded from `files`,
        // so scanning first would silently ignore the half-installed state.
        _ = try Self.recoverInterruptedFileTransaction(root: root, cancellation: cancellation)
        let baselineURL = stateRoot.appendingPathComponent("baseline.json")
        let baseline = try Self.readBaseline(baselineURL)
        try await ensureOwned(target, cancellation)
        let local = try Self.files(root: root, cancellation: cancellation)
        let remote = try await remoteFiles(target, cancellation)
        let plan = try Self.plan(local: local, remote: remote, baseline: baseline)
        if let conflict = plan.conflicts.first {
            throw FloeError.validationFailed("The task files changed or the destination is empty. Resolve the file before continuing: \(conflict)")
        }
        let localMap = Dictionary(uniqueKeysWithValues: local.map { ($0.path, $0) })
        let remoteMap = Dictionary(uniqueKeysWithValues: remote.map { ($0.path, $0) })
        var staged: [String: URL] = [:]
        var keepStaged = false
        defer { if !keepStaged { for url in Set(staged.values) { try? FileManager.default.removeItem(at: url) } } }
        if !plan.downloads.isEmpty {
            let staging = stateRoot.appendingPathComponent("transfer", isDirectory: true)
            try Self.ensureLocalDirectory(staging)
            for path in plan.downloads {
                guard let file = remoteMap[path] else { continue }
                let url = staging.appendingPathComponent(file.digest + ".part")
                try await download(file, target: target, to: url, cancellation: cancellation)
                staged[path] = url
            }
            let transaction = try EnvironmentFileTransaction(root: root, paths: plan.downloads, owner: Self.transactionOwner)
            do {
                for path in plan.downloads {
                    let url = try EnvironmentFileTransaction.location(path, root: root)
                    let current = try FileManager.default.fileExists(atPath: url.path) ? FloeDigest.sha256Hex(ofFileAt: url) : nil
                    guard current == localMap[path]?.digest else { throw FloeError.validationFailed("The local file changed: \(path)") }
                    if let file = remoteMap[path] {
                        guard let stagedURL = staged[path] else {
                            throw FloeError.storageCorrupted("The downloaded file was not staged: \(path)")
                        }
                        try transaction.copy(from: stagedURL, to: path, digest: file.digest, mode: file.executable ? 0o755 : 0o644)
                    } else {
                        try transaction.remove(path)
                    }
                }
                try transaction.commit()
                for url in Set(staged.values) { try? FileManager.default.removeItem(at: url) }
                staged.removeAll()
            } catch {
                // Roll back through the owning instance so the active-owner
                // registry and journal identity are checked; the original
                // transfer error remains the one the caller sees. A failed
                // rollback leaves the journal and both file copies intact.
                _ = try? transaction.rollback()
                keepStaged = cancellation?.isCancelled != true && !(error is CancellationError)
                throw error
            }
        }
        for path in plan.uploads {
            try cancellation?.throwIfCancelled(); try Task.checkCancellation()
            if let file = localMap[path] {
                try await upload(file, root: root, target: target, expected: remoteMap[path]?.digest, cancellation: cancellation)
            } else {
                let destination = target.remoteTaskRoot + "/" + path
                guard let expected = remoteMap[path]?.digest else {
                    throw FloeError.validationFailed("The remote file identity changed: \(path)")
                }
                let script = """
                d=\(Self.quote(destination))
                [ ! -L "$d" ] && \(Self.noLinkChecks(destination, target: target)) && [ "$(hash_file "$d")" = \(Self.quote(expected)) ] && rm -f "$d"
                """
                _ = try await command(script, target, cancellation)
            }
        }
        let finalLocal = try Self.files(root: root, cancellation: cancellation)
        let finalRemote = try await remoteFiles(target, cancellation)
        guard finalLocal == finalRemote else { throw FloeError.validationFailed("Task files changed during transfer. Check them and retry.") }
        try JSONEncoder().encode(finalLocal).write(to: baselineURL, options: .atomic)
        return finalLocal
    }

    /// Removes one uncommitted migration target. The root must be the exact
    /// task-owned root (canonical, UUID leaf), not `/`, not a symlink, not
    /// behind a symlinked ancestor, and its `.floe-owner` must equal this
    /// environment. A missing root is already safe; a foreign/unmarked root is
    /// preserved and reported as a failure. No ancestor is ever removed.
    func removeOwnedTarget(target: SSHShellTarget, cancellation: CancellationToken) async throws {
        let root = try Self.removableTaskRoot(target.remoteTaskRoot)
        let owner = target.environmentID
        let script = """
        r=\(Self.quote(root)); o=\(Self.quote(owner))
        [ "$r" != "/" ] || exit 80
        if [ ! -e "$r" ] && [ ! -L "$r" ]; then exit 0; fi
        [ ! -L "$r" ] && [ -d "$r" ] || exit 81
        [ ! -L "$r/.floe-owner" ] && [ -f "$r/.floe-owner" ] || exit 82
        [ "$(cat "$r/.floe-owner")" = "$o" ] || exit 83
        if [ -e "$r/.floe-transfer" ] || [ -L "$r/.floe-transfer" ]; then
          [ ! -L "$r/.floe-transfer" ] && [ -d "$r/.floe-transfer" ] || exit 84
        fi
        [ "$(cd "$r" 2>/dev/null && pwd -P)" = "$r" ] || exit 85
        rm -rf "$r"
        """
        // This is the explicit cancellation cleanup path. It must not be
        // aborted by the token that just requested cancellation; ownership was
        // checked inside the same command immediately before the exact removal.
        _ = cancellation
        _ = try await command(script, target, nil, timeout: 120)
    }

    private func ensureOwned(_ target: SSHShellTarget, _ token: CancellationToken?) async throws {
        let root = Self.quote(target.remoteTaskRoot)
        let owner = Self.quote(target.environmentID)
        let transfer = Self.quote(target.remoteTaskRoot + "/.floe-transfer")
        let script = """
        r=\(root); o=\(owner); t=\(transfer)
        [ "$r" != "/" ] || exit 80
        if [ ! -e "$r" ] && [ ! -L "$r" ]; then
          mkdir -p "$(dirname "$r")" || exit 81
          mkdir "$r" || exit 81
          if ! printf '%s' "$o" > "$r/.floe-owner"; then
            rm -rf "$r"
            exit 81
          fi
        fi
        [ ! -L "$r" ] && [ -d "$r" ] || exit 82
        [ ! -L "$r/.floe-owner" ] && [ -f "$r/.floe-owner" ] || exit 83
        [ "$(cat "$r/.floe-owner")" = "$o" ] || exit 84
        if [ -e "$t" ] || [ -L "$t" ]; then
          [ ! -L "$t" ] && [ -d "$t" ] || exit 85
        else
          mkdir "$t" || exit 85
        fi
        """
        _ = try await command(script, target, token)
    }

    private func remoteFiles(_ target: SSHShellTarget, _ token: CancellationToken?) async throws -> [TaskWorkspaceFile] {
        let name = UUID().uuidString + ".manifest"
        let remotePath = target.remoteTaskRoot + "/.floe-transfer/" + name
        let excludes = Self.excluded.sorted().map { "-name " + Self.quote($0) }.joined(separator: " -o ")
        let predicate = "\\( \(excludes) \\) -prune -o"
        let script = """
        cd \(Self.quote(target.remoteTaskRoot)) || exit 71
        [ -z "$(find . \(predicate) -type l -print -quit)" ] || exit 72
        find . \(predicate) -type f -exec sh -c '
        for p do
          h=$(if command -v sha256sum >/dev/null; then sha256sum "$p"; else shasum -a 256 "$p"; fi) || exit 73
          h=${h%% *}; n=$(wc -c < "$p") || exit 73
          x=0; [ ! -x "$p" ] || x=1
          printf "%s\\t%s\\t%s\\t%s\\n" "$(printf %s "${p#./}" | base64 | tr -d "\\n")" "$n" "$h" "$x"
        done' sh {} + > \(Self.quote(".floe-transfer/" + name))
        """
        do {
            _ = try await command(script, target, token, timeout: 120)
            let sizeText = try await command("wc -c < \(Self.quote(remotePath))", target, token)
            guard let size = Int64(sizeText.trimmingCharacters(in: .whitespacesAndNewlines)),
                  size >= 0, size <= Self.maxManifestBytes else {
                throw FloeError.storageCorrupted("Remote file index")
            }
            var manifest = Data()
            manifest.reserveCapacity(min(Int(size), 1_048_576))
            var received: Int64 = 0
            for block in 0..<Self.chunkCount(forBytes: size) {
                let bytes = try await readBlock(remotePath, block: block, target: target, token: token)
                received += Int64(bytes.count)
                guard received <= size else { throw FloeError.storageCorrupted("Remote file index") }
                manifest.append(bytes)
            }
            guard received == size else { throw FloeError.storageCorrupted("Remote file index") }
            let result = try Self.parseRemoteManifest(manifest)
            try? await command("rm -f \(Self.quote(remotePath))", target, nil)
            return result
        } catch {
            try? await command("rm -f \(Self.quote(remotePath))", target, nil)
            throw error
        }
    }

    private func readBlock(_ path: String, block: Int64, target: SSHShellTarget, token: CancellationToken?) async throws -> Data {
        let text = try await command("dd if=\(Self.quote(path)) bs=32768 skip=\(block) count=1 2>/dev/null | base64", target, token)
        let compact = text.filter { !$0.isWhitespace }
        guard let bytes = Data(base64Encoded: compact, options: []), bytes.count <= Int(Self.chunkSize) else {
            throw FloeError.storageCorrupted("Remote file bytes")
        }
        return bytes
    }

    private func download(_ file: TaskWorkspaceFile, target: SSHShellTarget, to url: URL, cancellation: CancellationToken?) async throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = try Self.regularFileSize(at: url)
        var resume: TransferResume = .restart
        if let existing {
            if existing == file.bytes {
                let digest = try FloeDigest.sha256Hex(ofFileAt: url)
                resume = Self.transferResumeDecision(expectedBytes: file.bytes, expectedDigest: file.digest,
                    partialBytes: existing, partialDigest: digest, partialPrefixDigest: nil)
            } else if existing > file.bytes {
                resume = .restart
            } else {
                let aligned = (existing / Self.chunkSize) * Self.chunkSize
                if aligned != existing { try Self.truncateFile(at: url, to: aligned) }
                if aligned == 0 {
                    resume = .append(offset: 0)
                } else {
                    let prefix = try Self.prefixSHA256(fileAt: url, length: aligned)
                    let remotePrefix = try await remotePrefixDigest(target.remoteTaskRoot + "/" + file.path,
                                                                   bytes: aligned, target: target, token: cancellation)
                    resume = Self.transferResumeDecision(expectedBytes: file.bytes, expectedDigest: file.digest,
                        partialBytes: aligned, partialDigest: prefix, partialPrefixDigest: remotePrefix)
                }
            }
        }
        let start: Int64
        switch resume {
        case .complete: start = file.bytes
        case .restart: start = 0
        case .append(let offset): start = offset
        }
        if resume != .complete {
            guard start % Self.chunkSize == 0 else {
                throw FloeError.validationFailed("The remote transfer state is invalid")
            }
        }
        guard start <= file.bytes else {
            throw FloeError.validationFailed("The remote transfer state is invalid")
        }
        do {
            if start < file.bytes || resume != .complete {
                let flags = start == 0 ? (O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW) : (O_WRONLY | O_NOFOLLOW)
                let descriptor = try Self.openFile(at: url, flags: flags)
                let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                defer { try? handle.close() }
                if start > 0 {
                    guard ftruncate(descriptor, off_t(start)) == 0, lseek(descriptor, off_t(start), SEEK_SET) >= 0 else {
                        throw FloeError.validationFailed("The transfer staging could not be resumed")
                    }
                }
                for block in (start / Self.chunkSize)..<Self.chunkCount(forBytes: file.bytes) {
                    try cancellation?.throwIfCancelled(); try Task.checkCancellation()
                    let bytes = try await readBlock(target.remoteTaskRoot + "/" + file.path, block: block, target: target, token: cancellation)
                    let expected = block == Self.chunkCount(forBytes: file.bytes) - 1
                        ? file.bytes - block * Self.chunkSize : Self.chunkSize
                    guard Int64(bytes.count) == expected else {
                        throw FloeError.validationFailed("The remote file changed: \(file.path)")
                    }
                    try handle.write(contentsOf: bytes)
                }
                try handle.synchronize()
            }
            let finalSize = try Self.regularFileSize(at: url)
            guard finalSize == file.bytes,
                  try FloeDigest.sha256Hex(ofFileAt: url) == file.digest else {
                throw FloeError.validationFailed("The remote file changed: \(file.path)")
            }
        } catch {
            if cancellation?.isCancelled == true || error is CancellationError {
                try? FileManager.default.removeItem(at: url)
            }
            throw error
        }
    }

    private func remotePrefixDigest(_ path: String, bytes: Int64, target: SSHShellTarget, token: CancellationToken?) async throws -> String {
        let blocks = Self.chunkCount(forBytes: bytes)
        let value = try await command("dd if=\(Self.quote(path)) bs=32768 count=\(blocks) 2>/dev/null | hash_stream",
                                      target, token, timeout: 120)
        let digest = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isSHA256(digest) else { throw FloeError.storageCorrupted("Remote file bytes") }
        return digest
    }

    private func upload(_ file: TaskWorkspaceFile, root: URL, target: SSHShellTarget, expected: String?, cancellation: CancellationToken?) async throws {
        let local = try EnvironmentFileTransaction.location(file.path, root: root)
        guard try Self.regularFileSize(at: local) == file.bytes,
              try FloeDigest.sha256Hex(ofFileAt: local, isCancelled: { cancellation?.isCancelled == true }) == file.digest else {
            throw FloeError.validationFailed("The local file changed: \(file.path)")
        }
        let stage = target.remoteTaskRoot + "/.floe-transfer/" + file.digest + ".part"
        do {
            let query = try await command("""
            s=\(Self.quote(stage))
            if [ -L "$s" ]; then rm -f "$s" || exit 74; fi
            if [ -f "$s" ]; then
              n=$(wc -c < "$s") || exit 73
              h=$(hash_file "$s") || exit 73
              printf '%s %s\\n' "$n" "$h"
            else printf '0 -\\n'
            fi
            """, target, cancellation, timeout: 120)
            let fields = query.split(whereSeparator: { $0.isWhitespace })
            guard fields.count == 2, let stageBytes = Int64(fields[0]), stageBytes >= 0,
                  String(fields[1]) == "-" || Self.isSHA256(String(fields[1])) else {
                throw FloeError.storageCorrupted("Transfer staging")
            }
            let stageDigest: String? = String(fields[1]) == "-" ? nil : String(fields[1])
            var resume: TransferResume
            if stageBytes > file.bytes || stageBytes < 0 {
                resume = .restart
            } else if stageBytes == file.bytes {
                resume = Self.transferResumeDecision(expectedBytes: file.bytes, expectedDigest: file.digest,
                    partialBytes: stageBytes, partialDigest: stageDigest, partialPrefixDigest: nil)
            } else if stageBytes == 0 {
                resume = .append(offset: 0)
            } else {
                let prefix = try Self.prefixSHA256(fileAt: local, length: stageBytes)
                resume = Self.transferResumeDecision(expectedBytes: file.bytes, expectedDigest: file.digest,
                    partialBytes: stageBytes, partialDigest: stageDigest, partialPrefixDigest: prefix)
            }
            let start: Int64
            switch resume {
            case .complete: start = file.bytes
            case .restart: start = 0
            case .append(let offset): start = offset
            }
            guard start >= 0, start <= file.bytes else { throw FloeError.validationFailed("The transfer state is invalid") }
            if resume == .restart || start == 0 {
                _ = try await command("""
                s=\(Self.quote(stage))
                [ ! -L "$s" ] || rm -f "$s"
                : > "$s"
                """, target, cancellation)
            }
            if start < file.bytes {
                let reader = try FileHandle(forReadingFrom: local)
                defer { try? reader.close() }
                if start > 0 { try reader.seek(toOffset: UInt64(start)) }
                while let data = try reader.read(upToCount: Int(Self.chunkSize)), !data.isEmpty {
                    try cancellation?.throwIfCancelled(); try Task.checkCancellation()
                    _ = try await command("""
                    p=\(Self.quote(stage))
                    [ ! -L "$p" ] || exit 74
                    printf %s \(Self.quote(data.base64EncodedString())) | decode_base64 >> "$p"
                    """, target, cancellation)
                }
            }
            guard try FloeDigest.sha256Hex(ofFileAt: local, isCancelled: { cancellation?.isCancelled == true }) == file.digest else {
                throw FloeError.validationFailed("The local file changed: \(file.path)")
            }
            let destination = target.remoteTaskRoot + "/" + file.path
            let expectedCheck = expected.map { "[ \"$(hash_file \(Self.quote(destination)))\" = \(Self.quote($0)) ]" }
                ?? "[ ! -e \(Self.quote(destination)) ]"
            let script = """
            s=\(Self.quote(stage)); d=\(Self.quote(destination))
            [ ! -L "$s" ] && [ -f "$s" ] || exit 74
            [ "$(wc -c < "$s")" = "\(file.bytes)" ] || exit 75
            [ "$(hash_file "$s")" = "\(file.digest)" ] || exit 76
            \(Self.noLinkChecks(destination, target: target)) || exit 77
            \(expectedCheck) || exit 78
            mkdir -p \(Self.quote((destination as NSString).deletingLastPathComponent)) || exit 79
            chmod \(file.executable ? "755" : "644") "$s" || exit 80
            mv -f "$s" "$d"
            """
            _ = try await command(script, target, cancellation, timeout: 120)
        } catch {
            if cancellation?.isCancelled == true || error is CancellationError {
                try? await command("rm -f \(Self.quote(stage))", target, nil)
            }
            throw error
        }
    }

    private func command(_ script: String, _ target: SSHShellTarget, _ token: CancellationToken?, timeout: TimeInterval = 30) async throws -> String {
        try token?.throwIfCancelled(); try Task.checkCancellation()
        let prelude = """
        hash_file() { h=$(if command -v sha256sum >/dev/null; then sha256sum "$1"; else shasum -a 256 "$1"; fi) || return; printf %s "${h%% *}"; }; \
        hash_stream() { if command -v sha256sum >/dev/null; then sha256sum | cut -d ' ' -f1; else shasum -a 256 | cut -d ' ' -f1; fi; }; \
        decode_base64() { if printf '' | base64 -d >/dev/null 2>&1; then base64 -d; else base64 -D; fi; };
        """
        let value = try await ssh.run(command: "/bin/sh -c " + Self.quote(prelude + script), hostID: target.hostID,
                                      timeout: timeout, maxOutputBytes: 128 * 1024, cancellation: token)
        guard value.exitCode == 0, !value.truncated else {
            throw FloeError.validationFailed("File transfer did not finish. Check the connection and available storage.")
        }
        return value.stdout
    }

    private static func canonicalRoot(_ root: URL) -> URL {
        root.resolvingSymlinksInPath().standardizedFileURL
    }

    private static func relativePath(_ url: URL, root: URL) throws -> String {
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        guard url.path.hasPrefix(prefix) else { throw FloeError.validationFailed("The task file escaped its root") }
        return String(url.path.dropFirst(prefix.count))
    }

    private static func uniqueMap(_ files: [TaskWorkspaceFile]) throws -> [String: TaskWorkspaceFile] {
        var map: [String: TaskWorkspaceFile] = [:]
        for file in files {
            guard !file.path.isEmpty, file.bytes >= 0, isSHA256(file.digest),
                  map.updateValue(file, forKey: file.path) == nil else {
                throw FloeError.storageCorrupted("Duplicate or invalid task file entry")
            }
        }
        return map
    }

    private static func isSHA256<S: StringProtocol>(_ value: S) -> Bool {
        guard value.utf8.count == 64 else { return false }
        return value.utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }

    private static func ensureLocalDirectory(_ url: URL) throws {
        var info = stat()
        if lstat(url.path, &info) == 0 {
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFDIR) else {
                throw FloeError.validationFailed("Transfer state is not a directory")
            }
        } else if errno == ENOENT {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            throw FloeError.validationFailed("Transfer state is unreadable")
        }
    }

    private static func readBaseline(_ url: URL) throws -> [TaskWorkspaceFile] {
        guard let size = try regularFileSize(at: url) else { return [] }
        guard size <= maxManifestBytes else { throw FloeError.storageCorrupted("The task file baseline is too large") }
        let files = try JSONDecoder().decode([TaskWorkspaceFile].self, from: Data(contentsOf: url))
        _ = try uniqueMap(files)
        return files
    }

    private static func regularFileSize(at url: URL) throws -> Int64? {
        var info = stat()
        guard lstat(url.path, &info) == 0 else {
            if errno == ENOENT { return nil }
            throw FloeError.validationFailed("Transfer staging is unreadable")
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else {
            throw FloeError.validationFailed("Transfer staging is not a regular file")
        }
        return Int64(info.st_size)
    }

    private static func openFile(at url: URL, flags: Int32) throws -> Int32 {
        let descriptor = url.path.withCString { open($0, flags, mode_t(0o600)) }
        guard descriptor >= 0 else { throw FloeError.validationFailed("Transfer staging is unavailable") }
        return descriptor
    }

    private static func truncateFile(at url: URL, to length: Int64) throws {
        let descriptor = try openFile(at: url, flags: O_WRONLY | O_NOFOLLOW)
        defer { _ = close(descriptor) }
        guard ftruncate(descriptor, off_t(length)) == 0 else {
            throw FloeError.validationFailed("Transfer staging could not be truncated")
        }
    }

    private static func prefixSHA256(fileAt url: URL, length: Int64) throws -> String {
        guard length >= 0 else { throw FloeError.validationFailed("The transfer prefix is invalid") }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        var remaining = length
        while remaining > 0 {
            let count = Int(min(remaining, 1 << 20))
            guard let data = try handle.read(upToCount: count), !data.isEmpty else {
                throw FloeError.storageCorrupted("Transfer staging is shorter than its recorded prefix")
            }
            hasher.update(data: data)
            remaining -= Int64(data.count)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func noLinkChecks(_ destination: String, target: SSHShellTarget) -> String {
        var paths = [destination, target.remoteTaskRoot + "/.floe-transfer"]
        var current = target.remoteTaskRoot
        let components = destination.dropFirst(target.remoteTaskRoot.count + 1).split(separator: "/").dropLast()
        for component in components {
            current += "/" + component
            paths.append(current)
        }
        return paths.map { "[ ! -L \(quote($0)) ]" }.joined(separator: " && ")
    }
}
