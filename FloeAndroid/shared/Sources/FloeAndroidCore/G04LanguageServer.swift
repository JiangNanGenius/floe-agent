// SPDX-License-Identifier: MPL-2.0
//
// G04LanguageServer — the REAL stdio JSON-RPC (LSP) client for Android
// (job-dda32d23d55e4460). It runs language servers INSIDE the ORIGINAL
// resolved Linux engine session (the same `ShellSessionCenter` +
// `AndroidLinuxShellBackend` + typed mailbox transport that exec.shell uses),
// NOT through any host interpreter, and NOT through the sanitized model
// tool surface:
//
//  * Transport: one owned interactive PTY session per (conversation,
//    language) server, started with the ORIGINAL `.conversation` receipt
//    attached BEFORE the engine awaits and released only after real
//    settlement. The launch command turns the PTY into raw, echo-off mode
//    (`stty raw -echo`) and closes the stdout/stderr merge the engine
//    cannot split (`2>/dev/null` guest-side), so Content-Length framing is
//    not contaminated by echo or by a crash banner; when the guest cannot
//    provide that shape the session fails CLOSED with the typed marker
//    (rawTtyUnsupported / toolMissing), never a "looks streaming" fallback.
//    The narrow engine delta that would give a first-class stderr channel
//    and kernel-side raw termios is exported to Main in the mounting delta
//    instead of being invented as unsupported request fields here.
//  * Framing: `G04LspFrameParser`/`G04LspFrameWriter` (this module) —
//    fragmented/coalesced Content-Length UTF-8, hard frame bounds, typed
//    contamination, no resynchronisation-by-search.
//  * Document truth: the shared native authority (MAIN's
//    `G04WorkspaceDocumentSession` through the root-owned
//    `G04WorkspaceFacade`). Every URI resolves under the ONE mapped
//    workspace (`file:///workspace/<relative>`; the engine binds the Core
//    workspace root at `/workspace`); every didOpen/didChange/completion
//    fence carries the EXACT opaque native revision; `workspace/applyEdit`
//    goes through the SAME atomic editor CAS (edit / bounded uploadEdit),
//    prevalidates all documents, and NEVER reports `applied:true` after a
//    partial application — a mid-flight failure answers `applied:false`
//    with the exact per-document outcomes (already-applied drafts stay in
//    the original undo/recovery history; nothing is dropped or faked).
//  * The Kotlin RAM editor projection is presentation only; this client
//    never writes a second revision store and never trusts a renderer
//    absolute path.
//  * Availability is honest: a closed per-language catalog names the guest
//    tool; if the probe fails the state is `toolMissing` with guidance to
//    the EXISTING Linux/package flow. No silent fake server, no model-run
//    fabrication, no reflection/raw evaluator, no host path grant.
import Foundation
import CoreFoundation
import FloeCore
import FloeTools
import FloeAndroidShellTools

// MARK: - Limits

public enum G04LanguageServerLimits {
    /// One server session per exact (conversation, language) pair.
    public static let maximumServersPerConversation = 3
    /// Live LSP sessions across the process-owned domain (the engine runs
    /// ONE workload globally; this bound mirrors the session-center cap).
    public static let maximumLiveServers = 3
    /// Live JSON-RPC requests per server (typed refusal beyond).
    public static let maximumLiveRequests = 64
    /// Bounded outgoing frame queue per server (aggregate body bytes).
    public static let maximumPendingWriteBytes = 8 * 1024 * 1024
    /// Diagnostic items surfaced per publish (the rest is honestly truncated).
    public static let maximumDiagnosticItems = 256
    /// Completion items surfaced per request.
    public static let maximumCompletionItems = 128
    /// Server-initiated messages surfaced (window/logMessage etc).
    public static let maximumServerMessageEvents = 16
    /// Bounded wait budgets (seconds).
    public static let initializeBudgetSeconds: Double = 90
    public static let completionBudgetSeconds: Double = 10
    public static let shutdownBudgetSeconds: Double = 10
    /// UTF-8 byte cap accepted into a didChange/didOpen body (the shared
    /// native document bound; larger documents refuse BEFORE framing).
    public static let maximumSyncedTextBytes = 4 * 1024 * 1024
}

// MARK: - Typed refusal codes


/// Swift-6-safe scoped synchronous NSLock helper (same rule as
/// G02TransportGate/FacadeEventPump): the lock is never taken directly from
/// an async context and never held across an await.
@inline(__always)
private func g04LspLocked<T>(_ lock: NSLock, _ body: () throws -> T) rethrows -> T {
    lock.lock()
    defer { lock.unlock() }
    return try body()
}

public enum G04LspCode: String, Sendable, Equatable, Error {
    case retired
    case ownerChanged
    case workspaceUnbound
    case engineUnqualified
    case languageUnsupported
    case languageDisabled
    case serverUnavailable
    case serverGone
    case saturated
    case staleRevision
    case missingDocument
    case tooLarge
    case framingContaminated
    case rawTtyUnsupported
    case toolMissing
    case timeout
    case cancelled
    case replyMalformed
    case applyEditRefused
    case transportFailed
    case invalidUri
}

// MARK: - Language catalog (closed; settings may only disable)

public struct G04LanguageServerDescriptor: Sendable, Equatable {
    public let languageID: String
    public let tool: String
    public let arguments: [String]
    public init(languageID: String, tool: String, arguments: [String]) {
        self.languageID = languageID; self.tool = tool; self.arguments = arguments
    }
}

public enum G04LanguageServerCatalog {
    /// The exact supported set with the guest tool each one requires.
    /// Installation of missing tools goes through the EXISTING Linux/package
    /// flow (the runtime setup surface); this catalog never downloads or
    /// installs anything itself.
    public static let servers: [G04LanguageServerDescriptor] = [
        .init(languageID: "shell", tool: "bash-language-server", arguments: ["start"]),
        .init(languageID: "python", tool: "pylsp", arguments: []),
        .init(languageID: "javascript", tool: "typescript-language-server", arguments: ["--stdio"]),
        .init(languageID: "typescript", tool: "typescript-language-server", arguments: ["--stdio"]),
        .init(languageID: "json", tool: "vscode-json-language-server", arguments: ["--stdio"]),
        .init(languageID: "html", tool: "vscode-html-language-server", arguments: ["--stdio"]),
        .init(languageID: "css", tool: "vscode-css-language-server", arguments: ["--stdio"]),
        .init(languageID: "yaml", tool: "yaml-language-server", arguments: ["--stdio"]),
    ]

    public static func descriptor(for languageID: String) -> G04LanguageServerDescriptor? {
        servers.first { $0.languageID == languageID }
    }

    /// The launch command riding the ORIGINAL `shell.start` (the engine runs
    /// it as `/bin/sh -lc <command>` with cwd under `/workspace`):
    /// probe → raw echo-off termios → exec server with stderr discarded.
    /// The closed markers are observed by the session BEFORE any framing is
    /// attempted and mapped to the typed `toolMissing` / `rawTtyUnsupported`
    /// states; nothing is silently swallowed.
    public static func startCommand(for descriptor: G04LanguageServerDescriptor) -> String {
        let quoted = ([descriptor.tool] + descriptor.arguments).map(G04LanguageRunPolicy.shellQuote).joined(separator: " ")
        return "if ! command -v \(G04LanguageRunPolicy.shellQuote(descriptor.tool)) >/dev/null 2>&1; "
            + "then echo FLOE-LSP-TOOL-MISSING \(G04LanguageRunPolicy.shellQuote(descriptor.tool)); exit 127; fi; "
            + "stty raw -echo 2>/dev/null || { echo FLOE-LSP-NO-RAWTTY; exit 71; }; "
            + "exec \(quoted) 2>/dev/null"
    }
}

// MARK: - Language run policy (ported from the ORIGINAL IDELanguageRunPolicy)

/// The executable-or-not decision layer for the embedded Run path. Pure and
/// unit-testable; dispatch happens in `G04TerminalStore.runDraft` over the
/// ORIGINAL session machinery. Android reality: every plan executes inside
/// the resolved Linux guest (probed with the ORIGINAL `command -v` pattern);
/// the iOS on-device interpreters (ios_system) and SSH-host targets are NOT
/// available here and are never faked.
public enum G04LanguageRunPolicy {
    /// The closed runnable language set on Android (all execute inside the
    /// resolved Linux guest after the ORIGINAL `command -v` probe).
    public static let supportedLanguageIDs = ["python", "javascript", "typescript", "shell", "c", "cpp"]

    public enum Failure: Error, Equatable {
        case unsupportedLanguage
        case invalidPath
    }

    public struct Plan: Sendable, Equatable {
        public let languageID: String
        public let tool: String
        public let argv: [String]
    }

    /// Closed language -> tool + argv template table. `{source}` is replaced
    /// by the QUOTED workspace-relative path only after `pathGuard`; no user
    /// string is ever concatenated into a command line (element-by-element
    /// quoting, the ORIGINAL rule).
    public static func plan(languageID: String, relativePath: String) throws(Failure) -> Plan {
        let path = try pathGuard(relativePath)
        switch languageID.lowercased() {
        case "python":
            return Plan(languageID: "python", tool: "python3", argv: ["python3", "-u", path])
        case "javascript", "typescript":
            return Plan(languageID: languageID.lowercased(), tool: "node", argv: ["node", path])
        case "shell":
            return Plan(languageID: "shell", tool: "sh", argv: ["sh", path])
        case "c":
            return Plan(languageID: "c", tool: "cc",
                        argv: ["cc", "-O0", "-o", "/tmp/.floe-run.out", path, "&&", "/tmp/.floe-run.out"])
        case "cpp":
            return Plan(languageID: "cpp", tool: "c++",
                        argv: ["c++", "-O0", "-std=c++17", "-o", "/tmp/.floe-run.out", path, "&&", "/tmp/.floe-run.out"])
        default:
            throw Failure.unsupportedLanguage
        }
    }

    /// The full engine command string: probe, then exec the argv with each
    /// element quoted. Output and exit ride the ORIGINAL PTY session
    /// settlement (stdout+stderr merged is the engine reality; the terminal
    /// pane labels them as merged output, never a fabricated split). The
    /// compile-output path stays in the GUEST scratch (`/tmp`, bound to the
    /// run-owned scratch directory by the engine) and is removed by the
    /// EXIT trap — the user workspace is never polluted by a run artifact.
    public static func startCommand(languageID: String, relativePath: String) throws(Failure) -> String {
        let plan = try plan(languageID: languageID, relativePath: relativePath)
        let quoted = plan.argv.map(shellQuote).joined(separator: " ")
        // `&&` inside the joined string: the two `&&` argv elements are
        // shell operators, quoted below by re-substitution.
        let command = quoted.replacingOccurrences(of: shellQuote("&&"), with: "&&")
        return "if ! command -v \(shellQuote(plan.tool)) >/dev/null 2>&1; "
            + "then echo FLOE-RUN-TOOLCHAIN-MISSING \(shellQuote(plan.tool)); exit 127; fi; "
            + "trap 'rm -f /tmp/.floe-run.out' EXIT; \(command)"
    }

    static func pathGuard(_ relativePath: String) throws(Failure) -> String {
        let standardized = (relativePath as NSString).standardizingPath
        guard !standardized.isEmpty, !standardized.hasPrefix("/"), !standardized.hasPrefix("~"),
              !standardized.contains("\0"), standardized != ".",
              standardized.split(separator: "/").allSatisfy({ !$0.isEmpty && $0 != ".." }) else {
            throw Failure.invalidPath
        }
        return standardized
    }

