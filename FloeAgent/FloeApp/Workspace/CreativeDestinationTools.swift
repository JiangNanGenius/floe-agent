// FloeApp — Creative destination routing + canvas→ordinary-task handoff.
//
// User-steered 2026-10-14 semantics:
// - A creative natural-language request is NOT always a new canvas. The
//   MODEL chooses the destination from the user's intent and the REAL
//   toolchain: visual composition/material arrangement → canvas; webpages,
//   executable source projects, terminal/package/web-service/Linux
//   toolchains → ordinary project + ordinary task, created and navigated.
//   Office/PPT routes by REAL connected native/Linux capability, never by
//   extension or a fixed artifact category, and never HTML/PDF standing in
//   for PPTX.
// - Ordinary Q&A creates nothing (no empty canvas/project). A task with
//   sufficient context routes directly — no per-request selection form;
//   low confidence may ask lightly, and the OPTIONAL mode question times
//   out into the normal flow without approving anything destructive.
// - The canvas model can start an ordinary task from EXPLICIT user-selected
//   or named canvas materials through a DETERMINISTIC tool; the manual
//   entry is a supplementary path over the SAME service. The handoff only
//   transfers targets and materials — it is NOT a Linux/execution bypass;
//   the new ordinary task runs under its own capabilities and approvals.
// - Idempotent per operation ID: replays, app restores and late results
//   never duplicate tasks or copy materials, never steal focus, never
//   restart ended runs. The source canvas/nodes are preserved; results
//   belong to the new task, and back-filling the canvas requires an
//   explicit adoption.

#if canImport(SwiftUI) && canImport(UIKit)
import Foundation
import FloeCore
import FloeModels
import FloePersistence
import FloeTools
import FloeExecution
import FloeWorkspace

// MARK: - Durable route records

/// One material's provenance: the source node, its immutable content
/// digest and size. The destination task can verify exactly what it got.
struct CreativeMaterialManifest: Codable, Sendable, Equatable {
    var nodeID: UUID
    var name: String
    var sha256: String
    var byteCount: Int
}

/// One creative routing / handoff association, durable across restarts so
/// replays and restores never recreate or re-navigate. The lifecycle is
/// explicit: `prepared` (workspace + materials staged + record persisted,
/// BEFORE any provider run exists) → `started` (the deferred task exists)
/// → `failed` (recoverable: workspace, materials and record survive; a
/// retry reuses them and never duplicates the project or copies).
struct CreativeRouteRecord: Codable, Sendable, Equatable {
    enum Status: String, Codable, Sendable {
        case prepared, started, failed
    }

    var operationID: String
    /// Digest of the semantic payload; a same-operation call with a
    /// DIFFERENT payload is a conflict, never silently merged.
    var payloadDigest: String
    var status: Status
    var sourceConversationID: UUID
    var sourceRunID: UUID
    var sourceCanvasID: UUID?
    /// The inspected source document the materials came from (never a
    /// guessed first document).
    var sourceDocumentID: UUID?
    /// The source canvas revision inspected when the materials froze.
    var sourceProjectRevision: Int64?
    var sourceNodeIDs: [UUID]
    var materials: [CreativeMaterialManifest]
    var destinationConversationID: UUID?
    var destinationWorkspaceID: UUID
    /// The destination environment identity when the plan named one
    /// (nil = the destination task resolves its own toolchain).
    var destinationEnvironmentID: String?
    var destinationCanvasID: UUID?
    var family: String
    var goal: String
    var error: String?
    var createdAt: Date
}

enum CreativeRouteError: LocalizedError {
    case payloadConflict(String)
    case storeCorrupt(String)
    case storeUnavailable(String)

    var errorDescription: String? {
        switch self {
        case .payloadConflict(let detail): return "route conflict: \(detail)"
        case .storeCorrupt(let detail): return "route store is corrupt: \(detail)"
        case .storeUnavailable(let detail): return "route store is unavailable: \(detail)"
        }
    }
}

enum CreativeRouteStore {
    private static let directoryName = "CreativeRoutes"
    nonisolated(unsafe) static var storageDirectoryOverride: URL?
    private static let lock = NSLock()

    static func fileURL() throws -> URL {
        guard let root = storageDirectoryOverride
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
                .appendingPathComponent("FloeAgent", isDirectory: true) else {
            throw CreativeRouteError.storeUnavailable("no Application Support directory")
        }
        return root
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent("routes.json")
    }

    /// STRICT, fail-closed reads: ONLY a missing store file means "empty".
    /// A read error (permissions, truncation, transient I/O) throws
    /// `storeUnavailable` and a decode error throws `storeCorrupt` — a read
    /// error is NEVER mistaken for an empty store, which could otherwise
    /// duplicate reservations or re-run side effects during recovery.
    static func load() throws -> [CreativeRouteRecord] {
        let url = try fileURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw CreativeRouteError.storeUnavailable(
                "route store could not be read: \(error.localizedDescription)")
        }
        do {
            return try JSONDecoder().decode([CreativeRouteRecord].self, from: data)
        } catch {
            throw CreativeRouteError.storeCorrupt(error.localizedDescription)
        }
    }

    static func save(_ records: [CreativeRouteRecord]) throws {
        let url = try fileURL()
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(records)
        try data.write(to: url, options: .atomic)
    }

    static func synchronized<T>(_ body: ([CreativeRouteRecord]) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body(load())
    }

    static func synchronizedSave(_ records: [CreativeRouteRecord]) throws {
        lock.lock()
        defer { lock.unlock() }
        try save(records)
    }

    static func existing(operationID: String, sourceRunID: UUID) throws -> CreativeRouteRecord? {
        try synchronized { $0.first { $0.operationID == operationID && $0.sourceRunID == sourceRunID } }
    }

    static func upsert(_ record: CreativeRouteRecord) throws {
        try synchronizedSave(load().filter {
            !($0.operationID == record.operationID && $0.sourceRunID == record.sourceRunID)
        } + [record])
    }
}

// MARK: - Router

/// The shared creative destination router. Both model tools and the manual
/// canvas entry call the SAME service; there is no parallel router.
@MainActor
enum CreativeDestinationRouter {
    /// Navigation seam: installed by the app shell (AppRouter). nil in
    /// tests/preview → navigation is honestly suppressed.
    nonisolated(unsafe) static var navigator: (@MainActor (UUID) -> Void)?

