// SPDX-License-Identifier: MPL-2.0
//
// S11 — the TRUSTED HOST folder-staging seam (RB7 SAF handoff).
//
// This is the module API the Android host adapter (floe_skills_folder_staging
// JNI TU → these @_cdecls) calls while copying a user-picked DocumentProvider
// tree into the Skills DOMAIN's OWN scratch space. It is the narrow trusted
// ingress the RB-6 binding handoff declared
// (`SkillsDomain.registerStagedFolder ⇄ SAF host copy (never a wire path)`):
//
//   * every identity is an opaque ASCII receipt (sfk/sft/sfi prefixes); a
//     raw filesystem path NEVER crosses the boundary in either direction,
//     and the caller can never name a directory — the DOMAIN allocates it
//     (`SkillsDomain.hostCreateStagingDirectory` under its own staging root,
//     binding-fenced like every other domain entry point);
//   * the route is bound to the ACTUAL accepted native Root epoch plus the
//     caller-captured request incarnation and host UI admission generation.
//     A retired/foreign generation fences every subsequent call on that
//     lane (-402): a late callback can never touch a newer root;
//   * the copy enforces the ORIGINAL validator budgets BEFORE the domain
//     sees the tree (256 files / 2 MiB per file / 8 MiB package /
//     depth 16 / original segment-safety + case-canonical duplicate
//     rules), so an adversarial or oversize selection is a typed refusal
//     with the owned directory removed, never a partial success;
//   * `treeFinish` computes the ORIGINAL canonical digest over the REAL
//     disk inventory (`SkillPackageValidator.canonicalDigest` over the
//     scanned files) and registers through
//     `SkillsDomain.registerStagedFolder(directory:receipt:now:)`, which
//     RE-computes and re-validates everything itself. Only a match yields
//     the domain-minted `stg:v1:` receipt of the CURRENT epoch; on any
//     refusal the owned tree is removed (recoverable cleanup).
//   * nothing here installs, grants permissions, or owns approvals: the
//     receipt only ever re-enters the world through the closed
//     `folder.import` payload, whose ORIGINAL validation/review/trust
//     gates (and the runtime approval policy) remain the sole authority.
//     There is deliberately NO model-callable path: no command, envelope
//     or JSON field ever reaches this seam — only the trusted JNI host.
//
// Registration honesty: this file adds no command key, no configuration
// label, no second store and no second approval system. It reads the ONE
// live installed composition (`G02RuntimeComposition.shared
// .installedComposition`) and the ONE bootstrap generation
// (`AndroidRuntimeBootstrap.currentPumps()`); when either is absent it
// refuses (-401/-402) exactly like the accepted attachment bridge does
// before install. File I/O uses the SAME Foundation primitives as the
// accepted attachment staging lane (FileHandle + synchronize), so the
// seam is platform-portable without C imports.
import Foundation
import FloeSkills

// MARK: - Typed status space (DISJOINT additive range; see the Kotlin
// SkillsFolderStagingNative contract doc for the mirrored table)

public enum SkillsFolderHostStatus {
    public static let ok: Int32 = 0
    public static let invalidArguments: Int32 = -400
    public static let notInstalled: Int32 = -401
    public static let epochFenced: Int32 = -402
    public static let routeUnknown: Int32 = -403
    public static let treeUnknown: Int32 = -404
    public static let fileUnknown: Int32 = -405
    public static let pathUnsafe: Int32 = -406
    public static let duplicatePath: Int32 = -407
    public static let fileCountExceeded: Int32 = -408
    public static let bytesExceeded: Int32 = -409
    public static let depthExceeded: Int32 = -410
    public static let diskFull: Int32 = -411
    public static let writeFailed: Int32 = -412
    public static let aborted: Int32 = -413
    public static let digestMismatch: Int32 = -414
    public static let receiptRefused: Int32 = -415
    public static let saturated: Int32 = -416
    public static let bufferTooSmall: Int32 = -417
    public static let `internal`: Int32 = -499
}

// MARK: - Opaque receipts (same canonical shape rule as every RB6 token)

private enum SkillsFolderReceipt {
    static let routePrefix = "sfk:v1:"
    static let treePrefix = "sft:v1:"
    static let filePrefix = "sfi:v1:"

    static func make(prefix: String) -> String {
        var random = Data(count: 16)
        for index in random.indices { random[index] = UInt8.random(in: 0...255) }
        return prefix + random.map { String(format: "%02x", $0) }.joined()
    }