    /// POSIX single-quote element quoting: the ORIGINAL "argument vectors
    /// are built as arrays and quoted element-by-element" rule.
    public static func shellQuote(_ element: String) -> String {
        "'" + element.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

// MARK: - Shared native document authority

public struct G04DocumentTab: Sendable, Equatable {
    public let documentID: UUID
    public let relativePath: String
    public let revision: String
    public let utf8Bytes: Int
    public let dirty: Bool
    public init(documentID: UUID, relativePath: String, revision: String, utf8Bytes: Int, dirty: Bool) {
        self.documentID = documentID; self.relativePath = relativePath
        self.revision = revision; self.utf8Bytes = utf8Bytes; self.dirty = dirty
    }
}

/// A single atomic CAS edit applied through the ORIGINAL editor session.
public struct G04DocumentAppliedEdit: Sendable, Equatable {
    public let documentID: UUID
    public let relativePath: String
    public let previousRevision: String
    public let newRevision: String
}

public enum G04DocumentAuthorityError: Error, Equatable, Sendable {
    case retired, ownerChanged, missingDocument, staleRevision, invalidRange, tooLarge, backendUnavailable
    case wire(code: String)
}

/// The narrow view of MAIN's shared native document authority this client
/// may use — NOTHING else. Implemented by the facade adapter below; tests
/// inject a deterministic fake. The Kotlin RAM projection never backs this.
public protocol G04WorkspaceDocumentAuthority: Sendable {
    func tabs(taskID: UUID, workspaceID: UUID) async throws -> [G04DocumentTab]
    func open(taskID: UUID, workspaceID: UUID, relativePath: String) async throws -> G04DocumentTab
    func fullText(taskID: UUID, workspaceID: UUID, documentID: UUID, revision: String) async throws -> String
    /// Atomic CAS replace over the original editor session (UTF-16 unit
    /// ranges, exactly the frozen wire grammar's `edit`/upload path).
    func edit(taskID: UUID, workspaceID: UUID, documentID: UUID, expectedRevision: String,
              location: Int, length: Int, replacement: String) async throws -> G04DocumentAppliedEdit
}

/// Production adapter: drives the root-owned `G04WorkspaceFacade` through
/// its EXACT closed wire grammar (workspace.read / workspace.write). No
/// second store, no direct WorkspaceFileService bypass, no payload outside
/// the frozen field sets. The large-replacement path uses the ORIGINAL
/// bounded upload transaction (beginEditUpload/append/commit) so a full
/// document edit can never be smuggled as an oversized control string.
public struct G04FacadeDocumentAuthority: G04WorkspaceDocumentAuthority {
    public static let maximumInlineReplacementBytes = 24 * 1024

    let facade: G04WorkspaceFacade
    public init(facade: G04WorkspaceFacade) { self.facade = facade }

    private typealias Value = SettingsDomainV1.JSONValue

    private func payload(_ pairs: [String: Value], workspaceID: UUID, op: String) -> Value {
        var object = pairs
        object["op"] = .string(op)
        object["workspaceID"] = .string(workspaceID.uuidString)
        object["nativeEpoch"] = .string(String(facade.epoch))
        return .object(object)
    }

    private func dispatch(_ command: String, taskID: UUID, payload: Value) async throws -> DesignJSONValue {
        let reply = await facade.execute(command: command, taskID: taskID, payload: payload)
        switch reply {
        case .completed(let document): return document
        case .refused(let code, _): throw Self.map(code)
        }
    }

    static func map(_ code: String) -> G04DocumentAuthorityError {
        switch code {
        case "retired": return .retired
        case "ownerChanged", "epochMismatch": return .ownerChanged
        case "missingDocument", "notFound": return .missingDocument
        case "staleRevision": return .staleRevision
        case "invalidRange": return .invalidRange
        case "tooLarge": return .tooLarge
        case "backendUnavailable": return .backendUnavailable
        default: return .wire(code: code)
        }
    }

    public func tabs(taskID: UUID, workspaceID: UUID) async throws -> [G04DocumentTab] {
        let document = try await dispatch("workspace.read", taskID: taskID,
                                          payload: payload([:], workspaceID: workspaceID, op: "tabs"))
        guard case .object(let pairs) = document, case .array(let rows)? = pairs["documents"] else {
            throw G04DocumentAuthorityError.wire(code: "replyMalformed")
        }
        return rows.compactMap(Self.tab(from:))
    }

    public func open(taskID: UUID, workspaceID: UUID, relativePath: String) async throws -> G04DocumentTab {
        let document = try await dispatch("workspace.read", taskID: taskID,
                                          payload: payload(["path": .string(relativePath)], workspaceID: workspaceID, op: "open"))
        guard case .object(let pairs) = document, let tab = Self.tab(from: .object(pairs)) else {
            throw G04DocumentAuthorityError.wire(code: "replyMalformed")
        }
        return tab
    }

    public func fullText(taskID: UUID, workspaceID: UUID, documentID: UUID, revision: String) async throws -> String {
        let begin = try await dispatch("workspace.read", taskID: taskID,
                                       payload: payload(["documentID": .string(documentID.uuidString),
                                                 "revision": .string(revision)], workspaceID: workspaceID, op: "beginContent"))
        guard case .object(let pairs) = begin,
              case .string(let rawHandle)? = pairs["handle"], let handle = UUID(uuidString: rawHandle),
              case .integer(let byteCount)? = pairs["byteCount"] else {
            throw G04DocumentAuthorityError.wire(code: "replyMalformed")
        }
        guard byteCount <= G04LanguageServerLimits.maximumSyncedTextBytes else { throw G04DocumentAuthorityError.tooLarge }
        var collected = Data()
        var offset: Int64 = 0
        var released = false
        defer {
            if !released {
                Task { try? await self.dispatch("workspace.write", taskID: taskID,
                                                payload: payload(["handle": .string(rawHandle)], workspaceID: workspaceID, op: "releaseContent")) }
            }
        }
        while Int64(collected.count) < byteCount {
            let limit = min(Int64(G04WorkspaceDocumentSession.maximumChunkBytes), byteCount - Int64(collected.count))
            let chunk = try await dispatch("workspace.read", taskID: taskID,
                                           payload: payload(["handle": .string(rawHandle),
                                                     "offset": .integer(offset),
                                                     "limit": .integer(limit)], workspaceID: workspaceID, op: "readContent"))
            guard case .object(let chunkPairs) = chunk,
                  case .string(let encoded)? = chunkPairs["bytes"], let data = Data(base64Encoded: encoded),
                  case .integer(let next)? = chunkPairs["nextOffset"] else {
                throw G04DocumentAuthorityError.wire(code: "replyMalformed")
            }
            collected.append(data)
            offset = next
            if case .bool(let finished)? = chunkPairs["finished"], finished { break }
        }
        let release = try await dispatch("workspace.write", taskID: taskID,
                                         payload: payload(["handle": .string(rawHandle)], workspaceID: workspaceID, op: "releaseContent"))
        released = true
        _ = release
        guard collected.count == Int(byteCount), let text = String(data: collected, encoding: .utf8) else {
            throw G04DocumentAuthorityError.wire(code: "contentDigestMismatch")
        }
        return text
    }

    public func edit(taskID: UUID, workspaceID: UUID, documentID: UUID, expectedRevision: String,
              location: Int, length: Int, replacement: String) async throws -> G04DocumentAppliedEdit {
        // Small replacement: the atomic inline `edit`. Large replacement:
        // the ORIGINAL bounded upload transaction — a complete-byte proof
        // (digest-bound) replaces any "truncate then claim success".
        if replacement.utf8.count <= Self.maximumInlineReplacementBytes {
            let document = try await dispatch("workspace.write", taskID: taskID,
                                              payload: payload(["documentID": .string(documentID.uuidString),
                                                        "revision": .string(expectedRevision),
                                                        "location": .integer(Int64(location)),
                                                        "length": .integer(Int64(length)),
                                                        "replacement": .string(replacement)], workspaceID: workspaceID, op: "edit"))
            return try appliedEdit(document, documentID: documentID, previous: expectedRevision)
        }
        let data = Data(replacement.utf8)
        let begin = try await dispatch("workspace.write", taskID: taskID,
                                       payload: payload(["documentID": .string(documentID.uuidString),
                                                 "revision": .string(expectedRevision),
                                                 "location": .integer(Int64(location)),
                                                 "length": .integer(Int64(length)),
                                                 "byteCount": .integer(Int64(data.count)),
                                                 "sha256": .string(FloeDigest.sha256Hex(data))], workspaceID: workspaceID, op: "beginEditUpload"))
        guard case .object(let pairs) = begin, case .string(let rawHandle)? = pairs["handle"] else {
            throw G04DocumentAuthorityError.wire(code: "replyMalformed")
        }
        var offset = 0
        while offset < data.count {
            let page = data.subdata(in: offset..<min(offset + G04WorkspaceDocumentSession.maximumChunkBytes, data.count))
            _ = try await dispatch("workspace.write", taskID: taskID,
                                   payload: payload(["handle": .string(rawHandle),
                                             "offset": .integer(Int64(offset)),
                                             "bytes": .string(page.base64EncodedString())], workspaceID: workspaceID, op: "appendEditUpload"))
            offset += page.count
        }
        let committed = try await dispatch("workspace.write", taskID: taskID,
                                           payload: payload(["handle": .string(rawHandle)], workspaceID: workspaceID, op: "commitEditUpload"))
        return try appliedEdit(committed, documentID: documentID, previous: expectedRevision)
    }

    private func appliedEdit(_ document: DesignJSONValue, documentID: UUID,
                              previous: String) throws -> G04DocumentAppliedEdit {
        guard case .object(let pairs) = document, let tab = Self.tab(from: .object(pairs)) else {
            throw G04DocumentAuthorityError.wire(code: "replyMalformed")
        }
        return G04DocumentAppliedEdit(documentID: documentID, relativePath: tab.relativePath,
                                      previousRevision: previous, newRevision: tab.revision)
    }

    static func tab(from value: DesignJSONValue) -> G04DocumentTab? {
        guard case .object(let pairs) = value,
              case .string(let rawID)? = pairs["documentID"], let documentID = UUID(uuidString: rawID),
              case .string(let path)? = pairs["relativePath"],
              case .string(let revision)? = pairs["revision"],
              case .integer(let bytes)? = pairs["utf8Bytes"],
              case .bool(let dirty)? = pairs["dirty"] else { return nil }
        return G04DocumentTab(documentID: documentID, relativePath: path, revision: revision,
                              utf8Bytes: Int(bytes), dirty: dirty)
    }
}

// MARK: - Trusted runtime registry (Main mount point)

/// Epoch-exact holder for the shared native document authority used by the
/// LSP client and the Run saved-draft check. Main's mounting delta calls
/// `register(epoch:facade:)` from `G04WorkspaceDomainExtension.attach` with
/// the SAME facade instance the workspace extension created, and
/// `unregister(epoch:)` from `beginRetirement` — exactly like the existing
/// `G04WorkspaceHostRegistry` source pattern. A stale epoch can never read
/// or replace a newer generation's binding.
public final class G04TerminalRuntimeRegistry: @unchecked Sendable {
    public static let shared = G04TerminalRuntimeRegistry()
    private let lock = NSLock()
    private var live: (epoch: UInt64, authority: G04WorkspaceDocumentAuthority)?

    /// Convenience production binding: wrap the root-owned facade.
    public func register(epoch: UInt64, facade: G04WorkspaceFacade) {
        register(epoch: epoch, authority: G04FacadeDocumentAuthority(facade: facade))
    }

    /// Test/custom binding (same single slot; first registration wins).
    public func register(epoch: UInt64, authority: G04WorkspaceDocumentAuthority) {
        lock.lock(); defer { lock.unlock() }
        guard live == nil || live?.epoch == epoch else { return }
        live = (epoch, authority)
    }

    public func unregister(epoch: UInt64) {
        lock.lock(); defer { lock.unlock() }
        if live?.epoch == epoch { live = nil }
    }

    public func authority(epoch: UInt64) -> G04WorkspaceDocumentAuthority? {
        lock.lock(); defer { lock.unlock() }
        guard let live, live.epoch == epoch else { return nil }
        return live.authority
    }

    public var currentAuthority: G04WorkspaceDocumentAuthority? {
        lock.lock(); defer { lock.unlock() }
        return live?.authority
    }
}

// MARK: - Server PTY transport seam

/// The narrow PTY-session seam the JSON-RPC engine consumes. The production
/// implementation drives the ORIGINAL ShellSessionCenter with
/// `forTerminal: true` (raw bytes); tests inject a deterministic fake.
public protocol G04LspSessionTransport: Sendable {
    /// Start the server process session; returns the session token.
    func start(command: String) async throws -> String
    /// Write raw frame bytes (already framed, valid UTF-8, no NUL). The
    /// PTY window may ALSO return output bytes collected during the write
    /// exchange — the caller MUST feed them to the parser; dropping them
    /// would silently lose frames.
    func write(_ bytes: Data) async throws -> G04LspPage
    /// Read the next available raw page (nil while nothing yet; empty-data
    /// pages are legal, the terminal flag says when the process truly ended).
    func read() async throws -> G04LspPage
    /// Explicitly requested cancellation (engine stop REQUEST).
    func requestStop() async
    /// Settle: the ORIGINAL center close path; may retain for reconciliation.
    func close() async
    /// Whether the ORIGINAL owned-work receipt behind this transport has
    /// been cancelled (task deletion / Root retirement). The pump asks this
    /// each round so a cancelled lease is followed by the honest close path
    /// (a stop REQUEST, settlement stays with the engine reconciliation).
    func isCancellationRequested() async -> Bool
}

public extension G04LspSessionTransport {
    /// Additive default: transports that cannot carry a receipt (fakes)
    /// report "not cancelled"; the production center transport overrides it.
    func isCancellationRequested() async -> Bool { false }
}

public struct G04LspPage: Sendable, Equatable {
    public var bytes: Data
    public var terminal: Bool
    public var exitCode: Int32?
    public var stopReason: String?
    public init(bytes: Data, terminal: Bool, exitCode: Int32? = nil, stopReason: String? = nil) {
        self.bytes = bytes; self.terminal = terminal
        self.exitCode = exitCode; self.stopReason = stopReason
    }
}

// MARK: - Center-backed production transport

/// Opens the language-server PTY over the ORIGINAL session machinery with
/// the conversation receipt attached before the awaited engine call and
/// released only after real settlement. The session rides the same engine
/// slot as the terminal/run paths (single-workload truth); a busy slot is
/// an honest refusal, never a queue invention.
public final class G04CenterLspTransport: G04LspSessionTransport, @unchecked Sendable {
    private struct Opened {
        let sessionToken: String
        let ownerRunID: UUID
        let receipt: G04WorkspaceOwnedOperation
        let cancellation: CancellationToken
    }

    private let epoch: UInt64
    private let conversationID: UUID
    private let workspaceRootURL: URL
    private let sink: any G04TerminalEventSink
    private let stateLock = NSLock()
    private var opened: Opened?
    /// Bytes handed off by `start`'s bounded initial drain that the engine
    /// already produced (the marker/first frame may arrive there).
    private var initialBacklog: [Data] = []

    public init(epoch: UInt64, conversationID: UUID, workspaceRootURL: URL,
                sink: any G04TerminalEventSink) {
        self.epoch = epoch; self.conversationID = conversationID
        self.workspaceRootURL = workspaceRootURL; self.sink = sink
    }

    private var components: LinuxShellComponents? { RuntimeFacadeLinuxBindings.shared.components }

    public func start(command: String) async throws -> String {
        guard let components, RuntimeFacadeLinuxBindings.shared.isCapabilityQualified else {
            throw G04LspCode.engineUnqualified
        }
        if await components.backend.isEngineSlotBusy() {
            // The engine runs ONE workload: the terminal pane or a run owns
            // the slot; refuse honestly (the host shows availability).
            throw G04LspCode.saturated
        }
        guard let (runDomain, _) = RunDomainFacade.current(epoch: epoch),
              let receipt = await runDomain.beginG04WorkspaceOperation(conversationID: conversationID,
                                                                       expectedEpoch: epoch) else {
            throw G04LspCode.retired
        }
        let ownerRunID = UUID()   // native-issued interaction identity (NOT a model run)
        // G04-R2: same operation-owned admission as the interactive terminal
        // (Main contract 2026-10-25) — the grant mints ONLY against this
        // REAL registered lease; refusal is honest and pre-dispatch.
        let operationGrantID = receipt.operationID
        guard LinuxWorkspaceAuthority.registerWorkspaceOperation(receipt, epoch: epoch,
                                                                 uiRunID: ownerRunID) else {
            await runDomain.endG04WorkspaceOperation(receipt)
            throw G04LspCode.retired
        }
        do {
            let result = try await components.sessions.open(
                command: command, cwd: ".", environment: [:],
                columns: 80, rows: 24,
                runID: ownerRunID, rootURL: workspaceRootURL,
                cancellation: receipt.cancellation,
                forTerminal: true, toolEnvironment: nil, clientSessionID: nil,
                conversationID: conversationID,
                workspaceOperationID: operationGrantID)
            let session = Opened(sessionToken: result.sessionID, ownerRunID: ownerRunID,
                                 receipt: receipt, cancellation: receipt.cancellation)
            g04LspLocked(stateLock) { opened = session }
            if let raw = result.terminalOutput, !raw.isEmpty { initialBacklog.append(raw) }
            return result.sessionID
        } catch {
            LinuxWorkspaceAuthority.retireWorkspaceOperation(operationID: operationGrantID)
            await runDomain.endG04WorkspaceOperation(receipt)
            throw G04LspCode.transportFailed
        }
    }

    private func current() throws -> Opened {
        let value = g04LspLocked(stateLock) { opened }
        guard let value else { throw G04LspCode.serverGone }
        return value
    }

    public func write(_ bytes: Data) async throws -> G04LspPage {
        let session = try current()
        guard let components else { throw G04LspCode.transportFailed }
        // The frames this client emits are valid UTF-8 with no NUL (the
        // writer enforces it); the engine stdin pages ride the ORIGINAL
        // <=16 KiB writeInput loop through exchange, and any output bytes
        // the exchange window collects are RETURNED for the caller to feed
        // the parser (never dropped here).
        let input = String(decoding: bytes, as: UTF8.self)
        let result = try await components.sessions.exchange(sessionID: session.sessionToken, input: input,
                                                            waitMs: 50, maxBytes: G04TerminalLimits.inputWriteBytes,
                                                            runID: session.ownerRunID,
                                                            cancellation: session.cancellation,
                                                            forTerminal: true, clientSessionID: nil)
        return G04LspPage(bytes: result.terminalOutput ?? Data(), terminal: !result.alive,
                          exitCode: result.exitCode, stopReason: nil)
    }

    public func read() async throws -> G04LspPage {
        if !initialBacklog.isEmpty {
            let first = initialBacklog.removeFirst()
            return G04LspPage(bytes: first, terminal: false)
        }
        let session = try current()
        guard let components else { throw G04LspCode.transportFailed }
        do {
            let result = try await components.sessions.exchange(sessionID: session.sessionToken,
                                                                input: nil,
                                                                waitMs: G04TerminalLimits.exchangeWaitMillis,
                                                                maxBytes: G04TerminalLimits.inputWriteBytes,
                                                                runID: session.ownerRunID,
                                                                cancellation: session.cancellation,
                                                                forTerminal: true, clientSessionID: nil)
            var terminal = !result.alive
            var exit: Int32? = result.exitCode
            if !terminal, Task.isCancelled { terminal = false }
            return G04LspPage(bytes: result.terminalOutput ?? Data(), terminal: terminal,
                              exitCode: exit, stopReason: nil)
        } catch is CancellationError {
            return G04LspPage(bytes: Data(), terminal: false)
        } catch {
            // The backend only throws here when the session is gone or the
            // transport failed: both are terminal for THIS server; the
            // engine lease remains owned for reconciliation (never assumed
            // stopped) — settle() below closes through the original path.
            return G04LspPage(bytes: Data(), terminal: true, exitCode: nil, stopReason: nil)
        }
    }

    public func requestStop() async {
        guard let session = try? current(), let components else { return }
        await components.sessions.signal(sessionID: session.sessionToken, signal: .terminate,
                                         runID: session.ownerRunID, clientSessionID: nil)
    }

    /// The REAL receipt state: the ORIGINAL deletion fence / retirement
    /// cancels exactly this token. A closed (settled) transport reports
    /// cancelled so a late pump round never re-opens anything.
    public func isCancellationRequested() async -> Bool {
        let value = g04LspLocked(stateLock) { opened }
        guard let value else { return true }
        return value.cancellation.isCancelled
    }

    public func close() async {
        guard let session = try? current() else { return }
        g04LspLocked(stateLock) { opened = nil }
        if let components {
            await components.sessions.close(sessionID: session.sessionToken, runID: session.ownerRunID,
                                            clientSessionID: nil)
        }
        if let (runDomain, _) = RunDomainFacade.current(epoch: epoch) {
            await runDomain.endG04WorkspaceOperation(session.receipt)
        }
        // G04-R2: clear the exact operation mapping when the real lease ends.
        LinuxWorkspaceAuthority.retireWorkspaceOperation(operationID: session.receipt.operationID)
    }
}

// MARK: - Position/URI mapping (exact, versioned)

/// One row of the versioned map native documentID/revision -> exact native
/// working-copy path -> trusted Linux-visible path. The Linux-visible root
/// is the ENGINE's own bind of the Core workspace at `/workspace`
/// (authoritative source: runtimeapp LinuxRuntimeOperations PRootLaunchSpec
/// `LinuxBind(workspace, "/workspace")`). SAF URIs, content URIs and host
/// absolute paths NEVER enter this map.
public enum G04LspPathMapping {
    public static let linuxWorkspaceRoot = "/workspace"
    public static let rootUri = "file:///workspace"

    /// relative path -> LSP uri. Bounded, percent-encoded per file path
    /// component (the ORIGINAL relative logical path stays canonical).
    public static func uri(relativePath: String) -> String {
        rootUri + "/" + relativePath.split(separator: "/", omittingEmptySubsequences: false)
            .map { percentEncodePathComponent(String($0)) }.joined(separator: "/")
    }

    /// LSP uri -> relative path, ONLY when it resolves under the exact
    /// mapped workspace root; anything else (absolute host path, other
    /// scheme, traversal) refuses.
    public static func relativePath(uri raw: String) -> String? {
        guard raw.hasPrefix(rootUri + "/"), raw.utf8.count <= 4096 else { return nil }
        let tail = String(raw.dropFirst(rootUri.count + 1))
        guard let decoded = percentDecodePath(tail) else { return nil }
        let components = decoded.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !decoded.isEmpty, !decoded.hasPrefix("/"), !components.contains(".."),
              !components.contains("."), !decoded.contains("\0") else { return nil }
        return components.joined(separator: "/")
    }

    private static let allowedUnreserved: Set<Character> =
        Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func percentEncodePathComponent(_ component: String) -> String {
        var out = ""
        for scalar in component.unicodeScalars {
            if scalar == "/" { out += "%2F"; continue }
            if CharacterSet(charactersIn: String(scalar)).isSubset(of: CharacterSet(
                charactersIn: String(ComponentSetCharacters))) && allowedUnreserved.contains(Character(scalar)) {
                out.unicodeScalars.append(scalar)
            } else if allowedUnreserved.contains(Character(scalar)) {
                out.unicodeScalars.append(scalar)
            } else {
                for byte in String(scalar).utf8 { out += String(format: "%%%02X", byte) }
            }
        }
        return out
    }

    /// Characters that pass through unescaped inside a path component.
    private static let ComponentSetCharacters = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~!$&'()*+,;=@"

    static func percentDecodePath(_ tail: String) -> String? {
        var bytes: [UInt8] = []
        var iterator = tail.utf8.makeIterator()
        while let byte = iterator.next() {
            if byte == 0x25 { // %
                guard let high = iterator.next(), let low = iterator.next(),
                      let value = hexByte(high, low) else { return nil }
                bytes.append(value)
            } else {
                bytes.append(byte)
            }
        }
        return String(bytes: bytes, encoding: .utf8)
    }

    private static func hexByte(_ high: UInt8, _ low: UInt8) -> UInt8? {
        func nibble(_ b: UInt8) -> UInt8? {
            switch b {
            case 0x30...0x39: return b - 0x30
            case 0x41...0x46: return b - 0x41 + 10
            case 0x61...0x66: return b - 0x61 + 10
            default: return nil
            }
        }
        guard let h = nibble(high), let l = nibble(low) else { return nil }
        return h << 4 | l
    }
}

/// LSP Position <-> UTF-16 offset conversion over the EXACT document text.
/// Line terminators per the LSP spec: \r\n, \n, \r (client-implemented
/// normalization; the server's view is the synced text we sent it).
public enum G04LspPosition {
    /// Returns (utf16Location, utf16Length) for an LSP Range within `text`.
    public static func offset(range: (startLine: Int, startChar: Int, endLine: Int, endChar: Int),
                              utf16 text: String.UTF16View) -> (location: Int, length: Int)? {
        guard range.startLine >= 0, range.endLine >= range.startLine,
              range.startChar >= 0, range.endChar >= 0 else { return nil }
        var lines: [(start: Int, length: Int)] = []
        var index = text.startIndex
        var lineStart = 0
        var currentLength = 0
        var utf16Offset = 0
        while index < text.endIndex {
            let unit = text[index]
            if unit == 0x0A { // \n
                lines.append((lineStart, currentLength))
                utf16Offset += 1
                lineStart = utf16Offset
                index = text.index(after: index)
                // consume a following \r-only sequence? No: \r\n handled below.
                currentLength = 0
                continue
            }
            if unit == 0x0D { // \r (possibly \r\n)
                lines.append((lineStart, currentLength))
                let next = text.index(after: index)
                let skip: Int = (next < text.endIndex && text[next] == 0x0A) ? 2 : 1
                if skip == 2 { index = text.index(after: next) } else { index = next }
                utf16Offset += skip
                lineStart = utf16Offset
                currentLength = 0
                continue
            }
            currentLength += 1
            utf16Offset += 1
            index = text.index(after: index)
        }
        lines.append((lineStart, currentLength))
        guard range.startLine < lines.count, range.endLine < lines.count else { return nil }
        let startLine = lines[range.startLine]
        let endLine = lines[range.endLine]
        let startOffset = startLine.start + min(range.startChar, startLine.length)
        let endOffset = endLine.start + min(range.endChar, endLine.length)
        guard endOffset >= startOffset else { return nil }
        return (startOffset, endOffset - startOffset)
    }

    /// Caret offset for a completion position.
    public static func offset(line: Int, character: Int, utf16 text: String.UTF16View) -> Int? {
        let converted = offset(range: (line, character, line, character), utf16: text)
        return converted?.location
    }
}

// MARK: - One language-server session

/// State machine for ONE (conversation, language) stdio JSON-RPC server.
/// The pump task owns ALL transport touches (write exchange output is fed
/// to the parser exactly like read output — frames can never be dropped by
/// a concurrent write). Server-initiated requests are answered; unsupported
/// server requests get the spec error -32601 (never silence).
public actor G04LanguageServerSession {
    public enum State: String, Sendable, Equatable {
        case idle, starting, ready, stopping, stopped, unavailable, failed
    }

    struct DocumentState {
        let documentID: UUID
        let relativePath: String
        var revision: String          // last NATIVE revision observed at sync
        var version: Int              // LSP didChange version (monotonic)
    }

    struct Pending {
        let hostRequestID: String
        let documentID: UUID?
        let revision: String?
        let kind: String              // "initialize" | "completion" | "shutdown"
        let deadlineNanos: UInt64
    }

    public let conversationID: UUID
    public let workspaceID: UUID
    public let languageID: String
    private let transport: any G04LspSessionTransport
    private let authority: any G04WorkspaceDocumentAuthority
    private let sink: any G04TerminalEventSink

    private(set) var state: State = .idle
    private(set) var stateCode: String?
    private var sessionToken: String?
    private let parser = G04LspFrameParser()
    private var pendingWrites: [Data] = []
    private var pendingWriteBytes = 0
    private var requestCounter: Int64 = 1
    private var pending: [Int64: Pending] = [:]
    private var documents: [UUID: DocumentState] = [:]
    private var documentsByRelativePath: [String: UUID] = [:]
    private var serverMessages = 0
    private var pumpRunning = false
    private var stopped = false
    /// completionProvider trigger characters observed from the server (for
    /// the App to decide when to ask; surfaced in the ready event).
    private(set) var triggerCharacters: [String] = []

    /// True once the session reached a terminal state (exited, failed, or a
    /// typed unavailable). The center replaces such a session on the next
    /// explicit ensure (e.g. after installing the tool through the existing
    /// Linux/package flow); it NEVER silently relaunches in the background.
    public var isTerminal: Bool { stopped || state == .stopped || state == .failed
        || state == .unavailable }

    /// True once every synced document has received a real didClose. The
    /// center uses this to shut an orphaned server down explicitly (the
    /// engine slot and conversation receipt must not be held after the
    /// last document of the task leaves; panes rebuilding never closes a
    /// document, so a reconstruction cannot reach this state).
    public func holdsNoDocuments() -> Bool { documents.isEmpty }

    /// The ACTUAL lifecycle snapshot for the trusted host's availability
    /// surface (never inferred from catalog presence).
    public func currentStatus() -> (state: State, code: String?) { (state, stateCode) }

    public init(conversationID: UUID, workspaceID: UUID, languageID: String,
                transport: any G04LspSessionTransport,
                authority: any G04WorkspaceDocumentAuthority,
                sink: any G04TerminalEventSink) {
        self.conversationID = conversationID; self.workspaceID = workspaceID
        self.languageID = languageID; self.transport = transport
        self.authority = authority; self.sink = sink
    }

    // MARK: Status egress

    private func emitState(_ value: State, code: String?, extra: [String: Any] = [:]) {
        state = value
        stateCode = code
        var object: [String: Any] = [
            "type": "lspStatus", "conversationID": conversationID.uuidString,
            "language": languageID, "state": value.rawValue,
        ]
        if let code { object["code"] = code }
        if let sessionToken { object["sessionToken"] = sessionToken }
        for (key, value) in extra { object[key] = value }
        sink.emitControl(object)
    }

    private func reply(_ hostRequestID: String, ok: Bool, code: G04LspCode? = nil, reason: String? = nil,
                       extra: [String: Any] = [:]) {
        var object: [String: Any] = ["type": "actionReply", "requestID": hostRequestID, "ok": ok]
        if let code { object["code"] = code.rawValue }
        if let reason { object["reason"] = reason }
        for (key, value) in extra { object[key] = value }
        sink.emitControl(object)
    }

    // MARK: Start

    /// Ensures the server is running and initialized. Idempotent: an
    /// already-ready server re-attaches nothing (survives view rebuild).
    public func ensureStarted(requestID: String) async {
        guard !stopped else { reply(requestID, ok: false, code: .serverGone); return }
        switch state {
        case .ready: reply(requestID, ok: true, extra: ["triggerCharacters": triggerCharacters]); return
        case .starting: reply(requestID, ok: false, code: .serverUnavailable, reason: "initializeInFlight"); return
        case .unavailable, .failed, .stopped:
            // A failed server never silently restarts into a second
            // process: the host must explicitly re-ensure after showing
            // the typed state; re-ensure below does that.
            break
        default: break
        }
        state = .starting
        let descriptor = G04LanguageServerCatalog.descriptor(for: languageID)
        guard let descriptor else {
            emitState(.unavailable, code: G04LspCode.languageUnsupported.rawValue)
            reply(requestID, ok: false, code: .languageUnsupported); return
        }
        do {
            let token = try await transport.start(command: G04LanguageServerCatalog.startCommand(for: descriptor))
            sessionToken = token
        } catch let code as G04LspCode {
            emitState(.unavailable, code: code.rawValue)
            reply(requestID, ok: false, code: code)
            return
        } catch {
            emitState(.failed, code: "transportStart")
            reply(requestID, ok: false, code: .transportFailed); return
        }
        startPump()
        // initialize request; the pump settles the reply (and sends
        // initialized) exactly once within the budget.
        let id = nextRequestID()
        let params: [String: Any] = [
            "processId": NSNull(),
            "clientInfo": ["name": "Floe Agent", "version": "g04"],
            "rootUri": G04LspPathMapping.rootUri,
            "workspaceFolders": [["uri": G04LspPathMapping.rootUri, "name": "workspace"]],
            "capabilities": [
                "textDocument": [
                    "synchronization": [
                        "didSave": false, "willSave": false, "willSaveWaitUntil": false,
                        "dynamicRegistration": false,
                    ],
                    "completion": [
                        "completionItem": [
                            "snippetSupport": false, "documentationFormat": ["plaintext"],
                            "resolveSupport": ["properties": [] as [String]],
                        ],
                        "contextSupport": false, "dynamicRegistration": false,
                    ],
                    "publishDiagnostics": [
                        "relatedInformation": false, "versionSupport": true, "dataSupport": false,
                    ],
                    "rename": NSNull(), "hover": NSNull(),
                ],
                "window": ["workDoneProgress": false],
                "workspace": [
                    "applyEdit": true,
                    "workspaceEdit": ["documentChanges": true, "resourceOperations": [] as [String]],
                    "configuration": false, "didChangeWatchedFiles": NSNull(),
                ],
            ],
            "initializationOptions": NSNull(),
        ]
        pending[id] = Pending(hostRequestID: requestID, documentID: nil, revision: nil,
                              kind: "initialize",
                              deadlineNanos: deadline(seconds: G04LanguageServerLimits.initializeBudgetSeconds))
        enqueueRequest(id: id, method: "initialize", params: params)
    }

    // MARK: Documents

    /// didOpen with the EXACT native revision fence. `text` must be the
    /// current native draft projection the host holds; the relative path is
    /// taken from the LIVE authority (never from a payload path string),
    /// and a revision mismatch against it refuses BEFORE any byte is sent.
    public func openDocument(documentID: UUID, expectedRevision: String,
                             text: String, requestID: String) async {
        guard state == .ready else {
            reply(requestID, ok: false, code: .serverUnavailable, reason: state.rawValue); return
        }
        guard text.utf8.count <= G04LanguageServerLimits.maximumSyncedTextBytes else {
            reply(requestID, ok: false, code: .tooLarge); return
        }
        let relativePath: String
        do {
            let tabs = try await authority.tabs(taskID: conversationID, workspaceID: workspaceID)
            guard let tab = tabs.first(where: { $0.documentID == documentID }) else {
                reply(requestID, ok: false, code: .missingDocument); return
            }
            guard tab.revision == expectedRevision else {
                reply(requestID, ok: false, code: .staleRevision); return
            }
            relativePath = tab.relativePath
        } catch let error as G04DocumentAuthorityError {
            reply(requestID, ok: false, reason: Self.authorityCode(error)); return
        } catch {
            reply(requestID, ok: false, reason: "authorityFailure"); return
        }
        let document = DocumentState(documentID: documentID, relativePath: relativePath,
                                     revision: expectedRevision, version: 1)
        documents[documentID] = document
        documentsByRelativePath[relativePath] = documentID
        let params: [String: Any] = ["textDocument": [
            "uri": G04LspPathMapping.uri(relativePath: relativePath),
            "languageId": languageID, "version": 1, "text": text,
        ]]
        enqueueNotification(method: "textDocument/didOpen", params: params)
        reply(requestID, ok: true, extra: ["version": 1, "relativePath": relativePath])
    }

    /// didChange (FULL sync) with the same exact revision fence; the LSP
    /// version is monotonically bumped from the previous sync.
    public func changeDocument(documentID: UUID, expectedRevision: String, text: String,
                               requestID: String) async {
        guard state == .ready, var document = documents[documentID] else {
            reply(requestID, ok: false, code: .missingDocument); return
        }
        guard text.utf8.count <= G04LanguageServerLimits.maximumSyncedTextBytes else {
            reply(requestID, ok: false, code: .tooLarge); return
        }
        do {
            let tabs = try await authority.tabs(taskID: conversationID, workspaceID: workspaceID)
            guard let tab = tabs.first(where: { $0.documentID == documentID }) else {
                reply(requestID, ok: false, code: .missingDocument); return
            }
            guard tab.revision == expectedRevision else {
                reply(requestID, ok: false, code: .staleRevision); return
            }
        } catch {
            reply(requestID, ok: false, reason: "authorityFailure"); return
        }
        document.revision = expectedRevision
        document.version += 1
        documents[documentID] = document
        let params: [String: Any] = [
            "textDocument": ["uri": G04LspPathMapping.uri(relativePath: document.relativePath),
                              "version": document.version],
            "contentChanges": [["text": text]],
        ]
        enqueueNotification(method: "textDocument/didChange", params: params)
        reply(requestID, ok: true, extra: ["version": document.version])
    }

    /// Real didClose. Returns true ONLY when a synced document actually
    /// left (a refusal for an unknown document must never look like the
    /// last close and tear the server down).
    @discardableResult
    public func closeDocument(documentID: UUID, requestID: String) -> Bool {
        guard let document = documents.removeValue(forKey: documentID) else {
            reply(requestID, ok: false, code: .missingDocument); return false
        }
        documentsByRelativePath.removeValue(forKey: document.relativePath)
        enqueueNotification(method: "textDocument/didClose", params: [
            "textDocument": ["uri": G04LspPathMapping.uri(relativePath: document.relativePath)],
        ])
        reply(requestID, ok: true)
        return true
    }

    // MARK: Completion

    public func completion(documentID: UUID, expectedRevision: String, line: Int, character: Int,
                           requestID: String) async {
        guard state == .ready, let document = documents[documentID] else {
            reply(requestID, ok: false, code: .missingDocument); return
        }
        guard document.revision == expectedRevision else {
            reply(requestID, ok: false, code: .staleRevision); return
        }
        guard pending.count < G04LanguageServerLimits.maximumLiveRequests else {
            reply(requestID, ok: false, code: .saturated); return
        }
        let id = nextRequestID()
        pending[id] = Pending(hostRequestID: requestID, documentID: documentID,
                              revision: expectedRevision, kind: "completion",
                              deadlineNanos: deadline(seconds: G04LanguageServerLimits.completionBudgetSeconds))
        enqueueRequest(id: id, method: "textDocument/completion", params: [
            "textDocument": ["uri": G04LspPathMapping.uri(relativePath: document.relativePath)],
            "position": ["line": line, "character": character],
            "context": ["triggerKind": 1],
        ])
    }

    /// Host cancellation of a pending completion: the JSON-RPC
    /// $/cancelRequest notification rides the SAME ordered write stream as
    /// the request it cancels; the host waiter is released with `cancelled`
    /// while the pending table keeps its slot until the server's real
    /// ResponseError(-32800) or a result arrives (late results are
    /// classified, never delivered to a resumed waiter twice).
    public func cancel(hostRequestID: String, requestID: String) {
        guard let entry = pending.first(where: { $0.value.hostRequestID == hostRequestID }) else {
            reply(requestID, ok: false, code: .missingDocument, reason: "noPendingRequest"); return
        }
        enqueueNotification(method: "$/cancelRequest", params: ["id": entry.key])
        let pendingValue = entry.value
        pending.removeValue(forKey: entry.key)
        reply(pendingValue.hostRequestID, ok: false, code: .cancelled)
        reply(requestID, ok: true)
    }

    // MARK: Shutdown

    /// Explicit close (user stopped the language, or the manager retires):
    /// best-effort `shutdown`/`exit` on the ordered stream, then the
    /// ORIGINAL session close path with receipt settlement. A stop request
    /// is never reported as a proven stop.
    public func shutdown(reason: String, requestID: String?) async {
        var ownedPendingID: Int64?
        if requestID != nil || state == .ready {
            let id = nextRequestID()
            ownedPendingID = id
            pending[id] = Pending(hostRequestID: requestID ?? "", documentID: nil, revision: nil,
                                  kind: "shutdown",
                                  deadlineNanos: deadline(seconds: G04LanguageServerLimits.shutdownBudgetSeconds))
            enqueueRequest(id: id, method: "shutdown", params: [:])
            enqueueNotification(method: "exit", params: [:])
            // Give the ordered stream one bounded flush window; the pump
            // closes the session when the queue drains OR the budget dies.
            var waited: UInt64 = 0
            while !pendingWrites.isEmpty, waited < 2_000_000_000 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                waited += 50_000_000
            }
        }
        // This call owns the truthful verdict for its own shutdown request:
        // withdraw it from `pending` BEFORE teardown so teardown's generic
        // serverGone flush cannot emit a spurious first `ok:false` reply for
        // the SAME requestID (a requestID-keyed host would then see a
        // contradicting false-before-true pair; host cohort evidence
        // test-145137.log G04LanguageServerTests/
        // testExplicitShutdownSendsShutdownExitAndCloses). Any OTHER pending
        // work still receives its honest serverGone reply from teardown.
        if let id = ownedPendingID, pending[id]?.kind == "shutdown" {
            pending.removeValue(forKey: id)
        }
        await teardown(code: reason, state: .stopped)
        if let requestID { reply(requestID, ok: true) }
    }

    private func teardown(code: String, state finalState: State) async {
        if !stopped {
            stopped = true
            emitState(finalState, code: code)
            for entry in pending.values {
                reply(entry.hostRequestID, ok: false, code: .serverGone)
            }
            pending.removeAll()
            for document in documents.values {
                documentsByRelativePath.removeValue(forKey: document.relativePath)
            }
            documents.removeAll()
            parser.reset()
        }
        await transport.close()
        sessionToken = nil
    }

    /// Transport close after a synchronous fault mark (contamination): the
    /// state was already emitted inside the marking path; this only closes
    /// the ORIGINAL session (which retains its own reconciliation).
    private func finishTeardown() async {
        await transport.close()
        sessionToken = nil
    }

    // MARK: Pump (sole transport toucher)

    private func startPump() {
        guard !pumpRunning else { return }
        pumpRunning = true
        Task { [weak self] in await self?.pump() }
    }

    private func pump() async {
        while !stopped {
            // Drain the ordered write queue first (one bounded chunk per
            // pass so reads stay interactive).
            if !pendingWrites.isEmpty {
                let chunk = pendingWrites.removeFirst()
                pendingWriteBytes = max(0, pendingWriteBytes - chunk.count)
                do {
                    let page = try await transport.write(chunk)
                    feed(page.bytes)
                    if stopped { await finishTeardown(); return }
                    if page.terminal { await teardown(code: "server-exited", state: .stopped); return }
                } catch {
                    await teardown(code: "writeFailed", state: .failed); return
                }
            } else {
                do {
                    let page = try await transport.read()
                    feed(page.bytes)
                    if stopped { await finishTeardown(); return }
                    if page.terminal {
                        let code = page.stopReason ?? (state == .ready || state == .starting ? "server-exited" : "closed")
                        await teardown(code: code, state: state == .failed ? .failed : .stopped)
                        return
                    }
                } catch {
                    await teardown(code: "readFailed", state: .failed); return
                }
            }
            expirePending()
            if stopped { break }
            if await transport.isCancellationRequested() {
                // The ORIGINAL owned-work receipt was cancelled (task
                // deletion / Root retirement): request the honest close
                // path. teardown runs the ORIGINAL transport close (an
                // engine stop REQUEST; the backend reconciliation owns the
                // long tail) and settles the receipt there — never a fake
                // proven stop and never a silent continue.
                await teardown(code: "lifecycle-cancelled", state: .stopped)
                return
            }
            if parser.pendingByteCount > 0 || !pendingWrites.isEmpty { continue }
            try? await Task.sleep(nanoseconds: G04TerminalLimits.busyDelayNanos)
        }
    }

    private func feed(_ data: Data) {
        guard !data.isEmpty else { return }
        parser.feed(data)
        while true {
            switch parser.nextFrame() {
            case .failure(let error):
                handleContamination(error)
                return
            case .success(nil):
                return
            case .success(let body?):
                handleFrame(body)
            }
        }
    }

    private func handleContamination(_ error: G04LspFramingError) {
        // Never swallow, never resynchronise: classify the observed prefix,
        // mark the session terminal, and surface the typed state. The pump
        // performs the transport close immediately after (finishTeardown).
        var code = G04LspCode.framingContaminated
        var prefix = ""
        if case .framingContaminated(let observed) = error {
            prefix = observed
            if observed.contains("FLOE-LSP-TOOL-MISSING") { code = .toolMissing }
            else if observed.contains("FLOE-LSP-NO-RAWTTY") { code = .rawTtyUnsupported }
        }
        stopped = true
        emitState(.unavailable, code: code.rawValue)
        for entry in pending.values {
            reply(entry.hostRequestID, ok: false, code: .serverGone)
        }
        pending.removeAll()
        sink.emitControl(["type": "lspFramingFault", "language": languageID,
                          "code": code.rawValue, "prefix": String(prefix.prefix(256)),
                          "conversationID": conversationID.uuidString])
    }

    private func expirePending() {
        let now = DispatchTime.now().uptimeNanoseconds
        for (id, entry) in pending where entry.deadlineNanos <= now {
            pending.removeValue(forKey: id)
            if entry.kind == "initialize" {
                Task { [weak self] in await self?.teardown(code: "initializeTimeout", state: .failed) }
            }
            reply(entry.hostRequestID, ok: false, code: .timeout)
            enqueueNotification(method: "$/cancelRequest", params: ["id": id])
        }
    }

    // MARK: Frame dispatch

    private func handleFrame(_ body: Data) {
        guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return }
        let idValue = object["id"]
        let method = object["method"] as? String
        let hasResult = object["result"] != nil
        let hasError = object["error"] != nil
        if let method, idValue != nil, !hasResult, !hasError {
            handleServerRequest(idValue: idValue, method: method, params: object["params"])
            return
        }
        if let method, idValue == nil {
            handleServerNotification(method: method, params: object["params"])
            return
        }
        if hasResult || hasError, let number = Self.int64(idValue), let entry = pending.removeValue(forKey: number) {
            handleResponse(entry: entry, result: object["result"], error: object["error"] as? [String: Any])
        }
    }