    struct RouteOutcome: Sendable {
        var record: CreativeRouteRecord
        /// True when this call created the destination (false for replays
        /// and recoveries that reuse a prepared workspace).
        var created: Bool
        /// True ONLY when real foreground navigation was delivered through
        /// the app shell (never on replays, background runs, or when the
        /// navigation seam is absent).
        var navigated: Bool
        var message: String
    }

    /// Foreground truth, installed by the app shell: the initiating run is
    /// still the SELECTED conversation's active run, OR its canvas is the
    /// canvas the user is currently looking at through the root canvas
    /// cover. Background runs and switched conversations answer false —
    /// no focus stealing.
    nonisolated(unsafe) static var foregroundRunProbe: (@MainActor (UUID) async -> Bool)?
    /// Navigation seam for the CANVAS destination (installed by the shell).
    nonisolated(unsafe) static var canvasNavigator: (@MainActor (UUID) -> Void)?

    static let maximumMaterials = 32
    static let maximumMaterialBytes = 256 * 1024 * 1024

    /// One verified immutable material snapshot with its provenance: the
    /// exact source node, the original (UTF-8) display name and the frozen
    /// bytes. The source canvas/nodes are never mutated.
    struct HandoffMaterial: Sendable, Equatable {
        var nodeID: UUID
        var name: String
        var bytes: Data
    }

    /// The FULL request digest: goal, family, linux need, destination hint,
    /// the target project choice (existing id or explicit create), the
    /// destination environment, the source canvas/document/revision and every
    /// material's identity + content hash. ANY change is a conflict for the
    /// same operationID (or requires an explicit new operation).
    static func payloadDigest(
        goal: String,
        family: DesignContentType,
        needsLinux: Bool,
        hint: String?,
        existingWorkspaceID: UUID?,
        createProject: Bool,
        destinationEnvironmentID: String?,
        canvasID: UUID?,
        sourceDocumentID: UUID?,
        sourceRevision: Int64?,
        nodeIDs: [UUID],
        materialSHAs: [String]
    ) -> String {
        var parts = [
            goal, family.rawValue,
            needsLinux ? "linux" : "native",
            hint ?? "-",
            existingWorkspaceID?.uuidString ?? (createProject ? "create-project" : "no-destination"),
            destinationEnvironmentID ?? "-",
            canvasID?.uuidString ?? "-",
            sourceDocumentID?.uuidString ?? "-",
            sourceRevision.map(String.init) ?? "-",
        ]
        parts.append(contentsOf: nodeIDs.map(\.uuidString).sorted())
        parts.append(contentsOf: materialSHAs.sorted())
        return FloeDigest.sha256Hex(Data(parts.joined(separator: "\u{1F}").utf8))
    }

    // MARK: Per-operation in-flight ownership
    //
    // The durable store is the cross-process truth; this in-process registry
    // makes CONCURRENT identical calls coalesce instead of resuming the same
    // prepared record twice. A key is registered only after the atomic
    // reservation and removed when the route reaches a terminal outcome
    // (started/failed) — or when the call itself fails.

    private static let inFlightLock = NSLock()
    private static var inFlightKeys: Set<String> = []

    private static func inFlightKey(operationID: String, sourceRunID: UUID) -> String {
        "\(operationID)\u{1F}\(sourceRunID.uuidString)"
    }

    private static func registerInFlight(_ key: String) -> Bool {
        inFlightLock.lock()
        defer { inFlightLock.unlock() }
        return inFlightKeys.insert(key).inserted
    }

    private static func unregisterInFlight(_ key: String) {
        inFlightLock.lock()
        inFlightKeys.remove(key)
        inFlightLock.unlock()
    }

    enum RouteError: LocalizedError {
        case unknownFamily(String)
        case familyUnavailable(family: String, reason: String)
        case linuxRequiredButUnavailable(reason: String)
        case canvasNotFound(UUID)
        case nodeMissing(UUID)
        case nodeOutsideSelection(UUID)
        case canvasBindingMismatch(expected: UUID, supplied: UUID)
        case noCanvasBinding(UUID)
        case noMaterials
        case destinationAmbiguous
        case destinationProjectNotFound(UUID)
        case alreadyDestination(String)
        case originUnresolvable(String)

        var errorDescription: String? {
            switch self {
            case .unknownFamily(let family):
                return "unknown destination family '\(family)'"
            case .familyUnavailable(let family, let reason):
                return "destination family '\(family)' is not connected: \(reason)"
            case .linuxRequiredButUnavailable(let reason):
                return "this destination needs the Linux toolchain, which is unavailable: \(reason)"
            case .canvasNotFound(let id):
                return "canvas \(id.uuidString) does not exist"
            case .nodeMissing(let id):
                return "canvas node \(id.uuidString) does not exist in the named canvas (no guessing)"
            case .nodeOutsideSelection(let id):
                return "canvas node \(id.uuidString) is not part of the user's selected or named materials"
            case .canvasBindingMismatch(let expected, let supplied):
                return "canvas \(supplied.uuidString) was supplied but this run is bound to canvas \(expected.uuidString); cross-canvas references are refused"
            case .noCanvasBinding(let runID):
                return "run \(runID.uuidString) is not bound to a canvas; the handoff must originate from the canvas run it names"
            case .noMaterials:
                return "no materials were named; pass explicit node ids (no guessing the selection)"
            case .destinationAmbiguous:
                return "name exactly one destination: an existing projectWorkspaceID or createProject=true"
            case .destinationProjectNotFound(let id):
                return "destination project \(id.uuidString) does not exist; name an existing project or pass createProject=true"
            case .alreadyDestination(let operationID):
                return "this conversation is already the destination of route '\(operationID)'; continue the work there instead of spawning another destination"
            case .originUnresolvable(let detail):
                return "could not resolve the originating task/provider: \(detail)"
            }
        }
    }