    static func isValid(_ value: String, prefix: String) -> Bool {
        let bytes = value.utf8
        guard bytes.count == prefix.utf8.count + 32, value.hasPrefix(prefix) else {
            return false
        }
        return value.dropFirst(prefix.count).utf8.allSatisfy { byte in
            (byte >= 48 && byte <= 57) || (byte >= 97 && byte <= 102)
        }
    }
}

// MARK: - Copy budgets (mirrors of the ORIGINAL closed limits; the domain
// validator remains the authority that re-checks everything)

private struct SkillsFolderBudgets {
    /// SkillValidationLimits defaults (FloeSkills/SkillModels.swift):
    let maximumFileCount = 256
    let maximumFileBytes = 2 * 1024 * 1024
    let maximumPackageBytes = 8 * 1024 * 1024
    let maximumRelativePathBytes = 512
    let maximumSegmentBytes = 255
    let maximumDepth = 16
    let maximumChunkBytes = 65_536
    /// Announced receipt TTL (≤ SkillsMcpLimits.maximumStagingReceiptTTLSec
    /// 1800; one user import comfortably finishes inside 600 s).
    let receiptTTLSec = 600
    /// One live user selection at a time per process lane; a second
    /// concurrent pick is a typed saturation, never an implicit takeover.
    let maximumLiveRoutes = 2
}

// MARK: - State

private final class SkillsFolderRoute {
    let receipt: String
    let incarnation: UInt64
    let uiGeneration: UInt64
    let epoch: UInt64
    var treeReceipts: Set<String> = []
    init(receipt: String, incarnation: UInt64, uiGeneration: UInt64, epoch: UInt64) {
        self.receipt = receipt
        self.incarnation = incarnation
        self.uiGeneration = uiGeneration
        self.epoch = epoch
    }
}

private final class SkillsFolderTree {
    let receipt: String
    let routeReceipt: String
    let directory: URL
    var openFile: String?
    var fileHandles: Set<String> = []
    var collisionKeys: Set<String> = []
    var fileCount: Int = 0
    var totalBytes: Int = 0
    var finished = false
    init(receipt: String, routeReceipt: String, directory: URL) {
        self.receipt = receipt
        self.routeReceipt = routeReceipt
        self.directory = directory
    }
}

private final class SkillsFolderFile {
    let receipt: String
    let treeReceipt: String
    let relativePath: String
    var handle: FileHandle?
    var bytes: Int = 0
    var ended = false
    init(receipt: String, treeReceipt: String, relativePath: String, handle: FileHandle) {
        self.receipt = receipt
        self.treeReceipt = treeReceipt
        self.relativePath = relativePath
        self.handle = handle
    }
}

/// Swift-6-safe one-shot result box for the bounded synchronous actor hops
/// (the caller's thread blocks on the semaphore; only the detached task
/// writes through this box before signalling).
private final class FolderHopBox<Value>: @unchecked Sendable {
    var value: Value?
}

/// The process-lane staging session table. NSLock-guarded, synchronous and
/// short-lived per call (byte pumps stream; only `treeOpen` and
/// `treeFinish` perform one bounded actor hop).
public final class SkillsFolderHostStaging: @unchecked Sendable {

    public static let shared = SkillsFolderHostStaging()

    private let lock = NSLock()
    private var routes: [String: SkillsFolderRoute] = [:]
    private var trees: [String: SkillsFolderTree] = [:]
    private var files: [String: SkillsFolderFile] = [:]
    private let budgets = SkillsFolderBudgets()

    /// Trusted fixture seam (same module only; the accepted pattern used
    /// by the attachment facade's install/currentInstalled test surface):
    /// unit tests install the LIVE SkillsDomain under test without the
    /// full G02 composition. Production never writes it; no command,
    /// envelope or JSON field can reach this lane either way.
    internal var domainOverrideForTesting: SkillsDomain?

    private init() {}

    // MARK: epoch truth

    /// The CURRENT accepted native generation, or nil when no live,
    /// non-retiring, store-ready root exists. Every entry point re-checks
    /// its lane against THIS value (never against the caller's claim).
    private func liveEpoch() -> UInt64? {
        guard let pumps = AndroidRuntimeBootstrap.currentPumps(),
              pumps.storeReady else { return nil }
        return pumps.epoch
    }

    private func requireDomain() -> SkillsDomain? {
        domainOverrideForTesting
            ?? G02RuntimeComposition.shared.installedComposition?.skillsDomain
    }

    // MARK: path safety (ORIGINAL validator segment rules, mirrored)