    private func handleServerRequest(idValue: Any?, method: String, params: Any?) {
        switch method {
        case "workspace/applyEdit":
            // Swift 6 region isolation: the spawned Task runs concurrently,
            // so the non-Sendable JSON fragments stay in this actor. The
            // request rides a self-built Data envelope (Sendable) and is
            // decoded AGAIN inside the actor — the exact same values, no
            // cross-isolation reference.
            guard let envelope = try? JSONSerialization.data(
                withJSONObject: ["id": idValue ?? NSNull(), "params": params ?? NSNull()]) else {
                enqueueReplyError(id: idValue, code: -32603, message: "internalError")
                return
            }
            Task { [weak self] in
                guard let self else { return }
                await self.answerApplyEditEnvelope(envelope)
            }
        case "window/showMessageRequest":
            // No UI surface for modal server messages in this batch: answer
            // null (spec-legal: user dismissed) and surface a typed event.
            surfaceServerMessage(method)
            enqueueReply(id: idValue, result: NSNull())
        default:
            // Method not found is spec-legal and never silent.
            enqueueReplyError(id: idValue, code: -32601, message: "methodNotSupported")
        }
    }

    private func handleServerNotification(method: String, params: Any?) {
        switch method {
        case "textDocument/publishDiagnostics":
            publishDiagnostics(params)
        default:
            surfaceServerMessage(method)
        }
    }