    /// Real destination decision for a creative request, derived from the
    /// live capability matrix and (when required) the real Linux image
    /// state — never from extensions or fixed categories.
    ///
    /// Order matters: a Linux toolchain need ALWAYS routes to an ordinary
    /// project (the canvas hosts visual composition only and has no Linux
    /// execution), so `hint=canvas` can never accept a canvas+Linux plan.
    /// CAD stays on the canvas for NATIVE visual composition (the native CAD
    /// kernel is compiled in); CAD work that needs an unavailable tool or a
    /// Linux toolchain routes ordinary. Office never routes to the canvas:
    /// original OOXML editing/builders belong to the native/Live Office
    /// toolchain, and PPTX is never replaced by HTML/PDF.
    nonisolated static func assessDestination(
        family: DesignContentType,
        needsLinux: Bool,
        hint: String?,
        environment: AppEnvironment
    ) -> (destination: String, reasons: [String]) {
        var reasons: [String] = []
        let canvasFamilies: Set<DesignContentType> = [.image, .video, .composition, .cad]
        if let hint {
            reasons.append("hint=\(hint)")
        }
        if needsLinux {
            reasons.append("needsLinux=true")
            if hint == "canvas" {
                reasons.append("a Linux toolchain cannot run on the canvas — routing to an ordinary project")
            }
            return ("project", reasons)
        }
        if hint == "project" {
            reasons.append("explicit project hint")
            return ("project", reasons)
        }
        if hint == "canvas" {
            // A canvas hint is honored only for REAL visual composition
            // families; anything else is refused with the reason.
            if canvasFamilies.contains(family) {
                reasons.append("family=\(family.rawValue) is visual composition")
                return ("canvas", reasons)
            }
            reasons.append("family=\(family.rawValue) is not a visual composition family — the canvas cannot host it")
            return ("refused", reasons)
        }
        if canvasFamilies.contains(family) {
            reasons.append("family=\(family.rawValue) is visual composition")
            return ("canvas", reasons)
        }
        reasons.append("family=\(family.rawValue) needs the ordinary project toolchain")
        return ("project", reasons)
    }

    /// Verifies the REAL requirement for the PROJECT path. The ordinary
    /// task owns its toolchain (its tools discover their own capabilities),
    /// so the only hard gate here is an explicit Linux need — probed
    /// against the REAL image state, never assumed. The family's creative
    /// capability assessment is reported alongside (Office native vs
    /// engine-session is probed live by the matrix) as recovery context.
    static func verifyCapability(
        family: DesignContentType,
        needsLinux: Bool,
        environment: AppEnvironment
    ) async -> String? {
        if needsLinux {
            let imageID = LinuxGuestImageDistributionCatalog.defaultImageID
            let status = FloePlatformServices.shared.cachedLinuxImageStatus(id: imageID)
            guard status?.installed == true, status?.verificationIssue == nil else {
                return status?.verificationIssue?.message
                    ?? "the pinned Linux guest image is not installed or verified"
            }
        }
        return nil
    }