    /// Returns the refusal status or nil. `relativePath` is validated
    /// BEFORE any filesystem effect.
    private func validateRelativePath(_ raw: String, tree: SkillsFolderTree) -> Int32 {
        guard !raw.isEmpty, raw.utf8.count <= budgets.maximumRelativePathBytes else {
            return SkillsFolderHostStatus.pathUnsafe
        }
        guard raw.firstIndex(of: "\\") == nil,
              !raw.hasPrefix("/"),
              !raw.hasSuffix("/"),
              raw.utf8.firstIndex(where: { $0 == 0 }) == nil else {
            return SkillsFolderHostStatus.pathUnsafe
        }
        let segments = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard !segments.isEmpty else { return SkillsFolderHostStatus.pathUnsafe }
        guard segments.count <= budgets.maximumDepth else {
            return SkillsFolderHostStatus.depthExceeded
        }
        for segment in segments {
            guard !segment.isEmpty, segment != ".", segment != ".." else {
                return SkillsFolderHostStatus.pathUnsafe
            }
            guard segment.utf8.count <= budgets.maximumSegmentBytes else {
                return SkillsFolderHostStatus.pathUnsafe
            }
        }
        let collision = raw.precomposedStringWithCanonicalMapping.lowercased()
        guard !tree.collisionKeys.contains(collision) else {
            return SkillsFolderHostStatus.duplicatePath
        }
        return SkillsFolderHostStatus.ok
    }

    // MARK: routes

    func routeOpen(incarnation: UInt64, uiGeneration: UInt64,
                   claimedEpoch: UInt64) -> (Int32, String?) {
        guard incarnation > 0, uiGeneration > 0, claimedEpoch > 0 else {
            return (SkillsFolderHostStatus.invalidArguments, nil)
        }
        lock.lock(); defer { lock.unlock() }
        guard requireDomain() != nil, let live = liveEpoch() else {
            return (SkillsFolderHostStatus.notInstalled, nil)
        }
        guard live == claimedEpoch else {
            return (SkillsFolderHostStatus.epochFenced, nil)
        }
        guard routes.count < budgets.maximumLiveRoutes else {
            return (SkillsFolderHostStatus.saturated, nil)
        }
        let receipt = SkillsFolderReceipt.make(prefix: SkillsFolderReceipt.routePrefix)
        routes[receipt] = SkillsFolderRoute(receipt: receipt, incarnation: incarnation,
                                           uiGeneration: uiGeneration, epoch: live)
        return (SkillsFolderHostStatus.ok, receipt)
    }

    func routeClose(receipt: String) -> Int32 {
        lock.lock()
        guard let route = routes[receipt] else { lock.unlock(); return SkillsFolderHostStatus.ok }
        routes[receipt] = nil
        let laneTrees = route.treeReceipts.compactMap { trees[$0] }
        for tree in laneTrees {
            trees[tree.receipt] = nil
            for handle in Array(tree.fileHandles) {
                _ = finishFileLocked(receipt: handle, removeBytes: true)
            }
        }
        lock.unlock()
        // Removal is IO work — outside the lock, but the trees were already
        // detached from the table above, so no new call can reach them.
        for tree in laneTrees {
            removeTreeOwnedDirectory(tree)
        }
        return SkillsFolderHostStatus.ok
    }

    // MARK: trees

    func treeOpen(routeReceipt: String, displayNameHint: String?) -> (Int32, String?) {
        // The hint is display metadata ONLY (clamped by the caller); it
        // never names a directory — the DOMAIN allocates the path.
        _ = displayNameHint
        lock.lock()
        guard SkillsFolderReceipt.isValid(routeReceipt,
                                          prefix: SkillsFolderReceipt.routePrefix),
              let route = routes[routeReceipt] else {
            lock.unlock()
            return (SkillsFolderHostStatus.routeUnknown, nil)
        }
        guard let live = liveEpoch(), live == route.epoch, requireDomain() != nil else {
            lock.unlock()
            return (SkillsFolderHostStatus.epochFenced, nil)
        }
        guard route.treeReceipts.isEmpty else {
            lock.unlock()
            // One active tree per captured pick; a second concurrent tree
            // is a typed saturation (no silent takeover).
            return (SkillsFolderHostStatus.saturated, nil)
        }
        lock.unlock()
        // Domain-owned allocation: ONE bounded actor hop; the actor's own
        // requireBinding is the authority on the epoch.
        guard let directory = domainCreateStagingDirectorySync() else {
            return (SkillsFolderHostStatus.notInstalled, nil)
        }
        let receipt = SkillsFolderReceipt.make(prefix: SkillsFolderReceipt.treePrefix)
        lock.lock()
        // Re-check lane liveness after the hop (a retirement may have
        // landed meanwhile); the directory is cleaned up on refusal.
        guard let live = liveEpoch(),
              let route = routes[routeReceipt], route.epoch == live else {
            lock.unlock()
            try? FileManager.default.removeItem(at: directory)
            return (SkillsFolderHostStatus.epochFenced, nil)
        }
        let tree = SkillsFolderTree(receipt: receipt, routeReceipt: routeReceipt,
                                    directory: directory)
        trees[receipt] = tree
        routes[routeReceipt]?.treeReceipts.insert(receipt)
        lock.unlock()
        return (SkillsFolderHostStatus.ok, receipt)
    }

