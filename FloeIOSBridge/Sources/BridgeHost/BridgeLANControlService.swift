import Foundation
import BridgeCore

// MARK: - Key storage

/// The control credential is a separate Keychain item. It is never derived
/// from, copied to, or returned with the legacy install/read-only token.
enum BridgeLANControlKeyStore {
    static let account = "lan-control-key"

    static func load() -> Data? {
        guard let encoded = try? BridgeInstallToken.load(account: account),
              let key = BridgeLANControlKey.decode(encoded) else {
            return nil
        }
        return key
    }

    static func save(_ key: Data) throws {
        try BridgeInstallToken.save(BridgeLANControlKey.encode(key), account: account)
    }

    static func delete() {
        BridgeInstallToken.delete(account: account)
    }
}

enum BridgeLANControlError: LocalizedError, Equatable {
    case missingKey
    case invalidKey
    case keyMatchesInstallToken

    var errorDescription: String? {
        switch self {
        case .missingKey:
            return BridgeL10n.t(
                "Complete remote control setup first.",
                "请先完成遥控设置。"
            )
        case .invalidKey:
            return BridgeL10n.t(
                "Remote control setup is invalid. Set it up again.",
                "遥控设置无效，请重新设置。"
            )
        case .keyMatchesInstallToken:
            return BridgeL10n.t(
                "Use separate credentials for remote control.",
                "请使用独立的遥控授权资料。"
            )
        }
    }
}

// MARK: - One-way shutdown relay

/// Small thread-safe handoff from the listener queue to the MainActor model.
final class BridgeLANShutdownRelay: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable (String) -> Void)?

    func setHandler(_ handler: (@Sendable (String) -> Void)?) {
        lock.lock()
        self.handler = handler
        lock.unlock()
    }

    func request(identifier: String) {
        lock.lock()
        let handler = self.handler
        lock.unlock()
        handler?(identifier)
    }
}

// MARK: - Command broker

/// Bridges the encrypted LAN request to the existing authenticated file lane.
/// It adds only a bounded replay/ownership ledger; the real host/engine
/// dispatchers and their PID/generation policy remain authoritative.
final class BridgeLANCommandBroker: @unchecked Sendable {
    private let lock = NSLock()
    private var ledger: BridgeLANCommandLedger
    private let limits: BridgeLANLimits
    private let tokenAccount: String

    init(limits: BridgeLANLimits = .default,
         tokenAccount: String = BridgeInstallToken.fileChannelAccount) {
        self.limits = limits
        self.tokenAccount = tokenAccount
        self.ledger = BridgeLANCommandLedger(
            maxRecords: limits.maxCommandRecords,
            commandTTL: limits.commandTTL
        )
    }

    func submit(_ request: BridgeLANControlRequest) -> BridgeLANSubmitOutcome {
        // Defense in depth: the server already decoded and validated, but the
        // broker is the only object that writes the real command file. No
        // SDK/file dispatch happens for an invalid or unexpected argument
        // shape, including a direct in-process call.
        if case .failure(let error) = BridgeControlArguments.validate(
            action: request.action,
            parameters: request.parameters
        ) {
            return .rejected(code: error.code, message: error.message)
        }
        lock.lock()
        defer { lock.unlock() }
        switch ledger.submit(request) {
        case .duplicate(let record):
            return .accepted(id: record.id, lane: record.lane, action: record.action,
                             generation: record.generation, duplicate: true)
        case .replayed:
            return .rejected(code: "command_replayed",
                             message: "This command ID was already used with different content.")
        case .busy:
            return .rejected(code: "command_busy",
                             message: "The bounded command ledger is full.")
        case .accepted(let record):
            guard let token = try? BridgeInstallToken.loadOrCreate(account: tokenAccount) else {
                ledger.cancelSubmission(id: record.id)
                return .rejected(code: "token_unavailable",
                                 message: "The local command token is unavailable.")
            }
            let envelope = BridgeCommandEnvelope(
                id: record.id,
                action: record.action,
                pid: record.pid,
                token: token,
                parameters: request.parameters,
                expectedGeneration: record.generation
            )
            guard let url = BridgeFileChannel.issue(envelope, lane: record.lane.commandLane),
                  ledger.markIssued(id: record.id, fileURL: url) else {
                ledger.cancelSubmission(id: record.id)
                return .rejected(code: "dispatch_unavailable",
                                 message: "The command could not be queued.")
            }
            return .accepted(id: record.id, lane: record.lane, action: record.action,
                             generation: record.generation, duplicate: false)
        }
    }