    /// Routes to an ordinary project + task with the FULL prepare-first,
    /// ATOMICALLY RESERVED lifecycle:
    ///   1. Resolve origin (run→conversation→provider/model) — read-only —
    ///      and refuse a route that would recursively spawn a destination
    ///      from a conversation that is ITSELF a route destination.
    ///   2. Compute the full request digest (goal/family/linux/hint/project
    ///      choice/environment/source canvas+document+revision/material hashes).
    ///   3. Under ONE store lock: replay (same digest, started), conflict
    ///      (different digest), or ATOMICALLY RESERVE the complete identity —
    ///      operation, source attribution, destination conversation/workspace
    ///      UUIDs — persisting a `prepared` record BEFORE any side effect.
    ///   4. Concurrent identical calls COALESCE on the per-operation
    ///      in-flight ownership; a call that finds a stale `prepared` record
    ///      (process died mid-route) RESUMES it exactly once per attempt.
    ///   5. Reconcile with the REAL launch facts (RunLaunchStore owns the
    ///      launch): a destination whose launch transaction committed is
    ///      marked `started` and NEVER re-sent; a bare conversation row
    ///      without its run fails closed instead of double-sending.
    ///   6. Create workspace + stage verified materials under the reserved
    ///      identity (create-if-missing; deterministic, collision-safe,
    ///      UTF-8-preserving names; readback-verified bytes).
    ///   7. Start the deferred task with the RESERVED conversation id.
    ///      Failures mark the record `failed` (recoverable) — workspace,
    ///      materials and record survive for an idempotent retry.
    static func routeToOrdinaryTask(
        goal: String,
        family: DesignContentType,
        needsLinux: Bool,
        operationID: String,
        sourceRunID: UUID,
        sourceCanvasID: UUID?,
        sourceNodeIDs: [UUID],
        snapshots: [HandoffMaterial],
        existingWorkspaceID: UUID?,
        createProject: Bool,
        destinationEnvironmentID: String? = nil,
        sourceDocumentID: UUID? = nil,
        sourceRevision: Int64? = nil,
        environment: AppEnvironment
    ) async throws -> RouteOutcome {
        guard !operationID.isEmpty else {
            throw FloeError.validationFailed("operationID is required (idempotency identity)")
        }
        // (1) REAL attribution: run → conversation (never fabricated).
        guard let originRun = try? await environment.runStore.run(id: sourceRunID) else {
            throw RouteError.originUnresolvable("run \(sourceRunID.uuidString) does not exist")
        }
        let sourceConversationID = originRun.conversationID
        // Recursive-destination guard: a conversation that is already the
        // destination of a route continues its work there instead of
        // spawning another destination (no route tool-loops).
        if let prior = try CreativeRouteStore.synchronized({ $0.first(where: {
            $0.destinationConversationID == sourceConversationID
        }) }) {
            throw RouteError.alreadyDestination(prior.operationID)
        }
        // Destination choice must be EXPLICIT: either an existing project
        // workspace or an explicit createProject flag — never both, never
        // neither (no silent first-project fallback).
        if (existingWorkspaceID != nil) == createProject {
            throw RouteError.destinationAmbiguous
        }
        let materialSHAs = snapshots.map { FloeDigest.sha256Hex($0.bytes) }
        let digest = payloadDigest(
            goal: goal, family: family, needsLinux: needsLinux, hint: nil,
            existingWorkspaceID: existingWorkspaceID, createProject: createProject,
            destinationEnvironmentID: destinationEnvironmentID,
            canvasID: sourceCanvasID, sourceDocumentID: sourceDocumentID,
            sourceRevision: sourceRevision,
            nodeIDs: sourceNodeIDs, materialSHAs: materialSHAs)

        // (2+3) Atomic reservation under the store lock.
        enum Reservation {
            case reserved(CreativeRouteRecord)
            case replayOutcome(RouteOutcome)
            case resume(CreativeRouteRecord)
        }
        let reservedWorkspaceID = existingWorkspaceID ?? UUID()
        let reservation: Reservation = try CreativeRouteStore.synchronized { records in
            if let existing = records.first(where: {
                $0.operationID == operationID && $0.sourceRunID == sourceRunID
            }) {
                guard existing.payloadDigest == digest else {
                    throw CreativeRouteError.payloadConflict(
                        "operationID '\(operationID)' was already used with a different payload (goal/materials/project/linux)")
                }
                switch existing.status {
                case .started:
                    return .replayOutcome(RouteOutcome(
                        record: existing, created: false, navigated: false,
                        message: "replayed operationID: the destination task already exists; nothing recreated or re-navigated"))
                case .prepared, .failed:
                    // Stale (crash) or recoverable (failure): the caller
                    // reconciles with the real launch facts and resumes with
                    // the staged inputs — in-flight calls coalesce instead.
                    return .resume(existing)
                }
            }
            let record = CreativeRouteRecord(
                operationID: operationID,
                payloadDigest: digest,
                status: .prepared,
                sourceConversationID: sourceConversationID,
                sourceRunID: sourceRunID,
                sourceCanvasID: sourceCanvasID,
                sourceDocumentID: sourceDocumentID,
                sourceProjectRevision: sourceRevision,
                sourceNodeIDs: sourceNodeIDs,
                materials: [],
                destinationConversationID: UUID(),
                destinationWorkspaceID: reservedWorkspaceID,
                destinationEnvironmentID: destinationEnvironmentID,
                destinationCanvasID: nil,
                family: family.rawValue,
                goal: goal,
                error: nil,
                createdAt: Date())
            var updated = records
            updated.append(record)
            try CreativeRouteStore.save(updated)
            return .reserved(record)
        }
        let record: CreativeRouteRecord
        switch reservation {
        case .reserved(let newRecord):
            // Fresh atomic reservation: this call owns the route.
            record = newRecord
        case .resume(let existing):
            // Stale (crash) or recoverable (failed) record: this call
            // reconciles with the real launch facts and resumes.
            record = existing
        case .replayOutcome(let outcome):
            return outcome
        }

        // (4) Per-operation in-flight ownership: a concurrent identical call
        // in this process coalesces instead of resuming the same record.
        let key = inFlightKey(operationID: operationID, sourceRunID: sourceRunID)
        guard registerInFlight(key) else {
            return RouteOutcome(
                record: record, created: false, navigated: false,
                message: "operationID in flight: a route with this identity is actively being prepared; nothing duplicated")
        }
        defer { unregisterInFlight(key) }

        /// Best-effort honest failure marking; the original error is always
        /// thrown so the caller sees the real cause. When the store write
        /// itself fails the record stays prepared — resumable, never stuck.
        func markFailed(_ message: String) {
            var failed = record
            failed.status = .failed
            failed.error = String(message.prefix(300))
            try? CreativeRouteStore.upsert(failed)
        }

        // Capability gate (real Linux probe when required).
        if let failure = await verifyCapability(
            family: family, needsLinux: needsLinux, environment: environment) {
            markFailed(failure)
            throw RouteError.linuxRequiredButUnavailable(reason: failure)
        }
        guard let providerID = originRun.providerID,
              let modelID = originRun.modelID,
              let provider = try? await environment.configurationStore.provider(id: providerID),
              let model = try? await environment.configurationStore.model(id: modelID) else {
            let message = "run \(sourceRunID.uuidString) has no resolvable provider/model; configure a provider and model for the originating task and retry"
            markFailed(message)
            throw RouteError.originUnresolvable(message)
        }
        guard let reservedConversationID = record.destinationConversationID else {
            throw CreativeRouteError.storeCorrupt("reserved route without a destination conversation id")
        }

        // An existing destination must be a REAL project workspace the user
        // can open — never a guessed or stale id.
        let workspaceStore = SQLiteWorkspaceStore(database: environment.database)
        if let existingID = existingWorkspaceID {
            guard let existing = try await workspaceStore.workspace(id: existingID),
                  existing.kind == .project else {
                throw RouteError.destinationProjectNotFound(existingID)
            }
        }

        // (5) Reconcile with the REAL launch facts before any side effect:
        // RunLaunchStore commits conversation+run+message in ONE transaction
        // before provider I/O, so a destination with a run proves the launch
        // happened and is never re-sent; a bare conversation row (no run)
        // fails closed; an absent destination proceeds to stage + launch.
        switch try await destinationLaunchFacts(
            environment: environment, conversationID: reservedConversationID) {
        case .launched:
            var started = record
            started.status = .started
            started.error = nil
            try CreativeRouteStore.upsert(started)
            return await finish(started, created: false, sourceRunID: sourceRunID)
        case .bareConversation:
            throw CreativeRouteError.storeCorrupt(
                "destination conversation exists without its launch run; refusing to re-send into it")
        case .absent:
            break
        }

        // (6) Workspace + materials under the RESERVED identity
        // (create-if-missing so recoveries reuse exactly the same objects).
        if try await workspaceStore.workspace(id: record.destinationWorkspaceID) == nil {
            let title = String(goal.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
            let support = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
                .appendingPathComponent("FloeAgent/CreativeProjects/\(record.destinationWorkspaceID.uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
            try await workspaceStore.saveWorkspace(WorkspaceRecord(
                id: record.destinationWorkspaceID,
                name: title.isEmpty ? "创意任务" : title,
                rootBookmark: try support.bookmarkData(options: .minimalBookmark),
                kind: .project))
        }
        var manifest = record.materials
        if manifest.isEmpty && !snapshots.isEmpty {
            // Per-material and aggregate bounds were already preflighted
            // BEFORE any byte was loaded (materialSnapshots); the staged
            // write is the verified, content-addressed copy.
            let workspace = try await resolveWorkspace(workspaceStore, id: record.destinationWorkspaceID)
            let lease = try await environment.workspaceCenter.acquireTaskRoot(
                workspace, conversationID: sourceConversationID)
            var staged: [CreativeMaterialManifest] = []
            do {
                let service = WorkspaceFileService(guard: WorkspacePathGuard(rootURL: lease.url))
                var usedNames: Set<String> = []
                for material in snapshots {
                    let sha = FloeDigest.sha256Hex(material.bytes)
                    // UTF-8 original names preserved; only path-hostile
                    // characters are replaced, and the content-addressed
                    // suffix plus node-id disambiguation make collisions
                    // impossible without mangling the display name.
                    let sanitized = Self.sanitizedMaterialName(material.name)
                    let unique = "\(sanitized)-\(sha.prefix(10))"
                    let finalName = usedNames.contains(unique)
                        ? "\(unique)-\(material.nodeID.uuidString.prefix(8))" : unique
                    usedNames.insert(finalName)
                    _ = try service.createBinaryFile(
                        "HandoffMaterials/\(finalName)", data: material.bytes)
                    let stagedURL = try service.guardResolver.resolve("HandoffMaterials/\(finalName)")
                    let readback = try Data(floeContentsOf: stagedURL, options: [.mappedIfSafe])
                    guard FloeDigest.sha256Hex(readback) == sha else {
                        throw FloeError.internalError("staged material '\(finalName)' failed readback verification")
                    }
                    staged.append(CreativeMaterialManifest(
                        nodeID: material.nodeID, name: finalName, sha256: sha,
                        byteCount: material.bytes.count))
                }
                lease.release()
                manifest = staged
            } catch {
                lease.release()
                markFailed(error.localizedDescription)
                throw error
            }
        }

        // (7) Deferred task start under the RESERVED conversation identity.
        // Final pre-send reconciliation closes the crash window between the
        // fact check above and the launch; a launch that committed between
        // the two checks is converged, never duplicated.
        switch try await destinationLaunchFacts(
            environment: environment, conversationID: reservedConversationID) {
        case .launched:
            var started = record
            started.materials = manifest
            started.status = .started
            started.error = nil
            try CreativeRouteStore.upsert(started)
            return await finish(started, created: false, sourceRunID: sourceRunID)
        case .bareConversation:
            throw CreativeRouteError.storeCorrupt(
                "destination conversation exists without its launch run; refusing to re-send into it")
        case .absent:
            break
        }
        var updated = record
        updated.materials = manifest
        do {
            _ = try await environment.conversationCenter.startTask(
                goal: goal,
                title: String(goal.prefix(40)),
                provider: provider,
                model: model,
                workspaceID: record.destinationWorkspaceID,
                newConversationID: reservedConversationID,
                startOrigin: .explicitUserAction)
            updated.status = .started
            updated.error = nil
            try CreativeRouteStore.upsert(updated)
            await environment.designEntryState.refresh(
                conversationID: reservedConversationID, environment: environment)
        } catch {
            updated.status = .failed
            updated.error = String(error.localizedDescription.prefix(300))
            try? CreativeRouteStore.upsert(updated)
            throw error
        }
        return await finish(updated, created: true, sourceRunID: sourceRunID)
    }

    /// The REAL launch facts for a reserved destination conversation,
    /// reconciled against the durable stores. Read errors FAIL CLOSED (throw)
    /// — a read error is never mistaken for "does not exist" (which would
    /// risk a duplicate paid launch). `launched` requires BOTH the
    /// conversation and at least one of its runs: RunLaunchStore commits
    /// them in one transaction before provider I/O, so together they prove
    /// the launch; a conversation row alone is NOT proof.
    private enum DestinationLaunchFacts {
        case launched
        case bareConversation
        case absent
    }

    private static func destinationLaunchFacts(
        environment: AppEnvironment,
        conversationID: UUID
    ) async throws -> DestinationLaunchFacts {
        guard try await environment.conversationStore.conversation(id: conversationID) != nil else {
            return .absent
        }
        let runs = try await environment.runStore.runs(conversationID: conversationID)
        return runs.isEmpty ? .bareConversation : .launched
    }

    /// Keeps the original display name intact (including UTF-8 text like
    /// 主视觉) while removing only characters that are hostile in a
    /// relative file path.
    static func sanitizedMaterialName(_ raw: String) -> String {
        var name = raw.replacingOccurrences(
            of: #"[/\\\x00-\x1f:]"#, with: "_", options: .regularExpression)
        name = name.trimmingCharacters(in: .whitespaces)
        while name.hasPrefix(".") { name.removeFirst() }
        if name.isEmpty { name = "material" }
        return String(name.prefix(80))
    }

    private static func finish(
        _ record: CreativeRouteRecord, created: Bool, sourceRunID: UUID
    ) async -> RouteOutcome {
        let foreground = await Self.foregroundRunProbe?(sourceRunID) ?? false
        var navigated = false
        if foreground, let navigator = CreativeDestinationRouter.navigator,
           let destination = record.destinationConversationID {
            navigator(destination)
            navigated = true
        }
        return RouteOutcome(
            record: record,
            created: created,
            navigated: navigated,
            message: navigated
                ? "created the ordinary task and navigated (foreground run)"
                : "created the ordinary task; navigation suppressed (background run, switched conversation, or no navigation seam)")
    }

    /// REAL canvas destination for a creative request: creates the durable
    /// canvas document + its workspace record (idempotent per operationID
    /// through a route record), and navigates ONLY when the initiating run
    /// is foreground with the seam installed. Replays return the recorded
    /// canvas without recreating or re-navigating.
    static func ensureCanvasDestination(
        goal: String,
        operationID: String,
        sourceRunID: UUID,
        environment: AppEnvironment
    ) async throws -> (navigableID: UUID, navigated: Bool) {
        // Read-only origin verification BEFORE the reservation.
        guard let originRun = try? await environment.runStore.run(id: sourceRunID) else {
            throw RouteError.originUnresolvable("run \(sourceRunID.uuidString) does not exist")
        }
        let digest = payloadDigest(
            goal: goal, family: .composition, needsLinux: false, hint: "canvas",
            existingWorkspaceID: nil, createProject: true,
            destinationEnvironmentID: nil, canvasID: nil,
            sourceDocumentID: nil, sourceRevision: nil,
            nodeIDs: [], materialSHAs: [])
        enum CanvasReservation { case reserved(CreativeRouteRecord), returnNavigable(UUID) }
        let reservation: CanvasReservation = try CreativeRouteStore.synchronized { records in
            if let existing = records.first(where: {
                $0.operationID == operationID && $0.sourceRunID == sourceRunID
            }) {
                guard existing.payloadDigest == digest else {
                    throw CreativeRouteError.payloadConflict(
                        "operationID '\(operationID)' was already used with a different payload")
                }
                guard let canvasID = existing.destinationCanvasID else {
                    throw CreativeRouteError.storeCorrupt("canvas route without a destination canvas id")
                }
                return .returnNavigable(canvasID)
            }
            let record = CreativeRouteRecord(
                operationID: operationID,
                payloadDigest: digest,
                status: .prepared,
                sourceConversationID: originRun.conversationID,
                sourceRunID: sourceRunID,
                sourceCanvasID: nil,
                sourceDocumentID: nil,
                sourceProjectRevision: nil,
                sourceNodeIDs: [],
                materials: [],
                destinationConversationID: nil,
                destinationWorkspaceID: UUID(),
                destinationEnvironmentID: nil,
                destinationCanvasID: UUID(),
                family: DesignContentType.composition.rawValue,
                goal: goal,
                error: nil,
                createdAt: Date())
            var updated = records
            updated.append(record)
            try CreativeRouteStore.save(updated)
            return .reserved(record)
        }
        if case .returnNavigable(let canvasID) = reservation {
            return (canvasID, false)
        }
        guard case .reserved(let record) = reservation else {
            throw CreativeRouteError.storeUnavailable("unexpected canvas reservation state")
        }
        guard let canvasID = record.destinationCanvasID else {
            throw CreativeRouteError.storeCorrupt("reserved canvas route without a destination canvas id")
        }
        let workspaceID = record.destinationWorkspaceID
        let title = String(goal.trimmingCharacters(in: .whitespacesAndNewlines).prefix(40))
        // Durable canvas document (WorkspaceCanvasRegistry storage).
        let projectURL = try WorkspaceCanvasRegistry.projectURL(canvasID: canvasID, createDirectory: true)
        let document = CanvasDocument(id: UUID(), name: title.isEmpty ? "创意画布" : title, nodes: [])
        let project = CanvasProject(
            id: canvasID,
            name: title.isEmpty ? "创意画布" : title,
            documents: [document],
            selectedDocumentID: document.id)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        try CanvasProjectCodec.encode(project, encoder: encoder).write(to: projectURL, options: .atomic)
        // Workspace record so the canvas appears in the sidebar and opens
        // through the SAME surface as every other canvas.
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true)
            .appendingPathComponent("FloeAgent/Canvases/\(canvasID.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        // The canvas opens through the EXISTING surface keyed by the
        // workspace id, so the workspace record carries the canvas id.
        let workspace = WorkspaceRecord(
            id: canvasID,
            name: project.name,
            rootBookmark: try support.bookmarkData(options: .minimalBookmark),
            kind: .project)
        try await SQLiteWorkspaceStore(database: environment.database).saveWorkspace(workspace)
        var started = record
        started.status = .started
        try CreativeRouteStore.upsert(started)
        let foreground = await Self.foregroundRunProbe?(sourceRunID) ?? false
        var navigated = false
        if foreground, let navigator = Self.canvasNavigator {
            navigator(canvasID)
            navigated = true
        }
        return (canvasID, navigated)
    }



    /// Verified immutable material snapshots for EXPLICIT canvas nodes —
    /// the shared path for the model tool and the manual canvas entry.
    /// Source canvas/nodes are never mutated; text nodes contribute their
    /// text, asset nodes contribute hash-verified bytes.
    ///
    /// Authority (BEFORE any material byte is read):
    /// - `runContext` (model route): the run must be bound to the named
    ///   canvas; the document is the bound document (never selected/first);
    ///   when the run carries the user's selection, every named node must be
    ///   part of it — forged, cross-canvas, stale or unknown references are
    ///   rejected with no read side effects.
    /// - `runContext == nil` (manual entry): the visible UI selection is the
    ///   authority; the selected document is used.
    /// Resource preflight: per-material count and the AGGREGATE byte bound
    /// are checked from asset metadata/text size BEFORE any asset Data is
    /// loaded (per-file actual-size guards still apply at resolve time).
    static func materialSnapshots(
        canvasID: UUID,
        nodeIDs: [UUID],
        repository: any CanvasDocumentRepository,
        environment: AppEnvironment,
        runContext: CanvasRunContext? = nil
    ) async throws -> (
        materials: [HandoffMaterial],
        documentID: UUID?,
        sourceRevision: Int64?
    ) {
        if let runContext {
            guard runContext.canvasID == canvasID else {
                throw RouteError.canvasBindingMismatch(
                    expected: runContext.canvasID, supplied: canvasID)
            }
        }
        guard let project = try? await repository.project(canvasID: canvasID) else {
            throw RouteError.canvasNotFound(canvasID)
        }
        let document: CanvasDocument?
        if let boundID = runContext?.documentID {
            document = project.documents.first(where: { $0.id == boundID })
            guard document != nil else {
                throw CreativeRouteError.storeCorrupt(
                    "run is bound to document \(boundID.uuidString) which is not in canvas \(canvasID.uuidString)")
            }
        } else {
            document = project.documents.first(where: { $0.id == project.selectedDocumentID })
                ?? project.documents.first
        }
        let selection = runContext.map { Set($0.selectedNodeIDs) } ?? []
        var expected: [(node: CanvasNode, name: String, expectedBytes: Int)] = []
        expected.reserveCapacity(nodeIDs.count)
        for nodeID in nodeIDs {
            if !selection.isEmpty && !selection.contains(nodeID) {
                throw RouteError.nodeOutsideSelection(nodeID)
            }
            guard let node = document?.nodes.first(where: { $0.id == nodeID }) else {
                throw RouteError.nodeMissing(nodeID)
            }
            if let asset = node.asset {
                guard let hash = asset.contentHash else {
                    throw FloeError.validationFailed("node \(nodeID.uuidString) has an unresolved material (no content hash)")
                }
                guard let assetRecord = try await environment.creativeAssetStore.asset(contentHash: hash) else {
                    throw FloeError.notFound("node \(nodeID.uuidString) material is not in the local asset store (cloud-only or missing)")
                }
                let displayName = node.title ?? node.id.uuidString
                expected.append((
                    node: node,
                    name: "\(displayName).\(Self.materialExtension(for: assetRecord))",
                    expectedBytes: Int(max(assetRecord.byteCount, 0))))
            } else if !node.text.isEmpty {
                expected.append((
                    node: node,
                    name: "\(node.title ?? node.id.uuidString).md",
                    expectedBytes: node.text.utf8.count))
            } else {
                throw RouteError.nodeMissing(nodeID)
            }
        }
        guard !expected.isEmpty else {
            throw RouteError.noMaterials
        }
        // AGGREGATE preflight BEFORE loading any material bytes (asset
        // byteCount is metadata and may be stale — per-file actual-size
        // guards still enforce the truth at resolve time).
        guard expected.count <= maximumMaterials else {
            throw FloeError.validationFailed("at most \(maximumMaterials) materials per handoff")
        }
        let totalExpected = expected.reduce(0) { $0 + $1.expectedBytes }
        guard totalExpected <= maximumMaterialBytes else {
            throw FloeError.validationFailed(
                "handoff materials exceed the \(maximumMaterialBytes)-byte bound (preflight total \(totalExpected))")
        }
        var snapshots: [HandoffMaterial] = []
        snapshots.reserveCapacity(expected.count)
        for item in expected {
            let bytes: Data
            if let asset = item.node.asset, let hash = asset.contentHash {
                guard let assetRecord = try await environment.creativeAssetStore.asset(contentHash: hash) else {
                    throw FloeError.notFound("node \(item.node.id.uuidString) material is not in the local asset store (cloud-only or missing)")
                }
                let resolved = try await AppCreativeDocumentPort.resolveVerifiedAssetBytes(
                    assetStore: environment.creativeAssetStore,
                    artifactRoot: { try FloeArtifactStore.root() },
                    creationID: assetRecord.id.uuidString)
                bytes = resolved.data
            } else {
                bytes = Data(item.node.text.utf8)
            }
            snapshots.append(HandoffMaterial(
                nodeID: item.node.id, name: item.name, bytes: bytes))
        }
        return (snapshots, document?.id, project.revision)
    }

    /// The real file extension for a staged material: the asset's own format
    /// when recorded, otherwise a small set of truthfully-derived
    /// fallbacks — never a fabricated conversion.
    private static func materialExtension(for record: CreativeAssetRecord) -> String {
        if let ext = record.localRelativePath?.split(separator: ".").last,
           !ext.isEmpty, ext.count <= 8 {
            return String(ext).lowercased()
        }
        return "bin"
    }

    private static func resolveWorkspace(
        _ store: SQLiteWorkspaceStore, id: UUID
    ) async throws -> WorkspaceRecord {
        guard let record = try await store.workspace(id: id) else {
            throw FloeError.notFound("workspace \(id.uuidString)")
        }
        return record
    }
}

// MARK: - Model tools

/// `creative.chooseDestination` — the model reads real capabilities (via
/// canvas.designCapabilities) and commits the destination HERE, with the
/// real capability re-verified and the project path created + navigated.
/// Ordinary Q&A never reaches this tool (no goal/materials → nothing to
/// route); a refusal carries the concrete recovery.
struct CreativeChooseDestinationTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var goal: String
        var family: String
        var needsLinux: Bool?
        var hint: String?
        var operationID: String
    }

    static let name = "creative.chooseDestination"
    static let toolDescription = "Commit the destination for a creative request after reading the real capabilities with canvas.designCapabilities: visual composition/material arrangement routes to the canvas ('canvas'); webpages, executable source projects and anything needing terminal/package/web-service/Linux tooling routes to a NEW ordinary project + ordinary task created and navigated ('project'). Office routes by real native/engine capability, never by extension. Idempotent by operationID: replays return the recorded destination without recreating, recopying or re-navigating. Ordinary Q&A must not call this tool."
    static let parametersJSON = #"{"type":"object","properties":{"goal":{"type":"string","description":"The user's creative goal verbatim (short)"},"family":{"type":"string","enum":["webpage","prototype","presentation","image","video","officeDocument","notes","pdf","cad"]},"needsLinux":{"type":"boolean","description":"True when the goal needs terminal/package install/web serving/Linux tooling"},"hint":{"type":"string","enum":["canvas","project"]},"operationID":{"type":"string","description":"Idempotency identity for this routing decision"}},"required":["goal","family","operationID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.writesFiles, .persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating

    let environment: AppEnvironment?

    func validate(_ args: Arguments) throws {
        guard !args.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("goal must not be empty")
        }
        guard !args.operationID.isEmpty else {
            throw FloeError.validationFailed("operationID is required")
        }
        guard DesignContentType(rawValue: args.family) != nil else {
            throw FloeError.validationFailed("family must be one of the declared content families")
        }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let environment else {
            return ToolExecutionOutput(digesting: "status=unavailable the creative router is not connected", exitStatus: 125)
        }
        guard let family = DesignContentType(rawValue: args.family) else {
            throw FloeError.validationFailed("unknown family \(args.family)")
        }
        // The FULL contract (digest check, replay/conflict/recover states,
        // store errors) lives in the router — no bypassing early returns,
        // no swallowed store errors.
        let decision = CreativeDestinationRouter.assessDestination(
            family: family, needsLinux: args.needsLinux == true, hint: args.hint,
            environment: environment)
        guard decision.destination != "refused" else {
            return ToolExecutionOutput(
                digesting: "status=unsupported destination=canvas refused: family \(family.rawValue) is not a visual composition family; route to 'project' instead",
                exitStatus: 125)
        }
        if decision.destination == "canvas" {
            // REAL canvas destination: create the durable canvas (idempotent
            // by operationID) and navigate through the shell seam.
            let canvas = try await CreativeDestinationRouter.ensureCanvasDestination(
                goal: args.goal, operationID: args.operationID,
                sourceRunID: context.runID, environment: environment)
            return ToolExecutionOutput(digesting: [
                "status=ok",
                "destination=canvas",
                "canvasID=\(canvas.navigableID.uuidString)",
                "navigated=\(canvas.navigated)",
                "reasons=\(decision.reasons.joined(separator: "; "))",
                "note=the canvas was created for this request (idempotent); the ordinary task path was NOT used",
            ].joined(separator: "\n"), exitStatus: 0)
        }
        let outcome = try await CreativeDestinationRouter.routeToOrdinaryTask(
            goal: args.goal,
            family: family,
            needsLinux: args.needsLinux == true,
            operationID: args.operationID,
            sourceRunID: context.runID,
            sourceCanvasID: nil,
            sourceNodeIDs: [],
            snapshots: [],
            existingWorkspaceID: nil,
            createProject: true,
            environment: environment)
        return output(outcome.record, created: outcome.created,
                      navigated: outcome.navigated, message: outcome.message)
    }