    // MARK: files

    func fileBegin(treeReceipt: String, relativePath: String) -> (Int32, String?) {
        lock.lock(); defer { lock.unlock() }
        guard SkillsFolderReceipt.isValid(treeReceipt,
                                          prefix: SkillsFolderReceipt.treePrefix),
              let tree = trees[treeReceipt], !tree.finished else {
            return (SkillsFolderHostStatus.treeUnknown, nil)
        }
        guard let live = liveEpoch(),
              let route = routes[tree.routeReceipt], route.epoch == live else {
            return (SkillsFolderHostStatus.epochFenced, nil)
        }
        guard tree.openFile == nil else {
            return (SkillsFolderHostStatus.invalidArguments, nil) // sequential pump
        }
        let status = validateRelativePath(relativePath, tree: tree)
        guard status == SkillsFolderHostStatus.ok else { return (status, nil) }
        guard tree.fileCount < budgets.maximumFileCount else {
            return (SkillsFolderHostStatus.fileCountExceeded, nil)
        }
        let collision = relativePath.precomposedStringWithCanonicalMapping.lowercased()
        guard tree.collisionKeys.insert(collision).inserted else {
            return (SkillsFolderHostStatus.duplicatePath, nil)
        }
        let url = tree.directory.appendingPathComponent(relativePath)
        let parent = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: parent,
                                                    withIntermediateDirectories: true)
            if !FileManager.default.createFile(atPath: url.path, contents: Data()) {
                tree.collisionKeys.remove(collision)
                return (SkillsFolderHostStatus.diskFull, nil)
            }
            guard let handle = FileHandle(forWritingAtPath: url.path) else {
                tree.collisionKeys.remove(collision)
                return (SkillsFolderHostStatus.writeFailed, nil)
            }
            let receipt = SkillsFolderReceipt.make(prefix: SkillsFolderReceipt.filePrefix)
            files[receipt] = SkillsFolderFile(receipt: receipt, treeReceipt: treeReceipt,
                                              relativePath: relativePath, handle: handle)
            tree.openFile = receipt
            tree.fileHandles.insert(receipt)
            tree.fileCount += 1
            return (SkillsFolderHostStatus.ok, receipt)
        } catch {
            tree.collisionKeys.remove(collision)
            return (SkillsFolderHostStatus.diskFull, nil)
        }
    }

    func fileWrite(receipt: String, pointer: UnsafeRawPointer, length: Int) -> Int32 {
        lock.lock()
        guard SkillsFolderReceipt.isValid(receipt, prefix: SkillsFolderReceipt.filePrefix),
              let file = files[receipt], !file.ended,
              let handle = file.handle,
              let tree = trees[file.treeReceipt], !tree.finished,
              length >= 0, length <= budgets.maximumChunkBytes else {
            lock.unlock()
            return SkillsFolderHostStatus.fileUnknown
        }
        guard let live = liveEpoch(),
              let route = routes[tree.routeReceipt], route.epoch == live else {
            lock.unlock()
            return SkillsFolderHostStatus.epochFenced
        }
        guard file.bytes + length <= budgets.maximumFileBytes,
              tree.totalBytes + length <= budgets.maximumPackageBytes else {
            lock.unlock()
            return SkillsFolderHostStatus.bytesExceeded
        }
        let chunk = Data(UnsafeRawBufferPointer(start: pointer, count: length))
        do {
            handle.write(chunk)
        } catch {
            lock.unlock()
            return SkillsFolderHostStatus.writeFailed
        }
        file.bytes += length
        tree.totalBytes += length
        lock.unlock()
        return SkillsFolderHostStatus.ok
    }

    /// Data-shaped convenience over the same bounded pump (used by the
    /// qualification suite; the JNI surface keeps the pointer/length form).
    func fileWrite(receipt: String, bytes: Data) -> Int32 {
        bytes.withUnsafeBytes { raw in
            fileWrite(receipt: receipt, pointer: raw.baseAddress!,
                      length: raw.count)
        }
    }

    func fileEnd(receipt: String) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        return finishFileLocked(receipt: receipt, removeBytes: false)
    }

    func fileAbort(receipt: String) -> Int32 {
        lock.lock()
        defer { lock.unlock() }
        _ = finishFileLocked(receipt: receipt, removeBytes: true)
        return SkillsFolderHostStatus.ok
    }

    private func finishFileLocked(receipt: String, removeBytes: Bool) -> Int32 {
        guard SkillsFolderReceipt.isValid(receipt, prefix: SkillsFolderReceipt.filePrefix),
              let file = files[receipt] else {
            return SkillsFolderHostStatus.fileUnknown
        }
        guard let tree = trees[file.treeReceipt] else {
            files[receipt] = nil
            return SkillsFolderHostStatus.treeUnknown
        }
        files[receipt] = nil
        tree.fileHandles.remove(receipt)
        if tree.openFile == receipt { tree.openFile = nil }
        if let handle = file.handle {
            file.handle = nil
            if !removeBytes {
                // EOF: durable flush exactly like the accepted attachment
                // lane (FileHandle.synchronize).
                do {
                    try handle.synchronize()
                } catch {
                    try? handle.close()
                    return SkillsFolderHostStatus.writeFailed
                }
            }
            try? handle.close()
        }
        if removeBytes {
            let collision = file.relativePath.precomposedStringWithCanonicalMapping.lowercased()
            tree.collisionKeys.remove(collision)
            tree.fileCount = max(0, tree.fileCount - 1)
            tree.totalBytes = max(0, tree.totalBytes - file.bytes)
            try? FileManager.default.removeItem(
                at: tree.directory.appendingPathComponent(file.relativePath))
        } else {
            file.ended = true
        }
        return SkillsFolderHostStatus.ok
    }

    // MARK: finish / abort

    func treeFinish(treeReceipt: String, displayNameHint: String?) -> (Int32, String?) {
        _ = displayNameHint
        lock.lock()
        guard SkillsFolderReceipt.isValid(treeReceipt,
                                          prefix: SkillsFolderReceipt.treePrefix),
              let tree = trees[treeReceipt], !tree.finished, tree.openFile == nil,
              let route = routes[tree.routeReceipt],
              let live = liveEpoch(), route.epoch == live else {
            lock.unlock()
            return (SkillsFolderHostStatus.treeUnknown, nil)
        }
        tree.finished = true
        lock.unlock()

        guard requireDomain() != nil else {
            removeTreeOwnedDirectory(tree)
            pruneTreeTable(treeReceipt: treeReceipt)
            return (SkillsFolderHostStatus.notInstalled, nil)
        }
        // ORIGINAL canonical digest over the REAL disk inventory (the same
        // regular-files + symlink-rejection shape the domain re-computes).
        let scanned: [String: Data]?
        do {
            scanned = try Self.scanStagedFiles(in: tree.directory, budgets: budgets)
        } catch {
            removeTreeOwnedDirectory(tree)
            pruneTreeTable(treeReceipt: treeReceipt)
            return (SkillsFolderHostStatus.receiptRefused, nil)
        }
        guard let filesFound = scanned, !filesFound.isEmpty else {
            removeTreeOwnedDirectory(tree)
            pruneTreeTable(treeReceipt: treeReceipt)
            return (SkillsFolderHostStatus.receiptRefused, nil)
        }
        let totalBytes = filesFound.values.reduce(0) { $0 + $1.count }
        guard filesFound.count <= budgets.maximumFileCount,
              totalBytes > 0,
              totalBytes <= budgets.maximumPackageBytes,
              filesFound.values.allSatisfy({ $0.count <= budgets.maximumFileBytes }) else {
            removeTreeOwnedDirectory(tree)
            pruneTreeTable(treeReceipt: treeReceipt)
            return (SkillsFolderHostStatus.bytesExceeded, nil)
        }
        let digest = SkillPackageValidator.canonicalDigest(files: filesFound)
        let receipt = SkillsFolderStagingReceipt(
            canonicalSHA256: digest,
            fileCount: filesFound.count,
            totalBytes: totalBytes,
            ttlSeconds: budgets.receiptTTLSec)

        // ONE bounded actor hop into the domain, which re-computes the
        // digest over its own inventory and mints the stg:v1 receipt of
        // the CURRENT epoch. A timeout or refusal removes the owned tree
        // (recoverable cleanup; no orphan lane is left).
        let domain: SkillsDomain
        guard let resolved = requireDomain() else {
            removeTreeOwnedDirectory(tree)
            pruneTreeTable(treeReceipt: treeReceipt)
            return (SkillsFolderHostStatus.notInstalled, nil)
        }
        domain = resolved
        let box = FolderHopBox<Result<String, any Error>?>()
        let gate = DispatchSemaphore(value: 0)
        let directory = tree.directory
        Task.detached(priority: .userInitiated) {
            do {
                let token = try await domain.registerStagedFolder(
                    directory: directory, receipt: receipt, now: Date())
                box.value = .success(token)
            } catch {
                box.value = .failure(error)
            }
            gate.signal()
        }
        if gate.wait(timeout: .now() + 30) == .timedOut {
            removeTreeOwnedDirectory(tree)
            pruneTreeTable(treeReceipt: treeReceipt)
            return (SkillsFolderHostStatus.internal, nil)
        }
        switch box.value ?? nil {
        case .success(let token):
            pruneTreeTable(treeReceipt: treeReceipt)
            return (SkillsFolderHostStatus.ok,
                    "\(token) \(filesFound.count) \(totalBytes)")
        case .failure:
            // Typed refusal (shape/digest/inventory): the domain minted
            // NOTHING; drop the whole owned tree.
            removeTreeOwnedDirectory(tree)
            pruneTreeTable(treeReceipt: treeReceipt)
            return (SkillsFolderHostStatus.digestMismatch, nil)
        case .none:
            removeTreeOwnedDirectory(tree)
            pruneTreeTable(treeReceipt: treeReceipt)
            return (SkillsFolderHostStatus.internal, nil)
        }
    }

    func treeAbort(treeReceipt: String) -> Int32 {
        lock.lock()
        guard let tree = trees[treeReceipt] else {
            lock.unlock()
            return SkillsFolderHostStatus.ok
        }
        trees[treeReceipt] = nil
        routes[tree.routeReceipt]?.treeReceipts.remove(treeReceipt)
        for handle in Array(tree.fileHandles) {
            _ = finishFileLocked(receipt: handle, removeBytes: true)
        }
        lock.unlock()
        removeTreeOwnedDirectory(tree)
        return SkillsFolderHostStatus.ok
    }

    private func pruneTreeTable(treeReceipt: String) {
        lock.lock()
        if let tree = trees[treeReceipt] {
            trees[treeReceipt] = nil
            routes[tree.routeReceipt]?.treeReceipts.remove(treeReceipt)
        }
        lock.unlock()
    }

    /// Recoverable cleanup: removes ONLY the domain-allocated tree
    /// directory this lane owns (allocated by
    /// `hostCreateStagingDirectory` under the domain staging root).
    /// Nothing else on disk is touched.
    private func removeTreeOwnedDirectory(_ tree: SkillsFolderTree) {
        try? FileManager.default.removeItem(at: tree.directory)
    }

    /// The regular-files inventory with the ORIGINAL rejection shape:
    /// symlinks anywhere are a typed failure (the domain's own
    /// `collectDirectoryFiles` re-runs the same check during registration;
    /// this scan exists only to build the receipt the domain will verify).
    private static func scanStagedFiles(in root: URL,
                                        budgets: SkillsFolderBudgets) throws
        -> [String: Data] {
        var files: [String: Data] = [:]
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            return [:]
        }
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isSymbolicLink == true {
                throw ConfigDomainError(code: .invalidEnvelope, reason: "hostStageSymlink")
            }
            guard values?.isRegularFile == true else { continue }
            let relative = String(url.standardizedFileURL.path
                .dropFirst(root.standardizedFileURL.path.count + 1))
            guard !relative.isEmpty else { continue }
            guard let data = try? Data(contentsOf: url) else {
                throw ConfigDomainError(code: .persistenceUnavailable, reason: "hostStageRead")
            }
            files[relative] = data
            if files.count > budgets.maximumFileCount {
                throw ConfigDomainError(code: .payloadTooLarge, reason: "hostStageCount")
            }
        }
        return files
    }

    /// Synchronous, bounded hop into the actor for the directory
    /// allocation (the same short no-network actor call pattern as
    /// `treeFinish`). A not-ready/retiring domain refuses internally and
    /// returns nil here.
    private func domainCreateStagingDirectorySync() -> URL? {
        guard let domain = requireDomain() else { return nil }
        let box = FolderHopBox<URL?>()
        let gate = DispatchSemaphore(value: 0)
        Task.detached(priority: .userInitiated) {
            do {
                box.value = try await domain.hostCreateStagingDirectory(
                    namespace: "host-folder")
            } catch {
                box.value = nil
            }
            gate.signal()
        }
        if gate.wait(timeout: .now() + 10) == .timedOut { return nil }
        return box.value ?? nil
    }

    // MARK: status (lock-only bounded counters; no paths/names/URIs)

    public func statusJSON() -> String? {
        lock.lock(); defer { lock.unlock() }
        let object: [String: Any] = [
            "routes": routes.count,
            "trees": trees.count,
            "files": files.count,
            "liveRoutesCap": budgets.maximumLiveRoutes,
        ]
        return (try? JSONSerialization.data(withJSONObject: object,
                                            options: [.sortedKeys]))
            .map { String(decoding: $0, as: UTF8.self) }
    }
}