    /// The shutdown action is executed by the existing local coordinator, not
    /// by a second dispatcher. The ledger still deduplicates its command ID.
    func reserveLocal(_ request: BridgeLANControlRequest) -> BridgeLANSubmitOutcome {
        lock.lock()
        defer { lock.unlock() }
        switch ledger.submit(request) {
        case .duplicate(let record):
            return .accepted(id: record.id, lane: record.lane, action: record.action,
                             generation: record.generation, duplicate: true)
        case .replayed:
            return .rejected(code: "command_replayed",
                             message: "This command ID was already used with different content.")
        case .busy:
            return .rejected(code: "command_busy",
                             message: "The bounded command ledger is full.")
        case .accepted(let record):
            guard ledger.markIssuedWithoutFile(id: record.id) else {
                return .rejected(code: "dispatch_unavailable",
                                 message: "The command could not be reserved.")
            }
            return .accepted(id: record.id, lane: record.lane, action: record.action,
                             generation: record.generation, duplicate: false)
        }
    }

    func result(_ request: BridgeLANResultRequest) -> BridgeLANCommandResultOutcome {
        lock.lock()
        let record = ledger.record(id: request.id)
        lock.unlock()
        guard let record else { return .unknown }
        // Never read a result (or its screenshot artifact) for a different
        // session, even before the server-level current-session check.
        guard record.session == request.session else {
            return .rejected(code: "session_mismatch",
                             message: "The result session does not own this command.")
        }

        let stored = BridgeFileChannel.result(identifier: request.id, lane: record.lane.commandLane)
        lock.lock()
        let disposition = ledger.disposition(
            id: request.id,
            pid: request.pid,
            generation: request.generation,
            session: request.session,
            hasResult: stored != nil
        )
        lock.unlock()

        switch disposition {
        case .unknown:
            return .unknown
        case .sessionMismatch:
            return .rejected(code: "session_mismatch",
                             message: "The result session does not own this command.")
        case .pending:
            return .pending
        case .expired:
            return .expired
        case .fenced:
            return .fenced
        case .late(let record):
            guard let stored else { return .fenced }
            return lateOutcome(record: record, result: stored.result)
        case .ready(let record):
            guard let stored else { return .pending }
            guard identityMatches(stored.result, record: record) else {
                return .rejected(code: "result_stale",
                                 message: "The stored result does not match the authorized command.")
            }
            if stored.result.status == "rejected" {
                return .rejected(code: "command_rejected",
                                 message: "The dispatcher rejected the command before execution.")
            }
            guard stored.result.generation == record.generation else {
                return .rejected(code: "result_stale",
                                 message: "The stored result does not match the authorized command.")
            }
            return .ready(payload(record: record, result: stored.result, includeArtifact: true))
        }
    }

    @discardableResult
    func fence(reason: String) -> Int {
        lock.lock()
        let affected = ledger.fence(reason: reason)
        lock.unlock()
        var removed = 0
        for record in affected {
            guard let url = record.fileURL else { continue }
            if FileManager.default.fileExists(atPath: url.path) {
                try? FileManager.default.removeItem(at: url)
                removed += 1
            }
        }
        return removed
    }

    func reset() {
        lock.lock()
        ledger.reset()
        lock.unlock()
    }

    private func identityMatches(_ result: BridgeCommandResult,
                                 record: BridgeLANCommandRecord) -> Bool {
        // The engine echoes a digest of the effective non-secret arguments.
        // This binds a stored result to the exact authorized argument shape
        // (bundle, coordinates, duration, text byte count), not only to the
        // command ID and action.
        let digest = result.details["argumentsDigest"] ?? ""
        return result.id == record.id &&
            result.action == record.action &&
            result.processIdentifier == record.pid &&
            digest == record.resultDigest
    }

    private func lateOutcome(record: BridgeLANCommandRecord,
                             result: BridgeCommandResult) -> BridgeLANCommandResultOutcome {
        guard identityMatches(result, record: record) else {
            return .rejected(code: "result_stale",
                             message: "The stored result does not match the authorized command.")
        }
        if result.status != "rejected", result.generation != record.generation {
            return .rejected(code: "result_stale",
                             message: "The stored result does not match the authorized command.")
        }
        let resulting = UInt64(result.details["resultingGeneration"] ?? "")
        return .late(BridgeLANLateResult(
            status: result.status,
            action: result.action,
            processIdentifier: result.processIdentifier,
            generation: result.generation,
            resultingGeneration: resulting,
            processedAt: result.processedAt,
            error: result.error.map { bounded($0, 4_096) }
        ))
    }

