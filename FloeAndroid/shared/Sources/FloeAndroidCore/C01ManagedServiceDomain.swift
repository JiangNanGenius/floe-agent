// SPDX-License-Identifier: MPL-2.0
//
// C01ManagedServiceDomain — service-owned long-running Linux workloads.
//
// One managed service is:
//   * a DURABLE `exec.shell` job submitted through the ORIGINAL
//     `jobs.submit`/`BackgroundJobService` (same provenance, store, cancellation
//     and launch reconciliation), with a typed `service` declaration;
//   * an engine session opened under the trusted `.service` role, which is
//     SEPARATE from the two interactive terminal slots and the one shared
//     Agent/run execution slot. Ordinary `exec.shell` keeps working while a
//     service is alive;
//   * bound to the exact accepted Root epoch, task/conversation, environment,
//     workspace identity and job/run owner. There is no first-project,
//     temp-root or host-process fallback;
//   * READY only after the runtime proves that the declared loopback port is a
//     LISTEN socket owned by this session's process tree. A connect-only probe
//     or a log line is not readiness;
//   * service-owned across view/turn closure. Only an explicit job cancel,
//     Root/environment drain, engine terminal or app process death ends it.
//     Process death never auto-restarts or replays it.
//
// The engine component contract is versioned. The current Alpha22 engine
// advertises `floe-multi-workload-v2` (2 interactive + 1 exec) and therefore
// keeps ordinary exec compatible but answers `serviceComponentUnavailable` for
// managed services. The v3 helper adds the two service roles and the
// `service.readiness` operation. No readiness flag is set without that live
// proof.
//
// MCP stdio is intentionally not claimed here: it needs three separate pipes
// (stdin, stdout, stderr) and no PTY. The current helper has no such transport;
// the typed `startStdioService` entry below fails closed with the exact missing
// capability instead of pretending a PTY session is a stdio channel.
import Foundation
import FloeCore
import FloeTools
import FloeAndroidShellTools
import FloeAndroidJobTools
import FloeBrowser
import FloeWorkspace

// MARK: - Public snapshot

public struct C01ManagedServiceSnapshot: Sendable, Equatable {
    public enum State: String, Sendable, Equatable {
        case starting
        case running
        case ready
        case stopping
        case stopped
        case failed
        case interruptedUnknown
    }

    public var jobID: UUID
    public var conversationID: UUID
    public var epoch: UInt64
    public var environmentID: String?
    public var runtime: String
    public var entry: String
    public var port: Int
    public var state: State
    /// Set ONLY after the runtime's owned-listener proof.
    public var previewURL: String?
    /// Bounded merged PTY tail (the engine exposes one PTY stream).
    public var outputTail: String
    public var startedAt: Date
    public var detail: String

    public init(jobID: UUID, conversationID: UUID, epoch: UInt64,
                environmentID: String?, runtime: String, entry: String,
                port: Int, state: State, previewURL: String?,
                outputTail: String, startedAt: Date, detail: String) {
        self.jobID = jobID
        self.conversationID = conversationID
        self.epoch = epoch
        self.environmentID = environmentID
        self.runtime = runtime
        self.entry = entry
        self.port = port
        self.state = state
        self.previewURL = previewURL
        self.outputTail = outputTail
        self.startedAt = startedAt
        self.detail = detail
    }
}

// MARK: - Service domain

public final class C01ManagedServiceDomain: C01ManagedServiceJobHosting, @unchecked Sendable {
    public static let shared = C01ManagedServiceDomain()

    /// Engine contract that adds the two service roles and owned readiness.
    public static let requiredContractVersion = "floe-multi-workload-v3"
    public static let stdioContractVersion = "floe-service-stdio-v1"

    private struct Record {
        var snapshot: C01ManagedServiceSnapshot
        var sessionID: String
        var previewOriginAuthorized: Bool
        var stopRequested: Bool
    }

