// SPDX-License-Identifier: MPL-2.0
//
// GitHubActionsArtifactStreaming — Android-owned service download seam for
// GitHub Actions artifacts and job logs (lane job-6cb7731a07774f01, G04-R1).
//
// The mirrored iOS `GitHubActionsClient.downloadArtifact` stays byte-identical
// in GitHubActionsService.swift. On the swift-corelibs (FoundationNetworking)
// transport its bounded branch falls back to a full-buffered `data(for:)`
// fetch, and `boundedText` reports a log larger than the cap as
// `responseTooLarge` instead of Apple's truncated slice. That is upstream's
// own Linux-branch behavior — a safe fallback, but not what Android product
// rules allow for LONG work: downloads must be incremental, bounded with
// EARLY cancellation at the cap, cooperative-cancellation aware,
// service-owned (never bound to a view), and staged-then-hash-verified into
// the trusted caller workspace. This file provides exactly that on the
// qualified `FloeTransport` streaming seam (job-ca18980891c043b5), keeping
// every security rule of the original client:
//
//   * HTTPS only; the bearer token is attached only to the configured API
//     origin and is stripped by the SAME `GitHubActionsRedirectGuard` when a
//     signed redirect moves cross-host to blob storage (and non-HTTPS
//     destinations are refused outright);
//   * responses are size-bounded from the declared `Content-Length`, the
//     API-reported artifact size, and observed stream bytes — the owned task
//     is cancelled the moment the cap is crossed, never after full buffer;
//   * a body that ends short of its declared length is a typed failure
//     (`.truncated`), never success with partial bytes;
//   * bytes land in a unique `.part` staging file in the destination
//     directory, are SHA-256 hashed incrementally while streaming, and are
//     verified against GitHub's `sha256:<hex>` attestation BEFORE the atomic
//     commit rename when one exists (mismatch deletes the staging file and
//     throws `.digestMismatch`; a previously committed file is left
//     untouched). A digest GitHub never attested keeps `serverAttested ==
//     false` — checksum-only is never presented as verified (same honesty
//     rule as the iOS artifact model);
//   * the final path is workspace-relative only (no absolute paths, no `..`
//     segments, nothing under `.git`), contained under the explicitly
//     supplied TRUSTED root that only Main's workspace resolution may
//     provide, and an existing final file is refused (`.destinationExists`)
//     instead of silently overwritten;
//   * error text is redacted against the token exactly like the original
//     client.
//
// BackgroundJobService ownership (Main integration, not implemented here):
// `progress` and `isCancellationRequested` are the adapter interface for a
// `NativeJobServiceAdapter`/`NativeJobPreparedOperation` binding — the durable
// job record owns the task; this actor only runs the owned byte work and
// honors cooperative cancellation without ever outliving `finish()`.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
#if canImport(Android)
// Bionic POSIX surface (`stat`) — documented platform delta mirroring the
// proven FloeCore pattern; Apple builds keep Foundation's Darwin overlay.
import Android
#endif
import Crypto
import FloeTransport

public enum GitHubActionsStreamingError: Error, Equatable, Sendable, LocalizedError {
    case invalidConfiguration(String)
    case transport(String)
    case http(status: Int, message: String)
    case responseTooLarge(limit: Int)
    /// The server declared N bytes and delivered fewer: partial output is
    /// never committed or reported as success.
    case truncated(declaredBytes: Int64, receivedBytes: Int)
    case expiredArtifact(name: String)
    case digestMismatch(serverDigest: String, computedSHA256: String)
    case invalidRelativePath(String)
    case destinationEscapesWorkspace(String)
    case destinationExists(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail): return "GitHub Actions download is not configured: \(detail)"
        case .transport(let detail): return "GitHub Actions download network error: \(detail)"
        case .http(let status, let message): return "GitHub Actions download failed (\(status)): \(message)"
        case .responseTooLarge(let limit): return "GitHub Actions download exceeded the \(limit) byte limit"
        case .truncated(let declared, let received):
            return "GitHub Actions download ended early (\(received) of \(declared) bytes); nothing was committed"
        case .expiredArtifact(let name): return "The GitHub Actions artifact \"\(name)\" has expired"
        case .digestMismatch(let server, let computed):
            return "GitHub Actions artifact digest mismatch (server \(server), computed \(computed)); bytes discarded"
        case .invalidRelativePath(let path):
            return "Artifact destination path must be workspace-relative without \"..\" or \".git\": \(path)"
        case .destinationEscapesWorkspace(let path): return "Artifact destination escapes the trusted workspace: \(path)"
        case .destinationExists(let path): return "Artifact destination already exists: \(path)"
        case .cancelled: return "GitHub Actions download was cancelled"
        }
    }
}