    private func surfaceServerMessage(_ method: String) {
        guard serverMessages < G04LanguageServerLimits.maximumServerMessageEvents else { return }
        serverMessages += 1
        sink.emitControl(["type": "lspServerMessage", "language": languageID, "method": method,
                          "truncated": serverMessages == G04LanguageServerLimits.maximumServerMessageEvents])
    }

    // MARK: Diagnostics

    private func publishDiagnostics(_ params: Any?) {
        guard let object = params as? [String: Any],
              let uri = object["uri"] as? String,
              let relative = G04LspPathMapping.relativePath(uri: uri),
              let documentID = documentsByRelativePath[relative],
              let rawItems = object["diagnostics"] as? [[String: Any]] else { return }
        guard let document = documents[documentID] else { return }
        var items: [[String: Any]] = []
        var truncated = false
        for raw in rawItems.prefix(G04LanguageServerLimits.maximumDiagnosticItems) {
            guard let range = raw["range"] as? [String: Any],
                  let message = raw["message"] as? String else { continue }
            let start = range["start"] as? [String: Any]
            let end = range["end"] as? [String: Any]
            let severity = (Self.int64(raw["severity"]) ?? 1)
            items.append([
                "startLine": Self.int64(start?["line"]) ?? 0,
                "startCharacter": Self.int64(start?["character"]) ?? 0,
                "endLine": Self.int64(end?["line"]) ?? 0,
                "endCharacter": Self.int64(end?["character"]) ?? 0,
                "severity": severity,            // 1 error, 2 warning, 3 info, 4 hint
                "message": String(message.prefix(2048)),
                "source": (raw["source"] as? String).map { String($0.prefix(64)) } ?? "",
            ])
        }
        truncated = rawItems.count > items.count
        sink.emitControl([
            "type": "lspDiagnostics",
            "conversationID": conversationID.uuidString, "workspaceID": workspaceID.uuidString,
            "documentID": document.documentID.uuidString,
            "relativePath": document.relativePath,
            "revision": document.revision,        // exact fence for the projection
            "lspVersion": document.version,
            "items": items, "truncated": truncated,
        ])
    }

