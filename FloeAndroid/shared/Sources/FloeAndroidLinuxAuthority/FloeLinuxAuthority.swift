// SPDX-License-Identifier: MPL-2.0
//
// G03-R2 — the Android isolated-runtime Linux environment authority.
//
// This actor is the ONLY owner of the runtime component's environment lease
// book. It reuses the ORIGINAL FloeEnvironments authority end-to-end:
// `EnvironmentRegistry` (records, layers, ownership),
// `EnvironmentExecutionCoordinator` (leases, stopAndWait accounting) and
// `LinuxExecutionLeaseResolver.acquireHolder` (launch-authority gate,
// cross-checked explicit `.linuxPRoot` backend, session ownership,
// workspace-hash owner chain). There is no alternate registry, no job DB, no
// environment DB, no host execution alias, and no backend selection outside
// the settled `linuxPRoot` value.
//
// Settled lifecycle rules (Main 2026-10-22):
// - ONE active runtime lease globally for this initial backend (bounded
//   concurrency 1): a later materialization can never mutate a live
//   directory, and Main's rootfs materializer runs under the held lease.
// - Holders live only here. Nothing in this wire releases on client
//   disconnect — there is no disconnect signal — and `cancel` NEVER
//   releases: it only requests cooperative cancellation and retains the
//   lease until a real process-identity-matched completion.
// - `abandon` (no process ever started — markWasStarted never bound an
//   identity) is strictly distinct from `complete` (started process with an
//   attested quiescence). A started holder can only finish via `complete`.
// - `complete` requires the EXACT bound process identity plus the runtime
//   service's waitpid-style quiescence attestation. The authority treats that
//   attestation as the trusted service's assertion; it does not claim OS
//   exit observation, and these lifecycle operations must never be exposed
//   to model command dispatch or public IPC (Main owns ingress separation).
// - Configuration replacement is refused while ANY lease is retained,
//   including started, cancel-requested and failed-release recoverable ones.
// - A failed lease release keeps the entry so `complete`/`abandon` can be
//   retried; the lease is never silently dropped.
// - `orderedLayers` is registry LOOKUP ORDER only. Rootfs materialization,
//   snapshot/inheritance and exec.shell capability enablement are Main's
//   composition (core/linuxruntime); this module never advertises readiness
//   from registry existence.

import Foundation
import FloeCore
import FloeTools
import FloeEnvironments

