import Foundation

public enum BridgeCommandLane: String, Codable, Sendable {
    case host
    case engine
}

public struct BridgeCommandEnvelope: Codable, Equatable, Sendable {
    public var id: String
    public var action: String
    public var pid: Int32?
    public var token: String?
    /// Prototype-only replacement material for `rotate_token`. It is never
    /// copied into results, status files or logs.
    public var replacementToken: String?
    /// Optional recovery preferences for `configure_recovery`. Omitted fields
    /// are left unchanged; the host lane must receive at least one of them.
    public var autoStart: Bool?
    public var lanEnabled: Bool?
    /// Enables the separate encrypted LAN control listener. It is not the
    /// read-only diagnostics switch and never defaults on.
    public var controlEnabled: Bool?
    /// A new 32-byte control credential. This is deliberately distinct from
    /// the install/read-only token; the policy refuses an equal value. The
    /// value is stored in the Keychain and only its fingerprint is returned.
    public var controlKey: String?
    /// Closed, typed arguments for the generic automation actions. Legacy
    /// commands omit this field and keep their existing behavior. The raw value
    /// is carried only in the short-lived authenticated command file; the LAN
    /// ledger retains digests instead.
    public var parameters: BridgeControlParameters?
    /// Optional freshness fence. Legacy commands omit it; the canary uses it
    /// so a Stop/fence prevents a queued but unobserved local command from
    /// being executed by a later generation.
    public var expectedGeneration: UInt64?
    public var issuedAt: String?

    public init(
        id: String,
        action: String,
        pid: Int32? = nil,
        token: String? = nil,
        replacementToken: String? = nil,
        autoStart: Bool? = nil,
        lanEnabled: Bool? = nil,
        controlEnabled: Bool? = nil,
        controlKey: String? = nil,
        parameters: BridgeControlParameters? = nil,
        expectedGeneration: UInt64? = nil,
        issuedAt: String? = nil
    ) {
        self.id = id
        self.action = action
        self.pid = pid
        self.token = token
        self.replacementToken = replacementToken
        self.autoStart = autoStart
        self.lanEnabled = lanEnabled
        self.controlEnabled = controlEnabled
        self.controlKey = controlKey
        self.parameters = parameters
        self.expectedGeneration = expectedGeneration
        self.issuedAt = issuedAt
    }
}

public enum BridgeCommandDecision: Equatable, Sendable {
    case accepted
    case missingID
    case missingAction
    case pidMismatch
    case invalidToken
    case generationMismatch
    case unsupportedAction
    case missingRecoveryConfiguration
    case invalidReplacementToken
    case unchangedReplacementToken
    case invalidControlKey
    case controlKeyMatchesInstallToken
    case invalidParameters(String)
}

public enum BridgeCommandPolicy {
    public static let hostActions: Set<String> = [
        "status",
        "start",
        "stop",
        "resume",
        "start_tunnel",
        "stop_tunnel",
        "download_ddi",
        "mount_ddi",
        "remove_ddi",
        "ddi_stage_probe",
        "configure_recovery",
        "rotate_token",
        "shutdown",
    ]

    public static let engineActions: Set<String> = [
        "status",
        "screenshot",
        "open_settings",
        "tap_general",
        "home",
        "stop_engine",
        BridgeControlAction.activateApp,
        BridgeControlAction.inspectUI,
        BridgeControlAction.tap,
        BridgeControlAction.swipe,
        BridgeControlAction.typeText,
    ]

    public static func actions(for lane: BridgeCommandLane) -> Set<String> {
        lane == .host ? hostActions : engineActions
    }

    public static func validate(
        _ command: BridgeCommandEnvelope,
        lane: BridgeCommandLane,
        expectedPid: Int32,
        expectedToken: String,
        expectedGeneration: UInt64? = nil
    ) -> BridgeCommandDecision {
        guard !command.id.isEmpty else { return .missingID }
        guard !command.action.isEmpty else { return .missingAction }
        guard command.pid == expectedPid else { return .pidMismatch }
        guard let token = command.token,
              BridgeInstallToken.constantTimeEquals(token, expectedToken) else {
            return .invalidToken
        }
        // Authentication precedes the freshness check. A command that asks
        // for a generation the caller cannot confirm is refused rather than
        // treated as legacy.
        if let commandGeneration = command.expectedGeneration {
            guard let expectedGeneration, commandGeneration == expectedGeneration else {
                return .generationMismatch
            }
        }
        guard actions(for: lane).contains(command.action) else { return .unsupportedAction }
        if command.action == "configure_recovery",
           command.autoStart == nil,
           command.lanEnabled == nil,
           command.controlEnabled == nil,
           command.controlKey == nil {
            return .missingRecoveryConfiguration
        }
        if let controlKey = command.controlKey {
            guard BridgeLANControlKey.isCanonical(controlKey) else {
                return .invalidControlKey
            }
            // The control credential must never be the legacy bearer that the
            // read-only diagnostics endpoint transmits in the clear.
            if BridgeInstallToken.constantTimeEquals(controlKey, expectedToken) {
                return .controlKeyMatchesInstallToken
            }
        }
        if command.action == "rotate_token", let replacement = command.replacementToken {
            guard BridgeInstallToken.isCanonical(replacement) else {
                return .invalidReplacementToken
            }
            if BridgeInstallToken.constantTimeEquals(replacement, expectedToken) {
                return .unchangedReplacementToken
            }
        }
        if BridgeControlAction.all.contains(command.action) {
            switch BridgeControlArguments.validate(action: command.action,
                                                   parameters: command.parameters) {
            case .failure(let error):
                return .invalidParameters(error.code)
            case .success:
                break
            }
        } else if command.parameters != nil {
            // Legacy actions are deliberately no-argument. Ignoring an
            // unexpected typed field would make two different requests look
            // identical, so refuse before any dispatch.
            return .invalidParameters("parameters_not_applicable")
        }
        return .accepted
    }
}