    // MARK: Responses

    private func handleResponse(entry: Pending, result: Any?, error: [String: Any]?) {
        switch entry.kind {
        case "initialize":
            if error != nil {
                Task { [weak self] in await self?.teardown(code: "initializeRejected", state: .failed) }
                reply(entry.hostRequestID, ok: false, code: .serverUnavailable, reason: "initializeRejected")
                return
            }
            enqueueNotification(method: "initialized", params: [:])
            if let capabilities = (result as? [String: Any])?["capabilities"] as? [String: Any],
               let completionProvider = capabilities["completionProvider"] as? [String: Any],
               let triggers = completionProvider["triggerCharacters"] as? [String] {
                triggerCharacters = triggers.prefix(16).map { String($0.prefix(8)) }
            }
            emitState(.ready, code: nil, extra: ["triggerCharacters": triggerCharacters])
            reply(entry.hostRequestID, ok: true, extra: ["triggerCharacters": triggerCharacters])
            // Re-sync documents that opened while initialize was in flight:
            for (id, document) in documents {
                Task { [weak self] in
                    guard let self else { return }
                    await self.resynchronize(documentID: id, document: document)
                }
            }
        case "completion":
            if let error {
                let code = Self.int64(error["code"]) ?? 0
                reply(entry.hostRequestID, ok: false, code: .serverUnavailable,
                      reason: "jsonrpcError:\(code)")
                return
            }
            let items = Self.completionItems(from: result)
            sink.emitControl([
                "type": "lspCompletion",
                "requestID": entry.hostRequestID,
                "conversationID": conversationID.uuidString,
                "documentID": entry.documentID?.uuidString ?? "",
                "revision": entry.revision ?? "",
                "items": items.values, "incomplete": items.incomplete,
                "truncated": items.truncated,
            ])
        case "shutdown":
            break   // teardown owns the terminal answer
        default:
            break
        }
    }