// MARK: - @_cdecl surface (resolved by the floe_skills_folder_staging JNI TU)

private func folderReadCString(_ pointer: UnsafePointer<CChar>?, limit: Int) -> String? {
    guard let pointer else { return nil }
    var value: [CChar] = []
    var index = 0
    while index <= limit {
        let byte = pointer[index]
        if byte == 0 {
            // NUL terminator within bounds: strict printable-ASCII only.
            return value.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
                ? String(cString: value + [0]) : nil
        }
        if index == limit { return nil } // no NUL within limit
        value.append(byte)
        index += 1
    }
    return nil
}

/// Bounded UTF-8 read for user-visible naming (relative paths / display
/// hints). Printable-ASCII is REQUIRED for receipts, but file/folder
/// names follow the ORIGINAL validator, which accepts Unicode segments
/// and rejects traversal/separator/control shapes itself (the JVM lane
/// pre-checks the same rules; the domain validator stays the authority).
/// Missing NUL within the bound is a hard refusal — never a truncation.
private func folderReadUtf8CString(_ pointer: UnsafePointer<CChar>?,
                                   limit: Int) -> String? {
    guard let pointer else { return nil }
    var bytes: [CChar] = []
    var index = 0
    while index <= limit {
        let byte = pointer[index]
        if byte == 0 {
            return String(cString: bytes + [0])
        }
        if index == limit { return nil } // no NUL within limit
        bytes.append(byte)
        index += 1
    }
    return nil
}

