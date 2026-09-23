// FloeWorkspace — optional guest → host archive bridge (host half).
//
// The guest runner can offer a `floe-host archive …` command so software
// inside a Linux environment can delegate archive work to the host's native
// engine instead of depending on guest packages. The bridge is deliberately
// small and boring:
//
//   * capability negotiation: the host advertises the action set it will
//     serve; an unadvertised action is refused, never silently downgraded.
//   * connection authorization: one bridge instance is bound to exactly one
//     environment and one live control-channel token. A message from another
//     token, or for a path outside that environment's declared 9p shares, is
//     refused without touching the filesystem.
//   * small control messages only: request and reply stay within a bounded
//     single line. File bytes live in the shared directory; `list` writes its
//     listing into the share and returns the path, so a large listing never
//     flows through the console.
//   * independent host scheduling: the handler performs pure host filesystem
//     work through `ArchiveEngine`. It never acquires a VM/pool slot, so a
//     guest blocked on a reply cannot deadlock against its own admission.

import Foundation
import FloeCore
import FloeTools

/// Guest→host path mapping for one environment's declared 9p shares.
/// Implemented by the app layer with the environment's real share table.
public protocol HostArchivePathMapping: Sendable {
    /// Host URL for a guest path inside a declared share, nil otherwise.
    func hostURL(forGuestPath path: String) -> URL?
    /// Guest path for a host path inside a declared share, nil otherwise.
    func guestPath(forHostPath path: String) -> String?
}

/// Actions the host can serve. Advertised through `FLOE-HELLO archive=…`.
public enum HostArchiveCapability: String, CaseIterable, Sendable, Hashable {
    case create
    case extract
    case list
    case decompress

    public static func parse(_ value: String) -> Set<HostArchiveCapability> {
        var result: Set<HostArchiveCapability> = []
        for piece in value.split(separator: ",") {
            let trimmed = piece.trimmingCharacters(in: .whitespaces).lowercased()
            if trimmed == "archive" {
                return Set(allCases)
            }
            if let capability = HostArchiveCapability(rawValue: trimmed) {
                result.insert(capability)
            }
        }
        return result
    }

    /// Canonical advertised string (`create,extract,list,decompress` order).
    public static func wireValue(_ capabilities: Set<HostArchiveCapability>) -> String {
        allCases.filter { capabilities.contains($0) }.map(\.rawValue).joined(separator: ",")
    }
}

public struct HostArchiveRequest: Sendable, Equatable {
    public var action: HostArchiveCapability
    public var format: String
    public var source: String
    public var destination: String?

    public init(action: HostArchiveCapability, format: String, source: String, destination: String? = nil) {
        self.action = action
        self.format = format
        self.source = source
        self.destination = destination
    }
}

/// Bounded single-line encoding of the request and its reply.
public enum HostArchiveProtocol {
    public static let maxPayloadBytes = 2048

    public static func encode(_ request: HostArchiveRequest, token: String) -> String {
        var parts = ["v1", "token=\(percentEncode(token))", "action=\(request.action.rawValue)",
                     "format=\(percentEncode(request.format))", "source=\(percentEncode(request.source))"]
        if let destination = request.destination {
            parts.append("destination=\(percentEncode(destination))")
        }
        return parts.joined(separator: " ")
    }

    public static func decode(_ payload: String) throws -> (token: String, request: HostArchiveRequest) {
        guard payload.utf8.count <= maxPayloadBytes else {
            throw HostArchiveBridgeError.payloadTooLarge
        }
        var fields: [String: String] = [:]
        for piece in payload.split(separator: " ", omittingEmptySubsequences: true) {
            guard let equals = piece.firstIndex(of: "=") else { continue }
            let key = String(piece[..<equals])
            let value = String(piece[piece.index(after: equals)...])
            fields[key] = percentDecode(value)
        }
        guard payload == "v1" || payload.hasPrefix("v1 ") else {
            throw HostArchiveBridgeError.malformed("missing protocol version")
        }
        guard let token = fields["token"], !token.isEmpty, token.utf8.count <= 128 else {
            throw HostArchiveBridgeError.malformed("missing or oversized token")
        }
        guard let actionRaw = fields["action"], let action = HostArchiveCapability(rawValue: actionRaw) else {
            throw HostArchiveBridgeError.malformed("unknown action")
        }
        guard let format = fields["format"], !format.isEmpty, format.utf8.count <= 16 else {
            throw HostArchiveBridgeError.malformed("missing format")
        }
        guard let source = fields["source"], !source.isEmpty else {
            throw HostArchiveBridgeError.malformed("missing source")
        }
        let destination = fields["destination"]
        return (token, HostArchiveRequest(action: action, format: format, source: source, destination: destination))
    }