    /// Pulls the CURRENT native text for a document whose native revision
    /// moved while initialize was in flight (the only resync path; never a
    /// speculative RAM text, never an empty-requestID reply pollution).
    private func resynchronize(documentID: UUID, document: DocumentState) async {
        guard state == .ready, documents[documentID] != nil else { return }
        do {
            let tabs = try await authority.tabs(taskID: conversationID, workspaceID: workspaceID)
            guard let tab = tabs.first(where: { $0.documentID == documentID }),
                  tab.revision != document.revision,
                  let text = try? await authority.fullText(taskID: conversationID, workspaceID: workspaceID,
                                                            documentID: documentID, revision: tab.revision) else {
                return
            }
            var current = document
            current.revision = tab.revision
            current.version += 1
            documents[documentID] = current
            let params: [String: Any] = [
                "textDocument": ["uri": G04LspPathMapping.uri(relativePath: current.relativePath),
                                  "version": current.version],
                "contentChanges": [["text": String(text.utf8.prefix(
                    G04LanguageServerLimits.maximumSyncedTextBytes))]],
            ]
            enqueueNotification(method: "textDocument/didChange", params: params)
        } catch {
            // The document vanished (closed/moved); the next host action
            // reopens honestly. Nothing here fabricates server state.
        }
    }

    // MARK: applyEdit (full prevalidation; honest partials)

    private struct ResolvedEdit {
        let uri: String
        let relativePath: String
        let documentID: UUID
        let initialRevision: String
        /// Each edit converted to UTF-16 (location,length) against the
        /// CURRENT text, sorted descending so earlier offsets stay valid.
        let prepared: [(location: Int, length: Int, newText: String)]
    }

    /// Prepare-phase refusal: carries the EXACT code to the wire answer.
    struct EditPlanFailure: Error { let code: String }

    /// Builds + fully validates the plan for every document (URI inside the
    /// mapped workspace, live tab present, version fence when the server
    /// provided one, all ranges inside the current text) BEFORE any CAS
    /// write happens. A failure anywhere refuses the WHOLE edit with the
    /// exact reason; nothing partial has touched any document.
    private func prepareWorkspaceEdit(_ params: Any?) async -> Result<[ResolvedEdit], EditPlanFailure> {
        guard let object = params as? [String: Any],
              let edit = object["edit"] as? [String: Any] else {
            return .failure(EditPlanFailure(code: "malformedEdit"))
        }
        var plan: [(uri: String, relative: String?, edits: [[String: Any]], version: Int?)] = []
        if let changes = edit["changes"] as? [String: [[String: Any]]] {
            for (uri, edits) in changes.sorted(by: { $0.key < $1.key }) {
                plan.append((uri, G04LspPathMapping.relativePath(uri: uri), edits, nil))
            }
        }
        if let documentChanges = edit["documentChanges"] as? [[String: Any]] {
            for change in documentChanges {
                if change["kind"] != nil {
                    return .failure(EditPlanFailure(code: "unsupportedFileOperations"))
                }
                guard let textDocument = change["textDocument"] as? [String: Any],
                      let uri = textDocument["uri"] as? String else {
                    return .failure(EditPlanFailure(code: "malformedDocumentChange"))
                }
                plan.append((uri, G04LspPathMapping.relativePath(uri: uri),
                             (change["edits"] as? [[String: Any]]) ?? [],
                             Self.int64(textDocument["version"]).map { Int($0) }))
            }
        }
        guard !plan.isEmpty else { return .failure(EditPlanFailure(code: "emptyEdit")) }
        let tabs: [G04DocumentTab]
        do {
            tabs = try await authority.tabs(taskID: conversationID, workspaceID: workspaceID)
        } catch {
            return .failure(EditPlanFailure(code: Self.authorityCodeFor(error)))
        }
        var resolved: [ResolvedEdit] = []
        for entry in plan {
            guard let relative = entry.relative else { return .failure(EditPlanFailure(code: "uriOutsideMappedWorkspace")) }
            guard let syncID = documentsByRelativePath[relative], let document = documents[syncID] else {
                return .failure(EditPlanFailure(code: "documentNotSynced"))
            }
            if let version = entry.version, version != document.version {
                return .failure(EditPlanFailure(code: "staleVersion"))
            }
            guard let tab = tabs.first(where: { $0.documentID == document.documentID }),
                  tab.relativePath == relative, tab.revision == document.revision else {
                return .failure(EditPlanFailure(code: "staleRevision"))
            }
            let text: String
            do {
                text = try await authority.fullText(taskID: conversationID, workspaceID: workspaceID,
                                                    documentID: tab.documentID, revision: tab.revision)
            } catch {
                return .failure(EditPlanFailure(code: Self.authorityCodeFor(error)))
            }
            var prepared: [(location: Int, length: Int, newText: String)] = []
            for item in entry.edits {
                guard let range = item["range"] as? [String: Any],
                      let newText = item["newText"] as? String,
                      let startValue = range["start"] as? [String: Any],
                      let endValue = range["end"] as? [String: Any] else {
                    return .failure(EditPlanFailure(code: "malformedEditItem"))
                }
                let position = (
                    startLine: Int(Self.int64(startValue["line"]) ?? -1),
                    startChar: Int(Self.int64(startValue["character"]) ?? -1),
                    endLine: Int(Self.int64(endValue["line"]) ?? -1),
                    endChar: Int(Self.int64(endValue["character"]) ?? -1)
                )
                guard position.startLine >= 0, position.endLine >= position.startLine,
                      position.startChar >= 0, position.endChar >= 0,
                      newText.utf8.count <= G04WorkspaceDocumentSession.maximumDocumentBytes else {
                    return .failure(EditPlanFailure(code: "invalidRange"))
                }
                guard let converted = G04LspPosition.offset(range: position, utf16: text.utf16) else {
                    return .failure(EditPlanFailure(code: "rangeOutsideText"))
                }
                prepared.append((converted.location, converted.length, newText))
            }
            prepared.sort { $0.location > $1.location }
            resolved.append(ResolvedEdit(uri: entry.uri, relativePath: relative,
                                         documentID: tab.documentID, initialRevision: tab.revision,
                                         prepared: prepared))
        }
        return .success(resolved)
    }

