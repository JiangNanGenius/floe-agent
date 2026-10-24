// FloeAndroid shared/Sources/FloeBrowser — token-bound loopback preview:
// Swift-side lease identity, request adjudication and owner lifecycle.
//
// Android mirror of the iOS originals
// FloeAgent/FloeApp/Browser/LocalStaticFileServer.swift @ 3fd597b…
// (sha256 1db0c2b477e6f500365c2d954b6e05909cfcb3e17b503ae2e944991ce374ee14)
// and the preview half of LocalPreviewServer.swift (sha256 8bec3f01…).
// Decision D4 (entry/MAIN_ARCHITECTURE_DECISION_02.json): the Kotlin
// `ServerSocket` loopback listener is PURE TRANSPORT. Swift owns the exact
// task/workspace/root-epoch/session lifetime, the per-server unpredictable
// token, the admitted resource identity and every authorization decision;
// the transport never accepts a disk root or model absolute path and never
// parses paths itself for trust purposes — it forwards bounded header blocks
// here and streams only the bytes this file admits.
//
// Documented mirror deltas against LocalStaticFileServer (Apple Network is
// not portable):
//  * NWListener/NWConnection become the `BrowserPreviewTransport` port
//    (Main's Kotlin implementation) plus this actor's adjudication. Header
//    accumulation/timeout/431 bounds are enforced at the transport AND
//    re-enforced here (defense in depth; the verdict never trusts the peer).
//  * Resource existence/size/read go through `PreviewResourcePort`, backed by
//    the ORIGINAL native workspace path authority (guardResolver semantics):
//    traversal, double-decoded traversal and symlink escape fail closed in
//    the port, in addition to the identical string checks kept here.
//  * Original serving rules kept: GET/HEAD only (405 otherwise), one
//    percent-decode then exact token segment match, ".." segments and
//    backslashes rejected, 20 MiB per-file ceiling, same MIME table, HEAD
//    sends declared length with no body, 404 (never a directory listing).
//  * New explicit rules required by the Android task contract: exact Host
//    allowlist (127.0.0.1:<port>/localhost:<port>, else 400/421), bounded
//    request bookkeeping, and single-range support (206 + Content-Range;
//    unsatisfiable -> 416; multi-range/other units -> typed unsupported:
//    honest full-body 200 with Accept-Ranges advertised).

import Foundation
import FloeCore

// MARK: - Ports and shapes

/// The only root identity the preview subsystem accepts: the trusted owner
/// triple plus a workspace-RELATIVE directory. Never a disk path.
public struct PreviewWorkspaceRoot: Sendable, Codable, Hashable {
    public var owner: BrowserOwnerID
    public var relativeRoot: String

    public init(owner: BrowserOwnerID, relativeRoot: String) {
        self.owner = owner
        self.relativeRoot = relativeRoot
    }
}

public struct PreviewResourceInfo: Sendable, Codable, Hashable {
    public var byteCount: Int
    public init(byteCount: Int) { self.byteCount = byteCount }
}

/// Native workspace reads for one preview lease. Implementation is Main's
/// composition over the ORIGINAL workspace file service; it owns the final
/// path authority (a request escaping the admitted root must throw or return
/// nil/empty here — this module already rejects the syntactic forms, and the
/// port owns symlink/realpath truth).
public protocol PreviewResourcePort: Sendable {
    func isDirectory(_ root: PreviewWorkspaceRoot, relativePath: String) async throws -> Bool
    func stat(_ root: PreviewWorkspaceRoot, relativePath: String) async throws -> PreviewResourceInfo?
    func read(_ root: PreviewWorkspaceRoot, relativePath: String, offset: Int, length: Int) async throws -> Data
    func listing(_ root: PreviewWorkspaceRoot, relativePath: String) async throws -> [String]
}

/// Kotlin loopback transport half (Main implements via JNI into
/// feature/browser's LoopbackPreviewTransport).
public struct BrowserPreviewLeaseRequest: Sendable, Hashable {
    public let leaseID: UUID
    /// 32-char lowercase hex token minted by Swift before binding.
    public let token: String

    public init(leaseID: UUID, token: String) {
        self.leaseID = leaseID
        self.token = token
    }
}

public struct BrowserPreviewEndpoint: Sendable, Hashable {
    public let port: Int
    public init(port: Int) { self.port = port }
}