private func folderCopyCString(_ value: String, buffer: UnsafeMutablePointer<CChar>?,
                               capacity: Int32) -> Int32 {
    guard let buffer, capacity > 0 else { return SkillsFolderHostStatus.invalidArguments }
    let bytes = Array(value.utf8)
    guard bytes.count + 1 <= Int(capacity) else { return SkillsFolderHostStatus.bufferTooSmall }
    for (index, byte) in bytes.enumerated() {
        buffer[index] = CChar(bitPattern: byte)
    }
    buffer[bytes.count] = 0
    return SkillsFolderHostStatus.ok
}

@_cdecl("floe_skills_folder_route_open")
public func floeSkillsFolderRouteOpen(_ incarnation: UInt64,
                                      _ uiGeneration: UInt64,
                                      _ rootEpoch: UInt64,
                                      _ outReceipt: UnsafeMutablePointer<CChar>?,
                                      _ outCap: Int32) -> Int32 {
    let (status, receipt) = SkillsFolderHostStaging.shared
        .routeOpen(incarnation: incarnation, uiGeneration: uiGeneration,
                   claimedEpoch: rootEpoch)
    guard status == SkillsFolderHostStatus.ok, let receipt else { return status }
    let written = folderCopyCString(receipt, buffer: outReceipt, capacity: outCap)
    return written < 0 ? written : SkillsFolderHostStatus.ok
}