    private func output(
        _ record: CreativeRouteRecord, created: Bool, navigated: Bool, message: String
    ) -> ToolExecutionOutput {
        ToolExecutionOutput(digesting: [
            "status=ok",
            "destination=project",
            "created=\(created)",
            "navigated=\(navigated)",
            "operationReplayed=\(!created)",
            "destinationConversationID=\(record.destinationConversationID?.uuidString ?? "-")",
            "destinationWorkspaceID=\(record.destinationWorkspaceID.uuidString)",
            "family=\(record.family)",
            message,
        ].joined(separator: "\n"), exitStatus: 0)
    }
}

/// `canvas.startOrdinaryTask` — the deterministic canvas→ordinary-task
/// handoff. The model names the canvas, the EXPLICIT node/material set, the
/// goal, the target project (existing or new) and the idempotency
/// operationID. Materials transfer as verified immutable byte snapshots;
/// the source canvas/nodes are untouched; the tool transfers NO execution
/// authority (the canvas whitelist stays visual-only; the new ordinary task
/// starts Linux only through its own capabilities and approvals).
struct CanvasStartOrdinaryTaskTool: AgentTool {
    struct Arguments: Decodable, Sendable {
        var canvasID: String
        var nodeIDs: [String]
        var goal: String
        /// The content family of the goal (webpage default) — used for the
        /// route digest, never to fabricate a toolchain.
        var family: String?
        var projectWorkspaceID: String?
        var createProject: Bool?
        var operationID: String
    }