    private static func percentEncode(_ value: String) -> String {
        var out = ""
        for byte in value.utf8 {
            switch byte {
            case 0x41...0x5A, 0x61...0x7A, 0x30...0x39, 0x2D, 0x2E, 0x5F, 0x2F, 0x7E:
                out.append(Character(UnicodeScalar(byte)))
            default:
                out += String(format: "%%%02X", byte)
            }
        }
        return out
    }

    private static func percentDecode(_ value: String) -> String {
        var bytes: [UInt8] = []
        var iterator = Array(value.utf8)
        var index = 0
        while index < iterator.count {
            let byte = iterator[index]
            if byte == 0x25, index + 2 < iterator.count,
               let high = hexValue(iterator[index + 1]), let low = hexValue(iterator[index + 2]) {
                bytes.append(high << 4 | low)
                index += 3
            } else {
                bytes.append(byte)
                index += 1
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func hexValue(_ byte: UInt8) -> UInt8? {
        switch byte {
        case 0x30...0x39: return byte - 0x30
        case 0x41...0x46: return byte - 0x41 + 10
        case 0x61...0x66: return byte - 0x61 + 10
        default: return nil
        }
    }
}

public struct HostArchiveReply: Sendable, Equatable {
    public var ok: Bool
    public var action: HostArchiveCapability?
    public var format: String?
    public var entries: Int?
    public var bytes: Int64?
    /// Guest path of the produced output, staging listing or error detail.
    public var path: String?
    public var code: String?
    public var detail: String?

    public static func success(
        action: HostArchiveCapability,
        format: String,
        entries: Int,
        bytes: Int64,
        path: String?
    ) -> HostArchiveReply {
        HostArchiveReply(ok: true, action: action, format: format, entries: entries, bytes: bytes, path: path)
    }

    public static func failure(code: String, detail: String) -> HostArchiveReply {
        HostArchiveReply(ok: false, code: code, detail: detail)
    }

    public func encoded() -> String {
        var parts = [ok ? "status=ok" : "status=error"]
        if let code { parts.append("code=\(code)") }
        if let action { parts.append("action=\(action.rawValue)") }
        if let format { parts.append("format=\(format)") }
        if let entries { parts.append("entries=\(entries)") }
        if let bytes { parts.append("bytes=\(bytes)") }
        if let path { parts.append("path=\(path)") }
        if let detail {
            parts.append("detail=\(detail.replacingOccurrences(of: "\n", with: " ").prefix(300))")
        }
        return parts.joined(separator: " ")
    }
}

public enum HostArchiveBridgeError: Error, Equatable {
    case malformed(String)
    case payloadTooLarge
    case tokenMismatch
    case unsupportedAction(String)
    case pathOutsideShare(String)
    case environmentMismatch

    public var code: String {
        switch self {
        case .malformed: return "malformed"
        case .payloadTooLarge: return "payload-too-large"
        case .tokenMismatch: return "token-mismatch"
        case .unsupportedAction: return "unsupported-action"
        case .pathOutsideShare: return "path-outside-share"
        case .environmentMismatch: return "environment-mismatch"
        }
    }

    public var message: String {
        switch self {
        case .malformed(let detail): return detail
        case .payloadTooLarge: return "control message exceeds \(HostArchiveProtocol.maxPayloadBytes) bytes"
        case .tokenMismatch: return "control token does not match this environment connection"
        case .unsupportedAction(let action): return "action \(action) was not negotiated with the guest"
        case .pathOutsideShare(let path): return "path is outside this environment's shared directories: \(path)"
        case .environmentMismatch: return "request belongs to a different environment"
        }
    }
}

/// Serves bounded `floe-host archive …` requests for one environment.
public final class HostArchiveBridge: @unchecked Sendable {
    public let environmentID: String
    private let token: String
    private let capabilities: Set<HostArchiveCapability>
    private let mapping: HostArchivePathMapping
    private let limits: ArchiveLimits
    private let listingDirectoryName: String
    /// Serializes archive work for this environment without involving the VM
    /// pool: host archive operations never wait for a guest slot.
    private let workLock = NSLock()

    public init(
        environmentID: String,
        token: String,
        capabilities: Set<HostArchiveCapability>,
        mapping: HostArchivePathMapping,
        limits: ArchiveLimits = ArchiveLimits(),
        listingDirectoryName: String = ".floe-host-archive"
    ) {
        self.environmentID = environmentID
        self.token = token
        self.capabilities = capabilities
        self.mapping = mapping
        self.limits = limits
        self.listingDirectoryName = listingDirectoryName
    }

    /// The capability string the host advertises for this environment.
    public var advertisedCapabilities: String {
        HostArchiveCapability.wireValue(capabilities)
    }

    /// Handles one small control message and returns a small reply. File bytes
    /// stay in the shared directory; the reply names paths and counts only.
    /// The work runs detached from the caller, so a guest waiting for the
    /// reply cannot block the console seam or a pool slot.
    public func handle(_ payload: String, cancellation: CancellationToken = CancellationToken()) async -> String {
        let reply: HostArchiveReply
        do {
            let decoded = try HostArchiveProtocol.decode(payload)
            guard decoded.token == token else { throw HostArchiveBridgeError.tokenMismatch }
            reply = try await Task.detached(priority: .utility) { [self] in
                try process(decoded.request, cancellation: cancellation)
            }.value
        } catch let error as HostArchiveBridgeError {
            reply = .failure(code: error.code, detail: error.message)
        } catch let error as ArchiveEngineError {
            reply = .failure(code: "archive-error", detail: error.localizedDescription)
        } catch let error as WorkspaceToolError {
            reply = .failure(code: "workspace-error", detail: error.localizedDescription)
        } catch {
            reply = .failure(code: "internal", detail: "\(error)")
        }
        return reply.encoded()
    }

    // MARK: - internals

    private func process(_ request: HostArchiveRequest, cancellation: CancellationToken) throws -> HostArchiveReply {
        guard capabilities.contains(request.action) else {
            throw HostArchiveBridgeError.unsupportedAction(request.action.rawValue)
        }
        let sourceURL = try requireInsideShare(request.source)
        let destinationURL = try request.destination.map { try requireInsideShare($0) }

        switch request.action {
        case .create:
            guard destinationURL != nil else {
                throw HostArchiveBridgeError.malformed("create requires a destination path")
            }
            guard ["zip", "tar", "tgz", "tbz2", "txz", "gz", "bz2", "xz"].contains(request.format) else {
                throw HostArchiveBridgeError.unsupportedAction("create \(request.format)")
            }
            let summary = try locked {
                try ArchiveEngine.create(
                    format: request.format,
                    sources: [sourceURL],
                    destination: destinationURL!,
                    limits: limits,
                    cancellation: cancellation
                )
            }
            return .success(action: .create, format: request.format, entries: summary.entries,
                            bytes: summary.uncompressedBytes, path: request.destination)
        case .extract:
            guard destinationURL != nil else {
                throw HostArchiveBridgeError.malformed("extract requires a destination path")
            }
            guard ArchiveEngine.containerFormats.contains(request.format) else {
                throw HostArchiveBridgeError.unsupportedAction("extract \(request.format)")
            }
            let summary = try locked {
                try ArchiveEngine.extract(
                    format: request.format,
                    source: sourceURL,
                    destination: destinationURL!,
                    limits: limits,
                    cancellation: cancellation
                )
            }
            return .success(action: .extract, format: request.format, entries: summary.entries,
                            bytes: summary.uncompressedBytes, path: request.destination)
        case .decompress:
            guard destinationURL != nil else {
                throw HostArchiveBridgeError.malformed("decompress requires a destination path")
            }
            guard ArchiveEngine.singleFileFormats.contains(request.format) else {
                throw HostArchiveBridgeError.unsupportedAction("decompress \(request.format)")
            }
            let summary = try locked {
                try ArchiveEngine.decompress(
                    format: request.format,
                    source: sourceURL,
                    destination: destinationURL!,
                    limits: limits,
                    cancellation: cancellation
                )
            }
            return .success(action: .decompress, format: request.format, entries: summary.entries,
                            bytes: summary.uncompressedBytes, path: request.destination)
        case .list:
            guard ArchiveEngine.containerFormats.contains(request.format) || ArchiveEngine.singleFileFormats.contains(request.format) else {
                throw HostArchiveBridgeError.unsupportedAction("list \(request.format)")
            }
            let listing = try locked {
                try ArchiveEngine.list(format: request.format, source: sourceURL, limits: limits, cancellation: cancellation)
            }
            let text = listing.entries.map { "\($0.isDirectory ? "dir" : "file")\t\($0.size)\t\($0.path)" }
                .joined(separator: "\n") + "\n"
            let listingURL = try writeListing(text, beside: sourceURL)
            guard let guestListing = mapping.guestPath(forHostPath: listingURL.path) else {
                throw HostArchiveBridgeError.pathOutsideShare(listingURL.path)
            }
            return HostArchiveReply(
                ok: true,
                action: .list,
                format: request.format,
                entries: listing.entries.count,
                bytes: Int64(text.utf8.count),
                path: guestListing
            )
        }
    }

    private func requireInsideShare(_ guestPath: String) throws -> URL {
        guard guestPath.hasPrefix("/"), !guestPath.contains(".."), !guestPath.contains("\u{0}") else {
            throw HostArchiveBridgeError.pathOutsideShare(guestPath)
        }
        guard let url = mapping.hostURL(forGuestPath: guestPath) else {
            throw HostArchiveBridgeError.pathOutsideShare(guestPath)
        }
        return url
    }

    private func writeListing(_ text: String, beside source: URL) throws -> URL {
        let directory = source.deletingLastPathComponent().appendingPathComponent(listingDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("listing-\(UUID().uuidString).txt")
        try Data(text.utf8).write(to: url, options: .atomic)
        return url
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        workLock.lock()
        defer { workLock.unlock() }
        return try body()
    }
}