public struct BridgeCommandResult: Codable, Sendable {
    public var id: String
    public var action: String
    public var status: String
    public var authoredBy: String
    public var processIdentifier: Int32
    public var generation: UInt64
    public var processedAt: String
    public var details: [String: String]
    public var error: String?

    public init(
        id: String,
        action: String,
        status: String,
        authoredBy: String,
        processIdentifier: Int32 = Int32(ProcessInfo.processInfo.processIdentifier),
        generation: UInt64 = 0,
        details: [String: String] = [:],
        error: String? = nil
    ) {
        self.id = id
        self.action = action
        self.status = status
        self.authoredBy = authoredBy
        self.processIdentifier = processIdentifier
        self.generation = generation
        self.processedAt = BridgeClock.timestamp()
        self.details = details
        self.error = error
    }
}

/// One JSON file per command in a lane-specific inbox. The file channel is a
/// prototype diagnostic aid only: it is compiled into this prototype, requires
/// the current process PID and a Keychain-backed random token, and never opens
/// an unauthenticated public listener.
public enum BridgeFileChannel {
    public static func inbox(for lane: BridgeCommandLane) -> URL {
        lane == .host ? BridgePaths.commandsHost : BridgePaths.commandsEngine
    }

    public static func results(for lane: BridgeCommandLane) -> URL {
        lane == .host ? BridgePaths.resultsHost : BridgePaths.resultsEngine
    }

    public static func pending(lane: BridgeCommandLane) -> [(url: URL, envelope: BridgeCommandEnvelope)] {
        let directory = inbox(for: lane)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        var output: [(URL, BridgeCommandEnvelope)] = []
        for name in names.sorted().prefix(64) where name.hasSuffix(".json") {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  data.count <= BridgeControlArguments.maximumSerializedCommandBytes else { continue }
            guard let envelope = try? JSONDecoder().decode(BridgeCommandEnvelope.self, from: data) else {
                continue
            }
            output.append((url, envelope))
        }
        return output
    }

    /// Writes one authenticated command envelope into the lane inbox. This is
    /// the same file/parser/auth/result path used by the primary's manual
    /// commands; it is not a second dispatcher.
    @discardableResult
    public static func issue(_ command: BridgeCommandEnvelope, lane: BridgeCommandLane) -> URL? {
        guard !command.id.isEmpty else { return nil }
        let safe = BridgeAtomicFile.safeIdentifier(command.id)
        let url = inbox(for: lane).appendingPathComponent("command-\(safe).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(command),
              data.count <= BridgeControlArguments.maximumSerializedCommandBytes else { return nil }
        do {
            // A text command file is encrypted at rest as well as owner-only;
            // the engine claims it, executes it and removes it (including on
            // rejection) before writing any result.
            let protection: BridgeFileProtection? =
                command.parameters?.containsSensitiveInput == true ? .complete : nil
            try BridgeAtomicFile.write(data, to: url, protection: protection)
            return url
        } catch {
            return nil
        }
    }

    /// Reads a result written by the existing engine/host result path. The
    /// returned byte count is serialized evidence only; no file content is
    /// copied into reports beyond the typed result fields.
    public static func result(
        identifier: String,
        lane: BridgeCommandLane
    ) -> (result: BridgeCommandResult, bytes: Int)? {
        let safe = BridgeAtomicFile.safeIdentifier(identifier)
        let url = results(for: lane).appendingPathComponent("result-\(safe).json")
        guard let data = try? Data(contentsOf: url),
              data.count <= 1_048_576,
              let result = try? JSONDecoder().decode(BridgeCommandResult.self, from: data) else {
            return nil
        }
        return (result, data.count)
    }

    /// Atomically claims a command by renaming it out of the inbox. Returns the
    /// processed URL so the caller can keep the original file for evidence.
    public static func claim(url: URL, lane: BridgeCommandLane, identifier: String) -> URL? {
        let safe = BridgeAtomicFile.safeIdentifier(identifier)
        let destination = BridgePaths.processed
            .appendingPathComponent("\(lane.rawValue)-\(safe)-\(Int(Date().timeIntervalSince1970 * 1000)).json")
        do {
            try FileManager.default.moveItem(at: url, to: destination)
            return destination
        } catch {
            return nil
        }
    }

    public static func writeResult(_ result: BridgeCommandResult, lane: BridgeCommandLane) {
        let safe = BridgeAtomicFile.safeIdentifier(result.id)
        let url = results(for: lane).appendingPathComponent("result-\(safe).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(result) else { return }
        try? BridgeAtomicFile.write(data, to: url)
    }

    @discardableResult
    public static func writeRejected(_ command: BridgeCommandEnvelope,
                                     lane: BridgeCommandLane,
                                     decision: BridgeCommandDecision) -> Bool {
        let result = BridgeCommandResult(
            id: command.id,
            action: command.action,
            status: "rejected",
            authoredBy: "bridge-channel",
            details: [
                "decision": "\(decision)",
                "argumentsDigest": BridgeControlArguments.resultDigest(
                    action: command.action,
                    parameters: command.parameters
                ),
            ],
            error: "command rejected: \(decision)"
        )
        writeResult(result, lane: lane)
        return decision == .accepted
    }
}
