// SPDX-License-Identifier: MPL-2.0
//
// C01LinuxStdioBindings — the typed bridge between the ORIGINAL C02 MCP stdio
// client and the C01 Linux engine's REAL three-pipe process.
//
// This file owns NO process and NO protocol logic: the runtime service owns
// the child (stdin write / stdout read / stderr read are three distinct OS
// pipes inside the selected PRoot guest), and `C02MCPStdioClient` owns the
// newline JSON-RPC framing. Here we define:
//
// * the immutable, fully validated binding an open channel is fenced to:
//   accepted epoch, project/environment/root identity, task/conversation,
//   live run, config revision/digest, exact argv and workspace-relative cwd;
// * the typed mailbox operations (`host.stdioStart`, `host.stdioWrite`,
//   `host.stdioPoll`, `host.stdioStdinEof`, `host.stdioClose`) over the
//   EXISTING `LinuxShellMailbox` (no second transport, no Binder access here,
//   no host process/interpreter and no shell string);
// * strict bounded parsing of every reply. A malformed/oversized/foreign
//   reply is a typed failure, never a partial success.
//
// Nothing in this file is model-visible: no tool name, no V3 handler and no
// prompt string can reach a stdio process through it.

import Foundation
import CoreFoundation
import FloeCore
import FloeAndroidShellTools
import FloeTools

// MARK: - Typed failures

/// Honest, closed failure vocabulary for the C01 stdio lane. The C02 provider
/// maps these onto the existing `C02MCPSetupFailure` codes; none of these
/// cases ever means "assume it ran".
public struct C01LinuxStdioFailure: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Code: String, Sendable, Equatable {
        /// No accepted generation, no qualified engine or no live stdio
        /// contract from the actual peer.
        case unavailable
        /// The saved binding/config/argv/cwd is not admissible.
        case invalidConfiguration
        /// The accepted Root epoch or the peer contract changed.
        case staleGeneration
        /// The resolved workspace/project/root identity does not match.
        case workspaceMismatch
        /// No legitimate live setup/task run can own this channel.
        case executionContextUnavailable
        /// One JSON-RPC line exceeded the supported bound. The channel is
        /// closed: there is no desynchronized resynchronization.
        case lineTooLong
        /// stdout lost bytes or could not be framed as complete lines.
        case streamDesynchronized
        /// The peer closed one of its pipes (EOF), distinct from a timeout.
        case pipeClosed
        /// The bounded read wait expired with no complete line.
        case timedOut
        /// The stdin pipe refused/closed the write (bounded accounting kept).
        case writeFailed
        /// A reply was malformed, oversized or outside the closed grammar.
        case protocolViolation

        public var isRetryable: Bool {
            switch self {
            case .unavailable, .staleGeneration, .timedOut: return true
            default: return false
            }
        }
    }

    public var code: Code
    public var message: String

    public init(_ code: Code, _ message: String) {
        self.code = code
        self.message = message
    }

    public var description: String { "\(code.rawValue): \(message)" }
    public var retryable: Bool { code.isRetryable }
}

// MARK: - Binding / request / reply values

/// The immutable identity a channel is fenced to. It is produced ONLY by
/// `C01MCPStdioChannelProvider` after the original workspace authority, live
/// run store and root identity agree; a caller cannot invent one through a
/// model/tool surface.
public struct C01LinuxStdioBinding: Sendable, Equatable {
    /// The persisted project row identity the configuration selected.
    public let projectID: UUID
    /// The engine's deterministic project identity (SHA256 of the trusted
    /// canonical Core workspace root) used on the `shell.start`-family wire.
    public let engineProjectID: UUID
    public let environmentID: String
    /// SHA256 hex of the canonical Core workspace root (C02 project root
    /// identity). Re-computed at open and re-checked before every start.
    public let rootIdentity: String
    /// The task/conversation identity the saved MCP binding named.
    public let taskID: UUID
    /// Exactly ONE live non-terminal run of that task. Never synthesized.
    public let runID: UUID
    public let conversationID: UUID
    public let workspaceID: UUID
    public let workspaceRootURL: URL
    /// The saved server revision at bind time (echoed, never guessed).
    public let serverRevision: UInt64
    /// `MCPServerConfigHash.digest` of the full configuration this channel
    /// was opened from. A different live digest means the edit superseded it.
    public let configDigest: String
    public let displayName: String
    public let command: String
    public let arguments: [String]
    public let cwdRelative: String
    public let acceptedEpoch: UInt64