    private let lock = NSLock()
    private var records: [UUID: Record] = [:]
    /// Installed by `RuntimeFacadeJobBindings.register()`: resolves the
    /// durable `service` dependency edge on the FIRST proven readiness so a
    /// waiting parent run continues without waiting for the service to stop.
    private var readyReporter: (@Sendable (UUID, String) async -> Void)?
    private static let portLock = NSLock()
    private nonisolated(unsafe) static var reservedPorts: Set<Int> = []

    private init() {}

    /// Trusted composition entry. Nil removes the reporter; a service still
    /// runs but a waiting parent run stays outstanding until terminal.
    public func installReadyReporter(
        _ reporter: (@Sendable (UUID, String) async -> Void)?
    ) {
        lock.lock(); defer { lock.unlock() }
        readyReporter = reporter
    }

    // MARK: Job payload API (called by the job module)

    public func makeExecShellPayload(
        innerArguments: Data,
        declaration: C01ManagedServiceDeclaration
    ) throws -> Data {
        guard !declaration.isStatic else {
            throw FloeError.validationFailed(
                "Static HTML preview uses the existing preview.start path; a managed service needs a real listener")
        }
        let epoch = RuntimeFacadeLinuxBindings.shared.boundNativeEpoch
        guard epoch > 0 else {
            throw FloeError.validationFailed(
                "The Linux generation is not bound; a managed service cannot be submitted")
        }
        return try C01ManagedServicePayload.combine(
            innerArguments: innerArguments, declaration: declaration, acceptedEpoch: epoch)
    }