@_cdecl("floe_skills_folder_route_close")
public func floeSkillsFolderRouteClose(_ routeReceipt: UnsafePointer<CChar>?) -> Int32 {
    guard let receipt = folderReadCString(routeReceipt, limit: 64) else {
        return SkillsFolderHostStatus.invalidArguments
    }
    return SkillsFolderHostStaging.shared.routeClose(receipt: receipt)
}

@_cdecl("floe_skills_folder_tree_open")
public func floeSkillsFolderTreeOpen(_ routeReceipt: UnsafePointer<CChar>?,
                                     _ nameHint: UnsafePointer<CChar>?,
                                     _ outTree: UnsafeMutablePointer<CChar>?,
                                     _ outCap: Int32) -> Int32 {
    guard let receipt = folderReadCString(routeReceipt, limit: 64) else {
        return SkillsFolderHostStatus.invalidArguments
    }
    // The hint is UNTRUSTED display text: bounded printable-ASCII read,
    // clamped, never used for allocation. Non-ASCII names are refused at
    // the JNI boundary (same strict rule as the attachment display hint);
    // DocumentsProvider names arrive already normalized.
    let hint = folderReadUtf8CString(nameHint, limit: 1024).map { String($0.prefix(255)) }
    let (status, tree) = SkillsFolderHostStaging.shared
        .treeOpen(routeReceipt: receipt, displayNameHint: hint)
    guard status == SkillsFolderHostStatus.ok, let tree else { return status }
    let written = folderCopyCString(tree, buffer: outTree, capacity: outCap)
    return written < 0 ? written : SkillsFolderHostStatus.ok
}