    static let name = "canvas.startOrdinaryTask"
    static let toolDescription = "Start an ordinary project+task from EXPLICIT canvas materials. Name the canvas id, the node ids the user selected or named (never guess the selection), the goal, the target project (existing projectWorkspaceID or createProject=true) and an idempotency operationID. Materials transfer as verified immutable snapshots; the source canvas and nodes stay untouched; results belong to the new task (back-filling the canvas needs an explicit adoption). Replays, restores and late results return the recorded association without recreating, recopying or re-navigating. This tool transfers no execution authority: the canvas stays visual-only and the new task uses its own capabilities and approvals for any Linux work."
    static let parametersJSON = #"{"type":"object","properties":{"canvasID":{"type":"string"},"nodeIDs":{"type":"array","items":{"type":"string"},"minItems":1},"goal":{"type":"string"},"family":{"type":"string","enum":["webpage","prototype","presentation","image","video","officeDocument","notes","pdf","cad"]},"projectWorkspaceID":{"type":"string","description":"Existing project workspace UUID"},"createProject":{"type":"boolean","description":"Create a new project workspace when no existing one is named"},"operationID":{"type":"string"}},"required":["canvasID","nodeIDs","goal","operationID"],"additionalProperties":false}"#
    static let riskLabels: Set<RiskLabel> = [.readsFiles, .writesFiles, .persistsPersonalData]
    static let isSideEffecting = true
    static let toolEffect: ToolEffect = .mutating