    public func validateJobPayload(_ payload: Data, workspaceRootURL: URL?) async throws {
        guard let declaration = try C01ManagedServicePayload.decode(payload) else {
            return // ordinary exec.shell job
        }
        guard !declaration.isStatic else {
            throw FloeError.validationFailed(
                "Static HTML preview uses preview.start, not a managed service")
        }
        let epoch = RuntimeFacadeLinuxBindings.shared.boundNativeEpoch
        guard epoch > 0, declaration.acceptedEpoch == epoch,
              RuntimeFacadeLinuxBindings.shared.isCapabilityQualified else {
            throw FloeError.validationFailed(
                "The Linux engine is not qualified in the submitted native generation; complete runtime setup and retry")
        }
        let cap = await capability()
        guard cap.available else {
            throw FloeError.validationFailed(
                "Managed services are unavailable in this build: \(cap.detail). Ordinary exec.shell remains available.")
        }
        guard let rootURL = workspaceRootURL else {
            throw FloeError.validationFailed(
                "A managed service requires the task's resolved workspace root")
        }
        let resolver = WorkspacePathGuard(rootURL: rootURL)
        let entryURL = try resolver.resolve(declaration.entry)
        let cwdURL = try resolver.resolve(declaration.cwd ?? ".")
        var entryIsDirectory: ObjCBool = false
        var cwdIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: entryURL.path,
                                             isDirectory: &entryIsDirectory),
              !entryIsDirectory.boolValue,
              FileManager.default.fileExists(atPath: cwdURL.path,
                                             isDirectory: &cwdIsDirectory),
              cwdIsDirectory.boolValue else {
            throw FloeError.validationFailed(
                "The service entry must be an existing workspace file and cwd an existing workspace directory")
        }
    }

    // MARK: Processor (called only by the job-scoped ExecShellJobRunner)

    public func runServiceJob(payloadJSON: Data, context: ToolContext) async throws -> ToolExecutionOutput {
        guard let declaration = try C01ManagedServicePayload.decode(payloadJSON) else {
            throw FloeError.validationFailed("This job is not a managed-service payload")
        }
        guard let jobID = JobProcessorIdentity.jobID(fromToolCallID: context.toolCallID),
              let conversationID = context.conversationID,
              let rootURL = context.workspaceRootURL?.standardizedFileURL,
              let port = declaration.port else {
            throw FloeError.validationFailed(
                "A managed service requires a durable job context with an owning task, workspace and declared port")
        }
        let epoch = RuntimeFacadeLinuxBindings.shared.boundNativeEpoch
        guard epoch > 0, declaration.acceptedEpoch == epoch else {
            throw FloeError.validationFailed(
                "The service belongs to a different native generation; it was not started and will not be replayed")
        }
        guard G02NativeRootEpoch.readback() == epoch,
              RuntimeFacadeLinuxBindings.shared.isCapabilityQualified else {
            throw FloeError.validationFailed("The Linux engine is not qualified; the service was not started")
        }
        let cap = await capability()
        guard cap.available else {
            throw FloeError.validationFailed("Managed services are unavailable: \(cap.detail)")
        }
        // Exact workspace ownership; never the model's path or a first project.
        guard let binding = await LinuxWorkspaceAuthority.resolveWorkspace(
            conversationID: conversationID),
              binding.rootURL.standardizedFileURL.path == rootURL.path else {
            throw FloeError.validationFailed(
                "This task's workspace binding does not match the service's frozen execution root")
        }
        guard let components = RuntimeFacadeLinuxBindings.shared.components else {
            throw FloeError.validationFailed("Linux shell components are not composed")
        }
        let cwd = declaration.cwd ?? "."
        _ = try ShellInputValidation.directory(cwd: cwd, root: rootURL)
        // Confine both the entry and cwd through the ORIGINAL workspace guard:
        // a `..`/absolute/symlink escape is refused before a process exists.
        let resolver = WorkspacePathGuard(rootURL: rootURL)
        let entryURL = try resolver.resolve(declaration.entry)
        let cwdURL = try resolver.resolve(cwd)
        var entryIsDirectory: ObjCBool = false
        var cwdIsDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: entryURL.path,
                                             isDirectory: &entryIsDirectory),
              !entryIsDirectory.boolValue,
              FileManager.default.fileExists(atPath: cwdURL.path, isDirectory: &cwdIsDirectory),
              cwdIsDirectory.boolValue else {
            throw FloeError.validationFailed(
                "The service entry must be an existing workspace file and cwd an existing workspace directory")
        }
        guard await components.backend.hasCapacity(for: .service) else {
            throw FloeError.validationFailed(
                "Both managed-service slots are occupied; stop a service before starting another")
        }
        guard Self.reservePort(port) else {
            throw FloeError.validationFailed("Another managed service in this process owns port \(port)")
        }
        var reserved = true
        defer { if reserved { Self.releasePort(port) } }
        if await portProbeInUse(port: port, epoch: epoch) {
            throw FloeError.validationFailed(
                "The requested port \(port) is already answering on loopback; choose another port")
        }

        let sessionID = UUID().uuidString.lowercased()
        let command = Self.command(declaration)
        let request = ShellOpenRequest(
            command: command,
            cwd: cwd,
            rootURL: rootURL,
            environment: ["PORT": String(port)],
            columns: 120,
            rows: 40,
            gateTimeout: 5,
            sessionID: sessionID,
            runID: context.runID,
            toolEnvironment: context.environment,
            conversationID: conversationID,
            hostToolCallID: context.toolCallID,
            environmentID: context.environmentID,
            prepareLinuxIfMissing: false,
            leaseRole: .service)
        let startedAt = Date()
        let initial = C01ManagedServiceSnapshot(
            jobID: jobID, conversationID: conversationID, epoch: epoch,
            environmentID: context.environmentID ?? context.environment?.id,
            runtime: declaration.runtime.rawValue, entry: declaration.entry,
            port: port, state: .starting, previewURL: nil, outputTail: "",
            startedAt: startedAt, detail: "starting the owned engine session")
        upsert(Record(snapshot: initial, sessionID: sessionID,
                      previewOriginAuthorized: false, stopRequested: false))
        await report(context, snapshot: initial)

        let opened: ShellOpenResult
        do {
            opened = try await components.backend.openSession(request, cancellation: context.cancellation)
        } catch {
            Self.releasePort(port); reserved = false
            // An uncertain start may have produced a claimed engine receipt;
            // request its owned stop but never claim it settled here.
            await components.backend.requestStopForSettlement(sessionID: sessionID)
            if let failed = withSnapshot(jobID: jobID, { snapshot in
                snapshot.state = .failed
                snapshot.detail = "the engine refused the service start"
            }) { await report(context, snapshot: failed) }
            throw error
        }
        guard opened.alive else {
            Self.releasePort(port); reserved = false
            await components.backend.closeSession(sessionID: sessionID)
            if let stopped = withSnapshot(jobID: jobID, { snapshot in
                snapshot.state = .failed
                snapshot.detail = "the service process exited immediately"
            }) { await report(context, snapshot: stopped) }
            return ToolExecutionOutput(
                digesting: "status=failed serviceJob=\(jobID.uuidString) port=\(port)\nThe managed service exited before becoming ready.",
                exitStatus: 1)
        }

        let engineSessionID = opened.runtimeSessionID ?? ""
        var output = opened.initialOutput
        var lastPreview: String?
        var becameReady = false
        var readinessAttempts = 0
        var stopSent = false
        var stopDeadline: UInt64?
        let outputCap = 16 * 1024
        do {
            while true {
                let drainRequested = isStopRequested(jobID: jobID)
                if context.cancellation.isCancelled || drainRequested {
                    if !stopSent {
                        stopSent = true
                        stopDeadline = DispatchTime.now().uptimeNanoseconds &+ 90 * 1_000_000_000
                        markStopping(jobID: jobID)
                        await components.backend.requestStopForSettlement(sessionID: sessionID)
                        if let snapshot = withSnapshot(jobID: jobID, { _ in }) {
                            await report(context, snapshot: snapshot)
                        }
                    }
                }
                let result: ShellExchangeResult
                do {
                    result = try await components.backend.exchangeSession(
                        ShellExchangeRequest(sessionID: sessionID, input: nil,
                                             waitMs: 1_000, maxBytes: 16_384),
                        cancellation: stopSent ? nil : context.cancellation)
                } catch is CancellationError {
                    // Cancellation is a request; keep observing the owned
                    // session until the engine proves release.
                    if stopSent, let deadline = stopDeadline,
                       DispatchTime.now().uptimeNanoseconds > deadline {
                        throw NativeJobSafetyFailure(
                            reason: "managed service stop was not proven within the bounded reconciliation window; the engine lease is retained")
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                } catch {
                    // A transport fault does not prove process death. Request
                    // the owned engine stop, keep the lease for the durable
                    // reconciliation/root drain, and let the job's launch
                    // reconciliation report UNKNOWN if the process is gone.
                    await components.backend.requestStopForSettlement(sessionID: sessionID)
                    throw error
                }
                if !result.output.isEmpty {
                    output = Self.boundedTail(output + result.output, cap: outputCap)
                    updateTail(jobID: jobID, output: output)
                    if let snapshot = withSnapshot(jobID: jobID, { _ in }) {
                        await report(context, snapshot: snapshot)
                    }
                }
                if !result.alive {
                    Self.releasePort(port); reserved = false
                    await components.backend.closeSession(sessionID: sessionID)
                    revokePreview(jobID: jobID)
                    let neverReady = !becameReady && !stopSent
                    if let terminal = withSnapshot(jobID: jobID, { snapshot in
                        snapshot.state = neverReady ? .failed : .stopped
                        snapshot.previewURL = nil
                        snapshot.detail = neverReady
                            ? "the service process ended before a ready owned listener was proven"
                            : Self.terminalDetail(result, stopRequested: stopSent)
                    }) { await report(context, snapshot: terminal) }
                    let exit = neverReady
                        ? (result.exitCode == 0 ? 1 : (result.exitCode ?? 1))
                        : (result.exitCode ?? (stopSent || result.cancelled ? 130 : 0))
                    let status = neverReady ? "failed" : (stopSent || result.cancelled ? "stopped" : "exited")
                    let clean = SecretRedactor.redact(ShellOutputSanitizer.sanitize(output))
                    var text = "status=\(status) serviceJob=\(jobID.uuidString) port=\(port) exit=\(exit)\n"
                    text += "--- bounded service output (merged PTY, sanitized) ---\n\(clean)"
                    return ToolExecutionOutput(digesting: text, exitStatus: exit)
                }
                // Readiness is checked at a slower cadence than the output
                // poll: it is a proof query, not a log read.
                readinessAttempts += 1
                if readinessAttempts % 2 == 0, !stopSent {
                    let readiness = await ownedReadiness(sessionID: engineSessionID,
                                                        port: port, epoch: epoch)
                    switch readiness {
                    case .ready:
                        let url = "http://127.0.0.1:\(port)/"
                        if lastPreview != url {
                            lastPreview = url
                            let authorized = authorizePreview(jobID: jobID, conversationID: conversationID,
                                                              epoch: epoch, url: url)
                            let firstReady = !becameReady
                            becameReady = true
                            if firstReady {
                                let reporter = readyReporterSnapshot()
                                await reporter?(jobID, "The managed service is ready at \(url); it keeps running after this reply.")
                            }
                            if let ready = withSnapshot(jobID: jobID, { snapshot in
                                snapshot.state = .ready
                                snapshot.previewURL = authorized ? url : nil
                                snapshot.detail = authorized
                                    ? "owned loopback listener proven ready"
                                    : "service ready; the browser preview generation is unavailable"
                            }) { await report(context, snapshot: ready) }
                        }
                    case .starting:
                        if lastPreview != nil {
                            lastPreview = nil
                            revokePreview(jobID: jobID)
                        }
                        if let starting = withSnapshot(jobID: jobID, { snapshot in
                            snapshot.state = .running
                            snapshot.previewURL = nil
                            snapshot.detail = "process is running; the owned listener is not proven yet"
                        }) { await report(context, snapshot: starting) }
                    case .unknown(let detail):
                        if lastPreview != nil {
                            lastPreview = nil
                            revokePreview(jobID: jobID)
                        }
                        if let unknown = withSnapshot(jobID: jobID, { snapshot in
                            snapshot.state = .running
                            snapshot.previewURL = nil
                            snapshot.detail = "readiness unverified: \(detail)"
                        }) { await report(context, snapshot: unknown) }
                    }
                }
                if stopSent, let deadline = stopDeadline,
                   DispatchTime.now().uptimeNanoseconds > deadline {
                    throw NativeJobSafetyFailure(
                        reason: "managed service stop was not proven within the bounded reconciliation window; the engine lease is retained")
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        } catch {
            // Keep the port reservation? No: the engine lease may still own
            // the port, although the job is failing. Release only our local
            // reservation; the port cannot be safely reused until the engine
            // session is proven gone, so the probe will refuse it next time.
            if reserved { Self.releasePort(port); reserved = false }
            revokePreview(jobID: jobID)
            if let failed = withSnapshot(jobID: jobID, { snapshot in
                snapshot.state = .failed
                snapshot.previewURL = nil
                snapshot.detail = "service processor ended without a clean terminal"
            }) { await report(context, snapshot: failed) }
            throw error
        }
    }

    // MARK: Stdio (deliberately gated)

    /// MCP stdio needs three distinct pipes and no PTY. The released helper
    /// does not provide that transport, so this entry refuses with the exact
    /// component capability instead of returning a PTY session.
    public func startStdioService(
        jobID: UUID,
        context: ToolContext
    ) async throws -> Never {
        let capability = await rawCapability()
        throw FloeError.invalidConfiguration(
            "Managed stdio services require runtime capability \(Self.stdioContractVersion); this helper advertises \(capability.contractVersion.isEmpty ? "none" : capability.contractVersion). No PTY fallback is used.")
    }

    // MARK: Snapshot / UI read

    public func snapshot(jobID: UUID) -> C01ManagedServiceSnapshot? {
        lock.lock(); defer { lock.unlock() }
        return records[jobID]?.snapshot
    }

    public func snapshots(conversationID: UUID) -> [C01ManagedServiceSnapshot] {
        lock.lock(); defer { lock.unlock() }
        return records.values.map(\.snapshot)
            .filter { $0.conversationID == conversationID }
            .sorted { $0.startedAt < $1.startedAt }
    }

    /// Trusted entry for the App terminal/preview pane and Main's explicit
    /// "open preview" action. It navigates ONLY this task's own browser
    /// session to the already-authorized owned service origin; it never
    /// accepts a model URL/path and never starts a service. Returns false on
    /// an unready/stale/foreign service or a browser refusal.
    @discardableResult
    public func openPreview(jobID: UUID,
                            cancellation: CancellationToken? = nil) async -> Bool {
        guard let current = snapshot(jobID: jobID),
              let preview = current.previewURL,
              let url = URL(string: preview) else { return false }
        return await G04ManagedServicePreview.open(
            epoch: current.epoch, conversationID: current.conversationID,
            owner: jobID, url: url, cancellation: cancellation)
    }

    /// Trusted Root/environment drain entry: request the engine's owned stop
    /// for every live service record. It does NOT end the records or release
    /// ports; each processor observes the real `leaseReleased` and settles
    /// its own port/preview. A job-drain cancellation normally reaches the
    /// same stop path first; this is the independent owner-cleanup entry.
    public func requestStopAll(epoch: UInt64? = nil) async {
        let live = allRecords()
        for record in live {
            if let epoch, record.snapshot.epoch != epoch { continue }
            guard record.snapshot.state != .stopped,
                  record.snapshot.state != .failed else { continue }
            let alreadyRequested = withRecord(jobID: record.snapshot.jobID) { value in
                let previous = value.stopRequested
                value.stopRequested = true
                return previous
            }
            guard !alreadyRequested else { continue }
            markStopping(jobID: record.snapshot.jobID)
            guard let components = RuntimeFacadeLinuxBindings.shared.components else { continue }
            await components.backend.requestStopForSettlement(sessionID: record.sessionID)
        }
    }

    /// Small locked record mutation used by the idempotent drain path.
    private func withRecord(jobID: UUID, _ mutate: (inout Record) -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard var record = records[jobID] else { return true }
        let value = mutate(&record)
        records[jobID] = record
        return value
    }

    private func allRecords() -> [Record] {
        lock.lock(); defer { lock.unlock() }
        return Array(records.values)
    }

    /// True while ANY service record is not terminal. Used by the trusted
    /// root drain so an opening service cannot be missed by an empty backend
    /// snapshot. It is a RAM view, not a readiness claim.
    public var hasLiveServices: Bool {
        lock.lock(); defer { lock.unlock() }
        return records.values.contains {
            $0.snapshot.state != .stopped && $0.snapshot.state != .failed
        }
    }

    public func hasLiveService(jobID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let state = records[jobID]?.snapshot.state else { return false }
        return state != .stopped && state != .failed
    }

    // MARK: Capability / readiness transport

    private struct Capability {
        var available: Bool
        var contractVersion: String
        var detail: String
    }

    private enum Readiness {
        case ready
        case starting
        case unknown(String)
    }

    private func capability() async -> Capability {
        let raw = await rawCapability()
        if raw.contractVersion == Self.requiredContractVersion {
            return Capability(available: true, contractVersion: raw.contractVersion,
                              detail: "service roles and owned readiness advertised")
        }
        return Capability(
            available: false, contractVersion: raw.contractVersion,
            detail: raw.contractVersion.isEmpty
                ? "the runtime component did not advertise a workload contract"
                : "the runtime advertises \(raw.contractVersion); \(Self.requiredContractVersion) is required")
    }

    private func rawCapability() async -> Capability {
        let epoch = RuntimeFacadeLinuxBindings.shared.boundNativeEpoch
        guard epoch > 0 else {
            return Capability(available: false, contractVersion: "", detail: "native generation is not bound")
        }
        guard let payload = try? JSONSerialization.data(
            withJSONObject: ["epoch": epoch], options: [.sortedKeys]) else {
            return Capability(available: false, contractVersion: "", detail: "capability query encoding failed")
        }
        do {
            let reply = try await LinuxShellMailbox.shared.submit(
                operation: "host.serviceCapability", payload: payload, timeoutMillis: 10_000)
            guard reply.count <= 8_192,
                  let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any],
                  let contract = object["contractVersion"] as? String else {
                return Capability(available: false, contractVersion: "", detail: "unreadable capability reply")
            }
            return Capability(available: object["serviceRoleAvailable"] as? Bool ?? false,
                              contractVersion: String(contract.prefix(64)),
                              detail: object["detail"] as? String ?? "")
        } catch {
            return Capability(available: false, contractVersion: "", detail: "runtime capability is unreachable")
        }
    }

    private func portProbeInUse(port: Int, epoch: UInt64) async -> Bool {
        guard let payload = try? JSONSerialization.data(
            withJSONObject: ["epoch": epoch, "port": port], options: [.sortedKeys]) else { return true }
        do {
            let reply = try await LinuxShellMailbox.shared.submit(
                operation: "host.servicePortProbe", payload: payload, timeoutMillis: 8_000)
            guard let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
                return true
            }
            return object["inUse"] as? Bool ?? true
        } catch {
            return true // fail closed: never claim a port from a failed probe
        }
    }

    private func ownedReadiness(sessionID: String, port: Int, epoch: UInt64) async -> Readiness {
        guard let payload = try? JSONSerialization.data(
            withJSONObject: ["epoch": epoch, "sessionID": sessionID, "port": port],
            options: [.sortedKeys]) else { return .unknown("request encoding failed") }
        do {
            let reply = try await LinuxShellMailbox.shared.submit(
                operation: "host.serviceReadiness", payload: payload, timeoutMillis: 8_000)
            guard let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any],
                  let state = object["state"] as? String else {
                return .unknown("unreadable readiness reply")
            }
            if state == "ready", (object["port"] as? Int) == port,
               object["owned"] as? Bool == true {
                return .ready
            }
            if state == "starting" { return .starting }
            return .unknown((object["detail"] as? String) ?? state)
        } catch {
            return .unknown("readiness query unavailable")
        }
    }

    // MARK: Preview

    private func authorizePreview(jobID: UUID, conversationID: UUID,
                                  epoch: UInt64, url: String) -> Bool {
        guard let parsed = URL(string: url),
              G04ManagedServicePreview.authorize(epoch: epoch, owner: jobID,
                                                 conversationID: conversationID,
                                                 url: parsed) else { return false }
        lock.lock()
        if var record = records[jobID] {
            record.previewOriginAuthorized = true
            records[jobID] = record
        }
        lock.unlock()
        return true
    }

    private func revokePreview(jobID: UUID) {
        lock.lock()
        let authorized = records[jobID]?.previewOriginAuthorized == true
        if var record = records[jobID] {
            record.previewOriginAuthorized = false
            records[jobID] = record
        }
        let epoch = records[jobID]?.snapshot.epoch
        lock.unlock()
        guard authorized, let epoch else { return }
        G04ManagedServicePreview.revoke(epoch: epoch, owner: jobID)
    }

    // MARK: Record helpers

    private func upsert(_ record: Record) {
        lock.lock(); defer { lock.unlock() }
        records[record.snapshot.jobID] = record
        if records.count > 128 {
            let terminal = records.values
                .filter { $0.snapshot.state == .stopped || $0.snapshot.state == .failed }
                .sorted { $0.snapshot.startedAt < $1.snapshot.startedAt }
            for old in terminal.prefix(max(0, records.count - 96)) {
                records.removeValue(forKey: old.snapshot.jobID)
            }
        }
    }

    private func withSnapshot(_ jobID: UUID,
                              _ mutate: (inout C01ManagedServiceSnapshot) -> Void)
        -> C01ManagedServiceSnapshot? {
        lock.lock(); defer { lock.unlock() }
        guard var record = records[jobID] else { return nil }
        mutate(&record.snapshot)
        records[jobID] = record
        return record.snapshot
    }

    private func readyReporterSnapshot() -> (@Sendable (UUID, String) async -> Void)? {
        lock.lock(); defer { lock.unlock() }
        return readyReporter
    }

    private func isStopRequested(jobID: UUID) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return records[jobID]?.stopRequested == true
    }

    private func markStopping(jobID: UUID) {
        lock.lock()
        if var record = records[jobID] {
            record.stopRequested = true
            record.snapshot.state = .stopping
            record.snapshot.previewURL = nil
            record.snapshot.detail = "stop requested; waiting for the engine's real release"
            records[jobID] = record
        }
        lock.unlock()
    }

    private func updateTail(jobID: UUID, output: String) {
        lock.lock()
        if var record = records[jobID] {
            record.snapshot.outputTail = output
            records[jobID] = record
        }
        lock.unlock()
    }

    private func report(_ context: ToolContext, snapshot: C01ManagedServiceSnapshot) async {
        var note = "service state=\(snapshot.state.rawValue) job=\(snapshot.jobID.uuidString) port=\(snapshot.port)"
        if let preview = snapshot.previewURL, !preview.isEmpty {
            note += " previewURL=\(preview)"
        }
        if !snapshot.detail.isEmpty {
            note += " detail=\(String(snapshot.detail.prefix(160)))"
        }
        await context.taskProgress?.report(TaskProgressUpdate(
            stage: snapshot.state == .stopping ? "cancelling" : "running",
            phase: "managedService",
            note: String(note.prefix(240))))
    }

    // MARK: Pure helpers

    private static func terminalDetail(_ result: ShellExchangeResult,
                                       stopRequested: Bool) -> String {
        if stopRequested || result.cancelled {
            return "engine proved the stop and released the service lease"
        }
        if let code = result.exitCode {
            return "engine proved process exit code \(code)"
        }
        return "engine proved the service terminal"
    }

    static func boundedTail(_ value: String, cap: Int) -> String {
        guard value.utf8.count > cap else { return value }
        var data = Data(value.utf8.suffix(cap))
        while let first = data.first, (first & 0xC0) == 0x80 { data.removeFirst() }
        return String(decoding: data, as: UTF8.self)
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func command(_ declaration: C01ManagedServiceDeclaration) -> String {
        let executable: String
        switch declaration.runtime {
        case .shell: executable = "sh"
        case .node: executable = "node"
        case .python: executable = "python3"
        case .static: executable = "sh"
        }
        var parts = [executable, shellQuote(declaration.entry)]
        parts.append(contentsOf: (declaration.arguments ?? []).map(shellQuote))
        return parts.joined(separator: " ")
    }

    private static func reservePort(_ port: Int) -> Bool {
        portLock.lock(); defer { portLock.unlock() }
        return reservedPorts.insert(port).inserted
    }

    private static func releasePort(_ port: Int) {
        portLock.lock(); defer { portLock.unlock() }
        reservedPorts.remove(port)
    }
}