@_cdecl("floe_skills_folder_file_begin")
public func floeSkillsFolderFileBegin(_ treeReceipt: UnsafePointer<CChar>?,
                                      _ relativePath: UnsafePointer<CChar>?,
                                      _ outFile: UnsafeMutablePointer<CChar>?,
                                      _ outCap: Int32) -> Int32 {
    guard let tree = folderReadCString(treeReceipt, limit: 64),
          let relativePath = folderReadUtf8CString(relativePath, limit: 512) else {
        return SkillsFolderHostStatus.invalidArguments
    }
    let (status, file) = SkillsFolderHostStaging.shared
        .fileBegin(treeReceipt: tree, relativePath: relativePath)
    guard status == SkillsFolderHostStatus.ok, let file else { return status }
    let written = folderCopyCString(file, buffer: outFile, capacity: outCap)
    return written < 0 ? written : SkillsFolderHostStatus.ok
}

@_cdecl("floe_skills_folder_file_write")
public func floeSkillsFolderFileWrite(_ fileReceipt: UnsafePointer<CChar>?,
                                      _ bytes: UnsafePointer<UInt8>?,
                                      _ length: Int32) -> Int32 {
    guard let receipt = folderReadCString(fileReceipt, limit: 64),
          let bytes, length >= 0 else {
        return SkillsFolderHostStatus.invalidArguments
    }
    return SkillsFolderHostStaging.shared
        .fileWrite(receipt: receipt, pointer: UnsafeRawPointer(bytes), length: Int(length))
}

@_cdecl("floe_skills_folder_file_end")
public func floeSkillsFolderFileEnd(_ fileReceipt: UnsafePointer<CChar>?) -> Int32 {
    guard let receipt = folderReadCString(fileReceipt, limit: 64) else {
        return SkillsFolderHostStatus.invalidArguments
    }
    return SkillsFolderHostStaging.shared.fileEnd(receipt: receipt)
}

@_cdecl("floe_skills_folder_file_abort")
public func floeSkillsFolderFileAbort(_ fileReceipt: UnsafePointer<CChar>?) -> Int32 {
    guard let receipt = folderReadCString(fileReceipt, limit: 64) else {
        return SkillsFolderHostStatus.invalidArguments
    }
    return SkillsFolderHostStaging.shared.fileAbort(receipt: receipt)
}

@_cdecl("floe_skills_folder_tree_finish")
public func floeSkillsFolderTreeFinish(_ treeReceipt: UnsafePointer<CChar>?,
                                       _ nameHint: UnsafePointer<CChar>?,
                                       _ outLine: UnsafeMutablePointer<CChar>?,
                                       _ outCap: Int32) -> Int32 {
    guard let tree = folderReadCString(treeReceipt, limit: 64) else {
        return SkillsFolderHostStatus.invalidArguments
    }
    let hint = folderReadUtf8CString(nameHint, limit: 1024).map { String($0.prefix(255)) }
    let (status, line) = SkillsFolderHostStaging.shared
        .treeFinish(treeReceipt: tree, displayNameHint: hint)
    guard status == SkillsFolderHostStatus.ok, let line else { return status }
    let written = folderCopyCString(line, buffer: outLine, capacity: outCap)
    return written < 0 ? written : SkillsFolderHostStatus.ok
}

@_cdecl("floe_skills_folder_tree_abort")
public func floeSkillsFolderTreeAbort(_ treeReceipt: UnsafePointer<CChar>?) -> Int32 {
    guard let receipt = folderReadCString(treeReceipt, limit: 64) else {
        return SkillsFolderHostStatus.invalidArguments
    }
    return SkillsFolderHostStaging.shared.treeAbort(treeReceipt: receipt)
}

@_cdecl("floe_skills_folder_status")
public func floeSkillsFolderStatus(_ buffer: UnsafeMutablePointer<CChar>?,
                                   _ capacity: Int32) -> Int32 {
    guard let json = SkillsFolderHostStaging.shared.statusJSON() else {
        return SkillsFolderHostStatus.internal
    }
    let written = folderCopyCString(json, buffer: buffer, capacity: capacity)
    return written < 0 ? written : SkillsFolderHostStatus.ok
}