    private func payload(record: BridgeLANCommandRecord,
                         result: BridgeCommandResult,
                         includeArtifact: Bool) -> BridgeLANCommandResultPayload {
        let resulting = UInt64(result.details["resultingGeneration"] ?? "")
        let sanitized = sanitize(result.details)
        var artifact: BridgeLANArtifact?
        var artifactError: String?
        if includeArtifact,
           result.action == "screenshot",
           let name = BridgeLANArtifactPolicy.safeScreenshotFileName(
               commandID: record.id,
               result: result
           ) {
            let url = BridgePaths.diagnostics.appendingPathComponent(name)
            guard BridgeLANArtifactPolicy.isConstrained(url, to: BridgePaths.diagnostics) else {
                artifactError = "The screenshot path is outside the diagnostics directory."
                return BridgeLANCommandResultPayload(
                    status: result.status, action: result.action,
                    processIdentifier: result.processIdentifier,
                    generation: result.generation,
                    resultingGeneration: resulting,
                    processedAt: result.processedAt, details: sanitized.details,
                    error: result.error.map { bounded($0, 4_096) },
                    artifact: nil, artifactError: artifactError
                )
            }
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                let size = (attributes[.size] as? NSNumber)?.intValue ?? -1
                guard size > 0, size <= limits.maxArtifactBytes else {
                    artifactError = "The screenshot size is outside the bounded range."
                    return BridgeLANCommandResultPayload(
                        status: result.status, action: result.action,
                        processIdentifier: result.processIdentifier,
                        generation: result.generation,
                        resultingGeneration: resulting,
                        processedAt: result.processedAt, details: sanitized.details,
                        error: result.error.map { bounded($0, 4_096) },
                        artifact: nil, artifactError: artifactError
                    )
                }
                let data = try Data(contentsOf: url, options: .mappedIfSafe)
                guard data.count <= limits.maxArtifactBytes else {
                    artifactError = "The screenshot exceeds the bounded artifact size."
                    return BridgeLANCommandResultPayload(
                        status: result.status, action: result.action,
                        processIdentifier: result.processIdentifier,
                        generation: result.generation,
                        resultingGeneration: resulting,
                        processedAt: result.processedAt, details: sanitized.details,
                        error: result.error.map { bounded($0, 4_096) },
                        artifact: nil, artifactError: artifactError
                    )
                }
                artifact = BridgeLANArtifact(
                    name: name,
                    mediaType: "image/png",
                    byteCount: data.count,
                    sha256: BridgeAtomicFile.sha256(data),
                    base64: data.base64EncodedString()
                )
            } catch {
                artifactError = "The screenshot artifact could not be read."
            }
        }
        return BridgeLANCommandResultPayload(
            status: result.status,
            action: result.action,
            processIdentifier: result.processIdentifier,
            generation: result.generation,
            resultingGeneration: resulting,
            processedAt: result.processedAt,
            details: sanitized.details,
            error: result.error.map { bounded($0, 4_096) },
            artifact: artifact,
            artifactError: artifactError
        )
    }

    private struct SanitizedDetails {
        var details: [String: String]
    }

    private func sanitize(_ details: [String: String]) -> SanitizedDetails {
        var output: [String: String] = [:]
        var total = 0
        // `inspect_ui` returns one bounded tree string instead of hundreds of
        // detail entries. Everything else keeps the original 4 KiB/32 KiB
        // budget; the tree has its own explicit ceiling and is still bounded
        // by the request's maxTotalBytes.
        let hasTree = details["uiTree"] != nil
        let totalLimit = hasTree ? 196_608 : 32_768
        for key in details.keys.sorted() {
            guard output.count < 64,
                  key.utf8.count <= 96,
                  !Self.isSecretKey(key) else { continue }
            let valueLimit = key == "uiTree" ? 131_072 : 4_096
            guard let value = details[key], value.utf8.count <= valueLimit else { continue }
            let cost = key.utf8.count + value.utf8.count
            guard total + cost <= totalLimit else { continue }
            output[key] = value
            total += cost
        }
        return SanitizedDetails(details: output)
    }

    private static func isSecretKey(_ key: String) -> Bool {
        let lower = key.lowercased()
        for fragment in ["token", "secret", "credential", "authorization",
                         "replacement", "key"] where lower.contains(fragment) {
            return true
        }
        return false
    }

    private func bounded(_ value: String, _ limit: Int) -> String {
        value.utf8.count <= limit ? value : String(value.prefix(limit / 4))
    }
}

// MARK: - MainActor service

@MainActor
final class BridgeLANControlService {
    private let server = BridgeLANControlServer()
    private let broker = BridgeLANCommandBroker()
    private let shutdownRelay = BridgeLANShutdownRelay()
    private var key: Data?

    private(set) var isListening = false
    private(set) var lastError: String?
    private(set) var urls: [String] = []