    /// Executes a fully prevalidated plan. The FIRST mid-flight failure
    /// stops the loop and everything already applied is reported EXACTLY
    /// (documentID + new revision per applied edit) with the overall answer
    /// `applied:false`: already-applied drafts stay recoverable in the
    /// original native undo/CAS history and nothing is hidden behind a
    /// success flag (the forbidden "applied:true after a prefix").
    private func applyWorkspaceEdit(_ params: Any?) async -> [String: Any] {
        switch await prepareWorkspaceEdit(params) {
        case .failure(let reason):
            return ["applied": false, "failureReason": reason.code]
        case .success(let documentsToEdit):
            var applied: [[String: Any]] = []
            for entry in documentsToEdit {
                var documentID = entry.documentID
                var revision = entry.initialRevision
                for item in entry.prepared {
                    do {
                        let result = try await authority.edit(taskID: conversationID,
                                                              workspaceID: workspaceID,
                                                              documentID: documentID,
                                                              expectedRevision: revision,
                                                              location: item.location, length: item.length,
                                                              replacement: item.newText)
                        revision = result.newRevision
                        applied.append(["relativePath": entry.relativePath,
                                        "documentID": documentID.uuidString, "revision": revision])
                    } catch let error as G04DocumentAuthorityError {
                        await refreshDocumentVersion(documentID: documentID, revision: revision)
                        emitPartial(applied: applied, reason: Self.authorityCode(error))
                        return ["applied": false, "failureReason": Self.authorityCode(error)]
                    } catch {
                        emitPartial(applied: applied, reason: "authorityFailure")
                        return ["applied": false, "failureReason": "authorityFailure"]
                    }
                }
                await refreshDocumentVersion(documentID: documentID, revision: revision)
            }
            sink.emitControl(["type": "lspApplyEditApplied", "conversationID": conversationID.uuidString,
                              "applied": applied])
            return ["applied": true]
        }
    }

    /// After a real CAS application the server must see the NEW native
    /// bytes (FULL sync): the authority text is the truth, the version is
    /// bumped monotonically, and the document's revision fence moves.
    private func refreshDocumentVersion(documentID: UUID, revision: String) async {
        guard var document = documents[documentID] else { return }
        document.revision = revision
        document.version += 1
        documents[documentID] = document
        do {
            let text = try await authority.fullText(taskID: conversationID, workspaceID: workspaceID,
                                                    documentID: documentID, revision: revision)
            let params: [String: Any] = [
                "textDocument": ["uri": G04LspPathMapping.uri(relativePath: document.relativePath),
                                  "version": document.version],
                "contentChanges": [["text": String(text.utf8.prefix(
                    G04LanguageServerLimits.maximumSyncedTextBytes))]],
            ]
            enqueueNotification(method: "textDocument/didChange", params: params)
        } catch {
            // The document vanished server-side; the host reopens honestly.
        }
    }

    private func emitPartial(applied: [[String: Any]], reason: String) {
        sink.emitControl([
            "type": "lspApplyEditPartial",
            "conversationID": conversationID.uuidString,
            "applied": applied, "refused": [["reason": reason]],
            "note": "alreadyAppliedDocumentsStayInNativeUndoHistory",
        ])
    }

    static func authorityCodeFor(_ error: any Error) -> String {
        if let typed = error as? G04DocumentAuthorityError { return authorityCode(typed) }
        return "authorityFailure"
    }

    // MARK: Writer helpers

    private func nextRequestID() -> Int64 {
        let id = requestCounter
        requestCounter &+= 1
        return id
    }

    private func deadline(seconds: Double) -> UInt64 {
        DispatchTime.now().uptimeNanoseconds &+ UInt64(seconds * 1_000_000_000)
    }

    private func enqueueRequest(id: Int64, method: String, params: [String: Any]) {
        enqueueObject(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
    }

    private func enqueueNotification(method: String, params: [String: Any]) {
        enqueueObject(["jsonrpc": "2.0", "method": method, "params": params])
    }

    private func enqueueReply(id: Any?, result: Any?) {
        enqueueObject(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result ?? NSNull()])
    }

    private func enqueueReplyError(id: Any?, code: Int, message: String) {
        enqueueObject(["jsonrpc": "2.0", "id": id ?? NSNull(),
                       "error": ["code": code, "message": message]])
    }

    private func enqueueObject(_ object: [String: Any]) {
        do {
            let frame = try G04LspFrameWriter.frame(object)
            guard pendingWriteBytes + frame.count <= G04LanguageServerLimits.maximumPendingWriteBytes else {
                sink.emitControl(["type": "lspWriteOverflow", "language": languageID])
                return
            }
            // Chunk into <=64 KiB writes (the exchange input bound).
            var offset = 0
            while offset < frame.count {
                let end = min(offset + G04TerminalLimits.inputWriteBytes, frame.count)
                pendingWrites.append(frame.subdata(in: offset..<end))
                offset = end
            }
            pendingWriteBytes += frame.count
        } catch {
            sink.emitControl(["type": "lspWriteRefused", "language": languageID,
                              "reason": String(describing: error)])
        }
    }

    /// Actor-side half of the applyEdit response: decode the envelope inside
    /// this actor's isolation, run the prevalidated CAS plan, and answer —
    /// the same flow that previously ran on the concurrently captured JSON
    /// objects (which region isolation forbids).
    private func answerApplyEditEnvelope(_ envelope: Data) async {
        let decoded = try? JSONSerialization.jsonObject(with: envelope) as? [String: Any]
        let idValue = decoded?["id"]
        let params = decoded?["params"]
        let result = await applyWorkspaceEdit(params)
        sendReplyObject(id: idValue, result: result)
    }

    private func sendReplyObject(id: Any?, result: Any?) {
        enqueueObject(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result ?? NSNull()])
    }

    // MARK: Mapping helpers

    private struct CompletionMapping {
        var values: [[String: Any]]
        var incomplete: Bool
        var truncated: Bool
    }

    private static func completionItems(from result: Any?) -> CompletionMapping {
        var raw: [[String: Any]] = []
        var incomplete = false
        if let list = result as? [String: Any] {
            raw = (list["items"] as? [[String: Any]]) ?? []
            incomplete = (list["isIncomplete"] as? Bool) ?? false
        } else if let array = result as? [[String: Any]] {
            raw = array
        }
        var mapped: [[String: Any]] = []
        for item in raw.prefix(G04LanguageServerLimits.maximumCompletionItems) {
            guard let label = item["label"] as? String else { continue }
            var insert = (item["insertText"] as? String) ?? label
            // Snippet insertText (format 2) is NEVER forwarded as raw
            // snippet bytes into the plain-text projection: fall back to
            // the label (the projection advertises snippetSupport:false).
            if (Self.int64(item["insertTextFormat"]) ?? 1) == 2 { insert = label }
            if let textEdit = item["textEdit"] as? [String: Any],
               (textEdit["newText"] as? String) != nil,
               Self.int64(item["insertTextFormat"]) ?? 1 == 2 {
                insert = label
            }
            mapped.append([
                "label": String(label.prefix(256)),
                "insertText": String(insert.prefix(512)),
                "kind": Self.int64(item["kind"]) ?? 0,
                "detail": (item["detail"] as? String).map { String($0.prefix(256)) } ?? "",
                "documentation": documentationText(item["documentation"]),
            ])
        }
        return CompletionMapping(values: mapped, incomplete: incomplete,
                                 truncated: raw.count > mapped.count)
    }

    private static func documentationText(_ value: Any?) -> String {
        if let string = value as? String { return String(string.prefix(512)) }
        if let object = value as? [String: Any], let value = object["value"] as? String {
            return String(value.prefix(512))
        }
        return ""
    }

    static func int64(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.int64Value
        }
        return nil
    }

    static func authorityCode(_ error: G04DocumentAuthorityError) -> String {
        switch error {
        case .retired: return "retired"
        case .ownerChanged: return "ownerChanged"
        case .missingDocument: return "missingDocument"
        case .staleRevision: return "staleRevision"
        case .invalidRange: return "invalidRange"
        case .tooLarge: return "tooLarge"
        case .backendUnavailable: return "backendUnavailable"
        case .wire(let code): return code
        }
    }
}

// MARK: - Manager (epoch-scoped, one per terminal host binding)