    public init(projectID: UUID, engineProjectID: UUID, environmentID: String,
                rootIdentity: String, taskID: UUID, runID: UUID,
                conversationID: UUID, workspaceID: UUID, workspaceRootURL: URL,
                serverRevision: UInt64, configDigest: String, displayName: String,
                command: String, arguments: [String], cwdRelative: String,
                acceptedEpoch: UInt64) {
        self.projectID = projectID
        self.engineProjectID = engineProjectID
        self.environmentID = environmentID
        self.rootIdentity = rootIdentity
        self.taskID = taskID
        self.runID = runID
        self.conversationID = conversationID
        self.workspaceID = workspaceID
        self.workspaceRootURL = workspaceRootURL
        self.serverRevision = serverRevision
        self.configDigest = configDigest
        self.displayName = displayName
        self.command = command
        self.arguments = arguments
        self.cwdRelative = cwdRelative
        self.acceptedEpoch = acceptedEpoch
    }
}

public struct C01LinuxStdioStartRequest: Sendable, Equatable {
    public let binding: C01LinuxStdioBinding
    /// Explicit service lifetime ceiling (the engine still enforces its own
    /// 24 h wire bound). Not a per-request timeout.
    public let timeoutSeconds: Double

    public init(binding: C01LinuxStdioBinding, timeoutSeconds: Double) {
        self.binding = binding
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct C01LinuxStdioStartReply: Sendable, Equatable {
    /// The engine lease/session identity. Every later operation addresses it
    /// exactly; a stale/foreign id refuses at the runtime.
    public let sessionID: String
    public let environmentID: String
    public let runtimeGeneration: String?
    public let stdioContractVersion: String
}

public struct C01LinuxStdioWriteReply: Sendable, Equatable {
    public let acceptedBytes: Int
    public let partial: Bool
    public let errnoCode: Int32?
}

public struct C01LinuxStdioPollRequest: Sendable, Equatable {
    public let sessionID: String
    public let stdoutCursor: UInt64
    public let stderrCursor: UInt64
    /// Per-stream page bound; the engine's own bound is 16384.
    public let maxBytes: Int

    public init(sessionID: String, stdoutCursor: UInt64, stderrCursor: UInt64,
                maxBytes: Int) {
        self.sessionID = sessionID
        self.stdoutCursor = stdoutCursor
        self.stderrCursor = stderrCursor
        self.maxBytes = maxBytes
    }
}

public struct C01LinuxStdioPollReply: Sendable, Equatable {
    public let sessionID: String
    public let stdout: Data
    public let stderr: Data
    public let stdoutCursor: UInt64
    public let stderrCursor: UInt64
    public let stdoutGapBytes: Int
    public let stderrGapBytes: Int
    public let stdoutMore: Bool
    public let stderrMore: Bool
    public let stdoutDroppedBytes: Int
    public let stderrDroppedBytes: Int
    public let stdoutEOF: Bool
    public let stderrEOF: Bool
    /// TRUE only after the runtime proved the real terminal and released the
    /// service lease (whole-UID quiescence + authority hand-back).
    public let leaseReleased: Bool
    public let cancelled: Bool
    public let stopReason: String?
    public let exitCode: Int32?
    public let termSig: Int32?
    public let waitErrno: Int32?
    public let workspaceStatus: String?
}

public struct C01LinuxStdioStdinEofReply: Sendable, Equatable {
    /// "closed" | "closed-idempotent" | "failed" | "rejected"
    public let state: String
    public let reason: String?
    public let errnoCode: Int32?
}

public struct C01LinuxStdioCapability: Sendable, Equatable {
    public let contractVersion: String
    public let stdioContractVersion: String
    public let serviceRoleAvailable: Bool
    public let stdioAvailable: Bool
    public let detail: String
}

// MARK: - Transport seam

/// The typed transport the provider/channel consume. Production is the
/// EXISTING `LinuxShellMailbox` (see `MailboxC01LinuxStdioTransport`); tests
/// inject a deterministic fake. No model or raw host command can reach the
/// engine through this seam.
public protocol C01LinuxStdioTransporting: Sendable {
    func capability(epoch: UInt64) async -> C01LinuxStdioCapability
    func start(_ request: C01LinuxStdioStartRequest) async throws -> C01LinuxStdioStartReply
    func write(sessionID: String, data: Data) async throws -> C01LinuxStdioWriteReply
    func poll(_ request: C01LinuxStdioPollRequest) async throws -> C01LinuxStdioPollReply
    func closeStdin(sessionID: String) async throws -> C01LinuxStdioStdinEofReply
    /// A stop REQUEST only. Ownership stays until `poll` proves release.
    func requestStop(sessionID: String) async throws
}

// MARK: - Production mailbox transport

/// Strict bounded mailbox implementation over the existing `LinuxShellMailbox`
/// (module-internal API). The trusted Kotlin pump owns the Binder exchange and
/// the runtime-UID engine; this type only encodes/decodes the closed payloads.
public struct MailboxC01LinuxStdioTransport: C01LinuxStdioTransporting {
    /// One stdin page; matches the engine's 16 KiB `stdio.write` bound.
    public static let maximumWriteBytes = 16_384
    /// One reply page per stream; matches the runtime `stdio.poll` bound.
    public static let maximumPageBytes = 16_384
    private static let maximumReplyBytes = 65_536
    private static let maximumStopReasonBytes = 48

    public init() {}

    public func capability(epoch: UInt64) async -> C01LinuxStdioCapability {
        guard epoch > 0,
              let payload = try? JSONSerialization.data(
                withJSONObject: ["epoch": epoch], options: [.sortedKeys]) else {
            return C01LinuxStdioCapability(contractVersion: "", stdioContractVersion: "",
                                           serviceRoleAvailable: false, stdioAvailable: false,
                                           detail: "invalidEpoch")
        }
        do {
            let reply = try await LinuxShellMailbox.shared.submit(
                operation: "host.serviceCapability", payload: payload, timeoutMillis: 10_000)
            guard reply.count <= Self.maximumReplyBytes,
                  let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
                return C01LinuxStdioCapability(contractVersion: "", stdioContractVersion: "",
                                               serviceRoleAvailable: false, stdioAvailable: false,
                                               detail: "unreadableCapability")
            }
            let contract = String(((object["contractVersion"] as? String) ?? "").prefix(64))
            let stdio = String(((object["stdioContractVersion"] as? String) ?? "").prefix(64))
            return C01LinuxStdioCapability(
                contractVersion: contract,
                stdioContractVersion: stdio,
                serviceRoleAvailable: object["serviceRoleAvailable"] as? Bool ?? false,
                stdioAvailable: object["stdioRoleAvailable"] as? Bool ?? false,
                detail: String(((object["detail"] as? String) ?? "").prefix(128)))
        } catch {
            return C01LinuxStdioCapability(contractVersion: "", stdioContractVersion: "",
                                           serviceRoleAvailable: false, stdioAvailable: false,
                                           detail: "capabilityUnreachable")
        }
    }

    public func start(_ request: C01LinuxStdioStartRequest) async throws -> C01LinuxStdioStartReply {
        let binding = request.binding
        var payload: [String: Any] = [
            "epoch": binding.acceptedEpoch,
            "projectID": binding.engineProjectID.uuidString,
            "runID": binding.runID.uuidString,
            "conversationID": binding.conversationID.uuidString,
            "environmentID": binding.environmentID,
            "command": binding.command,
            "arguments": binding.arguments,
            "cwd": binding.cwdRelative,
            "timeoutSeconds": min(86_400, max(60, request.timeoutSeconds)),
            "leaseRole": "service",
        ]
        if request.timeoutSeconds <= 0 { payload["timeoutSeconds"] = 86_400 }
        let reply = try await submit(operation: "host.stdioStart", payload: payload,
                                     timeoutMillis: LinuxShellMailboxLimits.preparationBudgetMillis)
        guard let object = reply,
              let sessionID = object["sessionID"] as? String,
              Self.validIdentifier(sessionID),
              let environmentID = object["environmentID"] as? String,
              !environmentID.isEmpty,
              let contract = object["stdioContractVersion"] as? String else {
            throw C01LinuxStdioFailure(.protocolViolation,
                                       "The runtime did not return a complete stdio start receipt.")
        }
        return C01LinuxStdioStartReply(
            sessionID: sessionID,
            environmentID: String(environmentID.prefix(256)),
            runtimeGeneration: (object["runtimeGeneration"] as? String).map { String($0.prefix(64)) },
            stdioContractVersion: String(contract.prefix(64)))
    }

    public func write(sessionID: String, data: Data) async throws -> C01LinuxStdioWriteReply {
        guard data.count <= Self.maximumWriteBytes else {
            throw C01LinuxStdioFailure(.invalidConfiguration,
                                       "A stdin page exceeded the engine 16 KiB bound.")
        }
        let reply = try await submit(
            operation: "host.stdioWrite",
            payload: ["sessionID": sessionID, "dataBase64": data.base64EncodedString()],
            timeoutMillis: LinuxShellMailboxLimits.inputBudgetMillis)
        guard let object = reply,
              let accepted = exactInt(object["acceptedBytes"]), accepted >= 0,
              accepted <= data.count else {
            throw C01LinuxStdioFailure(.protocolViolation,
                                       "The runtime returned an invalid stdio write receipt.")
        }
        return C01LinuxStdioWriteReply(
            acceptedBytes: accepted,
            partial: object["partial"] as? Bool ?? false,
            errnoCode: exactInt(object["errno"]).map { Int32($0) })
    }

    public func poll(_ request: C01LinuxStdioPollRequest) async throws -> C01LinuxStdioPollReply {
        guard (1...Self.maximumPageBytes).contains(request.maxBytes) else {
            throw C01LinuxStdioFailure(.invalidConfiguration,
                                       "A stdio poll page was outside the supported bound.")
        }
        let reply = try await submit(
            operation: "host.stdioPoll",
            payload: [
                "sessionID": request.sessionID,
                "stdoutCursor": request.stdoutCursor,
                "stderrCursor": request.stderrCursor,
                "maxBytes": request.maxBytes,
            ],
            timeoutMillis: LinuxShellMailboxLimits.pollBudgetMillis)
        guard let object = reply else {
            throw C01LinuxStdioFailure(.protocolViolation,
                                       "The runtime returned no stdio poll reply.")
        }
        guard let stdout = base64Page(object["stdoutBase64"]),
              let stderr = base64Page(object["stderrBase64"]),
              let stdoutCursor = exactUInt(object["stdoutCursor"]),
              let stderrCursor = exactUInt(object["stderrCursor"]) else {
            throw C01LinuxStdioFailure(.protocolViolation,
                                       "The runtime returned malformed stdio stream pages.")
        }
        let released = object["leaseReleased"] as? Bool ?? false
        let stdoutEOF = object["stdoutEof"] as? Bool ?? false
        let stderrEOF = object["stderrEof"] as? Bool ?? false
        if released && (!stdoutEOF || !stderrEOF) {
            // The runtime's own terminal page always carries closed pipes; a
            // receipt that claims release without EOF facts is inconsistent
            // and is never promoted into a usable channel.
            throw C01LinuxStdioFailure(.protocolViolation,
                                       "The stdio terminal receipt omitted its EOF facts.")
        }
        return C01LinuxStdioPollReply(
            sessionID: (object["sessionID"] as? String) ?? request.sessionID,
            stdout: stdout,
            stderr: stderr,
            stdoutCursor: stdoutCursor,
            stderrCursor: stderrCursor,
            stdoutGapBytes: max(0, exactInt(object["stdoutGapBytes"]) ?? 0),
            stderrGapBytes: max(0, exactInt(object["stderrGapBytes"]) ?? 0),
            stdoutMore: object["stdoutMore"] as? Bool ?? false,
            stderrMore: object["stderrMore"] as? Bool ?? false,
            stdoutDroppedBytes: max(0, exactInt(object["stdoutDroppedBytes"]) ?? 0),
            stderrDroppedBytes: max(0, exactInt(object["stderrDroppedBytes"]) ?? 0),
            stdoutEOF: stdoutEOF,
            stderrEOF: stderrEOF,
            leaseReleased: released,
            cancelled: object["cancelled"] as? Bool ?? false,
            stopReason: (object["stopReason"] as? String).map {
                String($0.prefix(Self.maximumStopReasonBytes))
            },
            exitCode: exactInt(object["exitCode"]).map { Int32($0) },
            termSig: exactInt(object["termSig"]).map { Int32($0) },
            waitErrno: exactInt(object["waitErrno"]).map { Int32($0) },
            workspaceStatus: (object["workspaceStatus"] as? String).map { String($0.prefix(32)) })
    }

    public func closeStdin(sessionID: String) async throws -> C01LinuxStdioStdinEofReply {
        let reply = try await submit(
            operation: "host.stdioStdinEof",
            payload: ["sessionID": sessionID],
            timeoutMillis: LinuxShellMailboxLimits.inputBudgetMillis)
        guard let object = reply,
              let state = object["stdinEof"] as? String,
              ["closed", "closed-idempotent", "failed", "rejected"].contains(state) else {
            throw C01LinuxStdioFailure(.protocolViolation,
                                       "The runtime returned an invalid stdin EOF receipt.")
        }
        return C01LinuxStdioStdinEofReply(
            state: state,
            reason: (object["reason"] as? String).map { String($0.prefix(64)) },
            errnoCode: exactInt(object["errno"]).map { Int32($0) })
    }

    public func requestStop(sessionID: String) async throws {
        let reply = try await submit(
            operation: "host.stdioClose",
            payload: ["sessionID": sessionID],
            timeoutMillis: LinuxShellMailboxLimits.cancelBudgetMillis)
        guard let object = reply,
              let state = object["state"] as? String,
              state == "stop_requested" || state == "released" else {
            throw C01LinuxStdioFailure(.protocolViolation,
                                       "The runtime did not acknowledge the owned stdio stop request.")
        }
    }

    // MARK: Bounded submit / parse

    private func submit(operation: String, payload: [String: Any],
                        timeoutMillis: Int) async throws -> [String: Any]? {
        guard JSONSerialization.isValidJSONObject(payload),
              let encoded = try? JSONSerialization.data(withJSONObject: payload,
                                                        options: [.sortedKeys]),
              encoded.count <= LinuxShellMailboxLimits.maximumFrameBytes else {
            throw C01LinuxStdioFailure(.invalidConfiguration,
                                       "The stdio request exceeded the frozen mailbox frame bound.")
        }
        do {
            let reply = try await LinuxShellMailbox.shared.submit(
                operation: operation, payload: encoded,
                timeoutMillis: max(1_000, min(timeoutMillis, 120_000)))
            guard reply.count <= Self.maximumReplyBytes,
                  let object = try JSONSerialization.jsonObject(with: reply) as? [String: Any] else {
                throw C01LinuxStdioFailure(.protocolViolation,
                                           "The runtime stdio reply was malformed or oversized.")
            }
            return object
        } catch let failure as C01LinuxStdioFailure {
            throw failure
        } catch let failure as LinuxShellTransportError {
            throw Self.map(failure)
        } catch {
            throw C01LinuxStdioFailure(.unavailable,
                                       "The stdio mailbox request did not settle.")
        }
    }

    private static func map(_ failure: LinuxShellTransportError) -> C01LinuxStdioFailure {
        switch failure {
        case .notBound, .hostFenced:
            return C01LinuxStdioFailure(.staleGeneration,
                                        "The Linux generation is no longer bound.")
        case .saturated:
            return C01LinuxStdioFailure(.unavailable,
                                        "The engine mailbox is saturated; retry shortly.")
        case .payloadTooLarge:
            return C01LinuxStdioFailure(.invalidConfiguration,
                                        "The stdio request exceeded the engine wire bound.")
        case .remoteFailed(let code):
            return C01LinuxStdioFailure(.unavailable,
                                        "The engine refused the stdio request (code=\(code)).")
        case .remoteFailedWithRestore(let code, _):
            return C01LinuxStdioFailure(.unavailable,
                                        "The engine refused the stdio request (code=\(code)).")
        case .remoteFailedWithStartFailure(let code, _, _, _):
            return C01LinuxStdioFailure(.unavailable,
                                        "The engine refused the stdio request (code=\(code)).")
        case .replyMalformed:
            return C01LinuxStdioFailure(.protocolViolation,
                                        "The engine stdio reply could not be decoded.")
        case .waitBudgetExpired:
            return C01LinuxStdioFailure(.unavailable,
                                        "The bounded stdio request wait expired; nothing was assumed.")
        }
    }

    static func validIdentifier(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 64 &&
            value.unicodeScalars.allSatisfy { scalar in
                (scalar.value >= 0x21 && scalar.value <= 0x7e)
            }
    }

    private func base64Page(_ value: Any?) -> Data? {
        guard let text = value as? String, text.utf8.count <= 24_000,
              let data = Data(base64Encoded: text, options: []) else { return nil }
        return data
    }

    private func exactInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite else { return nil }
        let integer = number.int64Value
        guard number.compare(NSNumber(value: integer)) == .orderedSame else { return nil }
        return Int(integer)
    }

    private func exactUInt(_ value: Any?) -> UInt64? {
        guard let integer = exactInt(value), integer >= 0 else { return nil }
        return UInt64(integer)
    }
}