public enum BrowserPreviewTransportError: Error, Sendable, Equatable {
    case startFailed(String)
}

public protocol BrowserPreviewTransport: Sendable {
    /// Bind exactly 127.0.0.1 with an OS-assigned port and start accepting.
    /// All authorization for accepted connections goes back through the
    /// coordinator (`adjudicate`/`readChunk`).
    func start(lease: BrowserPreviewLeaseRequest) async throws -> BrowserPreviewEndpoint
    /// Close the listener and every owned connection; join the accept loop.
    /// Never a silent detach.
    func stop(leaseID: UUID) async
}

public struct BrowserPreviewHeader: Sendable, Codable, Hashable {
    public var name: String
    public var value: String
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// One adjudicated response. `chunk` is the first bounded body slice;
/// remaining bytes are pulled with `readChunk(requestID:offset:)`, where the
/// offset counts from the START of the admitted body slice (post-range).
public struct BrowserPreviewVerdict: Sendable, Codable, Hashable {
    public var requestID: UUID
    public var statusLine: String
    public var headers: [BrowserPreviewHeader]
    /// Total admitted body bytes for THIS response (full file length, or the
    /// satisfied range length for 206).
    public var bodyLength: Int
    /// Absolute start offset inside the admitted resource.
    public var bodyStart: Int
    /// First slice already provided.
    public var chunk: Data

    public init(
        requestID: UUID,
        statusLine: String,
        headers: [BrowserPreviewHeader],
        bodyLength: Int = 0,
        bodyStart: Int = 0,
        chunk: Data = Data()
    ) {
        self.requestID = requestID
        self.statusLine = statusLine
        self.headers = headers
        self.bodyLength = bodyLength
        self.bodyStart = bodyStart
        self.chunk = chunk
    }