    init() {
        key = BridgeLANControlKeyStore.load()
    }

    var keyFingerprint: String? {
        guard let key else { return nil }
        return BridgeLANControlKey.fingerprint(key)
    }

    var hasKey: Bool { key != nil }

    var isStarted: Bool { server.isStarted }

    func setShutdownHandler(_ handler: (@Sendable (String) -> Void)?) {
        shutdownRelay.setHandler(handler)
    }

    func start() throws {
        guard let key = BridgeLANControlKeyStore.load() else {
            throw BridgeLANControlError.missingKey
        }
        self.key = key
        if server.isStarted {
            try server.replaceKey(key)
            _ = broker.fence(reason: "control-restart")
            refreshURLs()
            return
        }
        let broker = self.broker
        let relay = self.shutdownRelay
        let runtime = BridgeLANControlServer.Runtime(
            key: key,
            state: {
                let snapshot = BridgeSharedState.shared.snapshot()
                return BridgeLANCurrentState(pid: snapshot.hostPid,
                                             generation: snapshot.generation)
            },
            submit: { request in
                if request.action == "shutdown" {
                    // The server closes new admission synchronously after this
                    // returns accepted, then calls the shutdown callback below.
                    return broker.reserveLocal(request)
                }
                if request.lane == .engine,
                   !BridgeSharedState.shared.engineAcceptsCommands() {
                    return .rejected(code: "engine_not_ready",
                                     message: "The engine is not ready for commands.")
                }
                return broker.submit(request)
            },
            result: { request in
                broker.result(request)
            },
            shutdown: { identifier in
                // Fence queued LAN work immediately. Coordinator cleanup and
                // final socket/key teardown are scheduled promptly so the
                // sealed acknowledgement can flush first.
                _ = broker.fence(reason: "shutdown-accepted")
                relay.request(identifier: identifier)
            },
            log: { message in
                BridgeLog.shared.append(message)
            }
        )
        server.setStateChangeHandler { [weak self] listening, error in
            Task { @MainActor in
                self?.apply(listening: listening, error: error)
            }
        }
        do {
            try server.start(runtime)
            lastError = nil
            refreshURLs()
        } catch {
            lastError = error.localizedDescription
            throw error
        }
    }

    func stop() {
        // Close the listener first: server.stop waits for an in-flight submit
        // to finish, then invalidates its listener/auth instance. Fence the
        // broker afterwards so that any command issued just before the close
        // is removed from the lane. An already-claimed call is never killed or
        // retried; its late result stays late.
        server.stop()
        _ = broker.fence(reason: "control-off")
        isListening = false
        urls = []
    }

    func fence(reason: String) {
        // requestEpoch/arm is the linearization point for new submits; the
        // broker fence removes commands that were already issued before it.
        server.fence()
        _ = broker.fence(reason: reason)
    }

    /// One-way revoke. Stops the listener, removes queued LAN commands and
    /// deletes the separate control key. It never changes AutoStart, the
    /// install token or the read-only diagnostics preference.
    func revoke() {
        fence(reason: "revoke")
        stop()
        broker.reset()
        BridgeLANControlKeyStore.delete()
        key = nil
        lastError = nil
    }

    @discardableResult
    func provision(keyString: String) throws -> String {
        guard let data = BridgeLANControlKey.decode(keyString) else {
            throw BridgeLANControlError.invalidKey
        }
        if let install = try? BridgeInstallToken.load(account: BridgeInstallToken.fileChannelAccount),
           BridgeInstallToken.constantTimeEquals(keyString, install) {
            throw BridgeLANControlError.keyMatchesInstallToken
        }
        try BridgeLANControlKeyStore.save(data)
        key = data
        if server.isStarted {
            // Replace the key first: the auth epoch advances, so an in-flight
            // request opened under the old key cannot commit or seal. Then
            // fence the request epoch and remove queued commands. Already-
            // entered SDK/native calls keep running; their late results are
            // never replayed as current.
            try server.replaceKey(data)
            fence(reason: "control-key-rotation")
        }
        refreshURLs()
        return BridgeLANControlKey.fingerprint(data)
    }

    func refreshURLs() {
        guard isListening, let port = server.listeningPort else {
            urls = []
            return
        }
        urls = BridgeNetworkInfo.controlURLs(port: port)
    }

    private func apply(listening: Bool, error: String?) {
        // A late close/failure callback from an older listener must not clear
        // the state of a listener that has already been restarted.
        if !listening && server.isListening {
            return
        }
        isListening = listening
        lastError = error
        if listening {
            refreshURLs()
        } else {
            urls = []
        }
    }
}