/// Linux environment lease authority for the independent-UID runtime
/// component. Public so Main's composition can use it directly from Swift;
/// the C bridge (`FloeLinuxAuthorityBridge`) funnels the same `exchange`
/// entry for JNI callers.
public actor FloeLinuxAuthority {
    /// Process-wide authority instance used by the native bridge. Main's
    /// serialized native IO executor is the only concurrent caller; the
    /// actor itself remains safe for direct Swift use.
    public static let shared = FloeLinuxAuthority()

    public init() {}

    // MARK: - State

    private struct Configuration {
        let stateRoot: LinuxAuthorityResolvedRoot
        let workspacesRoot: LinuxAuthorityResolvedRoot
        let baseRoot: LinuxAuthorityResolvedRoot
        let baseRevision: String
        let roots: EnvironmentRoots
        let registry: EnvironmentRegistry
        let coordinator: EnvironmentExecutionCoordinator
    }

    private struct LeaseEntry {
        let leaseID: String
        let holder: LinuxExecutionLeaseHolder
        let descriptor: LinuxExecutionLeaseDescriptor
        let cancellation: CancellationToken
        var processIdentity: LinuxAuthorityProcessIdentity?
        var cancellationRequested = false
        /// True once a trusted quiescence (or never-started abandon) gate has
        /// marked the holder; lets a failed release retry without re-attesting.
        var quiescenceAcknowledged = false
    }

    private enum TerminalKind: Equatable { case released, abandoned }

    private var configuration: Configuration?
    private var leases: [String: LeaseEntry] = [:]
    /// Reentrancy gates (Main review 2026-10-22): Swift actors suspend at
    /// `await`, so checked-then-commit alone is NOT exclusive. These
    /// reservations are set in each operation's FIRST synchronous stretch —
    /// before any suspension — and cleared on every exit path, so a
    /// concurrent acquire/configure callback (possibly from different trusted
    /// threads) can never pass a stale emptiness check.
    private var acquireInFlight = false
    private var configureInFlight = false
    /// Bounded FIFO of finished lease ids so an idempotent `complete`/
    /// `abandon` retry returns success instead of `leaseNotFound`.
    private var terminalLedger: [(leaseID: String, kind: TerminalKind)] = []

    // MARK: - Handshake

    public func handshake() -> LinuxAuthorityHandshakeInfo {
        LinuxAuthorityHandshakeInfo(
            wireVersion: LinuxAuthorityWire.version,
            configured: configuration != nil,
            activeLease: !leases.isEmpty,
            leaseAdmissionPending: acquireInFlight,
            configurationInFlight: configureInFlight,
            maxConcurrentRuntimeLeases: 1,
            execShellReady: false
        )
    }

    // MARK: - Configuration

    /// Applies the trusted engine-private configuration. Identical repeats
    /// are no-ops; a different configuration may only replace a fully
    /// lease-free one. The ORIGINAL registry/coordinator are (re)built here
    /// and `registry.prepare()` gates usability fail-closed.
    public func configure(_ request: LinuxAuthorityConfigureRequest) async throws -> LinuxAuthorityConfigureInfo {
        // Reserve BEFORE any suspension: no second configure can interleave,
        // and lease admission arriving mid-apply sees configurationInFlight.
        guard !configureInFlight else {
            throw LinuxAuthorityError(code: .configurationInFlight, message: "a configure is already applying; retry after it settles")
        }
        configureInFlight = true
        defer { configureInFlight = false }
        let baseRevision = request.baseRevision
        guard !baseRevision.isEmpty,
              baseRevision.utf8.count <= LinuxAuthorityWire.maximumBaseRevisionBytes,
              !baseRevision.unicodeScalars.contains(where: { $0 == "\u{0}" || CharacterSet.controlCharacters.contains($0) }),
              baseRevision.trimmingCharacters(in: .whitespacesAndNewlines) == baseRevision,
              !baseRevision.isEmpty else {
            throw LinuxAuthorityError(code: .invalidBaseRevision, message: "baseRevision must be a trimmed 1–64 byte string without control characters")
        }
        let stateRoot = try LinuxAuthorityRootPolicy.validate(path: request.stateRoot, role: "stateRoot")
        let workspacesRoot = try LinuxAuthorityRootPolicy.validate(path: request.workspacesRoot, role: "workspacesRoot")
        let baseRoot = try LinuxAuthorityRootPolicy.validate(path: request.baseRoot, role: "baseRoot")
        try LinuxAuthorityRootPolicy.validateDisjoint([stateRoot, workspacesRoot, baseRoot])

        if let existing = configuration {
            if existing.stateRoot.canonicalPath == stateRoot.canonicalPath,
               existing.workspacesRoot.canonicalPath == workspacesRoot.canonicalPath,
               existing.baseRoot.canonicalPath == baseRoot.canonicalPath,
               existing.baseRevision == baseRevision {
                return Self.configureInfo(existing, replaced: false)
            }
            guard leases.isEmpty, !acquireInFlight else {
                // Any retained holder OR a pending lease admission (reserved
                // across its await window) locks the configuration.
                throw LinuxAuthorityError(code: .configurationLockedByLease,
                                          message: "configuration replacement is refused while a runtime lease is retained or being admitted")
            }
        }

        let roots: EnvironmentRoots
        do {
            roots = try EnvironmentRoots.makeTrusted(rootURL: stateRoot.url)
        } catch {
            throw LinuxAuthorityError(code: .invalidRoot,
                                      message: "stateRoot rejected by the original trusted-root gate: \(LinuxAuthorityWire.boundedMessage(error.localizedDescription))")
        }
        let registry = EnvironmentRegistry(
            roots: roots,
            baseRevision: baseRevision,
            compatibleBaseRevisions: [],
            defaultExecutionBackend: .linuxPRoot
        )
        let coordinator = EnvironmentExecutionCoordinator(roots: roots, registry: registry, bundledBaseURL: baseRoot.url)
        do {
            try await registry.prepare()
        } catch {
            // Fail closed WITHOUT touching a previously committed
            // configuration: the old registry (if any) stays authoritative.
            throw LinuxAuthorityError(code: .stateRootUnusable,
                                      message: "registry prepare failed for the new configuration: \(LinuxAuthorityWire.boundedMessage(error.localizedDescription))")
        }
        let replaced = configuration != nil
        configuration = Configuration(stateRoot: stateRoot, workspacesRoot: workspacesRoot, baseRoot: baseRoot,
                                      baseRevision: baseRevision, roots: roots, registry: registry, coordinator: coordinator)
        return Self.configureInfo(configuration!, replaced: replaced)
    }

    private static func configureInfo(_ config: Configuration, replaced: Bool) -> LinuxAuthorityConfigureInfo {
        LinuxAuthorityConfigureInfo(configured: true, replaced: replaced, baseRevision: config.baseRevision,
                                    stateRoot: config.stateRoot.canonicalPath,
                                    workspacesRoot: config.workspacesRoot.canonicalPath,
                                    baseRoot: config.baseRoot.canonicalPath)
    }

    // MARK: - Metadata

    /// Environment metadata ONLY (registry records). No layer paths, no
    /// variables, no process or lease data.
    public func list() async throws -> LinuxAuthorityEnvironmentList {
        guard let config = configuration else { throw LinuxAuthorityError(code: .notConfigured, message: "configure the authority with trusted roots first") }
        let baseRevision = await config.registry.baseRevision
        let records = await config.registry.all()
        let metadata = records.sorted { $0.id < $1.id }.map { record in
            LinuxAuthorityEnvironmentMetadata(
                id: record.id,
                kind: record.kind.rawValue,
                ownerID: record.ownerID,
                name: record.name,
                state: record.state.rawValue,
                baseRevision: record.baseRevision,
                requiresRebuild: record.requiresRebuild,
                rebuildReason: record.rebuildReason,
                executionBackend: record.executionBackend?.rawValue,
                bytes: record.bytes,
                packageCount: record.packageCount,
                parentID: record.parentID,
                templateID: record.templateID
            )
        }
        return LinuxAuthorityEnvironmentList(baseRevision: baseRevision, environments: metadata)
    }

    // MARK: - Lease acquisition

    /// Acquires the single runtime lease through the ORIGINAL authority.
    /// Creates/resolves the explicit engine-private workspace
    /// `workspacesRoot/<canonical project UUID>`, constructs the original
    /// `ToolContext` and calls `LinuxExecutionLeaseResolver.acquireHolder`
    /// with the settled `.linuxPRoot` selection. No hidden first-project or
    /// default workspace selection exists on any path.
    public func acquire(_ request: LinuxAuthorityAcquireRequest) async throws -> LinuxAuthorityAcquireInfo {
        guard let config = configuration else { throw LinuxAuthorityError(code: .notConfigured, message: "configure the authority with trusted roots first") }
        let projectID = try Self.canonicalUUID(request.projectID, field: "projectID")
        let runID = try Self.canonicalUUID(request.runID, field: "runID")
        let conversationID: UUID?
        if let raw = request.conversationID {
            conversationID = try Self.canonicalUUID(raw, field: "conversationID")
        } else {
            conversationID = nil
        }
        let environmentID: String?
        if let raw = request.environmentID {
            guard Self.isValidEnvironmentID(raw) else {
                throw LinuxAuthorityError(code: .invalidIdentifier, message: "environmentID must be a 1–64 character [A-Za-z0-9._-] id without '..'")
            }
            environmentID = raw
        } else {
            environmentID = nil
        }
        // Settled global concurrency 1: ANY retained entry (including a
        // failed-release one) blocks acquisition so no later materialization
        // can mutate a live directory. The IN-FLIGHT admission is reserved
        // here, in this synchronous stretch BEFORE the first suspension, so
        // two concurrent acquires (or an acquire against a configuring
        // replacement) can never both pass the emptiness check (Main
        // reentrancy review 2026-10-22).
        guard !configureInFlight else {
            throw LinuxAuthorityError(code: .configurationInFlight,
                                      message: "a configure is applying; lease admission is refused until it settles")
        }
        guard leases.isEmpty, !acquireInFlight else {
            throw LinuxAuthorityError(code: .leaseBusy, message: "one runtime lease is already retained or being admitted; release or abandon it before acquiring another")
        }
        acquireInFlight = true
        defer { acquireInFlight = false }

        let workspace = try LinuxAuthorityRootPolicy.workspace(parentCanonicalPath: config.workspacesRoot.canonicalPath, name: projectID.uuidString)
        let cancellation = CancellationToken()
        let context = ToolContext(
            runID: runID,
            scope: .local,
            workspaceRootURL: workspace.url,
            cancellation: cancellation,
            environmentID: environmentID,
            conversationID: conversationID
        )
        let holder: LinuxExecutionLeaseHolder
        do {
            holder = try await LinuxExecutionLeaseResolver.acquireHolder(
                context,
                coordinator: config.coordinator,
                registry: config.registry,
                selectedBackend: .linuxPRoot
            )
        } catch let error {
            throw Self.mapAuthorityError(error)
        }
        let descriptor = await holder.descriptor
        // Identity survival check (defensive, should never trip): the holder
        // must carry exactly the workspace/run this request addressed; if it
        // does not, nothing was ever launched, so the not-started cleanup
        // path applies.
        guard descriptor.runID == runID, descriptor.workspaceRootURL.path == workspace.canonicalPath else {
            await Self.retireUnstartedHolder(holder)
            throw LinuxAuthorityError(code: .internalError, message: "acquired descriptor does not match the requested identities; lease was retired unstarted")
        }
        let leaseID = UUID().uuidString
        leases[leaseID] = LeaseEntry(leaseID: leaseID, holder: holder, descriptor: descriptor, cancellation: cancellation)
        return LinuxAuthorityAcquireInfo(leaseID: leaseID, descriptor: Self.descriptorInfo(descriptor))
    }

    private static func descriptorInfo(_ descriptor: LinuxExecutionLeaseDescriptor) -> LinuxAuthorityDescriptor {
        LinuxAuthorityDescriptor(
            environmentID: descriptor.environmentID,
            runID: descriptor.runID.uuidString,
            conversationID: descriptor.conversationID?.uuidString,
            workspaceID: descriptor.workspaceID,
            workspaceRoot: descriptor.workspaceRootURL.path,
            projectContainerID: descriptor.projectContainerID,
            backend: descriptor.backend.rawValue,
            writableLayer: descriptor.writableLayerURL.path,
            orderedLayers: descriptor.orderedLayerURLs.map(\.path),
            home: descriptor.homeURL.path,
            tmp: descriptor.temporaryURL.path,
            variables: descriptor.environmentVariables,
            baseRevision: descriptor.baseRevision
        )
    }

    // MARK: - Lease lifecycle

    /// Binds the launched process identity ONCE. A repeat with the identical
    /// identity is an idempotent success; a different identity fails closed.
    public func markStarted(_ request: LinuxAuthorityMarkStartedRequest) throws -> LinuxAuthorityLeaseStateInfo {
        guard configuration != nil else { throw LinuxAuthorityError(code: .notConfigured, message: "configure the authority with trusted roots first") }
        let leaseID = try Self.canonicalUUID(request.leaseID, field: "leaseID")
        try validateProcessIdentityShape(request.processIdentity)
        guard var entry = leases[leaseID.uuidString] else {
            throw Self.leaseLookupFailure(leaseID)
        }
        if let bound = entry.processIdentity {
            guard bound == request.processIdentity else {
                throw LinuxAuthorityError(code: .processIdentityMismatch, message: "this lease already carries a different bound process identity")
            }
        } else {
            entry.processIdentity = request.processIdentity
            leases[leaseID.uuidString] = entry
        }
        return LinuxAuthorityLeaseStateInfo(leaseID: leaseID.uuidString, state: "started", started: true, released: false)
    }

    /// Cooperative cancellation REQUEST only: cancels the context token the
    /// ORIGINAL coordinator tracks, retains the holder and the registry
    /// lease. Never a release path; disconnect is not an operation here.
    public func cancel(_ request: LinuxAuthorityLeaseRequest) throws -> LinuxAuthorityLeaseStateInfo {
        guard configuration != nil else { throw LinuxAuthorityError(code: .notConfigured, message: "configure the authority with trusted roots first") }
        let leaseID = try Self.canonicalUUID(request.leaseID, field: "leaseID")
        guard var entry = leases[leaseID.uuidString] else {
            throw Self.leaseLookupFailure(leaseID)
        }
        entry.cancellationRequested = true
        entry.cancellation.cancel()
        leases[leaseID.uuidString] = entry
        return LinuxAuthorityLeaseStateInfo(leaseID: leaseID.uuidString, state: "cancelRequested",
                                            started: entry.processIdentity != nil, released: false)
    }

    /// The ONLY finish path for a STARTED lease. Requires the exact bound
    /// process identity and the trusted runtime service's quiescence
    /// attestation, then marks the holder quiesced and hands the ORIGINAL
    /// coordinator lease back. A failed hand-back keeps the entry recoverable
    /// for a retry of this same call.
    public func complete(_ request: LinuxAuthorityCompleteRequest) async throws -> LinuxAuthorityCompleteInfo {
        guard configuration != nil else { throw LinuxAuthorityError(code: .notConfigured, message: "configure the authority with trusted roots first") }
        let leaseID = try Self.canonicalUUID(request.leaseID, field: "leaseID")
        guard var entry = leases[leaseID.uuidString] else {
            if terminalLedgerContains(leaseID.uuidString, kind: .released) {
                return LinuxAuthorityCompleteInfo(leaseID: leaseID.uuidString, state: "released", leaseHandedBack: false)
            }
            throw Self.leaseLookupFailure(leaseID)
        }
        guard let bound = entry.processIdentity else {
            throw LinuxAuthorityError(code: .leaseNotStarted,
                                      message: "no process identity was ever bound for this lease; use abandon for a not-started holder")
        }
        guard bound == request.processIdentity else {
            throw LinuxAuthorityError(code: .processIdentityMismatch,
                                      message: "completion requires the exact process identity bound by markStarted")
        }
        guard request.quiescence.reaped,
              request.quiescence.exitStatus >= 0, request.quiescence.exitStatus <= 65_535 else {
            throw LinuxAuthorityError(code: .quiescenceNotAcknowledged,
                                      message: "the runtime service must attest a reaped waitpid-style exit status (0–65535)")
        }
        if !entry.quiescenceAcknowledged {
            await entry.holder.markProcessQuiesced()
            entry.quiescenceAcknowledged = true
            leases[leaseID.uuidString] = entry
        }
        do {
            let handedBack = try await entry.holder.release()
            leases.removeValue(forKey: leaseID.uuidString)
            recordTerminal(leaseID.uuidString, kind: .released)
            return LinuxAuthorityCompleteInfo(leaseID: leaseID.uuidString, state: "released", leaseHandedBack: handedBack)
        } catch {
            // Recoverable: the attestation stays recorded, the holder stays
            // retained, and a retry of complete() re-runs only the hand-back.
            throw LinuxAuthorityError(code: .releaseIncomplete,
                                      message: "the underlying lease hand-back failed; the holder is retained for retry: \(LinuxAuthorityWire.boundedMessage(error.localizedDescription))")
        }
    }

    /// The ONLY finish path for a NEVER-STARTED holder: an acquire whose
    /// materialization/launch failed before (or without) `markStarted`.
    /// Strictly refuses once any process identity was bound — a started
    /// process can only finish via `complete`.
    public func abandon(_ request: LinuxAuthorityLeaseRequest) async throws -> LinuxAuthorityAbandonInfo {
        guard configuration != nil else { throw LinuxAuthorityError(code: .notConfigured, message: "configure the authority with trusted roots first") }
        let leaseID = try Self.canonicalUUID(request.leaseID, field: "leaseID")
        guard var entry = leases[leaseID.uuidString] else {
            if terminalLedgerContains(leaseID.uuidString, kind: .abandoned) {
                return LinuxAuthorityAbandonInfo(leaseID: leaseID.uuidString, state: "abandoned", released: false)
            }
            throw Self.leaseLookupFailure(leaseID)
        }
        guard entry.processIdentity == nil else {
            throw LinuxAuthorityError(code: .abandonRefusedAfterStart,
                                      message: "a process identity was bound; cancel then complete with the exact identity and quiescence attestation instead")
        }
        if !entry.quiescenceAcknowledged {
            // No process was ever authorized to launch under this holder, so
            // "quiesced" here means "nothing to wait for" — the distinct
            // never-started path Main asked to keep separate from completion.
            await entry.holder.markProcessQuiesced()
            entry.quiescenceAcknowledged = true
            leases[leaseID.uuidString] = entry
        }
        do {
            let released = try await entry.holder.release()
            leases.removeValue(forKey: leaseID.uuidString)
            recordTerminal(leaseID.uuidString, kind: .abandoned)
            return LinuxAuthorityAbandonInfo(leaseID: leaseID.uuidString, state: "abandoned", released: released)
        } catch {
            throw LinuxAuthorityError(code: .releaseIncomplete,
                                      message: "abandon hand-back failed; the holder is retained: \(LinuxAuthorityWire.boundedMessage(error.localizedDescription))")
        }
    }

    /// Cleanup for the acquire-path internal validation failure (nothing was
    /// ever launched under the holder).
    private static func retireUnstartedHolder(_ holder: LinuxExecutionLeaseHolder) async {
        await holder.markProcessQuiesced()
        _ = try? await holder.release()
    }

    // MARK: - Wire exchange

    /// Bounded Codable exchange entry. Never throws: every failure (wire
    /// shape, version, semantics, authority rejection, internal) is a typed
    /// version-1 reply, capped at 65536 UTF-8 bytes.
    public func exchange(_ request: Data) async -> Data {
        var requestID: String?
        do {
            let envelope: LinuxAuthorityRequest
            do {
                envelope = try LinuxAuthorityWire.decodeRequest(request)
            } catch let wireError as LinuxAuthorityWireError {
                let code: LinuxAuthorityErrorCode = wireError == .oversizedRequest ? .requestTooLarge : .invalidWire
                throw LinuxAuthorityError(code: code, message: wireError.description)
            } catch {
                throw LinuxAuthorityError(code: .invalidWire, message: "the request is not a well-formed version-1 envelope")
            }
            requestID = try Self.validatedRequestID(envelope.requestID)
            guard envelope.version == LinuxAuthorityWire.version else {
                throw LinuxAuthorityError(code: .unsupportedVersion,
                                          message: "wire version \(envelope.version) is not supported; this authority speaks version \(LinuxAuthorityWire.version)")
            }
            let result = try await dispatch(envelope.operation)
            return LinuxAuthorityWire.encodeReply(LinuxAuthorityReply(version: LinuxAuthorityWire.version, requestID: requestID, outcome: .ok(result)))
        } catch let error as LinuxAuthorityError {
            return LinuxAuthorityWire.failureData(code: error.code, message: error.message, requestID: requestID)
        } catch {
            return LinuxAuthorityWire.failureData(code: .internalError, message: LinuxAuthorityWire.boundedMessage(String(describing: error)), requestID: requestID)
        }
    }

    private func dispatch(_ operation: LinuxAuthorityOperation) async throws -> LinuxAuthorityResult {
        switch operation {
        case .handshake:
            return .handshake(handshake())
        case .configure(let request):
            return .configure(try await configure(request))
        case .list:
            return .list(try await list())
        case .acquire(let request):
            return .acquire(try await acquire(request))
        case .markStarted(let request):
            return .markStarted(try markStarted(request))
        case .cancel(let request):
            return .cancel(try cancel(request))
        case .complete(let request):
            return .complete(try await complete(request))
        case .abandon(let request):
            return .abandon(try await abandon(request))
        }
    }

    // MARK: - Validation helpers

    private static func validatedRequestID(_ raw: String?) throws -> String? {
        guard let raw else { return nil }
        guard !raw.isEmpty, raw.utf8.count <= LinuxAuthorityWire.maximumRequestIDBytes,
              !raw.unicodeScalars.contains(where: { $0 == "\u{0}" || CharacterSet.controlCharacters.contains($0) }) else {
            throw LinuxAuthorityError(code: .invalidWire, message: "requestID must be a non-empty string of at most 64 bytes without control characters")
        }
        return raw
    }

    /// Strict canonical UUID addressing: the ORIGINAL runtime identities are
    /// 8-4-4-4-12 hex. Accepted case-insensitively, echoed in Foundation's
    /// canonical (upper-case) form — the workspace directory name uses that
    /// canonical form, so it cannot carry caller-chosen path spelling.
    static func canonicalUUID(_ raw: String, field: String) throws -> UUID {
        let pieces = raw.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        let isStandardForm = pieces.count == 5
            && zip(pieces, [8, 4, 4, 4, 12]).allSatisfy { piece, width in piece.count == width && piece.allSatisfy { $0.isHexDigit } }
        guard isStandardForm, let uuid = UUID(uuidString: raw) else {
            throw LinuxAuthorityError(code: .invalidUUID, message: "\(field) must be a canonical 8-4-4-4-12 UUID")
        }
        return uuid
    }

    static func isValidEnvironmentID(_ raw: String) -> Bool {
        guard !raw.isEmpty, raw.utf8.count <= LinuxAuthorityWire.maximumIdentifierBytes, !raw.contains("..") else { return false }
        return raw.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || $0 == "-" || $0 == "_" || $0 == "." }
    }

    private func validateProcessIdentityShape(_ identity: LinuxAuthorityProcessIdentity) throws {
        // Linux kernel pid ceilings (default 4194304; never below 1).
        guard identity.pid > 0, identity.pid <= 4_194_304 else {
            throw LinuxAuthorityError(code: .invalidProcessIdentity, message: "pid must be within 1–4194304")
        }
        if let pgid = identity.pgid {
            guard pgid > 0, pgid <= 4_194_304 else {
                throw LinuxAuthorityError(code: .invalidProcessIdentity, message: "pgid must be within 1–4194304")
            }
        }
        guard !identity.launcherToken.isEmpty,
              identity.launcherToken.utf8.count <= LinuxAuthorityWire.maximumIdentifierBytes,
              !identity.launcherToken.contains(where: { $0.isWhitespace || $0.isNewline }),
              identity.launcherToken.unicodeScalars.allSatisfy({ !$0.properties.isNoncharacterCodePoint && !CharacterSet.controlCharacters.contains($0) && $0 != "\u{0}" }) else {
            throw LinuxAuthorityError(code: .invalidProcessIdentity, message: "launcherToken must be a 1–64 byte printable, whitespace-free string")
        }
        if let startedAt = identity.startedAtUnixMillis {
            guard startedAt >= 0 else {
                throw LinuxAuthorityError(code: .invalidProcessIdentity, message: "startedAtUnixMillis must not be negative")
            }
        }
    }

    private static func leaseLookupFailure(_ leaseID: UUID) -> LinuxAuthorityError {
        LinuxAuthorityError(code: .leaseNotFound, message: "no retained runtime lease is addressed by \(leaseID.uuidString)")
    }

    private func terminalLedgerContains(_ leaseID: String, kind: TerminalKind) -> Bool {
        terminalLedger.contains { $0.leaseID == leaseID && $0.kind == kind }
    }

    private func recordTerminal(_ leaseID: String, kind: TerminalKind) {
        terminalLedger.removeAll { $0.leaseID == leaseID }
        terminalLedger.append((leaseID, kind))
        if terminalLedger.count > LinuxAuthorityWire.maximumTerminalLedger {
            terminalLedger.removeFirst(terminalLedger.count - LinuxAuthorityWire.maximumTerminalLedger)
        }
    }

    // MARK: - Authority error mapping

    /// Maps typed rejections from the ORIGINAL resolver/registry/coordinator
    /// onto stable wire codes. Messages carry the original reason strings
    /// (identifiers/hashes only) bounded to 512 bytes.
    static func mapAuthorityError(_ error: Error) -> LinuxAuthorityError {
        if let authorityError = error as? LinuxAuthorityError { return authorityError }
        if let resolverError = error as? LinuxExecutionLeaseResolverError {
            switch resolverError {
            case .backendNotSelectableOnAndroid:
                return LinuxAuthorityError(code: .backendNotSelectable, message: resolverError.description)
            case .sessionRequiresOwningConversation:
                return LinuxAuthorityError(code: .sessionRequiresConversation, message: resolverError.description)
            case .foreignConversation:
                return LinuxAuthorityError(code: .foreignConversation, message: resolverError.description)
            case .noResolvedEnvironment:
                return LinuxAuthorityError(code: .noResolvedEnvironment, message: resolverError.description)
            case .recordBackendMismatch:
                return LinuxAuthorityError(code: .recordBackendMismatch, message: resolverError.description)
            }
        }
        if let floeError = error as? FloeError {
            switch floeError {
            case .notFound(let detail):
                return LinuxAuthorityError(code: .environmentNotFound, message: LinuxAuthorityWire.boundedMessage(detail))
            case .cancelled:
                return LinuxAuthorityError(code: .cancelled, message: "the acquisition cancellation token was already cancelled")
            case .validationFailed, .storageCorrupted, .invalidConfiguration,
                 .syncUnavailable, .internalError, .unauthorized:
                return LinuxAuthorityError(code: .authorityRejected, message: LinuxAuthorityWire.boundedMessage(floeError.reason))
            @unknown default:
                return LinuxAuthorityError(code: .internalError, message: LinuxAuthorityWire.boundedMessage(floeError.reason))
            }
        }
        return LinuxAuthorityError(code: .internalError, message: LinuxAuthorityWire.boundedMessage(String(describing: error)))
    }
}