    public static func error(_ requestID: UUID, _ statusLine: String) -> BrowserPreviewVerdict {
        BrowserPreviewVerdict(
            requestID: requestID,
            statusLine: statusLine,
            headers: [
                BrowserPreviewHeader(name: "Content-Type", value: "text/plain; charset=utf-8"),
                BrowserPreviewHeader(name: "Content-Length", value: "0"),
                BrowserPreviewHeader(name: "Cache-Control", value: "no-store"),
                BrowserPreviewHeader(name: "X-Content-Type-Options", value: "nosniff"),
                BrowserPreviewHeader(name: "Connection", value: "close"),
            ]
        )
    }
}

// MARK: - Per-lease adjudicator

public actor LocalPreviewServer {
    public struct Session: Sendable, Codable, Hashable {
        public let root: PreviewWorkspaceRoot
        public let entry: String
        public let url: URL
        public let token: String
        public let port: Int
        public let leaseID: UUID
    }

    struct PendingBody: Sendable {
        let relativePath: String
        let start: Int
        let length: Int
    }

    public static let maximumHeaderBytes = 64 * 1024
    public static let chunkBytes = 64 * 1024
    public static let maximumResourceBytes = 20 * 1024 * 1024
    private static let maximumPendingRequests = 64

    public nonisolated let session: Session

    private let resource: PreviewResourcePort
    private var pending: [UUID: PendingBody] = [:]
    private var pendingOrder: [UUID] = []
    private var stopped = false

    public init(session: Session, resource: PreviewResourcePort) {
        self.session = session
        self.resource = resource
    }

    /// Mint the per-server unpredictable token (32-char lowercase hex),
    /// identical strength rule to the iOS original (>=32 chars enforced by
    /// BrowserURLPolicy).
    public static func mintToken() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    public func stop() {
        stopped = true
        pending.removeAll()
        pendingOrder.removeAll()
    }

    public func adjudicate(requestID: UUID, headerBlock: Data) async -> BrowserPreviewVerdict {
        guard !stopped else {
            return .error(requestID, "404 Not Found")
        }
        // Re-enforce the transport ceiling even if the caller bypassed it.
        guard headerBlock.count <= Self.maximumHeaderBytes else {
            return .error(requestID, "431 Request Header Fields Too Large")
        }
        guard let text = String(data: headerBlock, encoding: .utf8),
              let firstLine = text.split(separator: "\r\n", maxSplits: 1).first else {
            return .error(requestID, "400 Bad Request")
        }
        let parts = firstLine.split(separator: " ")
        // A line that is not a well-formed "METHOD TARGET VERSION" request is
        // malformed (400), not a method verdict. Only a well-formed request
        // naming an unsupported method gets 405; the two statuses stay
        // distinct exactly as the adjudication contract requires.
        guard parts.count == 3 else {
            return .error(requestID, "400 Bad Request")
        }
        guard parts[0] == "GET" || parts[0] == "HEAD" else {
            return .error(requestID, "405 Method Not Allowed")
        }
        let headers = Self.parseHeaders(text)
        // Strict Host check (loopback allocation is port-bound; a foreign
        // Host can never be one of ours).
        if let host = headers["host"] {
            let allowed = ["127.0.0.1:\(session.port)", "localhost:\(session.port)"]
            guard allowed.contains(host.lowercased()) else {
                return .error(requestID, "421 Misdirected Request")
            }
        } else {
            return .error(requestID, "400 Bad Request")
        }
        let rawTarget = String(parts[1])
        guard rawTarget.hasPrefix("/"), !rawTarget.contains("://") else {
            return .error(requestID, "400 Bad Request")
        }
        let rawPath = String(rawTarget.split(separator: "?", maxSplits: 1).first ?? "")
        // Exactly ONE percent-decode (the original's rule). Double-encoded
        // traversal decodes to literal "%2e%2e" segments, which resolve to no
        // admitted resource; the native port owns the final real-path truth.
        guard let decoded = rawPath.removingPercentEncoding else {
            return .error(requestID, "400 Bad Request")
        }
        let components = decoded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard components.first == session.token else {
            return .error(requestID, "404 Not Found")
        }
        let relative = components.dropFirst().joined(separator: "/")
        guard !relative.isEmpty,
              !relative.split(separator: "/").contains(".."),
              !relative.contains("\\") else {
            return .error(requestID, "404 Not Found")
        }
        return await adjudicateBody(
            requestID: requestID,
            method: String(parts[0]),
            relative: relative,
            headers: headers
        )
    }

    private func adjudicateBody(
        requestID: UUID,
        method: String,
        relative: String,
        headers: [String: String]
    ) async -> BrowserPreviewVerdict {
        let root = PreviewWorkspaceRoot(owner: session.root.owner, relativeRoot: session.root.relativeRoot)
        guard let info = (try? await resource.stat(root, relativePath: relative)) ?? nil,
              info.byteCount >= 0,
              info.byteCount <= Self.maximumResourceBytes else {
            // Missing, unreadable or over the 20 MiB ceiling: the original's
            // honest 404 (no partial service, no listing).
            return .error(requestID, "404 Not Found")
        }
        var start = 0
        var length = info.byteCount
        var statusLine = "200 OK"
        var rangeHeaders: [BrowserPreviewHeader] = []
        if let rangeValue = headers["range"], let parsed = Self.parseSingleByteRange(rangeValue, total: info.byteCount) {
            switch parsed {
            case .satisfiable(let from, let to):
                start = from
                length = to - from + 1
                statusLine = "206 Partial Content"
                rangeHeaders = [
                    BrowserPreviewHeader(name: "Content-Range", value: "bytes \(from)-\(to)/\(info.byteCount)"),
                ]
            case .unsatisfiable:
                var verdict = BrowserPreviewVerdict.error(requestID, "416 Range Not Satisfiable")
                verdict.headers.append(BrowserPreviewHeader(name: "Content-Range", value: "bytes */\(info.byteCount)"))
                verdict.headers.append(BrowserPreviewHeader(name: "Accept-Ranges", value: "bytes"))
                return verdict
            case .unsupported:
                break // honest full-body 200 below (typed unsupported range)
            }
        }
        let mime = Self.mimeType(for: (relative as NSString).pathExtension)
        var verdict = BrowserPreviewVerdict(
            requestID: requestID,
            statusLine: statusLine,
            headers: [
                BrowserPreviewHeader(name: "Content-Type", value: mime),
                BrowserPreviewHeader(name: "Content-Length", value: String(length)),
                BrowserPreviewHeader(name: "Cache-Control", value: "no-store"),
                BrowserPreviewHeader(name: "X-Content-Type-Options", value: "nosniff"),
                BrowserPreviewHeader(name: "Accept-Ranges", value: "bytes"),
                BrowserPreviewHeader(name: "Connection", value: "close"),
            ] + rangeHeaders
        )
        // `bodyLength` is the admitted BODY budget the transport may stream
        // with chunk/readChunk, not the declared header value. HEAD keeps the
        // truthful Content-Length header above but admits zero body bytes:
        // a HEAD verdict must never hand the transport bytes to serve.
        verdict.bodyLength = method == "HEAD" ? 0 : length
        verdict.bodyStart = method == "HEAD" ? 0 : start
        if method != "HEAD", length > 0 {
            let firstCount = min(Self.chunkBytes, length)
            guard let chunk = try? await resource.read(root, relativePath: relative, offset: start, length: firstCount) else {
                // The native authority refused or failed the read (for
                // example a symlink escape discovered at open): the honest
                // answer is 404, never a 200 with a truncated or empty body.
                return .error(requestID, "404 Not Found")
            }
            verdict.chunk = chunk
            registerPending(requestID: requestID, body: PendingBody(relativePath: relative, start: start, length: length))
        }
        return verdict
    }

    /// Stream the next bounded slice of one admitted body. `offset` counts
    /// from the beginning of the admitted slice (chunk already served = 0).
    public func readChunk(requestID: UUID, offset: Int) async -> Data {
        guard !stopped, let body = pending[requestID] else { return Data() }
        guard offset >= 0, offset < body.length else {
            retire(requestID: requestID)
            return Data()
        }
        let root = PreviewWorkspaceRoot(owner: session.root.owner, relativeRoot: session.root.relativeRoot)
        let count = min(Self.chunkBytes, body.length - offset)
        guard let data = try? await resource.read(root, relativePath: body.relativePath, offset: body.start + offset, length: count) else {
            retire(requestID: requestID)
            return Data()
        }
        if offset + count >= body.length {
            retire(requestID: requestID)
        }
        return data
    }

    private func retire(requestID: UUID) {
        pending.removeValue(forKey: requestID)
        pendingOrder.removeAll { $0 == requestID }
    }

    private func registerPending(requestID: UUID, body: PendingBody) {
        pending[requestID] = body
        pendingOrder.append(requestID)
        // Bounded bookkeeping: the oldest unfinished allocations are retired
        // (their connections are already over-capacity at the transport).
        while pendingOrder.count > Self.maximumPendingRequests {
            let oldest = pendingOrder.removeFirst()
            pending.removeValue(forKey: oldest)
        }
    }

    // MARK: Parsing helpers (ported semantics)

    static func parseHeaders(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let lines = text.split(separator: "\r\n", omittingEmptySubsequences: true)
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty, result[name] == nil { result[name] = value }
        }
        return result
    }