/// Outcome of one staged artifact download.
public struct GitHubActionsStagedArtifact: Sendable, Equatable {
    /// Final committed location under the trusted root.
    public let fileURL: URL
    public let byteCount: Int
    /// Lowercase hex SHA-256 of every committed byte (computed while
    /// streaming; the staging file is owned by this operation only).
    public let sha256: String
    /// True ONLY when GitHub's API carried a `sha256:` attestation that the
    /// local digest matched. False means checksum-only — integrity is locally
    /// computed, not server-attested (mirrors the iOS artifact `digest` rule).
    public let serverAttested: Bool
    /// The host the signed blob ultimately came from; never carries the
    /// bearer token.
    public let sourceHost: String
    public let suggestedFileName: String

    public init(fileURL: URL, byteCount: Int, sha256: String, serverAttested: Bool,
                sourceHost: String, suggestedFileName: String) {
        self.fileURL = fileURL; self.byteCount = byteCount; self.sha256 = sha256
        self.serverAttested = serverAttested; self.sourceHost = sourceHost
        self.suggestedFileName = suggestedFileName
    }
}

/// Service-owned streaming downloader. Construct once per owned operation;
/// `finish()` releases the streaming session (the caller keeps ownership,
/// exactly as `StreamingTransport.makeSession` documents).
public actor GitHubActionsArtifactStreamer {
    private let session: URLSession
    private let baseURL: URL
    /// Buffered ceiling handed to the transport relay per read window; body
    /// memory stays bounded regardless of `maxBytes` because chunks are
    /// written straight to the staging file as they arrive.
    private static let relayWindowBytes = 1024 * 1024

    public init(
        baseURL: URL = URL(string: "https://api.github.com/")!,
        configuration: URLSessionConfiguration = .ephemeral
    ) {
        self.baseURL = baseURL
        // The SAME redirect guard the mirrored iOS client uses for its
        // guarded sessions is installed as the streaming session's policy
        // delegate: FloeTransport forwards every redirection AND authentication
        // callback to it (it never silently replaces the caller's policy), so
        // cross-host forwards lose `Authorization` and non-HTTPS destinations
        // are refused — identically to Apple's per-task delegate path.
        self.session = StreamingTransport.makeSession(
            configuration: configuration,
            policyDelegate: GitHubActionsRedirectGuard()
        )
    }

    /// Invalidate the owned session; the router fences every pending sink.
    public func finish() {
        session.finishTasksAndInvalidate()
    }

    // MARK: - Artifact staging

    /// Streams one artifact archive into `relativeDirectory` under the
    /// explicitly trusted workspace root with staged write + digest check.
    /// `root` must come from Main's resolved workspace ownership — never from
    /// model JSON, a temp guess or the first repository found.
    public func stage(
        artifact: GitHubActionsArtifact,
        token: String,
        intoTrustedRoot root: URL,
        relativeDirectory: String,
        maxBytes: Int = GitHubActionsClient.maximumArtifactBytes,
        progress: (@Sendable (_ receivedBytes: Int) -> Void)? = nil,
        isCancellationRequested: @escaping @Sendable () -> Bool = { false }
    ) async throws -> GitHubActionsStagedArtifact {
        guard artifact.archiveDownloadURL.scheme?.lowercased() == "https" else {
            throw GitHubActionsStreamingError.invalidConfiguration("artifact download URL must be HTTPS")
        }
        if artifact.expired {
            throw GitHubActionsStreamingError.expiredArtifact(name: artifact.name)
        }
        if artifact.sizeInBytes > Int64(maxBytes) {
            throw GitHubActionsStreamingError.responseTooLarge(limit: maxBytes)
        }
        let directory = try Self.validated(relativeDirectory: relativeDirectory)
        let fileName = Self.suggestedArtifactName(id: artifact.id, name: artifact.name)

        let rootURL = root.standardizedFileURL
        guard rootURL.isFileURL, !rootURL.path.isEmpty else {
            throw GitHubActionsStreamingError.invalidConfiguration("trusted root must be a local file URL")
        }
        let targetDirectory = rootURL.appendingPathComponent(directory, isDirectory: true).standardizedFileURL
        let finalURL = targetDirectory.appendingPathComponent(fileName)
        guard finalURL.path.hasPrefix(rootURL.path + "/") else {
            throw GitHubActionsStreamingError.destinationEscapesWorkspace(directory)
        }
        var finalInfo = stat()
        if stat(finalURL.path, &finalInfo) == 0 {
            throw GitHubActionsStreamingError.destinationExists(finalURL.path)
        }
        // Unique per-attempt staging name in the SAME directory (same
        // filesystem ⇒ the commit rename below stays atomic).
        let stagingURL = targetDirectory.appendingPathComponent(
            ".\(fileName)-\(UUID().uuidString.prefix(8)).part"
        )
        let streamed: (byteCount: Int, sha256: String, serverAttested: Bool, sourceHost: String)
        do {
            streamed = try await streamToStaging(
                artifact: artifact, token: token,
                stagingURL: stagingURL, maxBytes: maxBytes,
                progress: progress, isCancellationRequested: isCancellationRequested
            )
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw error
        }
        // Commit only verified, complete bytes.
        do {
            try FileManager.default.moveItem(at: stagingURL, to: finalURL)
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            throw GitHubActionsStreamingError.invalidConfiguration(
                "artifact commit failed: \(error.localizedDescription)"
            )
        }
        return GitHubActionsStagedArtifact(
            fileURL: finalURL, byteCount: streamed.byteCount, sha256: streamed.sha256,
            serverAttested: streamed.serverAttested, sourceHost: streamed.sourceHost,
            suggestedFileName: fileName
        )
    }

    /// Byte-level streaming worker. `internal` (not `private`) ONLY so the
    /// `@testable` loopback suite can drive it with a synthetic localhost
    /// endpoint while the public `stage(...)` entry keeps enforcing the
    /// HTTPS / expiry / declared-size / destination rules before reaching
    /// any socket. Production callers use `stage`.
    func streamToStaging(
        artifact: GitHubActionsArtifact, token: String,
        stagingURL: URL, maxBytes: Int,
        progress: (@Sendable (Int) -> Void)?,
        isCancellationRequested: @escaping @Sendable () -> Bool
    ) async throws -> (byteCount: Int, sha256: String, serverAttested: Bool, sourceHost: String) {
        var request = URLRequest(url: artifact.archiveDownloadURL)
        request.timeoutInterval = 120
        // Foreground recovery must revalidate instead of replaying a cached
        // response (same rule as the original client's request builder).
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Same-origin rule preserved from `downloadArtifact`: the bearer
        // token rides only to the configured API host; a caller-supplied
        // foreign archive host is fetched uncredentialed (and the redirect
        // guard strips it if a response redirects again).
        if artifact.archiveDownloadURL.host?.lowercased() == baseURL.host?.lowercased() {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.setValue("FloeAgent", forHTTPHeaderField: "User-Agent")

        let stream: IncrementalByteStream
        do {
            stream = try StreamingTransport.stream(
                request, via: session, maxBufferedBytes: Self.relayWindowBytes)
        } catch let error as IncrementalTransportError {
            throw GitHubActionsStreamingError.transport(redact(String(describing: error), token: token))
        }

        let http: HTTPURLResponse
        do {
            http = try await stream.httpResponse()
        } catch let error as IncrementalTransportError {
            throw GitHubActionsStreamingError.transport(redact(String(describing: error), token: token))
        } catch {
            throw GitHubActionsStreamingError.transport(redact(error.localizedDescription, token: token))
        }
        guard (200..<300).contains(http.statusCode) else {
            stream.cancelOwned()
            let message = HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw GitHubActionsStreamingError.http(
                status: http.statusCode, message: redact(message, token: token))
        }
        if http.expectedContentLength > 0, http.expectedContentLength > Int64(maxBytes) {
            stream.cancelOwned()
            throw GitHubActionsStreamingError.responseTooLarge(limit: maxBytes)
        }

        FileManager.default.createFile(atPath: stagingURL.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: stagingURL) else {
            throw GitHubActionsStreamingError.invalidConfiguration("artifact staging file could not be opened")
        }
        defer { try? handle.close() }

        var hasher = SHA256()
        var received = 0
        do {
            for try await chunk in stream {
                if Task.isCancelled || isCancellationRequested() {
                    stream.cancelOwned()
                    throw GitHubActionsStreamingError.cancelled
                }
                if received + chunk.count > maxBytes {
                    // Early hard stop at the cap (mirrors the Apple branch's
                    // byte-loop guard; the transport cancels the owned task).
                    stream.cancelOwned()
                    throw GitHubActionsStreamingError.responseTooLarge(limit: maxBytes)
                }
                try handle.write(contentsOf: chunk)
                hasher.update(data: chunk)
                received += chunk.count
                progress?(received)
            }
        } catch let error as GitHubActionsStreamingError {
            throw error
        } catch is CancellationError {
            stream.cancelOwned()
            throw GitHubActionsStreamingError.cancelled
        } catch let error as IncrementalTransportError {
            throw GitHubActionsStreamingError.transport(redact(String(describing: error), token: token))
        } catch {
            throw GitHubActionsStreamingError.transport(redact(error.localizedDescription, token: token))
        }
        if http.expectedContentLength > 0, Int64(received) != http.expectedContentLength {
            throw GitHubActionsStreamingError.truncated(
                declaredBytes: http.expectedContentLength, receivedBytes: received)
        }
        // Platform reality update (G04-R1 host cohort, build-132430.log:842):
        // swift-corelibs Foundation declares `synchronize()` as throws and
        // the macOS 27 SDK (Xcode 27.1) now declares Apple's
        // FileHandle.synchronize() as throws too, so ONE throwing call is
        // correct on both platforms. The enclosing `throws` seam propagates
        // the real sync failure instead of swallowing it, so the
        // atomic-commit contract is unchanged — a failed flush still aborts
        // promotion to the final path on Android exactly as before.
        try handle.synchronize()

        let digest = hasher.finalize()
        let computed = digest.map { String(format: "%02x", $0) }.joined()
        var serverAttested = false
        if let attestation = artifact.digest {
            let parts = attestation.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else {
                throw GitHubActionsStreamingError.invalidConfiguration(
                    "artifact digest is not a `sha256:<hex>` attestation")
            }
            guard parts[0].lowercased() == "sha256" else {
                // An unknown attestation algorithm must not be downgraded to
                // "checksum-only" silently: honoring it would fake a match
                // GitHub never provided; ignoring it would drop an attestation
                // that IS present. Fail typed and discard the bytes.
                throw GitHubActionsStreamingError.invalidConfiguration(
                    "unsupported artifact digest algorithm \"\(parts[0])\"")
            }
            let server = parts[1].lowercased()
            if server != computed {
                throw GitHubActionsStreamingError.digestMismatch(serverDigest: server, computedSHA256: computed)
            }
            serverAttested = true
        }
        let host = artifact.archiveDownloadURL.host?.lowercased() ?? baseURL.host?.lowercased() ?? ""
        return (byteCount: received, sha256: computed, serverAttested: serverAttested, sourceHost: host)
    }

    // MARK: - Job logs with honest truncation

    /// Android-equivalent of the Apple `boundedText` behavior for job logs:
    /// reads AT the cap, stops early and reports `truncated` instead of
    /// failing the whole view on an oversized log (restores the iOS-visible
    /// semantics that the mirrored client's corelibs branch documents as a
    /// fallback limitation — the mirror itself stays untouched).
    public func boundedLogSlice(
        owner: String, repository: String, jobID: Int64, token: String,
        maxBytes: Int = GitHubActionsClient.maximumLogBytes,
        isCancellationRequested: @escaping @Sendable () -> Bool = { false }
    ) async throws -> GitHubActionsLogSlice {
        let path = "repos/\(Self.escaped(owner))/\(Self.escaped(repository))/actions/jobs/\(jobID)/logs"
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL,
              url.host?.lowercased() == baseURL.host?.lowercased(),
              url.scheme?.lowercased() == "https" else {
            throw GitHubActionsStreamingError.invalidConfiguration("invalid GitHub API path")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("FloeAgent", forHTTPHeaderField: "User-Agent")

        let stream: IncrementalByteStream
        do {
            stream = try StreamingTransport.stream(
                request, via: session, maxBufferedBytes: Self.relayWindowBytes)
        } catch let error as IncrementalTransportError {
            throw GitHubActionsStreamingError.transport(redact(String(describing: error), token: token))
        }
        let http: HTTPURLResponse
        do {
            http = try await stream.httpResponse()
        } catch let error as IncrementalTransportError {
            throw GitHubActionsStreamingError.transport(redact(String(describing: error), token: token))
        } catch {
            throw GitHubActionsStreamingError.transport(redact(error.localizedDescription, token: token))
        }
        guard (200..<300).contains(http.statusCode) else {
            stream.cancelOwned()
            throw GitHubActionsStreamingError.http(
                status: http.statusCode,
                message: redact(HTTPURLResponse.localizedString(forStatusCode: http.statusCode), token: token))
        }
        var data = Data()
        data.reserveCapacity(min(maxBytes, 64 * 1024))
        var truncated = false
        do {
            for try await chunk in stream {
                if Task.isCancelled || isCancellationRequested() {
                    stream.cancelOwned()
                    throw GitHubActionsStreamingError.cancelled
                }
                let room = maxBytes - data.count
                if room <= 0 || chunk.count > room {
                    if chunk.count > room { data.append(chunk.prefix(Swift.max(room, 0))) }
                    truncated = true
                    stream.cancelOwned()
                    break
                }
                data.append(chunk)
            }
        } catch let error as GitHubActionsStreamingError {
            throw error
        } catch is CancellationError {
            stream.cancelOwned()
            throw GitHubActionsStreamingError.cancelled
        } catch let error as IncrementalTransportError {
            throw GitHubActionsStreamingError.transport(redact(String(describing: error), token: token))
        } catch {
            throw GitHubActionsStreamingError.transport(redact(error.localizedDescription, token: token))
        }
        return GitHubActionsLogSlice(
            text: String(decoding: data, as: UTF8.self),
            truncated: truncated, byteCount: data.count)
    }

    // MARK: - Shared rules

    /// Workspace-relative destination rule with the same shape as
    /// `LocalGitService.validRelativePath` (private to that type, so it is
    /// restated here rather than weakened): no absolute paths, no `..`
    /// segments, no drive into `.git`, backslashes normalized.
    nonisolated static func validated(relativeDirectory: String) throws -> String {
        let value = relativeDirectory
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // The component checks mirror the ORIGINAL workspace commit guard
        // (FloeAgent/Sources/FloeWorkspace/WorkspacePathGuard.swift:126-128
        // rejects a `.git` component at ANY depth, not only as the first
        // segment). Host cohort evidence: an interior `x/.git/y` previously
        // passed this port's stricter-than-original-prefix spelling.
        let components = value.split(separator: "/")
        guard !value.isEmpty, !value.hasPrefix("/"),
              !components.contains(".."), !components.contains(".git") else {
            throw GitHubActionsStreamingError.invalidRelativePath(relativeDirectory)
        }
        return value
    }

    /// Path-segment escaping identical to the mirrored client's rule.
    nonisolated static func escaped(_ segment: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    /// Artifact file name rule copied verbatim from the original
    /// `downloadArtifact` (sanitize unsafe characters to `_`, fall back to
    /// the id-based name when nothing survives).
    nonisolated static func suggestedArtifactName(id: Int64, name: String) -> String {
        let safeName = name.replacingOccurrences(
            of: #"[^A-Za-z0-9._-]"#, with: "_", options: .regularExpression
        )
        return safeName.isEmpty ? "artifact-\(id).zip" : "\(safeName).zip"
    }

    /// Token redaction identical to the original client rule.
    nonisolated func redact(_ message: String, token: String) -> String {
        guard !token.isEmpty else { return message }
        return message.replacingOccurrences(of: token, with: "<redacted>")
    }
}