    let environment: AppEnvironment?
    let canvasRepository: any CanvasDocumentRepository
    /// The durable run→canvas binding authority. The tool may ONLY hand off
    /// from the canvas/document this run is bound to — a supplied canvas id
    /// that does not match the binding is a forged cross-canvas reference
    /// and is refused BEFORE any material byte is read.
    let runContexts: CanvasRunContextStore

    func validate(_ args: Arguments) throws {
        _ = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        guard !args.nodeIDs.isEmpty else {
            throw FloeError.validationFailed("nodeIDs must name at least one material (no guessing)")
        }
        for id in args.nodeIDs { _ = try DesignToolOutput.requireUUID(id, field: "nodeIDs") }
        guard !args.goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw FloeError.validationFailed("goal must not be empty")
        }
        guard !args.operationID.isEmpty else {
            throw FloeError.validationFailed("operationID is required")
        }
        if let raw = args.family, DesignContentType(rawValue: raw) == nil {
            throw FloeError.validationFailed("family must be one of the declared content families")
        }
        if let raw = args.projectWorkspaceID {
            _ = try DesignToolOutput.requireUUID(raw, field: "projectWorkspaceID")
        }
        // Exactly one destination choice: an existing project workspace or
        // an explicit createProject=true — never a silent fallback.
        if (args.projectWorkspaceID != nil) == (args.createProject == true) {
            throw FloeError.validationFailed(
                "name exactly one destination: projectWorkspaceID (existing project) or createProject=true")
        }
    }

    func execute(_ args: Arguments, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let environment else {
            return ToolExecutionOutput(digesting: "status=unavailable the handoff service is not connected", exitStatus: 125)
        }
        // Full router contract (digest/replay/conflict/recover + store
        // errors propagate) — no bypassing early seam.
        let canvasID = try DesignToolOutput.requireUUID(args.canvasID, field: "canvasID")
        let nodeIDs = try args.nodeIDs.map { try DesignToolOutput.requireUUID($0, field: "nodeIDs") }
        // Authority BEFORE any bytes: the run must be bound to a canvas, and
        // the supplied canvas id must match that durable binding.
        guard let runContext = try await runContexts.context(runID: context.runID) else {
            throw CreativeDestinationRouter.RouteError.noCanvasBinding(context.runID)
        }
        guard runContext.canvasID == canvasID else {
            throw CreativeDestinationRouter.RouteError.canvasBindingMismatch(
                expected: runContext.canvasID, supplied: canvasID)
        }
        let staged = try await CreativeDestinationRouter.materialSnapshots(
            canvasID: canvasID,
            nodeIDs: nodeIDs,
            repository: canvasRepository,
            environment: environment,
            runContext: runContext)
        let snapshots = staged.materials
        guard !snapshots.isEmpty else {
            throw CreativeDestinationRouter.RouteError.noMaterials
        }
        let workspaceID = args.projectWorkspaceID.flatMap(UUID.init(uuidString:))
        let family = args.family.flatMap(DesignContentType.init(rawValue:)) ?? .webpage
        // The handoff transfers materials only; whether the new task needs
        // Linux is decided by ITS OWN toolchain and approvals, so no Linux
        // requirement is imposed here.
        let outcome = try await CreativeDestinationRouter.routeToOrdinaryTask(
            goal: args.goal,
            family: family,
            needsLinux: false,
            operationID: args.operationID,
            sourceRunID: context.runID,
            sourceCanvasID: canvasID,
            sourceNodeIDs: nodeIDs,
            snapshots: snapshots,
            existingWorkspaceID: workspaceID,
            createProject: args.createProject == true,
            sourceDocumentID: staged.documentID,
            sourceRevision: staged.sourceRevision,
            environment: environment)
        return ToolExecutionOutput(digesting: [
            "status=ok",
            "destination=project",
            "created=\(outcome.created)",
            "navigated=\(outcome.navigated)",
            "materials=\(snapshots.count)",
            "sourceDocumentID=\(outcome.record.sourceDocumentID?.uuidString ?? "-")",
            "sourceRevision=\(outcome.record.sourceProjectRevision.map(String.init) ?? "-")",
            "destinationConversationID=\(outcome.record.destinationConversationID?.uuidString ?? "-")",
            "note=source canvas and nodes preserved; results belong to the new task",
            outcome.message,
        ].joined(separator: "\n"), exitStatus: 0)
    }
}
#endif