    enum SingleRange: Equatable {
        case satisfiable(Int, Int)
        case unsatisfiable
        case unsupported
    }

    static func parseSingleByteRange(_ value: String, total: Int) -> SingleRange? {
        guard value.hasPrefix("bytes=") else { return .unsupported }
        let spec = String(value.dropFirst("bytes=".count))
        let pieces = spec.split(separator: ",", omittingEmptySubsequences: false)
        guard pieces.count == 1 else { return .unsupported } // multi-range: typed unsupported
        let range = String(pieces[0])
        guard let dash = range.firstIndex(of: "-") else { return nil }
        let startText = String(range[..<dash])
        let endText = String(range[range.index(after: dash)...])
        if startText.isEmpty {
            // suffix range: last N bytes
            guard let suffix = Int(endText), suffix > 0 else { return .unsatisfiable }
            guard total > 0 else { return .unsatisfiable }
            let from = max(0, total - suffix)
            return .satisfiable(from, total - 1)
        }
        guard let from = Int(startText), from >= 0 else { return .unsatisfiable }
        guard from < total else { return .unsatisfiable }
        if endText.isEmpty {
            return .satisfiable(from, total - 1)
        }
        guard let to = Int(endText), to >= from else { return .unsatisfiable }
        return .satisfiable(from, min(to, total - 1))
    }

    /// MIME table ported verbatim from the iOS original.
    public static func mimeType(for extensionName: String) -> String {
        switch extensionName.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "json", "map": return "application/json; charset=utf-8"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "svg": return "image/svg+xml"
        case "webp": return "image/webp"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "wasm": return "application/wasm"
        default: return "application/octet-stream"
        }
    }
}