/// Owns the live (conversation, language) server sessions and dispatches
/// the closed LSP action grammar. Temporary chat, retired epochs and
/// unbound conversations cannot reach any session (admission is the SAME
/// ORIGINAL durable check).
public actor G04LanguageServerCenter {
    public let epoch: UInt64
    private let sink: any G04TerminalEventSink
    private var sessions: [String: G04LanguageServerSession] = [:]   // "<conversation>:<language>"
    private var retired = false

    /// The durable enabled snapshot loaded from the ORIGINAL accepted-Root
    /// settings authority (app_settings via the one DatabaseManager). nil
    /// means NOT KNOWN (no composition / failed read) — never coerced into
    /// "all persisted": availability surfaces the flag honestly.
    private(set) var settingsSnapshot: G04LanguageSettingsSnapshot?
    /// Synthetic test binding only (same precedent as the mailbox
    /// testHandler): production init always resolves the live store from
    /// the exact-epoch installed composition and never uses this slot.
    private let settingsOverride: G04LanguageSettingsStore?

    public init(epoch: UInt64, sink: any G04TerminalEventSink) {
        self.epoch = epoch; self.sink = sink; self.settingsOverride = nil
    }

    init(epoch: UInt64, sink: any G04TerminalEventSink, settingsStore: G04LanguageSettingsStore) {
        self.epoch = epoch; self.sink = sink; self.settingsOverride = settingsStore
    }

    // MARK: Durable settings (load on Root bind; honest unknown state)

    /// Resolves the settings store from the LIVE exact-epoch composition.
    /// No live Root generation => no durable read/write is attempted.
    private func liveSettingsStore() -> G04LanguageSettingsStore? {
        if let settingsOverride { return settingsOverride }
        guard let installed = G02RuntimeComposition.shared.installedComposition,
              installed.epoch == epoch else { return nil }
        return G04LanguageSettingsStore(database: installed.cluster.database)
    }

    /// One load attempt per success; a failed load is retried on the next
    /// demand (so a cold store failure cannot pin the generation into a
    /// permanently-unknown state). Applies any persisted disables to live
    /// sessions exactly once (the Root-bind effect on the real lifecycle).
    private func ensureSettingsLoaded() async {
        if settingsSnapshot != nil { return }
        guard let store = liveSettingsStore() else { return }
        guard let loaded = try? await store.load() else { return }
        settingsSnapshot = loaded
        if !loaded.disabled.isEmpty {
            for language in loaded.disabled { await retireDisabled(language) }
        }
    }

    /// Bind-time preload (mailbox calls this right after creating the
    /// generation's center): the first capabilities/ensure answer carries
    /// the persisted truth instead of racing the durable read.
    public func preloadSettings() async { await ensureSettingsLoaded() }

    /// Disabling a language settles its live servers EXPLICITLY through the
    /// session's own shutdown path (LSP shutdown/exit, then the ORIGINAL
    /// transport close — a stop REQUEST until the engine settles).
    private func retireDisabled(_ language: String) async {
        let suffix = ":" + language
        for (key, session) in sessions where key.hasSuffix(suffix) {
            await session.shutdown(reason: "language-disabled", requestID: nil)
            sessions.removeValue(forKey: key)
        }
    }

    private func rootOwnerLive() -> Bool {
        // The synthetic test binding stands in for the whole accepted Root
        // (its store is a real DatabaseManager fixture); production always
        // cross-checks the live epoch exactly like admission().
        if settingsOverride != nil { return !retired }
        return !retired && G02NativeRootEpoch.readback() == epoch
            && G02RuntimeComposition.shared.installedComposition?.epoch == epoch
    }

    private func key(conversationID: UUID, language: String) -> String {
        conversationID.uuidString + ":" + language
    }

    private func reply(_ requestID: String, ok: Bool, code: G04LspCode? = nil, reason: String? = nil,
                       extra: [String: Any] = [:]) {
        var object: [String: Any] = ["type": "actionReply", "requestID": requestID, "ok": ok]
        if let code { object["code"] = code.rawValue }
        if let reason { object["reason"] = reason }
        for (key, value) in extra { object[key] = value }
        sink.emitControl(object)
    }

    private func admission(conversationID: UUID, workspaceID expected: UUID?) async
        -> (workspaceID: UUID, rootURL: URL, authority: G04WorkspaceDocumentAuthority)? {
        guard !retired, G02NativeRootEpoch.readback() == epoch,
              let installed = G02RuntimeComposition.shared.installedComposition,
              installed.epoch == epoch else { return nil }
        guard let conversation = try? await installed.cluster.conversationStore
            .conversation(id: conversationID), conversation.purpose == .ordinary else { return nil }
        guard let binding = await LinuxWorkspaceAuthority.resolveWorkspace(conversationID: conversationID) else {
            return nil
        }
        if let expected, expected != binding.workspaceID { return nil }
        guard let authority = G04TerminalRuntimeRegistry.shared.authority(epoch: epoch) as? G04WorkspaceDocumentAuthority else {
            return nil
        }
        return (binding.workspaceID, binding.rootURL, authority)
    }

    /// Synthetic test binding ONLY (same reviewed precedent as the mailbox
    /// `testHandler`): seeds one session under the exact key so host-facing
    /// route/settlement logic can be exercised deterministically over fakes.
    /// Production never calls this; `ensureServer` remains the only path
    /// that creates sessions, and it stays behind full admission.
    internal func seedSessionForTests(_ session: G04LanguageServerSession,
                                      conversationID: UUID, language: String) {
        guard !retired else { return }
        sessions[key(conversationID: conversationID, language: language)] = session
    }

    // MARK: Actions (closed grammar)

    public func ensureServer(conversationID: UUID, workspaceID: UUID?, language: String,
                             requestID: String) async {
        guard G04LanguageServerCatalog.descriptor(for: language) != nil else {
            reply(requestID, ok: false, code: .languageUnsupported); return
        }
        await ensureSettingsLoaded()
        guard settingsSnapshot?.enabled[language] != false else {
            // The DISABLED answer comes from the PERSISTED user choice
            // (loaded on bind); an unknown snapshot never blocks a server.
            reply(requestID, ok: false, code: .languageDisabled); return
        }
        guard let admitted = await admission(conversationID: conversationID, workspaceID: workspaceID) else {
            reply(requestID, ok: false, code: .workspaceUnbound); return
        }
        guard RuntimeFacadeLinuxBindings.shared.isCapabilityQualified else {
            reply(requestID, ok: false, code: .engineUnqualified); return
        }
        let key = key(conversationID: conversationID, language: language)
        if let existing = sessions[key] {
            if await existing.isTerminal {
                // Replace a terminal server explicitly on the host's next
                // ensure (retry after a package install); a live/starting
                // server is never re-created underneath the caller.
                sessions.removeValue(forKey: key)
            } else {
                await existing.ensureStarted(requestID: requestID); return
            }
        }
        let conversationSessions = sessions.keys.filter { $0.hasPrefix(conversationID.uuidString + ":") }
        guard conversationSessions.count < G04LanguageServerLimits.maximumServersPerConversation,
              sessions.count < G04LanguageServerLimits.maximumLiveServers else {
            reply(requestID, ok: false, code: .saturated); return
        }
        let transport = G04CenterLspTransport(epoch: epoch, conversationID: conversationID,
                                              workspaceRootURL: admitted.rootURL, sink: sink)
        let session = G04LanguageServerSession(conversationID: conversationID,
                                               workspaceID: admitted.workspaceID, languageID: language,
                                               transport: transport, authority: admitted.authority, sink: sink)
        sessions[key] = session
        await session.ensureStarted(requestID: requestID)
    }

    public func route(documentAction action: String, conversationID: UUID, workspaceID: UUID?,
                      language: String, documentID: UUID, expectedRevision: String,
                      text: String?, line: Int?, character: Int?, hostRequestID: String,
                      cancelTarget: String?) async {
        guard let session = sessions[key(conversationID: conversationID, language: language)] else {
            reply(hostRequestID, ok: false, code: .serverUnavailable, reason: "noSession"); return
        }
        switch action {
        case "lspOpenDocument":
            guard let text else { reply(hostRequestID, ok: false, code: .tooLarge); return }
            await session.openDocument(documentID: documentID, expectedRevision: expectedRevision,
                                       text: text, requestID: hostRequestID)
        case "lspChangeDocument":
            guard let text else { reply(hostRequestID, ok: false, code: .tooLarge); return }
            await session.changeDocument(documentID: documentID, expectedRevision: expectedRevision,
                                         text: text, requestID: hostRequestID)
        case "lspCloseDocument":
            let closedOne = await session.closeDocument(documentID: documentID, requestID: hostRequestID)
            // Real didClose settled for the LAST synced document: shut this
            // conversation's server down explicitly through the ORIGINAL
            // shutdown/close path (engine stop REQUEST + receipt
            // settlement). A refused close (unknown document) never counts;
            // a pane reconstruction never closes a document, so this cannot
            // fire on view churn. An idle orphan must not hold the shared
            // Linux session budget after the task left.
            if closedOne, await session.holdsNoDocuments() {
                await session.shutdown(reason: "last-document-closed", requestID: nil)
                sessions.removeValue(forKey: key(conversationID: conversationID, language: language))
            }
        case "lspCompletion":
            await session.completion(documentID: documentID, expectedRevision: expectedRevision,
                                     line: line ?? -1, character: character ?? -1, requestID: hostRequestID)
        case "lspCancel":
            await session.cancel(hostRequestID: cancelTarget ?? "", requestID: hostRequestID)
        case "lspShutdown":
            await session.shutdown(reason: "explicit-shutdown", requestID: hostRequestID)
            sessions.removeValue(forKey: key(conversationID: conversationID, language: language))
        default:
            reply(hostRequestID, ok: false, reason: "unknownAction")
        }
        _ = workspaceID
    }

    /// Durable toggle: whitelist language + exact-epoch Root owner + the
    /// ORIGINAL settings authority CAS write first, RAM projection and live
    /// session lifecycle applied ONLY from the committed answer. A rejected
    /// or failed write leaves both exactly at the last persisted snapshot
    /// (root-safe rollback); nothing is ever answered ok on a failed write.
    public func setLanguageEnabled(language: String, enabled: Bool, requestID: String) async {
        guard rootOwnerLive() else {
            reply(requestID, ok: false, code: .retired, reason: "rootNotLive"); return
        }
        guard G04LanguageServerCatalog.descriptor(for: language) != nil else {
            reply(requestID, ok: false, code: .languageUnsupported, reason: "unknownLanguage"); return
        }
        await ensureSettingsLoaded()
        guard let store = liveSettingsStore() else {
            reply(requestID, ok: false, reason: "settingsUnbound"); return
        }
        let expected = settingsSnapshot?.revision ?? G04LanguageSettingsSnapshot.defaults.revision
        let next: G04LanguageSettingsSnapshot
        do {
            next = try await store.toggle(language: language, enabled: enabled, expectedRevision: expected)
        } catch let error as G04LanguageSettingsError {
            // settingsSnapshot unchanged: it still mirrors the persisted row.
            reply(requestID, ok: false, reason: error.rawValue)
            return
        } catch {
            reply(requestID, ok: false, reason: "persistenceUnavailable")
            return
        }
        settingsSnapshot = next
        reply(requestID, ok: true, extra: ["language": language, "enabled": enabled,
                                           "persisted": true, "revision": next.revision])
        if !enabled { await retireDisabled(language) }
        // Enabling never auto-starts: availability is proven by the host's
        // next explicit ensure (existing Linux/package flow + real probe).
    }

    /// ACTUAL availability surface for the trusted host: persisted user
    /// choices, the durable-read state, and the live per-language session
    /// states for the requested conversation (never catalog inference).
    /// Swift 6 region isolation: rides out of the actor as JSON `Data`
    /// (Sendable); the nonisolated host decode yields byte-identical
    /// capability fields — the same values, never a reference crossing.
    public func capabilityPayload(conversationID: UUID?) async -> Data? {
        await ensureSettingsLoaded()
        var object: [String: Any] = [
            "settingsKnown": settingsSnapshot != nil,
            "languageEnabled": (settingsSnapshot ?? .defaults).enabled,
            "settingsRevision": settingsSnapshot?.revision ?? -1,
        ]
        var states: [[String: Any]] = []
        if let conversationID {
            let prefix = conversationID.uuidString + ":"
            for (key, session) in sessions where key.hasPrefix(prefix) {
                let status = await session.currentStatus()
                states.append(["language": String(key.dropFirst(prefix.count)),
                               "state": status.state.rawValue,
                               "code": status.code ?? ""])
            }
        }
        object["serverStates"] = states
        return try? JSONSerialization.data(withJSONObject: object)
    }

    public func retireAll(reason: String) async {
        guard !retired else { return }
        retired = true
        for session in sessions.values {
            await session.shutdown(reason: reason, requestID: nil)
        }
        sessions.removeAll()
    }
}
